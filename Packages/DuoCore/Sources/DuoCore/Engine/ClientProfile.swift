import Foundation

/// Per-client defaults keyed by bundle identifier (SPEC.md §4.10, critique R10, R17).
///
/// Direct is never a default: it is opt-in through the input menu or Settings
/// (`DuoSettings.appProfiles`).
public struct ClientProfile: Sendable, Hashable {
    /// The client app (`IMKTextInput.bundleIdentifier()`, cached once per session).
    public var bundleIdentifier: String
    /// Language prior when the user has not chosen one for this app.
    public var defaultAppProfile: AppProfile
    /// How the client handles `replacementRange` (imk-platform.md §5.3).
    public var replacement: ReplacementSupport
    /// Terminal-class client (English-first by default, critique R10).
    public var isTerminal: Bool
    /// Java clients need `setMarkedText(x)` before `insertText(x)` (critique R17). The IMK adapter
    /// applies it; the engine and `BufferTextClient` never need it.
    public var needsMarkBeforeInsert: Bool
    /// Whether the engine may rewrite text that is already committed: re-open eagerly committed
    /// Latin for a flip, flip the last word, offer the "flip last word" chip. Always `false` when
    /// `replacement == .none`. Monaco (VS Code and its forks) ignores `replacementRange` in both
    /// `setMarkedText` and `insertText`, so such an edit would add the new reading next to the old
    /// one; eager English still runs there (IntelliSense needs real text), which `.none` would stop.
    public var canReplaceCommittedText: Bool

    /// A profile with explicit values; ``forBundleIdentifier(_:)`` knows the built-in table.
    public init(bundleIdentifier: String, defaultAppProfile: AppProfile = .automatic,
                replacement: ReplacementSupport = .full, isTerminal: Bool = false, needsMarkBeforeInsert: Bool = false,
                canReplaceCommittedText: Bool = true) {
        self.bundleIdentifier = bundleIdentifier
        self.defaultAppProfile = defaultAppProfile
        self.replacement = replacement
        self.isTerminal = isTerminal
        self.needsMarkBeforeInsert = needsMarkBeforeInsert
        self.canReplaceCommittedText = canReplaceCommittedText && replacement != .none
    }

    /// The built-in profile for a client (SPEC.md §4.10); unknown apps are `.automatic` with
    /// full replacement support (every replacement is verified before it is used anyway).
    public static func forBundleIdentifier(_ id: String) -> ClientProfile {
        if let terminal = terminals[id] {
            return ClientProfile(bundleIdentifier: id, defaultAppProfile: .englishFirst, replacement: terminal,
                                 isTerminal: true, canReplaceCommittedText: !xtermTerminals.contains(id))
        }
        if isJava(id) {
            return ClientProfile(bundleIdentifier: id, defaultAppProfile: .englishFirst, replacement: .none,
                                 needsMarkBeforeInsert: true)
        }
        let monaco = monacoEditors.contains(id)
        if codeEditors.contains(id) {
            return ClientProfile(bundleIdentifier: id, defaultAppProfile: .englishFirst, canReplaceCommittedText: !monaco)
        }
        if koreanFirst.contains(id) || id.hasPrefix("com.hancom.office.hwp") {
            return ClientProfile(bundleIdentifier: id, defaultAppProfile: .koreanFirst)
        }
        return ClientProfile(bundleIdentifier: id, canReplaceCommittedText: !monaco)
    }

    /// The user's override if any, else the default.
    public func effectiveProfile(_ settings: DuoSettings) -> AppProfile {
        settings.appProfiles[bundleIdentifier] ?? defaultAppProfile
    }

    /// `biasKO` for this client (critique R8): the profile prior plus the global language bias,
    /// clamped to ±1500 millinats.
    public func biasKO(_ settings: DuoSettings) -> Int {
        let profile: Int = switch effectiveProfile(settings) {
        case .koreanFirst: 1000
        case .englishFirst: -1000
        case .automatic, .direct: 0
        }
        return min(1500, max(-1500, profile + settings.languageBias))
    }

    // MARK: Tables (SPEC.md §4.10)

    /// Terminal-class apps and their replacement support.
    static let terminals: [String: ReplacementSupport] = [
        "com.apple.Terminal": .beforeCaretOnly,
        "com.googlecode.iterm2": .none,
        "com.stablyai.orca": .full,
        "com.cmuxterm.app": .full,
        "com.mitchellh.ghostty": .full,
        "dev.warp.Warp-Stable": .full,
        "net.kovidgoyal.kitty": .full,
        "org.alacritty": .full,
        "com.github.wez.wezterm": .full,
        "co.zeit.hyper": .none,
    ]

    /// Terminals drawn with xterm.js: text committed to the shell cannot be replaced, so a
    /// replacement range is ignored and the new reading lands after the old one (Orca, user report
    /// 2026-11-07: 이상하게dltkdgkrp). Marked text works.
    static let xtermTerminals: Set<String> = [
        "com.stablyai.orca",
    ]

    static let codeEditors: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.panic.Nova",
        "com.barebones.bbedit",
    ]

    /// Editors built on Monaco: `replacementRange` is ignored (verified live in VS Code; Chrome,
    /// Safari, TextEdit and Terminal honour it).
    static let monacoEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.vscodium",
        "com.exafunction.windsurf",
        "com.visualstudio.code.oss",
    ]

    static let koreanFirst: Set<String> = [
        "com.kakao.KakaoTalkMac",
        "jp.naver.line.mac",
    ]

    /// JetBrains IDEs and Android Studio run on the JBR: no replacement ranges, mark before insert.
    static func isJava(_ id: String) -> Bool {
        id.hasPrefix("com.jetbrains.") || id == "com.google.android.studio"
    }
}
