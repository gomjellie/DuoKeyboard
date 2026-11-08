// CONTRACT FILE: owned by the lead. Implementers must not change these signatures; add helpers in
// your own files (extensions are fine). See SPEC.md §3.

import Foundation

/// Which key flips the current/last word (critique R3; default right ⌘ tap).
public enum FlipKey: String, Sendable, Codable, CaseIterable, Hashable {
    case rightCommand
    case rightOption
    case doubleShift
    case shiftSpace
    case capsLock

    /// Keycap glyphs for the HUD and Settings.
    public var keycaps: [String] {
        switch self {
        case .rightCommand: ["⌘"]
        case .rightOption: ["⌥"]
        case .doubleShift: ["⇧", "⇧"]
        case .shiftSpace: ["⇧", "Space"]
        case .capsLock: ["⇪"]
        }
    }
}

/// What Backspace removes while composing Korean (Apple's 자소/글자 setting).
public enum BackspaceUnit: String, Sendable, Codable, CaseIterable, Hashable {
    /// One keystroke (닭 → 달 → 다 → ㄷ). Default.
    case jaso
    /// One whole syllable block.
    case gulja
}

/// Per-app behaviour (critique R8, R10).
public enum AppProfile: String, Sendable, Codable, CaseIterable, Hashable {
    /// No bias.
    case automatic
    /// `biasKO = +1000`.
    case koreanFirst
    /// `biasKO = −1000` (code editors and terminals by default).
    case englishFirst
    /// Keys pass straight through; a flip tap turns Bilingual on for the current line.
    case direct
}

/// All user-facing settings, shared by the host app and the IME through
/// `UserDefaults(suiteName: DuoIDs.sharedSuite)` as one JSON blob (DuoKit.SettingsStore).
/// Decoding tolerates missing keys so older blobs keep working, and values it cannot read (a newer
/// build's enum case) fall back per key; in `appProfiles`, per app.
public struct DuoSettings: Sendable, Hashable, Codable {
    public var flipKey: FlipKey = .rightCommand
    /// Tap window for modifier-tap flip keys, 200…500 ms.
    public var flipTapWindowMs: Int = 300
    /// Show the composition HUD (alternative reading). Failure messages and badges still show.
    public var showHints: Bool = true
    /// With `showHints`, the choice bar is up for every word being typed, not only when another
    /// reading is likely (SPEC.md 4.11절). The flip key brings it up either way.
    public var alwaysShowChoices: Bool = false
    /// Offer "↺ flip last word" after an uncertain or surprising commit.
    public var offerUndoAfterCommit: Bool = true
    public var backspaceUnit: BackspaceUnit = .jaso
    /// `` ` `` types ₩ (Apple 2-Set behaviour); default off.
    public var graveTypesWon: Bool = false
    /// Global language bias, −1000 (English) … +1000 (Korean), added to `biasKO`.
    public var languageBias: Int = 0
    /// Commit English early once it is certain (critique R1.2) so autocomplete sees real text.
    public var eagerEnglishCommit: Bool = true
    public var learningEnabled: Bool = true
    /// Temporary pause from the input menu ("학습 일시 정지").
    public var learningPaused: Bool = false
    /// User overrides by bundle identifier; apps not listed use `ClientProfile` defaults.
    public var appProfiles: [String: AppProfile] = [:]
    public var hasCompletedOnboarding: Bool = false

    public init() {}

    public static let `default` = DuoSettings()

    private enum CodingKeys: String, CodingKey {
        case flipKey, flipTapWindowMs, showHints, alwaysShowChoices, offerUndoAfterCommit, backspaceUnit, graveTypesWon,
             languageBias, eagerEnglishCommit, learningEnabled, learningPaused, appProfiles,
             hasCompletedOnboarding
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DuoSettings()
        flipKey = (try? c.decodeIfPresent(FlipKey.self, forKey: .flipKey)) ?? d.flipKey
        flipTapWindowMs = (try? c.decodeIfPresent(Int.self, forKey: .flipTapWindowMs)) ?? d.flipTapWindowMs
        showHints = (try? c.decodeIfPresent(Bool.self, forKey: .showHints)) ?? d.showHints
        alwaysShowChoices = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysShowChoices)) ?? d.alwaysShowChoices
        offerUndoAfterCommit = (try? c.decodeIfPresent(Bool.self, forKey: .offerUndoAfterCommit)) ?? d.offerUndoAfterCommit
        backspaceUnit = (try? c.decodeIfPresent(BackspaceUnit.self, forKey: .backspaceUnit)) ?? d.backspaceUnit
        graveTypesWon = (try? c.decodeIfPresent(Bool.self, forKey: .graveTypesWon)) ?? d.graveTypesWon
        languageBias = (try? c.decodeIfPresent(Int.self, forKey: .languageBias)) ?? d.languageBias
        eagerEnglishCommit = (try? c.decodeIfPresent(Bool.self, forKey: .eagerEnglishCommit)) ?? d.eagerEnglishCommit
        learningEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .learningEnabled)) ?? d.learningEnabled
        learningPaused = (try? c.decodeIfPresent(Bool.self, forKey: .learningPaused)) ?? d.learningPaused
        appProfiles = Self.decodeProfiles(c) ?? d.appProfiles
        hasCompletedOnboarding = (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
        flipTapWindowMs = min(500, max(200, flipTapWindowMs))
        languageBias = min(1000, max(-1000, languageBias))
    }

    /// Any string key (bundle identifiers).
    private struct BundleKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// `appProfiles` one app at a time: a profile this build does not know (from a newer build) drops
    /// only that app, not every override. Nil when the key is missing or not an object.
    private static func decodeProfiles(_ c: KeyedDecodingContainer<CodingKeys>) -> [String: AppProfile]? {
        guard let profiles = try? c.nestedContainer(keyedBy: BundleKey.self, forKey: .appProfiles) else { return nil }
        var out: [String: AppProfile] = [:]
        for key in profiles.allKeys {
            if let profile = try? profiles.decode(AppProfile.self, forKey: key) { out[key.stringValue] = profile }
        }
        return out
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(flipKey, forKey: .flipKey)
        try c.encode(flipTapWindowMs, forKey: .flipTapWindowMs)
        try c.encode(showHints, forKey: .showHints)
        try c.encode(alwaysShowChoices, forKey: .alwaysShowChoices)
        try c.encode(offerUndoAfterCommit, forKey: .offerUndoAfterCommit)
        try c.encode(backspaceUnit, forKey: .backspaceUnit)
        try c.encode(graveTypesWon, forKey: .graveTypesWon)
        try c.encode(languageBias, forKey: .languageBias)
        try c.encode(eagerEnglishCommit, forKey: .eagerEnglishCommit)
        try c.encode(learningEnabled, forKey: .learningEnabled)
        try c.encode(learningPaused, forKey: .learningPaused)
        try c.encode(appProfiles, forKey: .appProfiles)
        try c.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
    }
}

// MARK: - Learning data on disk (written only by the IME; read by the host app)

/// One learned key string in one context. `votes` are exponentially decayed counts (60-day
/// half-life) as of `updatedAt`; read-time value = `votes[h] · 0.5^((now − updatedAt) / 60 d)`
/// (critique R7).
public struct LearningEntry: Sendable, Hashable, Codable {
    public var raw: String
    public var context: LanguageContext
    /// Keyed by `Hypothesis.key` ("K", "E", "M3").
    public var votes: [String: Double]
    public var updatedAt: Date

    public init(raw: String, context: LanguageContext, votes: [String: Double], updatedAt: Date) {
        self.raw = raw
        self.context = context
        self.votes = votes
        self.updatedAt = updatedAt
    }
}

/// `~/Library/Application Support/Duo/learning.json`.
public struct LearningSnapshot: Sendable, Hashable, Codable {
    public var version: Int = 1
    public var entries: [LearningEntry]

    public init(entries: [LearningEntry] = []) { self.entries = entries }
}
