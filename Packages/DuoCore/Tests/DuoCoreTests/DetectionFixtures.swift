import Foundation
import Testing
@testable import DuoCore

/// `Tests/DuoCoreTests/Resources/test_vectors.json` (written by `Tools/ModelBuilder/build_model.py`,
/// docs/research/detection.md §8). Every number is an `Int` in millinats.
struct DetectionVectors: Decodable, Sendable {
    struct Automaton: Decodable, Sendable, CustomTestStringConvertible {
        var keys: String
        var normalized: String
        var text: String
        var orphans: Int
        var trailingLoneConsonant: Bool
        var testDescription: String { keys }
    }

    struct Hash: Decodable, Sendable, CustomTestStringConvertible {
        var s: String
        var hash: String
        var testDescription: String { "\"\(s)\"" }
    }

    struct Lexicon: Decodable, Sendable, CustomTestStringConvertible {
        var lang: String
        var key: String
        var value: Int?
        var testDescription: String { "\(lang):\(key)" }
    }

    struct LM: Decodable, Sendable, CustomTestStringConvertible {
        var model: String
        var keys: String
        var prefix: [Int]
        var withEos: [Int]
        var testDescription: String { "\(model):\(keys)" }
    }

    struct Features: Decodable, Sendable {
        struct Mix: Decodable, Sendable {
            var b: Int
            var enLm: Int
            var enLex: Int?
            var enCase: String
            var suffix: Int?
            var generic: Int?
            var rollover: Int
            var stray: Int
            var shortOk: Bool
        }

        var koLm: Int
        var koLex: Int?
        var koOrphans: Int
        var koRollover: Int
        var koStray: Int
        var enLm: Int
        var enLex: Int?
        var enCase: String
        var enNumUnit: Bool
        var mix: [Mix]
        var koSplit: Int?
    }

    struct Final: Decodable, Sendable, CustomTestStringConvertible {
        struct Case: Decodable, Sendable {
            var ctx: String
            var term: String
            var scores: [String: Int]
            var best: String
            var output: String
        }

        var raw: String
        var features: Features
        var cases: [Case]
        var testDescription: String { raw }
    }

    struct Incremental: Decodable, Sendable, CustomTestStringConvertible {
        struct Step: Decodable, Sendable {
            var scores: [String: Int]
            var shown: String
            var text: String
        }

        var raw: String
        var ctx: String
        var steps: [Step]
        var testDescription: String { "\(raw) @\(ctx)" }
    }

    struct Apostrophe: Decodable, Sendable, CustomTestStringConvertible {
        var raw: String
        var ctx: String
        var scores: [String: Int]
        /// `internal` in the JSON: the apostrophe stays inside the token.
        var isInternal: Bool
        var testDescription: String { "\(raw)' @\(ctx)" }

        private enum CodingKeys: String, CodingKey {
            case raw, ctx, scores
            case isInternal = "internal"
        }
    }

    struct User: Decodable, Sendable, CustomTestStringConvertible {
        var raw: String
        var ctx: String
        var userCounts: [String: Int]
        var scores: [String: Int]
        var best: String
        var output: String
        var testDescription: String { "\(raw) \(userCounts.sorted { $0.key < $1.key })" }
    }

    var modelContentHash: String
    var params: [String: Int]
    var automaton: [Automaton]
    var fnv1a64: [Hash]
    var lexicon: [Lexicon]
    var lm: [LM]
    var final: [Final]
    var incremental: [Incremental]
    var apostrophe: [Apostrophe]
    var user: [User]
    var userBonus: [String: Int]

    static let empty = DetectionVectors(modelContentHash: "", params: [:], automaton: [], fnv1a64: [], lexicon: [],
                                        lm: [], final: [], incremental: [], apostrophe: [], user: [], userBonus: [:])
}

/// Shared, lazily loaded test inputs: the golden vectors and the shipped model.
enum DetectionFixtures {
    /// The decoded vectors, or the error that prevented loading them.
    static let loadedVectors: Result<DetectionVectors, any Error> = Result {
        guard let url = Bundle.module.url(forResource: "test_vectors", withExtension: "json", subdirectory: "Resources")
        else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(DetectionVectors.self, from: Data(contentsOf: url))
    }

    /// The vectors used as test arguments (empty if loading failed; `vectorsLoad` reports why).
    static var vectors: DetectionVectors { (try? loadedVectors.get()) ?? .empty }

    /// `DuoInputMethod/Resources/duo-model.bin` of this repository, found from this file's path.
    static let modelURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // DuoCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Packages/DuoCore
        .appending(path: "../../DuoInputMethod/Resources/duo-model.bin")
        .standardizedFileURL

    /// The shipped model, opened once for the whole test run.
    static let detector: Result<DuoDetector, any Error> = Result { try DuoDetector(modelURL: modelURL) }
}

extension LanguageContext {
    /// Context from a vector's `ctx` string.
    init(vector: String) throws {
        self = try #require(LanguageContext(rawValue: vector), "unknown ctx \(vector)")
    }
}

extension HypothesisScores {
    /// `{K, E, M<b>}` exactly as the vectors spell it.
    var vectorDictionary: [String: Int] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.hypothesis.key, $0.score) })
    }

    /// Candidate order is `K, E, M(1), M(2), …` (detection.md §5.4).
    var isInCandidateOrder: Bool {
        guard entries.count >= 2, entries[0].hypothesis == .korean, entries[1].hypothesis == .english else { return false }
        var last = 0
        for e in entries.dropFirst(2) {
            guard case .mixed(let b) = e.hypothesis, b > last else { return false }
            last = b
        }
        return true
    }
}

extension UserCounts {
    /// Counts from a vector's `{"E": 3}` dictionary.
    init(vector: [String: Int]) throws {
        var counts: [Hypothesis: Int] = [:]
        for (key, n) in vector { counts[try #require(Hypothesis(key: key))] = n }
        self.init(counts)
    }
}
