/// Hangul jamo tables (Unicode "Hangul Compatibility Jamo" block, U+3131–U+318E) and the index
/// mapping used to compose precomposed syllables (U+AC00–U+D7A3).
public enum Jamo {
    // MARK: Syllable composition indices

    /// 19 initial consonants in Unicode order.
    public static let choseong: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]
    /// 21 medial vowels in Unicode order.
    public static let jungseong: [Character] = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ", "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ",
    ]
    /// 28 final slots in Unicode order; index 0 means "no final consonant".
    public static let jongseong: [Character?] = [
        nil, "ㄱ", "ㄲ", "ㄳ", "ㄴ", "ㄵ", "ㄶ", "ㄷ", "ㄹ", "ㄺ", "ㄻ", "ㄼ", "ㄽ", "ㄾ", "ㄿ", "ㅀ", "ㅁ", "ㅂ", "ㅄ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]

    static let choIndex: [Character: Int] = Dictionary(uniqueKeysWithValues: choseong.enumerated().map { ($1, $0) })
    static let jungIndex: [Character: Int] = Dictionary(uniqueKeysWithValues: jungseong.enumerated().map { ($1, $0) })
    static let jongIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: jongseong.enumerated().compactMap { i, c in c.map { ($0, i) } })

    public static let syllableBase: UInt32 = 0xAC00
    public static let syllableLast: UInt32 = 0xD7A3

    // MARK: Classification

    public static func isConsonant(_ c: Character) -> Bool { choIndex[c] != nil || jongIndex[c] != nil }
    public static func isVowel(_ c: Character) -> Bool { jungIndex[c] != nil }
    public static func canBeInitial(_ c: Character) -> Bool { choIndex[c] != nil }
    public static func canBeFinal(_ c: Character) -> Bool { jongIndex[c] != nil }

    public static func isPrecomposedSyllable(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return s.value >= syllableBase && s.value <= syllableLast
    }

    public static func isHangul(_ c: Character) -> Bool { isPrecomposedSyllable(c) || isConsonant(c) || isVowel(c) }

    // MARK: Compound rules (두벌식 / KS X 5002)

    /// Two simple vowels typed in sequence that merge into a compound vowel.
    public static let compoundVowels: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ",
    ]
    /// Two consonants typed in sequence (after a vowel) that merge into a compound final consonant.
    public static let compoundFinals: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ", "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ",
        "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ",
    ]
    /// Inverse of `compoundVowels`.
    public static let vowelParts: [Character: (Character, Character)] = Dictionary(
        uniqueKeysWithValues: compoundVowels.map { key, v in (v, (key.first!, key.last!)) })
    /// Inverse of `compoundFinals`.
    public static let finalParts: [Character: (Character, Character)] = Dictionary(
        uniqueKeysWithValues: compoundFinals.map { key, v in (v, (key.first!, key.last!)) })

    public static func combineVowels(_ a: Character, _ b: Character) -> Character? { compoundVowels[String([a, b])] }
    public static func combineFinals(_ a: Character, _ b: Character) -> Character? { compoundFinals[String([a, b])] }

    // MARK: Compose / decompose

    public static func compose(initial: Character, medial: Character, final: Character? = nil) -> Character? {
        guard let l = choIndex[initial], let v = jungIndex[medial] else { return nil }
        let t: Int
        if let final { guard let ti = jongIndex[final] else { return nil }; t = ti } else { t = 0 }
        let value = syllableBase + UInt32((l * 21 + v) * 28 + t)
        return UnicodeScalar(value).map(Character.init)
    }

    /// Splits a precomposed syllable into (initial, medial, final?).
    public static func decompose(_ c: Character) -> (initial: Character, medial: Character, final: Character?)? {
        guard isPrecomposedSyllable(c), let s = c.unicodeScalars.first else { return nil }
        let index = Int(s.value - syllableBase)
        let l = index / (21 * 28), v = (index % (21 * 28)) / 28, t = index % 28
        return (choseong[l], jungseong[v], jongseong[t])
    }

    /// Decomposes any Hangul text into the sequence of *simple* jamo as they are typed on 두벌식
    /// (compound vowels/finals are split into their typed parts). Non-Hangul characters are kept.
    public static func typedJamo(of text: String) -> [Character] {
        var out: [Character] = []
        for c in text {
            if let (l, v, t) = decompose(c) {
                out.append(l)
                out.append(contentsOf: split(vowel: v))
                if let t { out.append(contentsOf: split(final: t)) }
            } else if isVowel(c) {
                out.append(contentsOf: split(vowel: c))
            } else if let parts = finalParts[c] {
                out.append(parts.0); out.append(parts.1)
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func split(vowel v: Character) -> [Character] { vowelParts[v].map { [$0.0, $0.1] } ?? [v] }
    static func split(final t: Character) -> [Character] { finalParts[t].map { [$0.0, $0.1] } ?? [t] }
}
