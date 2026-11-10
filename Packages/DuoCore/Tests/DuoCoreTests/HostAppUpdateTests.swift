import CryptoKit
@testable import DuoKit
import Foundation
import Testing

/// Self-update: which feed counts as newer, when to check, and that only a zip signed by the release
/// key, holding the right app, gets installed. The install script runs on throwaway bundles.
@Suite("Host · app update")
struct HostAppUpdateTests {
    static func feed(_ version: String = "1.1.0", build: String = "2", minimum: String = "15.0",
                     data: Data = Data(), key: Curve25519.Signing.PrivateKey? = nil) -> AppUpdate.Feed {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let signature = (try? key?.signature(for: data))?.base64EncodedString() ?? ""
        return AppUpdate.Feed(version: version, build: build, url: URL(string: "https://example.com/Duo.zip")!,
                              size: data.count, sha256: digest, signature: signature, minimumSystemVersion: minimum)
    }

    static let macOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2)

    @Test("the feed the release script writes decodes")
    func feedDecodes() throws {
        let json = Data("""
            {"version":"1.1.0","build":"2","url":"https://gomjellie.github.io/DuoKeyboard/Duo.zip?v=2","size":9300000,
             "sha256":"ab","signature":"cd","minimumSystemVersion":"15.0"}
            """.utf8)
        let feed = try JSONDecoder().decode(AppUpdate.Feed.self, from: json)
        #expect(feed.bundleVersion == BundleVersion(marketing: "1.1.0", build: "2"))
        #expect(feed.url.query == "v=2")
    }

    @Test("only a newer version on a new enough macOS is offered")
    func decisions() {
        let current = BundleVersion(marketing: "1.0.0", build: "1")
        let newer = Self.feed()
        #expect(AppUpdate.decide(newer, current: current, system: Self.macOS26) == .available(newer))
        #expect(AppUpdate.decide(Self.feed("1.0.0", build: "1"), current: current, system: Self.macOS26) == .upToDate)
        #expect(AppUpdate.decide(Self.feed("0.9.0", build: "9"), current: current, system: Self.macOS26) == .upToDate)
        let needs27 = Self.feed(minimum: "27.0")
        #expect(AppUpdate.decide(needs27, current: current, system: Self.macOS26) == .needsNewerSystem(needs27))
        #expect(AppUpdate.decide(Self.feed(minimum: "26.6.2"), current: current, system: Self.macOS26) == .available(Self.feed(minimum: "26.6.2")))
    }

    @Test("a check is due once a day, and when the clock moved back")
    func schedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppUpdate.isCheckDue(lastAttempt: nil, now: now))
        #expect(!AppUpdate.isCheckDue(lastAttempt: now.addingTimeInterval(-3600), now: now))
        #expect(AppUpdate.isCheckDue(lastAttempt: now.addingTimeInterval(-AppUpdate.checkInterval), now: now))
        #expect(AppUpdate.isCheckDue(lastAttempt: now.addingTimeInterval(600), now: now))
    }

    @Test("a zip passes only with its size, digest and a signature by the release key")
    func verification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("pretend this is Duo.zip".utf8)
        let feed = Self.feed(data: data, key: key)
        try AppUpdate.verify(archive: data, against: feed, publicKey: publicKey)

        var tampered = data
        tampered[0] ^= 1
        #expect(throws: AppUpdate.Failure.digestMismatch) { try AppUpdate.verify(archive: tampered, against: feed, publicKey: publicKey) }
        #expect(throws: AppUpdate.Failure.sizeMismatch(expected: data.count, actual: data.count + 1)) {
            try AppUpdate.verify(archive: data + [0], against: feed, publicKey: publicKey)
        }
        let otherKey = Curve25519.Signing.PrivateKey()
        let forged = Self.feed(data: data, key: otherKey)
        #expect(throws: AppUpdate.Failure.badSignature) { try AppUpdate.verify(archive: data, against: forged, publicKey: publicKey) }
        #expect(throws: AppUpdate.Failure.badSignature) { try AppUpdate.verify(archive: data, against: feed) }
    }

    @Test("the shipped public key is a valid Ed25519 key")
    func shippedKey() throws {
        let raw = try #require(Data(base64Encoded: AppUpdate.publicKey))
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    // MARK: Bundles on disk

    /// A minimal ad-hoc signed app bundle.
    static func makeApp(in directory: URL, name: String = "Duo.app", identifier: String = DuoIDs.hostAppBundleID,
                        version: String = "1.1.0", build: String = "2") throws -> URL {
        let app = directory.appending(path: name)
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Duo",
                                    "CFBundleShortVersionString": version, "CFBundleVersion": build,
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appending(path: "Duo"))
        #expect(AppUpdate.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) == 0)
        return app
    }

    static func zip(_ app: URL, to zip: URL) {
        #expect(AppUpdate.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]) == 0)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "duo-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("unpacking checks the bundle identifier, the version and the code signature")
    func unpacking() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let app = try Self.makeApp(in: source)
        let archive = root.appending(path: "Duo.zip")
        Self.zip(app, to: archive)

        let unpacked = try AppUpdate.unpack(archive: archive, into: root.appending(path: "a"), expecting: Self.feed())
        #expect(unpacked.lastPathComponent == "Duo.app")
        #expect(throws: AppUpdate.Failure.wrongVersion(BundleVersion(marketing: "1.1.0", build: "2"))) {
            try AppUpdate.unpack(archive: archive, into: root.appending(path: "b"), expecting: Self.feed(build: "3"))
        }
        #expect(throws: AppUpdate.Failure.wrongBundle(DuoIDs.hostAppBundleID)) {
            try AppUpdate.unpack(archive: archive, into: root.appending(path: "c"), expecting: Self.feed(),
                                 bundleIdentifier: "com.example.Other")
        }

        // A file changed after signing breaks the seal.
        try Data("x".utf8).write(to: app.appending(path: "Contents/Resources-extra"))
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try Data("changed".utf8).write(to: app.appending(path: "Contents/Resources/added.txt"))
        let broken = root.appending(path: "Broken.zip")
        Self.zip(app, to: broken)
        #expect(throws: AppUpdate.Failure.invalidCodeSignature) {
            try AppUpdate.unpack(archive: broken, into: root.appending(path: "d"), expecting: Self.feed())
        }
    }

    @Test("the install script waits for the app to quit, then swaps the bundle")
    func installScriptSwapsTheBundle() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root,
                                                    create: true)
        let target = try Self.makeApp(in: installed, version: "1.0.0", build: "1")
        let newer = try Self.makeApp(in: root.appending(path: "new"), version: "1.1.0", build: "2")

        // A process that has already exited stands in for the quitting app.
        let quitter = Process()
        quitter.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try quitter.run()
        quitter.waitUntilExit()

        let script = root.appending(path: "install.zsh")
        try AppUpdate.installScript.write(to: script, atomically: true, encoding: .utf8)
        #expect(AppUpdate.run("/bin/zsh", [script.path, String(quitter.processIdentifier), newer.path, target.path, "none"]) == 0)
        #expect(BundleVersion(bundleURL: target) == BundleVersion(marketing: "1.1.0", build: "2"))
        #expect(AppUpdate.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", target.path]) == 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.path).filter { $0.contains(".old-") }
        #expect(leftovers.isEmpty, "the old bundle is removed after the swap")
        try? FileManager.default.removeItem(at: installed)
    }

    @Test("the install script keeps the old bundle when the new one cannot be copied")
    func installScriptRollsBack() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try Self.makeApp(in: root.appending(path: "installed"), version: "1.0.0", build: "1")
        let script = root.appending(path: "install.zsh")
        try AppUpdate.installScript.write(to: script, atomically: true, encoding: .utf8)
        let missing = root.appending(path: "missing/Duo.app").path
        #expect(AppUpdate.run("/bin/zsh", [script.path, "99999999", missing, target.path, "none"]) != 0)
        #expect(BundleVersion(bundleURL: target) == BundleVersion(marketing: "1.0.0", build: "1"))
    }
}
