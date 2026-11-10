import DuoKit
import SwiftUI

/// Settings ▸ 일반 ▸ 업데이트: the automatic update switch, what the last check found, and the one
/// action that fits (지금 확인, 다시 시도, or 지금 설치).
struct UpdateSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let updater = app.updater
        Section {
            Toggle(isOn: app.settings.binding(\.autoUpdate)) {
                Text("자동으로 업데이트")
                Text("하루에 한 번 새 버전을 확인해서 내려받고, Duo 설정을 종료할 때 설치해요. 입력한 내용은 보내지 않아요.")
            }
            LabeledContent {
                HStack(spacing: 8) {
                    if updater.isWorking { ProgressView().controlSize(.small) }
                    switch updater.phase {
                    case .ready:
                        Button("지금 설치") { updater.installAndRelaunch() }
                    case .failed:
                        Button("다시 시도") { Task { await updater.check() } }
                    default:
                        Button("지금 확인") { Task { await updater.check() } }
                            .disabled(updater.isWorking)
                    }
                }
            } label: {
                Text(title(updater.phase))
                Text(detail(updater.phase, current: updater.current))
            }
        } header: {
            Text("Duo 업데이트")
        }
    }

    private func title(_ phase: AppUpdater.Phase) -> LocalizedStringKey {
        switch phase {
        case .idle: "새 버전 확인"
        case .checking: "새 버전을 확인하고 있어요"
        case .upToDate: "최신 버전이에요"
        case .downloading(let version): "Duo \(version.description) 내려받는 중"
        case .ready(let version): "Duo \(version.description) 설치 준비 완료"
        case .needsNewerSystem(let version, _), .cannotReplace(let version): "Duo \(version.description)이 나왔어요"
        case .failed: "새 버전을 확인하지 못했어요"
        }
    }

    private func detail(_ phase: AppUpdater.Phase, current: BundleVersion?) -> LocalizedStringKey {
        switch phase {
        case .idle, .checking, .upToDate, .downloading:
            "지금 버전은 \(current?.description ?? "–")이에요."
        case .ready:
            "Duo 설정을 종료하면 설치해요. 지금 설치하면 Duo 설정이 다시 열려요."
        case .needsNewerSystem(_, let minimum):
            "macOS \(minimum) 이상에서 설치할 수 있어요."
        case .cannotReplace:
            "지금 위치에서는 Duo를 바꿀 수 없어요. Duo를 응용 프로그램 폴더로 옮긴 뒤 다시 확인해 주세요."
        case .failed:
            "인터넷 연결을 확인한 뒤 다시 시도해 주세요."
        }
    }
}
