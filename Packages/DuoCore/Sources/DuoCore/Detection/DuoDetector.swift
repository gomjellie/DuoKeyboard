import Foundation

/// The memory-mapped DUOM v1 model plus the scoring algorithm of docs/research/detection.md §5–7:
/// a bit-exact port of `Tools/ModelBuilder/detector.py`.
///
/// All arithmetic is integer millinats, so with `user == nil` and `biasKO == 0` every score equals
/// `test_vectors.json` exactly. The detector is immutable and `Sendable`; score on any thread.
///
/// `raw` is the ABC-layout keystroke string of one token: ASCII letters (uppercase = Shift) plus a
/// token-internal `'`. Any other character is outside the model's alphabet and is scored like `'`
/// (it disables `M(b)` and is rendered literally).
public final class DuoDetector: LanguageDetector, Sendable {
    /// `Contents/Resources/duo-model.bin` of `bundle`, if present.
    public static func bundledModelURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "duo-model", withExtension: "bin")
    }

    /// FNV-1a-64 content hash from the header (hex, e.g. "20dd934c2856173a").
    public let contentHash: String

    /// Tuned constants from the model's `meta.params` (HYST, USER_UNIT, …).
    public let parameters: [String: Int]

    let scorer: DetectionScorer

    /// Maps the model at `modelURL` and validates it.
    /// - Throws: `DuoModelError` when the file is missing, not a DUOM v1 model, or inconsistent.
    public init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw DuoModelError.cannotOpen(modelURL.path)
        }
        let model = try DuoModel(url: modelURL)
        scorer = try DetectionScorer(model: model)
        contentHash = Self.hex(model.contentHash)
        parameters = model.meta.params
    }

    var model: DuoModel { scorer.model }

    // MARK: LanguageDetector

    public func finalScores(raw: String, context: LanguageContext, terminator: Terminator,
                            user: UserCounts?, biasKO: Int) -> HypothesisScores {
        let features = TokenBytes.with(raw) { scorer.features($0, mode: .final) }
        return scorer.scores(features, mode: .final, context: context, terminator: terminator, user: user,
                             biasKO: biasKO)
    }

    public func prefixScores(raw: String, context: LanguageContext, user: UserCounts?, biasKO: Int) -> HypothesisScores {
        let features = TokenBytes.with(raw) { scorer.features($0, mode: .prefix) }
        return scorer.scores(features, mode: .prefix, context: context, terminator: .space, user: user,
                             biasKO: biasKO)
    }

    public func render(raw: String, _ hypothesis: Hypothesis) -> String {
        switch hypothesis {
        case .english:
            return raw
        case .korean:
            return HangulAutomaton.render(raw: raw).text
        case .mixed(let latin):
            let split = raw.index(raw.startIndex, offsetBy: min(max(latin, 0), raw.count))
            return String(raw[..<split]) + HangulAutomaton.render(raw: String(raw[split...])).text
        }
    }

    /// Critique R1.2 re-open gate for eager English: the key at `raw[latinCount]` arrives after
    /// `raw[0..<latinCount]` was committed as Latin. True when that key is a consonant key after
    /// Korean normalisation (`qwertasdfgzxcv` or `QWERT`; a Shift on any other consonant key is
    /// dropped as in DET §3) and `lexEN[low[0..<b]] != nil`, or the Latin part has an uppercase
    /// letter, or `suffixPrefix[kno[b...]] != nil`. False when `latinCount` is not inside the token
    /// or the token has an apostrophe (`M(b)` cannot exist then).
    public func canAttachKorean(raw: String, latinCount: Int) -> Bool {
        TokenBytes.with(raw) { t in
            let b = latinCount
            guard b >= 1, b < t.count, !t.hasNonLetter, KeySymbols.isConsonantKey[Int(t.kno[b])] else { return false }
            if (0..<b).contains(where: { KeySymbols.isUpper(t.raw[$0]) }) { return true }
            let m = scorer.model
            if m.englishLexicon.value(hash: FNV1a64.hash(t.low, b)) != nil { return true }
            let tail = t.kno + b, tailCount = t.count - b
            return m.suffixPrefix.contains(tail, tailCount, hash: FNV1a64.hash(tail, tailCount))
        }
    }

    // MARK: Helpers

    /// DET §4 apostrophe rule: after `raw`, a typed `'` stays inside the token iff the prefix-mode
    /// argmax of `raw + "'"` is English (`don't`, `it's`); otherwise the token is committed and `'`
    /// is typed literally (`'사랑'이라는`).
    public func apostropheIsInternal(after raw: String, context: LanguageContext, user: UserCounts? = nil,
                                     biasKO: Int = 0) -> Bool {
        prefixScores(raw: raw + "'", context: context, user: user, biasKO: biasKO).best?.hypothesis == .english
    }

    /// `userBonus(n)` of DET §5.5 for an effective count `n` (millinats).
    public func userBonus(count: Int) -> Int { scorer.userBonus(count) }

    /// Context-free features (`detector.py` `features()`), for tests and diagnostics.
    func features(raw: String, mode: ScoringMode) -> TokenFeatures {
        TokenBytes.with(raw) { scorer.features($0, mode: mode) }
    }

    static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
