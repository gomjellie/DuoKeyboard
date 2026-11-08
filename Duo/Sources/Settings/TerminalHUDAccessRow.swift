import AppKit
import DuoKit
import SwiftUI

/// Settings ▸ 일반 ▸ 입력: whether the input method may read the input field of xterm.js terminals
/// (Orca), which puts the choice bar under the word there (`ClientProfile.compositionAtFocusedElement`).
/// The permission belongs to the input method, so the IME reports it (`pong`) and shows the prompt.
struct TerminalHUDAccessRow: View {
    enum Access: Equatable {
        /// The input method did not answer (not running, or not yet).
        case unknown
        /// It answered without the permission key: a build from before this setting.
        case needsUpdate
        case granted
        case denied
    }

    @State private var access = Access.unknown

    var body: some View {
        LabeledContent {
            switch access {
            case .granted:
                StatusValue(ok: true, text: "허용됨")
            case .denied:
                Button("허용…") { Task { await Self.requestAccess() } }
            case .needsUpdate:
                Text("입력기 업데이트 필요")
                    .foregroundStyle(.secondary)
            case .unknown:
                Text("입력기 응답 없음")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text("터미널에서 후보 막대 위치")
            Text("Orca 같은 터미널은 입력기에 입력 위치를 틀리게 알려 줘요. 손쉬운 사용 권한을 주면 Duo가 입력 칸의 위치만 읽어서 막대를 단어 아래에 띄워요.")
        }
        .task {
            // A grant in System Settings shows up here within a few seconds.
            while !Task.isCancelled {
                access = Self.access(from: await InputMethodPing.reply(timeout: .seconds(1)))
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    static func access(from reply: [String: String]?) -> Access {
        guard let reply else { return .unknown }
        guard let value = reply[DuoIDs.pongAccessibilityKey] else { return .needsUpdate }
        return value == "true" ? .granted : .denied
    }

    /// Clears the input method's own Accessibility entry, asks it to request the permission, and
    /// opens the list in System Settings. An entry left by another build of the input method
    /// (another signature) makes macOS ignore both the switch and the request.
    static func requestAccess() async {
        await Task.detached {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", DuoIDs.inputMethodBundleID]
            reset.standardOutput = FileHandle.nullDevice
            reset.standardError = FileHandle.nullDevice
            try? reset.run()
            reset.waitUntilExit()
        }.value
        DistributedNotificationCenter.default().postNotificationName(
            DuoIDs.Notifications.requestAccessibility, object: nil, userInfo: nil, deliverImmediately: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
