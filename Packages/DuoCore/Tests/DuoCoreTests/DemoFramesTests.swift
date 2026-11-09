import Foundation
import Testing
@testable import DuoCore

/// Writes the frames the download page's typing demo plays (`Tools/dist/demo-frames.json`): after
/// each key, what Duo shows and what plain 두벌식 typing would show. Runs only when
/// `DUO_DEMO_FRAMES_OUT` names the output file, e.g.
/// `cd Packages/DuoCore && DUO_DEMO_FRAMES_OUT=$PWD/../../Tools/dist/demo-frames.json swift test --filter DemoFrames`
@MainActor
@Suite("Demo frames (real model)",
       .enabled(if: RealModel.isAvailable && ProcessInfo.processInfo.environment["DUO_DEMO_FRAMES_OUT"] != nil))
struct DemoFramesTests {
    struct Scene {
        var id: String
        /// Key tokens: one character each, or `{rcmd}` for a right ⌘ tap.
        var tokens: [String]
        /// What Duo must have typed after the last token.
        var expected: String
    }

    static func tokens(_ text: String) throws -> [String] {
        try #require(CorpusTypingTests.keys(for: text)).map(String.init)
    }

    static func scenes() throws -> [Scene] {
        [
            Scene(id: "mix", tokens: try tokens("내일 meeting 몇 시야?"), expected: "내일 meeting 몇 시야?"),
            Scene(id: "dev", tokens: try tokens("오늘 PR을 올렸는데 CI가 깨졌네요."),
                  expected: "오늘 PR을 올렸는데 CI가 깨졌네요."),
            // Duo reads go as 해 after a Korean word; the right ⌘ tap picks the English reading.
            Scene(id: "flip", tokens: try tokens("배포 go") + ["{rcmd}"] + tokens(" 할까요?"),
                  expected: "배포 go 할까요?"),
        ]
    }

    /// Plain 두벌식 typing: every run of letters through the automaton, the rest as typed. The last
    /// syllable of an unfinished run is the marked text.
    static func plainKorean(_ tokens: [String]) -> (text: String, marked: String) {
        var text = ""
        var run: [Keystroke] = []
        for token in tokens where token.count == 1 {
            let c = Character(token)
            if let key = Keystroke(latin: c) {
                run.append(key)
            } else {
                text += HangulAutomaton.compose(run).text
                run = []
                text.append(c)
            }
        }
        let blocks = HangulAutomaton.compose(run).blocks
        return (text + blocks.dropLast().map(\.text).joined(), blocks.last?.text ?? "")
    }

    static func hud(_ request: HUDRequest?) -> [String: Any]? {
        guard let request, case .alternative(let choice, eligible: true) = request.content else { return nil }
        return ["selected": choice.selected,
                "readings": choice.readings.map { ["text": $0.text, "lang": $0.language == .english ? "en" : "ko"] }]
    }

    @Test func writeFrames() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DUO_DEMO_FRAMES_OUT"])
        var scenes: [[String: Any]] = []
        for scene in try Self.scenes() {
            var frames: [[String: Any]] = []
            for end in 1...scene.tokens.count {
                // A fresh engine per prefix: a flip replayed on the same engine would be learned.
                let mirror = try #require(HarnessMirror())
                let duo = mirror.run(scene.tokens[0..<end].joined())
                let plain = Self.plainKorean(Array(scene.tokens[0..<end]))
                var frame: [String: Any] = ["duo": String(duo.text.dropLast(duo.marked.count)), "duoMarked": duo.marked,
                                            "ko": plain.text, "koMarked": plain.marked]
                if let hud = Self.hud(mirror.engine.hud) { frame["hud"] = hud }
                frames.append(frame)
            }
            let last = try #require(frames.last)
            #expect("\(last["duo"]!)\(last["duoMarked"]!)" == scene.expected, "\(scene.id) ends as intended")
            scenes.append(["id": scene.id, "tokens": scene.tokens, "frames": frames])
        }
        let data = try JSONSerialization.data(withJSONObject: scenes, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
