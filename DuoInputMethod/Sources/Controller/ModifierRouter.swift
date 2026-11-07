import AppKit
import Carbon
import DuoCore
import DuoKit

/// Delivers every `flagsChanged` to the focused engine exactly once.
///
/// - **Duplicates.** Chromium (Chrome and every Electron app) hands each modifier change to the
///   input method twice, about 2 ms apart. A physical modifier key always alternates state, so a
///   change identical to the previous one (same key, same device-independent flags) is a copy.
/// - **Clients that never forward modifiers** (some non-Cocoa toolkits). A global `.flagsChanged`
///   monitor, which needs no permission, covers a session until IMK delivers its first modifier
///   event; from then on only IMK's copy is used, because its client calls run inside the app's
///   event dispatch where IMK's cached ranges are current.
/// - **Chords the input method never sees.** Cocoa apps route ⌘-shortcuts to the menu without
///   calling the input method, so "right ⌘ + C" would look like a tap. The window server's event
///   counters (no permission needed) tell whether a key or click happened between two modifier
///   events.
///
/// The rules themselves are DuoKit's ``ModifierRouting`` (unit-tested); this type feeds them.
@MainActor
final class ModifierRouter {
    private var monitor: Any?
    private var copies = ModifierRouting.CopyFilter()
    private var activity = ModifierRouting.ActivityCounter(count: 0)

    func start() {
        activity = ModifierRouting.ActivityCounter(count: Self.currentInputCount())
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { DuoRuntime.shared.modifierRouter.receiveFromMonitor(event) }
        }
        if monitor == nil {
            Log.runtime.error("global modifier monitor unavailable; clients that do not forward modifiers get no flip key")
        }
    }

    /// A `flagsChanged` from IMK `handle(_:client:)`: the session forwards modifiers from now on.
    func noteForwarded(by controller: DuoInputController) {
        controller.forwardsModifierEvents = true
    }

    /// Whether `event` is a new modifier change (not a copy of the previous one). Call once per
    /// event that is about to reach the engine; records it.
    func isNewChange(_ event: NSEvent) -> Bool {
        copies.isNewChange(keyCode: event.keyCode, flags: event.modifierFlags.rawValue,
                           at: ProcessInfo.processInfo.systemUptime)
    }

    /// Whether any key-down or click happened since the previous modifier change that reached the
    /// engine. Call once per new change.
    func otherInputBefore(_ event: NSEvent) -> Bool {
        activity.otherInputBefore(count: Self.currentInputCount(), eventTimestamp: event.timestamp,
                                  lastInputUptime: Self.lastInputUptime)
    }

    private func receiveFromMonitor(_ event: NSEvent) {
        guard let controller = DuoRuntime.shared.activeController, !controller.forwardsModifierEvents,
              controller.bundleIdentifier == NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              DuoRuntime.isDuoSelected() else { return }
        controller.handleMonitoredModifier(event)
    }

    private static let inputTypes: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    private static func currentInputCount() -> UInt32 {
        inputTypes.reduce(0) { $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1) }
    }

    /// System uptime of the most recent key-down or click.
    private static func lastInputUptime() -> TimeInterval {
        let since = inputTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? .infinity
        return ProcessInfo.processInfo.systemUptime - since
    }
}
