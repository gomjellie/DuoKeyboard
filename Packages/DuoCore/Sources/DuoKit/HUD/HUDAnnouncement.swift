import DuoCore

/// What VoiceOver says when a flip-key press gives feedback instead of flipping a word.
///
/// The HUD is hidden from accessibility (ux-spec §7.5), and only successful flips are announced
/// (`EngineNotification.flipped`). Without this, a VoiceOver user hears nothing when the flip key is
/// refused, arms the next word's language, or toggles Bilingual for a Direct-profile line: feedback
/// ux-spec §7.3 shows on screen precisely because the user asked for something. The input method maps
/// each case to a localized phrase; this type only decides *which* one, from the engine's HUD request
/// before and after the press, so the rules are unit-tested.
public enum HUDAnnouncement: Hashable, Sendable {
    /// The flip was refused ("여기서는 바꿀 수 없어요").
    case cannotChange
    /// The next word will be typed in this language.
    case oneShot(ScriptLanguage)
    /// A second press cancelled the next word's language.
    case oneShotCancelled
    /// Bilingual turned on for this line of a Direct-profile app.
    case bilingualLineOn
    /// Bilingual turned off again: back to direct input.
    case bilingualLineOff

    /// How the flip key reached the engine.
    public enum Press: Sendable, Hashable {
        /// A `flagsChanged` of the flip key. The engine keeps its HUD request unless the press
        /// changed it, so an unchanged request means the press did nothing new (a hold, not a tap).
        case modifier
        /// A ⇧Space key-down. The engine clears its HUD request first, so even an unchanged request
        /// is a fresh answer (a second refused flip is refused again).
        case keyDown
    }

    /// The announcement for one flip-key press, or `nil` when there is nothing to say. Call it only
    /// when the press did not flip a word (that is announced with the word instead).
    ///
    /// - Parameters:
    ///   - press: how the flip key arrived.
    ///   - before: `CompositionEngine.hud` before the event.
    ///   - after: `CompositionEngine.hud` after it.
    public static func feedback(for press: Press, before: HUDRequest?, after: HUDRequest?) -> HUDAnnouncement? {
        if press == .modifier, before == after { return nil }
        switch (before?.content, after?.content) {
        case (_, .cannotChange?):
            return .cannotChange
        case (_, .oneShot(let language)?):
            return .oneShot(language)
        case (.oneShot?, nil):
            return .oneShotCancelled
        case (.bilingualLine?, .bilingualLine?):
            // Still on: the engine re-shows the badge after every key of the line.
            return nil
        case (_, .bilingualLine?):
            return .bilingualLineOn
        case (.bilingualLine?, nil):
            return .bilingualLineOff
        default:
            return nil
        }
    }

    /// Whether a `flagsChanged` with this key code can be a press of `flipKey`. Other modifiers are
    /// never announced: Caps Lock and fn may commit a word, which changes the HUD without any flip.
    public static func isFlipKey(modifierKeyCode keyCode: UInt16, flipKey: FlipKey) -> Bool {
        switch flipKey {
        case .rightCommand: keyCode == FlipTapDetector.KeyCode.rightCommand
        case .rightOption: keyCode == FlipTapDetector.KeyCode.rightOption
        case .doubleShift: keyCode == FlipTapDetector.KeyCode.leftShift || keyCode == FlipTapDetector.KeyCode.rightShift
        case .capsLock: keyCode == FlipTapDetector.KeyCode.capsLock
        case .shiftSpace: false
        }
    }

    /// Whether a key-down is the ⇧Space flip (the engine's rule: Space with exactly ⇧ held). An
    /// autorepeat is not a new press.
    public static func isFlipKey(_ key: KeyEvent, flipKey: FlipKey) -> Bool {
        flipKey == .shiftSpace && key.key == .space && !key.isRepeat
            && key.modifiers.intersection([.shift, .control, .option, .command]) == .shift
    }
}
