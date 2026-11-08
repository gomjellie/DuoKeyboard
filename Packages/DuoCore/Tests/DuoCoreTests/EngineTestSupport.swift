// Shared fakes for the engine tests: a scripted detector, a recording client proxy and a harness
// that plays the app's side of every passed key.

import Foundation
import Testing
@testable import DuoCore

// MARK: - FakeDetector

/// A `LanguageDetector` whose scores are scripted per raw string.
///
/// Scores apply in both modes unless `finals` overrides them; user counts add the DET bonus
/// (`USER_UNIT · USER_LOG2[n] / 1000`) and `biasKO` is added to K, so learning and bias are
/// observable. Only main-actor test code touches it.
final class FakeDetector: LanguageDetector, @unchecked Sendable {
    /// Prefix-mode scores (and final-mode, unless overridden) per raw.
    var scores: [String: [Hypothesis: Int]] = [:]
    /// Final-mode overrides per raw.
    var finals: [String: [Hypothesis: Int]] = [:]
    /// Final-mode overrides per raw and context.
    var finalsByContext: [String: [LanguageContext: [Hypothesis: Int]]] = [:]
    /// Used for raws without a script: Korean wins by 9 nats. Both sit 30 nats below a scripted word,
    /// so keys a test did not script never make a likely end of a longer word (SPEC.md 4.11절).
    var fallback: (String) -> [Hypothesis: Int] = { raw in
        [.korean: -1000 * raw.count - 30_000, .english: -1000 * raw.count - 39_000]
    }
    /// Latin words for the M(b) re-open gate (`lexEN`).
    var latinWords: Set<String> = []
    /// Korean tails for the re-open gate (`suffixPrefix`), as raw keys.
    var suffixPrefixes: Set<String> = []
    var parameters: [String: Int] = ["HYST": 1500, "USER_UNIT": 2500]

    private(set) var prefixCalls: [String] = []
    private(set) var prefixContexts: [LanguageContext] = []
    private(set) var finalCalls: [(raw: String, context: LanguageContext, terminator: Terminator)] = []
    private(set) var lastUser: UserCounts?
    private(set) var lastBias: Int?

    static let userLog2 = [0, 1000, 1585, 2000, 2322, 2585, 2807, 3000, 3170, 3322, 3459, 3585, 3700, 3807, 3907, 4000]

    // MARK: Scripting helpers

    /// Every prefix of `word` reads clearly as English (margin 20 nats, eager E fires).
    func english(_ word: String) {
        for i in 1...word.count {
            let p = String(word.prefix(i))
            scores[p] = [.korean: -20_000 - 1000 * i, .english: -1000 * i]
        }
    }

    /// Every prefix of `keys` reads clearly as Korean.
    func korean(_ keys: String) {
        for i in 1...keys.count {
            let p = String(keys.prefix(i))
            scores[p] = [.korean: -1000 * i, .english: -20_000 - 1000 * i]
        }
    }

    func reset() {
        prefixCalls = []
        prefixContexts = []
        finalCalls = []
        choiceCalls = []
    }

    // MARK: LanguageDetector

    func prefixScores(raw: String, context: LanguageContext, user: UserCounts?, biasKO: Int) -> HypothesisScores {
        prefixCalls.append(raw)
        prefixContexts.append(context)
        lastUser = user
        lastBias = biasKO
        return make(scores[raw] ?? fallback(raw), user: user, biasKO: biasKO)
    }

    /// The choice bar's scoring, kept apart from `finalCalls` (those are commits and eager E).
    private(set) var choiceCalls: [String] = []

    func choiceScores(raw: String, context: LanguageContext, user: UserCounts?, biasKO: Int) -> HypothesisScores {
        choiceCalls.append(raw)
        let table = finalsByContext[raw]?[context] ?? finals[raw] ?? scores[raw] ?? fallback(raw)
        return make(table, user: user, biasKO: biasKO)
    }

    func finalScores(raw: String, context: LanguageContext, terminator: Terminator, user: UserCounts?,
                     biasKO: Int) -> HypothesisScores {
        finalCalls.append((raw, context, terminator))
        lastUser = user
        lastBias = biasKO
        let table = finalsByContext[raw]?[context] ?? finals[raw] ?? scores[raw] ?? fallback(raw)
        return make(table, user: user, biasKO: biasKO)
    }

    func render(raw: String, _ hypothesis: Hypothesis) -> String {
        switch hypothesis {
        case .english: return raw
        case .korean: return Self.hangul(raw)
        case .mixed(let b): return String(raw.prefix(b)) + Self.hangul(String(raw.dropFirst(b)))
        }
    }

    func canAttachKorean(raw: String, latinCount b: Int) -> Bool {
        let chars = Array(raw)
        guard b < chars.count, "qwertasdfgzxcvQWERT".contains(chars[b]) else { return false }
        let latin = String(chars[..<b])
        return latinWords.contains(latin.lowercased()) || latin.contains(where: \.isUppercase)
            || suffixPrefixes.contains(String(chars[b...]))
    }

    /// Automaton per apostrophe-separated segment (DET emits `'` literally).
    static func hangul(_ raw: String) -> String {
        raw.split(separator: "'", omittingEmptySubsequences: false)
            .map { HangulAutomaton.hangul(fromLatin: String($0)) }
            .joined(separator: "'")
    }

    private func make(_ table: [Hypothesis: Int], user: UserCounts?, biasKO: Int) -> HypothesisScores {
        let unit = parameters["USER_UNIT"] ?? 2500
        func order(_ h: Hypothesis) -> Int {
            switch h {
            case .korean: 0
            case .english: 1
            case .mixed(let b): 1 + b
            }
        }
        let entries = table.sorted { order($0.key) < order($1.key) }.map { h, score in
            var s = score
            if h == .korean { s += biasKO }
            if let n = user?[h], n > 0 { s += unit * Self.userLog2[min(n, 15)] / 1000 }
            return ScoredHypothesis(h, s)
        }
        return HypothesisScores(entries)
    }
}

// MARK: - RecordingClient

/// Forwards to a `BufferTextClient` and records every call, so tests can assert the exact XPC
/// traffic (critique R15).
@MainActor
final class RecordingClient: TextClient {
    enum Call: Equatable, CustomStringConvertible {
        case insert(String, NSRange?)
        case mark(String, NSRange?)
        case selectedRange
        case markedRange
        case string(NSRange)

        var description: String {
            switch self {
            case .insert(let s, let r): "insert(\(s.debugDescription)\(r.map { ", \($0)" } ?? ""))"
            case .mark(let s, let r): "mark(\(s.debugDescription)\(r.map { ", \($0)" } ?? ""))"
            case .selectedRange: "selectedRange"
            case .markedRange: "markedRange"
            case .string(let r): "string(\(r))"
            }
        }

        var isMutation: Bool {
            switch self {
            case .insert, .mark: true
            default: false
            }
        }
    }

    let buffer: BufferTextClient
    private(set) var calls: [Call] = []
    /// `selectedRange()` reports the caret this many UTF-16 units early (Terminal answers before the
    /// shell has echoed what was just inserted).
    var selectionLag = 0

    init(_ buffer: BufferTextClient) { self.buffer = buffer }

    func take() -> [Call] {
        defer { calls = [] }
        return calls
    }

    func insertText(_ text: String, replacementRange: NSRange?) {
        calls.append(.insert(text, replacementRange))
        buffer.insertText(text, replacementRange: replacementRange)
    }

    func setMarkedText(_ text: String, replacementRange: NSRange?) {
        calls.append(.mark(text, replacementRange))
        buffer.setMarkedText(text, replacementRange: replacementRange)
    }

    func selectedRange() -> NSRange? {
        calls.append(.selectedRange)
        guard let range = buffer.selectedRange() else { return nil }
        return NSRange(location: max(0, range.location - selectionLag), length: range.length)
    }

    func markedRange() -> NSRange? {
        calls.append(.markedRange)
        return buffer.markedRange()
    }

    func string(in range: NSRange) -> String? {
        calls.append(.string(range))
        return buffer.string(in: range)
    }

    var bundleIdentifier: String { buffer.bundleIdentifier }
}

// MARK: - Harness

/// One key's outcome.
struct Step {
    var consumed: Bool
    var calls: [RecordingClient.Call]

    var mutations: [RecordingClient.Call] { calls.filter(\.isMutation) }
}

/// An engine wired to a recording `BufferTextClient`, a fake detector, a learning store and a
/// controllable clock. `press` plays the app's side: a key the engine passes is typed into the buffer.
@MainActor
final class EngineHarness {
    let detector: FakeDetector
    let store: LearningStore
    let buffer: BufferTextClient
    let client: RecordingClient
    let engine: CompositionEngine
    /// Engine clock and key timestamps (seconds).
    var now: TimeInterval = 1000
    /// Learning-store clock.
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private(set) var notifications: [EngineNotification] = []

    /// - Parameter scorer: a real detector to use instead of `detector` (scenario tests).
    init(settings: DuoSettings = .default, bundleIdentifier: String = "com.apple.TextEdit",
         replacement: ReplacementSupport? = nil, detector: FakeDetector = FakeDetector(),
         scorer: (any LanguageDetector)? = nil, snapshot: LearningSnapshot = LearningSnapshot()) {
        self.detector = detector
        let profile = ClientProfile.forBundleIdentifier(bundleIdentifier)
        buffer = BufferTextClient(bundleIdentifier: bundleIdentifier, replacementSupport: replacement ?? profile.replacement)
        client = RecordingClient(buffer)
        var dateBox: () -> Date = { Date() }
        var nowBox: () -> TimeInterval = { 0 }
        let store = LearningStore(snapshot: snapshot, now: { dateBox() })
        self.store = store
        engine = CompositionEngine(detector: scorer ?? detector, learning: store, settings: settings,
                                   bundleIdentifier: bundleIdentifier, clock: { nowBox() })
        dateBox = { [unowned self] in self.date }
        nowBox = { [unowned self] in self.now }
        engine.onNotification = { [unowned self] in self.notifications.append($0) }
    }

    var text: String { buffer.text }
    var marked: String? { buffer.markedText }
    var markedRange: NSRange? { buffer.marked }
    var hud: HUDRequest? { engine.hud }

    /// Sends one key down (advancing the clock by `dt`); a passed key is applied to the buffer.
    @discardableResult
    func press(_ event: KeyEvent, after dt: TimeInterval = 0.05, characters: String? = nil) -> Step {
        now += dt
        var e = event
        e.timestamp = now
        _ = client.take()
        let consumed = engine.handle(e, client: client)
        let calls = client.take()
        if !consumed { buffer.applyPassedKey(e, characters: characters) }
        return Step(consumed: consumed, calls: calls)
    }

    /// Types an ABC-layout string (`KeyEvent.typing`), one key at a time.
    @discardableResult
    func type(_ text: String, after dt: TimeInterval = 0.05) -> [Step] {
        KeyEvent.typing(text).map { press($0, after: dt) }
    }

    @discardableResult
    func press(_ key: KeyEvent.Key, _ modifiers: KeyEvent.Modifiers = [], after dt: TimeInterval = 0.05) -> Step {
        press(KeyEvent(key, modifiers: modifiers), after: dt)
    }

    /// Taps a modifier: flagsChanged down then up, `hold` seconds apart.
    @discardableResult
    func tap(keyCode: UInt16 = FlipTapDetector.KeyCode.rightCommand, flag: UInt = FlipTapDetector.Flags.command,
             device: UInt = FlipTapDetector.Flags.rightCommandDevice, hold: TimeInterval = 0.08) -> [RecordingClient.Call] {
        now += 0.05
        _ = client.take()
        engine.handleModifier(ModifierEvent(keyCode: keyCode, flags: flag | device, timestamp: now), client: client)
        now += hold
        engine.handleModifier(ModifierEvent(keyCode: keyCode, flags: 0, timestamp: now), client: client)
        return client.take()
    }

    /// The flip key (right ⌘ by default).
    @discardableResult
    func flip() -> [RecordingClient.Call] { tap() }

    /// Presses (`down`) or releases one modifier, `dt` seconds after the last event: half a tap.
    func modifier(down: Bool, keyCode: UInt16 = FlipTapDetector.KeyCode.rightCommand,
                  flag: UInt = FlipTapDetector.Flags.command,
                  device: UInt = FlipTapDetector.Flags.rightCommandDevice, after dt: TimeInterval = 0.05) {
        now += dt
        engine.handleModifier(ModifierEvent(keyCode: keyCode, flags: down ? flag | device : 0, timestamp: now),
                              client: client)
    }

    func commit(_ reason: CommitReason) -> [RecordingClient.Call] {
        _ = client.take()
        engine.commit(reason, client: client)
        return client.take()
    }

    func clearNotifications() { notifications = [] }

    /// Learned effective counts at `(raw, ctx)`.
    func learned(_ raw: String, _ ctx: LanguageContext) -> [Hypothesis: Int] {
        store.counts(raw: raw, context: ctx)?.counts ?? [:]
    }
}

extension HUDRequest {
    /// The offered reading's text when this is an `.alternative` request.
    var alternativeText: String? {
        if case .alternative(let choice, _) = content { return choice.other.text }
        return nil
    }

    var isEligible: Bool {
        if case .alternative(_, let eligible) = content { return eligible }
        return false
    }

    /// This is the last word's choice bar.
    var isLastWordChoice: Bool {
        if case .flipLastWord = content { return true }
        return false
    }
}

/// A choice bar for expectations: `current` is in the document, `other` is offered.
func bar(_ current: String, _ currentLanguage: ScriptLanguage, offering other: String, _ otherLanguage: ScriptLanguage,
         currentFirst: Bool) -> HUDChoice {
    HUDChoice(current: HUDReading(text: current, language: currentLanguage),
              other: HUDReading(text: other, language: otherLanguage), currentFirst: currentFirst)
}

extension KeyEvent {
    static func letter(_ c: Character, _ modifiers: KeyEvent.Modifiers = []) -> KeyEvent {
        let k = Keystroke(latin: c)!
        return KeyEvent(.letter(k), modifiers: k.shift ? modifiers.union(.shift) : modifiers)
    }
}
