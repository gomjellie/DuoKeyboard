import AppKit
import ApplicationServices

/// Where an xterm.js terminal draws the composition: the frame of the hidden text field xterm.js
/// keeps there, read as the client's focused accessibility element
/// (`ClientProfile.compositionAtFocusedElement`). The rects IMK gets from such a client come from
/// that field's own text layout and land up to 100 pt off.
///
/// Needs the Accessibility permission for the input method. Without it, or when the client is
/// slow or its focus is not xterm.js's field, every answer is `nil` and the HUD uses IMK's rects.
/// Only the field's class list, position and size are read, never its text.
@MainActor
enum FocusedElementLocator {
    /// DOM class of xterm.js's hidden input field (Chromium reports it as `AXDOMClassList`).
    nonisolated static let xtermFieldClass = "xterm-helper-textarea"
    /// Seconds the client may take to answer one attribute.
    nonisolated static let messagingTimeout: Float = 0.25

    /// Reads run here, never on the main thread: the client answers accessibility requests on its
    /// main thread, which waits for the input method while IMK delivers a key, so a read made
    /// inside an IMK callback stalls until the timeout and fails.
    private static let queue = DispatchQueue(label: "com.inkyuoh.Duo.focused-element", qos: .userInteractive)

    private static var trust: (value: Bool, checkedAt: TimeInterval)?

    /// `AXIsProcessTrusted()`, re-read at most every two seconds: a grant in System Settings takes
    /// effect without a restart.
    static var isTrusted: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let trust, now - trust.checkedAt < 2 { return trust.value }
        let value = AXIsProcessTrusted()
        trust = (value, now)
        return value
    }

    /// Reads the frame of xterm.js's input field in the app `pid` (top-left origin) off the main
    /// thread and calls `completion` on the main thread: `nil` without the permission, when the
    /// focused element is not that field, or when the client does not answer in time.
    static func readXtermFieldFrame(pid: pid_t, completion: @escaping @MainActor @Sendable (CGRect?) -> Void) {
        guard isTrusted else { return completion(nil) }
        queue.async {
            let frame = xtermFieldFrame(pid: pid)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(frame) } }
        }
    }

    /// Asks macOS to show its Accessibility prompt for the input method (`requestAccessibility`).
    static func requestPermission() {
        trust = nil
        // The value of kAXTrustedCheckOptionPrompt, spelled out: the imported global is not
        // concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    nonisolated private static func xtermFieldFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let focused = value(of: app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let field = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(field, messagingTimeout)
        guard let classes = value(of: field, "AXDOMClassList") as? [String], classes.contains(xtermFieldClass),
              let position = value(of: field, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(of: field, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    nonisolated private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
