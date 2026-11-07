import AppKit
import DuoKit

/// AppKit lifecycle: single instance, quit with the last window, flush settings on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `DuoApp.init` before launching finishes.
    static var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        handOffToRunningInstance()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        LaunchMode.current.presentsWindows
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.model?.reopen() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let model = Self.model else { return }
        // ⌘Q with onboarding still open counts like closing its window.
        if model.isOnboardingWindowOpen { model.onboardingWindowDidClose() }
        model.settings.flush()
    }

    /// Duo is a single-instance app: a second copy (say, a build next to /Applications/Duo.app)
    /// activates the first one and quits.
    private func handOffToRunningInstance() {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: DuoIDs.hostAppBundleID)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) else { return }
        other.activate()
        exit(0)
    }
}
