import CryptoKit
import Foundation

/// Self-update of Duo.app from the download site: `update.json` describes the newest `Duo.zip`
/// (Tools/scripts/dist.sh writes both). The host app checks, downloads, verifies and installs; the
/// input method never goes online and only asks the host to check (``HostRequest/checkForUpdatesIfDue(now:)``).
public enum AppUpdate {
    /// The site's description of the newest release.
    public struct Feed: Codable, Sendable, Equatable {
        /// `CFBundleShortVersionString` of the new Duo.app.
        public var version: String
        /// `CFBundleVersion` of the new Duo.app.
        public var build: String
        /// The zip with `Duo.app` at its top level.
        public var url: URL
        /// Byte count of the zip.
        public var size: Int
        /// Lowercase hex SHA-256 of the zip.
        public var sha256: String
        /// Base64 Ed25519 signature of the zip's bytes, by the key whose public half is ``publicKey``.
        public var signature: String
        /// The oldest macOS the release runs on, e.g. `"15.0"`.
        public var minimumSystemVersion: String

        public init(version: String, build: String, url: URL, size: Int, sha256: String, signature: String,
                    minimumSystemVersion: String) {
            self.version = version
            self.build = build
            self.url = url
            self.size = size
            self.sha256 = sha256
            self.signature = signature
            self.minimumSystemVersion = minimumSystemVersion
        }

        public var bundleVersion: BundleVersion { BundleVersion(marketing: version, build: build) }
    }

    /// The feed on the download site.
    public static let feedURL = URL(string: "https://gomjellie.github.io/DuoKeyboard/update.json")!

    /// Raw Ed25519 public key (base64) that signs every release zip. Duo.app is ad-hoc signed, so its
    /// code signature cannot say who built an update; this key does. The private half stays with the
    /// maintainer (Tools/scripts/update-sign.swift).
    public static let publicKey = "icJD1ZmachzTBfwRTak6cAiGr56HhjqCuxx+eh6s7Hk="

    // MARK: Deciding

    public enum Decision: Equatable, Sendable {
        case upToDate
        case available(Feed)
        /// Newer, but this macOS is older than the release needs.
        case needsNewerSystem(Feed)
    }

    /// What to do with `feed` when `current` is running on `system`.
    public static func decide(_ feed: Feed, current: BundleVersion, system: OperatingSystemVersion) -> Decision {
        guard current < feed.bundleVersion else { return .upToDate }
        let parts = feed.minimumSystemVersion.split(separator: ".").map { Int($0) ?? 0 }
        let needed = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0,
                                            patchVersion: parts.count > 2 ? parts[2] : 0)
        let tooOld = (system.majorVersion, system.minorVersion, system.patchVersion)
            < (needed.majorVersion, needed.minorVersion, needed.patchVersion)
        return tooOld ? .needsNewerSystem(feed) : .available(feed)
    }

    // MARK: Scheduling

    /// How often Duo looks for a new version.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// `Date` of the last check or request to check, in the shared defaults. The IME writes it when it
    /// asks the host to check, the host when it checks, so neither repeats within ``checkInterval``.
    public static let lastAttemptDefaultsKey = "update.lastAttempt"

    /// Whether a check is due. A last attempt in the future (the clock moved back) counts as due.
    public static func isCheckDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= checkInterval
    }

    public static func lastAttempt(in defaults: UserDefaults = SettingsStore.defaults) -> Date? {
        CFPreferencesAppSynchronize(DuoIDs.sharedSuite as CFString)
        return defaults.object(forKey: lastAttemptDefaultsKey) as? Date
    }

    public static func recordAttempt(_ date: Date, in defaults: UserDefaults = SettingsStore.defaults) {
        defaults.set(date, forKey: lastAttemptDefaultsKey)
    }

    // MARK: Verifying

    public enum Failure: Error, Equatable, Sendable {
        case sizeMismatch(expected: Int, actual: Int)
        case digestMismatch
        case badSignature
        case unpackFailed
        case missingApp
        case wrongBundle(String?)
        case wrongVersion(BundleVersion?)
        case invalidCodeSignature
    }

    /// Checks a downloaded zip against the feed: size, SHA-256 and the Ed25519 signature.
    public static func verify(archive data: Data, against feed: Feed, publicKey: String = publicKey) throws {
        guard data.count == feed.size else { throw Failure.sizeMismatch(expected: feed.size, actual: data.count) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == feed.sha256.lowercased() else { throw Failure.digestMismatch }
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: feed.signature),
              key.isValidSignature(signature, for: data)
        else { throw Failure.badSignature }
    }

    /// Unzips a verified archive into `directory` and checks the app inside: bundle identifier,
    /// version (the feed's) and an intact code signature. Returns the app's URL.
    public static func unpack(archive: URL, into directory: URL, expecting feed: Feed,
                              bundleIdentifier: String = DuoIDs.hostAppBundleID) throws -> URL {
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path]) == 0 else { throw Failure.unpackFailed }
        guard let app = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { throw Failure.missingApp }
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        let identifier = info?["CFBundleIdentifier"] as? String
        guard identifier == bundleIdentifier else { throw Failure.wrongBundle(identifier) }
        let version = BundleVersion(bundleURL: app)
        guard version == feed.bundleVersion else { throw Failure.wrongVersion(version) }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw Failure.invalidCodeSignature
        }
        return app
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: Installing

    /// Swaps the app bundle once the running app has quit, then optionally opens the new one. A
    /// running app cannot replace itself safely, so a detached shell does it.
    ///
    /// Arguments: `<pid> <new app> <target app> <relaunch: none|background|foreground> [launch arguments…]`.
    /// The old bundle is moved aside first and put back if the copy fails.
    public static let installScript = #"""
        #!/bin/zsh
        pid=$1 new=$2 target=$3 relaunch=$4
        shift 4
        for i in {1..300}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$pid" 2>/dev/null && exit 1
        backup="${target%/}.old-$$"
        mv "$target" "$backup" || exit 1
        if ! ditto "$new" "$target"; then
          rm -rf "$target"
          mv "$backup" "$target"
          exit 1
        fi
        rm -rf "$backup"
        xattr -dr com.apple.quarantine "$target" 2>/dev/null
        [[ $relaunch == none ]] && exit 0
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target" 2>/dev/null
        if [[ $relaunch == background ]]; then
          open -n -g "$target" --args "$@"
        else
          open -n "$target" --args "$@"
        fi
        """#

    /// How the new app opens after the swap.
    public enum Relaunch: String, Sendable {
        case none
        /// Hidden, for a background update (`HostRequest.checkForUpdatesArgument`).
        case background
        /// Frontmost, after the user chose to restart.
        case foreground
    }

    /// Writes ``installScript`` to `scriptDirectory` and starts it; it waits for `pid` to exit.
    public static func startInstaller(newApp: URL, target: URL, relaunch: Relaunch, arguments: [String] = [],
                                      scriptDirectory: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let script = scriptDirectory.appending(path: "install-update.zsh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, String(pid), newApp.path, target.path, relaunch.rawValue] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
