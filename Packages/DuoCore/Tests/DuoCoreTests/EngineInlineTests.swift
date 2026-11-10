import Foundation
import Testing
@testable import DuoCore

/// SPEC.md 4.10절 "Enter로 바로 보내기": through `InlineTextClient` the word goes straight into the
/// document, never as marked text, and the document ends up as it would with marked text.
@MainActor
@Suite("Engine · typing inline")
struct EngineInlineTests {
    typealias Call = RecordingClient.Call

    static func range(_ text: String, at location: Int = 0) -> NSRange {
        NSRange(location: location, length: (text as NSString).length)
    }

    @Test func koreanWordIsTypedIntoTheDocumentAndReturnPassesWithNothingMarked() {
        let h = EngineHarness(inline: true)
        h.detector.korean("dkssud")
        let expected = ["ㅇ", "아", "안", "안ㄴ", "안녀", "안녕"]
        for (i, key) in KeyEvent.typing("dkssud").enumerated() {
            let step = h.press(key)
            #expect(step.consumed)
            let previous = i == 0 ? nil : Self.range(expected[i - 1])
            #expect(step.mutations == [.insert(expected[i], previous)], "one write per key (R15)")
            #expect(h.text == expected[i])
            #expect(h.markedRange == nil)
        }
        let ret = h.press(.returnKey)
        #expect(!ret.consumed, "the app gets the Return with nothing marked")
        #expect(ret.mutations.isEmpty, "the committed reading is already in the document")
        #expect(h.text == "안녕\n")
        #expect(h.inline?.wordRange == nil)
    }

    @Test func aFinalReadingThatDiffersReplacesTheWordBeforeTheBoundaryPasses() {
        let h = EngineHarness(inline: true)
        h.detector.korean("rkatk")
        h.detector.finals["rkatk"] = [.korean: -9000, .english: -2000]
        h.type("rkatk")
        #expect(h.text == "감사")
        let space = h.press(.space)
        #expect(!space.consumed)
        #expect(space.mutations == [.insert("rkatk", Self.range("감사"))])
        #expect(h.text == "rkatk ")
    }

    @Test func eagerEnglishReplacesTheWordAndLaterLettersPass() {
        let h = EngineHarness(inline: true)
        h.detector.english("hello")
        let steps = h.type("hello")
        #expect(steps[2].mutations == [.insert("hel", Self.range("he"))])
        #expect(!steps[3].consumed && !steps[4].consumed, "the app types the rest itself")
        h.press(.space)
        #expect(h.text == "hello ")
        #expect(h.markedRange == nil)
    }

    @Test func backspaceShortensAndThenDeletesTheWord() {
        let h = EngineHarness(inline: true)
        h.detector.korean("dk")
        h.type("dk")
        let first = h.press(.backspace)
        #expect(first.consumed)
        #expect(first.mutations == [.insert("ㅇ", Self.range("아"))])
        let second = h.press(.backspace)
        #expect(second.consumed)
        #expect(second.mutations == [.insert("", Self.range("ㅇ"))])
        #expect(h.text == "")
        #expect(h.engine.token == nil)
        let next = h.press(.letter(Keystroke(latin: "r")!))
        #expect(next.mutations == [.insert("ㄱ", nil)], "a new word starts at the caret")
    }

    @Test func flipReplacesTheWord() {
        let h = EngineHarness(inline: true)
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        #expect(h.text == "해")
        let calls = h.flip()
        #expect(calls.filter(\.isMutation) == [.insert("go", Self.range("해"))])
        #expect(h.text == "go")
        h.press(.space)
        #expect(h.text == "go ")
        #expect(h.markedRange == nil)
    }

    @Test func flipReopensCommittedLatinOverTheTypedTail() {
        let h = EngineHarness(inline: true)
        h.detector.latinWords = ["tab"]
        h.detector.english("tab")
        h.detector.scores["tabs"] = [.korean: -1000, .english: -5000, .mixed(latin: 3): -6000]
        h.type("tabs")
        #expect(h.text == "tabs")
        #expect(h.inline?.wordRange == NSRange(location: 3, length: 1))
        let korean = FakeDetector.hangul("tabs")
        let calls = h.flip()
        #expect(calls == [.string(NSRange(location: 0, length: 3)), .insert(korean, NSRange(location: 0, length: 4))],
                "the recorded range stands in for markedRange(); the tail needs no commit")
        #expect(h.text == korean)
        #expect(h.markedRange == nil)
        #expect(h.inline?.wordRange == Self.range(korean))
    }

    @Test func typingOverASelectionReplacesIt() {
        let h = EngineHarness(inline: true)
        h.buffer.setText("hello world")
        h.buffer.select(NSRange(location: 6, length: 5))
        h.detector.korean("dk")
        h.type("dk")
        #expect(h.text == "hello 아")
        #expect(h.inline?.wordRange == NSRange(location: 6, length: 1))
    }

    @Test func aClientWithoutASelectionKeepsTheWordMarked() {
        let h = EngineHarness(inline: true)
        h.buffer.reportsSelection = false
        h.detector.korean("dk")
        h.type("dk")
        #expect(h.marked == "아", "no position to record")
        h.press(.space)
        #expect(h.text == "아 ")
    }

    @Test func aWordKeepsTheModeItStartedIn() throws {
        let h = EngineHarness(inline: true)
        let inline = try #require(h.inline)
        inline.wantsInline = false
        h.detector.korean("dks")
        h.type("dk")
        inline.wantsInline = true
        h.type("s")
        #expect(h.marked == "안", "turned on mid-word: the word stays marked")
        h.press(.space)
        #expect(h.text == "안 ")
        h.type("dk")
        #expect(h.marked == nil)
        #expect(h.text == "안 아")
        inline.wantsInline = false
        h.press(.space)
        #expect(h.text == "안 아 ", "turned off mid-word: the word ends inline")
    }

    @Test func aWordTheAppClearedIsNotConfirmedAndNeverComesBack() throws {
        let h = EngineHarness(inline: true)
        let inline = try #require(h.inline)
        h.detector.korean("dkssud")
        h.type("dkssud")
        #expect(inline.confirmWord(), "nothing changed")
        // Telegram sends on a Return it does not pass to the input method, then clears the field.
        h.buffer.clear()
        #expect(!inline.confirmWord())
        h.engine.dropComposition()
        #expect(h.engine.token == nil)
        h.detector.korean("r")
        h.type("r")
        #expect(h.text == "ㄱ", "no ghost of the sent word")
    }

    @Test func aMovedCaretIsNotConfirmed() throws {
        let h = EngineHarness(inline: true)
        let inline = try #require(h.inline)
        h.buffer.setText("ab")
        h.detector.korean("dk")
        h.type("dk")
        #expect(h.text == "ab아")
        h.buffer.select(NSRange(location: 0, length: 0))
        #expect(!inline.confirmWord())
        #expect(inline.wordRange == nil)
    }

    @Test func aMarkedWordStillChecksTheClient() throws {
        // Off, the adapter passes everything through: resync, commits and flips ask the client.
        let h = EngineHarness(inline: true)
        let inline = try #require(h.inline)
        inline.wantsInline = false
        h.detector.korean("dk")
        h.type("dk")
        h.buffer.clear()
        h.press(.letter(Keystroke(latin: "s")!), after: 2)
        #expect(h.text == "ㄴ", "the cleared word was dropped by the resync after a pause")
    }
}
