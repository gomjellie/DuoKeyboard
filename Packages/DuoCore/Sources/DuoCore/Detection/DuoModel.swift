import Foundation

/// Errors from opening a `duo-model.bin`.
public enum DuoModelError: Error, Sendable, Equatable {
    /// The file does not exist or cannot be opened or mapped.
    case cannotOpen(String)
    /// The first four bytes are not `"DUOM"`.
    case badMagic
    /// The file's major version is not 1.
    case unsupportedVersion(Int)
    /// The directory, a section or the meta JSON is inconsistent.
    case corrupt(String)
}

/// A read-only, memory-mapped DUOM v1 model file (docs/research/detection.md §7).
///
/// Opening it maps the file, validates the header, the directory and every section the scorer uses,
/// and decodes the `meta` JSON once. Pages fault in lazily while scoring. Instances are immutable,
/// so they are safe to share between threads.
final class DuoModel: @unchecked Sendable {
    /// One directory entry.
    struct Section: Hashable, Sendable {
        var offset: Int
        var length: Int
        var elemSize: Int
        var count: Int
    }

    /// Format version from the header.
    let version: (major: Int, minor: Int)
    /// FNV-1a-64 over every byte from the first section's offset to EOF, as stored in the header.
    let contentHash: UInt64
    /// The directory, by section name.
    let sections: [String: Section]
    /// Decoded `meta` section.
    let meta: ModelMeta
    /// Korean (`kno`) and English (`low`) character LMs.
    let korean: CharacterLM
    let english: CharacterLM
    /// FNV-hashed lexicons: `kno` for Korean, `low` for English.
    let koreanLexicon: HashedLexicon
    let englishLexicon: HashedLexicon
    /// `meta.suffix.full` / `meta.suffix.prefix` (keys are `kno` strings).
    let suffixFull: ByteStringTable
    let suffixPrefix: ByteStringTable
    /// Exact-case Latin forms (iOS, GitHub, API …).
    let caseLexicon: ByteStringTable
    /// Lowercase tokens typical right after a digit (th, km, fps …).
    let numberUnits: ByteStringTable

    private let base: UnsafeRawPointer
    private let size: Int
    /// Codebooks (padded to 256 entries each) and the per-order level views.
    private let codebooks: UnsafeMutablePointer<Int>
    private let levelStorage: UnsafeMutablePointer<NGramLevel>

    /// Maps and validates the model at `url`.
    init(url: URL) throws {
        let path = url.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw DuoModelError.cannotOpen(path) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw DuoModelError.cannotOpen(path) }
        let size = Int(st.st_size)
        guard size > 0 else { throw DuoModelError.badMagic }
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0),
              mapped != UnsafeMutableRawPointer(bitPattern: -1)
        else { throw DuoModelError.cannotOpen(path) }
        let base = UnsafeRawPointer(mapped)

        let parsed: Parsed
        do {
            parsed = try Self.parse(base: base, size: size)
        } catch {
            munmap(mapped, size)
            throw error
        }
        self.base = base
        self.size = size
        version = parsed.version
        contentHash = parsed.contentHash
        sections = parsed.sections
        meta = parsed.meta
        korean = parsed.korean
        english = parsed.english
        koreanLexicon = parsed.koreanLexicon
        englishLexicon = parsed.englishLexicon
        suffixFull = ByteStringTable(parsed.meta.suffix.full)
        suffixPrefix = ByteStringTable(parsed.meta.suffix.prefix)
        caseLexicon = ByteStringTable(keys: parsed.meta.caseLexicon)
        numberUnits = ByteStringTable(keys: parsed.meta.numUnitsEn)
        codebooks = parsed.codebooks
        levelStorage = parsed.levels
    }

    deinit {
        levelStorage.deallocate()
        codebooks.deallocate()
        munmap(UnsafeMutableRawPointer(mutating: base), size)
    }

    /// FNV-1a-64 of the mapped content (the header's `contentHash` must equal it). Touches every
    /// page, so it is for tests and diagnostics, not for the runtime path (critique R21).
    func computeContentHash() -> UInt64 {
        let first = sections.values.map(\.offset).min() ?? size
        return FNV1a64.hash(base.assumingMemoryBound(to: UInt8.self) + first, size - first)
    }

    /// The bytes of a section, for tests.
    func bytes(of name: String) -> UnsafeRawBufferPointer? {
        sections[name].map { UnsafeRawBufferPointer(start: base + $0.offset, count: $0.length) }
    }

    // MARK: - Parsing

    static let headerSize = 32
    /// Largest accepted |value| of a codebook entry, parameter or table value (millinats).
    static let maxMagnitude = 1_000_000_000
    static let directoryEntrySize = 48
    static let magic: [UInt8] = Array("DUOM".utf8)

    private struct Parsed {
        var version: (major: Int, minor: Int)
        var contentHash: UInt64
        var sections: [String: Section]
        var meta: ModelMeta
        var korean: CharacterLM
        var english: CharacterLM
        var koreanLexicon: HashedLexicon
        var englishLexicon: HashedLexicon
        var codebooks: UnsafeMutablePointer<Int>
        var levels: UnsafeMutablePointer<NGramLevel>
    }

    private static func parse(base: UnsafeRawPointer, size: Int) throws -> Parsed {
        // Header (32 bytes): magic, u16 major, u16 minor, u32 section count, u32 directory offset,
        // u64 content hash, u64 reserved.
        guard size >= magic.count,
              (0..<magic.count).allSatisfy({ base.load(fromByteOffset: $0, as: UInt8.self) == magic[$0] })
        else { throw DuoModelError.badMagic }
        guard size >= headerSize else { throw DuoModelError.corrupt("file too small (\(size) bytes)") }
        let major = Int(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: 4, as: UInt16.self)))
        let minor = Int(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: 6, as: UInt16.self)))
        guard major == 1 else { throw DuoModelError.unsupportedVersion(major) }
        let sectionCount = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
        let directoryOffset = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
        let contentHash = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        guard directoryOffset >= headerSize,
              sectionCount > 0,
              directoryOffset + sectionCount * directoryEntrySize <= size
        else { throw DuoModelError.corrupt("directory out of bounds") }

        // Directory: name [24]u8 (NUL-padded ASCII), offset u64, length u64, elemSize u32, count u32.
        var sections: [String: Section] = [:]
        for i in 0..<sectionCount {
            let entry = directoryOffset + i * directoryEntrySize
            var nameBytes: [UInt8] = []
            for j in 0..<24 {
                let byte = base.load(fromByteOffset: entry + j, as: UInt8.self)
                if byte == 0 { break }
                nameBytes.append(byte)
            }
            guard !nameBytes.isEmpty, nameBytes.allSatisfy({ $0 < 0x80 }),
                  let name = String(bytes: nameBytes, encoding: .ascii)
            else { throw DuoModelError.corrupt("bad section name at directory entry \(i)") }
            let offset = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: entry + 24, as: UInt64.self))
            let length = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: entry + 32, as: UInt64.self))
            let elemSize = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: entry + 40, as: UInt32.self)))
            let count = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: entry + 44, as: UInt32.self)))
            guard offset <= UInt64(size), length <= UInt64(size) - offset else {
                throw DuoModelError.corrupt("section \(name) out of bounds")
            }
            guard offset % 8 == 0 else { throw DuoModelError.corrupt("section \(name) is not 8-byte aligned") }
            let (bytes, overflow) = elemSize.multipliedReportingOverflow(by: count)
            guard elemSize > 0, !overflow, bytes == Int(length) else {
                throw DuoModelError.corrupt("section \(name) length \(length) ≠ \(count) × \(elemSize)")
            }
            guard sections.updateValue(Section(offset: Int(offset), length: Int(length), elemSize: elemSize, count: count),
                                       forKey: name) == nil
            else { throw DuoModelError.corrupt("duplicate section \(name)") }
        }

        // Meta JSON.
        guard let metaSection = sections["meta"], metaSection.elemSize == 1 else {
            throw DuoModelError.corrupt("missing meta section")
        }
        let meta: ModelMeta
        do {
            let data = Data(bytes: base + metaSection.offset, count: metaSection.length)
            meta = try JSONDecoder().decode(ModelMeta.self, from: data)
        } catch {
            throw DuoModelError.corrupt("meta: \(error)")
        }
        guard meta.format == "DUOM", meta.version.first == major else {
            throw DuoModelError.corrupt("meta format \(meta.format) \(meta.version)")
        }
        guard meta.symbolBits == KeySymbols.bits, meta.symbols == KeySymbols.expectedTable else {
            throw DuoModelError.corrupt("unexpected symbol table")
        }
        guard !meta.userLog2Millibits.isEmpty else { throw DuoModelError.corrupt("empty userLog2Millibits") }
        // Scores are sums of these; bounding them keeps every runtime sum far from overflow.
        var numbers: [Int] = Array(meta.params.values) + meta.userLog2Millibits
        for lm in meta.lm.values {
            numbers += lm.lpCodebook.values.joined()
            numbers += lm.bowCodebook.values.joined()
        }
        for lexicon in meta.lexicon.values { numbers += lexicon.codebook }
        numbers += meta.suffix.full.values
        numbers += meta.suffix.prefix.values
        guard numbers.allSatisfy({ abs($0) <= Self.maxMagnitude }) else {
            throw DuoModelError.corrupt("meta value out of range")
        }

        guard let koInfo = meta.lm["ko"], let enInfo = meta.lm["en"],
              let koLex = meta.lexicon["ko"], let enLex = meta.lexicon["en"]
        else { throw DuoModelError.corrupt("meta.lm / meta.lexicon incomplete") }
        for info in [koInfo, enInfo] {
            guard (1...10).contains(info.order) else { throw DuoModelError.corrupt("unsupported LM order \(info.order)") }
        }

        // Codebooks: per LM and order, 256 lp + 256 bow slots (all zeros where unused); then 256 per
        // lexicon. Every u8 index therefore lands inside its codebook's slot.
        let lmSlots = (koInfo.order + enInfo.order) * 512
        let codebooks = UnsafeMutablePointer<Int>.allocate(capacity: lmSlots + 512)
        codebooks.initialize(repeating: 0, count: lmSlots + 512)
        let levels = UnsafeMutablePointer<NGramLevel>.allocate(capacity: koInfo.order + enInfo.order)
        var initializedLevels = 0
        do {
            var cursor = 0
            func codebook(_ values: [Int]?, _ what: String) throws -> UnsafePointer<Int> {
                let slot = codebooks + cursor
                cursor += 256
                guard let values else { return UnsafePointer(slot) }
                guard !values.isEmpty, values.count <= 256 else {
                    throw DuoModelError.corrupt("\(what) codebook has \(values.count) entries")
                }
                for (i, v) in values.enumerated() { slot[i] = v }
                return UnsafePointer(slot)
            }
            func section(_ name: String, elemSize: Int, count: Int? = nil) throws -> Section {
                guard let s = sections[name] else { throw DuoModelError.corrupt("missing section \(name)") }
                guard s.elemSize == elemSize else { throw DuoModelError.corrupt("section \(name) elemSize \(s.elemSize)") }
                if let count, s.count != count { throw DuoModelError.corrupt("section \(name) count \(s.count) ≠ \(count)") }
                return s
            }
            func languageModel(_ tag: String, _ info: ModelMeta.LanguageModel) throws -> CharacterLM {
                let first = levels + initializedLevels
                for n in 1...info.order {
                    let key = "\(n)"
                    guard let count = info.count[key], let keyType = info.keyType[key] else {
                        throw DuoModelError.corrupt("meta.lm.\(tag) order \(n) incomplete")
                    }
                    let wide: Bool
                    switch keyType {
                    case "u32":
                        guard KeySymbols.bits * n <= 32 else { throw DuoModelError.corrupt("\(tag).\(n).key too narrow") }
                        wide = false
                    case "u64": wide = true
                    default: throw DuoModelError.corrupt("\(tag).\(n) keyType \(keyType)")
                    }
                    let keys = try section("\(tag).\(n).key", elemSize: wide ? 8 : 4, count: count)
                    let lp = try section("\(tag).\(n).lp", elemSize: 1, count: count)
                    guard let lpValues = info.lpCodebook[key] else { throw DuoModelError.corrupt("\(tag) lpCodebook \(n)") }
                    let lpBook = try codebook(lpValues, "\(tag).\(n).lp")
                    var bowIndex: UnsafePointer<UInt8>?
                    let bowBook: UnsafePointer<Int>
                    if n < info.order {
                        let bow = try section("\(tag).\(n).bow", elemSize: 1, count: count)
                        guard let bowValues = info.bowCodebook[key] else { throw DuoModelError.corrupt("\(tag) bowCodebook \(n)") }
                        bowBook = try codebook(bowValues, "\(tag).\(n).bow")
                        bowIndex = (base + bow.offset).assumingMemoryBound(to: UInt8.self)
                    } else {
                        bowBook = try codebook(nil, "\(tag).\(n).bow")  // highest order: no contexts
                    }
                    (first + n - 1).initialize(to: NGramLevel(
                        keys: base + keys.offset, wideKeys: wide, count: count,
                        lpIndex: (base + lp.offset).assumingMemoryBound(to: UInt8.self), bowIndex: bowIndex,
                        lpCodebook: lpBook, bowCodebook: bowBook))
                    initializedLevels += 1
                }
                let lm = CharacterLM(order: info.order, levels: UnsafePointer(first),
                                     cacheTag: tag == "ko" ? 0 : 1 << 63)
                // `cond` relies on a unigram entry for every predictable symbol (</s>, a…z, QWERTOP, ').
                for w in UInt64(KeySymbols.eos)...UInt64(KeySymbols.apostrophe) where lm.level(1).find(w) < 0 {
                    throw DuoModelError.corrupt("\(tag) unigram table lacks symbol \(w)")
                }
                return lm
            }
            func lexicon(_ tag: String, _ info: ModelMeta.Lexicon) throws -> HashedLexicon {
                let keys = try section("lex\(tag).key", elemSize: 8, count: info.count)
                let values = try section("lex\(tag).val", elemSize: 1, count: info.count)
                let book = codebooks + lmSlots + (tag == "ko" ? 0 : 256)
                guard !info.codebook.isEmpty, info.codebook.count <= 256 else {
                    throw DuoModelError.corrupt("lex\(tag) codebook has \(info.codebook.count) entries")
                }
                for (i, v) in info.codebook.enumerated() { book[i] = v }
                return HashedLexicon(keys: (base + keys.offset).assumingMemoryBound(to: UInt64.self),
                                     values: (base + values.offset).assumingMemoryBound(to: UInt8.self),
                                     count: info.count, codebook: UnsafePointer(book))
            }

            let korean = try languageModel("ko", koInfo)
            let english = try languageModel("en", enInfo)
            let koreanLexicon = try lexicon("ko", koLex)
            let englishLexicon = try lexicon("en", enLex)
            return Parsed(version: (major, minor), contentHash: contentHash, sections: sections, meta: meta,
                          korean: korean, english: english, koreanLexicon: koreanLexicon,
                          englishLexicon: englishLexicon, codebooks: codebooks, levels: levels)
        } catch {
            levels.deinitialize(count: initializedLevels)
            levels.deallocate()
            codebooks.deallocate()
            throw error
        }
    }
}
