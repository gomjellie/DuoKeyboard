import Foundation
import Testing
@testable import DuoCore

/// Types real sentences through the engine with the shipped model and writes what came out
/// (`Tools/scripts/corpus-typing.sh`). Runs only when `DUO_CORPUS_IN` names a corpus TSV
/// (`source<TAB>id<TAB>text`); `DUO_CORPUS_OUT` receives
/// `source<TAB>id<TAB>reachable<TAB>correct<TAB>expected<TAB>produced<TAB>keys` per sentence.
/// `DUO_CORPUS_APP` types into that app's client profile (bundle identifier; TextEdit when unset).
@MainActor
@Suite("Corpus typing (real model)",
       .enabled(if: RealModel.isAvailable && ProcessInfo.processInfo.environment["DUO_CORPUS_IN"] != nil))
struct CorpusTypingTests {
    /// The ABC-layout keys a 두벌식 typist presses for `text`: Hangul through the layout, the rest as is.
    static func keys(for text: String) -> String? {
        var out = ""
        for ch in text {
            if Jamo.isHangul(ch) {
                guard let keys = DubeolsikLayout.keystrokes(forHangul: String(ch)) else { return nil }
                out += keys.latinString
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Whether plain 두벌식 typing of each Hangul run gives that run back. A jamo that joins the
    /// syllable before it (하ㅋ types as 핰) cannot be typed without a break, so the sentence is left out
    /// of the accuracy.
    static func reachable(_ text: String) -> Bool {
        var run = ""
        func ok() -> Bool {
            defer { run = "" }
            guard !run.isEmpty, let keys = keys(for: run) else { return true }
            return HangulAutomaton.hangul(fromLatin: keys) == run
        }
        for ch in text {
            if Jamo.isHangul(ch) { run.append(ch) } else if !ok() { return false }
        }
        return ok()
    }

    @Test func typeCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        let lines = try String(contentsOfFile: env["DUO_CORPUS_IN"]!, encoding: .utf8).split(separator: "\n")
        let limit = Int(env["DUO_CORPUS_LIMIT"] ?? "") ?? lines.count
        let app = env["DUO_CORPUS_APP"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.apple.TextEdit"
        var out = ""
        for line in lines.prefix(limit) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let keys = Self.keys(for: parts[2]) else { continue }
            // A fresh engine per sentence: no learning carries over from one sentence to the next.
            let h = EngineHarness(bundleIdentifier: app, scorer: RealModel.detector)
            h.type(keys + " ")
            let expected = parts[2] + " "
            out += [parts[0], parts[1], Self.reachable(parts[2]) ? "1" : "0", h.text == expected ? "1" : "0",
                    expected, h.text, keys].joined(separator: "\t") + "\n"
        }
        let path = try #require(env["DUO_CORPUS_OUT"], "DUO_CORPUS_OUT names the output TSV")
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
