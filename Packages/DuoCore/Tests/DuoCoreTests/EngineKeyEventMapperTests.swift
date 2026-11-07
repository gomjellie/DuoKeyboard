import AppKit
import DuoCore
import DuoKit
import Testing

/// DuoKit.KeyEventMapper: NSEvent → KeyEvent / ModifierEvent (critique R16).
@MainActor
@Suite("Engine · KeyEventMapper")
struct EngineKeyEventMapperTests {
    static func keyDown(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], characters: String = "x",
                        repeat isRepeat: Bool = false, timestamp: TimeInterval = 42) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: timestamp, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: isRepeat, keyCode: code)!
    }

    static func flagsChanged(_ code: UInt16, _ raw: UInt, timestamp: TimeInterval = 7) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
                         timestamp: timestamp, windowNumber: 0, context: nil, characters: "",
                         charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    @Test(arguments: KeyScript.ansiKeyCodes.filter { $0.key.isLetter }.map { ($0.key, $0.value) })
    func lettersComeFromTheKeyPosition(_ letter: Character, _ code: UInt16) {
        // `characters` is deliberately wrong (Dvorak, Korean layout): only the key code counts.
        let plain = KeyEventMapper.keyEvent(from: Self.keyDown(code, characters: "ㅁ"))
        #expect(plain?.key == .letter(Keystroke(base: letter, shift: false)))
        let shifted = KeyEventMapper.keyEvent(from: Self.keyDown(code, .shift, characters: "Q"))
        #expect(shifted?.key == .letter(Keystroke(base: letter, shift: true)))
        #expect(shifted?.modifiers == .shift)
    }

    @Test func capsLockIsAModifierNotAShift() {
        let e = KeyEventMapper.keyEvent(from: Self.keyDown(0x00, .capsLock, characters: "A"))
        #expect(e?.key == .letter(Keystroke(base: "a", shift: false)))
        #expect(e?.modifiers == .capsLock)
    }

    @Test(arguments: [
        (UInt16(0x12), "1", "!"), (0x13, "2", "@"), (0x14, "3", "#"), (0x15, "4", "$"), (0x17, "5", "%"),
        (0x16, "6", "^"), (0x1A, "7", "&"), (0x1C, "8", "*"), (0x19, "9", "("), (0x1D, "0", ")"),
        (0x1B, "-", "_"), (0x18, "=", "+"), (0x21, "[", "{"), (0x1E, "]", "}"), (0x2A, "\\", "|"),
        (0x29, ";", ":"), (0x27, "'", "\""), (0x2B, ",", "<"), (0x2F, ".", ">"), (0x2C, "/", "?"),
        (0x32, "`", "~"),
    ] as [(UInt16, Character, Character)])
    func digitsAndPunctuationUseTheABCLayout(_ code: UInt16, _ base: Character, _ shifted: Character) {
        #expect(KeyEventMapper.keyEvent(from: Self.keyDown(code))?.key == .character(base))
        #expect(KeyEventMapper.keyEvent(from: Self.keyDown(code, .shift))?.key == .character(shifted))
    }

    @Test func tablesAgreeWithTheHarnessDSL() {
        for (ch, code) in KeyScript.ansiKeyCodes where !ch.isLetter && ch != " " {
            #expect(KeyEventMapper.key(forKeyCode: code, shift: false) == .character(ch))
        }
        for (shifted, base) in KeyScript.shiftedSymbols {
            let code = KeyScript.ansiKeyCodes[base]!
            #expect(KeyEventMapper.key(forKeyCode: code, shift: true) == .character(shifted))
        }
    }

    @Test(arguments: [
        (UInt16(0x52), "0"), (0x53, "1"), (0x5C, "9"), (0x41, "."), (0x43, "*"), (0x45, "+"), (0x4B, "/"),
        (0x4E, "-"), (0x51, "="),
    ] as [(UInt16, Character)])
    func keypad(_ code: UInt16, _ c: Character) {
        #expect(KeyEventMapper.keyEvent(from: Self.keyDown(code, .numericPad))?.key == .keypad(c))
    }

    @Test(arguments: [
        (UInt16(0x31), KeyEvent.Key.space), (0x24, .returnKey), (0x4C, .returnKey), (0x30, .tab), (0x35, .escape),
        (0x33, .backspace), (0x75, .forwardDelete), (0x7B, .arrowLeft), (0x7C, .arrowRight), (0x7E, .arrowUp),
        (0x7D, .arrowDown), (0x73, .navigation), (0x77, .navigation), (0x74, .navigation), (0x79, .navigation),
        (0x72, .navigation), (0x7A, .function), (0x6F, .function), (0x4F, .function), (0x5A, .function),
        (0x66, .other), (0x68, .other),
    ] as [(UInt16, KeyEvent.Key)])
    func specialKeys(_ code: UInt16, _ key: KeyEvent.Key) {
        #expect(KeyEventMapper.keyEvent(from: Self.keyDown(code, characters: ""))?.key == key)
    }

    @Test func modifiersIncludingFunctionAndCapsLock() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock, .function, .numericPad]
        #expect(KeyEventMapper.modifiers(from: flags) == [.shift, .control, .option, .command, .capsLock, .function])
        let arrow = KeyEventMapper.keyEvent(from: Self.keyDown(0x7B, [.numericPad, .function]))
        #expect(arrow?.modifiers == .function)
    }

    @Test(arguments: [(UInt16(0x0E), true), (0x32, true), (0x20, true), (0x22, true), (0x2D, true), (0x00, false),
                      (0x01, false)] as [(UInt16, Bool)])
    func deadKeys(_ code: UInt16, _ dead: Bool) {
        let e = KeyEventMapper.keyEvent(from: Self.keyDown(code, .option, characters: ""))
        #expect(e?.isDeadKey == dead)
        #expect(KeyEventMapper.keyEvent(from: Self.keyDown(code, [.option, .shift]))?.isDeadKey == false)
        #expect(KeyEventMapper.keyEvent(from: Self.keyDown(code, [.option, .command]))?.isDeadKey == false)
        #expect(KeyEventMapper.keyEvent(from: Self.keyDown(code))?.isDeadKey == false)
    }

    @Test func repeatAndTimestamp() {
        let e = KeyEventMapper.keyEvent(from: Self.keyDown(0x06, repeat: true, timestamp: 123.5))
        #expect(e?.isRepeat == true)
        #expect(e?.timestamp == 123.5)
    }

    @Test func modifierEvents() {
        let raw: UInt = 0x100000 | 0x10 | 0x100
        let m = KeyEventMapper.modifierEvent(from: Self.flagsChanged(54, raw), pressedMouseButtons: 1)
        #expect(m == ModifierEvent(keyCode: 54, flags: raw, timestamp: 7, pressedMouseButtons: 1))
        #expect(KeyEventMapper.keyEvent(from: Self.flagsChanged(54, raw)) == nil)
        #expect(KeyEventMapper.modifierEvent(from: Self.keyDown(0x00)) == nil)
    }

    @Test func mappedEventsDriveTheEngineLikeTypedOnes() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        let codes: [UInt16] = [0x02, 0x28, 0x01, 0x01, 0x20, 0x02]   // d k s s u d
        for code in codes {
            h.press(KeyEventMapper.keyEvent(from: Self.keyDown(code))!)
        }
        #expect(h.marked == "안녕")
    }
}
