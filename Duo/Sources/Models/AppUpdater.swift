import AppKit
import DuoKit
import Foundation
import Observation

/// Duo.app's self-update (DuoKit `AppUpdate`): look at the feed, download and verify the new app,
/// and swap it in when Duo.app quits. Shown in Settings ▸ 일반 ▸ Duo 업데이트.
///
/// With 자동으로 업데이트 on, a check runs at launch and when the input method asks (once a day).
/// The input method asks a Duo.app that is not running to start in the background
/// (`HostRequest.checkForUpdatesArgument`): ``runInBackground(status:)``.
@MainActor
@Observable
final class AppUpdater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(BundleVersion)
        /// Downloaded and verified; installed when Duo.app quits.
        case ready(BundleVersion)
        case needsNewerSystem(BundleVersion, minimum: String)
        /// Duo.app runs from a place that cannot be replaced.
        case cannotReplace(BundleVersion)
        case failed
    }

    private(set) var phase: Phase

    /// The running app's version.
    let current: BundleVersion?

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var staged: Staged?
    @ObservationIgnored private var installerStarted = false

    private struct Staged {
        var app: URL
        var directory: URL
    }

    /// - Parameter fixedPhase: a fixture for offscreen rendering; disables every action.
    init(fixedPhase: Phase? = nil) {
        isLive = fixedPhase == nil
        phase = fixedPhase ?? .idle
        current = BundleVersion(bundleURL: Bundle.main.bundleURL)
    }

    var isWorking: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    // MARK: Checking

    /// Looks at the feed and, when there is a newer Duo, downloads and verifies it.
    func check() async {
        guard isLive, !isWorking, staged == nil, let current else { return }
        phase = .checking
        AppUpdate.recordAttempt(Date())
        do {
            let feed = try await Self.fetchFeed()
            switch AppUpdate.decide(feed, current: current, system: ProcessInfo.processInfo.operatingSystemVersion) {
            case .upToDate:
                phase = .upToDate
            case .needsNewerSystem(let feed):
                phase = .needsNewerSystem(feed.bundleVersion, minimum: feed.minimumSystemVersion)
            case .available(let feed):
                guard AppUpdate.canReplace(appAt: Bundle.main.bundleURL) else {
                    phase = .cannotReplace(feed.bundleVersion)
                    return
                }
                phase = .downloading(feed.bundleVersion)
                staged = try await Self.stage(feed)
                phase = .ready(feed.bundleVersion)
            }
        } catch {
            Self.log("update check failed: \(error)")
            phase = .failed
        }
    }

    /// ``check()`` when 자동으로 업데이트 is on and the last check is a day old.
    func checkIfDue(autoUpdate: Bool) async {
        guard autoUpdate, AppUpdate.isCheckDue(lastAttempt: AppUpdate.lastAttempt(), now: Date()) else { return }
        await check()
    }

    nonisolated private static func fetchFeed() async throws -> AppUpdate.Feed {
        let (data, response) = try await session.data(from: AppUpdate.feedURL(in: SettingsStore.defaults))
        try requireSuccess(response)
        return try JSONDecoder().decode(AppUpdate.Feed.self, from: data)
    }

    /// Downloads the zip, checks it against the feed and unpacks it into a new temporary folder.
    nonisolated private static func stage(_ feed: AppUpdate.Feed) async throws -> Staged {
        let (data, response) = try await session.data(from: feed.url)
        try requireSuccess(response)
        try AppUpdate.verify(archive: data, against: feed)
        let directory = FileManager.default.temporaryDirectory.appending(path: "duo-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let archive = directory.appending(path: "Duo.zip")
            try data.write(to: archive)
            let app = try await Task.detached(priority: .utility) {
                try AppUpdate.unpack(archive: archive, into: directory, expecting: feed)
            }.value
            return Staged(app: app, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    nonisolated private static func requireSuccess(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    /// No cookies, no cache, no credentials: the feed and the zip are public files.
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    // MARK: Installing

    /// "지금 설치": install the downloaded Duo now and open it on Settings.
    func installAndRelaunch() {
        guard startInstaller(relaunch: .foreground, arguments: [HostRequest.showSettingsArgument]) else { return }
        NSApp.terminate(nil)
    }

    /// Duo.app is quitting: install the downloaded Duo. The new Duo.app then starts once in the
    /// background to update the input method.
    func installOnQuit() {
        startInstaller(relaunch: .background, arguments: [HostRequest.checkForUpdatesArgument])
    }

    @discardableResult
    private func startInstaller(relaunch: AppUpdate.Relaunch, arguments: [String]) -> Bool {
        guard isLive, !installerStarted, let staged else { return false }
        do {
            try AppUpdate.startInstaller(newApp: staged.app, target: Bundle.main.bundleURL, relaunch: relaunch,
                                         arguments: arguments, scriptDirectory: staged.directory)
            installerStarted = true
            return true
        } catch {
            Self.log("could not start the update installer: \(error)")
            phase = .failed
            return false
        }
    }

    // MARK: Background run

    /// How long the keyboard must be quiet before the input method is replaced, and how long to
    /// wait for that. Replacing it ends the word being typed.
    static let quietKeyboard: TimeInterval = 15
    static let quietKeyboardTimeout: TimeInterval = 300

    /// `--duo-update-check`: bring the installed input method up to the one inside this Duo.app,
    /// then look for a newer Duo.app and install it. The caller quits afterwards; a newer Duo.app
    /// starts the same way once more, for its input method.
    func runInBackground(status: InputMethodStatus) async {
        guard isLive else { return }
        if status.state.isInstalled, status.isUpdateAvailable, await Self.waitForQuietKeyboard() {
            await status.update()
        }
        await check()
        guard case .ready = phase else { return }
        // Another Duo.app with windows may have started meanwhile: it installs when it quits.
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: DuoIDs.hostAppBundleID)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
        if !others { installOnQuit() }
    }

    private static func waitForQuietKeyboard() async -> Bool {
        var waited: TimeInterval = 0
        while CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < quietKeyboard {
            guard waited < quietKeyboardTimeout else { return false }
            try? await Task.sleep(for: .seconds(5))
            waited += 5
        }
        return true
    }

    nonisolated private static func log(_ message: String) {
        NSLog("Duo update: %@", message)
    }
}
