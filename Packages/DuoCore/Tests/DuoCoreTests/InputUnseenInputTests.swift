import DuoKit
import Foundation
import Testing

/// `UnseenInputCounter` (SPEC.md 4.9절): a key or click the app handled without the input method,
/// such as a Return Telegram sends on when nothing is marked.
@Suite("Input · unseen keys and clicks")
struct InputUnseenInputTests {
    /// A counter driven one event at a time (`#expect` cannot call a mutating method).
    final class Counter {
        var counter: UnseenInputCounter
        init(count: UInt32) { counter = UnseenInputCounter(count: count) }
        func unseen(own: UInt32 = 1, count: UInt32, at time: TimeInterval, lastInput: () -> TimeInterval) -> Bool {
            counter.unseenBefore(own: own, count: count, eventTimestamp: time, lastInputUptime: lastInput)
        }
    }

    @Test func keysTheInputMethodHandlesOneByOneAreAllSeen() {
        let c = Counter(count: 40)
        for (i, time) in [10.0, 10.1, 10.2].enumerated() {
            #expect(!c.unseen(count: 41 + UInt32(i), at: time, lastInput: { Issue.record("read without a gap"); return time }))
        }
    }

    @Test func aReturnTheAppHandledItselfIsUnseen() {
        let c = Counter(count: 40)
        #expect(!c.unseen(count: 41, at: 10, lastInput: { 10 }))
        // Return at 10.3 went to the app only; the next key at 10.8 is handled.
        #expect(c.unseen(count: 43, at: 10.8, lastInput: { 10.8 }))
        #expect(!c.unseen(count: 44, at: 10.9, lastInput: { 10.9 }), "counted once")
    }

    @Test func theEventItselfCountedAHairLaterIsNotAKeyTypedAfterIt() {
        let c = Counter(count: 40)
        #expect(c.unseen(count: 42, at: 10.8, lastInput: { 10.8 + 0.0002 }))
    }

    @Test func aKeyTypedRightAfterIsCarriedToTheNextEvent() {
        let c = Counter(count: 40)
        #expect(!c.unseen(count: 42, at: 10, lastInput: { 10.02 }), "the next key is already counted")
        #expect(!c.unseen(count: 42, at: 10.02, lastInput: { 10.02 }), "and it is that key")
    }

    @Test func anUnseenReturnFollowedByTwoFastKeysIsStillUnseen() {
        let c = Counter(count: 40)
        #expect(c.unseen(count: 43, at: 10.5, lastInput: { 10.52 }))
        #expect(!c.unseen(count: 43, at: 10.52, lastInput: { 10.52 }))
    }

    @Test func aClickBeforeAModifierChangeIsUnseen() {
        let c = Counter(count: 40)
        #expect(!c.unseen(own: 0, count: 40, at: 10, lastInput: { 9 }))
        #expect(c.unseen(own: 0, count: 41, at: 11, lastInput: { 10.5 }), "a click on the app's Send button")
    }

    @Test func injectedEventsTheCountersNeverSawAreNotUnseen() {
        let c = Counter(count: 40)
        #expect(!c.unseen(count: 40, at: 10, lastInput: { 9 }))
        #expect(!c.unseen(count: 40, at: 10.1, lastInput: { 9 }))
    }

    @Test func theCountersWrapAround() {
        let c = Counter(count: .max)
        #expect(!c.unseen(count: 0, at: 10, lastInput: { 10 }))
        #expect(c.unseen(count: 2, at: 11, lastInput: { 11 }))
    }
}
