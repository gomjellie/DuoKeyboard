import DuoCore
import DuoKit
import SwiftUI

// User-facing names for contract enums. Strings live in Localizable.xcstrings (Korean source).

extension FlipKey: @retroactive Identifiable {
    public var id: Self { self }
}

extension FlipKey {
    /// Short name under the key caps, e.g. "오른쪽 Command".
    var title: String {
        switch self {
        case .rightCommand: String(localized: "오른쪽 Command")
        case .rightOption: String(localized: "오른쪽 Option")
        case .doubleShift: String(localized: "Shift 두 번")
        case .shiftSpace: String(localized: "Shift + Space")
        case .capsLock: String(localized: "Caps Lock")
        }
    }

    /// What to do to flip, as a full sentence (no particle after a key name).
    var instruction: String {
        switch self {
        case .rightCommand: String(localized: "오른쪽 Command 키를 톡 눌러 보세요.")
        case .rightOption: String(localized: "오른쪽 Option 키를 톡 눌러 보세요.")
        case .doubleShift: String(localized: "Shift 키를 빠르게 두 번 눌러 보세요.")
        case .shiftSpace: String(localized: "Shift 키를 누른 채 Space 키를 눌러 보세요.")
        case .capsLock: String(localized: "Caps Lock 키를 눌러 보세요.")
        }
    }

    /// Whether `flipTapWindowMs` matters for this key.
    var usesTapWindow: Bool {
        switch self {
        case .rightCommand, .rightOption, .doubleShift: true
        case .shiftSpace, .capsLock: false
        }
    }
}

extension AppProfile: @retroactive Identifiable {
    public var id: Self { self }
}

extension AppProfile {
    var title: String {
        switch self {
        case .automatic: String(localized: "자동")
        case .koreanFirst: String(localized: "한국어 우선")
        case .englishFirst: String(localized: "English 우선")
        case .direct: String(localized: "직접 입력")
        }
    }
}

extension LanguageContext {
    /// The 문맥 column of the learning table.
    var title: String {
        switch self {
        case .start: String(localized: "문장 시작")
        case .korean: String(localized: "한국어 뒤")
        case .english: String(localized: "영어 뒤")
        case .number: String(localized: "숫자 뒤")
        }
    }
}

extension BackspaceUnit: @retroactive Identifiable {
    public var id: Self { self }
}

extension BackspaceUnit {
    var title: String {
        switch self {
        case .jaso: String(localized: "자소")
        case .gulja: String(localized: "글자")
        }
    }
}

extension InputMethodInstaller.Step: @retroactive Identifiable {
    public var id: Self { self }
}

extension InputMethodInstaller.Step {
    /// Checklist label (복사 · 등록 · macOS 허용 · 활성화 · 선택).
    var title: String {
        switch self {
        case .copied: String(localized: "Duo 입력기 복사")
        case .registered: String(localized: "입력 소스로 등록")
        case .allowListed: String(localized: "macOS에서 허용")
        case .enabled: String(localized: "입력 소스 켜기")
        case .selected: String(localized: "Duo로 전환")
        }
    }

    var detail: String {
        switch self {
        case .copied: String(localized: "사용자 Library의 Input Methods 폴더에 넣어요.")
        case .registered: String(localized: "macOS가 Duo를 입력 소스로 알아보게 해요.")
        case .allowListed: String(localized: "시스템 설정에 뜨는 확인 창에서 ‘허용’을 눌러요.")
        case .enabled: String(localized: "입력 메뉴에 Duo가 나타나요.")
        case .selected: String(localized: "지금 바로 Duo로 입력해요.")
        }
    }
}
