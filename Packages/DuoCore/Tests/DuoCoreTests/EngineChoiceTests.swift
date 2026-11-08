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
