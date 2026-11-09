import DuoCore

/// What the HUD chip draws for one ``HUDRequest`` (ui-design §2.2 merged with critique R12). A word
/// with two plausible readings gets the choice bar: both readings with their language badges
/// (가 orange / A blue), the one in the document marked as selected, and the flip key's keycaps.
/// Feedback kinds are a badge or a message. The SwiftUI views render this value and nothing else,
/// so the mapping is unit-tested here.
public struct HUDPresentation: Hashable, Sendable {
    /// The five request kinds of `HUDRequest.Content`.
    public enum Kind: Hashable, Sendable {
        /// The word being composed and its other reading.
        case alternative
        /// The word just committed and its other reading.
        case flipLastWord
        /// Badge only: the next word will be typed in this language.
        case oneShot
        /// "여기서는 바꿀 수 없어요" (the client cannot replace text).
        case cannotChange
        /// Small dimmed badge: Bilingual is on for this line of a Direct-profile app.
        case bilingualLine
    }

    public var kind: Kind
    /// Both readings, for the choice-bar kinds (``Kind/alternative``, ``Kind/flipLastWord``).
    public var choice: HUDChoice?
    /// Language of the badge for the badge kinds, or `nil` for no badge.
    public var badge: ScriptLanguage?
    /// Flip-key glyphs to draw as keycaps at the end (empty = none).
    public var keycaps: [String]
    /// The keycaps name the side ("오른쪽 ⌘"): the flip key is a right-side modifier.
    public var namesKeySide: Bool

    public init(kind: Kind, choice: HUDChoice? = nil, badge: ScriptLanguage? = nil, keycaps: [String] = [],
                namesKeySide: Bool = false) {
        self.kind = kind
        self.choice = choice
        self.badge = badge
        self.keycaps = keycaps
        self.namesKeySide = namesKeySide
    }

    /// Maps engine content to what the chip shows. Keycaps hint the flip key only on the choice
    /// bar, where flipping is the next useful action.
    public init(_ content: HUDRequest.Content, flipKey: FlipKey) {
        switch content {
        case .alternative(let choice, _):
            self.init(kind: .alternative, choice: choice, keycaps: flipKey.keycaps,
                      namesKeySide: flipKey.isRightSideModifier)
        case .flipLastWord(let choice):
            self.init(kind: .flipLastWord, choice: choice, keycaps: flipKey.keycaps,
                      namesKeySide: flipKey.isRightSideModifier)
        case .oneShot(let language):
            self.init(kind: .oneShot, badge: language)
        case .cannotChange:
            self.init(kind: .cannotChange)
        case .bilingualLine:
            self.init(kind: .bilingualLine, badge: .korean)
        }
    }

    /// Nothing to draw (the panel is hidden).
    public static let empty = HUDPresentation(kind: .alternative)

    /// The chip offers a reading to click. Every other chip lets clicks through to the app below.
    public var isClickable: Bool { choice != nil }

    /// The readings carry the numbers 1, 2, 3 …: the digit keys choose them. Only the word being
    /// typed, since a digit typed after a committed word is text.
    public var isNumbered: Bool { kind == .alternative && choice?.numbered == true }

    /// The reading a digit key chooses on a numbered bar: 1 → the first … 9 → the ninth. `nil` for
    /// any other key and for a digit with ⌘, ⌃ or ⌥ (a shortcut).
    public static func readingIndex(for key: KeyEvent) -> Int? {
        guard case .character(let c) = key.key, key.modifiers.isDisjoint(with: [.command, .control, .option]),
              let digit = c.wholeNumberValue, (1...9).contains(digit) else { return nil }
        return digit - 1
    }

    /// The chip is just the badge (a 28 pt glass circle).
    public var isBadgeOnly: Bool { badge != nil && choice == nil && kind != .cannotChange }

    /// Opacity of the whole chip: the Bilingual-line badge is a quiet, persistent indicator (ux-spec §7.2).
    public var opacity: Double { kind == .bilingualLine ? 0.6 : 1 }
}

extension FlipKey {
    /// Right ⌘ or right ⌥. Its keycap names the side: the left key has the same glyph and does not flip.
    public var isRightSideModifier: Bool {
        switch self {
        case .rightCommand, .rightOption: true
        case .doubleShift, .shiftSpace, .capsLock: false
        }
    }
}
