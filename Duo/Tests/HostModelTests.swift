import Carbon
import DuoCore
import DuoKit
import Foundation
import Testing

@Suite("Bundle versions and install state")
struct InstallStateTests {
    @Test(arguments: [
        ("1.0.0", "1", "1.0.0", "2", true),
        ("1.9.0", "9", "1.10.0", "1", true),
        ("1.0.0", "10", "1.0.0", "9", false),
        ("2.0", "1", "1.99", "1", false),
        ("1.0.0", "1", "1.0.0", "1", false),
    ])
    func ordering(lhsVersion: String, lhsBuild: String, rhsVersion: String, rhsBuild: String, ascending: Bool) {
        let lhs = BundleVersion(marketing: lhsVersion, build: lhsBuild)
        let rhs = BundleVersion(marketing: rhsVersion, build: rhsBuild)
        #expect((lhs < rhs) == ascending)
    }

    @Test func readsInfoPlistFromDisk() throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "DuoTests-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let contents = bundle.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let version = try #require(BundleVersion(bundleURL: bundle))
        #expect(version == BundleVersion(marketing: "1.2.3", build: "45"))
        #expect(version.description == "1.2.3 (45)")
        #expect(BundleVersion(bundleURL: bundle.appending(path: "missing")) == nil)
    }

    @Test func eachStepMapsToItsFlag() {
        let state = InputMethodState(isInstalled: true, isRegistered: true, isAllowListed: false, isEnabled: true, isSelected: false)
        let done = InputMethodInstaller.Step.allCases.filter(state.isComplete)
        #expect(done == [.copied, .registered, .enabled])
        #expect(state.isReady)
        #expect(!InputMethodState(isInstalled: true).isReady)
        #expect(!InputMethodState(isEnabled: true).isReady)
    }

    @Test(arguments: [
        (true, "1.0.0", "1.1.0", true),
        (true, "1.1.0", "1.1.0", false),
        (true, "1.2.0", "1.1.0", false),
        (false, "1.0.0", "1.1.0", false),
    ])
    func updateIsOfferedOnlyForANewerEmbeddedCopy(installed: Bool, installedVersion: String, embedded: String, offered: Bool) {
        let state = InputMethodState(isInstalled: installed, installedVersion: BundleVersion(marketing: installedVersion, build: "1"))
        #expect(state.isUpdateAvailable(embedded: BundleVersion(marketing: embedded, build: "1")) == offered)
        #expect(!state.isUpdateAvailable(embedded: nil))
    }

    @Test func installErrorsPointAtTheirStep() {
        #expect(InputMethodInstaller.InstallError.bundleMissing("x").step == .copied)
        #expect(InputMethodInstaller.InstallError.copyFailed("x").step == .copied)
        #expect(InputMethodInstaller.InstallError.registerFailed(-50).step == .registered)
        #expect(InputMethodInstaller.InstallError.enableFailed(-50).step == .enabled)
        #expect(InputMethodInstaller.InstallError.selectFailed(-50).step == .selected)
    }
}

@Suite("Learned words")
struct LearnedWordsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test(arguments: [(0.0, 4.0), (60.0, 2.0), (120.0, 1.0), (-5.0, 4.0)])
    func decayHasASixtyDayHalfLife(days: Double, expected: Double) {
        let since = now.addingTimeInterval(-days * 86_400)
        #expect(abs(LearnedWords.decayed(4, since: since, now: now) - expected) < 1e-9)
    }

    @Test(arguments: [
        (["K": 1.0, "E": 3.0], Hypothesis.english),
        (["K": 3.0, "E": 3.0], .korean),
        (["E": 2.0, "M1": 2.0], .english),
        (["M3": 2.0, "M2": 2.0], .mixed(latin: 2)),
        (["K": -1.0, "M2": 0.5], .mixed(latin: 2)),
    ] as [([String: Double], Hypothesis)])
    func winnerIsTheArgmaxWithCandidateOrderTies(votes: [String: Double], expected: Hypothesis) {
        #expect(LearnedWords.winner(of: votes) == expected)
    }

    @Test func noPositiveVoteHasNoWinner() {
        #expect(LearnedWords.winner(of: ["K": 0, "E": -1, "bogus": 5]) == nil)
    }

    @Test func rowsAreGroupedByKeysThenContext() {
        let snapshot = LearningSnapshot(entries: [
            LearningEntry(raw: "go", context: .english, votes: ["E": 1], updatedAt: now),
            LearningEntry(raw: "dkssud", context: .start, votes: ["K": 4], updatedAt: now),
            LearningEntry(raw: "go", context: .korean, votes: ["K": 3, "E": 1], updatedAt: now),
            LearningEntry(raw: "zz", context: .korean, votes: [:], updatedAt: now),
        ])
        let words = LearnedWords.words(in: snapshot, now: now)
        #expect(words.map(\.raw) == ["dkssud", "go", "go"])
        #expect(words.map(\.context) == [.start, .korean, .english])
        #expect(words[1].winner == .korean)
        #expect(words[1].weight == 4)
    }

    @Test func removingOneContextOrAll() {
        let snapshot = LearningSnapshot(entries: [
            LearningEntry(raw: "go", context: .korean, votes: ["K": 3], updatedAt: now),
            LearningEntry(raw: "go", context: .english, votes: ["E": 1], updatedAt: now),
            LearningEntry(raw: "hi", context: .start, votes: ["E": 1], updatedAt: now),
        ])
        #expect(LearnedWords.removing(raw: "go", context: .korean, from: snapshot).entries.map(\.context) == [.english, .start])
        #expect(LearnedWords.removing(raw: "go", context: nil, from: snapshot).entries.map(\.raw) == ["hi"])
    }
}

@Suite("Learning commands (critique R14)")
struct LearningCommandTests {
    @Test func payloads() {
        #expect(LearningCommand.remove(raw: "go", context: .korean).userInfo == ["op": "remove", "raw": "go", "ctx": "KO"])
        #expect(LearningCommand.remove(raw: "go", context: nil).userInfo == ["op": "remove", "raw": "go"])
        #expect(LearningCommand.removeAll.userInfo == ["op": "removeAll"])
    }

    @Test func withoutTheIMEtheHostRewritesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "DuoTests-\(UUID().uuidString)/learning.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let date = Date(timeIntervalSinceReferenceDate: 0)
        try LearningFile.write(LearningSnapshot(entries: [
            LearningEntry(raw: "go", context: .korean, votes: ["K": 3], updatedAt: date),
            LearningEntry(raw: "hi", context: .start, votes: ["E": 1], updatedAt: date),
        ]), to: url)

        let delivery = try LearningEditor.apply(.remove(raw: "go", context: .korean), fileURL: url, inputMethodRunning: false)
        #expect(delivery == .written)
        #expect(LearningFile.load(from: url).entries.map(\.raw) == ["hi"])

        try LearningEditor.apply(.removeAll, fileURL: url, inputMethodRunning: false)
        #expect(LearningFile.load(from: url).entries.isEmpty)
    }
}

@Suite("App catalog")
struct AppCatalogTests {
    @Test func seenFirstThenRunningWithoutDuplicatesOrDuo() {
        let entries = AppCatalog.merge(seen: ["com.apple.Notes", "com.apple.Terminal", DuoIDs.hostAppBundleID],
                                       running: ["com.apple.Safari", "com.apple.Notes", DuoIDs.inputMethodBundleID, ""])
        #expect(entries.map(\.bundleID) == ["com.apple.Notes", "com.apple.Terminal", "com.apple.Safari"])
        #expect(entries.map(\.isSeen) == [true, true, false])
        #expect(entries.map(\.isRunning) == [true, false, true])
    }

    @Test(arguments: [(AppProfile.englishFirst, nil as AppProfile?), (.direct, .direct), (.automatic, .automatic)])
    func choosingTheDefaultRemovesTheOverride(choice: AppProfile, stored: AppProfile?) {
        let profiles = AppCatalog.setting(choice, for: "com.apple.Terminal", default: .englishFirst,
                                          in: ["com.apple.Terminal": .koreanFirst, "x": .direct])
        #expect(profiles["com.apple.Terminal"] == stored)
        #expect(profiles["x"] == .direct)
    }
}

@Suite("String Catalog")
struct LocalizationTests {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/Localizable.xcstrings")

    @Test func koreanSourceWithEnglishForEveryString() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "ko")
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(strings.count > 150)
        var untranslated: [String] = []
        for (key, entry) in strings {
            let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let unit = en?["stringUnit"] as? [String: Any]
            let plural = (en?["variations"] as? [String: Any])?["plural"] as? [String: [String: [String: Any]]]
            let translated = unit.map { $0["state"] as? String == "translated" && !(($0["value"] as? String) ?? "").isEmpty }
                ?? plural.map { $0["other"]?["stringUnit"]?["state"] as? String == "translated" }
                ?? false
            if !translated { untranslated.append(key) }
        }
        #expect(untranslated.isEmpty, "missing English: \(untranslated)")
    }

    @Test func formatSpecifiersSurviveTranslation() throws {
        let data = try Data(contentsOf: Self.catalogURL)
        let strings = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: [String: Any]])
        let specifier = /%(\d+\$)?(lld|@)/
        for (key, entry) in strings {
            guard let value = (((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            else { continue }
            #expect(key.matches(of: specifier).count == value.matches(of: specifier).count, "\(key) → \(value)")
        }
    }
}

// MARK: - Round 2 fixes

@Suite("Learned words: corrupt votes and strength (safety-2, host-12)")
struct LearnedWordsHardeningTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func hugeAndNonFiniteVotesStayInRange() {
        // A hand-edited file decodes fine, but `Int(1e20)` traps (the old table did `Int(weight.rounded())`).
        // The entries are built directly, so the table's own bound is tested whatever the loader repairs.
        let snapshot = LearningSnapshot(entries: [
            LearningEntry(raw: "go", context: .korean, votes: ["K": 1e20, "E": 1e308], updatedAt: now),
            LearningEntry(raw: "hi", context: .start, votes: ["E": .infinity, "K": 2, "M1": .nan], updatedAt: now),
        ])
        let words = LearnedWords.words(in: snapshot, now: now)
        #expect(words.count == 2)
        for word in words {
            #expect(word.weight.isFinite && word.weight <= 2 * LearnedWords.maxVote)
            #expect(word.winnerWeight <= LearnedWords.maxVote)
            #expect((0...1).contains(word.strength))
            #expect(Int(exactly: word.weight.rounded()) != nil)
        }
        #expect(words.first { $0.raw == "hi" }?.winner == .korean, "infinite and NaN votes are ignored")
        #expect(LearnedWords.winner(of: ["K": .infinity]) == nil)
    }

    @Test func overlongKeyStringsAreLeftOut() {
        let long = String(repeating: "a", count: LearnedWords.maxRawLength + 1)
        let snapshot = LearningSnapshot(entries: [
            LearningEntry(raw: long, context: .start, votes: ["E": 1], updatedAt: now),
            LearningEntry(raw: "", context: .start, votes: ["E": 1], updatedAt: now),
            LearningEntry(raw: "ok", context: .start, votes: ["E": 1], updatedAt: now),
        ])
        #expect(LearnedWords.words(in: snapshot, now: now).map(\.raw) == ["ok"])
    }

    @Test(arguments: [(0.0, 0.0), (1.0, 0.25), (3.0, 0.5), (15.0, 1.0), (900.0, 1.0)])
    func strengthFollowsTheDetectorsLogBonus(votes: Double, expected: Double) {
        // USER_LOG2[min(n, 15)] = log2(1 + n): one flip (+3) is already half of the maximum pull.
        let word = LearnedWord(raw: "go", context: .korean, winner: .korean, weight: votes, lastUsed: now)
        #expect(abs(word.strength - expected) < 1e-9)
    }

    @Test func strengthUsesTheWinnersVotesNotTheTotal() throws {
        let snapshot = LearningSnapshot(entries: [
            LearningEntry(raw: "go", context: .korean, votes: ["K": 3, "E": 1], updatedAt: now),
        ])
        let word = try #require(LearnedWords.words(in: snapshot, now: now).first)
        #expect(word.weight == 4)
        #expect(word.winnerWeight == 3)
        #expect(abs(word.strength - 0.5) < 1e-9)
    }
}

@Suite("Learning edits: one command per action (safety-3)")
@MainActor
struct LearningBatchEditTests {
    private func id(_ raw: String, _ context: LanguageContext) -> LearnedWord.ID { .init(raw: raw, context: context) }

    @Test func selectingEveryRowIsOneRemoveAll() {
        let stored: Set = [id("go", .korean), id("go", .english), id("hi", .start)]
        #expect(LearningEditor.commands(forgetting: stored, stored: stored) == [.removeAll])
    }

    @Test func everyContextOfAKeyStringIsOneRemove() {
        let stored: Set = [id("go", .korean), id("go", .english), id("hi", .start), id("zz", .korean)]
        let commands = LearningEditor.commands(forgetting: [id("go", .korean), id("go", .english), id("hi", .start)],
                                               stored: stored)
        #expect(commands == [.remove(raw: "go", context: nil), .remove(raw: "hi", context: nil)])
    }

    @Test func aPartlySelectedKeyStringKeepsItsOtherContexts() {
        let stored: Set = [id("go", .start), id("go", .korean), id("go", .english), id("hi", .start)]
        let commands = LearningEditor.commands(forgetting: [id("go", .english), id("go", .start)], stored: stored)
        #expect(commands == [.remove(raw: "go", context: .start), .remove(raw: "go", context: .english)])
    }

    @Test func rowsTheUserDidNotSeeAreNeverForgotten() {
        // The table shows only go/KO, but the file has learned go/EN since: no removeAll, no context-less remove.
        let commands = LearningEditor.commands(forgetting: [id("go", .korean)], stored: [id("go", .english)])
        #expect(commands == [.remove(raw: "go", context: .korean)])
        #expect(LearningEditor.commands(forgetting: [], stored: [id("go", .english)]).isEmpty)
    }

    /// Records posts and barriers, as the IME would see them.
    @MainActor
    final class Recorder {
        var posted: [LearningCommand] = []
        var pendingAtBarrier: [Int] = []
        var confirmed = 0
        var answers: [Bool] = []

        var channel: LearningCommandChannel {
            LearningCommandChannel(post: { self.posted.append($0) }, barrier: {
                self.pendingAtBarrier.append(self.posted.count - self.confirmed)
                self.confirmed = self.posted.count
                return self.answers.isEmpty ? true : self.answers.removeFirst()
            })
        }
    }

    @Test func manyRowsGoInConfirmedBurstsBelowTheNotificationQueueLimit() async {
        let commands = (0..<1_234).map { LearningCommand.remove(raw: "w\($0)", context: .korean) }
        let recorder = Recorder()
        #expect(await LearningEditor.send(commands, via: recorder.channel))
        #expect(recorder.posted == commands)
        #expect(recorder.pendingAtBarrier.allSatisfy { $0 <= LearningEditor.maxBurst })
        #expect(recorder.pendingAtBarrier.count == 25)
        #expect(LearningEditor.maxBurst < 256 / 2)
    }

    @Test func anUnansweredBurstStopsTheRest() async throws {
        let commands = (0..<120).map { LearningCommand.remove(raw: "w\($0)", context: nil) }
        let recorder = Recorder()
        recorder.answers = [true, false]
        await #expect(throws: LearningEditor.EditError.inputMethodNotResponding) {
            try await LearningEditor.apply(commands, inputMethodRunning: true, channel: recorder.channel)
        }
        #expect(recorder.posted.count == 2 * LearningEditor.maxBurst)
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "DuoTests-\(UUID().uuidString)/learning.json")
    }

    @Test func withoutTheIMEaBatchIsOneRewrite() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let date = Date(timeIntervalSinceReferenceDate: 0)
        try LearningFile.write(LearningSnapshot(entries: (0..<300).map {
            LearningEntry(raw: "w\($0)", context: .korean, votes: ["K": 3], updatedAt: date)
        }), to: url)
        let commands = (0..<200).map { LearningCommand.remove(raw: "w\($0)", context: .korean) }
        let recorder = Recorder()
        let delivery = try await LearningEditor.apply(commands, fileURL: url, inputMethodRunning: false,
                                                      channel: recorder.channel)
        #expect(delivery == .written)
        #expect(recorder.posted.isEmpty)
        #expect(Set(LearningFile.load(from: url).entries.map(\.raw)) == Set((200..<300).map { "w\($0)" }))
    }

    private static let unreadable = Data(#"{"version":1,"entries":[{"raw":"go","#.utf8)

    private func files(besides url: URL) throws -> [Data] {
        let dir = url.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).map { try Data(contentsOf: dir.appending(path: $0)) }
    }

    @Test func anUnreadableFileIsNeverReplacedByAnEdit() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.unreadable.write(to: url)
        try LearningEditor.rewrite(url, applying: [.remove(raw: "go", context: nil)])
        #expect(try files(besides: url).contains(Self.unreadable), "the original bytes survive (set aside)")
        if FileManager.default.fileExists(atPath: url.path) {
            #expect(try Data(contentsOf: url) == Self.unreadable, "never replaced by a partial edit")
        }
    }

    @Test func anUnreadableFileThatCannotBeSetAsideIsLeftAloneUnlessEverythingGoes() throws {
        let url = temporaryFile()
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.unreadable.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(throws: LearningEditor.EditError.unreadableFile) {
            try LearningEditor.rewrite(url, applying: [.remove(raw: "go", context: nil)])
        }
        #expect(try Data(contentsOf: url) == Self.unreadable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        // Erase All goes through: afterwards no learned word can be read from the file.
        try LearningEditor.rewrite(url, applying: [.removeAll])
        #expect(LearningFile.load(from: url).entries.isEmpty)
    }

    @Test func aMissingFileIsNotCreated() throws {
        let url = temporaryFile()
        try LearningEditor.rewrite(url, applying: [.remove(raw: "go", context: nil), .removeAll])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("Playground with the real model (host-1, host-3, host-4)")
@MainActor
struct PlaygroundSessionTests {
    /// `DuoInputMethod/Resources/duo-model.bin` of this repository, found from this file's path.
    static let modelURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "DuoInputMethod/Resources/duo-model.bin")
    static let detector = Result { try DuoDetector(modelURL: modelURL) }

    private func session() throws -> PlaygroundSession {
        PlaygroundSession(detector: try Self.detector.get(), learning: LearningSnapshot(), settings: DuoSettings())
    }

    /// Right ⌘ down, optionally a menu shortcut while it is held, then up 0.1 s later.
    private func tapRightCommand(_ session: PlaygroundSession, during shortcut: KeyEvent? = nil) {
        let t = ProcessInfo.processInfo.systemUptime
        session.handleModifier(ModifierEvent(keyCode: FlipTapDetector.KeyCode.rightCommand,
                                             flags: FlipTapDetector.Flags.command | FlipTapDetector.Flags.rightCommandDevice,
                                             timestamp: t))
        if let shortcut { session.noteShortcut(shortcut) }
        session.handleModifier(ModifierEvent(keyCode: FlipTapDetector.KeyCode.rightCommand, flags: 0, timestamp: t + 0.1))
    }

    @Test(arguments: ["dkssudgktpdy Duofmf TJqhkdy. macOS 26 djqepdlxm ", "dlrjs ", "dkssud ", "", "hello "])
    func practiceTask3TicksAfterOneFlipOfGo(prefix: String) throws {
        let session = try session()
        session.type(prefix + "go")
        #expect(session.isComposing)
        tapRightCommand(session)
        let flip = try #require(session.takeFlip())
        #expect(flip.whileComposing)
        if prefix.hasPrefix("d") {
            // DET already shows 해 after Korean, so the one flip the task asks for gives go.
            #expect(flip.language == .english)
            #expect(session.buffer.markedText == "go")
        }
        var progress = PracticeProgress()
        progress.note(flip: PlaygroundFlip(serial: 1, language: flip.language, whileComposing: flip.whileComposing,
                                           word: flip.word))
        #expect(progress.flippedWhileTyping)
        #expect(!progress.flippedLastWord)
    }

    @Test func aMenuShortcutDuringTheFlipKeyHoldIsAChordNotAFlip() throws {
        let command = KeyEvent(.letter(try #require(Keystroke(latin: "c"))), modifiers: .command)
        let session = try session()
        session.type("dkssud ")
        #expect(session.text == "안녕 ")
        tapRightCommand(session, during: command)
        #expect(session.text == "안녕 ")
        #expect(session.takeFlip() == nil)

        // Without seeing the shortcut (the menu took it), the release reads as a tap and flips the word.
        let unaware = try self.session()
        unaware.type("dkssud ")
        tapRightCommand(unaware)
        #expect(unaware.text == "dkssud ")
    }

    @Test func aShortcutCommitsTheWordBeingTyped() throws {
        let session = try session()
        session.type("dkss")
        #expect(session.isComposing)
        session.noteShortcut(KeyEvent(.letter(try #require(Keystroke(latin: "a"))), modifiers: .command))
        #expect(!session.isComposing)
        #expect(session.markedRange == nil)
        // Plain keys are not shortcuts.
        session.type("dk")
        session.noteShortcut(KeyEvent(.letter(try #require(Keystroke(latin: "s"))), modifiers: .shift))
        #expect(session.isComposing)
    }

    @Test func switchingToNativeModeAndBackKeepsEveryCharacter() throws {
        let session = try session()
        session.type("dkssud ")
        session.type("dkss")
        #expect(session.markedRange != nil)
        session.suspend()
        #expect(session.markedRange == nil, "the marked word is committed for the native view")
        let carried = session.text
        #expect(carried.hasPrefix("안녕 ") && carried.count > "안녕 ".count)

        // The user types natively, then switches back: the engine continues from the native text.
        session.resume(text: carried + "hello ")
        #expect(session.text == carried + "hello ")
        #expect(session.selection == NSRange(location: (session.text as NSString).length, length: 0))
        session.type("dkssud ")
        #expect(session.text == carried + "hello 안녕 ")
    }
}

@Suite("Onboarding and window routing (host-5, host-7)")
struct OnboardingRouteTests {
    @Test func launchArgumentsNameTheRequest() {
        #expect(HostLaunchRequest(arguments: ["Duo"]) == .none)
        #expect(HostLaunchRequest(arguments: ["Duo", HostRequest.showGuideArgument]) == .guide)
        #expect(HostLaunchRequest(arguments: ["Duo", HostRequest.showSettingsArgument]) == .settings)
    }

    @Test(arguments: [
        (false, false, HostLaunchRequest.none, true),
        (true, false, .none, false),
        (true, true, .none, true),
        (true, false, .guide, true),
        (false, false, .settings, false),
        (false, true, .settings, false),
    ])
    func whichWindowOpens(completed: Bool, needsSetup: Bool, request: HostLaunchRequest, onboarding: Bool) {
        #expect(OnboardingRoute.presentsOnboarding(hasCompleted: completed, needsSetup: needsSetup, request: request) == onboarding)
    }

    @Test func initialStep() {
        #expect(OnboardingRoute.initialStep(hasCompleted: false, request: .none) == .welcome)
        #expect(OnboardingRoute.initialStep(hasCompleted: true, request: .none) == .enable)
        #expect(OnboardingRoute.initialStep(hasCompleted: true, request: .guide) == .welcome)
    }

    @Test func reopeningAMinimizedOnboardingWindowKeepsItsStep() {
        #expect(OnboardingRoute.reopen(onboardingWindowIsOpen: true, presentsOnboarding: true, initialStep: .welcome)
            == .onboarding(restartAt: nil))
        #expect(OnboardingRoute.reopen(onboardingWindowIsOpen: true, presentsOnboarding: false, initialStep: .enable)
            == .onboarding(restartAt: nil))
        #expect(OnboardingRoute.reopen(onboardingWindowIsOpen: false, presentsOnboarding: true, initialStep: .enable)
            == .onboarding(restartAt: .enable))
        #expect(OnboardingRoute.reopen(onboardingWindowIsOpen: false, presentsOnboarding: false, initialStep: .enable)
            == .settings)
    }

    @Test func theDelayedAutoAdvanceOnlyMovesFromEnable() {
        #expect(OnboardingRoute.step(afterEnablingFrom: .enable) == .tryIt)
        // The user pressed 계속 (or 나중에) within the 700 ms: do not skip 써보기.
        #expect(OnboardingRoute.step(afterEnablingFrom: .tryIt) == nil)
        #expect(OnboardingRoute.step(afterEnablingFrom: .welcome) == nil)
        #expect(OnboardingRoute.step(afterEnablingFrom: .done) == nil)
    }

    @Test(arguments: [
        (OnboardingStep.welcome, true, false),
        (.enable, false, false),
        (.enable, true, true),
        (.tryIt, true, true),
        (.done, true, true),
        (.tryIt, false, false),
    ])
    func closingFinishesOnboardingOnceDuoIsReady(step: OnboardingStep, ready: Bool, completes: Bool) {
        #expect(OnboardingRoute.completesOnClose(at: step, isReady: ready) == completes)
    }
}

@Suite("Install checklist and recovery (host-2)")
@MainActor
struct InstallChecklistTests {
    typealias Step = InputMethodInstaller.Step

    @Test func aFailureTheUserFixedInTheInputMenuShowsAsDone() {
        let selected = InputMethodState(isInstalled: true, isRegistered: true, isAllowListed: true, isEnabled: true, isSelected: true)
        #expect(InstallChecklist.resolves(failureAt: .selected, in: selected))
        #expect(InstallChecklist.mark(for: .selected, running: nil, failed: .selected, finished: [], state: selected) == .done)
        let notYet = InputMethodState(isInstalled: true, isRegistered: true, isAllowListed: true, isEnabled: true)
        #expect(InstallChecklist.mark(for: .selected, running: nil, failed: .selected, finished: [], state: notYet) == .failed)
        #expect(InstallChecklist.resolves(failureAt: .enabled, in: notYet))
    }

    @Test func copyAndRegistrationFailuresStayEvenIfAnOldInstallLooksComplete() {
        let old = InputMethodState(isInstalled: true, isRegistered: true, isAllowListed: true, isEnabled: true, isSelected: true)
        #expect(!InstallChecklist.resolves(failureAt: .copied, in: old))
        #expect(!InstallChecklist.resolves(failureAt: .registered, in: old))
        #expect(InstallChecklist.mark(for: .copied, running: nil, failed: .copied, finished: [], state: old) == .failed)
        #expect(InstallChecklist.mark(for: .registered, running: .registered, failed: nil, finished: [], state: old) == .running)
        #expect(InstallChecklist.mark(for: .enabled, running: nil, failed: nil, finished: [.enabled], state: InputMethodState()) == .done)
        #expect(InstallChecklist.mark(for: .enabled, running: nil, failed: nil, finished: [], state: InputMethodState()) == .pending)
    }

    final class Fake {
        var enabledAfterPolls: Int?
        var polls = 0
        var selectResults: [OSStatus] = []
        var selects = 0
        var steps: [Step] = []
        var slept: Duration = .zero

        func isEnabled() -> Bool {
            defer { polls += 1 }
            return enabledAfterPolls.map { polls >= $0 } ?? false
        }

        func select() -> OSStatus {
            selects += 1
            return selectResults.isEmpty ? noErr : selectResults.removeFirst()
        }
    }

    private func resume(_ error: InputMethodInstaller.InstallError, _ fake: Fake) async -> InputMethodInstaller.InstallError? {
        await InstallRecovery.resume(after: error, select: true, isEnabled: fake.isEnabled, selectSource: fake.select,
                                     onStep: { fake.steps.append($0) }, sleep: { fake.slept += $0 })
    }

    @Test func waitsForTheUserToAllowTheSourceThenSelects() async {
        let fake = Fake()
        fake.enabledAfterPolls = 6
        #expect(await resume(.enableFailed(noErr), fake) == nil)
        #expect(fake.steps == [.allowListed, .enabled, .selected], "Allow approves and enables at once")
        #expect(fake.slept == InstallRecovery.pollInterval * 6)
    }

    @Test func givesUpOnEnablingAfterTheTimeout() async {
        let fake = Fake()
        #expect(await resume(.enableFailed(noErr), fake) == .enableFailed(noErr))
        #expect(fake.steps.isEmpty)
        #expect(fake.selects == 0)
        #expect(fake.slept >= InstallRecovery.enableTimeout)
    }

    @Test func asksOnceMoreWhenThePromptMayHaveBeenLost() async {
        // System Settings was launched by the enable call and dropped the prompt: one more enable
        // after `reenableAfter` brings it up; never a second time.
        let fake = Fake()
        fake.enabledAfterPolls = 20
        var reenables = 0
        let result = await InstallRecovery.resume(
            after: .enableFailed(noErr), select: true, isEnabled: fake.isEnabled, selectSource: fake.select,
            onStep: { fake.steps.append($0) }, reenable: { reenables += 1 }, sleep: { fake.slept += $0 })
        #expect(result == nil)
        #expect(reenables == 1)
        #expect(fake.steps == [.allowListed, .enabled, .selected])

        let refused = Fake()
        var asked = 0
        _ = await InstallRecovery.resume(
            after: .enableFailed(-50), select: true, isEnabled: refused.isEnabled, selectSource: refused.select,
            onStep: { _ in }, reenable: { asked += 1 }, sleep: { refused.slept += $0 })
        #expect(asked == 0, "a refused enable is not asked again")
    }

    @Test func aRejectedEnableIsReportedWithoutTheLongWait() async {
        // TIS refused (paramErr): no prompt is waiting, so the error shows after a short grace.
        let fake = Fake()
        #expect(await resume(.enableFailed(-50), fake) == .enableFailed(-50))
        #expect(fake.slept >= InstallRecovery.rejectedEnableGrace)
        #expect(fake.slept < InstallRecovery.enableTimeout)

        let late = Fake()
        late.enabledAfterPolls = 2
        #expect(await resume(.enableFailed(-50), late) == nil, "a source list that caught up still selects")
        #expect(late.steps == [.allowListed, .enabled, .selected])
    }

    @Test func retriesAFailedSelectOnce() async {
        let fake = Fake()
        fake.selectResults = [-50]
        #expect(await resume(.selectFailed(-50), fake) == nil)
        #expect(fake.selects == 2)
        #expect(fake.steps == [.selected])

        let stubborn = Fake()
        stubborn.selectResults = [-50, -51]
        #expect(await resume(.selectFailed(-50), stubborn) == .selectFailed(-51))
        #expect(stubborn.selects == 2)
    }

    @Test func otherFailuresAreNotRetried() async {
        let fake = Fake()
        #expect(await resume(.copyFailed("disk full"), fake) == .copyFailed("disk full"))
        #expect(fake.selects == 0 && fake.polls == 0)
    }
}

@Suite("Status polling and links (host-9, host-14)")
struct HostPolicyTests {
    @Test(arguments: [
        (0, true, true, 1, false),
        (1, true, false, 0, true),
        (1, false, false, 0, false),
        (1, false, true, 0, true),
        (2, false, false, 1, true),
    ])
    func pollsOnlyWhileSomeoneCanSeeIt(monitors: Int, active: Bool, busy: Bool, background: Int, polls: Bool) {
        #expect(StatusPolling.isNeeded(monitors: monitors, appIsActive: active, isBusy: busy, backgroundMonitors: background) == polls)
    }

    @Test func licenseLinkFollowsTheAppLanguage() {
        #expect(HostLinks.ccBySALegalCode(languageCode: "ko").absoluteString
            == "https://creativecommons.org/licenses/by-sa/4.0/legalcode.ko")
        #expect(HostLinks.ccBySALegalCode(languageCode: "en").absoluteString
            == "https://creativecommons.org/licenses/by-sa/4.0/legalcode.en")
        #expect(HostLinks.ccBySALegalCode(languageCode: nil).absoluteString.hasSuffix("legalcode.en"))
    }
}
