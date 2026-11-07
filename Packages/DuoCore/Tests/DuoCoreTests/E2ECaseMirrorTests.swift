// Replays `Tests/E2E/cases.json` through the in-process engine with the REAL model, mirroring what
// the live E2E run does (DuoHarness + the input method's DEBUG-only DebugInjector), so a change in
// the engine or the model that would break the live run shows up in `swift test` first, without
// installing the input method or taking focus.
//
// The mirror follows the live path step by step:
// - every case starts with a click in the previous field, then gets a fresh empty field (the
//   harness injects `{click}` before clearing its text view);
// - keys are `KeyScript` events built the way `DebugInjector` builds them (device bits, Caps Lock
//   state carried into keyDowns), mapped with `KeyEventMapper`;
// - a key the engine passes through is applied to the field the way the harness's text view does;
// - one engine and one learning store serve all cases, in file order, as one IMK controller and
//   the IME's shared store do in the live run (so a flip in one case is learned for the next).

import AppKit
import DuoKit
import Foundation
import Testing
@testable import DuoCore

@MainActor
@Suite("E2E cases (in-process mirror, real model)", .enabled(if: RealModel.isAvailable, "needs the real DuoDetector port"))
struct E2ECaseMirrorTests {
    struct Case: Decodable {
        var name: String
        var keys: String
        var expect: String?
        var expectMarked: String?
    }

    /// `<repo>/Tests/E2E/cases.json`.
    static let casesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // DuoCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // DuoCore
        .appending(path: "../../Tests/E2E/cases.json")
        .standardizedFileURL

    @Test func caseFileIsWellFormed() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.casesURL))
        #expect(!cases.isEmpty)
        #expect(Set(cases.map(\.name)).count == cases.count, "case names are unique (report keys)")
        for c in cases {
            #expect(c.expect != nil || c.expectMarked != nil, "\(c.name) checks something")
            #expect(!KeyScript.parse(c.keys).isEmpty, "\(c.name) has keys")
        }
    }

    @Test func everyCaseMatchesTheEngine() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.casesURL))
        let mirror = try #require(HarnessMirror())
        for c in cases {
            let (text, marked) = mirror.run(c.keys)
            if let expect = c.expect {
                #expect(text == expect, "\(c.name): text")
            }
            if let expectMarked = c.expectMarked {
                #expect(marked == expectMarked, "\(c.name): marked text")
            }
        }
        #expect(!mirror.capsLockOn, "cases leave Caps Lock off (the live injector keeps its state)")
    }
}

/// One IMK controller's engine plus the harness's text view, driven like the live E2E run.
@MainActor
final class HarnessMirror {
    let engine: CompositionEngine
    private var field = BufferTextClient(bundleIdentifier: DuoIDs.harnessBundleID)
    /// `DebugInjector` keeps Caps Lock state across scripts, like the real toggle.
    private(set) var capsLockOn = false

    init?() {
        guard let detector = RealModel.detector else { return nil }
        engine = CompositionEngine(detector: detector, learning: LearningStore(), settings: .default,
                                   bundleIdentifier: DuoIDs.harnessBundleID)
        engine.setClient(bundleIdentifier: DuoIDs.harnessBundleID)
    }

    /// Runs one case: reset click, fresh field, then the keys. Returns the field's text and marked text.
    func run(_ keys: String) -> (text: String, marked: String) {
        engine.commit(.mouse, client: field)
        field = BufferTextClient(bundleIdentifier: DuoIDs.harnessBundleID)
        for key in KeyScript.parse(keys) {
            switch key.kind {
            case .wait:
                Thread.sleep(forTimeInterval: Double(key.milliseconds) / 1000)
            case .click:
                engine.commit(.mouse, client: field)
            case .modifierTap, .modifierPress, .modifierRelease:
                for event in flagsEvents(for: key) {
                    if let modifier = KeyEventMapper.modifierEvent(from: event, pressedMouseButtons: 0) {
                        engine.handleModifier(modifier, client: field)
                    }
                }
            case .key:
                let key = applyingCapsLock(key)
                guard let event = keyDownEvent(key), let mapped = KeyEventMapper.keyEvent(from: event) else {
                    Issue.record("unmapped key \(key)")
                    continue
                }
                if !engine.handle(mapped, client: field) {
                    field.applyPassedKey(mapped, characters: key.characters)
                }
            }
        }
        return (field.text, field.markedText ?? "")
    }

    // The same event construction as DuoInputMethod/Sources/Debug/DebugInjector.swift.

    private func applyingCapsLock(_ key: SyntheticKey) -> SyntheticKey {
        guard capsLockOn else { return key }
        var key = key
        key.modifiers |= KeyScript.capsLockFlag
        if key.modifiers & (KeyScript.commandFlag | KeyScript.controlFlag) == 0,
           key.characters.count == 1, key.characters.first?.isLetter == true {
            key.characters = key.characters.uppercased()
        }
        return key
    }

    private func keyDownEvent(_ key: SyntheticKey) -> NSEvent? {
        let flags = key.modifiers | KeyScript.leftDeviceBits(forModifiers: key.modifiers) | KeyScript.nonCoalescedFlag
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                characters: key.characters, charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                isARepeat: false, keyCode: key.keyCode)
    }

    private func flagsEvents(for key: SyntheticKey) -> [NSEvent] {
        let masks: [UInt]
        if key.keyCode == KeyScript.VK.capsLock {
            capsLockOn.toggle()
            masks = [capsLockOn ? KeyScript.capsLockFlag : 0]
        } else {
            masks = KeyScript.flagsMasks(for: key)
        }
        return masks.compactMap { mask in
            let flags = mask | KeyScript.nonCoalescedFlag
            guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: mask != 0) else { return nil }
            cg.type = .flagsChanged
            cg.flags = CGEventFlags(rawValue: UInt64(flags))
            return NSEvent(cgEvent: cg)
        }
    }
}

/// The key DSL's held modifiers (`{press:…}` / `{release:…}`), which the chord cases rely on.
@Suite("E2E key script: held modifiers")
struct E2EKeyScriptTests {
    @Test func aHeldRightCommandMakesAChord() {
        let keys = KeyScript.parse("{press:rcmd}c{release:rcmd}")
        #expect(keys.map(\.kind) == [.modifierPress, .key, .modifierRelease])
        #expect(keys[0].keyCode == KeyScript.VK.rightCommand)
        #expect(keys[0].modifiers == KeyScript.commandFlag)
        #expect(keys[1].keyCode == KeyScript.ansiKeyCodes["c"])
        #expect(keys[1].modifiers == KeyScript.commandFlag)
        #expect(keys[1].characters == "c")
        #expect(keys[2].modifiers == 0)
        #expect(KeyScript.flagsMasks(for: keys[0]) == [KeyScript.commandFlag | KeyScript.DeviceBit.rightCommand])
        #expect(KeyScript.flagsMasks(for: keys[2]) == [0])
    }

    @Test func heldModifiersJoinTokensAndChordsButNotAfterTheRelease() {
        let keys = KeyScript.parse("{press:lopt}{bs}{cmd+a}{release:lopt}{bs}a")
        #expect(keys.map(\.kind) == [.modifierPress, .key, .key, .modifierRelease, .key, .key])
        #expect(keys[1].modifiers == KeyScript.optionFlag)
        #expect(keys[2].modifiers == KeyScript.optionFlag | KeyScript.commandFlag)
        #expect(keys[4].modifiers == 0)
        #expect(keys[5].modifiers == 0)
    }

    @Test func aTapWhileAnotherModifierIsHeldKeepsItHeld() {
        let keys = KeyScript.parse("{press:rcmd}{lshift}{release:rcmd}")
        #expect(keys.map(\.kind) == [.modifierPress, .modifierPress, .modifierRelease, .modifierRelease])
        #expect(KeyScript.flagsMasks(for: keys[1]) == [KeyScript.commandFlag | KeyScript.shiftFlag | KeyScript.DeviceBit.leftShift])
        #expect(KeyScript.flagsMasks(for: keys[2]) == [KeyScript.commandFlag], "⇧ up, ⌘ still down")
        #expect(KeyScript.flagsMasks(for: keys[3]) == [0])
    }

    @Test func plainTapsAreUnchanged() {
        let keys = KeyScript.parse("{rcmd}")
        #expect(keys.map(\.kind) == [.modifierTap])
        #expect(KeyScript.flagsMasks(for: keys[0]) == [KeyScript.commandFlag | KeyScript.DeviceBit.rightCommand, 0])
        #expect(KeyScript.parse("{press:caps}").isEmpty, "Caps Lock is a toggle, not held")
    }
}
