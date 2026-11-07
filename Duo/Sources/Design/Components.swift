import DuoCore
import DuoKit
import SwiftUI

/// System Settings–style colored squircle with a white glyph (sidebar and pane headers).
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = DuoStyle.sidebarIconSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Small rounded key caps such as ⌘ or ⇧ Space.
struct KeyCaps: View {
    let caps: [String]
    var size: CGFloat = 11
    var isHighlighted = false

    var body: some View {
        HStack(spacing: size * 0.3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .padding(.horizontal, size * 0.45)
                    .frame(minWidth: size * 1.65, minHeight: size * 1.65)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                            .fill(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.38, style: .continuous)
                            .strokeBorder(.separator, lineWidth: isHighlighted ? 0 : 0.5))
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// A 가 / A language badge. Drawn as text: the SF Symbol `character` is localized and shows 가 in
/// a Korean locale.
struct LanguageBadge: View {
    let language: ScriptLanguage
    var size: CGFloat = 18

    var body: some View {
        Text(verbatim: language == .korean ? "가" : "A")
            .font(.system(size: size * (language == .korean ? 0.5 : 0.56), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(DuoStyle.color(for: language).gradient))
            .accessibilityLabel(language == .korean ? Text("한국어") : Text("English"))
    }
}

/// One row of a live checklist: hollow circle → spinner → green check (or a red mark on failure).
struct ChecklistRow<Trailing: View>: View {
    let mark: ChecklistMark
    let title: Text
    var detail: Text?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
                .frame(width: 18, height: 18)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .foregroundStyle(mark == .pending ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    detail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    @ViewBuilder private var icon: some View {
        switch mark {
        case .running:
            ProgressView().controlSize(.small)
        case .pending, .done, .failed:
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(style)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var symbol: String {
        switch mark {
        case .pending, .running: "circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var style: AnyShapeStyle {
        switch mark {
        case .pending, .running: AnyShapeStyle(.tertiary)
        case .done: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.red)
        }
    }

    private var accessibilityState: Text {
        switch mark {
        case .pending: Text("대기 중")
        case .running: Text("진행 중")
        case .done: Text("완료")
        case .failed: Text("실패")
        }
    }
}

extension ChecklistRow where Trailing == EmptyView {
    init(mark: ChecklistMark, title: Text, detail: Text? = nil) {
        self.init(mark: mark, title: title, detail: detail, trailing: { EmptyView() })
    }
}

/// Onboarding page indicator: 6 pt dots, the current one an 18 pt capsule.
struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy, value: index)
        .accessibilityElement()
        .accessibilityLabel(Text("\(index + 1)/\(count) 단계"))
    }
}

/// The host app's icon: the `AppIcon` that actool compiled from `AppIcon.icon` into `Assets.car`,
/// read synchronously (Icon Services can hand back the generic icon until it has rendered the
/// layered icon, so it is only the fallback).
struct AppIconImage: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
