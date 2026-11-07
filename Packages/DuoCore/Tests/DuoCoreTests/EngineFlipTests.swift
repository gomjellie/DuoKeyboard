import Foundation
import Testing
@testable import DuoCore

/// docs/SPEC.md §4.7: the flip key's three cases, the lock and the second flip.
@MainActor
@Suite("Engine · flip")
struct EngineFlipTests {
    typealias Call = RecordingClient.Call

    /// `go`: 해 shown in START/KO, English close behind.
    static func scriptGo(_ d: FakeDetector) {
        d.scores["g"] = [.korean: -3000, .english: -3500]
        d.scores["go"] = [.korean: -4000, .english: -5000]
        d.scores["gos"] = [.korean: -6000, .english: -9000]
    }

    // MARK: (a) token present

    @Test func flipSwapsTheMarkedReadingAndLocks() {
        let h = EngineHarness()
        Self.scriptGo(h.detector)
        h.type("go")
        #expect(h.marked == "해")
        let calls = h.flip()
        #expect(calls == [.mark("go", nil)], "one setMarkedText; no marked-range check within 1 s")
        #expect(h.text == "go")
        #expect(h.engine.token?.locked == .english)
        #expect(h.engine.token?.lockedOriginal == .korean)
        #expect(h.notifications == [.flipped(to: .english)])
        #expect(h.hud?.alternativeText == "해", "the HUD offers the way back")
        // Locked: hysteresis is off even though K now leads by far.
        h.type("s")
        #expect(h.marked == "gos")
        h.press(.space)
        #expect(h.text == "gos ")
        #expect(h.detector.finalCalls.isEmpty, "a locked token needs no final scoring")
        #expect(h.learned("gos", .start) == [.english: 3])
    }

    @Test func secondFlipReturnsToTheOriginalAndKeepsTheLock() {
        let h = EngineHarness()
        Self.scriptGo(h.detector)
        h.type("go")
        h.flip()
        let back = h.flip()
        #expect(back == [.mark("해", nil)])
        #expect(h.engine.token?.locked == .korean)
        h.detector.scores["gos"] = [.korean: -20000, .english: -3000]   // E far ahead: still locked
        h.type("s")
        #expect(h.marked == "핸")
        h.press(.space)
        #expect(h.text == "핸 ")
        #expect(h.store.count == 0, "flipping back to the original cancels the vote")
        #expect(h.notifications.filter { if case .flipped = $0 { true } else { false } }.count == 2)
    }

    @Test func flipInEnglishContextThenContinueTypingGos() {
        // ux-spec §9 #69: EN context, `go` R⌘ `s␣` → go → 해 (locked) → 핸␣; vote `gos` = K.
        let h = EngineHarness()
        h.detector.english("hi")
        h.detector.scores["g"] = [.korean: -3000, .english: -3200]
        h.detector.scores["go"] = [.korean: -4000, .english: -3000]
        h.type("hi ")
        h.type("go")
        #expect(h.marked == "go")
        h.flip()
        #expect(h.marked == "해")
        h.type("s ")
        #expect(h.text == "hi 핸 ")
        #expect(h.learned("gos", .english) == [.korean: 3])
    }

    @Test func flipReopensCommittedLatinWithAReplacementRange() {
        // c > 0 and nothing marked: verify the committed Latin, then mark the new reading over it.
        let h = EngineHarness()
        h.detector.english("push")
        h.type("push")
        #expect(h.text == "push")
        #expect(h.markedRange == nil)
        let calls = h.flip()
        #expect(calls == [.selectedRange, .string(NSRange(location: 0, length: 4)),
                          .mark("ㅔㅕ노", NSRange(location: 0, length: 4))])
        #expect(h.text == "ㅔㅕ노")
        #expect(h.markedRange == NSRange(location: 0, length: 3))
        #expect(h.engine.token?.committed == 0)
        let back = h.flip()
        #expect(back == [.mark("push", nil)])
        h.press(.space)
        #expect(h.text == "push ")
    }

    @Test func flipReopensCommittedLatinPlusMarkedTail() {
        let h = EngineHarness()
        h.detector.latinWords = ["tab"]
        h.detector.english("tab")
        h.detector.scores["tabs"] = [.korean: -1000, .english: -5000, .mixed(latin: 3): -6000]
        h.type("tabs")
        #expect(h.text == "tabs")
        #expect(h.markedRange == NSRange(location: 3, length: 1))
        let korean = FakeDetector.hangul("tabs")
        let calls = h.flip()
        #expect(calls == [.markedRange, .string(NSRange(location: 0, length: 3)),
                          .mark(korean, NSRange(location: 0, length: 4))])
        #expect(h.text == korean)
        #expect(h.markedRange == NSRange(location: 0, length: (korean as NSString).length))
    }

    @Test func flipToAConsistentReadingNeedsNoReopen() {
        let h = EngineHarness()
        h.detector.latinWords = ["push"]
        h.detector.english("push")
        h.detector.scores["pushg"] = [.korean: -42545, .english: -23964, .mixed(latin: 4): -19991]
        h.detector.scores["pushgo"] = [.korean: -49991, .english: -26493, .mixed(latin: 4): -20698]
        h.type("pushgo")
        #expect(h.text == "push해")
        let calls = h.flip()
        #expect(calls == [.mark("go", nil)], "M(4) → E keeps the committed Latin")
        #expect(h.text == "pushgo")
    }

    @Test func reopenVerificationFailureShowsCannotChangeAndChangesNothing() {
        let h = EngineHarness()
        h.detector.english("push")
        h.type("push")
        h.buffer.setText("PUSH")   // the app rewrote the text under us
        let calls = h.flip()
        #expect(calls == [.selectedRange, .string(NSRange(location: 0, length: 4))])
        #expect(h.text == "PUSH")
        #expect(h.hud == HUDRequest(content: .cannotChange, anchor: .caret, immediate: true, lifetime: 1.2))
        #expect(h.engine.token?.committed == 4)
        #expect(h.engine.token?.locked == nil)
        #expect(h.notifications.isEmpty)
    }

    @Test func reopenWithoutCaretShowsCannotChange() {
        let h = EngineHarness()
        h.detector.english("push")
        h.type("push")
        h.buffer.reportsSelection = false
        #expect(h.flip() == [.selectedRange])
        #expect(h.hud?.content == .cannotChange)
    }

    @Test func reopenInTerminalEndsAtTheCaret() {
        let h = EngineHarness(bundleIdentifier: "com.apple.Terminal")
        h.detector.english("list")
        h.type("list")
        #expect(h.text == "list")
        #expect(h.markedRange == nil)
        h.flip()
        #expect(h.text == FakeDetector.hangul("list"), "the range ends at the caret, so .beforeCaretOnly honours it")
    }

    @Test func flipWorksInClientsThatCannotReplace() {
        // iTerm2: no eager E, so the whole token is marked and a flip only re-marks it (R17).
        let h = EngineHarness(bundleIdentifier: "com.googlecode.iterm2")
        h.detector.english("ls")
        h.type("ls")
        #expect(h.marked == "ls")
        #expect(h.flip() == [.mark("ㅣㄴ", nil)])
    }

    @Test func flipAfterAPauseChecksTheClientStillHasOurMarkedText() {
        let h = EngineHarness()
        Self.scriptGo(h.detector)
        h.type("go")
        h.buffer.clear()
        h.now += 2
        let calls = h.flip()
        #expect(calls == [.markedRange])
        #expect(h.text == "", "no ghost: the token was dropped")
        #expect(!h.engine.isComposing)
        #expect(h.engine.oneShot == .english, "then it was a flip with nothing to flip")
    }

    @Test func menuFlipAlwaysChecksTheMarkedText() {
        let h = EngineHarness()
        Self.scriptGo(h.detector)
        h.type("go")
        _ = h.client.take()
        h.engine.flip(client: h.client)
        #expect(h.client.take() == [.markedRange, .mark("go", nil)])
    }

    // MARK: (b) the word just committed

    @Test func flipReplacesTheLastCommittedWordAndKeepsTheBoundary() {
        // ux-spec §9 #70: "go␣" → "해␣", caret after the space, vote go = K (+3).
        let h = EngineHarness()
        h.detector.scores["g"] = [.korean: -3500, .english: -3000]
        h.detector.scores["go"] = [.korean: -6000, .english: -3000]
        h.detector.finals["go"] = [.korean: -6000, .english: -3000]
        h.type("go ")
        #expect(h.text == "go ")
        let calls = h.flip()
        #expect(calls == [.selectedRange, .string(NSRange(location: 0, length: 3)),
                          .insert("해 ", NSRange(location: 0, length: 3))])
        #expect(h.text == "해 ")
        #expect(h.buffer.selection == NSRange(location: 2, length: 0))
        #expect(h.learned("go", .start) == [.korean: 3])
        #expect(h.notifications.contains(.flipped(to: .korean)))
        #expect(h.notifications.contains(.learningChanged))
        // The next word follows the new language.
        h.press(.letter("g"))
        #expect(h.detector.prefixContexts.last == .korean)
    }

    @Test func secondFlipOfTheLastWordFlipsBackAndCancelsTheVote() {
        let h = EngineHarness()
        h.detector.finals["go"] = [.korean: -6000, .english: -5000]   // margin 1000 → implicit +1 to E
        h.detector.scores["go"] = [.korean: -6000, .english: -3000]
        h.detector.scores["g"] = [.korean: -3500, .english: -3000]
        h.type("go ")
        #expect(h.learned("go", .start) == [.english: 1])
        h.flip()
        #expect(h.text == "해 ")
        #expect(h.learned("go", .start) == [.korean: 3], "the implicit vote was taken back")
        h.flip()
        #expect(h.text == "go ")
        #expect(h.learned("go", .start) == [.english: 1], "flipping back restores the original commit")
        #expect(h.buffer.selection == NSRange(location: 3, length: 0))
    }

    @Test func flipWithTheCaretRightAfterTheWord() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        h.press(.arrowRight)   // commit without a space (boundary length 0)
        #expect(h.flip() == [.selectedRange, .string(NSRange(location: 0, length: 2)),
                             .insert("dkssud", NSRange(location: 0, length: 2))])
        #expect(h.text == "dkssud")
    }

    @Test func flipAfterPunctuationBoundary() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud,")
        h.flip()
        #expect(h.text == "dkssud,")
        #expect(h.buffer.selection.location == 7)
    }

    @Test func lastCommitExpiresAfterThirtySeconds() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.now += 31
        let calls = h.flip()
        #expect(calls.isEmpty)
        #expect(h.text == "안녕 ")
        #expect(h.engine.oneShot == .english)
    }

    @Test func caretAwayFromTheWordMeansNextWord() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.press(.arrowLeft)
        h.press(.arrowLeft)
        let calls = h.flip()
        #expect(calls == [.selectedRange])
        #expect(h.text == "안녕 ")
        #expect(h.hud?.content == .oneShot(.english))
    }

    @Test func changedTextShowsCannotChange() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.buffer.setText("안경 ")
        let calls = h.flip()
        #expect(calls == [.selectedRange, .string(NSRange(location: 0, length: 3))])
        #expect(h.text == "안경 ")
        #expect(h.hud?.content == .cannotChange)
    }

    @Test func clientsWithoutReplacementShowCannotChange() {
        // ux-spec §9 #71 (iTerm2): unchanged, "여기서는 바꿀 수 없어요".
        let h = EngineHarness(bundleIdentifier: "com.googlecode.iterm2")
        h.detector.korean("dkssud")
        let commit = h.type("dkssud ").last!
        #expect(commit.calls == [.insert("안녕", nil)], "no selectedRange for a client that can't replace")
        #expect(h.flip().isEmpty)
        #expect(h.text == "안녕 ")
        #expect(h.hud?.content == .cannotChange)
    }

    @Test func terminalCanFlipTheLastWord() {
        let h = EngineHarness(bundleIdentifier: "com.apple.Terminal")
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.flip()
        #expect(h.text == "dkssud ", "the replaced range ends at the caret")
    }

    // Terminal answers `selectedRange()` before the shell has echoed what was just inserted, so
    // the end recorded at commit time trails; the word is measured back from the caret instead.

    static func terminal() -> EngineHarness {
        let h = EngineHarness(bundleIdentifier: "com.apple.Terminal")
        h.detector.english("world")
        return h
    }

    @Test func terminalFlipsTheLastWordWhoseEndWasReportedBeforeTheEcho() {
        let h = Self.terminal()
        h.client.selectionLag = 2
        h.type("world ")
        #expect(h.text == "world ")
        #expect(h.engine.lastCommit?.endLocation == 3, "recorded before the echo")
        h.client.selectionLag = 0
        let calls = h.flip()
        #expect(calls == [.selectedRange, .string(NSRange(location: 0, length: 6)),
                          .insert("재깅 ", NSRange(location: 0, length: 6))])
        #expect(h.text == "재깅 ")
        #expect(h.buffer.selection == NSRange(location: 3, length: 0))
        #expect(h.learned("world", .start) == [.korean: 3])
        #expect(h.notifications.contains(.flipped(to: .korean)))

        h.flip()
        #expect(h.text == "world ", "a second flip returns, measured from the caret again")
        #expect(h.learned("world", .start).isEmpty, "and takes the vote back")
    }

    @Test func terminalFlipsTheLastWordAfterPunctuation() {
        let h = Self.terminal()
        h.client.selectionLag = 1
        h.type("world.")
        h.client.selectionLag = 0
        h.flip()
        #expect(h.text == "재깅.")
    }

    @Test func terminalFlipsTheBareWordBeforeTheShellEchoesTheBoundary() {
        let h = Self.terminal()
        h.type("world")
        h.now += 0.05
        var space = KeyEvent(.space)
        space.timestamp = h.now
        #expect(!h.engine.handle(space, client: h.client))   // passed, but not echoed yet
        #expect(h.text == "world")
        let calls = h.flip()
        #expect(calls.last == .insert("재깅", NSRange(location: 0, length: 5)))
        #expect(h.text == "재깅")
    }

    @Test func terminalShowsCannotChangeWhenTheTextBeforeTheCaretIsNotTheWord() {
        let h = Self.terminal()
        h.type("world ")
        h.buffer.setText("wordy ")
        let calls = h.flip()
        #expect(calls.filter(\.isMutation).isEmpty)
        #expect(h.text == "wordy ")
        #expect(h.hud?.content == .cannotChange)
        #expect(h.store.count == 0)
        #expect(h.engine.lastCommit?.text == "world", "nothing changed")
    }

    @Test func terminalBackspaceOverTheBoundaryKeepsTheWordFlippable() {
        // Re-review R4: the end recorded at commit trailed the echo; ⌫ re-anchors from the caret.
        let h = Self.terminal()
        h.detector.english("world")
        h.client.selectionLag = 2
        h.type("world ")
        h.client.selectionLag = 0
        h.press(.backspace)
        #expect(h.engine.lastCommit != nil, "the word is still adjacent")
        h.flip()
        #expect(h.text == "재깅")
    }

    @Test func terminalBackspaceIntoTheWordEndsCaseB() {
        let h = Self.terminal()
        h.detector.english("world")
        h.type("world")
        h.press(.space)
        h.press(.backspace)
        h.press(.backspace)
        #expect(h.engine.lastCommit == nil)
    }

    @Test func terminalWithASelectionMeansNextWord() {
        let h = Self.terminal()
        h.type("world ")
        h.buffer.select(NSRange(location: 0, length: 5))
        let calls = h.flip()
        #expect(calls == [.selectedRange])
        #expect(h.engine.oneShot != nil)
    }

    @Test func clientWithoutSelectionIsNotFlippable() {
        let h = EngineHarness()
        h.buffer.reportsSelection = false
        h.detector.korean("dkssud")
        h.type("dkssud ")
        #expect(h.engine.lastCommit?.endLocation == nil)
        #expect(h.flip().isEmpty)
        #expect(h.hud?.content == .cannotChange)
    }

    @Test func mouseClickEndsFlipCaseB() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        _ = h.commit(.mouse)
        h.flip()
        #expect(h.text == "안녕 ")
        #expect(h.engine.oneShot == .english)
    }

    // MARK: (c) nothing to flip

    @Test func flipWithNothingArmsAOneShotEnglishWord() {
        let h = EngineHarness()
        let calls = h.flip()
        #expect(calls.isEmpty)
        #expect(h.hud == HUDRequest(content: .oneShot(.english), anchor: .caret, immediate: true, lifetime: 0.9))
        Self.scriptGo(h.detector)
        h.detector.finals["go"] = [.korean: -4000, .english: -9000]
        h.type("go")
        #expect(h.marked == "go", "the one-shot word starts in English and stays there")
        h.press(.space)
        #expect(h.text == "go ")
        #expect(h.learned("go", .start) == [.english: 3], "it overruled the detector: an explicit vote")
        // One shot only.
        h.type("go")
        #expect(h.engine.token?.languageLock == nil)
    }

    @Test func oneShotKoreanInEnglishContext() {
        // ux-spec §9 #72. Two spaces: the caret is no longer at the last word, so this is case (c).
        let h = EngineHarness()
        h.detector.english("hi")
        h.detector.scores["g"] = [.korean: -3000, .english: -2000]
        h.detector.scores["go"] = [.korean: -6000, .english: -2000]
        h.detector.finalsByContext["go"] = [.english: [.korean: -9000, .english: -2000]]
        h.type("hi  ")
        h.flip()
        #expect(h.hud?.content == .oneShot(.korean))
        h.type("go ")
        #expect(h.text == "hi  해 ")
    }

    @Test func oneShotThatAgreesWithTheDetectorTeachesNothing() {
        let h = EngineHarness()
        h.detector.english("hello")
        h.flip()
        h.type("hello ")
        #expect(h.text == "hello ")
        #expect(h.store.count == 0)
    }

    @Test func secondTapCancelsTheOneShot() {
        let h = EngineHarness()
        h.flip()
        h.flip()
        #expect(h.engine.oneShot == nil)
        #expect(h.hud == nil)
    }

    @Test func flipAMidWordOneShotToken() {
        let h = EngineHarness()
        Self.scriptGo(h.detector)
        h.flip()
        h.type("go")
        #expect(h.marked == "go")
        h.flip()
        #expect(h.marked == "해")
        h.flip()
        #expect(h.marked == "go")
    }
}
