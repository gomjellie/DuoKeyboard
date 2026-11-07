import AppKit
import DuoCore
import DuoKit
import Observation
import UniformTypeIdentifiers

/// Settings ▸ 앱별 설정: apps Duo has seen plus running apps, with their names, icons and default
/// profiles (`ClientProfile.forBundleIdentifier`).
@MainActor
@Observable
final class AppsModel {
    struct App: Identifiable, Hashable {
        var bundleID: String
        var name: String
        var icon: NSImage
        var isSeen: Bool
        var isRunning: Bool
        /// The built-in profile for this app (used when the user has no override).
        var defaultProfile: AppProfile
        var id: String { bundleID }
    }

    private(set) var apps: [App] = []

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var cache: [String: (name: String, icon: NSImage)] = [:]

    init() {
        isLive = true
        let center = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
            .map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        // The IME records the apps it types in without telling anyone; catch up when the user comes back.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.viewers > 0 else { return }
                self.refresh()
            }
        })
    }

    /// The pane appeared: refresh now and whenever Duo.app becomes active while it shows.
    func beginObserving() {
        viewers += 1
        refresh()
    }

    func endObserving() {
        viewers = max(0, viewers - 1)
    }

    /// A fixed list for offscreen rendering.
    init(fixture apps: [App]) {
        isLive = false
        self.apps = apps
    }

    func refresh() {
        guard isLive else { return }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let runningByID = Dictionary(running.compactMap { app in app.bundleIdentifier.map { ($0, app) } },
                                     uniquingKeysWith: { first, _ in first })
        let entries = AppCatalog.merge(seen: SettingsStore.seenApps(),
                                       running: running.compactMap(\.bundleIdentifier))
        var seen: [App] = []
        var others: [App] = []
        for entry in entries {
            let (name, icon) = describe(entry.bundleID, running: runningByID[entry.bundleID])
            let app = App(bundleID: entry.bundleID, name: name, icon: icon, isSeen: entry.isSeen,
                          isRunning: entry.isRunning,
                          defaultProfile: ClientProfile.forBundleIdentifier(entry.bundleID).defaultAppProfile)
            if entry.isSeen { seen.append(app) } else { others.append(app) }
        }
        others.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let next = seen + others
        if next != apps { apps = next }
    }

    private func describe(_ bundleID: String, running: NSRunningApplication?) -> (String, NSImage) {
        if let cached = cache[bundleID] { return cached }
        var result: (name: String, icon: NSImage)
        if let running, let name = running.localizedName, let icon = running.icon {
            result = (name, icon)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let display = FileManager.default.displayName(atPath: url.path)
            let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
            result = (name, NSWorkspace.shared.icon(forFile: url.path))
        } else {
            result = (bundleID, NSWorkspace.shared.icon(for: .application))
        }
        cache[bundleID] = result
        return result
    }
}
