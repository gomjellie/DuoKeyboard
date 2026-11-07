import AppKit
import DuoCore
import DuoKit
import Observation

/// The "써보기" field's state (critique P2 "Playground double processing").
///
/// - `.engine`: Duo is *not* the selected input source. Key events from a view whose `inputContext`
///   is `nil` go through `KeyEventMapper` into a `PlaygroundSession` (an in-process
///   `CompositionEngine` backed by a `BufferTextClient`); the view draws the text and the marked
///   range itself.
/// - `.native`: Duo *is* selected, so a plain `NSTextView` lets the real IME do the work; this model
///   only mirrors its text and listens for `DuoIDs.Notifications.flipped`.
///
/// The field switches between the two live; ``willLeaveEngine()`` and ``didEnterEngine()`` carry
/// the text across, so nothing typed in one mode is lost in the other.
@MainActor
@Observable
final class PlaygroundModel {
    enum Availability: Equatable {
        case loading
        case ready
        /// The model could not be loaded from the embedded input method.
        case unavailable
    }

    /// One flip the user made, for the practice tasks.
    typealias Flip = PlaygroundFlip
    typealias PassThrough = PlaygroundSession.PassThrough

    private(set) var availability: Availability = .loading
    /// Whole text, marked text included.
    private(set) var text = ""
    private(set) var markedRange: NSRange?
    private(set) var selection = NSRange(location: 0, length: 0)
    /// What the engine wants its HUD to show; the field draws a small chip for it.
    private(set) var hud: HUDRequest?
    private(set) var lastFlip: Flip?
    /// The field has keyboard focus (onboarding turns off ⏎ = 계속 while typing).
    var hasFocus = false

    /// Text without the marked part: what the practice tasks check.
    var committedText: String {
        guard let markedRange else { return text }
        return (text as NSString).replacingCharacters(in: markedRange, with: "")
    }

    @ObservationIgnored private let languageModel: LanguageModelProvider
    @ObservationIgnored private var session: PlaygroundSession?
    @ObservationIgnored private var flipSerial = 0
    @ObservationIgnored private var hudExpiry: Task<Void, Never>?
    @ObservationIgnored private var pointerOverHUD = false
    /// When an eligible numbered bar came up (`systemUptime`, the clock of `NSEvent.timestamp`).
    @ObservationIgnored private var numberedSince: TimeInterval?
    @ObservationIgnored private var flipObserver: (any NSObjectProtocol)?
    @ObservationIgnored private weak var nativeTextView: NSTextView?
    /// Called after every change the canvas view has to draw.
    @ObservationIgnored var onDisplayChange: (() -> Void)?

    init(languageModel: LanguageModelProvider) {
        self.languageModel = languageModel
    }

    /// Loads the detector and the user's learned words, then builds the engine.
    func prepare(settings: DuoSettings) async {
        guard session == nil else { return }
        let snapshot = await Task.detached(priority: .userInitiated) { LearningFile.load() }.value
        guard let detector = await languageModel.detector() else {
            availability = .unavailable
            return
        }
        let session = PlaygroundSession(detector: detector, learning: snapshot, settings: settings)
        // Anything typed natively while the model loaded carries over.
        if !text.isEmpty { session.resume(text: text) }
        self.session = session
        availability = .ready
    }

    func apply(settings: DuoSettings) {
        session?.settings = settings
    }

    // MARK: Engine mode

    /// A key-down in the canvas. Returns what the view should do with keys the engine passed on.
    func handleKeyDown(_ event: NSEvent) -> PassThrough {
        guard let session, let key = KeyEventMapper.keyEvent(from: event) else { return .unhandled }
        // A digit while the chip lists numbered readings chooses one, as in the IME: only a bar
        // that earned the HUD and has been up for the IME's typing pause.
        if let index = HUDPresentation.readingIndex(for: key), let shown = hud,
           case .alternative(_, eligible: true) = shown.content,
           let since = numberedSince, event.timestamp - since >= HUDTimeline.Timing.standard.appearDelay,
           session.selectReading(at: index, on: shown) != .notOnBar {
            sync()
            return .handled
        }
        let result = session.handle(key, characters: event.characters)
        sync()
        return result
    }

    /// A flagsChanged in the canvas (the engine's own flip-key detector runs on these).
    func handleFlagsChanged(_ event: NSEvent) {
        guard let session, let modifier = KeyEventMapper.modifierEvent(from: event) else { return }
        session.handleModifier(modifier)
        sync()
    }

    /// A ⌘/⌃ key-down a menu is about to handle (⌘C, ⌘A): show it to the engine first, as the IME
    /// would see it, so a held flip key counts as a chord and not as a tap.
    func noteShortcut(_ event: NSEvent) {
        guard let session, let key = KeyEventMapper.keyEvent(from: event) else { return }
        session.noteShortcut(key)
        sync()
    }

    /// The reading at `index` on the playground's choice bar for `shown` was clicked.
    func chooseReading(at index: Int, on shown: HUDRequest) {
        guard let session else { return }
        session.selectReading(at: index, on: shown)
        sync()
    }

    /// The pointer entered or left the playground's chip: like the IME's HUD, the choice bar's
    /// lifetime is held while the pointer is on it, and it hides 0.8 s after the pointer leaves.
    func setPointerOverHUD(_ inside: Bool) {
        guard inside != pointerOverHUD else { return }
        pointerOverHUD = inside
        guard hud?.lifetime != nil else { return }
        hudExpiry?.cancel()
        hudExpiry = nil
        if !inside { expireHUD(after: Self.pointerExitGrace) }
    }

    /// Commits the word being typed (click, focus loss).
    func commit(_ reason: CommitReason) {
        guard let session, session.isComposing else { return }
        session.commit(reason)
        sync()
    }

    /// Feeds ABC-layout text as key events (snapshot fixtures and the welcome demo).
    func type(_ string: String) {
        guard let session else { return }
        session.type(string)
        sync()
    }

    func selectAll() {
        guard let session else { return }
        session.selectAll()
        sync()
    }

    func clear() {
        session?.clear()
        hud = nil
        lastFlip = nil
        if session != nil {
            sync()
        } else {
            text = ""
            markedRange = nil
            selection = NSRange(location: 0, length: 0)
        }
        nativeTextView?.string = ""
    }

    // MARK: Switching modes

    /// Duo became the selected input source: commit the word being typed so ``text`` holds
    /// everything the native view starts from (it may already show the uncommitted text).
    func willLeaveEngine() {
        // The canvas is going away without resigning first responder; the text view reports its own focus.
        hasFocus = false
        guard let session else { return }
        session.suspend()
        sync()
        setHUD(nil)
        if let textView = nativeTextView, !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            nativeTextDidChange(textView)
        }
    }

    /// Duo stopped being the selected input source: the engine continues from what the native view
    /// showed, caret at the end.
    func didEnterEngine() {
        hasFocus = false
        guard let session else { return }
        session.resume(text: text)
        sync()
    }

    private func sync() {
        guard let session else { return }
        text = session.text
        markedRange = session.markedRange
        selection = session.selection
        setHUD(session.hud)
        if let flip = session.takeFlip() {
            recordFlip(to: flip.language, whileComposing: flip.whileComposing, word: flip.word)
        }
        onDisplayChange?()
    }

    private func setHUD(_ request: HUDRequest?) {
        guard request != hud else { return }
        // Digits choose only once an eligible bar has been up for a while (as the IME's pause).
        if case .alternative(_, eligible: true)? = request?.content {
            if numberedSince == nil { numberedSince = ProcessInfo.processInfo.systemUptime }
        } else {
            numberedSince = nil
        }
        hud = request
        hudExpiry?.cancel()
        hudExpiry = nil
        // A chip that went away may never report the pointer leaving.
        if request == nil { pointerOverHUD = false }
        guard let lifetime = request?.lifetime, !pointerOverHUD else { return }
        expireHUD(after: lifetime)
    }

    private func expireHUD(after delay: TimeInterval) {
        hudExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.hud = nil
            self?.pointerOverHUD = false
        }
    }

    /// `HUDTimeline.Timing.pointerExitGrace`.
    private static let pointerExitGrace: TimeInterval = 0.8

    private func recordFlip(to language: ScriptLanguage, whileComposing: Bool, word: String = "") {
        flipSerial += 1
        lastFlip = Flip(serial: flipSerial, language: language, whileComposing: whileComposing, word: word)
    }

    // MARK: Native mode (Duo is the selected input source)

    /// Connects the `NSTextView` the real IME types into, after seeding it with ``text``.
    func attachNative(_ textView: NSTextView) {
        nativeTextView = textView
        // Mirror the seeded view once the current view update is over (no state changes inside it).
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, self.nativeTextView === textView else { return }
            self.nativeTextDidChange(textView)
        }
        guard flipObserver == nil else { return }
        flipObserver = DistributedNotificationCenter.default().addObserver(
            forName: DuoIDs.Notifications.flipped, object: nil, queue: .main
        ) { [weak self] note in
            let to = note.userInfo?["to"] as? String
            MainActor.assumeIsolated {
                guard let self, self.nativeTextView?.window?.isKeyWindow == true else { return }
                self.recordFlip(to: to == ScriptLanguage.english.rawValue ? .english : .korean,
                                whileComposing: self.nativeTextView?.hasMarkedText() ?? false)
            }
        }
    }

    /// Mirrors the native field after every edit.
    func nativeTextDidChange(_ textView: NSTextView) {
        text = textView.string
        markedRange = textView.hasMarkedText() ? textView.markedRange() : nil
        selection = textView.selectedRange()
    }

    // MARK: Snapshot fixtures

    #if DEBUG
    /// Shows a HUD chip without the engine producing one (offscreen renders of the placeholder engine).
    func showFixtureHUD(_ request: HUDRequest) { hud = request }

    /// Puts committed and marked text straight into the buffer (offscreen renders).
    func showFixture(committed: String, marked: String) {
        guard let buffer = session?.buffer else { return }
        buffer.insertText(committed, replacementRange: nil)
        if !marked.isEmpty { buffer.setMarkedText(marked, replacementRange: nil) }
        sync()
    }
    #endif
}
