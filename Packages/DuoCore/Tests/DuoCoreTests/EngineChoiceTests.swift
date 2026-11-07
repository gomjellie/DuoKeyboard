import Foundation
import Testing
@testable import DuoCore

/// docs/SPEC.md §4.11: the choice bar shows both readings of an ambiguous word.
@MainActor
@Suite("Engine · choice bar")
struct EngineChoiceTests {
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
}
