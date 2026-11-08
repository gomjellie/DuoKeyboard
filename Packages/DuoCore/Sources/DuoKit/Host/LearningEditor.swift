import AppKit
import DuoCore
import Foundation

/// Routes learning edits: the IME is the only writer while it runs, so the host posts commands to
/// it; with no IME process the host rewrites `learning.json` itself (critique R14).
///
/// One user action is one edit (safety-3). Selecting every row and deleting becomes a single
/// `removeAll`; a key string whose every context is selected becomes one context-less `remove`.
/// The rest go one command per row, posted in bursts of at most ``maxBurst``. After each burst the
/// editor waits until the IME has handled everything posted so far (it answers `ping` in order), so
/// the distributed-notification queue (≈ 256 pending posts, measured) can never overflow and drop
/// deletions.
public enum LearningEditor {
    /// How an edit reached the store.
    public enum Delivery: Sendable, Equatable {
        /// Posted to the running IME, which writes the file and answers with `learningChanged`.
        case posted
        /// No IME was running, so the file was rewritten directly.
        case written
    }

    /// Why an edit did not reach the store.
    public enum EditError: Error, Sendable, Equatable, LocalizedError {
        /// The running IME did not confirm a burst in time; later commands were not posted.
        case inputMethodNotResponding
        /// `learning.json` cannot be decoded and could not be set aside; it is left untouched rather
        /// than replaced, since it may be the only copy of the user's words.
        case unreadableFile

        /// A Korean description for logs and fallback UI (the host shows its own localized copy).
        public var errorDescription: String? {
            switch self {
            case .inputMethodNotResponding: "Duo 입력기가 응답하지 않아요"
            case .unreadableFile: "학습 파일을 읽을 수 없어요"
            }
        }
    }

    /// Commands posted before waiting for the IME to confirm them: well under the ≈ 256 pending
    /// distributed notifications after which posts are silently dropped.
    public static let maxBurst = 50
    /// How long to wait for the IME to confirm one burst.
    public static let confirmationTimeout: Duration = .seconds(10)

    /// Whether a Duo input method process is running for this user.
    public static var isInputMethodRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: DuoIDs.inputMethodBundleID).isEmpty
    }

    // MARK: Planning

    /// The fewest commands that forget `ids` without forgetting any other row in `stored` (the rows
    /// the store holds as far as the host knows; `ids` are added to it).
    ///
    /// - Every stored row selected: one `removeAll`.
    /// - Every context of a key string selected: one `remove(raw:context: nil)`.
    /// - Otherwise one `remove(raw:context:)` per row, in key-string then context order.
    public static func commands(forgetting ids: Set<LearnedWord.ID>, stored: Set<LearnedWord.ID>) -> [LearningCommand] {
        guard !ids.isEmpty else { return [] }
        let known = stored.union(ids)
        if known.count == ids.count { return [.removeAll] }
        let byRaw = Dictionary(grouping: known, by: \.raw)
        let contextOrder = LanguageContext.allCases
        var commands: [LearningCommand] = []
        for raw in Set(ids.map(\.raw)).sorted() {
            let rows = byRaw[raw] ?? []
            let chosen = rows.filter(ids.contains)
            if chosen.count == rows.count {
                commands.append(.remove(raw: raw, context: nil))
            } else {
                let contexts = chosen.map(\.context).sorted {
                    (contextOrder.firstIndex(of: $0) ?? 0) < (contextOrder.firstIndex(of: $1) ?? 0)
                }
                commands += contexts.map { .remove(raw: raw, context: $0) }
            }
        }
        return commands
    }

    // MARK: Applying

    /// Applies one `command` through the IME when it runs, else by rewriting the file at `fileURL`.
    @discardableResult
    public static func apply(_ command: LearningCommand, fileURL: URL = DuoIDs.learningFileURL,
                             inputMethodRunning: Bool = isInputMethodRunning) throws -> Delivery {
        if inputMethodRunning {
            postToInputMethod(command)
            return .posted
        }
        try rewrite(fileURL, applying: [command])
        return .written
    }

    /// Applies `commands` as one edit: through the IME when it runs (confirmed bursts, see
    /// ``send(_:via:burst:)``), else with one read and one atomic write, off the main thread.
    @MainActor
    @discardableResult
    public static func apply(_ commands: [LearningCommand], fileURL: URL = DuoIDs.learningFileURL,
                             inputMethodRunning: Bool = isInputMethodRunning,
                             channel: LearningCommandChannel = .distributed) async throws -> Delivery {
        if inputMethodRunning {
            guard await send(commands, via: channel) else { throw EditError.inputMethodNotResponding }
            return .posted
        }
        try await Task.detached(priority: .userInitiated) {
            try rewrite(fileURL, applying: commands)
        }.value
        return .written
    }

    /// Rewrites the file with every command applied: one read, one atomic write, none when nothing
    /// changes. The read is `LearningFile.loadReporting`, which keeps a copy of the original before
    /// leaving out entries it cannot decode and moves an unreadable file aside, so this write never
    /// replaces the only copy of anything. A missing file has nothing to forget.
    public static func rewrite(_ fileURL: URL, applying commands: [LearningCommand]) throws {
        guard !commands.isEmpty else { return }
        let forgetsEverything = commands.contains(.removeAll)
        // The recovery copies (`learning.corrupt-*.json`) hold words too: forgetting everything
        // deletes them as well, as the IME does for a posted `removeAll`.
        defer { if forgetsEverything { LearningFile.removeBackups(besides: fileURL) } }
        let loaded = LearningFile.loadReporting(from: fileURL)
        switch loaded.status {
        case .missing:
            return
        case .unreadable:
            // Moved aside: nothing is left to edit. Still in place: it may be the only copy, so only
            // an explicit "forget everything" replaces it.
            guard loaded.backupURL == nil, FileManager.default.fileExists(atPath: fileURL.path) else { return }
            guard forgetsEverything else { throw EditError.unreadableFile }
            try LearningFile.write(LearningSnapshot(), to: fileURL)
            return
        case .loaded, .recovered:
            break
        }
        let edited = forgetsEverything ? LearningSnapshot() : commands.reduce(loaded.snapshot) { $1.applied(to: $0) }
        guard edited != loaded.snapshot else { return }
        try LearningFile.write(edited, to: fileURL)
    }

    /// Posts `commands` in bursts of at most `burst`, waiting after each burst until the receiver has
    /// handled everything posted so far. Returns `false`, leaving the rest unsent, when a
    /// confirmation does not arrive.
    @MainActor
    public static func send(_ commands: [LearningCommand], via channel: LearningCommandChannel,
                            burst: Int = maxBurst) async -> Bool {
        let size = max(1, burst)
        var start = commands.startIndex
        while start < commands.endIndex {
            let end = min(start + size, commands.endIndex)
            for command in commands[start..<end] { channel.post(command) }
            start = end
            guard await channel.barrier() else { return false }
        }
        return true
    }

    static func postToInputMethod(_ command: LearningCommand) {
        DistributedNotificationCenter.default().postNotificationName(
            DuoIDs.Notifications.learningCommand, object: nil, userInfo: command.userInfo,
            deliverImmediately: true)
    }
}

/// Where ``LearningEditor`` sends commands when the IME runs: the distributed notifications in
/// production, a recorder in tests.
public struct LearningCommandChannel: Sendable {
    /// Hands one command to the receiver.
    public var post: @MainActor @Sendable (LearningCommand) -> Void
    /// Waits until the receiver has handled everything posted before; `false` on timeout.
    public var barrier: @MainActor @Sendable () async -> Bool

    /// A channel from its two operations.
    public init(post: @escaping @MainActor @Sendable (LearningCommand) -> Void,
                barrier: @escaping @MainActor @Sendable () async -> Bool) {
        self.post = post
        self.barrier = barrier
    }

    /// `learning.command` notifications, confirmed with a `ping` → `pong` round trip: the IME
    /// handles distributed notifications in order on its main thread, so its `pong` means every
    /// command posted before the `ping` has been applied.
    public static let distributed = LearningCommandChannel(
        post: { LearningEditor.postToInputMethod($0) },
        barrier: { await InputMethodPing.roundTrip(timeout: LearningEditor.confirmationTimeout) })
}

/// `DuoIDs.Notifications.ping` → `pong`: the running IME's liveness, and a barrier for commands
/// posted before it.
@MainActor
public enum InputMethodPing {
    /// Posts `ping` and waits for the next `pong`; `false` when none arrives within `timeout`.
    public static func roundTrip(timeout: Duration) async -> Bool {
        await reply(timeout: timeout) != nil
    }

    /// Posts `ping` and returns the next `pong`'s string values (`DuoIDs.Notifications.pong`), or
    /// `nil` when none arrives within `timeout` (the IME is not running).
    public static func reply(timeout: Duration) async -> [String: String]? {
        let waiter = PongWaiter()
        return await withCheckedContinuation { continuation in
            waiter.start(continuation, timeout: timeout)
        }
    }
}

@MainActor
private final class PongWaiter {
    private var continuation: CheckedContinuation<[String: String]?, Never>?
    private var observer: (any NSObjectProtocol)?
    private var timeout: Task<Void, Never>?

    func start(_ continuation: CheckedContinuation<[String: String]?, Never>, timeout: Duration) {
        self.continuation = continuation
        let center = DistributedNotificationCenter.default()
        observer = center.addObserver(forName: DuoIDs.Notifications.pong, object: nil, queue: .main) { [weak self] note in
            let values = (note.userInfo ?? [:]).reduce(into: [String: String]()) { out, pair in
                if let key = pair.key as? String, let value = pair.value as? String { out[key] = value }
            }
            MainActor.assumeIsolated { self?.finish(values) }
        }
        self.timeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(nil)
        }
        center.postNotificationName(DuoIDs.Notifications.ping, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func finish(_ answer: [String: String]?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        continuation.resume(returning: answer)
    }
}
