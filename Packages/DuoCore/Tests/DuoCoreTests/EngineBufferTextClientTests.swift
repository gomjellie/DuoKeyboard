import Foundation
import Testing
@testable import DuoCore

/// `BufferTextClient`: the NSTextView model behind the engine tests and the playground.
@MainActor
@Suite("Engine · BufferTextClient")
struct EngineBufferTextClientTests {
    @Test func markedTextReplacesItselfAndInsertCommitsIt() {
        let c = BufferTextClient()
        c.insertText("a ", replacementRange: nil)
        c.setMarkedText("ㅎ", replacementRange: nil)
        c.setMarkedText("한", replacementRange: nil)
        #expect(c.text == "a 한")
        #expect(c.marked == NSRange(location: 2, length: 1))
        #expect(c.selection == NSRange(location: 3, length: 0), "caret at the end of the marked text (R18 #5)")
        #expect(c.committedText == "a ")
        #expect(c.markedText == "한")
        c.insertText("한글", replacementRange: nil)
        #expect(c.text == "a 한글")
        #expect(c.marked == nil)
        #expect(c.selection.location == 4)
    }

    @Test func emptyMarkedTextClearsTheComposition() {
        let c = BufferTextClient()
        c.setMarkedText("가", replacementRange: nil)
        c.setMarkedText("", replacementRange: nil)
        #expect(c.text == "")
        #expect(c.marked == nil)
    }

    @Test func replacementRangeUnmarksAndReplaces() {
        let c = BufferTextClient()
        c.setText("go ")
        c.insertText("해 ", replacementRange: NSRange(location: 0, length: 3))
        #expect(c.text == "해 ")
        #expect(c.selection == NSRange(location: 2, length: 0))
        c.setText("push")
        c.setMarkedText("ㅎ", replacementRange: nil)
        c.setMarkedText("ㅔㅕ노ㅎ", replacementRange: NSRange(location: 0, length: 5))
        #expect(c.text == "ㅔㅕ노ㅎ")
        #expect(c.marked == NSRange(location: 0, length: 4))
    }

    @Test func replacementElsewhereLeavesOldMarkedTextAsText() {
        let c = BufferTextClient()
        c.setText("ab")
        c.setMarkedText("c", replacementRange: nil)
        c.insertText("X", replacementRange: NSRange(location: 0, length: 1))
        #expect(c.text == "Xbc")
        #expect(c.marked == nil)
    }

    @Test func beforeCaretOnlyIgnoresOtherRanges() {
        let c = BufferTextClient(bundleIdentifier: "com.apple.Terminal", replacementSupport: .beforeCaretOnly)
        c.setText("go ")
        c.insertText("해 ", replacementRange: NSRange(location: 0, length: 3))
        #expect(c.text == "해 ", "ends at the caret: honoured")
        c.setText("go ")
        c.insertText("해", replacementRange: NSRange(location: 0, length: 2))
        #expect(c.text == "go 해", "Terminal ignores the range and inserts at the caret (the bug to avoid)")
    }

    @Test func noneIgnoresRangesAndCannotRead() {
        let c = BufferTextClient(bundleIdentifier: "com.googlecode.iterm2", replacementSupport: .none)
        c.setText("go ")
        #expect(c.string(in: NSRange(location: 0, length: 2)) == nil)
        c.insertText("해", replacementRange: NSRange(location: 0, length: 2))
        #expect(c.text == "go 해")
    }

    @Test func monacoIgnoresRangesButStillReads() {
        let c = BufferTextClient(bundleIdentifier: "com.microsoft.VSCode")
        c.ignoresReplacementRanges = true
        c.setText("hello")
        #expect(c.string(in: NSRange(location: 0, length: 5)) == "hello")
        c.setMarkedText("ㅗ디ㅣㅐ", replacementRange: NSRange(location: 0, length: 5))
        #expect(c.text == "helloㅗ디ㅣㅐ", "the duplicate VS Code shows when a re-open is attempted")
        c.insertText("x", replacementRange: NSRange(location: 0, length: 1))
        #expect(c.text == "hellox", "the range is ignored: the marked text is replaced")
    }

    @Test func stringInRangeChecksBounds() {
        let c = BufferTextClient()
        c.setText("안녕 hi")
        #expect(c.string(in: NSRange(location: 0, length: 2)) == "안녕")
        #expect(c.string(in: NSRange(location: 3, length: 10)) == nil)
        #expect(c.string(in: NSRange(location: -1, length: 1)) == nil)
    }

    @Test func selectionReportingCanBeTurnedOff() {
        let c = BufferTextClient()
        c.reportsSelection = false
        #expect(c.selectedRange() == nil)
    }

    @Test func appSideKeys() {
        let c = BufferTextClient()
        for e in KeyEvent.typing("Hi 3!\n") { c.applyPassedKey(e) }
        #expect(c.text == "Hi 3!\n")
        c.applyPassedKey(KeyEvent(.backspace))
        c.applyPassedKey(KeyEvent(.arrowLeft))
        c.applyPassedKey(KeyEvent(.backspace))
        #expect(c.text == "Hi !")
        c.applyPassedKey(KeyEvent(.forwardDelete))
        #expect(c.text == "Hi ")
        c.applyPassedKey(KeyEvent.letter("a", .command))
        #expect(c.selection == NSRange(location: 0, length: 3))
        c.applyPassedKey(KeyEvent(.backspace))
        #expect(c.text == "")
        c.applyPassedKey(KeyEvent(.letter(Keystroke(base: "q", shift: false)), modifiers: .capsLock))
        #expect(c.text == "Q", "Caps Lock types capitals in the app")
    }

    @Test func backspaceDeletesAWholeComposedCharacter() {
        let c = BufferTextClient()
        c.setText("a👍🏽")
        c.applyPassedKey(KeyEvent(.backspace))
        #expect(c.text == "a")
    }

    @Test(arguments: [
        (Character("e"), Character("e"), "é"), ("u", "u", "ü"), ("i", "o", "ô"), ("n", "n", "ñ"), ("`", "a", "à"),
        ("e", "x", "´x"),
    ])
    func deadKeysCompose(_ dead: Character, _ next: Character, _ expected: String) {
        let c = BufferTextClient()
        let deadKey: KeyEvent.Key = dead == "`" ? .character("`") : .letter(Keystroke(base: dead, shift: false))
        c.applyPassedKey(KeyEvent(deadKey, modifiers: .option, isDeadKey: true))
        #expect(c.text == "")
        c.applyPassedKey(.letter(next))
        #expect(c.text == expected)
    }

    @Test func systemCharactersWinWhenGiven() {
        let c = BufferTextClient()
        c.applyPassedKey(KeyEvent(.letter(Keystroke(base: "a", shift: false)), modifiers: .option), characters: "å")
        c.applyPassedKey(KeyEvent(.letter(Keystroke(base: "e", shift: false)), modifiers: .option, isDeadKey: true),
                         characters: "")
        c.applyPassedKey(.letter("e"), characters: "é")
        #expect(c.text == "åé")
    }

    @Test func onChangeFiresOnEveryMutation() {
        let c = BufferTextClient()
        var n = 0
        c.onChange = { n += 1 }
        c.setMarkedText("가", replacementRange: nil)
        c.insertText("가", replacementRange: nil)
        c.select(NSRange(location: 0, length: 0))
        c.clear()
        #expect(n == 4)
    }
}

/// "선택한 텍스트 한↔A 변환" (ux-spec §5.2).
@Suite("Engine · SelectionConverter")
struct EngineSelectionConverterTests {
    @Test(arguments: [
        ("dkssud", "안녕"),
        ("안녕", "dkssud"),
        ("dkssudgktpdy, gksrmf!", "안녕하세요, 한글!"),
        ("안녕하세요, 한글!", "dkssudgktpdy, gksrmf!"),
        ("ㅋㅋㅋ", "zzz"),
        ("닭", "ekfr"),
        ("있다", "dlTek"),
        ("PR을", "ㅖㄲdmf"),
        ("3시 10분", "3tl 10qns"),
        ("", ""),
        ("123 😀", "123 😀"),
    ])
    func convertsEachScriptRun(_ input: String, _ expected: String) {
        #expect(SelectionConverter.convert(input) == expected)
    }

    @Test func roundTripsTypedHangul() {
        let text = "오늘 회의는 3시에 해요. 괜찮아요?"
        #expect(SelectionConverter.convert(SelectionConverter.convert(text)) == text)
    }

    @Test func capsAtTwoThousandCharacters() {
        let long = String(repeating: "a", count: SelectionConverter.maxLength + 1)
        #expect(SelectionConverter.convert(long) == long)
        #expect(!SelectionConverter.canConvert(long))
        let ok = String(repeating: "k", count: SelectionConverter.maxLength)
        #expect(SelectionConverter.convert(ok) == String(repeating: "ㅏ", count: SelectionConverter.maxLength))
        #expect(SelectionConverter.canConvert("dk"))
        #expect(!SelectionConverter.canConvert("123 !"))
    }
}
