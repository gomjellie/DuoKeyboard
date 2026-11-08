import Foundation
import Testing
@testable import DuoCore

/// Bit-exact checks against `test_vectors.json` (docs/research/detection.md §8): exact `Int`
/// equality everywhere, no tolerance.
@Suite("Detection golden vectors")
struct DetectionVectorTests {
    private var detector: DuoDetector { get throws { try DetectionFixtures.detector.get() } }

    @Test func vectorsLoad() throws {
        let v = try DetectionFixtures.loadedVectors.get()
        #expect(v.automaton.count == 696)
        #expect(v.fnv1a64.count == 8)
        #expect(v.lexicon.count == 28)
        #expect(v.lm.count == 44)
        #expect(v.final.count == 1101)
        #expect(v.incremental.count == 663)
        #expect(v.apostrophe.count == 63)
        #expect(v.user.count == 7)
        #expect(v.userBonus.count == 20)
    }

    @Test func modelContentHash() throws {
        let d = try detector
        #expect(d.contentHash == "6610e67e1ca8e3e3")
        #expect(d.contentHash == DetectionFixtures.vectors.modelContentHash)
        // The header is truthful: FNV-1a-64 over every byte after the directory.
        #expect(DuoDetector.hex(d.model.computeContentHash()) == "6610e67e1ca8e3e3")
    }

    @Test func parametersMatchVectors() throws {
        #expect(try detector.parameters == DetectionFixtures.vectors.params)
    }

    // MARK: Automaton (DET §3)

    @Test(arguments: DetectionFixtures.vectors.automaton)
    func automaton(_ v: DetectionVectors.Automaton) {
        #expect(HangulAutomaton.koreanNormalize(v.keys) == v.normalized)
        let r = HangulAutomaton.render(raw: v.keys)
        #expect(r.text == v.text)
        #expect(r.orphans == v.orphans)
        #expect(r.trailingLoneConsonant == v.trailingLoneConsonant)
        #expect(r.keyCounts.count == r.text.count)
        #expect(r.keyCounts.reduce(0, +) == v.keys.count)
        // The scorer's allocation-free counter agrees with the renderer.
        let stats = Array(v.keys.utf8).withUnsafeBufferPointer(DubeolsikMachine.orphanStats)
        #expect(stats.orphans == v.orphans)
        #expect(stats.lone == v.trailingLoneConsonant)
    }

    // MARK: Hashing and lexicons (DET §7.2)

    @Test(arguments: DetectionFixtures.vectors.fnv1a64)
    func fnv1a64(_ v: DetectionVectors.Hash) {
        #expect(DuoDetector.hex(FNV1a64.hash(v.s)) == v.hash)
    }

    @Test(arguments: DetectionFixtures.vectors.lexicon)
    func lexicon(_ v: DetectionVectors.Lexicon) throws {
        let model = try detector.model
        let lexicon = try #require(v.lang == "ko" ? model.koreanLexicon : v.lang == "en" ? model.englishLexicon : nil)
        #expect(lexicon.value(hash: FNV1a64.hash(v.key)) == v.value)
    }

    // MARK: Language models (DET §5.2)

    @Test(arguments: DetectionFixtures.vectors.lm)
    func languageModel(_ v: DetectionVectors.LM) throws {
        let model = try detector.model
        let lm = try #require(v.model == "ko" ? model.korean : v.model == "en" ? model.english : nil)
        let symbols = v.keys.utf8.map { KeySymbols.symbolForByte[Int($0)] }
        let (prefix, withEos) = lm.prefixScores(symbols)
        #expect(prefix == v.prefix)
        #expect(withEos == v.withEos)
        // `score` agrees with the cumulative pass.
        symbols.withUnsafeBufferPointer { s in
            #expect(lm.score(s, eos: false) == v.prefix.last)
            #expect(lm.score(s, eos: true) == v.withEos.last)
        }
    }

    // MARK: Final mode (DET §5.4)

    @Test(arguments: DetectionFixtures.vectors.final)
    func finalDecision(_ v: DetectionVectors.Final) throws {
        let d = try detector
        for c in v.cases {
            let ctx = try LanguageContext(vector: c.ctx)
            let term = try #require(Terminator(rawValue: c.term))
            let scores = d.finalScores(raw: v.raw, context: ctx, terminator: term, user: nil, biasKO: 0)
            #expect(scores.vectorDictionary == c.scores, "\(c.ctx)/\(c.term)")
            #expect(scores.isInCandidateOrder)
            let best = try #require(scores.best)
            #expect(best.hypothesis.key == c.best, "\(c.ctx)/\(c.term)")
            #expect(d.render(raw: v.raw, best.hypothesis) == c.output, "\(c.ctx)/\(c.term)")
        }
    }

    @Test(arguments: DetectionFixtures.vectors.final)
    func finalFeatures(_ v: DetectionVectors.Final) throws {
        let f = try detector.features(raw: v.raw, mode: .final)
        let e = v.features
        #expect(f.koLM == e.koLm)
        #expect(f.koLex == e.koLex)
        #expect(f.koOrphans == e.koOrphans)
        #expect(f.koRollover == e.koRollover)
        #expect(f.koStray == e.koStray)
        #expect(f.enLM == e.enLm)
        #expect(f.enLex == e.enLex)
        #expect(f.enCase.rawValue == e.enCase)
        #expect(f.enNumUnit == e.enNumUnit)
        #expect(f.mix.map(\.latin) == e.mix.map(\.b))
        for (a, b) in zip(f.mix, e.mix) {
            #expect(a.enLM == b.enLm, "M\(b.b)")
            #expect(a.enLex == b.enLex, "M\(b.b)")
            #expect(a.enCase.rawValue == b.enCase, "M\(b.b)")
            #expect(a.suffix == b.suffix, "M\(b.b)")
            #expect(a.generic == b.generic, "M\(b.b)")
            #expect(a.rollover == b.rollover, "M\(b.b)")
            #expect(a.stray == b.stray, "M\(b.b)")
            #expect(a.shortOK == b.shortOk, "M\(b.b)")
        }
    }

    // MARK: Prefix mode + display (DET §5.6)

    @Test(arguments: DetectionFixtures.vectors.incremental)
    func incremental(_ v: DetectionVectors.Incremental) throws {
        let d = try detector
        let ctx = try LanguageContext(vector: v.ctx)
        let trace = d.displayTrace(raw: v.raw, context: ctx)
        try #require(trace.count == v.steps.count)
        for (i, (got, want)) in zip(trace, v.steps).enumerated() {
            #expect(got.scores.vectorDictionary == want.scores, "step \(i + 1)")
            #expect(got.scores.isInCandidateOrder)
            #expect(got.shown.key == want.shown, "step \(i + 1)")
            #expect(got.text == want.text, "step \(i + 1)")
        }
    }

    @Test(arguments: DetectionFixtures.vectors.incremental)
    func incrementalWithEmptyUserCounts(_ v: DetectionVectors.Incremental) throws {
        // Critique R7 applies the user bonus in prefix mode too; with no counts nothing changes.
        let d = try detector
        let ctx = try LanguageContext(vector: v.ctx)
        let trace = d.displayTrace(raw: v.raw, context: ctx, user: UserCounts())
        #expect(trace.map(\.scores.vectorDictionary) == v.steps.map(\.scores))
        #expect(trace.map(\.shown.key) == v.steps.map(\.shown))
    }

    // MARK: Apostrophe rule (DET §4)

    @Test(arguments: DetectionFixtures.vectors.apostrophe)
    func apostrophe(_ v: DetectionVectors.Apostrophe) throws {
        let d = try detector
        let ctx = try LanguageContext(vector: v.ctx)
        let scores = d.prefixScores(raw: v.raw + "'", context: ctx, user: nil, biasKO: 0)
        #expect(scores.vectorDictionary == v.scores)
        #expect(scores.entries.count == 2, "M(b) is disabled for tokens with an apostrophe")
        #expect((scores.best?.hypothesis == .english) == v.isInternal)
        #expect(d.apostropheIsInternal(after: v.raw, context: ctx) == v.isInternal)
    }

    // MARK: User adaptation (DET §5.5)

    @Test(arguments: DetectionFixtures.vectors.user)
    func user(_ v: DetectionVectors.User) throws {
        let d = try detector
        let ctx = try LanguageContext(vector: v.ctx)
        let counts = try UserCounts(vector: v.userCounts)
        let scores = d.finalScores(raw: v.raw, context: ctx, terminator: .space, user: counts, biasKO: 0)
        #expect(scores.vectorDictionary == v.scores)
        let best = try #require(scores.best)
        #expect(best.hypothesis.key == v.best)
        #expect(d.render(raw: v.raw, best.hypothesis) == v.output)
    }

    @Test func userBonus() throws {
        let d = try detector
        let expected = DetectionFixtures.vectors.userBonus
        try #require(!expected.isEmpty)
        for (n, bonus) in expected {
            #expect(d.userBonus(count: try #require(Int(n))) == bonus, "n = \(n)")
        }
        #expect(d.userBonus(count: -3) == 0)
    }
}
