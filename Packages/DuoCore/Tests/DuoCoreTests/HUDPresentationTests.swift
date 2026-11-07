import DuoCore
import DuoKit
import Testing

/// 아 in the document, dk offered.
private let choice = HUDChoice(current: HUDReading(text: "아", language: .korean),
                               other: HUDReading(text: "dk", language: .english), currentFirst: true)

@Suite("HUD presentation")
struct HUDPresentationTests {
    @Test("an alternative is the choice bar with both readings and the flip key's keycaps",
          arguments: FlipKey.allCases)
    func alternative(flipKey: FlipKey) {
        let p = HUDPresentation(.alternative(choice, eligible: true), flipKey: flipKey)
        #expect(p.kind == .alternative)
        #expect(p.choice == choice)
        #expect(p.badge == nil)
        #expect(p.keycaps == flipKey.keycaps)
        #expect(!p.isBadgeOnly)
        #expect(p.opacity == 1)
    }

    @Test("the choice keeps its order and marks the reading in the document")
    func choiceOrder() {
        #expect(choice.readings.map(\.text) == ["아", "dk"])
        #expect(choice.current.text == "아")
        #expect(choice.other.text == "dk")
        let flipped = HUDChoice(current: choice.other, other: choice.current, currentFirst: false)
        #expect(flipped.readings == choice.readings, "a flip moves the selection, not the readings")
        #expect(flipped.selected == 1)
    }

    @Test("eligibility does not change what is drawn")
    func eligibilityIsTimingOnly() {
        let a = HUDPresentation(.alternative(choice, eligible: true), flipKey: .rightCommand)
        let b = HUDPresentation(.alternative(choice, eligible: false), flipKey: .rightCommand)
        #expect(a == b)
    }

    @Test("the last word's choice bar shows both readings too")
    func flipLastWord() {
        let p = HUDPresentation(.flipLastWord(choice), flipKey: .rightCommand)
        #expect(p.kind == .flipLastWord)
        #expect(p.choice == choice)
        #expect(p.keycaps == ["⌘"])
    }

    @Test("one-shot is a badge only", arguments: [ScriptLanguage.korean, .english])
    func oneShot(language: ScriptLanguage) {
        let p = HUDPresentation(.oneShot(language), flipKey: .doubleShift)
        #expect(p.kind == .oneShot)
        #expect(p.badge == language)
        #expect(p.isBadgeOnly)
        #expect(p.keycaps.isEmpty)
    }

    @Test("cannot-change is a message with no badge and no keycaps")
    func cannotChange() {
        let p = HUDPresentation(.cannotChange, flipKey: .rightCommand)
        #expect(p.kind == .cannotChange)
        #expect(p.badge == nil)
        #expect(p.keycaps.isEmpty)
        #expect(!p.isBadgeOnly)
    }

    @Test("the Bilingual-line badge is a dimmed 가 badge")
    func bilingualLine() {
        let p = HUDPresentation(.bilingualLine, flipKey: .rightOption)
        #expect(p.kind == .bilingualLine)
        #expect(p.badge == .korean)
        #expect(p.isBadgeOnly)
        #expect(p.opacity == 0.6)
    }
}
