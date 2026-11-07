import AppKit
import DuoCore
import DuoKit

/// Spoken feedback for flips (ux-spec §7.5). The HUD itself is hidden from accessibility so it never
/// steals VoiceOver focus; a flip is announced instead, e.g. "해, 한국어로 바꿈", and so is the
/// feedback a flip-key press shows when it flips nothing (``HUDAnnouncement``).
@MainActor
enum VoiceOverAnnouncer {
    static func announceFlip(word: String, to language: ScriptLanguage) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let message: String
        switch (language, word.isEmpty) {
        case (.korean, false): message = String(localized: "\(word), 한국어로 바꿈")
        case (.english, false): message = String(localized: "\(word), 영어로 바꿈")
        case (.korean, true): message = String(localized: "한국어로 바꿈")
        case (.english, true): message = String(localized: "영어로 바꿈")
        }
        post(message)
    }

    /// The HUD's feedback, spoken: a refused flip, the next word's language, Bilingual for the line.
    static func announce(_ feedback: HUDAnnouncement) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let message: String
        switch feedback {
        case .cannotChange: message = String(localized: "여기서는 바꿀 수 없어요")
        case .oneShot(.korean): message = String(localized: "다음 단어는 한국어")
        case .oneShot(.english): message = String(localized: "다음 단어는 영어")
        case .oneShotCancelled: message = String(localized: "다음 단어 언어 지정 취소")
        case .bilingualLineOn: message = String(localized: "이 줄은 한영 자동")
        case .bilingualLineOff: message = String(localized: "직접 입력으로 돌아감")
        }
        post(message)
    }

    private static func post(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
