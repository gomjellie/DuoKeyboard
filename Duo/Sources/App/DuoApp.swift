import DuoKit
import SwiftUI

/// Duo.app: onboarding and settings for the Duo input method. The app *is* the settings surface:
/// one System Settings–style sidebar window (also opened with ⌘,), plus a 4-step onboarding window
/// shown on first launch and whenever Duo is not installed or turned on.
@main
struct DuoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app: AppModel
    private let presentOnboarding: Bool
    private let presentsWindows: Bool

    init() {
        let model = AppModel.live(embedded: LaunchMode.embeddedInputMethod)
        _app = State(initialValue: model)
        AppDelegate.model = model
        presentsWindows = LaunchMode.current.presentsWindows
        presentOnboarding = model.shouldPresentOnboarding
        model.onboardingStep = model.initialOnboardingStep
        model.consumeLaunchRequest()
    }

    var body: some Scene {
        Window(Text("Duo 설정"), id: WindowID.settings) {
            SettingsRootView()
                .environment(app)
                .registersWindowActions(in: app)
        }
        .defaultSize(DuoStyle.settingsDefaultSize)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(presentsWindows && !presentOnboarding ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands { DuoCommands(app: app) }

        Window(Text("Duo 시작하기"), id: WindowID.onboarding) {
            OnboardingView()
                .environment(app)
                .registersWindowActions(in: app)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(presentsWindows && presentOnboarding ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct WindowActionsRegistrar: ViewModifier {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear { app.registerWindowActions(open: openWindow, dismiss: dismissWindow) }
    }
}

extension View {
    /// Hands the scene's `openWindow` / `dismissWindow` to the app model for menu and delegate use.
    func registersWindowActions(in app: AppModel) -> some View {
        modifier(WindowActionsRegistrar(app: app))
    }
}
