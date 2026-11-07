import DuoCore
import DuoKit
import Observation
import SwiftUI

/// `DuoSettings` for SwiftUI: read through `SettingsStore`, written back (debounced), and reloaded
/// live whenever either process posts `settingsChanged` (`SettingsStore.observe`).
@MainActor
@Observable
final class SettingsModel {
    /// The current settings. Mutate through `update(_:)` or `binding(_:)`.
    private(set) var value: DuoSettings

    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private let persists: Bool

    /// - Parameter persists: `false` for snapshot fixtures, which must never write the user's settings.
    init(initial: DuoSettings? = nil, persists: Bool = true) {
        self.persists = persists
        value = initial ?? SettingsStore.load()
        if persists {
            observer = SettingsStore.observe { [weak self] in self?.reload() }
        }
    }

    /// Re-reads the shared suite. Ignored while a local edit is waiting to be saved, so a slow
    /// round trip never reverts what the user just did.
    func reload() {
        guard persists, pendingSave == nil else { return }
        let loaded = SettingsStore.load()
        if loaded != value { value = loaded }
    }

    func update(_ change: (inout DuoSettings) -> Void) {
        var next = value
        change(&next)
        guard next != value else { return }
        value = next
        scheduleSave()
    }

    /// A binding to one setting; writes go through `update(_:)`.
    func binding<T>(_ keyPath: WritableKeyPath<DuoSettings, T>) -> Binding<T> {
        Binding(
            get: { self.value[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } })
    }

    /// Writes a pending edit now (app termination).
    func flush() {
        guard let task = pendingSave else { return }
        task.cancel()
        pendingSave = nil
        SettingsStore.save(value)
    }

    /// Coalesces bursts (a dragged slider) into one write and one `settingsChanged` notification.
    private func scheduleSave() {
        guard persists else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            SettingsStore.save(self.value)
            self.pendingSave = nil
        }
    }
}
