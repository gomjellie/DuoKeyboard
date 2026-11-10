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
