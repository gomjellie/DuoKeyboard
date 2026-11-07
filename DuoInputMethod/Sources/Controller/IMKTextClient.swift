import AppKit
import DuoCore
import InputMethodKit

/// Adapts the IMK client proxy to the engine's `TextClient` (docs/SPEC.md §5 C1, critique R18).
///
/// One instance lives as long as its controller. The proxy is bound only for the duration of one
/// IMK callback, so the input method never keeps an XPC proxy alive between events. Every method is
/// one synchronous round trip; the engine keeps to one mark or insert per key (critique R15).
///
/// Invariants enforced here, whatever the engine does:
/// - marked text is always a non-nil `NSAttributedString` with non-nil underline attributes
///   (R18 #4: a `nil` string or attributes crashes some hosts on macOS 26.6);
/// - the marked selection is `(length, 0)`, one clause, `kTSMHiliteConvertedText` (R18 #5);
/// - no empty mark or insert is sent while idle (R18 #3: Office loses the selection);
/// - Java clients get `setMarkedText(x)` right before `insertText(x)` (R17);
/// - a client that does not report the marked range it shows is detected once per session (R15,
///   ux-spec §6.8), and then never makes the engine drop a word as if the app had cleared it.
@MainActor
final class IMKTextClient: TextClient {
    typealias Proxy = any IMKTextInput & NSObjectProtocol

    private(set) var bundleIdentifier: String = ""
    /// From `ClientProfile.needsMarkBeforeInsert` (JetBrains, Android Studio).
    var needsMarkBeforeInsert = false
    /// The last string sent with a mark or an insert (the flipped word, for the VoiceOver announcement).
    private(set) var lastSentText = ""
    /// The proxy of the IMK callback in progress, if any.
    private(set) var proxy: Proxy?

    private weak var controller: IMKInputController?
    /// Whether this client shows marked text we set. Kept in step with every mark, insert and
    /// `markedRange()` answer, so the R18 #3 guard needs no extra XPC call.
    private var hasMarkedText = false
    /// UTF-16 length of the last non-empty mark.
    private var markedLength = 0
    /// The session's first non-empty mark has been checked against `markedRange()`.
    private var markedRangeProbed = false
    /// The client showed our first mark but reported it as `NSNotFound` or with another length
    /// (clients without document access; upstream GLFW reports `length - 1`). For the rest of the
    /// session our own belief stands in for its "nothing marked".
    private(set) var markedRangeUnreliable = false
    /// Bound outside an IMK `handle` callback (a global modifier monitor, a TIS notification, a menu
    /// action). Live QA: TextEdit then answers from a stale cache, so a "nothing marked" proves
    /// nothing either, and our own belief stands in for it until ``unbind()``.
    private var boundOutsideCallback = false

    private static let notFound = NSRange(location: NSNotFound, length: NSNotFound)

    init(controller: IMKInputController) {
        self.controller = controller
    }

    /// Binds the proxy for one IMK callback, or (`outsideCallback`) for work started by something
    /// else, whose client answers may be stale.
    func bind(_ proxy: Proxy, bundleIdentifier: String, outsideCallback: Bool = false) {
        self.proxy = proxy
        self.bundleIdentifier = bundleIdentifier
        boundOutsideCallback = outsideCallback
    }

    func unbind() {
        proxy = nil
        boundOutsideCallback = false
    }

    /// Forget the marked-text belief (a new client session, or the client went away).
    func resetMarkedState() {
        hasMarkedText = false
        markedLength = 0
        markedRangeProbed = false
        markedRangeUnreliable = false
    }

    // MARK: TextClient

    func insertText(_ text: String, replacementRange: NSRange?) {
        guard let proxy else { return unbound(#function) }
        if text.isEmpty, replacementRange == nil, !hasMarkedText {
            Log.ime.debug("skipped empty insert while idle")
            return
        }
        if needsMarkBeforeInsert, replacementRange == nil, !text.isEmpty {
            // AWT drops short inserts that arrive without marked text (JDK-8195675).
            proxy.setMarkedText(markedString(text), selectionRange: Self.caretAtEnd(of: text),
                                replacementRange: Self.notFound)
        }
        proxy.insertText(text as NSString, replacementRange: replacementRange ?? Self.notFound)
        hasMarkedText = false
        lastSentText = text
    }

    func setMarkedText(_ text: String, replacementRange: NSRange?) {
        guard let proxy else { return unbound(#function) }
        if text.isEmpty, replacementRange == nil, !hasMarkedText {
            Log.ime.debug("skipped empty mark while idle")
            return
        }
        proxy.setMarkedText(markedString(text), selectionRange: Self.caretAtEnd(of: text),
                            replacementRange: replacementRange ?? Self.notFound)
        hasMarkedText = !text.isEmpty
        lastSentText = text
        guard !text.isEmpty else { return }
        markedLength = (text as NSString).length
        // Only inside a callback: a stale answer would brand a good client unreliable for the session.
        if !markedRangeProbed, !boundOutsideCallback { probeMarkedRange(proxy) }
    }

    /// One extra round trip per session, right after the first mark: does the client report it?
    private func probeMarkedRange(_ proxy: Proxy) {
        markedRangeProbed = true
        let range = proxy.markedRange()
        markedRangeUnreliable = range.location == NSNotFound || range.length != markedLength
        guard markedRangeUnreliable else { return }
        let reported = range.location == NSNotFound ? "NSNotFound" : "length \(range.length) of \(markedLength)"
        Log.ime.info("\(self.bundleIdentifier, privacy: .public) misreports its marked range (\(reported, privacy: .public)); words are kept across pauses this session")
    }

    func selectedRange() -> NSRange? {
        guard let proxy else { unbound(#function); return nil }
        let range = proxy.selectedRange()
        return range.location == NSNotFound ? nil : range
    }

    func markedRange() -> NSRange? {
        guard let proxy else { unbound(#function); return nil }
        let range = proxy.markedRange()
        if range.location != NSNotFound, range.length > 0 { return range }
        if markedRangeUnreliable || boundOutsideCallback, hasMarkedText {
            // This client's "nothing marked" proves nothing: report our own mark. Its location is
            // unknown, so 0; re-opening committed Latin then refuses instead of guessing. Outside a
            // callback this keeps the pre-check behaviour: the word is committed, never dropped.
            return NSRange(location: 0, length: markedLength)
        }
        hasMarkedText = false
        return nil
    }

    func string(in range: NSRange) -> String? {
        guard let proxy else { unbound(#function); return nil }
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
        return proxy.attributedSubstring(from: range)?.string
    }

    // MARK: Helpers

    /// The marked string with the client's "converted text" underline (`mark(forStyle:at:)`), or a
    /// plain single underline when IMK has none. Never `nil`, never without attributes.
    private func markedString(_ text: String) -> NSAttributedString {
        let length = (text as NSString).length
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let mark = controller?.mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: length)) {
            for (key, value) in mark {
                if let name = key.base as? String { attributes[NSAttributedString.Key(name)] = value }
            }
        }
        if attributes[.underlineStyle] == nil {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func caretAtEnd(of text: String) -> NSRange {
        NSRange(location: (text as NSString).length, length: 0)
    }

    private func unbound(_ function: String) {
        Log.ime.error("TextClient.\(function, privacy: .public) called with no client bound")
    }
}
