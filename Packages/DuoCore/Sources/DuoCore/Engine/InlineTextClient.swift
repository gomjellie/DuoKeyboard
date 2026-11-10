import Foundation

/// A `TextClient` that puts the word being typed straight into the document instead of as marked
/// text, as Apple's Korean input method does in Cocoa apps ("Enter로 바로 보내기", SPEC.md 4.10절).
/// Some apps (Telegram) do not send a message on a Return that arrives while text is marked: they
/// break the line instead.
///
/// The engine keeps speaking in marked text. While ``wantsInline`` is on, each call becomes a
/// replacement of the word's range, which this client records:
/// - `setMarkedText(x)`: the first one inserts `x` at the caret (over a selection); later ones
///   replace the word, `""` deletes it. With a replacement range, that range is replaced.
/// - `insertText(x)` with no range commits the word: the word is replaced only when `x` differs.
/// - `markedRange()` is the recorded range, without a round trip.
///
/// Whether the document still holds the word is checked only by ``confirmWord()``. Checking inside
/// `markedRange()` would lose the range of a word the engine keeps: some callers fall back to the
/// caret on `nil` and keep the word.
///
/// A word keeps the mode it started in: a change of ``wantsInline`` takes effect at the next word.
@MainActor
public final class InlineTextClient: TextClient {
    public let base: any TextClient
    /// The app is in `DuoSettings.inlineApps` and supports it (`ClientProfile.usesInline`).
    public var wantsInline = false
    /// The word in the document, while one is being typed inline.
    public private(set) var wordRange: NSRange?
    private var word = ""
    /// Marked text went through to `base` and may still be there: that word stays marked text.
    private var baseHasMarkedText = false

    public init(base: any TextClient) {
        self.base = base
    }

    public var bundleIdentifier: String { base.bundleIdentifier }

    /// Forget the word (a new client session).
    public func reset() {
        wordRange = nil
        word = ""
        baseHasMarkedText = false
    }

    /// Whether the document still holds the word, with the caret right after it. Call inside an IMK
    /// callback when the app may have changed the text without the engine: it sent the message on a
    /// Return it handled itself, or the user clicked its Send button. On `false` the word is
    /// forgotten here, and the caller must drop it from the engine
    /// (``CompositionEngine/dropComposition()``).
    public func confirmWord() -> Bool {
        guard let range = wordRange else { return true }
        if base.selectedRange() == NSRange(location: NSMaxRange(range), length: 0), base.string(in: range) == word {
            return true
        }
        wordRange = nil
        word = ""
        return false
    }

    // MARK: TextClient

    public func setMarkedText(_ text: String, replacementRange: NSRange?) {
        if let range = wordRange {
            if replacementRange == nil, text == word { return }
            let target = replacementRange ?? range
            base.insertText(text, replacementRange: target)
            record(text, at: target.location)
            return
        }
        guard wantsInline, !baseHasMarkedText else {
            base.setMarkedText(text, replacementRange: replacementRange)
            baseHasMarkedText = !text.isEmpty
            return
        }
        if let replacementRange {
            base.insertText(text, replacementRange: replacementRange)
            record(text, at: replacementRange.location)
            return
        }
        guard !text.isEmpty else { return }
        guard let selection = base.selectedRange() else {
            // No position to record: this word stays marked text.
            base.setMarkedText(text, replacementRange: nil)
            baseHasMarkedText = true
            return
        }
        base.insertText(text, replacementRange: nil)
        record(text, at: selection.location)
    }

    public func insertText(_ text: String, replacementRange: NSRange?) {
        guard let range = wordRange else {
            base.insertText(text, replacementRange: replacementRange)
            if replacementRange == nil { baseHasMarkedText = false }
            return
        }
        let typed = word
        wordRange = nil
        word = ""
        if let replacementRange {
            base.insertText(text, replacementRange: replacementRange)
        } else if text != typed {
            base.insertText(text, replacementRange: range)
        }
    }

    public func markedRange() -> NSRange? {
        if let wordRange { return wordRange }
        if wantsInline, !baseHasMarkedText { return nil }
        let range = base.markedRange()
        if range == nil { baseHasMarkedText = false }
        return range
    }

    public func selectedRange() -> NSRange? { base.selectedRange() }

    public func string(in range: NSRange) -> String? { base.string(in: range) }

    private func record(_ text: String, at location: Int) {
        let length = (text as NSString).length
        wordRange = length == 0 ? nil : NSRange(location: location, length: length)
        word = length == 0 ? "" : text
    }
}
