import DuoCore
import DuoKit
import SwiftUI

/// Step 3 — 써보기: four practice tasks checked live in the playground (ux-spec §8.1 #6), plus
/// flip-key coaching.
struct TryItStep: View {
    @Environment(AppModel.self) private var app
    @State private var playground: PlaygroundModel?
    @State private var coach: FlipKeyCoachModel?
    @State private var progress = PracticeProgress()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(symbol: "character.cursor.ibeam.ko", color: .orange, title: "써보기",
                       subtitle: "아래 칸에 직접 입력해 보세요. 해낸 일은 바로 체크돼요.")
            if let playground {
                PlaygroundField(model: playground, placeholder: "안녕하세요 Duo를 써봐요", height: 78, autoFocus: true)
                    .onAppear { progress.note(text: playground.committedText) }
                    .onChange(of: playground.committedText) { _, text in progress.note(text: text) }
                    .onChange(of: playground.lastFlip) { _, flip in
                        if let flip { progress.note(flip: flip) }
                    }
            }
            tasks
            if let coach { FlipKeyCoach(coach: coach) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if playground == nil { playground = PlaygroundModel(languageModel: app.languageModel) }
            if coach == nil { coach = FlipKeyCoachModel(settings: app.settings.value) }
        }
    }

    private var tasks: some View {
        let caps = app.settings.value.flipKey.keycaps
        return VStack(alignment: .leading, spacing: 10) {
            ChecklistRow(mark: progress.greeting ? .done : .pending, title: Text("‘안녕하세요 Duo를 써봐요’ 입력하기"))
            ChecklistRow(mark: progress.numbers ? .done : .pending, title: Text("‘macOS 26 업데이트’ 입력하기"))
            ChecklistRow(mark: progress.flippedWhileTyping ? .done : .pending,
                         title: Text("한국어 문장 속 go를 쓰는 중에 go ↔ 해 바꾸기")) {
                KeyCaps(caps: caps, size: 10)
            }
            ChecklistRow(mark: progress.flippedLastWord ? .done : .pending,
                         title: Text("단어를 쓰고 Space를 누른 다음, 그 단어 바꾸기")) {
                KeyCaps(caps: caps, size: 10)
            }
        }
        .duoCard(padding: 14)
        .animation(.snappy, value: progress)
    }
}

extension TryItStep {
    #if DEBUG
    /// A step with prepared models, for offscreen renders.
    init(playground: PlaygroundModel, coach: FlipKeyCoachModel, progress: PracticeProgress) {
        _playground = State(initialValue: playground)
        _coach = State(initialValue: coach)
        _progress = State(initialValue: progress)
    }
    #endif
}
