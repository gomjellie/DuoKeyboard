import Foundation
import Testing
@testable import DuoCore

/// SPEC.md §4.8 reasons, §4.9 resync, §4.3.7/§4.8.3 HUD requests, critique R15.
@MainActor
@Suite("Engine · robustness and HUD")
struct EngineRobustnessTests {
    typealias Call = RecordingClient.Call

    // MARK: Resync (R18 #7)

    @Test func clearedFieldDropsTheTokenSilentlyAfterAPause() {
        // ux-spec §9 #85: Slack clears the field after sending.
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.detector.korean("g")
        h.type("dkssud")
        h.buffer.clear()
        let step = h.press(.letter("g"), after: 1.5)
        #expect(step.calls == [.markedRange, .mark("ㅎ", nil)], "no ghost re-insert of 안녕")
        #expect(h.text == "ㅎ")
        #expect(h.engine.rawKeys == "g")
    }

    @Test func noResyncCallWithinOneSecond() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        let step = h.press(.letter("g"), after: 0.9)
        #expect(step.calls.count == 1)
    }

    @Test func resyncAppliesToBoundariesToo() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        h.buffer.clear()
        let step = h.press(.space, after: 2)
        #expect(step.calls == [.markedRange])
        #expect(h.text == " ")
    }

    @Test func resyncKeepsALiveComposition() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkss")
        let step = h.press(.letter("u"), after: 3)
        #expect(step.calls == [.markedRange, .mark("안녀", nil)])
    }

    @Test func commitCompositionAfterTheClientUnmarkedDoesNotInsertTwice() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        h.buffer.unmarkText()
        let calls = h.commit(.commitComposition)
        #expect(calls == [.markedRange])
        #expect(h.text == "안녕")
        #expect(!h.engine.isComposing)
    }

    @Test func commitCompositionCommitsAsUsual() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        let calls = h.commit(.commitComposition)
        #expect(calls == [.markedRange, .insert("안녕", nil), .selectedRange])
        #expect(h.engine.lastCommit != nil, "commitComposition keeps the word flippable")
    }

    // MARK: Mouse, deactivate, secure input (R4, R5, R18 #6)

    @Test(arguments: [CommitReason.mouse, .deactivate, .secureInput])
    func reasonCommitsInsertOnceAndForgetTheWord(_ reason: CommitReason) {
        let h = EngineHarness()
        h.detector.korean("dkssu")
        h.type("dkssu")
        let calls = h.commit(reason)
        #expect(calls == [.markedRange, .insert("안녀", nil)], "ux-spec §9 #81: committed as shown, no flip record")
        #expect(h.text == "안녀")
        #expect(h.engine.lastCommit == nil)
        #expect(h.hud == nil)
        #expect(h.detector.finalCalls.map(\.terminator) == [.space])
    }

    @Test(arguments: [CommitReason.mouse, .deactivate, .secureInput])
    func reasonCommitAfterTheAppClearedTheFieldInsertsNoGhost(_ reason: CommitReason) {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        h.buffer.clear()
        h.now += 2
        let calls = h.commit(reason)
        #expect(calls == [.markedRange])
        #expect(h.text == "")
        #expect(!h.engine.isComposing)
    }

    @Test(arguments: [CommitReason.mouse, .deactivate])
    func reasonCommitAfterTheClientKeptTheStringDoesNotInsertTwice(_ reason: CommitReason) {
        // Chromium can end the composition itself (blur) before IMK deactivates the session.
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        h.buffer.unmarkText()
        _ = h.commit(reason)
        #expect(h.text == "안녕")
    }

    @Test(arguments: [(UInt16(57), UInt(FlipTapDetector.Flags.capsLock)), (UInt16(63), UInt(FlipTapDetector.Flags.function))])
    func capsLockOrGlobeAfterAClearedFieldInsertsNoGhost(_ keyCode: UInt16, _ flag: UInt) {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        h.buffer.clear()
        h.now += 2
        _ = h.client.take()
        h.engine.handleModifier(ModifierEvent(keyCode: keyCode, flags: flag, timestamp: h.now), client: h.client)
        #expect(h.client.take() == [.markedRange])
        #expect(h.text == "")
        #expect(!h.engine.isComposing)
    }

    @Test func reasonCommitWithNothingComposingSendsNothing() {
        let h = EngineHarness()
        #expect(h.commit(.mouse).isEmpty)
        #expect(h.commit(.deactivate).isEmpty)
    }

    @Test func mouseDisarmsAPendingTapAndEndsLiteralAndOneShot() {
        let h = EngineHarness()
        h.type("/x")
        h.flip()
        _ = h.commit(.mouse)
        #expect(!h.engine.literal)
        _ = h.client.take()
        h.engine.handleModifier(ModifierEvent(keyCode: 54, flags: FlipTapDetector.Flags.command | 0x10, timestamp: h.now),
                                client: h.client)
        _ = h.commit(.mouse)
        h.engine.handleModifier(ModifierEvent(keyCode: 54, flags: 0, timestamp: h.now + 0.05), client: h.client)
        #expect(h.engine.oneShot == nil, "the click disarmed the tap")
    }

    @Test func setClientForgetsEverything() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.flip()   // case (b): flips 안녕 → dkssud
        h.engine.setClient(bundleIdentifier: "com.googlecode.iterm2")
        #expect(h.engine.clientProfile.replacement == .none)
        #expect(h.engine.lastCommit == nil)
        #expect(!h.engine.isComposing)
    }

    // MARK: HUD while composing (§4.3.7)

    @Test func alternativeIsEligibleWhenCloseAndLongEnough() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("g")
        #expect(h.hud?.alternativeText == "g")
        #expect(h.hud?.isEligible == false, "one key outside the collision set")
        h.type("o")
        #expect(h.hud == HUDRequest(content: .alternative(bar("해", .korean, offering: "go", .english, currentFirst: true),
                                                          eligible: true), anchor: .markedText))
    }

    @Test(arguments: ["a", "e", "i", "o", "u", "x", "I"])
    func collisionKeysAreEligibleAfterOneKey(_ key: String) {
        let h = EngineHarness()
        h.detector.scores[key] = [.korean: -3000, .english: -3200]
        h.type(key)
        #expect(h.hud?.isEligible == true)
    }

    @Test(arguments: [(2944, true), (2945, false)])
    func theBarIsEligibleUpToFivePercent(_ margin: Int, _ eligible: Bool) {
        // Margins.hudCandidates: the other reading has P ≥ 5 %.
        let h = EngineHarness()
        h.detector.scores["dk"] = [.korean: -2000, .english: -2000 - margin]
        h.type("dk")
        #expect(h.hud?.isEligible == eligible)
        #expect(h.hud?.alternativeText == "dk", "always sent, so a visible HUD can update in place")
    }

    @Test(arguments: [2944, 2945, 20_000])
    func alwaysShowChoicesMakesTheBarEligibleAtAnyMargin(_ margin: Int) {
        var settings = DuoSettings()
        settings.alwaysShowChoices = true
        let h = EngineHarness(settings: settings)
        h.detector.scores["dk"] = [.korean: -2000, .english: -2000 - margin]
        h.type("d")
        #expect(h.hud?.isEligible == true, "from the first key, as a candidate window is")
        h.type("k")
        #expect(h.hud?.isEligible == true, "unlikely readings are listed too: the user picks")
        #expect(h.hud?.alternativeText == "dk")
    }

    @Test func autorepeatIsNeverEligible() {
        // ux-spec §9 #80.
        let h = EngineHarness()
        h.detector.scores["zz"] = [.korean: -3000, .english: -3100]
        h.press(.letter("z"))
        h.press(KeyEvent(.letter(Keystroke(base: "z", shift: false)), isRepeat: true))
        #expect(h.marked == "ㅋㅋ")
        #expect(h.hud?.isEligible == false)
    }

    @Test func hintsOffMeansNoAlternative() {
        var settings = DuoSettings()
        settings.showHints = false
        let h = EngineHarness(settings: settings)
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        #expect(h.hud == nil)
    }

    @Test(arguments: [
        // (scores, shown, alternative): K → best of {E, M}; E → best of {K, M}; M → E.
        ([Hypothesis.korean: -1000, .english: -5000, .mixed(latin: 2): -3000], "ㅖㄲ을", "PR을"),
        ([Hypothesis.korean: -9000, .english: -1000, .mixed(latin: 2): -3000], "PRdmf", "PR을"),
        ([Hypothesis.korean: -3000, .english: -5000, .mixed(latin: 2): -1000], "PR을", "PRdmf"),
    ])
    func alternativeFollowsR11(_ scores: [Hypothesis: Int], _ shown: String, _ alternative: String) {
        var settings = DuoSettings()
        settings.eagerEnglishCommit = false
        let h = EngineHarness(settings: settings)
        h.detector.fallback = { _ in scores }
        h.type("PRdmf")
        #expect(h.marked == shown)
        #expect(h.hud?.alternativeText == alternative)
    }

    // MARK: Chip after commit (§4.8.3)

    @Test func surprisingCommitShowsTheChip() {
        let h = EngineHarness()
        h.detector.scores["g"] = [.korean: -3000, .english: -3500]
        h.detector.scores["go"] = [.korean: -4000, .english: -5000]
        h.detector.finals["go"] = [.korean: -9000, .english: -2000]   // final ≠ shown, margin 7 nats
        h.type("go")
        #expect(h.marked == "해")
        h.press(.space)
        #expect(h.text == "go ")
        #expect(h.hud == HUDRequest(content: .flipLastWord(bar("go", .english, offering: "해", .korean, currentFirst: false)),
                                    anchor: .location(0), immediate: true, lifetime: CompositionEngine.chipLifetime))
        h.press(.letter("a"))
        #expect(h.hud?.isLastWordChoice != true, "the next key cancels the chip")
    }

    @Test(arguments: [(619, true), (620, false)])
    func uncertainCommitShowsTheChip(_ margin: Int, _ chip: Bool) {
        let h = EngineHarness()
        h.detector.scores["dk"] = [.korean: -2000, .english: -9000]
        h.detector.finals["dk"] = [.korean: -2000, .english: -2000 - margin]
        h.type("dk ")
        #expect(h.text == "아 ")
        if chip {
            #expect(h.hud?.content == .flipLastWord(bar("아", .korean, offering: "dk", .english, currentFirst: true)))
        } else {
            #expect(h.hud == nil)
        }
    }

    @Test func noChipForLockedWordsOrClientsThatCannotReplace() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.detector.finals["go"] = [.korean: -4000, .english: -4100]
        h.type("go")
        h.flip()
        h.press(.space)
        #expect(h.hud == nil)

        let i = EngineHarness(bundleIdentifier: "com.googlecode.iterm2")
        EngineFlipTests.scriptGo(i.detector)
        i.detector.finals["go"] = [.korean: -4000, .english: -4100]
        i.type("go ")
        #expect(i.hud == nil)
    }

    @Test func chipAnchorsAtTheStartOfTheWholeWord() {
        let h = EngineHarness()
        h.detector.latinWords = ["push"]
        h.detector.english("push")
        h.detector.scores["pushg"] = [.korean: -42545, .english: -23964, .mixed(latin: 4): -19991]
        h.detector.scores["pushgo"] = [.korean: -49991, .english: -26493, .mixed(latin: 4): -20698]
        h.detector.finals["pushgo"] = [.korean: -49991, .english: -20500, .mixed(latin: 4): -20698]
        h.type("ok ")
        h.type("pushgo")
        #expect(h.text == "ㅐㅏ push해")
        h.press(.space)
        // Final mode prefers E (consistent with the committed "push"): a surprise, so the chip
        // offers M(4) and anchors where the whole word starts, not where the last insert began.
        #expect(h.text == "ㅐㅏ pushgo ")
        #expect(h.hud == HUDRequest(content: .flipLastWord(bar("pushgo", .english, offering: "push해", .korean,
                                                               currentFirst: false)),
                                    anchor: .location(3), immediate: true, lifetime: CompositionEngine.chipLifetime))
        h.flip()
        #expect(h.text == "ㅐㅏ push해 ")
    }

    @Test func eagerStateHasNoHUD() {
        let h = EngineHarness()
        h.detector.english("hello")
        h.type("hel")
        #expect(h.hud == nil)
    }

    // MARK: R15: one mutation per key in the common case

    @Test func sentenceCostsOneMutationPerKey() {
        let h = EngineHarness()
        h.detector.korean("dkssudgktpdy")
        h.detector.korean("qksrkqtmqslek")
        h.detector.english("hello")
        let steps = h.type("dkssudgktpdy hello qksrkqtmqslek.")
        for (i, step) in steps.enumerated() {
            #expect(step.mutations.count <= 1, "key \(i): \(step.calls)")
            #expect(step.calls.count <= 2, "key \(i): at most one mutation plus the commit's selectedRange")
        }
        #expect(h.text == "안녕하세요 hello 반갑습니다.")
    }

    // MARK: Commits by a modifier

    @Test(arguments: [(UInt16(57), FlipTapDetector.Flags.capsLock), (UInt16(63), FlipTapDetector.Flags.function)])
    func aCommitByCapsLockOrFnTakesTheAlternativeAway(_ keyCode: UInt16, _ flag: UInt) {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        #expect(h.hud?.isEligible == true)
        h.engine.handleModifier(ModifierEvent(keyCode: keyCode, flags: flag, timestamp: h.now), client: h.client)
        #expect(!h.engine.isComposing)
        #expect(h.hud.map { if case .alternative = $0.content { true } else { false } } != true,
                "no alternative is left for a word that is gone")
    }
}
