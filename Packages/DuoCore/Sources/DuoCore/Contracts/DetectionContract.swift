// CONTRACT FILE: owned by the lead. Implementers must not change these signatures; add helpers in
// your own files (extensions are fine). See docs/SPEC.md §3.

import Foundation

/// One interpretation of a token's keystrokes (docs/research/detection.md §1).
public enum Hypothesis: Hashable, Sendable, CustomStringConvertible {
    /// `K`: the 두벌식 automaton applied to the whole raw string.
    case korean
    /// `E`: the raw string itself, case as typed.
    case english
    /// `M(b)`: `raw[0..<latin]` as Latin + the automaton applied to `raw[latin...]` (PR을, push했어요).
    case mixed(latin: Int)

    /// Key used by the test vectors and the learning store: `"K"`, `"E"`, `"M3"`.
    public var key: String {
        switch self {
        case .korean: "K"
        case .english: "E"
        case .mixed(let b): "M\(b)"
        }
    }

    public init?(key: String) {
        switch key {
        case "K": self = .korean
        case "E": self = .english
        default:
            guard key.first == "M", let b = Int(key.dropFirst()), b > 0 else { return nil }
            self = .mixed(latin: b)
        }
    }

    public var description: String { key }

    /// The script the user perceives for this reading: K and M read as Korean, E as English.
    public var language: ScriptLanguage { self == .english ? .english : .korean }
}

extension Hypothesis: Codable {
    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let h = Hypothesis(key: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad hypothesis \(s)"))
        }
        self = h
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

/// The language the user sees (HUD badge 가 / A, one-shot flips).
public enum ScriptLanguage: String, Sendable, Codable, Hashable {
    case korean, english

    public var opposite: ScriptLanguage { self == .korean ? .english : .korean }
}

/// Context for the next token (detection.md §4).
public enum LanguageContext: String, Sendable, Codable, CaseIterable, Hashable {
    case start = "START"
    case korean = "KO"
    case english = "EN"
    /// The character immediately before the token is a digit (3개, 10mm, 4th).
    case number = "NUM"
}

/// The boundary key that ended a token (final mode only, detection.md §4).
public enum Terminator: String, Sendable, Codable, CaseIterable, Hashable {
    /// Space, Return, Tab, Esc, arrows, click, focus change, end of input.
    case space = "S"
    case digit = "D"
    case hyphen = "H"
    /// Any other punctuation.
    case punctuation = "P"
}

public struct ScoredHypothesis: Hashable, Sendable {
    public var hypothesis: Hypothesis
    /// Integer log-score in millinats.
    public var score: Int

    public init(_ hypothesis: Hypothesis, _ score: Int) {
        self.hypothesis = hypothesis
        self.score = score
    }
}

/// Scores in candidate order `K, E, M(1), M(2), …` (only hypotheses that exist for this raw).
public struct HypothesisScores: Hashable, Sendable {
    public var entries: [ScoredHypothesis]

    public init(_ entries: [ScoredHypothesis]) { self.entries = entries }

    public subscript(_ h: Hypothesis) -> Int? { entries.first { $0.hypothesis == h }?.score }

    /// First candidate with the strictly greatest score; ties go to the earlier one (detection.md §5.4).
    public var best: ScoredHypothesis? { best { _ in true } }

    /// Same tie rule, restricted to hypotheses satisfying `include`.
    public func best(where include: (Hypothesis) -> Bool) -> ScoredHypothesis? {
        var winner: ScoredHypothesis?
        for e in entries where include(e.hypothesis) {
            if winner == nil || e.score > winner!.score { winner = e }
        }
        return winner
    }
}

/// Effective (already decayed, rounded) per-hypothesis counts for one `(raw, context)` from the
/// learning store. The detector turns them into `userBonus(n)` (detection.md §5.5).
public struct UserCounts: Hashable, Sendable {
    public var counts: [Hypothesis: Int]

    public init(_ counts: [Hypothesis: Int] = [:]) { self.counts = counts }

    public subscript(_ h: Hypothesis) -> Int { counts[h] ?? 0 }
    public var isEmpty: Bool { counts.values.allSatisfy { $0 <= 0 } }
}

/// The scoring engine (port of `Tools/ModelBuilder/detector.py`). Immutable and thread-safe.
///
/// With `user == nil` and `biasKO == 0` every score must equal `test_vectors.json` exactly.
public protocol LanguageDetector: Sendable {
    /// Final mode: the token is complete (`</s>`, lexicon, terminator). `biasKO` (millinats, the
    /// per-app/global language bias of critique R8, clamped by the caller) is added to `S_K` only.
    func finalScores(raw: String, context: LanguageContext, terminator: Terminator,
                     user: UserCounts?, biasKO: Int) -> HypothesisScores

    /// Prefix mode (display while typing). The user bonus applies here too (critique R7).
    func prefixScores(raw: String, context: LanguageContext, user: UserCounts?, biasKO: Int) -> HypothesisScores

    /// `render(raw, h)` of detection.md §5.6.
    func render(raw: String, _ hypothesis: Hypothesis) -> String

    /// Critique R1.2 re-open gate, evaluated when the key at index `latinCount` of `raw` arrives after
    /// `raw[0..<latinCount]` was committed as Latin: that key is a consonant key (`qwertasdfgzxcv` or
    /// `QWERT`) AND (`lexEN[low[0..<b]] != nil` OR the Latin part has an uppercase letter OR
    /// `suffixPrefix[kno[b...]] != nil`).
    func canAttachKorean(raw: String, latinCount: Int) -> Bool

    /// Tuned constants from the model's `meta.params` (HYST, USER_UNIT, …).
    var parameters: [String: Int] { get }
}

/// Probability thresholds expressed as score margins (critique R8): a 2-way softmax of the shown
/// reading against the best other one.
public enum Margins {
    /// P(alt) ≥ 20 %: HUD offers the alternative; implicit learning counts the commit.
    public static let hudAlternative = 1386
    /// P(alt) ≥ 35 %: "uncertain commit" chip.
    public static let uncertainCommit = 619
    /// P(alt) < 1 %: eager English commit.
    public static let eagerCommit = 4595
}
