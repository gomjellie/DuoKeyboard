import AppKit
import Carbon
import Darwin
import Foundation
import os

/// Installs, enables and selects the Duo input method for the current user.
///
/// `TISEnableInputSource` on a third-party source that the user has not approved yet opens System
/// Settings ▸ Keyboard with "Allow “Duo” to enable “Duo”?" and returns `noErr` at once; the source is
/// enabled when the user presses Allow, which also writes `com.apple.inputsources` →
/// `AppleEnabledThirdPartyInputSources`. The installer never writes that allow-list itself: a source
/// enabled that way works when selected, but macOS never adds it to the input menu (verified live
/// on macOS 26). `install` therefore stops with `.enableFailed(noErr)` while the prompt is up, and
/// the host waits for the answer (`InstallRecovery`).
///
/// Every entry point is synchronous and may be called from a background thread: file work runs on the
/// caller's thread and TIS mutations hop to the main thread (see `InputSourceManager`).
public enum InputMethodInstaller {
    /// The stages of `install`, in order. The host app shows them as a live checklist.
    public enum Step: String, Sendable, CaseIterable {
        case copied, registered, allowListed, enabled, selected
    }

    /// Why `install` stopped. Hosts show their own localized copy; `errorDescription` is a fallback.
    public enum InstallError: Error, LocalizedError, Sendable, Equatable {
        case bundleMissing(String)
        case copyFailed(String)
        case registerFailed(OSStatus)
        case enableFailed(OSStatus)
        case selectFailed(OSStatus)

        /// A Korean description for logs and fallback UI.
        public var errorDescription: String? {
            switch self {
            case .bundleMissing(let p): "입력기 번들을 찾을 수 없어요: \(p)"
            case .copyFailed(let m): "입력기를 설치하지 못했어요: \(m)"
            case .registerFailed(let s): "입력 소스를 등록하지 못했어요 (\(s))"
            case .enableFailed(let s): "입력 소스를 켜지 못했어요 (\(s))"
            case .selectFailed(let s): "입력 소스를 선택하지 못했어요 (\(s))"
            }
        }

        /// The checklist step that failed.
        public var step: Step {
            switch self {
            case .bundleMissing, .copyFailed: .copied
            case .registerFailed: .registered
            case .enableFailed: .enabled
            case .selectFailed: .selected
            }
        }
    }

    static var thirdPartyDomain: CFString { "com.apple.inputsources" as CFString }
    static var thirdPartyKey: CFString { "AppleEnabledThirdPartyInputSources" as CFString }

    /// The input method bundle embedded in the host app (Duo.app/Contents/Library/Input Methods/…).
    public static var embeddedBundleURL: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Library/Input Methods/DuoInputMethod.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Version string of the installed input method, if any. Read from disk on every call (no
    /// `Bundle` cache), so it reflects an update immediately.
    public static var installedVersion: String? {
        BundleVersion(bundleURL: InputSourceManager.installedBundleURL)?.marketing
    }

    /// `DuoInputMethod.app` is in `~/Library/Input Methods`.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: InputSourceManager.installedBundleURL.path)
    }

    // MARK: - Install

    /// Copies `source` into ~/Library/Input Methods, replacing any older copy, then stops the running
    /// server so the next activation launches the new binary.
    ///
    /// The copy goes to a staging folder next to the destination and is swapped in with one rename,
    /// so a failed copy (disk full, unreadable source) leaves the installed IME untouched and a
    /// partial bundle never sits at the registered path. The old server is stopped only after the
    /// swap: whatever TSM relaunches is the new code (as `Tools/scripts/install-ime.sh` does).
    public static func copyBundle(from source: URL) throws {
        try copyBundle(from: source, to: InputSourceManager.installedBundleURL, stopServer: { stopRunningServer() })
    }

    /// ``copyBundle(from:)`` with the destination and the server stop injected (tests use temporary
    /// folders and never touch a real process).
    static func copyBundle(from source: URL, to destination: URL, stopServer: () -> Void,
                           fileManager fm: FileManager = .default) throws {
        guard fm.fileExists(atPath: source.path) else { throw InstallError.bundleMissing(source.path) }
        do {
            try replaceBundle(at: destination, with: source, fileManager: fm)
        } catch {
            log.error("copying the input method failed: \(LearningFile.describe(error), privacy: .public)")
            throw InstallError.copyFailed(error.localizedDescription)
        }
        stopServer()
    }

    /// Name of the staging copy next to the destination. Not an `.app`, so neither TIS nor Launch
    /// Services treats it as a second input method with the same bundle id.
    static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appending(path: destination.lastPathComponent + ".installing", directoryHint: .isDirectory)
    }

    /// Replaces the bundle at `destination` with a copy of `source`: copy to the staging folder (any
    /// stale one from an interrupted install is removed first), then swap it in with
    /// `replaceItemAt` (an atomic exchange on APFS) or, on a first install, a rename. On failure the
    /// staging folder is removed and `destination` is as it was.
    static func replaceBundle(at destination: URL, with source: URL, fileManager fm: FileManager = .default) throws {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = stagingURL(for: destination)
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        do {
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staging, backupItemName: nil,
                                         options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Full install: copy (if a source is given), register, enable (the user approves) and optionally
    /// select.
    @discardableResult
    public static func install(from source: URL?, select: Bool = true) throws -> [Step] {
        try install(from: source, select: select, onStep: { _ in })
    }

    /// `install(from:select:)` that reports each step as it completes, for a live checklist.
    ///
    /// After a copy replaced the running server while Duo is the selected source, Duo is selected
    /// again (via another keyboard source) so the frontmost app connects to the new server; see
    /// ``InputSourceManager/reselect(pause:)``.
    ///
    /// - Parameter onStep: called on the installing thread right after a step succeeds.
    @discardableResult
    public static func install(from source: URL?, select: Bool, onStep: (Step) -> Void) throws -> [Step] {
        var done: [Step] = []
        func complete(_ step: Step) {
            done.append(step)
            onStep(step)
        }
        if let source {
            try copyBundle(from: source)
            complete(.copied)
        }
        let reg = InputSourceManager.register()
        if reg != noErr && !InputSourceManager.isRegistered { throw InstallError.registerFailed(reg) }
        complete(.registered)
        // Not yet approved: macOS shows its prompt and `isEnabled` turns true on Allow.
        if !isAllowListed, !InputSourceManager.isEnabled { openSettingsForApproval() }
        let en = InputSourceManager.enable()
        if !InputSourceManager.isEnabled { throw InstallError.enableFailed(en) }
        complete(.allowListed)
        complete(.enabled)
        let reconnect = source != nil && InputSourceManager.isSelected
        if select {
            let sel = reconnect ? InputSourceManager.reselect() : InputSourceManager.select()
            if sel != noErr { throw InstallError.selectFailed(sel) }
            complete(.selected)
        } else if reconnect {
            InputSourceManager.reselect()
        }
        return done
    }

    /// Replaces the installed input method with `source` (a newer embedded copy): copy and swap,
    /// stop the old server so TSM launches the new binary on next use, re-register the bundle and,
    /// when Duo is the selected source, select it again so the frontmost app reconnects.
    public static func update(from source: URL) throws {
        try copyBundle(from: source)
        let reg = InputSourceManager.register()
        if reg != noErr && !InputSourceManager.isRegistered { throw InstallError.registerFailed(reg) }
        if InputSourceManager.isSelected { InputSourceManager.reselect() }
    }

    /// Disables the source, removes the allow-list entry and deletes the installed bundle. If Duo is
    /// the selected source, a fallback keyboard (ABC) is selected first.
    public static func uninstall() {
        if InputSourceManager.isSelected { InputSourceManager.selectFallbackSource() }
        InputSourceManager.disable()
        removeFromThirdPartyAllowList()
        stopRunningServer()
        try? FileManager.default.removeItem(at: InputSourceManager.installedBundleURL)
    }

    // MARK: - Approval prompt

    /// macOS asks "Allow “Duo” to enable “Duo”?" in System Settings. When System Settings is not
    /// running, the enable call launches it and the prompt can be lost while it starts (seen live: it
    /// opened on General with no prompt, and only a second enable showed it). So open the Keyboard
    /// pane first and give it a moment to come up. Blocks the (background) calling thread.
    static func openSettingsForApproval(launchTimeout: TimeInterval = 5, settle: TimeInterval = 1.2) {
        let settingsID = "com.apple.systempreferences"
        func running() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: settingsID).isEmpty }
        let wasRunning = running()
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        guard !wasRunning, !Thread.isMainThread else { return }
        let deadline = Date().addingTimeInterval(launchTimeout)
        while !running(), Date() < deadline { usleep(100_000) }
        usleep(useconds_t(settle * 1_000_000))
    }

    // MARK: - Server process

    /// The input method's executable name (what `pkill -x` matches).
    static let serverProcessName = "DuoInputMethod"

    /// How long a stop waits for the server to exit. It flushes its learning store on SIGTERM for up
    /// to 3 s before exiting.
    static let serverExitTimeout: Duration = .seconds(4)

    /// Stops every running `DuoInputMethod` process of this user and waits (up to 4 s) for them to
    /// exit; TSM relaunches the server on next use. When Duo is the selected source it is then
    /// selected again, so the frontmost app connects to the new process instead of typing plain ABC
    /// through the dead one. Apps in the background reconnect on their next focus change.
    ///
    /// - Returns: `false` when a process was still running after the timeout.
    @discardableResult
    public static func terminateRunningServer() -> Bool {
        let exited = stopRunningServer()
        if InputSourceManager.isSelected { InputSourceManager.reselect() }
        return exited
    }

    /// SIGTERM to this user's server processes, then a bounded wait for them to exit.
    @discardableResult
    static func stopRunningServer() -> Bool {
        let pids = processIDs(named: serverProcessName)
        guard !pids.isEmpty else { return true }
        let exited = terminate(pids, timeout: serverExitTimeout)
        if !exited { log.error("the input method server did not exit within \(serverExitTimeout, privacy: .public)") }
        return exited
    }

    /// Sends `signal` to each of `pids` and waits until every one that received it has exited.
    ///
    /// - Returns: whether they all exited within `timeout`.
    static func terminate(_ pids: [pid_t], timeout: Duration, pollInterval: Duration = .milliseconds(50),
                          send: (pid_t) -> Bool = { kill($0, SIGTERM) == 0 },
                          isAlive: (pid_t) -> Bool = processExists) -> Bool {
        let signalled = pids.filter(send)
        return waitForExit(of: signalled, timeout: timeout, pollInterval: pollInterval, isAlive: isAlive)
    }

    /// Polls `isAlive` until none of `pids` is alive or `timeout` passes.
    static func waitForExit(of pids: [pid_t], timeout: Duration, pollInterval: Duration = .milliseconds(50),
                            isAlive: (pid_t) -> Bool = processExists) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var remaining = pids
        while true {
            remaining = remaining.filter(isAlive)
            if remaining.isEmpty { return true }
            if clock.now >= deadline { return false }
            Thread.sleep(forTimeInterval: Self.seconds(min(pollInterval, deadline - clock.now)))
        }
    }

    /// `kill(pid, 0)` succeeds (or is refused) while the process exists.
    static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// PIDs of this user's processes whose name is exactly `name`, excluding this process.
    static func processIDs(named name: String) -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        let me = getpid(), uid = getuid()
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0, pid != me else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { return false }
            return processName(pid) == name
        }
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (s, attoseconds) = duration.components
        return max(0, TimeInterval(s) + TimeInterval(attoseconds) / 1e18)
    }

    static let log = Logger(subsystem: DuoIDs.logSubsystem, category: "install")

    // MARK: - Third-party allow-list

    static func readAllowList() -> [[String: Any]] {
        CFPreferencesCopyAppValue(thirdPartyKey, thirdPartyDomain) as? [[String: Any]] ?? []
    }

    /// Duo is listed in `AppleEnabledThirdPartyInputSources`.
    public static var isAllowListed: Bool {
        readAllowList().contains { ($0["Bundle ID"] as? String) == InputSourceManager.inputMethodBundleID }
    }

    /// Removes Duo from `AppleEnabledThirdPartyInputSources`.
    public static func removeFromThirdPartyAllowList() {
        let list = readAllowList().filter { ($0["Bundle ID"] as? String) != InputSourceManager.inputMethodBundleID }
        CFPreferencesSetAppValue(thirdPartyKey, list as CFArray, thirdPartyDomain)
        CFPreferencesAppSynchronize(thirdPartyDomain)
        postEnabledSourcesChanged()
    }

    static func postEnabledSourcesChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.Carbon.TISNotifyEnabledKeyboardInputSourcesChanged"),
            object: nil, userInfo: nil, deliverImmediately: true)
    }
}
