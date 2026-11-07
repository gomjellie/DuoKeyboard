import DuoCore
import DuoKit
import SwiftUI

/// Settings ▸ 앱별 설정: which language Duo leans to in each app (critique R8, R10).
struct AppsPane: View {
    @Environment(AppModel.self) private var app
    @State private var confirmReset = false

    var body: some View {
        let apps = app.apps.apps
        let seen = apps.filter(\.isSeen)
        let others = apps.filter { !$0.isSeen }
        Form {
            Section {
                ForEach(AppProfile.allCases) { profile in
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Text(profile.title)
                        Text(profile.explanation)
                    }
                }
            } header: {
                Text("앱마다 Duo가 먼저 생각할 언어를 정해요")
            } footer: {
                Text("터미널과 코드 편집기는 처음부터 English 우선이에요.")
            }

            Section("Duo로 입력한 앱") {
                if seen.isEmpty {
                    Text("아직 Duo로 입력한 앱이 없어요. Duo로 입력하면 여기에 나타나요.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(seen) { AppProfileRow(app: $0) }
                }
            }
            if !others.isEmpty {
                Section("실행 중인 다른 앱") {
                    ForEach(others) { AppProfileRow(app: $0) }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("기본값 복원…") { confirmReset = true }
                        .disabled(app.settings.value.appProfiles.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { app.apps.beginObserving() }
        .onDisappear { app.apps.endObserving() }
        .confirmationDialog("모든 앱을 기본값으로 되돌릴까요?", isPresented: $confirmReset) {
            Button("기본값 복원", role: .destructive) {
                app.settings.update { $0.appProfiles = [:] }
            }
        } message: {
            Text("직접 고른 앱별 설정이 모두 지워지고, Duo가 정한 기본값으로 돌아가요.")
        }
    }
}

extension AppProfile {
    /// One-line description in the legend at the top of the pane.
    var explanation: String {
        switch self {
        case .automatic: String(localized: "단어마다 알아서 판단해요.")
        case .koreanFirst: String(localized: "애매하면 한국어로 써요. 메신저에 좋아요.")
        case .englishFirst: String(localized: "애매하면 English로 써요. 터미널과 코드에 좋아요.")
        case .direct: String(localized: "키를 그대로 보내요. 바꾸기 키를 누르면 그 줄에서만 한국어를 써요.")
        }
    }
}

/// One app: icon, name, and a profile menu that marks the built-in default.
private struct AppProfileRow: View {
    let app: AppsModel.App
    @Environment(AppModel.self) private var model

    var body: some View {
        let profiles = model.settings.value.appProfiles
        let current = profiles[app.bundleID] ?? app.defaultProfile
        LabeledContent {
            Picker(selection: Binding(
                get: { current },
                set: { profile in
                    model.settings.update {
                        $0.appProfiles = AppCatalog.setting(profile, for: app.bundleID, default: app.defaultProfile,
                                                            in: $0.appProfiles)
                    }
                })
            ) {
                ForEach(AppProfile.allCases) { profile in
                    Text(profile == app.defaultProfile
                         ? String(localized: "\(profile.title) (기본값)")
                         : profile.title)
                        .tag(profile)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: app.name)
                        .lineLimit(1)
                    Text(verbatim: app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
