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

    init() {}
}

/// The Liquid Glass composition chip (ui-design §2.2 merged with critique R12): a 28 pt capsule with
/// a 20 pt language badge (가 orange / A blue), the alternative in 14 pt medium, and the flip key's
/// keycaps. The view is hidden from accessibility (ux-spec §7.5); flips are announced instead.
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
            if let language = presentation.badge {
                LanguageBadge(language: language)
            }
            if presentation.showsUndoGlyph {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if presentation.kind == .cannotChange {
                Text("여기서는 바꿀 수 없어요")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else if !presentation.text.isEmpty {
                Text(verbatim: presentation.text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Self.maximumTextWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
                    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.28, bounce: 0.12),
                               value: model.flipCount)
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

    /// The badge sits concentric in the capsule (4 pt); text-only content gets a roomier inset.
    private func leadingPadding(_ p: HUDPresentation) -> CGFloat { p.badge == nil ? 12 : 4 }

    private func trailingPadding(_ p: HUDPresentation) -> CGFloat {
        if p.isBadgeOnly || !p.keycaps.isEmpty { return 4 }
        return p.kind == .cannotChange ? 12 : 10
    }
}

/// 20 pt circle with "가" (orange, Korean) or "A" (blue, English): which language the chip offers.
private struct LanguageBadge: View {
    let language: ScriptLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: language == .english ? "character" : "character.ko")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(language == .english ? Color.blue : Color.orange))
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
