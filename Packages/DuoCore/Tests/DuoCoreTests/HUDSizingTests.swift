import AppKit
import DuoKit
import Observation
import SwiftUI
import Testing

/// Stands in for the input method's `CompositionHUDModel`: an `@Observable` the controller mutates
/// right before it sizes the panel.
@MainActor
@Observable
private final class ChipModel {
    var text = "dk"
}

/// Shaped like the real chip: a fixed-size text in a 28 pt capsule, padded by the panel margin.
private struct ChipView: View {
    let model: ChipModel
    let margin: CGFloat

    var body: some View {
        Text(verbatim: model.text)
            .font(.system(size: 14, weight: .medium))
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(minWidth: 28, minHeight: 28, maxHeight: 28)
            .padding(margin)
    }
}

@MainActor
@Suite("HUD sizing")
struct HUDSizingTests {
    private static let margin: CGFloat = 14

    /// The size the view settles on once SwiftUI has applied every change (a fresh hosting view).
    private func settledSize(of text: String) -> CGSize {
        let model = ChipModel()
        model.text = text
        let view = NSHostingView(rootView: ChipView(model: model, margin: Self.margin))
        view.sizingOptions = [.intrinsicContentSize]
        return HUDSizing.fittingSize(of: view)
    }

    @Test("measures the content the model holds now, not the previous presentation",
          arguments: ["dkssudgktpdy", "안", "dk"])
    func measuresCurrentContent(next: String) {
        let model = ChipModel()
        model.text = "i"
        let view = NSHostingView(rootView: ChipView(model: model, margin: Self.margin))
        view.sizingOptions = [.intrinsicContentSize]
        _ = HUDSizing.fittingSize(of: view)          // the panel's first presentation

        model.text = next                            // the controller's `model.presentation = …`
        #expect(HUDSizing.fittingSize(of: view) == settledSize(of: next))
    }

    @Test("a chip that grows and then shrinks is measured exactly each time")
    func growsAndShrinks() {
        let model = ChipModel()
        let view = NSHostingView(rootView: ChipView(model: model, margin: Self.margin))
        view.sizingOptions = [.intrinsicContentSize]
        for text in ["dkssudgktpdy", "dk", "안녕하세요", "a"] {
            model.text = text
            #expect(HUDSizing.fittingSize(of: view) == settledSize(of: text), "\(text)")
        }
    }

    @Test("the chip size leaves out the panel margin")
    func chipSizeWithoutMargin() {
        let model = ChipModel()
        model.text = "dkssud"
        let view = NSHostingView(rootView: ChipView(model: model, margin: Self.margin))
        view.sizingOptions = [.intrinsicContentSize]
        let fit = HUDSizing.fittingSize(of: view)
        let chip = HUDSizing.chipSize(in: view, margin: Self.margin)
        #expect(chip.width == fit.width - 2 * Self.margin)
        #expect(chip.height == 28)
    }
}
