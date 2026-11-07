import DuoCore
import SwiftUI

/// The flip key as a row of selectable key-cap tiles; VoiceOver sees a standard picker.
struct FlipKeyPicker: View {
    @Binding var selection: FlipKey
    /// Smaller tiles for the onboarding coach card.
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            ForEach(FlipKey.allCases) { key in
                tile(key)
            }
        }
        .accessibilityRepresentation {
            Picker("바꾸기 키", selection: $selection) {
                ForEach(FlipKey.allCases) { key in Text(key.title).tag(key) }
            }
        }
    }

    private func tile(_ key: FlipKey) -> some View {
        let selected = key == selection
        let shape = RoundedRectangle(cornerRadius: compact ? 9 : 11, style: .continuous)
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = key }
        } label: {
            VStack(spacing: compact ? 5 : 7) {
                KeyCaps(caps: key.keycaps, size: compact ? 11 : 13)
                    .frame(height: compact ? 20 : 24)
                Text(key.title)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, compact ? 7 : 10)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(shape.fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.clear)))
            .overlay(shape.strokeBorder(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                        lineWidth: selected ? 1.5 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}
