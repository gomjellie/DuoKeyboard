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
}
