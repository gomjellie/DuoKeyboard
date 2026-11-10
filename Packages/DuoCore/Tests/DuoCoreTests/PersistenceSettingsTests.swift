import DuoCore
@testable import DuoKit
import Foundation
import Testing

/// Settings survive version skew between the host app and the IME (review safety-7): an unknown
/// per-app profile drops only that app, and saving keeps what this build cannot read. The blob merge
/// is tested directly; nothing here touches the real shared defaults.
@Suite("Persistence · settings across versions")
struct PersistenceSettingsTests {
    /// A blob from a newer build: one profile and one key this build does not know.
    static let newer = Data("""
        {"appProfiles":{"com.apple.Terminal":"koreanFirst","com.example.New":"bilingual","com.example.Odd":7},
         "showHints":false,"futureKey":{"nested":[1,2]},"flipKey":"fn"}
        """.utf8)

    static func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func oneUnknownProfileDropsOnlyThatApp() throws {
        let settings = try JSONDecoder().decode(DuoSettings.self, from: Self.newer)
        #expect(settings.appProfiles == ["com.apple.Terminal": .koreanFirst])
        #expect(settings.showHints == false)
        #expect(settings.flipKey == .rightCommand, "an unknown flip key falls back to the default")
    }

    @Test func profilesThatAreNotAnObjectFallBackToNone() throws {
        let settings = try JSONDecoder().decode(DuoSettings.self, from: Data(#"{"appProfiles":["x"],"showHints":false}"#.utf8))
        #expect(settings.appProfiles.isEmpty)
        #expect(settings.showHints == false)
    }

    @Test func autoUpdateDefaultsOnAndRoundTrips() throws {
        let older = try JSONDecoder().decode(DuoSettings.self, from: Data(#"{"showHints":true}"#.utf8))
        #expect(older.autoUpdate, "a blob from before the setting checks for updates")
        var off = DuoSettings()
        off.autoUpdate = false
        let back = try JSONDecoder().decode(DuoSettings.self, from: JSONEncoder().encode(off))
        #expect(back.autoUpdate == false)
    }

    @Test func alwaysShowChoicesDefaultsOffAndRoundTrips() throws {
        let older = try JSONDecoder().decode(DuoSettings.self, from: Data(#"{"showHints":true}"#.utf8))
        #expect(older.alwaysShowChoices == false, "a blob from before the setting keeps the bar to likely words")
        var on = DuoSettings()
        on.alwaysShowChoices = true
        let back = try JSONDecoder().decode(DuoSettings.self, from: JSONEncoder().encode(on))
        #expect(back.alwaysShowChoices)
    }

    /// The IME's input menu (`SettingsStore.update`) toggling 힌트 표시 on a newer host's blob.
    @Test func anUpdateWritesOnlyWhatChanged() throws {
        let before = SettingsStore.decode(Self.newer)
        var after = before
        after.showHints = true
        let merged = try Self.object(SettingsStore.blob(writing: after, over: Self.newer, base: before))

        #expect(merged["showHints"] as? Bool == true)
        #expect(merged["flipKey"] as? String == "fn", "a value this build cannot read keeps its stored form")
        #expect((merged["futureKey"] as? [String: Any])?["nested"] as? [Int] == [1, 2])
        let profiles = try #require(merged["appProfiles"] as? [String: Any])
        #expect(profiles["com.apple.Terminal"] as? String == "koreanFirst")
        #expect(profiles["com.example.New"] as? String == "bilingual")
        #expect(profiles["com.example.Odd"] as? Int == 7)
    }

    @Test func anUpdateChangesAndRemovesOnlyTheAppsItTouched() throws {
        let before = SettingsStore.decode(Self.newer)
        var after = before
        after.appProfiles["com.apple.Terminal"] = nil
        after.appProfiles["com.example.New"] = .englishFirst
        after.appProfiles["com.apple.Notes"] = .direct
        let merged = try Self.object(SettingsStore.blob(writing: after, over: Self.newer, base: before))
        let profiles = try #require(merged["appProfiles"] as? [String: Any])

        #expect(profiles["com.apple.Terminal"] == nil)
        #expect(profiles["com.example.New"] as? String == "englishFirst", "setting an app replaces what was stored")
        #expect(profiles["com.apple.Notes"] as? String == "direct")
        #expect(profiles["com.example.Odd"] as? Int == 7)
    }

    /// The host's whole-value save (Settings window).
    @Test func aSaveWritesEveryKnownKeyAndKeepsTheUnknown() throws {
        var settings = SettingsStore.decode(Self.newer)
        settings.appProfiles["com.apple.Terminal"] = nil
        settings.appProfiles["com.apple.Notes"] = .englishFirst
        let merged = try Self.object(SettingsStore.blob(writing: settings, over: Self.newer, base: nil))

        #expect(merged["flipKey"] as? String == "rightCommand", "a whole-value save writes every key it knows")
        #expect(merged["futureKey"] != nil)
        let profiles = try #require(merged["appProfiles"] as? [String: Any])
        #expect(profiles["com.apple.Terminal"] == nil, "a readable profile the user removed is gone")
        #expect(profiles["com.apple.Notes"] as? String == "englishFirst")
        #expect(profiles["com.example.New"] as? String == "bilingual")
        #expect(profiles["com.example.Odd"] as? Int == 7)
    }

    @Test func theMergedBlobReadsBackAsWhatWasWritten() throws {
        var settings = SettingsStore.decode(Self.newer)
        settings.languageBias = -300
        settings.appProfiles["com.apple.Notes"] = .direct
        for base in [nil, SettingsStore.decode(Self.newer)] {
            let data = SettingsStore.blob(writing: settings, over: Self.newer, base: base)
            #expect(SettingsStore.decode(data) == settings)
        }
    }

    @Test(arguments: [nil, Data("not json".utf8), Data("[1,2]".utf8)])
    func withoutAReadableStoredBlobTheEncodedValueIsWritten(_ stored: Data?) throws {
        var settings = DuoSettings()
        settings.graveTypesWon = true
        let data = SettingsStore.blob(writing: settings, over: stored, base: DuoSettings())
        let written = try Self.object(data) as NSDictionary
        #expect(written == (try Self.object(JSONEncoder().encode(settings)) as NSDictionary))
    }
}
