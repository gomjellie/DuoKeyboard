import AppKit

/// Borderless, non-activating, click-through floating panel for the HUD (ui-design §2.6,
/// critique R12). It is never key or main and is shown with `orderFrontRegardless()`: the input
/// method process must never become the active app, or it would steal focus from the client.
final class CompositionHUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        isFloatingPanel = true
        // The real level is set per client on show: max(client + 1, popUpMenu), never shielding.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isOpaque = false
        backgroundColor = .clear
        // Glass draws its own shadow; a window shadow would be rectangular.
        hasShadow = false
        // Fades are driven explicitly through `alphaValue`.
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        isRestorable = false
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
