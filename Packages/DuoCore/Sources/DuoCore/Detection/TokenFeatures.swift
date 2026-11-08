/// Scoring mode (docs/research/detection.md §1): `final` when the token is committed (`</s>`,
/// lexicon, terminator), `prefix` while it is still being typed.
enum ScoringMode: Sendable, Hashable {
    case final
    case prefix
}

/// The context-free per-token features of `detector.py` `features()` (docs/research/detection.md
/// §5.3). Scores for any context, terminator and user counts are derived from these without
/// touching the model again.
struct TokenFeatures: Sendable, Hashable {
    /// One surviving `M(b)` candidate.
    struct Mix: Sendable, Hashable {
        /// `b`: number of leading Latin characters.
        var latin: Int
        /// EN LM score of `low[0..<b]` with `</s>` (the Latin part is always complete).
        var enLM: Int
        var enLex: Int?
        var enCase: CasePattern
        /// `suffixFull[ks]` (final) or `suffixPrefix[ks]` (prefix).
        var suffix: Int?
        /// KO LM score of the Korean tail when the generic gate holds.
        var generic: Int?
        var rollover: Int
        var stray: Int
        /// `b ≥ MIX_MIN_LATIN` or the Latin part is all uppercase.
        var shortOK: Bool
    }

    var koLM: Int
    var koLex: Int?
    var koOrphans: Int
    var koRollover: Int
    var koStray: Int
    var enLM: Int
    var enLex: Int?
    var enCase: CasePattern
    var enNumUnit: Bool
    var mix: [Mix]
}

/// Byte views of one raw token, one byte per Unicode scalar: `raw` (non-ASCII scalars replaced by
/// `'`), `kno` (Korean normalisation), `low` (lowercased) and their LM symbol ids. Built once per
/// scoring call in a temporary (stack) allocation, so the scorer never touches `String` again.
struct TokenBytes {
    let count: Int
    let raw: UnsafePointer<UInt8>
    let kno: UnsafePointer<UInt8>
    let low: UnsafePointer<UInt8>
    let koSymbols: UnsafePointer<UInt8>
    let enSymbols: UnsafePointer<UInt8>
    /// The token contains `'` (or another character outside the letters), which disables `M(b)`.
    let hasNonLetter: Bool

    static func with<R>(_ string: String, _ body: (TokenBytes) -> R) -> R {
        let capacity = Swift.max(1, string.utf8.count)
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: capacity * 5) { buffer in
            let raw = buffer.baseAddress!
            let kno = raw + capacity, low = raw + 2 * capacity
            let ko = raw + 3 * capacity, en = raw + 4 * capacity
            var n = 0
            var nonLetter = false
            for scalar in string.unicodeScalars {
                let byte = scalar.isASCII ? UInt8(truncatingIfNeeded: scalar.value) : KeySymbols.otherByte
                if !KeySymbols.isLetter(byte) { nonLetter = true }
                raw[n] = byte
                n += 1
            }
            DubeolsikTables.normalizedKey.withUnsafeBufferPointer { normalized in
                KeySymbols.symbolForByte.withUnsafeBufferPointer { symbol in
                    var i = 0
                    while i < n {
                        let k = normalized[Int(raw[i])]
                        let l = KeySymbols.lowercased(raw[i])
                        kno[i] = k
                        low[i] = l
                        ko[i] = symbol[Int(k)]
                        en[i] = symbol[Int(l)]
                        i &+= 1
                    }
                }
            }
            return body(TokenBytes(count: n, raw: raw, kno: kno, low: low, koSymbols: ko, enSymbols: en,
                                   hasNonLetter: nonLetter))
        }
    }
}

/// The integer scorer of docs/research/detection.md §5 (`detector.py` `features` + `hyp_scores`).
struct DetectionScorer: Sendable {
    let model: DuoModel
    let params: DetectorParameters
    /// `USER_LOG2` (millibits) from `meta.userLog2Millibits`; never recomputed (critique V7).
    let userLog2: [Int]

    init(model: DuoModel) throws {
        self.model = model
        params = try DetectorParameters(model.meta.params)
        userLog2 = model.meta.userLog2Millibits
    }

    // MARK: Features

    /// `features(raw, final)` of `detector.py`.
    func features(_ t: TokenBytes, mode: ScoringMode) -> TokenFeatures {
        let n = t.count
        let final = mode == .final
        let m = model
        let (orphans, lone) = DubeolsikMachine.orphanStats(UnsafeBufferPointer(start: t.kno, count: n))
        let (rollover, stray) = Self.shiftCounts(t.raw, 0, n)
        let koLex = final ? m.koreanLexicon.value(hash: FNV1a64.hash(t.kno, n)) : nil
        let lowHash = FNV1a64.hash(t.low, n)
        let enLex = final ? m.englishLexicon.value(hash: lowHash) : nil
        let enCase = casePattern(t.raw, n)
        let enNumUnit = m.numberUnits.contains(t.low, n, hash: lowHash)
        let koOrphans = final ? orphans : orphans - (lone ? 1 : 0)
        let koSymbols = UnsafeBufferPointer(start: t.koSymbols, count: n)

        guard n >= 2, !t.hasNonLetter else {  // no M(b): one K pass and one E pass
            return TokenFeatures(
                koLM: m.korean.score(koSymbols, eos: final), koLex: koLex, koOrphans: koOrphans,
                koRollover: rollover, koStray: stray,
                enLM: m.english.score(UnsafeBufferPointer(start: t.enSymbols, count: n), eos: final), enLex: enLex,
                enCase: enCase, enNumUnit: enNumUnit, mix: [])
        }

        return CondCache.with(tokenLength: n) { cache in
            withUnsafeTemporaryAllocation(of: CharacterLM.History.self, capacity: n + 1) { histories in
                withUnsafeTemporaryAllocation(of: Int.self, capacity: n + 1) { prefix in
                    let ko = m.korean, en = m.english
                    let koLM = ko.score(koSymbols, eos: final, cache: &cache)

                    // One E pass gives the token's score and, lazily, `F[b]` for every Latin prefix.
                    var history = CharacterLM.History(contextLength: en.contextLength)
                    var total = 0
                    histories[0] = history
                    prefix[0] = 0
                    var i = 0
                    while i < n {
                        total += en.cond(history, t.enSymbols[i], cache: &cache)
                        history.append(t.enSymbols[i], contextLength: en.contextLength)
                        histories[i + 1] = history
                        prefix[i + 1] = total
                        i &+= 1
                    }
                    let enLM = final ? total + en.cond(history, KeySymbols.eos, cache: &cache) : total

                    var mix: [TokenFeatures.Mix] = []
                    let table = final ? m.suffixFull : m.suffixPrefix
                    var latinHash = FNV1a64.offsetBasis
                    var latinHasUpper = false
                    var latinAllUpper = true
                    var b = 0
                    while b < n - 1 {
                        b &+= 1
                        latinHash = (latinHash ^ UInt64(t.low[b - 1])) &* FNV1a64.prime
                        if KeySymbols.isUpper(t.raw[b - 1]) { latinHasUpper = true } else { latinAllUpper = false }
                        let tail = t.kno + b, tailCount = n - b
                        let suffix = table.value(tail, tailCount, hash: FNV1a64.hash(tail, tailCount))
                        // `lexEN[low[0..<b]]`, looked up at most once and only when needed.
                        var latinLex: Int?? = .none
                        var generic: Int?
                        // Generic tail gate (reordered cheapest first; every test is pure): a consonant
                        // key starts the tail, the Latin part has an uppercase letter or is an English
                        // word, and the tail has no orphan (a trailing lone consonant is fine in prefix mode).
                        if KeySymbols.isConsonantKey[Int(t.kno[b])] {
                            if !latinHasUpper { latinLex = .some(m.englishLexicon.value(hash: latinHash)) }
                            if latinHasUpper || latinLex! != nil {
                                let (o2, lone2) = DubeolsikMachine.orphanStats(UnsafeBufferPointer(start: tail, count: tailCount))
                                if (final ? o2 : o2 - (lone2 ? 1 : 0)) == 0 {
                                    generic = ko.score(UnsafeBufferPointer(start: t.koSymbols + b, count: tailCount),
                                                       eos: final, cache: &cache)
                                }
                            }
                        }
                        if suffix == nil && generic == nil { continue }
                        let lex = latinLex ?? m.englishLexicon.value(hash: latinHash)
                        let (r2, s2) = Self.shiftCounts(t.raw, b, n)
                        mix.append(TokenFeatures.Mix(
                            latin: b, enLM: prefix[b] + en.cond(histories[b], KeySymbols.eos, cache: &cache),
                            enLex: lex, enCase: casePattern(t.raw, b), suffix: suffix, generic: generic,
                            rollover: r2, stray: s2, shortOK: b >= params.mixMinLatin || latinAllUpper))
                    }
                    return TokenFeatures(koLM: koLM, koLex: koLex, koOrphans: koOrphans, koRollover: rollover,
                                         koStray: stray, enLM: enLM, enLex: enLex, enCase: enCase,
                                         enNumUnit: enNumUnit, mix: mix)
                }
            }
        }
    }

    /// `shift_counts(raw[start..<end])`: Shift on a key whose 두벌식 jamo ignores Shift, counted as
    /// rollover when a shifted `Q W E R T O P` is adjacent (inside the range), else as stray.
    @inline(__always)
    static func shiftCounts(_ raw: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> (rollover: Int, stray: Int) {
        var rollover = 0, stray = 0
        var i = start
        while i < end {  // `while`, not `for in`: ranges iterate slowly at -Onone
            let c = raw[i]
            if KeySymbols.isUpper(c), !KeySymbols.isShiftedQWERTOP(c) {
                if (i > start && KeySymbols.isShiftedQWERTOP(raw[i - 1]))
                    || (i + 1 < end && KeySymbols.isShiftedQWERTOP(raw[i + 1])) {
                    rollover += 1
                } else {
                    stray += 1
                }
            }
            i &+= 1
        }
        return (rollover, stray)
    }

    /// `case_pattern(s)` over the letters of `s[0..<count]`.
    @inline(__always)
    func casePattern(_ s: UnsafePointer<UInt8>, _ count: Int) -> CasePattern {
        var letters = 0, upper = 0
        var firstUpper = false, upperAfterFirst = false
        var i = 0
        while i < count {
            let c = s[i]
            i &+= 1
            guard KeySymbols.isLetter(c) else { continue }
            let isUpper = KeySymbols.isUpper(c)
            if letters == 0 { firstUpper = isUpper } else if isUpper { upperAfterFirst = true }
            letters += 1
            if isUpper { upper += 1 }
        }
        if upper == 0 { return .lower }
        if model.caseLexicon.contains(s, count, hash: FNV1a64.hash(s, count)) { return .exact }
        if letters >= 2 && upper == letters { return .allcaps }
        if firstUpper && !upperAfterFirst { return .initcap }
        return .mixed
    }

    // MARK: Hypothesis scores

    /// `hyp_scores` (docs/research/detection.md §5.4) plus the runtime extras: `biasKO` on `S_K`
    /// and the user bonus on every hypothesis, in both modes (critique R7, R8).
    func scores(_ f: TokenFeatures, mode: ScoringMode, context: LanguageContext, terminator: Terminator,
                user: UserCounts?, biasKO: Int) -> HypothesisScores {
        let p = params
        var ko: Int, en: Int
        switch mode {
        case .final:
            ko = Self.word(f.koLM + p.orphan * f.koOrphans, f.koLex, p.ngKO, p.lexKO)
            en = Self.word(f.enLM, f.enLex, p.ngEN, p.lexEN)
            switch terminator {
            case .digit: en += p.termDigitEN
            case .hyphen: en += p.termHyphenEN
            case .space, .punctuation: break
            }
        case .prefix:
            ko = f.koLM + p.orphan * f.koOrphans
            en = f.enLM
        }
        let prior = p.prior(context)
        ko += p.rollover * f.koRollover + p.stray * f.koStray + prior.korean + biasKO
        en += p.cost(f.enCase) + prior.english
        if context == .number && f.enNumUnit { en += p.numUnitEN }

        var entries: [ScoredHypothesis] = []
        entries.reserveCapacity(2 + f.mix.count)
        entries.append(ScoredHypothesis(.korean, ko))
        entries.append(ScoredHypothesis(.english, en))
        for x in f.mix {
            // A single lowercase letter takes table suffixes only (m에, h의).
            let short = !x.shortOK && context != .number
            if short && x.suffix == nil { continue }
            var fromTable = x.suffix.map { $0 + p.mix }
            if fromTable != nil, x.latin == 1, x.enCase != .lower, context != .english {
                fromTable! += p.mixInitial  // A씨, B양, C가
            }
            let fromLM = short ? nil : x.generic.map { $0 + p.mixGeneric }
            let tail: Int  // a Mix always has a table suffix, a generic tail, or both
            if let a = fromTable, let g = fromLM { tail = a >= g ? a : g } else { tail = fromTable ?? fromLM! }
            let s = Self.word(x.enLM, x.enLex, p.ngEN, p.lexEN) + p.cost(x.enCase) + tail
                + p.rollover * x.rollover + p.stray * x.stray + prior.english
            entries.append(ScoredHypothesis(.mixed(latin: x.latin), s))
        }
        if let user {
            for i in entries.indices { entries[i].score += userBonus(user[entries[i].hypothesis]) }
        }
        return HypothesisScores(entries)
    }

    /// `word(lm, lex, ng, lx)`: the better of the novel-word path and the lexicon path.
    @inline(__always)
    static func word(_ lm: Int, _ lex: Int?, _ ngOffset: Int, _ lexOffset: Int) -> Int {
        let a = lm + ngOffset
        guard let lex else { return a }
        let b = lex + lexOffset
        return a >= b ? a : b
    }

    /// `userBonus(n) = USER_UNIT · USER_LOG2[min(n, 15)] / 1000` (floor division, as in Python),
    /// with `USER_LOG2` read from `meta.userLog2Millibits`.
    func userBonus(_ count: Int) -> Int {
        let n = Swift.min(Swift.max(count, 0), userLog2.count - 1)
        return Self.floorDivide(params.userUnit * userLog2[n], 1000)
    }

    @inline(__always)
    static func floorDivide(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0) && ((a < 0) != (b < 0)) ? q - 1 : q
    }
}
