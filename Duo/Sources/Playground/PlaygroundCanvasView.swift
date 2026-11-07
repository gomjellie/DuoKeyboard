import AppKit
import DuoCore
import DuoKit

/// The playground's text surface when Duo is not the selected input source.
///
/// `inputContext` is `nil`, so no input method (Duo or any other) sees these keys: they go straight
/// to the in-process engine (critique P2). The view lays the text out with TextKit and draws it
/// itself, the marked range underlined, with the system insertion indicator as its caret.
final class PlaygroundCanvasView: NSView {
    static let font = NSFont.systemFont(ofSize: 18)
    static let inset = NSSize(width: 14, height: 12)

    let model: PlaygroundModel
    var placeholder = "" { didSet { needsDisplay = true } }
    /// Become first responder when first placed in a window.
    var takesInitialFocus = false
    /// Where the HUD chip should hang (below the marked text, or the caret), in view coordinates.
    private(set) var hudAnchor: NSRect = .zero

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()
    private let caret = NSTextInsertionIndicator()
    private var scrollY: CGFloat = 0
    /// Notified when `hudAnchor` moves.
    var onAnchorChange: ((NSRect) -> Void)?
    /// What VoiceOver was last told, so a resize or redraw posts nothing.
    private var spokenText = ""
    private var spokenSelection = NSRange(location: 0, length: 0)
    private var spokenFlip = 0

    init(model: PlaygroundModel) {
        self.model = model
        super.init(frame: .zero)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        caret.displayMode = .hidden
        addSubview(caret)
        spokenText = model.text
        spokenSelection = model.selection
        spokenFlip = model.lastFlip?.serial ?? 0
        model.onDisplayChange = { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { model.availability == .ready }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    /// No input context: keys never reach an input method (critique P2).
    override var inputContext: NSTextInputContext? { nil }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        model.hasFocus = true
        updateCaret()
        return true
    }

    override func resignFirstResponder() -> Bool {
        model.commit(.deactivate)
        model.hasFocus = false
        updateCaret()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window)
        }
        if takesInitialFocus {
            takesInitialFocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    @objc private func windowKeyChanged(_ note: Notification) {
        if note.name == NSWindow.didResignKeyNotification { model.commit(.deactivate) }
        updateCaret()
    }

    // MARK: Events

    override func keyDown(with event: NSEvent) {
        switch model.handleKeyDown(event) {
        case .handled: break
        case .focusNext: window?.selectNextKeyView(self)
        case .focusPrevious: window?.selectPreviousKeyView(self)
        case .unhandled: super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        model.handleFlagsChanged(event)
        super.flagsChanged(with: event)
    }

    /// Menu shortcuts (⌘C, ⌘A) are handled before `keyDown`, which then never comes. The engine sees
    /// them first, as the IME would, so right ⌘ held for ⌘C is a chord and not a flip tap. The window
    /// offers key equivalents to every view, hence the first-responder check.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self { model.noteShortcut(event) }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        } else {
            model.commit(.mouse)
        }
    }

    override func selectAll(_ sender: Any?) { model.selectAll() }

    @objc func copy(_ sender: Any?) {
        let ns = model.text as NSString
        let range = model.selection.length > 0 ? model.selection : NSRange(location: 0, length: ns.length)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ns.substring(with: range), forType: .string)
    }

    // MARK: Layout & drawing

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reload()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reload()
    }

    private func reload() {
        container.size = NSSize(width: max(1, bounds.width - 2 * Self.inset.width), height: .greatestFiniteMagnitude)
        storage.setAttributedString(attributedText())
        layoutManager.ensureLayout(for: container)
        let caretRect = caretRectInContainer(at: model.selection.location)
        let visibleHeight = bounds.height - 2 * Self.inset.height
        scrollY = max(0, caretRect.maxY - visibleHeight)
        updateCaret()
        updateAnchor(caretRect: caretRect)
        needsDisplay = true
        postAccessibilityChanges()
    }

    private func attributedText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakStrategy = .hangulWordPriority
        paragraph.lineSpacing = 2
        let s = NSMutableAttributedString(string: model.text, attributes: [
            .font: Self.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        if let marked = model.markedRange, NSMaxRange(marked) <= s.length {
            s.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.controlAccentColor,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12),
            ], range: marked)
        }
        if model.selection.length > 0, NSMaxRange(model.selection) <= s.length {
            s.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: model.selection)
        }
        return s
    }

    private var textOrigin: NSPoint { NSPoint(x: Self.inset.width, y: Self.inset.height - scrollY) }

    override func draw(_ dirtyRect: NSRect) {
        if model.text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.placeholderTextColor]
            (placeholder as NSString).draw(at: textOrigin, withAttributes: attrs)
            return
        }
        let glyphs = layoutManager.glyphRange(for: container)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        layoutManager.drawBackground(forGlyphRange: glyphs, at: textOrigin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: textOrigin)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The insertion point rect for a character index, in text-container coordinates.
    private func caretRectInContainer(at index: Int) -> NSRect {
        let lineHeight = layoutManager.defaultLineHeight(for: Self.font)
        let length = storage.length
        guard length > 0 else { return NSRect(x: 0, y: 0, width: 1, height: lineHeight) }
        if index >= length {
            if layoutManager.extraLineFragmentTextContainer != nil {
                let extra = layoutManager.extraLineFragmentRect
                return NSRect(x: extra.minX, y: extra.minY, width: 1, height: extra.height)
            }
            let last = layoutManager.glyphIndexForCharacter(at: length - 1)
            let line = layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            let glyph = layoutManager.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
            return NSRect(x: glyph.maxX, y: line.minY, width: 1, height: line.height)
        }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(0, index))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphIndex)
        return NSRect(x: line.minX + location.x, y: line.minY, width: 1, height: line.height)
    }

    private func toView(_ rect: NSRect) -> NSRect {
        rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
    }

    private func updateCaret() {
        let focused = window?.firstResponder === self && window?.isKeyWindow == true && model.selection.length == 0
        caret.displayMode = focused ? .automatic : .hidden
        caret.frame = toView(caretRectInContainer(at: model.selection.location))
    }

    private func updateAnchor(caretRect: NSRect) {
        var anchor = toView(caretRect)
        if let marked = model.markedRange, NSMaxRange(marked) <= storage.length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: marked, actualCharacterRange: nil)
            anchor = toView(layoutManager.boundingRect(forGlyphRange: glyphs, in: container))
        }
        if anchor != hudAnchor {
            hudAnchor = anchor
            onAnchorChange?(anchor)
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { String(localized: "써보기 입력 칸") }
    override func accessibilityValue() -> Any? { model.text }
    override func accessibilityNumberOfCharacters() -> Int { (model.text as NSString).length }
    override func accessibilitySelectedTextRange() -> NSRange { model.selection }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: (model.text as NSString).length)
    }

    override func accessibilitySelectedText() -> String? {
        accessibilityString(for: model.selection)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let ns = model.text as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityLine(for: model.selection.location)
    }

    override func accessibilityLine(for index: Int) -> Int {
        lineRanges().lastIndex { $0.location <= index } ?? 0
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let lines = lineRanges()
        return lines.indices.contains(line) ? lines[line] : NSRange(location: NSNotFound, length: 0)
    }

    /// Character ranges of the laid-out lines (one empty line for an empty field).
    private func lineRanges() -> [NSRange] {
        var lines: [NSRange] = []
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { [layoutManager] _, _, _, glyphRange, _ in
            lines.append(layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil))
        }
        if lines.isEmpty || layoutManager.extraLineFragmentTextContainer != nil {
            lines.append(NSRange(location: storage.length, length: 0))
        }
        return lines
    }

    /// Tells VoiceOver what changed, and speaks a flip the way the IME does (ux-spec §7.5). Only the
    /// engine canvas does this: in native mode the IME itself announces.
    private func postAccessibilityChanges() {
        if model.text != spokenText {
            spokenText = model.text
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        if model.selection != spokenSelection {
            spokenSelection = model.selection
            NSAccessibility.post(element: self, notification: .selectedTextChanged)
        }
        guard let flip = model.lastFlip, flip.serial != spokenFlip else { return }
        spokenFlip = flip.serial
        guard NSWorkspace.shared.isVoiceOverEnabled, window?.firstResponder === self else { return }
        let message = switch (flip.language, flip.word.isEmpty) {
        case (.korean, false): String(localized: "\(flip.word), 한국어로 바꿈")
        case (.english, false): String(localized: "\(flip.word), 영어로 바꿈")
        case (.korean, true): String(localized: "한국어로 바꿈")
        case (.english, true): String(localized: "영어로 바꿈")
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
