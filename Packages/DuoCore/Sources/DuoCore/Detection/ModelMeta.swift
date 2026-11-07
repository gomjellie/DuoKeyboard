/// The `meta` JSON section of DUOM v1 (docs/research/detection.md §7.2). Only the keys the runtime
/// uses are decoded; `provenance` and friends are ignored.
struct ModelMeta: Decodable, Sendable {
    struct LanguageModel: Decodable, Sendable {
        var order: Int
        /// Keyed by order (`"1"` … `"5"`): codeword values in millinats.
        var lpCodebook: [String: [Int]]
        /// Keyed by order `"1"` … `"order-1"`; always contains an exact 0.
        var bowCodebook: [String: [Int]]
        var count: [String: Int]
        /// `"u32"` or `"u64"` per order.
        var keyType: [String: String]
    }

    struct Lexicon: Decodable, Sendable {
        var count: Int
        var codebook: [Int]
    }

    struct Suffix: Decodable, Sendable {
        /// `kno` key string → ln P(suffix) (millinats).
        var full: [String: Int]
        /// Every prefix of a suffix → ln of the summed probability of the suffixes it starts.
        var prefix: [String: Int]
    }

    var format: String
    var version: [Int]
    var symbols: [String: Int]
    var symbolBits: Int
    var lm: [String: LanguageModel]
    var lexicon: [String: Lexicon]
    var suffix: Suffix
    var caseLexicon: [String]
    var numUnitsEn: [String]
    var params: [String: Int]
    var userLog2Millibits: [Int]
}
