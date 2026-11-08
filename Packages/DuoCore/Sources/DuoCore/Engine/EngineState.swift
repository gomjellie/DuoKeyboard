// Internal state of `CompositionEngine` (SPEC.md §4.1). Value types only, so the engine's
// transitions stay easy to reason about and to test.

import Foundation

/// The word being composed (SPEC.md §4.1 `token`).
struct Token {
    /// ABC-layout keystrokes: letters plus internal `'` (detection.md §4).
    var raw: String
    /// `raw.count`, cached (the token is capped at 32 keys).
    var count: Int
    /// Context frozen when the token started (detection.md §4, R9).
    let context: LanguageContext
    /// `c`: leading raw characters already committed as Latin by eager E (0 if none).
    var committed = 0
    /// The reading on screen.
    var shown: Hypothesis
    /// Set by a flip: the commit uses it and hysteresis is off (R11).
    var locked: Hypothesis?
    /// What was shown when the token was first flipped; a second flip returns to it.
    var lockedOriginal: Hypothesis?
    /// Keys the user confirmed as Latin by choosing E or M(b) (flip or the choice bar). A Korean
    /// ending may follow them: `cmd`, chosen as English, then `fh` reads cmd로 (SPEC.md §4.11).
    var lockedLatin: Int?
    /// The reading the user last locked away from `lockedOriginal`: from the original, the flip key
    /// returns to it (cmd로 after cmd + flip + fh, then a flip back to 층로).
    var lockedReturn: Hypothesis?
    /// The user kept the shown reading on the choice bar: an explicit choice, taught at the commit
    /// when the model would have committed another reading.
    var keptByChoice = false
    /// A one-shot language chosen with nothing to flip (SPEC.md §4.7 c): only readings in this
    /// language are allowed, and hysteresis runs inside it.
    var languageLock: ScriptLanguage?
    /// The word starts with a capital that ended a Korean word (한A, SPEC.md 4.3절 8): K is not
    /// allowed without a flip, so the capital stays Latin and a Korean ending may follow (API를).
    var latinStart = false
    /// The Korean word that capital ended, kept to re-open it (only where committed text can be replaced).
    var splitHead: SplitHead?
    /// Prefix-mode scores of `raw`, computed once per key and reused for display, eager commit, the
    /// HUD and flips (SPEC.md §5 B.6). `nil` while stale (keys passed raw in the eager-E state).
    var scores: HypothesisScores?
    /// Exactly what the engine last sent as marked text (`""` = nothing marked).
    var marked = ""
    /// `KeyEvent.timestamp` of the latest key (resync after a pause, R18 #7).
    var lastKeyAt: TimeInterval

    init(context: LanguageContext, shown: Hypothesis, languageLock: ScriptLanguage?, at time: TimeInterval) {
        raw = ""
        count = 0
        self.context = context
        self.shown = shown
        self.languageLock = languageLock
        lastKeyAt = time
    }

    /// Everything typed so far is committed as Latin (SPEC.md §4.3.5 "eager-E state").
    var isFullyCommitted: Bool { committed > 0 && committed == count }

    /// Whether the token is locked to a reading or to a language.
    var isLocked: Bool { locked != nil || languageLock != nil }

    /// The user chose a Korean reading explicitly: a flip locked K or M, or a one-shot made the
    /// word Korean (a flip lock wins over the one-shot).
    var koreanChosen: Bool { locked.map { $0.language == .korean } ?? (languageLock == .korean) }

    /// SPEC.md §4.3.4: with `c > 0` only `E` and `M(b)` with `b ≥ c` keep the committed Latin.
    func isConsistent(_ h: Hypothesis) -> Bool {
        guard committed > 0 else { return true }
        switch h {
        case .english: return true
        case .mixed(let b): return b >= committed
        case .korean: return false
        }
    }

    /// Readings the engine may show or commit without a flip.
    func isAllowed(_ h: Hypothesis) -> Bool {
        isConsistent(h) && (languageLock == nil || h.language == languageLock) && !(latinStart && h == .korean)
            && !isChoiceOnly(h)
    }

    /// One lowercase Latin letter + a Korean suffix outside a number (a양, SPEC.md 4.3절 4): only the
    /// flip key or the choice bar picks it. As a reading of its own it mostly mistakes English words
    /// (ask, ago) and Korean initials (ㄱ씨는).
    func isChoiceOnly(_ h: Hypothesis) -> Bool {
        h == .mixed(latin: 1) && context != .number && raw.first?.isLowercase == true
    }

    /// Hysteresis (detection.md §5.6) on the current `scores`. Returns `true` if `shown` changed.
    mutating func applyHysteresis(_ hysteresis: Int) -> Bool {
        if let locked {
            shown = locked
            return false
        }
        guard let scores, let best = scores.best(where: isAllowed) else { return false }
        let old = shown
        if !isAllowed(shown) || scores[shown] == nil {
            shown = best.hypothesis
        } else if let current = scores[shown], best.score - current > hysteresis {
            shown = best.hypothesis
        }
        return shown != old
    }

    /// Backspace never changes the language (ux-spec §2.4): keep `shown` unless it can no longer be
    /// shown, in which case fall back to the best allowed reading.
    mutating func keepShownIfPossible() {
        if let locked, !isWellFormed(locked) {
            // A flipped M(b) whose Korean tail was deleted reads as its Latin part.
            self.locked = .english
            if let original = lockedOriginal, !exists(original) { lockedOriginal = .english }
        }
        if let locked {
            shown = locked
            return
        }
        if !isAllowed(shown) || !exists(shown) {
            shown = scores?.best(where: isAllowed)?.hypothesis ?? .english
        }
    }

    /// Whether `h` can be rendered for the current raw, scored or not (M(b) needs `1 ≤ b < count`
    /// and no apostrophe). A chosen M(b) the detector does not score stays chosen.
    func isWellFormed(_ h: Hypothesis) -> Bool {
        if case .mixed(let b) = h { return b >= 1 && b < count && !raw.contains("'") }
        return true
    }

    /// Whether `h` is a hypothesis of the current raw (M(b) needs `1 ≤ b < count`).
    func exists(_ h: Hypothesis) -> Bool {
        if let scores { return scores[h] != nil }
        if case .mixed(let b) = h { return b >= 1 && b < count && !raw.contains("'") }
        return true
    }

    /// The `c` leading characters committed as Latin.
    var committedPrefix: Substring { raw.prefix(committed) }
}

/// A Korean word committed because a capital started a Latin word (SPEC.md 4.3절 8).
final class SplitHead {
    /// The word as it was before the commit.
    let token: Token
    /// What the commit inserted: `render(raw, shown)`.
    let text: String

    init(token: Token, text: String) {
        self.token = token
        self.text = text
    }
}

/// The word committed last, for flip case (b) (SPEC.md §4.1 `lastCommit`, §4.7 b).
struct LastCommit {
    /// The committed reading as it is in the document now (the whole token, including the part
    /// committed eagerly).
    var text: String
    /// `text` length in UTF-16 units.
    var length: Int
    let raw: String
    let context: LanguageContext
    var hypothesis: Hypothesis
    /// The reading a flip turns it into, and its render.
    var alternative: Hypothesis
    var alternativeText: String
    /// `selectedRange().location` right after the insert; `nil` = not flippable (client reported
    /// `NSNotFound`, or it cannot replace text).
    var endLocation: Int?
    /// UTF-16 length of the boundary the app inserts after the word (1 for space, 0 for arrows).
    var boundaryLength: Int
    /// Engine clock time of the commit or of the latest flip.
    var time: TimeInterval
    let clientBundleID: String
    /// The reading as originally committed and the learning votes that commit recorded, so a flip
    /// can undo them and a second flip can restore them exactly.
    let committedHypothesis: Hypothesis
    let committedVotes: [LearningVote]
    /// Votes currently in the store on behalf of this word.
    var appliedVotes: [LearningVote]
    /// Whether flips of this word may teach the store (R7 "never learned" list).
    let learnable: Bool
}

/// Where the next token's context comes from (SPEC.md §4.1 `contextTracker`, §4.2).
struct ContextTracker {
    /// Language of the last committed token (K and M read as Korean).
    var previousLanguage: ScriptLanguage?
    var previousWasDigit = false
    var atSentenceStart = true
    /// `.` `!` `?` was typed and may still be followed by closing quotes; whitespace then starts a sentence.
    var pendingSentenceEnd = false
    var atWordStart = true
    /// Number of `.` typed at word start (`./`, `../` literal triggers).
    var dotRun = 0
    /// The previous key was the `.` that ended an English token (node.js, github.com).
    var dotAfterEnglishToken = false
    /// The previous key was the `:` that ended an English token (https:/).
    var colonAfterEnglishToken = false

    /// SPEC.md §4.2.
    var contextForNewToken: LanguageContext {
        if previousWasDigit { return .number }
        if atSentenceStart { return .start }
        switch previousLanguage {
        case .english: return .english
        case .korean: return .korean
        case nil: return .start
        }
    }

    mutating func noteCommitted(_ language: ScriptLanguage) {
        previousLanguage = language
        previousWasDigit = false
        atSentenceStart = false
        pendingSentenceEnd = false
        atWordStart = false
        dotRun = 0
    }

    /// Letters that reached the app raw (literal, Caps Lock, dead keys) read as English.
    mutating func noteRawLetter() { noteCommitted(.english) }

    mutating func resetToSentenceStart() {
        previousWasDigit = false
        atSentenceStart = true
        pendingSentenceEnd = false
        atWordStart = true
        dotRun = 0
        dotAfterEnglishToken = false
        colonAfterEnglishToken = false
    }

    /// Effect of a key the app handles itself (after any commit), SPEC.md §4.1/§4.2.
    mutating func notePassed(_ key: KeyEvent.Key) {
        switch key {
        case .space:
            if pendingSentenceEnd { atSentenceStart = true }
            pendingSentenceEnd = false
            previousWasDigit = false
            atWordStart = true
            dotRun = 0
        case .tab, .returnKey, .arrowLeft, .arrowRight, .arrowUp, .arrowDown, .navigation:
            resetToSentenceStart()
        case .character(let ch):
            noteCharacter(ch)
        case .keypad(let ch):
            if ch.isASCII, ch.isNumber {
                previousWasDigit = true
                atWordStart = false
                pendingSentenceEnd = false
                dotRun = 0
            } else {
                noteCharacter(ch)
            }
        case .letter:
            noteRawLetter()
        case .escape, .backspace, .forwardDelete, .function, .other:
            break
        }
    }

    private mutating func noteCharacter(_ ch: Character) {
        switch ch {
        case "0"..."9":
            previousWasDigit = true
            atWordStart = false
            pendingSentenceEnd = false
            dotRun = 0
        case ".", "!", "?":
            pendingSentenceEnd = true
            previousWasDigit = false
            atWordStart = false
            dotRun = 0
        case "\"", "'", ")", "]", "}", "(", "[", "{", "<", "“", "”", "‘", "’":
            // Quotes and brackets keep the context (detection.md §4) and a pending sentence end
            // ("Done." then space); an opening one starts a word ("(~/Library)").
            previousWasDigit = false
            atWordStart = "([{<\"'“‘".contains(ch)
            dotRun = 0
        default:
            previousWasDigit = false
            pendingSentenceEnd = false
            atWordStart = false
            dotRun = 0
        }
    }
}
