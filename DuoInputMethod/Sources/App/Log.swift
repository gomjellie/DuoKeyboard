import DuoKit
import os

/// Loggers for the input method process (subsystem `DuoIDs.logSubsystem`).
///
/// Privacy rule: typed text, key codes and committed words are user content. They are logged only
/// at `.debug` (never persisted) and always with `privacy: .private`. Lifecycle, bundle identifiers
/// and errors are fine at `.info` and above.
///
/// Watch with: `log stream --level debug --predicate 'subsystem == "com.inkyuoh.inputmethod.Duo"'`.
enum Log {
    /// Process lifecycle, model loading, persistence.
    static let runtime = Logger(subsystem: DuoIDs.logSubsystem, category: "runtime")
    /// Controller lifecycle and event routing.
    static let ime = Logger(subsystem: DuoIDs.logSubsystem, category: "ime")
    /// The composition HUD.
    static let hud = Logger(subsystem: DuoIDs.logSubsystem, category: "hud")
    /// The input menu and its actions.
    static let menu = Logger(subsystem: DuoIDs.logSubsystem, category: "menu")
}
