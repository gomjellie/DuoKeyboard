/// The incremental display rule of docs/research/detection.md §5.6: prefix-mode scores plus
/// hysteresis, starting from the context language ("context init"). This is the reference the
/// composition engine's own state machine must agree with.
public enum DisplayHysteresis {
    /// What the display shows before the first key: English after an English word, Korean
    /// otherwise, so even the first key has to beat the context language by `HYST`.
    public static func initialHypothesis(for context: LanguageContext) -> Hypothesis {
        context == .english ? .english : .korean
    }

    /// One keystroke of hysteresis: keep `shown` unless it no longer exists (an `M(b)` that became
    /// invalid) or the best reading beats it by more than `hysteresis` millinats. Ties keep the
    /// earlier candidate (`HypothesisScores.best`). To restrict the choice (for example to the
    /// readings still consistent with an eager English commit), pass only those entries.
    public static func next(shown: Hypothesis, scores: HypothesisScores, hysteresis: Int) -> Hypothesis {
        guard let best = scores.best else { return shown }
        guard let current = scores[shown] else { return best.hypothesis }
        return best.hypothesis != shown && best.score - current > hysteresis ? best.hypothesis : shown
    }
}

/// One keystroke of a display trace.
public struct DisplayStep: Hashable, Sendable {
    /// Prefix-mode scores of the keys typed so far.
    public var scores: HypothesisScores
    /// The reading on screen after this key.
    public var shown: Hypothesis
    /// `render(prefix, shown)`: the marked text.
    public var text: String

    public init(scores: HypothesisScores, shown: Hypothesis, text: String) {
        self.scores = scores
        self.shown = shown
        self.text = text
    }
}

extension LanguageDetector {
    /// Replays `raw` one key at a time through the §5.6 display rule (the `incremental[]` vectors):
    /// prefix scores of every prefix, the hysteresis state starting from the context language, and
    /// the rendered marked text.
    ///
    /// - Parameter hysteresis: margin in millinats; defaults to the model's `HYST` (1500, the DET
    ///   value, if the detector has none).
    public func displayTrace(raw: String, context: LanguageContext, user: UserCounts? = nil, biasKO: Int = 0,
                             hysteresis: Int? = nil) -> [DisplayStep] {
        let margin = hysteresis ?? parameters["HYST"] ?? 1500
        var shown = DisplayHysteresis.initialHypothesis(for: context)
        var steps: [DisplayStep] = []
        steps.reserveCapacity(raw.count)
        var prefix = ""
        for ch in raw {
            prefix.append(ch)
            let scores = prefixScores(raw: prefix, context: context, user: user, biasKO: biasKO)
            shown = DisplayHysteresis.next(shown: shown, scores: scores, hysteresis: margin)
            steps.append(DisplayStep(scores: scores, shown: shown, text: render(raw: prefix, shown)))
        }
        return steps
    }
}
