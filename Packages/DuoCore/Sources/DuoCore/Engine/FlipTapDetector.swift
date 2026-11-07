import Foundation

/// Detects a tap of the flip key from `flagsChanged` events (docs/SPEC.md §4.9, critique R3).
///
/// A pure state machine: feed it every `ModifierEvent`, call ``noteKeyDown()`` for every key-down
/// and ``noteMouseDown()`` for every click, and it reports when the configured key was tapped. It
/// never consumes anything; the caller always lets the event through.
///
/// - Right ⌘ / right ⌥: arms when key code 54 (61) sets `.command` (`.option`) from clear with no
///   other held modifier and without the left-side device bit, and fires when the same key clears
///   the flag within the tap window. Any key-down, other modifier change, mouse button or timeout
///   disarms it.
/// - Double ⇧: two ⇧ taps, the second pressed within the window after the first was released.
/// - Caps Lock: every key-code-57 `flagsChanged` fires.
/// - ⇧Space is a key-down, handled by the engine; the detector never fires for it.
///
/// Events with key code 0 are ignored entirely (remote-desktop tools send them, per Squirrel).
public struct FlipTapDetector: Sendable, Hashable {
    /// The key being watched.
    public var flipKey: FlipKey {
        didSet { reset() }
    }
    /// Maximum press-to-release time of one tap, and gap between the two ⇧ taps, in seconds.
    public var tapWindow: TimeInterval

    private var previousFlags: UInt = 0
    private var armedAt: TimeInterval?
    private var shiftPressedAt: TimeInterval?
    private var firstShiftTapReleasedAt: TimeInterval?

    /// - Parameters:
    ///   - flipKey: the configured flip key.
    ///   - tapWindowMs: `DuoSettings.flipTapWindowMs` (200…500).
    public init(flipKey: FlipKey, tapWindowMs: Int = 300) {
        self.flipKey = flipKey
        self.tapWindow = TimeInterval(tapWindowMs) / 1000
    }

    /// `NSEvent.ModifierFlags` raw values (DuoCore has no AppKit).
    public enum Flags {
        public static let capsLock: UInt = 1 << 16
        public static let shift: UInt = 1 << 17
        public static let control: UInt = 1 << 18
        public static let option: UInt = 1 << 19
        public static let command: UInt = 1 << 20
        public static let numericPad: UInt = 1 << 21
        public static let help: UInt = 1 << 22
        public static let function: UInt = 1 << 23
        /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask`.
        public static let deviceIndependentMask: UInt = 0xFFFF_0000
        /// Modifiers that count as "held" (Caps Lock is a lock state, numeric pad a key property).
        public static let held: UInt = shift | control | option | command | function
        /// Device-dependent bits from `IOLLEvent.h` (critique V3).
        public static let leftCommandDevice: UInt = 0x08
        public static let rightCommandDevice: UInt = 0x10
        public static let leftOptionDevice: UInt = 0x20
        public static let rightOptionDevice: UInt = 0x40
    }

    /// Hardware key codes of the modifier keys (Carbon `kVK_*`).
    public enum KeyCode {
        public static let rightCommand: UInt16 = 54
        public static let leftCommand: UInt16 = 55
        public static let leftShift: UInt16 = 56
        public static let capsLock: UInt16 = 57
        public static let leftOption: UInt16 = 58
        public static let rightShift: UInt16 = 60
        public static let rightOption: UInt16 = 61
        public static let function: UInt16 = 63
    }

    /// Feeds one `flagsChanged`. Returns `true` when this event completes a flip-key tap.
    public mutating func handle(_ event: ModifierEvent) -> Bool {
        guard event.keyCode != 0 else { return false }
        let flags = event.flags & Flags.deviceIndependentMask
        defer { previousFlags = flags }
        guard event.pressedMouseButtons == 0 else {
            disarm()
            return false
        }
        switch flipKey {
        case .rightCommand:
            return modifierTap(event, flags: flags, keyCode: KeyCode.rightCommand, flag: Flags.command,
                               otherSide: Flags.leftCommandDevice)
        case .rightOption:
            return modifierTap(event, flags: flags, keyCode: KeyCode.rightOption, flag: Flags.option,
                               otherSide: Flags.leftOptionDevice)
        case .doubleShift:
            return doubleShift(event, flags: flags)
        case .capsLock:
            return event.keyCode == KeyCode.capsLock
        case .shiftSpace:
            return false
        }
    }

    /// Any key-down disarms a pending tap (⌘C is not a tap).
    public mutating func noteKeyDown() { disarm() }

    /// A click disarms a pending tap (⌘-click is not a tap).
    public mutating func noteMouseDown() { disarm() }

    /// Forget everything, including the last seen modifier state.
    public mutating func reset() {
        disarm()
        previousFlags = 0
    }

    /// Whether a press is armed and waiting for its release (for tests and diagnostics).
    public var isArmed: Bool { armedAt != nil || shiftPressedAt != nil || firstShiftTapReleasedAt != nil }

    private mutating func disarm() {
        armedAt = nil
        shiftPressedAt = nil
        firstShiftTapReleasedAt = nil
    }

    private func withinWindow(_ elapsed: TimeInterval) -> Bool {
        // A microsecond of slack absorbs binary floating-point noise in event timestamps.
        elapsed >= 0 && elapsed <= tapWindow + 1e-6
    }

    private mutating func modifierTap(_ event: ModifierEvent, flags: UInt, keyCode: UInt16, flag: UInt,
                                      otherSide: UInt) -> Bool {
        let wasSet = previousFlags & flag != 0
        let isSet = flags & flag != 0
        if event.keyCode == keyCode, !wasSet, isSet {
            let othersHeld = flags & Flags.held & ~flag != 0
            armedAt = othersHeld || event.flags & otherSide != 0 ? nil : event.timestamp
            return false
        }
        if event.keyCode == keyCode, wasSet, !isSet {
            defer { armedAt = nil }
            guard let start = armedAt, event.flags & otherSide == 0, flags & Flags.held == 0 else { return false }
            return withinWindow(event.timestamp - start)
        }
        // Any other modifier change (left ⌘ joining, ⇧ pressed during the hold, …).
        armedAt = nil
        return false
    }

    private mutating func doubleShift(_ event: ModifierEvent, flags: UInt) -> Bool {
        let isShiftKey = event.keyCode == KeyCode.leftShift || event.keyCode == KeyCode.rightShift
        let wasSet = previousFlags & Flags.shift != 0
        let isSet = flags & Flags.shift != 0
        if isShiftKey, !wasSet, isSet, flags & Flags.held & ~Flags.shift == 0 {
            if let first = firstShiftTapReleasedAt, !withinWindow(event.timestamp - first) {
                firstShiftTapReleasedAt = nil
            }
            shiftPressedAt = event.timestamp
            return false
        }
        if isShiftKey, wasSet, !isSet, let pressed = shiftPressedAt {
            shiftPressedAt = nil
            guard withinWindow(event.timestamp - pressed) else {
                firstShiftTapReleasedAt = nil
                return false
            }
            if let first = firstShiftTapReleasedAt, withinWindow(pressed - first) {
                firstShiftTapReleasedAt = nil
                return true
            }
            firstShiftTapReleasedAt = event.timestamp
            return false
        }
        disarm()
        return false
    }
}
