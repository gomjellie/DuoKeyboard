// The choice bar's list of readings and choosing one (SPEC.md 4.11절).

import Foundation

/// What a digit key or a click on the choice bar did (SPEC.md 4.11절).
public enum ReadingChoice: Equatable, Sendable {
    /// The engine has no such bar now (it replaced the request the user saw): the key is text.
    case notOnBar
    /// The bar is current but the choice could not be made (the client cannot re-open committed
    /// Latin, or the marked text is gone). The key was aimed at the bar, so it is not text either.
    case refused
    /// The word changed to the chosen reading, or kept the one it showed.
    case chosen
}

extension CompositionEngine {
    /// Most readings the bar lists.
    static let maxCandidates = 5
    /// Readings further behind the best one than this (10 nats) in both modes are not listed,
    /// unless they are the shown reading, the flip key's target or the Latin-plus-ending reading
    /// of a choice.
    static let candidateFloor = 10_000

    /// The bar for `t`: its readings in display order, which one is shown, which one the flip key
    /// switches to, and the scores behind it. `nil` when there is nothing to choose.
    struct ChoiceList {
        var readings: [ChoiceReading]
        var choice: HUDChoice
        /// Prefix-mode scores, with learned Latin words carried to their endings.
        var prefix: HypothesisScores
        /// Final-mode scores (what a boundary would commit), with the same carry.
        var final: HypothesisScores
        /// The listed readings that change only the end of the word.
        var segments: [Segment]
        var selected: Int { choice.selected }
    }

    /// The readings the bar lists for `t`, in the order the flip key walks them.
    ///
    /// - First the word's original reading (what it showed before any flip), then the reading a
    ///   first flip switches to (R11: the other script, or a reading of the end of the word that
    ///   scores higher), then the rest best first by prefix-mode score (unscored ones last). The
    ///   order stays while the word does not change.
    /// - K, E and every M(b) the detector scored, without two that render alike.
    /// - With `segments` (default ``wantsSegments(_:)``), up to ``maxSegmentRows`` readings that change
    ///   only the end of the word (`segments(raw:context:committed:scored:)`).
    /// - Readings inconsistent with eagerly committed Latin only where the client can re-open it.
    /// - At most ``maxCandidates``; the original, the first flip's target, the R11 alternative, the
    ///   shown reading and a chosen Latin-plus-ending always stay.
    /// - The scores carry a Latin word's learned English to its endings (`userCounts` with
    ///   `carryLatinPrefixes`), so cmd로 rises on the bar; what is shown and committed does not.
    func choiceList(_ t: Token, _ shownScores: HypothesisScores, segments wanted: Bool? = nil) -> ChoiceList? {
        let original = ChoiceReading.whole(t.lockedOriginal ?? t.shown)
        let shown = ChoiceReading.whole(t.shown)
        let plain = userCounts(t.raw, t.context)
        let carried = userCounts(t.raw, t.context, carryLatinPrefixes: true)
        let prefix = carried == plain ? shownScores
            : detector.prefixScores(raw: t.raw, context: t.context, user: carried, biasKO: biasKO)
        let final = detector.choiceScores(raw: t.raw, context: t.context, user: carried, biasKO: biasKO)
        let otherScript = alternative(of: t.lockedOriginal ?? t.shown, raw: t.raw, in: prefix)
        let bestPrefix = prefix.best?.score ?? 0
        let bestFinal = final.best?.score ?? 0

        var segments: [Segment] = []
        // The end of a split is not split again: its bar walks its own readings back to the original.
        if !t.segmentTail, wanted ?? wantsSegments(t) {
            var texts: Set<String> = []
            for s in self.segments(raw: t.raw, context: t.context, committed: t.committed, scored: [prefix, final])
            where s.score >= bestFinal - Self.candidateFloor && texts.insert(s.text).inserted {
                segments.append(s)
                if segments.count == Self.maxSegmentRows { break }
            }
        }
        let first = segmentBeating(otherScript, in: segments, final: final, prefix: prefix)?.reading
            ?? otherScript.map(ChoiceReading.whole)

        var kept: [ChoiceReading] = [original]
        if let first { kept.append(first) }
        // When a reading of the end goes first, the other script's reading stays listed.
        if let otherScript { kept.append(.whole(otherScript)) }
        kept.append(shown)
        if let b = t.lockedLatin, b < t.count, !t.raw.contains("'") { kept.append(.whole(.mixed(latin: b))) }

        /// Prefix-mode scale for a reading of the end of the word (scored in final mode).
        func score(_ r: ChoiceReading) -> Int? {
            if case .whole(let h) = r, let s = prefix[h] { return s }
            return segments.first { $0.reading == r }.map { $0.score - bestFinal + bestPrefix }
        }
        var rows: [(reading: ChoiceReading, score: Int?, text: String)] = []
        func add(_ r: ChoiceReading) {
            if case .whole(let h) = r, !canChoose(t, h) { return }
            let text = segments.first { $0.reading == r }?.text ?? render(t.raw, r)
            if let i = rows.firstIndex(where: { $0.text == text }) {
                // Two readings that look the same: keep the one the bar must show.
                if kept.contains(r), !kept.contains(rows[i].reading) { rows[i] = (r, score(r), text) }
                return
            }
            rows.append((r, score(r), text))
        }
        for r in kept { add(r) }
        for entry in prefix.entries + final.entries {
            let close = prefix[entry.hypothesis].map { bestPrefix - $0 <= Self.candidateFloor } ?? false
                || final[entry.hypothesis].map { bestFinal - $0 <= Self.candidateFloor } ?? false
            if close { add(.whole(entry.hypothesis)) }
        }
        for s in segments { add(s.reading) }
        // The original and the first flip's target lead; the rest by score.
        let lead = rows.filter { $0.reading == original || $0.reading == first }
            .sorted { a, _ in a.reading == original }
        var rest = rows.filter { $0.reading != original && $0.reading != first }
        rest.sort { a, b in
            switch (a.score, b.score) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return Self.displayRank(a.reading) < Self.displayRank(b.reading)
            }
        }
        rows = lead + rest
        while rows.count > Self.maxCandidates, let i = rows.lastIndex(where: { !kept.contains($0.reading) }) {
            rows.remove(at: i)
        }
        guard rows.count >= 2, let selected = rows.firstIndex(where: { $0.reading == shown }) else { return nil }
        // The flip key walks the bar: the next reading, and from the last one back to the first.
        let alternate = (selected + 1) % rows.count
        let readings = rows.map { HUDReading(text: $0.text, language: $0.reading.language) }
        return ChoiceList(readings: rows.map(\.reading),
                          choice: HUDChoice(readings: readings, selected: selected, alternate: alternate,
                                            numbered: t.locked != nil || t.choicesRevealed),
                          prefix: prefix, final: final,
                          segments: segments.filter { s in rows.contains { $0.reading == s.reading } })
    }

    /// The reading the flip key switches `t` to: the next one on the bar (SPEC.md 4.11절), so a
    /// first flip goes to the other script (or to a likelier reading of the end of the word) and
    /// further flips walk the other readings and come back to the original. It is the bar the user
    /// sees (the right ⌘ press reveals it with the readings of the end of the word). Without a bar
    /// (one reading the client can choose), the R11 alternative, so the flip can still say why it
    /// cannot change the word.
    func flipTarget(_ t: Token, _ scores: HypothesisScores) -> ChoiceReading? {
        if let bar = choiceList(t, scores) { return bar.readings[bar.choice.alternate] }
        return alternative(of: t.lockedOriginal ?? t.shown, raw: t.raw, in: scores).map(ChoiceReading.whole)
    }

    /// A reading the token can switch to: consistent with the Latin committed eagerly, or the
    /// client can re-open that Latin.
    func canChoose(_ t: Token, _ h: Hypothesis) -> Bool {
        t.isConsistent(h) || clientProfile.canReplaceCommittedText
    }

    /// A reading on the bar was chosen with a digit key or a click (SPEC.md 4.11절).
    ///
    /// - The word being typed switches to that reading and keeps it, as after a flip. Choosing the
    ///   reading already shown keeps it too, and teaches it at the commit if the model would have
    ///   committed another one.
    /// - On the last word's bar, choosing the other reading flips that word.
    ///
    /// - Parameter shown: the request whose bar the user saw. A bar the engine has replaced since
    ///   (a hide debounce or fade-out still shows it) is not this bar.
    @discardableResult
    public func selectReading(at index: Int, on shown: HUDRequest, client: any TextClient) -> ReadingChoice {
        // A digit or a click between two flip-key presses makes them a chord, not a tap.
        tap.noteKeyDown()
        guard let request = hud, request == shown, barCanAct(request) else { return .notOnBar }
        switch request.content {
        case .alternative(let choice, _):
            guard choice.readings.indices.contains(index), let t = token, let scores = t.scores,
                  let bar = choiceList(t, scores), bar.choice == choice else { return .notOnBar }
            let target = bar.readings[index]
            hud = nil
            let marked = t.marked.isEmpty ? nil : client.markedRange()
            guard t.marked.isEmpty || marked != nil else {
                dropToken()
                return .refused
            }
            if case .whole(let target) = target, target == t.shown {
                var kept = t
                if kept.locked == nil {
                    kept.locked = target
                    kept.lockedOriginal = target
                    kept.lockedLatin = Self.latinCount(of: target, count: kept.count)
                }
                kept.keptByChoice = true
                token = kept
                hud = alternativeHUD(kept, pulse: false, isRepeat: false)
                return .chosen
            }
            return flipToken(t, to: target, markedRange: marked, checked: true, client: client) ? .chosen : .refused
        case .flipLastWord(let choice):
            guard choice.readings.indices.contains(index) else { return .notOnBar }
            guard index != choice.selected else { return .chosen }
            return chooseOtherReading(on: shown, client: client) ? .chosen : .refused
        case .oneShot, .cannotChange, .bilingualLine:
            return .notOnBar
        }
    }

    /// The bar index a digit chooses while the flip key (right ⌘ or right ⌥) is held on its own:
    /// ⌘1 … ⌘9 (SPEC.md 4.11절). `nil` for any other key, a repeat, or another modifier with it.
    public func readingChordIndex(_ event: KeyEvent) -> Int? {
        guard tap.isFlipKeyHeld, !event.isRepeat, case .character(let c) = event.key,
              let digit = c.wholeNumberValue, (1...9).contains(digit) else { return nil }
        let flag: KeyEvent.Modifiers = settings.flipKey == .rightOption ? .option : .command
        guard event.modifiers.intersection([.shift, .control, .option, .command]) == flag else { return nil }
        return digit - 1
    }

    /// The flip key went down while a word is typed: the word's bar comes up numbered, whether it
    /// had earned the HUD or not, so a digit chooses while the key is held (⌘3) and after a flip.
    /// The text does not change; releasing the key alone still flips.
    func revealChoices() {
        guard !literal, var t = token, !t.marked.isEmpty, !t.choicesRevealed else { return }
        t.choicesRevealed = true
        token = t
        if let request = alternativeHUD(t, pulse: false, isRepeat: false) { hud = request }
    }

    /// The keys a chosen reading confirms as Latin: all of them for E, the first `b` for M(b).
    static func latinCount(of h: Hypothesis, count: Int) -> Int? {
        switch h {
        case .english: count
        case .mixed(let b): b
        case .korean: nil
        }
    }

    /// After the user chose a Latin reading for the first `b` keys, each later key decides again
    /// between all-English and Latin plus a Korean ending: `cmd` (chosen as English) + `fh` reads
    /// cmd로, + `s` reads cmds.
    ///
    /// The ending must be whole Hangul syllables (a lone jamo is English typing on). Then Latin plus
    /// ending wins unless English leads it by more than the hysteresis; without a score for it (the
    /// Latin is no lexicon word), unless the keys still read best as English.
    func continueAfterLatinChoice(_ t: inout Token) {
        guard let b = t.lockedLatin, b < t.count, !t.raw.contains("'"),
              t.locked == .english || t.locked == .mixed(latin: b) else { return }
        let mixed = Hypothesis.mixed(latin: b)
        let wholeSyllables = render(t.raw, mixed).dropFirst(b).unicodeScalars.allSatisfy {
            (0xAC00...0xD7A3).contains($0.value)
        }
        let prefersMixed: Bool
        if !wholeSyllables {
            prefersMixed = false
        } else if let scores = t.scores, let m = scores[mixed], let e = scores[.english] {
            prefersMixed = m >= e - hysteresis
        } else if let scores = t.scores, let e = scores[.english], let best = scores.best {
            prefersMixed = best.score - e > hysteresis
        } else {
            prefersMixed = true
        }
        let next: Hypothesis = prefersMixed ? mixed : .english
        t.locked = next
        t.shown = next
    }
}
