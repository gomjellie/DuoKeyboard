import DuoKit
import SwiftUI

/// Settings ▸ 일반 ▸ 상태: a summary with the one action that helps, then the detail rows
/// (설치, 입력 소스, 현재 입력 소스, 버전) and the Secure Keyboard Entry warning.
struct StatusSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let status = app.status
        let state = status.state
        Section {
            summary
            LabeledContent("설치") {
                StatusValue(ok: state.isInstalled, text: state.isInstalled ? "설치됨" : "설치 안 됨")
            }
            LabeledContent("입력 소스") {
                StatusValue(ok: state.isEnabled, text: state.isEnabled ? "켜짐" : "꺼짐")
            }
            LabeledContent("현재 입력 소스") {
                if state.isSelected {
                    StatusValue(ok: true, text: "Duo")
                } else {
                    Text(verbatim: state.otherSelectedSourceName ?? String(localized: "다른 입력 소스"))
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("버전") {
                HStack(spacing: 6) {
                    Text(verbatim: state.installedVersion?.description ?? "–")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if status.isUpdateAvailable {
                        Text("새 버전 \(status.embeddedVersion?.description ?? "")")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                    }
                }
            }
            if state.isSecureInputActive {
                SecureInputWarning()
            }
            if let failure = status.failure {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Duo를 켜지 못했어요")
                        Text(failure.message).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        } header: {
            Text("상태")
        }
    }

    private var summary: some View {
        let status = app.status
        let content = SummaryContent(status: status)
        return HStack(spacing: 12) {
            Image(systemName: content.symbol)
                .font(.system(size: 26))
                .foregroundStyle(content.color)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(.headline)
                Text(content.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if status.isBusy {
                ProgressView().controlSize(.small)
            } else if let action = content.action {
                Button(action.title) { Task { await action.run(status) } }
                    .glassButton(prominent: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The headline of the status section and the action that fixes the current state.
private struct SummaryContent {
    struct Action {
        var title: LocalizedStringKey
        var run: @MainActor (InputMethodStatus) async -> Void
    }

    var symbol: String
    var color: Color
    var title: LocalizedStringKey
    var detail: String
    var action: Action?

    @MainActor init(status: InputMethodStatus) {
        let state = status.state
        let turnOn = Action(title: "Duo 켜기") { await $0.turnOn() }
        if status.isUpdateAvailable {
            symbol = "arrow.down.circle.fill"
            color = .blue
            title = "새 버전이 준비됐어요"
            detail = String(localized: "업데이트하면 Duo 입력기가 다시 시작돼요. 설정과 학습은 그대로예요.")
            action = Action(title: "업데이트") { await $0.update() }
        } else if !state.isInstalled {
            symbol = "exclamationmark.triangle.fill"
            color = .orange
            title = "Duo가 아직 설치되지 않았어요"
            detail = String(localized: "Duo 켜기를 누르면 입력 소스에 추가되고 바로 켜져요.")
            action = turnOn
        } else if !state.isEnabled {
            symbol = "exclamationmark.triangle.fill"
            color = .orange
            title = "Duo가 꺼져 있어요"
            detail = String(localized: "입력 메뉴에 Duo가 보이지 않아요. 다시 켜 주세요.")
            action = turnOn
        } else if !state.isSelected {
            symbol = "checkmark.circle"
            color = .green
            title = "Duo가 켜져 있어요"
            detail = String(localized: "지금은 다른 입력 소스를 쓰고 있어요. 입력 메뉴에서 Duo를 고르면 돼요.")
            action = Action(title: "Duo로 전환") { await $0.turnOn() }
        } else {
            symbol = "checkmark.circle.fill"
            color = .green
            title = "Duo를 쓰고 있어요"
            detail = String(localized: "어느 앱에서나 그냥 입력하면 돼요.")
            action = nil
        }
    }
}

/// A trailing status value with a small colored symbol.
private struct StatusValue: View {
    let ok: Bool
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
    }
}

/// Some app turned on Secure Keyboard Entry: Duo passes keys through until it is off (critique R5).
private struct SecureInputWarning: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("보안 키보드 입력이 켜져 있어요")
                Text("다른 앱이 보안 키보드 입력을 켜 두면 Duo는 잠시 키를 그대로 보내요. 그 앱에서 끄거나 앱을 닫으면 다시 동작해요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "lock.shield.fill").foregroundStyle(.orange)
        }
    }
}

/// "Duo 다시 시작" and the System Settings link.
struct TroubleshootingSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let status = app.status
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if status.activity == .restarting {
                        ProgressView().controlSize(.small)
                    } else if status.restartedAt != nil {
                        Label("다시 시작했어요", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Button("Duo 다시 시작") { Task { await status.restartInputMethod() } }
                        .disabled(status.isBusy || !status.state.isInstalled)
                }
            } label: {
                Text("입력기 다시 시작")
                Text("입력이 이상하면 Duo 입력기를 다시 시작해 보세요. 설정과 학습한 단어는 그대로예요.")
            }
            LabeledContent {
                Button("키보드 설정 열기…") { SystemSettings.openKeyboard() }
            } label: {
                Text("키보드 설정")
                Text("입력 소스 목록과 단축키는 시스템 설정에서 바꿀 수 있어요.")
            }
        } header: {
            Text("문제 해결")
        }
    }
}
