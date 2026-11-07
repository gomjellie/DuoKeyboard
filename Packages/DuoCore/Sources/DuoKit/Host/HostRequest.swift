import AppKit
import Foundation

/// Requests other Duo processes (the input method's menu) can make of the host app, Duo.app.
public enum HostRequest {
    /// Distributed notification asking a running Duo.app to show its setup guide (no payload).
    public static let showGuideNotification = Notification.Name("com.inkyuoh.Duo.host.showGuide")
    /// Launch argument with the same meaning, for a Duo.app that is not running yet.
    public static let showGuideArgument = "--duo-show-guide"

    /// Distributed notification asking a running Duo.app to show its Settings window (no payload).
    public static let showSettingsNotification = Notification.Name("com.inkyuoh.Duo.host.showSettings")
    /// Launch argument with the same meaning, for a Duo.app that is not running yet. Settings opens
    /// even if onboarding was never finished: Duo is evidently in use.
    public static let showSettingsArgument = "--duo-show-settings"

    /// Opens Duo.app — launching it with `showGuideArgument` if needed — and asks it to show the
    /// setup guide (input menu ▸ "Duo 도움말"). A no-op when Duo.app cannot be found.
    @MainActor
    public static func showGuide() {
        open(notification: showGuideNotification, argument: showGuideArgument)
    }

    /// Opens Duo.app on its Settings window (input menu ▸ "Duo 설정…"). A no-op when Duo.app cannot
    /// be found.
    @MainActor
    public static func showSettings() {
        open(notification: showSettingsNotification, argument: showSettingsArgument)
    }

    @MainActor
    private static func open(notification: Notification.Name, argument: String) {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: DuoIDs.hostAppBundleID).isEmpty
        if running {
            DistributedNotificationCenter.default().postNotificationName(
                notification, object: nil, userInfo: nil, deliverImmediately: true)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DuoIDs.hostAppBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = running ? [] : [argument]
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }
}
