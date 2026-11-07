import Carbon
import Foundation

/// Thin, Swift-friendly wrapper over the Text Input Sources (TIS) API used to install,
/// enable and select the Duo input method.
///
/// Queries are safe from any thread. Mutations (`register`, `enable`, `disable`, `select`) always run
/// on the main thread: called from a background thread they hop there synchronously, so a long
/// install can run off the main actor while TSM still sees its calls on the main thread.
public enum InputSourceManager {
    /// The input method bundle id (`DuoIDs.inputMethodBundleID`).
    public static let inputMethodBundleID = DuoIDs.inputMethodBundleID

    /// Where the input method bundle must live for TSM to discover it.
    public static var userInputMethodsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Input Methods", directoryHint: .isDirectory)
    }

    /// `~/Library/Input Methods/DuoInputMethod.app`.
    public static var installedBundleURL: URL {
        userInputMethodsDirectory.appending(path: "DuoInputMethod.app", directoryHint: .isDirectory)
    }

    /// One input source as TIS describes it.
    public struct SourceInfo: Sendable, Equatable {
        /// `kTISPropertyInputSourceID`.
        public var id: String
        /// `kTISPropertyBundleID`.
        public var bundleID: String?
        /// `kTISPropertyLocalizedName`, e.g. "2벌식".
        public var localizedName: String?
        /// The source is in the user's input menu.
        public var isEnabled: Bool
        /// The source is the current keyboard input source.
        public var isSelected: Bool
        /// TIS can select it (an input method or one of its modes).
        public var isSelectCapable: Bool
    }

    // MARK: - Queries
    //
    // TIS asserts the main queue on macOS 26 (`islGetInputSourceListWithAdditions` →
    // `dispatch_assert_queue`, a SIGTRAP seen live when `install` checked `isEnabled` from its
    // background thread). Every public query therefore hops to the main thread like the mutations.

    /// All input sources (installed, not only enabled) whose bundle id matches Duo's.
    static func duoSources() -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: inputMethodBundleID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list
    }

    /// The Duo source that can actually be selected (the input method or its only mode).
    static func primaryDuoSource() -> TISInputSource? {
        let sources = duoSources()
        return sources.first { boolProperty($0, kTISPropertyInputSourceIsSelectCapable) } ?? sources.first
    }

    /// Every Duo source TIS knows, enabled or not.
    public static func duoSourceInfos() -> [SourceInfo] { onMain { duoSources().map(info) } }

    /// TIS knows Duo (the bundle was registered).
    public static var isRegistered: Bool { onMain { !duoSources().isEmpty } }
    /// Duo is in the input menu.
    public static var isEnabled: Bool {
        onMain { primaryDuoSource().map { boolProperty($0, kTISPropertyInputSourceIsEnabled) } ?? false }
    }
    /// Duo is the current keyboard input source.
    public static var isSelected: Bool {
        onMain { primaryDuoSource().map { boolProperty($0, kTISPropertyInputSourceIsSelected) } ?? false }
    }

    /// `kTISPropertyInputSourceID` of the current keyboard input source.
    public static func currentKeyboardSourceID() -> String? {
        onMain {
            guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
            return stringProperty(src, kTISPropertyInputSourceID)
        }
    }

    /// The currently selected keyboard input source (for status rows such as "현재: 2벌식").
    public static func currentKeyboardSource() -> SourceInfo? {
        onMain {
            guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
            return info(src)
        }
    }

    // MARK: - Mutations

    /// Registers the bundle at `url` with TSM (needed after copying a new bundle into Input Methods).
    @discardableResult
    public static func register(bundleAt url: URL = installedBundleURL) -> OSStatus {
        onMain { TISRegisterInputSource(url as CFURL) }
    }

    @discardableResult
    public static func enable() -> OSStatus {
        onMain {
            var status: OSStatus = OSStatus(paramErr)
            for src in duoSources() where !boolProperty(src, kTISPropertyInputSourceIsEnabled) {
                status = TISEnableInputSource(src)
            }
            return isEnabled ? noErr : status
        }
    }

    @discardableResult
    public static func disable() -> OSStatus {
        onMain {
            var status: OSStatus = noErr
            for src in duoSources() where boolProperty(src, kTISPropertyInputSourceIsEnabled) {
                status = TISDisableInputSource(src)
            }
            return status
        }
    }

    @discardableResult
    public static func select() -> OSStatus {
        onMain {
            guard let src = primaryDuoSource() else { return OSStatus(paramErr) }
            return TISSelectInputSource(src)
        }
    }

    /// Selects an arbitrary keyboard input source by id (used to restore the user's previous source).
    @discardableResult
    public static func select(sourceID: String) -> OSStatus {
        onMain {
            let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
            guard let src = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first else {
                return OSStatus(paramErr)
            }
            return TISSelectInputSource(src)
        }
    }

    /// Keyboard layouts tried, in order, when Duo has to stop being the selected source.
    public static let fallbackSourceIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]

    /// Moves the selection off Duo before it is disabled, so the user is never left without a keyboard.
    ///
    /// Picks the first enabled source from `fallbackSourceIDs`, then any other enabled, selectable
    /// ASCII-capable keyboard source. When none is enabled, ABC is enabled first.
    @discardableResult
    public static func selectFallbackSource() -> OSStatus {
        onMain {
            if let src = enabledAlternativeSource() { return TISSelectInputSource(src) }
            let filter = [kTISPropertyInputSourceID as String: fallbackSourceIDs[0]] as CFDictionary
            guard let abc = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first else {
                return OSStatus(paramErr)
            }
            let status = TISEnableInputSource(abc)
            return status == noErr ? TISSelectInputSource(abc) : status
        }
    }

    /// Selects another keyboard source and then Duo again (qa-4).
    ///
    /// After the server process is replaced (install, update, restart), apps stay bound to the dead
    /// process and type plain ABC until the input source is re-selected while they are frontmost.
    /// Toggling the selection makes the frontmost app connect to the new server; apps in the
    /// background reconnect on their next focus change.
    ///
    /// The other source is an already enabled one (as in ``selectFallbackSource()``); nothing is
    /// enabled for this. Without one, Duo is only selected. The calling thread sleeps for `pause`
    /// between the two selections (both run on the main thread), so call it off the main thread.
    ///
    /// - Returns: the status of selecting Duo.
    @discardableResult
    public static func reselect(pause: Duration = .milliseconds(300)) -> OSStatus {
        let away: OSStatus = onMain {
            guard let src = enabledAlternativeSource() else { return OSStatus(paramErr) }
            return TISSelectInputSource(src)
        }
        if away == noErr {
            let (seconds, attoseconds) = pause.components
            Thread.sleep(forTimeInterval: TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18)
        }
        return select()
    }

    /// The first enabled, selectable keyboard source that is not Duo: one of `fallbackSourceIDs`,
    /// else any ASCII-capable one.
    @MainActor
    static func enabledAlternativeSource() -> TISInputSource? {
        let enabled = enabledKeyboardSources().filter {
            stringProperty($0, kTISPropertyBundleID) != inputMethodBundleID
                && boolProperty($0, kTISPropertyInputSourceIsSelectCapable)
        }
        for id in fallbackSourceIDs {
            if let src = enabled.first(where: { stringProperty($0, kTISPropertyInputSourceID) == id }) { return src }
        }
        return enabled.first { boolProperty($0, kTISPropertyInputSourceIsASCIICapable) }
    }

    // MARK: - Property helpers

    static func enabledKeyboardSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func info(_ src: TISInputSource) -> SourceInfo {
        SourceInfo(
            id: stringProperty(src, kTISPropertyInputSourceID) ?? "?",
            bundleID: stringProperty(src, kTISPropertyBundleID),
            localizedName: stringProperty(src, kTISPropertyLocalizedName),
            isEnabled: boolProperty(src, kTISPropertyInputSourceIsEnabled),
            isSelected: boolProperty(src, kTISPropertyInputSourceIsSelected),
            isSelectCapable: boolProperty(src, kTISPropertyInputSourceIsSelectCapable)
        )
    }

    static func stringProperty(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func boolProperty(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue())
    }

    /// Runs a TIS call on the main thread, synchronously, from whichever thread calls it.
    static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
