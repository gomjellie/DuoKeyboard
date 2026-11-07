import DuoCore

/// What the HUD chip draws for one ``HUDRequest`` (ui-design §2.2 merged with critique R12): a
/// language badge (가 orange / A blue), an optional text, and the flip key's keycaps. The SwiftUI view
/// renders this value and nothing else, so the mapping is unit-tested here.
public struct HUDPresentation: Hashable, Sendable {
    /// The five request kinds of `HUDRequest.Content`.
    public enum Kind: Hashable, Sendable {
        /// The other reading of the token being composed.
        case alternative
        /// "↺" chip offering to flip the word just committed.
        case flipLastWord
        /// Badge only: the next word will be typed in this language.
        case oneShot
        /// "여기서는 바꿀 수 없어요" (the client cannot replace text).
        case cannotChange
        /// Small dimmed badge: Bilingual is on for this line of a Direct-profile app.
        case bilingualLine
    }

    public var kind: Kind
    /// The alternative reading; empty for badge-only and message kinds (the view supplies the
    /// localized message for ``Kind/cannotChange``).
    public var text: String
    /// Language of the badge, or `nil` for no badge.
    public var badge: ScriptLanguage?
    /// Flip-key glyphs to draw as keycaps after the text (empty = none).
    public var keycaps: [String]

    public init(kind: Kind, text: String = "", badge: ScriptLanguage? = nil, keycaps: [String] = []) {
        self.kind = kind
        self.text = text
        self.badge = badge
        self.keycaps = keycaps
    }

    /// Maps engine content to what the chip shows. Keycaps hint the flip key only where flipping is
    /// the next useful action (an alternative or the flip-last-word chip).
    public init(_ content: HUDRequest.Content, flipKey: FlipKey) {
        switch content {
        case .alternative(let text, let language, _):
            self.init(kind: .alternative, text: text, badge: language, keycaps: flipKey.keycaps)
        case .flipLastWord(let text, let language):
            self.init(kind: .flipLastWord, text: text, badge: language, keycaps: flipKey.keycaps)
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

    /// The chip shows the "↺" glyph before the text.
    public var showsUndoGlyph: Bool { kind == .flipLastWord }

    /// The chip is just the badge (a 28 pt glass circle).
    public var isBadgeOnly: Bool { badge != nil && text.isEmpty && keycaps.isEmpty && kind != .cannotChange }

    /// Opacity of the whole chip: the Bilingual-line badge is a quiet, persistent indicator (ux-spec §7.2).
    public var opacity: Double { kind == .bilingualLine ? 0.6 : 1 }
}
