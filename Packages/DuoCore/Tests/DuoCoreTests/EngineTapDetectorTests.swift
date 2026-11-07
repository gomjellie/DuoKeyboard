import Foundation
import Testing
@testable import DuoCore

/// SPEC.md §4.9 / critique R3: the flip-key tap detector is a pure state machine.
@Suite("Engine · flip tap detector")
struct EngineTapDetectorTests {
    typealias F = FlipTapDetector.Flags
    typealias K = FlipTapDetector.KeyCode

    static let rcmdDown = F.command | F.rightCommandDevice
    static let lcmdDown = F.command | F.leftCommandDevice

    /// Right-⌘ press at 10.0 and release after `ms` milliseconds.
    static func rightCommandTap(ms: Double, detector: inout FlipTapDetector, mouse: Int = 0, flags: UInt = rcmdDown) -> Bool {
        let down = detector.handle(ModifierEvent(keyCode: K.rightCommand, flags: flags, timestamp: 10))
        let up = detector.handle(ModifierEvent(keyCode: K.rightCommand, flags: 0, timestamp: 10 + ms / 1000,
                                               pressedMouseButtons: mouse))
        return !down && up
    }

    @Test(arguments: [(50.0, true), (299.0, true), (300.0, true), (301.0, false), (800.0, false)])
    func rightCommandTapWindowEdges(_ ms: Double, _ fires: Bool) {
        var d = FlipTapDetector(flipKey: .rightCommand, tapWindowMs: 300)
        let fired1 = Self.rightCommandTap(ms: ms, detector: &d)
        #expect(fired1 == fires)
        #expect(!d.isArmed)
    }

    @Test(arguments: [(199.0, true), (201.0, false)])
    func configurableWindow(_ ms: Double, _ fires: Bool) {
        var d = FlipTapDetector(flipKey: .rightCommand, tapWindowMs: 200)
        let fired2 = Self.rightCommandTap(ms: ms, detector: &d)
        #expect(fired2 == fires)
    }

    @Test func injectedEventsWithoutDeviceBitsStillFire() {
        // Critique V3: synthesised flagsChanged may carry 0x100000 with no 0x10.
        var d = FlipTapDetector(flipKey: .rightCommand)
        let fired3 = Self.rightCommandTap(ms: 80, detector: &d, flags: F.command)
        #expect(fired3)
    }

    @Test func commandClickIsNotATap() {
        var d = FlipTapDetector(flipKey: .rightCommand)
        let fired4 = Self.rightCommandTap(ms: 80, detector: &d, mouse: 1)
        #expect(!fired4, "mouse button down at release")
        var e = FlipTapDetector(flipKey: .rightCommand)
        _ = e.handle(ModifierEvent(keyCode: K.rightCommand, flags: Self.rcmdDown, timestamp: 10))
        e.noteMouseDown()
        let fired5 = e.handle(ModifierEvent(keyCode: K.rightCommand, flags: 0, timestamp: 10.08))
        #expect(!fired5)
        var f = FlipTapDetector(flipKey: .rightCommand)
        _ = f.handle(ModifierEvent(keyCode: K.rightCommand, flags: Self.rcmdDown, timestamp: 10, pressedMouseButtons: 1))
        let fired6 = f.handle(ModifierEvent(keyCode: K.rightCommand, flags: 0, timestamp: 10.08))
        #expect(!fired6)
    }

    @Test func commandCIsNotATap() {
        var d = FlipTapDetector(flipKey: .rightCommand)
        _ = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: Self.rcmdDown, timestamp: 10))
        d.noteKeyDown()   // ⌘C
        let fired7 = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: 0, timestamp: 10.1))
        #expect(!fired7)
    }

    @Test func leftAndRightCommandTogetherIsNotATap() {
        // Left ⌘ held first: the right ⌘ press carries 0x08.
        var d = FlipTapDetector(flipKey: .rightCommand)
        _ = d.handle(ModifierEvent(keyCode: K.leftCommand, flags: Self.lcmdDown, timestamp: 9.9))
        _ = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: Self.lcmdDown | F.rightCommandDevice, timestamp: 10))
        let fired8 = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: Self.lcmdDown, timestamp: 10.05))
        #expect(!fired8)
        // Left ⌘ joins during the right-⌘ hold.
        var e = FlipTapDetector(flipKey: .rightCommand)
        _ = e.handle(ModifierEvent(keyCode: K.rightCommand, flags: Self.rcmdDown, timestamp: 10))
        _ = e.handle(ModifierEvent(keyCode: K.leftCommand, flags: Self.rcmdDown | F.leftCommandDevice, timestamp: 10.02))
        _ = e.handle(ModifierEvent(keyCode: K.leftCommand, flags: Self.rcmdDown, timestamp: 10.04))
        let fired9 = e.handle(ModifierEvent(keyCode: K.rightCommand, flags: 0, timestamp: 10.06))
        #expect(!fired9)
    }

    @Test func leftCommandAloneNeverFires() {
        var d = FlipTapDetector(flipKey: .rightCommand)
        _ = d.handle(ModifierEvent(keyCode: K.leftCommand, flags: Self.lcmdDown, timestamp: 10))
        let fired10 = d.handle(ModifierEvent(keyCode: K.leftCommand, flags: 0, timestamp: 10.05))
        #expect(!fired10)
    }

    @Test func otherHeldModifierPreventsArming() {
        var d = FlipTapDetector(flipKey: .rightCommand)
        _ = d.handle(ModifierEvent(keyCode: K.leftShift, flags: F.shift | 0x02, timestamp: 9.9))
        _ = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: F.shift | 0x02 | Self.rcmdDown, timestamp: 10))
        let fired11 = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: F.shift | 0x02, timestamp: 10.05))
        #expect(!fired11)
    }

    @Test func capsLockStateDoesNotBlockTheTap() {
        var d = FlipTapDetector(flipKey: .rightCommand)
        _ = d.handle(ModifierEvent(keyCode: K.capsLock, flags: F.capsLock, timestamp: 9))
        _ = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: F.capsLock | Self.rcmdDown, timestamp: 10))
        let fired12 = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: F.capsLock, timestamp: 10.05))
        #expect(fired12)
    }

    @Test func keyCodeZeroIsIgnored() {
        // Remote-desktop tools send flagsChanged with key code 0; they must not disturb a tap.
        var d = FlipTapDetector(flipKey: .rightCommand)
        _ = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: Self.rcmdDown, timestamp: 10))
        let fired13 = d.handle(ModifierEvent(keyCode: 0, flags: 0, timestamp: 10.02))
        #expect(!fired13)
        let fired14 = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: 0, timestamp: 10.05))
        #expect(fired14)
    }

    @Test func rightOption() {
        var d = FlipTapDetector(flipKey: .rightOption)
        _ = d.handle(ModifierEvent(keyCode: K.rightOption, flags: F.option | F.rightOptionDevice, timestamp: 10))
        let fired15 = d.handle(ModifierEvent(keyCode: K.rightOption, flags: 0, timestamp: 10.1))
        #expect(fired15)
        let fired16 = Self.rightCommandTap(ms: 50, detector: &d)
        #expect(!fired16, "right ⌘ does nothing when ⌥ is the flip key")
    }

    @Test(arguments: [(0.1, 0.2, 0.3, true), (0.1, 0.45, 0.5, false), (0.1, 0.2, 0.55, false)])
    func doubleShift(_ release1: Double, _ press2: Double, _ release2: Double, _ fires: Bool) {
        var d = FlipTapDetector(flipKey: .doubleShift)
        let lshift = F.shift | 0x02
        _ = d.handle(ModifierEvent(keyCode: K.leftShift, flags: lshift, timestamp: 10))
        let fired17 = d.handle(ModifierEvent(keyCode: K.leftShift, flags: 0, timestamp: 10 + release1))
        #expect(!fired17)
        _ = d.handle(ModifierEvent(keyCode: K.rightShift, flags: F.shift | 0x04, timestamp: 10 + press2))
        let fired18 = d.handle(ModifierEvent(keyCode: K.rightShift, flags: 0, timestamp: 10 + release2))
        #expect(fired18 == fires)
    }

    @Test func doubleShiftWithATypedCapitalBetweenIsNotAFlip() {
        var d = FlipTapDetector(flipKey: .doubleShift)
        let lshift = F.shift | 0x02
        _ = d.handle(ModifierEvent(keyCode: K.leftShift, flags: lshift, timestamp: 10))
        _ = d.handle(ModifierEvent(keyCode: K.leftShift, flags: 0, timestamp: 10.05))
        _ = d.handle(ModifierEvent(keyCode: K.leftShift, flags: lshift, timestamp: 10.1))
        d.noteKeyDown()   // ⇧A
        let fired19 = d.handle(ModifierEvent(keyCode: K.leftShift, flags: 0, timestamp: 10.15))
        #expect(!fired19)
    }

    @Test func capsLockFiresOnEveryToggle() {
        var d = FlipTapDetector(flipKey: .capsLock)
        let fired20 = d.handle(ModifierEvent(keyCode: K.capsLock, flags: F.capsLock, timestamp: 10))
        #expect(fired20)
        let fired21 = d.handle(ModifierEvent(keyCode: K.capsLock, flags: 0, timestamp: 12))
        #expect(fired21)
        let fired22 = d.handle(ModifierEvent(keyCode: K.leftShift, flags: F.shift, timestamp: 13))
        #expect(!fired22)
    }

    @Test func shiftSpaceIsNotAModifierTap() {
        var d = FlipTapDetector(flipKey: .shiftSpace)
        _ = d.handle(ModifierEvent(keyCode: K.leftShift, flags: F.shift, timestamp: 10))
        let fired23 = d.handle(ModifierEvent(keyCode: K.leftShift, flags: 0, timestamp: 10.05))
        #expect(!fired23)
    }

    @Test func changingTheKeyResets() {
        var d = FlipTapDetector(flipKey: .rightCommand)
        _ = d.handle(ModifierEvent(keyCode: K.rightCommand, flags: Self.rcmdDown, timestamp: 10))
        #expect(d.isArmed)
        d.flipKey = .rightOption
        #expect(!d.isArmed)
    }

    @MainActor
    @Test func engineFlipsOnTheTapAndSettingsReconfigureIt() {
        let h = EngineHarness()
        EngineFlipTests.scriptGo(h.detector)
        h.type("go")
        h.tap(hold: 0.35)
        #expect(h.marked == "해", "too slow: no flip")
        h.tap(hold: 0.1)
        #expect(h.marked == "go")
        var s = h.engine.settings
        s.flipKey = .rightOption
        h.engine.settings = s
        h.tap()
        #expect(h.marked == "go")
        h.tap(keyCode: K.rightOption, flag: F.option, device: F.rightOptionDevice)
        #expect(h.marked == "해")
    }
}
