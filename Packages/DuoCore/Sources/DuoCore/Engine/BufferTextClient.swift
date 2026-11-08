import Foundation

/// A `TextClient` backed by a plain string: the unit-test fake and the host app's in-process
/// playground (critique P2 "Playground double processing"). Models marked text, selection and the
/// client quirks the engine must handle.
///
/// It follows `NSTextView`'s `NSTextInputClient` behaviour:
/// - `replacementRange == nil` (`NSNotFound`) means "the marked text if any, else the selection";
/// - after either call the caret sits at the end of the new text (selection `(len, 0)` inside the
///   marked text, critique R18 #5);
/// - a replacement range elsewhere first unmarks the current marked text, which stays in the
///   document as ordinary text.
///
/// ``replacementSupport`` reproduces the clients of imk-platform.md §5.3:
/// - `.full`: every range is honoured;
/// - `.beforeCaretOnly` (Terminal): a range is honoured only if it ends at the caret, otherwise it is
///   silently ignored and the text goes to the caret (the duplicate-text failure the engine must
///   never trigger);
/// - `.none` (iTerm2, Java): ranges are always ignored and `string(in:)` returns `nil`.
///
/// ``ignoresReplacementRanges`` models Monaco (VS Code and its forks): every range is ignored, but
/// `string(in:)` still answers (`ClientProfile.canReplaceCommittedText`).
@MainActor
public final class BufferTextClient: TextClient {
    /// Whole document including the marked text.
    public private(set) var text: String = ""
    /// Marked range in UTF-16 units, or `nil`.
    public private(set) var marked: NSRange?
    /// Caret / selection in UTF-16 units.
    public var selection = NSRange(location: 0, length: 0)
    /// Reported to the engine as the client's bundle id.
    public var bundleIdentifier: String
    /// How replacement ranges and `string(in:)` behave (see the type documentation).
    public var replacementSupport: ReplacementSupport
    /// When `false`, `selectedRange()` reports `NSNotFound` (clients without document access).
    public var reportsSelection = true
    /// When `true`, `insertText` and `setMarkedText` act at the marked text or selection whatever
    /// range they are given, while `string(in:)` keeps answering (Monaco).
    public var ignoresReplacementRanges = false
    /// Called after every mutation.
    public var onChange: (() -> Void)?

    /// Accent of the last dead key the app received, waiting for the next character.
    private var pendingDeadKey: Character?

    /// An empty document with the caret at 0.
    public init(bundleIdentifier: String = "com.inkyuoh.Duo.Playground", replacementSupport: ReplacementSupport = .full) {
        self.bundleIdentifier = bundleIdentifier
        self.replacementSupport = replacementSupport
    }

    /// The committed text only (marked text removed).
    public var committedText: String {
        guard let m = marked else { return text }
        let ns = text as NSString
        return ns.replacingCharacters(in: m, with: "")
    }

    /// The marked substring, or `nil`.
    public var markedText: String? {
        guard let m = marked else { return nil }
        return (text as NSString).substring(with: m)
    }

    /// Document length in UTF-16 units.
    public var length: Int { (text as NSString).length }

    // MARK: TextClient

    public func insertText(_ s: String, replacementRange: NSRange?) {
        let r = target(for: replacementRange)
        replace(r, with: s)
        marked = nil
        selection = NSRange(location: r.location + (s as NSString).length, length: 0)
        onChange?()
    }

    public func setMarkedText(_ s: String, replacementRange: NSRange?) {
        // Like NSTextView: while text is marked, the new marked text replaces it and the range is ignored.
        let r = target(for: marked == nil ? replacementRange : nil)
        replace(r, with: s)
        let len = (s as NSString).length
        marked = len == 0 ? nil : NSRange(location: r.location, length: len)
        selection = NSRange(location: r.location + len, length: 0)
        onChange?()
    }

    public func selectedRange() -> NSRange? { reportsSelection ? selection : nil }
    public func markedRange() -> NSRange? { marked }

    public func string(in range: NSRange) -> String? {
        guard replacementSupport != .none else { return nil }
        let ns = text as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    // MARK: App-side simulation

    /// Replaces the document, unmarks, and puts the caret at the end.
    public func setText(_ newText: String) {
        text = newText
        marked = nil
        selection = NSRange(location: length, length: 0)
        pendingDeadKey = nil
        onChange?()
    }

    /// The app ends the composition by itself, keeping the marked string (Chromium on blur).
    public func unmarkText() {
        marked = nil
        onChange?()
    }

    /// The app clears the field (Slack after sending a message).
    public func clear() { setText("") }

    /// Moves the caret (a click or a programmatic selection change).
    public func select(_ range: NSRange) {
        let len = length
        let location = min(max(0, range.location), len)
        selection = NSRange(location: location, length: min(max(0, range.length), len - location))
        marked = nil
        onChange?()
    }

    /// Simulates the app handling a key the engine passed through (`handle` returned false).
    ///
    /// - Parameters:
    ///   - event: the key.
    ///   - characters: `NSEvent.characters` when known (the playground passes it, so ⌥ letters and
    ///     dead-key sequences produce exactly what the system layout produced). When `nil`, the ABC
    ///     layout is modelled from the key itself, including Caps Lock and the five dead keys.
    public func applyPassedKey(_ event: KeyEvent, characters: String? = nil) {
        let mods = event.modifiers
        if mods.contains(.command) || mods.contains(.control) {
            if mods.contains(.command), case .letter(let k) = event.key, k.base == "a" {
                selection = NSRange(location: 0, length: length)
                marked = nil
                onChange?()
            }
            return
        }
        switch event.key {
        case .letter, .character, .keypad, .space:
            if let characters {
                if !characters.isEmpty { typeText(characters) }
                return
            }
            if event.isDeadKey, let accent = Self.deadKeyAccent(event.key) {
                pendingDeadKey = accent
                return
            }
            // Other ⌥ characters (å ∫ ç) come from the system layout; without `characters` the
            // model types nothing rather than a wrong letter.
            if mods.contains(.option), event.key != .space { return }
            guard let typed = Self.typedCharacter(event) else { return }
            if let accent = pendingDeadKey {
                pendingDeadKey = nil
                typeText(Self.compose(accent, typed))
            } else {
                typeText(String(typed))
            }
        case .returnKey: typeText("\n")
        case .tab: typeText("\t")
        case .backspace:
            if selection.length > 0 {
                insertText("", replacementRange: selection)
            } else if selection.location > 0 {
                let r = (text as NSString).rangeOfComposedCharacterSequence(at: selection.location - 1)
                insertText("", replacementRange: r)
            }
        case .forwardDelete:
            if selection.length > 0 {
                insertText("", replacementRange: selection)
            } else if selection.location < length {
                let r = (text as NSString).rangeOfComposedCharacterSequence(at: selection.location)
                let caret = selection.location
                insertText("", replacementRange: r)
                selection = NSRange(location: caret, length: 0)
            }
        case .arrowLeft:
            let target = selection.length > 0 ? selection.location : max(0, selection.location - 1)
            select(NSRange(location: target, length: 0))
        case .arrowRight:
            let target = selection.length > 0 ? NSMaxRange(selection) : min(length, selection.location + 1)
            select(NSRange(location: target, length: 0))
        case .arrowUp: select(NSRange(location: 0, length: 0))
        case .arrowDown: select(NSRange(location: length, length: 0))
        case .escape, .navigation, .function, .other: break
        }
    }

    // MARK: - Internals

    /// The range an insert or mark actually replaces, after the client's quirks.
    private func target(for requested: NSRange?) -> NSRange {
        let fallback = marked ?? selection
        guard let requested, requested.location != NSNotFound, !ignoresReplacementRanges else { return fallback }
        let len = length
        guard requested.location >= 0, requested.length >= 0, NSMaxRange(requested) <= len else { return fallback }
        switch replacementSupport {
        case .full:
            break
        case .beforeCaretOnly:
            let caret = marked.map(NSMaxRange) ?? NSMaxRange(selection)
            guard NSMaxRange(requested) == caret else { return fallback }
        case .none:
            return fallback
        }
        // An explicit range commits the current marked text as ordinary text first.
        if marked != nil { marked = nil }
        return requested
    }

    private func replace(_ range: NSRange, with s: String) {
        text = (text as NSString).replacingCharacters(in: range, with: s)
    }

    private func typeText(_ s: String) {
        insertText(s, replacementRange: nil)
    }

    /// What the ABC layout types for a key the app receives raw.
    private static func typedCharacter(_ event: KeyEvent) -> Character? {
        switch event.key {
        case .letter(let k):
            let upper = k.shift != event.modifiers.contains(.capsLock)
            return upper ? Character(k.base.uppercased()) : k.base
        case .character(let c), .keypad(let c): return c
        case .space: return " "
        default: return nil
        }
    }

    private static func deadKeyAccent(_ key: KeyEvent.Key) -> Character? {
        switch key {
        case .letter(let k):
            switch k.base {
            case "e": return "\u{0301}"  // acute
            case "u": return "\u{0308}"  // diaeresis
            case "i": return "\u{0302}"  // circumflex
            case "n": return "\u{0303}"  // tilde
            default: return nil
            }
        case .character("`"): return "\u{0300}"  // grave
        default: return nil
        }
    }

    /// Dead key + character, as the ABC layout composes it (é, ü, ñ); a non-composable character
    /// gets the spacing accent first, like macOS.
    private static func compose(_ accent: Character, _ c: Character) -> String {
        let combined = (String(c) + String(accent)).precomposedStringWithCanonicalMapping
        if combined.unicodeScalars.count == 1 { return combined }
        let spacing: String = switch accent {
        case "\u{0301}": "´"
        case "\u{0308}": "¨"
        case "\u{0302}": "ˆ"
        case "\u{0303}": "˜"
        default: "`"
        }
        return c == " " ? spacing : spacing + String(c)
    }
}
