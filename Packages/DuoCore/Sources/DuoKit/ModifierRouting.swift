import DuoCore
import Foundation

/// The pure rules behind the input method's `ModifierRouter` (DuoInputMethod), kept here so they are
/// unit-tested: which `flagsChanged` events are copies, and whether the user typed or clicked between
/// two modifier changes without the engine seeing it.
public enum ModifierRouting {
    /// Drops copies of a modifier change.
    ///
    /// Chromium (Chrome and every Electron app) hands each modifier change to the input method
    /// twice, about 2 ms apart (live QA); the IMK copy has no device bits and a later timestamp than
    /// the global monitor's. A physical modifier key always alternates state, so a change identical
    /// to the previous one (same key, same device-independent flags) within ``copyWindow`` is a copy.
    public struct CopyFilter: Sendable {
        /// How far apart two identical changes are still one change.
        public static let copyWindow: TimeInterval = 0.2

        private var last: (keyCode: UInt16, flags: UInt, uptime: TimeInterval)?

        public init() {}

        /// Whether this change is new (not a copy of the previous one); records it. Call once per
        /// event that is about to reach the engine.
        ///
        /// - Parameters:
        ///   - flags: the event's raw modifier flags (device bits are ignored).
        ///   - uptime: when the event was received (`ProcessInfo.systemUptime`): the copies' own
        ///     timestamps differ.
        public mutating func isNewChange(keyCode: UInt16, flags: UInt, at uptime: TimeInterval) -> Bool {
            let flags = flags & FlipTapDetector.Flags.deviceIndependentMask
            if let last, last.keyCode == keyCode, last.flags == flags, uptime - last.uptime < Self.copyWindow {
                return false
            }
            last = (keyCode, flags, uptime)
            return true
        }
    }

    /// Whether any key-down or click happened since the previous modifier change, from the window
    /// server's session-wide event counters (no permission needed). Cocoa apps route ⌘-shortcuts to
    /// the menu without calling the input method, so "right ⌘ + C" would otherwise look like a tap.
    public struct ActivityCounter: Sendable {
        private var count: UInt32

        /// - Parameter count: the counters' sum now (key-downs plus mouse-downs).
        public init(count: UInt32) {
            self.count = count
        }

        /// Call once per new modifier change.
        ///
        /// The event reaches the input method a little after the hardware: a key that went down
        /// after it (typed right after a tap's release, or the C of a quick ⌘C right after the
        /// press) may already be counted. It belongs to the next change, so it is carried over
        /// instead of spent here.
        ///
        /// - Parameters:
        ///   - now: the counters' sum now (wraps around).
        ///   - eventTimestamp: the modifier event's timestamp (system uptime).
        ///   - lastInputUptime: the system uptime of the most recent key-down or click; read only
        ///     when the counters moved.
        public mutating func otherInputBefore(count now: UInt32, eventTimestamp: TimeInterval,
                                              lastInputUptime: () -> TimeInterval) -> Bool {
            let delta = now &- count
            guard delta > 0 else {
                count = now
                return false
            }
            let carried: UInt32 = lastInputUptime() > eventTimestamp ? 1 : 0
            count = now &- carried
            return delta > carried
        }
    }
}
