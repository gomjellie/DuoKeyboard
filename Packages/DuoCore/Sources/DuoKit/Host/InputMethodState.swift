import AppKit
import Carbon
import Foundation

/// `CFBundleShortVersionString` + `CFBundleVersion` of a bundle, compared numerically.
public struct BundleVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// `CFBundleShortVersionString`, e.g. `"1.0.0"`.
    public var marketing: String
    /// `CFBundleVersion`, e.g. `"1"`.
    public var build: String

    /// A version from its two Info.plist strings.
    public init(marketing: String, build: String) {
        self.marketing = marketing
        self.build = build
    }

    /// Reads `Contents/Info.plist` straight from disk. `Bundle(url:)` caches its info dictionary per
    /// path, which would hide an update made while the host app runs.
    public init?(bundleURL: URL) {
        let plistURL = bundleURL.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let marketing = plist["CFBundleShortVersionString"] as? String else { return nil }
        self.init(marketing: marketing, build: plist["CFBundleVersion"] as? String ?? "")
    }

    /// "1.0.0 (1)", or just the marketing version when there is no build number.
    public var description: String { build.isEmpty ? marketing : "\(marketing) (\(build))" }

    /// Numeric order: marketing version first (`1.10` > `1.9`), then build number.
    public static func < (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        let m = lhs.marketing.compare(rhs.marketing, options: .numeric)
        if m != .orderedSame { return m == .orderedAscending }
        return lhs.build.compare(rhs.build, options: .numeric) == .orderedAscending
    }
}

/// The copy of `DuoInputMethod.app` inside the host app, and the files the host reads from it.
public struct EmbeddedInputMethod: Sendable, Equatable {
    /// `Duo.app/Contents/Library/Input Methods/DuoInputMethod.app`.
    public var bundleURL: URL

    /// The embedded input method at `bundleURL`.
    public init(bundleURL: URL) { self.bundleURL = bundleURL }

    /// The embedded input method of the running host app, if the bundle is there.
    public static var current: EmbeddedInputMethod? {
        InputMethodInstaller.embeddedBundleURL.map(EmbeddedInputMethod.init(bundleURL:))
    }

    /// The embedded copy's version (compared with the installed one for 업데이트).
    public var version: BundleVersion? { BundleVersion(bundleURL: bundleURL) }

    var resourcesURL: URL { bundleURL.appending(path: "Contents/Resources", directoryHint: .isDirectory) }

    /// `duo-model.bin`, the language model the playground loads (critique R21: no second copy).
    public var modelURL: URL { resourcesURL.appending(path: "duo-model.bin") }

    /// `duo-model.LICENSE.txt`, the CC BY-SA 4.0 attribution for the model data.
    public var modelLicenseURL: URL { resourcesURL.appending(path: "duo-model.LICENSE.txt") }

    /// The attribution text, or `nil` when the file is missing or unreadable.
    public func modelLicenseText() -> String? {
        try? String(contentsOf: modelLicenseURL, encoding: .utf8)
    }
}

/// Everything the host app shows about Duo's installation, read in one go.
public struct InputMethodState: Sendable, Equatable {
    /// `DuoInputMethod.app` is in `~/Library/Input Methods`.
    public var isInstalled: Bool
    /// TIS knows the source.
    public var isRegistered: Bool
    /// Listed in `AppleEnabledThirdPartyInputSources`.
    public var isAllowListed: Bool
    /// Duo is in the input menu.
    public var isEnabled: Bool
    /// Duo is the current keyboard input source.
    public var isSelected: Bool
    /// Version of `~/Library/Input Methods/DuoInputMethod.app`.
    public var installedVersion: BundleVersion?
    /// A `DuoInputMethod` process is running (learning edits must go through it, critique R14).
    public var isServerRunning: Bool
    /// Some app turned on Secure Keyboard Entry. While it is on, macOS turns Duo off and dims it in
    /// the input menu.
    public var isSecureInputActive: Bool
    /// Name of the app holding Secure Keyboard Entry, when it is on and the holder is known.
    public var secureInputAppName: String?
    /// Localized name of the selected keyboard input source, when it is not Duo.
    public var otherSelectedSourceName: String?

    /// A state with every flag given explicitly (tests and fixtures); `read()` reads the live one.
    public init(isInstalled: Bool = false, isRegistered: Bool = false, isAllowListed: Bool = false,
                isEnabled: Bool = false, isSelected: Bool = false, installedVersion: BundleVersion? = nil,
                isServerRunning: Bool = false, isSecureInputActive: Bool = false,
                secureInputAppName: String? = nil, otherSelectedSourceName: String? = nil) {
        self.isInstalled = isInstalled
        self.isRegistered = isRegistered
        self.isAllowListed = isAllowListed
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.installedVersion = installedVersion
        self.isServerRunning = isServerRunning
        self.isSecureInputActive = isSecureInputActive
        self.secureInputAppName = secureInputAppName
        self.otherSelectedSourceName = otherSelectedSourceName
    }

    /// Reads TIS, the allow-list, the installed bundle and the process list. Read-only.
    public static func read() -> InputMethodState {
        let selected = InputSourceManager.isSelected
        let secure = IsSecureEventInputEnabled()
        return InputMethodState(
            isInstalled: InputMethodInstaller.isInstalled,
            isRegistered: InputSourceManager.isRegistered,
            isAllowListed: InputMethodInstaller.isAllowListed,
            isEnabled: InputSourceManager.isEnabled,
            isSelected: selected,
            installedVersion: BundleVersion(bundleURL: InputSourceManager.installedBundleURL),
            isServerRunning: !NSRunningApplication.runningApplications(
                withBundleIdentifier: DuoIDs.inputMethodBundleID).isEmpty,
            isSecureInputActive: secure,
            secureInputAppName: secure ? SecureInputOwner.appName() : nil,
            otherSelectedSourceName: selected ? nil : InputSourceManager.currentKeyboardSource()?.localizedName)
    }

    /// Whether an install step is already true on this Mac (the checklist shows it as done).
    public func isComplete(_ step: InputMethodInstaller.Step) -> Bool {
        switch step {
        case .copied: isInstalled
        case .registered: isRegistered
        case .allowListed: isAllowListed
        case .enabled: isEnabled
        case .selected: isSelected
        }
    }

    /// Duo can be used: installed and turned on. Onboarding opens on launch until this holds.
    public var isReady: Bool { isInstalled && isEnabled }

    /// The embedded copy is newer than the installed one, so the host offers 업데이트.
    public func isUpdateAvailable(embedded: BundleVersion?) -> Bool {
        guard isInstalled, let embedded, let installedVersion else { return false }
        return installedVersion < embedded
    }
}
