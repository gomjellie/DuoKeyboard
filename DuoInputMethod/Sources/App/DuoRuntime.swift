import AppKit
import Carbon
import DuoCore
import DuoKit
import os

/// The input method's process-wide singletons (SPEC.md §2, critique R14): the detector, the
/// learning store and its writer, the settings, and the HUD. `main.swift` creates it and calls
/// ``start()`` before `NSApp.run()`; every `DuoInputController` (one per client session) reads it.
@MainActor
final class DuoRuntime {
    static let shared = DuoRuntime()

    /// The scoring model, or `nil` when `duo-model.bin` is missing or corrupt. Without it every key
    /// passes straight through, so a broken install types plain ABC instead of nothing.
    let detector: DuoDetector?
    let learning: LearningStore
    let hud: CompositionHUDController
    /// Routes modifier events from IMK and from a global monitor (Chromium/Electron) to the engine.
    let modifierRouter = ModifierRouter()
    /// The ASCII layout forced on clients so raw pass-through matches the model's ABC keys (critique R16).
    let keyboardLayoutID: String

    private(set) var settings: DuoSettings
    /// Bumped whenever ``settings`` changes; controllers compare it to resync their engine cheaply.
    private(set) var settingsGeneration = 0

    /// The controller of the focused client session (for TIS source changes and the debug injector).
    weak var activeController: DuoInputController?

    /// Every successful write tells the host, so an open Settings ▸ 학습 pane follows what the IME
    /// learns while typing, not only the host's own edits (review host-8).
    private let writer = LearningWriter(didWrite: {
        DistributedNotificationCenter.default().postNotificationName(
            DuoIDs.Notifications.learningChanged, object: nil, userInfo: nil, deliverImmediately: true)
    })
    private let notifications = DistributedNotificationRelay()
    private var systemObservers: [any NSObjectProtocol] = []
    private var persistTask: Task<Void, Never>?
    private var hasUnsavedLearning = false
    /// The write that follows a burst of host `learning.command`s (one snapshot, one write).
    private var commandWriteTask: Task<Void, Never>?
    /// A command since the last such write changed the store.
    private var commandsChangedLearning = false
    private var terminationSignal: (any DispatchSourceSignal)?

    private init() {
        detector = Self.loadDetector()
        learning = LearningStore(snapshot: LearningFile.load())
        settings = SettingsStore.load()
        hud = CompositionHUDController(flipKey: settings.flipKey)
        keyboardLayoutID = Self.resolveKeyboardLayout()
    }

    /// Installs observers. Call once, before `NSApp.run()`.
    func start() {
        learning.onChange = { [weak self] in self?.learningDidChange() }

        notifications.observe(DuoIDs.Notifications.settingsChanged) { [weak self] _ in self?.reloadSettings() }
        notifications.observe(DuoIDs.Notifications.learningCommand) { [weak self] info in
            self?.applyLearningCommand(info)
        }
        notifications.observe(DuoIDs.Notifications.ping) { [weak self] _ in self?.answerPing() }
        notifications.observe(Self.selectedSourceChanged) { [weak self] _ in self?.selectedInputSourceDidChange() }

        // The panel joins every Space (ux-spec §7.1), and a latched alternative or the Bilingual
        // badge has no lifetime. A Space switch within the same app sends no deactivateServer, and
        // a display change leaves the cached caret stale: hide; the next keystroke re-earns the HUD.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            systemObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DuoRuntime.shared.hud.forceHide() }
            })
        }
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DuoRuntime.shared.hud.forceHide() }
            })
        installTerminationSignalHandler()
        modifierRouter.start()

        Log.runtime.info("""
            Duo input method started: model=\(self.detector?.contentHash ?? "MISSING", privacy: .public) \
            learned=\(self.learning.count, privacy: .public) \
            layout=\(self.keyboardLayoutID, privacy: .public)
            """)
    }

    // MARK: Settings

    /// Re-reads the shared settings (on `settingsChanged`, in `activateServer`, after menu actions).
    func reloadSettings() {
        let fresh = SettingsStore.load()
        guard fresh != settings else { return }
        settings = fresh
        settingsGeneration &+= 1
        hud.flipKey = fresh.flipKey
        Log.runtime.info("settings reloaded (generation \(self.settingsGeneration, privacy: .public))")
    }

    /// Read-modify-write through `SettingsStore` (which tells the host app), then applies it here at once.
    func updateSettings(_ change: (inout DuoSettings) -> Void) {
        SettingsStore.update(change)
        reloadSettings()
    }

    // MARK: Learning persistence

    /// Coalesces bursts of learning changes into one snapshot for the writer (which debounces again
    /// and writes atomically). Taking the snapshot off the keystroke path keeps typing cheap.
    func learningDidChange() {
        hasUnsavedLearning = true
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            self.persistTask = nil
            guard self.hasUnsavedLearning else { return }
            self.hasUnsavedLearning = false
            await self.writer.schedule(self.learning.snapshot())
        }
    }

    /// Writes any pending learning data now and waits for it (`applicationWillTerminate`, SIGTERM).
    func flushLearningSynchronously(timeout: TimeInterval = 3) {
        persistTask?.cancel()
        persistTask = nil
        let snapshot: LearningSnapshot? = hasUnsavedLearning ? learning.snapshot() : nil
        hasUnsavedLearning = false
        let writer = self.writer
        let done = DispatchSemaphore(value: 0)
        let flushed = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
            if let snapshot { await writer.schedule(snapshot) }
            let ok = await writer.flush()
            flushed.withLock { $0 = ok }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Log.runtime.error("learning flush timed out after \(timeout, privacy: .public) s")
        } else if flushed.withLock({ $0 }) {
            Log.runtime.info("learning flushed")
        } else {
            // LearningWriter logged the error itself (domain and code).
            Log.runtime.error("learning flush failed")
        }
    }

    /// Host → IME `learning.command` (`op` = `remove` with `raw` and optional `ctx`, or `removeAll`).
    /// The IME is the only writer (critique R14): apply, write, then tell the host.
    ///
    /// The change is applied in memory at once, in arrival order, on the main thread: the host posts
    /// up to 50 commands and then a `ping`, and takes the `pong` to mean all of them are applied
    /// (LearningEditor's barrier). The write follows the burst: one snapshot and one write for all
    /// of it, skipped when no command changed anything.
    private func applyLearningCommand(_ info: [String: String]) {
        switch info["op"] {
        case "remove":
            guard let raw = info["raw"], !raw.isEmpty else {
                Log.runtime.error("learning command 'remove' without raw")
                return
            }
            var context: LanguageContext?
            if let ctx = info["ctx"] {
                guard let parsed = LanguageContext(rawValue: ctx) else {
                    Log.runtime.error("learning command with unknown ctx \(ctx, privacy: .public)")
                    return
                }
                context = parsed
            }
            if learning.remove(raw: raw, context: context) { commandsChangedLearning = true }
        case "removeAll":
            learning.removeAll()
            // Written even if the store was already empty, so the file is empty too afterwards.
            commandsChangedLearning = true
            // The recovery copies (learning.corrupt-*.json) hold words too.
            Task.detached(priority: .utility) { LearningFile.removeBackups() }
        default:
            Log.runtime.error("unknown learning command \(info["op"] ?? "nil", privacy: .public)")
            return
        }
        Log.runtime.debug("learning command \(info["op"] ?? "", privacy: .public) applied")
        guard commandWriteTask == nil else { return }
        commandWriteTask = Task { [weak self] in
            // Let the rest of the burst arrive first (distributed notifications come a few ms apart).
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            self.commandWriteTask = nil
            await self.writeAfterLearningCommands()
        }
    }

    /// Writes the store after a burst of commands and tells the host. On success the writer's
    /// `didWrite` posts `learningChanged`; with nothing to write, or a failed write, it is posted
    /// here, with `ok` = `"false"` for a failure so the host can say the change was not saved.
    private func writeAfterLearningCommands() async {
        let changed = commandsChangedLearning
        commandsChangedLearning = false
        var ok = true
        if changed {
            persistTask?.cancel()
            persistTask = nil
            hasUnsavedLearning = false
            await writer.schedule(learning.snapshot())
            ok = await writer.flush()
        }
        Log.runtime.info("""
            learning commands applied: changed=\(changed, privacy: .public) saved=\(ok, privacy: .public)
            """)
        guard !changed || !ok else { return }
        DistributedNotificationCenter.default().postNotificationName(
            DuoIDs.Notifications.learningChanged, object: nil, userInfo: LearningChangedNotice.userInfo(saved: ok),
            deliverImmediately: true)
    }

    // MARK: Other notifications

    private func answerPing() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        DistributedNotificationCenter.default().postNotificationName(
            DuoIDs.Notifications.pong, object: nil,
            userInfo: ["version": version, "modelLoaded": detector == nil ? "false" : "true"],
            deliverImmediately: true)
    }

    /// macOS 26 does not call `deactivateServer` when another process selects a different source
    /// (critique R18 #6): commit and hide ourselves.
    private func selectedInputSourceDidChange() {
        guard !Self.isDuoSelected() else { return }
        Log.ime.info("selected input source is no longer Duo; committing")
        activeController?.inputSourceDidChangeAway()
        hud.forceHide()
    }

    // MARK: Process

    /// `pkill`/`killall` (reinstall) sends SIGTERM, which skips `applicationWillTerminate`. Flush the
    /// learning store first so a reinstall never loses the last two seconds of corrections.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Log.runtime.info("SIGTERM: flushing and exiting")
                DuoRuntime.shared.flushLearningSynchronously()
            }
            exit(0)
        }
        source.resume()
        terminationSignal = source
    }

    private static func loadDetector() -> DuoDetector? {
        guard let url = DuoDetector.bundledModelURL(in: .main) else {
            Log.runtime.fault("duo-model.bin is missing from the input method bundle; Duo passes every key through")
            return nil
        }
        do {
            let detector = try DuoDetector(modelURL: url)
            Log.runtime.info("model loaded: \(detector.contentHash, privacy: .public)")
            return detector
        } catch {
            Log.runtime.fault("""
                cannot load \(url.path, privacy: .public): \(String(describing: error), privacy: .public); \
                Duo passes every key through
                """)
            return nil
        }
    }

    /// `com.apple.keylayout.ABC`, falling back to `…US` on systems without it.
    private static func resolveKeyboardLayout() -> String {
        let candidates = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        for id in candidates {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
               !list.isEmpty {
                return id
            }
        }
        Log.runtime.error("neither ABC nor US keyboard layout found; using US")
        return candidates[1]
    }

    private static let selectedSourceChanged = Notification.Name(
        (kTISNotifySelectedKeyboardInputSourceChanged as String?)
            ?? "AppleSelectedInputSourcesChangedNotification")

    /// Whether the current keyboard input source belongs to Duo (any of its modes).
    static func isDuoSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return false }
        let bundleID = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return bundleID == DuoIDs.inputMethodBundleID
    }
}

/// Distributed-notification observer that always delivers immediately (an input method is a
/// background process; system TIS notifications are not posted with `deliverImmediately`) and hands
/// handlers only plist-safe string values, on the main actor.
@MainActor
final class DistributedNotificationRelay: NSObject {
    private var handlers: [Notification.Name: @MainActor ([String: String]) -> Void] = [:]

    func observe(_ name: Notification.Name, handler: @escaping @MainActor ([String: String]) -> Void) {
        handlers[name] = handler
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receive(_:)), name: name, object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private nonisolated func receive(_ note: Notification) {
        let name = note.name
        var info: [String: String] = [:]
        for (key, value) in note.userInfo ?? [:] {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let deliver: @MainActor () -> Void = { [weak self] in self?.handlers[name]?(info) }
        if Thread.isMainThread {
            MainActor.assumeIsolated(deliver)
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }
}
