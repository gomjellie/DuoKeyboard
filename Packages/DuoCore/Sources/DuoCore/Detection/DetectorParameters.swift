/// The tuned scoring constants of `meta.params` (docs/research/detection.md §6), in millinats.
/// The model file is the only source of truth for them (critique R8).
struct DetectorParameters: Sendable, Hashable {
    var ngKO, lexKO, ngEN, lexEN: Int
    var orphan, rollover, stray: Int
    var caseLower, caseInitcap, caseAllcaps, caseMixed, caseExact: Int
    var mix, mixMinLatin, mixGeneric, mixInitial: Int
    var termDigitEN, termHyphenEN: Int
    var priorStartKO, priorStartEN, priorKOKO, priorKOEN, priorENKO, priorENEN, priorNumKO, priorNumEN: Int
    var numUnitEN: Int
    var hysteresis: Int
    var userUnit: Int

    /// Reads every key; a missing one means the file does not belong to this scorer.
    init(_ params: [String: Int]) throws {
        func p(_ key: String) throws -> Int {
            guard let v = params[key] else { throw DuoModelError.corrupt("meta.params lacks \(key)") }
            return v
        }
        ngKO = try p("NG_KO"); lexKO = try p("LEX_KO"); ngEN = try p("NG_EN"); lexEN = try p("LEX_EN")
        orphan = try p("ORPHAN"); rollover = try p("ROLLOVER"); stray = try p("STRAY")
        caseLower = try p("CASE_LOWER"); caseInitcap = try p("CASE_INITCAP"); caseAllcaps = try p("CASE_ALLCAPS")
        caseMixed = try p("CASE_MIXED"); caseExact = try p("CASE_EXACT")
        mix = try p("MIX"); mixMinLatin = try p("MIX_MIN_LATIN"); mixGeneric = try p("MIX_GENERIC")
        mixInitial = try p("MIX_INITIAL")
        termDigitEN = try p("TERM_DIGIT_EN"); termHyphenEN = try p("TERM_HYPHEN_EN")
        priorStartKO = try p("PRIOR_START_KO"); priorStartEN = try p("PRIOR_START_EN")
        priorKOKO = try p("PRIOR_KO_KO"); priorKOEN = try p("PRIOR_KO_EN")
        priorENKO = try p("PRIOR_EN_KO"); priorENEN = try p("PRIOR_EN_EN")
        priorNumKO = try p("PRIOR_NUM_KO"); priorNumEN = try p("PRIOR_NUM_EN")
        numUnitEN = try p("NUM_UNIT_EN")
        hysteresis = try p("HYST")
        userUnit = try p("USER_UNIT")
    }

    /// `PRIOR[ctx]` for the Korean and English readings.
    func prior(_ context: LanguageContext) -> (korean: Int, english: Int) {
        switch context {
        case .start: (priorStartKO, priorStartEN)
        case .korean: (priorKOKO, priorKOEN)
        case .english: (priorENKO, priorENEN)
        case .number: (priorNumKO, priorNumEN)
        }
    }

    /// `CASE[pattern]`.
    func cost(_ pattern: CasePattern) -> Int {
        switch pattern {
        case .lower: caseLower
        case .initcap: caseInitcap
        case .allcaps: caseAllcaps
        case .mixed: caseMixed
        case .exact: caseExact
        }
    }
}

/// The English case pattern of a token (docs/research/detection.md §5.3).
enum CasePattern: String, Sendable, Hashable {
    /// No uppercase letter.
    case lower
    /// First letter uppercase, the rest lowercase ("I" is initcap).
    case initcap
    /// At least two letters, all uppercase.
    case allcaps
    /// Anything else.
    case mixed
    /// The exact string is in the case lexicon (iOS, GitHub, API).
    case exact
}
