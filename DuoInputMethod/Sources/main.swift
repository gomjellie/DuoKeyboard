import AppKit
import DuoKit
import InputMethodKit

// Entry point of the Duo input method server process.
//
// The application object comes first (the HUD owns an NSPanel), then the singletons (detector,
// learning store and writer, settings, HUD), all before the first controller can be created, i.e.
// before `NSApp.run()` (docs/SPEC.md §2).
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate

let runtime = DuoRuntime.shared
runtime.start()

// Must match `InputMethodConnectionName` in Info.plist.
let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
    ?? "\(DuoIDs.inputMethodBundleID)_Connection"
guard let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier) else {
    Log.runtime.fault("IMKServer could not register \(connectionName, privacy: .public)")
    exit(1)
}

withExtendedLifetime(server) {
    application.run()
}
