import AppKit
import DuoKit

/// AppKit lifecycle: single instance, quit with the last window, flush settings on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `DuoApp.init` before launching finishes.
    static var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        switch LaunchMode.current {
        case .normal:
            handOffToRunningInstance()
        case .updateCheck:
            // Never appear in the Dock, never take the menu bar or focus: the user may be typing.
            NSApp.setActivationPolicy(.prohibited)
            // A running Duo.app checks by itself (HostRequest sends it a notification instead).
            if otherInstance() != nil { exit(0) }
        #if DEBUG
        case .render:
            // Never appear in the Dock, never take the menu bar or focus: the user may be typing.
            NSApp.setActivationPolicy(.prohibited)
        #endif
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LaunchMode.current == .normal {
            // A System Settings cache built while Duo was missing hides Duo from its input source list,
            // and the list the menu bar's input menu reads can lack Duo while Duo is on.
            Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: InputSourceManager.installedBundleURL.path) else { return }
                KeyboardSettingsCache.removeIfStale()
                InputMenuList.addDuoIfMissing()
            }
            if let model = Self.model {
                Task { @MainActor in
                    let autoUpdate = model.settings.value.autoUpdate
                    // A Duo.app that was just replaced brings its input method along.
                    if autoUpdate, model.status.state.isInstalled, model.status.isUpdateAvailable {
                        await model.status.update()
                    }
                    await model.updater.checkIfDue(autoUpdate: autoUpdate)
                }
            }
        }
        if LaunchMode.current == .updateCheck {
            Task { @MainActor in
                if let model = Self.model, model.settings.value.autoUpdate {
                    await model.updater.runInBackground(status: model.status)
                }
                NSApp.terminate(nil)
            }
        }
        #if DEBUG
        if case .render(let directory) = LaunchMode.current, let model = Self.model {
            Task { @MainActor in
                let failures = await SnapshotRenderer(app: model, directory: directory).renderAll()
                exit(failures == 0 ? 0 : 1)
            }
        }
        #endif
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
        model.updater.installOnQuit()
    }

    /// Duo is a single-instance app: a second copy (say, a build next to /Applications/Duo.app)
    /// activates the first one and quits.
    private func handOffToRunningInstance() {
        guard let other = otherInstance() else { return }
        other.activate()
        exit(0)
    }

    /// Another Duo.app with windows. One that is updating in the background (`LaunchMode.updateCheck`)
    /// has no window to come forward, so it does not count.
    private func otherInstance() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: DuoIDs.hostAppBundleID)
            .first { $0.processIdentifier != me && !$0.isTerminated && $0.activationPolicy != .prohibited }
    }
}
