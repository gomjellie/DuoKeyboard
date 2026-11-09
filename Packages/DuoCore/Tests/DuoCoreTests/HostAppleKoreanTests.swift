@testable import DuoKit
import Testing

/// macOS's Korean input method is in the input menu only while the input method itself is enabled.
@Suite("Host · macOS Korean input method")
struct HostAppleKoreanTests {
    private typealias Info = InputSourceManager.SourceInfo

    private static func method(enabled: Bool) -> Info {
        Info(id: "com.apple.inputmethod.Korean", bundleID: "com.apple.inputmethod.Korean", localizedName: "한국어",
             isEnabled: enabled, isSelected: false, isSelectCapable: false)
    }

    private static func mode(_ suffix: String, _ name: String, enabled: Bool) -> Info {
        Info(id: "com.apple.inputmethod.Korean.\(suffix)", bundleID: "com.apple.inputmethod.Korean", localizedName: name,
             isEnabled: enabled, isSelected: false, isSelectCapable: true)
    }

    @Test("the enabled modes are named while the input method is enabled")
    func enabledModesAreNamed() {
        let sources = [Self.method(enabled: true), Self.mode("2SetKorean", "2벌식", enabled: true),
                       Self.mode("3SetKorean", "3벌식", enabled: false), Self.mode("390Sebulshik", "390 세벌식", enabled: true)]
        #expect(InputSourceManager.appleKoreanModeNames(in: sources) == ["2벌식", "390 세벌식"])
    }

    @Test("a mode left enabled under a removed input method is not in the input menu")
    func removedInputMethodHidesItsModes() {
        let sources = [Self.method(enabled: false), Self.mode("2SetKorean", "2벌식", enabled: true)]
        #expect(InputSourceManager.appleKoreanModeNames(in: sources).isEmpty)
    }

    @Test("no Korean input method installed means nothing to remove")
    func nothingInstalled() {
        #expect(InputSourceManager.appleKoreanModeNames(in: []).isEmpty)
    }
}
