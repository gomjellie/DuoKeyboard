import SwiftUI

/// Step 1 — 환영: the promise, the hero morph, and a live field to try before installing anything.
struct WelcomeStep: View {
    @Environment(AppModel.self) private var app
    @State private var playground: PlaygroundModel?
    /// Offscreen renders freeze the hero on one frame.
    var heroFrame: (example: Int, morphed: Bool)?

    var body: some View {
        VStack(spacing: 0) {
            AppIconImage(size: 76)
            Text("한영 전환 없이, 그냥 쓰세요.")
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            Text("Duo는 입력하는 단어를 보고 한국어인지 영어인지 알아서 판단해요.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HeroMorph(frozen: heroFrame)
                .padding(.top, 26)
            VStack(alignment: .leading, spacing: 8) {
                Text("직접 쳐 보세요")
                    .font(.headline)
                if let playground {
                    PlaygroundField(model: playground, placeholder: "dkssud를 쳐 보세요", height: 64)
                }
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 12)
        .onAppear {
            if playground == nil { playground = PlaygroundModel(languageModel: app.languageModel) }
        }
    }
}

extension WelcomeStep {
    #if DEBUG
    /// A step with a prepared playground, for offscreen renders.
    init(playground: PlaygroundModel, heroFrame: (example: Int, morphed: Bool)) {
        _playground = State(initialValue: playground)
        self.heroFrame = heroFrame
    }
    #endif
}
