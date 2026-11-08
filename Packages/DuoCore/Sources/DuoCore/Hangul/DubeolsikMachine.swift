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

    /// A stretch of the K reading the chat rules see (DET `jamo_pieces`): a run of syllables, one
    /// piece of a run of orphan jamo, or a literal.
    enum ChatSegment: Equatable {
        case syllables
        /// `count` orphan jamo. `free`: never charged as orphans (mash laughter, one ㅋ/ㅎ after a
        /// syllable, a run of one emotive or repeated jamo); the other jamo between such runs form one piece.
        case jamo(count: Int, free: Bool)
        case literal
    }

    /// Chat code of an orphan block: its choseong index, or 19 + its jungseong index.
    private static func chatCode(_ block: Block) -> Int { block.cho >= 0 ? Int(block.cho) : 19 + Int(block.jung) }

    private static func chatCodes(_ jamo: String) -> [Bool] {
        var table = [Bool](repeating: false, count: 40)
        for c in jamo { table[Jamo.choIndex[c] ?? (19 + Jamo.jungIndex[c]!)] = true }
        return table
    }

    /// Jamo chat repeats for laughter and feelings (DET `EMOTIVE_JAMO`): a run of two or more of one is free.
    private static let emotiveCodes = chatCodes("ㅋㅎㅠㅜㅡㄷㅉ")
    /// Jamo chat repeats for emphasis (DET `REPEAT_JAMO`): a run of three or more of one is free.
    private static let repeatCodes = chatCodes("ㅇㄱㄴㅊㅅㅍ")
    /// Mash laughter (DET `MASH_JAMO`): a whole run of these with at least two ㅋ is free.
    private static let mashCodes = chatCodes("ㅋㄱㄲㄷㅅㅎ")
    /// One of these alone right after a syllable is free (DET `TRAIL_JAMO`).
    private static let trailCodes = chatCodes("ㅋㅎ")
    private static let codeK = Jamo.choIndex["ㅋ"]!
    private static let codeYu = 19 + Jamo.jungIndex["ㅠ"]!
    private static let codeU = 19 + Jamo.jungIndex["ㅜ"]!

    /// The K reading of `keys` in order as ``ChatSegment``s, each with its keys `start..<end`
    /// (DET `jamo_pieces`), plus the `orphans` and `trailingLoneConsonant` outputs of DET §3.
    static func chatSegments(_ keys: UnsafeBufferPointer<UInt8>,
                             _ visit: (_ segment: ChatSegment, _ start: Int, _ end: Int) -> Void)
        -> (orphans: Int, lone: Bool) {
        // One unit per emitted block or literal: code = chat code, -1 syllable, -2 literal.
        withUnsafeTemporaryAllocation(of: (code: Int, start: Int, end: Int).self, capacity: keys.count + 1) { units in
            var count = 0, offset = 0, orphans = 0
            var machine = DubeolsikMachine()
            func note(_ block: Block?) {
                guard let block else { return }
                let start = offset
                offset += block.keyCount
                if block.isOrphan { orphans += 1 }
                units[count] = (block.isOrphan ? chatCode(block) : -1, start, offset)
                count += 1
            }
            DubeolsikTables.keyConsonant.withUnsafeBufferPointer { cons in
                DubeolsikTables.keyVowel.withUnsafeBufferPointer { vows in
                    var i = 0
                    while i < keys.count {
                        let byte = keys[i]
                        i &+= 1
                        if byte < 0x80, cons[Int(byte)] >= 0 {
                            note(machine.consonant(cons[Int(byte)]))
                        } else if byte < 0x80, vows[Int(byte)] >= 0 {
                            note(machine.vowel(vows[Int(byte)]))
                        } else {
                            note(machine.flush())
                            units[count] = (-2, offset, offset + 1)
                            count += 1
                            offset += 1
                        }
                    }
                }
            }
            let lone = machine.pendingIsLoneConsonant
            note(machine.flush())

            var i = 0
            while i < count {
                let code = units[i].code
                if code == -2 {
                    visit(.literal, units[i].start, units[i].end)
                    i += 1
                    continue
                }
                var j = i + 1
                if code == -1 {
                    while j < count, units[j].code == -1 { j += 1 }
                    visit(.syllables, units[i].start, units[j - 1].end)
                    i = j
                    continue
                }
                while j < count, units[j].code >= 0 { j += 1 }
                var ks = 0, mash = true
                for u in i..<j {
                    if units[u].code == codeK { ks += 1 }
                    if !mashCodes[units[u].code] { mash = false }
                }
                if ks >= 2, mash {
                    visit(.jamo(count: j - i, free: true), units[i].start, units[j - 1].end)
                } else if j - i == 1, trailCodes[code], i > 0, units[i - 1].code == -1 {
                    visit(.jamo(count: 1, free: true), units[i].start, units[i].end)
                } else {
                    // Stretches of one jamo (ㅠ = ㅜ); emotive ones of two or more and repeated ones of
                    // three or more are free pieces.
                    func cls(_ c: Int) -> Int { c == codeU ? codeYu : c }
                    var piece = i, k = i
                    while k < j {
                        var e = k + 1
                        while e < j, cls(units[e].code) == cls(units[k].code) { e += 1 }
                        let c = units[k].code
                        if (e - k >= 2 && emotiveCodes[c]) || (e - k >= 3 && repeatCodes[c]) {
                            if piece < k { visit(.jamo(count: k - piece, free: false), units[piece].start, units[k - 1].end) }
                            visit(.jamo(count: e - k, free: true), units[k].start, units[e - 1].end)
                            piece = e
                        }
                        k = e
                    }
                    if piece < j { visit(.jamo(count: j - piece, free: false), units[piece].start, units[j - 1].end) }
                }
                i = j
            }
            return (orphans, lone)
        }
    }

    /// ``orphanStats(_:)`` plus the orphans the K reading is not charged for (DET `chat_runs`), and
    /// whether the last block is one of them: the free pieces of ``chatSegments(_:_:)``, and each other
    /// piece of two or more jamo for which `isWord(start, end)` holds; `start..<end` are the piece's keys
    /// in `keys` (ㅈㄹ하고, 뭔ㅅㅂ, ㄹㅇㅋㅋ).
    static func orphanRunStats(_ keys: UnsafeBufferPointer<UInt8>, isWord: (Int, Int) -> Bool)
        -> (orphans: Int, lone: Bool, runs: Int, runAtEnd: Bool) {
        var exempt = 0, atEnd = false
        let (orphans, lone) = chatSegments(keys) { segment, start, end in
            guard case .jamo(let count, let free) = segment, free || (count >= 2 && isWord(start, end)) else { return }
            exempt += count
            if end == keys.count { atEnd = true }
        }
        return (orphans, lone, exempt, atEnd)
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
