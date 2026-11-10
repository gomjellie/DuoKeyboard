import AppKit
import Carbon
import DuoKit
import Foundation
import Observation

/// Live installation status of the Duo input method plus the actions that change it (turn on,
/// update, restart, uninstall). Shared by onboarding step 2 and Settings ▸ 일반.
///
/// While any view monitors it, it re-reads `InputMethodState` on TIS change notifications and, while
/// Duo.app is active or an install runs, every second (critique U5: a one-time system prompt may
/// delay a step, so polling must tolerate it). Onboarding 켜기 keeps the poll running in the
/// background too, since the user may be answering that prompt in another window.
@MainActor
@Observable
final class InputMethodStatus {
    typealias Step = InputMethodInstaller.Step

    /// What the installer is doing right now.
    enum Activity: Equatable {
        case idle
        /// Installing; `step` is the one in progress.
        case installing(step: Step)
        case updating
        case restarting
        case uninstalling
    }

    /// The last failed action, shown with 다시 시도 and the System Settings fallback.
    struct Failure: Equatable {
        var step: Step
        var message: String
    }

    private(set) var state: InputMethodState
    private(set) var activity: Activity = .idle {
        didSet { if activity != oldValue { updatePolling() } }
    }
    private(set) var failure: Failure?
    /// Steps finished by the install running in this session (shown as done even before TIS catches up).
    private(set) var finishedSteps: Set<Step> = []
    /// Set for three seconds after 다시 시작, for a brief confirmation.
    private(set) var restartedAt: Date?

    let embedded: EmbeddedInputMethod?
    let embeddedVersion: BundleVersion?

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var monitorCount = 0
    @ObservationIgnored private var backgroundMonitorCount = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var appObservers: [any NSObjectProtocol] = []

    /// - Parameters:
    ///   - embedded: the IME inside Duo.app (`nil` when the bundle is missing).
    ///   - fixedState: a fixture for offscreen rendering; disables polling and every action.
    init(embedded: EmbeddedInputMethod?, fixedState: InputMethodState? = nil) {
        self.embedded = embedded
        embeddedVersion = embedded?.version
        isLive = fixedState == nil
        state = fixedState ?? InputMethodState.read()
    }

    // MARK: Derived

    var isUpdateAvailable: Bool { state.isUpdateAvailable(embedded: embeddedVersion) }

    /// Onboarding opens on launch while this is true.
    var needsSetup: Bool { !state.isReady }

    var isBusy: Bool { activity != .idle }

    func mark(for step: Step) -> ChecklistMark {
        InstallChecklist.mark(for: step, running: currentStep, failed: failure?.step, finished: finishedSteps, state: state)
    }

    // MARK: Monitoring

    /// A view shows the state. `inBackground`: keep polling while Duo.app is not active.
    func beginMonitoring(inBackground: Bool = false) {
        monitorCount += 1
        if inBackground { backgroundMonitorCount += 1 }
        guard isLive else { return }
        if monitorCount == 1 {
            refresh()
            observeChanges()
        }
        updatePolling()
    }

    func endMonitoring(inBackground: Bool = false) {
        monitorCount = max(0, monitorCount - 1)
        if inBackground { backgroundMonitorCount = max(0, backgroundMonitorCount - 1) }
        guard isLive else { return }
        if monitorCount == 0 {
            observers.forEach(DistributedNotificationCenter.default().removeObserver)
            appObservers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            appObservers = []
        }
        updatePolling()
    }

    /// Re-reads the state. A failure the user has since fixed another way (allowed the prompt,
    /// added Duo in Keyboard Settings, picked it in the input menu) is cleared.
    func refresh() {
        guard isLive else { return }
        let next = InputMethodState.read()
        if next != state { state = next }
        if let failure, InstallChecklist.resolves(failureAt: failure.step, in: state) { self.failure = nil }
    }

    private func observeChanges() {
        let names = [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged]
            .compactMap { $0 as String? }
        observers = names.map { name in
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }
        let app = NotificationCenter.default
        appObservers = [
            app.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.updatePolling()
                }
            },
            app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePolling() }
            },
        ]
    }

    /// Starts or stops the 1 s poll (`StatusPolling.isNeeded`).
    private func updatePolling() {
        guard isLive else { return }
        let needed = StatusPolling.isNeeded(monitors: monitorCount, appIsActive: NSApplication.shared.isActive,
                                            isBusy: isBusy, backgroundMonitors: backgroundMonitorCount)
        if !needed {
            pollTask?.cancel()
            pollTask = nil
        } else if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
        }
    }

    // MARK: Actions

    /// "Duo 켜기": copy (when missing or outdated), register, enable (the user approves in macOS) and select.
    /// - Parameter removingAppleKorean: once Duo is on, take macOS's Korean input method out of the
    ///   input menu. Never before, so a failed install still leaves a way to type Korean.
    func turnOn(removingAppleKorean: Bool = false) async {
        guard isLive, !isBusy else { return }
        failure = nil
        finishedSteps = []
        let needsCopy = !state.isInstalled || isUpdateAvailable
        let source = needsCopy ? embedded?.bundleURL : nil
        if needsCopy && source == nil {
            failure = Failure(step: .copied, message: String(localized: "Duo 앱 안에 입력기가 없어요. Duo를 다시 내려받아 설치해 주세요."))
            return
        }
        activity = .installing(step: needsCopy ? .copied : .registered)
        // macOS asks for approval in System Settings; if this install launches it, the first prompt
        // can be lost while it starts (InstallRecovery asks once more).
        let settingsWasRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences").isEmpty
        let report: @Sendable (Step) -> Void = { [weak self] step in
            Task { @MainActor in self?.didFinish(step) }
        }
        do {
            try await Self.perform {
                _ = try InputMethodInstaller.install(from: source, select: true, onStep: report)
            }
        } catch let error as InputMethodInstaller.InstallError where InstallChecklist.userResolvableSteps.contains(error.step) {
            // macOS may be waiting for the user to allow the new source, or a select raced TIS:
            // wait for it instead of failing at once (critique U5).
            activity = .installing(step: error.step)
            if let remaining = await InstallRecovery.resume(
                after: error, select: true,
                isEnabled: {
                    InputSourceManager.catchUpWithSystemList(waiting: true)
                    return InputSourceManager.isEnabled
                },
                selectSource: {
                    // Selecting while System Settings is frontmost does not stick: come back first.
                    NSApplication.shared.activate()
                    return InputSourceManager.select()
                },
                isSelected: { InputSourceManager.isSelected },
                onStep: { didFinish($0) },
                reenable: settingsWasRunning ? nil : { _ = InputSourceManager.enable() }) {
                failure = Self.failure(for: remaining, during: remaining.step)
            } else if case .enableFailed = error {
                // The user answered macOS's prompt in System Settings: come back for the next step.
                NSApplication.shared.activate()
            }
        } catch {
            failure = Self.failure(for: error, during: currentStep ?? .copied)
        }
        if removingAppleKorean && failure == nil && InputSourceManager.isEnabled {
            _ = try? await Self.perform { InputSourceManager.removeAppleKorean() }
        }
        activity = .idle
        refresh()
    }

    /// 업데이트: replace the installed IME with the embedded, newer one and restart it.
    func update() async {
        guard isLive, !isBusy, let source = embedded?.bundleURL else { return }
        failure = nil
        activity = .updating
        do {
            try await Self.perform { try InputMethodInstaller.update(from: source) }
        } catch {
            failure = Self.failure(for: error, during: .copied)
        }
        activity = .idle
        refresh()
    }

    /// "Duo 다시 시작": stop the IME process; macOS starts it again on the next keystroke.
    func restartInputMethod() async {
        guard isLive, !isBusy else { return }
        activity = .restarting
        try? await Self.perform { InputMethodInstaller.terminateRunningServer() }
        activity = .idle
        let now = Date()
        restartedAt = now
        refresh()
        try? await Task.sleep(for: .seconds(3))
        if restartedAt == now { restartedAt = nil }
    }

    /// Removes Duo from the input sources and deletes the installed IME (settings and learning stay).
    func uninstall() async {
        guard isLive, !isBusy else { return }
        activity = .uninstalling
        try? await Self.perform { InputMethodInstaller.uninstall() }
        activity = .idle
        finishedSteps = []
        refresh()
    }

    #if DEBUG
    /// Freezes an in-between state for offscreen renders.
    func setFixture(activity: Activity, failure: Failure?, finishedSteps: Set<Step>) {
        self.activity = activity
        self.failure = failure
        self.finishedSteps = finishedSteps
    }
    #endif

    // MARK: Private

    private var currentStep: Step? {
        if case .installing(let step) = activity { return step }
        return nil
    }

    private func didFinish(_ step: Step) {
        finishedSteps.insert(step)
        guard case .installing = activity,
              let index = Step.allCases.firstIndex(of: step), index + 1 < Step.allCases.count else { return }
        activity = .installing(step: Step.allCases[index + 1])
    }

    private static func failure(for error: any Error, during step: Step) -> Failure {
        guard let error = error as? InputMethodInstaller.InstallError else {
            return Failure(step: step, message: error.localizedDescription)
        }
        let message = switch error {
        case .bundleMissing:
            String(localized: "Duo 앱 안에 입력기가 없어요. Duo를 다시 내려받아 설치해 주세요.")
        case .copyFailed(let reason):
            String(localized: "입력기를 Input Methods 폴더에 복사하지 못했어요. (\(reason))")
        case .registerFailed(let status):
            String(localized: "macOS가 Duo를 입력 소스로 등록하지 못했어요. (오류 \(Int(status)))")
        case .enableFailed(let status) where status == noErr:
            // TIS took the call; the user did not answer macOS's prompt in time.
            String(localized: "macOS의 허용을 받지 못했어요. 시스템 설정의 확인 창에서 ‘허용’을 누른 뒤 다시 시도해 주세요.")
        case .enableFailed(let status):
            String(localized: "입력 소스를 켜지 못했어요. 키보드 설정에서 직접 추가할 수 있어요. (오류 \(Int(status)))")
        case .selectFailed(let status):
            String(localized: "Duo를 선택하지 못했어요. 메뉴 막대의 입력 메뉴에서 Duo를 골라 주세요. (오류 \(Int(status)))")
        }
        return Failure(step: error.step, message: message)
    }

    /// Runs blocking installer work on a background queue (file copies, `pkill`); TIS calls inside hop
    /// back to the main thread on their own.
    nonisolated private static func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
