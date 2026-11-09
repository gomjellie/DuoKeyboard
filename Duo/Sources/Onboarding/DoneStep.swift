import SwiftUI

/// Step 4 — 완료: where Duo lives, how to fix a word, and that learning stays on this Mac.
struct DoneStep: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green.gradient)
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                .accessibilityHidden(true)
            Text("준비됐어요")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 14)
            Text("이제 어디서나 그냥 쓰면 돼요.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 14) {
                Tip(symbol: "menubar.rectangle", color: .blue,
                    text: "메뉴 막대의 입력 메뉴에서 언제든 Duo 설정을 열 수 있어요.")
                Tip(symbol: "arrow.left.arrow.right", color: .orange,
                    text: "단어가 잘못 나오면 바꾸기 키를 눌러요. 바꾼 단어는 Duo가 기억해요.") {
                    KeyCaps(flipKey: app.settings.value.flipKey, size: 11)
                }
                Tip(symbol: "lock.fill", color: .green,
                    text: "모든 판단과 학습은 이 Mac 안에서만 이뤄져요.")
                Tip(symbol: "terminal.fill", color: .gray,
                    text: "vim이나 less를 자주 쓴다면 터미널을 ‘직접 입력’으로 바꿔 보세요.") {
                    Button("앱별 설정") { app.finishOnboarding(openingPane: .apps) }
                        .buttonStyle(.link)
                }
            }
            .duoCard(padding: 18)
            .padding(.top, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 12)
        .onAppear { if !reduceMotion { appeared = true } }
    }
}

private struct Tip<Trailing: View>: View {
    let symbol: String
    let color: Color
    let text: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsIcon(symbol: symbol, color: color, size: 26)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}

extension Tip where Trailing == EmptyView {
    init(symbol: String, color: Color, text: LocalizedStringKey) {
        self.init(symbol: symbol, color: color, text: text, trailing: { EmptyView() })
    }
}
