import DuoCore
import Foundation

/// The app list of Settings ▸ 앱별 설정: apps Duo has typed into, plus apps running now (ux-spec §8.2).
public enum AppCatalog {
    /// One app row before names and icons are resolved.
    public struct Entry: Hashable, Sendable, Identifiable {
        /// The app's bundle identifier.
        public var bundleID: String
        /// The IME recorded it as a client (`SettingsStore.seenApps()`).
        public var isSeen: Bool
        /// The app is running now.
        public var isRunning: Bool
        /// `bundleID`.
        public var id: String { bundleID }

        /// Creates an entry.
        public init(bundleID: String, isSeen: Bool, isRunning: Bool) {
            self.bundleID = bundleID
            self.isSeen = isSeen
            self.isRunning = isRunning
        }
    }

    /// Bundle ids that never get a row: Duo's own processes.
    public static let excludedBundleIDs: Set<String> = [
        DuoIDs.hostAppBundleID, DuoIDs.inputMethodBundleID, DuoIDs.harnessBundleID,
    ]

    /// Seen apps first (most recent first), then running apps that are not seen, in the given order.
    /// Duplicates and `excluded` ids are dropped.
    public static func merge(seen: [String], running: [String], excluding excluded: Set<String> = excludedBundleIDs) -> [Entry] {
        let runningSet = Set(running)
        var emitted = Set<String>()
        var result: [Entry] = []
        for id in seen where !id.isEmpty && !excluded.contains(id) && emitted.insert(id).inserted {
            result.append(Entry(bundleID: id, isSeen: true, isRunning: runningSet.contains(id)))
        }
        for id in running where !id.isEmpty && !excluded.contains(id) && emitted.insert(id).inserted {
            result.append(Entry(bundleID: id, isSeen: false, isRunning: true))
        }
        return result
    }

    /// `profiles` with `bundleID` set to `profile`, or the override removed when `profile` equals the
    /// app's default, so a later change of the built-in table still reaches the user.
    public static func setting(_ profile: AppProfile, for bundleID: String, default defaultProfile: AppProfile,
                               in profiles: [String: AppProfile]) -> [String: AppProfile] {
        var copy = profiles
        copy[bundleID] = profile == defaultProfile ? nil : profile
        return copy
    }
}
