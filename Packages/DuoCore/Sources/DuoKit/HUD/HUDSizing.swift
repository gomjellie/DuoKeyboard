import AppKit

/// Measures the HUD's hosting view (ui-design §2.6).
///
/// The HUD controller changes an `@Observable` model and then sizes the panel in the same call.
/// `NSHostingView` applies observation-driven changes only on its next layout pass, so a bare
/// `fittingSize` read at that point returns the size of the *previous* content: a chip that grew is
/// clipped, one that shrank sits off its caret. Laying the subtree out first makes the measurement
/// match what the view will draw.
@MainActor
public enum HUDSizing {
    /// The fitting size of `view` for the content it holds now.
    public static func fittingSize(of view: NSView) -> CGSize {
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    /// The chip's size inside a hosting view that pads it by `margin` on every side.
    public static func chipSize(in view: NSView, margin: CGFloat) -> CGSize {
        let fit = fittingSize(of: view)
        return CGSize(width: max(0, fit.width - 2 * margin), height: max(0, fit.height - 2 * margin))
    }
}
