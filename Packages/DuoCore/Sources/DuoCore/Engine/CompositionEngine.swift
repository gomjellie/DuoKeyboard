import Foundation

/// The per-client composition state machine (SPEC.md §4). One instance per IMK controller
/// (client session); the detector, learning store and settings are shared.
///
/// The engine keeps the whole token marked until a boundary, shows the detector's prefix-mode
/// reading with hysteresis, commits English early when it is certain, and commits the final-mode
/// reading at the boundary (critique R1, R2). It talks to the app only through ``TextClient`` and
/// keeps to one `setMarkedText` or `insertText` per key in the common case (critique R15).
///
/// Typical host loop:
/// ```swift
/// let consumed = engine.handle(keyEvent, client: client)  // keyDown
/// engine.handleModifier(modifierEvent, client: client)    // flagsChanged, never consumed
/// hudController.show(engine.hud)
/// ```
@MainActor
public final class CompositionEngine {
    /// Current settings. Assigning reconfigures the flip-key detector.
    public var settings: DuoSettings {
        didSet {
            if settings.flipKey != oldValue.flipKey || settings.flipTapWindowMs != oldValue.flipTapWindowMs {
                tap = FlipTapDetector(flipKey: settings.flipKey, tapWindowMs: settings.flipTapWindowMs)
            }
            // Bilingual-for-this-line belongs to Direct: leaving Direct (input menu, Settings)
            // ends it, or its badge would stay up in a profile that never clears it.
            if bilingualLine, effectiveProfile != .direct {
                bilingualLine = false
                if hud == Self.bilingualBadge { hud = nil }
            }
        }
    }
    /// Built-in behaviour for the current client (SPEC.md §4.10).
    public private(set) var clientProfile: ClientProfile
    /// What the HUD should show after the last call; `nil` = hidden.
    public internal(set) var hud: HUDRequest?
    /// Flips, commits and learning changes, for the host (VoiceOver, distributed notifications).
    public var onNotification: ((EngineNotification) -> Void)?

    let detector: any LanguageDetector
    let learning: LearningStore
    /// Monotonic seconds (same base as `NSEvent.timestamp` by default), for `lastCommit` validity.
    let clock: () -> TimeInterval
    /// Display hysteresis from the model's `meta.params` (critique R8).
    let hysteresis: Int

    var token: Token?
    var context = ContextTracker()
    /// L phase: keys pass raw until whitespace (SPEC.md §4.6).
    var literal = false
    /// UTF-16 units typed since L began, its trigger included. Backspacing over all of them (the
    /// trigger is gone, so the next word is not part of a path or address) ends L.
    var literalLength = 0
    /// The key after a dead key passes raw (é, ü, ñ).
    var passNextRaw = false
    var capsLockOn = false
    /// Direct profile with Bilingual turned on for the current line (ux-spec §6.6).
    var bilingualLine = false
    /// Language of the next token, armed by a flip with nothing to flip (SPEC.md §4.7 c).
    var oneShot: ScriptLanguage?
    var lastCommit: LastCommit?
    var tap: FlipTapDetector

    /// - Parameters:
    ///   - detector: the shared scorer.
    ///   - learning: the shared learned votes.
    ///   - settings: current settings (reassign ``settings`` when they change).
    ///   - bundleIdentifier: the client's bundle id (cached by the adapter; one XPC call per session).
    ///   - clock: monotonic time in seconds; defaults to `ProcessInfo.systemUptime`, the base of
    ///     `NSEvent.timestamp`.
    public init(detector: any LanguageDetector, learning: LearningStore, settings: DuoSettings = .default,
                bundleIdentifier: String = "", clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.detector = detector
        self.learning = learning
        self.settings = settings
        self.clock = clock
        self.clientProfile = ClientProfile.forBundleIdentifier(bundleIdentifier)
        self.hysteresis = detector.parameters["HYST"] ?? 1500
        self.tap = FlipTapDetector(flipKey: settings.flipKey, tapWindowMs: settings.flipTapWindowMs)
    }

    /// A word is in progress (marked, or partly committed as Latin by eager E).
    public var isComposing: Bool { token != nil }

    /// Something is marked in the client right now.
    public var hasMarkedText: Bool { !(token?.marked.isEmpty ?? true) }

    /// The marked string the engine last sent (IMK `composedString`).
    public var composedText: String { token?.marked ?? "" }

    /// The keys of the word in progress (IMK `originalString`).
    public var rawKeys: String { token?.raw ?? "" }

    /// The profile in force for this client (user override or default).
    public var effectiveProfile: AppProfile { clientProfile.effectiveProfile(settings) }

    /// Re-targets the engine at a new client (IMK may reuse a controller); commits nothing.
    /// Everything per-field is forgotten and the next word starts a sentence.
    public func setClient(bundleIdentifier: String) {
        clientProfile = ClientProfile.forBundleIdentifier(bundleIdentifier)
        reset()
    }

    /// Forget all state without touching the client (e.g. the client went away).
    public func reset() {
        token = nil
        hud = nil
        context = ContextTracker()
        endLiteral()
        passNextRaw = false
        bilingualLine = false
        oneShot = nil
        lastCommit = nil
        tap.reset()
    }

    // MARK: - Key down

    /// A keyDown. Returns `true` if consumed (`handle(_:client:)` return value).
    public func handle(_ event: KeyEvent, client: any TextClient) -> Bool {
        tap.noteKeyDown()
        hud = nil
        capsLockOn = event.modifiers.contains(.capsLock)
        let wasLiteral = literal
        let consumed = dispatch(event, client: client)
        if wasLiteral, literal { literalLength += Self.literalTypedLength(event, graveTypesWon: settings.graveTypesWon) }
        if bilingualLine, hud == nil { hud = Self.bilingualBadge }
        return consumed
    }

    private func dispatch(_ event: KeyEvent, client: any TextClient) -> Bool {
        let mods = event.modifiers
        // One-key look-behinds for the literal triggers (SPEC.md §4.6).
        let dotAfterEnglish = context.dotAfterEnglishToken
        let colonAfterEnglish = context.colonAfterEnglishToken
        context.dotAfterEnglishToken = false
        context.colonAfterEnglishToken = false

        if isShiftSpaceFlip(event), !literal {
            // The flip does its own marked-text check. Autorepeat must not flip back and forth with
            // how long the key is held, so repeats are swallowed. In L a flip can do nothing, so
            // ⇧Space is the space it most likely was (a ⇧ still held from a capital) and ends L.
            if !event.isRepeat { flip(client: client, at: event.timestamp) }
            return true
        }

        resyncIfNeeded(at: event.timestamp, client: client)

        if effectiveProfile == .direct, !bilingualLine {
            // A word marked before the profile became Direct (input menu) is committed first, or
            // the app would type over it and a later commit would put it somewhere else.
            return passLetterOrRaw(event, terminator: .space, client: client)
        }

        if passNextRaw {
            passNextRaw = false
            return passRaw(event, terminator: .punctuation, client: client)
        }

        if mods.contains(.command) || mods.contains(.control) || (mods.contains(.function) && event.key.isTyping) {
            // Shortcuts act on committed text (⌘A, ⌘C, fn-E) and type nothing, so the context stays;
            // the caret check guards a later flip. They can delete or move away from the literal
            // text (⌘A ⌫, ⌘Z, ⌘←, ⌃A), so L ends; '.' or '/' after an English word re-enter it.
            endLiteral()
            return passThrough(event, terminator: .space, boundaryLength: 0, affectsContext: false, client: client)
        }

        switch event.key {
        case .letter(let k):
            if mods.contains(.option) {
                if event.isDeadKey { passNextRaw = true }
                return passRaw(event, terminator: .punctuation, boundaryLength: 0, client: client)
            }
            if capsLockOn, settings.flipKey != .capsLock {
                return passRaw(event, terminator: .space, boundaryLength: 0, client: client)
            }
            if literal { return passLetterOrRaw(event, terminator: .space, client: client) }
            if dotAfterEnglish, token == nil {
                beginLiteral()
                return passLetterOrRaw(event, terminator: .space, client: client)
            }
            return handleLetter(k, event: event, client: client)

        case .character(let ch):
            if mods.contains(.option) {
                if ch == "`", settings.graveTypesWon, event.isDeadKey {
                    commitToken(terminator: .punctuation, boundaryLength: 1, trailing: "`", client: client)
                    context.notePassed(event.key)
                    return true
                }
                if event.isDeadKey { passNextRaw = true }
                // ⌥2 types ™, not 2: the layout's symbol says nothing about the next word.
                return passThrough(event, terminator: .punctuation, boundaryLength: 0, affectsContext: false,
                                   client: client)
            }
            if literal { return passThrough(event, terminator: .punctuation, client: client) }
            return handleCharacter(ch, event: event, colonAfterEnglish: colonAfterEnglish, client: client)

        case .space:
            endLiteral()
            return passThrough(event, terminator: .space, boundaryLength: 1, client: client)

        case .returnKey, .escape:
            endLiteral()
            let consumed = passThrough(event, terminator: .space,
                                       boundaryLength: event.key == .returnKey ? 1 : 0, client: client)
            if effectiveProfile == .direct, bilingualLine {
                bilingualLine = false
                hud = nil
            }
            return consumed

        case .tab:
            endLiteral()
            return passThrough(event, terminator: .space, boundaryLength: 1, client: client)

        case .backspace:
            if mods.contains(.option) {
                // ⌥⌫ deletes a whole word, the literal text with it.
                endLiteral()
                return passThrough(event, terminator: .space, boundaryLength: 0, client: client)
            }
            if literal, token == nil {
                // Deleting the trigger itself (`@`, `/`) ends L: what follows is a new word.
                literalLength -= 1
                if literalLength <= 0 { endLiteral() }
            }
            return handleBackspace(event, client: client)

        case .keypad(let ch):
            let terminator: Terminator = ch.isASCII && ch.isNumber ? .digit : ch == "-" ? .hyphen : .punctuation
            return passThrough(event, terminator: terminator, client: client)

        case .arrowLeft, .arrowRight, .arrowUp, .arrowDown, .navigation:
            // The caret leaves the literal text; the context restarts at a sentence start too.
            endLiteral()
            return passThrough(event, terminator: .space, boundaryLength: 0, client: client)

        case .forwardDelete, .function, .other:
            return passThrough(event, terminator: .space, boundaryLength: 0, client: client)
        }
    }

    // MARK: - Literal phase bookkeeping (SPEC.md §4.6)

    /// Enter L; the trigger key (or the first raw letter after `.`) is the first unit typed.
    func beginLiteral() {
        literal = true
        literalLength = 1
    }

    func endLiteral() {
        literal = false
        literalLength = 0
    }

    /// UTF-16 units a key typed while in L (what a later Backspace has to delete).
    static func literalTypedLength(_ event: KeyEvent, graveTypesWon: Bool) -> Int {
        let mods = event.modifiers
        if mods.contains(.command) || mods.contains(.control) { return 0 }
        if event.isDeadKey {
            // A dead key types nothing until the next key (é is one unit, counted with that key);
            // ⌥` with `graveTypesWon` is the engine typing a backquote.
            return event.key == .character("`") && graveTypesWon ? 1 : 0
        }
        switch event.key {
        case .letter: return 1
        case .character(let c), .keypad(let c): return mods.contains(.option) ? 1 : String(c).utf16.count
        default: return 0
        }
    }

    /// Commit any token (one `insertText`), record the key's effect on the context and let the app
    /// handle the key (SPEC.md §4.5).
    @discardableResult
    func passThrough(_ event: KeyEvent, terminator: Terminator, boundaryLength: Int? = nil,
                     affectsContext: Bool = true, client: any TextClient) -> Bool {
        let length = boundaryLength ?? Self.boundaryLength(of: event.key)
        commitToken(terminator: terminator, boundaryLength: length, client: client)
        if affectsContext { context.notePassed(event.key) }
        return false
    }

    /// `passThrough` for a key the app types itself: a typed letter ends flip case (b) validity.
    private func passRaw(_ event: KeyEvent, terminator: Terminator, boundaryLength: Int? = nil,
                         client: any TextClient) -> Bool {
        let consumed = passThrough(event, terminator: terminator, boundaryLength: boundaryLength, client: client)
        if case .letter = event.key { lastCommit = nil }
        return consumed
    }

    /// Caps Lock is the flip key and its lock is on. macOS toggles the lock on every press, so
    /// after every other flip it is on, but it means "flip", not capitals: a letter the app types
    /// itself would come out uppercase while the token's raw keys are lowercase.
    var appUppercasesLetters: Bool { settings.flipKey == .capsLock && capsLockOn }

    /// `passRaw` for a key the app would type, except that a plain letter is typed by the engine
    /// when the app would uppercase it (``appUppercasesLetters``).
    private func passLetterOrRaw(_ event: KeyEvent, terminator: Terminator, client: any TextClient) -> Bool {
        guard appUppercasesLetters, case .letter(let k) = event.key,
              event.modifiers.isDisjoint(with: [.command, .control, .option, .function]) else {
            return passRaw(event, terminator: terminator, client: client)
        }
        commitToken(terminator: terminator, boundaryLength: 1, client: client)
        insert(String(k.latin), client: client)
        context.notePassed(event.key)
        lastCommit = nil
        return true
    }

    private func isShiftSpaceFlip(_ event: KeyEvent) -> Bool {
        event.key == .space && settings.flipKey == .shiftSpace
            && event.modifiers.intersection([.shift, .control, .option, .command]) == .shift
    }

    /// UTF-16 length the app will insert for a passed key.
    static func boundaryLength(of key: KeyEvent.Key) -> Int {
        switch key {
        case .space, .returnKey, .tab: 1
        case .character(let c), .keypad(let c): String(c).utf16.count
        case .letter: 1
        default: 0
        }
    }

    // MARK: - Modifiers

    /// A key or click the engine did not see (a ⌘-shortcut the app routed to its menu, a key typed
    /// in a client that does not forward modifier events) happened: a pending flip-key tap is a chord.
    public func noteKeyActivity() {
        tap.noteKeyDown()
    }

    /// A flagsChanged (flip-key tap detection, Caps Lock). Never consumes the event.
    public func handleModifier(_ event: ModifierEvent, client: any TextClient) {
        guard event.keyCode != 0 else { return }
        let flags = event.flags & FlipTapDetector.Flags.deviceIndependentMask
        if event.keyCode == FlipTapDetector.KeyCode.capsLock {
            let on = flags & FlipTapDetector.Flags.capsLock != 0
            // Caps Lock on = English lock (D9): finish the word first, as Apple's Korean IME does.
            if on, !capsLockOn, settings.flipKey != .capsLock, token != nil {
                // After a pause the app may have cleared the field (R18 #7): no ghost insert.
                resyncIfNeeded(at: event.timestamp, client: client)
                commitFromModifier(client: client)
            }
            capsLockOn = on
        }
        if event.keyCode == FlipTapDetector.KeyCode.function, flags & FlipTapDetector.Flags.function != 0, token != nil {
            // Globe/fn opens the emoji picker or dictation: the word lands before what it inserts.
            resyncIfNeeded(at: event.timestamp, client: client)
            commitFromModifier(client: client)
        }
        if tap.handle(event) {
            flip(client: client, at: event.timestamp)
            // A flip that changed nothing in a Bilingual line (literal text, a word with no other
            // reading) cleared the HUD, but the line is still bilingual: keep the badge, as after
            // every key (`handle`). Otherwise it vanishes and VoiceOver hears "back to direct
            // input". Only after a flip: a bare press must not announce the line again.
            if bilingualLine, hud == nil { hud = Self.bilingualBadge }
        }
    }

    /// Commits the word for Caps Lock or fn. The word's choice bar goes with it, as before every key
    /// (`handle`): only the commit may put up a new request (the last word's chip).
    private func commitFromModifier(client: any TextClient) {
        hud = nil
        commitToken(terminator: .space, boundaryLength: 0, client: client)
        if bilingualLine, hud == nil { hud = Self.bilingualBadge }
    }

    // MARK: - Explicit commits

    /// Commit whatever is being composed (mouse, deactivate, commitComposition, secure input).
    ///
    /// With something marked, the client is asked first (one `markedRange()` call): if it already
    /// ended the composition, by keeping the string (Chromium on blur) or by clearing the field
    /// (R18 #7), inserting would duplicate the word or put a ghost into the emptied field.
    public func commit(_ reason: CommitReason, client: any TextClient) {
        if let t = token {
            if !t.marked.isEmpty, client.markedRange() == nil {
                token = nil
            } else {
                commitToken(terminator: .space, boundaryLength: 0, reason: reason, client: client)
            }
        }
        hud = nil
        tap.reset()
        switch reason {
        case .commitComposition:
            break
        case .mouse, .deactivate, .secureInput:
            lastCommit = nil
            context.resetToSentenceStart()
            endLiteral()
            passNextRaw = false
            oneShot = nil
            bilingualLine = false
        }
    }

    // MARK: - Resync (critique R18 #7)

    /// After a pause, check that the client still has our marked text; if the app cleared it
    /// (Slack after sending), drop the token silently.
    func resyncIfNeeded(at time: TimeInterval, client: any TextClient) {
        guard let t = token, !t.marked.isEmpty, time - t.lastKeyAt > 1 else { return }
        if client.markedRange() == nil { dropToken() }
    }

    func dropToken() {
        token = nil
        hud = nil
        context.resetToSentenceStart()
    }

    // MARK: - Shared helpers

    var biasKO: Int { clientProfile.biasKO(settings) }

    /// Learned counts for `raw`.
    ///
    /// - Parameter carryLatinPrefixes: also add half (rounded up) of what each Latin prefix of
    ///   `raw` learned: its English votes and its stem votes (a chosen cmd로 records M(3) on `cmd`,
    ///   which the bare word never scores). Only the choice bar asks for this (SPEC.md
    ///   4.11절): cmd learned as English lifts cmd로 on the bar, while what is shown and committed
    ///   stays the model's and the word's own learning, so 층로 is still typed as 층로.
    func userCounts(_ raw: String, _ context: LanguageContext, carryLatinPrefixes: Bool = false) -> UserCounts? {
        guard settings.learningEnabled else { return nil }
        var counts = learning.counts(raw: raw, context: context)?.counts ?? [:]
        if carryLatinPrefixes {
            var prefix = ""
            for (i, ch) in raw.dropLast().enumerated() {
                prefix.append(ch)
                guard i >= 1, ch != "'", let learned = learning.counts(raw: prefix, context: context) else { continue }
                let latin = learned[.english] + learned[.mixed(latin: i + 1)]
                if latin > 0 { counts[.mixed(latin: i + 1), default: 0] += (latin + 1) / 2 }
            }
        }
        return counts.isEmpty ? nil : UserCounts(counts)
    }

    func prefixScores(_ raw: String, _ context: LanguageContext) -> HypothesisScores {
        detector.prefixScores(raw: raw, context: context, user: userCounts(raw, context), biasKO: biasKO)
    }

    func render(_ raw: String, _ h: Hypothesis) -> String { detector.render(raw: raw, h) }

    /// Marked or inserted text for the uncommitted part of `t` in reading `h`.
    func display(_ t: Token, _ h: Hypothesis) -> String {
        String(render(t.raw, h).dropFirst(t.committed))
    }

    /// The single reading a flip offers (critique R11): K → E or M, E → K or M, M → E, always with
    /// a different rendered string.
    ///
    /// A mixed reading is offered only when it is a real contender: it beats the other pure
    /// reading and the model gives it at least 1 % of the shown one (`Margins.eagerCommit`).
    /// Otherwise the runner-up mix is noise (사랑 → `tk랑`, test → `tesㅅ`, thanks → `thankㄴ`) and the
    /// user, who just said "not this script", wants the plain other reading. Real mixes (PR을,
    /// git을) are either shown already or within that margin.
    func alternative(of h: Hypothesis, raw: String, in scores: HypothesisScores) -> Hypothesis? {
        if case .mixed = h { return .english }
        let shownText = render(raw, h)
        let pure: Hypothesis = h == .korean ? .english : .korean
        let differs = { (x: Hypothesis) in self.render(raw, x) != shownText }
        let pureScore = differs(pure) ? scores[pure] : nil
        let mixed = HypothesisScores(scores.entries.filter {
            if case .mixed = $0.hypothesis { differs($0.hypothesis) } else { false }
        }).best
        if let mixed, let shownScore = scores[h] ?? scores.best?.score,
           shownScore - mixed.score <= Margins.eagerCommit,
           pureScore.map({ mixed.score >= $0 }) ?? true {
            return mixed.hypothesis
        }
        if pureScore != nil { return pure }
        return mixed?.hypothesis
    }

    /// The choice bar for a word read as `current` with `other` offered.
    func choice(current: (Hypothesis, String), other: (Hypothesis, String)) -> HUDChoice {
        HUDChoice(current: HUDReading(text: current.1, language: current.0.language),
                  other: HUDReading(text: other.1, language: other.0.language),
                  currentFirst: Self.displayRank(current.0) <= Self.displayRank(other.0))
    }

    func choice(raw: String, current: Hypothesis, other: Hypothesis) -> HUDChoice {
        choice(current: (current, render(raw, current)), other: (other, render(raw, other)))
    }

    /// Choice-bar order: the Korean reading, then mixed readings by Latin length, then English.
    /// The order depends only on the hypotheses, so it survives a flip.
    static func displayRank(_ h: Hypothesis) -> (Int, Int) {
        switch h {
        case .korean: (0, 0)
        case .mixed(let latin): (1, latin)
        case .english: (2, 0)
        }
    }

    func setMarked(_ text: String, in t: inout Token, client: any TextClient) {
        client.setMarkedText(text, replacementRange: nil)
        t.marked = text
    }

    /// Commits `text` at the marked text or caret. Java clients' mark-before-insert (critique R17) is
    /// the IMK adapter's job (SPEC.md §5 C.1, `ClientProfile.needsMarkBeforeInsert`), so the
    /// engine sends exactly one call here.
    func insert(_ text: String, client: any TextClient) {
        client.insertText(text, replacementRange: nil)
    }

    func notify(_ n: EngineNotification) { onNotification?(n) }

    static let bilingualBadge = HUDRequest(content: .bilingualLine, anchor: .caret, immediate: true)
}

extension KeyEvent.Key {
    /// A key that types a character (letters, digits, punctuation): with fn held it is a system
    /// shortcut instead. Arrows and F-keys carry `.function` by themselves.
    var isTyping: Bool {
        switch self {
        case .letter, .character: true
        default: false
        }
    }
}
