import DuoCore
import DuoKit
import Foundation
import Testing

/// DuoKit.LearningFile / LearningWriter / LearningCommand (critique R14).
@Suite("Engine · learning persistence")
struct EngineLearningPersistenceTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "duo-learning-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "learning.json")
    }

    static let sample = LearningSnapshot(entries: [
        LearningEntry(raw: "go", context: .korean, votes: ["K": 3], updatedAt: t0),
        LearningEntry(raw: "PRdmf", context: .start, votes: ["M2": 1.5, "E": 0.25], updatedAt: t0.addingTimeInterval(1)),
    ])

    @Test func writeThenLoadRoundTrips() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try LearningFile.write(Self.sample, to: url)
        #expect(LearningFile.load(from: url) == Self.sample)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("\"updatedAt\":\"2026-05-09T"), "ISO 8601 dates")
        #expect(json.contains("\"context\":\"KO\""))
    }

    @Test func missingOrCorruptFilesLoadEmpty() throws {
        let url = Self.tempURL()
        #expect(LearningFile.load(from: url) == LearningSnapshot())
        #expect(throws: (any Error).self) { try LearningFile.read(from: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{ not json".utf8).write(to: url)
        #expect(LearningFile.load(from: url) == LearningSnapshot())
    }

    @Test func readsNumericDatesFromDefaultEncoders() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Self.sample).write(to: url)
        #expect(LearningFile.load(from: url) == Self.sample)
    }

    @Test func writerDebouncesBurstsIntoOneWrite() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LearningWriter(url: url, debounce: .milliseconds(150))
        for i in 0..<5 {
            await writer.schedule(LearningSnapshot(entries: [
                LearningEntry(raw: "w\(i)", context: .start, votes: ["E": 1], updatedAt: Self.t0),
            ]))
        }
        #expect(await writer.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await Task.sleep(for: .milliseconds(900))
        #expect(await writer.writeCount == 1)
        #expect(LearningFile.load(from: url).entries.map(\.raw) == ["w4"], "the last snapshot wins")
    }

    @Test func defaultDebounceIsTwoSeconds() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LearningWriter(url: url)
        await writer.schedule(Self.sample)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await writer.writeCount == 0)
        await writer.flush()
        #expect(await writer.writeCount == 1)
    }

    @Test func flushWritesImmediatelyAndOnlyOnce() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LearningWriter(url: url, debounce: .seconds(30))
        await writer.flush()
        #expect(await writer.writeCount == 0, "nothing queued, nothing written")
        await writer.schedule(Self.sample)
        await writer.flush()
        #expect(await writer.writeCount == 1)
        #expect(LearningFile.load(from: url) == Self.sample)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await writer.writeCount == 1)
    }

    @Test func maxDelayBoundsAContinuousBurst() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LearningWriter(url: url, debounce: .milliseconds(150), maxDelay: .milliseconds(300))
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .milliseconds(700) {
            await writer.schedule(Self.sample)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await writer.writeCount >= 1, "changes every 50 ms still reach the disk")
    }

    @Test func providerIsReadOnTheMainActorAtWriteTime() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = await MainActor.run { LearningStore(now: { Self.t0 }) }
        let writes = Counter()
        let writer = LearningWriter(url: url, debounce: .seconds(30), didWrite: { writes.increment() })
        await writer.schedule(from: { store.snapshot() })
        await MainActor.run { _ = store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3) }
        await writer.flush()
        #expect(LearningFile.load(from: url).entries.map(\.raw) == ["go"], "snapshot taken when writing")
        #expect(writes.value == 1)
    }

    @Test func failedWritesAreReported() async {
        let writer = LearningWriter(url: URL(fileURLWithPath: "/dev/null/learning.json"), debounce: .seconds(30))
        await writer.schedule(Self.sample)
        await writer.flush()
        #expect(await writer.lastError != nil)
        #expect(await writer.writeCount == 0)
    }

    // MARK: Commands

    @Test(arguments: [
        (["op": "removeAll"], LearningCommand.removeAll),
        (["op": "remove", "raw": "go", "ctx": "KO"], .remove(raw: "go", context: .korean)),
        (["op": "remove", "raw": "go"], .remove(raw: "go", context: nil)),
    ] as [([String: String], LearningCommand)])
    func commandsParse(_ info: [String: String], _ command: LearningCommand) {
        #expect(LearningCommand(userInfo: info as [AnyHashable: Any]) == command)
        #expect(LearningCommand(userInfo: command.userInfo) == command)
    }

    @Test func badCommandsAreRejected() {
        #expect(LearningCommand(userInfo: nil) == nil)
        #expect(LearningCommand(userInfo: ["op": "explode"]) == nil)
        #expect(LearningCommand(userInfo: ["op": "remove"]) == nil)
        #expect(LearningCommand(userInfo: ["op": "remove", "raw": ""]) == nil)
    }

    @MainActor
    @Test func commandsApplyToTheStore() {
        let store = LearningStore(now: { Self.t0 })
        store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3)
        store.record(raw: "go", context: .english, hypothesis: .english, votes: 3)
        store.record(raw: "so", context: .korean, hypothesis: .korean, votes: 3)
        store.apply(.remove(raw: "go", context: .korean))
        #expect(store.count == 2)
        store.apply(.remove(raw: "go", context: nil))
        #expect(store.count == 1)
        store.apply(.removeAll)
        #expect(store.count == 0)
    }

    @MainActor
    @Test func commandsReportWhetherTheyChangedAnything() {
        // The IME skips the snapshot and the write for a command that changed nothing (a host
        // retry, a row the IME already forgot), so a burst of stale commands costs no disk writes.
        let store = LearningStore(now: { Self.t0 })
        var changes = 0
        store.onChange = { changes += 1 }
        store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3)
        changes = 0
        #expect(store.apply(.remove(raw: "so", context: nil)) == false)
        #expect(store.apply(.remove(raw: "go", context: .english)) == false)
        #expect(changes == 0)
        #expect(store.apply(.remove(raw: "go", context: .korean)) == true)
        #expect(changes == 1)
        #expect(store.apply(.remove(raw: "go", context: .korean)) == false)
        #expect(store.apply(.removeAll) == false, "nothing left to forget")
        store.record(raw: "so", context: .korean, hypothesis: .korean, votes: 3)
        #expect(store.apply(.removeAll) == true)
        #expect(changes == 3)
    }
}

/// A thread-safe counter for `@Sendable` callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
