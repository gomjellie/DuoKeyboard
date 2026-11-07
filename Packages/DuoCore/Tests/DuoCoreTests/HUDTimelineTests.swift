import DuoCore
import DuoKit
import Foundation
import Testing

private func alternative(_ text: String, eligible: Bool = true, pulse: Bool = false) -> HUDRequest {
    let choice = HUDChoice(current: HUDReading(text: "·", language: .korean),
                           other: HUDReading(text: text, language: .english), currentFirst: true)
    return HUDRequest(content: .alternative(choice, eligible: eligible), anchor: .markedText, pulse: pulse)
}

private let chip = HUDRequest(
    content: .flipLastWord(HUDChoice(current: HUDReading(text: "해", language: .korean),
                                     other: HUDReading(text: "go", language: .english), currentFirst: true)),
    anchor: .location(10), immediate: true, lifetime: 1.6)
private let oneShot = HUDRequest(content: .oneShot(.english), anchor: .caret, immediate: true, lifetime: 0.9)

private let timing = HUDTimeline.Timing.standard

@Suite("HUD timeline: appearing")
struct HUDTimelineAppearTests {
    @Test("an eligible alternative appears only after a 300 ms typing pause")
    func appearsAfterPause() {
        var t = HUDTimeline()
        #expect(t.receive(alternative("dk"), at: 10) == nil)
        #expect(t.nextDeadline == 10 + timing.appearDelay)
        #expect(t.advance(to: 10.299) == nil)
        #expect(t.advance(to: 10 + timing.appearDelay) == .show(alternative("dk")))
        #expect(t.isVisible)
        #expect(t.nextDeadline == nil)
    }

    @Test("every keystroke restarts the pause; the latest request is the one shown")
    func keystrokesRestartPause() {
        var t = HUDTimeline()
        _ = t.receive(alternative("dk"), at: 10)
        _ = t.receive(alternative("dks"), at: 10.2)
        #expect(t.advance(to: 10.35) == nil)
        _ = t.receive(alternative("dkss"), at: 10.4)
        #expect(t.advance(to: 10.69) == nil)
        #expect(t.advance(to: 10.4 + timing.appearDelay) == .show(alternative("dkss")))
    }

    @Test("an ineligible alternative never brings the HUD up")
    func ineligibleStaysHidden() {
        var t = HUDTimeline()
        #expect(t.receive(alternative("a", eligible: false), at: 10) == nil)
        #expect(t.nextDeadline == nil)
        #expect(t.advance(to: 20) == nil)
        #expect(!t.isVisible)
    }

    @Test("an ineligible request cancels a pending appearance")
    func ineligibleCancelsPending() {
        var t = HUDTimeline()
        _ = t.receive(alternative("dk"), at: 10)
        _ = t.receive(alternative("dks", eligible: false), at: 10.1)
        #expect(t.nextDeadline == nil)
        #expect(t.advance(to: 11) == nil)
    }

    @Test("nil cancels a pending appearance without a hide command")
    func nilCancelsPending() {
        var t = HUDTimeline()
        _ = t.receive(alternative("dk"), at: 10)
        #expect(t.receive(nil, at: 10.1) == nil)
        #expect(t.phase == .hidden)
    }

    @Test("immediate requests appear at once", arguments: [chip, oneShot,
        HUDRequest(content: .cannotChange, anchor: .caret, immediate: true, lifetime: 1.2)])
    func immediateAppearsAtOnce(request: HUDRequest) {
        var t = HUDTimeline()
        #expect(t.receive(request, at: 10) == .show(request))
        #expect(t.isVisible)
    }

    @Test("an immediate request replaces a pending one at once")
    func immediateReplacesPending() {
        var t = HUDTimeline()
        _ = t.receive(alternative("go"), at: 10)
        #expect(t.receive(chip, at: 10.1) == .show(chip))
    }
}

@Suite("HUD timeline: latching and updating")
struct HUDTimelineLatchTests {
    private func visible(_ request: HUDRequest = alternative("dk")) -> HUDTimeline {
        var t = HUDTimeline()
        _ = t.receive(request, at: 10)
        _ = t.advance(to: 10 + timing.appearDelay)
        return t
    }

    @Test("a visible alternative updates in place on every keystroke")
    func updatesInPlace() {
        var t = visible()
        #expect(t.receive(alternative("dks"), at: 10.4) == .update(alternative("dks"), pulse: false))
        #expect(t.visibleRequest == alternative("dks"))
    }

    @Test("a visible alternative latches while the token composes, even when no longer eligible")
    func latchesWhenIneligible() {
        var t = visible()
        let next = alternative("dkss", eligible: false)
        #expect(t.receive(next, at: 10.4) == .update(next, pulse: false))
        #expect(t.isVisible)
        #expect(t.nextDeadline == nil)
    }

    @Test("pulse passes through for in-place updates")
    func pulseOnUpdate() {
        var t = visible()
        #expect(t.receive(alternative("rk", pulse: true), at: 10.4) == .update(alternative("rk", pulse: true), pulse: true))
    }

    @Test("a first appearance never carries the pulse")
    func noPulseOnShow() {
        var t = HUDTimeline()
        _ = t.receive(alternative("rk", pulse: true), at: 10)
        #expect(t.advance(to: 10 + timing.appearDelay) == .show(alternative("rk", pulse: true)))
    }

    @Test("an ineligible alternative while a chip is up starts the hide debounce")
    func ineligibleAfterChipHides() {
        var t = HUDTimeline()
        _ = t.receive(chip, at: 10)
        #expect(t.receive(alternative("a", eligible: false), at: 10.5) == nil)
        #expect(t.nextDeadline == 10.5 + timing.hideDebounce)
        #expect(t.advance(to: 10.5 + timing.hideDebounce) == .hide)
    }

    @Test("an eligible alternative after a chip hides the chip and still waits for the typing pause")
    func eligibleAfterChipWaitsForPause() {
        var t = HUDTimeline()
        _ = t.receive(chip, at: 10)
        #expect(t.receive(alternative("dk"), at: 10.5) == .hide)
        #expect(!t.isVisible)
        #expect(t.nextDeadline == 10.5 + timing.appearDelay)
        #expect(t.advance(to: 10.5 + timing.appearDelay - 0.01) == nil)
        #expect(t.advance(to: 10.5 + timing.appearDelay) == .show(alternative("dk")))
        #expect(t.nextDeadline == nil, "the chip's lifetime is gone with the chip")
    }

    @Test("an immediate request still replaces a visible chip in place")
    func immediateReplacesChipInPlace() {
        var t = HUDTimeline()
        _ = t.receive(chip, at: 10)
        #expect(t.receive(oneShot, at: 10.5) == .update(oneShot, pulse: false))
        #expect(t.nextDeadline == 10.5 + 0.9)
    }
}

@Suite("HUD timeline: feedback on screen does not skip the pause")
struct HUDTimelineFeedbackPauseTests {
    private static let cannotChange = HUDRequest(content: .cannotChange, anchor: .caret, immediate: true, lifetime: 1.2)
    private static let bilingual = HUDRequest(content: .bilingualLine, anchor: .caret, immediate: true)

    @Test("a chip, badge or message gives way to a new word's alternative only after the pause",
          arguments: [chip, oneShot, cannotChange, bilingual])
    func feedbackThenAlternative(feedback: HUDRequest) {
        var t = HUDTimeline()
        #expect(t.receive(feedback, at: 10) == .show(feedback))
        #expect(t.receive(alternative("dk"), at: 10.08) == .hide)
        #expect(t.advance(to: 10.08 + timing.appearDelay) == .show(alternative("dk")))
    }

    @Test("typing straight through after `go␣`'s chip brings up nothing: the burst never paused")
    func burstAfterChipShowsNothing() {
        // `go␣` commits uncertainly (chip), then `dkssud` at 80 ms per key; only `dk` is eligible.
        var t = HUDTimeline()
        _ = t.receive(chip, at: 10)
        var commands: [HUDTimeline.Command] = []
        let keys: [(String, Bool)] = [("d", false), ("dk", true), ("dks", false), ("dkss", false), ("dkssu", false), ("dkssud", false)]
        for (i, key) in keys.enumerated() {
            let now = 10.08 + 0.08 * Double(i)
            if let deadline = t.nextDeadline, deadline <= now, let c = t.advance(to: deadline) { commands.append(c) }
            if let c = t.receive(alternative(key.0, eligible: key.1), at: now) { commands.append(c) }
        }
        if let deadline = t.nextDeadline, let c = t.advance(to: deadline) { commands.append(c) }
        #expect(!commands.contains { if case .update = $0 { true } else { false } }, "\(commands)")
        #expect(!commands.contains { if case .show(let r) = $0 { r != chip } else { false } }, "\(commands)")
        #expect(!t.isVisible)
    }
}

@Suite("HUD timeline: the Bilingual-line badge")
struct HUDTimelineBilingualTests {
    private static let badge = HUDRequest(content: .bilingualLine, anchor: .caret, immediate: true)

    /// What the engine asks for in a Direct-profile terminal with hints on: right ⌘ turns Bilingual
    /// on (badge), each key of a word that has not earned the HUD asks for an ineligible alternative,
    /// and the commit at Space asks for the badge again.
    @Test("the badge stays up while words that have not earned the HUD are typed under it")
    func badgeStaysWhileTyping() {
        var t = HUDTimeline()
        var commands: [HUDTimeline.Command] = []
        func feed(_ request: HUDRequest?, at now: TimeInterval, trigger: HUDTimeline.Trigger = .keystroke) {
            while let deadline = t.nextDeadline, deadline <= now, let c = t.advance(to: deadline) { commands.append(c) }
            if let c = t.receive(request, at: now, trigger: trigger) { commands.append(c) }
        }
        feed(Self.badge, at: 10, trigger: .other)                 // right ⌘
        var now = 10.0
        for word in ["qjrm", "tnwjd"] {                           // 버그 수정, 200 ms per key
            for i in 1...word.count {
                now += 0.2
                feed(alternative(String(word.prefix(i)), eligible: false), at: now)
            }
            now += 0.2
            feed(Self.badge, at: now)                             // Space commits; badge again
        }
        feed(Self.badge, at: now + 5, trigger: .other)            // a later ⇧ press changes nothing
        #expect(commands.first == .show(Self.badge))
        #expect(!commands.contains(.hide), "\(commands)")
        #expect(t.isVisible)
        #expect(t.visibleRequest == Self.badge)
    }

    @Test("an eligible alternative under the badge waits for the pause; the commit brings the badge back in place")
    func eligibleUnderBadge() {
        var t = HUDTimeline()
        _ = t.receive(Self.badge, at: 10, trigger: .other)
        #expect(t.receive(alternative("dk"), at: 10.2) == .hide)
        #expect(t.advance(to: 10.2 + timing.appearDelay) == .show(alternative("dk")))
        #expect(t.receive(Self.badge, at: 11) == .update(Self.badge, pulse: false))
        #expect(t.nextDeadline == nil, "the badge has no lifetime")
    }

    @Test("leaving Bilingual (nil) still hides the badge after the debounce")
    func leavingBilingualHides() {
        var t = HUDTimeline()
        _ = t.receive(Self.badge, at: 10, trigger: .other)
        #expect(t.receive(nil, at: 11) == nil)
        #expect(t.advance(to: 11 + timing.hideDebounce) == .hide)
    }

    @Test("an ineligible alternative during the badge's hide debounce does not cancel the hide")
    func hidingBadgeStaysHidden() {
        var t = HUDTimeline()
        _ = t.receive(Self.badge, at: 10, trigger: .other)
        _ = t.receive(nil, at: 11)
        #expect(t.receive(alternative("q", eligible: false), at: 11.05) == nil)
        #expect(t.advance(to: 11 + timing.hideDebounce) == .hide)
    }
}

@Suite("HUD timeline: hiding")
struct HUDTimelineHideTests {
    private func visible() -> HUDTimeline {
        var t = HUDTimeline()
        _ = t.receive(alternative("dk"), at: 10)
        _ = t.advance(to: 10 + timing.appearDelay)
        return t
    }

    @Test("nil hides after the 140 ms debounce")
    func hidesAfterDebounce() {
        var t = visible()
        #expect(t.receive(nil, at: 11) == nil)
        #expect(t.isVisible)
        #expect(t.nextDeadline == 11 + timing.hideDebounce)
        #expect(t.advance(to: 11.139) == nil)
        #expect(t.advance(to: 11 + timing.hideDebounce) == .hide)
        #expect(t.phase == .hidden)
    }

    @Test("an eligible request inside the debounce keeps the HUD up (no blink between words)")
    func debounceCancelledByEligible() {
        var t = visible()
        _ = t.receive(nil, at: 11)
        #expect(t.receive(alternative("gk"), at: 11.1) == .update(alternative("gk"), pulse: false))
        #expect(t.nextDeadline == nil)
        #expect(t.advance(to: 12) == nil)
    }

    @Test("an ineligible request inside the debounce does not resurrect the HUD")
    func debounceNotCancelledByIneligible() {
        var t = visible()
        _ = t.receive(nil, at: 11)
        #expect(t.receive(alternative("g", eligible: false), at: 11.05) == nil)
        #expect(t.advance(to: 11 + timing.hideDebounce) == .hide)
    }

    @Test("lifetimes are honoured", arguments: [chip, oneShot])
    func lifetime(request: HUDRequest) throws {
        var t = HUDTimeline()
        _ = t.receive(request, at: 10)
        let lifetime = try #require(request.lifetime)
        #expect(t.nextDeadline == 10 + lifetime)
        #expect(t.advance(to: 10 + lifetime - 0.01) == nil)
        #expect(t.advance(to: 10 + lifetime) == .hide)
    }

    @Test("a hide request never extends a shorter running lifetime")
    func debounceKeepsEarlierLifetime() {
        var t = HUDTimeline()
        _ = t.receive(oneShot, at: 10)
        _ = t.receive(nil, at: 10.85)   // lifetime ends at 10.9, debounce would end at 10.99
        #expect(t.nextDeadline == 10 + 0.9)
    }

    @Test("reset drops everything without a command")
    func reset() {
        var t = visible()
        t.reset()
        #expect(t.phase == .hidden)
        #expect(t.nextDeadline == nil)
        #expect(t.advance(to: 100) == nil)
    }
}

@Suite("HUD timeline: triggers")
struct HUDTimelineTriggerTests {
    @Test("identical requests from non-keystroke events are ignored")
    func nonKeystrokeDedupes() {
        var t = HUDTimeline()
        _ = t.receive(alternative("dk"), at: 10)
        _ = t.receive(alternative("dk"), at: 10.25, trigger: .other)   // ⇧ pressed: must not restart the pause
        #expect(t.nextDeadline == 10 + timing.appearDelay)
    }

    @Test("an expired chip is not resurrected by a modifier press")
    func expiredChipStaysHidden() {
        var t = HUDTimeline()
        _ = t.receive(chip, at: 10)
        _ = t.advance(to: 11.7)
        #expect(t.receive(chip, at: 12, trigger: .other) == nil)
        #expect(!t.isVisible)
    }

    @Test("a keystroke re-shows an identical chip (Backspace right after the commit)")
    func keystrokeReshowsChip() {
        var t = HUDTimeline()
        _ = t.receive(chip, at: 10)
        _ = t.advance(to: 11.7)
        #expect(t.receive(chip, at: 12) == .show(chip))
    }

    @Test("a stale request after a reset does not come back on a modifier press")
    func resetRemembersLastRequest() {
        var t = HUDTimeline()
        _ = t.receive(chip, at: 10)
        t.reset()
        #expect(t.receive(chip, at: 10.5, trigger: .other) == nil)
    }

    @Test("a changed request from a non-keystroke event (a flip) is applied")
    func flipFromModifier() {
        var t = HUDTimeline()
        #expect(t.receive(oneShot, at: 10, trigger: .other) == .show(oneShot))
        #expect(t.receive(nil, at: 10.2, trigger: .other) == nil)
        #expect(t.nextDeadline == 10.2 + timing.hideDebounce)
    }

    @Test("IME feedback survives the engine's unchanged nil on the next modifier press")
    func feedbackKeepsEngineRequest() {
        var t = HUDTimeline()
        _ = t.receive(nil, at: 9)   // engine: nothing to show
        let message = HUDRequest(content: .cannotChange, anchor: .caret, immediate: true, lifetime: 1.2)
        #expect(t.receive(message, at: 10, trigger: .feedback) == .show(message))
        #expect(t.receive(nil, at: 10.2, trigger: .other) == nil)
        #expect(t.nextDeadline == 10 + 1.2)
        // A keystroke still dismisses it with the normal debounce.
        _ = t.receive(nil, at: 10.5)
        #expect(t.nextDeadline == 10.5 + timing.hideDebounce)
    }
}

