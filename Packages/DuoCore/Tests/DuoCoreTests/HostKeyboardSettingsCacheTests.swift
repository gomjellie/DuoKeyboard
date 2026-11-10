@testable import DuoKit
import Foundation
import Testing

/// System Settings ▸ Keyboard drops the approval request for an input method its own cache does not
/// list. A cache without Duo is stale and goes; a missing cache is left for the extension to build.
@Suite("Host · System Settings keyboard cache")
struct HostKeyboardSettingsCacheTests {
    static func directory(index: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "duo-kbcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let index {
            try Data("bplist00 \(index) /Library/Input Methods".utf8).write(to: url.appending(path: KeyboardSettingsCache.indexFileName))
            try Data("le".utf8).write(to: url.appending(path: "com.apple.IntlDataCache.le"))
        }
        return url
    }

    @Test("a cache without Duo is stale and is removed")
    func staleCacheIsRemoved() throws {
        let url = try Self.directory(index: "com.apple.inputmethod.Korean")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(KeyboardSettingsCache.isStale(in: url))
        #expect(KeyboardSettingsCache.removeIfStale(in: url))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
    }

    @Test("a cache that lists Duo stays")
    func currentCacheStays() throws {
        let url = try Self.directory(index: "com.apple.inputmethod.Korean \(DuoIDs.inputMethodBundleID)")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!KeyboardSettingsCache.isStale(in: url))
        #expect(!KeyboardSettingsCache.removeIfStale(in: url))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).count == 2)
    }

    @Test("no cache is not stale; removing one that lists Duo forgets it")
    func missingAndForcedRemoval() throws {
        let empty = try Self.directory(index: nil)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(!KeyboardSettingsCache.isStale(in: empty))
        #expect(!KeyboardSettingsCache.remove(in: empty))

        let listed = try Self.directory(index: DuoIDs.inputMethodBundleID)
        defer { try? FileManager.default.removeItem(at: listed) }
        #expect(KeyboardSettingsCache.remove(in: listed))
        #expect(try FileManager.default.contentsOfDirectory(atPath: listed.path).isEmpty)
    }

    @Test("the cache lives in the extension's folder of the user cache directory")
    func directoryPath() throws {
        let url = try #require(KeyboardSettingsCache.directory)
        #expect(url.lastPathComponent == "com.apple.Keyboard-Settings.extension")
        #expect(url.path.hasPrefix("/private/var/folders/") || url.path.hasPrefix("/var/folders/"))
    }
}

/// TIS here can miss that System Settings turned Duo on; the reload request repeats while the lists
/// disagree, but not forever.
@Suite("Host · TIS catch-up")
struct HostTISCatchUpTests {
    @Test("asks to reload every 2 s while behind, at most 5 times, and starts over once in step")
    func pacing() {
        var catchUp = InputSourceManager.CatchUp()
        func post(_ behind: Bool, at seconds: Double) -> Bool {
            catchUp.shouldPost(behind: behind, now: Date(timeIntervalSince1970: seconds))
        }
        #expect(!post(false, at: 0))
        #expect(post(true, at: 0))
        #expect(!post(true, at: 1))
        #expect(post(true, at: 2))
        let more = (3...5).map { post(true, at: Double($0) * 2) }
        #expect(more == [true, true, true])
        #expect(!post(true, at: 20), "no sixth request in a row")
        #expect(!post(false, at: 21))
        #expect(post(true, at: 22), "a new disagreement asks again")

        var waiting = InputSourceManager.CatchUp()
        let asks = (0..<8).map { waiting.shouldPost(behind: true, unlimited: true, now: Date(timeIntervalSince1970: Double($0) * 2)) }
        #expect(asks == Array(repeating: true, count: 8), "a turn-on waiting for the user keeps asking")
    }
}
