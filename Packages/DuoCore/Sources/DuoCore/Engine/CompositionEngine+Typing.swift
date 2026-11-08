// Letters, the apostrophe, literal triggers and Backspace (SPEC.md §4.3–§4.6).

import Foundation

extension CompositionEngine {
    /// Keys per token before a forced commit (ux-spec §4.1).
    static let maxTokenLength = 32
    /// Fewest keys in a token before English may be committed early (see `shouldEagerCommit`).
    static let eagerMinimumKeys = 3
    /// One-key tokens that are words in both scripts get the HUD without a second key (critique R12).
    static let collisionKeys: Set<String> = ["a", "e", "i", "o", "u", "x"]
    /// Prefix margin of K over every other reading before a capital may end the word (SPEC.md 4.3절 8).
    /// On the shipped model, Korean heads that end with a capital score ≥ 12.4 nats (한, 삼성, 회사,
    /// 그런데), camelCase heads ≤ 10.6 nats (to 새, do 애, did 양, db 유, cnt 츠, z, e, d).
    static let latinSplitMargin = 11_000
    /// Prefix margin of K over the allowed readings of a word a capital started, at which the capital
    /// was a stray Shift and the word joins the Korean word again (G in 안녕하세요). On the shipped
    /// model, such words pass 8 nats by their 2nd to 5th key; Latin ones stay ≤ 1.7 nats (A를,
    /// SDI가, API를, B마트, A군).
    static let latinMergeMargin = 6_000

    // MARK: Letters (§4.3)

    func handleLetter(_ key: Keystroke, event: KeyEvent, client: any TextClient) -> Bool {
        if let t = token, t.count >= Self.maxTokenLength,
           startsLatinWord(key, after: t) || !carryLastSyllable(of: t, before: key, at: event.timestamp, client: client) {
            commitToken(terminator: .space, boundaryLength: 0, client: client)
        }
        if var t = token, startsLatinWord(key, after: t) {
            // The capital is not a word end: commit what is on screen, without final-mode scoring,
            // learning or a chip, and keep it to re-open (Backspace, a stray Shift).
            let head = SplitHead(token: t, text: render(t.raw, t.shown))
            if t.locked == nil { t.locked = t.shown }
            token = t
            commitToken(terminator: .space, boundaryLength: 0, client: client)
            hud = nil
            startToken(at: event.timestamp)
            token?.latinStart = true
            if clientProfile.canReplaceCommittedText { token?.splitHead = head }
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
            continueAfterLatinChoice(&t)
            let changed = t.applyHysteresis(hysteresis)
            setMarked(display(t, t.shown), in: &t, client: client)
            token = t
            hud = alternativeHUD(t, pulse: changed, isRepeat: event.isRepeat)
            return true
        }

        t.scores = prefixScores(t.raw, t.context)
        if t.latinStart, t.count >= 2, let scores = t.scores, let k = scores[.korean],
           let best = scores.best(where: t.isAllowed), k - best.score >= Self.latinMergeMargin,
           let merged = reopenSplitHead(of: t, appending: t.raw, client: client) {
            // The capital was a stray Shift inside the Korean word.
            token = merged
            hud = alternativeHUD(merged, pulse: true, isRepeat: event.isRepeat)
            return true
        }
        continueAfterLatinChoice(&t)
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

    /// SPEC.md 4.3절 2: when `key` would change the last syllable of a word at ``maxTokenLength`` keys
    /// that reads Korean (K, or M(b) with Korean before that syllable), the word commits all but that
    /// syllable as shown, and the syllable's keys start the next word (감서 + ㅇ → 감성, 영화 + ㅈ →
    /// 영홪 + ㅣ → 영화지). Returns `false` and changes nothing otherwise: a key that starts a new
    /// syllable leaves nothing to carry, and a carried syllable alone reads worse (같음 + ㅋ as dmaz).
    func carryLastSyllable(of t: Token, before key: Keystroke, at time: TimeInterval, client: any TextClient) -> Bool {
        let h = t.locked ?? t.shown
        let koreanStart: Int
        switch h {
        case .english: return false
        case .korean: koreanStart = 0
        case .mixed(let b): koreanStart = b
        }
        guard t.committed == 0, let last = t.raw.last, last.isASCII, last.isLetter else { return false }
        let korean = String(t.raw.dropFirst(koreanStart))
        let blocks = HangulAutomaton.render(raw: korean).keyCounts
        let next = HangulAutomaton.render(raw: korean + String(key.latin)).keyCounts
        guard next.count != blocks.count + 1 || !next.starts(with: blocks),
              let carry = blocks.last, t.count - carry > koreanStart else { return false }
        // The head is committed as shown, like a word a capital ended (4.3절 8): no final-mode
        // scoring, learning, chip or flip case (b) for a part of a word.
        var head = t
        head.raw = String(t.raw.prefix(t.count - carry))
        head.count = t.count - carry
        head.locked = h
        head.lockedOriginal = nil
        head.keptByChoice = false
        head.scores = nil
        token = head
        commitToken(terminator: .space, boundaryLength: 0, client: client)
        hud = nil
        startToken(at: time)
        token?.raw = String(t.raw.suffix(carry))
        token?.count = carry
        token?.languageLock = t.languageLock
        return true
    }

    /// SPEC.md 4.3절 8: a capital on a key whose 두벌식 jamo has no shifted form (A–Z but Q W E R T O P) is
    /// Latin, since Shift there types the same jamo. After a Korean word it ends that word: no reading
    /// puts Latin after Korean (한A, 삼성SDI, 그런데API를).
    ///
    /// The word must read as Korean: chosen so by the user, or shown as K with a prefix margin of
    /// ``latinSplitMargin`` (camelCase heads such as to or do read as 새 or 애 by less). Not after
    /// another capital: Shift still held from a shifted jamo (했 + D for 했어) is a roll-over. Not when
    /// the word with the capital reads as English (GitHub, iOS).
    func startsLatinWord(_ key: Keystroke, after t: Token) -> Bool {
        guard key.shift, !key.shiftIsMeaningfulInKorean, t.count > 0, !t.isFullyCommitted,
              let previous = t.raw.last, !previous.isUppercase,
              t.locked?.language != .english, t.languageLock != .english else { return false }
        if !t.koreanChosen {
            guard t.shown == .korean else { return false }
            let head = t.scores ?? prefixScores(t.raw, t.context)
            guard let k = head[.korean] else { return false }
            if let other = head.best(where: { $0 != .korean }), k - other.score < Self.latinSplitMargin { return false }
        }
        let scores = prefixScores(t.raw + String(key.latin), t.context)
        return scores.best(where: t.isAllowed)?.hypothesis != .english
    }

    /// Re-opens the Korean word a capital split off (SPEC.md 4.3절 8) as one marked word: the
    /// committed word plus `raw` (the keys typed after it that belong to it, or none). Only where
    /// committed text can be replaced, and only if the word is still right before the marked text.
    func reopenSplitHead(of tail: Token, appending raw: String, client: any TextClient) -> Token? {
        guard let head = tail.splitHead, clientProfile.canReplaceCommittedText else { return nil }
        let marked = tail.marked.isEmpty ? nil : client.markedRange()
        let length = head.text.utf16.count
        guard let anchor = marked?.location ?? client.selectedRange()?.location, anchor >= length,
              client.string(in: NSRange(location: anchor - length, length: length)) == head.text else { return nil }
        var t = head.token
        t.raw += raw
        t.count = t.raw.count
        t.committed = 0
        t.lastKeyAt = tail.lastKeyAt
        t.scores = prefixScores(t.raw, t.context)
        t.keepShownIfPossible()
        let text = display(t, t.shown)
        // NSTextView ignores a replacement range while text is marked, and TextEdit does not end a
        // composition on an empty mark or insert: commit the tail as it is, then mark the word over
        // the committed word and the tail.
        if marked != nil { client.insertText(tail.marked, replacementRange: nil) }
        client.setMarkedText(text, replacementRange: NSRange(location: anchor - length,
                                                             length: length + (marked?.length ?? 0)))
        t.marked = text
        return t
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

    /// §4.3.7, §4.11: the choice bar while the token is marked: the word's readings in the order
    /// the flip key walks them.
    ///
    /// It earns the HUD on any key but an autorepeat when `alwaysShowChoices` is on, when the user
    /// chose the reading (a flip or the bar) or pressed the flip key, or when a listed reading is
    /// within ``Margins/hudCandidates`` of the shown one (P ≥ 5 %) and the token has at least two
    /// keys (or is one of the 1-key collision words).
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
        let likely = (closeness(bar.prefix, onlyMixed: false) || closeness(bar.final, onlyMixed: true))
            && (t.count >= 2 || Self.collisionKeys.contains(t.raw.lowercased()))
        let eligible = !isRepeat && (settings.alwaysShowChoices || t.locked != nil || t.choicesRevealed || likely)
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
            if t.count == 0, let head = reopenSplitHead(of: t, appending: "", client: client) {
                // The capital that split the word is gone: the Korean word is composing again.
                token = head
                hud = alternativeHUD(head, pulse: false, isRepeat: event.isRepeat)
                return true
            }
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
