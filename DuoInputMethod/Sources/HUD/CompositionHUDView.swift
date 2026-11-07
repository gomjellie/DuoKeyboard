import DuoCore
import DuoKit
import Observation
import SwiftUI

/// What the HUD view observes. The HUD controller mutates it on the main actor.
@MainActor
@Observable
final class CompositionHUDModel {
    /// The chip's content (badge, text, keycaps).
    var presentation: HUDPresentation = .empty
    /// Bumped when the reading changed by itself mid-word: plays one pulse (ui-design §2.1).
    var pulseCount = 0
    /// Bumped when the user flipped: the text change animates instead of snapping.
    var flipCount = 0
    /// The pointer is over the panel (the choice bar highlights the reading it would switch to).
    var pointerInside = false
    /// The other reading on the choice bar was clicked.
    @ObservationIgnored var onChooseOther: () -> Void = {}

    init() {}
}

/// The Liquid Glass composition chip (ui-design §2.2 merged with critique R12): a 28 pt capsule.
/// A word with two plausible readings gets the choice bar (docs/SPEC.md §4.11): both readings with
/// 16 pt language badges (가 orange / A blue), the one in the document on a selection pill, then the
/// flip key's keycaps. Feedback is a 20 pt badge or a message. The view is hidden from
/// accessibility (ux-spec §7.5); flips are announced instead.
struct CompositionHUDView: View {
    let model: CompositionHUDModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pulsing = false

    /// Chip height.
    static let height: CGFloat = 28
    /// Longest alternative before middle truncation (tokens are capped at 32 keys, so this rarely bites).
    static let maximumTextWidth: CGFloat = 280

    var body: some View {
        let presentation = model.presentation
        HStack(spacing: 6) {
            if let choice = presentation.choice {
                ChoiceBar(choice: choice, pointerInside: model.pointerInside,
                          emphasized: reduceTransparency || contrast == .increased,
                          onChooseOther: model.onChooseOther)
                    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.15),
                               value: choice.selected)
            } else if let language = presentation.badge {
                LanguageBadge(language: language)
            }
            if presentation.kind == .cannotChange {
                Text("여기서는 바꿀 수 없어요")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !presentation.keycaps.isEmpty {
                Keycaps(glyphs: presentation.keycaps, emphasized: reduceTransparency || contrast == .increased)
            }
        }
        .padding(.leading, leadingPadding(presentation))
        .padding(.trailing, trailingPadding(presentation))
        .frame(minWidth: Self.height, minHeight: Self.height, maxHeight: Self.height)
        .duoGlass(pulsing ? .regular.tint(Color.accentColor.opacity(0.25)) : .regular, in: Capsule())
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
            }
        }
        .opacity(presentation.opacity)
        .scaleEffect(pulsing && !reduceMotion ? 1.04 : 1, anchor: .leading)
        .onChange(of: model.pulseCount) {
            guard !reduceMotion else { return }
            withAnimation(.spring(duration: 0.18, bounce: 0.4)) {
                pulsing = true
            } completion: {
                withAnimation(.spring(duration: 0.32, bounce: 0.2)) { pulsing = false }
            }
        }
        .accessibilityHidden(true)
    }

    /// Badges and the selection pill sit concentric in the capsule; a message gets a roomier inset.
    private func leadingPadding(_ p: HUDPresentation) -> CGFloat {
        if p.choice != nil { return ChoiceBar.inset }
        return p.badge == nil ? 12 : 4
    }

    private func trailingPadding(_ p: HUDPresentation) -> CGFloat {
        if p.isBadgeOnly || !p.keycaps.isEmpty { return 4 }
        return p.kind == .cannotChange ? 12 : 10
    }
}

/// Both readings of a word, the one in the document on the selection pill. A click on the other
/// reading switches to it; the pill then slides over, since the order never changes.
private struct ChoiceBar: View {
    let choice: HUDChoice
    let pointerInside: Bool
    let emphasized: Bool
    let onChooseOther: () -> Void

    /// Pill inset inside the 28 pt capsule, so the pill is concentric with it.
    static let inset: CGFloat = 3
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(choice.readings.enumerated()), id: \.offset) { index, reading in
                if index == choice.selected {
                    ReadingLabel(reading: reading, prominent: true)
                        .background {
                            // Tinted with the reading's language, so it cannot pass for a hover.
                            Capsule()
                                .fill(LanguageBadge.color(for: reading.language).opacity(emphasized ? 0.34 : 0.22))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                } else {
                    Button(action: onChooseOther) {
                        ReadingLabel(reading: reading, prominent: pointerInside)
                    }
                    .buttonStyle(OtherReadingStyle(highlighted: pointerInside, emphasized: emphasized))
                }
            }
        }
    }
}

/// One reading: its 16 pt badge and its text.
private struct ReadingLabel: View {
    let reading: HUDReading
    let prominent: Bool

    var body: some View {
        HStack(spacing: 5) {
            LanguageBadge(language: reading.language, size: 16)
            Text(verbatim: reading.text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(prominent ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: CompositionHUDView.maximumTextWidth / 2, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .frame(height: CompositionHUDView.height - 2 * ChoiceBar.inset)
        .contentShape(Capsule())
    }
}

/// The reading a click switches to: a faint neutral pill while the pointer is over the bar, a firmer
/// one while pressed.
private struct OtherReadingStyle: ButtonStyle {
    let highlighted: Bool
    let emphasized: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Capsule().fill(Color.primary.opacity(fill(pressed: configuration.isPressed)))
            }
    }

    private func fill(pressed: Bool) -> Double {
        if pressed { return emphasized ? 0.22 : 0.14 }
        return highlighted ? (emphasized ? 0.1 : 0.06) : 0
    }
}

/// A circle with "가" (orange, Korean) or "A" (blue, English): the language of a reading or of the
/// next word.
private struct LanguageBadge: View {
    let language: ScriptLanguage
    var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func color(for language: ScriptLanguage) -> Color { language == .english ? .blue : .orange }

    var body: some View {
        Image(systemName: language == .english ? "character" : "character.ko")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(for: language)))
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.downUp))
            .animation(.snappy(duration: 0.22), value: language)
    }
}

/// The flip key as small rounded keycaps (⌘, ⇧ Space, …).
private struct Keycaps: View {
    let glyphs: [String]
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                Text(verbatim: glyph)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(emphasized ? 0.14 : 0.08))
                    )
            }
        }
    }
}

// MARK: - Glass with an offscreen-snapshot stand-in (ui-design §2.7)

extension EnvironmentValues {
    /// `true` only when rendering offscreen for visual checks: glass does not rasterize there, so an
    /// opaque capsule with the same geometry stands in.
    @Entry var duoSnapshotMode: Bool = false
}

private struct DuoGlassModifier<S: InsettableShape>: ViewModifier {
    let glass: Glass
    let shape: S
    @Environment(\.duoSnapshotMode) private var snapshot

    func body(content: Content) -> some View {
        if snapshot {
            content
                .background(shape.fill(.background.secondary))
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    /// `.glassEffect(glass, in: shape)`, or the snapshot stand-in under ``EnvironmentValues/duoSnapshotMode``.
    func duoGlass<S: InsettableShape>(_ glass: Glass = .regular, in shape: S) -> some View {
        modifier(DuoGlassModifier(glass: glass, shape: shape))
    }
}
