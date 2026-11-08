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
    /// The reading at `index` on the choice bar for `shown`, the request on screen, was clicked.
    func hudChooseReading(at index: Int, on shown: HUDRequest)
    /// The anchor of the word being typed is being read and will arrive with
    /// `CompositionHUDController.refreshPlacement(from:)`: until then the HUD shows nothing rather
    /// than the previous word's place.
    var hudPlacementIsPending: Bool { get }
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
            setPresentation(HUDPresentation(request.content, flipKey: flipKey))
            reposition(for: request, stabilize: true)
        }
    }

    /// Transparent space around the chip inside the panel, for the glass shadow and pulse overshoot.
    static let panelMargin: CGFloat = 14
    /// Longest wait for a pending anchor (`hudPlacementIsPending`) before the HUD shows anyway.
    static let placementWait: Duration = .milliseconds(150)

    private let model = CompositionHUDModel()
    private let panel = CompositionHUDPanel()
    private let hosting: HUDHostingView
    private var timeline = HUDTimeline()
    private var timer: Task<Void, Never>?
    private weak var provider: (any HUDAnchorProvider)?
    private var lastCaret: CGRect?
    private var lastAnchor: HUDRequest.Anchor?
    private var isOrderedIn = false
    /// Invalidates fade-out completions that a newer show or hide has superseded.
    private var fadeGeneration = 0
    /// When the panel last came on screen (`systemUptime`).
    private var orderedInAt: TimeInterval?
    /// The visible capsule, in global coordinates (the panel adds a transparent margin around it).
    private var chipFrame: CGRect?
    /// Mouse-moved monitors, installed only while a choice bar is on screen.
    private var pointerMonitors: [Any] = []
    /// The visible request waits for the provider's anchor: not ordered in yet, or held at alpha 0.
    private var waitingForPlacement = false
    private var placementTimer: Task<Void, Never>?

    init(flipKey: FlipKey) {
        self.flipKey = flipKey
        hosting = HUDHostingView(rootView: HUDRootView(model: model, margin: Self.panelMargin))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        model.onChoose = { [weak self] index in self?.choose(index) }
    }

    /// Feeds the engine's current request after every engine call.
    func present(_ request: HUDRequest?, from provider: any HUDAnchorProvider, trigger: HUDTimeline.Trigger) {
        if self.provider !== provider {
            self.provider = provider
            lastCaret = nil
            cancelPlacementWait()
        }
        apply(timeline.receive(request, at: Self.now, trigger: trigger))
        rescheduleTimer()
    }

    /// The provider's caret changed without a new request (an anchor read in the background
    /// arrived): move the panel on screen, if it shows this provider's request.
    func refreshPlacement(from provider: any HUDAnchorProvider) {
        guard self.provider === provider else { return }
        if waitingForPlacement {
            if !provider.hudPlacementIsPending { endPlacementWait() }
            return
        }
        guard isOrderedIn, let request = timeline.visibleRequest, reposition(for: request, stabilize: true) else { return }
        updatePointer()
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

    // MARK: Pointer

    /// The request the user can see now: on screen, not on its way out, and faded in. The digit
    /// keys choose from this bar only; a bar still at alpha 0 was not seen.
    var seenRequest: HUDRequest? {
        guard isOrderedIn, let shownAt = orderedInAt, Self.now - shownAt >= timeline.timing.fadeIn else { return nil }
        return timeline.visibleRequest
    }

    /// A click on a reading of the choice bar. The provider switches the word and presents the
    /// engine's new request, which moves the selection pill. A bar on its way out (a hide was
    /// issued) no longer counts.
    private func choose(_ index: Int) {
        guard isOrderedIn, model.presentation.isClickable, let shown = timeline.visibleRequest else { return }
        provider?.hudChooseReading(at: index, on: shown)
    }

    /// Follows the pointer while a choice bar is on screen. The panel takes clicks only while the
    /// pointer is over the capsule itself, so its transparent margin never swallows a click meant
    /// for the text. The input method process is never the active app, so this listens to
    /// mouse-moved events globally (no permission needed) and on the panel itself.
    private func updatePointerTracking() {
        let wanted = isOrderedIn && model.presentation.isClickable
        if wanted, pointerMonitors.isEmpty {
            panel.acceptsMouseMovedEvents = true
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePointer() }
            }) { pointerMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.updatePointer() }
                return event
            }) { pointerMonitors.append(local) }
        } else if !wanted, !pointerMonitors.isEmpty {
            pointerMonitors.forEach(NSEvent.removeMonitor)
            pointerMonitors = []
        }
        updatePointer()
    }

    /// Whether the pointer is over the visible choice bar: the panel takes clicks, the chip's
    /// lifetime is held and the reading a click would choose is highlighted.
    private func updatePointer() {
        let over = isOrderedIn && !waitingForPlacement && model.presentation.isClickable
            && (chipFrame?.contains(NSEvent.mouseLocation) ?? false)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        guard over != model.pointerInside else { return }
        model.pointerInside = over
        timeline.setPointerInside(over, at: Self.now)
        rescheduleTimer()
    }

    private func setPresentation(_ presentation: HUDPresentation) {
        model.presentation = presentation
    }

    // MARK: Commands

    private func apply(_ command: HUDTimeline.Command?) {
        switch command {
        case nil:
            break
        case .show(let request):
            setPresentation(HUDPresentation(request.content, flipKey: flipKey))
            lastCaret = nil
            if provider?.hudPlacementIsPending == true {
                waitForPlacement()
                return
            }
            show(request)
        case .update(let request, let pulse):
            setPresentation(HUDPresentation(request.content, flipKey: flipKey))
            if pulse { model.pulseCount &+= 1 }
            // The latest content goes up with endPlacementWait.
            if waitingForPlacement { return }
            if provider?.hudPlacementIsPending == true, isOrderedIn {
                // A new word: never at the previous word's place, even for a moment.
                fadeGeneration &+= 1
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    panel.animator().alphaValue = 0
                }
                orderedInAt = nil
                waitForPlacement()
                updatePointer()
                return
            }
            reposition(for: request, stabilize: true)
            updatePointerTracking()
        case .hide:
            cancelPlacementWait()
            fadeOut()
        }
    }

    /// Places `request`, raises the panel to the client's level and fades it in.
    private func show(_ request: HUDRequest) {
        guard reposition(for: request, stabilize: false) else { return }
        if let provider {
            panel.level = NSWindow.Level(rawValue: HUDGeometry.windowLevel(
                clientLevel: provider.hudClientWindowLevel(),
                popUpMenuLevel: NSWindow.Level.popUpMenu.rawValue,
                shieldingLevel: Int(CGShieldingWindowLevel())))
        }
        fadeIn()
        updatePointerTracking()
    }

    // MARK: Pending anchors

    private func waitForPlacement() {
        waitingForPlacement = true
        placementTimer?.cancel()
        placementTimer = Task { [weak self] in
            do { try await Task.sleep(for: Self.placementWait) } catch { return }
            self?.endPlacementWait()
        }
    }

    /// The anchor arrived (or the wait ran out): show the timeline's visible request where it is now.
    private func endPlacementWait() {
        guard waitingForPlacement else { return }
        cancelPlacementWait()
        guard let request = timeline.visibleRequest else { return }
        if isOrderedIn {
            guard reposition(for: request, stabilize: false) else { return }
            fadeIn()
            updatePointerTracking()
        } else {
            show(request)
        }
    }

    private func cancelPlacementWait() {
        waitingForPlacement = false
        placementTimer?.cancel()
        placementTimer = nil
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
        chipFrame = placement.chipFrame
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
            // A hidden application's windows stay off screen, even after orderFrontRegardless
            // (`open -j` launches the input method hidden).
            if NSApp.isHidden {
                Log.hud.info("input method app was hidden; unhiding")
                NSApp.unhideWithoutActivation()
            }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            isOrderedIn = true
        }
        // Also after a hold at alpha 0 (a pending anchor): the bar is seen from now.
        if orderedInAt == nil { orderedInAt = Self.now }
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
        cancelPlacementWait()
        fadeGeneration &+= 1
        lastCaret = nil
        lastAnchor = nil
        chipFrame = nil
        defer { updatePointerTracking() }
        guard isOrderedIn else { return }
        panel.orderOut(nil)
        panel.alphaValue = 0
        isOrderedIn = false
        orderedInAt = nil
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

/// Hosts the chip. Takes the first click although the panel is never key: the input method must
/// not take focus from the client.
final class HUDHostingView: NSHostingView<HUDRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
