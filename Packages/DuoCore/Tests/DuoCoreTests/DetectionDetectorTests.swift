import Foundation
import Testing
@testable import DuoCore

/// Runtime behaviour beyond the golden vectors: bias, user bonus in prefix mode, the eager-E
/// re-open gate, rendering, hysteresis, robustness and the `cond` memo.
@Suite("Detection detector")
struct DetectionDetectorTests {
    private var detector: DuoDetector { get throws { try DetectionFixtures.detector.get() } }

    // MARK: biasKO (critique R8)

    @Test(arguments: ["go", "dkssud", "PRdmf", "pushgoTdjdy", "don't"], [-1500, -1000, 0, 1000, 1500])
    func biasShiftsOnlyKorean(_ raw: String, _ bias: Int) throws {
        let d = try detector
        for ctx in LanguageContext.allCases {
            let base = d.finalScores(raw: raw, context: ctx, terminator: .space, user: nil, biasKO: 0)
            let biased = d.finalScores(raw: raw, context: ctx, terminator: .space, user: nil, biasKO: bias)
            #expect(biased.entries.map(\.hypothesis) == base.entries.map(\.hypothesis))
            for (b, e) in zip(biased.entries, base.entries) {
                #expect(b.score == e.score + (b.hypothesis == .korean ? bias : 0))
            }
            let basePrefix = d.prefixScores(raw: raw, context: ctx, user: nil, biasKO: 0)
            let biasedPrefix = d.prefixScores(raw: raw, context: ctx, user: nil, biasKO: bias)
            for (b, e) in zip(biasedPrefix.entries, basePrefix.entries) {
                #expect(b.score == e.score + (b.hypothesis == .korean ? bias : 0))
            }
        }
    }

    // MARK: User bonus in both modes (critique R7)

    @Test func userBonusAppliesInPrefixMode() throws {
        let d = try detector
        // detector.py hyp_scores(features("go", final=False), "KO", final=False, user={"E": 3})
        let counts = UserCounts([.english: 3])
        let plain = d.prefixScores(raw: "go", context: .korean, user: nil, biasKO: 0)
        let learned = d.prefixScores(raw: "go", context: .korean, user: counts, biasKO: 0)
        #expect(plain.vectorDictionary == ["K": -4680, "E": -9530])
        #expect(learned.vectorDictionary == ["K": -4680, "E": -4530])
        #expect(learned.best?.hypothesis == .english)
    }

    @Test(arguments: ["go", "PRdmf", "pushgoTdjdy", "rk"])
    func userBonusIsAdditivePerHypothesis(_ raw: String) throws {
        let d = try detector
        let plain = d.prefixScores(raw: raw, context: .start, user: nil, biasKO: 0)
        var counts: [Hypothesis: Int] = [:]
        for (i, e) in plain.entries.enumerated() { counts[e.hypothesis] = i * 2 + 1 }
        let user = UserCounts(counts)
        for mode in [true, false] {
            let a = mode ? d.finalScores(raw: raw, context: .start, terminator: .space, user: nil, biasKO: 0)
                : plain
            let b = mode ? d.finalScores(raw: raw, context: .start, terminator: .space, user: user, biasKO: 0)
                : d.prefixScores(raw: raw, context: .start, user: user, biasKO: 0)
            for (x, y) in zip(b.entries, a.entries) {
                #expect(x.score == y.score + d.userBonus(count: user[x.hypothesis]))
            }
        }
        #expect(d.prefixScores(raw: raw, context: .start, user: UserCounts(), biasKO: 0) == plain)
    }

    // MARK: Eager-E re-open gate (critique R1.2)

    /// Expected values from the contract rule evaluated with the Python reader of the same file.
    @Test(arguments: [
        ("PRd", 2, true), ("pushg", 4, true), ("pushk", 4, false), ("xqzvd", 4, true), ("mergeg", 5, true),
        ("iOSd", 3, true), ("githubd", 6, true), ("qwxzd", 4, true), ("helloS", 5, true), ("Hellod", 5, true),
        ("dont'd", 5, false), ("PR", 2, false), ("PRd", 0, false), ("thed", 3, true), ("kkkkr", 4, true),
    ])
    func canAttachKorean(_ raw: String, _ latinCount: Int, _ expected: Bool) throws {
        #expect(try detector.canAttachKorean(raw: raw, latinCount: latinCount) == expected)
    }

    @Test func canAttachKoreanNeedsAConsonantKey() throws {
        let d = try detector
        for key in "yuiophjklbnm" { #expect(!d.canAttachKorean(raw: "PR\(key)", latinCount: 2), "\(key)") }
        for key in "qwertasdfgzxcvQWERT" { #expect(d.canAttachKorean(raw: "PR\(key)", latinCount: 2), "\(key)") }
        #expect(!d.canAttachKorean(raw: "PRO", latinCount: 2))  // ㅒ
    }

    // MARK: Rendering (DET §5.6)

    @Test func render() throws {
        let d = try detector
        #expect(d.render(raw: "PRdmf", .korean) == "ㅖㄲ을")
        #expect(d.render(raw: "PRdmf", .english) == "PRdmf")
        #expect(d.render(raw: "PRdmf", .mixed(latin: 2)) == "PR을")
        #expect(d.render(raw: "pushgoTdjdy", .mixed(latin: 4)) == "push했어요")
        #expect(d.render(raw: "dLTek", .korean) == "있다")  // Shift on L is dropped by normalisation
        #expect(d.render(raw: "don't", .korean) == "애ㅜ'ㅅ")
        #expect(d.render(raw: "rk", .mixed(latin: 9)) == "rk")  // out-of-range b clamps
        #expect(d.render(raw: "", .korean) == "")
    }

    @Test func apostropheRule() throws {
        let d = try detector
        #expect(d.apostropheIsInternal(after: "don", context: .start))
        #expect(!d.apostropheIsInternal(after: "tkfkd", context: .korean))
    }

    // MARK: Hysteresis (DET §5.6)

    @Test func hysteresisRule() {
        func scores(_ k: Int, _ e: Int, _ m: Int? = nil) -> HypothesisScores {
            HypothesisScores([ScoredHypothesis(.korean, k), ScoredHypothesis(.english, e)]
                             + (m.map { [ScoredHypothesis(.mixed(latin: 2), $0)] } ?? []))
        }
        #expect(DisplayHysteresis.initialHypothesis(for: .english) == .english)
        for ctx in [LanguageContext.start, .korean, .number] {
            #expect(DisplayHysteresis.initialHypothesis(for: ctx) == .korean)
        }
        // Strictly more than HYST is needed to switch.
        #expect(DisplayHysteresis.next(shown: .korean, scores: scores(0, 1500), hysteresis: 1500) == .korean)
        #expect(DisplayHysteresis.next(shown: .korean, scores: scores(0, 1501), hysteresis: 1500) == .english)
        #expect(DisplayHysteresis.next(shown: .english, scores: scores(0, -1), hysteresis: 1500) == .english)
        // A shown M(b) that no longer exists falls back to the best.
        #expect(DisplayHysteresis.next(shown: .mixed(latin: 3), scores: scores(-5, -9, -1), hysteresis: 1500)
                == .mixed(latin: 2))
        // Ties go to the earlier candidate.
        #expect(DisplayHysteresis.next(shown: .mixed(latin: 3), scores: scores(-5, -5), hysteresis: 1500) == .korean)
    }

    // MARK: Robustness

    @Test func emptyToken() throws {
        let d = try detector
        // detector.py on "": final K −19929 / E −21339; prefix K −200 / E −1000.
        #expect(d.finalScores(raw: "", context: .start, terminator: .space, user: nil, biasKO: 0).vectorDictionary
                == ["K": -19929, "E": -21339])
        #expect(d.prefixScores(raw: "", context: .start, user: nil, biasKO: 0).vectorDictionary
                == ["K": -200, "E": -1000])
        #expect(d.displayTrace(raw: "", context: .start).isEmpty)
    }

    /// Long tokens (beyond the engine's 32-key cap) against `detector.py`, including one long
    /// enough to fill the `cond` memo so it stops memoising.
    @Test(arguments: [
        ("long", "dkssudgktpdyrkatkgkqslekwjsmsdhsmfehwlqdpdlTtmqslek" + "dkssudgktpdyrkatkgkqslekwjsmsdhsmfehwlqdpdlTtmqslek"),
        ("mixedlong", "PRdmfdhffuTsmsepCIrkRoWuTspdyghkrdlsgowntpdyrkatkgkqslekpushgoTdjdy"),
        ("huge", String(String(repeating: "PRdmfdhffuTsmsepCIrkRoWuTspdyghkrdlsgowntpdyrkatkgkqslekpushgoTdjdy",
                               count: 5).prefix(300))),
    ])
    func longTokensMatchReference(_ name: String, _ raw: String) throws {
        let d = try detector
        let expected = try #require(Self.longReference["\(name)/final"])
        let expectedPrefix = try #require(Self.longReference["\(name)/prefix"])
        #expect(d.finalScores(raw: raw, context: .korean, terminator: .space, user: nil, biasKO: 0).vectorDictionary
                == expected)
        #expect(d.prefixScores(raw: raw, context: .korean, user: nil, biasKO: 0).vectorDictionary == expectedPrefix)
    }

    @Test(arguments: ["abc1", "가나", "😀", "a-b", "e\u{301}", "  ", "'", "''", "A'B"])
    func charactersOutsideTheAlphabetDoNotCrash(_ raw: String) throws {
        let d = try detector
        let f = d.finalScores(raw: raw, context: .start, terminator: .space, user: nil, biasKO: 0)
        let p = d.prefixScores(raw: raw, context: .start, user: nil, biasKO: 0)
        #expect(f.entries.count == 2, "a non-letter disables M(b)")
        #expect(p.entries.count == 2)
        _ = d.render(raw: raw, f.best!.hypothesis)
        _ = d.canAttachKorean(raw: raw, latinCount: 1)
    }

    @Test func concurrentScoringIsDeterministic() async throws {
        let d = try detector
        let tokens = DetectionBenchmarkTests.tokens.map(\.raw)
        let expected = tokens.map { d.prefixScores(raw: $0, context: .korean, user: nil, biasKO: 0) }
        let results = await withTaskGroup(of: [HypothesisScores].self) { group in
            for _ in 0..<8 {
                group.addTask { tokens.map { d.prefixScores(raw: $0, context: .korean, user: nil, biasKO: 0) } }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == expected })
    }

    // MARK: cond memo

    @Test func memoMatchesDirectCondEvenWhenFull() throws {
        let lm = try detector.model.korean
        CondCache.with(tokenLength: 1) { cache in  // 64 slots: fills after 48 inserts
            for round in 0..<2 {
                for a in UInt8(3)...UInt8(36) {
                    for w in [UInt8(2), 6, 13, 36] {
                        var h = CharacterLM.History(contextLength: lm.contextLength)
                        h.append(a, contextLength: lm.contextLength)
                        if round == 1 { h.append(w, contextLength: lm.contextLength) }
                        #expect(lm.cond(h, w, cache: &cache) == lm.cond(h, w))
                    }
                }
            }
        }
    }

    /// `detector.py` scores (ctx KO) for the long tokens above.
    static let longReference: [String: [String: Int]] = [
        "long/final": ["K": -243244, "E": -491561, "M44": -380993, "M47": -394315, "M49": -386365,
                       "M51": -380626, "M54": -404663, "M57": -408736, "M59": -423116, "M61": -417852,
                       "M63": -413170, "M66": -422544, "M68": -439143, "M71": -461803, "M73": -451587,
                       "M75": -445011, "M77": -456782, "M80": -449838, "M82": -464578, "M85": -459884,
                       "M87": -458124, "M90": -467508, "M92": -467218, "M95": -489464, "M98": -502786,
                       "M100": -496200],
        "long/prefix": ["K": -240229, "E": -490138, "M44": -380978, "M47": -394300, "M49": -386350,
                        "M51": -380611, "M54": -404648, "M57": -408721, "M59": -423101, "M61": -417837,
                        "M63": -413155, "M66": -422529, "M68": -439128, "M71": -461788, "M73": -451572,
                        "M75": -444996, "M77": -456767, "M80": -449823, "M82": -464563, "M85": -459869,
                        "M87": -458109, "M90": -467493, "M92": -467218, "M95": -489449, "M98": -502771,
                        "M100": -495769],
        "mixedlong/final": ["K": -239540, "E": -372708, "M58": -352620, "M60": -340067, "M63": -375310,
                            "M65": -376791],
        "mixedlong/prefix": ["K": -236538, "E": -370418, "M58": -352618, "M60": -340067, "M63": -375308,
                             "M65": -375558],
        "huge/final": ["K": -1088619, "E": -1579250, "M270": -1545874, "M273": -1542554, "M276": -1560163,
                       "M279": -1572675, "M282": -1578680, "M284": -1586394, "M286": -1571729, "M288": -1578070,
                       "M290": -1579608, "M293": -1585694, "M295": -1588523, "M297": -1580714],
        "huge/prefix": ["K": -1080789, "E": -1577859, "M270": -1541044, "M273": -1537724, "M276": -1555333,
                        "M279": -1567845, "M282": -1573850, "M284": -1581564, "M286": -1566899, "M288": -1573240,
                        "M290": -1574778, "M293": -1580864, "M295": -1583693, "M297": -1579178]
    ]
}
