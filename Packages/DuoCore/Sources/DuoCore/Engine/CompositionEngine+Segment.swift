// Readings that change only the end of a word, read back from the caret (SPEC.md 4.11절).

import Foundation

/// One reading on the choice bar (SPEC.md 4.11절).
enum ChoiceReading: Hashable {
    /// A reading of the whole word.
    case whole(Hypothesis)
    /// The first `head` keys stay Korean and the rest reads as `tail`, a reading of those keys as a
    /// word of their own (중간에 + english, 중간에 + english가). Choosing it commits the Korean part
    /// and starts a word with the rest.
    case split(head: Int, tail: Hypothesis)

    /// The language of the part the user reads last: the tail of a split.
    var language: ScriptLanguage {
        switch self {
        case .whole(let h): h.language
        case .split(_, let tail): tail.language
        }
    }
}

/// Prefix-mode scores of the keys a word had earlier, which a split reads its head from. Every
/// head of the word in progress was the whole word a few keys ago, so typing fills this as it goes.
struct PrefixMemo {
    var context: LanguageContext?
    var biasKO = 0
    var scores: [String: HypothesisScores] = [:]
}

extension CompositionEngine {
    /// Fewest keys on each side of a split.
    static let segmentMinimumKeys = 2
    /// Longest end of a word read back from the caret.
    static let maxSegmentKeys = 16
    /// The keys before a split must read as their language by this much in prefix mode (the best
    /// other reading of those keys is this far behind).
    static let segmentHeadMargin = 3_000
    /// Words with at least this many keys get the readings of their end on every key, so the bar can
    /// offer one by itself. Shorter words get them once the flip key is used.
    static let segmentAutoKeys = 10
    /// A reading of the end of the word goes first on the bar when it beats the shown reading and
    /// the other script's reading by this much; it brings the bar up by itself (a word of
    /// ``segmentAutoKeys`` keys or more) and the last word's bar after a commit when it beats the
    /// shown reading by this much.
    static let segmentMargin = 6_000
    /// Most readings of the end of a word on the bar.
    static let maxSegmentRows = 2

    /// A reading that changes only the end of a word, scored on the final-mode scale of the whole
    /// word: the prefix-mode score of the head plus the final-mode score of the end as a word.
    struct Segment {
        var reading: ChoiceReading
        var text: String
        var score: Int
        /// The end does not read in Korean as consonants only or as ㅜ, ㅠ and ㅡ only. Laughter,
        /// initials and tears (ㅋㅋ, ㅇㅋ, ㄱㄱ, ㅠㅠ, ㅜ, ㅡㅡ) are Korean chat that the whole-word score
        /// charges as orphans, so such a reading is listed but never goes first or brings a bar up.
        /// Other vowel-only ends are English (ok as ㅐㅏ, ui as ㅕㅑ).
        var mayLead: Bool
        /// Keys in the head, the head's prefix-mode score, and how the end is read and scored.
        var split: Int
        var headScore: Int
        var tail: Hypothesis
        var tailContext: LanguageContext
    }

    /// Whether `segment` beats the shown reading by ``segmentMargin`` in prefix mode, the mode of a
    /// word still being typed. Final mode charges a syllable the next key completes as an orphan
    /// (그런데요즘 + ㅇ), so a bar that comes up by itself while typing compares in prefix mode.
    func segmentLeadsWhileTyping(_ segment: Segment, raw: String, shownScore: Int) -> Bool {
        guard segment.mayLead else { return false }
        let tail = String(raw.dropFirst(segment.split))
        let scores = detector.prefixScores(raw: tail, context: segment.tailContext,
                                           user: userCounts(tail, segment.tailContext), biasKO: biasKO)
        guard let score = scores[segment.tail] else { return false }
        return segment.headScore + score - shownScore >= Self.segmentMargin
    }

    /// Readings of the end of a word are worth computing: the user used the flip key in this word,
    /// or the word is long. A reading chosen on the bar with a click adds none, so the bar it was
    /// chosen on keeps its rows.
    func wantsSegments(_ t: Token) -> Bool {
        t.choicesRevealed || t.count >= Self.segmentAutoKeys
    }

    /// The readings of `raw` that change only its end, best first:
    /// - Korean head + the end as a reading of its own that beats Korean there (중간에english,
    ///   중간에english가), where the head reads as Korean. Only with nothing committed eagerly.
    /// - Latin head + the end as Korean (M(b)) where the detector does not score M(b) (its Latin is
    ///   no lexicon word and has no capital, and its end is no suffix: regex쓰면), the head
    ///   reads as English, and the end renders as two or more whole Hangul syllables that read as
    ///   Korean better than as anything else.
    ///
    /// - Parameters:
    ///   - committed: keys committed eagerly as Latin (a Latin head must cover them).
    ///   - scored: the whole word's scores; an M(b) they have is a reading of its own already.
    func segments(raw: String, context: LanguageContext, committed: Int, scored: [HypothesisScores]) -> [Segment] {
        let n = raw.count
        guard n >= 2 * Self.segmentMinimumKeys, !raw.contains("'") else { return [] }
        let keys = Array(raw)
        var found: [Segment] = []
        for s in max(Self.segmentMinimumKeys, n - Self.maxSegmentKeys)...(n - Self.segmentMinimumKeys) {
            let head = String(keys[..<s])
            let headScores = memoizedPrefixScores(head, context)
            guard let top = headScores.best else { continue }
            let runnerUp = headScores.best(where: { $0 != top.hypothesis })?.score ?? Int.min / 2
            guard top.score - runnerUp >= Self.segmentHeadMargin else { continue }
            let tail = String(keys[s...])
            switch top.hypothesis {
            case .korean where committed == 0:
                // The head ends on a whole syllable, unless it is all jamo (ㅋㅋㅋ): 중간ㅇ + penglish
                // splits a syllable the keys after it complete.
                let headText = render(head, .korean)
                guard let last = headText.unicodeScalars.last,
                      (0xAC00...0xD7A3).contains(last.value)
                        || !headText.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) })
                else { continue }
                let scores = detector.choiceScores(raw: tail, context: .korean, user: userCounts(tail, .korean),
                                                   biasKO: biasKO)
                guard let korean = scores[.korean] else { continue }
                // ㅜ, ㅠ, ㅡ
                let tailText = render(tail, .korean).unicodeScalars
                let mayLead = !tailText.allSatisfy { (0x3131...0x314E).contains($0.value) }
                    && !tailText.allSatisfy { [0x315C, 0x3160, 0x3161].contains($0.value) }
                for e in scores.entries where e.hypothesis != .korean && e.score > korean {
                    found.append(Segment(reading: .split(head: s, tail: e.hypothesis),
                                         text: headText + render(tail, e.hypothesis),
                                         score: top.score + e.score, mayLead: mayLead, split: s,
                                         headScore: top.score, tail: e.hypothesis, tailContext: .korean))
                }
            case .english where s >= committed || clientProfile.canReplaceCommittedText:
                let mixed = Hypothesis.mixed(latin: s)
                guard !scored.contains(where: { $0[mixed] != nil }) else { continue }
                // Two syllables or more: one-syllable endings are particles, which the detector
                // scores itself from its suffix table.
                let ending = render(tail, .korean)
                guard ending.count >= 2,
                      ending.unicodeScalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) }) else { continue }
                let scores = detector.choiceScores(raw: tail, context: .english, user: userCounts(tail, .english),
                                                   biasKO: biasKO)
                guard let korean = scores[.korean], korean > scores.best(where: { $0 != .korean })?.score ?? Int.min
                else { continue }
                found.append(Segment(reading: .whole(mixed), text: head + ending, score: top.score + korean,
                                     mayLead: true, split: s, headScore: top.score, tail: .korean,
                                     tailContext: .english))
            default:
                continue
            }
        }
        return found.sorted { $0.score > $1.score }
    }

    /// The readings of the end of `raw` a bar lists, best first: within ``candidateFloor`` of the best
    /// whole reading in final mode, one per text, at most ``maxSegmentRows``. The composing bar, the
    /// commit and flip (b) use the same list, so the last word offers what its bar would have.
    func listedSegments(raw: String, context: LanguageContext, committed: Int, prefix: HypothesisScores?,
                        final: HypothesisScores) -> [Segment] {
        let floor = (final.best?.score ?? 0) - Self.candidateFloor
        var texts: Set<String> = []
        var listed: [Segment] = []
        for s in segments(raw: raw, context: context, committed: committed, scored: [prefix, final].compactMap { $0 })
        where s.score >= floor && texts.insert(s.text).inserted {
            listed.append(s)
            if listed.count == Self.maxSegmentRows { break }
        }
        return listed
    }

    /// `prefixScores(raw, context)`, kept for the rest of the word (SPEC.md 4.11절).
    func memoizedPrefixScores(_ raw: String, _ context: LanguageContext) -> HypothesisScores {
        if prefixMemo.context != context || prefixMemo.biasKO != biasKO {
            prefixMemo = PrefixMemo(context: context, biasKO: biasKO)
        }
        if let scores = prefixMemo.scores[raw] { return scores }
        let scores = prefixScores(raw, context)
        prefixMemo.scores[raw] = scores
        return scores
    }

    /// Keeps the scores of the word as typed so far for a later split of a longer word.
    func rememberPrefixScores(_ t: Token) {
        guard let scores = t.scores else { return }
        if prefixMemo.context != t.context || prefixMemo.biasKO != biasKO {
            prefixMemo = PrefixMemo(context: t.context, biasKO: biasKO)
        }
        prefixMemo.scores[t.raw] = scores
    }

    /// `text` has a lone jamo before the run of jamo it ends with: as Korean it is broken inside
    /// (중간에두히ㅑ노), not only at its end (재밌는데ㅠ, 고마워요ㅎㅎ).
    static func hasJamoBeforeItsEnd(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        let isJamo = { (u: Unicode.Scalar) in (0x3131...0x3163).contains(u.value) }
        var end = scalars.count
        while end > 0, isJamo(scalars[end - 1]) { end -= 1 }
        return scalars[..<end].contains(where: isJamo)
    }

    /// The text of `reading` for `raw`.
    func render(_ raw: String, _ reading: ChoiceReading) -> String {
        switch reading {
        case .whole(let h):
            return render(raw, h)
        case .split(let s, let tail):
            return render(String(raw.prefix(s)), .korean) + render(String(raw.dropFirst(s)), tail)
        }
    }

    /// The best reading of the end of the word that a flip offers instead of `alternative` (the
    /// other script's whole reading), if any. On the final-mode scale it must beat both `shown`
    /// (the word's original reading, or the reading it was committed in) and `alternative` by
    /// ``segmentMargin``. A word that reads well keeps its flip to the other script (그러면 →
    /// rmfjaus, not 그럼us), a short word whose other reading is a word of its own keeps it (chat
    /// stays first over 초at), while 30 keys of gibberish lose to their English end.
    func segmentBeating(_ alternative: Hypothesis?, shown: Hypothesis, in segments: [Segment],
                        final: HypothesisScores, prefix: HypothesisScores? = nil) -> Segment? {
        guard let top = segments.first(where: \.mayLead) else { return nil }
        func score(_ h: Hypothesis) -> Int? {
            final[h] ?? prefix.flatMap { p in p[h].map { $0 - (p.best?.score ?? 0) + (final.best?.score ?? 0) } }
        }
        if let s = score(shown), top.score - s < Self.segmentMargin { return nil }
        guard let alternative, let s = score(alternative) else { return top }
        return top.score - s >= Self.segmentMargin ? top : nil
    }

    // MARK: Choosing a split

    /// Commits the Korean start of `t` and keeps typing its end as a word of its own in the reading
    /// `tail` (SPEC.md 4.11절 14): 중간에두히ㅑ노 → 중간에 + english. The start is committed as Korean
    /// even where the word showed another reading. The end is locked, so English then a Korean
    /// ending works as after any Latin choice (english가). Backspace over the whole end re-opens the
    /// start where committed text can be replaced, as after a capital (4.3절 8).
    func splitToken(_ t: Token, head s: Int, tail h: Hypothesis, client: any TextClient) -> Bool {
        guard t.committed == 0, s > 0, s < t.count else { return false }
        // The join goes on to the whole word's reading after the split on its bar, so the flip key
        // reaches every reading of the bar and comes back to the original.
        let original = t.lockedOriginal ?? t.shown
        var joinReading = original
        if let scores = t.scores, let bar = choiceList(t, scores),
           let i = bar.readings.firstIndex(of: .split(head: s, tail: h)) {
            for k in 1..<bar.readings.count {
                if case .whole(let w) = bar.readings[(i + k) % bar.readings.count] {
                    joinReading = w
                    break
                }
            }
        }
        let memo = prefixMemo
        var head = t
        head.raw = String(t.raw.prefix(s))
        head.count = s
        head.shown = .korean
        head.locked = .korean
        head.lockedOriginal = nil
        head.lockedLatin = nil
        head.keptByChoice = false
        head.languageLock = nil
        head.scores = nil
        var reopened = head
        reopened.locked = nil
        reopened.choicesRevealed = false
        reopened.segmentTail = false
        let headText = render(head.raw, .korean)

        // The start is part of a word: no final-mode scoring, learning, chip or flip case (b), as
        // for the word a capital ends (4.3절 8).
        token = head
        commitToken(terminator: .space, boundaryLength: 0, client: client)
        startToken(at: t.lastKeyAt)
        guard var tail = token else { return false }
        tail.raw = String(t.raw.dropFirst(s))
        tail.count = t.count - s
        tail.shown = h
        tail.locked = h
        tail.lockedOriginal = .korean
        tail.lockedLatin = Self.latinCount(of: h, count: tail.count)
        tail.choicesRevealed = t.choicesRevealed
        tail.segmentTail = true
        tail.scores = prefixScores(tail.raw, tail.context)
        if clientProfile.canReplaceCommittedText {
            tail.splitHead = SplitHead(token: reopened, text: headText, joinReading: joinReading,
                                       wholeOriginal: original, memo: memo)
        }
        setMarked(display(tail, h), in: &tail, client: client)
        token = tail
        notify(.flipped(to: h.language))
        hud = alternativeHUD(tail, pulse: false, isRepeat: false)
        return true
    }

    /// What the end of a split turns into when it goes back to its original Korean reading: the
    /// whole word again, locked to the reading after the split on its bar (SPEC.md 4.11절 14).
    /// `nil` where the start cannot be re-opened or the joined word would pass ``maxTokenLength``:
    /// the end alone turns Korean then.
    func joinTarget(of t: Token) -> (raw: String, reading: Hypothesis)? {
        guard t.segmentTail, let head = t.splitHead, let reading = head.joinReading,
              clientProfile.canReplaceCommittedText, head.token.count + t.count <= Self.maxTokenLength else {
            return nil
        }
        let raw = head.token.raw + t.raw
        if case .mixed(let b) = reading, b >= raw.count || raw.contains("'") { return (raw, .english) }
        return (raw, reading)
    }

    /// The end of a split goes back to its original Korean reading: where committed text can be
    /// replaced, it joins its Korean start again as `joinTarget(of:)` says (사진 + jpg →
    /// tkwlsjpg when the bar listed it after 사진jpg). Returns `false` (the end alone turns Korean)
    /// where the start cannot be re-opened.
    func joinSegmentTail(_ t: Token, client: any TextClient) -> Bool {
        guard let target = joinTarget(of: t), let original = t.splitHead?.wholeOriginal,
              var joined = reopenSplitHead(of: t, appending: t.raw, locked: target.reading, client: client) else {
            return false
        }
        joined.lockedOriginal = original
        joined.lockedLatin = Self.latinCount(of: joined.shown, count: joined.count)
        joined.choicesRevealed = t.choicesRevealed
        token = joined
        notify(.flipped(to: joined.shown.language))
        hud = alternativeHUD(joined, pulse: false, isRepeat: false)
        return true
    }
}
