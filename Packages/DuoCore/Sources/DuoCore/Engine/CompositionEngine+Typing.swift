// Letters, the apostrophe, literal triggers and Backspace (docs/SPEC.md §4.3–§4.6).

import Foundation

extension CompositionEngine {
    /// Keys per token before a forced commit (ux-spec §4.1).
    static let maxTokenLength = 32
    /// Fewest keys in a token before English may be committed early (see `shouldEagerCommit`).
    static let eagerMinimumKeys = 3
    /// One-key tokens that are words in both scripts get the HUD without a second key (critique R12).
    static let collisionKeys: Set<String> = ["a", "e", "i", "o", "u", "x"]

    // MARK: Letters (§4.3)

    func handleLetter(_ key: Keystroke, event: KeyEvent, client: any TextClient) -> Bool {
        if let t = token, t.count >= Self.maxTokenLength {
            commitToken(terminator: .space, boundaryLength: 0, client: client)
        }
        if token == nil { startToken(at: event.timestamp) }
        // A new letter ends flip case (b) for the previous word.
        lastCommit = nil
        guard var t = token else { return false }

        let wasFullyCommitted = t.isFullyCommitted
        t.raw.append(key.latin)
        t.count += 1
        t.lastKeyAt = event.timestamp

        if wasFullyCommitted {
            // Eager-E state (§4.3.5): reopen only when Korean can attach to the committed Latin.
            // M(b) does not exist for tokens with an apostrophe (detection.md §4), so don't ask.
            guard !t.raw.contains("'"), detector.canAttachKorean(raw: t.raw, latinCount: t.committed) else {
                // The app types the letter itself (ABC layout via overrideKeyboard). No scoring needed.
                t.committed += 1
                t.scores = nil
                token = t
                if appUppercasesLetters {
                    // The app would type it in capitals (Caps Lock as the flip key): type it here.
                    insert(String(key.latin), client: client)
                    return true
                }
                return false
            }
            t.scores = prefixScores(t.raw, t.context)
            t.shown = .english
            let changed = t.applyHysteresis(hysteresis)
            setMarked(display(t, t.shown), in: &t, client: client)
            token = t
            hud = alternativeHUD(t, pulse: changed, isRepeat: event.isRepeat)
            return true
        }

        t.scores = prefixScores(t.raw, t.context)
        let changed = t.applyHysteresis(hysteresis) && t.count >= 2
        if shouldEagerCommit(t) {
            insert(display(t, .english), client: client)
            t.committed = t.count
            t.marked = ""
            token = t
            return true
        }
        setMarked(display(t, t.shown), in: &t, client: client)
        token = t
        hud = alternativeHUD(t, pulse: changed, isRepeat: event.isRepeat)
        return true
    }

    func startToken(at time: TimeInterval) {
        let ctx = context.contextForNewToken
        let lock = oneShot
        oneShot = nil
        let shown: Hypothesis = switch lock ?? (ctx == .english ? .english : .korean) {
        case .english: .english
        case .korean: .korean
        }
        token = Token(context: ctx, shown: shown, languageLock: lock, at: time)
    }

    /// §4.3.6: commit English early once it is certain, so autocomplete sees real text.
    ///
    /// Besides the SPEC conditions (setting on, client can replace, not locked, E shown, prefix
    /// margin ≥ `Margins.eagerCommit` over every consistent reading), an eager commit must be one a
    /// boundary would make now and must not take a possible Korean tail away (critique U7). Measured
    /// on DET's mixed dev-chat set through a mirror of this engine on the shipped model, the
    /// SPEC-only rule commits 7 more tokens wrongly than no eager commit (99.35 % vs 99.86 %);
    /// with these three guards it matches the no-eager accuracy and still commits ~71 % of each
    /// English word of three or more keys before the boundary:
    /// - at least ``eagerMinimumKeys`` keys: one or two keys say little (`W` of 쪽 after English);
    /// - the last key is not a consonant key where Korean could attach (the re-open gate at
    ///   `b = count − 1`): it stays marked so `M(b)` stays consistent (`reject` + 된);
    /// - the final-mode argmax is E as well (R2): prefix mode charges a lone ㅠ/ㅜ as an orphan
    ///   vowel, but `bb`/`nn` are ㅠㅠ/ㅜㅜ in final mode.
    /// The final scoring runs only on keys that pass every cheaper condition.
    func shouldEagerCommit(_ t: Token) -> Bool {
        guard settings.eagerEnglishCommit, clientProfile.replacement != .none, !t.isLocked,
              t.shown == .english, t.count >= Self.eagerMinimumKeys,
              let scores = t.scores, let english = scores[.english] else { return false }
        if let other = scores.best(where: { $0 != .english && t.isConsistent($0) }),
           english - other.score < Margins.eagerCommit {
            return false
        }
        if !t.raw.contains("'"), detector.canAttachKorean(raw: t.raw, latinCount: t.count - 1) { return false }
        let final = detector.finalScores(raw: t.raw, context: t.context, terminator: .space,
                                         user: userCounts(t.raw, t.context), biasKO: biasKO)
        return final.best(where: t.isConsistent)?.hypothesis == .english
    }

    /// §4.3.7, §4.11: the choice bar while the token is marked: the shown reading, the one the
    /// flip key switches to, and any other likely reading, best first.
    ///
    /// It earns the HUD when a listed reading is within ``Margins/hudCandidates`` of the shown one
    /// (P ≥ 5 %), or when the user chose the reading (a flip or the bar), and the token has at least
    /// two keys (or is one of the 1-key collision words).
    func alternativeHUD(_ t: Token, pulse: Bool, isRepeat: Bool) -> HUDRequest? {
        guard settings.showHints, !t.marked.isEmpty, let prefix = t.scores,
              let bar = choiceList(t, prefix) else { return nil }
        // Close in prefix mode, or, for Latin plus an ending only, in final mode: prefix mode charges
        // no end of word, so 층로 buries cmd로 there; final mode scores an unfinished syllable as a
        // finished word (감ㅅ → rkat), so only M(b) may earn the bar on its final score.
        func closeness(_ scores: HypothesisScores, onlyMixed: Bool) -> Bool {
            let shownScore = scores[t.shown] ?? scores.best?.score ?? 0
            return bar.hypotheses.enumerated().contains { i, h in
                guard i != bar.selected, let s = scores[h] else { return false }
                if onlyMixed, case .mixed = h {} else if onlyMixed { return false }
                return shownScore - s <= Margins.hudCandidates
            }
        }
        let close = closeness(bar.prefix, onlyMixed: false) || closeness(bar.final, onlyMixed: true)
        let eligible = !isRepeat && (t.locked != nil || close)
            && (t.count >= 2 || Self.collisionKeys.contains(t.raw.lowercased()))
        return HUDRequest(content: .alternative(bar.choice, eligible: eligible), anchor: .markedText, pulse: pulse)
    }

    // MARK: Apostrophe (§4.4)

    func handleApostrophe(_ event: KeyEvent, client: any TextClient) -> Bool {
        guard var t = token else { return passThrough(event, terminator: .punctuation, client: client) }
        let englishAllowed = (t.locked == nil || t.locked == .english)
            && (t.languageLock == nil || t.languageLock == .english)
        if t.count < Self.maxTokenLength, englishAllowed {
            let candidate = t.raw + "'"
            let scores = prefixScores(candidate, t.context)
            if scores.best?.hypothesis == .english {
                let wasFullyCommitted = t.isFullyCommitted
                let changed = t.shown != .english
                t.raw = candidate
                t.count += 1
                t.lastKeyAt = event.timestamp
                t.scores = scores
                t.shown = .english
                if wasFullyCommitted {
                    // Nothing is marked: the app types the apostrophe.
                    t.committed += 1
                    token = t
                    return false
                }
                if shouldEagerCommit(t) {
                    insert(display(t, .english), client: client)
                    t.committed = t.count
                    t.marked = ""
                    token = t
                    return true
                }
                setMarked(display(t, .english), in: &t, client: client)
                token = t
                hud = alternativeHUD(t, pulse: changed, isRepeat: event.isRepeat)
                return true
            }
        }
        return passThrough(event, terminator: .punctuation, client: client)
    }

    // MARK: Characters, literal triggers (§4.5, §4.6)

    func handleCharacter(_ ch: Character, event: KeyEvent, colonAfterEnglish: Bool,
                         client: any TextClient) -> Bool {
        switch ch {
        case "'":
            return handleApostrophe(event, client: client)
        case "`" where settings.graveTypesWon:
            commitToken(terminator: .punctuation, boundaryLength: 1, trailing: "₩", client: client)
            context.notePassed(event.key)
            return true
        case "@", "_":
            if let t = token {
                // A reading chosen with the flip key (or a one-shot) wins over the literal rule:
                // ㅠ_ㅠ needs `b`, flip, `_`. The generic commit below keeps it.
                if !t.koreanChosen {
                    commitLiteral(client: client)
                    context.notePassed(event.key)
                    beginLiteral()
                    return false
                }
            } else if ch == "@", context.atWordStart {
                beginLiteral()
            }
        case "/", "~", "\\", ":":
            if token == nil,
               context.atWordStart || (ch == "/" && (colonAfterEnglish || context.dotRun > 0)) {
                beginLiteral()
                return passThrough(event, terminator: .punctuation, client: client)
            }
        case ".":
            if let t = token, t.raw.lowercased() == "www", !t.koreanChosen {
                commitLiteral(client: client)
                context.notePassed(event.key)
                beginLiteral()
                return false
            }
            if token == nil, context.atWordStart || context.dotRun > 0 {
                let run = context.dotRun + 1
                _ = passThrough(event, terminator: .punctuation, client: client)
                context.dotRun = run <= 2 ? run : 0
                return false
            }
        default:
            break
        }
        let terminator: Terminator = ch.isASCII && ch.isNumber ? .digit : ch == "-" ? .hyphen : .punctuation
        let committed = commitToken(terminator: terminator, boundaryLength: String(ch).utf16.count, client: client)
        context.notePassed(event.key)
        if committed == .english {
            if ch == "." { context.dotAfterEnglishToken = true }
            if ch == ":" { context.colonAfterEnglishToken = true }
        }
        return false
    }

    /// `@`, `_` and `www.` turn the token into literal Latin (§4.6): commit the E render whatever
    /// the detector showed, never learn, never offer a flip. A Korean reading the user chose
    /// explicitly (`Token.koreanChosen`) is not overruled.
    func commitLiteral(client: any TextClient) {
        guard let t = token else { return }
        token = nil
        let text = display(t, .english)
        if !text.isEmpty || !t.marked.isEmpty { insert(text, client: client) }
        lastCommit = nil
        context.noteCommitted(.english)
        notify(.committed(language: .english))
    }

    // MARK: Backspace (§4.5.4)

    func handleBackspace(_ event: KeyEvent, client: any TextClient) -> Bool {
        guard var t = token else {
            backspaceAfterCommit(client: client)
            return false
        }
        if t.committed == t.count {
            // Everything typed so far is committed Latin: the app deletes the last letter.
            t.raw.removeLast()
            t.count -= 1
            t.committed -= 1
            t.scores = nil
            token = t.count == 0 ? nil : t
            return false
        }
        let unit = settings.backspaceUnit == .gulja ? syllableKeyCount(t) : 1
        let n = min(t.count - t.committed, unit)
        t.raw.removeLast(n)
        t.count -= n
        t.lastKeyAt = event.timestamp
        if t.count == t.committed {
            client.setMarkedText("", replacementRange: nil)
            t.marked = ""
            if t.count == 0 {
                token = nil
                return true
            }
            t.scores = nil
            t.keepShownIfPossible()
            token = t
            return true
        }
        t.scores = prefixScores(t.raw, t.context)
        t.keepShownIfPossible()
        setMarked(display(t, t.shown), in: &t, client: client)
        token = t
        hud = alternativeHUD(t, pulse: false, isRepeat: event.isRepeat)
        return true
    }

    /// Backspace with nothing composing: if it deletes the boundary right after the last commit,
    /// the word stays flippable and the chip comes back (ux-spec §5.4); otherwise it deletes into
    /// the word (or elsewhere) and flip case (b) ends.
    private func backspaceAfterCommit(client: any TextClient) {
        guard let lc = lastCommit, isFresh(lc), var end = lc.endLocation else { return }
        guard lc.boundaryLength > 0, let sel = client.selectedRange(), sel.length == 0 else {
            lastCommit = nil
            return
        }
        if clientProfile.replacement == .beforeCaretOnly {
            // Terminal: the end recorded at commit can trail the shell's echo (qa-2). Re-anchor
            // from the caret, which sits after the boundary this Backspace is about to delete.
            let wordEnd = sel.location - lc.boundaryLength
            guard wordEnd - lc.length >= 0,
                  client.string(in: NSRange(location: wordEnd - lc.length, length: lc.length)) == lc.text else {
                lastCommit = nil
                return
            }
            end = wordEnd
            lastCommit?.endLocation = wordEnd
        } else if sel.location != end + lc.boundaryLength {
            lastCommit = nil
            return
        }
        if settings.offerUndoAfterCommit, clientProfile.canReplaceCommittedText {
            hud = lastWordChoiceHUD(lc, start: end - lc.length)
        }
    }

    /// Keys forming the last syllable block of the marked Korean part (Backspace unit 글자).
    func syllableKeyCount(_ t: Token) -> Int {
        let start: Int
        switch t.shown {
        case .english: return 1
        case .korean: start = t.committed
        case .mixed(let b): start = max(b, t.committed)
        }
        let tail = Array(t.raw.dropFirst(start))
        guard tail.count > 1 else { return 1 }
        let target = String(render(String(tail), .korean).dropLast())
        for j in 1...tail.count where render(String(tail.dropLast(j)), .korean) == target {
            return j
        }
        return 1
    }
}
