/// A per-call memo of `CharacterLM.cond` results, keyed by the tagged packed n-gram key.
///
/// The generic `M(b)` tails rescore the Korean continuation from `<s>` for every split point, and
/// after four symbols their histories are the ones the `K` pass already scored; memoising turns
/// that O(n²) work into O(n) distinct lookups. Open addressing over two temporary (stack)
/// buffers; key 0 marks an empty slot (real keys always contain a non-zero symbol). When the table
/// is three quarters full it stops memoising, which only costs time, never correctness.
struct CondCache {
    private let keys: UnsafeMutablePointer<UInt64>?
    private let values: UnsafeMutablePointer<Int>?
    private let mask: Int
    private var remaining: Int

    /// A cache that never memoises.
    static var disabled: CondCache { CondCache(keys: nil, values: nil, mask: 0, remaining: 0) }

    private init(keys: UnsafeMutablePointer<UInt64>?, values: UnsafeMutablePointer<Int>?, mask: Int, remaining: Int) {
        self.keys = keys
        self.values = values
        self.mask = mask
        self.remaining = remaining
    }

    /// Runs `body` with an empty cache sized for a token of `tokenLength` keys.
    static func with<R>(tokenLength: Int, _ body: (inout CondCache) -> R) -> R {
        // ≈ 8 distinct conds per key (K, E, </s>, and the first symbols of each tail); keep the load ≤ ½.
        var capacity = 64
        while capacity < 16 * tokenLength && capacity < 4096 { capacity <<= 1 }
        return withUnsafeTemporaryAllocation(of: UInt64.self, capacity: capacity) { keys in
            withUnsafeTemporaryAllocation(of: Int.self, capacity: capacity) { values in
                keys.initialize(repeating: 0)
                var cache = CondCache(keys: keys.baseAddress, values: values.baseAddress, mask: capacity - 1,
                                      remaining: capacity * 3 / 4)
                return body(&cache)
            }
        }
    }

    /// The slot holding `key`, or the empty slot where it would go.
    @inline(__always)
    func slot(for key: UInt64) -> (index: Int, found: Bool) {
        guard let keys else { return (0, false) }
        var i = Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 32) & mask
        while true {
            let k = keys[i]
            if k == key { return (i, true) }
            if k == 0 { return (i, false) }
            i = (i &+ 1) & mask
        }
    }

    @inline(__always)
    func value(at index: Int) -> Int { values![index] }

    /// Stores `value` for `key` in the empty slot `index` returned by `slot(for:)`.
    @inline(__always)
    mutating func insert(_ key: UInt64, _ value: Int, at index: Int) {
        guard remaining > 0, let keys, let values else { return }
        keys[index] = key
        values[index] = value
        remaining -= 1
    }
}
