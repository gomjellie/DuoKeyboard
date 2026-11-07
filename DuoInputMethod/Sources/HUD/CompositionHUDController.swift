import AppKit
import DuoCore
import DuoKit
import SwiftUI

/// Gives the HUD the geometry it needs, on demand. Implemented by `DuoInputController`; each call is
/// a synchronous XPC round trip to the client, so the HUD asks only when it shows or updates
/// (critique R12, R15).
@MainActor
protocol HUDAnchorProvider: AnyObject {
    /// Line-height rect for `anchor` in Cocoa global coordinates, or `nil` when the client has none.
    func hudCaretRect(for anchor: HUDRequest.Anchor) -> CGRect?
    /// `IMKTextInput.windowLevel()` of the client window.
    func hudClientWindowLevel() -> Int
}

/// The single, reused composition HUD (one panel per process: azooKey #348 leaked dozens).
///
/// Timing lives in the pure `HUDTimeline`, placement in `HUDGeometry`; this class only turns their
/// answers into AppKit calls: frames, levels, fades and one timer.
@MainActor
final class CompositionHUDController {
    /// Keycaps follow the flip-key setting.
    var flipKey: FlipKey {
        didSet {
            guard flipKey != oldValue, let request = timeline.visibleRequest else { return }
            model.presentation = HUDPresentation(request.content, flipKey: flipKey)
            reposition(for: request, stabilize: true)
        }
    }

    /// Transparent space around the chip inside the panel, for the glass shadow and pulse overshoot.
    static let panelMargin: CGFloat = 14

    private let model = CompositionHUDModel()
    private let panel = CompositionHUDPanel()
    private let hosting: NSHostingView<HUDRootView>
    private var timeline = HUDTimeline()
    private var timer: Task<Void, Never>?
    private weak var provider: (any HUDAnchorProvider)?
    private var lastCaret: CGRect?
    private var lastAnchor: HUDRequest.Anchor?
    private var isOrderedIn = false
    /// Invalidates fade-out completions that a newer show or hide has superseded.
    private var fadeGeneration = 0

    init(flipKey: FlipKey) {
        self.flipKey = flipKey
        hosting = NSHostingView(rootView: HUDRootView(model: model, margin: Self.panelMargin))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
    }

    /// Feeds the engine's current request after every engine call.
    func present(_ request: HUDRequest?, from provider: any HUDAnchorProvider, trigger: HUDTimeline.Trigger) {
        if self.provider !== provider {
            self.provider = provider
            lastCaret = nil
        }
        apply(timeline.receive(request, at: Self.now, trigger: trigger))
        rescheduleTimer()
    }

    /// Drops the HUD at once, without a fade (deactivate, secure input, screen sleep, source change).
    func forceHide() {
        timeline.reset()
        timer?.cancel()
        timer = nil
        orderOut()
    }

    /// The user flipped: animate the next text change instead of snapping it.
    func noteManualFlip() {
        model.flipCount &+= 1
    }

    // MARK: Commands

    private func apply(_ command: HUDTimeline.Command?) {
        switch command {
        case nil:
            break
        case .show(let request):
            model.presentation = HUDPresentation(request.content, flipKey: flipKey)
            lastCaret = nil
            guard reposition(for: request, stabilize: false) else { return }
            if let provider {
                panel.level = NSWindow.Level(rawValue: HUDGeometry.windowLevel(
                    clientLevel: provider.hudClientWindowLevel(),
                    popUpMenuLevel: NSWindow.Level.popUpMenu.rawValue,
                    shieldingLevel: Int(CGShieldingWindowLevel())))
            }
            fadeIn()
        case .update(let request, let pulse):
            model.presentation = HUDPresentation(request.content, flipKey: flipKey)
            if pulse { model.pulseCount &+= 1 }
            reposition(for: request, stabilize: true)
        case .hide:
            fadeOut()
        }
    }

    /// Measures the chip, asks for the caret and moves the panel. Returns `false` (and drops the
    /// HUD) when the caret rect is unusable: never guess a position.
    @discardableResult
    private func reposition(for request: HUDRequest, stabilize: Bool) -> Bool {
        guard let raw = provider?.hudCaretRect(for: request.anchor) else {
            Log.hud.debug("no caret rect; hiding")
            forceHide()
            return false
        }
        let caret = stabilize && lastAnchor == request.anchor
            ? HUDGeometry.stabilized(previous: lastCaret, current: raw) : raw
        Log.hud.debug("place \(String(describing: request.anchor), privacy: .public) caret \(raw.debugDescription, privacy: .public)")
        // The model was just changed; measure what SwiftUI will draw, not the previous content.
        let chip = HUDSizing.chipSize(in: hosting, margin: Self.panelMargin)
        let screens = NSScreen.screens.map {
            HUDScreen(frame: $0.frame, visibleFrame: $0.visibleFrame, scale: $0.backingScaleFactor)
        }
        guard let placement = HUDGeometry.place(caret: caret, chipSize: chip, margin: Self.panelMargin,
                                                screens: screens) else {
            Log.hud.debug("caret rect off every screen; hiding")
            forceHide()
            return false
        }
        lastCaret = caret
        lastAnchor = request.anchor
        if panel.frame != placement.panelFrame {
            panel.setFrame(placement.panelFrame, display: true, animate: false)
        }
        return true
    }

    private func fadeIn() {
        fadeGeneration &+= 1
        if !isOrderedIn {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            isOrderedIn = true
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? timeline.timing.reducedMotionFadeIn : timeline.timing.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = timeline.timing.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.orderOut()
            }
        })
    }

    private func orderOut() {
        fadeGeneration &+= 1
        lastCaret = nil
        lastAnchor = nil
        guard isOrderedIn else { return }
        panel.orderOut(nil)
        panel.alphaValue = 0
        isOrderedIn = false
    }

    // MARK: Timer

    private func rescheduleTimer() {
        timer?.cancel()
        timer = nil
        guard let deadline = timeline.nextDeadline else { return }
        let delay = max(0, deadline - Self.now)
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.timerFired()
        }
    }

    private func timerFired() {
        timer = nil
        apply(timeline.advance(to: Self.now))
        rescheduleTimer()
    }

    /// Monotonic seconds, the same clock as `NSEvent.timestamp`.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// The hosting view's root: the chip plus the transparent panel margin.
struct HUDRootView: View {
    let model: CompositionHUDModel
    let margin: CGFloat

    var body: some View {
        CompositionHUDView(model: model)
            .padding(margin)
    }
}
