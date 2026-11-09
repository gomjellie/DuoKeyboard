import AppKit
import DuoCore
import DuoKit
import Observation
import SwiftUI

/// Watches this app's own key events for a flip-key press with the engine's own `FlipTapDetector`
/// (no permission needed: a local monitor only sees events sent to Duo's windows). Events are
/// always passed on unchanged.
@MainActor
@Observable
final class FlipKeyCoachModel {
    private(set) var detected = false
    /// Briefly true right after a press, to light the key caps.
    private(set) var flash = false
    /// No press within 8 s: offer the other flip keys (critique P2).
    private(set) var offersAlternatives = false

    @ObservationIgnored private var detector: FlipTapDetector
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    static let alternativesDelay: Duration = .seconds(8)

    init(settings: DuoSettings) {
        detector = FlipTapDetector(flipKey: settings.flipKey, tapWindowMs: settings.flipTapWindowMs)
    }

    #if DEBUG
    /// A frozen state for offscreen renders.
    init(fixtureFlipKey: FlipKey, detected: Bool, offersAlternatives: Bool) {
        detector = FlipTapDetector(flipKey: fixtureFlipKey)
        self.detected = detected
        self.offersAlternatives = offersAlternatives
    }
    #endif

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        scheduleAlternatives()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hintTask?.cancel()
        flashTask?.cancel()
    }

    func apply(_ settings: DuoSettings) {
        guard settings.flipKey != detector.flipKey || Int((detector.tapWindow * 1000).rounded()) != settings.flipTapWindowMs
        else { return }
        detector = FlipTapDetector(flipKey: settings.flipKey, tapWindowMs: settings.flipTapWindowMs)
        detected = false
    }

    private func observe(_ event: NSEvent) {
        let fired: Bool
        switch event.type {
        case .flagsChanged:
            fired = KeyEventMapper.modifierEvent(from: event).map { detector.handle($0) } ?? false
        case .keyDown:
            detector.noteKeyDown()
            fired = Self.isShiftSpace(event, flipKey: detector.flipKey)
        default:
            detector.noteMouseDown()
            fired = false
        }
        guard fired else { return }
        withAnimation(.snappy) {
            detected = true
            flash = true
        }
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.flash = false }
        }
    }

    /// ⇧Space is a key-down, which the engine handles itself rather than the tap detector.
    private static func isShiftSpace(_ event: NSEvent, flipKey: FlipKey) -> Bool {
        flipKey == .shiftSpace && event.keyCode == KeyEventMapper.VK.space && !event.isARepeat
            && event.modifierFlags.intersection([.shift, .control, .option, .command]) == .shift
    }

    private func scheduleAlternatives() {
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: Self.alternativesDelay)
            guard let self, !Task.isCancelled, !self.detected else { return }
            withAnimation(.smooth) { self.offersAlternatives = true }
        }
    }
}

/// Step 3's flip-key card: "press it now", a check when it works, alternatives after 8 s.
struct FlipKeyCoach: View {
    let coach: FlipKeyCoachModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let flipKey = app.settings.value.flipKey
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                KeyCaps(flipKey: flipKey, size: 17, isHighlighted: coach.flash)
                    .frame(minWidth: 52)
                    .animation(.snappy, value: coach.flash)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coach.detected ? "잘 눌렸어요!" : "바꾸기 키를 눌러 보세요")
                        .font(.headline)
                    Text(coach.detected
                         ? String(localized: "단어가 잘못 나오면 이렇게 바꾸면 돼요. 바꾼 단어는 Duo가 기억해요.")
                         : flipKey.instruction)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if coach.detected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            if coach.offersAlternatives && !coach.detected {
                Divider()
                Text("이 키보드에서 누르기 어렵다면 다른 키를 골라 보세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                FlipKeyPicker(selection: app.settings.binding(\.flipKey), compact: true)
            }
        }
        .duoCard(padding: 14)
        .onAppear { coach.start() }
        .onDisappear { coach.stop() }
        .onChange(of: app.settings.value) { _, settings in coach.apply(settings) }
        .accessibilityElement(children: .contain)
    }
}
