// CONTRACT FILE: owned by the lead. Settings persistence + change notification shared by the host
// app and the IME (critique R6).

import DuoCore
import Foundation

public enum SettingsStore {
    /// `UserDefaults(suiteName: DuoIDs.sharedSuite)`. Never nil for this name (it is not our bundle id).
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: DuoIDs.sharedSuite) ?? .standard
    }

    /// Current settings (defaults for anything missing or unreadable).
    public static func load() -> DuoSettings {
        // Pick up writes from the other process.
        CFPreferencesAppSynchronize(DuoIDs.sharedSuite as CFString)
        return decode(defaults.data(forKey: DuoIDs.settingsDefaultsKey))
    }

    /// Persists `settings` and tells the other process.
    ///
    /// Keys this build does not know, and per-app profiles it cannot read, stay as stored: the host
    /// and the IME can be different versions while an update is pending (review safety-7).
    public static func save(_ settings: DuoSettings) {
        CFPreferencesAppSynchronize(DuoIDs.sharedSuite as CFString)
        guard let data = blob(writing: settings, over: defaults.data(forKey: DuoIDs.settingsDefaultsKey), base: nil)
        else { return }
        store(data)
    }

    /// Read-modify-write helper. Only what `change` changed is written; everything else keeps its
    /// stored form, including values this build cannot read.
    public static func update(_ change: (inout DuoSettings) -> Void) {
        CFPreferencesAppSynchronize(DuoIDs.sharedSuite as CFString)
        let stored = defaults.data(forKey: DuoIDs.settingsDefaultsKey)
        let before = decode(stored)
        var after = before
        change(&after)
        guard let data = blob(writing: after, over: stored, base: before) else { return }
        store(data)
    }

    // MARK: Blob

    static func decode(_ data: Data?) -> DuoSettings {
        guard let data, let settings = try? JSONDecoder().decode(DuoSettings.self, from: data) else { return .default }
        return settings
    }

    private static func store(_ data: Data) {
        defaults.set(data, forKey: DuoIDs.settingsDefaultsKey)
        CFPreferencesAppSynchronize(DuoIDs.sharedSuite as CFString)
        DistributedNotificationCenter.default().postNotificationName(
            DuoIDs.Notifications.settingsChanged, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static let profilesKey = "appProfiles"

    /// The JSON blob to store for `settings`, merged over the `stored` one.
    ///
    /// - Top-level keys this build does not encode are kept.
    /// - Without `base` (a whole-value save), every key this build knows is written. In
    ///   `appProfiles`, stored apps whose profile this build cannot read are kept unless `settings`
    ///   sets that app.
    /// - With `base` (the decoded value `settings` was derived from), only keys and apps whose value
    ///   differs from `base` are written; the rest keep their stored form.
    /// - A missing or unreadable `stored` blob is replaced by `settings` as encoded.
    static func blob(writing settings: DuoSettings, over stored: Data?, base: DuoSettings?) -> Data? {
        guard let encoded = try? JSONEncoder().encode(settings) else { return nil }
        guard let stored, var merged = jsonObject(stored), let fresh = jsonObject(encoded) else { return encoded }
        let old = base.flatMap { try? JSONEncoder().encode($0) }.flatMap(jsonObject)
        for (key, value) in fresh {
            if key == profilesKey {
                merged[key] = mergedProfiles(stored: merged[key] as? [String: Any], fresh: value as? [String: Any] ?? [:],
                                             base: old.map { $0[key] as? [String: Any] ?? [:] })
            } else if let old, merged[key] != nil, same(old[key], value) {
                continue
            } else {
                merged[key] = value
            }
        }
        return try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }

    /// `appProfiles` for ``blob(writing:over:base:)``.
    static func mergedProfiles(stored: [String: Any]?, fresh: [String: Any], base: [String: Any]?) -> [String: Any] {
        var out = stored ?? [:]
        if let base {
            for app in Set(base.keys).union(fresh.keys) where !same(base[app], fresh[app]) {
                out[app] = fresh[app]
            }
        } else {
            out = out.filter { ($0.value as? String).flatMap(AppProfile.init(rawValue:)) == nil }
            out.merge(fresh) { _, new in new }
        }
        return out
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as? NSObject)?.isEqual(b) ?? false
        default: false
        }
    }

    /// Calls `handler` on the main queue whenever the settings change in either process.
    public static func observe(_ handler: @escaping @MainActor @Sendable () -> Void) -> any NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: DuoIDs.Notifications.settingsChanged, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { handler() } }
    }

    // MARK: Seen apps (IME writes, host reads)

    public static func recordSeenApp(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var list = defaults.stringArray(forKey: DuoIDs.seenAppsDefaultsKey) ?? []
        if list.first == bundleID { return }
        list.removeAll { $0 == bundleID }
        list.insert(bundleID, at: 0)
        defaults.set(Array(list.prefix(200)), forKey: DuoIDs.seenAppsDefaultsKey)
    }

    public static func seenApps() -> [String] {
        CFPreferencesAppSynchronize(DuoIDs.sharedSuite as CFString)
        return defaults.stringArray(forKey: DuoIDs.seenAppsDefaultsKey) ?? []
    }
}
