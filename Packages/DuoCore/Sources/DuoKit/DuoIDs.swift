// CONTRACT FILE: owned by the lead (critique R6). One table of identifiers for every target.

import Foundation

public enum DuoIDs {
    /// Input method bundle (`DuoInputMethod.app`). Never use it as a defaults suite name (critique V4).
    public static let inputMethodBundleID = "com.inkyuoh.inputmethod.Duo"
    /// Host app (`Duo.app`).
    public static let hostAppBundleID = "com.inkyuoh.Duo"
    public static let harnessBundleID = "com.inkyuoh.Duo.Harness"
    /// Shared preferences domain for settings (both apps read/write `~/Library/Preferences/<suite>.plist`).
    public static let sharedSuite = "com.inkyuoh.Duo.shared"
    /// Log subsystem for every target.
    public static let logSubsystem = "com.inkyuoh.inputmethod.Duo"

    public enum Notifications {
        /// Settings blob changed (no payload). The IME re-reads on this and on `activateServer`.
        public static let settingsChanged = Notification.Name("com.inkyuoh.Duo.settingsChanged")
        /// Host → IME: `userInfo = ["op": "remove"|"removeAll", "raw": String, "ctx": String?]`.
        public static let learningCommand = Notification.Name("com.inkyuoh.Duo.learning.command")
        /// IME → host: the learning file was rewritten (no payload).
        public static let learningChanged = Notification.Name("com.inkyuoh.Duo.learning.changed")
        /// IME → host: the user flipped a word (no text payload). `userInfo = ["to": "korean"|"english"]`.
        public static let flipped = Notification.Name("com.inkyuoh.Duo.event.flipped")
        /// Host → IME: open nothing, just report liveness via `pong` (used by Settings ▸ status).
        public static let ping = Notification.Name("com.inkyuoh.Duo.ping")
        /// IME → host. `userInfo`: `"version"`, `"modelLoaded"` (`"true"`/`"false"`) and
        /// ``DuoIDs/pongAccessibilityKey``.
        public static let pong = Notification.Name("com.inkyuoh.Duo.pong")
        /// Host → IME: ask macOS for the Accessibility permission of the input method (no payload).
        /// The prompt must come from the IME process: the permission belongs to its binary.
        public static let requestAccessibility = Notification.Name("com.inkyuoh.Duo.accessibility.request")
    }

    /// `pong` key: `"true"` when the IME may read the client's focused element (Accessibility),
    /// which places the HUD in xterm.js terminals (`ClientProfile.compositionAtFocusedElement`).
    public static let pongAccessibilityKey = "accessibilityTrusted"

    /// Bundle ids the IME has seen as clients (for Settings ▸ Apps). `[String]`, most recent first, ≤ 200.
    public static let seenAppsDefaultsKey = "seenApps.v1"
    /// The JSON-encoded `DuoSettings` blob.
    public static let settingsDefaultsKey = "settings.v1"

    /// `~/Library/Application Support/Duo/` (created on demand).
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Duo", directoryHint: .isDirectory)
    }

    /// The learning store; the IME is the only writer while it runs (critique R14).
    public static var learningFileURL: URL { supportDirectory.appending(path: "learning.json") }
}
