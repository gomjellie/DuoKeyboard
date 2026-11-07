/// Integer-coded tables for the 두벌식 automaton, derived once from `Jamo` and `DubeolsikLayout` so
/// there is a single source of truth for the jamo inventory and the compound rules.
///
/// Indices follow Unicode order: choseong 0..<19, jungseong 0..<21, jongseong 0..<28 (0 = none).
enum DubeolsikTables {
    /// ASCII byte → choseong index of the key's jamo after Korean normalisation, or -1.
    static let keyConsonant: [Int8] = keyTable { jamo in Jamo.choIndex[jamo] }
    /// ASCII byte → jungseong index of the key's jamo after Korean normalisation, or -1.
    static let keyVowel: [Int8] = keyTable { jamo in Jamo.jungIndex[jamo] }

    /// ASCII byte → the byte after Korean normalisation (DET §3): an uppercase letter whose
    /// lowercase is not one of `q w e r t o p` is lowercased; every other byte is unchanged.
    static let normalizedKey: [UInt8] = (0..<128).map { b in
        let byte = UInt8(b)
        guard byte >= 0x41, byte <= 0x5A else { return byte }
        let lower = byte | 0x20
        return shiftMeaningful.contains(lower) ? byte : lower
    }

    /// Lowercase keys whose shifted 두벌식 jamo differs (ㅃ ㅉ ㄸ ㄲ ㅆ ㅒ ㅖ).
    static let shiftMeaningful: Set<UInt8> = Set(DubeolsikLayout.shiftedJamo.keys.map { $0.asciiValue! })

    /// Choseong index → jongseong index of the same consonant, or -1 when it can never be a final
    /// (ㄸ ㅃ ㅉ).
    static let choToJong: [Int8] = Jamo.choseong.map { c in Int8(Jamo.jongIndex[c] ?? -1) }

    /// Simple jongseong index → choseong index (for 도깨비불); -1 for compounds and slot 0.
    static let jongToCho: [Int8] = Jamo.jongseong.map { j in
        guard let j, Jamo.finalParts[j] == nil else { return -1 }
        return Int8(Jamo.choIndex[j] ?? -1)
    }

    /// Compound jongseong index → (remaining jongseong index, choseong index that moves on); `nil`
    /// for simple finals.
    static let jongSplit: [(keep: Int8, move: Int8)?] = Jamo.jongseong.map { j in
        guard let j, let (a, b) = Jamo.finalParts[j], let keep = Jamo.jongIndex[a], let move = Jamo.choIndex[b]
        else { return nil }
        return (Int8(keep), Int8(move))
    }

    /// `jongCombine[jong * 19 + cho]` = compound jongseong index, or -1.
    static let jongCombine: [Int8] = {
        var table = [Int8](repeating: -1, count: 28 * 19)
        for (pair, compound) in Jamo.compoundFinals {
            let first = pair.first!, second = pair.last!
            table[Jamo.jongIndex[first]! * 19 + Jamo.choIndex[second]!] = Int8(Jamo.jongIndex[compound]!)
        }
        return table
    }()

    /// `jungCombine[jung * 21 + jung2]` = compound jungseong index, or -1.
    static let jungCombine: [Int8] = {
        var table = [Int8](repeating: -1, count: 21 * 21)
        for (pair, compound) in Jamo.compoundVowels {
            let first = pair.first!, second = pair.last!
            table[Jamo.jungIndex[first]! * 21 + Jamo.jungIndex[second]!] = Int8(Jamo.jungIndex[compound]!)
        }
        return table
    }()

    private static func keyTable(_ index: (Character) -> Int?) -> [Int8] {
        (0..<128).map { b in
            let normalized = normalizedKey[b]
            guard let jamo = jamo(forNormalizedKey: normalized), let i = index(jamo) else { return -1 }
            return Int8(i)
        }
    }

    private static func jamo(forNormalizedKey byte: UInt8) -> Character? {
        switch byte {
        case 0x61...0x7A:
            return DubeolsikLayout.jamoForKey[Character(UnicodeScalar(byte))]
        case 0x41...0x5A:
            return DubeolsikLayout.shiftedJamo[Character(UnicodeScalar(byte | 0x20))]
        default:
            return nil
        }
    }
}

/// The state of the 두벌식 automaton of DET §3 (`hangul.py` `Automaton`), integer-coded so the
/// detector can run it over byte buffers without touching `String` or `Character`.
///
/// Every mutating input returns the block it flushed, if any; the caller decides whether to render
/// it, count it, or both. Literal input (the apostrophe, or anything that is not a letter) is the
/// caller's job: call `flush()` and then emit the literal.
struct DubeolsikMachine {
    /// A finished (or pending) syllable block in integer form.
    struct Block: Hashable {
        /// Choseong index, or -1.
        var cho: Int8
        /// Jungseong index, or -1.
        var jung: Int8
        /// Jongseong index, 0 for none.
        var jong: Int8

        /// Exactly one of initial or vowel: emitted as a compatibility jamo ("orphan").
        var isOrphan: Bool { (cho >= 0) != (jung >= 0) }
    }

    private(set) var cho: Int8 = -1
    private(set) var jung: Int8 = -1
    private(set) var jong: Int8 = 0

    /// The pending block, if any input is pending.
    var pending: Block? { cho >= 0 || jung >= 0 ? Block(cho: cho, jung: jung, jong: jong) : nil }
    /// `trailingLoneConsonant` of DET §3: the pending block is an initial consonant only.
    var pendingIsLoneConsonant: Bool { cho >= 0 && jung < 0 }
    /// The pending block would be emitted as an orphan jamo (initial only or vowel only).
    var pendingIsOrphan: Bool { (cho >= 0) != (jung >= 0) }

    /// Emits the pending block (if any) and clears the state.
    @inline(__always)
    mutating func flush() -> Block? {
        defer { cho = -1; jung = -1; jong = 0 }
        return pending
    }

    /// Feeds one consonant (choseong index).
    @inline(__always)
    mutating func consonant(_ c: Int8) -> Block? {
        if cho >= 0, jung >= 0 {
            if jong == 0 {
                let asFinal = DubeolsikTables.choToJong[Int(c)]
                if asFinal < 0 {  // ㄸ ㅃ ㅉ are never finals
                    let out = flush()
                    cho = c
                    return out
                }
                jong = asFinal
                return nil
            }
            let combined = DubeolsikTables.jongCombine[Int(jong) * 19 + Int(c)]
            if combined >= 0 {
                jong = combined
                return nil
            }
        }
        // Empty, initial only, vowel only, or a final that does not combine: start a new block.
        // Consonants never combine without a vowel (r t → ㄱㅅ).
        let out = flush()
        cho = c
        return out
    }

    /// Feeds one vowel (jungseong index).
    @inline(__always)
    mutating func vowel(_ v: Int8) -> Block? {
        if jong != 0 {  // 도깨비불: the (second part of the) final starts the next syllable
            let moved: Int8
            if let split = DubeolsikTables.jongSplit[Int(jong)] {
                jong = split.keep
                moved = split.move
            } else {
                moved = DubeolsikTables.jongToCho[Int(jong)]
                jong = 0
            }
            let out = flush()
            cho = moved
            jung = v
            return out
        }
        if jung >= 0 {
            let combined = DubeolsikTables.jungCombine[Int(jung) * 21 + Int(v)]
            if combined >= 0 {
                jung = combined
                return nil
            }
            let out = flush()
            jung = v
            return out
        }
        jung = v  // empty or initial only
        return nil
    }

    /// Orphan count and trailing-lone-consonant flag of `keys` (ASCII bytes, raw or normalised) —
    /// the `orphans` and `trailingLoneConsonant` outputs of DET §3 without building any text.
    /// Bytes that are not letters are literals (they flush).
    static func orphanStats(_ keys: UnsafeBufferPointer<UInt8>) -> (orphans: Int, lone: Bool) {
        var machine = DubeolsikMachine()
        var orphans = 0
        DubeolsikTables.keyConsonant.withUnsafeBufferPointer { cons in
            DubeolsikTables.keyVowel.withUnsafeBufferPointer { vows in
                var i = 0
                while i < keys.count {  // `while`, not `for in`: faster at -Onone
                    let byte = keys[i]
                    i &+= 1
                    let flushed: Block?
                    if byte < 0x80, cons[Int(byte)] >= 0 {
                        flushed = machine.consonant(cons[Int(byte)])
                    } else if byte < 0x80, vows[Int(byte)] >= 0 {
                        flushed = machine.vowel(vows[Int(byte)])
                    } else {
                        flushed = machine.flush()
                    }
                    if let flushed, flushed.isOrphan { orphans += 1 }
                }
            }
        }
        if machine.pendingIsOrphan { orphans += 1 }
        return (orphans, machine.pendingIsLoneConsonant)
    }
}

extension DubeolsikMachine.Block {
    /// The character this block renders as: a precomposed syllable, or a compatibility jamo.
    var character: Character {
        if cho >= 0, jung >= 0 {
            let value = Jamo.syllableBase + UInt32((Int(cho) * 21 + Int(jung)) * 28 + Int(jong))
            return Character(UnicodeScalar(value)!)
        }
        return cho >= 0 ? Jamo.choseong[Int(cho)] : Jamo.jungseong[Int(jung)]
    }

    /// Number of keystrokes (typed jamo) that make up this block.
    var keyCount: Int {
        var n = cho >= 0 ? 1 : 0
        if jung >= 0 { n += Jamo.vowelParts[Jamo.jungseong[Int(jung)]] == nil ? 1 : 2 }
        if jong > 0, let final = Jamo.jongseong[Int(jong)] { n += Jamo.finalParts[final] == nil ? 1 : 2 }
        return n
    }

    /// The public, typed-parts representation.
    var hangulBlock: HangulBlock {
        var block = HangulBlock()
        if cho >= 0 { block.initial = Jamo.choseong[Int(cho)] }
        if jung >= 0 {
            let v = Jamo.jungseong[Int(jung)]
            if let (a, b) = Jamo.vowelParts[v] { block.vowel1 = a; block.vowel2 = b } else { block.vowel1 = v }
        }
        if jong > 0, let f = Jamo.jongseong[Int(jong)] {
            if let (a, b) = Jamo.finalParts[f] { block.final1 = a; block.final2 = b } else { block.final1 = f }
        }
        return block
    }
}
