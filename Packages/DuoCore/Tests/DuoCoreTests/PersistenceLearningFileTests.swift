import DuoCore
@testable import DuoKit
import Foundation
import Testing

/// `LearningFile.load` never lets one bad entry, a newer format or a damaged file cost the user their
/// only copy of `learning.json` (review imk-6, safety-1).
@Suite("Persistence · learning file recovery")
struct PersistenceLearningFileTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A fresh directory holding (eventually) `learning.json`; removed by `cleanUp`.
    static func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "duo-persistence-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "learning.json")
    }

    static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The `learning.corrupt-*.json` copies next to `url`.
    static func backups(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("learning.corrupt-") && $0.pathExtension == "json" }
    }

    /// Three recent entries; the middle one has a context this build does not know.
    static let partlyUnknown: String = {
        let recent = Date.now.addingTimeInterval(-60).formatted(.iso8601)
        return """
            {"version":1,"entries":[
              {"raw":"dkssud","context":"START","votes":{"K":3},"updatedAt":"\(recent)"},
              {"raw":"rkskek","context":"JA","votes":{"K":3},"updatedAt":"\(recent)"},
              {"raw":"go","context":"KO","votes":{"K":1.5},"updatedAt":"\(recent)"}
            ]}
            """
    }()

    @Test func oneUnknownEntryIsSkippedAndTheRestLoads() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        try Data(Self.partlyUnknown.utf8).write(to: url)

        let snapshot = LearningFile.load(from: url)
        #expect(snapshot.entries.map(\.raw) == ["dkssud", "go"])
        #expect(snapshot.entries.map(\.context) == [.start, .korean])
    }

    @Test func badDatesAndWrongShapesSkipOnlyThatEntry() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        try Data("""
            {"version":1,"entries":[
              {"raw":"a1","context":"KO","votes":{"K":3},"updatedAt":"yesterday"},
              {"raw":"a2","context":"KO","votes":"many","updatedAt":"2026-05-09T10:00:00Z"},
              42,
              null,
              {"context":"KO","votes":{"K":3},"updatedAt":"2026-05-09T10:00:00Z"},
              {"raw":"ok","context":"EN","votes":{"E":2},"updatedAt":800000000}
            ]}
            """.utf8).write(to: url)

        let result = LearningFile.loadReporting(from: url)
        #expect(result.snapshot.entries.map(\.raw) == ["ok"])
        #expect(result.skippedEntries == 5)
        #expect(result.status == .recovered)
    }

    @Test func skippedEntriesKeepACopyOfTheOriginalOnce() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        let original = Data(Self.partlyUnknown.utf8)
        try original.write(to: url)

        let first = LearningFile.loadReporting(from: url)
        let backup = try #require(first.backupURL)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try Data(contentsOf: url) == original, "the readable file stays where the host reads it")

        // Every later load (host reloads, the IME restarting) finds the same bytes: no second copy.
        let second = LearningFile.loadReporting(from: url)
        #expect(second.backupURL == backup)
        #expect(try Self.backups(of: url).count == 1)
    }

    @Test func anUnreadableFileIsMovedAsideBeforeAnyWrite() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        let original = Data("{ not json".utf8)
        try original.write(to: url)

        let result = LearningFile.loadReporting(from: url)
        #expect(result.snapshot == LearningSnapshot())
        #expect(result.status == .unreadable)
        let backup = try #require(result.backupURL)
        #expect(try Data(contentsOf: backup) == original)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // The next write (the IME's first learning change) creates a new file and keeps the copy.
        try LearningFile.write(LearningSnapshot(entries: [
            LearningEntry(raw: "hi", context: .start, votes: ["E": 1], updatedAt: Self.t0),
        ]), to: url)
        #expect(try Data(contentsOf: backup) == original)
        #expect(LearningFile.load(from: url).entries.map(\.raw) == ["hi"])
    }

    @Test(arguments: [
        "[]",
        "{\"version\":1}",
        "{\"version\":1,\"entries\":{\"raw\":\"go\"}}",
        "{\"version\":2,\"words\":[{\"raw\":\"go\"}]}",
    ])
    func filesThatAreNotALearningStoreAreMovedAside(_ json: String) throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        try Data(json.utf8).write(to: url)

        let result = LearningFile.loadReporting(from: url)
        #expect(result.snapshot.entries.isEmpty)
        #expect(result.status == .unreadable)
        #expect(try Self.backups(of: url).count == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aMissingFileLoadsEmptyAndCreatesNothing() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }

        let result = LearningFile.loadReporting(from: url)
        #expect(result.snapshot == LearningSnapshot())
        #expect(result.status == .missing)
        #expect(result.backupURL == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).isEmpty)
    }

    @Test func aCleanFileLoadsAsIsWithoutACopy() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        let sample = LearningSnapshot(entries: [
            LearningEntry(raw: "go", context: .korean, votes: ["K": 3], updatedAt: Self.t0),
            LearningEntry(raw: "PRdmf", context: .start, votes: ["M2": 1.5, "E": 0.25], updatedAt: Self.t0),
        ])
        try LearningFile.write(sample, to: url)

        let result = LearningFile.loadReporting(from: url)
        #expect(result.snapshot == sample)
        #expect(result.status == .loaded)
        #expect(result.skippedEntries == 0 && result.repairedEntries == 0)
        #expect(try Self.backups(of: url).isEmpty)
    }

    @Test func aNewerFormatLoadsWhatItCanAndKeepsTheOriginal() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        let original = Data("""
            {"version":2,"entries":[{"raw":"go","context":"KO","votes":{"K":3},"updatedAt":"2026-05-09T10:00:00Z","extra":true}]}
            """.utf8)
        try original.write(to: url)

        let result = LearningFile.loadReporting(from: url)
        #expect(result.snapshot.entries.map(\.raw) == ["go"])
        #expect(result.snapshot.version == LearningSnapshot().version, "written back in this build's format")
        let backup = try #require(result.backupURL)
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func outOfRangeValuesAreRepaired() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        let now = Date(timeIntervalSinceReferenceDate: 810_000_000)
        try Data("""
            {"version":1,"entries":[
              {"raw":"huge","context":"KO","votes":{"K":1e300,"E":2},"updatedAt":800000000},
              {"raw":"neg","context":"KO","votes":{"K":-4,"E":2},"updatedAt":800000000},
              {"raw":"allbad","context":"KO","votes":{"K":-1},"updatedAt":800000000},
              {"raw":"","context":"KO","votes":{"K":3},"updatedAt":800000000},
              {"raw":"future","context":"EN","votes":{"E":3},"updatedAt":"2999-01-01T00:00:00Z"},
              {"raw":"fine","context":"EN","votes":{"E":3},"updatedAt":800000000}
            ]}
            """.utf8).write(to: url)

        let result = LearningFile.loadReporting(from: url, now: now)
        let byRaw = Dictionary(uniqueKeysWithValues: result.snapshot.entries.map { ($0.raw, $0) })
        #expect(Set(byRaw.keys) == ["huge", "neg", "future", "fine"])
        #expect(byRaw["huge"]?.votes == ["K": LearningFile.maxVotes, "E": 2])
        #expect(byRaw["neg"]?.votes == ["E": 2])
        #expect(byRaw["future"]?.updatedAt == now)
        #expect(byRaw["fine"]?.votes == ["E": 3])
        #expect(byRaw["fine"]?.updatedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(result.repairedEntries == 5)
        #expect(result.skippedEntries == 0)
        #expect(result.backupURL == nil, "repairs alone are not worth a copy")
    }

    @Test func repairedVotesNeverOverflowTheDetectorCounts() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        try Data("""
            {"version":1,"entries":[{"raw":"rk","context":"KO","votes":{"K":1e300},"updatedAt":800000000}]}
            """.utf8).write(to: url)
        let snapshot = LearningFile.load(from: url)
        // `LearningStore.counts` rounds votes into an `Int`; 1e300 would trap there.
        let votes = try #require(snapshot.entries.first?.votes["K"])
        #expect(votes <= LearningFile.maxVotes)
        #expect(Double(Int.max) > votes)
    }

    @Test func readIsStrictAboutTheFileButLenientAboutEntriesAndTouchesNothing() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        #expect(throws: (any Error).self) { try LearningFile.read(from: url) }

        try Data(Self.partlyUnknown.utf8).write(to: url)
        #expect(try LearningFile.read(from: url).entries.map(\.raw) == ["dkssud", "go"])
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try LearningFile.read(from: url) }
        #expect(try Self.backups(of: url).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The host's direct-write path (no IME running): removing one word keeps every other one.
    @Test func hostDirectRemoveKeepsTheOtherEntries() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        let original = Data(Self.partlyUnknown.utf8)
        try original.write(to: url)

        try LearningEditor.apply(.remove(raw: "go", context: .korean), fileURL: url, inputMethodRunning: false)
        #expect(LearningFile.load(from: url).entries.map(\.raw) == ["dkssud"])
        let backup = try #require(try Self.backups(of: url).first)
        #expect(try Data(contentsOf: backup) == original, "the entry this build cannot read survives in the copy")
    }

    /// The IME's shape (DuoRuntime): load at launch, learn, write through `LearningWriter`.
    @MainActor
    @Test func imeStartupThenWriteKeepsTheOriginalEntries() async throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        let original = Data(Self.partlyUnknown.utf8)
        try original.write(to: url)

        let store = LearningStore(snapshot: LearningFile.load(from: url))
        #expect(store.count == 2)
        store.record(raw: "rk", context: .korean, hypothesis: .korean, votes: LearningStore.flipVotes)
        let writer = LearningWriter(url: url, debounce: .seconds(30))
        await writer.schedule(store.snapshot())
        #expect(await writer.flush())

        #expect(Set(LearningFile.load(from: url).entries.map(\.raw)) == ["dkssud", "go", "rk"])
        #expect(try Self.backups(of: url).count == 1)
    }

    /// Forgetting everything also deletes the recovery copies: they hold the words the user asked
    /// Duo to forget. Other files in the folder, and the learning file itself, stay.
    @Test func removeBackupsDeletesOnlyTheCopies() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        try Data(Self.partlyUnknown.utf8).write(to: url)
        _ = LearningFile.loadReporting(from: url)   // keeps one copy (an entry was skipped)
        let dir = url.deletingLastPathComponent()
        try Data("{}".utf8).write(to: dir.appending(path: "learning.corrupt-20260101T000000Z.json"))
        try Data("{}".utf8).write(to: dir.appending(path: "settings-notes.json"))
        #expect(try Self.backups(of: url).count == 2)

        #expect(LearningFile.removeBackups(besides: url) == 2)
        #expect(try Self.backups(of: url).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "settings-notes.json").path))
        #expect(LearningFile.removeBackups(besides: url) == 0)
    }

    /// The host's direct "모두 지우기" (no IME running) empties the file and deletes the copies,
    /// including one an unreadable file was moved to.
    @Test(arguments: [true, false])
    func hostDirectEraseAllDeletesTheCopiesToo(unreadable: Bool) throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        try Data((unreadable ? "not json" : Self.partlyUnknown).utf8).write(to: url)
        _ = LearningFile.loadReporting(from: url)
        #expect(try Self.backups(of: url).count == 1)

        try LearningEditor.rewrite(url, applying: [.removeAll])
        #expect(try Self.backups(of: url).isEmpty)
        #expect(LearningFile.load(from: url).entries.isEmpty)
    }

    /// Removing one word keeps the copies: they may hold other words this build could not read.
    @Test func hostDirectRemoveOfOneWordKeepsTheCopies() throws {
        let url = try Self.tempFile()
        defer { Self.cleanUp(url) }
        try Data(Self.partlyUnknown.utf8).write(to: url)
        try LearningEditor.rewrite(url, applying: [.remove(raw: "go", context: nil)])
        #expect(try Self.backups(of: url).count == 1)
    }
}
