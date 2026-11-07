import AppKit
import SwiftUI

/// Standard menus, with Settings… (⌘,) opening the main window and Help offering onboarding again.
struct DuoCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("설정…") { app.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        // Both scenes are single windows; there is nothing to create.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .help) {
            Button("Duo 시작하기 안내") { app.showOnboarding(at: .welcome) }
            Divider()
            Button("키보드 설정 열기…") { SystemSettings.openKeyboard() }
        }
    }
}

/// Deep links into System Settings.
enum SystemSettings {
    /// Keyboard ▸ Text Input (critique V8).
    static let keyboardURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    @MainActor static func openKeyboard() {
        NSWorkspace.shared.open(keyboardURL)
    }
}
