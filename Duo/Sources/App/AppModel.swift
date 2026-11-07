import DuoCore
import DuoKit
import Observation
import SwiftUI

/// Window identifiers of the two scenes.
enum WindowID {
    static let settings = "settings"
    static let onboarding = "onboarding"
}

/// The four Settings panes (critique P2).
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, apps, learning, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "일반")
        case .apps: String(localized: "앱별 설정")
        case .learning: String(localized: "학습")
        case .about: String(localized: "정보")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .apps: "square.grid.2x2.fill"
        case .learning: "character.book.closed.ko"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .apps: .indigo
        case .learning: .orange
        case .about: .blue
        }
    }
}

/// Root state shared by every scene: models, navigation, and window routing.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsModel
    let status: InputMethodStatus
    let languageModel: LanguageModelProvider
    let learning: LearningModel
    let apps: AppsModel

    var selectedPane: SettingsPane = .general
    var onboardingStep: OnboardingStep = .welcome
    /// The onboarding window exists (it may be minimized).
    @ObservationIgnored private(set) var isOnboardingWindowOpen = false

    @ObservationIgnored private var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var dismissWindowAction: DismissWindowAction?
    @ObservationIgnored private var requestObservers: [any NSObjectProtocol] = []
    /// What the input menu asked for when it launched this process; cleared once acted on.
    @ObservationIgnored private var launchRequest: HostLaunchRequest

    init(settings: SettingsModel, status: InputMethodStatus, languageModel: LanguageModelProvider,
         learning: LearningModel, apps: AppsModel, launchRequest: HostLaunchRequest = .none) {
        self.settings = settings
        self.status = status
        self.languageModel = languageModel
        self.learning = learning
        self.apps = apps
        self.launchRequest = launchRequest
    }

    /// The live model for the running app.
    static func live(embedded: EmbeddedInputMethod?) -> AppModel {
        let languageModel = LanguageModelProvider(modelURL: embedded?.modelURL)
        let model = AppModel(settings: SettingsModel(),
                             status: InputMethodStatus(embedded: embedded),
                             languageModel: languageModel,
                             learning: LearningModel(languageModel: languageModel),
                             apps: AppsModel(),
                             launchRequest: HostLaunchRequest(arguments: ProcessInfo.processInfo.arguments))
        // Input menu ▸ Duo 도움말 / Duo 설정… while Duo.app is already running.
        let center = DistributedNotificationCenter.default()
        model.requestObservers = [
            center.addObserver(forName: HostRequest.showGuideNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.showOnboarding(at: .welcome) }
            },
            center.addObserver(forName: HostRequest.showSettingsNotification, object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.showSettings() }
            },
        ]
        return model
    }

    /// First launch, Duo is not installed or not turned on (SPEC §5 D1), or the guide was asked for;
    /// never when the input menu asked for Settings.
    var shouldPresentOnboarding: Bool {
        OnboardingRoute.presentsOnboarding(hasCompleted: settings.value.hasCompletedOnboarding,
                                           needsSetup: status.needsSetup, request: launchRequest)
    }

    /// Where onboarding starts: users who finished it once skip straight to 켜기, unless they asked
    /// for the whole guide.
    var initialOnboardingStep: OnboardingStep {
        OnboardingRoute.initialStep(hasCompleted: settings.value.hasCompletedOnboarding, request: launchRequest)
    }

    /// The first window has been chosen (`DuoApp.init`): later Dock clicks behave like a plain launch.
    func consumeLaunchRequest() {
        launchRequest = .none
    }

    // MARK: Windows

    /// Called by every scene's root view so AppKit-side code (the app delegate, menus) can open windows.
    func registerWindowActions(open: OpenWindowAction, dismiss: DismissWindowAction) {
        openWindowAction = open
        dismissWindowAction = dismiss
    }

    func showSettings(_ pane: SettingsPane? = nil) {
        if let pane { selectedPane = pane }
        openWindowAction?(id: WindowID.settings)
        NSApp.activate()
    }

    func showOnboarding(at step: OnboardingStep = .welcome) {
        onboardingStep = step
        openWindowAction?(id: WindowID.onboarding)
        NSApp.activate()
    }

    /// 완료: remember it, then hand over to Settings as the main window.
    func finishOnboarding(openingPane pane: SettingsPane = .general) {
        settings.update { $0.hasCompletedOnboarding = true }
        showSettings(pane)
        dismissWindowAction?(id: WindowID.onboarding)
    }

    func onboardingWindowDidAppear() {
        isOnboardingWindowOpen = true
    }

    /// The onboarding window closed (or the app is quitting with it open). Once Duo is ready and the
    /// user got past the welcome screen, that finishes onboarding: the next launch opens Settings.
    func onboardingWindowDidClose() {
        isOnboardingWindowOpen = false
        guard !settings.value.hasCompletedOnboarding,
              OnboardingRoute.completesOnClose(at: onboardingStep, isReady: status.state.isReady) else { return }
        settings.update { $0.hasCompletedOnboarding = true }
    }

    /// Dock click or `open` with no visible window. A minimized onboarding window comes back on the
    /// step the user left it at.
    func reopen() {
        switch OnboardingRoute.reopen(onboardingWindowIsOpen: isOnboardingWindowOpen,
                                      presentsOnboarding: shouldPresentOnboarding,
                                      initialStep: initialOnboardingStep) {
        case .onboarding(let restartAt):
            if let restartAt { onboardingStep = restartAt }
            openWindowAction?(id: WindowID.onboarding)
            NSApp.activate()
        case .settings:
            showSettings()
        }
    }
}

/// How this process was launched.
enum LaunchMode: Equatable {
    case normal
    #if DEBUG
    /// `--duo-render <dir>`: render every onboarding step and Settings pane offscreen, then exit.
    case render(URL)
    #endif

    static let current: LaunchMode = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--duo-render"), i + 1 < args.count {
            return .render(URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
        #endif
        return .normal
    }()

    var presentsWindows: Bool { self == .normal }

    /// The embedded input method. DEBUG builds honour `DUO_EMBEDDED_IME=<path>` so a missing IME or
    /// model can be exercised (`DUO_EMBEDDED_IME=/nonexistent`).
    static var embeddedInputMethod: EmbeddedInputMethod? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["DUO_EMBEDDED_IME"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? EmbeddedInputMethod(bundleURL: url) : nil
        }
        #endif
        return EmbeddedInputMethod.current
    }
}
