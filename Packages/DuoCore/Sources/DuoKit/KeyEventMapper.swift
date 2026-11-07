import AppKit
import DuoCore

/// NSEvent → engine input. Letters come from the ANSI key position, never from `characters`
/// (critique R16), so the IME and the host playground produce identical raw strings.
///
/// Digits and punctuation are the ABC layout's characters for the key and Shift state; Caps Lock
/// is reported as a modifier and never folded into letters. ⌥e ⌥` ⌥u ⌥i ⌥n are flagged as dead
/// keys (ABC layout), so the engine lets the next key through raw.
public enum KeyEventMapper {
    /// `nil` for events that are not key-downs.
    public static func keyEvent(from event: NSEvent) -> KeyEvent? {
        guard event.type == .keyDown else { return nil }
        let modifiers = modifiers(from: event.modifierFlags)
        let key = key(forKeyCode: event.keyCode, shift: modifiers.contains(.shift))
        return KeyEvent(key, modifiers: modifiers, isRepeat: event.isARepeat,
                        isDeadKey: isDeadKey(keyCode: event.keyCode, modifiers: modifiers),
                        timestamp: event.timestamp)
    }

    /// `nil` for events that are not flagsChanged.
    public static func modifierEvent(from event: NSEvent) -> ModifierEvent? {
        modifierEvent(from: event, pressedMouseButtons: NSEvent.pressedMouseButtons)
    }

    /// `modifierEvent(from:)` with the mouse-button state supplied by the caller (tests, replay).
    public static func modifierEvent(from event: NSEvent, pressedMouseButtons: Int) -> ModifierEvent? {
        guard event.type == .flagsChanged else { return nil }
        return ModifierEvent(keyCode: event.keyCode, flags: event.modifierFlags.rawValue, timestamp: event.timestamp,
                             pressedMouseButtons: pressedMouseButtons)
    }

    /// The engine's modifier set for AppKit flags (device-dependent bits are dropped).
    public static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyEvent.Modifiers {
        var m: KeyEvent.Modifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.capsLock) { m.insert(.capsLock) }
        if flags.contains(.function) { m.insert(.function) }
        return m
    }

    /// The key for a hardware key code on the ABC layout.
    public static func key(forKeyCode code: UInt16, shift: Bool) -> KeyEvent.Key {
        if let base = letters[code] { return .letter(Keystroke(base: base, shift: shift)) }
        if let pair = characters[code] { return .character(shift ? pair.shifted : pair.base) }
        if let c = keypad[code] { return .keypad(c) }
        switch code {
        case VK.space: return .space
        case VK.returnKey, VK.keypadEnter: return .returnKey
        case VK.tab: return .tab
        case VK.escape: return .escape
        case VK.delete: return .backspace
        case VK.forwardDelete: return .forwardDelete
        case VK.left: return .arrowLeft
        case VK.right: return .arrowRight
        case VK.up: return .arrowUp
        case VK.down: return .arrowDown
        case VK.home, VK.end, VK.pageUp, VK.pageDown, VK.help: return .navigation
        default: return functionKeys.contains(code) ? .function : .other
        }
    }

    /// ⌥ (without ⇧, ⌘ or ⌃) on e, `, u, i or n: a dead key on the ABC layout.
    public static func isDeadKey(keyCode: UInt16, modifiers: KeyEvent.Modifiers) -> Bool {
        modifiers.contains(.option) && modifiers.isDisjoint(with: [.shift, .command, .control])
            && deadKeyCodes.contains(keyCode)
    }

    // MARK: Tables (Carbon kVK_* values, HIToolbox/Events.h)

    /// Virtual key codes of the non-character keys.
    public enum VK {
        public static let returnKey: UInt16 = 0x24
        public static let tab: UInt16 = 0x30
        public static let space: UInt16 = 0x31
        public static let delete: UInt16 = 0x33
        public static let escape: UInt16 = 0x35
        public static let help: UInt16 = 0x72
        public static let home: UInt16 = 0x73
        public static let pageUp: UInt16 = 0x74
        public static let forwardDelete: UInt16 = 0x75
        public static let end: UInt16 = 0x77
        public static let pageDown: UInt16 = 0x79
        public static let left: UInt16 = 0x7B
        public static let right: UInt16 = 0x7C
        public static let down: UInt16 = 0x7D
        public static let up: UInt16 = 0x7E
        public static let keypadEnter: UInt16 = 0x4C
    }

    /// `kVK_ANSI_A` … `kVK_ANSI_Z` → base letter.
    static let letters: [UInt16: Character] = [
        0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x04: "h", 0x05: "g", 0x06: "z", 0x07: "x",
        0x08: "c", 0x09: "v", 0x0B: "b", 0x0C: "q", 0x0D: "w", 0x0E: "e", 0x0F: "r", 0x10: "y",
        0x11: "t", 0x1F: "o", 0x20: "u", 0x22: "i", 0x23: "p", 0x25: "l", 0x26: "j", 0x28: "k",
        0x2D: "n", 0x2E: "m",
    ]

    /// Digit and punctuation keys → ABC characters (unshifted, shifted).
    static let characters: [UInt16: (base: Character, shifted: Character)] = [
        0x12: ("1", "!"), 0x13: ("2", "@"), 0x14: ("3", "#"), 0x15: ("4", "$"), 0x17: ("5", "%"),
        0x16: ("6", "^"), 0x1A: ("7", "&"), 0x1C: ("8", "*"), 0x19: ("9", "("), 0x1D: ("0", ")"),
        0x1B: ("-", "_"), 0x18: ("=", "+"), 0x21: ("[", "{"), 0x1E: ("]", "}"), 0x2A: ("\\", "|"),
        0x29: (";", ":"), 0x27: ("'", "\""), 0x2B: (",", "<"), 0x2F: (".", ">"), 0x2C: ("/", "?"),
        0x32: ("`", "~"),
        0x0A: ("§", "±"),  // kVK_ISO_Section
    ]

    /// Numeric keypad digits and operators (`kVK_ANSI_Keypad*`, `kVK_JIS_KeypadComma`).
    static let keypad: [UInt16: Character] = [
        0x52: "0", 0x53: "1", 0x54: "2", 0x55: "3", 0x56: "4", 0x57: "5", 0x58: "6", 0x59: "7",
        0x5B: "8", 0x5C: "9", 0x41: ".", 0x43: "*", 0x45: "+", 0x4B: "/", 0x4E: "-", 0x51: "=",
        0x5F: ",",
    ]

    /// F1–F20.
    static let functionKeys: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A,
        0x40, 0x4F, 0x50, 0x5A,
    ]

    /// e, `, u, i, n.
    static let deadKeyCodes: Set<UInt16> = [0x0E, 0x32, 0x20, 0x22, 0x2D]
}
