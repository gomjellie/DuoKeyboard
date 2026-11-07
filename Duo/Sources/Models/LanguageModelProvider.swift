import DuoCore
import DuoKit
import Foundation
import Observation

/// Loads `duo-model.bin` from the embedded input method (critique R21) once, off the main thread,
/// and shares the detector with the playgrounds and the learning table.
@MainActor
@Observable
final class LanguageModelProvider {
    enum State: Equatable {
        case loading
        case ready
        /// The embedded IME or its model is missing or unreadable; the UI degrades gracefully.
        case unavailable
    }

    private(set) var state: State = .loading
    @ObservationIgnored private let load: Task<DuoDetector?, Never>

    init(modelURL: URL?) {
        load = Task.detached(priority: .userInitiated) {
            guard let modelURL else { return nil }
            return try? DuoDetector(modelURL: modelURL)
        }
        Task { [weak self, load] in
            let detector = await load.value
            self?.state = detector == nil ? .unavailable : .ready
        }
    }

    /// The detector, once loading has finished (`nil` when unavailable).
    func detector() async -> DuoDetector? { await load.value }
}
