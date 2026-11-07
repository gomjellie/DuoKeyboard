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
    /// non-finite values, an origin of exactly (0, 0) (what clients without geometry report, with or
    /// without a size), negative sizes, or rects larger than ``maximumCaretExtent``.
    /// A zero height becomes ``fallbackLineHeight``.
    public static func sanitized(_ rect: CGRect) -> CGRect? {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard values.allSatisfy(\.isFinite), rect.origin != .zero,
              rect.size.width >= 0, rect.size.height >= 0,
              rect.size.width <= maximumCaretExtent, rect.size.height <= maximumCaretExtent else { return nil }
        var caret = rect
        if caret.height < 1 { caret.size.height = fallbackLineHeight }
        return caret
    }

    /// The point used to pick a display: the leading edge at mid-line.
    private static func probe(_ caret: CGRect) -> CGPoint { CGPoint(x: caret.minX, y: caret.midY) }
}
