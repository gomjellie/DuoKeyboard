import AppKit
import Carbon
import DuoCore
import DuoKit
import InputMethodKit

/// The IMK controller: one per client input session (critique R14). A thin adapter that routes IMK
/// callbacks into its own `CompositionEngine` and pushes the engine's HUD request to the shared HUD.
///
/// Concurrency (critique R14, V6, imk-platform D3): the class is `@MainActor`, every IMK override is
/// `nonisolated`, rebinds its non-Sendable IMK arguments with `nonisolated(unsafe)`, and hops with
/// `MainActor.assumeIsolated` (IMK calls controllers on the main thread). Marked text is always set
/// synchronously before `handle` returns (iTerm2 checks right after, imk-platform D5).
@MainActor
@objc(DuoInputController)
final class DuoInputController: IMKInputController {
    typealias Proxy = any IMKTextInput & NSObjectProtocol

    /// `nil` in pass-through mode (no model) or before the first activation.
    private(set) var engine: CompositionEngine?
    private var textClient: IMKTextClient?
    /// Cached `client.bundleIdentifier()`, fetched once per activation (critique R15).
    private(set) var bundleIdentifier = ""
    /// The client app's process, looked up once per activation, only for clients whose HUD
    /// follows their focused element (`ClientProfile.compositionAtFocusedElement`).
    private var focusedElementClientPID: pid_t?
    /// The last caret read from that client's focused element (Cocoa coordinates). Placements use
    /// it and then read again; a changed answer moves the visible HUD (`refreshPlacement`). `nil`
    /// when the focus is not xterm.js's field: the HUD uses IMK's rects then.
    private var focusedElementCaretRect: CGRect?
    /// A read started when the current word could begin has answered, so `focusedElementCaretRect`
    /// is not the previous word's (`hudPlacementIsPending`).
    private var focusedElementCaretIsCurrent = true
    private var focusedElementRead: FocusedElementRead = .idle
    /// Bumped on every activation: answers to reads started before it are dropped.
    private var focusedElementGeneration = 0
    private var settingsGeneration = -1
    private var wasSecure = false
    private var pendingFlipAnnouncement: ScriptLanguage?
    /// The client has passed a `flagsChanged` through IMK (Cocoa, Chromium); until then the global
    /// monitor stands in (``ModifierRouter``).
    var forwardsModifierEvents = false

    nonisolated override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    nonisolated override init() {
        super.init()
    }

    // MARK: IMK entry points

    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        // Taking .flagsChanged turns off IMK's own commit-on-click, so mouse-downs come to `handle` (R4).
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]).rawValue)
    }

    nonisolated override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        nonisolated(unsafe) let sender = sender
        onMain { $0.activate(sender) }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        nonisolated(unsafe) let sender = sender
        onMain { $0.deactivate(sender) }
        super.deactivateServer(sender)
    }

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        nonisolated(unsafe) let event = event
        nonisolated(unsafe) let sender = sender
        return onMain { $0.handleEvent(event, sender: sender) }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let sender = sender
        onMain { $0.commit(.commitComposition, sender: sender) }
    }

    nonisolated override func hidePalettes() {
        onMain { _ in DuoRuntime.shared.hud.forceHide() }
        super.hidePalettes()
    }

    nonisolated override func inputControllerWillClose() {
        onMain { $0.willClose() }
        super.inputControllerWillClose()
    }

    /// IMK calls controllers on the main thread; this documents and enforces it without crashing
    /// if a future IMK ever does not.
    nonisolated func onMain<T: Sendable>(_ work: @MainActor (DuoInputController) -> T) -> T {
        // `self` reaches a nonisolated override from IMK's ObjC side; rebind it like the IMK
        // arguments (critique V6) so region isolation accepts the hop.
        nonisolated(unsafe) let this = self
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work(this) }
        }
        Log.ime.fault("IMK called the controller off the main thread")
        return DispatchQueue.main.sync { MainActor.assumeIsolated { work(this) } }
    }

    // MARK: Lifecycle

    private func activate(_ sender: Any?) {
        let runtime = DuoRuntime.shared
        guard let proxy = (sender as? Proxy) ?? client() else {
            Log.ime.error("activateServer without a client")
            return
        }
        runtime.reloadSettings()
        let previousBundleIdentifier = bundleIdentifier
        bundleIdentifier = proxy.bundleIdentifier() ?? ""
        // A controller IMK reuses for another client must find out again whether it forwards modifiers.
        if bundleIdentifier != previousBundleIdentifier { forwardsModifierEvents = false }
        proxy.overrideKeyboard(withKeyboardNamed: runtime.keyboardLayoutID)

        let textClient = self.textClient ?? IMKTextClient(controller: self)
        self.textClient = textClient
        textClient.resetMarkedState()

        if let detector = runtime.detector {
            let engine = self.engine ?? makeEngine(detector: detector, learning: runtime.learning)
            self.engine = engine
            engine.setClient(bundleIdentifier: bundleIdentifier)
            syncSettings(engine)
            textClient.needsMarkBeforeInsert = engine.clientProfile.needsMarkBeforeInsert
        }
        focusedElementGeneration &+= 1
        focusedElementCaretRect = nil
        focusedElementCaretIsCurrent = true
        focusedElementRead = .idle
        focusedElementClientPID = nil
        if engine?.clientProfile.compositionAtFocusedElement == true {
            // The client is frontmost when it activates us; another instance with the same id is not.
            let front = NSWorkspace.shared.frontmostApplication
            focusedElementClientPID = front?.bundleIdentifier == bundleIdentifier
                ? front?.processIdentifier
                : NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier
            startFocusedElementRead()
        }

        if !bundleIdentifier.isEmpty, !bundleIdentifier.hasPrefix("com.inkyuoh.") {
            SettingsStore.recordSeenApp(bundleIdentifier)
        }
        runtime.activeController = self
        runtime.checkInputMenuListOnce()
        // The input method never goes online: Duo.app checks, at most once a day.
        if runtime.settings.autoUpdate { HostRequest.checkForUpdatesIfDue() }
        wasSecure = IsSecureEventInputEnabled()
        #if DEBUG
        // The end-to-end hook types only into DuoHarness's own text view (DebugInjector checks again
        // before every key).
        if bundleIdentifier == DuoIDs.harnessBundleID { DebugInjector.install() }
        #endif
        Log.ime.info("""
            activate \(self.bundleIdentifier, privacy: .public) \
            profile=\(self.engine?.clientProfile.effectiveProfile(runtime.settings).rawValue ?? "pass-through", privacy: .public) \
            secure=\(self.wasSecure, privacy: .public)
            """)
    }

    private func deactivate(_ sender: Any?) {
        commit(.deactivate, sender: sender)
        let runtime = DuoRuntime.shared
        if runtime.activeController === self { runtime.activeController = nil }
        Log.ime.info("deactivate \(self.bundleIdentifier, privacy: .public)")
    }

    private func willClose() {
        engine?.reset()
        textClient?.resetMarkedState()
        let runtime = DuoRuntime.shared
        if runtime.activeController === self {
            runtime.activeController = nil
            runtime.hud.forceHide()
        }
    }

    /// The selected input source changed away from Duo without a `deactivateServer` (R18 #6).
    func inputSourceDidChangeAway() {
        // From a TIS notification, not an IMK callback: the client's answers may be stale.
        commit(.deactivate, sender: client(), outsideCallback: true)
    }

    private func makeEngine(detector: DuoDetector, learning: LearningStore) -> CompositionEngine {
        let engine = CompositionEngine(detector: detector, learning: learning,
                                       settings: DuoRuntime.shared.settings, bundleIdentifier: bundleIdentifier)
        engine.onNotification = { [weak self] note in self?.engineDidNotify(note) }
        return engine
    }

    // MARK: Events

    private func handleEvent(_ event: NSEvent?, sender: Any?) -> Bool {
        guard let event, let proxy = sender as? Proxy else { return false }
        guard let engine, let textClient else { return false }   // pass-through mode
        let runtime = DuoRuntime.shared
        syncSettings(engine)
        textClient.bind(proxy, bundleIdentifier: bundleIdentifier)
        defer { textClient.unbind() }

        // R5: secure input first. Commit what is pending, then every key passes raw: no HUD, no learning.
        let secure = IsSecureEventInputEnabled()
        if secure != wasSecure {
            wasSecure = secure
            Log.ime.info("secure event input \(secure ? "on" : "off", privacy: .public)")
        }
        if secure {
            if engine.isComposing { engine.commit(.secureInput, client: textClient) }
            runtime.hud.forceHide()
            return false
        }

        let consumed: Bool
        let trigger: HUDTimeline.Trigger
        let hudBefore = engine.hud
        var flipPress: HUDAnnouncement.Press?
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // R4: IMK no longer commits on click for us. Commit, and let the click move the caret.
            engine.commit(.mouse, client: textClient)
            consumed = false
            trigger = .other
        case .flagsChanged:
            // Flip-key taps and Caps Lock. Never consumed: the app must see modifier state.
            runtime.modifierRouter.noteForwarded(by: self)
            routeModifier(event, engine: engine, client: textClient)
            if HUDAnnouncement.isFlipKey(modifierKeyCode: event.keyCode, flipKey: engine.settings.flipKey) {
                flipPress = .modifier
            }
            consumed = false
            trigger = .other
        case .keyDown:
            guard let key = KeyEventMapper.keyEvent(from: event) else { return false }
            // A word may start with this key: read where it will be drawn, before the HUD asks.
            if !engine.isComposing { startFocusedElementRead() }
            // ⌘3 with the flip key held chooses like a flip, so a refusal is spoken like one.
            if HUDAnnouncement.isFlipKey(key, flipKey: engine.settings.flipKey)
                || engine.readingChordIndex(key) != nil {
                flipPress = .keyDown
            }
            var choice = ReadingChoice.notOnBar
            if let index = HUDPresentation.readingIndex(for: key),
               let shown = runtime.hud.seenRequest,
               HUDPresentation(shown.content, flipKey: engine.settings.flipKey).isNumbered {
                // A digit while numbered readings are on screen chooses one (SPEC.md 4.11절);
                // a refused choice is not text either, and keeps its message.
                choice = engine.selectReading(at: index, on: shown, client: textClient)
                if choice == .refused, engine.hud?.content == .cannotChange {
                    Task { @MainActor in VoiceOverAnnouncer.announce(.cannotChange) }
                }
            }
            consumed = choice == .notOnBar ? engine.handle(key, client: textClient) : true
            trigger = .keystroke
            Log.ime.debug("""
                key \(event.keyCode, privacy: .private) repeat=\(event.isARepeat, privacy: .public) \
                consumed=\(consumed, privacy: .public)
                """)
        default:
            return false
        }

        runtime.hud.present(engine.hud, from: self, trigger: trigger)
        announce(flipPress, hudBefore: hudBefore, hudAfter: engine.hud)
        return consumed
    }

    /// One `flagsChanged`, from IMK or from ``ModifierRouter``'s monitor; copies are dropped.
    private func routeModifier(_ event: NSEvent, engine: CompositionEngine, client: IMKTextClient) {
        let router = DuoRuntime.shared.modifierRouter
        guard router.isNewChange(event), let modifier = KeyEventMapper.modifierEvent(from: event) else { return }
        if router.otherInputBefore(event) { engine.noteKeyActivity() }
        engine.handleModifier(modifier, client: client)
    }

    /// A `flagsChanged` from ``ModifierRouter``'s global monitor, for a session whose client has not
    /// forwarded any modifier event through IMK.
    func handleMonitoredModifier(_ event: NSEvent) {
        guard let engine, let textClient, let proxy = client() as Proxy? else { return }
        guard !IsSecureEventInputEnabled() else { return }
        syncSettings(engine)
        textClient.bind(proxy, bundleIdentifier: bundleIdentifier, outsideCallback: true)
        defer { textClient.unbind() }
        let hudBefore = engine.hud
        routeModifier(event, engine: engine, client: textClient)
        DuoRuntime.shared.hud.present(engine.hud, from: self, trigger: .other)
        let isFlipKey = HUDAnnouncement.isFlipKey(modifierKeyCode: event.keyCode, flipKey: engine.settings.flipKey)
        announce(isFlipKey ? .modifier : nil, hudBefore: hudBefore, hudAfter: engine.hud)
    }

    private func commit(_ reason: CommitReason, sender: Any?, outsideCallback: Bool = false) {
        defer { DuoRuntime.shared.hud.forceHide() }
        guard let engine, let textClient, let proxy = (sender as? Proxy) ?? client() else { return }
        textClient.bind(proxy, bundleIdentifier: bundleIdentifier, outsideCallback: outsideCallback)
        defer { textClient.unbind() }
        engine.commit(reason, client: textClient)
    }

    private func syncSettings(_ engine: CompositionEngine) {
        let runtime = DuoRuntime.shared
        guard settingsGeneration != runtime.settingsGeneration else { return }
        engine.settings = runtime.settings
        settingsGeneration = runtime.settingsGeneration
    }

    // MARK: Engine notifications

    private func engineDidNotify(_ note: EngineNotification) {
        switch note {
        case .flipped(let language):
            DuoRuntime.shared.hud.noteManualFlip()
            pendingFlipAnnouncement = language
            Log.ime.info("flipped to \(language.rawValue, privacy: .public)")
        case .committed:
            break
        case .learningChanged:
            DuoRuntime.shared.learningDidChange()
        }
    }

    /// After the engine call returns: a flip is announced with its word (``announcePendingFlip()``);
    /// any other flip-key press that changed the HUD's feedback (refused, the next word's language,
    /// Bilingual for the line) is spoken as that feedback, which VoiceOver cannot read off the hidden HUD.
    private func announce(_ flipPress: HUDAnnouncement.Press?, hudBefore: HUDRequest?, hudAfter: HUDRequest?) {
        if announcePendingFlip() { return }
        guard let flipPress,
              let feedback = HUDAnnouncement.feedback(for: flipPress, before: hudBefore, after: hudAfter) else { return }
        Task { @MainActor in VoiceOverAnnouncer.announce(feedback) }
    }

    /// After the engine call returns (so the flipped word has been sent to the client), tell the host
    /// app (onboarding challenge) and VoiceOver (ux-spec §7.5). Both run on the next turn so the key
    /// returns to the client first. Returns whether a flip was pending.
    @discardableResult
    private func announcePendingFlip() -> Bool {
        guard let language = pendingFlipAnnouncement else { return false }
        pendingFlipAnnouncement = nil
        let word = textClient?.lastSentText ?? ""
        Task { @MainActor in
            DistributedNotificationCenter.default().postNotificationName(
                DuoIDs.Notifications.flipped, object: nil, userInfo: ["to": language.rawValue],
                deliverImmediately: true)
            VoiceOverAnnouncer.announceFlip(word: word, to: language)
        }
        return true
    }

    // MARK: Client access for the menu

    /// Binds `proxy` to the engine's client for a one-off action (menu commands, which IMK does not
    /// send inside a `handle` callback, so the client's answers may be stale).
    func withEngineClient(_ proxy: Proxy, _ body: (CompositionEngine, IMKTextClient) -> Void) {
        guard let engine, let textClient else { return }
        textClient.bind(proxy, bundleIdentifier: bundleIdentifier, outsideCallback: true)
        defer { textClient.unbind() }
        body(engine, textClient)
    }
}

// MARK: - HUD geometry

extension DuoInputController: HUDAnchorProvider {
    func hudCaretRect(for anchor: HUDRequest.Anchor) -> CGRect? {
        guard let proxy = textClient?.proxy ?? client() else { return nil }
        switch anchor {
        case .markedText:
            if let rect = focusedElementCaret() { return rect }
            return lineRectAtSessionStart(proxy) ?? firstRect(proxy, of: proxy.markedRange())
        case .caret:
            if let rect = focusedElementCaret() { return rect }
            if let rect = lineRectAtSessionStart(proxy) { return rect }
            return firstRect(proxy, of: NSRange(location: proxy.selectedRange().location, length: 0))
        case .location(let location):
            // The word ends at the caret: its line is the caret's (TextEdit answers a line off
            // right after a commit), unless a Return put the caret on the next line.
            return HUDGeometry.wordRect(word: firstRect(proxy, of: NSRange(location: location, length: 1)),
                                        caretLine: lineRectAtSessionStart(proxy),
                                        caretFollowsNewline: caretFollowsNewline(proxy))
        }
    }

    func hudChooseReading(at index: Int, on shown: HUDRequest) {
        guard let engine, let textClient, let proxy = client() as Proxy? else { return }
        guard !IsSecureEventInputEnabled() else { return }
        syncSettings(engine)
        // A click reaches us outside any IMK callback: the client's answers may be stale.
        textClient.bind(proxy, bundleIdentifier: bundleIdentifier, outsideCallback: true)
        defer { textClient.unbind() }
        let changed = engine.selectReading(at: index, on: shown, client: textClient) == .chosen
        DuoRuntime.shared.hud.present(engine.hud, from: self, trigger: .other)
        if changed {
            announcePendingFlip()
        } else if engine.hud?.content == .cannotChange {
            Task { @MainActor in VoiceOverAnnouncer.announce(.cannotChange) }
        }
        Log.hud.info("choice bar click changed=\(changed, privacy: .public)")
    }

    func hudClientWindowLevel() -> Int {
        guard let proxy = textClient?.proxy ?? client() else { return Int(CGWindowLevelForKey(.normalWindow)) }
        return Int(proxy.windowLevel())
    }

    /// A focused-element client is being read for a word that may just have started, with the
    /// permission to read it: the HUD waits for the answer instead of showing the previous word's
    /// place (`CompositionHUDController`).
    var hudPlacementIsPending: Bool {
        focusedElementClientPID != nil && !focusedElementCaretIsCurrent && FocusedElementLocator.isTrusted
    }

    /// xterm.js terminals: the left edge of the hidden field xterm.js keeps at the composition, or
    /// at the cursor when nothing is marked (`FocusedElementLocator`), as last read. Every call
    /// reads it again in the background; `nil` until a read succeeds, without the Accessibility
    /// permission, when the focus is another field, or for any other client.
    private func focusedElementCaret() -> CGRect? {
        guard focusedElementClientPID != nil else { return nil }
        readFocusedElementCaret()
        return focusedElementCaretRect
    }

    /// The next word's place is unknown until a read answers (activation, a key with no word).
    private func startFocusedElementRead() {
        guard focusedElementClientPID != nil else { return }
        focusedElementCaretIsCurrent = false
        readFocusedElementCaret()
    }

    /// One read in flight at a time; a request made meanwhile reads again once it returns, so the
    /// last answer is never older than the last placement.
    private func readFocusedElementCaret() {
        guard let pid = focusedElementClientPID else { return }
        switch focusedElementRead {
        case .reading, .readingThenAgain:
            focusedElementRead = .readingThenAgain
            return
        case .idle:
            focusedElementRead = .reading
        }
        let generation = focusedElementGeneration
        FocusedElementLocator.read(pid: pid) { [weak self] answer in
            guard let self, self.focusedElementGeneration == generation else { return }
            // A request made while this read ran (a new word, a placement) gets a newer read; this
            // answer still applies, but only the last one says the word's place is known.
            let again = self.focusedElementRead == .readingThenAgain
            self.focusedElementRead = .idle
            let wasPending = !self.focusedElementCaretIsCurrent
            if !again { self.focusedElementCaretIsCurrent = true }
            var caret = self.focusedElementCaretRect
            switch answer {
            case .frame(let frame):
                caret = NSScreen.screens.first.flatMap {
                    HUDGeometry.caretFromAccessibilityFrame(frame, primaryScreenHeight: $0.frame.height)
                }.flatMap { self.usable($0) }
            case .notXtermField:
                caret = nil
            case .noAnswer:
                break
            }
            let moved = caret != self.focusedElementCaretRect
            self.focusedElementCaretRect = caret
            if moved || (wasPending && !again) { DuoRuntime.shared.hud.refreshPlacement(from: self) }
            if again { self.readFocusedElementCaret() }
        }
    }

    /// `attributes(forCharacterIndex: 0, lineHeightRectangle:)`: the start of the marked text, or
    /// the caret when nothing is marked (imk-platform §4.5).
    private func lineRectAtSessionStart(_ proxy: Proxy) -> CGRect? {
        var rect = NSRect.zero
        _ = proxy.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return usable(rect)
    }

    /// `firstRect(forCharacterRange:)` for a valid document range (fallback for clients whose
    /// `attributes(forCharacterIndex:)` returns nothing).
    private func firstRect(_ proxy: Proxy, of range: NSRange) -> CGRect? {
        guard range.location != NSNotFound, range.location >= 0 else { return nil }
        return usable(proxy.firstRect(forCharacterRange: range, actualRange: nil))
    }

    /// The character before the caret is a line break (a Return just committed the word).
    private func caretFollowsNewline(_ proxy: Proxy) -> Bool {
        let caret = proxy.selectedRange().location
        guard caret != NSNotFound, caret > 0,
              let before = proxy.attributedSubstring(from: NSRange(location: caret - 1, length: 1))?.string else {
            return false
        }
        return before.rangeOfCharacter(from: .newlines) != nil
    }

    /// A caret rect the HUD may follow (`HUDGeometry.followable`): sane, not a "no caret" answer,
    /// and inside one of the client's windows.
    private func usable(_ rect: NSRect) -> CGRect? {
        let windows = ClientWindows.frames(ofApp: bundleIdentifier)
        let screens = NSScreen.screens.map {
            HUDScreen(frame: $0.frame, visibleFrame: $0.visibleFrame, scale: $0.backingScaleFactor)
        }
        guard let followed = HUDGeometry.followable(rect, windows: windows, screens: screens) else {
            Log.hud.debug("""
                caret \(rect.debugDescription, privacy: .public) is not followable \
                (\(windows.count, privacy: .public) window(s) of \(self.bundleIdentifier, privacy: .public))
                """)
            return nil
        }
        return followed
    }
}

/// The state of the background read of a client's focused element.
private enum FocusedElementRead {
    case idle
    case reading
    /// A placement asked again while a read was in flight.
    case readingThenAgain
}
