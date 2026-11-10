import Foundation

/// Whether the app got a key-down or a click that the input method never saw, from the window
/// server's session-wide event counters (no permission needed, as for
/// ``ModifierRouting/ActivityCounter``).
///
/// With "Enter로 바로 보내기" nothing is marked, so an app may handle a Return itself without
/// calling the input method (send the message, clear the field), and a click on its Send button
/// does the same. The word the engine is typing may then be gone (SPEC.md 4.9절).
public struct UnseenInputCounter: Sendable {
    /// A key counted later than the event it is compared with by less than this is the event itself
    /// (the two uptimes come through different conversions).
    static let sameEventTolerance: TimeInterval = 0.001

    private var count: UInt32

    /// - Parameter count: the counters' sum now (key-downs plus mouse-downs).
    public init(count: UInt32) {
        self.count = count
    }

    /// Call once per event the input method handles, before the engine sees it.
    ///
    /// The window server counts an event before the input method gets it, and a key typed right
    /// after it may already be counted: such a key belongs to the next event, so it is carried over.
    ///
    /// - Parameters:
    ///   - own: how many counted events this one is: 1 for a key-down or click, 0 for a modifier
    ///     change. Events the counters never saw (the DEBUG injector's) count as nothing.
    ///   - now: the counters' sum now (wraps around).
    ///   - eventTimestamp: the event's timestamp (system uptime).
    ///   - lastInputUptime: the system uptime of the most recent key-down or click; read only when
    ///     the counters moved past `own`.
    public mutating func unseenBefore(own: UInt32, count now: UInt32, eventTimestamp: TimeInterval,
                                      lastInputUptime: () -> TimeInterval) -> Bool {
        let delta = now &- count
        guard delta > own else {
            count = now
            return false
        }
        let carried: UInt32 = lastInputUptime() > eventTimestamp + Self.sameEventTolerance ? 1 : 0
        count = now &- carried
        return delta > own &+ carried
    }
}
