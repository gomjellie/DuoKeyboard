#if DEBUG
import AppKit
import DuoCore
import DuoKit
import SwiftUI

/// Visual QA without screen capture (ui-design §5): renders every onboarding step and Settings pane
/// into PNGs with `cacheDisplay`, in light and dark, from windows parked far outside every display.
///
/// Run: `Duo.app/Contents/MacOS/Duo --duo-render <dir> [-AppleLanguages '(en)']`. The process uses
/// the `.prohibited` activation policy, so it never shows a window, a Dock icon or takes focus.
/// Fixtures never persist anything (`SettingsModel(persists: false)`, fixed `InputMethodStatus`).
@MainActor
struct SnapshotRenderer {
    let app: AppModel
    let directory: URL

    private var suffix: String {
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        let noModel = ProcessInfo.processInfo.environment["DUO_EMBEDDED_IME"] != nil ? "-nomodel" : ""
        return "-\(language)\(noModel)"
    }

    /// Renders everything; returns the number of images that failed.
    func renderAll() async -> Int {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var failures = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let tag = appearance == .aqua ? "light" : "dark"
            for (name, scene) in await scenes() {
                let url = directory.appending(path: "\(name)\(suffix)-\(tag).png")
                if await render(scene, appearance: appearance, to: url) {
                    print("wrote", url.lastPathComponent)
                } else {
                    print("FAILED", url.lastPathComponent)
                    failures += 1
                }
            }
        }
        return failures
    }

    // MARK: Scenes

    private struct Scene {
        enum Chrome { case onboarding, settings, pane }
        var chrome: Chrome
        var size: CGSize
        var model: AppModel
        var view: AnyView
    }

    private func scenes() async -> [(String, Scene)] {
        let embedded = app.status.embedded
        let ready = InputMethodState(isInstalled: true, isRegistered: true, isAllowListed: true, isEnabled: true,
                                     isSelected: true, installedVersion: embedded?.version ?? BundleVersion(marketing: "1.0.0", build: "1"),
                                     isServerRunning: true)
        var enabledOnly = ready
        enabledOnly.isSelected = false
        enabledOnly.otherSelectedSourceName = "2벌식"
        let fresh = InputMethodState(otherSelectedSourceName: "2벌식")
        var outdated = ready
        outdated.installedVersion = BundleVersion(marketing: "0.9.0", build: "1")
        var secure = ready
        secure.isSecureInputActive = true
        secure.secureInputAppName = "Google Chrome"
        secure.isSelected = false
        secure.otherSelectedSourceName = "ABC"

        var result: [(String, Scene)] = []
        let onboarding = CGSize(width: DuoStyle.onboardingSize.width, height: DuoStyle.onboardingSize.height)

        func onboardingScene(_ step: OnboardingStep, _ model: AppModel, _ content: some View) -> Scene {
            Scene(chrome: .onboarding, size: onboarding, model: model,
                  view: AnyView(OnboardingView(fixtureStep: step, content: AnyView(content))))
        }

        // 1 환영
        let welcome = await model(state: fresh)
        let welcomePlayground = await playground(welcome, text: "", marked: "안녕")
        result.append(("onboarding-1-welcome",
                       onboardingScene(.welcome, welcome, WelcomeStep(playground: welcomePlayground, heroFrame: (0, true)))))
        let welcomeTyping = await model(state: fresh)
        let typingPlayground = await playground(welcomeTyping, text: "", marked: "")
        result.append(("onboarding-1-welcome-typing",
                       onboardingScene(.welcome, welcomeTyping, WelcomeStep(playground: typingPlayground, heroFrame: (1, false)))))

        // 2 Duo 켜기
        let enableError = InputMethodStatus.Failure(
            step: .enabled, message: String(localized: "입력 소스를 켜지 못했어요. 키보드 설정에서 직접 추가할 수 있어요. (오류 \(-50))"))
        let enableCases: [(String, InputMethodState, InputMethodStatus.Activity, InputMethodStatus.Failure?, Set<InputMethodInstaller.Step>)] = [
            ("fresh", fresh, .idle, nil, []),
            ("installing", fresh, .installing(step: .allowListed), nil, [.copied, .registered]),
            ("error", fresh, .idle, enableError, [.copied, .registered, .allowListed]),
            ("update", outdated, .idle, nil, []),
            ("done", ready, .idle, nil, []),
        ]
        for (name, state, activity, failure, finished) in enableCases {
            let m = await model(state: state)
            m.status.setFixture(activity: activity, failure: failure, finishedSteps: finished)
            result.append(("onboarding-2-enable-\(name)", onboardingScene(.enable, m, EnableStep())))
        }

        // 3 써보기
        let tryIt = await model(state: enabledOnly)
        let tryPlayground = await playground(tryIt, text: "안녕하세요 Duo를 써봐요. 이건 ", marked: "해")
        let goChoice = HUDChoice(current: HUDReading(text: "해", language: .korean),
                                 other: HUDReading(text: "go", language: .english), currentFirst: true)
        tryPlayground.showFixtureHUD(HUDRequest(content: .alternative(goChoice, eligible: true), anchor: .markedText))
        let detectedCoach = FlipKeyCoachModel(fixtureFlipKey: .rightCommand, detected: true, offersAlternatives: false)
        let someProgress = PracticeProgress(greeting: true, numbers: false, flippedWhileTyping: true, flippedLastWord: false)
        result.append(("onboarding-3-try", onboardingScene(.tryIt, tryIt,
                       TryItStep(playground: tryPlayground, coach: detectedCoach, progress: someProgress))))
        let tryAlt = await model(state: enabledOnly)
        let altPlayground = await playground(tryAlt, text: "", marked: "")
        let waitingCoach = FlipKeyCoachModel(fixtureFlipKey: .rightCommand, detected: false, offersAlternatives: true)
        result.append(("onboarding-3-try-alternatives", onboardingScene(.tryIt, tryAlt,
                       TryItStep(playground: altPlayground, coach: waitingCoach, progress: PracticeProgress()))))

        // 3 써보기, driven end to end: synthetic key-downs → KeyEventMapper → CompositionEngine → BufferTextClient.
        let live = await model(state: enabledOnly)
        let livePlayground = await playground(live, text: "", marked: "")
        for chunk in ["dkssudgktpdy", " ", "Duofmf", " ", "TJqhkdy", ". ", "macOS", " 26 ", "djqepdlxm", " ", "go"] {
            Self.press(chunk, into: livePlayground)
        }
        print("live playground:", livePlayground.text.debugDescription, "marked:", String(describing: livePlayground.markedRange))
        result.append(("onboarding-3-try-live", onboardingScene(.tryIt, live,
                       TryItStep(playground: livePlayground, coach: FlipKeyCoachModel(fixtureFlipKey: .rightCommand, detected: false,
                                                                                      offersAlternatives: false),
                                 progress: PracticeProgress()))))

        // 4 완료
        let done = await model(state: ready)
        result.append(("onboarding-4-done", onboardingScene(.done, done, DoneStep())))

        // Settings
        let window = DuoStyle.settingsDefaultSize
        for (pane, state) in [(SettingsPane.general, ready), (.apps, ready), (.learning, ready), (.about, ready)] {
            let m = await model(state: state)
            m.selectedPane = pane
            result.append(("settings-\(pane.rawValue)", Scene(chrome: .settings, size: window, model: m,
                                                              view: AnyView(SettingsWindowStandIn()))))
        }
        // Whole panes, tall, to check every row.
        for (name, state) in [("ready", ready), ("not-installed", fresh), ("secure-input", secure), ("update", outdated)] {
            let m = await model(state: state)
            let field = await playground(m, text: "오늘 회의는 3시예요. ", marked: "")
            result.append(("pane-general-\(name)", Scene(chrome: .pane, size: CGSize(width: 580, height: 1560), model: m,
                                                        view: AnyView(GeneralPane(playground: field)))))
        }
        let learning = await model(state: ready)
        result.append(("pane-learning", Scene(chrome: .pane, size: CGSize(width: 580, height: 760), model: learning,
                                             view: AnyView(LearningPane()))))
        let empty = await model(state: ready, learningRows: [])
        result.append(("pane-learning-empty", Scene(chrome: .pane, size: CGSize(width: 580, height: 600), model: empty,
                                                   view: AnyView(LearningPane()))))
        let apps = await model(state: ready)
        result.append(("pane-apps", Scene(chrome: .pane, size: CGSize(width: 580, height: 980), model: apps,
                                         view: AnyView(AppsPane()))))
        let unseen = Self.sampleApps().map { app in
            var app = app
            app.isSeen = false
            return app
        }
        let noApps = await model(state: ready, apps: unseen)
        result.append(("pane-apps-none-seen", Scene(chrome: .pane, size: CGSize(width: 580, height: 900), model: noApps,
                                                   view: AnyView(AppsPane()))))
        let about = await model(state: ready)
        result.append(("pane-about", Scene(chrome: .pane, size: CGSize(width: 580, height: 900), model: about,
                                          view: AnyView(AboutPane()))))
        return result
    }

    // MARK: Fixtures

    /// ANSI key codes of the ABC layout (the engine maps key positions, never characters).
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, ".": 47, " ": 49,
    ]

    /// Sends key-downs for `text` straight to the playground model (no window, no system injection).
    private static func press(_ text: String, into playground: PlaygroundModel) {
        for ch in text {
            let lower = Character(ch.lowercased())
            guard let code = keyCodes[lower] else { continue }
            let shift = ch.isUppercase
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                               context: nil, characters: String(ch), charactersIgnoringModifiers: String(lower),
                                               isARepeat: false, keyCode: code) else { continue }
            _ = playground.handleKeyDown(event)
        }
    }

    private func model(state: InputMethodState, learningRows: [LearningModel.Row]? = nil,
                       apps: [AppsModel.App]? = nil) async -> AppModel {
        var settings = DuoSettings()
        settings.hasCompletedOnboarding = true
        settings.appProfiles = ["com.apple.Notes": .koreanFirst]
        let languageModel = LanguageModelProvider(modelURL: app.status.embedded?.modelURL)
        let detector = await languageModel.detector()
        let rows = learningRows ?? Self.sampleWords.map { LearningModel.row(for: $0, detector: detector) }
        return AppModel(settings: SettingsModel(initial: settings, persists: false),
                        status: InputMethodStatus(embedded: app.status.embedded, fixedState: state),
                        languageModel: languageModel,
                        learning: LearningModel(fixture: rows, languageModel: languageModel),
                        apps: AppsModel(fixture: apps ?? Self.sampleApps()))
    }

    private func playground(_ model: AppModel, text: String, marked: String) async -> PlaygroundModel {
        let playground = PlaygroundModel(languageModel: model.languageModel)
        await playground.prepare(settings: model.settings.value)
        playground.showFixture(committed: text, marked: marked)
        return playground
    }

    private static var sampleWords: [LearnedWord] {
        let now = Date()
        func word(_ raw: String, _ context: LanguageContext, _ winner: Hypothesis, _ weight: Double, daysAgo: Double) -> LearnedWord {
            LearnedWord(raw: raw, context: context, winner: winner, weight: weight,
                        lastUsed: now.addingTimeInterval(-daysAgo * 86_400))
        }
        return [
            word("dkssud", .start, .korean, 4, daysAgo: 0.1),
            word("go", .korean, .korean, 3, daysAgo: 1),
            word("go", .english, .english, 1, daysAgo: 6),
            word("rust", .korean, .english, 6, daysAgo: 2),
            word("gksrmf", .start, .korean, 2, daysAgo: 12),
            word("PRdmf", .korean, .mixed(latin: 2), 3, daysAgo: 3),
            word("tmdnlvmxm", .korean, .korean, 1, daysAgo: 30),
            word("zoom", .number, .english, 2, daysAgo: 45),
        ]
    }

    private static func sampleApps() -> [AppsModel.App] {
        let specs: [(String, AppProfile, Bool)] = [
            ("com.apple.Terminal", .englishFirst, true),
            ("com.apple.Notes", .automatic, true),
            ("com.apple.Safari", .automatic, true),
            ("com.kakao.KakaoTalkMac", .koreanFirst, true),
            ("com.microsoft.VSCode", .englishFirst, false),
            ("com.apple.TextEdit", .automatic, false),
        ]
        return specs.map { id, profile, seen in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? (id == "com.kakao.KakaoTalkMac" ? "카카오톡" : id)
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
            return AppsModel.App(bundleID: id, name: name, icon: icon, isSeen: seen, isRunning: true, defaultProfile: profile)
        }
    }

    // MARK: Rendering

    /// The Settings window as `cacheDisplay` can draw it: the real sidebar rows beside the real pane.
    private struct SettingsWindowStandIn: View {
        @Environment(AppModel.self) private var app

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { color in
                            Circle().fill(color.opacity(0.85)).frame(width: 12, height: 12)
                        }
                    }
                    .padding(.leading, 20)
                    .frame(height: 52)
                    List(SettingsPane.allCases, selection: .constant(app.selectedPane)) { pane in
                        SettingsSidebarLabel(pane: pane).tag(pane)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
                .frame(width: 210)
                .background(.background.secondary)
                Divider()
                VStack(spacing: 0) {
                    Text(app.selectedPane.title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .frame(height: 52)
                    SettingsPaneView(pane: app.selectedPane)
                }
            }
            .frame(width: DuoStyle.settingsDefaultSize.width, height: DuoStyle.settingsDefaultSize.height)
        }
    }

    private func render(_ scene: Scene, appearance: NSAppearance.Name, to url: URL) async -> Bool {
        let root = scene.view
            .environment(scene.model)
            .environment(\.duoSnapshotMode, true)
        let window: NSWindow
        switch scene.chrome {
        case .onboarding:
            window = NSWindow(contentRect: NSRect(origin: .zero, size: scene.size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: root)
        case .settings, .pane:
            // Offscreen, Forms and Lists only draw in a borderless window, and a NavigationSplitView
            // not at all; the Settings window render therefore composites the real sidebar rows and
            // the real pane (`SettingsWindowStandIn`).
            window = NSWindow(contentRect: NSRect(origin: .zero, size: scene.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = NSHostingView(rootView: root.frame(width: scene.size.width, height: scene.size.height))
        }
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        // Far outside every display: "visible" to AppKit (lists realize their rows), no pixel on screen.
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(900))
        window.contentView?.needsDisplay = true
        window.display()
        try? await Task.sleep(for: .milliseconds(200))

        guard let frameView = window.contentView?.superview ?? window.contentView else { return false }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
#endif
