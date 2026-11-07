import AppKit
import DuoCore
import DuoKit
import Foundation
import Observation

/// Settings ▸ 학습: the learned words read from `learning.json` (the IME is the only writer, so the
/// host only reads it and sends edits through `LearningEditor`).
///
/// While the pane is on screen the table follows the file: on `learningChanged` and whenever Duo.app
/// becomes active, coalesced. One delete is one edit however many rows it covers (safety-3), and
/// rows being forgotten stay hidden until the file no longer lists them, so a reload that races the
/// IME's write never brings them back.
@MainActor
@Observable
final class LearningModel {
    /// One table row.
    struct Row: Identifiable, Hashable, Sendable {
        var id: LearnedWord.ID
        var raw: String
        /// The argmax-vote reading, rendered by the detector (the raw keys when the model is missing).
        var result: String
        var language: ScriptLanguage
        var contextTitle: String
        /// How strongly the votes steer the detector, 0…1 (`LearnedWord.strength`).
        var strength: Double
        var lastUsed: Date
    }

    private(set) var rows: [Row] = []
    private(set) var isLoaded = false
    /// The last edit that could not be applied.
    private(set) var errorMessage: String?

    /// How long a forgotten row stays hidden while the file still lists it.
    private static let forgetHold: TimeInterval = 60

    @ObservationIgnored private let languageModel: LanguageModelProvider
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var appObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private var editTask: Task<Void, Never>?
    /// Rows asked to be forgotten, with the time their hiding lapses.
    @ObservationIgnored private var forgotten: [Row.ID: Date] = [:]

    init(languageModel: LanguageModelProvider, fileURL: URL = DuoIDs.learningFileURL) {
        self.languageModel = languageModel
        self.fileURL = fileURL
        isLive = true
        observers = [
            DistributedNotificationCenter.default().addObserver(
                forName: DuoIDs.Notifications.learningChanged, object: nil, queue: .main
            ) { [weak self] note in
                // The IME applied an edit but could not save the file.
                let saveFailed = LearningChangedNotice.reportsFailedSave(note.userInfo)
                MainActor.assumeIsolated {
                    if saveFailed { self?.errorMessage = Self.saveFailedMessage }
                    self?.scheduleReload()
                }
            },
        ]
        // The IME also learns without telling anyone; catch up when the user comes back.
        appObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleReload() } },
        ]
    }

    /// A fixed table for offscreen rendering; edits are disabled.
    init(fixture rows: [Row], languageModel: LanguageModelProvider) {
        self.languageModel = languageModel
        fileURL = DuoIDs.learningFileURL
        isLive = false
        self.rows = rows
        isLoaded = true
    }

    // MARK: Loading

    /// The pane appeared: load now, and keep the table fresh while it is on screen.
    func beginObserving() {
        viewers += 1
        if viewers == 1 { scheduleReload(after: .zero) }
    }

    func endObserving() {
        viewers = max(0, viewers - 1)
    }

    /// Re-reads the file shortly, so a burst of changes costs one read. Nothing while no pane shows it.
    func scheduleReload(after delay: Duration = .milliseconds(200)) {
        guard isLive, viewers > 0 else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        guard isLive else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        let url = fileURL
        let detector = await languageModel.detector()
        let loaded = await Task.detached(priority: .userInitiated) {
            LearnedWords.words(in: LearningFile.load(from: url)).map { Self.row(for: $0, detector: detector) }
        }.value
        guard generation == reloadGeneration else { return }
        // A forgotten row the file no longer lists is gone; the others stay hidden until the IME writes.
        let present = Set(loaded.map(\.id))
        let now = Date()
        forgotten = forgotten.filter { present.contains($0.key) && $0.value > now }
        rows = loaded.filter { forgotten[$0.id] == nil }
        isLoaded = true
    }

    // MARK: Editing

    /// Forgets the given rows: one edit, whatever the selection's size (safety-3).
    func remove(_ ids: Set<Row.ID>) {
        guard isLive, !ids.isEmpty else { return }
        let shown = Set(rows.map(\.id))
        hide(ids)
        enqueueEdit { model in
            let stored = await model.storedIDs().union(shown)
            await model.run(LearningEditor.commands(forgetting: ids, stored: stored), forgetting: ids)
        }
    }

    /// Forgets everything.
    func removeAll() {
        guard isLive else { return }
        let ids = Set(rows.map(\.id))
        hide(ids)
        enqueueEdit { model in await model.run([.removeAll], forgetting: ids) }
    }

    private func hide(_ ids: Set<Row.ID>) {
        let until = Date().addingTimeInterval(Self.forgetHold)
        for id in ids { forgotten[id] = until }
        rows.removeAll { ids.contains($0.id) }
    }

    /// Edits run one after another, so two quick deletes never interleave their commands.
    private func enqueueEdit(_ work: @escaping @MainActor (LearningModel) async -> Void) {
        let previous = editTask
        editTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Every row the file lists now, so a delete never forgets more than the user chose.
    private func storedIDs() async -> Set<Row.ID> {
        let url = fileURL
        return await Task.detached(priority: .userInitiated) {
            Set(LearnedWords.words(in: LearningFile.load(from: url)).map(\.id))
        }.value
    }

    private func run(_ commands: [LearningCommand], forgetting ids: Set<Row.ID>) async {
        errorMessage = nil
        do {
            // The IME answers with `learningChanged`; a direct write has no one to answer, so re-read now.
            if try await LearningEditor.apply(commands, fileURL: fileURL) == .written { await reload() }
        } catch {
            for id in ids { forgotten[id] = nil }
            errorMessage = Self.message(for: error)
            await reload()
        }
    }

    /// The IME forgot the words but could not write `learning.json`.
    private static var saveFailedMessage: String {
        String(localized: "학습 파일을 저장하지 못했어요. 디스크 공간과 권한을 확인해 주세요.")
    }

    private static func message(for error: any Error) -> String {
        switch error as? LearningEditor.EditError {
        case .inputMethodNotResponding:
            String(localized: "Duo 입력기가 응답하지 않아 일부 단어를 지우지 못했어요. 잠시 후 다시 해 보세요.")
        case .unreadableFile:
            String(localized: "학습 파일을 읽을 수 없어서 건드리지 않고 그대로 두었어요. 디스크 공간과 폴더 권한을 확인해 주세요.")
        case nil:
            String(localized: "학습 데이터를 바꾸지 못했어요. (\(error.localizedDescription))")
        }
    }

    nonisolated static func row(for word: LearnedWord, detector: (any LanguageDetector)?) -> Row {
        Row(id: word.id, raw: word.raw,
            result: detector?.render(raw: word.raw, word.winner) ?? word.raw,
            language: word.winner.language,
            contextTitle: word.context.title,
            strength: word.strength,
            lastUsed: word.lastUsed)
    }
}
