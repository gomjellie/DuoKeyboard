// The flip key (SPEC.md §4.7).

import Foundation

extension CompositionEngine {
    /// Flip the current token / last word / next word (SPEC.md §4.7).
    ///
    /// (a) a word is in progress: show its other reading and lock it (a second flip returns);
    /// (b) the caret is right after the last commit: replace that word (verified first);
    /// (c) otherwise: arm a one-shot language for the next word (Direct: toggle Bilingual for the line).
    public func flip(client: any TextClient) {
        flip(client: client, at: nil)
    }

    /// - Parameter time: timestamp of the event that triggered the flip; `nil` (menu, tests) always
    ///   re-checks that the client still has our marked text.
    func flip(client: any TextClient, at time: TimeInterval?) {
        hud = nil
        if literal {
            // Only the word whose boundary started L can change (op.gg/), and a change ends L.
            guard lastWordChangesInLiteral, let lc = lastCommit, isFresh(lc),
                  flipLastCommit(lc, client: client) else { return }
            if lastCommit?.hypothesis != lc.hypothesis { endLiteral() }
            return
        }

        if var t = token {
            var markedRange: NSRange?
            var checked = false
            if !t.marked.isEmpty, time.map({ $0 - t.lastKeyAt > 1 }) ?? true {
                markedRange = client.markedRange()
                checked = true
            }
            if checked, markedRange == nil {
                dropToken()
            } else {
                // Every flip key flips to what the right ⌘ press reveals (SPEC.md 4.7절 a).
                t.choicesRevealed = true
                flipToken(t, markedRange: markedRange, checked: checked, client: client)
                return
            }
        }

        if let lc = lastCommit, isFresh(lc), flipLastCommit(lc, client: client) { return }
        flipNextWord()
    }

    // MARK: The choice bar

    /// The other reading on the choice bar was clicked (SPEC.md §4.11): flip the word the bar
    /// belongs to, as the flip key does. A click arrives outside any key event, so when that word is
    /// gone nothing happens: the click never arms the next word's language.
    ///
    /// - Parameter shown: the request whose bar was clicked. The panel can still show a bar the
    ///   engine has replaced (a hide debounce or fade-out); such a click is ignored.
    /// - Returns: whether a word changed.
    @discardableResult
    public func chooseOtherReading(on shown: HUDRequest, client: any TextClient) -> Bool {
        guard let request = hud, request == shown, barCanAct(request) else { return false }
        switch request.content {
        case .alternative:
            hud = nil
            guard let t = token else { return false }
            let marked = t.marked.isEmpty ? nil : client.markedRange()
            guard t.marked.isEmpty || marked != nil else {
                dropToken()
                return false
            }
            return flipToken(t, markedRange: marked, checked: true, client: client)
        case .flipLastWord:
            hud = nil
            guard let lc = lastCommit else { return false }
            guard isFresh(lc), flipLastCommit(lc, client: client) else {
                // The bar still offered the switch (it outlived the flip window under the pointer,
                // or the caret moved): say why nothing happened.
                if hud == nil { hud = cannotChangeHUD(anchor: .caret) }
                return false
            }
            guard let flipped = lastCommit, flipped.hypothesis != lc.hypothesis, let end = flipped.endLocation else {
                return false
            }
            endLiteral()
            // Keep the bar up with the selection moved, so the user sees the change and can undo it.
            hud = lastWordChoiceHUD(flipped, start: end - flipped.length)
            return true
        case .oneShot, .cannotChange, .bilingualLine:
            return false
        }
    }

    // MARK: (a) the token being composed

    /// - Parameter explicitTarget: the reading chosen on the bar; `nil` for the flip key's target.
    /// - Returns: whether the token changed to another reading.
    @discardableResult
    func flipToken(_ token: Token, to explicitTarget: ChoiceReading? = nil, markedRange knownMarked: NSRange?,
                   checked: Bool, client: any TextClient) -> Bool {
        var t = token
        if t.scores == nil { t.scores = prefixScores(t.raw, t.context) }
        guard let scores = t.scores, let reading = explicitTarget ?? flipTarget(t, scores) else { return false }
        let target: Hypothesis
        switch reading {
        case .whole(let h):
            target = h
        case .split(let head, let tail):
            return splitToken(t, head: head, tail: tail, client: client)
        }
        if t.segmentTail, target == t.lockedOriginal, joinSegmentTail(t, client: client) { return true }
        if t.lockedOriginal == nil { t.lockedOriginal = t.shown }

        if t.committed > 0, !t.isConsistent(target) {
            // The Latin committed by eager E must be re-opened: verify it, end the marked tail, then
            // mark the new reading over the committed Latin.
            guard clientProfile.canReplaceCommittedText else {
                // The client would ignore the range and add the new reading after the old one.
                hud = cannotChangeHUD(anchor: t.marked.isEmpty ? .caret : .markedText)
                return false
            }
            let marked = checked ? knownMarked : (t.marked.isEmpty ? nil : client.markedRange())
            let c = t.committed
            guard let anchor = marked?.location ?? client.selectedRange()?.location, anchor >= c,
                  client.string(in: NSRange(location: anchor - c, length: c)) == String(t.committedPrefix) else {
                hud = cannotChangeHUD(anchor: t.marked.isEmpty ? .caret : .markedText)
                return false
            }
            let text = render(t.raw, target)
            // NSTextView ignores a replacement range while text is marked, and TextEdit does not
            // end a composition on an empty mark or insert: commit the tail as it is, then mark the
            // new reading over the committed Latin and the tail.
            if marked != nil { client.insertText(t.marked, replacementRange: nil) }
            client.setMarkedText(text, replacementRange: NSRange(location: anchor - c, length: c + (marked?.length ?? 0)))
            t.marked = text
            t.committed = 0
        } else {
            setMarked(display(t, target), in: &t, client: client)
        }
        t.locked = target
        t.shown = target
        t.lockedLatin = Self.latinCount(of: target, count: t.count)
        t.keptByChoice = false
        t.languageLock = nil
        self.token = t
        notify(.flipped(to: target.language))
        hud = alternativeHUD(t, pulse: false, isRepeat: false)
        return true
    }

    // MARK: (b) the word just committed

    /// Returns `false` when the caret is not at the word, so the flip means "next word" instead.
    private func flipLastCommit(_ word: LastCommit, client: any TextClient) -> Bool {
        var lc = word
        guard let end = lc.endLocation else {
            hud = cannotChangeHUD(anchor: .caret)
            return true
        }
        guard let sel = client.selectedRange() else {
            hud = cannotChangeHUD(anchor: .caret)
            return true
        }
        // Where the word is now. Clients that report exact positions must still have the caret at
        // the word or right after its boundary. Terminal reports the caret only once the shell has
        // echoed, so the end recorded at commit time can trail by a character or two; there the
        // word is measured back from the caret, and the content check below decides.
        let candidates: [NSRange]
        if clientProfile.replacement == .beforeCaretOnly {
            guard sel.length == 0 else { return false }
            candidates = [
                NSRange(location: sel.location - lc.length - lc.boundaryLength, length: lc.length + lc.boundaryLength),
                NSRange(location: sel.location - lc.length, length: lc.length),
            ]
        } else {
            let start = end - lc.length
            guard sel.length == 0, sel.location == end || sel.location == end + lc.boundaryLength, start >= 0 else {
                return false
            }
            // Replace word + boundary up to the caret, so the caret stays after the boundary in
            // every client (NSTextView puts it after the inserted text).
            candidates = [NSRange(location: start, length: sel.location - start)]
        }
        // The caret is at the word. A client that ignores replacement ranges (Monaco) would add
        // the new reading after the old one: refuse before reading or writing anything.
        guard clientProfile.canReplaceCommittedText else {
            hud = cannotChangeHUD(anchor: .caret)
            return true
        }
        var match: (range: NSRange, suffix: String)?
        for candidate in candidates where candidate.location >= 0 {
            if let current = client.string(in: candidate), let suffix = Self.suffix(of: current, after: lc.text) {
                match = (candidate, suffix)
                break
            }
        }
        guard let (range, suffix) = match else {
            hud = cannotChangeHUD(anchor: .caret)
            return true
        }
        lc = checkSegments(lc)
        let start = range.location
        client.insertText(lc.alternativeText + suffix, replacementRange: range)

        // Learning: undo what this word recorded so far, then vote for the new reading (+3), or
        // restore the original commit's votes when this flips back.
        var updated = lc
        for vote in lc.appliedVotes { learning.cancel(vote) }
        var votes: [LearningVote] = []
        if lc.alternative == .whole(lc.committedHypothesis) {
            votes = lc.committedVotes.map {
                learning.record(raw: $0.raw, context: $0.context, hypothesis: $0.hypothesis, votes: $0.amount)
            }
        } else if lc.learnable, canLearnNow, case .whole(let alternative) = lc.alternative {
            // A reading of only the end of the word is no reading of these keys: nothing to learn.
            votes = [learning.record(raw: lc.raw, context: lc.context, hypothesis: alternative,
                                     votes: LearningStore.flipVotes)]
        }
        let learningChanged = !lc.appliedVotes.isEmpty || !votes.isEmpty

        updated.appliedVotes = votes
        updated.hypothesis = lc.alternative
        updated.alternative = lc.hypothesis
        updated.text = lc.alternativeText
        updated.alternativeText = lc.text
        updated.length = lc.alternativeText.utf16.count
        updated.endLocation = start + updated.length
        updated.time = clock()
        lastCommit = updated
        context.previousLanguage = lc.alternative.language

        notify(.flipped(to: lc.alternative.language))
        if learningChanged { notify(.learningChanged) }
        return true
    }

    /// `text` minus its leading `word`, or `nil` if it does not start with `word` (UTF-16 exact).
    static func suffix(of text: String, after word: String) -> String? {
        let ns = text as NSString
        let len = (word as NSString).length
        guard ns.length >= len, ns.substring(to: len) == word else { return nil }
        return ns.substring(from: len)
    }

    // MARK: (c) nothing to flip

    private func flipNextWord() {
        if effectiveProfile == .direct {
            bilingualLine.toggle()
            hud = bilingualLine ? Self.bilingualBadge : nil
            return
        }
        if oneShot != nil {
            oneShot = nil
            return
        }
        let language: ScriptLanguage = context.contextForNewToken == .english ? .korean : .english
        oneShot = language
        hud = HUDRequest(content: .oneShot(language), anchor: .caret, immediate: true, lifetime: 0.9)
    }

    func cannotChangeHUD(anchor: HUDRequest.Anchor) -> HUDRequest {
        HUDRequest(content: .cannotChange, anchor: anchor, immediate: true, lifetime: 1.2)
    }
}
