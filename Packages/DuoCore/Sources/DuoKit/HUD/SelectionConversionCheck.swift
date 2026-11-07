import DuoCore
import Foundation

/// What "선택한 텍스트 한↔A 변환" (ux-spec §5.2) does before it touches the text.
///
/// The HUD message "여기서는 바꿀 수 없어요" (ux-spec §5.3) means the *app* cannot replace text. Having
/// nothing to convert is not that: there the menu command answers with the standard macOS beep, and
/// it does so before committing a composition, so a mistaken choice changes nothing.
public enum SelectionConversionCheck: Hashable, Sendable {
    /// Read the text in this range and convert it.
    case convert(NSRange)
    /// No selection, or one longer than ``SelectionConverter/maxLength``: beep, no HUD.
    case nothingToConvert
    /// The client cannot replace text: show "여기서는 바꿀 수 없어요".
    case cannotChange

    /// - Parameters:
    ///   - replacement: `ClientProfile.replacement` of the client.
    ///   - selection: the client's `selectedRange()`, `nil` when it reports `NSNotFound`.
    ///   - maxLength: the converter's cap, in UTF-16 units of the selection.
    public static func check(replacement: ReplacementSupport, selection: NSRange?,
                             maxLength: Int = SelectionConverter.maxLength) -> SelectionConversionCheck {
        guard replacement != .none else { return .cannotChange }
        guard let selection, selection.location != NSNotFound, selection.location >= 0,
              selection.length > 0, selection.length <= maxLength else { return .nothingToConvert }
        return .convert(selection)
    }
}
