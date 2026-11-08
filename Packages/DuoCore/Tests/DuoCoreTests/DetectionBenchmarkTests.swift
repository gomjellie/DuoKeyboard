import Foundation
import Testing
@testable import DuoCore

/// Per-keystroke scoring cost (SPEC §5 A.4, critique R15): every prefix of 32-key tokens is scored
/// from scratch in prefix mode (the display after each key) and in final mode (a commit at that
/// key), over Korean, English and mixed tokens. Run alone for clean numbers:
///
///     swift test -c release --filter DetectionBenchmark
@Suite("Detection benchmark", .serialized)
struct DetectionBenchmarkTests {
    /// Realistic long tokens, cut to the engine's 32-key cap.
    static let tokens: [(raw: String, context: LanguageContext)] = ([
        // Korean (keys of 안녕하세요감사합니다…, 그런데요즘에는…, 사랑하는마음으로…)
        ("dkssudgktpdyrkatkgkqslekwjsmsdhsmfehwlqdpdlTtmqslek", .start),
        ("rmfjsepdywmadpsmsdlfdlaksgdktjgkfwlahfmrpTdjdy", .korean),
        ("tkfkdgksmsakdmadmfhdnflrkcmfrjqrptkfdkdi", .korean),
        ("gksrmfdmfrhdqngkrhdlTsmsgkrtodlqslek", .start),
        // English
        ("internationalizationconfigurationfiles", .english),
        ("thequickbrownfoxjumpsoverthelazydog", .start),
        ("Implementationofcharacterlanguagemodels", .english),
        ("pleasereviewthepullrequestbeforemerging", .korean),
        // Mixed Latin + attached Korean
        ("PRdmfdhffuTsmsepCIrkRoWuTspdyghkrdls", .korean),
        ("iOSdptjqnfjdhsmsdkqvmfdmfdkswnTtmqslek", .korean),
        ("pushgoTdjdyghkrdlsgowntpdyrkatkgkqslek", .korean),
        ("ChatGPTgksxpanfdjqhkTejsepdkwlrdmsdkfrhdlTek", .start),
    ] as [(String, LanguageContext)]).map { (String($0.0.prefix(32)), $0.1) }

    struct Stats: CustomStringConvertible {
        var samples: [Double]  // microseconds
        var p50: Double { percentile(0.50) }
        var p99: Double { percentile(0.99) }
        var max: Double { samples.max() ?? 0 }
        func percentile(_ q: Double) -> Double {
            let s = samples.sorted()
            return s.isEmpty ? 0 : s[Swift.min(s.count - 1, Int((Double(s.count) * q).rounded(.up)) - 1)]
        }
        var description: String {
            String(format: "p50 %7.1f µs   p99 %7.1f µs   max %7.1f µs   (n = %d)", p50, p99, max, samples.count)
        }
    }

    private static func time(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
    }

    @Test func perKeystrokeCost() throws {
        let d = try DetectionFixtures.detector.get()
        try #require(Self.tokens.allSatisfy { $0.raw.count == 32 })
        // Warm the page cache and the lazily initialised tables.
        for t in Self.tokens { _ = d.finalScores(raw: t.raw, context: t.context, terminator: .space, user: nil, biasKO: 0) }

        let rounds = 5
        var prefix: [Double] = [], final: [Double] = [], both: [Double] = []
        var sink = 0
        for _ in 0..<rounds {
            for t in Self.tokens {
                for i in 1...t.raw.count {
                    let raw = String(t.raw.prefix(i))
                    let p = Self.time {
                        sink &+= d.prefixScores(raw: raw, context: t.context, user: nil, biasKO: 0).entries.count
                    }
                    let f = Self.time {
                        sink &+= d.finalScores(raw: raw, context: t.context, terminator: .space, user: nil, biasKO: 0)
                            .entries.count
                    }
                    prefix.append(p)
                    final.append(f)
                    both.append(p + f)
                }
            }
        }
        #expect(sink > 0)
        let p = Stats(samples: prefix), f = Stats(samples: final), b = Stats(samples: both)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("""
            [DetectionBenchmark] \(build), \(Self.tokens.count) tokens × 32 prefixes × \(rounds) rounds
              prefix mode (display, per key)  \(p)
              final mode  (commit, per key)   \(f)
              prefix + final (same key)       \(b)
            """)
        #if !DEBUG
        #expect(p.p99 <= 300, "prefix-mode p99 \(p.p99) µs exceeds the 300 µs budget")
        #expect(f.p99 <= 300, "final-mode p99 \(f.p99) µs exceeds the 300 µs budget")
        #endif
    }

    /// The worst case of a key while the choice bar lists the readings of the word's end (SPEC.md
    /// 4.11절): the flip key went down at the first key, so every key of the 32-key word scores the
    /// word (prefix mode, then the bar's final mode) and each end of up to 16 keys as a word of its own.
    @MainActor
    @Test func perKeyCostWithTheEndsOfTheWordOnTheBar() throws {
        let d = try DetectionFixtures.detector.get()
        let rounds = 3
        var keys: [Double] = []
        for _ in 0..<rounds {
            for t in Self.tokens {
                let h = EngineHarness(scorer: d)
                if t.context == .korean { h.type("dkssud ") } else if t.context == .english { h.type("hello ") }
                let events = KeyEvent.typing(t.raw)
                h.press(events[0])
                h.modifier(down: true)
                for event in events.dropFirst() {
                    keys.append(Self.time { h.press(event) })
                }
            }
        }
        let k = Stats(samples: keys)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("""
            [DetectionBenchmark] \(build), \(Self.tokens.count) tokens × 31 keys × \(rounds) rounds, ends on the bar
              key (engine, bar with ends)     \(k)
            """)
        #if !DEBUG
        #expect(k.p99 <= 1000, "per-key p99 \(k.p99) µs exceeds the 1 ms budget")
        #endif
    }

    /// Joining the end of a split word back to its start (SPEC.md 4.11절 14) is one key event: the
    /// joined word of 32 keys is scored and gets its bar with the readings of its end again.
    @MainActor
    @Test func costOfJoiningTheEndOfALongWordBack() throws {
        let d = try DetectionFixtures.detector.get()
        // Invented: 길어졌을때중간에 + english가서 (32 keys), 오늘회의는 + zoom으로하자고 (28 keys)
        let words = [("rlfdjwuTdmfEowndrksdpenglish", "rktj"), ("dhsmfghldmlsmszoom", "dmfhgkwkrh")]
        var joins: [Double] = []
        for _ in 0..<20 {
            for (word, more) in words {
                let h = EngineHarness(scorer: d)
                h.type(word)
                h.flip()
                try #require(h.engine.token?.segmentTail == true, "the first flip splits \(word)")
                h.type(more)
                let shown = try #require(h.hud)
                joins.append(Self.time { h.engine.selectReading(at: 0, on: shown, client: h.client) })
                try #require(h.engine.token?.count == word.count + more.count, "the end joined its start")
            }
        }
        let j = Stats(samples: joins)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("""
            [DetectionBenchmark] \(build), joins of a split word of \(words.map { $0.0.count + $0.1.count }) keys
              join (engine, bar with ends)    \(j)
            """)
        #if !DEBUG
        #expect(j.p99 <= 1000, "join p99 \(j.p99) µs exceeds the 1 ms budget")
        #endif
    }
}
