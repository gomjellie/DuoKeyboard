/// One order of a backoff n-gram table, viewed in place inside the mapped model file.
///
/// Only trivial (pointer and integer) fields, so the hot path never retains or releases anything.
/// The memory belongs to the `DuoModel` that created the view.
struct NGramLevel {
    /// Sorted ascending packed n-gram keys, `UInt32` or `UInt64` wide.
    let keys: UnsafeRawPointer
    let wideKeys: Bool
    let count: Int
    /// `lp` codebook index per key.
    let lpIndex: UnsafePointer<UInt8>
    /// `bow` codebook index per key; `nil` at the highest order.
    let bowIndex: UnsafePointer<UInt8>?
    /// 256 codewords (millinats), padded with 0 past the stored codebook.
    let lpCodebook: UnsafePointer<Int>
    let bowCodebook: UnsafePointer<Int>

    /// Index of `key`, or -1.
    @inline(__always)
    func find(_ key: UInt64) -> Int {
        if wideKeys { return Self.search(keys.assumingMemoryBound(to: UInt64.self), count, key) }
        guard key <= UInt64(UInt32.max) else { return -1 }
        return Self.search(keys.assumingMemoryBound(to: UInt32.self), count, UInt32(truncatingIfNeeded: key))
    }

    @inline(__always) func lp(_ i: Int) -> Int { lpCodebook[Int(lpIndex[i])] }
    @inline(__always) func bow(_ i: Int) -> Int { bowIndex.map { bowCodebook[Int($0[i])] } ?? 0 }

    // Branch-free lower-bound searches returning the index of `key` or -1. Written per key width
    // rather than generically so unoptimised (Debug) builds do not go through protocol witnesses.

    @inline(__always)
    private static func search(_ a: UnsafePointer<UInt32>, _ n: Int, _ key: UInt32) -> Int {
        guard n > 0 else { return -1 }
        var base = 0, len = n
        while len > 1 {
            let half = len &>> 1
            if a[base &+ half] <= key { base &+= half }
            len &-= half
        }
        return a[base] == key ? base : -1
    }

    @inline(__always)
    private static func search(_ a: UnsafePointer<UInt64>, _ n: Int, _ key: UInt64) -> Int {
        guard n > 0 else { return -1 }
        var base = 0, len = n
        while len > 1 {
            let half = len &>> 1
            if a[base &+ half] <= key { base &+= half }
            len &-= half
        }
        return a[base] == key ? base : -1
    }
}

/// The runtime character LM of docs/research/detection.md §5.2: integer backoff over packed keys.
struct CharacterLM {
    let order: Int
    /// The tables of orders 1…order, in that order.
    let levels: UnsafePointer<NGramLevel>
    /// Distinguishes this model's entries in a shared `CondCache` (packed keys use ≤ 60 bits).
    let cacheTag: UInt64

    /// The table of order `n` (1…order).
    @inline(__always) func level(_ n: Int) -> NGramLevel { levels[n - 1] }

    /// Symbols of history the model conditions on (`N − 1`).
    var contextLength: Int { order - 1 }

    /// A rolling packed history: the last `min(len(hist), N − 1)` symbols, oldest in the high bits.
    struct History {
        var packed: UInt64
        var length: Int

        /// `[<s>]`, truncated to the model's context length.
        @inline(__always)
        init(contextLength: Int) {
            packed = contextLength > 0 ? UInt64(KeySymbols.bos) : 0
            length = contextLength > 0 ? 1 : 0
        }

        @inline(__always)
        mutating func append(_ symbol: UInt8, contextLength: Int) {
            guard contextLength > 0 else { return }
            let mask: UInt64 = (1 << UInt64(KeySymbols.bits * contextLength)) &- 1
            packed = ((packed << UInt64(KeySymbols.bits)) | UInt64(symbol)) & mask
            length = Swift.min(length + 1, contextLength)
        }
    }

    /// `cond(hist, w)`: ln P(w | hist) in millinats, with backoff. An absent context adds 0 and the
    /// unigram `<s>` entry (which only carries `bow(<s>)`) is never a prediction.
    @inline(__always)
    func cond(_ history: History, _ w: UInt8) -> Int {
        let bits = UInt64(KeySymbols.bits)
        var hk = history.packed
        var n = history.length + 1
        var acc = 0
        while true {
            let level = levels[n - 1]
            let i = level.find((hk << bits) | UInt64(w))
            if i >= 0, !(n == 1 && w == KeySymbols.bos) { return acc + level.lp(i) }
            // The unigram table is dense over 2…36 (checked when the model is opened), so the
            // backoff chain always ends above; `<s>` is never predicted.
            if n == 1 { return acc }
            let lower = levels[n - 2]
            let j = lower.find(hk)
            if j >= 0 { acc += lower.bow(j) }
            n -= 1
            hk = n > 1 ? hk & ((1 << (bits * UInt64(n - 1))) &- 1) : 0
        }
    }

    /// `cond` through a per-call memo. `cond` depends only on `(history, w)`, and the packed n-gram
    /// key identifies that pair exactly (every symbol is non-zero), so the result is identical.
    @inline(__always)
    func cond(_ history: History, _ w: UInt8, cache: inout CondCache) -> Int {
        let key = ((history.packed << UInt64(KeySymbols.bits)) | UInt64(w)) | cacheTag
        let slot = cache.slot(for: key)
        if slot.found { return cache.value(at: slot.index) }
        let value = cond(history, w)
        cache.insert(key, value, at: slot.index)
        return value
    }

    /// `score(keys, eos)`: Σ cond(<s> s1…s(i−1), si) [+ cond(<s> s1…sn, </s>)].
    @inline(__always)
    func score(_ symbols: UnsafeBufferPointer<UInt8>, eos: Bool, cache: inout CondCache) -> Int {
        let ctx = contextLength
        var history = History(contextLength: ctx)
        var total = 0
        var i = 0
        while i < symbols.count {  // `while`, not `for in`: ranges iterate slowly at -Onone
            total += cond(history, symbols[i], cache: &cache)
            history.append(symbols[i], contextLength: ctx)
            i &+= 1
        }
        if eos { total += cond(history, KeySymbols.eos, cache: &cache) }
        return total
    }

    /// `score(keys, eos)` without a memo.
    func score(_ symbols: UnsafeBufferPointer<UInt8>, eos: Bool) -> Int {
        var cache = CondCache.disabled
        return score(symbols, eos: eos, cache: &cache)
    }

    /// Cumulative scores of every prefix: `prefix[i]` = score(keys[0..<i], eos: false) and
    /// `withEos[i]` = score(keys[0..<i], eos: true) (the `lm[]` vectors).
    func prefixScores(_ symbols: [UInt8]) -> (prefix: [Int], withEos: [Int]) {
        let ctx = contextLength
        var history = History(contextLength: ctx)
        var prefix = [0]
        var withEos = [cond(history, KeySymbols.eos)]
        var total = 0
        for s in symbols {
            total += cond(history, s)
            history.append(s, contextLength: ctx)
            prefix.append(total)
            withEos.append(total + cond(history, KeySymbols.eos))
        }
        return (prefix, withEos)
    }
}

/// A hashed lexicon section: sorted FNV-1a-64 keys with parallel codebook indices
/// (docs/research/detection.md §7.2). Membership is by hash only, as in the reference.
struct HashedLexicon {
    let keys: UnsafePointer<UInt64>
    let values: UnsafePointer<UInt8>
    let count: Int
    /// 256 codewords (millinats), padded with 0.
    let codebook: UnsafePointer<Int>

    /// ln P(word | language) in millinats for the key whose hash is `hash`, or `nil`.
    @inline(__always)
    func value(hash: UInt64) -> Int? {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if keys[mid] < hash { lo = mid + 1 } else { hi = mid }
        }
        return lo < count && keys[lo] == hash ? codebook[Int(values[lo])] : nil
    }
}
