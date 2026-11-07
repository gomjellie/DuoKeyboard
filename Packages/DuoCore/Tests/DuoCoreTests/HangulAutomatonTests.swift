import Testing
@testable import DuoCore

@Suite("두벌식 automaton")
struct HangulAutomatonTests {
    @Test(arguments: [
        ("dkssud", "안녕"),
        ("dkssudgktpdy", "안녕하세요"),
        ("rkskekfk", "가나다라"),
        ("gksrmf", "한글"),
        ("ekfr", "닭"),
        ("ekfrdl", "닭이"), ("ekfrl", "달기"),
        ("dkfg", "앓"),
        ("dkfgdk", "앓아"),
        ("rhk", "과"),
        ("rhkd", "광"),
        ("dhks", "완"),
        ("dnjs", "원"),
        ("dml", "의"),
        ("Rk", "까"),
        ("Tkfkd", "싸랑"),
        ("zzz", "ㅋㅋㅋ"),
        ("bb", "ㅠㅠ"),
        ("gg", "ㅎㅎ"),
        ("rt", "ㄱㅅ"),
        ("k", "ㅏ"),
        ("hk", "ㅘ"),
        ("kk", "ㅏㅏ"),
        ("rkt", "갓"),
        ("rkqt", "값"),
        ("rkqtdl", "값이"),
        ("dlTek", "있다"),
        ("goTdjdy", "했어요"), ("gotTdjdy", "햇ㅆ어요"),
        ("tkfkdgo", "사랑해"),
        ("qkfqdk", "밟아"),
        ("dhoEo", "왜때"),
        ("rkE", "가ㄸ"),
        ("aksgdl", "많이"),
        ("dkswdk", "앉아"),
    ])
    func compose(_ latin: String, _ expected: String) {
        #expect(HangulAutomaton.hangul(fromLatin: latin) == expected)
    }

    @Test func wellFormedness() {
        let ok = HangulAutomaton.compose([Keystroke](latin: "dkssud"))
        #expect(ok.isWellFormed)
        #expect(ok.completeCount == 2)
        let hello = HangulAutomaton.compose([Keystroke](latin: "hello"))
        #expect(hello.text == "ㅗ디ㅣㅐ")
        #expect(!hello.isWellFormed)
        #expect(hello.orphanVowelCount == 3)
        let prefix = HangulAutomaton.compose([Keystroke](latin: "dkss"))
        #expect(prefix.text == "안ㄴ")
        #expect(prefix.isWellFormedPrefix)
        #expect(!prefix.isWellFormed)
    }

    @Test(arguments: ["안녕하세요", "가나다라", "닭", "값이", "했어요", "왜때", "의사", "ㅋㅋㅋ", "까치", "뷁", "읽었다"])
    func roundTrip(_ word: String) throws {
        let keys = try #require(DubeolsikLayout.keystrokes(forHangul: word))
        #expect(HangulAutomaton.compose(keys).text == word)
    }

    @Test func keystrokeBasics() {
        #expect(Keystroke(latin: "H")!.jamo == "ㅗ")
        #expect(Keystroke(latin: "R")!.jamo == "ㄲ")
        #expect(Keystroke(latin: "R")!.shiftIsMeaningfulInKorean)
        #expect(!Keystroke(latin: "H")!.shiftIsMeaningfulInKorean)
        #expect([Keystroke](latin: "Hello").latinString == "Hello")
    }

    @Test func composeDecompose() {
        #expect(Jamo.compose(initial: "ㄷ", medial: "ㅏ", final: "ㄺ") == "닭")
        let d = Jamo.decompose("닭")!
        #expect(d.initial == "ㄷ" && d.medial == "ㅏ" && d.final == "ㄺ")
        #expect(Jamo.typedJamo(of: "닭") == ["ㄷ", "ㅏ", "ㄹ", "ㄱ"])
    }

    // MARK: DET §3 (normative for detection; expected values from Tools/ModelBuilder/hangul.py)

    /// `render(raw:)`: text, orphans (emitted + a pending initial-only or vowel-only block) and
    /// whether the pending block is a lone initial consonant.
    @Test(arguments: [
        // §3 examples
        ("ekfrrhrl", "닭고기", 0, false), ("rkqtdl", "값이", 0, false), ("rkqtl", "갑시", 0, false),
        ("sjrtl", "넉시", 0, false), ("dlTdj", "있어", 0, false), ("goTtmqslek", "했습니다", 0, false),
        ("rkk", "가ㅏ", 1, false), ("zzz", "ㅋㅋㅋ", 3, true), ("rt", "ㄱㅅ", 2, true), ("Ehrqo", "똑배", 0, false),
        // ㄸ ㅃ ㅉ are never finals; ㄲ ㅆ are
        ("rkE", "가ㄸ", 1, true), ("rkQ", "가ㅃ", 1, true), ("rkW", "가ㅉ", 1, true), ("rkEk", "가따", 0, false),
        ("tT", "ㅅㅆ", 2, true), ("R", "ㄲ", 1, true),
        // compound vowels without an initial
        ("hk", "ㅘ", 1, false), ("nl", "ㅟ", 1, false), ("ml", "ㅢ", 1, false), ("hko", "ㅘㅐ", 2, false),
        ("njp", "ㅝㅔ", 2, false), ("k", "ㅏ", 1, false),
        // the apostrophe flushes and is emitted literally
        ("dkssud'", "안녕'", 0, false), ("gks'rmf", "한'글", 0, false), ("r'k", "ㄱ'ㅏ", 2, false), ("r'", "ㄱ'", 1, false),
        // Korean normalisation: Shift only matters on Q W E R T O P
        ("dLTek", "있다", 0, false), ("Hello", "ㅗ디ㅣㅐ", 3, false), ("PRdmf", "ㅖㄲ을", 2, false),
        ("qQ", "ㅂㅃ", 2, true), ("rks", "간", 0, false),
    ])
    func detRendering(_ raw: String, _ text: String, _ orphans: Int, _ lone: Bool) {
        let r = HangulAutomaton.render(raw: raw)
        #expect(r.text == text)
        #expect(r.orphans == orphans)
        #expect(r.trailingLoneConsonant == lone)
        #expect(HangulAutomaton.hangul(fromLatin: raw) == text)
    }

    @Test(arguments: [("Hello", "hello"), ("PRdmf", "PRdmf"), ("dLTek", "dlTek"), ("QWERTOP", "QWERTOP"),
                      ("ASDFGHJKLZXCVBNMYUI", "asdfghjklzxcvbnmyui"), ("don't", "don't")])
    func koreanNormalization(_ raw: String, _ normalized: String) {
        #expect(HangulAutomaton.koreanNormalize(raw) == normalized)
    }

    /// Keys per rendered character, for Backspace by 글자 (the 도깨비불 key moves with its jamo).
    @Test(arguments: [("ekfr", [4]), ("ekfrdl", [4, 2]), ("ekfrl", [3, 2]), ("dkssud'", [3, 3, 1]), ("rhkd", [4]),
                      ("rt", [1, 1]), ("", [])])
    func keyCounts(_ raw: String, _ counts: [Int]) {
        #expect(HangulAutomaton.render(raw: raw).keyCounts == counts)
    }

    @Test func composeAgreesWithRender() {
        for raw in ["dkssudgktpdy", "ekfrrhrl", "rkE", "hk", "zzz", "Ehrqo", "QQ"] {
            let composition = HangulAutomaton.compose([Keystroke](latin: raw))
            let rendering = HangulAutomaton.render(raw: raw)
            #expect(composition.text == rendering.text, "\(raw)")
            #expect(composition.orphanConsonantCount + composition.orphanVowelCount == rendering.orphans, "\(raw)")
            #expect(composition.blocks.map(\.keyCount) == rendering.keyCounts, "\(raw)")
        }
        // Compound jamo are fed as their typed parts.
        #expect(HangulAutomaton.compose(jamo: ["ㄷ", "ㅘ", "ㄺ"]).text == "돩")
        #expect(HangulAutomaton.compose(jamo: Jamo.typedJamo(of: "뷁")).text == "뷁")
    }
}
