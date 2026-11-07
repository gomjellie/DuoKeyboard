import DuoCore
import SwiftUI

/// The welcome hero: keys are typed one by one, then morph into what Duo writes —
/// `dkssud` → 안녕, then `hello` → hello. The core idea in four seconds.
struct HeroMorph: View {
    struct Example: Equatable {
        var keys: String
        var result: String
        var language: ScriptLanguage
    }

    static let examples = [
        Example(keys: "dkssud", result: "안녕", language: .korean),
        Example(keys: "hello", result: "hello", language: .english),
    ]

    /// Freeze on one frame (offscreen renders): example index and whether it has morphed.
    var frozen: (example: Int, morphed: Bool)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var typed = 0
    @State private var morphed = false

    var body: some View {
        Group {
            if reduceMotion && frozen == nil {
                staticPairs
            } else {
                animated
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .duoGlass(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("dkssud를 치면 안녕, hello를 치면 hello가 돼요."))
    }

    private var example: Example { Self.examples[frozen?.example ?? index] }
    private var isMorphed: Bool { frozen?.morphed ?? morphed }
    private var typedCount: Int { frozen.map { _ in example.keys.count } ?? typed }

    private var animated: some View {
        VStack(spacing: 12) {
            Text(verbatim: isMorphed ? example.result : String(example.keys.prefix(typedCount)))
                .font(.system(size: 50, weight: isMorphed ? .bold : .medium, design: .rounded))
                .foregroundStyle(isMorphed ? AnyShapeStyle(DuoStyle.color(for: example.language).gradient)
                                           : AnyShapeStyle(.secondary))
                .contentTransition(.interpolate)
                .frame(height: 60)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(Array(example.keys.enumerated()), id: \.offset) { i, key in
                        KeyCaps(caps: [String(key).uppercased()], size: 11)
                            .opacity(i < typedCount ? 1 : 0.35)
                    }
                }
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                LanguageBadge(language: example.language, size: 18)
                    .opacity(isMorphed ? 1 : 0.35)
                    .scaleEffect(isMorphed ? 1 : 0.85)
            }
        }
        .task(id: frozen == nil) {
            guard frozen == nil else { return }
            await loop()
        }
    }

    private var staticPairs: some View {
        HStack(spacing: 36) {
            ForEach(Self.examples, id: \.keys) { example in
                HStack(spacing: 10) {
                    Text(verbatim: example.keys).font(.system(size: 26, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(verbatim: example.result).font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(DuoStyle.color(for: example.language))
                }
            }
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            for i in Self.examples.indices {
                withAnimation(.easeOut(duration: 0.2)) {
                    index = i
                    typed = 0
                    morphed = false
                }
                try? await Task.sleep(for: .milliseconds(450))
                for n in 1...Self.examples[i].keys.count {
                    try? await Task.sleep(for: .milliseconds(115))
                    typed = n
                }
                try? await Task.sleep(for: .milliseconds(380))
                withAnimation(.spring(duration: 0.6, bounce: 0.2)) { morphed = true }
                try? await Task.sleep(for: .seconds(1.8))
                if Task.isCancelled { return }
            }
        }
    }
}
