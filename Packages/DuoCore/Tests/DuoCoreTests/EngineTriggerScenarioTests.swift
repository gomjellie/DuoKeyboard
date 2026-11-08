// SPEC.md 4.6절: the symbols that used to start the literal phase, run with the REAL detector and the
// shipped model in the three profiles that decide them differently: Automatic (TextEdit), English
// first (Orca, an xterm.js terminal that cannot replace committed text) and Korean first (KakaoTalk).
// `⌘` in the keys taps the flip key.

import Foundation
import Testing
@testable import DuoCore

@MainActor
@Suite("Engine · trigger symbols (real model)", .enabled(if: RealModel.isAvailable, "needs the real DuoDetector port"))
struct EngineTriggerScenarioTests {
    enum App: String, Sendable, CaseIterable {
        case textEdit = "com.apple.TextEdit"
        case orca = "com.stablyai.orca"
        case kakao = "com.kakao.KakaoTalkMac"
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var app: App
        var prime: EngineScenarioTests.Prime
        var keys: String
        var expected: String

        var testDescription: String { "\(app) \(prime) \(keys.debugDescription) → \(expected.debugDescription)" }
    }

    /// The same outcome in every profile.
    nonisolated static func all(_ prime: EngineScenarioTests.Prime, _ keys: String, _ expected: String) -> [Row] {
        App.allCases.map { Row(app: $0, prime: prime, keys: keys, expected: expected) }
    }

    nonisolated static func only(_ app: App, _ prime: EngineScenarioTests.Prime, _ keys: String, _ expected: String) -> [Row] {
        [Row(app: app, prime: prime, keys: keys, expected: expected)]
    }

    /// `_` ends a word like other punctuation (SPEC.md 4.6절).
    nonisolated static let underscore: [Row] = [
        // snake_case and SCREAMING_CASE: the pieces after an English piece read English
        all(.start, "user_id ", "user_id "),
        all(.korean, "user_id ", "user_id "),
        all(.english, "user_id ", "user_id "),
        all(.korean, "max_len ", "max_len "),
        all(.korean, "get_value ", "get_value "),
        all(.korean, "is_ok ", "is_ok "),
        all(.korean, "MAX_VALUE ", "MAX_VALUE "),
        all(.start, "__init__ ", "__init__ "),
        all(.korean, "cmp_to_key ", "cmp_to_key "),
        all(.korean, "get_valuefmf ", "get_value를 "),
        all(.start, "a_b ", "a_b "),
        all(.korean, "node_modules ", "node_modules "),
        all(.korean, "IMG_1234.jpg ", "IMG_1234.jpg "),
        all(.korean, "user_id@example.com ", "user_id@example.com "),
        // Korean file names
        all(.start, "qhrhtj_chlwhd.hwp ", "보고서_최종.hwp "),
        all(.english, "qhrhtj_chlwhd.hwp ", "보고서_최종.hwp "),
        all(.start, "tkwls_2024.jpg ", "사진_2024.jpg "),
        all(.start, "rlghlrdks_chlwhd_v3.docx ", "기획안_최종_v3.docx "),
        all(.korean, "test_dkssud ", "test_안녕 "),
        all(.start, "KakaoTalk_Chat_ghdrlfehd ahdla_2026-11-08-23-18-29.csv ",
            "KakaoTalk_Chat_홍길동 모임_2026-11-08-23-18-29.csv "),
        all(.start, "KakaoTalk_Chat_tjdnfeo dusrnghl_2026-11-08-23-18-29.csv ",
            "KakaoTalk_Chat_서울대 연구회_2026-11-08-23-18-29.csv "),
        // Emoticons
        all(.korean, "b_b ", "ㅠ_ㅠ "),
        all(.korean, "n_n ", "ㅜ_ㅜ "),
        all(.korean, "z_z ", "ㅋ_ㅋ "),
        only(.textEdit, .start, "b_b ", "ㅠ_ㅠ "),
        only(.kakao, .start, "b_b ", "ㅠ_ㅠ "),
        only(.orca, .start, "b_b ", "ㅠ_ㅠ "),
        all(.english, "b_b ", "b_b "),
        all(.start, "b⌘_b⌘ ", "ㅠ_ㅠ "),
        all(.korean, "T_T ", "T_T "),
        all(.korean, "-_- ", "-_- "),
        // A short word that reads Korean after Korean (go 해) reads so before `_` too: the flip
        // before `_` fixes it everywhere, the flip right after `_` where committed text can change.
        all(.korean, "go_back ", "해_back "),
        all(.korean, "go⌘_back ", "go_back "),
        only(.textEdit, .korean, "go_⌘back ", "go_back "),
        only(.kakao, .korean, "go_⌘back ", "go_back "),
        only(.orca, .korean, "go_⌘back ", "해_back "),
    ].flatMap { $0 }

    /// Types the prime, then the keys; returns the harness and the text the keys produced.
    /// `@` at a word start passes and the name after it composes; `@` in a word is an e-mail address.
    nonisolated static let at: [Row] = [
        // Korean names (KakaoTalk, Slack mentions), with a particle too
        all(.start, "@ghdrlfehd ", "@홍길동 "),
        all(.korean, "@ghdrlfehd ", "@홍길동 "),
        all(.english, "@ghdrlfehd ", "@홍길동 "),
        all(.start, "@rlacjftn tkfkd ", "@김철수 사랑 "),
        all(.korean, "@ghdrlfehdsla ", "@홍길동님 "),
        all(.korean, "@rlacjftnrk ", "@김철수가 "),
        all(.korean, "@dudgml ", "@영희 "),
        // Code and handles
        all(.start, "@Override ", "@Override "),
        all(.korean, "@param ", "@param "),
        all(.start, "@types/node ", "@types/node "),
        all(.korean, "@MainActor ", "@MainActor "),
        all(.korean, "@user123 ", "@user123 "),
        all(.korean, "@here ", "@here "),
        all(.start, "@minsu ", "@minsu "),
        // E-mail addresses keep the literal rule
        all(.korean, "user@example.com ", "user@example.com "),
        all(.korean, "dkssud@example.com ", "dkssud@example.com "),
    ].flatMap { $0 }

    /// Only `~/` is a path; `~` before anything else is punctuation.
    nonisolated static let tilde: [Row] = [
        all(.start, "~gkwk ", "~하자 "),
        all(.english, "~gkwk ", "~하자 "),
        all(.korean, "~sk ", "~나 "),
        all(.korean, "~~rkdwh~~ ", "~~강조~~ "),
        all(.korean, "\"~dmf\" ", "\"~을\" "),
        all(.korean, "~5cjs ", "~5천 "),
        all(.korean, "10~20ro ", "10~20개 "),
        all(.korean, "~test ", "~test "),
        all(.start, "~/Library ", "~/Library "),
        all(.korean, "cd ~/Projects/duo ", "cd ~/Projects/duo "),
        all(.start, "ls ~/.ssh ", "ls ~/.ssh "),
    ].flatMap { $0 }

    static func run(_ row: Row) -> (EngineHarness, String) {
        let h = EngineHarness(bundleIdentifier: row.app.rawValue, scorer: RealModel.detector)
        h.type(row.prime.rawValue)
        let before = h.text
        var chunk = ""
        for ch in row.keys {
            if ch == "⌘" {
                h.type(chunk)
                chunk = ""
                h.flip()
            } else {
                chunk.append(ch)
            }
        }
        h.type(chunk)
        #expect(h.text.hasPrefix(before))
        return (h, String(h.text.dropFirst(before.count)))
    }

    @Test(arguments: underscore)
    func underscoreRow(_ row: Row) {
        let (h, produced) = Self.run(row)
        #expect(produced == row.expected)
        #expect(!h.engine.literal)
    }

    @Test(arguments: at)
    func atRow(_ row: Row) {
        let (h, produced) = Self.run(row)
        #expect(produced == row.expected)
        #expect(!h.engine.literal)
    }

    @Test(arguments: tilde)
    func tildeRow(_ row: Row) {
        let (h, produced) = Self.run(row)
        #expect(produced == row.expected)
        #expect(!h.engine.literal)
    }
}
