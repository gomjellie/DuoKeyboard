#if DEBUG
import AppKit
import DuoKit
import InputMethodKit

/// DEBUG-ONLY end-to-end test hook. Never compiled into Release builds.
///
/// macOS does not route in-process synthesized NSEvents through input methods, and posting HID
/// events needs Accessibility permission. To still exercise the *real* IMK client path
/// (setMarkedText / insertText travelling to the client app), the harness posts a distributed
/// notification with a key script; the input method converts it to NSEvents and feeds them to the
/// active controller's `handle(_:client:)` exactly as IMK would: keyDowns, flagsChanged with the
/// device-dependent bits real hardware sets (critique V3), and mouse-downs (`{click}`, R4).
///
/// Confinement: a distributed notification needs no permission to post, so the hook would otherwise
/// let any local process type into whatever app is focused. Keys are injected only while DuoHarness
/// (``DuoIDs/harnessBundleID``) is the frontmost app *and* the focused client is its own text view;
/// both are checked again before every key, so a script stops when the harness loses focus.
///
/// Protocol (all distributed notifications, delivered immediately):
/// 1. harness → IME `debug.inject` `{keys, token}`;
/// 2. for each key the IME declines, IME → harness `debug.passthrough` `{key, token}` and waits for
///    `debug.passthrough.ack`, so the harness applies it in order with the preceding IMK messages;
/// 3. IME → harness `debug.injected` `{token, handled}` when the script is done.
@MainActor
enum DebugInjector {
    static let injectName = Notification.Name("com.inkyuoh.Duo.debug.inject")
    static let doneName = Notification.Name("com.inkyuoh.Duo.debug.injected")
    static let passName = Notification.Name("com.inkyuoh.Duo.debug.passthrough")
    static let passAckName = Notification.Name("com.inkyuoh.Duo.debug.passthrough.ack")

    private static var observer: (any NSObjectProtocol)?
    private static var passObserver: (any NSObjectProtocol)?
    private static var passWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private static var passCounter = 0
    /// Caps Lock is a toggle: one flagsChanged per press, alternating on and off.
    private static var capsLockOn = false

    static func install() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: injectName, object: nil, queue: .main) { note in
            let keys = note.userInfo?["keys"] as? String ?? ""
            let token = note.userInfo?["token"] as? String ?? ""
            MainActor.assumeIsolated { _ = Task { await run(keys: keys, token: token) } }
        }
        Log.ime.info("debug injector installed")
    }

    static func run(keys: String, token: String) async {
        var handled = 0
        if let controller = harnessController(), let client = controller.client() {
            for key in KeyScript.parse(keys) {
                guard harnessController() === controller else {
                    Log.ime.error("debug inject stopped: DuoHarness is no longer the focused client")
                    break
                }
                switch key.kind {
                case .wait:
                    try? await Task.sleep(for: .milliseconds(key.milliseconds))
                case .click:
                    if let event = mouseDownEvent() {
                        _ = controller.handle(event, client: client)
                        handled += 1
                    }
                case .modifierTap, .modifierPress, .modifierRelease:
                    for event in flagsEvents(for: key) {
                        _ = controller.handle(event, client: client)
                    }
                    handled += 1
                case .key:
                    let key = applyingCapsLock(key)
                    if let event = keyDownEvent(key) {
                        if !controller.handle(event, client: client) { await passThrough(key, client: client) }
                        handled += 1
                    }
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        } else {
            Log.ime.error("debug inject refused: the focused client is not DuoHarness")
        }
        DistributedNotificationCenter.default().postNotificationName(
            doneName, object: nil, userInfo: ["token": token, "handled": handled], deliverImmediately: true)
    }

    /// The focused controller, if it belongs to DuoHarness and DuoHarness is the frontmost app.
    private static func harnessController() -> DuoInputController? {
        guard let controller = DuoRuntime.shared.activeController,
              controller.bundleIdentifier == DuoIDs.harnessBundleID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == DuoIDs.harnessBundleID else { return nil }
        return controller
    }

    /// When the input method declines a key, the client app processes it itself. Hand the key back to
    /// the harness (which runs it through its own text view's key bindings) and wait, so ordering with
    /// preceding IMK messages is preserved.
    static func passThrough(_ key: SyntheticKey, client: any IMKTextInput) async {
        if passObserver == nil {
            passObserver = DistributedNotificationCenter.default().addObserver(forName: passAckName, object: nil, queue: .main) { note in
                let t = note.userInfo?["token"] as? String ?? ""
                MainActor.assumeIsolated { passWaiters.removeValue(forKey: t)?.resume() }
            }
        }
        _ = client.selectedRange() // synchronous round-trip: flushes earlier IMK messages first
        passCounter += 1
        let token = "p\(passCounter)"
        let payload = (try? JSONEncoder().encode(key)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            passWaiters[token] = cont
            DistributedNotificationCenter.default().postNotificationName(
                passName, object: nil, userInfo: ["key": payload, "token": token], deliverImmediately: true)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                passWaiters.removeValue(forKey: token)?.resume()
            }
        }
    }

    /// While Caps Lock is on, a real keyDown carries `.capsLock` and the ABC layout types letters in
    /// uppercase (with or without Shift). The same key goes to the harness if it is passed through.
    static func applyingCapsLock(_ key: SyntheticKey) -> SyntheticKey {
        guard capsLockOn else { return key }
        var key = key
        key.modifiers |= KeyScript.capsLockFlag
        if key.modifiers & (KeyScript.commandFlag | KeyScript.controlFlag) == 0,
           key.characters.count == 1, key.characters.first?.isLetter == true {
            key.characters = key.characters.uppercased()
        }
        return key
    }

    static func keyDownEvent(_ key: SyntheticKey) -> NSEvent? {
        let flags = key.modifiers | KeyScript.leftDeviceBits(forModifiers: key.modifiers) | KeyScript.nonCoalescedFlag
        return NSEvent.keyEvent(with: .keyDown, location: .zero,
                                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                isARepeat: false, keyCode: key.keyCode)
    }

    /// The flagsChanged events a physical modifier key produces. A tap is press (device-independent
    /// flag + device bit, critique V3: right ⌘ is `0x100010`) then release; `{press:…}` and
    /// `{release:…}` are one each (`KeyScript.flagsMasks`); Caps Lock is a single event that toggles
    /// the lock.
    static func flagsEvents(for key: SyntheticKey) -> [NSEvent] {
        let masks: [UInt]
        if key.keyCode == KeyScript.VK.capsLock {
            capsLockOn.toggle()
            masks = [capsLockOn ? KeyScript.capsLockFlag : 0]
        } else {
            masks = KeyScript.flagsMasks(for: key)
        }
        return masks.compactMap { flagsEvent(code: key.keyCode, flags: $0 | KeyScript.nonCoalescedFlag) }
    }

    static func flagsEvent(code: UInt16, flags: UInt) -> NSEvent? {
        guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: flags & ~KeyScript.nonCoalescedFlag != 0) else {
            return nil
        }
        cg.type = .flagsChanged
        cg.flags = CGEventFlags(rawValue: UInt64(flags))
        return NSEvent(cgEvent: cg)
    }

    /// A left mouse-down in the client, so the R4 commit-on-click path is testable.
    static func mouseDownEvent() -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }
}
#endif
