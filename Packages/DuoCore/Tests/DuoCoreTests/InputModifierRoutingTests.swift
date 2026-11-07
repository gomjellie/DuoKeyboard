import DuoCore
import DuoKit
import Foundation
import Testing

/// The input method's modifier routing rules (DuoInputMethod `ModifierRouter`, review qa-1 / imk-1):
/// Chromium's duplicate `flagsChanged`, and chords whose key the input method never sees.
@Suite("Input · modifier routing")
struct InputModifierRoutingTests {
    typealias Flags = FlipTapDetector.Flags
    typealias KeyCode = FlipTapDetector.KeyCode

    static let rightCommandDown = Flags.command | Flags.rightCommandDevice

    /// A copy filter driven one change at a time (`#expect` cannot call a mutating method).
    final class Copies {
        var filter = ModifierRouting.CopyFilter()
        func isNew(_ keyCode: UInt16, _ flags: UInt, at time: TimeInterval) -> Bool {
            filter.isNewChange(keyCode: keyCode, flags: flags, at: time)
        }
    }

    /// An activity counter driven one change at a time.
    final class Activity {
        var counter: ModifierRouting.ActivityCounter
        init(count: UInt32) { counter = ModifierRouting.ActivityCounter(count: count) }
        func otherInput(count: UInt32, at time: TimeInterval, lastInput: () -> TimeInterval) -> Bool {
            counter.otherInputBefore(count: count, eventTimestamp: time, lastInputUptime: lastInput)
        }
    }

    // MARK: Copies

    @Test func chromiumsSecondCopyIsDroppedEvenWithoutDeviceBits() {
        // Live QA: the global monitor's copy has device bits, the IMK copy ~2 ms later has none.
        let copies = Copies()
        #expect(copies.isNew(KeyCode.rightCommand, Self.rightCommandDown, at: 10))
        #expect(!copies.isNew(KeyCode.rightCommand, Flags.command, at: 10.002))
        #expect(copies.isNew(KeyCode.rightCommand, 0, at: 10.08), "the release is a new change")
        #expect(!copies.isNew(KeyCode.rightCommand, 0, at: 10.082))
    }

    @Test func aTapTypedTwiceQuicklyIsTwoTaps() {
        let copies = Copies()
        let changes: [(UInt, TimeInterval)] = [(Self.rightCommandDown, 1.00), (0, 1.06), (Self.rightCommandDown, 1.12), (0, 1.18)]
        for (flags, time) in changes {
            #expect(copies.isNew(KeyCode.rightCommand, flags, at: time))
        }
    }

    @Test func theSameStateLaterOrFromAnotherKeyIsNew() {
        let copies = Copies()
        #expect(copies.isNew(KeyCode.leftShift, Flags.shift, at: 5))
        #expect(copies.isNew(KeyCode.rightShift, Flags.shift, at: 5.01), "another key")
        #expect(copies.isNew(KeyCode.rightShift, Flags.shift, at: 5.01 + ModifierRouting.CopyFilter.copyWindow),
                "outside the copy window")
    }

    // MARK: Activity the engine did not see

    @Test func nothingTypedBetweenChangesIsATap() {
        let activity = Activity(count: 40)
        #expect(!activity.otherInput(count: 40, at: 10, lastInput: { Issue.record("read without a change"); return 0 }))
        #expect(!activity.otherInput(count: 40, at: 10.08, lastInput: { 0 }))
    }

    @Test func aShortcutTheMenuTookBetweenPressAndReleaseIsAChord() {
        // Right ⌘ down, C (routed to the menu, never seen by the input method), right ⌘ up.
        let activity = Activity(count: 40)
        #expect(!activity.otherInput(count: 40, at: 10, lastInput: { 9 }))
        #expect(activity.otherInput(count: 41, at: 10.15, lastInput: { 10.1 }))
    }

    @Test func aQuickChordsKeyCountedBeforeThePressIsHandledStillCounts() {
        // ⌘C typed fast: when the press is handled, the window server has already counted the C.
        // It belongs to the release, which must see it.
        let activity = Activity(count: 40)
        #expect(!activity.otherInput(count: 41, at: 10, lastInput: { 10.03 }), "press: carried over")
        #expect(activity.otherInput(count: 41, at: 10.12, lastInput: { 10.03 }), "release: a chord")
    }

    @Test func typingBeforeThePressAndAQuickChordKeyBothCount() {
        // Two keys since the last change: one typed before the press, and the chord's C, already
        // counted, which is carried to the release (review imk-1: before, only a delta of exactly 1
        // was carried, so the release looked like a tap and ⌘C flipped the word).
        let activity = Activity(count: 40)
        #expect(activity.otherInput(count: 42, at: 10, lastInput: { 10.03 }))
        #expect(activity.otherInput(count: 42, at: 10.12, lastInput: { 10.03 }))
        #expect(!activity.otherInput(count: 42, at: 10.5, lastInput: { 10.03 }), "spent")
    }

    @Test func aKeyTypedRightAfterATapsReleaseBelongsToTheNextChange() {
        // The release is handled after the next letter was counted: the tap still flips.
        let activity = Activity(count: 7)
        #expect(!activity.otherInput(count: 7, at: 3, lastInput: { 2 }))
        #expect(!activity.otherInput(count: 8, at: 3.08, lastInput: { 3.1 }))
        #expect(activity.otherInput(count: 8, at: 4, lastInput: { 3.1 }), "the next press sees it")
    }

    @Test func theCountersWrapAround() {
        let activity = Activity(count: .max)
        #expect(activity.otherInput(count: 0, at: 10, lastInput: { 9 }))
        #expect(!activity.otherInput(count: 0, at: 10.1, lastInput: { 9 }))
    }

    // MARK: With the engine

    @MainActor
    @Test func unseenActivityBetweenPressAndReleaseMeansNoFlip() {
        // What the router does with the answer: `noteKeyActivity()` before the release reaches the
        // engine disarms the tap, so the last word stays as typed.
        let h = EngineHarness()
        h.detector.english("so")
        h.type("so ")
        h.now += 0.05
        h.engine.handleModifier(ModifierEvent(keyCode: KeyCode.rightCommand, flags: Self.rightCommandDown, timestamp: h.now),
                                client: h.client)
        h.engine.noteKeyActivity()
        h.now += 0.08
        h.engine.handleModifier(ModifierEvent(keyCode: KeyCode.rightCommand, flags: 0, timestamp: h.now), client: h.client)
        #expect(h.text == "so ")
        h.flip()
        #expect(h.text != "so ", "a real tap afterwards still flips the word")
    }
}
