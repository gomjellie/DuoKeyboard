import DuoCore
import DuoKit
import SwiftUI

/// Settings ▸ 일반: playground, status and troubleshooting, flip key, typing options, language bias.
struct GeneralPane: View {
    @Environment(AppModel.self) private var app
    @State private var playground: PlaygroundModel?

    var body: some View {
        let settings = app.settings
        Form {
            Section {
                if let playground {
                    PlaygroundField(model: playground, placeholder: "여기에 입력해 보세요. Duo가 언어를 알아서 골라요.",
                                    height: 60, isEmbedded: true)
                        .padding(.horizontal, -10)
                }
            } header: {
                Text("써보기")
            }

            StatusSection()

            Section {
                FlipKeyPicker(selection: settings.binding(\.flipKey))
                    .padding(.vertical, 2)
            } header: {
                Text("바꾸기 키")
            } footer: {
                if [.rightCommand, .rightOption].contains(settings.value.flipKey) {
                    Text("단어가 잘못 나오면 이 키로 한국어와 English를 바꿔요. 누르고 있는 동안 숫자를 누르면 후보에서 골라요. 바꾼 단어는 Duo가 기억해요.")
                } else {
                    Text("단어가 잘못 나오면 이 키로 한국어와 English를 바꿔요. 바꾼 단어는 Duo가 기억해요.")
                }
            }

            Section("입력") {
                Toggle(isOn: settings.binding(\.showHints)) {
                    Text("입력 중 힌트 보기")
                    Text("애매한 단어를 쓰는 동안, 바꾸면 어떻게 되는지 커서 아래에 보여 줘요.")
                }
                Toggle(isOn: settings.binding(\.alwaysShowChoices)) {
                    Text("후보 늘 보기")
                    Text("애매하지 않은 단어도 쓰는 동안 모든 읽기를 보여 줘요. 꺼 두어도 바꾸기 키를 누르면 보여요.")
                }
                .disabled(!settings.value.showHints)
                TerminalHUDAccessRow()
                Toggle(isOn: settings.binding(\.offerUndoAfterCommit)) {
                    Text("확정 후 바꾸기 제안")
                    Text("Duo가 확신하지 못한 단어를 확정하면 잠깐 ‘↺ 바꾸기’를 띄워요.")
                }
                // fixedSize goes on the bare control: on the labelled row it also shrinks the row, and
                // the picker then stops where the detail text ends instead of the trailing edge.
                LabeledContent {
                    Picker("백스페이스 단위", selection: settings.binding(\.backspaceUnit)) {
                        ForEach(BackspaceUnit.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                } label: {
                    Text("백스페이스 단위")
                    Text("자소는 닭 → 달 → 다처럼 한 자소씩, 글자는 한 글자를 통째로 지워요.")
                }
                Toggle(isOn: settings.binding(\.graveTypesWon)) {
                    Text("` 키로 ₩ 입력")
                    Text("Apple 두벌식처럼 ` 키를 누르면 ₩가 입력돼요.")
                }
            }

            Section {
                LanguageBiasSlider(bias: settings.binding(\.languageBias))
            } header: {
                Text("언어 감지")
            } footer: {
                Text("Duo가 언어를 자주 잘못 고른다면, 주로 쓰는 언어 쪽으로 옮겨 보세요.")
            }

            Section("고급") {
                TapWindowSlider(milliseconds: settings.binding(\.flipTapWindowMs))
                    .disabled(!settings.value.flipKey.usesTapWindow)
                Toggle(isOn: settings.binding(\.eagerEnglishCommit)) {
                    Text("확실한 영어는 바로 확정")
                    Text("영어 단어가 확실하면 입력하는 동안 확정해서, 자동 완성이 실제 글자를 볼 수 있어요.")
                }
            }

            TroubleshootingSection()
        }
        .formStyle(.grouped)
        .onAppear {
            if playground == nil { playground = PlaygroundModel(languageModel: app.languageModel) }
        }
    }
}

extension GeneralPane {
    #if DEBUG
    /// A pane with a prepared playground, for offscreen renders.
    init(playground: PlaygroundModel) {
        _playground = State(initialValue: playground)
    }
    #endif
}

/// English ↔ 한국어 bias (−1000…+1000 millinats, critique R8), filling from the centre.
private struct LanguageBiasSlider: View {
    @Binding var bias: Int

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Slider(value: value, in: -1000...1000, neutralValue: 0) {
                    Text("자주 쓰는 언어")
                } minimumValueLabel: {
                    Text(verbatim: "English")
                } maximumValueLabel: {
                    Text("한국어")
                } ticks: {
                    SliderTick(-1000.0)
                    SliderTick(0.0)
                    SliderTick(1000.0)
                }
            } else {
                // No centre fill or ticks before macOS 26; 21 stops still land on 0.
                Slider(value: value, in: -1000...1000, step: 100) {
                    Text("자주 쓰는 언어")
                } minimumValueLabel: {
                    Text(verbatim: "English")
                } maximumValueLabel: {
                    Text("한국어")
                }
            }
        }
        .accessibilityValue(accessibilityValue)
    }

    private var value: Binding<Double> {
        Binding(get: { Double(bias) }, set: { bias = Int(($0 / 100).rounded()) * 100 })
    }

    private var accessibilityValue: Text {
        switch bias {
        case ..<0: Text("English 쪽으로 \(abs(bias) / 100)")
        case 1...: Text("한국어 쪽으로 \(bias / 100)")
        default: Text("가운데")
        }
    }
}

/// Modifier-tap window, 200…500 ms.
private struct TapWindowSlider: View {
    @Binding var milliseconds: Int

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { Double(milliseconds) }, set: { milliseconds = Int(($0 / 10).rounded()) * 10 }),
                       in: 200...500) {
                    Text("탭 인식 시간")
                }
                .labelsHidden()
                .frame(width: 180)
                Text("\(milliseconds)ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        } label: {
            Text("탭 인식 시간")
            Text("바꾸기 키를 이 시간 안에 눌렀다 떼면 탭으로 쳐요.")
        }
    }
}
