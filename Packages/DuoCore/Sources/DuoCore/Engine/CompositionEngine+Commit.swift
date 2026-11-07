// Committing a token (docs/SPEC.md §4.8).

import Foundation

extension CompositionEngine {
    /// How long the last word's choice bar stays up while nothing is typed. Long enough to reach it
    /// with the pointer; the next key hides it anyway, and the HUD holds it while the pointer is on it.
    static let chipLifetime: TimeInterval = 4
    /// How long after a commit the word can still be flipped (case b).
    static let lastCommitLifetime: TimeInterval = 30

    /// Final-commits the token, if any, with one `insertText` (docs/SPEC.md §4.8).
    ///
    /// - Parameters:
    ///   - terminator: the boundary that ended the token (final mode).
    ///   - boundaryLength: UTF-16 length the app will insert for that boundary.
    ///   - reason: set for commits without a key of their own (`commit(_:client:)`).
    ///   - trailing: text the engine itself appends in the same insert (`₩`).
    /// - Returns: the committed reading, or `nil` when nothing was composing.
    @discardableResult
    func commitToken(terminator: Terminator, boundaryLength: Int, reason: CommitReason? = nil,
                     trailing: String = "", client: any TextClient) -> Hypothesis? {
        guard let t = token else {
            if !trailing.isEmpty { insert(trailing, client: client) }
            return nil
        }
        token = nil

        // 1. Choose: a flip's lock, else the final-mode argmax among the allowed readings.
        let final: HypothesisScores?
        let h: Hypothesis
        if let locked = t.locked {
            final = nil
            h = locked
        } else {
            let scores = detector.finalScores(raw: t.raw, context: t.context, terminator: terminator,
                                              user: userCounts(t.raw, t.context), biasKO: biasKO)
            final = scores
            h = scores.best(where: t.isAllowed)?.hypothesis ?? (t.isAllowed(t.shown) ? t.shown : .english)
        }
        let fullText = render(t.raw, h)
        let text = String(fullText.dropFirst(t.committed)) + trailing
        if !text.isEmpty || !t.marked.isEmpty { insert(text, client: client) }

        // The word's alternative and how close it came (final mode; a locked word offers its original).
        let alternative: Hypothesis?
        var margin: Int?
        if let final {
            alternative = self.alternative(of: h, raw: t.raw, in: final)
            if let score = final[h], let other = final.best(where: { $0 != h }) { margin = score - other.score }
        } else if let original = t.lockedOriginal, original != h {
            alternative = original
        } else {
            alternative = t.scores.flatMap { self.alternative(of: h, raw: t.raw, in: $0) }
        }

        // 4. Learning (critique R7).
        let learnable = reason != .secureInput && t.count >= 2 && effectiveProfile != .direct
        var votes: [LearningVote] = []
        if learnable, canLearnNow {
            if let locked = t.locked {
                if let original = t.lockedOriginal, locked != original {
                    votes.append(learning.record(raw: t.raw, context: t.context, hypothesis: locked,
                                                 votes: LearningStore.flipVotes))
                } else if t.keptByChoice, let would = detector.finalScores(
                    raw: t.raw, context: t.context, terminator: terminator, user: userCounts(t.raw, t.context),
                    biasKO: biasKO).best?.hypothesis, would != locked {
                    // The shown reading kept on the bar against what a boundary would commit: an
                    // explicit correction (층로 kept while cmd로 had become the model's choice).
                    votes.append(learning.record(raw: t.raw, context: t.context, hypothesis: locked,
                                                 votes: LearningStore.flipVotes))
                }
            } else if let lock = t.languageLock {
                // A one-shot language that overruled the detector is an explicit correction.
                if let best = final?.best, best.hypothesis.language != lock {
                    votes.append(learning.record(raw: t.raw, context: t.context, hypothesis: h,
                                                 votes: LearningStore.flipVotes))
                }
            } else if let margin, margin <= Margins.hudAlternative {
                votes.append(learning.record(raw: t.raw, context: t.context, hypothesis: h,
                                             votes: LearningStore.implicitVotes))
            }
        }

        // 2. Record `lastCommit` for flip case (b); one `selectedRange()` call, only at commits.
        // Monaco reports positions but ignores replacement ranges: the end is still recorded, so a
        // flip with the caret away from the word means "next word" there too (case c).
        let keepsCommit = reason == nil || reason == .commitComposition
        let canReplace = clientProfile.canReplaceCommittedText
        var end: Int?
        if keepsCommit, clientProfile.replacement != .none, alternative != nil,
           let caret = client.selectedRange()?.location {
            end = caret - trailing.utf16.count
        }
        if keepsCommit, let alternative {
            lastCommit = LastCommit(
                text: fullText, length: fullText.utf16.count, raw: t.raw, context: t.context, hypothesis: h,
                alternative: alternative, alternativeText: render(t.raw, alternative), endLocation: end,
                boundaryLength: trailing.isEmpty ? boundaryLength : trailing.utf16.count, time: clock(),
                clientBundleID: clientProfile.bundleIdentifier, committedHypothesis: h, committedVotes: votes,
                appliedVotes: votes, learnable: learnable)
        } else {
            lastCommit = nil
        }

        // 3. "Never silently different" (critique R2): chip after a surprising or uncertain commit.
        if reason == nil, settings.offerUndoAfterCommit, canReplace, let end, !t.isLocked, let lc = lastCommit {
            let surprising = render(t.raw, t.shown) != fullText
            let uncertain = margin.map { $0 <= Margins.uncertainCommit } ?? false
            if surprising || uncertain {
                hud = lastWordChoiceHUD(lc, start: end - lc.length)
            }
        }

        // 5. Context for the next token.
        context.noteCommitted(h.language)
        notify(.committed(language: h.language))
        if !votes.isEmpty { notify(.learningChanged) }
        return h
    }

    /// The choice bar for the word just committed; `start` is its document location.
    func lastWordChoiceHUD(_ lc: LastCommit, start: Int) -> HUDRequest {
        HUDRequest(content: .flipLastWord(choice(current: (lc.hypothesis, lc.text),
                                                 other: (lc.alternative, lc.alternativeText))),
                   anchor: .location(start), immediate: true, lifetime: Self.chipLifetime)
    }

    /// Learning is on and not paused.
    var canLearnNow: Bool { settings.learningEnabled && !settings.learningPaused }

    func isFresh(_ lc: LastCommit) -> Bool {
        lc.clientBundleID == clientProfile.bundleIdentifier && clock() - lc.time <= Self.lastCommitLifetime
    }
}
