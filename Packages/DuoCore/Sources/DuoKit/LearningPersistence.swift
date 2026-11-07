import DuoCore
import Foundation
import os

/// Reads/writes `learning.json` (critique R14: atomic writes, 2 s debounce, IME is the only writer).
///
/// Dates are written as ISO 8601; reading also accepts `JSONEncoder`'s default numeric dates.
///
/// Reading never costs the user their only copy (review imk-6, safety-1). Both writers (the IME and
/// the host's direct-write path) rewrite the whole file from what was loaded, so ``load(from:)``:
/// - skips only the entries it cannot decode (an unknown context from a newer build, a bad date), and
///   repairs out-of-range values (see ``maxVotes``);
/// - keeps a copy of the original as `learning.corrupt-<time>.json` whenever it had to leave anything
///   out, or the file comes from a newer format; the readable file stays in place;
/// - moves a file it cannot read at all aside under that name, so the next write starts a new file.
public enum LearningFile {
    /// The file format this build writes (`LearningSnapshot.version`).
    public static let currentVersion = LearningSnapshot().version

    /// Largest vote count kept for one reading. The detector's user bonus saturates at 15 effective
    /// votes, so this changes nothing real; it only keeps a damaged or hand-edited value from
    /// overflowing `LearningStore`'s integer counts.
    public static let maxVotes: Double = 100_000

    /// What ``loadReporting(from:now:)`` found.
    public struct LoadResult: Sendable, Equatable {
        public enum Status: Sendable, Equatable {
            /// No file yet (first run, or after a reset).
            case missing
            /// Read in full.
            case loaded
            /// Read, but some entries were left out or the format is newer; the original is kept in
            /// ``backupURL`` (nil if the copy failed).
            case recovered
            /// Not a readable learning file; it was moved to ``backupURL`` (nil if even that failed).
            case unreadable
        }

        public var snapshot: LearningSnapshot
        public var status: Status
        /// Entries that could not be decoded and were left out.
        public var skippedEntries: Int
        /// Entries dropped or changed because a value was out of range (votes, dates, empty keys).
        public var repairedEntries: Int
        /// Where the original file is kept, when it could not be used in full.
        public var backupURL: URL?
    }

    /// The snapshot at `url`, recovering what it can (see the type's notes). Never throws; a missing
    /// file is an empty snapshot.
    public static func load(from url: URL = DuoIDs.learningFileURL) -> LearningSnapshot {
        loadReporting(from: url).snapshot
    }

    /// ``load(from:)`` with a report of what was skipped, repaired or set aside.
    ///
    /// - Parameter now: the clock for repairing `updatedAt` values in the future (tests inject one).
    public static func loadReporting(from url: URL = DuoIDs.learningFileURL, now: Date = Date()) -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error where isMissingFile(error) {
            return LoadResult(snapshot: LearningSnapshot(), status: .missing, skippedEntries: 0, repairedEntries: 0)
        } catch {
            return setAside(url, reason: "read failed, \(describe(error))")
        }

        let decoded: Decoded
        do {
            decoded = try decode(data)
        } catch {
            return setAside(url, reason: "not a learning file")
        }
        let (snapshot, repaired) = sanitised(decoded.entries, now: now)
        let newer = decoded.version.map { $0 > currentVersion } ?? true
        guard decoded.skipped > 0 || newer else {
            if repaired > 0 { log.info("repaired \(repaired, privacy: .public) learning entries") }
            return LoadResult(snapshot: snapshot, status: .loaded, skippedEntries: 0, repairedEntries: repaired)
        }

        let backup = keepCopy(of: data, besides: url)
        log.error("""
            learning.json: kept \(snapshot.entries.count, privacy: .public) entries, skipped \(decoded.skipped, privacy: .public), \
            repaired \(repaired, privacy: .public), format \(decoded.version.map(String.init) ?? "?", privacy: .public); \
            original kept as \(backup?.lastPathComponent ?? "(copy failed)", privacy: .public)
            """)
        return LoadResult(snapshot: snapshot, status: .recovered, skippedEntries: decoded.skipped,
                          repairedEntries: repaired, backupURL: backup)
    }

    /// The snapshot at `url`, with undecodable entries left out and values repaired; throws when the
    /// file is missing or is not a learning file at all. Unlike ``load(from:)`` it never touches the disk.
    public static func read(from url: URL = DuoIDs.learningFileURL) throws -> LearningSnapshot {
        let decoded = try decode(Data(contentsOf: url))
        return sanitised(decoded.entries, now: Date()).snapshot
    }

    /// Writes `snapshot` atomically, creating the directory if needed.
    public static func write(_ snapshot: LearningSnapshot, to url: URL = DuoIDs.learningFileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(snapshot).write(to: url, options: .atomic)
    }

    /// The file's bytes for `snapshot` (stable key order).
    public static func encode(_ snapshot: LearningSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    // MARK: - Decoding

    static let log = Logger(subsystem: DuoIDs.logSubsystem, category: "learning")

    /// The file as found: its `version` (nil when present but not an integer), the entries that
    /// decoded, and how many did not.
    struct Decoded: Decodable {
        var version: Int?
        var entries: [LearningEntry]
        var skipped: Int

        private enum CodingKeys: String, CodingKey { case version, entries }

        /// Consumes one array element of any shape, so a bad entry can be stepped over.
        private struct Skip: Decodable {
            init(from decoder: any Decoder) {}
        }

        init(from decoder: any Decoder) throws {
            // Not an object, no `entries`, or `entries` not an array: not a learning file (throws).
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.version) {
                version = try? container.decode(Int.self, forKey: .version)
            } else {
                version = LearningFile.currentVersion
            }
            var list = try container.nestedUnkeyedContainer(forKey: .entries)
            var entries: [LearningEntry] = []
            var skipped = 0
            while !list.isAtEnd {
                if let entry = try? list.decode(LearningEntry.self) {
                    entries.append(entry)
                    continue
                }
                if try !list.decodeNil() { _ = try list.decode(Skip.self) }
                skipped += 1
            }
            self.entries = entries
            self.skipped = skipped
        }
    }

    static func decode(_ data: Data) throws -> Decoded {
        try decoder.decode(Decoded.self, from: data)
    }

    /// `entries` with values in range: finite, non-negative votes up to ``maxVotes``, no empty keys,
    /// `updatedAt` no later than `now`. Entries left without votes are dropped. Returns how many
    /// entries were dropped or changed.
    static func sanitised(_ entries: [LearningEntry], now: Date) -> (snapshot: LearningSnapshot, repaired: Int) {
        var out: [LearningEntry] = []
        out.reserveCapacity(entries.count)
        var repaired = 0
        for entry in entries {
            var fixed = entry
            fixed.votes = entry.votes.compactMapValues { $0.isFinite && $0 >= 0 ? min($0, maxVotes) : nil }
            if fixed.updatedAt > now { fixed.updatedAt = now }
            guard !fixed.raw.isEmpty, !fixed.votes.isEmpty else {
                repaired += 1
                continue
            }
            if fixed != entry { repaired += 1 }
            out.append(fixed)
        }
        return (LearningSnapshot(entries: out), repaired)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                guard seconds.isFinite else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date")
                }
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try container.decode(String.self)
            guard let date = try? Date(text, strategy: .iso8601) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date")
            }
            return date
        }
        return decoder
    }

    // MARK: - Keeping the original

    /// Moves an unusable file aside so the next write cannot replace the only copy.
    private static func setAside(_ url: URL, reason: String) -> LoadResult {
        let backup = backupURL(besides: url)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
        } catch let error where isMissingFile(error) {
            // Another process (the host or the IME) set it aside first.
            return LoadResult(snapshot: LearningSnapshot(), status: .missing, skippedEntries: 0, repairedEntries: 0)
        } catch {
            log.fault("""
                learning.json is unusable (\(reason, privacy: .public)) and could not be moved aside: \
                \(describe(error), privacy: .public)
                """)
            return LoadResult(snapshot: LearningSnapshot(), status: .unreadable, skippedEntries: 0, repairedEntries: 0)
        }
        log.error("""
            learning.json is unusable (\(reason, privacy: .public)); moved to \(backup.lastPathComponent, privacy: .public), \
            starting with no learned words
            """)
        return LoadResult(snapshot: LearningSnapshot(), status: .unreadable, skippedEntries: 0, repairedEntries: 0,
                          backupURL: backup)
    }

    /// Copies `data` (the original file) next to `url`, unless an earlier copy holds the same bytes.
    /// Returns the copy, or nil if writing it failed.
    private static func keepCopy(of data: Data, besides url: URL) -> URL? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let existing = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for candidate in existing where isBackupName(candidate.lastPathComponent) {
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if size == data.count, (try? Data(contentsOf: candidate)) == data {
                // Spelled from the caller's URL (the listing may resolve /var to /private/var).
                return dir.appending(path: candidate.lastPathComponent)
            }
        }
        let backup = backupURL(besides: url)
        do {
            try data.write(to: backup, options: .withoutOverwriting)
            return backup
        } catch {
            log.fault("could not keep a copy of learning.json: \(describe(error), privacy: .public)")
            return nil
        }
    }

    /// `learning.corrupt-<UTC time>.json` next to `url`, with a counter if that name is taken.
    static func backupURL(besides url: URL, now: Date = Date()) -> URL {
        let dir = url.deletingLastPathComponent()
        let stamp = now.formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, dateTimeSeparator: .standard,
                                                          timeSeparator: .omitted, timeZone: .gmt))
        var candidate = dir.appending(path: "\(backupPrefix)\(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: "\(backupPrefix)\(stamp)-\(n).json")
            n += 1
        }
        return candidate
    }

    /// Deletes every `learning.corrupt-*.json` copy next to `url` (the file itself stays). Called when
    /// the user forgets everything: the copies hold words they asked Duo to forget.
    ///
    /// - Returns: how many copies were deleted.
    @discardableResult
    public static func removeBackups(besides url: URL = DuoIDs.learningFileURL) -> Int {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let listed = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for candidate in listed where isBackupName(candidate.lastPathComponent) {
            do {
                try fm.removeItem(at: candidate)
                removed += 1
            } catch {
                log.error("could not delete a learning.json copy: \(describe(error), privacy: .public)")
            }
        }
        if removed > 0 { log.info("deleted \(removed, privacy: .public) learning.json copies") }
        return removed
    }

    static let backupPrefix = "learning.corrupt-"

    static func isBackupName(_ name: String) -> Bool {
        name.hasPrefix(backupPrefix) && name.hasSuffix(".json")
    }

    static func isMissingFile(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoSuchFile.rawValue
            || ns.code == CocoaError.fileNoSuchFile.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
        }
        return false
    }

    /// An error as domain and code (plus the underlying POSIX code): no paths, no file contents.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }
}

/// Debounced background writer for `learning.json` (critique R14).
///
/// The IME calls ``schedule(_:)`` (or ``schedule(from:)``, which takes the snapshot only when the
/// write happens) after every learning change. The file is written once changes have been quiet for
/// the debounce interval (2 s), and at most ``maxDelay`` after the first pending change, always
/// atomically. Call ``flush()`` from `applicationWillTerminate`.
///
/// A failed write is logged (`learning` category, error domain and code only) and reported by
/// ``flush()``; the next change writes the whole snapshot again.
public actor LearningWriter {
    private let url: URL
    private let debounce: Duration
    private let maxDelay: Duration
    private let didWrite: (@Sendable () -> Void)?

    private var pending: Pending?
    private var firstPendingAt: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var generation = 0

    /// Description of the most recent failed write, cleared by a successful one.
    public private(set) var lastError: String?
    /// Number of successful writes (diagnostics, tests).
    public private(set) var writeCount = 0

    private enum Pending {
        case snapshot(LearningSnapshot)
        case provider(@Sendable @MainActor () -> LearningSnapshot)
    }

    /// - Parameters:
    ///   - url: the learning file.
    ///   - debounce: quiet time before writing (2 s).
    ///   - maxDelay: longest a change may wait while changes keep coming (10 s).
    ///   - didWrite: called after each successful write (post `DuoIDs.Notifications.learningChanged`).
    public init(url: URL = DuoIDs.learningFileURL, debounce: Duration = .seconds(2), maxDelay: Duration = .seconds(10),
                didWrite: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.debounce = debounce
        self.maxDelay = maxDelay
        self.didWrite = didWrite
    }

    /// Queues `snapshot` for the next write, replacing anything queued before.
    public func schedule(_ snapshot: LearningSnapshot) {
        enqueue(.snapshot(snapshot))
    }

    /// Queues a write whose snapshot is taken on the main actor when the write happens, so a burst
    /// of changes costs one snapshot (`LearningStore` lives on the main actor).
    public func schedule(from provider: @escaping @Sendable @MainActor () -> LearningSnapshot) {
        enqueue(.provider(provider))
    }

    /// Writes anything queued now and waits for it.
    ///
    /// - Returns: `true` when the file holds everything scheduled so far (also when nothing was
    ///   pending), `false` when the most recent write failed.
    @discardableResult
    public func flush() async -> Bool {
        timer?.cancel()
        timer = nil
        await writePending()
        return lastError == nil
    }

    private func enqueue(_ item: Pending) {
        pending = item
        let now = ContinuousClock.now
        let first = firstPendingAt ?? now
        firstPendingAt = first
        let deadline = min(now + debounce, first + maxDelay)
        generation += 1
        let current = generation
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.timerFired(generation: current)
        }
    }

    private func timerFired(generation fired: Int) async {
        guard fired == generation else { return }
        timer = nil
        await writePending()
    }

    private func writePending() async {
        guard let item = pending else { return }
        pending = nil
        firstPendingAt = nil
        let snapshot: LearningSnapshot = switch item {
        case .snapshot(let s): s
        case .provider(let make): await make()
        }
        do {
            try LearningFile.write(snapshot, to: url)
            lastError = nil
            writeCount += 1
            didWrite?()
        } catch {
            lastError = String(describing: error)
            LearningFile.log.error("""
                learning write failed (\(snapshot.entries.count, privacy: .public) entries): \
                \(LearningFile.describe(error), privacy: .public)
                """)
        }
    }
}

/// The payload of `DuoIDs.Notifications.learningChanged`, which the IME posts after it wrote
/// `learning.json` (no payload), or after a host edit it applied in memory but could not save
/// (`ok` = `"false"`), so Settings ▸ 학습 can say so.
public enum LearningChangedNotice {
    public static let okKey = "ok"

    /// The payload for an edit whose write succeeded (`saved`) or failed.
    public static func userInfo(saved: Bool) -> [String: String] {
        [okKey: saved ? "true" : "false"]
    }

    /// Whether a received notice reports a failed save; no payload means the file was written.
    public static func reportsFailedSave(_ userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?[okKey] as? String) == "false"
    }
}

/// A host-app request to edit the learned words (critique R14), carried by the
/// `DuoIDs.Notifications.learningCommand` distributed notification.
public enum LearningCommand: Sendable, Hashable {
    /// Forget one key string, in one context or (nil) all of them.
    case remove(raw: String, context: LanguageContext?)
    /// Forget everything.
    case removeAll

    /// Parses `["op": "remove"|"removeAll", "raw": String, "ctx": String?]`.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo, let op = info["op"] as? String else { return nil }
        switch op {
        case "removeAll":
            self = .removeAll
        case "remove":
            guard let raw = info["raw"] as? String, !raw.isEmpty else { return nil }
            let context = (info["ctx"] as? String).flatMap(LanguageContext.init(rawValue:))
            self = .remove(raw: raw, context: context)
        default:
            return nil
        }
    }

    /// The notification payload for this command.
    public var userInfo: [String: String] {
        switch self {
        case .removeAll:
            return ["op": "removeAll"]
        case .remove(let raw, let context):
            var info = ["op": "remove", "raw": raw]
            if let context { info["ctx"] = context.rawValue }
            return info
        }
    }
}

extension LearningStore {
    /// Applies a host-app command.
    ///
    /// - Returns: whether it changed anything (a repeated or stale command changes nothing).
    @discardableResult
    public func apply(_ command: LearningCommand) -> Bool {
        switch command {
        case .removeAll: removeAll()
        case .remove(let raw, let context): remove(raw: raw, context: context)
        }
    }
}
