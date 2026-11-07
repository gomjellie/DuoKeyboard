import CoreGraphics
import DuoKit
import Testing

/// Primary 1512×982 @2x laptop (33 pt menu bar, no Dock reserve), external 2560×1440 @1x to the right
/// and 200 pt lower, and a laptop with a 70 pt Dock at the bottom.
private enum Displays {
    static let laptop = HUDScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949), scale: 2)
    static let external = HUDScreen(frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                                    visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1407), scale: 1)
    static let laptopWithDock = HUDScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                          visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879), scale: 2)
    static let both = [laptop, external]
}

private let chip = CGSize(width: 120, height: 28)
private let margin: CGFloat = 8

@Suite("HUD placement")
struct HUDGeometryTests {
    @Test("sits below the caret, aligned with the marked-text start")
    func placesBelowCaret() throws {
        let caret = CGRect(x: 400, y: 500, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin, screens: Displays.both))
        #expect(p.edge == .below)
        #expect(p.chipFrame.maxY == caret.minY - HUDGeometry.gap)
        #expect(p.chipFrame.minX == caret.minX - HUDGeometry.leadingOutset)
        #expect(p.chipFrame.size == chip)
        #expect(p.panelFrame == p.chipFrame.insetBy(dx: -margin, dy: -margin))
    }

    @Test("flips above the caret when the chip would cross the Dock")
    func flipsAboveNearDock() throws {
        // Caret line just above the Dock: below would end at y = 72 - 5 - 28 = 39 < 70 + 6.
        let caret = CGRect(x: 400, y: 72, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin,
                                               screens: [Displays.laptopWithDock]))
        #expect(p.edge == .above)
        #expect(p.chipFrame.minY == caret.maxY + HUDGeometry.gap)
    }

    @Test("flips above at the bottom edge of a screen without a Dock reserve")
    func flipsAboveNearBottomEdge() throws {
        let caret = CGRect(x: 400, y: 20, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin, screens: [Displays.laptop]))
        #expect(p.edge == .above)
        #expect(p.chipFrame.minY == caret.maxY + HUDGeometry.gap)
    }

    @Test("clamps into visibleFrame minus the screen margin", arguments: [
        CGRect(x: 1500, y: 500, width: 1, height: 18),   // right edge
        CGRect(x: 2, y: 500, width: 1, height: 18),      // left edge
        CGRect(x: 700, y: 960, width: 1, height: 18),    // under the menu bar
    ])
    func clampsToVisibleFrame(caret: CGRect) throws {
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin, screens: [Displays.laptop]))
        let allowed = Displays.laptop.visibleFrame.insetBy(dx: HUDGeometry.screenMargin, dy: HUDGeometry.screenMargin)
        #expect(allowed.contains(p.chipFrame))
    }

    @Test("stays on the display that contains the caret and snaps to its pixel grid")
    func staysOnCaretScreen() throws {
        let caret = CGRect(x: 2000.3, y: -100.2, width: 1, height: 18)   // external display, below y = 0
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin, screens: Displays.both))
        #expect(Displays.external.visibleFrame.contains(p.chipFrame))
        #expect(p.chipFrame.minX == p.chipFrame.minX.rounded())   // @1x: whole points
        #expect(p.chipFrame.minY == p.chipFrame.minY.rounded())
    }

    @Test("snaps to half points on a Retina display")
    func snapsToRetinaGrid() throws {
        let caret = CGRect(x: 400.37, y: 500.81, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin, screens: [Displays.laptop]))
        #expect((p.chipFrame.minX * 2) == (p.chipFrame.minX * 2).rounded())
        #expect((p.chipFrame.minY * 2) == (p.chipFrame.minY * 2).rounded())
    }

    @Test("a caret near the right edge of the laptop never spills onto the external display")
    func neverSpillsAcrossDisplays() throws {
        let caret = CGRect(x: 1505, y: 300, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin, screens: Displays.both))
        #expect(p.chipFrame.maxX <= Displays.laptop.visibleFrame.maxX - HUDGeometry.screenMargin)
    }

    @Test("recovers from clients that report top-left-origin coordinates")
    func recoversFromFlippedCoordinates() throws {
        // External display BELOW the primary. True caret (Cocoa) y = -500; a buggy client reports
        // y = 982 - (-500) - 18 = 1464, which is on no display.
        let below = HUDScreen(frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), scale: 1)
        let buggy = CGRect(x: 400, y: 1464, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: buggy, chipSize: chip, margin: margin,
                                               screens: [Displays.laptop, below]))
        #expect(p.chipFrame.maxY == -500 - HUDGeometry.gap)
    }

    @Test("rejects garbage caret rects", arguments: [
        CGRect.zero,
        CGRect(x: 0, y: 0, width: 1, height: 17),                    // origin (0, 0): no geometry
        CGRect(x: -5000, y: -5000, width: 1, height: 18),            // on no display
        CGRect(x: CGFloat.nan, y: 400, width: 1, height: 18),
        CGRect(x: 400, y: CGFloat.infinity, width: 1, height: 18),
        CGRect(x: 400, y: 400, width: 1, height: CGFloat.infinity),
        CGRect(x: 10, y: 10, width: 1512, height: 982),              // a whole-window rect
    ])
    func rejectsGarbage(caret: CGRect) {
        #expect(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin, screens: Displays.both) == nil)
    }

    @Test("no screens means no HUD")
    func noScreens() {
        #expect(HUDGeometry.place(caret: CGRect(x: 10, y: 10, width: 1, height: 18), chipSize: chip,
                                  margin: margin, screens: []) == nil)
    }

    @Test("a zero-height caret is treated as a 16 pt line")
    func zeroHeightCaret() throws {
        let caret = CGRect(x: 400, y: 500, width: 0, height: 0)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: margin, screens: [Displays.laptop]))
        #expect(p.edge == .below)
        #expect(p.chipFrame.maxY == 500 - HUDGeometry.gap)
        #expect(HUDGeometry.sanitized(caret)?.height == HUDGeometry.fallbackLineHeight)
    }

    @Test("a fractional chip size is rounded up to whole device pixels, never down", arguments: [
        (180.5, 1, 181.0),          // 1x external display: the panel must not clip half a point
        (180.5, 2, 180.5),          // 2x laptop: 361 pixels exactly
        (102.3, 2, 102.5),
        (56.000_000_1, 2, 56.0),    // floating-point noise does not add a pixel
        (120.0, 1, 120.0),
    ])
    func chipSizeSnapsToPixels(width: CGFloat, scale: CGFloat, expected: CGFloat) throws {
        let screen = scale == 1 ? Displays.external : Displays.laptop
        let caret = CGRect(x: screen.frame.midX, y: screen.frame.midY, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: CGSize(width: width, height: 28),
                                               margin: margin, screens: [screen]))
        #expect(p.chipFrame.width == expected)
        #expect(p.chipFrame.height == 28)
        #expect(p.panelFrame.width == expected + 2 * margin)
    }

    @Test("the right-edge clamp uses the rounded width")
    func clampUsesRoundedWidth() throws {
        let caret = CGRect(x: 4060, y: 500, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: CGSize(width: 180.5, height: 28),
                                               margin: margin, screens: [Displays.external]))
        #expect(p.chipFrame.maxX == Displays.external.visibleFrame.maxX - HUDGeometry.screenMargin)
    }

    @Test("a chip wider than the display hides")
    func chipTooWide() {
        let caret = CGRect(x: 400, y: 500, width: 1, height: 18)
        #expect(HUDGeometry.place(caret: caret, chipSize: CGSize(width: 5000, height: 28), margin: margin,
                                  screens: [Displays.laptop]) == nil)
    }
}

@Suite("HUD jitter threshold")
struct HUDJitterTests {
    private let previous = CGRect(x: 400, y: 500, width: 1, height: 18)

    @Test("keeps the previous caret for moves of at most 2 pt", arguments: [
        CGRect(x: 401.5, y: 500, width: 1, height: 18),
        CGRect(x: 400, y: 498, width: 1, height: 18),
        CGRect(x: 402, y: 502, width: 2, height: 20),
        CGRect(x: 400, y: 500, width: 1, height: 18),
    ])
    func keepsPrevious(current: CGRect) {
        #expect(HUDGeometry.stabilized(previous: previous, current: current) == previous)
    }

    @Test("follows the caret once it moves more than 2 pt", arguments: [
        CGRect(x: 402.5, y: 500, width: 1, height: 18),
        CGRect(x: 400, y: 497, width: 1, height: 18),
        CGRect(x: 400, y: 500, width: 1, height: 21),
        CGRect(x: 900, y: 120, width: 1, height: 18),
    ])
    func followsLargeMoves(current: CGRect) {
        #expect(HUDGeometry.stabilized(previous: previous, current: current) == current)
    }

    @Test("without a previous rect the current one is used")
    func noPrevious() {
        #expect(HUDGeometry.stabilized(previous: nil, current: previous) == previous)
    }
}

@Suite("HUD window level")
struct HUDWindowLevelTests {
    private static let popUpMenu = 101
    private static let shielding = 2_147_483_628

    @Test("never below pop-up menus, one above the client, never at or above shielding", arguments: [
        (0, 101),          // normal window → popUpMenu
        (3, 101),          // floating window → popUpMenu
        (101, 102),        // client is a menu-level panel → one above it
        (1000, 1001),      // screen-saver-ish client → one above it
        (2_147_483_640, 2_147_483_627),
    ])
    func level(client: Int, expected: Int) {
        #expect(HUDGeometry.windowLevel(clientLevel: client, popUpMenuLevel: Self.popUpMenu,
                                        shieldingLevel: Self.shielding) == expected)
    }
}
