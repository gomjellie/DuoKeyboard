import DuoCore
import Foundation

/// The composition HUD's timing rules as a pure state machine (critique R12, ui-design §2.1,
/// ux-spec §7.3). The AppKit controller feeds it every `CompositionEngine.hud` value and wakes it at
/// ``nextDeadline``; the timeline answers with what the panel should do. No clocks, no AppKit, so
/// every rule is unit-tested.
///
/// Rules:
/// - A non-immediate request appears only after a typing pause of ``Timing/appearDelay``; every
///   keystroke restarts the pause. With no pause (the standard timing) it appears on the next timer
///   tick: showing the panel inside the key event left it off screen in the input method.
/// - An immediate request (chips, badges) appears at once.
/// - Once an alternative is on screen it **latches**: it stays and updates in place while the token
///   is composing, even when a later request says `eligible == false`.
/// - A chip, badge or message on screen does not let a new word's alternative skip the pause: it
///   hides, and the alternative appears after the pause like any other (ux-spec §7.3: the chip is
///   cancelled by the next letter).
/// - The Bilingual-line badge is persistent (ux-spec §6.6, §7.2): a word that has not earned the
///   HUD composes under it without hiding it.
/// - `nil` (commit, Esc, …) hides after ``Timing/hideDebounce``; an eligible alternative arriving
///   inside the debounce of a visible alternative keeps the HUD up, so continuous typing never blinks.
/// - `lifetime` hides the request that long after it was shown. While the pointer is over the chip
///   (the choice bar takes clicks) the lifetime does not run out; leaving the chip hides it after
///   ``Timing/pointerExitGrace``. Hides the engine asks for still happen.
/// - `pulse` is passed through only for in-place updates (a first appearance already fades in).
public struct HUDTimeline: Sendable, Equatable {
    /// Durations in seconds.
    public struct Timing: Sendable, Equatable {
        /// Typing pause before a non-immediate request appears. 0: the choice bar comes up with the
        /// key that composed the word, as a Pinyin candidate window does (user request, 2026-11-08).
        public var appearDelay: TimeInterval = 0
        /// Delay between a hide request and the start of the fade-out.
        public var hideDebounce: TimeInterval = 0.140
        /// Fade-in on first appearance.
        public var fadeIn: TimeInterval = 0.140
        /// Fade-in with Reduce Motion on.
        public var reducedMotionFadeIn: TimeInterval = 0.080
        /// Fade-out once the debounce or the lifetime has elapsed.
        public var fadeOut: TimeInterval = 0.100
        /// How long a chip whose lifetime ran out under the pointer stays after the pointer leaves.
        public var pointerExitGrace: TimeInterval = 0.8

        public init() {}

        public static let standard = Timing()
    }

    /// Where the timeline is.
    public enum Phase: Sendable, Equatable {
        /// Nothing on screen.
        case hidden
        /// Waiting for the typing pause; `request` appears at `showAt` unless something changes.
        case pending(HUDRequest, showAt: TimeInterval)
        /// On screen. `hideAt` is set while a debounce or a lifetime is running.
        case visible(HUDRequest, hideAt: TimeInterval?)
    }

    /// What the panel should do.
    public enum Command: Sendable, Equatable {
        /// Bring the panel up with `request` (fade in).
        case show(HUDRequest)
        /// Change the visible panel's content in place; `pulse` plays the auto-flip pulse.
        case update(HUDRequest, pulse: Bool)
        /// Fade out, then order the panel out.
        case hide
    }

    /// How a request reached the timeline.
    public enum Trigger: Sendable, Equatable {
        /// A keyDown. A keystroke restarts the typing pause and may re-show an identical request
        /// (Backspace right after a commit brings the chip back).
        case keystroke
        /// Anything else (flagsChanged, mouse, focus). An identical consecutive request is ignored, so
        /// holding ⇧ never restarts a timer or resurrects an expired chip.
        case other
        /// Feedback from the IME itself (a menu action that cannot run). Shown like a keystroke, but
        /// it does not replace the remembered engine request, so the engine's unchanged `nil` on the
        /// next modifier press does not cut the message short.
        case feedback
    }

    public var timing: Timing
    public private(set) var phase: Phase = .hidden
    /// The pointer is over the chip.
    public private(set) var pointerInside = false
    private var lastReceived: HUDRequest?
    /// The visible chip's `hideAt` is a hide request's debounce, not its lifetime.
    private var hideIsDebounce = false
    /// The visible chip's lifetime deadline, paused while the pointer is over it.
    private var heldHideAt: TimeInterval?

    public init(timing: Timing = .standard) { self.timing = timing }

    /// The time at which ``advance(to:)`` must be called next, or `nil` when no timer is needed.
    public var nextDeadline: TimeInterval? {
        switch phase {
        case .hidden: nil
        case .pending(_, let showAt): showAt
        case .visible(_, let hideAt): hideAt
        }
    }

    /// Whether the panel is (or is about to stay) on screen.
    public var isVisible: Bool {
        if case .visible = phase { return true }
        return false
    }

    /// The request currently on screen, if any.
    public var visibleRequest: HUDRequest? {
        if case .visible(let r, _) = phase { return r }
        return nil
    }

    /// Feeds the engine's current request.
    public mutating func receive(_ request: HUDRequest?, at now: TimeInterval,
                                 trigger: Trigger = .keystroke) -> Command? {
        if trigger == .other, request == lastReceived { return nil }
        if trigger != .feedback { lastReceived = request }

        guard let request else { return requestHide(at: now) }

        guard request.earnsHUD else {
            switch phase {
            case .visible(let current, nil) where current.isTimelineAlternative:
                // Latched: the token that earned the HUD is still composing.
                makeVisible(request, at: now)
                return .update(request, pulse: request.pulse)
            case .visible(let current, nil) where current.content == .bilingualLine:
                // The persistent Bilingual-line badge stays while a word composes under it; the
                // engine asks for it again once the word is committed.
                return nil
            case .visible:
                // A chip or badge is up, or the HUD is already on its way out: an ineligible
                // alternative means a new token started that has not earned the HUD.
                return requestHide(at: now)
            case .pending:
                phase = .hidden
                return nil
            case .hidden:
                return nil
            }
        }

        switch phase {
        case .visible(let current, _) where !request.immediate && !current.isTimelineAlternative:
            // A chip, badge or message is up: a new word's alternative still waits for the typing
            // pause (R12), and the chip goes now (ux-spec §7.3), with whatever pointer was over it.
            phase = .pending(request, showAt: now + timing.appearDelay)
            forgetPointer()
            return .hide
        case .visible:
            makeVisible(request, at: now)
            return .update(request, pulse: request.pulse)
        case .hidden, .pending:
            if request.immediate {
                makeVisible(request, at: now)
                return .show(request)
            }
            phase = .pending(request, showAt: now + timing.appearDelay)
            return nil
        }
    }

    /// Fires due deadlines. Call at (or after) ``nextDeadline``.
    public mutating func advance(to now: TimeInterval) -> Command? {
        switch phase {
        case .pending(let request, let showAt) where now >= showAt:
            makeVisible(request, at: now)
            return .show(request)
        case .visible(_, let hideAt?) where now >= hideAt:
            // A hidden chip has no pointer over it; the next chip starts unheld.
            phase = .hidden
            forgetPointer()
            return .hide
        default:
            return nil
        }
    }

    /// Drops everything without a fade (deactivate, secure input, screen sleep, unusable caret).
    /// The last received request is remembered, so a stale identical request from a later
    /// non-keystroke event does not bring the HUD back.
    public mutating func reset() {
        phase = .hidden
        forgetPointer()
    }

    /// The pointer entered or left the chip. Only the choice bar takes the pointer: over it, the
    /// lifetime is held; on leaving, the chip hides at its own deadline but no sooner than
    /// ``Timing/pointerExitGrace`` from now. Never produces a command by itself: the caller
    /// reschedules its timer from ``nextDeadline``.
    public mutating func setPointerInside(_ inside: Bool, at now: TimeInterval) {
        guard case .visible(let request, let hideAt) = phase, request.takesPointer else {
            forgetPointer()
            return
        }
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside {
            if let hideAt, !hideIsDebounce {
                heldHideAt = hideAt
                phase = .visible(request, hideAt: nil)
            }
        } else if let held = heldHideAt {
            heldHideAt = nil
            phase = .visible(request, hideAt: max(held, now + timing.pointerExitGrace))
        }
    }

    /// Puts `request` on screen with its lifetime, held while the pointer is over the chip.
    private mutating func makeVisible(_ request: HUDRequest, at now: TimeInterval) {
        hideIsDebounce = false
        if !request.takesPointer { forgetPointer() }
        let lifetimeEnd = request.lifetime.map { now + $0 }
        heldHideAt = pointerInside ? lifetimeEnd : nil
        phase = .visible(request, hideAt: pointerInside ? nil : lifetimeEnd)
    }

    private mutating func forgetPointer() {
        pointerInside = false
        heldHideAt = nil
    }

    private mutating func requestHide(at now: TimeInterval) -> Command? {
        switch phase {
        case .hidden:
            return nil
        case .pending:
            phase = .hidden
            return nil
        case .visible(let current, let hideAt):
            let debounced = now + timing.hideDebounce
            phase = .visible(current, hideAt: min(hideAt ?? debounced, debounced))
            hideIsDebounce = true
            heldHideAt = nil
            return nil
        }
    }
}

private extension HUDRequest {
    /// Alternatives must earn the HUD; feedback (chips, badges, messages) always may show.
    var earnsHUD: Bool {
        if case .alternative(_, let eligible) = content { return eligible }
        return true
    }

    var isTimelineAlternative: Bool {
        if case .alternative = content { return true }
        return false
    }

    /// The choice bar takes clicks, so the pointer can be over it (SPEC §4.11).
    var takesPointer: Bool {
        switch content {
        case .alternative, .flipLastWord: true
        case .oneShot, .cannotChange, .bilingualLine: false
        }
    }
}
