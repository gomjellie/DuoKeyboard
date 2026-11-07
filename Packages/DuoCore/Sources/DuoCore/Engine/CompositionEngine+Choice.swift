// The choice bar's list of readings (docs/SPEC.md 4.11절).

import Foundation

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
        /// Prefix-mode scores.
        var prefix: HypothesisScores
        /// Final-mode scores (what a boundary would commit).
        var final: HypothesisScores
        var selected: Int { choice.selected }
    }

    /// The readings the bar lists for `t`, best first by prefix-mode score (unscored ones last).
    ///
    /// - K, E and every M(b) the detector scored, without two that render alike.
    /// - Readings inconsistent with eagerly committed Latin only where the client can re-open it.
    /// - At most ``maxCandidates``; the shown reading and the flip key's target always stay.
    func choiceList(_ t: Token, _ shownScores: HypothesisScores) -> ChoiceList? {
        guard let flipTarget = flipTarget(t, shownScores) else { return nil }
        let prefix = shownScores
        let final = detector.choiceScores(raw: t.raw, context: t.context, user: userCounts(t.raw, t.context),
                                          biasKO: biasKO)

        let kept: [Hypothesis] = [t.shown, flipTarget]

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

    /// The reading the flip key switches `t` to: back to the original after a flip, otherwise the
    /// R11 alternative.
    func flipTarget(_ t: Token, _ scores: HypothesisScores) -> Hypothesis? {
        if let locked = t.locked, let original = t.lockedOriginal {
            if locked != original { return original }
            return alternative(of: original, raw: t.raw, in: scores)
        }
        return alternative(of: t.shown, raw: t.raw, in: scores)
    }

    /// A reading the token can switch to: consistent with the Latin committed eagerly, or the
    /// client can re-open that Latin.
    func canChoose(_ t: Token, _ h: Hypothesis) -> Bool {
        t.isConsistent(h) || clientProfile.canReplaceCommittedText
    }
}
