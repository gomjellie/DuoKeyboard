import Foundation

/// A tiny DSL that describes a sequence of physical key presses on a US (ANSI) keyboard.
///
/// Used by the end-to-end harness and by the input method's DEBUG-only injection hook so that tests
/// can drive the real IMK client path without Accessibility permissions.
///
/// Syntax: literal characters (`dkssud`, `Hello`, `!`) plus tokens in braces:
/// `{space} {S-space} {ret} {tab} {esc} {bs} {del} {left} {right} {up} {down} {home} {end}`
/// `{rcmd}` (tap right ⌘) `{lcmd}` `{lshift}` `{rshift}` `{ropt}` `{lopt}` `{lctl}` `{rctl}` (modifier taps)
/// `{caps}` (toggle Caps Lock: one flagsChanged per token, like the real key)
/// `{cmd+a}` `{ctrl+a}` `{opt+e}` (chords) `{wait:120}` (milliseconds) `{click}` (left mouse down in the client).
/// `{press:rcmd}` … `{release:rcmd}` hold a modifier (any of the tap names but `caps`): one
/// flagsChanged each, and every key in between carries the held modifiers, so
/// `{press:rcmd}c{release:rcmd}` is ⌘C typed with right ⌘ (a chord, never a flip). Held ⇧ does not
/// change the characters (use capitals), and the device bits of other held keys are not repeated.
public struct SyntheticKey: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case key, modifierTap, wait, click
        /// One modifier pressed (`{press:…}`); `modifiers` are all held after it.
        case modifierPress
        /// One modifier released (`{release:…}`); `modifiers` are the ones still held.
        case modifierRelease
    }
    public var kind: Kind
    public var keyCode: UInt16 = 0
    public var characters: String = ""
    public var charactersIgnoringModifiers: String = ""
    /// Raw `NSEvent.ModifierFlags` bits.
    public var modifiers: UInt = 0
    public var milliseconds: Int = 0
}

public enum KeyScript {
    // NSEvent.ModifierFlags raw values (duplicated here to keep DuoKit free of AppKit).
    public static let shiftFlag: UInt = 1 << 17
    public static let controlFlag: UInt = 1 << 18
    public static let optionFlag: UInt = 1 << 19
    public static let commandFlag: UInt = 1 << 20
    public static let capsLockFlag: UInt = 1 << 16
    public static let numericPadFlag: UInt = 1 << 21
    public static let functionFlag: UInt = 1 << 23
    /// `NX_NONCOALSESCEDMASK`: set on every real keyboard event's flags.
    public static let nonCoalescedFlag: UInt = 0x100

    /// Device-dependent modifier bits (`IOLLEvent.h` `NX_DEVICE*KEYMASK`, critique V3). Real
    /// `flagsChanged` events carry them next to the device-independent bit; a synthesized event must
    /// OR them in or a right-⌘ tap looks like a left one.
    public enum DeviceBit {
        public static let leftControl: UInt = 0x0001
        public static let leftShift: UInt = 0x0002
        public static let rightShift: UInt = 0x0004
        public static let leftCommand: UInt = 0x0008
        public static let rightCommand: UInt = 0x0010
        public static let leftOption: UInt = 0x0020
        public static let rightOption: UInt = 0x0040
        public static let rightControl: UInt = 0x2000
    }

    /// The device bit a modifier key sets while held, by key code (0 for Caps Lock and unknown keys).
    public static func deviceBit(forModifierKeyCode keyCode: UInt16) -> UInt {
        switch keyCode {
        case VK.rightCommand: DeviceBit.rightCommand
        case VK.command: DeviceBit.leftCommand
        case VK.shift: DeviceBit.leftShift
        case VK.rightShift: DeviceBit.rightShift
        case VK.option: DeviceBit.leftOption
        case VK.rightOption: DeviceBit.rightOption
        case VK.control: DeviceBit.leftControl
        case VK.rightControl: DeviceBit.rightControl
        default: 0
        }
    }

    /// Device bits a real keyboard reports for chord modifiers held with a key (the left-hand keys).
    public static func leftDeviceBits(forModifiers modifiers: UInt) -> UInt {
        var bits: UInt = 0
        if modifiers & shiftFlag != 0 { bits |= DeviceBit.leftShift }
        if modifiers & controlFlag != 0 { bits |= DeviceBit.leftControl }
        if modifiers & optionFlag != 0 { bits |= DeviceBit.leftOption }
        if modifiers & commandFlag != 0 { bits |= DeviceBit.leftCommand }
        return bits
    }

    public static let ansiKeyCodes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, " ": 0x31, "`": 0x32,
    ]

    public static let shiftedSymbols: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    // Virtual key codes for non-character keys (Carbon kVK_* values).
    public enum VK {
        public static let returnKey: UInt16 = 0x24, tab: UInt16 = 0x30, space: UInt16 = 0x31
        public static let delete: UInt16 = 0x33, escape: UInt16 = 0x35
        public static let rightCommand: UInt16 = 0x36, command: UInt16 = 0x37, shift: UInt16 = 0x38
        public static let capsLock: UInt16 = 0x39, option: UInt16 = 0x3A, control: UInt16 = 0x3B
        public static let rightShift: UInt16 = 0x3C, rightOption: UInt16 = 0x3D, rightControl: UInt16 = 0x3E
        public static let forwardDelete: UInt16 = 0x75, home: UInt16 = 0x73, end: UInt16 = 0x77
        public static let pageUp: UInt16 = 0x74, pageDown: UInt16 = 0x79
        public static let left: UInt16 = 0x7B, right: UInt16 = 0x7C, down: UInt16 = 0x7D, up: UInt16 = 0x7E
        public static let keypadEnter: UInt16 = 0x4C
    }

    static func fnKey(_ scalar: Int) -> String { String(UnicodeScalar(UInt32(scalar)).map(Character.init) ?? " ") }

    public static func parse(_ dsl: String) -> [SyntheticKey] {
        var keys: [SyntheticKey] = []
        // Device-independent flags of the modifiers held with `{press:…}`.
        var held: UInt = 0
        var i = dsl.startIndex
        while i < dsl.endIndex {
            let c = dsl[i]
            if c == "{", let close = dsl[i...].firstIndex(of: "}"), close > dsl.index(after: i) {
                let name = String(dsl[dsl.index(after: i)..<close])
                i = dsl.index(after: close)
                if let k = holdToken(name, held: &held) {
                    keys.append(k)
                } else if let k = token(name, held: held) {
                    if k.kind == .modifierTap, held != 0, k.keyCode != VK.capsLock {
                        // A tap while others are held: its release keeps their flags.
                        keys.append(SyntheticKey(kind: .modifierPress, keyCode: k.keyCode, modifiers: held | k.modifiers))
                        keys.append(SyntheticKey(kind: .modifierRelease, keyCode: k.keyCode, modifiers: held))
                    } else {
                        keys.append(k)
                    }
                }
                continue
            }
            if let k = character(c, extraModifiers: held) { keys.append(k) }
            i = dsl.index(after: i)
        }
        return keys
    }

    /// `{press:name}` / `{release:name}`, updating `held`; nil for any other token.
    static func holdToken(_ name: String, held: inout UInt) -> SyntheticKey? {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "press" || parts[0] == "release", parts[1] != "caps",
              let tap = token(parts[1]), tap.kind == .modifierTap else { return nil }
        if parts[0] == "press" {
            held |= tap.modifiers
            return SyntheticKey(kind: .modifierPress, keyCode: tap.keyCode, modifiers: held)
        }
        held &= ~tap.modifiers
        return SyntheticKey(kind: .modifierRelease, keyCode: tap.keyCode, modifiers: held)
    }

    /// The `flagsChanged` masks (device-independent flags plus the key's device bit) one modifier
    /// key event produces, for the DEBUG injector and its in-process mirror. A tap is press then
    /// release; `{press:…}` and `{release:…}` are one event each. Caps Lock is a toggle and is
    /// handled by the caller.
    public static func flagsMasks(for key: SyntheticKey) -> [UInt] {
        switch key.kind {
        case .modifierTap: [key.modifiers | deviceBit(forModifierKeyCode: key.keyCode), 0]
        case .modifierPress: [key.modifiers | deviceBit(forModifierKeyCode: key.keyCode)]
        case .modifierRelease: [key.modifiers]
        case .key, .wait, .click: []
        }
    }

    public static func character(_ ch: Character, extraModifiers: UInt = 0) -> SyntheticKey? {
        var base = Character(ch.lowercased())
        var mods = extraModifiers
        if ch.isUppercase && ch.isLetter { mods |= shiftFlag }
        if let unshifted = shiftedSymbols[ch] { base = unshifted; mods |= shiftFlag }
        guard let code = ansiKeyCodes[base] else { return nil }
        let chars: String
        if mods & (commandFlag | controlFlag) != 0 {
            chars = mods & controlFlag != 0 && base.isLetter
                ? String(UnicodeScalar(UInt8(base.asciiValue! - 96)).description) : String(base)
        } else {
            chars = String(ch)
        }
        return SyntheticKey(kind: .key, keyCode: code, characters: chars,
                            charactersIgnoringModifiers: mods & shiftFlag != 0 && !(mods & (commandFlag | controlFlag) != 0) ? String(ch) : String(base),
                            modifiers: mods)
    }

    /// - Parameter held: modifiers held with `{press:…}`, added to a key token (not to a tap).
    static func token(_ name: String, held: UInt = 0) -> SyntheticKey? {
        func special(_ code: UInt16, _ chars: String, _ mods: UInt = 0) -> SyntheticKey {
            SyntheticKey(kind: .key, keyCode: code, characters: chars, charactersIgnoringModifiers: chars,
                         modifiers: mods | held)
        }
        let arrows = numericPadFlag | functionFlag
        switch name {
        case "space": return special(VK.space, " ")
        case "S-space": return special(VK.space, " ", shiftFlag)
        case "ret": return special(VK.returnKey, "\r")
        case "enter": return special(VK.keypadEnter, "\u{3}", numericPadFlag)
        case "tab": return special(VK.tab, "\t")
        case "S-tab": return special(VK.tab, "\u{19}", shiftFlag)
        case "esc": return special(VK.escape, "\u{1B}")
        case "bs": return special(VK.delete, "\u{7F}")
        case "del": return special(VK.forwardDelete, fnKey(0xF728), functionFlag)
        case "left": return special(VK.left, fnKey(0xF702), arrows)
        case "right": return special(VK.right, fnKey(0xF703), arrows)
        case "up": return special(VK.up, fnKey(0xF700), arrows)
        case "down": return special(VK.down, fnKey(0xF701), arrows)
        case "home": return special(VK.home, fnKey(0xF729), functionFlag)
        case "end": return special(VK.end, fnKey(0xF72B), functionFlag)
        case "rcmd": return SyntheticKey(kind: .modifierTap, keyCode: VK.rightCommand, modifiers: commandFlag)
        case "lcmd": return SyntheticKey(kind: .modifierTap, keyCode: VK.command, modifiers: commandFlag)
        case "lshift": return SyntheticKey(kind: .modifierTap, keyCode: VK.shift, modifiers: shiftFlag)
        case "rshift": return SyntheticKey(kind: .modifierTap, keyCode: VK.rightShift, modifiers: shiftFlag)
        case "ropt": return SyntheticKey(kind: .modifierTap, keyCode: VK.rightOption, modifiers: optionFlag)
        case "lopt": return SyntheticKey(kind: .modifierTap, keyCode: VK.option, modifiers: optionFlag)
        case "lctl": return SyntheticKey(kind: .modifierTap, keyCode: VK.control, modifiers: controlFlag)
        case "rctl": return SyntheticKey(kind: .modifierTap, keyCode: VK.rightControl, modifiers: controlFlag)
        case "caps": return SyntheticKey(kind: .modifierTap, keyCode: VK.capsLock, modifiers: capsLockFlag)
        case "click": return SyntheticKey(kind: .click)
        default:
            if name.hasPrefix("wait:"), let ms = Int(name.dropFirst(5)) {
                return SyntheticKey(kind: .wait, milliseconds: ms)
            }
            // Chords like cmd+a, ctrl+shift+k, opt+e
            let parts = name.split(separator: "+").map(String.init)
            guard parts.count >= 2, let last = parts.last, last.count == 1, let ch = last.first else { return nil }
            var mods: UInt = held
            for p in parts.dropLast() {
                switch p {
                case "cmd": mods |= commandFlag
                case "ctrl": mods |= controlFlag
                case "opt": mods |= optionFlag
                case "shift": mods |= shiftFlag
                default: return nil
                }
            }
            return character(ch, extraModifiers: mods)
        }
    }
}
