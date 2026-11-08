import Foundation
import Testing
@testable import DuoCore

/// SPEC.md 4.3절 8: a capital on a key with no shifted jamo, after a word that does not read as
/// English with it, ends that word and starts a Latin word.
@MainActor
@Suite("Engine · capital after a Korean word")
struct EngineCapitalSplitTests {
    /// 한 then A: `gksA` reads 한ㅁ, and `A` alone would read ㅁ too.
    static func scriptHanA(_ h: EngineHarness) {
        h.detector.korean("gks")
        h.detector.scores["gksA"] = [.korean: -4000, .english: -12_000]
        h.detector.scores["A"] = [.korean: -2000, .english: -3000]
    }

    @Test func capitalEndsTheKoreanWordAndStartsALatinWord() {
        let h = EngineHarness()
        Self.scriptHanA(h)
        h.type("gks")
        #expect(h.marked == "한")
        let a = h.press(.letter("A"))
        #expect(a.consumed)
        #expect(h.text == "한A")
        #expect(h.marked == "A", "K wins the capital alone but is not allowed after the split")
        #expect(h.hud?.isLastWordChoice != true, "no chip for the Korean word")
        h.press(.space)
        #expect(h.text == "한A ")
        #expect(h.detector.finalCalls.map(\.raw) == ["A"], "the Korean word commits as shown, without final scoring")
    }

    @Test func koreanWordCommitsAsShown() {
        let h = EngineHarness()
        Self.scriptHanA(h)
        h.detector.finals["gks"] = [.korean: -9000, .english: -1000]
        h.type("gksA ")
        #expect(h.text == "한A ", "the capital is not a word end: no final-mode re-scoring")
        #expect(h.learned("gks", .start).isEmpty, "nothing learned from the split")
    }

    @Test func weakKoreanReadingDoesNotSplit() {
        let h = EngineHarness()
        h.detector.scores["t"] = [.korean: -2000, .english: -3000]
        h.detector.scores["to"] = [.korean: -3000, .english: -6000]   // 새 by 3 nats: to in toString
        h.detector.scores["toS"] = [.korean: -5000, .english: -9000]
        h.type("toS")
        #expect(h.marked == "샌", "one word: K leads by less than latinSplitMargin")
        #expect(h.text == "샌")
    }

    @Test func koreanChosenWithTheFlipSplitsAtAnyMargin() {
        let h = EngineHarness()
        h.detector.scores["t"] = [.korean: -3000, .english: -2000]
        h.detector.scores["to"] = [.korean: -6000, .english: -3000]
        h.detector.scores["toS"] = [.korean: -4000, .english: -9000]
        h.detector.scores["S"] = [.korean: -2000, .english: -1000]
        h.type("to")
        h.flip()
        #expect(h.marked == "새")
        h.press(.letter("S"))
        #expect(h.text == "새S")
        #expect(h.marked == "S")
    }

    @Test func backspaceOverTheCapitalReopensTheKoreanWord() {
        let h = EngineHarness()
        Self.scriptHanA(h)
        h.detector.korean("gksk")
        h.type("gksA")
        h.press(.backspace)
        #expect(h.text == "한")
        #expect(h.marked == "한", "the committed word is composing again")
        h.press(.letter("k"))
        #expect(h.marked == "하나")
        h.press(.space)
        #expect(h.text == "하나 ")
    }

    @Test func noReopenWhereCommittedTextCannotChange() {
        let h = EngineHarness(bundleIdentifier: "com.microsoft.VSCode")
        Self.scriptHanA(h)
        h.type("gksA")
        h.press(.backspace)
        #expect(h.text == "한", "Monaco ignores replacement ranges: the word stays committed")
        #expect(h.marked == nil || h.marked == "")
    }

    @Test func strayShiftInsideAKoreanWordJoinsItAgain() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.detector.scores["dkssudG"] = [.korean: -8000, .english: -30_000]
        h.detector.scores["G"] = [.korean: -3000, .english: -2000]
        h.detector.scores["Gk"] = [.korean: -2000, .english: -12_000]   // 하: K by 10 nats
        h.type("dkssudG")
        #expect(h.text == "안녕G")
        h.press(.letter("k"))
        #expect(h.text == "안녕하")
        #expect(h.marked == "안녕하", "one Korean word again")
        h.type("tpdy ")
        #expect(h.text == "안녕하세요 ")
    }

    @Test func latinWordGrowsAfterTheCapital() {
        let h = EngineHarness()
        Self.scriptHanA(h)
        h.detector.scores["AI"] = [.korean: -5000, .english: -6000]
        h.type("gksAI ")
        #expect(h.text == "한AI ")
    }

    @Test func koreanEndingMayFollowTheCapital() {
        let h = EngineHarness()
        h.detector.korean("rmfjsep")
        h.detector.scores["rmfjsepA"] = [.korean: -8000, .english: -30_000]
        h.detector.scores["Af"] = [.korean: -9000, .english: -5000]
        h.detector.scores["Afm"] = [.korean: -12_000, .english: -9000, .mixed(latin: 1): -8000]
        h.detector.scores["Afmf"] = [.korean: -1000, .english: -9000, .mixed(latin: 1): -4000]
        h.type("rmfjsepAfmf")
        #expect(h.text == "그런데A를")
        #expect(h.marked == "A를", "M(b) stays allowed; only K is not")
    }

    @Test func capitalInsideAnEnglishReadingContinuesTheWord() {
        let h = EngineHarness()
        h.detector.scores["i"] = [.korean: -2000, .english: -3000]
        h.detector.scores["iO"] = [.korean: -4000, .english: -4500]
        h.detector.scores["iOS"] = [.korean: -9000, .english: -5000]
        h.type("iO")
        #expect(h.marked == "ㅑㅒ")
        h.press(.letter("S"))
        #expect(h.marked == "iOS", "one word: the reading with the capital is English")
        h.press(.space)
        #expect(h.text == "iOS ")
    }

    @Test func shiftedJamoKeyDoesNotSplit() {
        let h = EngineHarness()
        h.detector.korean("goT")
        h.type("goT")
        #expect(h.marked == "했", "T types ㅆ: Shift is meaningful in Korean there")
    }

    @Test func capitalRightAfterAShiftedKeyIsARollOver() {
        let h = EngineHarness()
        h.detector.korean("goTDj")
        h.type("goTDj ")
        #expect(h.text == "했어 ", "Shift still held from ㅆ: D types ㅇ")
    }

    @Test func wordFlippedToEnglishKeepsTheCapital() {
        let h = EngineHarness()
        Self.scriptHanA(h)
        h.type("gks")
        h.flip()
        #expect(h.marked == "gks")
        h.press(.letter("A"))
        #expect(h.marked == "gksA", "the user chose English: the capital continues it")
    }

    @Test func flipStillReachesKoreanForTheCapital() {
        let h = EngineHarness()
        Self.scriptHanA(h)
        h.type("gksA")
        h.flip()
        #expect(h.marked == "ㅁ", "the flip key may choose K, which the engine never shows by itself")
        h.press(.space)
        #expect(h.text == "한ㅁ ")
    }
}
