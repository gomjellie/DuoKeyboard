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
    static let xtermFieldClass = "xterm-helper-textarea"
    /// Seconds a client may take to answer one attribute before the HUD falls back to IMK.
    static let messagingTimeout: Float = 0.05

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

    /// The frame of the focused element of the app `pid`, top-left origin, when it is xterm.js's
    /// input field.
    static func xtermFieldFrame(pid: pid_t) -> CGRect? {
        guard isTrusted else { return nil }
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

    /// Asks macOS to show its Accessibility prompt for the input method (`requestAccessibility`).
    static func requestPermission() {
        trust = nil
        // The value of kAXTrustedCheckOptionPrompt, spelled out: the imported global is not
        // concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
