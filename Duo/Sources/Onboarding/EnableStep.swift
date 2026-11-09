import DuoKit
import SwiftUI

/// Step 2 — Duo 켜기: one button runs the installer off the main thread while a live checklist
/// (복사 · 등록 · macOS 허용 · 활성화 · 선택) follows TIS every second.
struct EnableStep: View {
    /// Called once, shortly after a successful install started from this step.
    var onEnabled: () -> Void = {}

    @Environment(AppModel.self) private var app
    @State private var removesAppleKorean = false

    var body: some View {
        let status = app.status
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(symbol: "keyboard.fill", color: .blue, title: "Duo 켜기",
                       subtitle: "버튼 하나면 Duo가 입력 소스에 추가되고 바로 켜져요.")

            // With a card below, the step details make way so everything fits the fixed window.
            let showsDetails = status.failure == nil && !status.isUpdateAvailable
            VStack(alignment: .leading, spacing: showsDetails ? 12 : 9) {
                ForEach(InputMethodInstaller.Step.allCases) { step in
                    ChecklistRow(mark: status.mark(for: step), title: Text(step.title),
                                 detail: showsDetails ? Text(step.detail) : nil)
                }
            }
            .duoCard()

            if let failure = status.failure {
                InstallFailureCard(failure: failure)
            } else if status.isUpdateAvailable {
                UpdateCard()
            }

            actionRow
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A one-time system prompt can hold this step while the user is in another window (U5).
        .onAppear { app.status.beginMonitoring(inBackground: true) }
        .onDisappear { app.status.endMonitoring(inBackground: true) }
    }

    @ViewBuilder private var actionRow: some View {
        let status = app.status
        if status.state.isReady && status.state.isSelected {
            Label("Duo가 켜져 있어요. 메뉴 막대의 입력 메뉴에서도 확인할 수 있어요.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.body.weight(.medium))
                .symbolRenderingMode(.multicolor)
        } else {
            let appleKorean = status.state.appleKoreanModeNames
            VStack(alignment: .leading, spacing: 14) {
                if !appleKorean.isEmpty {
                    Toggle(isOn: $removesAppleKorean) {
                        Text("macOS 기본 한국어 입력기(\(appleKorean.formatted(.list(type: .and)))) 빼기")
                        Text("Duo가 한국어와 영어를 모두 쳐요. 키보드 설정에서 언제든 다시 넣을 수 있어요.")
                    }
                    .toggleStyle(.checkbox)
                    .disabled(status.isBusy)
                }
                HStack(spacing: 12) {
                    Button {
                        Task {
                            await status.turnOn(removingAppleKorean: removesAppleKorean && !appleKorean.isEmpty)
                            if status.failure == nil && status.state.isReady {
                                try? await Task.sleep(for: .milliseconds(700))
                                onEnabled()
                            }
                        }
                    } label: {
                        Text(status.state.isReady ? "Duo로 전환" : "Duo 켜기")
                            .frame(minWidth: 96)
                    }
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    // ⏎ turns Duo on; once it is on, ⏎ is the bottom bar's 계속.
                    .keyboardShortcut(status.state.isReady ? nil : .defaultAction)
                    .disabled(status.isBusy)

                    if status.isBusy {
                        Text("macOS가 확인을 요청하면 허용을 눌러 주세요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .animation(.snappy, value: status.isBusy)
            }
        }
    }
}

/// The error and the System Settings fallback (critique V8). Retrying is the Duo 켜기 button below.
struct InstallFailureCard: View {
    let failure: InputMethodStatus.Failure

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duo를 켜지 못했어요").font(.headline)
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("키보드 설정의 ‘텍스트 입력’에서 편집…을 누른 다음, + 버튼으로 한국어 ▸ Duo를 추가해도 돼요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Button("키보드 설정 열기…") { SystemSettings.openKeyboard() }
                .glassButton()
                .padding(.leading, 28)
        }
        .duoCard(padding: 14)
    }
}

/// The embedded IME is newer than the installed one.
struct UpdateCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let status = app.status
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("새 버전이 준비됐어요").font(.headline)
                Text("설치된 Duo \(status.state.installedVersion?.description ?? "–") → \(status.embeddedVersion?.description ?? "–")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status.activity == .updating {
                ProgressView().controlSize(.small)
            }
            Button("업데이트") { Task { await status.update() } }
                .glassButton()
                .disabled(status.isBusy)
        }
        .duoCard(padding: 14)
    }
}
