import Foundation

/// The shared 37-symbol keystroke alphabet of both language models (docs/research/detection.md §5.1)
/// and the byte-level helpers the scorer uses instead of `String`/`Character` work.
enum KeySymbols {
    /// `<s>` (0 is padding and never stored).
    static let bos: UInt8 = 1
    /// `</s>`.
    static let eos: UInt8 = 2
    /// `'`, also used for any other character outside the alphabet.
    static let apostrophe: UInt8 = 36
    /// Bits per packed symbol.
    static let bits = 6
    /// The byte that stands in for every character outside the model alphabet.
    static let otherByte: UInt8 = 0x27

    /// The alphabet as `meta.symbols` must spell it: `<s>` 1, `</s>` 2, `a…z` 3…28, `Q W E R T O P`
    /// 29…35, `'` 36.
    static let expectedTable: [String: Int] = {
        var table = ["<s>": 1, "</s>": 2, "'": 36]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { table[String(c)] = 3 + i }
        for (i, c) in "QWERTOP".enumerated() { table[String(c)] = 29 + i }
        return table
    }()

    /// ASCII byte → symbol id. Lowercase letters and `Q W E R T O P` have their own symbols; any
    /// other uppercase letter maps to its lowercase symbol (it never occurs after normalisation);
    /// every non-letter maps to `'`.
    static let symbolForByte: [UInt8] = (0..<128).map { b in
        switch UInt8(b) {
        case 0x61...0x7A: return UInt8(b) - 0x61 + 3
        case 0x51: return 29  // Q
        case 0x57: return 30  // W
        case 0x45: return 31  // E
        case 0x52: return 32  // R
        case 0x54: return 33  // T
        case 0x4F: return 34  // O
        case 0x50: return 35  // P
        case 0x41...0x5A: return UInt8(b) - 0x41 + 3
        default: return apostrophe
        }
    }

    /// `KEY_IS_CONSONANT` of `detector.py`: `qwertasdfgzxcv` and `QWERT` (normalised keys).
    static let isConsonantKey: [Bool] = (0..<128).map { b in
        "qwertasdfgzxcvQWERT".utf8.contains(UInt8(b))
    }

    @inline(__always) static func isUpper(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
    @inline(__always) static func isLower(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }
    @inline(__always) static func isLetter(_ byte: UInt8) -> Bool { isUpper(byte) || isLower(byte) }
    @inline(__always) static func lowercased(_ byte: UInt8) -> UInt8 { isUpper(byte) ? byte | 0x20 : byte }
    /// Shifted `Q W E R T O P`: the keys whose Shift changes the 두벌식 jamo.
    @inline(__always) static func isShiftedQWERTOP(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x51, 0x57, 0x45, 0x52, 0x54, 0x4F, 0x50: true
        default: false
        }
    }
}

/// FNV-1a 64-bit hash (docs/research/detection.md §7.2), the lexicon key function.
enum FNV1a64 {
    static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// Hash of `bytes`.
    @inline(__always)
    static func hash<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var h = offsetBasis
        for byte in bytes { h = (h ^ UInt64(byte)) &* prime }
        return h
    }

    /// Hash of the UTF-8 bytes of `string` (ASCII in every model key).
    static func hash(_ string: String) -> UInt64 { hash(string.utf8) }

    /// Hash of a raw byte range (the scorer's allocation-free path).
    @inline(__always)
    static func hash(_ base: UnsafePointer<UInt8>, _ count: Int) -> UInt64 {
        var h = offsetBasis
        var p = base
        let end = base + count
        while p < end {  // `while`, not `for in`: ranges iterate slowly at -Onone
            h = (h ^ UInt64(truncatingIfNeeded: p.pointee)) &* prime
            p += 1
        }
        return h
    }
}

/// An exact `String → Int` table (suffixes, case lexicon, number units) that is looked up by byte
/// range without creating strings: sorted FNV-1a hashes with a byte comparison on every hit, so a
/// hash collision can never produce a wrong answer.
///
/// Immutable after `init`; the storage is raw memory so lookups do no reference counting.
final class ByteStringTable: @unchecked Sendable {
    private struct Entry {
        var hash: UInt64
        var offset: Int
        var length: Int
        var value: Int
    }

    private let entries: UnsafeMutablePointer<Entry>
    private let arena: UnsafeMutablePointer<UInt8>
    /// Number of entries.
    let count: Int

    init(_ table: [String: Int]) {
        let sorted = table.map { (FNV1a64.hash($0.key), Array($0.key.utf8), $0.value) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.lexicographicallyPrecedes($1.1) }
        count = sorted.count
        entries = .allocate(capacity: Swift.max(1, sorted.count))
        let arenaSize = sorted.reduce(0) { $0 + $1.1.count }
        arena = .allocate(capacity: Swift.max(1, arenaSize))
        var offset = 0
        for (i, (hash, bytes, value)) in sorted.enumerated() {
            (entries + i).initialize(to: Entry(hash: hash, offset: offset, length: bytes.count, value: value))
            for (j, byte) in bytes.enumerated() { arena[offset + j] = byte }
            offset += bytes.count
        }
    }

    convenience init(keys: [String]) {
        self.init(Dictionary(keys.map { ($0, 0) }, uniquingKeysWith: { a, _ in a }))
    }

    deinit {
        entries.deallocate()
        arena.deallocate()
    }

    /// The value stored for the bytes `base[0..<length]`, whose FNV-1a hash is `hash`.
    @inline(__always)
    func value(_ base: UnsafePointer<UInt8>, _ length: Int, hash: UInt64) -> Int? {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo &+ hi) &>> 1
            if entries[mid].hash < hash { lo = mid &+ 1 } else { hi = mid }
        }
        while lo < count, entries[lo].hash == hash {
            let e = entries[lo]
            if e.length == length, memcmp(arena + e.offset, base, length) == 0 { return e.value }
            lo &+= 1
        }
        return nil
    }

    /// Whether the bytes are a key.
    @inline(__always)
    func contains(_ base: UnsafePointer<UInt8>, _ length: Int, hash: UInt64) -> Bool {
        value(base, length, hash: hash) != nil
    }

    /// Convenience lookup for tests and non-hot paths.
    func value(_ key: String) -> Int? {
        let bytes = Array(key.utf8) + [0]  // never empty, so there is always a base address
        return bytes.withUnsafeBufferPointer { b in
            value(b.baseAddress!, b.count - 1, hash: FNV1a64.hash(b.baseAddress!, b.count - 1))
        }
    }
}
