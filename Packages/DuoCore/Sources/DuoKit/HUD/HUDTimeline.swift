import DuoCore
import Foundation

/// The composition HUD's timing rules as a pure state machine (critique R12, ui-design §2.1,
/// ux-spec §7.3). The AppKit controller feeds it every `CompositionEngine.hud` value and wakes it at
/// ``nextDeadline``; the timeline answers with what the panel should do. No clocks, no AppKit, so
/// every rule is unit-tested.
///
/// Rules:
/// - A non-immediate request appears only after a typing pause of ``Timing/appearDelay``; every
///   keystroke restarts the pause.
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
/// - `lifetime` hides the request that long after it was shown.
/// - `pulse` is passed through only for in-place updates (a first appearance already fades in).
public struct HUDTimeline: Sendable, Equatable {
    /// Durations in seconds.
    public struct Timing: Sendable, Equatable {
        /// Typing pause before a non-immediate request appears.
        public var appearDelay: TimeInterval = 0.300
        /// Delay between a hide request and the start of the fade-out.
        public var hideDebounce: TimeInterval = 0.140
        /// Fade-in on first appearance.
        public var fadeIn: TimeInterval = 0.140
        /// Fade-in with Reduce Motion on.
        public var reducedMotionFadeIn: TimeInterval = 0.080
        /// Fade-out once the debounce or the lifetime has elapsed.
        public var fadeOut: TimeInterval = 0.100

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
    private var lastReceived: HUDRequest?

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
                phase = .visible(request, hideAt: request.lifetime.map { now + $0 })
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
            // pause (R12), and the chip goes now (ux-spec §7.3).
            phase = .pending(request, showAt: now + timing.appearDelay)
            return .hide
        case .visible:
            phase = .visible(request, hideAt: request.lifetime.map { now + $0 })
            return .update(request, pulse: request.pulse)
        case .hidden, .pending:
            if request.immediate {
                phase = .visible(request, hideAt: request.lifetime.map { now + $0 })
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
            phase = .visible(request, hideAt: request.lifetime.map { now + $0 })
            return .show(request)
        case .visible(_, let hideAt?) where now >= hideAt:
            phase = .hidden
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
}
