import Foundation
import Testing
@testable import DuoCore

/// docs/SPEC.md §4.11: the choice bar shows both readings of an ambiguous word, and a click on the
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
