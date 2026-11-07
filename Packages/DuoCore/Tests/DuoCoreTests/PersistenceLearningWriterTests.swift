import DuoCore
import DuoKit
import Foundation
import Testing

/// `LearningWriter.flush()` reports a failed write, so the IME can tell the host instead of
/// claiming success (review safety-6). The failure itself is logged inside the writer.
@Suite("Persistence · learning writer failures")
struct PersistenceLearningWriterTests {
    static let entry = LearningEntry(raw: "go", context: .korean, votes: ["K": 3],
                                     updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))

    @Test func flushReportsAFailedWrite() async {
        // A path under /dev/null can never be created.
        let writer = LearningWriter(url: URL(fileURLWithPath: "/dev/null/Duo/learning.json"), debounce: .seconds(30))
        await writer.schedule(LearningSnapshot(entries: [Self.entry]))
        #expect(await writer.flush() == false)
        #expect(await writer.lastError != nil)
        #expect(await writer.writeCount == 0)
        // Nothing new is pending, but the file still does not hold what was scheduled.
        #expect(await writer.flush() == false)
    }

    @Test func flushReportsSuccessAndANothingPendingFlush() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "duo-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "learning.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = LearningWriter(url: url, debounce: .seconds(30))
        #expect(await writer.flush(), "nothing scheduled yet")
        await writer.schedule(LearningSnapshot(entries: [Self.entry]))
        #expect(await writer.flush())
        #expect(LearningFile.load(from: url).entries == [Self.entry])
    }

    @Test func aLaterSuccessfulWriteClearsTheFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "duo-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        // `Duo` exists as a plain file, so the writer cannot create its directory.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appending(path: "Duo")
        try Data().write(to: blocker)
        let writer = LearningWriter(url: blocker.appending(path: "learning.json"), debounce: .seconds(30))
        await writer.schedule(LearningSnapshot(entries: [Self.entry]))
        #expect(await writer.flush() == false)

        try FileManager.default.removeItem(at: blocker)
        await writer.schedule(LearningSnapshot(entries: [Self.entry]))
        #expect(await writer.flush())
        #expect(await writer.lastError == nil)
    }
}

/// The IME → host `learningChanged` payload (safety-6): a failed save must reach Settings ▸ 학습.
@Suite("Persistence · learningChanged notice")
struct PersistenceLearningChangedNoticeTests {
    @Test func aFailedSaveIsReportedAndEverythingElseMeansSaved() {
        #expect(LearningChangedNotice.reportsFailedSave(LearningChangedNotice.userInfo(saved: false)))
        #expect(!LearningChangedNotice.reportsFailedSave(LearningChangedNotice.userInfo(saved: true)))
        #expect(!LearningChangedNotice.reportsFailedSave(nil), "an ordinary write posts no payload")
        #expect(!LearningChangedNotice.reportsFailedSave(["ok": 0]))
    }
}
