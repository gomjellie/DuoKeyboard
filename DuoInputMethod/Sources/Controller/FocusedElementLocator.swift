import AppKit
import ApplicationServices

/// Where an xterm.js terminal draws the composition: the frame of the hidden text field xterm.js
/// keeps there, read as the client's focused accessibility element
/// (`ClientProfile.compositionAtFocusedElement`). The rects IMK gets from such a client come from
/// that field's own text layout and land up to 100 pt off.
///
/// Needs the Accessibility permission for the input method. Only the field's class list, position
/// and size are read, never its text.
@MainActor
enum FocusedElementLocator {
    /// What one read found.
    enum Answer: Sendable, Equatable {
        /// The focused element is xterm.js's input field; its frame, top-left origin.
        case frame(CGRect)
        /// The focus is elsewhere (another text field of the app), or the permission is missing:
        /// IMK's rects are the ones to use.
        case notXtermField
        /// The client did not answer in time: what was read before still holds.
        case noAnswer
    }

    /// DOM class of xterm.js's hidden input field (Chromium reports it as `AXDOMClassList`).
    nonisolated static let xtermFieldClass = "xterm-helper-textarea"
    /// Seconds the client may take to answer one attribute.
    nonisolated static let messagingTimeout: Float = 0.25

    /// Reads run here, never on the main thread: the client answers accessibility requests on its
    /// main thread, which waits for the input method while IMK delivers a key, so a read made
    /// inside an IMK callback stalls until the timeout and fails.
    private static let queue = DispatchQueue(label: "com.inkyuoh.Duo.focused-element", qos: .userInteractive)
    /// Apps asked to build their web accessibility tree (`AXManualAccessibility`). Only touched on `queue`.
    nonisolated(unsafe) private static var manualAccessibilityPIDs = Set<pid_t>()

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

    /// Reads the focused element of the app `pid` off the main thread and calls `completion` on
    /// the main thread, always later than this call returns.
    static func read(pid: pid_t, completion: @escaping @MainActor @Sendable (Answer) -> Void) {
        guard isTrusted else {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(.notXtermField) } }
            return
        }
        queue.async {
            let answer = answer(pid: pid)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(answer) } }
        }
    }

    /// Asks macOS to show its Accessibility prompt for the input method (`requestAccessibility`).
    static func requestPermission() {
        trust = nil
        // The value of kAXTrustedCheckOptionPrompt, spelled out: the imported global is not
        // concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    nonisolated private static func answer(pid: pid_t) -> Answer {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        if !manualAccessibilityPIDs.contains(pid) {
            // Electron builds its web accessibility tree only for assistive apps that ask; without
            // it the focused element is the web view, not xterm.js's field. Apps that are not
            // Electron reject the attribute, which changes nothing.
            manualAccessibilityPIDs.insert(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        if result == .noValue { return .notXtermField }
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .noAnswer }
        let field = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(field, messagingTimeout)
        var classes: CFTypeRef?
        switch AXUIElementCopyAttributeValue(field, "AXDOMClassList" as CFString, &classes) {
        case .success:
            guard let names = classes as? [String], names.contains(xtermFieldClass) else { return .notXtermField }
        case .attributeUnsupported, .noValue:
            return .notXtermField
        default:
            return .noAnswer
        }
        guard let position = value(of: field, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(of: field, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return .noAnswer }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return .noAnswer }
        return .frame(CGRect(origin: origin, size: extent))
    }

    nonisolated private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
