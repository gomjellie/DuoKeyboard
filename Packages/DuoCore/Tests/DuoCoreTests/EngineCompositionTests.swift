import Foundation
import Testing
@testable import DuoCore

/// SPEC.md §4.3 (letters, hysteresis, eager E, consistency, cap) and §4.4 (apostrophe).
@MainActor
@Suite("Engine · composition")
struct EngineCompositionTests {
    typealias Call = RecordingClient.Call

    // MARK: Whole-token marking

    @Test func koreanWordStaysMarkedAndCommitsAtSpace() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        let expected = ["ㅇ", "아", "안", "안ㄴ", "안녀", "안녕"]
        for (i, key) in KeyEvent.typing("dkssud").enumerated() {
            let step = h.press(key)
            #expect(step.consumed)
            #expect(step.calls == [.mark(expected[i], nil)], "exactly one mark per key (R15)")
            #expect(h.text == expected[i])
            #expect(h.markedRange == NSRange(location: 0, length: (expected[i] as NSString).length))
        }
        let space = h.press(.space)
        #expect(!space.consumed, "the space is passed, never inserted by Duo")
        #expect(space.calls == [.insert("안녕", nil), .selectedRange])
        #expect(h.text == "안녕 ")
        #expect(h.markedRange == nil)
        #expect(h.detector.finalCalls.map(\.terminator) == [.space])
        #expect(h.detector.prefixCalls == ["d", "dk", "dks", "dkss", "dkssu", "dkssud"], "one prefix scoring per key")
    }

    @Test func finalScoresOnlyAtCommit() {
        let h = EngineHarness()
        h.detector.korean("rkatk")
        h.type("rkatk")
        #expect(h.detector.finalCalls.isEmpty)
        h.press(.returnKey)
        #expect(h.detector.finalCalls.count == 1)
        #expect(h.text == "감사\n")
    }

    @Test func contextInitShowsKoreanUntilEnglishBeatsHysteresis() {
        let h = EngineHarness()
        // START context initialises the display to K; E must win by more than HYST (1500).
        h.detector.scores["t"] = [.korean: -5000, .english: -4000]   // +1000: not enough
        h.detector.scores["th"] = [.korean: -9000, .english: -7400]  // +1600: switch to E
        h.detector.scores["the"] = [.korean: -20000, .english: -8000]
        let first = h.press(.letter("t"))
        #expect(first.calls == [.mark("ㅅ", nil)])
        #expect(h.hud?.pulse == false)
        let second = h.press(.letter("h"))
        #expect(second.calls == [.mark("th", nil)])
        #expect(h.hud?.pulse == true, "the reading changed by itself mid-word")
        let e = h.press(.letter("e"))
        #expect(e.calls == [.insert("the", nil)], "certain English commits eagerly")
        #expect(h.hud == nil, "nothing marked, no alternative")
    }

    @Test func hysteresisKeepsShownWithinMargin() {
        let h = EngineHarness()
        h.detector.scores["g"] = [.korean: -3000, .english: -4000]
        h.detector.scores["go"] = [.korean: -6000, .english: -4600]    // E ahead by 1.4 nats: keep 해
        h.detector.finals["go"] = [.korean: -6000, .english: -4600]
        h.type("go")
        #expect(h.marked == "해")
        h.press(.space)
        #expect(h.text == "go ", "commit is the final-mode argmax, not what was shown (R2)")
    }

    @Test func lowercaseInitialWithASuffixIsOnlyChosen() {
        let h = EngineHarness()
        h.detector.scores["a"] = [.korean: -3000, .english: -2000]
        h.detector.scores["ar"] = [.korean: -6000, .english: -4000]
        h.detector.scores["arn"] = [.korean: -9000, .english: -6000]
        h.detector.scores["arns"] = [.korean: -12_000, .english: -8000, .mixed(latin: 1): -5000]
        h.type("arns")
        #expect(h.marked == "arns", "a군 leads, but one lowercase letter + a suffix is never shown by itself")
        h.flip()
        #expect(h.marked == "a군", "the flip key picks it")
        h.press(.space)
        #expect(h.text == "a군 ")
    }

    @Test func lowercaseInitialAfterADigitIsShown() {
        let h = EngineHarness()
        h.detector.scores["m"] = [.korean: -3000, .english: -2000]
        h.detector.scores["md"] = [.korean: -6000, .english: -4000]
        h.detector.scores["mdp"] = [.korean: -9000, .english: -8000, .mixed(latin: 1): -3000]
        h.type("3mdp ")
        #expect(h.text == "3m에 ", "after a digit the reading is a unit + a suffix (100m에서)")
    }

    @Test func englishContextInitShowsLatinFromTheFirstKey() {
        let h = EngineHarness()
        h.detector.english("hi")
        h.detector.scores["g"] = [.korean: -3000, .english: -3400]
        h.type("hi ")
        #expect(h.text == "hi ")
        let g = h.press(.letter("g"))
        #expect(g.calls == [.mark("g", nil)], "EN context: E is shown until K beats it by HYST")
    }

    // MARK: Eager E (§4.3.5–6)

    @Test func eagerEnglishCommitsAndPassesLaterLetters() {
        let h = EngineHarness()
        h.detector.english("hello")
        let steps = h.type("hello")
        #expect(steps[0].calls == [.mark("h", nil)], "one or two keys never commit early")
        #expect(steps[1].calls == [.mark("he", nil)])
        // hel: E beats K by 20 nats ≥ 4.595, final mode agrees → insert, then the letters pass raw.
        #expect(steps[2].consumed)
        #expect(steps[2].calls == [.insert("hel", nil)], "the insert replaces the marked text in one call")
        for step in steps.dropFirst(3) {
            #expect(!step.consumed)
            #expect(step.calls.isEmpty, "keys passed in the eager-E state cost no client call")
        }
        #expect(h.text == "hello")
        #expect(h.markedRange == nil)
        #expect(h.detector.prefixCalls == ["h", "he", "hel"], "no scoring while letters pass raw")
        let space = h.press(.space)
        #expect(space.calls == [.selectedRange], "nothing left to insert (R18 #3), only the commit record")
        #expect(h.text == "hello ")
        #expect(h.detector.finalCalls.map(\.raw) == ["hel", "hello"], "final mode at the eager commit and the boundary")
    }

    @Test func eagerCommitNeedsTheFullMargin() {
        let h = EngineHarness()
        h.detector.scores["w"] = [.korean: -9000, .english: -2000]
        h.detector.scores["we"] = [.korean: -9000, .english: -3000]
        h.detector.scores["wel"] = [.korean: -9000, .english: -4406]   // E ahead by 4594 < 4595
        h.detector.scores["well"] = [.korean: -19000, .english: -6000]
        h.type("wel")
        #expect(h.marked == "wel")
        let l = h.press(.letter("l"))
        #expect(l.calls == [.insert("well", nil)])
        #expect(h.text == "well")
        #expect(h.markedRange == nil)
    }

    @Test func eagerCommitWaitsForFinalModeToAgree() {
        // ㅠㅠ: a lone ㅠ looks certainly English in prefix mode, but final mode reads ㅠㅠ.
        let h = EngineHarness()
        for raw in ["b", "bb", "bbb"] { h.detector.scores[raw] = [.korean: -14000, .english: -4000] }
        h.detector.finals["bbb"] = [.korean: -7000, .english: -13000]
        h.detector.finals["bb"] = [.korean: -7000, .english: -13000]
        let steps = h.type("bbb")
        #expect(steps.map(\.mutations) == [[.mark("b", nil)], [.mark("bb", nil)], [.mark("bbb", nil)]])
        #expect(h.detector.finalCalls.map(\.raw) == ["bbb"], "final mode asked only once all else agreed")
        let space = h.press(.space)
        #expect(space.mutations == [.insert("ㅠㅠㅠ", nil)])
        #expect(h.hud?.content == .flipLastWord(bar("ㅠㅠㅠ", .korean, offering: "bbb", .english, currentFirst: true)),
                "shown ≠ committed: chip (R2)")
    }

    @Test func eagerCommitNeverEndsOnAnAttachableConsonant() {
        // log + 이: logd is certain English, but d (ㅇ) right after the Latin word "log" could start
        // an attached Korean tail, so it stays marked and M(3) remains consistent.
        let h = EngineHarness()
        h.detector.latinWords = ["log"]
        h.detector.scores["l"] = [.korean: -9000, .english: -6000]
        h.detector.scores["lo"] = [.korean: -9000, .english: -7000]
        h.detector.scores["log"] = [.korean: -9000, .english: -8000]
        h.detector.scores["logd"] = [.korean: -40000, .english: -10000, .mixed(latin: 3): -16000]
        h.detector.scores["logdl"] = [.korean: -40000, .english: -20000, .mixed(latin: 3): -12000]
        let steps = h.type("logd")
        #expect(steps.map(\.calls) == [[.mark("l", nil)], [.mark("lo", nil)], [.mark("log", nil)], [.mark("logd", nil)]])
        #expect(h.detector.finalCalls.isEmpty, "blocked before final mode was asked")
        #expect(h.press(.letter("l")).calls == [.mark("log이", nil)])
        h.press(.space)
        #expect(h.text == "log이 ")
    }

    @Test(arguments: [
        ("eagerOff", ReplacementSupport.full, false),
        ("iTerm2", ReplacementSupport.none, true),
    ])
    func eagerCommitIsOffWhenDisabledOrClientCannotReplace(_ name: String, _ support: ReplacementSupport, _ on: Bool) {
        var settings = DuoSettings()
        settings.eagerEnglishCommit = on
        let h = EngineHarness(settings: settings, bundleIdentifier: support == .none ? "com.googlecode.iterm2" : "com.apple.TextEdit")
        h.detector.english("list")
        let steps = h.type("list")
        #expect(steps.map(\.calls) == [[.mark("l", nil)], [.mark("li", nil)], [.mark("lis", nil)], [.mark("list", nil)]],
                "\(name): whole-token marking (R17)")
        #expect(h.marked == "list")
    }

    @Test func eagerCommitAllowedInTerminal() {
        // Terminal replaces only before the caret, which is all eager E and its re-open need.
        let h = EngineHarness(bundleIdentifier: "com.apple.Terminal")
        h.detector.english("list")
        #expect(h.type("lis").last?.calls == [.insert("lis", nil)])
    }

    @Test func mixedReadingPRdmf() {
        // PR을 (real-model scores): P and PR read English; at d, M(2) beats E by more than HYST.
        let h = EngineHarness()
        h.detector.scores["P"] = [.korean: -23570, .english: -9279]
        h.detector.scores["PR"] = [.korean: -27225, .english: -10215, .mixed(latin: 1): -28089]
        h.detector.scores["PRd"] = [.korean: -37834, .english: -29167, .mixed(latin: 2): -22918]
        h.detector.scores["PRdm"] = [.korean: -39545, .english: -37623, .mixed(latin: 2): -23801]
        h.detector.scores["PRdmf"] = [.korean: -41150, .english: -42675, .mixed(latin: 2): -25611, .mixed(latin: 4): -48837]
        h.detector.finals["PRdmf"] = [.korean: -45000, .english: -50000, .mixed(latin: 2): -20000]
        let steps = h.type("PRdmf")
        #expect(steps.map(\.calls) == [[.mark("P", nil)], [.mark("PR", nil)], [.mark("PRㅇ", nil)], [.mark("PR으", nil)],
                                        [.mark("PR을", nil)]])
        #expect(h.hud?.alternativeText == "PRdmf")
        let space = h.press(.space)
        #expect(space.calls == [.insert("PR을", nil), .selectedRange])
        #expect(h.text == "PR을 ")
    }

    @Test func eagerStateReopensForUppercaseLatin() {
        // API를: API commits early; the f key reopens (uppercase Latin) and M(3) wins at once.
        let h = EngineHarness()
        h.detector.english("API")
        h.detector.scores["APIf"] = [.korean: -40000, .english: -20000, .mixed(latin: 3): -12000]
        h.detector.scores["APIfm"] = [.korean: -42000, .english: -24000, .mixed(latin: 3): -13000]
        h.detector.scores["APIfmf"] = [.korean: -43000, .english: -26000, .mixed(latin: 3): -14000]
        let steps = h.type("API")
        #expect(steps[2].calls == [.insert("API", nil)])
        let f = h.press(.letter("f"))
        #expect(f.consumed)
        #expect(f.calls == [.mark("ㄹ", nil)])
        #expect(h.hud?.pulse == true, "E → M(3) by itself")
        #expect(h.type("mf").last?.calls == [.mark("를", nil)])
        #expect(h.markedRange == NSRange(location: 3, length: 1))
        h.press(.space)
        #expect(h.text == "API를 ")
    }

    @Test func eagerStatePassesVowelsAndReopensOnConsonantPushgoTdj() {
        // push했어: after the eager commit the vowel h passes raw; g reopens (lexEN["push"]).
        let h = EngineHarness()
        h.detector.latinWords = ["push"]
        h.detector.english("push")
        h.detector.scores["pushg"] = [.korean: -42545, .english: -23964, .mixed(latin: 4): -19991]
        h.detector.scores["pushgo"] = [.korean: -49991, .english: -26493, .mixed(latin: 4): -20698]
        h.detector.scores["pushgoT"] = [.korean: -60000, .english: -40000, .mixed(latin: 4): -22000]
        h.detector.scores["pushgoTd"] = [.korean: -61000, .english: -42000, .mixed(latin: 4): -23000]
        h.detector.scores["pushgoTdj"] = [.korean: -62000, .english: -44000, .mixed(latin: 4): -24000]
        let steps = h.type("pushgoTdj")
        #expect(steps[2].calls == [.insert("pus", nil)])
        #expect(!steps[3].consumed && steps[3].calls.isEmpty, "h is a vowel key: it passes raw")
        #expect(steps[4].calls == [.mark("ㅎ", nil)], "M(4) wins by 4 nats > HYST")
        #expect(steps[5].calls == [.mark("해", nil)])
        #expect(steps[6].calls == [.mark("했", nil)])
        #expect(steps[8].calls == [.mark("했어", nil)])
        #expect(h.text == "push했어")
        h.press(.space)
        #expect(h.text == "push했어 ")
    }

    @Test func reopenShowsLatinUntilKoreanBeatsHysteresis() {
        let h = EngineHarness()
        h.detector.latinWords = ["log"]
        h.detector.english("log")
        h.detector.scores["logs"] = [.korean: -30000, .english: -9000, .mixed(latin: 3): -9500]
        let s = h.type("logs")
        #expect(s[2].calls == [.insert("log", nil)])
        #expect(s[3].calls == [.mark("s", nil)], "reopened; hysteresis starts from E")
        #expect(h.text == "logs")
        #expect(h.markedRange == NSRange(location: 3, length: 1))
    }

    @Test func consistencyFilterExcludesKoreanOnceLatinIsCommitted() {
        // With c > 0 only E and M(b ≥ c) may be shown or committed, even if K scores best.
        let h = EngineHarness()
        h.detector.latinWords = ["tab"]
        h.detector.english("tab")
        h.detector.scores["tabs"] = [.korean: -1000, .english: -5000, .mixed(latin: 1): -900, .mixed(latin: 3): -3400]
        h.detector.finals["tabs"] = [.korean: 0, .english: -6000, .mixed(latin: 1): 100, .mixed(latin: 3): -3000]
        h.type("tabs")
        #expect(h.text == "tabㄴ", "M(3): M(1) and K would rewrite committed Latin")
        h.press(.space)
        #expect(h.text == "tabㄴ ")
    }

    @Test func eagerStateConsistencyFallsBackToEnglishWhenMixedVanishes() {
        let h = EngineHarness()
        h.detector.latinWords = ["tab"]
        h.detector.english("tab")
        h.detector.scores["tabs"] = [.korean: -1000, .english: -5000, .mixed(latin: 3): -1000]
        h.detector.scores["tabsk"] = [.korean: -1000, .english: -6000]
        h.type("tabs")
        #expect(h.marked == "ㄴ")
        h.press(.letter("k"))
        #expect(h.text == "tabsk", "M(3) no longer exists; the best consistent reading is E")
    }

    // MARK: Cap (§4.3.2)

    @Test func thirtyThirdKeyCommitsAndStartsANewToken() {
        let h = EngineHarness()
        h.detector.fallback = { raw in [.korean: -100 * raw.count, .english: -100 * raw.count - 9000] }
        for _ in 0..<32 { h.press(.letter("z")) }
        #expect(h.marked == String(repeating: "ㅋ", count: 32))
        let step = h.press(.letter("z"))
        #expect(step.calls == [.insert(String(repeating: "ㅋ", count: 32), nil), .selectedRange, .mark("ㅋ", nil)])
        #expect(h.detector.finalCalls.map(\.terminator) == [.space])
        #expect(h.text == String(repeating: "ㅋ", count: 33))
        #expect(h.markedRange == NSRange(location: 32, length: 1))
        #expect(h.engine.rawKeys == "z")
    }

    @Test func fortyKeysNeverMakeAGiantUnderline() {
        let h = EngineHarness()
        for _ in 0..<40 { h.press(.letter("a")) }
        #expect((h.markedRange?.length ?? 0) <= 32)
        #expect(h.engine.rawKeys.count == 8)
    }

    // MARK: Apostrophe (§4.4)

    @Test func apostropheJoinsAnEnglishWordDont() {
        let h = EngineHarness()
        for raw in ["d", "do", "don"] { h.detector.scores[raw] = [.korean: -1000, .english: -3000] }
        h.detector.scores["don'"] = [.korean: -34705, .english: -8128]
        h.detector.scores["don't"] = [.korean: -40000, .english: -9000]
        h.detector.finals["don't"] = [.korean: -40000, .english: -9000]
        h.type("don")
        #expect(h.marked == "애ㅜ")
        let apostrophe = h.press(.character("'"))
        #expect(apostrophe.consumed)
        #expect(apostrophe.calls == [.insert("don'", nil)], "E shown and certain → eager commit")
        #expect(h.detector.prefixCalls.last == "don'")
        let t = h.press(.letter("t"))
        #expect(!t.consumed, "the eager-E state passes t raw")
        h.press(.space)
        #expect(h.text == "don't ")
    }

    @Test func apostropheMarkedWhenNotCertain() {
        let h = EngineHarness()
        h.detector.scores["it"] = [.korean: -2000, .english: -2500]
        h.detector.scores["it'"] = [.korean: -6000, .english: -4000]
        h.type("it")
        let step = h.press(.character("'"))
        #expect(step.calls == [.mark("it'", nil)])
        #expect(h.hud?.pulse == true)
    }

    @Test func apostropheAfterKoreanIsAQuote() {
        let h = EngineHarness()
        h.detector.korean("tkfkd")
        h.detector.scores["tkfkd'"] = [.korean: -9000, .english: -20000]
        h.press(.character("'"))   // no token: an opening quote passes
        #expect(h.text == "'")
        h.type("tkfkd")
        let close = h.press(.character("'"))
        #expect(!close.consumed)
        #expect(close.calls == [.insert("사랑", nil), .selectedRange])
        #expect(h.detector.finalCalls.last?.terminator == .punctuation)
        #expect(h.text == "'사랑'")
    }

    @Test func apostropheNeverJoinsAKoreanLock() {
        let h = EngineHarness()
        h.detector.scores["go"] = [.korean: -6000, .english: -2000]
        h.detector.scores["go'"] = [.korean: -9000, .english: -3000]
        h.type("go")
        h.flip()   // locked to K
        #expect(h.marked == "해")
        h.press(.character("'"))
        #expect(h.text == "해'")
    }
}
