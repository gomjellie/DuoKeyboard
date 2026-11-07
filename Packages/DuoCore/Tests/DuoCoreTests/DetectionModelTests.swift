import Foundation
import Testing
@testable import DuoCore

/// The DUOM v1 reader (docs/research/detection.md §7): header, directory, sections, meta.
@Suite("Detection model file")
struct DetectionModelTests {
    private var model: DuoModel { get throws { try DetectionFixtures.detector.get().model } }

    @Test func headerAndDirectory() throws {
        let m = try model
        #expect(m.version.major == 1)
        #expect(m.version.minor == 0)
        #expect(m.sections.count == 33)
        #expect(m.sections.values.allSatisfy { $0.offset % 8 == 0 && $0.elemSize * $0.count == $0.length })
        #expect(m.korean.order == 5)
        #expect(m.english.order == 5)
        #expect(m.koreanLexicon.count == 100_000)
        #expect(m.englishLexicon.count == 60_000)
        #expect(m.suffixFull.count == 1684)
        #expect(m.caseLexicon.count == 250)
        #expect(m.numberUnits.count == 56)
        #expect(m.meta.userLog2Millibits == [0, 1000, 1585, 2000, 2322, 2585, 2807, 3000, 3170, 3322, 3459, 3585,
                                             3700, 3807, 3907, 4000])
    }

    /// Binary search needs every key section strictly ascending; the reader does not scan them at
    /// open time (pages fault in lazily), so the shipped file is checked here.
    @Test(arguments: ["ko", "en", "lexko", "lexen"])
    func keySectionsAreStrictlyAscending(_ tag: String) throws {
        let m = try model
        let names = tag.hasPrefix("lex") ? ["\(tag).key"] : (1...5).map { "\(tag).\($0).key" }
        for name in names {
            let bytes = try #require(m.bytes(of: name))
            let section = try #require(m.sections[name])
            var ascending = true
            if section.elemSize == 4 {
                let keys = bytes.bindMemory(to: UInt32.self)
                var i = 1
                while i < keys.count { if keys[i - 1] >= keys[i] { ascending = false; break }; i += 1 }
            } else {
                let keys = bytes.bindMemory(to: UInt64.self)
                var i = 1
                while i < keys.count { if keys[i - 1] >= keys[i] { ascending = false; break }; i += 1 }
            }
            #expect(ascending, "\(name)")
        }
    }

    @Test func suffixAndCaseTables() throws {
        let m = try model
        #expect(m.suffixFull.value("dmf") == m.meta.suffix.full["dmf"])  // 을
        #expect(m.suffixFull.value("goTdjdy") != nil)  // 했어요
        #expect(m.suffixFull.value("zzzzzzzz") == nil)
        #expect(m.suffixPrefix.value("") == nil)
        #expect(m.caseLexicon.value("iOS") != nil)
        #expect(m.caseLexicon.value("ios") == nil)
        #expect(m.numberUnits.value("km") != nil)
        for (key, value) in m.meta.suffix.prefix { #expect(m.suffixPrefix.value(key) == value, "\(key)") }
    }

    // MARK: Rejected files

    private static func withTemporaryModel(_ bytes: [UInt8], _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "DuoDetectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "duo-model.bin")
        try Data(bytes).write(to: url)
        try body(url)
    }

    private static func shippedBytes() throws -> [UInt8] {
        [UInt8](try Data(contentsOf: DetectionFixtures.modelURL))
    }

    @Test func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/duo-model.bin")
        #expect(throws: DuoModelError.cannotOpen(url.path)) { try DuoDetector(modelURL: url) }
    }

    @Test func badMagic() throws {
        var bytes = try Self.shippedBytes()
        bytes[0] = UInt8(ascii: "X")
        try Self.withTemporaryModel(bytes) { url in
            #expect(throws: DuoModelError.badMagic) { try DuoDetector(modelURL: url) }
        }
    }

    @Test func unsupportedMajorVersion() throws {
        var bytes = try Self.shippedBytes()
        bytes[4] = 2
        try Self.withTemporaryModel(bytes) { url in
            #expect(throws: DuoModelError.unsupportedVersion(2)) { try DuoDetector(modelURL: url) }
        }
    }

    @Test(arguments: [0, 3, 31, 1000, 1616 + 10, 4_000_000])
    func truncatedFileIsRejected(_ length: Int) throws {
        let bytes = Array(try Self.shippedBytes().prefix(length))
        try Self.withTemporaryModel(bytes) { url in
            #expect(throws: DuoModelError.self) { try DuoDetector(modelURL: url) }
        }
    }

    @Test func corruptDirectoryEntryIsRejected() throws {
        var bytes = try Self.shippedBytes()
        // Directory entry 1 (`ko.1.key`): make its offset unaligned.
        bytes[32 + 48 + 24] &+= 4
        try Self.withTemporaryModel(bytes) { url in
            #expect(throws: DuoModelError.corrupt("section ko.1.key is not 8-byte aligned")) {
                try DuoDetector(modelURL: url)
            }
        }
    }

    @Test func corruptMetaIsRejected() throws {
        var bytes = try Self.shippedBytes()
        let meta = try #require(try model.sections["meta"])
        bytes[meta.offset] = UInt8(ascii: "[")  // no longer a JSON object
        try Self.withTemporaryModel(bytes) { url in
            let error = #expect(throws: DuoModelError.self) { try DuoDetector(modelURL: url) }
            guard case .corrupt(let message)? = error else {
                Issue.record("expected DuoModelError.corrupt, got \(String(describing: error))")
                return
            }
            #expect(message.hasPrefix("meta"))
        }
    }

    @Test func intactCopyOpens() throws {
        try Self.withTemporaryModel(try Self.shippedBytes()) { url in
            let d = try DuoDetector(modelURL: url)
            #expect(d.contentHash == "aa722069c1e3076e")
        }
    }
}
