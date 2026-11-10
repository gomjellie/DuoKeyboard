import Foundation
import Testing
@testable import DuoCore

/// SPEC.md §4.5.4 Backspace: never overloaded, never changes the language.
@MainActor
@Suite("Engine · Backspace")
struct EngineBackspaceTests {
    typealias Call = RecordingClient.Call

    @Test func jasoDeletesOneKeystrokeAtATime() {
        // ux-spec §9 #67: 닭 → 달 → 다 → ㄷ → (empty, ⌫ consumed).
        let h = EngineHarness()
        h.detector.korean("ekfr")
        h.type("ekfr")
        #expect(h.marked == "닭")
        for expected in ["달", "다", "ㄷ"] {
            let step = h.press(.backspace)
            #expect(step.consumed)
            #expect(step.calls == [.mark(expected, nil)])
            #expect(h.text == expected)
        }
        let last = h.press(.backspace)
        #expect(last.consumed, "the empty buffer does not delete an extra character")
        #expect(last.calls == [.mark("", nil)])
        #expect(h.text == "")
        #expect(!h.engine.isComposing)
        let more = h.press(.backspace)
        #expect(!more.consumed)
        #expect(more.calls.isEmpty)
    }

    @Test func jasoDeletesEarlierSyllablesWhole() {
        // Like macOS's Korean keyboard: only the syllable being typed comes apart.
        let h = EngineHarness()
        h.detector.korean("dkssudgktpdy")
        h.type("dkssudgktpdy")
        #expect(h.marked == "안녕하세요")
        // 요 comes apart (its ㅇ joins 세 for a moment, since the word is composed again from its
        // keys); 세, 하, 녕, 안 go whole.
        for expected in ["안녕하셍", "안녕하세", "안녕하", "안녕", "안"] {
            #expect(h.press(.backspace).calls == [.mark(expected, nil)])
        }
        #expect(h.press(.backspace).calls == [.mark("", nil)])
        #expect(!h.engine.isComposing)
    }

    @Test func jasoTakesANewlyTypedSyllableApartAgain() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.detector.korean("dksgk")
        h.type("dkssud")
        for expected in ["안녀", "안ㄴ", "안"] {
            #expect(h.press(.backspace).calls == [.mark(expected, nil)])
        }
        h.type("gk")
        #expect(h.marked == "안하")
        #expect(h.press(.backspace).calls == [.mark("않", nil)])
        #expect(h.press(.backspace).calls == [.mark("안", nil)])
        #expect(h.press(.backspace).calls == [.mark("", nil)])
    }

    @Test func guljaDeletesTheLastSyllableBlock() {
        var settings = DuoSettings()
        settings.backspaceUnit = .gulja
        let h = EngineHarness(settings: settings)
        h.detector.korean("dkssudgktpdy")
        h.type("dkssudgktpdy")
        #expect(h.marked == "안녕하세요")
        for expected in ["안녕하세", "안녕하", "안녕", "안"] {
            #expect(h.press(.backspace).calls == [.mark(expected, nil)])
        }
        #expect(h.press(.backspace).calls == [.mark("", nil)])
        #expect(!h.engine.isComposing)
    }

    @Test func guljaIsLetterWiseForEnglish() {
        var settings = DuoSettings()
        settings.backspaceUnit = .gulja
        settings.eagerEnglishCommit = false
        let h = EngineHarness(settings: settings)
        h.detector.english("word")
        h.type("word")
        #expect(h.press(.backspace).calls == [.mark("wor", nil)])
    }

    @Test func backspaceNeverChangesTheLanguage() {
        let h = EngineHarness()
        h.detector.scores["g"] = [.korean: -3000, .english: -3500]
        h.detector.scores["gk"] = [.korean: -4000, .english: -9000]
        h.detector.scores["gks"] = [.korean: -5000, .english: -9000]
        h.type("gks")
        #expect(h.marked == "한")
        // After deleting, E would beat K by 10 nats, far above HYST: the display must stay Korean.
        h.detector.scores["gk"] = [.korean: -14000, .english: -4000]
        #expect(h.press(.backspace).calls == [.mark("하", nil)])
    }

    @Test func backspaceInMarkedPartAfterEagerCommit() {
        // push + 해 (M(4)): ⌫ edits the marked tail, then the empty tail is cleared, then the app
        // deletes committed letters one at a time.
        let h = EngineHarness()
        h.detector.latinWords = ["push"]
        h.detector.english("push")
        h.detector.scores["pushg"] = [.korean: -42545, .english: -23964, .mixed(latin: 4): -19991]
        h.detector.scores["pushgo"] = [.korean: -49991, .english: -26493, .mixed(latin: 4): -20698]
        h.type("pushgo")
        #expect(h.text == "push해")
        let first = h.press(.backspace)
        #expect(first.calls == [.mark("ㅎ", nil)])
        #expect(h.text == "pushㅎ")
        let second = h.press(.backspace)
        #expect(second.consumed)
        #expect(second.calls == [.mark("", nil)], "marked part empty with c > 0: clear and consume")
        #expect(h.text == "push")
        #expect(h.engine.token?.committed == 4)
        let third = h.press(.backspace)
        #expect(!third.consumed, "nothing marked, c > 0: the app deletes the letter")
        #expect(third.calls.isEmpty)
        #expect(h.text == "pus")
        #expect(h.engine.token?.committed == 3)
        #expect(h.engine.rawKeys == "pus")
        h.press(.space)
        #expect(h.text == "pus ")
    }

    @Test func guljaRemovesTheKoreanTailBlockOfAMixedReading() {
        var settings = DuoSettings()
        settings.backspaceUnit = .gulja
        let h = EngineHarness(settings: settings)
        h.detector.latinWords = ["push"]
        h.detector.english("push")
        for raw in ["pushg", "pushgo", "pushgoT", "pushgoTd", "pushgoTdj"] {
            h.detector.scores[raw] = [.korean: -60000, .english: -40000, .mixed(latin: 4): -20000]
        }
        h.type("pushgoTdj")
        #expect(h.text == "push했어")
        #expect(h.press(.backspace).calls == [.mark("했", nil)])
        #expect(h.press(.backspace).calls == [.mark("", nil)])
        #expect(h.text == "push")
    }

    @Test func backspaceToEmptyWithCommittedLatinDropsTheTokenWhenAllIsDeleted() {
        let h = EngineHarness()
        h.detector.english("abc")
        h.type("abc")
        #expect(h.text == "abc")
        #expect(h.markedRange == nil)
        for _ in 0..<3 { h.press(.backspace) }
        #expect(h.text == "")
        #expect(!h.engine.isComposing)
    }

    @Test func backspaceOverTheBoundaryKeepsTheWordFlippableAndShowsTheChip() {
        // ux-spec §9 #68: `dkssud␣` ⌫ deletes the space and brings back "↺ dkssud".
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        let step = h.press(.backspace)
        #expect(!step.consumed)
        #expect(step.calls == [.selectedRange])
        #expect(h.text == "안녕")
        #expect(h.hud == HUDRequest(content: .flipLastWord(bar("안녕", .korean, offering: "dkssud", .english, currentFirst: true)),
                                    anchor: .location(0), immediate: true, lifetime: CompositionEngine.chipLifetime))
        let flip = h.flip()
        #expect(flip == [.selectedRange, .string(NSRange(location: 0, length: 2)),
                         .insert("dkssud", NSRange(location: 0, length: 2))])
        #expect(h.text == "dkssud")
        #expect(h.buffer.selection == NSRange(location: 6, length: 0))
    }

    @Test func backspaceIntoTheWordEndsFlipCaseB() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.press(.backspace)
        h.press(.backspace)
        #expect(h.text == "안")
        #expect(h.engine.lastCommit == nil)
        h.flip()
        #expect(h.engine.oneShot == .english, "nothing to flip: one-shot next word (case c)")
    }

    @Test func noChipWhenUndoOfferIsOff() {
        var settings = DuoSettings()
        settings.offerUndoAfterCommit = false
        let h = EngineHarness(settings: settings)
        h.detector.korean("dkssud")
        h.type("dkssud ")
        h.press(.backspace)
        #expect(h.hud == nil)
    }
}
