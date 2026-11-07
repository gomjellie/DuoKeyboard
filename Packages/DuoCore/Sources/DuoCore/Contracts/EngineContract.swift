// CONTRACT FILE: owned by the lead. Implementers must not change these signatures; add helpers in
// your own files (extensions are fine). See docs/SPEC.md §3.

import Foundation

// MARK: - Key input (produced by DuoKit.KeyEventMapper from NSEvent, or by tests)

/// A key press, normalised for the engine. Letters are identified by their **ANSI key position**
/// (the ABC layout), never by `event.characters`, so the raw string the model scores is always the
/// ABC-layout string (critique R16).
public struct KeyEvent: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        /// a–z by key position; `Keystroke.shift` carries Shift (Caps Lock is *not* folded in).
        case letter(Keystroke)
        /// A printable non-letter the ABC layout produces for this key + Shift: digits, punctuation,
        /// `'`, `` ` ``. Space is `.space`.
        case character(Character)
        case space
        /// Return and keypad Enter.
        case returnKey
        case tab
        case escape
        case backspace
        case forwardDelete
        case arrowLeft, arrowRight, arrowUp, arrowDown
        /// Home, End, Page Up/Down, Help.
        case navigation
        /// F1–F20.
        case function
        /// A numeric-keypad digit or operator (always a boundary, never part of a token).
        case keypad(Character)
        /// Anything else (unknown key codes, media keys).
        case other
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let capsLock = Modifiers(rawValue: 1 << 4)
        public static let function = Modifiers(rawValue: 1 << 5)
    }

    public var key: Key
    public var modifiers: Modifiers
    public var isRepeat: Bool
    /// ⌥+key that is a dead key on the ABC layout (⌥e ⌥` ⌥u ⌥i ⌥n): the *next* key must pass raw.
    public var isDeadKey: Bool
    /// Seconds (monotonic, `NSEvent.timestamp` / `ProcessInfo.systemUptime`).
    public var timestamp: TimeInterval

    public init(_ key: Key, modifiers: Modifiers = [], isRepeat: Bool = false, isDeadKey: Bool = false,
                timestamp: TimeInterval = 0) {
        self.key = key
        self.modifiers = modifiers
        self.isRepeat = isRepeat
        self.isDeadKey = isDeadKey
        self.timestamp = timestamp
    }

    /// Convenience for tests: one event per character of an ABC-layout string (letters, digits,
    /// punctuation, space).
    public static func typing(_ text: String) -> [KeyEvent] {
        text.map { ch in
            if let k = Keystroke(latin: ch) { return KeyEvent(.letter(k), modifiers: k.shift ? .shift : []) }
            if ch == " " { return KeyEvent(.space) }
            if ch == "\n" { return KeyEvent(.returnKey) }
            if ch == "\t" { return KeyEvent(.tab) }
            return KeyEvent(.character(ch))
        }
    }
}

/// A `flagsChanged` event for the flip-key tap detector (critique R3).
public struct ModifierEvent: Hashable, Sendable {
    /// Hardware key code of the modifier that changed (54 = right ⌘, 61 = right ⌥, 56/60 = ⇧, 57 = ⇪).
    public var keyCode: UInt16
    /// Raw `NSEvent.modifierFlags.rawValue` *including* device-dependent bits (0x10 = right ⌘ …).
    public var flags: UInt
    public var timestamp: TimeInterval
    /// `NSEvent.pressedMouseButtons` at the time of the event.
    public var pressedMouseButtons: Int

    public init(keyCode: UInt16, flags: UInt, timestamp: TimeInterval, pressedMouseButtons: Int = 0) {
        self.keyCode = keyCode
        self.flags = flags
        self.timestamp = timestamp
        self.pressedMouseButtons = pressedMouseButtons
    }
}

// MARK: - Text client (IMKTextInput, mirrored so the engine is testable with a fake)

/// What the engine needs from the text client. The IME adapts `IMKTextInput`; tests use
/// `FakeTextClient`. Every call is a synchronous XPC round trip in the IME: keep to one
/// mark/insert per key event in the common case (critique R15).
@MainActor
public protocol TextClient: AnyObject {
    /// `insertText(_:replacementRange:)`. `nil` range = `NSNotFound` (replace the marked text / insert at caret).
    func insertText(_ text: String, replacementRange: NSRange?)
    /// `setMarkedText(_:selectionRange:(len,0):replacementRange:)`. `""` clears an active composition.
    func setMarkedText(_ text: String, replacementRange: NSRange?)
    /// `nil` when the client reports `NSNotFound`.
    func selectedRange() -> NSRange?
    /// `nil` when nothing is marked (`NSNotFound`).
    func markedRange() -> NSRange?
    /// `attributedSubstring(from:)?.string`; `nil` when the client cannot provide it.
    func string(in range: NSRange) -> String?
    var bundleIdentifier: String { get }
}

/// How well a client supports replacing already-committed text (docs/research/imk-platform.md §5.3).
public enum ReplacementSupport: String, Sendable, Codable, Hashable {
    /// Cocoa, WebKit, Chromium, Electron.
    case full
    /// Terminal.app: only ranges that end at the caret.
    case beforeCaretOnly
    /// iTerm2, Hyper, Java/JetBrains: never replace; keep the whole token marked (critique R17).
    case none
}

// MARK: - Engine output for the HUD

/// What the composition HUD should show. The HUD controller (IME) owns timing details such as the
/// 300 ms appear delay, the 140 ms hide debounce and fades (critique R12).
public struct HUDRequest: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// The other reading of the token being composed (critique R11).
        /// `eligible == false` means "keep showing it if it is already visible, but don't bring it up".
        case alternative(text: String, language: ScriptLanguage, eligible: Bool)
        /// "↺ flip last word" chip after an uncertain/surprising commit, or Backspace right after one.
        case flipLastWord(text: String, language: ScriptLanguage)
        /// One-shot language for the next word (flip with nothing to flip).
        case oneShot(ScriptLanguage)
        /// "여기서는 바꿀 수 없어요" (the client can't replace text).
        case cannotChange
        /// Direct-profile app with Bilingual turned on for this line.
        case bilingualLine
    }

    public enum Anchor: Hashable, Sendable {
        /// Caret rect of the marked text (index 0 of the marked range).
        case markedText
        /// Document location where the last committed word starts.
        case location(Int)
        /// Wherever the caret is.
        case caret
    }

    public var content: Content
    public var anchor: Anchor
    /// Show at once (chips, badges) instead of after the typing pause.
    public var immediate: Bool
    /// Auto-hide after this many seconds; `nil` = until the engine changes the request.
    public var lifetime: TimeInterval?
    /// The reading changed by itself mid-word (not a user flip): pulse the badge once.
    public var pulse: Bool

    public init(content: Content, anchor: Anchor, immediate: Bool = false, lifetime: TimeInterval? = nil,
                pulse: Bool = false) {
        self.content = content
        self.anchor = anchor
        self.immediate = immediate
        self.lifetime = lifetime
        self.pulse = pulse
    }
}

/// Why a composition is being committed without a key of its own.
public enum CommitReason: String, Sendable, Hashable {
    /// IMK `commitComposition(_:)`.
    case commitComposition
    /// A mouse-down event reached `handle` (critique R4).
    case mouse
    /// `deactivateServer`, or the selected input source changed away from Duo (critique R18 #6).
    case deactivate
    /// Secure event input turned on (critique R5).
    case secureInput
}

/// Things the engine reports to its host (the IME forwards some as distributed notifications).
public enum EngineNotification: Hashable, Sendable {
    /// The user flipped a word (onboarding challenge listens for `com.inkyuoh.Duo.event.flipped`).
    case flipped(to: ScriptLanguage)
    /// A word was committed (for VoiceOver announcements and diagnostics; no text leaves the IME).
    case committed(language: ScriptLanguage)
    /// Learning data changed and should be persisted (debounced by the writer).
    case learningChanged
}
