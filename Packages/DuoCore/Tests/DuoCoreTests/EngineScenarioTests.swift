// ux-spec §9 edge cases that make sense under the critique, run with the REAL detector and the
// shipped model. They skip while `DuoDetector` is the placeholder (`contentHash == "placeholder"`).
//
// Expected outcomes were derived from the DET reference (`Tools/ModelBuilder/detector.py` on
// `duo-model.bin`) driven through a line-by-line mirror of this engine. That mirror reproduces
// DET's published 99.86 % on the mixed dev-chat set (detection.md §9.2). Where DET and the UX
// expectation disagree, DET wins (critique R8) and the row is a known issue with the reason.

import Foundation
import Testing
@testable import DuoCore

enum RealModel {
    /// `<package>/../../DuoInputMethod/Resources/duo-model.bin`.
    static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DuoCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // DuoCore
        .appending(path: "../../DuoInputMethod/Resources/duo-model.bin")
        .standardizedFileURL

    static let detector: DuoDetector? = try? DuoDetector(modelURL: url)

    /// The real port is in place (not the placeholder that keeps the API compiling).
    static var isAvailable: Bool { detector.map { $0.contentHash != "placeholder" } ?? false }
}

@MainActor
@Suite("Engine · scenarios (real model)", .enabled(if: RealModel.isAvailable, "needs the real DuoDetector port"))
struct EngineScenarioTests {
    /// What was typed before the row, to set the context.
    enum Prime: String, Sendable {
        case start = ""
        /// 안녕␣ → KO context.
        case korean = "dkssud "
        /// hello␣ → EN context.
        case english = "hello "
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var prime: Prime
        var keys: String
        var expected: String
        /// DET's outcome differs from ux-spec §9; DET wins (critique R8).
        var knownIssue: String?

        init(_ prime: Prime, _ keys: String, _ expected: String, knownIssue: String? = nil) {
            self.prime = prime
            self.keys = keys
            self.expected = expected
            self.knownIssue = knownIssue
        }

        var testDescription: String { "\(prime) \(keys.debugDescription) → \(expected.debugDescription)" }
    }

    nonisolated static let rows: [Row] = [
        // Korean words (ux §9 #1–4, #63, #65, #66)
        Row(.start, "dkssudgktpdy ", "안녕하세요 "),
        Row(.start, "rkatkgkqslek ", "감사합니다 "),
        Row(.start, "rkskekfk ", "가나다라 "),
        Row(.start, "gksrmf ", "한글 "),
        Row(.start, "rlaalstn ", "김민수 "),
        Row(.korean, "Dkssudgktpdy ", "안녕하세요 "),
        Row(.start, "dlTek ", "있다 "),
        Row(.start, "rkTek ", "갔다 "),
        Row(.start, "xptmxm ", "테스트 "),
        Row(.start, "ehdgo ", "동해 "),
        Row(.start, "tkvkfl\n", "사파리\n"),
        // English words, case and code (#5, #6, #14–19, #25, #53)
        Row(.start, "hello ", "hello "),
        Row(.korean, "hello ", "hello "),
        Row(.start, "Hello ", "Hello "),
        Row(.korean, "iPhone ", "iPhone "),
        Row(.korean, "macOS ", "macOS "),
        Row(.start, "OK ", "OK "),
        Row(.korean, "OK ", "OK "),
        Row(.start, "ok ", "ok "),
        Row(.korean, "ok ", "ok "),
        Row(.korean, "IT ", "IT "),
        Row(.korean, "PR ", "PR "),
        Row(.korean, "the ", "the "),
        Row(.korean, "and ", "and "),
        Row(.korean, "meeting ", "meeting "),
        Row(.korean, "Slack ", "Slack "),
        Row(.korean, "GitHub ", "GitHub "),
        Row(.start, "getElementById ", "getElementById "),
        Row(.start, "pushed ", "pushed "),
        Row(.start, "users ", "users "),
        // Latin + attached Korean (#27–30)
        Row(.korean, "PRdmf ", "PR을 "),
        Row(.start, "PRdptj ", "PR에서 "),
        Row(.korean, "APIfmf ", "API를 "),
        Row(.start, "pushgoTdj ", "push했어 "),
        Row(.start, "Reactzjavhsjsxm ", "React컴포넌트 "),
        // Jamo runs (#7–12, #90)
        Row(.start, "zzz ", "ㅋㅋㅋ "),
        Row(.korean, "zzz ", "ㅋㅋㅋ "),
        Row(.english, "zzz ", "ㅋㅋㅋ "),
        Row(.start, "bb ", "ㅠㅠ "),
        Row(.start, "nn ", "ㅜㅜ "),
        Row(.start, "dz ", "ㅇㅋ "),
        Row(.korean, "gg ", "ㅎㅎ "),
        Row(.english, "gg ", "gg ",
            knownIssue: "DET final mode reads gg as ㅎㅎ after English too (E−K = −5.3 nats); one flip teaches it"),
        Row(.start, "eeee ", "ㄷㄷㄷㄷ "),
        Row(.korean, "rt ", "ㄱㅅ "),
        Row(.english, "rt ", "rt ",
            knownIssue: "DET final mode reads rt as ㄱㅅ after English (E−K = −1.5 nats)"),
        Row(.korean, "lol ", "lol "),
        // Ambiguous two-letter words (#20–24, #26; detection.md §9.2 confusion table)
        Row(.korean, "go ", "해 "),
        Row(.english, "go ", "go "),
        Row(.start, "go ", "go "),
        Row(.korean, "so ", "내 "),
        Row(.english, "so ", "so "),
        Row(.korean, "do ", "애 "),
        Row(.english, "do ", "do "),
        Row(.korean, "to ", "새 "),
        Row(.english, "to ", "to "),
        Row(.start, "So ", "So "),
        Row(.start, "To ", "To "),
        Row(.korean, "a ", "a "),
        Row(.korean, "I ", "I "),
        Row(.korean, "i ", "i "),
        Row(.english, "dl ", "이 "),
        // Apostrophes and hyphens (#49–51)
        Row(.start, "don't ", "don't "),
        Row(.start, "I'm ", "I'm "),
        Row(.start, "'dkssud' ", "'안녕' "),
        Row(.start, "e-mail ", "e-mail "),
        Row(.start, "my-component ", "my-component "),
        // Digits (#33, #54–62)
        Row(.start, "3tl ", "3시 "),
        Row(.start, "10ro ", "10개 "),
        Row(.start, "2rodnjf ", "2개월 "),
        Row(.start, "5qns ", "5분 "),
        Row(.start, "1emd ", "1등 "),
        Row(.start, "30ch ", "30초 "),
        Row(.korean, "4th ", "4th "),
        Row(.korean, "3pm ", "3pm "),
        Row(.korean, "10am ", "10am "),
        Row(.start, "4K ", "4K "),
        Row(.start, "5G ", "5G "),
        Row(.start, "3D ", "3D "),
        Row(.start, "iOS26 ", "iOS26 "),
        Row(.start, "macOS 26 ", "macOS 26 "),
        Row(.korean, "v1.2 ", "v1.2 "),
        Row(.korean, "mp3 ", "mp3 "),
        Row(.korean, "B2B ", "B2B "),
        Row(.start, "dkdlvhs16 ", "아이폰16 "),
        Row(.start, "roffjrtlS24 ", "갤럭시S24 "),
        // A capital with no shifted jamo after a Korean word starts a Latin word (SPEC.md 4.3절 8)
        Row(.start, "gksA ", "한A "),
        Row(.korean, "tkatjdSDI ", "삼성SDI "),
        Row(.korean, "tkatjdSDIrk ", "삼성SDI가 "),
        Row(.korean, "rmfjsepAPIfmf ", "그런데API를 "),
        Row(.korean, "dkdlvhsXS ", "아이폰XS "),
        Row(.korean, "ghltkHRxla ", "회사HR팀 "),
        // ... not after Shift held over from ㅆ (roll-over), nor inside English words
        Row(.start, "goTDj ", "했어 "),
        Row(.korean, "dlTDj ", "있어 "),
        // ... nor after a short word that reads Korean only weakly (to 새, do 애, d ㅇ, z ㅋ)
        Row(.korean, "toString ", "toString "),
        Row(.korean, "doSomething ", "doSomething "),
        Row(.korean, "zIndex ", "zIndex "),
        Row(.korean, "dLTdj ", "있어 "),
        // A stray Shift inside a Korean word joins it again once the next keys read Korean
        Row(.korean, "dkssudGktpdy ", "안녕하세요 "),
        // One Latin capital + a Korean suffix (MIX_INITIAL), not in an English sentence
        Row(.korean, "ATl ", "A씨 "),
        Row(.korean, "Adid ", "A양 "),
        Row(.korean, "Arns ", "A군 "),
        Row(.start, "Brmq ", "B급 "),
        Row(.korean, "roffjrtlSrk ", "갤럭시S가 "),
        Row(.english, "Arns ", "Arns "),
        Row(.korean, "Arnsdms ", "A군은 "),
        Row(.korean, "Brmqeh ", "B급도 "),
        // ... one lowercase letter + a suffix only through the flip key or the bar
        Row(.korean, "arns ", "arns "),
        Row(.korean, "ask ", "ask "),
        Row(.korean, "rTlsms ", "ㄱ씨는 "),
        Row(.korean, "McDonald ", "McDonald "),
        Row(.korean, "YouTube ", "YouTube "),
        Row(.korean, "KakaoTalk ", "KakaoTalk "),
        Row(.korean, "LoL ", "LoL "),
        // Unspaced Korean past the 32-key cap: the last syllable carries over (SPEC.md 4.3절 2)
        Row(.start, "gksqjsqhswjrdmsdjqwlakswoaldlTdmfrjtrkxek ", "한번본적은업지만재미있을것같다 "),
        Row(.korean, "dnwntjsdksdptjwndfurdlgowpehlstkdxodptj ", "우주선안에서중력이해제된상태에서 "),
        Row(.korean, "snrnskruRdmftndlTsmstkfadpeogksaksgdmsdltbemfdmfdlftkdwjrdlaustj ",
            "누구나겪을수있는삶에대한많은이슈들을일상적이면서 "),
        // The most frequent words keep their lexicon values (uniform codebook): 내 at a sentence start
        Row(.start, "so ", "내 "),
        Row(.english, "so ", "so "),
        // Chat words and emotive jamo runs (ko_chat.txt; a run of ㅋㅎㅠㅜㅡㄷㅉ is not an orphan)
        Row(.start, "rne ", "굳 "),
        Row(.english, "rne ", "굳 "),
        Row(.start, "eh ", "도 "),
        Row(.start, "wrkxek ", "ㅈ같다 "),
        Row(.korean, "wrkxsp ", "ㅈ같네 "),
        Row(.korean, "wrkxdms ", "ㅈ같은 "),
        Row(.start, "rid ", "걍 "),
        Row(.start, "zzzzzzzzzz ", "ㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋ "),
        Row(.korean, "zzzzsks ", "ㅋㅋㅋㅋ난 "),
        Row(.start, "gggg ", "ㅎㅎㅎㅎ "),
        Row(.korean, "WW ", "ㅉㅉ "),
        Row(.korean, "gee ", "ㅎㄷㄷ "),
        Row(.english, "rid ", "rid "),
        // Chat abbreviations and words missing from the corpora; English after English stays English
        Row(.korean, "dwf ", "ㅇㅈㄹ "),
        Row(.start, "drfd ", "ㅇㄱㄹㅇ "),
        Row(.korean, "fdzz ", "ㄹㅇㅋㅋ "),
        Row(.korean, "aka ", "맘 "),
        Row(.start, "dO ", "얘 "),
        Row(.korean, "zi ", "캬 "),
        Row(.korean, "Wha ", "쫌 "),
        Row(.english, "aka ", "aka "),
        Row(.english, "bn ", "bn "),
        // A chat abbreviation inside a word is not charged as orphans (ㅈㄹ하고, 뭔ㅅㅂ)
        Row(.korean, "wfgkrh ", "ㅈㄹ하고 "),
        Row(.korean, "qtdlejfk ", "ㅂㅅ이더라 "),
        Row(.korean, "anjstq ", "뭔ㅅㅂ "),
        Row(.korean, "fddla ", "ㄹㅇ임 "),
        Row(.korean, "tqzzz ", "ㅅㅂㅋㅋㅋ "),
        Row(.english, "class ", "class "),
        Row(.start, "try ", "try "),
        // Lone jamo that chat uses far more than the Latin letter, at a low rate: Korean only after Korean
        Row(.korean, "m ", "ㅡ "),
        Row(.korean, "r ", "ㄱ "),
        Row(.korean, "W ", "ㅉ "),
        Row(.english, "m ", "m "),
        Row(.start, "e ", "e "),
        Row(.korean, "e2e ", "e2e "),
        // AI is an everyday word in Korean chat (en_terms tier 0): ai + a Korean suffix
        Row(.korean, "airk ", "ai가 "),
        Row(.start, "aidp ", "ai에 "),
        Row(.korean, "AIfh ", "AI로 "),
        Row(.english, "see ", "see "),
        // Literal phase and dotted words (#36–48, #52)
        Row(.korean, "github.com/foo ", "github.com/foo "),
        Row(.start, "user@example.com ", "user@example.com "),
        Row(.start, "dkssud@example.com ", "dkssud@example.com "),
        Row(.start, "user_name ", "user_name "),
        Row(.start, "~/Library ", "~/Library "),
        Row(.start, "https://apple.com ", "https://apple.com "),
        Row(.start, "/help ", "/help "),
        Row(.start, "@minsu ", "@minsu "),
        Row(.start, ":smile: ", ":smile: "),
        Row(.start, "#aktwlq ", "#맛집 "),
        Row(.start, "www.example.com ", "www.example.com "),
        Row(.korean, "e.g. ", "e.g. "),
        Row(.start, "node.js ", "node.js "),
        Row(.start, "U.S. ", "U.S. "),
        Row(.korean, "ek.rmfotj ", "다.그래서 "),
    ]

    static func harness() -> EngineHarness {
        EngineHarness(scorer: RealModel.detector)
    }

    /// Types `prime` then `keys`; returns the text the row produced.
    static func run(_ h: EngineHarness, _ row: Row) -> String {
        h.type(row.prime.rawValue)
        let before = h.text
        h.type(row.keys)
        #expect(h.text.hasPrefix(before))
        return String(h.text.dropFirst(before.count))
    }

    @Test(arguments: rows)
    func edgeCase(_ row: Row) {
        let h = Self.harness()
        let produced = Self.run(h, row)
        if let reason = row.knownIssue {
            withKnownIssue(Comment(rawValue: reason)) {
                #expect(produced == row.expected)
            }
        } else {
            #expect(produced == row.expected)
        }
        #expect(h.markedRange == nil, "every row ends at a boundary")
    }

    // MARK: Display and HUD on the real model

    @Test func koreanNeverFlickers() {
        // detection.md §9.3: Korean words keep their reading on every key; one mark per key.
        let h = Self.harness()
        let steps = h.type("dkssudgktpdy")
        let marks = steps.map(\.calls)
        #expect(marks == ["ㅇ", "아", "안", "안ㄴ", "안녀", "안녕", "안녕ㅎ", "안녕하", "안녕핫", "안녕하세", "안녕하셍", "안녕하세요"]
            .map { [.mark($0, nil)] })
    }

    @Test func englishCommitsEarlyFromTheThirdKey() {
        let h = Self.harness()
        let steps = h.type("hello")
        #expect(steps.map(\.calls) == [[.mark("h", nil)], [.mark("he", nil)], [.insert("hel", nil)], [], []])
    }

    @Test func mixedWordDisplay() {
        let h = Self.harness()
        h.type("dkssud ")
        let steps = h.type("PRdmf")
        #expect(steps.map(\.calls) == ["P", "PR", "PRㅇ", "PR으", "PR을"].map { [.mark($0, nil)] })
    }

    // MARK: Flip alternatives on the real model (R11: a mix only when it is a real contender)

    @Test(arguments: [
        ("tkfkd", "사랑", "tkfkd"), ("vmfhrmfoa", "프로그램", "vmfhrmfoa"), ("rpdlxm", "게이트", "rpdlxm"),
        ("gksrmf", "한글", "gksrmf"), ("sodlf", "내일", "sodlf"),
    ])
    func flippingAKoreanWordGivesItsLetters(_ keys: String, _ korean: String, _ english: String) {
        // Before: the runner-up mix (tk랑, vm로그램, rp이트, gks글, so일), noise the user never meant.
        let h = Self.harness()
        h.type(keys)
        #expect(h.marked == korean)
        h.flip()
        #expect(h.text == english)
    }

    @Test(arguments: [("test", "ㅅㄷㄴㅅ"), ("thanks", "소무ㅏㄴ"), ("meeting", "ㅡㄷㄷ샤ㅜㅎ"), ("www", "ㅈㅈㅈ")])
    func flippingAnEnglishWordGivesItsKoreanReading(_ keys: String, _ korean: String) {
        // Before: tesㅅ, thankㄴ, meetinㅎ, wwㅈ.
        let h = Self.harness()
        h.type(keys)
        h.flip()
        #expect(h.text == korean)
    }

    @Test func aMixedWordStillFlipsToItsLetters() {
        let h = Self.harness()
        h.type("dkssud PRdmf")
        #expect(h.marked == "PR을")
        h.flip()
        #expect(h.marked == "PRdmf")
    }

    @Test func goAtSentenceStartCommitsEnglishAndOffersTheFlip() {
        // detection.md §9.2: go at START is +0.47 nats English in final mode, while 해 was shown.
        let h = Self.harness()
        h.type("go")
        #expect(h.marked == "해")
        #expect(h.hud?.isEligible == true)
        h.press(.space)
        #expect(h.text == "go ")
        #expect(h.hud?.content == .flipLastWord(bar("go", .english, offering: "해", .korean, currentFirst: false)),
                "never silently different (R2)")
        #expect(h.learned("go", .start) == [.english: 1], "ambiguous implicit commit: +1")
    }

    @Test func flipGoToKoreanThenItIsLearnedInThatContext() {
        // ux §9 #70 under R7: one flip in EN context (+5 nats) beats the 2.37-nat margin there.
        let h = Self.harness()
        h.type("hello go ")
        #expect(h.text == "hello go ")
        h.flip()
        #expect(h.text == "hello 해 ")
        #expect(h.learned("go", .english) == [.korean: 3])
        h.type("hello ")
        h.type("g")
        h.type("o")
        #expect(h.marked == "해", "the learned reading shows while typing (prefix-mode bonus)")
        h.press(.space)
        #expect(h.text == "hello 해 hello 해 ")
        // The vote is for (go, EN) only: after a Korean word go was already 해, and at a sentence
        // start it stays English.
        h.press(.returnKey)
        h.type("go ")
        #expect(h.text.hasSuffix("\ngo "))
    }

    @Test func flipWhileComposingLocksAndLearns() {
        // ux §9 #69: EN context, go R⌘ s␣ → 핸␣; the vote is for `gos` = K in EN.
        let h = Self.harness()
        h.type("hello go")
        #expect(h.marked == "go")
        h.flip()
        #expect(h.marked == "해")
        h.type("s ")
        #expect(h.text == "hello 핸 ")
        #expect(h.learned("gos", .english) == [.korean: 3])
    }

    @Test func backspaceJasoOnTheRealModel() {
        // ux §9 #67: 닭 → 달 → 다 → ㄷ → (empty, ⌫ consumed).
        let h = Self.harness()
        h.type("ekfr")
        #expect(h.marked == "닭")
        for expected in ["달", "다", "ㄷ"] {
            #expect(h.press(.backspace).calls == [.mark(expected, nil)])
        }
        let last = h.press(.backspace)
        #expect(last.consumed)
        #expect(h.text == "")
    }

    // MARK: English + Korean endings (user report 2026-11-07)

    /// The texts on the bar after typing `keys`, and whether it earns the HUD.
    static func listed(_ h: EngineHarness, _ keys: String) -> (texts: [String], eligible: Bool)? {
        h.type(keys)
        guard case .alternative(let choice, let eligible)? = h.hud?.content else { return nil }
        return (choice.readings.map(\.text), eligible)
    }

    @Test(arguments: [("worksdlftneh", "재간일수도", "works일수도"), ("cmdfh", "층로", "cmd로"),
                      ("cmdrk", "층가", "cmd가")])
    func anEnglishWordThatAlsoReadsKoreanListsBoth(_ keys: String, _ korean: String, _ mixed: String) throws {
        let h = Self.harness()
        let bar = try #require(Self.listed(h, keys))
        #expect(bar.texts.first == korean, "the shown reading leads")
        let index = try #require(bar.texts.firstIndex(of: mixed), "the Latin-plus-ending reading is listed")
        #expect(bar.eligible)
        let shown = try #require(h.hud)
        #expect(h.engine.selectReading(at: index, on: shown, client: h.client) == .chosen)
        h.press(.space)
        #expect(h.text == mixed + " ")
    }

    // MARK: Readings of the end of a word (SPEC.md 4.11절)

    @Test(arguments: [
        ("", "rlfdjwuTdmfEowndrksdpenglish", "길어졌을때중간에english"),
        ("", "qhrhtjpdf", "보고서pdf"),
        ("dkssud ", "tkwlsjpg", "안녕 사진jpg"),
        ("dkssud ", "ghldmlzoom", "안녕 회의zoom"),
        ("dkssud ", "webhookaksemfrl", "안녕 webhook만들기"),
    ])
    func theFirstFlipReadsOnlyTheEndInTheOtherScript(_ prime: String, _ keys: String, _ expected: String) {
        let h = Self.harness()
        h.type(prime + keys)
        h.flip()
        #expect(h.text == expected)
    }

    @Test func aParticleFollowsTheChosenEnglishEnd() {
        let h = Self.harness()
        h.type("rlfdjwuTdmfEowndrksdpenglish")
        #expect(h.marked == "길어졌을때중간에두히ㅑ노")
        #expect(h.hud?.isEligible == true, "the bar comes up by itself with the English end")
        h.flip()
        h.type("rk ")
        #expect(h.text == "길어졌을때중간에english가 ")
    }

    @Test func theLastWordsBarOffersTheEndOfALongWord() {
        let h = Self.harness()
        h.type("rlfdjwuTdmfEowndrksdpenglish ")
        #expect(h.text == "길어졌을때중간에두히ㅑ노 ", "typing is not changed")
        #expect(h.hud?.isLastWordChoice == true)
        h.flip()
        #expect(h.text == "길어졌을때중간에english ")
    }

    @Test(arguments: ["dhsmfdmsghldmlrkdlTdjdy", "rmfjsepdywmadpsmsdlfdlaksgdktjgkfwlahfmrpTdjdy",
                      "tkfkdgksmsakdmadmfhdnflrkcmfrjqrptkfdkdi", "rkatkgkqslekwhdmsgkfnwlsotpdy"])
    func aLongKoreanWordGetsNoBarFromItsEnd(_ keys: String) {
        // 오늘은회의가있어요, 그런데요즘에는일이많아서힘들지모르겠어요, …: invented long unspaced Korean.
        let h = Self.harness()
        for key in KeyEvent.typing(keys) {
            h.press(key)
            if case .alternative(_, let eligible)? = h.hud?.content, eligible {
                Issue.record("the bar came up at \(h.engine.rawKeys)")
                return
            }
        }
    }

    @Test(arguments: [("gksrmf", "gksrmf"), ("tkfkd", "tkfkd"), ("go", "go")])
    func aShortWordStillFlipsToTheOtherScript(_ keys: String, _ flipped: String) {
        let h = Self.harness()
        h.type("dkssud ")
        h.type(keys)
        h.flip()
        #expect(h.text == "안녕 " + flipped)
    }

    @Test func cmdChosenAsEnglishThenRoReadsCmdRo() {
        let h = Self.harness()
        h.type("cmd")
        #expect(h.marked == "층")
        h.flip()
        #expect(h.marked == "cmd")
        h.type("fh")
        #expect(h.marked == "cmd로")
        h.press(.space)
        #expect(h.text == "cmd로 ")
    }

    @Test func cmdLeftAsKoreanThenRoReadsCheungRo() {
        let h = Self.harness()
        h.type("cmdfh ")
        #expect(h.text == "층로 ", "층 stays possible: no rule makes cmd English")
    }

    @Test func cmdTaughtAsEnglishBringsUpCmdRoAndStillTypesCheungRo() throws {
        // Learning is per context: teach cmd at the sentence start, where cmdfh is typed.
        let h = Self.harness()
        h.store.record(raw: "cmd", context: .start, hypothesis: .english, votes: LearningStore.flipVotes)
        let bar = try #require(Self.listed(h, "cmdfh"))
        #expect(bar.texts.first == "층로", "the shown reading first")
        #expect(bar.texts.contains("cmd로"), "cmd로 on the bar")
        #expect(bar.eligible)
        h.press(.space)
        #expect(h.text == "층로 ", "what is typed stays the model's: 층 is still possible")
    }

    @Test func choosingGoReulDoesNotTeachTheBareWordGo() {
        // Review: a Latin + ending choice must never make the bare word English (해 stays 해).
        let h = Self.harness()
        h.type("dkssud go")
        h.flip()
        h.type("fmf ")
        #expect(h.text == "안녕 go를 ")
        h.type("go ")
        #expect(h.text == "안녕 go를 해 ")
    }

    @Test func pausingInsideAKoreanSyllableKeepsItShown() throws {
        // Review: final mode reads 감ㅅ as a finished word, so rkat (E) looked likely.
        let h = Self.harness()
        h.type("dkssud rkat")
        #expect(h.marked == "감ㅅ")
        guard case .alternative(let choice, _)? = h.hud?.content else {
            Issue.record("expected the choice bar")
            return
        }
        #expect(choice.current.text == "감ㅅ")
        #expect(choice.selected == 0, "the word leads the bar")
    }

    @Test func bilingualSentenceOneMutationPerKey() {
        let h = Self.harness()
        let steps = h.type("dhsmf PRdmf dhffuTsmsep CIrk RowuTspdy. Thank you!")
        #expect(h.text == "오늘 PR을 올렸는데 CI가 깨졌네요. Thank you!")
        #expect(steps.allSatisfy { $0.mutations.count <= 1 })
    }
}
