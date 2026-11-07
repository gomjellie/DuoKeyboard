/// A syllable block produced by the 두벌식 automaton. A block may be incomplete (orphan jamo).
public struct HangulBlock: Hashable, Sendable {
    public var initial: Character?
    /// First typed vowel and optional second vowel of a compound (e.g. ㅗ + ㅏ = ㅘ).
    public var vowel1: Character?
    public var vowel2: Character?
    /// First typed final consonant and optional second of a compound (e.g. ㄹ + ㄱ = ㄺ).
    public var final1: Character?
    public var final2: Character?

    public init(initial: Character? = nil, vowel1: Character? = nil, vowel2: Character? = nil,
                final1: Character? = nil, final2: Character? = nil) {
        self.initial = initial; self.vowel1 = vowel1; self.vowel2 = vowel2; self.final1 = final1; self.final2 = final2
    }

    /// No initial and no vowel.
    public var isEmpty: Bool { initial == nil && vowel1 == nil }
    /// The (possibly compound) vowel.
    public var medial: Character? {
        guard let v1 = vowel1 else { return nil }
        guard let v2 = vowel2 else { return v1 }
        return Jamo.combineVowels(v1, v2)
    }
    /// The (possibly compound) final consonant.
    public var final: Character? {
        guard let f1 = final1 else { return nil }
        guard let f2 = final2 else { return f1 }
        return Jamo.combineFinals(f1, f2)
    }
    /// Initial + vowel present: renders as a precomposed syllable.
    public var isComplete: Bool { initial != nil && vowel1 != nil }
    public var isOrphanConsonant: Bool { initial != nil && vowel1 == nil }
    public var isOrphanVowel: Bool { initial == nil && vowel1 != nil }
    /// Number of keystrokes that typed this block (each typed jamo is one key).
    public var keyCount: Int {
        [initial, vowel1, vowel2, final1, final2].lazy.filter { $0 != nil }.count
    }

    /// The precomposed syllable, or the lone compatibility jamo of an incomplete block.
    public var text: String {
        if let i = initial, let m = medial, let s = Jamo.compose(initial: i, medial: m, final: final) {
            return String(s)
        }
        if let i = initial { return String(i) }
        if let m = medial { return String(m) }
        return ""
    }
}

/// Result of running jamo or keystrokes through the 두벌식 automaton.
public struct HangulComposition: Hashable, Sendable {
    public var blocks: [HangulBlock]

    public init(blocks: [HangulBlock]) { self.blocks = blocks }

    public var text: String { blocks.map(\.text).joined() }
    public var completeCount: Int { blocks.lazy.filter(\.isComplete).count }
    public var orphanConsonantCount: Int { blocks.lazy.filter(\.isOrphanConsonant).count }
    public var orphanVowelCount: Int { blocks.lazy.filter(\.isOrphanVowel).count }
    /// Every block is a full syllable (no stray jamo) — the hallmark of intentional Korean typing.
    public var isWellFormed: Bool { !blocks.isEmpty && blocks.allSatisfy(\.isComplete) }
    /// Well-formed except possibly the last block, which may still be in progress (e.g. "안ㄴ").
    public var isWellFormedPrefix: Bool {
        guard let last = blocks.last else { return true }
        return blocks.dropLast().allSatisfy(\.isComplete) && (last.isComplete || last.isOrphanConsonant)
    }
}

/// The DET-faithful rendering of a raw ABC keystroke string (docs/research/detection.md §3).
public struct HangulRendering: Hashable, Sendable {
    /// Emitted characters plus the pending block (rendering does not flush it).
    public var text: String
    /// Compatibility jamo emitted, plus 1 if the pending block is initial-only or vowel-only.
    public var orphans: Int
    /// The pending block is a lone initial consonant (`rk` + `s` → 가ㄴ).
    public var trailingLoneConsonant: Bool
    /// For each `Character` of `text`, how many characters of `raw` produced it (a syllable block
    /// counts its typed jamo; a literal counts 1). Dropping the last entry's worth of keys from
    /// `raw` removes the last block — Backspace by 글자.
    public var keyCounts: [Int]

    public init(text: String, orphans: Int, trailingLoneConsonant: Bool, keyCounts: [Int]) {
        self.text = text
        self.orphans = orphans
        self.trailingLoneConsonant = trailingLoneConsonant
        self.keyCounts = keyCounts
    }
}

/// Deterministic 두벌식 (KS X 5002) composition automaton, including compound vowels, compound
/// finals and the 도깨비불 rule (a final consonant moves to the next syllable when a vowel follows).
/// It is normative for detection: `render(raw:)` is bit-exact with `Tools/ModelBuilder/hangul.py`
/// (docs/research/detection.md §3).
///
/// - Consonants never combine without a vowel (`rt` → ㄱㅅ).
/// - Vowels combine with or without an initial (`hk` → ㅘ).
/// - ㄸ ㅃ ㅉ are never finals (`rkE` → 가ㄸ); ㄲ and ㅆ are single keys and therefore simple finals.
/// - Anything that cannot be part of a syllable is emitted as a compatibility jamo ("orphan").
///
/// The engine recomposes from the full keystroke buffer on every change, so backspace naturally
/// removes exactly the last typed jamo (닭 → 달, ㅘ → ㅗ), matching Apple's 2-Set behaviour.
public enum HangulAutomaton {
    /// Composes keystrokes (each key types one simple jamo).
    public static func compose(_ keys: [Keystroke]) -> HangulComposition {
        compose(jamo: keys.map(\.jamo))
    }

    /// Composes a sequence of jamo as they are typed. Compound jamo (ㅘ, ㄳ) are fed as their typed
    /// parts; anything that is not a jamo flushes the pending block and is otherwise ignored (use
    /// `render(raw:)` to keep literals such as `'`).
    public static func compose(jamo: [Character]) -> HangulComposition {
        var blocks: [HangulBlock] = []
        var machine = DubeolsikMachine()
        func emit(_ block: DubeolsikMachine.Block?) {
            if let block { blocks.append(block.hangulBlock) }
        }
        for j in jamo {
            let parts = Jamo.vowelParts[j].map { [$0.0, $0.1] } ?? Jamo.finalParts[j].map { [$0.0, $0.1] } ?? [j]
            for part in parts {
                if let c = Jamo.choIndex[part] {
                    emit(machine.consonant(Int8(c)))
                } else if let v = Jamo.jungIndex[part] {
                    emit(machine.vowel(Int8(v)))
                } else {
                    emit(machine.flush())
                }
            }
        }
        emit(machine.flush())
        return HangulComposition(blocks: blocks)
    }

    /// DET §3 `keys_to_hangul`: runs a raw ABC keystroke string (lowercase = unshifted key,
    /// uppercase = Shift+key, plus `'`) through Korean normalisation and the automaton.
    ///
    /// Every character that is not an ASCII letter (the token-internal apostrophe in practice)
    /// flushes the pending block and is emitted literally (`dkssud'` → 안녕').
    public static func render(raw: String) -> HangulRendering {
        var text = ""
        text.reserveCapacity(3 * raw.utf8.count)  // UTF-8 of a syllable is 3 bytes
        var keyCounts: [Int] = []
        var orphans = 0
        var machine = DubeolsikMachine()
        func emit(_ block: DubeolsikMachine.Block?) {
            guard let block else { return }
            text.append(block.character)
            keyCounts.append(block.keyCount)
            if block.isOrphan { orphans += 1 }
        }
        for ch in raw {
            if let byte = ch.asciiValue {
                let c = DubeolsikTables.keyConsonant[Int(byte)]
                if c >= 0 { emit(machine.consonant(c)); continue }
                let v = DubeolsikTables.keyVowel[Int(byte)]
                if v >= 0 { emit(machine.vowel(v)); continue }
            }
            emit(machine.flush())
            text.append(ch)
            keyCounts.append(1)
        }
        let lone = machine.pendingIsLoneConsonant
        if let pending = machine.pending {
            text.append(pending.character)
            keyCounts.append(pending.keyCount)
            if pending.isOrphan { orphans += 1 }
        }
        return HangulRendering(text: text, orphans: orphans, trailingLoneConsonant: lone, keyCounts: keyCounts)
    }

    /// DET §3 Korean normalisation: every uppercase letter whose lowercase is not one of
    /// `q w e r t o p` is lowercased (`Hello` → `hello`; `PRdmf` stays). Shift only matters in
    /// 두벌식 on those seven keys (ㅃ ㅉ ㄸ ㄲ ㅆ ㅒ ㅖ).
    public static func koreanNormalize(_ raw: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if scalar.isASCII {
                out.unicodeScalars.append(UnicodeScalar(DubeolsikTables.normalizedKey[Int(scalar.value)]))
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Latin keys → Hangul text (`"dkssudgktpdy"` → `"안녕하세요"`); the text of `render(raw:)`.
    public static func hangul(fromLatin text: String) -> String {
        render(raw: text).text
    }
}
