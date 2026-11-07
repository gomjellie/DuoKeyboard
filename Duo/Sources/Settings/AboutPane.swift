import AppKit
import DuoKit
import SwiftUI

/// Settings ▸ 정보: identity, privacy, acknowledgements (CC BY-SA 4.0 model data), and uninstall.
struct AboutPane: View {
    @Environment(AppModel.self) private var app
    @State private var confirmUninstall = false
    @State private var license: String?

    /// The legal code in the language the app is shown in.
    static var ccBySAURL: URL {
        HostLinks.ccBySALegalCode(languageCode: Bundle.main.preferredLocalizations.first)
    }

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Duo는 모든 판단을 Mac 안에서 해요. 입력한 문장은 저장하지 않고, 학습에는 단어별 횟수만 남아요. Duo는 인터넷에 연결하지 않아요.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                }
                .padding(.vertical, 2)
                LabeledContent("데이터 위치") {
                    HStack(spacing: 8) {
                        Text(verbatim: "~/Library/Application Support/Duo")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Finder에서 보기") { revealSupportFolder() }
                    }
                }
            } header: {
                header
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("언어 모델 데이터")
                        .font(.headline)
                    // U+2011 keeps “BY‑SA” on one line.
                    Text("Duo의 언어 모델은 CC BY‑SA 4.0 라이선스로 공개된 자료를 가공해 만들었고, 같은 라이선스로 배포해요.")
                        .fixedSize(horizontal: false, vertical: true)
                    if let license {
                        ScrollView {
                            Text(verbatim: license)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(height: 170)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        Text("라이선스 파일을 찾지 못했어요. Duo 입력기 안의 duo-model.LICENSE.txt에 들어 있어요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Link("CC BY‑SA 4.0 라이선스 전문 보기", destination: Self.ccBySAURL)
                }
                .padding(.vertical, 4)
            } header: {
                Text("감사의 말")
            }

            Section {
                LabeledContent {
                    Button("Duo 제거…", role: .destructive) { confirmUninstall = true }
                        .disabled(!app.status.state.isInstalled || app.status.isBusy)
                } label: {
                    Text("Duo 제거")
                    Text("입력 소스에서 Duo를 빼고 입력기를 지워요. 설정과 학습한 단어는 남아요.")
                }
            }
        }
        .formStyle(.grouped)
        .task { license = app.status.embedded?.modelLicenseText().map(Self.reflow) }
        .confirmationDialog("Duo 입력기를 제거할까요?", isPresented: $confirmUninstall) {
            Button("제거", role: .destructive) { Task { await app.status.uninstall() } }
        } message: {
            Text("Duo가 지금 쓰는 입력 소스라면 ABC로 바꾼 다음 제거해요. 언제든 Duo 켜기로 다시 설치할 수 있어요.")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            AppIconImage(size: 96)
            Text(verbatim: "Duo")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)
            Text("키보드 하나, 두 언어.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("버전 \(Self.appVersion)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .textCase(nil)
    }

    static var appVersion: String {
        BundleVersion(bundleURL: Bundle.main.bundleURL)?.description ?? "–"
    }

    /// Joins the hard-wrapped lines of the license file into paragraphs, keeping bullets and the
    /// lines after a colon on their own lines, so the text wraps to the box instead of twice.
    static func reflow(_ text: String) -> String {
        text.components(separatedBy: "\n\n").map { paragraph in
            var result = ""
            for raw in paragraph.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if result.isEmpty {
                    result = line
                } else if line.hasPrefix("•") || result.hasSuffix(":") {
                    result += "\n" + line
                } else {
                    result += " " + line
                }
            }
            return result
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func revealSupportFolder() {
        let url = DuoIDs.supportDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
