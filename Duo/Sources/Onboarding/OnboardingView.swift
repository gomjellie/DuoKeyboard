import DuoKit
import SwiftUI

/// The 4-step onboarding window (ui-design §3.2 frame, ux-spec §8.1 content, critique P2).
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var forward = true
    /// A playground has focus: ⏎ types a newline there instead of pressing 계속.
    @State private var isTyping = false
    /// Offscreen renders show a prepared step instead of the live one.
    private var fixture: (step: OnboardingStep, content: AnyView)?

    init() {}

    private var step: OnboardingStep { fixture?.step ?? app.onboardingStep }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    if let fixture { fixture.content } else { stepView(step) }
                }
                .id(step)
                .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 44)
            .padding(.top, 40)

            bottomBar
        }
        .frame(width: DuoStyle.onboardingSize.width, height: DuoStyle.onboardingSize.height)
        .background(OnboardingBackground())
        .onPreferenceChange(PlaygroundFocusKey.self) { isTyping = $0 }
        .onAppear {
            app.status.beginMonitoring()
            if fixture == nil { app.onboardingWindowDidAppear() }
        }
        .onDisappear {
            app.status.endMonitoring()
            if fixture == nil { app.onboardingWindowDidClose() }
        }
    }

    @ViewBuilder private func stepView(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomeStep()
        case .enable: EnableStep(onEnabled: advanceAfterEnabling)
        case .tryIt: TryItStep()
        case .done: DoneStep()
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            PageDots(count: OnboardingStep.allCases.count, index: step.rawValue)
            Spacer()
            if step != .welcome && step != .done {
                Button("뒤로") { go(-1) }
                    .glassButton()
                    .keyboardShortcut(isTyping ? nil : .cancelAction)
            }
            primaryButton
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    @ViewBuilder private var primaryButton: some View {
        let shortcut: KeyboardShortcut? = isTyping ? nil : .defaultAction
        switch step {
        case .enable where !app.status.state.isReady:
            // Duo 켜기 is the prominent action on this step; skipping stays possible.
            Button("나중에") { go(+1) }
                .glassButton()
        case .done:
            Button("완료") { app.finishOnboarding() }
                .glassButton(prominent: true)
                .keyboardShortcut(shortcut)
        default:
            Button("계속") { go(+1) }
                .glassButton(prominent: true)
                .keyboardShortcut(shortcut)
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: app.onboardingStep.rawValue + delta) else { return }
        go(to: next)
    }

    private func go(to next: OnboardingStep) {
        forward = next.rawValue > app.onboardingStep.rawValue
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4)) {
            app.onboardingStep = next
        }
    }

    /// Shortly after 켜기 succeeds: on to 써보기, unless the user already left the step.
    private func advanceAfterEnabling() {
        guard let next = OnboardingRoute.step(afterEnablingFrom: app.onboardingStep) else { return }
        go(to: next)
    }
}

extension OnboardingView {
    #if DEBUG
    /// Shows `content` as `step`, for offscreen renders.
    init(fixtureStep: OnboardingStep, content: AnyView) {
        fixture = (fixtureStep, content)
    }
    #endif
}

/// A whisper of the two language colors at the top of the window.
private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            LinearGradient(colors: [DuoStyle.korean.opacity(0.07), DuoStyle.english.opacity(0.05), .clear],
                           startPoint: .topLeading, endPoint: UnitPoint(x: 0.7, y: 0.55))
        }
        .ignoresSafeArea()
    }
}

/// Reports whether any playground in the subtree has keyboard focus.
struct PlaygroundFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Left-aligned step title with an icon tile (steps 2 and 3).
struct StepHeader: View {
    let symbol: String
    let color: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIcon(symbol: symbol, color: color, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
