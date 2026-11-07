import AppKit

/// The IME process's application delegate. `NSSupportsSuddenTermination` is `false` in Info.plist,
/// so logout and shutdown come through here and the learning store is flushed (critique R14).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DuoRuntime.shared.flushLearningSynchronously()
    }
}
