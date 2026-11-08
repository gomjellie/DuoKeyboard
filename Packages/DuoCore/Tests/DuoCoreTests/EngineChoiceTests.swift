import Foundation
import Testing
@testable import DuoCore
import DuoKit

/// SPEC.md §4.11: the choice bar shows both readings of an ambiguous word, and a click on the
/// other reading flips that word like the flip key does.
@MainActor
@Suite("Engine · choice bar")
struct EngineChoiceTests {
    /// `dk␣`: 아 committed, dk only 0.3 nats behind (an uncertain commit, so the chip comes up).
    static func typeUncertainDk(_ h: EngineHarness) {
        h.detector.scores["dk"] = [.korean: -2000, .english: -9000]
        h.detector.finals["dk"] = [.korean: -2000, .english: -2300]
        h.type("dk ")
    }

    /// A click on the bar the engine asked for (a request that is not a bar when there is none).
    @discardableResult
    static func click(_ h: EngineHarness) -> Bool {
        h.engine.chooseOtherReading(on: h.hud ?? HUDRequest(content: .cannotChange, anchor: .caret), client: h.client)
    }

    // MARK: What the bar shows

    @Test func theBarShowsBothReadingsWithTheShownOneSelected() throws {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        let request = try #require(h.hud)
        guard case .alternative(let choice, let eligible) = request.content else {
            Issue.record("expected the choice bar, got \(request.content)")
            return
        }
        #expect(eligible)
        #expect(choice.readings == [HUDReading(text: "해", language: .korean), HUDReading(text: "go", language: .english)])
        #expect(choice.current.text == "해")
    }

    @Test func aFlipMovesTheSelectionAndKeepsTheOrder() throws {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.flip()
        guard case .alternative(let choice, _)? = h.hud?.content else {
            Issue.record("expected the choice bar")
            return
        }
        #expect(choice.readings.map(\.text) == ["해", "go"], "Korean first, whichever is selected")
        #expect(choice.current.text == "go")
    }

    @Test func aMixedReadingSitsBetweenKoreanAndEnglish() {
        #expect(CompositionEngine.displayRank(.korean) < CompositionEngine.displayRank(.mixed(latin: 2)))
        #expect(CompositionEngine.displayRank(.mixed(latin: 2)) < CompositionEngine.displayRank(.mixed(latin: 3)))
        #expect(CompositionEngine.displayRank(.mixed(latin: 9)) < CompositionEngine.displayRank(.english))
    }

    // MARK: The numbered list

    /// `cmdfh`: 층로 shown, cmd로 (M3) and cmdfh close behind, and c층로 (M1) 11 nats behind the best.
    static func scriptCmdFh(_ d: FakeDetector) {
        d.scores["cmdfh"] = [.korean: -23000, .mixed(latin: 3): -25000, .english: -27000,
                             .mixed(latin: 1): -34000]
    }

    static func typeCmdFh(_ h: EngineHarness) {
        h.detector.scores["c"] = [.korean: -3000, .english: -9000]
        h.detector.scores["cm"] = [.korean: -6000, .english: -12000]
        h.detector.scores["cmd"] = [.korean: -9000, .english: -10000]
        h.detector.scores["cmdf"] = [.korean: -20000, .english: -24000]
        Self.scriptCmdFh(h.detector)
        h.type("cmdfh")
    }

    @Test func theListLeadsWithTheWordThenTheFlipTarget() throws {
        let h = EngineHarness()
        Self.typeCmdFh(h)
        guard case .alternative(let choice, let eligible)? = h.hud?.content else {
            Issue.record("expected the choice bar")
            return
        }
        #expect(choice.readings.map(\.text) == ["층로", "cmd로", "cmdfh"], "c층로 is 11 nats behind")
        #expect(choice.selected == 0)
        #expect(choice.alternate == 1, "the flip key walks the bar from the word to the next reading")
        #expect(eligible)
        #expect(!HUDPresentation(h.hud!.content, flipKey: .rightCommand).isNumbered,
                "digits are text until the user flips in this word")
        h.flip()
        #expect(HUDPresentation(h.hud!.content, flipKey: .rightCommand).isNumbered)
    }

    @Test func atMostFiveReadingsAreListed() {
        let h = EngineHarness()
        h.detector.scores["abcdef"] = [.korean: -20000, .english: -20500, .mixed(latin: 1): -21000,
                                       .mixed(latin: 2): -21500, .mixed(latin: 3): -22000, .mixed(latin: 4): -22500]
        h.type("abcdef")
        guard case .alternative(let choice, _)? = h.hud?.content else {
            Issue.record("expected the choice bar")
            return
        }
        #expect(choice.readings.count == CompositionEngine.maxCandidates)
        #expect(!choice.readings.map(\.text).contains(FakeDetector().render(raw: "abcdef", .mixed(latin: 4))))
    }

    @Test func readingsFarBehindAreNotListed() {
        let h = EngineHarness()
        h.detector.scores["cmdfh"] = [.korean: -23000, .mixed(latin: 3): -25000, .english: -33001]
        h.type("cmdfh")
        guard case .alternative(let choice, _)? = h.hud?.content else {
            Issue.record("expected the choice bar")
            return
        }
        #expect(choice.readings.map(\.text) == ["층로", "cmd로"], "E is more than 10 nats behind")
    }

    // MARK: The flip key held (⌘3)

    static func isNumbered(_ h: EngineHarness) -> Bool {
        guard let content = h.hud?.content else { return false }
        return HUDPresentation(content, flipKey: h.engine.settings.flipKey).isNumbered
    }

    @Test func pressingTheFlipKeyBringsUpTheNumberedBarWithoutChangingTheWord() {
        let h = EngineHarness()
        h.detector.scores["dk"] = [.korean: -2000, .english: -9000]
        h.type("dk")
        #expect(h.hud?.isEligible == false, "E is 7 nats behind: the bar does not come up by itself")
        h.modifier(down: true)
        #expect(h.hud?.isEligible == true)
        #expect(Self.isNumbered(h))
        #expect(h.marked == "아")
    }

    @Test func aDigitWithTheFlipKeyHeldChoosesAndTheReleaseDoesNotFlip() {
        let h = EngineHarness()
        Self.typeCmdFh(h)
        h.modifier(down: true)
        let step = h.press(.character("2"), .command)
        #expect(step.consumed, "⌘2 is aimed at the bar, never a shortcut")
        #expect(h.marked == "cmd로")
        #expect(h.engine.token?.locked == .mixed(latin: 3))
        h.modifier(down: false)
        #expect(h.marked == "cmd로", "the digit made a chord: no tap")
        #expect(Self.isNumbered(h))
    }

    @Test func releasingTheFlipKeyAloneStillFlipsAndKeepsTheNumbers() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.modifier(down: true)
        h.modifier(down: false, after: 0.08)
        #expect(h.marked == "go")
        #expect(Self.isNumbered(h))
    }

    @Test func holdingTheFlipKeyPastTheTapWindowKeepsTheWordAndTheNumbers() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.modifier(down: true)
        h.modifier(down: false, after: 0.8)
        #expect(h.marked == "해")
        #expect(Self.isNumbered(h), "the bar stays numbered until the word ends")
    }

    @Test func aChordPastTheLastReadingDoesNothing() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.modifier(down: true)
        let step = h.press(.character("9"), .command)
        #expect(step.consumed)
        #expect(h.marked == "해")
        #expect(h.text == "해")
    }

    @Test func leftCommandWithADigitIsAShortcut() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.modifier(down: true, keyCode: FlipTapDetector.KeyCode.leftCommand,
                   device: FlipTapDetector.Flags.leftCommandDevice)
        #expect(!Self.isNumbered(h), "only the flip key brings up the numbers")
        let step = h.press(.character("2"), .command)
        #expect(!step.consumed, "the app gets ⌘2")
        #expect(h.marked == nil, "the shortcut commits the word first")
        #expect(h.text == "해")
    }

    @Test func aDigitWithShiftAndTheFlipKeyIsNotAChoice() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.modifier(down: true)
        #expect(h.engine.readingChordIndex(KeyEvent(.character("2"), modifiers: [.command, .shift])) == nil)
        #expect(h.engine.readingChordIndex(KeyEvent(.character("2"), modifiers: .command)) == 1)
    }

    @Test func rightOptionAsTheFlipKeyChoosesWithOptionDigits() {
        var settings = DuoSettings()
        settings.flipKey = .rightOption
        let h = EngineHarness(settings: settings)
        Self.typeCmdFh(h)
        h.modifier(down: true, keyCode: FlipTapDetector.KeyCode.rightOption, flag: FlipTapDetector.Flags.option,
                   device: FlipTapDetector.Flags.rightOptionDevice)
        #expect(Self.isNumbered(h))
        let step = h.press(.character("3"), .option)
        #expect(step.consumed)
        #expect(h.marked == "cmdfh")
    }

    @Test func theFlipKeyAfterACommitRevealsNothing() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go ")
        h.modifier(down: true)
        #expect(h.hud == nil)
        let step = h.press(.character("1"), .command)
        #expect(!step.consumed, "no word is being typed: ⌘1 is the app's")
    }

    @Test func aDigitChoosesAReadingAndCommittingTeachesTheLatinWord() throws {
        let h = EngineHarness()
        Self.typeCmdFh(h)
        let bar = try #require(h.hud)
        #expect(h.engine.selectReading(at: 1, on: bar, client: h.client) == .chosen)
        #expect(h.marked == "cmd로")
        #expect(h.engine.token?.locked == .mixed(latin: 3))
        h.press(.space)
        #expect(h.text == "cmd로 ")
        #expect(h.learned("cmdfh", .start) == [.mixed(latin: 3): 3])
        #expect(h.learned("cmd", .start) == [.mixed(latin: 3): 3],
                "a stem vote: it lifts cmd's other endings on the bar, never the bare word")
    }

    @Test func choosingTheShownReadingKeepsIt() throws {
        let h = EngineHarness()
        Self.typeCmdFh(h)
        let bar = try #require(h.hud)
        #expect(h.engine.selectReading(at: 0, on: bar, client: h.client) == .chosen)
        #expect(h.marked == "층로")
        #expect(h.engine.token?.locked == .korean)
        h.press(.space)
        #expect(h.store.count == 0, "keeping the shown reading teaches nothing")
    }

    @Test func aChoiceOnABarTheEngineHasReplacedIsIgnored() throws {
        let h = EngineHarness()
        Self.typeCmdFh(h)
        let bar = try #require(h.hud)
        h.detector.scores["cmdfhs"] = [.korean: -30000, .english: -31000]
        h.type("s")
        #expect(h.engine.selectReading(at: 1, on: bar, client: h.client) == .notOnBar)
        #expect(h.engine.token?.locked == nil)
    }

    // MARK: A Korean ending after a Latin choice

    @Test func afterChoosingEnglishAKoreanEndingFollows() {
        let h = EngineHarness()
        h.detector.scores["c"] = [.korean: -3000, .english: -9000]
        h.detector.scores["cm"] = [.korean: -6000, .english: -12000]
        h.detector.scores["cmd"] = [.korean: -9000, .english: -10000]
        h.type("cmd")
        #expect(h.marked == "층")
        h.flip()
        #expect(h.marked == "cmd")
        h.detector.scores["cmdf"] = [.korean: -20000, .mixed(latin: 3): -21000, .english: -22000]
        Self.scriptCmdFh(h.detector)
        h.type("fh")
        #expect(h.marked == "cmd로", "the ending reads as Korean after the chosen English")
        h.press(.space)
        #expect(h.text == "cmd로 ")
    }

    @Test func englishThatContinuesStaysEnglish() {
        let h = EngineHarness()
        h.detector.scores["cmd"] = [.korean: -9000, .english: -10000]
        h.type("cmd")
        h.flip()
        h.detector.scores["cmds"] = [.korean: -20000, .mixed(latin: 3): -26000, .english: -14000]
        h.type("s")
        #expect(h.marked == "cmds")
    }

    @Test func withoutAScoreAWholeSyllableEndingFollowsTheLatin() {
        // zlqhem is no lexicon word, so the detector scores no M(6): whole syllables decide.
        let h = EngineHarness()
        h.detector.scores["zlqhem"] = [.korean: -9000, .english: -10000]
        h.type("zlqhem")
        h.flip()
        #expect(h.marked == "zlqhem")
        h.type("dms")
        #expect(h.marked == "zlqhem은")
        h.type("x")
        #expect(h.marked == "zlqhemdmsx", "은 + ㅌ is no whole syllable: back to English")
    }

    @Test func aLatinPrefixTaughtAsEnglishHelpsItsEndingsOnTheBarOnly() {
        let h = EngineHarness()
        h.store.record(raw: "cmd", context: .start, hypothesis: .english, votes: 3)
        h.store.record(raw: "zlqhem", context: .start, hypothesis: .mixed(latin: 6), votes: 3)
        let carried = h.engine.userCounts("cmdfh", .start, carryLatinPrefixes: true)
        #expect(carried?[.mixed(latin: 3)] == 2, "half the 3 votes, rounded up")
        #expect(carried?[.korean] == 0, "층로 keeps its own score")
        #expect(h.engine.userCounts("cmdfh", .start) == nil, "display and commit see only the word's own learning")
        #expect(h.engine.userCounts("zlqhemdms", .start, carryLatinPrefixes: true)?[.mixed(latin: 6)] == 2,
                "a stem vote carries too")
        #expect(h.engine.userCounts("zlqhem", .start)?[.english] == 0, "the bare word never scores its stem vote")
    }

    @Test func theFlipKeyReturnsToTheLatinPlusEndingAfterAFlipBack() {
        let h = EngineHarness()
        h.detector.scores["cmd"] = [.korean: -9000, .english: -10000]
        h.type("cmd")
        h.flip()
        h.detector.scores["cmdf"] = [.korean: -20000, .mixed(latin: 3): -21000, .english: -22000]
        h.detector.scores["cmdfh"] = [.korean: -16000, .mixed(latin: 3): -26000, .english: -27000]
        h.type("fh")
        #expect(h.marked == "cmd로")
        guard case .alternative(let choice, _)? = h.hud?.content else {
            Issue.record("expected the choice bar")
            return
        }
        #expect(choice.readings.map(\.text) == ["층로", "cmdfh", "cmd로"], "the original first, then its flip target")
        h.flip()
        #expect(h.marked == "층로", "from the last reading back to the first")
        h.flip()
        #expect(h.marked == "cmdfh")
        h.flip()
        #expect(h.marked == "cmd로", "the flip key walks the whole bar")
    }

    @Test func keepingTheShownReadingAgainstTheModelTeachesIt() throws {
        let h = EngineHarness()
        h.detector.scores["cmdfh"] = [.korean: -16000, .mixed(latin: 3): -18000, .english: -27000]
        h.detector.finals["cmdfh"] = [.korean: -24000, .mixed(latin: 3): -22000, .english: -27000]
        h.type("cmdfh")
        #expect(h.marked == "층로")
        let bar = try #require(h.hud)
        let index = try #require({ if case .alternative(let c, _) = bar.content { c.selected } else { nil } }())
        #expect(h.engine.selectReading(at: index, on: bar, client: h.client) == .chosen)
        h.press(.space)
        #expect(h.text == "층로 ")
        #expect(h.learned("cmdfh", .start) == [.korean: 3], "a boundary would have committed cmd로")
    }

    @Test func backspaceKeepsAChosenEndingTheDetectorDoesNotScore() {
        let h = EngineHarness()
        h.detector.scores["zlqhem"] = [.korean: -9000, .english: -10000]
        h.type("zlqhem")
        h.flip()
        h.type("dms")
        #expect(h.marked == "zlqhem은")
        h.press(.backspace)
        #expect(h.marked == "zlqhem으", "still Latin plus ending, not zlqhemdm")
    }

    // MARK: Clicking the word being typed

    @Test func clickingTheOtherReadingFlipsTheWordBeingTyped() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        _ = h.client.take()
        #expect(Self.click(h))
        #expect(h.client.take() == [.markedRange, .mark("go", nil)], "a click re-checks the marked text first")
        #expect(h.marked == "go")
        #expect(h.engine.token?.locked == .english)
        #expect(h.notifications == [.flipped(to: .english)])
        #expect(h.hud?.alternativeText == "해", "the bar now offers the way back")
        h.press(.space)
        #expect(h.text == "go ")
        #expect(h.learned("go", .start) == [.english: 3], "a click teaches like the flip key")
    }

    @Test func aSecondClickReturnsToTheOriginal() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        Self.click(h)
        #expect(Self.click(h))
        #expect(h.marked == "해")
        h.press(.space)
        #expect(h.store.count == 0, "flipping back cancels the vote")
    }

    @Test func aClickAfterTheClientDroppedTheMarkedTextChangesNothing() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.buffer.unmarkText()
        #expect(!Self.click(h))
        #expect(h.text == "해")
        #expect(!h.engine.isComposing)
        #expect(h.engine.oneShot == nil)
    }

    // MARK: Clicking the word just committed

    @Test func clickingTheLastWordsOtherReadingReplacesIt() {
        let h = EngineHarness()
        Self.typeUncertainDk(h)
        #expect(h.text == "아 ")
        #expect(h.hud?.isLastWordChoice == true)
        #expect(Self.click(h))
        #expect(h.text == "dk ")
        #expect(h.notifications.contains(.flipped(to: .english)))
        #expect(h.hud == HUDRequest(content: .flipLastWord(bar("dk", .english, offering: "아", .korean, currentFirst: false)),
                                    anchor: .location(0), immediate: true, lifetime: CompositionEngine.chipLifetime),
                "the bar stays with the selection moved")
        #expect(h.learned("dk", .start) == [.english: 3])
        #expect(Self.click(h), "and a second click undoes it")
        #expect(h.text == "아 ")
    }

    @Test func aClickAfterTheCaretMovedSaysItCannotChange() {
        let h = EngineHarness()
        Self.typeUncertainDk(h)
        h.buffer.select(NSRange(location: 0, length: 0))
        #expect(!Self.click(h))
        #expect(h.text == "아 ")
        #expect(h.hud?.content == .cannotChange, "the bar offered the switch: say why nothing happened")
        #expect(h.engine.oneShot == nil, "a click never arms the next word")
    }

    @Test func aClickOnABarTheEngineHasReplacedIsIgnored() throws {
        let h = EngineHarness()
        Self.typeUncertainDk(h)
        let chip = try #require(h.hud)
        h.type("r")   // a new word starts while the chip is still fading out
        #expect(!h.engine.chooseOtherReading(on: chip, client: h.client))
        #expect(h.text.hasPrefix("아 "), "the clicked word is not touched")
        #expect(h.engine.token?.locked == nil, "and the new word is not flipped")
    }

    @Test func aClickInAClientThatCannotReplaceShowsCannotChange() {
        let h = EngineHarness(bundleIdentifier: "com.microsoft.VSCode")
        h.buffer.ignoresReplacementRanges = true
        Self.typeUncertainDk(h)
        let before = h.text
        // Monaco gets no chip (it cannot replace committed text), so give the engine one by hand.
        let lc = h.engine.lastCommit!
        h.engine.hud = h.engine.lastWordChoiceHUD(lc, start: 0)
        #expect(!Self.click(h))
        #expect(h.hud?.content == .cannotChange)
        #expect(h.text == before)
    }

    // MARK: Readings of the end of a word (중간에 + english)

    /// 중간에 then english typed as one word: the Korean start reads clearly, the English end reads
    /// as English on its own, and the whole word reads as Korean (중간에두히ㅑ노).
    static func scriptKoreanThenEnglish(_ d: FakeDetector) {
        d.korean("wndrksdp")
        d.scores["wndrksdpenglish"] = [.korean: -30_000, .english: -60_000]
        d.scores["english"] = [.english: -9000, .korean: -40_000]
    }

    static func readings(_ h: EngineHarness) -> [String] {
        guard case .alternative(let choice, _)? = h.hud?.content else { return [] }
        return choice.readings.map(\.text)
    }

    @Test func aLongWordOffersItsEnglishEndFirst() throws {
        let h = EngineHarness()
        Self.scriptKoreanThenEnglish(h.detector)
        h.type("wndrksdpenglish")
        #expect(h.marked == "중간에두히ㅑ노", "typing is not changed")
        guard case .alternative(let choice, let eligible)? = h.hud?.content else {
            Issue.record("expected the choice bar")
            return
        }
        #expect(eligible, "a long word whose end reads much better as English brings the bar up by itself")
        #expect(choice.readings.map(\.text) == ["중간에두히ㅑ노", "중간에english", "wndrksdpenglish"],
                "the end beats 30 keys of Latin gibberish, so it is the first flip; the other script stays")
        #expect(choice.readings[1].language == .english)
        #expect(choice.alternate == 1)
    }

    @Test func choosingTheEndCommitsTheStartAndKeepsTheEndComposing() {
        let h = EngineHarness()
        Self.scriptKoreanThenEnglish(h.detector)
        h.type("wndrksdpenglish")
        let calls = h.flip()
        #expect(calls.filter(\.isMutation) == [.insert("중간에", nil), .mark("english", nil)],
                "the start as shown, then the end marked: no replacement range (NSTextView ignores it while marked)")
        #expect(h.text == "중간에english")
        #expect(h.marked == "english")
        #expect(h.engine.token?.locked == .english)
        #expect(h.notifications.contains(.flipped(to: .english)))
        #expect(Self.readings(h) == ["두히ㅑ노", "english"], "the end's own bar")
        #expect(Self.isNumbered(h))
    }

    @Test func aKoreanEndingFollowsTheChosenEnglishAndNothingIsLearned() {
        let h = EngineHarness()
        Self.scriptKoreanThenEnglish(h.detector)
        h.detector.scores["englishrk"] = [.korean: -40_000, .english: -25_000, .mixed(latin: 7): -12_000]
        h.type("wndrksdpenglish")
        h.flip()
        h.type("rk")
        #expect(h.marked == "english가", "English then a particle, as after any Latin choice")
        h.press(.space)
        #expect(h.text == "중간에english가 ")
        #expect(h.store.count == 0, "neither the start nor the end is a word the user typed on its own")
    }

    @Test func flippingTheEndBackJoinsTheWordAgain() {
        let h = EngineHarness()
        Self.scriptKoreanThenEnglish(h.detector)
        h.type("wndrksdpenglish")
        h.flip()
        let back = h.flip()
        #expect(back.filter(\.isMutation) == [.insert("english", nil),
                                              .mark("중간에두히ㅑ노", NSRange(location: 0, length: 10))],
                "end the composition first, then mark the whole word over the start and the end")
        #expect(h.text == "중간에두히ㅑ노")
        #expect(h.marked == "중간에두히ㅑ노", "one word again")
        #expect(h.engine.token?.raw == "wndrksdpenglish")
        #expect(Self.readings(h) == ["중간에두히ㅑ노", "중간에english", "wndrksdpenglish"])
        h.flip()
        #expect(h.text == "중간에english", "the flip key walks the bar again")
    }

    @Test func backspaceOverTheWholeEndReopensTheStart() {
        let h = EngineHarness()
        Self.scriptKoreanThenEnglish(h.detector)
        h.type("wndrksdpenglish")
        h.flip()
        for _ in 0..<7 { h.press(.backspace) }
        #expect(h.text == "중간에")
        #expect(h.marked == "중간에", "the start is composing again")
        h.press(.backspace)
        #expect(h.marked == "중간ㅇ")
    }

    @Test func whereCommittedTextCannotChangeTheEndStaysAWordOfItsOwn() {
        let h = EngineHarness(bundleIdentifier: "com.microsoft.VSCode")
        h.buffer.ignoresReplacementRanges = true
        Self.scriptKoreanThenEnglish(h.detector)
        h.type("wndrksdpenglish")
        h.flip()
        #expect(h.text == "중간에english", "a split never replaces committed text")
        h.flip()
        #expect(h.text == "중간에두히ㅑ노")
        #expect(h.marked == "두히ㅑ노", "the start stays committed")
        for _ in 0..<7 { h.press(.backspace) }
        #expect(h.text == "중간에")
        #expect(h.marked == nil, "the start is not re-opened: the app deletes from it")
        #expect(!h.press(.backspace).consumed)
    }

    @Test func aShortWordKeepsTheOtherScriptFirst() {
        // 초 + at reads better than 촘ㅅ, but chat is a word: an end only goes first when it beats the
        // other script's reading by segmentMargin.
        let h = EngineHarness()
        h.detector.korean("ch")
        h.detector.scores["cha"] = [.korean: -3000, .english: -6000]
        h.detector.scores["chat"] = [.korean: -8000, .english: -9000]
        h.detector.scores["at"] = [.english: -3000, .korean: -12_000]
        h.type("chat")
        #expect(h.marked == "촘ㅅ")
        h.modifier(down: true)
        #expect(Self.readings(h) == ["촘ㅅ", "chat", "초at"], "listed after the other script")
        h.modifier(down: false)
        #expect(h.marked == "chat")
    }

    @Test func endsAreOnlyComputedWhenTheyCanMatter() {
        let h = EngineHarness()
        h.detector.korean("ch")
        h.detector.scores["cha"] = [.korean: -3000, .english: -6000]
        h.detector.scores["chat"] = [.korean: -8000, .english: -9000]
        h.detector.scores["at"] = [.english: -3000, .korean: -12_000]
        h.type("chat")
        #expect(!h.detector.choiceCalls.contains("at"), "a short word without the flip key: no ends")
        h.modifier(down: true)
        #expect(h.detector.choiceCalls.contains("at"), "the flip key brings them")
    }

    @Test func aLatinStartWithAKoreanEndTheDetectorDoesNotScoreIsOffered() {
        // regex + 쓰면: the detector scores no M(5) (regex is no lexicon word and 쓰면 no suffix).
        var settings = DuoSettings.default
        settings.eagerEnglishCommit = false
        let h = EngineHarness(settings: settings)
        h.detector.english("regex")
        h.detector.scores["regexTmaus"] = [.korean: -45_000, .english: -30_000]
        h.detector.scores["Tmaus"] = [.korean: -6000, .english: -25_000]
        h.type("regexTmaus")
        #expect(h.marked == "regexTmaus")
        #expect(Self.readings(h) == ["regexTmaus", "regex쓰면", FakeDetector.hangul("regexTmaus")],
                "the end reading goes first; the Korean reading, 15 nats behind, stays as the other script")
        h.flip()
        #expect(h.marked == "regex쓰면")
        #expect(h.engine.token?.locked == .mixed(latin: 5))
    }

    @Test func aChosenEndOnTheBarWithADigit() throws {
        let h = EngineHarness()
        Self.scriptKoreanThenEnglish(h.detector)
        h.type("wndrksdpenglish")
        h.modifier(down: true)
        let step = h.press(.character("2"), .command)
        #expect(step.consumed)
        #expect(h.text == "중간에english")
        #expect(h.marked == "english")
    }

    // MARK: Nothing to choose

    @Test(arguments: [nil, HUDRequest(content: .oneShot(.english), anchor: .caret, immediate: true, lifetime: 0.9),
                      HUDRequest(content: .cannotChange, anchor: .caret, immediate: true, lifetime: 1.2)])
    func aClickWithoutAChoiceBarDoesNothing(_ request: HUDRequest?) {
        let h = EngineHarness()
        h.type("dk")
        h.engine.hud = request
        #expect(!Self.click(h))
        #expect(h.engine.oneShot == nil)
        #expect(h.marked == "아")
    }
}
