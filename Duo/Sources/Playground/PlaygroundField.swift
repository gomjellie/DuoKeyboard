import AppKit
import DuoCore
import DuoKit
import SwiftUI

/// The "써보기" field used in onboarding and at the top of Settings ▸ 일반 (critique P2).
///
/// It switches by itself between the in-process engine (Duo not selected) and a plain text view
/// where the real input method runs (Duo selected).
struct PlaygroundField: View {
    let model: PlaygroundModel
    var placeholder: LocalizedStringResource = "여기에 입력해 보세요"
    var height: CGFloat = 84
    /// Inside a grouped `Form` row, which already draws the card: no background or border of its own.
    var isEmbedded = false
    /// Take keyboard focus as soon as the field is in a window (onboarding 써보기).
    var autoFocus = false

    @Environment(AppModel.self) private var app
    @State private var anchor: CGRect = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .background(isEmbedded ? AnyShapeStyle(.clear) : AnyShapeStyle(.background), in: shape)
                .overlay {
                    if !isEmbedded {
                        shape.strokeBorder(model.hasFocus ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.separator),
                                           lineWidth: model.hasFocus ? 2 : 0.5)
                    }
                }
                .animation(.snappy(duration: 0.2), value: model.hasFocus)
            if !model.text.isEmpty && (model.availability == .ready || !usesEngine) {
                Button("지우기", systemImage: "xmark.circle.fill") { model.clear() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .padding(8)
                    .help(Text("지우기"))
            }
        }
        .overlay(alignment: .topLeading) {
            if let hud = model.hud, usesEngine {
                PlaygroundHUDChip(request: hud, flipKey: app.settings.value.flipKey)
                    .offset(x: max(0, anchor.minX - 8), y: anchor.maxY + 6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.hud)
        .preference(key: PlaygroundFocusKey.self, value: model.hasFocus)
        .task { await model.prepare(settings: app.settings.value) }
        .onChange(of: app.settings.value) { _, settings in model.apply(settings: settings) }
        // Carry the text across when Duo becomes, or stops being, the selected input source.
        .onChange(of: usesEngine) { _, engine in
            if engine { model.didEnterEngine() } else { model.willLeaveEngine() }
        }
        .onAppear { app.status.beginMonitoring() }
        .onDisappear { app.status.endMonitoring() }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private var usesEngine: Bool { !app.status.state.isSelected }

    @ViewBuilder private var content: some View {
        if usesEngine {
            switch model.availability {
            case .loading:
                ProgressView().controlSize(.small)
            case .ready:
                EngineCanvas(model: model, placeholder: String(localized: placeholder), autoFocus: autoFocus, anchor: $anchor)
            case .unavailable:
                unavailableMessage
            }
        } else {
            NativeEditor(model: model, placeholder: placeholder, autoFocus: autoFocus)
        }
    }

    private var unavailableMessage: some View {
        Label {
            Text("써보기를 준비하지 못했어요. Duo를 켜면 어느 앱에서나 바로 써 볼 수 있어요.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "character.cursor.ibeam.ko")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// `PlaygroundCanvasView` for SwiftUI.
private struct EngineCanvas: NSViewRepresentable {
    let model: PlaygroundModel
    let placeholder: String
    let autoFocus: Bool
    @Binding var anchor: CGRect

    func makeNSView(context: Context) -> PlaygroundCanvasView {
        let view = PlaygroundCanvasView(model: model)
        view.placeholder = placeholder
        view.takesInitialFocus = autoFocus
        view.onAnchorChange = { rect in
            DispatchQueue.main.async { anchor = rect }
        }
        return view
    }

    func updateNSView(_ view: PlaygroundCanvasView, context: Context) {
        view.placeholder = placeholder
    }
}

/// A plain `NSTextView` for when Duo is the selected input source, so the real IME runs.
private struct NativeEditor: View {
    let model: PlaygroundModel
    let placeholder: LocalizedStringResource
    let autoFocus: Bool

    var body: some View {
        NativeTextView(model: model, autoFocus: autoFocus)
            .overlay(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, PlaygroundCanvasView.inset.width)
                        .padding(.vertical, PlaygroundCanvasView.inset.height)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct NativeTextView: NSViewRepresentable {
    let model: PlaygroundModel
    let autoFocus: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.font = PlaygroundCanvasView.font
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: PlaygroundCanvasView.inset.width - 5,
                                             height: PlaygroundCanvasView.inset.height)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.setAccessibilityLabel(String(localized: "써보기 입력 칸"))
        // Everything the canvas showed; `willLeaveEngine` replaces it with the committed text.
        textView.string = model.text
        model.attachNative(textView)
        if autoFocus {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let textView = view.documentView as? NSTextView else { return }
        if model.text.isEmpty && !textView.string.isEmpty && !textView.hasMarkedText() { textView.string = "" }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: PlaygroundModel
        init(model: PlaygroundModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.nativeTextDidChange(textView)
        }

        func textDidBeginEditing(_ notification: Notification) { model.hasFocus = true }
        func textDidEndEditing(_ notification: Notification) { model.hasFocus = false }
    }
}

/// The in-process stand-in for the IME's HUD (the real one belongs to the input method process).
struct PlaygroundHUDChip: View {
    let request: HUDRequest
    let flipKey: FlipKey

    var body: some View {
        HStack(spacing: 6) {
            switch request.content {
            case .alternative(let text, let language, _):
                LanguageBadge(language: language, size: 20)
                Text(verbatim: text).font(.system(size: 14, weight: .medium))
                KeyCaps(caps: flipKey.keycaps, size: 10)
            case .flipLastWord(let text, let language):
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DuoStyle.color(for: language))
                    .frame(width: 20, height: 20)
                Text(verbatim: text).font(.system(size: 14, weight: .medium))
                KeyCaps(caps: flipKey.keycaps, size: 10)
            case .oneShot(let language):
                LanguageBadge(language: language, size: 22)
            case .cannotChange:
                Text("여기서는 바꿀 수 없어요")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            case .bilingualLine:
                LanguageBadge(language: .korean, size: 20).opacity(0.6)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(height: 28)
        .duoGlass(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
