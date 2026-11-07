import DuoCore
import DuoKit
import Testing

@Suite("HUD presentation")
struct HUDPresentationTests {
    @Test("an alternative shows its badge, text and the flip key's keycaps", arguments: FlipKey.allCases)
    func alternative(flipKey: FlipKey) {
        let p = HUDPresentation(.alternative(text: "dkssud", language: .english, eligible: true), flipKey: flipKey)
        #expect(p.kind == .alternative)
        #expect(p.text == "dkssud")
        #expect(p.badge == .english)
        #expect(p.keycaps == flipKey.keycaps)
        #expect(!p.showsUndoGlyph)
        #expect(!p.isBadgeOnly)
        #expect(p.opacity == 1)
    }

    @Test("eligibility does not change what is drawn")
    func eligibilityIsTimingOnly() {
        let a = HUDPresentation(.alternative(text: "해", language: .korean, eligible: true), flipKey: .rightCommand)
        let b = HUDPresentation(.alternative(text: "해", language: .korean, eligible: false), flipKey: .rightCommand)
        #expect(a == b)
    }

    @Test("the flip-last-word chip adds the ↺ glyph")
    func flipLastWord() {
        let p = HUDPresentation(.flipLastWord(text: "해", language: .korean), flipKey: .rightCommand)
        #expect(p.kind == .flipLastWord)
        #expect(p.showsUndoGlyph)
        #expect(p.badge == .korean)
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
