import CoreGraphics

/// One display, as the HUD placement math sees it (a value copy of the relevant `NSScreen` fields).
///
/// Every rect is in Cocoa *global* screen coordinates: the origin is the bottom-left corner of the
/// primary display (`NSScreen.screens[0]`) and y grows upward. That is the space IMK returns from
/// `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` and `firstRect(forCharacterRange:)`.
public struct HUDScreen: Sendable, Equatable {
    /// `NSScreen.frame`.
    public var frame: CGRect
    /// `NSScreen.visibleFrame`: the frame minus the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// `NSScreen.backingScaleFactor` (1 or 2), used to snap the chip to whole device pixels.
    public var scale: CGFloat

    public init(frame: CGRect, visibleFrame: CGRect, scale: CGFloat) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
    }
}

/// Where the composition HUD goes for one caret rect.
public struct HUDPlacement: Sendable, Equatable {
    /// Which side of the caret line the chip ended up on.
    public enum Edge: Sendable, Equatable {
        case below
        case above
    }

    /// Frame of the visible glass capsule, in global coordinates.
    public var chipFrame: CGRect
    /// Frame of the transparent panel that hosts the chip plus its shadow margin.
    public var panelFrame: CGRect
    public var edge: Edge

    public init(chipFrame: CGRect, panelFrame: CGRect, edge: Edge) {
        self.chipFrame = chipFrame
        self.panelFrame = panelFrame
        self.edge = edge
    }
}

/// Pure, unit-tested placement math for the composition HUD (ui-design §2.4, ux-spec §7.4, critique R12).
///
/// The HUD controller feeds it the IMK caret rect and the SwiftUI fitting size of the chip; the
/// function never touches AppKit, so every rule is covered by Swift Testing.
public enum HUDGeometry {
    /// Vertical gap between the caret line box and the chip.
    public static let gap: CGFloat = 5
    /// Minimum distance between the chip and the edges of `visibleFrame`.
    public static let screenMargin: CGFloat = 6
    /// The chip's leading edge sits this far left of the marked-text start, so the text column inside
    /// the chip (after the 4 pt padding, the 20 pt badge and 6 pt spacing) lines up with the word.
    public static let leadingOutset: CGFloat = 8
    /// Line height assumed for clients that report a zero-height caret rect.
    public static let fallbackLineHeight: CGFloat = 16
    /// A visible HUD does not move unless the caret rect changed by more than this (ux-spec §7.4.5).
    public static let jitterThreshold: CGFloat = 2
    /// Caret rects larger than this in either dimension are not caret rects (clients have returned
    /// whole-window or whole-document rects); the HUD hides rather than guessing.
    public static let maximumCaretExtent: CGFloat = 1_000

    /// Places the chip for a caret rect.
    ///
    /// - Parameters:
    ///   - rawCaret: line-height rect of the start of the marked text (character index 0), or of the
    ///     location the request is anchored to.
    ///   - chipSize: SwiftUI fitting size of the chip, without the panel margin (``HUDSizing``);
    ///     rounded up to whole device pixels.
    ///   - margin: transparent margin around the chip inside the panel (shadow and pulse overshoot).
    ///   - screens: `NSScreen.screens` mapped to ``HUDScreen``; index 0 is the primary display.
    /// - Returns: `nil` when the caret rect is unusable, in which case the HUD must hide.
    public static func place(caret rawCaret: CGRect, chipSize: CGSize, margin: CGFloat,
                             screens: [HUDScreen]) -> HUDPlacement? {
        guard let first = screens.first, var caret = sanitized(rawCaret) else { return nil }

        // 1. The display that contains the caret (never NSScreen.main: that is the key window's screen,
        //    and the IME process has no key window).
        var screen = screens.first { $0.frame.contains(probe(caret)) }
        // 2. Some clients hand back top-left-origin y. Flip around the primary display's height and
        //    accept the result only if that lands on a display.
        if screen == nil {
            var flipped = caret
            flipped.origin.y = first.frame.height - caret.maxY
            if let match = screens.first(where: { $0.frame.contains(probe(flipped)) }) {
                caret = flipped
                screen = match
            }
        }
        // 3. Still nowhere: the client gave us garbage. Hide rather than guess.
        guard let screen else { return nil }

        let scale = screen.scale > 0 ? screen.scale : 1
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        // The panel covers whole device pixels and is never narrower than the chip, so a fractional
        // fitting size (180.5 pt on a 1x display) is neither clipped nor squeezed. The small slack
        // keeps floating-point noise from adding a pixel.
        func snapUp(_ value: CGFloat) -> CGFloat { (value * scale - pixelSlack).rounded(.up) / scale }
        let size = CGSize(width: snapUp(chipSize.width), height: snapUp(chipSize.height))

        let visible = screen.visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        guard visible.width >= size.width, visible.height >= size.height else { return nil }

        // Horizontal: align with the word, clamp into the visible frame.
        var x = caret.minX - leadingOutset
        x = min(max(x, visible.minX), visible.maxX - size.width)

        // Vertical: prefer below the line; go above when that would cross the Dock / bottom edge.
        var edge = HUDPlacement.Edge.below
        var y = caret.minY - gap - size.height
        if y < visible.minY {
            edge = .above
            y = caret.maxY + gap
        }
        y = min(max(y, visible.minY), visible.maxY - size.height)

        let chip = CGRect(x: snap(x), y: snap(y), width: size.width, height: size.height)
        return HUDPlacement(chipFrame: chip, panelFrame: chip.insetBy(dx: -margin, dy: -margin), edge: edge)
    }

    /// Device-pixel tolerance for ``place(caret:chipSize:margin:screens:)``'s size rounding.
    private static let pixelSlack: CGFloat = 0.001

    /// The panel's window level (critique R12): one above the client's window and never below pop-up
    /// menus, so the chip clears autocomplete popovers, but always under the shielding level that
    /// covers the lock screen.
    ///
    /// - Parameters:
    ///   - clientLevel: `IMKTextInput.windowLevel()`.
    ///   - popUpMenuLevel: `NSWindow.Level.popUpMenu.rawValue` (101).
    ///   - shieldingLevel: `CGShieldingWindowLevel()`.
    public static func windowLevel(clientLevel: Int, popUpMenuLevel: Int, shieldingLevel: Int) -> Int {
        min(max(clientLevel + 1, popUpMenuLevel), shieldingLevel - 1)
    }

    /// The caret rect a *visible* HUD should use: the previous one when the new rect is within
    /// ``jitterThreshold`` of it on every edge that matters (origin and line height), else the new one.
    ///
    /// Clients report sub-point differences between keystrokes (baseline rounding, a glyph with a
    /// taller ascender); without this the chip would shimmer while the user types.
    public static func stabilized(previous: CGRect?, current: CGRect,
                                  threshold: CGFloat = jitterThreshold) -> CGRect {
        guard let previous else { return current }
        let close = abs(previous.minX - current.minX) <= threshold
            && abs(previous.minY - current.minY) <= threshold
            && abs(previous.height - current.height) <= threshold
        return close ? previous : current
    }

    /// Normalises a client caret rect, or returns `nil` for rects that cannot be a caret:
    /// non-finite or subnormal values (XPC marshalling garbage such as 1.6e-314), an origin at the
    /// primary display's bottom-left corner (what clients without geometry report, with or without
    /// a size, exactly or within a point), negative sizes, or rects larger than
    /// ``maximumCaretExtent``. A zero height becomes ``fallbackLineHeight``.
    public static func sanitized(_ rect: CGRect) -> CGRect? {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard values.allSatisfy({ $0.isZero || $0.isNormal }), !isScreenOrigin(rect),
              rect.size.width >= 0, rect.size.height >= 0,
              rect.size.width <= maximumCaretExtent, rect.size.height <= maximumCaretExtent else { return nil }
        var caret = rect
        if caret.height < 1 { caret.size.height = fallbackLineHeight }
        return caret
    }

    /// Tallest accessibility frame taken for one line of text (``caretFromAccessibilityFrame``).
    public static let maximumAccessibilityLineHeight: CGFloat = 64

    /// The caret rect at the left edge of an accessibility frame, in Cocoa global coordinates.
    ///
    /// `frame` is `AXPosition` + `AXSize` of the client's focused element: top-left origin, y down,
    /// in points from the primary display's top-left corner. The result keeps the frame's left
    /// edge and line, one point wide. `nil` for a frame that cannot be one line of text:
    /// non-finite values, a negative width, a height under a point or over
    /// ``maximumAccessibilityLineHeight`` (a whole text view).
    public static func caretFromAccessibilityFrame(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect? {
        let values = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, primaryScreenHeight]
        guard values.allSatisfy(\.isFinite), frame.size.width >= 0, frame.size.height >= 1,
              frame.size.height <= maximumAccessibilityLineHeight else { return nil }
        return CGRect(x: frame.origin.x, y: primaryScreenHeight - frame.origin.y - frame.size.height,
                      width: 1, height: frame.size.height)
    }

    /// The rect the HUD may follow for a client caret rect, or `nil`: sane (``sanitized(_:)``), not
    /// a window's corner (what Chromium reports without geometry), and inside one of the client's
    /// windows. A rect on no display is tried with top-left-origin y first, as ``place`` does.
    public static func followable(_ rect: CGRect, windows: [CGRect], screens: [HUDScreen]) -> CGRect? {
        guard let caret = sanitized(rect) else { return nil }
        var candidate = rect
        if let primary = screens.first, !screens.contains(where: { $0.frame.contains(probe(caret)) }) {
            var flipped = rect
            flipped.origin.y = primary.frame.height - caret.maxY
            if screens.contains(where: { $0.frame.contains(probe(flipped)) }) { candidate = flipped }
        }
        guard !isWindowCorner(candidate, windows: windows),
              isInsideClientWindow(candidate, windows: windows) else { return nil }
        return candidate
    }

    /// The rect of a word that ends at the caret, from the word's own rect and the caret's line rect.
    ///
    /// Right after a commit TextEdit still answers `firstRect(forCharacterRange:)` from the layout
    /// before the commit, one line off, while the caret's line rect is current. When the two are on
    /// different lines the caret's line wins; the word's x is kept unless it lies after the caret.
    /// After a Return the caret really is on the next line, so the word keeps its own rect.
    public static func wordRect(word: CGRect?, caretLine: CGRect?, caretFollowsNewline: Bool = false) -> CGRect? {
        guard let word else { return caretLine }
        guard let caretLine, !caretFollowsNewline else { return word }
        let halfLine = max(word.height, caretLine.height) / 2
        guard abs(word.midY - caretLine.midY) > halfLine else { return word }
        return CGRect(x: min(word.minX, caretLine.minX), y: caretLine.minY, width: word.width,
                      height: caretLine.height)
    }

    /// Whether `caret` lies in one of the client's on-screen windows, with `tolerance` points of
    /// slack. Some clients report a caret far from their text (a screen corner, a position relative
    /// to the window) when they have none; a HUD there floats away from what the user types.
    /// No known windows means "cannot tell": the caret is accepted.
    public static func isInsideClientWindow(_ caret: CGRect, windows: [CGRect], tolerance: CGFloat = 8) -> Bool {
        guard !windows.isEmpty else { return true }
        let point = probe(caret)
        return windows.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
    }

    /// Within a point of a window's bottom-left or top-left corner: Chromium converts an empty rect at
    /// its view's origin when it has no caret, and no real caret sits exactly on a window's corner.
    static func isWindowCorner(_ rect: CGRect, windows: [CGRect]) -> Bool {
        windows.contains { w in
            abs(rect.minX - w.minX) < 1
                && (abs(rect.minY - w.minY) < 1 || abs(rect.minY - w.maxY) < 1 || abs(rect.maxY - w.maxY) < 1)
        }
    }

    /// At the primary display's bottom-left corner: x within a point of 0 and y within a line of it.
    static func isScreenOrigin(_ rect: CGRect) -> Bool {
        abs(rect.minX) < 1 && abs(rect.minY) < fallbackLineHeight + 4
    }

    /// A `CGWindowListCopyWindowInfo` bounds rect (origin at the top left of the primary display,
    /// y down) in Cocoa global coordinates. `primaryHeight` is the primary display's height.
    public static func cocoaRect(fromWindowBounds bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// The point used to pick a display: the leading edge at mid-line.
    private static func probe(_ caret: CGRect) -> CGPoint { CGPoint(x: caret.minX, y: caret.midY) }
}
