import DuoCore
import SwiftUI

/// Design tokens (ui-design §3.4). Only system dynamic colors: they adapt to Dark Mode and
/// Increase Contrast by themselves.
enum DuoStyle {
    /// Warm = 한국어.
    static let korean = Color.orange
    /// Cool = English.
    static let english = Color.blue

    static func color(for language: ScriptLanguage) -> Color {
        language == .korean ? korean : english
    }

    static let sidebarIconSize: CGFloat = 22
    static let sidebarIconRadius: CGFloat = 6
    static let cardRadius: CGFloat = 14

    /// Onboarding window content size (fixed, `.windowResizability(.contentSize)`).
    static let onboardingSize = CGSize(width: 640, height: 600)
    /// Settings window default and minimum sizes.
    static let settingsDefaultSize = CGSize(width: 780, height: 600)
    static let settingsMinimumSize = CGSize(width: 700, height: 480)
}

extension EnvironmentValues {
    /// `true` only while rendering offscreen for visual QA. `cacheDisplay` draws Liquid Glass as an
    /// empty layer, so glass surfaces substitute an opaque stand-in with the same geometry
    /// (ui-design §2.7).
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
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    /// `.glassEffect(_:in:)`, with an opaque stand-in in snapshot mode.
    func duoGlass<S: InsettableShape>(_ glass: Glass = .regular, in shape: S) -> some View {
        modifier(DuoGlassModifier(glass: glass, shape: shape))
    }

    /// A rounded card on the secondary background, as used for the playground and checklists.
    func duoCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DuoStyle.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DuoStyle.cardRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

private struct DuoGlassButtonModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.duoSnapshotMode) private var snapshot

    func body(content: Content) -> some View {
        switch (snapshot, prominent) {
        case (false, false): content.buttonStyle(.glass)
        case (false, true): content.buttonStyle(.glassProminent)
        // `cacheDisplay` draws glass buttons without their glass; bordered styles keep the geometry.
        case (true, false): content.buttonStyle(.bordered)
        case (true, true): content.buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    /// `.buttonStyle(.glass)` or `.glassProminent`, with a bordered stand-in in snapshot mode.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(DuoGlassButtonModifier(prominent: prominent))
    }
}
