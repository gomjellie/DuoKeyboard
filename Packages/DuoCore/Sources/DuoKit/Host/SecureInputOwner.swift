import AppKit
import IOKit

/// The app that turned on Secure Keyboard Entry. macOS turns Duo off while any app holds it.
public enum SecureInputOwner {
    /// The localized name of the app holding Secure Keyboard Entry, or `nil` when no app holds it
    /// or the holder has no app name.
    public static func appName() -> String? {
        guard let pid = pid(inConsoleUsers: consoleUsers(), uid: getuid()) else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    /// The holder's pid in the login session of `uid`.
    ///
    /// WindowServer writes `kCGSSessionSecureInputPID` into the session dictionaries of the registry
    /// root's `IOConsoleUsers`. The key is not public API, so a missing or odd value means "unknown".
    static func pid(inConsoleUsers sessions: [[String: Any]], uid: uid_t) -> pid_t? {
        for session in sessions {
            guard (session["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid,
                  let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
                  pid > 0 else { continue }
            return pid
        }
        return nil
    }

    private static func consoleUsers() -> [[String: Any]] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != MACH_PORT_NULL else { return [] }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? [[String: Any]] ?? []
    }
}
