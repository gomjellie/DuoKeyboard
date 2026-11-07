import DuoCore
import DuoKit
import Testing

private let cannotChange = HUDRequest(content: .cannotChange, anchor: .caret, immediate: true, lifetime: 1.2)
private let badge = HUDRequest(content: .bilingualLine, anchor: .caret, immediate: true)
private func oneShot(_ language: ScriptLanguage) -> HUDRequest {
    HUDRequest(content: .oneShot(language), anchor: .caret, immediate: true, lifetime: 0.9)
}
private let chip = HUDRequest(content: .flipLastWord(text: "해", language: .korean), anchor: .location(3),
                              immediate: true, lifetime: 1.6)
private let alternative = HUDRequest(content: .alternative(text: "dk", language: .english, eligible: true),
                                     anchor: .markedText)

@Suite("HUD announcements for flip-key feedback")
struct HUDAnnouncementTests {
    @Test("a refused flip says it cannot change text", arguments: [HUDAnnouncement.Press.modifier, .keyDown])
    func refused(press: HUDAnnouncement.Press) {
        #expect(HUDAnnouncement.feedback(for: press, before: nil, after: cannotChange) == .cannotChange)
        #expect(HUDAnnouncement.feedback(for: press, before: chip, after: cannotChange) == .cannotChange)
    }

    @Test("arming the next word's language names it", arguments: [ScriptLanguage.korean, .english])
    func armsOneShot(language: ScriptLanguage) {
        #expect(HUDAnnouncement.feedback(for: .modifier, before: nil, after: oneShot(language)) == .oneShot(language))
    }

    @Test("a second press cancels the next word's language", arguments: [HUDAnnouncement.Press.modifier, .keyDown])
    func cancelsOneShot(press: HUDAnnouncement.Press) {
        #expect(HUDAnnouncement.feedback(for: press, before: oneShot(.english), after: nil) == .oneShotCancelled)
    }

    @Test("Bilingual for the line: on, then off")
    func bilingualToggle() {
        #expect(HUDAnnouncement.feedback(for: .modifier, before: nil, after: badge) == .bilingualLineOn)
        #expect(HUDAnnouncement.feedback(for: .modifier, before: chip, after: badge) == .bilingualLineOn)
        #expect(HUDAnnouncement.feedback(for: .modifier, before: badge, after: nil) == .bilingualLineOff)
        #expect(HUDAnnouncement.feedback(for: .keyDown, before: badge, after: nil) == .bilingualLineOff)
    }

    @Test("a badge that stays up is not announced again (the engine re-shows it after every key)")
    func badgeStaysQuiet() {
        #expect(HUDAnnouncement.feedback(for: .keyDown, before: badge, after: badge) == nil)
        #expect(HUDAnnouncement.feedback(for: .modifier, before: badge, after: badge) == nil)
    }

    @Test("an unchanged request after a modifier means nothing happened (a hold, not a tap)")
    func unchangedModifierIsSilent() {
        #expect(HUDAnnouncement.feedback(for: .modifier, before: cannotChange, after: cannotChange) == nil)
        #expect(HUDAnnouncement.feedback(for: .modifier, before: oneShot(.korean), after: oneShot(.korean)) == nil)
    }

    @Test("⇧Space refused twice is announced twice: the engine cleared its request in between")
    func keyDownRepeatsRefusal() {
        #expect(HUDAnnouncement.feedback(for: .keyDown, before: cannotChange, after: cannotChange) == .cannotChange)
    }

    @Test("other outcomes say nothing", arguments: [
        (nil, nil), (alternative, nil), (chip, nil), (nil, alternative), (nil, chip), (alternative, alternative),
    ] as [(HUDRequest?, HUDRequest?)])
    func silent(before: HUDRequest?, after: HUDRequest?) {
        #expect(HUDAnnouncement.feedback(for: .modifier, before: before, after: after) == nil)
        #expect(HUDAnnouncement.feedback(for: .keyDown, before: before, after: after) == nil)
    }

    @Test("only the flip key's own flagsChanged counts", arguments: [
        (FlipKey.rightCommand, FlipTapDetector.KeyCode.rightCommand, true),
        (.rightCommand, FlipTapDetector.KeyCode.leftCommand, false),
        (.rightCommand, FlipTapDetector.KeyCode.capsLock, false),     // Caps Lock commits, never flips here
        (.rightCommand, FlipTapDetector.KeyCode.function, false),
        (.rightOption, FlipTapDetector.KeyCode.rightOption, true),
        (.doubleShift, FlipTapDetector.KeyCode.leftShift, true),
        (.doubleShift, FlipTapDetector.KeyCode.rightShift, true),
        (.capsLock, FlipTapDetector.KeyCode.capsLock, true),
        (.shiftSpace, FlipTapDetector.KeyCode.leftShift, false),
    ])
    func flipKeyModifier(flipKey: FlipKey, keyCode: UInt16, expected: Bool) {
        #expect(HUDAnnouncement.isFlipKey(modifierKeyCode: keyCode, flipKey: flipKey) == expected)
    }

    @Test("⇧Space is a flip-key press only for the ⇧Space setting, with exactly ⇧, and not on autorepeat")
    func flipKeyDown() {
        let shiftSpace = KeyEvent(.space, modifiers: .shift)
        #expect(HUDAnnouncement.isFlipKey(shiftSpace, flipKey: .shiftSpace))
        #expect(HUDAnnouncement.isFlipKey(KeyEvent(.space, modifiers: [.shift, .capsLock]), flipKey: .shiftSpace))
        #expect(!HUDAnnouncement.isFlipKey(shiftSpace, flipKey: .rightCommand))
        #expect(!HUDAnnouncement.isFlipKey(KeyEvent(.space), flipKey: .shiftSpace))
        #expect(!HUDAnnouncement.isFlipKey(KeyEvent(.space, modifiers: [.shift, .command]), flipKey: .shiftSpace))
        #expect(!HUDAnnouncement.isFlipKey(KeyEvent(.space, modifiers: .shift, isRepeat: true), flipKey: .shiftSpace))
        #expect(!HUDAnnouncement.isFlipKey(KeyEvent(.letter(Keystroke(base: "a", shift: true)), modifiers: .shift),
                                           flipKey: .shiftSpace))
    }
}
