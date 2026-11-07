import DuoCore
@testable import DuoKit
import Foundation
import Testing

/// `InputMethodInstaller.copyBundle` stages the copy and swaps it in, and stops the old server only
/// once the new bundle is in place (review safety-5, host-6). Everything runs in temporary folders
/// with an injected server stop; the real `~/Library/Input Methods` and processes are never touched.
@Suite("Installer · bundle swap")
struct InstallerBundleSwapTests {
    /// A scratch folder with `Input Methods/` (the destination's parent) and a source bundle.
    struct Sandbox {
        let root: URL
        var inputMethods: URL { root.appending(path: "Input Methods", directoryHint: .isDirectory) }
        var destination: URL { inputMethods.appending(path: "DuoInputMethod.app", directoryHint: .isDirectory) }
        var staging: URL { InputMethodInstaller.stagingURL(for: destination) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "duo-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// A fake bundle at `url` whose Info.plist holds `marker`, plus `extra` files.
        @discardableResult
        func makeBundle(at url: URL, marker: String, extra: [String] = []) throws -> URL {
            let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: contents.appending(path: "Info.plist"))
            try Data("binary-\(marker)".utf8).write(to: contents.appending(path: "MacOS/DuoInputMethod"))
            for name in extra { try Data().write(to: contents.appending(path: name)) }
            return url
        }

        func marker(at url: URL) -> String? {
            (try? Data(contentsOf: url.appending(path: "Contents/Info.plist"))).map { String(decoding: $0, as: UTF8.self) }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// Copies normally until `failAfterPartialCopy`, then leaves a half-written folder and throws,
    /// like a copy that runs out of disk space.
    final class FailingCopyFileManager: FileManager, @unchecked Sendable {
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            try createDirectory(at: dstURL.appending(path: "Contents"), withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: dstURL.appending(path: "Contents/Info.plist"))
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    @Test func aFirstInstallMovesTheCopyIntoPlace() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let source = try box.makeBundle(at: box.root.appending(path: "new/DuoInputMethod.app"), marker: "new")
        var stops = 0

        try InputMethodInstaller.copyBundle(from: source, to: box.destination, stopServer: { stops += 1 })
        #expect(box.marker(at: box.destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: box.staging.path))
        #expect(stops == 1)
        #expect(box.marker(at: source) == "new", "the embedded copy stays")
    }

    @Test func anUpdateReplacesTheWholeBundle() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.makeBundle(at: box.destination, marker: "old", extra: ["OnlyInOld"])
        let source = try box.makeBundle(at: box.root.appending(path: "new/DuoInputMethod.app"), marker: "new")

        try InputMethodInstaller.copyBundle(from: source, to: box.destination, stopServer: {})
        #expect(box.marker(at: box.destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: box.destination.appending(path: "Contents/OnlyInOld").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.inputMethods.path)
        #expect(leftovers == ["DuoInputMethod.app"], "no staging or old copy is left next to it")
    }

    @Test func theServerStopsOnlyOnceTheNewBundleIsInPlace() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.makeBundle(at: box.destination, marker: "old")
        let source = try box.makeBundle(at: box.root.appending(path: "new/DuoInputMethod.app"), marker: "new")
        var seenAtStop: String?

        try InputMethodInstaller.copyBundle(from: source, to: box.destination, stopServer: {
            seenAtStop = box.marker(at: box.destination)
        })
        #expect(seenAtStop == "new", "whatever TSM relaunches after the stop is the new code")
    }

    @Test func aFailedCopyKeepsTheInstalledBundleAndTheServer() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.makeBundle(at: box.destination, marker: "old")
        let source = try box.makeBundle(at: box.root.appending(path: "new/DuoInputMethod.app"), marker: "new")
        var stops = 0

        #expect {
            try InputMethodInstaller.copyBundle(from: source, to: box.destination, stopServer: { stops += 1 },
                                                fileManager: FailingCopyFileManager())
        } throws: { error in
            guard case .copyFailed = error as? InputMethodInstaller.InstallError else { return false }
            return true
        }
        #expect(box.marker(at: box.destination) == "old", "the working IME is untouched")
        #expect(!FileManager.default.fileExists(atPath: box.staging.path), "the partial copy is removed")
        #expect(stops == 0, "the running server keeps working")
    }

    @Test func aFailedFirstInstallLeavesNoPartialBundle() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let source = try box.makeBundle(at: box.root.appending(path: "new/DuoInputMethod.app"), marker: "new")

        #expect(throws: InputMethodInstaller.InstallError.self) {
            try InputMethodInstaller.copyBundle(from: source, to: box.destination, stopServer: {},
                                                fileManager: FailingCopyFileManager())
        }
        #expect(!FileManager.default.fileExists(atPath: box.destination.path),
                "a partial bundle would read as installed and never be offered again")
        #expect(!FileManager.default.fileExists(atPath: box.staging.path))
    }

    @Test func aStaleStagingFolderIsReplaced() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.makeBundle(at: box.staging, marker: "interrupted", extra: ["Junk"])
        let source = try box.makeBundle(at: box.root.appending(path: "new/DuoInputMethod.app"), marker: "new")

        try InputMethodInstaller.copyBundle(from: source, to: box.destination, stopServer: {})
        #expect(box.marker(at: box.destination) == "new")
        #expect(!FileManager.default.fileExists(atPath: box.destination.appending(path: "Contents/Junk").path))
        #expect(!FileManager.default.fileExists(atPath: box.staging.path))
    }

    @Test func aMissingSourceChangesNothing() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.makeBundle(at: box.destination, marker: "old")
        var stops = 0

        #expect(throws: InputMethodInstaller.InstallError.bundleMissing(box.root.appending(path: "nope.app").path)) {
            try InputMethodInstaller.copyBundle(from: box.root.appending(path: "nope.app"), to: box.destination,
                                                stopServer: { stops += 1 })
        }
        #expect(box.marker(at: box.destination) == "old")
        #expect(stops == 0)
    }

    @Test func theStagingFolderIsNotAnAppBundle() {
        let staging = InputMethodInstaller.stagingURL(for: InputSourceManager.installedBundleURL)
        #expect(staging.deletingLastPathComponent() == InputSourceManager.userInputMethodsDirectory)
        #expect(staging.pathExtension != "app")
    }
}
