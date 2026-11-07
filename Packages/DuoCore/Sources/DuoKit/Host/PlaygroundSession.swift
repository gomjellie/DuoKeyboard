import DuoCore
import Foundation

/// A flip the user made in a playground, for the practice tasks.
public struct PlaygroundFlip: Equatable, Sendable {
    /// Increases with every flip, so two equal flips in a row still read as a change.
    public var serial: Int
    /// The language the word was flipped to.
    public var language: ScriptLanguage
    /// `true` if the word being typed was flipped, `false` if the word just committed was.
    public var whileComposing: Bool
    /// The word as it reads after the flip (spoken by VoiceOver); empty when unknown.
    public var word: String

    /// A flip record.
    public init(serial: Int, language: ScriptLanguage, whileComposing: Bool, word: String = "") {
        self.serial = serial
        self.language = language
        self.whileComposing = whileComposing
        self.word = word
    }
}

/// Which practice tasks of onboarding 써보기 are done (ux-spec §8.1 #6). Tasks stay done once
/// achieved, even if the text is cleared.
public struct PracticeProgress: Equatable, Sendable {
    /// ‘안녕하세요 Duo를 써봐요’.
    public var greeting: Bool
    /// ‘macOS 26 업데이트’.
    public var numbers: Bool
    /// Flipped the word being typed.
    public var flippedWhileTyping: Bool
    /// Flipped the word just committed.
    public var flippedLastWord: Bool

    /// Progress with the given tasks done.
    public init(greeting: Bool = false, numbers: Bool = false, flippedWhileTyping: Bool = false,
                flippedLastWord: Bool = false) {
        self.greeting = greeting
        self.numbers = numbers
        self.flippedWhileTyping = flippedWhileTyping
        self.flippedLastWord = flippedLastWord
    }

    /// Checks the typing tasks against the committed text.
    public mutating func note(text: String) {
        if text.contains("안녕하세요") && text.contains("Duo") { greeting = true }
        if text.contains("macOS 26") && text.contains("업데이트") { numbers = true }
    }

    /// Checks the flip tasks. Any flip of the word being typed counts, whichever way it goes: in a
    /// Korean sentence `go` already reads 해 while it is typed (DET, critique R8), and the user's
    /// own learning can change that, so the task asks for the flip, not for one result.
    public mutating func note(flip: PlaygroundFlip) {
        if flip.whileComposing { flippedWhileTyping = true } else { flippedLastWord = true }
    }
}

/// The playground's in-process engine, used while Duo is not the selected input source (critique
/// P2): a `CompositionEngine` typing into a `BufferTextClient`, fed the canvas's key events.
@MainActor
public final class PlaygroundSession {
    /// What the canvas does with a key the engine did not consume.
    public enum PassThrough: Equatable, Sendable {
        case handled
        /// Tab: move keyboard focus instead of typing a tab.
        case focusNext
        case focusPrevious
        /// Let the responder chain have it (beep, menu shortcut).
        case unhandled
    }

    /// The document the engine types into.
    public let buffer: BufferTextClient
    private let engine: CompositionEngine
    private var pendingFlip: ScriptLanguage?

    /// A session over `detector` with the user's learned words.
    public init(detector: any LanguageDetector, learning: LearningSnapshot, settings: DuoSettings,
                bundleIdentifier: String = "com.inkyuoh.Duo.Playground") {
        let buffer = BufferTextClient(bundleIdentifier: bundleIdentifier)
        self.buffer = buffer
        engine = CompositionEngine(detector: detector, learning: LearningStore(snapshot: learning),
                                   settings: settings, bundleIdentifier: bundleIdentifier)
        engine.onNotification = { [weak self] notification in
            if case .flipped(let language) = notification { self?.pendingFlip = language }
        }
    }

    /// The engine's settings (flip key, profile bias, …).
    public var settings: DuoSettings {
        get { engine.settings }
        set { engine.settings = newValue }
    }

    /// Whole text, marked text included.
    public var text: String { buffer.text }
    /// The marked (composing) range.
    public var markedRange: NSRange? { buffer.markedRange() }
    /// Caret or selection.
    public var selection: NSRange { buffer.selection }
    /// Text without the marked part.
    public var committedText: String { buffer.committedText }
    /// What the engine wants its HUD to show.
    public var hud: HUDRequest? { engine.hud }
    /// A word is being composed.
    public var isComposing: Bool { engine.isComposing }

    // MARK: Events

    /// A key-down in the canvas. `characters` is `NSEvent.characters` (for ⌥ letters).
    public func handle(_ key: KeyEvent, characters: String?) -> PassThrough {
        guard !engine.handle(key, client: buffer) else { return .handled }
        return applyPassedKey(key, characters: characters)
    }

    /// A flagsChanged (the engine's flip-key tap detector runs on these).
    public func handleModifier(_ event: ModifierEvent) {
        engine.handleModifier(event, client: buffer)
    }

    /// The other reading on the playground's choice bar for `shown` was clicked. Returns whether a
    /// word changed.
    @discardableResult
    public func chooseOtherReading(on shown: HUDRequest) -> Bool {
        engine.chooseOtherReading(on: shown, client: buffer)
    }

    /// A reading on the playground's bar for `shown` was chosen (digit key or click).
    @discardableResult
    public func selectReading(at index: Int, on shown: HUDRequest) -> ReadingChoice {
        engine.selectReading(at: index, on: shown, client: buffer)
    }

    /// A ⌘ or ⌃ key-down about to be taken by a menu (⌘C, ⌘A), which then never reaches the canvas's
    /// `keyDown`. The engine sees it as the IME would: the word is committed and a held flip key
    /// becomes a chord instead of a tap. Seeing the same key again in `keyDown` is harmless.
    public func noteShortcut(_ key: KeyEvent) {
        guard !key.modifiers.isDisjoint(with: [.command, .control]) else { return }
        _ = engine.handle(key, client: buffer)
    }

    /// Commits the word being typed (click, focus loss).
    public func commit(_ reason: CommitReason) {
        guard engine.isComposing else { return }
        engine.commit(reason, client: buffer)
    }

    /// Feeds ABC-layout text as key events (snapshot fixtures, the welcome demo, tests).
    public func type(_ string: String) {
        for key in KeyEvent.typing(string) where !engine.handle(key, client: buffer) {
            buffer.applyPassedKey(key)
        }
    }

    /// ⌘A: commit, then select everything.
    public func selectAll() {
        commit(.commitComposition)
        buffer.selection = NSRange(location: 0, length: buffer.length)
    }

    /// Empties the field and forgets the engine's state.
    public func clear() {
        engine.reset()
        buffer.setText("")
    }

    // MARK: Switching between engine and native mode

    /// Duo became the selected input source and a native text view takes over: commit the word
    /// being typed, so ``text`` holds everything for the native view to start from.
    public func suspend() {
        commit(.deactivate)
    }

    /// Back from native mode: start from what the native view held, caret at the end, and a fresh
    /// engine (its context and last commit describe text that may have changed).
    public func resume(text: String) {
        engine.reset()
        buffer.setText(text)
    }

    /// The flip the last event made, if any; each flip is returned once.
    public func takeFlip() -> (language: ScriptLanguage, whileComposing: Bool, word: String)? {
        guard let language = pendingFlip else { return nil }
        pendingFlip = nil
        let composing = engine.isComposing
        return (language, composing, composing ? buffer.markedText ?? "" : lastCommittedWord())
    }

    // MARK: Private

    private func applyPassedKey(_ key: KeyEvent, characters: String?) -> PassThrough {
        if !key.modifiers.isDisjoint(with: [.command, .control]) { return .unhandled }
        switch key.key {
        case .tab:
            return key.modifiers.contains(.shift) ? .focusPrevious : .focusNext
        case .escape, .other, .function, .navigation, .forwardDelete, .arrowUp, .arrowDown:
            return .handled
        case .letter(let stroke):
            if key.modifiers.contains(.option), let characters, !characters.isEmpty {
                buffer.insertText(characters, replacementRange: nil)
            } else {
                let letter = String(stroke.latin)
                buffer.insertText(key.modifiers.contains(.capsLock) ? letter.uppercased() : letter, replacementRange: nil)
            }
            return .handled
        default:
            buffer.applyPassedKey(key)
            return .handled
        }
    }

    /// The word before the caret, ignoring the boundary typed after it.
    private func lastCommittedWord() -> String {
        let ns = buffer.text as NSString
        let end = min(max(0, buffer.selection.location), ns.length)
        let before = ns.substring(to: end).trimmingCharacters(in: .whitespacesAndNewlines)
        return before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }
}
