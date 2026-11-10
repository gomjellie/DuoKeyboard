import DuoCore
@testable import DuoKit
import Testing

/// The key sequence onboarding 써보기's keyboard hint plays.
@Suite("Host · typing hint")
struct HostTypingHintTests {
    /// The keys of each step as typed text: a shifted key as its uppercase letter, the flip as {flip}.
    private static func typed(_ steps: [TypingHint.Step]) -> String {
        steps.map { step -> String in
            if step.isFlip { return "{flip}" }
            let key = step.chord.first { !$0.key.hasSuffix("shift") }?.key ?? ""
            let shifted = step.chord.contains { $0.key.hasSuffix("shift") }
            return key == "space" ? " " : shifted ? key.uppercased() : key
        }.joined()
    }

    @Test("a practice sentence types through 두벌식, with Shift for capitals and ㅆ")
    func practiceSentenceKeys() {
        let steps = TypingHint.steps(typing: "안녕하세요 Duo를 써봐요")
        #expect(Self.typed(steps) == "dkssudgktpdy Duofmf Tjqhkdy")
        #expect(steps.last?.typedCount == "안녕하세요 Duo를 써봐요".count)
        #expect(Self.typed(TypingHint.steps(typing: "macOS 26 업데이트")) == "macOS 26 djqepdlxm")
    }

    @Test("a syllable counts as typed only after its last key")
    func syllableProgress() {
        let steps = TypingHint.steps(typing: "안녕")
        #expect(steps.map(\.typedCount) == [0, 0, 1, 1, 1, 2])
    }

    @Test("Shift is pressed by the other hand's little finger")
    func shiftUsesTheOtherHand() {
        #expect(TypingHint.chord(latin: "D") == [.init(key: "d", finger: .l3), .init(key: "rshift", finger: .r5)])
        #expect(TypingHint.chord(latin: "O") == [.init(key: "o", finger: .r4), .init(key: "lshift", finger: .l5)])
        #expect(TypingHint.chord(latin: "?") == [.init(key: "/", finger: .r5), .init(key: "lshift", finger: .l5)])
        #expect(TypingHint.chord(latin: "€") == nil)
    }

    @Test("every flip key is pressed by the hint", arguments: FlipKey.allCases)
    func flipKeys(flipKey: FlipKey) {
        let steps = TypingHint.steps(typing: "이건 해", thenFlip: flipKey)
        let flips = steps.filter(\.isFlip)
        #expect(flips.count == (flipKey == .doubleShift ? 2 : 1))
        #expect(Self.typed(steps.filter { !$0.isFlip }) == "dlrjs go")
        let keys = Set(flips.flatMap(\.chord).map(\.key))
        switch flipKey {
        case .rightCommand: #expect(keys == ["rcmd"])
        case .rightOption: #expect(keys == ["roption"])
        case .doubleShift: #expect(keys == ["lshift"])
        case .shiftSpace: #expect(keys == ["lshift", "space"])
        case .capsLock: #expect(keys == ["caps"])
        }
    }

    @Test("the timeline presses one step at a time and shows progress as keys go down")
    func timeline() {
        let timeline = TypingHint.Timeline(steps: TypingHint.steps(typing: "이건 해", thenFlip: .rightCommand))
        for (a, b) in zip(timeline.events, timeline.events.dropFirst()) {
            #expect(a.start < a.down && a.down < a.up && a.up <= b.start)
        }
        #expect(timeline.duration > timeline.events.last!.up)
        #expect(timeline.progress(at: 0).typed == 0)
        let flip = timeline.events.last!
        let before = timeline.progress(at: flip.down - 0.01)
        #expect(before.typed == 4 && !before.flipped)
        let after = timeline.progress(at: flip.down)
        #expect(after.typed == 4 && after.flipped)
        #expect(timeline.stepDown(at: flip.down) == timeline.steps.count - 1)
        #expect(timeline.loopTime(timeline.duration + 0.5) == 0.5)
    }
}
