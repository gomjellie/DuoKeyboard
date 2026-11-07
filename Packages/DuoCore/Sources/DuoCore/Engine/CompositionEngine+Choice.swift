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
        var hypotheses: [Hypothesis]
        var choice: HUDChoice
        /// Prefix-mode scores, with learned Latin words carried to their endings.
        var prefix: HypothesisScores
        /// Final-mode scores (what a boundary would commit), with the same carry.
        var final: HypothesisScores
        var selected: Int { choice.selected }
    }

    /// The readings the bar lists for `t`, best first by prefix-mode score (unscored ones last).
    ///
    /// - K, E and every M(b) the detector scored, without two that render alike.
    /// - Readings inconsistent with eagerly committed Latin only where the client can re-open it.
    /// - At most ``maxCandidates``; the shown reading and the flip key's target always stay.
    /// - The scores carry a Latin word's learned English to its endings (`userCounts` with
    ///   `carryLatinPrefixes`), so cmd로 rises on the bar; what is shown and committed does not.
    func choiceList(_ t: Token, _ shownScores: HypothesisScores) -> ChoiceList? {
        guard let flipTarget = flipTarget(t, shownScores) else { return nil }
        let plain = userCounts(t.raw, t.context)
        let carried = userCounts(t.raw, t.context, carryLatinPrefixes: true)
        let prefix = carried == plain ? shownScores
            : detector.prefixScores(raw: t.raw, context: t.context, user: carried, biasKO: biasKO)
        let final = detector.choiceScores(raw: t.raw, context: t.context, user: carried, biasKO: biasKO)

        var kept: [Hypothesis] = [t.shown, flipTarget]
        if let b = t.lockedLatin, b < t.count, !t.raw.contains("'") { kept.append(.mixed(latin: b)) }

        let bestPrefix = prefix.best?.score ?? 0
        let bestFinal = final.best?.score ?? 0
        var rows: [(hypothesis: Hypothesis, score: Int?, text: String)] = []
        func add(_ h: Hypothesis) {
            guard canChoose(t, h) else { return }
            let text = render(t.raw, h)
            if let i = rows.firstIndex(where: { $0.text == text }) {
                // Two readings that look the same: keep the one the bar must show.
                if kept.contains(h), !kept.contains(rows[i].hypothesis) { rows[i] = (h, prefix[h], text) }
                return
            }
            rows.append((h, prefix[h], text))
        }
        for h in kept { add(h) }
        for entry in prefix.entries + final.entries {
            let close = prefix[entry.hypothesis].map { bestPrefix - $0 <= Self.candidateFloor } ?? false
                || final[entry.hypothesis].map { bestFinal - $0 <= Self.candidateFloor } ?? false
            if close { add(entry.hypothesis) }
        }
        rows.sort { a, b in
            switch (a.score, b.score) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return Self.displayRank(a.hypothesis) < Self.displayRank(b.hypothesis)
            }
        }
        while rows.count > Self.maxCandidates, let i = rows.lastIndex(where: { !kept.contains($0.hypothesis) }) {
            rows.remove(at: i)
        }
        guard rows.count >= 2, let selected = rows.firstIndex(where: { $0.hypothesis == t.shown }),
              let alternate = rows.firstIndex(where: { $0.hypothesis == flipTarget }), alternate != selected else {
            return nil
        }
        let readings = rows.map { HUDReading(text: $0.text, language: $0.hypothesis.language) }
        return ChoiceList(hypotheses: rows.map(\.hypothesis),
                          choice: HUDChoice(readings: readings, selected: selected, alternate: alternate),
                          prefix: prefix, final: final)
    }

    /// The reading the flip key switches `t` to: back to the original after a flip; from the
    /// original, back to the reading the user last chose (cmd로 after cmd + flip + fh); otherwise
    /// the R11 alternative.
    func flipTarget(_ t: Token, _ scores: HypothesisScores) -> Hypothesis? {
        if let locked = t.locked, let original = t.lockedOriginal {
            if locked != original { return original }
            if let back = t.lockedReturn, back != original, t.isWellFormed(back), canChoose(t, back),
               render(t.raw, back) != render(t.raw, original) {
                return back
            }
            return alternative(of: original, raw: t.raw, in: scores)
        }
        return alternative(of: t.shown, raw: t.raw, in: scores)
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
        guard !literal, let request = hud, request == shown else { return .notOnBar }
        switch request.content {
        case .alternative(let choice, _):
            guard choice.readings.indices.contains(index), let t = token, let scores = t.scores,
                  let bar = choiceList(t, scores), bar.choice == choice else { return .notOnBar }
            let target = bar.hypotheses[index]
            hud = nil
            let marked = t.marked.isEmpty ? nil : client.markedRange()
            guard t.marked.isEmpty || marked != nil else {
                dropToken()
                return .refused
            }
            if target == t.shown {
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
