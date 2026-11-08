import Foundation
import Testing
@testable import DuoCore

/// SPEC.md §4.5 (boundaries, terminators, special keys) and §4.6 (literal phase).
@MainActor
@Suite("Engine · boundaries and literal")
struct EngineBoundaryTests {
    typealias Call = RecordingClient.Call

    struct BoundaryCase: CustomTestStringConvertible, Sendable {
        var name: String
        var event: KeyEvent
        var terminator: Terminator
        /// The document after the app handled the key.
        var document: String
        var testDescription: String { name }
    }

    nonisolated static let boundaries: [BoundaryCase] = [
        .init(name: "space", event: KeyEvent(.space), terminator: .space, document: "안녕 "),
        .init(name: "return", event: KeyEvent(.returnKey), terminator: .space, document: "안녕\n"),
        .init(name: "tab", event: KeyEvent(.tab), terminator: .space, document: "안녕\t"),
        .init(name: "escape", event: KeyEvent(.escape), terminator: .space, document: "안녕"),
        .init(name: "arrow", event: KeyEvent(.arrowLeft), terminator: .space, document: "안녕"),
        .init(name: "home/end", event: KeyEvent(.navigation), terminator: .space, document: "안녕"),
        .init(name: "F-key", event: KeyEvent(.function), terminator: .space, document: "안녕"),
        .init(name: "forward delete", event: KeyEvent(.forwardDelete), terminator: .space, document: "안녕"),
        .init(name: "⌘A", event: .letter("a", .command), terminator: .space, document: "안녕"),
        .init(name: "⌃K", event: .letter("k", .control), terminator: .space, document: "안녕"),
        .init(name: "⌘⌫", event: KeyEvent(.backspace, modifiers: .command), terminator: .space, document: "안녕"),
        .init(name: "⌥⌫", event: KeyEvent(.backspace, modifiers: .option), terminator: .space, document: "안"),
        .init(name: "digit", event: KeyEvent(.character("3")), terminator: .digit, document: "안녕3"),
        .init(name: "keypad digit", event: KeyEvent(.keypad("5")), terminator: .digit, document: "안녕5"),
        .init(name: "hyphen", event: KeyEvent(.character("-")), terminator: .hyphen, document: "안녕-"),
        .init(name: "keypad minus", event: KeyEvent(.keypad("-")), terminator: .hyphen, document: "안녕-"),
        .init(name: "comma", event: KeyEvent(.character(",")), terminator: .punctuation, document: "안녕,"),
        .init(name: "period", event: KeyEvent(.character(".")), terminator: .punctuation, document: "안녕."),
        .init(name: "question", event: KeyEvent(.character("?"), modifiers: .shift), terminator: .punctuation, document: "안녕?"),
        .init(name: "paren", event: KeyEvent(.character("("), modifiers: .shift), terminator: .punctuation, document: "안녕("),
        .init(name: "⌥ letter", event: .letter("a", .option), terminator: .punctuation, document: "안녕"),
        .init(name: "double quote", event: KeyEvent(.character("\""), modifiers: .shift), terminator: .punctuation, document: "안녕\""),
    ]

    @Test(arguments: boundaries)
    func boundaryCommitsInOneInsertThenPasses(_ c: BoundaryCase) {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        let step = h.press(c.event)
        #expect(!step.consumed, "Duo never inserts the boundary itself (R18 #2)")
        #expect(step.mutations == [.insert("안녕", nil)], "exactly one insert, no setMarkedText first")
        #expect(h.detector.finalCalls.map(\.terminator) == [c.terminator])
        #expect(h.markedRange == nil)
        #expect(h.text == c.document)
    }

    @Test(arguments: [KeyEvent(.space), KeyEvent(.returnKey), KeyEvent(.character(".")), KeyEvent(.arrowLeft),
                      .letter("v", .command)])
    func boundaryWithNothingComposingSendsNothing(_ event: KeyEvent) {
        let h = EngineHarness()
        let step = h.press(event)
        #expect(!step.consumed)
        #expect(step.calls.isEmpty, "never an empty insert or mark while idle (R18 #3)")
    }

    @Test func graveTypesWonCommitsAndInsertsInOneCall() {
        var settings = DuoSettings()
        settings.graveTypesWon = true
        let h = EngineHarness(settings: settings)
        h.detector.korean("dkssud")
        h.type("dkssud")
        let step = h.press(.character("`"))
        #expect(step.consumed)
        #expect(step.mutations == [.insert("안녕₩", nil)])
        #expect(h.text == "안녕₩")
        let alone = h.press(.character("`"))
        #expect(alone.calls == [.insert("₩", nil)])
        // ⌥` types a literal backtick while the setting is on (ux-spec §3).
        let option = h.press(KeyEvent(.character("`"), modifiers: .option, isDeadKey: true))
        #expect(option.consumed)
        #expect(h.text == "안녕₩₩`")
    }

    @Test func graveIsABackquoteByDefault() {
        let h = EngineHarness()
        let step = h.press(.character("`"))
        #expect(!step.consumed)
        #expect(h.text == "`")
    }

    @Test func shiftSpaceFlipsOnlyWhenItIsTheFlipKey() {
        var settings = DuoSettings()
        settings.flipKey = .shiftSpace
        let h = EngineHarness(settings: settings)
        h.detector.korean("xptmxm")
        h.type("xptmxm")
        #expect(h.marked == "테스트")
        let flip = h.press(.space, .shift)
        #expect(flip.consumed)
        #expect(flip.calls == [.mark("xptmxm", nil)])
        #expect(h.text == "xptmxm")

        let d = EngineHarness()
        d.detector.korean("xptmxm")
        d.type("xptmxm")
        let space = d.press(.space, .shift)
        #expect(!space.consumed, "default: ⇧Space is a space (ux-spec §9 #87)")
        #expect(d.text == "테스트 ")
    }

    // MARK: Literal phase (§4.6)

    @Test(arguments: ["/help ", "~/Library ", "\\\\server ", ":smile: ", "./run.sh ", "../up "])
    func wordStartTriggersPassEverythingRaw(_ input: String) {
        let h = EngineHarness()
        h.detector.fallback = { raw in [.korean: 0, .english: -9000 - raw.count] }   // would read Korean
        let steps = h.type(input)
        #expect(steps.allSatisfy { !$0.consumed && $0.calls.isEmpty }, "no marked text in L phase")
        #expect(h.text == input)
        #expect(!h.engine.literal, "whitespace ends L")
        #expect(h.detector.prefixCalls.isEmpty, "the detector is not consulted in L phase")
    }

    @Test func literalEndsAtWhitespaceAndCompositionResumes() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("/help ")
        h.type("dkssud")
        #expect(h.marked == "안녕")
        #expect(h.text == "/help 안녕")
    }

    @Test(arguments: [KeyEvent(.returnKey), KeyEvent(.tab), KeyEvent(.escape)])
    func returnTabEscEndLiteral(_ end: KeyEvent) {
        let h = EngineHarness()
        h.type("/x")
        #expect(h.engine.literal)
        h.press(end)
        #expect(!h.engine.literal)
    }

    @Test func atInsideATokenCommitsLatinEvenIfKoreanWasShown() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        #expect(h.marked == "안녕")
        let at = h.press(.character("@"), .shift)
        #expect(!at.consumed)
        #expect(at.calls == [.insert("dkssud", nil)], "Latin replaces the marked Hangul; no final scoring")
        #expect(h.detector.finalCalls.isEmpty)
        let rest = h.type("example.com")
        #expect(rest.allSatisfy { !$0.consumed && $0.calls.isEmpty })
        #expect(h.text == "dkssud@example.com")
        #expect(h.store.count == 0, "literal tokens are never learned")
        #expect(h.engine.lastCommit == nil, "no flip of a literal commit")
    }

    @Test func atAtAWordStartIsAMentionAndTheNameComposes() {
        // @홍길동 (KakaoTalk, Slack): `@` passes and the name after it is an ordinary word.
        let h = EngineHarness()
        h.detector.korean("ghdrlfehd")
        let at = h.press(.character("@"), .shift)
        #expect(!at.consumed)
        #expect(at.calls.isEmpty)
        #expect(!h.engine.literal)
        h.type("ghdrlfehd")
        #expect(h.marked == "홍길동")
        h.press(.space)
        #expect(h.text == "@홍길동 ")
        #expect(h.engine.lastCommit?.alternativeText == "ghdrlfehd", "the flip can still change the name")
    }

    @Test func anEnglishHandleAfterAtStaysEnglish() {
        let h = EngineHarness()
        h.detector.english("param")
        h.type("@param ")
        #expect(h.text == "@param ")
    }

    @Test func userAtExampleCom() {
        let h = EngineHarness()
        h.detector.english("user")
        h.type("user@example.com ")
        #expect(h.text == "user@example.com ")
    }

    @Test func underscoreInsideATokenIsPunctuation() {
        // 보고서_최종.hwp: `_` ends the word like any other punctuation, and the piece after it is
        // a word of its own.
        let h = EngineHarness()
        h.detector.korean("qhrhtj")
        h.detector.korean("chlwhd")
        h.detector.english("hwp")
        h.type("qhrhtj")
        #expect(h.marked == "보고서")
        let underscore = h.press(.character("_"), .shift)
        #expect(!underscore.consumed)
        #expect(underscore.mutations == [.insert("보고서", nil)])
        #expect(h.detector.finalCalls.map(\.terminator) == [.punctuation])
        #expect(!h.engine.literal)
        h.type("chlwhd")
        #expect(h.marked == "최종")
        #expect(h.detector.prefixContexts.last == .korean, "the piece after `_` follows the piece before it")
        h.type(".hwp ")
        #expect(h.text == "보고서_최종.hwp ")
    }

    @Test func englishPiecesOfASnakeCaseNameStayEnglish() {
        let h = EngineHarness()
        h.detector.english("user")
        h.detector.english("name")
        h.type("user_name ")
        #expect(h.text == "user_name ")
        #expect(h.detector.prefixContexts.last == .english)
    }

    @Test func theWordBeforeAnUnderscoreCanBeFlipped() {
        // Flip case (b) right after `_`: the word and its `_` are replaced, the caret stays after `_`.
        let h = EngineHarness()
        h.detector.scores["g"] = [.korean: -3500, .english: -3000]
        h.detector.scores["go"] = [.korean: -6000, .english: -3000]
        h.type("go_")
        #expect(h.text == "go_")
        let calls = h.flip()
        #expect(calls == [.selectedRange, .string(NSRange(location: 0, length: 3)),
                          .insert("해_", NSRange(location: 0, length: 3))])
        #expect(h.text == "해_")
        #expect(h.buffer.selection == NSRange(location: 2, length: 0))
        #expect(h.learned("go", .start) == [.korean: 3])
    }

    @Test func anUncertainWordBeforeAnUnderscoreGetsTheChip() {
        let h = EngineHarness()
        h.detector.scores["d"] = [.korean: -3000, .english: -3200]
        h.detector.scores["do"] = [.korean: -5000, .english: -5300]
        h.type("do_")
        #expect(h.text == "애_")
        guard case .flipLastWord(let choice)? = h.hud?.content else {
            Issue.record("the last word's choice bar is up")
            return
        }
        #expect(choice.other.text == "do")
    }

    @Test func colonAfterEnglishThenSlashIsLiteral() {
        let h = EngineHarness()
        h.detector.english("https")
        h.type("https://apple.com ")
        #expect(h.text == "https://apple.com ")
        #expect(h.detector.prefixCalls == ["h", "ht", "htt"], "scoring stops at the eager commit")
    }

    @Test func colonAfterKoreanIsPunctuation() {
        let h = EngineHarness()
        h.detector.korean("ckarh")
        h.detector.korean("sodyd")
        h.type("ckarh: sodyd ")
        #expect(h.text == "참고: 내용 ")
    }

    @Test(arguments: ["node.js ", "github.com/foo ", "e.g. ", "snu.ac.kr ", "example.com:8080/x ", "a.b,c "])
    func aWordAfterTheDotOfAnEnglishWordStaysLatin(_ input: String) {
        // Korean would win every piece here: K needs a flip after `.`, and after a boundary other
        // than `.` the rest is literal.
        let h = EngineHarness()
        for word in ["node", "github", "e", "snu", "example", "a"] { h.detector.english(word) }
        h.detector.fallback = { raw in [.korean: 0, .english: -9000 - raw.count] }
        h.type(input)
        #expect(h.text == input)
    }

    @Test func aWordAfterTheDotOfAnEnglishWordComposes() {
        let h = EngineHarness()
        h.detector.english("node")
        h.detector.fallback = { raw in [.korean: 0, .english: -9000 - raw.count] }
        h.type("node.j")
        #expect(!h.engine.literal)
        #expect(h.marked == "j", "K needs a flip")
        #expect(h.engine.token?.context == .english)
    }

    @Test func aWordAfterTheDotOfAnEnglishWordTakesAKoreanEnding() {
        // notes.txt라는, setup.exe가: Latin plus a Korean ending is allowed.
        let h = EngineHarness()
        h.detector.english("node")
        h.detector.english("js")
        h.detector.scores["jsf"] = [.korean: 0, .english: -6000, .mixed(latin: 2): -5000]
        h.detector.scores["jsfh"] = [.korean: 0, .english: -9000, .mixed(latin: 2): -3000]
        h.type("node.jsfh ")
        #expect(h.text == "node.js로 ")
        #expect(!h.engine.literal)
    }

    @Test func aWordThatReadsKoreanByFarAfterTheDotComposesAsKorean() {
        // ok.알겠어: the `.` ended a sentence.
        let h = EngineHarness()
        h.detector.english("ok")
        h.detector.korean("dkfrpTdj")
        h.type("ok.dkfrpTdj ")
        #expect(h.text == "ok.알겠어 ")
    }

    @Test func aKoreanWordAfterTheDotOfAnEnglishWordIsOneFlipAway() {
        // A.I.가: Korean leads by less than `latinSplitMargin`, so the word stays Latin; it is
        // composed, so the flip key reaches it (L passed it raw).
        let h = EngineHarness()
        h.detector.english("A")
        h.detector.english("I")
        h.detector.fallback = { raw in [.korean: 0, .english: -9000 - raw.count] }
        h.type("A.I.rk")
        #expect(h.marked == "rk")
        h.flip()
        #expect(h.marked == "가")
        h.press(.space)
        #expect(h.text == "A.I.가 ")
    }

    @Test func dotAfterKoreanIsSentencePunctuation() {
        let h = EngineHarness()
        h.detector.korean("ek")
        h.detector.korean("rmfotj")
        h.type("ek.rmfotj ")
        #expect(h.text == "다.그래서 ")
    }

    @Test func wwwDotIsLiteralEvenWhenItReadsKorean() {
        let h = EngineHarness()
        h.detector.korean("www")
        h.type("www")
        #expect(h.marked == "ㅈㅈㅈ")
        h.type(".example.com ")
        #expect(h.text == "www.example.com ")
    }

    @Test func tildeBeforeAWordIsPunctuation() {
        // ~하자, ~~강조~~: only `~/` is a path.
        let h = EngineHarness()
        h.detector.korean("gkwk")
        h.detector.korean("rkdwh")
        let tilde = h.press(.character("~"), .shift)
        #expect(!tilde.consumed)
        #expect(tilde.calls.isEmpty)
        #expect(!h.engine.literal)
        h.type("gkwk ~~rkdwh~~ ")
        #expect(h.text == "~하자 ~~강조~~ ")
    }

    @Test func tildeSlashIsAHomePath() {
        let h = EngineHarness()
        h.detector.fallback = { raw in [.korean: 0, .english: -9000 - raw.count] }   // would read Korean
        let tilde = h.press(.character("~"), .shift)
        #expect(!h.engine.literal)
        let slash = h.press(.character("/"))
        #expect(h.engine.literal)
        let rest = h.type("Library ")
        #expect(([tilde, slash] + rest).allSatisfy { !$0.consumed && $0.calls.isEmpty })
        #expect(h.text == "~/Library ")
    }

    @Test func aSlashAfterATildeInsideAWordIsNotAPath() {
        let h = EngineHarness()
        h.detector.korean("rk")
        h.detector.korean("sk")
        h.type("rk~/sk ")
        #expect(h.text == "가~/나 ")
        #expect(!h.engine.literal)
    }

    @Test func hashIsNotLiteral() {
        let h = EngineHarness()
        h.detector.korean("aktwlq")
        h.type("#aktwlq ")
        #expect(h.text == "#맛집 ")
    }

    @Test func slashInsideAWordIsABoundary() {
        let h = EngineHarness()
        h.detector.korean("rm")
        h.detector.korean("rmsu")
        h.type("rm/rmsu ")
        #expect(h.text == "그/그녀 ")
        #expect(!h.engine.literal)
    }

    @Test func flipDoesNothingInLiteral() {
        let h = EngineHarness()
        h.type("/he")
        let calls = h.flip()
        #expect(calls.isEmpty)
        #expect(h.hud == nil)
        #expect(h.engine.oneShot == nil)
    }

    // MARK: Where L ends besides whitespace

    @Test(arguments: ["/", ":"])
    func backspacingOverTheTriggerEndsLiteral(_ trigger: String) {
        // Slack `/` menu: the trigger is typed, deleted, and Korean follows.
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type(trigger)
        #expect(h.engine.literal)
        h.press(.backspace)
        #expect(!h.engine.literal)
        h.type("dkssud ")
        #expect(h.text == "안녕 ")
    }

    @Test func backspacingOverTheSlashOfAHomePathEndsLiteral() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("~/")
        #expect(h.engine.literal)
        h.press(.backspace)
        #expect(!h.engine.literal, "`~` alone is not a trigger")
        h.type("dkssud ")
        #expect(h.text == "~안녕 ")
    }

    @Test func backspaceInsideTheLiteralTextKeepsLiteral() {
        let h = EngineHarness()
        h.detector.fallback = { raw in [.korean: 0, .english: -9000 - raw.count] }   // would read Korean
        h.type("/help")
        h.press(.backspace)
        h.press(.backspace)
        #expect(h.engine.literal, "the `/` is still there")
        h.type("lp ")
        #expect(h.text == "/help ")
    }

    @Test func backspacingOverALiteralTokenAndItsAtEndsLiteral() {
        // `kim@` deletes back to `kim`: the `@` (the unit L started with) is gone.
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("kim@na")
        h.press(.backspace)
        h.press(.backspace)
        #expect(h.engine.literal)
        h.press(.backspace)
        #expect(!h.engine.literal)
        #expect(h.text == "kim")
    }

    @Test func theBoundaryAfterADottedWordIsTheFirstLiteralUnit() {
        let h = EngineHarness()
        h.detector.english("github")
        h.detector.english("com")
        h.type("github.com/")
        #expect(h.engine.literal)
        h.press(.backspace)
        #expect(!h.engine.literal)
        #expect(h.text == "github.com")
    }

    @Test func selectAllThenDeleteEndsLiteral() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("kim@example.com")
        #expect(h.engine.literal)
        h.press(.letter("a", .command))
        h.press(.backspace)
        #expect(h.text == "")
        h.type("dkssud ")
        #expect(h.text == "안녕 ")
    }

    @Test(arguments: [KeyEvent.Key.arrowUp, .arrowDown, .arrowLeft, .arrowRight, .navigation])
    func movingTheCaretEndsLiteral(_ key: KeyEvent.Key) {
        let h = EngineHarness()
        h.type("a@b")
        #expect(h.engine.literal)
        h.press(key)
        #expect(!h.engine.literal)
    }

    @Test func koreanOnAnotherLineAfterAnArrowComposes() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("a@b")
        h.press(.arrowUp)
        h.type("dkssud ")
        #expect(h.text == "안녕 a@b")
    }

    @Test func optionBackspaceEndsLiteral() {
        let h = EngineHarness()
        h.type("/xyz")
        h.press(.backspace, .option)
        #expect(!h.engine.literal)
    }

    @Test func forwardDeleteKeepsLiteral() {
        let h = EngineHarness()
        h.type("/xyz")
        h.press(.forwardDelete)
        #expect(h.engine.literal, "the literal text before the caret is untouched")
    }

    // MARK: `@` `_` after an explicit Korean choice

    @Test(arguments: ["_", "@"])
    func aFlipToKoreanWinsOverTheLiteralRule(_ symbol: String) {
        // ㅠ_ㅠ: b, flip, _, b, flip.
        let h = EngineHarness()
        h.detector.english("b")
        h.type("b")
        #expect(h.marked == "b")
        h.flip()
        #expect(h.marked == "ㅠ")
        let step = h.press(KeyEvent.typing(symbol)[0])
        #expect(!step.consumed)
        #expect(step.mutations == [.insert("ㅠ", nil)])
        #expect(!h.engine.literal)
        h.type("b")
        #expect(h.engine.isComposing, "the next letter composes again")
        h.flip()
        h.press(.space)
        #expect(h.text == "ㅠ\(symbol)ㅠ ")
    }

    @Test func aOneShotKoreanWordKeepsItsReadingAtUnderscore() {
        let h = EngineHarness()
        h.detector.english("hi")
        h.detector.english("bb")
        h.type("hi ")
        h.now += 31   // the last word can no longer be flipped: the tap arms a one-shot
        h.flip()
        #expect(h.engine.oneShot == .korean)
        h.type("bb")
        #expect(h.marked == "ㅠㅠ")
        h.press(.character("_"))
        #expect(!h.engine.literal)
        #expect(h.text == "hi ㅠㅠ_")
    }

    @Test func aFlipToEnglishStillGoesLiteral() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        h.flip()
        #expect(h.marked == "dkssud")
        h.press(.character("@"), .shift)
        #expect(h.engine.literal)
        h.type("x")
        #expect(h.text == "dkssud@x")
    }

    @Test func aFlipToEnglishIsKeptAtUnderscore() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        h.flip()
        h.press(.character("_"), .shift)
        #expect(!h.engine.literal)
        #expect(h.text == "dkssud_")
        #expect(h.engine.lastCommit?.alternativeText == "안녕", "the flip right after `_` turns it back")
    }

    @Test func wwwFlippedToKoreanIsNotLiteral() {
        let h = EngineHarness()
        h.detector.english("www")
        h.type("www")
        h.flip()
        #expect(h.engine.token?.locked == .korean)
        h.press(.character("."))
        #expect(!h.engine.literal)
        #expect(h.text == "ㅈㅈㅈ.")
    }

    // MARK: ⇧Space as the flip key

    @Test func shiftSpaceInLiteralTypesTheSpaceAndEndsLiteral() {
        var settings = DuoSettings()
        settings.flipKey = .shiftSpace
        let h = EngineHarness(settings: settings)
        h.detector.korean("dkssud")
        h.type("/he")
        let step = h.press(.space, .shift)
        #expect(!step.consumed, "a flip can do nothing in L: the space it most likely was")
        #expect(h.text == "/he ")
        #expect(!h.engine.literal)
        h.type("dkssud ")
        #expect(h.text == "/he 안녕 ")
    }

    @Test func shiftSpaceAutorepeatDoesNotFlipAgain() {
        var settings = DuoSettings()
        settings.flipKey = .shiftSpace
        let h = EngineHarness(settings: settings)
        EngineFlipTests.scriptGo(h.detector)
        h.type("go ")
        #expect(h.text == "해 ")
        h.press(.space, .shift)
        #expect(h.text == "go ")
        let learned = h.learned("go", .start)
        for _ in 0..<3 {
            let repeatStep = h.press(KeyEvent(.space, modifiers: .shift, isRepeat: true))
            #expect(repeatStep.consumed, "the repeat is swallowed, not typed")
            #expect(repeatStep.calls.isEmpty)
        }
        #expect(h.text == "go ")
        #expect(h.learned("go", .start) == learned)
    }
}
