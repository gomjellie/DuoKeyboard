import Foundation
import Testing
@testable import DuoCore

/// Critique R7: `LearningStore` and the engine's votes.
@MainActor
@Suite("Engine · learning")
struct EngineLearningTests {
    nonisolated static let day: TimeInterval = 24 * 60 * 60
    nonisolated static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    final class Clock {
        var date = EngineLearningTests.t0
    }

    // MARK: LearningStore

    @Test func recordsAndReadsCountsPerRawAndContext() {
        let store = LearningStore(now: { Self.t0 })
        store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3)
        store.record(raw: "go", context: .english, hypothesis: .english, votes: 1)
        store.record(raw: "PRdmf", context: .korean, hypothesis: .mixed(latin: 2), votes: 1)
        #expect(store.counts(raw: "go", context: .korean) == UserCounts([.korean: 3]))
        #expect(store.counts(raw: "go", context: .english) == UserCounts([.english: 1]))
        #expect(store.counts(raw: "go", context: .start) == nil, "contexts are separate keys")
        #expect(store.counts(raw: "PRdmf", context: .korean)?[.mixed(latin: 2)] == 1)
        #expect(store.count == 3)
    }

    @Test(arguments: [(0.0, 3), (59.0, 2), (60.0, 2), (120.0, 1), (179.0, 0), (240.0, 0)])
    func decaysWithASixtyDayHalfLife(_ days: Double, _ expected: Int) {
        // 3 votes: 1.5 after 60 d (rounds to 2), 0.75 after 120 d (1), 0.375 after 180 d (0).
        let clock = Clock()
        let store = LearningStore(now: { clock.date })
        store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3)
        clock.date = Self.t0.addingTimeInterval(days * Self.day)
        #expect((store.counts(raw: "go", context: .korean)?[.korean] ?? 0) == expected)
    }

    @Test func newVotesAddToDecayedOnes() {
        let clock = Clock()
        let store = LearningStore(now: { clock.date })
        store.record(raw: "so", context: .korean, hypothesis: .korean, votes: 3)
        clock.date = Self.t0.addingTimeInterval(60 * Self.day)
        store.record(raw: "so", context: .korean, hypothesis: .korean, votes: 3)
        let votes = store.effectiveVotes(raw: "so", context: .korean)[.korean] ?? 0
        #expect(abs(votes - 4.5) < 1e-9)
        #expect(store.snapshot().entries.first?.updatedAt == clock.date)
        #expect(store.counts(raw: "so", context: .korean)?[.korean] == 5)
    }

    @Test func cancelTakesBackExactlyOneVoteAndRemovesEmptyEntries() {
        let store = LearningStore(now: { Self.t0 })
        var changes = 0
        store.onChange = { changes += 1 }
        let a = store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3)
        store.record(raw: "go", context: .korean, hypothesis: .english, votes: 1)
        store.cancel(a)
        #expect(store.counts(raw: "go", context: .korean) == UserCounts([.english: 1]))
        store.cancel(LearningVote(raw: "go", context: .korean, hypothesis: .english, amount: 5))
        #expect(store.count == 0, "never below zero; empty entries disappear")
        store.cancel(a)
        #expect(changes == 4, "a cancel of nothing is not a change")
    }

    @Test func lruCapEvictsTheLeastRecentlyUpdated() {
        let clock = Clock()
        let store = LearningStore(now: { clock.date })
        for i in 0...LearningStore.capacity {
            clock.date = Self.t0.addingTimeInterval(TimeInterval(i))
            store.record(raw: "w\(i)", context: .start, hypothesis: .english, votes: 1)
        }
        #expect(store.count == LearningStore.capacity * 95 / 100, "room for a thousand new words at once")
        #expect(store.counts(raw: "w0", context: .start) == nil)
        #expect(store.counts(raw: "w\(LearningStore.capacity)", context: .start) != nil)
    }

    @Test func snapshotRoundTripsAndLoadPrunesJunk() {
        let clock = Clock()
        let store = LearningStore(now: { clock.date })
        store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3)
        clock.date = Self.t0.addingTimeInterval(10)
        store.record(raw: "to", context: .english, hypothesis: .english, votes: 1)
        let snap = store.snapshot()
        #expect(snap.entries.map(\.raw) == ["to", "go"], "most recent first")
        let loaded = LearningStore(snapshot: snap, now: { clock.date })
        #expect(loaded.snapshot() == snap)

        let junk = LearningSnapshot(entries: [
            LearningEntry(raw: "old", context: .start, votes: ["K": 1], updatedAt: Self.t0.addingTimeInterval(-400 * Self.day)),
            LearningEntry(raw: "bad", context: .start, votes: ["Z9": 3, "K": -1], updatedAt: Self.t0),
            LearningEntry(raw: "", context: .start, votes: ["K": 3], updatedAt: Self.t0),
            LearningEntry(raw: "ok", context: .start, votes: ["E": 2, "M": 4], updatedAt: Self.t0),
        ])
        let pruned = LearningStore(snapshot: junk, now: { Self.t0 })
        #expect(pruned.count == 1)
        #expect(pruned.counts(raw: "ok", context: .start) == UserCounts([.english: 2]))
    }

    // MARK: Corrupted or hostile learning.json (Int(_:) traps on huge values)

    @Test func absurdVotesFromTheFileAreClampedOrDropped() {
        let snap = LearningSnapshot(entries: [
            LearningEntry(raw: "go", context: .korean, votes: ["K": 1e20, "E": .infinity, "M1": .nan], updatedAt: Self.t0),
            LearningEntry(raw: "so", context: .korean, votes: ["K": .greatestFiniteMagnitude], updatedAt: Self.t0),
            LearningEntry(raw: "to", context: .korean, votes: ["K": -5, "E": 2], updatedAt: Self.t0),
            LearningEntry(raw: String(repeating: "a", count: 65), context: .korean, votes: ["K": 3], updatedAt: Self.t0),
            LearningEntry(raw: "do", context: .korean, votes: ["K": 3], updatedAt: Date(timeIntervalSinceReferenceDate: .nan)),
        ])
        let store = LearningStore(snapshot: snap, now: { Self.t0 })
        #expect(store.count == 3, "over-long keys and undated entries are dropped")
        #expect(store.effectiveVotes(raw: "go", context: .korean) == [.korean: LearningStore.maxVotes])
        #expect(store.effectiveVotes(raw: "so", context: .korean) == [.korean: LearningStore.maxVotes])
        #expect(store.counts(raw: "go", context: .korean) == UserCounts([.korean: 1000]))
        #expect(store.counts(raw: "so", context: .korean) == UserCounts([.korean: 1000]))
        #expect(store.counts(raw: "to", context: .korean) == UserCounts([.english: 2]))
        store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3)
        #expect(store.counts(raw: "go", context: .korean) == UserCounts([.korean: 1000]), "recording keeps the cap")
    }

    @Test func nonFiniteOrNonPositiveVotesAreNeverRecorded() {
        let store = LearningStore(now: { Self.t0 })
        for amount in [Double.infinity, -.infinity, .nan, -3, 0] {
            store.record(raw: "go", context: .korean, hypothesis: .korean, votes: amount)
        }
        store.record(raw: String(repeating: "a", count: 65), context: .korean, hypothesis: .korean, votes: 3)
        #expect(store.count == 0)
        store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 5_000)
        #expect(store.counts(raw: "go", context: .korean) == UserCounts([.korean: 1000]))
        store.cancel(LearningVote(raw: "go", context: .korean, hypothesis: .korean, amount: .nan))
        #expect(store.counts(raw: "go", context: .korean) == UserCounts([.korean: 1000]))
    }

    // MARK: Ordering and cost at the cap

    @Test func snapshotOrdersEqualDatesByRawThenContext() {
        let entries = [("b", LanguageContext.korean), ("a", .start), ("c", .english), ("a", .korean), ("b", .english)]
            .map { LearningEntry(raw: $0.0, context: $0.1, votes: ["K": 3], updatedAt: Self.t0) }
        let newer = LearningEntry(raw: "z", context: .start, votes: ["E": 1], updatedAt: Self.t0.addingTimeInterval(1))
        let expected = ["z/START", "a/KO", "a/START", "b/EN", "b/KO", "c/EN"]
        for order in [entries + [newer], [newer] + entries.reversed()] {
            let store = LearningStore(snapshot: LearningSnapshot(entries: order), now: { Self.t0 })
            #expect(store.snapshot().entries.map { "\($0.raw)/\($0.context.rawValue)" } == expected)
        }
    }

    @Test func snapshotAndEvictionStayCheapAtTheCap() {
        // The IME takes a snapshot on the main actor for every write, and eviction runs inside
        // `record` while a word is committed. Before: about 57 ms each at 20 000 entries.
        let clock = Clock()
        let full = LearningSnapshot(entries: (0..<LearningStore.capacity).map { i in
            LearningEntry(raw: "w\(i)", context: .start, votes: ["E": 1], updatedAt: Self.t0.addingTimeInterval(TimeInterval(i)))
        })
        let store = LearningStore(snapshot: full, now: { clock.date })
        #expect(store.count == LearningStore.capacity)
        #if !DEBUG
        let c = ContinuousClock()
        var snapshotCost = Duration.seconds(1), evictionCost = Duration.seconds(1)
        var next = LearningStore.capacity
        for _ in 0..<3 {
            snapshotCost = min(snapshotCost, c.measure { _ = store.snapshot() })
            while store.count < LearningStore.capacity {
                next += 1
                clock.date = Self.t0.addingTimeInterval(TimeInterval(next))
                store.record(raw: "w\(next)", context: .start, hypothesis: .english, votes: 1)
            }
            next += 1
            clock.date = Self.t0.addingTimeInterval(TimeInterval(next))
            evictionCost = min(evictionCost, c.measure {
                store.record(raw: "w\(next)", context: .start, hypothesis: .english, votes: 1)
            })
            #expect(store.count < LearningStore.capacity)
        }
        #expect(snapshotCost < .milliseconds(25), "snapshot at the cap: \(snapshotCost)")
        #expect(evictionCost < .milliseconds(25), "evicting record at the cap: \(evictionCost)")
        #endif
    }

    @Test func removeAndReplaceNotify() {
        let store = LearningStore(now: { Self.t0 })
        var changes = 0
        store.onChange = { changes += 1 }
        store.record(raw: "go", context: .korean, hypothesis: .korean, votes: 3)
        store.record(raw: "go", context: .english, hypothesis: .english, votes: 3)
        store.record(raw: "so", context: .korean, hypothesis: .korean, votes: 3)
        store.remove(raw: "go", context: .korean)
        #expect(store.count == 2)
        store.remove(raw: "go", context: nil)
        #expect(store.count == 1)
        store.remove(raw: "absent", context: nil)
        store.replace(with: LearningSnapshot())
        #expect(store.count == 0)
        store.removeAll()
        #expect(changes == 6, "3 records, 2 removals, 1 replace; no-op removals are silent")
    }

    // MARK: Engine votes

    @Test(arguments: [(1386, true), (1387, false), (-500, false)])
    func implicitVoteOnlyWhenTheFinalMarginIsSmall(_ margin: Int, _ learns: Bool) {
        let h = EngineHarness()
        h.detector.scores["g"] = [.korean: -3000, .english: -4000]
        h.detector.scores["go"] = [.korean: -4000, .english: -6000]
        // Negative margin means E wins: the vote goes to the winner, so use |margin| for the check.
        h.detector.finals["go"] = margin >= 0 ? [.korean: -4000, .english: -4000 - margin]
                                              : [.korean: -9000, .english: -1000]
        h.type("go ")
        #expect((h.learned("go", .start) == [.korean: 1]) == learns)
        if !learns { #expect(h.store.count == 0) }
    }

    @Test func singleLetterTokensAreNeverLearned() {
        let h = EngineHarness()
        h.detector.scores["a"] = [.korean: -3000, .english: -3500]
        h.type("a")
        h.flip()
        h.press(.space)
        #expect(h.store.count == 0)
        h.type("i ")
        h.flip()
        #expect(h.store.count == 0)
    }

    @Test(arguments: ["paused", "disabled", "direct"])
    func noLearningWhenPausedDisabledOrDirect(_ mode: String) {
        var settings = DuoSettings()
        if mode == "paused" { settings.learningPaused = true }
        if mode == "disabled" { settings.learningEnabled = false }
        if mode == "direct" { settings.appProfiles["com.apple.TextEdit"] = .direct }
        let h = EngineHarness(settings: settings)
        EngineFlipTests.scriptGo(h.detector)
        if mode == "direct" { h.flip() }   // Bilingual for this line
        h.type("go")
        h.flip()
        h.press(.space)
        #expect(h.text == "go ")
        #expect(h.store.count == 0)
    }

    @Test func secureInputCommitTeachesNothing() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.flip()
        _ = h.commit(.secureInput)
        #expect(h.text == "go")
        #expect(h.store.count == 0)
    }

    @Test func learnedVotesReachTheDetectorInPrefixAndFinalMode() {
        let h = EngineHarness()
        h.store.record(raw: "go", context: .start, hypothesis: .english, votes: 3)
        EngineFlipTests.scriptGo(h.detector)
        h.type("g")
        #expect(h.detector.lastUser == nil)
        h.type("o")
        #expect(h.detector.lastUser == UserCounts([.english: 3]))
        // +5 nats for E in prefix mode: the learned reading shows while typing (R7).
        #expect(h.marked == "go")
        h.press(.space)
        #expect(h.detector.lastUser == UserCounts([.english: 3]))
        #expect(h.text == "go ")
    }

    @Test func disabledLearningIsNotApplied() {
        var settings = DuoSettings()
        settings.learningEnabled = false
        let h = EngineHarness(settings: settings)
        h.store.record(raw: "go", context: .start, hypothesis: .english, votes: 3)
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        #expect(h.detector.lastUser == nil)
        #expect(h.marked == "해")
    }

    @Test func flipThenLearnChangesTheNextCommitInTheSameContextOnly() {
        // One flip is +5 nats: enough to turn an ambiguous word around in that context.
        let h = EngineHarness()
        h.detector.english("hi")
        h.detector.scores["g"] = [.korean: -3000, .english: -3200]
        h.detector.scores["go"] = [.korean: -5000, .english: -3000]
        h.detector.finals["go"] = [.korean: -5000, .english: -3000]
        h.type("hi go ")
        #expect(h.text == "hi go ")
        h.flip()
        #expect(h.text == "hi 해 ")
        #expect(h.learned("go", .english) == [.korean: 3])
        h.type("hi go ")
        #expect(h.text == "hi 해 hi 해 ")
        h.buffer.setText("")
        h.engine.setClient(bundleIdentifier: "com.apple.TextEdit")
        h.type("go ")
        #expect(h.learned("go", .start).isEmpty)
    }

    @Test func learningChangedIsNotifiedOnce() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.flip()
        h.clearNotifications()
        h.press(.space)
        #expect(h.notifications == [.committed(language: .english), .learningChanged])
    }
}

/// SPEC.md §4.2 context tracking.
@MainActor
@Suite("Engine · context")
struct EngineContextTests {
    /// Context the detector saw for the token that starts with the last key typed.
    static func contextOfNextToken(after prefix: String, setup: (EngineHarness) -> Void = { _ in }) -> LanguageContext? {
        let h = EngineHarness()
        h.detector.english("hi")
        h.detector.korean("dkssud")
        setup(h)
        h.type(prefix)
        h.detector.reset()
        h.press(.letter("z"))
        return h.detector.prefixContexts.first
    }

    @Test(arguments: [
        ("", LanguageContext.start),
        ("hi ", .english),
        ("dkssud ", .korean),
        ("hi, ", .english),
        ("dkssud (", .korean),
        ("hi \"", .english),
        ("hi. ", .start),
        ("dkssud? ", .start),
        ("hi.\" ", .start),
        ("dkssud!", .korean),
        ("hi\n", .start),
        ("hi\t", .start),
        ("3", .number),
        ("10", .number),
        ("3 ", .start),
        ("hi 3 ", .english),
        ("dkssud-", .korean),
    ])
    func contextForTheNextToken(_ prefix: String, _ expected: LanguageContext) {
        #expect(Self.contextOfNextToken(after: prefix) == expected)
    }

    @Test func mixedReadingCountsAsKorean() {
        let h = EngineHarness()
        h.detector.latinWords = ["push"]
        h.detector.english("push")
        h.detector.scores["pushg"] = [.korean: -42545, .english: -23964, .mixed(latin: 4): -19991]
        h.detector.scores["pushgo"] = [.korean: -49991, .english: -26493, .mixed(latin: 4): -20698]
        h.type("pushgo ")
        h.detector.reset()
        h.press(.letter("z"))
        #expect(h.detector.prefixContexts == [.korean])
    }

    @Test(arguments: [KeyEvent.Key.arrowLeft, .arrowUp, .navigation])
    func navigationStartsASentence(_ key: KeyEvent.Key) {
        let h = EngineHarness()
        h.detector.english("hi")
        h.type("hi ")
        h.press(key)
        h.detector.reset()
        h.press(.letter("z"))
        #expect(h.detector.prefixContexts == [.start])
    }

    @Test(arguments: [CommitReason.mouse, .deactivate, .secureInput])
    func focusChangesStartASentence(_ reason: CommitReason) {
        let h = EngineHarness()
        h.detector.english("hi")
        h.type("hi ")
        _ = h.commit(reason)
        h.press(.letter("z"))
        #expect(h.detector.prefixContexts.last == .start)
    }

    @Test(arguments: [KeyEvent.letter("a", .command), .letter("z", .control), KeyEvent(.character("2"), modifiers: .option)])
    func shortcutsAndOptionSymbolsKeepTheContext(_ key: KeyEvent) {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.press(key)
        h.detector.reset()
        h.press(.letter("z"))
        #expect(h.detector.prefixContexts == [.korean])
    }

    @Test func commitCompositionKeepsTheContext() {
        let h = EngineHarness()
        h.detector.english("hi")
        h.detector.scores["y"] = [.korean: -4000, .english: -3000]
        h.type("hi y")
        _ = h.commit(.commitComposition)
        h.detector.reset()
        h.press(.letter("z"))
        #expect(h.detector.prefixContexts == [.english])
    }

    @Test func contextIsFrozenAtTokenStart() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.detector.reset()
        h.type("dkssud ")
        #expect(Set(h.detector.prefixContexts) == [.korean])
        #expect(h.detector.finalCalls.map(\.context) == [.korean])
    }
}
