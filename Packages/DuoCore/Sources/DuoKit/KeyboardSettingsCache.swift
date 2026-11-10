import AppKit
import Foundation

/// System Settings ▸ Keyboard is a sandboxed extension (`com.apple.Keyboard-Settings.extension`)
/// with its own copy of the input source cache, `com.apple.IntlDataCache.le*` in its folder of the
/// user cache directory. When that copy was built while Duo was not installed — before the first
/// install, or between 정보 ▸ Duo 제거 and installing again — macOS does not always rebuild it, and
/// System Settings does not know Duo:
/// - it drops the request `TISEnableInputSource` sends for approval ("Invalid value on
///   inputSourceToBeEnabled" in its log), so "Allow “Duo” to enable “Duo”?" never shows;
/// - Duo is missing from the + list and from the list of enabled input sources.
///
/// Deleting the stale copy makes the extension build a new one from the input sources installed
/// now, the next time it starts. A copy that does not exist is not stale.
public enum KeyboardSettingsCache {
    public static let extensionIdentifier = "com.apple.Keyboard-Settings.extension"
    static let indexFileName = "com.apple.IntlDataCache.le.kbdx"
    static let fileNames = ["com.apple.IntlDataCache.le", indexFileName]

    /// `$DARWIN_USER_CACHE_DIR/com.apple.Keyboard-Settings.extension`.
    public static var directory: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        let base = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: base, isDirectory: true).appending(path: extensionIdentifier, directoryHint: .isDirectory)
    }

    /// The copy exists and does not list the input method `bundleID`.
    public static func isStale(in directory: URL, bundleID: String = DuoIDs.inputMethodBundleID) -> Bool {
        guard let data = try? Data(contentsOf: directory.appending(path: indexFileName)) else { return false }
        return data.range(of: Data(bundleID.utf8)) == nil
    }

    /// Deletes the copy. Returns whether a file was deleted.
    @discardableResult
    public static func remove(in directory: URL? = directory) -> Bool {
        guard let directory else { return false }
        var removed = false
        for name in fileNames where (try? FileManager.default.removeItem(at: directory.appending(path: name))) != nil {
            removed = true
        }
        return removed
    }

    /// Deletes the copy when it does not list Duo. Returns whether it did.
    @discardableResult
    public static func removeIfStale(in directory: URL? = directory, bundleID: String = DuoIDs.inputMethodBundleID) -> Bool {
        guard let directory, isStale(in: directory, bundleID: bundleID) else { return false }
        return remove(in: directory)
    }

    /// System Settings holds the cache it loaded: a running copy must quit before a new cache counts.
    /// Waits up to `timeout` for it to exit. Blocks the calling (background) thread.
    static func quitSystemSettings(timeout: TimeInterval = 3) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
        guard !apps.isEmpty else { return }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline { usleep(100_000) }
    }
}
