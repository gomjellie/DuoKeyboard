import DuoCore
import DuoKit
import SwiftUI

/// Settings ▸ 학습: the learning switch and a searchable table of learned words.
struct LearningPane: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var selection = Set<LearningModel.Row.ID>()
    @State private var sortOrder = [KeyPathComparator(\LearningModel.Row.raw, comparator: .localizedStandard)]
    @State private var confirmReset = false

    var body: some View {
        let learning = app.learning
        let rows = visibleRows
        Form {
            Section {
                Toggle(isOn: app.settings.binding(\.learningEnabled)) {
                    Text("학습하기")
                    Text("바꾸기 키로 고친 단어와 애매했던 단어를 기억해서 다음부터 맞게 써요.")
                }
                if app.settings.value.learningPaused {
                    LabeledContent {
                        Button("다시 시작") { app.settings.update { $0.learningPaused = false } }
                    } label: {
                        Label("학습이 잠시 멈춰 있어요", systemImage: "pause.circle.fill")
                    }
                }
            } footer: {
                Text("학습은 이 Mac 안에서만 이뤄져요. 입력한 문장은 저장하지 않고, 단어별 횟수만 남아요.")
            }

            Section {
                table(rows)
                    .frame(minHeight: 260)
                HStack(spacing: 10) {
                    Button("삭제", systemImage: "minus") { remove(selection) }
                        .labelStyle(.iconOnly)
                        .disabled(selection.isEmpty)
                        .help(Text("선택한 단어 삭제"))
                    Text(summary(total: learning.rows.count, shown: rows.count))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("모두 지우기…", role: .destructive) { confirmReset = true }
                        .disabled(learning.rows.isEmpty)
                }
            } header: {
                Text("학습한 단어")
            } footer: {
                Text("확신도는 바꾸기 키로 고친 단어에서 크게, 애매했던 단어를 그대로 쓰면 조금 올라가요. 쓰지 않으면 60일마다 표가 절반으로 줄어서 확신도도 서서히 낮아져요.")
            }
            if let message = learning.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: Text("입력 키나 결과 검색"))
        .onAppear { learning.beginObserving() }
        .onDisappear { learning.endObserving() }
        .confirmationDialog("학습한 단어를 모두 지울까요?", isPresented: $confirmReset) {
            Button("모두 지우기", role: .destructive) {
                withAnimation(.snappy) { learning.removeAll() }
                selection = []
            }
        } message: {
            Text("Duo가 기억한 단어가 모두 사라져요. 되돌릴 수 없어요.")
        }
    }

    private var visibleRows: [LearningModel.Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let rows = q.isEmpty ? app.learning.rows : app.learning.rows.filter {
            $0.raw.localizedCaseInsensitiveContains(q) || $0.result.localizedCaseInsensitiveContains(q)
        }
        return rows.sorted(using: sortOrder)
    }

    private func table(_ rows: [LearningModel.Row]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("입력 키", value: \.raw, comparator: .localizedStandard) { row in
                Text(verbatim: row.raw).font(.body.monospaced())
            }
            TableColumn("결과", value: \.result, comparator: .localizedStandard) { row in
                HStack(spacing: 6) {
                    LanguageBadge(language: row.language, size: 16)
                    Text(verbatim: row.result)
                }
            }
            TableColumn("문맥", value: \.contextTitle, comparator: .localizedStandard) { row in
                Text(verbatim: row.contextTitle).foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 76)
            TableColumn("확신도", value: \.strength) { row in
                StrengthBar(value: row.strength, color: DuoStyle.color(for: row.language))
            }
            .width(min: 52, ideal: 60)
            TableColumn("마지막 사용", value: \.lastUsed) { row in
                Text(row.lastUsed, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            }
            .width(min: 76, ideal: 92)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if rows.isEmpty { emptyState }
        }
        .contextMenu(forSelectionType: LearningModel.Row.ID.self) { ids in
            Button("삭제", systemImage: "trash", role: .destructive) { remove(ids) }
        }
        .onDeleteCommand { remove(selection) }
    }

    @ViewBuilder private var emptyState: some View {
        if !app.learning.isLoaded {
            ProgressView()
        } else if query.isEmpty {
            ContentUnavailableView {
                Label("학습한 단어가 없어요", systemImage: "character.book.closed.ko")
            } description: {
                Text("바꾸기 키로 고친 단어가 여기에 나타나요.")
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func summary(total: Int, shown: Int) -> String {
        shown == total ? String(localized: "단어 \(total)개") : String(localized: "단어 \(total)개 중 \(shown)개")
    }

    private func remove(_ ids: Set<LearningModel.Row.ID>) {
        guard !ids.isEmpty else { return }
        withAnimation(.snappy) { app.learning.remove(ids) }
        selection.subtract(ids)
    }
}

/// `LearningModel.Row.strength` (0…1) as a short bar in the reading's language color.
private struct StrengthBar: View {
    let value: Double
    let color: Color

    private static let width: CGFloat = 44

    var body: some View {
        let percent = Text(value, format: .percent.precision(.fractionLength(0)))
        Capsule()
            .fill(.quaternary)
            .frame(width: Self.width, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(6, Self.width * min(max(value, 0), 1)), height: 6)
            }
            .help(percent)
            .accessibilityElement()
            .accessibilityLabel(Text("확신도"))
            .accessibilityValue(percent)
    }
}
