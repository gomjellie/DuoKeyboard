import DuoKit
import SwiftUI

/// Settings ▸ 일반 ▸ 입력: whether the input method may read the input field of xterm.js terminals
/// (Orca), which puts the choice bar under the word there (`ClientProfile.compositionAtFocusedElement`).
/// The permission belongs to the input method, so the IME reports it (`pong`) and shows the prompt.
struct TerminalHUDAccessRow: View {
    /// `nil` until the input method answers (it is not running, or has not answered yet).
    @State private var trusted: Bool?

    var body: some View {
        LabeledContent {
            switch trusted {
            case true?:
                StatusValue(ok: true, text: "허용됨")
            case false?:
                Button("허용…") {
                    DistributedNotificationCenter.default().postNotificationName(
                        DuoIDs.Notifications.requestAccessibility, object: nil, userInfo: nil, deliverImmediately: true)
                }
            case nil:
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
                if let reply = await InputMethodPing.reply(timeout: .seconds(1)) {
                    trusted = reply[DuoIDs.pongAccessibilityKey] == "true"
                } else {
                    trusted = nil
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
