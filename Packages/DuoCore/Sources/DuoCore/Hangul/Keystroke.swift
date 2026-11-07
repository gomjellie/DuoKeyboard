/// One physical letter key press as seen by the engine: the base (unshifted, lowercase) key on a US
/// QWERTY layout plus whether Shift was effectively held. Caps Lock is deliberately not modelled —
/// the input method resolves it before creating keystrokes.
public struct Keystroke: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Lowercase ASCII letter `a`–`z`.
    public let base: Character
    public let shift: Bool

    public init(base: Character, shift: Bool) {
        self.base = Character(base.lowercased())
        self.shift = shift
    }

    /// Creates a keystroke from a typed Latin letter: uppercase implies Shift.
    public init?(latin: Character) {
        guard let a = latin.asciiValue, latin.isLetter else { return nil }
        self.init(base: Character(UnicodeScalar(a | 0x20)), shift: latin.isUppercase)
    }

    /// The character this key produces under the English (Latin) interpretation.
    public var latin: Character { shift ? Character(base.uppercased()) : base }

    /// The jamo this key produces under 두벌식.
    public var jamo: Character { DubeolsikLayout.jamo(for: self) }

    /// True if Shift changes the 두벌식 output for this key (ㅃㅉㄸㄲㅆㅒㅖ).
    public var shiftIsMeaningfulInKorean: Bool { DubeolsikLayout.shiftedJamo[base] != nil }

    public var description: String { String(latin) }

    // Codable as the Latin character it types ("a" / "A").
    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = s.first, let k = Keystroke(latin: c) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad keystroke \(s)"))
        }
        self = k
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(String(latin))
    }
}

extension Array where Element == Keystroke {
    /// Parses a Latin string such as `"dkssud"` or `"Hello"` into keystrokes (non-letters dropped).
    public init(latin text: String) { self = text.compactMap(Keystroke.init(latin:)) }

    public var latinString: String { String(map(\.latin)) }
}

/// The standard Korean 두벌식 (KS X 5002) layout on a US keyboard.
public enum DubeolsikLayout {
    public static let jamoForKey: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
    ]
    public static let shiftedJamo: [Character: Character] = [
        "q": "ㅃ", "w": "ㅉ", "e": "ㄸ", "r": "ㄲ", "t": "ㅆ", "o": "ㅒ", "p": "ㅖ",
    ]

    /// Inverse mapping: jamo → the keystroke that types it.
    public static let keystrokeForJamo: [Character: Keystroke] = {
        var m: [Character: Keystroke] = [:]
        for (k, j) in jamoForKey { m[j] = Keystroke(base: k, shift: false) }
        for (k, j) in shiftedJamo { m[j] = Keystroke(base: k, shift: true) }
        return m
    }()

    public static func jamo(for key: Keystroke) -> Character {
        if key.shift, let j = shiftedJamo[key.base] { return j }
        return jamoForKey[key.base] ?? key.base
    }

    /// Converts Hangul text into the keystrokes a 두벌식 typist presses. Returns nil if the text contains
    /// anything that is not typable Hangul.
    public static func keystrokes(forHangul text: String) -> [Keystroke]? {
        var out: [Keystroke] = []
        for j in Jamo.typedJamo(of: text) {
            guard let k = keystrokeForJamo[j] else { return nil }
            out.append(k)
        }
        return out
    }
}
