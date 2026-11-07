import Carbon
import Foundation

// Pure decisions behind the host app's windows and install checklist, kept here so they can be
// unit-tested without launching Duo.app.

/// The four onboarding steps (ui-design §3.2, critique P2).
public enum OnboardingStep: Int, CaseIterable, Hashable, Sendable {
    case welcome, enable, tryIt, done
}

/// Why Duo.app was opened by another Duo process (the input menu).
public enum HostLaunchRequest: Sendable, Equatable {
    /// A plain launch (Finder, Dock, Spotlight).
    case none
    /// Input menu ▸ Duo 도움말: the whole setup guide.
    case guide
    /// Input menu ▸ Duo 설정…: the Settings window.
    case settings

    /// The request carried by launch `arguments` (`HostRequest.showGuideArgument` / `showSettingsArgument`).
    public init(arguments: [String]) {
        if arguments.contains(HostRequest.showGuideArgument) {
            self = .guide
        } else if arguments.contains(HostRequest.showSettingsArgument) {
            self = .settings
        } else {
            self = .none
        }
    }
}

/// Which window Duo.app shows, and when onboarding counts as finished (SPEC §5 D1).
public enum OnboardingRoute {
    /// Onboarding opens until it was finished once, and whenever Duo is not installed or turned
    /// on; the guide request always opens it, the Settings request never does.
    public static func presentsOnboarding(hasCompleted: Bool, needsSetup: Bool, request: HostLaunchRequest) -> Bool {
        switch request {
        case .guide: true
        case .settings: false
        case .none: !hasCompleted || needsSetup
        }
    }

    /// Users who finished onboarding once skip straight to 켜기, unless they asked for the guide.
    public static func initialStep(hasCompleted: Bool, request: HostLaunchRequest) -> OnboardingStep {
        hasCompleted && request != .guide ? .enable : .welcome
    }

    /// What a Dock click (or `open`) with no visible window shows.
    public enum Reopen: Equatable, Sendable {
        /// The onboarding window, starting over at `step` when given, else as the user left it.
        case onboarding(restartAt: OnboardingStep?)
        case settings
    }

    /// A minimized or hidden onboarding window comes back where the user left it; only a new one
    /// starts at `initialStep`.
    public static func reopen(onboardingWindowIsOpen: Bool, presentsOnboarding: Bool,
                              initialStep: OnboardingStep) -> Reopen {
        if onboardingWindowIsOpen { return .onboarding(restartAt: nil) }
        return presentsOnboarding ? .onboarding(restartAt: initialStep) : .settings
    }

    /// The step to move to once 켜기 succeeded: the next one, but only if the user is still on 켜기
    /// (they may have pressed 계속, 나중에 or 뒤로 while the installer ran).
    public static func step(afterEnablingFrom current: OnboardingStep) -> OnboardingStep? {
        current == .enable ? .tryIt : nil
    }

    /// Closing the onboarding window (or quitting) finishes onboarding once Duo is ready and the
    /// user got past the welcome screen, so the next launch opens Settings instead of starting over.
    public static func completesOnClose(at step: OnboardingStep, isReady: Bool) -> Bool {
        isReady && step != .welcome
    }
}

/// When the host re-reads the input method's state every second.
public enum StatusPolling {
    /// Poll while a view shows the state and either the app is active, an install is running, or a
    /// view needs it in the background too (onboarding 켜기 waits for a system prompt, critique U5).
    /// Otherwise the TIS notifications, delivered when the app becomes active again, are enough.
    public static func isNeeded(monitors: Int, appIsActive: Bool, isBusy: Bool, backgroundMonitors: Int) -> Bool {
        monitors > 0 && (appIsActive || isBusy || backgroundMonitors > 0)
    }
}

/// State of one checklist row.
public enum ChecklistMark: Equatable, Sendable {
    case pending, running, done, failed
}

/// The live 켜기 checklist (복사 · 등록 · macOS 허용 · 활성화 · 선택).
public enum InstallChecklist {
    public typealias Step = InputMethodInstaller.Step

    /// Steps the user can complete outside Duo: allowing macOS's prompt or adding Duo in Keyboard
    /// Settings (enabled), choosing Duo in the input menu (selected). A failure there is over once
    /// the step holds. Copy and registration failures stay, because an older install can make
    /// those steps look complete.
    public static let userResolvableSteps: Set<Step> = [.enabled, .selected]

    /// The failure at `step` no longer stands: the user fixed it another way.
    public static func resolves(failureAt step: Step, in state: InputMethodState) -> Bool {
        userResolvableSteps.contains(step) && state.isComplete(step)
    }

    /// The row for `step`.
    public static func mark(for step: Step, running: Step?, failed: Step?, finished: Set<Step>,
                            state: InputMethodState) -> ChecklistMark {
        if running == step { return .running }
        if failed == step, !resolves(failureAt: step, in: state) { return .failed }
        return finished.contains(step) || state.isComplete(step) ? .done : .pending
    }
}

/// Finishing an install that stopped at 활성화 or 선택 (critique U5).
///
/// macOS may ask the user to confirm a new input source; `TISEnableInputSource` then returns before
/// the user answers, and the installer's check right after it fails. A select right after enabling
/// can also race TIS. Both are worth waiting for instead of showing an error.
public enum InstallRecovery {
    /// How long to wait for the user to answer a system prompt.
    public static let enableTimeout: Duration = .seconds(60)
    /// How long to wait when TIS refused the enable outright (no prompt is waiting): enough for a
    /// source list that is still catching up with the new bundle, short enough to show the error.
    public static let rejectedEnableGrace: Duration = .seconds(2)
    /// How often to look while waiting.
    public static let pollInterval: Duration = .milliseconds(500)
    /// Pause before the one retry of a failed select.
    public static let selectRetryDelay: Duration = .milliseconds(500)
    /// When to ask TIS once more while waiting, if the first prompt may have been lost.
    public static let reenableAfter: Duration = .seconds(4)

    /// Continues after `error` from `InputMethodInstaller.install`: waits up to `enableTimeout` for
    /// Duo to become enabled, then selects it (`select`), retrying a failed select once. Reports
    /// each step that completes through `onStep`. Returns the error that still stands, or `nil`.
    ///
    /// - Parameter reenable: asked once, `reenableAfter` into the wait. Pass it when System Settings
    ///   was not running before the install: the enable call launched it, and macOS can lose the
    ///   prompt while it starts (seen live). A second enable shows the prompt and never stacks a
    ///   second one (verified live), so the user still answers once.
    @MainActor
    public static func resume(after error: InputMethodInstaller.InstallError, select: Bool,
                              isEnabled: () -> Bool, selectSource: () -> OSStatus,
                              onStep: (InputMethodInstaller.Step) -> Void,
                              reenable: (() -> Void)? = nil, reenableAfter: Duration = reenableAfter,
                              enableTimeout: Duration = enableTimeout, pollInterval: Duration = pollInterval,
                              selectRetryDelay: Duration = selectRetryDelay,
                              sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async
        -> InputMethodInstaller.InstallError? {
        switch error {
        case .enableFailed(let status):
            // `noErr` means TIS took the call but Duo is not on yet: macOS is asking the user (U5).
            // Any other status is a refusal, worth only a short look before the error shows.
            let limit = status == noErr ? enableTimeout : min(enableTimeout, rejectedEnableGrace)
            var waited = Duration.zero
            var reenabled = false
            while !isEnabled() {
                guard waited < limit else { return error }
                if let reenable, !reenabled, status == noErr, waited >= reenableAfter {
                    reenabled = true
                    reenable()
                }
                await sleep(pollInterval)
                waited += pollInterval
            }
            onStep(.allowListed)
            onStep(.enabled)
            guard select else { return nil }
        case .selectFailed:
            break
        case .bundleMissing, .copyFailed, .registerFailed:
            return error
        }
        var status = selectSource()
        if status != noErr {
            await sleep(selectRetryDelay)
            status = selectSource()
        }
        guard status == noErr else { return .selectFailed(status) }
        onStep(.selected)
        return nil
    }
}

/// Links the host app opens.
public enum HostLinks {
    /// The CC BY-SA 4.0 legal code (전문) in Korean for Korean users, else in English.
    public static func ccBySALegalCode(languageCode: String?) -> URL {
        let suffix = languageCode == "ko" ? "ko" : "en"
        return URL(string: "https://creativecommons.org/licenses/by-sa/4.0/legalcode.\(suffix)")!
    }
}
