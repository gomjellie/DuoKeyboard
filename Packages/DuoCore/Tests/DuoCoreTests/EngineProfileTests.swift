import Foundation
import Testing
@testable import DuoCore
import DuoKit

/// SPEC.md §4.10 client profiles, the Direct profile, Caps Lock, dead keys and shortcuts.
@MainActor
@Suite("Engine · profiles and input modes")
struct EngineProfileTests {
    typealias Call = RecordingClient.Call

    // MARK: ClientProfile table

    @Test(arguments: [
        ("com.apple.Terminal", AppProfile.automatic, ReplacementSupport.beforeCaretOnly, true, false),
        ("com.googlecode.iterm2", .automatic, .none, true, false),
        ("com.stablyai.orca", .automatic, .full, true, false),
        ("com.cmuxterm.app", .automatic, .full, true, false),
        ("com.mitchellh.ghostty", .automatic, .full, true, false),
        ("dev.warp.Warp-Stable", .automatic, .full, true, false),
        ("net.kovidgoyal.kitty", .automatic, .full, true, false),
        ("org.alacritty", .automatic, .full, true, false),
        ("com.github.wez.wezterm", .automatic, .full, true, false),
        ("co.zeit.hyper", .automatic, .none, true, false),
        ("com.apple.dt.Xcode", .englishFirst, .full, false, false),
        ("com.microsoft.VSCode", .englishFirst, .full, false, false),
        ("com.todesktop.230313mzl4w4u92", .englishFirst, .full, false, false),
        ("dev.zed.Zed", .englishFirst, .full, false, false),
        ("com.sublimetext.4", .englishFirst, .full, false, false),
        ("com.panic.Nova", .englishFirst, .full, false, false),
        ("com.barebones.bbedit", .englishFirst, .full, false, false),
        ("com.jetbrains.WebStorm", .englishFirst, .none, false, true),
        ("com.jetbrains.intellij", .englishFirst, .none, false, true),
        ("com.google.android.studio", .englishFirst, .none, false, true),
        ("com.kakao.KakaoTalkMac", .koreanFirst, .full, false, false),
        ("com.hancom.office.hwp12.mac.general", .koreanFirst, .full, false, false),
        ("jp.naver.line.mac", .koreanFirst, .full, false, false),
        ("com.tinyspeck.slackmacgap", .automatic, .full, false, false),
        ("com.apple.TextEdit", .automatic, .full, false, false),
        ("", .automatic, .full, false, false),
    ])
    func profileTable(_ id: String, _ profile: AppProfile, _ replacement: ReplacementSupport, _ terminal: Bool,
                      _ java: Bool) {
        let p = ClientProfile.forBundleIdentifier(id)
        #expect(p.bundleIdentifier == id)
        #expect(p.defaultAppProfile == profile)
        #expect(p.replacement == replacement)
        #expect(p.isTerminal == terminal)
        #expect(p.needsMarkBeforeInsert == java)
    }

    @Test func orcaKeepsMarkedTextButNeverRewritesCommittedText() {
        // xterm.js ignores replacement ranges: the flipped word landed after the old one
        // (user report: 이상하게dltkdgkrp).
        let p = ClientProfile.forBundleIdentifier("com.stablyai.orca")
        #expect(p.replacement == .full)
        #expect(!p.canReplaceCommittedText)
        let h = EngineHarness(bundleIdentifier: "com.stablyai.orca")
        h.buffer.ignoresReplacementRanges = true
        h.detector.korean("dltkdgkrp")
        h.type("dltkdgkrp ")
        let before = h.text
        h.flip()
        #expect(h.text == before, "nothing appended")
        #expect(h.hud?.content == .cannotChange)
    }

    /// "Enter로 바로 보내기" rewrites the word on every key: only clients that honour replacement
    /// ranges and let committed text change can have it (SPEC.md 4.10절).
    @Test(arguments: [
        ("ru.keepcoder.Telegram", true),
        ("com.apple.TextEdit", true),
        ("com.kakao.KakaoTalkMac", true),
        ("com.anthropic.claudefordesktop", true),
        ("com.apple.Terminal", false),
        ("com.googlecode.iterm2", false),
        ("com.stablyai.orca", false),
        ("com.mitchellh.ghostty", false),
        ("com.microsoft.VSCode", false),
        ("com.vscodium", false),
        ("com.jetbrains.intellij", false),
        ("com.google.android.studio", false),
    ])
    func inlineSupport(_ id: String, _ supported: Bool) {
        let p = ClientProfile.forBundleIdentifier(id)
        #expect(p.supportsInline == supported)
        var settings = DuoSettings()
        #expect(!p.usesInline(settings), "off until the user turns it on")
        settings.inlineApps = [id]
        #expect(p.usesInline(settings) == supported)
    }

    @Test func onlyXtermTerminalsPlaceTheHUDAtTheFocusedElement() {
        #expect(ClientProfile.forBundleIdentifier("com.stablyai.orca").compositionAtFocusedElement)
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.TextEdit", "com.microsoft.VSCode",
                   "com.google.Chrome"] {
            #expect(!ClientProfile.forBundleIdentifier(id).compositionAtFocusedElement, "\(id)")
        }
    }

    @Test func directIsNeverADefault() {
        let ids = Array(ClientProfile.terminals.keys) + Array(ClientProfile.codeEditors) + Array(ClientProfile.koreanFirst)
        #expect(ids.allSatisfy { ClientProfile.forBundleIdentifier($0).defaultAppProfile != .direct })
    }

    @Test(arguments: [
        ("com.apple.TextEdit", 0, -1000, -1000),
        ("com.kakao.KakaoTalkMac", 0, nil, 1000),
        ("com.kakao.KakaoTalkMac", 1000, nil, 1500),
        ("com.microsoft.VSCode", -1000, nil, -1500),
        ("com.microsoft.VSCode", 500, nil, -500),
        ("com.apple.Terminal", 0, nil, 0),
        ("com.apple.Terminal", 0, -1000, -1000),
    ] as [(String, Int, Int?, Int)])
    func biasKOCombinesProfileAndSliderClamped(_ id: String, _ slider: Int, _ englishOverride: Int?, _ expected: Int) {
        var settings = DuoSettings()
        settings.languageBias = slider
        if englishOverride != nil { settings.appProfiles[id] = .englishFirst }
        #expect(ClientProfile.forBundleIdentifier(id).biasKO(settings) == expected)
    }

    @Test func biasReachesTheDetectorOnEveryCall() {
        let h = EngineHarness(bundleIdentifier: "com.kakao.KakaoTalkMac")
        h.detector.korean("dk")
        h.type("dk")
        #expect(h.detector.lastBias == 1000)
        h.press(.space)
        #expect(h.detector.lastBias == 1000)
    }

    @Test func userOverrideWins() {
        var settings = DuoSettings()
        settings.appProfiles["com.microsoft.VSCode"] = .koreanFirst
        let h = EngineHarness(settings: settings, bundleIdentifier: "com.microsoft.VSCode")
        #expect(h.engine.effectiveProfile == .koreanFirst)
        h.type("a")
        #expect(h.detector.lastBias == 1000)
    }

    // MARK: Direct

    @Test func directPassesEverythingUntilAFlipTurnsOnBilingualForTheLine() {
        // ux-spec §9 #74–75, opt-in Direct.
        var settings = DuoSettings()
        settings.appProfiles["com.apple.Terminal"] = .direct
        let h = EngineHarness(settings: settings, bundleIdentifier: "com.apple.Terminal")
        h.detector.korean("qjrm")
        h.detector.korean("tnwjd")
        let raw = h.type("ls -al")
        #expect(raw.allSatisfy { !$0.consumed && $0.calls.isEmpty })
        #expect(h.hud == nil)
        h.press(.returnKey)
        #expect(h.text == "ls -al\n")

        h.flip()
        #expect(h.engine.bilingualLine)
        #expect(h.hud == HUDRequest(content: .bilingualLine, anchor: .caret, immediate: true))
        h.type("qjrm tnwjd")
        #expect(h.text == "ls -al\n버그 수정")
        #expect(h.hud != nil)
        let ret = h.press(.returnKey)
        #expect(!ret.consumed)
        #expect(ret.mutations == [.insert("수정", nil)])
        #expect(!h.engine.bilingualLine, "Return ends Bilingual and goes back to Direct")
        #expect(h.hud == nil)
        #expect(h.text == "ls -al\n버그 수정\n")
        #expect(h.store.count == 0, "never learned in Direct")
        let after = h.type("dd")
        #expect(after.allSatisfy { !$0.consumed })
    }

    @Test func switchingToDirectMidWordCommitsTheWordFirst() {
        // The input menu's 직접 입력 changes the profile while 안녕 is marked; the next key sees it.
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        #expect(h.marked == "안녕")
        var settings = h.engine.settings
        settings.appProfiles["com.apple.TextEdit"] = .direct
        h.engine.settings = settings
        let a = h.press(.letter("a"), after: 3)   // choosing from the menu takes a while
        #expect(!a.consumed)
        #expect(a.mutations == [.insert("안녕", nil)], "committed before the app types the key")
        #expect(!h.engine.isComposing)
        #expect(h.engine.lastCommit == nil, "a typed letter ends flip case (b)")
        h.type("b")
        h.press(.returnKey)
        h.type("cd")
        _ = h.commit(.mouse)
        #expect(h.text == "안녕ab\ncd")
        #expect(h.store.count == 0, "never learned in Direct")
    }

    @Test func aFlipThatChangesNothingKeepsTheBilingualBadge() {
        // In a Bilingual line, the flip key over literal text flips nothing: the line stays
        // bilingual, so the badge must stay (before: the modifier path left `hud == nil`, the badge
        // disappeared and VoiceOver announced "back to direct input").
        var settings = DuoSettings()
        settings.appProfiles["com.apple.TextEdit"] = .direct
        let h = EngineHarness(settings: settings)
        h.detector.korean("dkssud")
        h.flip()
        #expect(h.engine.bilingualLine)
        h.type("/he")
        #expect(h.hud == CompositionEngine.bilingualBadge)
        let calls = h.flip()
        #expect(calls.filter(\.isMutation).isEmpty, "literal text is never flipped")
        #expect(h.engine.bilingualLine)
        #expect(h.hud == CompositionEngine.bilingualBadge)
        h.press(.space)
        h.type("dkssud")
        h.press(.space)
        #expect(h.text == "/he 안녕 ", "the line is still bilingual")
    }

    @Test func leavingDirectWhileBilingualEndsTheLine() {
        // Re-review R5: the input menu switches a Direct app to Automatic mid-line.
        var settings = DuoSettings()
        settings.appProfiles["com.apple.TextEdit"] = .direct
        let h = EngineHarness(settings: settings)
        h.detector.korean("dkssud")
        h.flip()
        #expect(h.engine.bilingualLine)
        _ = h.commit(.commitComposition)
        var s = h.engine.settings
        s.appProfiles["com.apple.TextEdit"] = .automatic
        h.engine.settings = s
        #expect(!h.engine.bilingualLine)
        #expect(h.hud == nil)
        h.type("dkssud ")
        #expect(h.text == "안녕 ")
        #expect(h.hud != CompositionEngine.bilingualBadge, "no Bilingual line outside Direct")
    }

    @Test func aFlipKeyPressAloneDoesNotAnnounceTheBilingualLine() {
        // Re-review R3: after commitComposition cleared the HUD, pressing (not yet releasing) the
        // flip key toggles nothing, so the badge must not come back on that press.
        var settings = DuoSettings()
        settings.appProfiles["com.apple.TextEdit"] = .direct
        let h = EngineHarness(settings: settings)
        h.detector.korean("dkssud")
        h.flip()
        #expect(h.engine.bilingualLine)
        h.type("dkssud")
        _ = h.commit(.commitComposition)
        #expect(h.engine.hud == nil)
        h.now += 0.05
        h.engine.handleModifier(ModifierEvent(keyCode: FlipTapDetector.KeyCode.rightCommand,
                                              flags: FlipTapDetector.Flags.command | FlipTapDetector.Flags.rightCommandDevice,
                                              timestamp: h.now), client: h.client)
        #expect(HUDAnnouncement.feedback(for: .modifier, before: nil, after: h.engine.hud) == nil)
    }

    @Test func directEscapeEndsBilingualAndASecondTapTurnsItOff() {
        var settings = DuoSettings()
        settings.appProfiles["com.apple.TextEdit"] = .direct
        let h = EngineHarness(settings: settings)
        h.flip()
        h.press(.escape)
        #expect(!h.engine.bilingualLine)
        h.flip()
        h.flip()
        #expect(!h.engine.bilingualLine)
        #expect(h.hud == nil)
    }

    // MARK: Caps Lock (D9)

    @Test func capsLockPassesLettersRaw() {
        // ux-spec §9 #77: Caps Lock on, `asap␣` → ASAP␣ raw.
        let h = EngineHarness()
        let steps = KeyEvent.typing("asap ").map { e -> Step in
            var e = e
            e.modifiers.insert(.capsLock)
            return h.press(e)
        }
        #expect(steps.allSatisfy { !$0.consumed && $0.calls.isEmpty })
        #expect(h.text == "ASAP ")
        #expect(h.detector.prefixCalls.isEmpty)
    }

    @Test func capsLockOnCommitsTheWordInProgress() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        _ = h.client.take()
        h.engine.handleModifier(ModifierEvent(keyCode: 57, flags: FlipTapDetector.Flags.capsLock, timestamp: h.now),
                                client: h.client)
        #expect(h.client.take() == [.insert("안녕", nil), .selectedRange])
        #expect(!h.engine.isComposing)
    }

    @Test func capsLockAsTheFlipKeyFlipsAndLettersStillCompose() {
        var settings = DuoSettings()
        settings.flipKey = .capsLock
        let h = EngineHarness(settings: settings)
        EngineFlipTests.scriptGo(h.detector)
        for e in KeyEvent.typing("go") {
            var e = e
            e.modifiers.insert(.capsLock)
            h.press(e)
        }
        #expect(h.marked == "해")
        _ = h.client.take()
        h.engine.handleModifier(ModifierEvent(keyCode: 57, flags: 0, timestamp: h.now), client: h.client)
        #expect(h.marked == "go")
    }

    /// Every key with the Caps Lock lock on, as macOS reports it after an odd number of flips.
    static func typeWithCapsLock(_ text: String, _ h: EngineHarness) {
        for e in KeyEvent.typing(text) {
            var e = e
            e.modifiers.insert(.capsLock)
            h.press(e)
        }
    }

    static var capsLockFlipKey: DuoSettings {
        var settings = DuoSettings()
        settings.flipKey = .capsLock
        return settings
    }

    @Test func capsLockAsTheFlipKeyKeepsEagerEnglishTailsInTheirCase() {
        let h = EngineHarness(settings: Self.capsLockFlipKey)
        h.detector.english("Hello")
        Self.typeWithCapsLock("Hello ", h)
        #expect(h.text == "Hello ", "the app would type the tail as LO")
        // The document matches the word, so the last-word flip works (Caps Lock is the flip key).
        h.engine.handleModifier(ModifierEvent(keyCode: 57, flags: 0, timestamp: h.now), client: h.client)
        #expect(h.text == FakeDetector.hangul("Hello") + " ")
    }

    @Test func capsLockAsTheFlipKeyKeepsLiteralLettersInTheirCase() {
        let h = EngineHarness(settings: Self.capsLockFlipKey)
        Self.typeWithCapsLock("/help ", h)
        #expect(h.text == "/help ")
        let g = EngineHarness(settings: Self.capsLockFlipKey)
        g.detector.english("github")
        Self.typeWithCapsLock("github.com ", g)
        #expect(g.text == "github.com ")
    }

    @Test func capsLockAsTheFlipKeyKeepsDirectLettersInTheirCase() {
        var settings = Self.capsLockFlipKey
        settings.appProfiles["com.apple.TextEdit"] = .direct
        let h = EngineHarness(settings: settings)
        Self.typeWithCapsLock("ls -al", h)
        #expect(h.text == "ls -al")
    }

    @Test func capsLockAsTheFlipKeyLeavesLettersToTheAppWhileTheLockIsOff() {
        let h = EngineHarness(settings: Self.capsLockFlipKey)
        h.detector.english("hello")
        let steps = h.type("hello ")
        #expect(steps[3].calls.isEmpty && !steps[3].consumed, "the eager-E tail passes as usual")
        #expect(h.text == "hello ")
    }

    // MARK: Dead keys, ⌥, ⌘, ⌃

    @Test func deadKeyCommitsAndTheNextKeyPassesRaw() {
        // ux-spec §9 #78: ⌥e then e → é.
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        let dead = h.press(KeyEvent(.letter(Keystroke(base: "e", shift: false)), modifiers: .option, isDeadKey: true))
        #expect(!dead.consumed)
        #expect(dead.mutations == [.insert("안녕", nil)])
        let e = h.press(.letter("e"))
        #expect(!e.consumed, "the key after a dead key passes raw")
        #expect(e.calls.isEmpty)
        #expect(h.text == "안녕é")
        let next = h.press(.letter("d"))
        #expect(next.consumed, "only one key passes")
    }

    @Test func optionLetterCommitsAndPasses() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        let step = h.press(KeyEvent(.letter(Keystroke(base: "a", shift: false)), modifiers: .option), characters: "å")
        #expect(!step.consumed)
        #expect(step.mutations == [.insert("안녕", nil)])
        #expect(h.text == "안녕å")
    }

    @Test func commandShortcutCommitsThenPasses() {
        // ux-spec §9 #82: `go`, ⌘A → "go" committed, then select all.
        let h = EngineHarness()
        h.detector.english("hi")
        h.detector.scores["g"] = [.korean: -3500, .english: -3000]
        h.detector.scores["go"] = [.korean: -6000, .english: -3000]
        h.type("hi ")
        h.type("go")
        let step = h.press(.letter("a", .command))
        #expect(!step.consumed)
        #expect(step.mutations == [.insert("go", nil)])
        #expect(h.buffer.selection == NSRange(location: 0, length: 5))
    }

    @Test func controlShortcutCommitsThenPasses() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        let step = h.press(.letter("c", .control))
        #expect(!step.consumed)
        #expect(step.mutations == [.insert("안녕", nil)])
    }

    @Test func fnLetterIsASystemShortcut() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        let step = h.press(.letter("e", .function))
        #expect(!step.consumed)
        #expect(step.mutations == [.insert("안녕", nil)])
        let arrow = h.press(KeyEvent(.arrowLeft, modifiers: .function))
        #expect(!arrow.consumed)
    }

    @Test func emojiPickerShortcutCommitsFirst() {
        // ux-spec §9 #79: ⌃⌘Space after a word.
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        let step = h.press(KeyEvent(.space, modifiers: [.control, .command]))
        #expect(!step.consumed)
        #expect(step.mutations == [.insert("안녕", nil)])
    }

    @Test func globeKeyCommitsTheWord() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        _ = h.client.take()
        h.engine.handleModifier(ModifierEvent(keyCode: 63, flags: FlipTapDetector.Flags.function, timestamp: h.now),
                                client: h.client)
        #expect(h.client.take().first == .insert("안녕", nil))
    }

    @Test func otherModifiersAloneDoNothing() {
        let h = EngineHarness()
        h.detector.korean("dkssud")
        h.type("dkssud")
        _ = h.client.take()
        h.engine.handleModifier(ModifierEvent(keyCode: 56, flags: FlipTapDetector.Flags.shift | 0x02, timestamp: h.now),
                                client: h.client)
        h.engine.handleModifier(ModifierEvent(keyCode: 56, flags: 0, timestamp: h.now + 0.05), client: h.client)
        #expect(h.client.take().isEmpty, "a held ⇧ does not commit")
        #expect(h.marked == "안녕")
    }

    // MARK: Monaco editors (VS Code and its forks)

    @Test(arguments: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                      "com.vscodium", "com.exafunction.windsurf", "com.visualstudio.code.oss"])
    func monacoEditorsCannotReplaceCommittedText(_ id: String) {
        let p = ClientProfile.forBundleIdentifier(id)
        #expect(!p.canReplaceCommittedText)
        #expect(p.replacement == .full, "eager English stays on: IntelliSense needs real text")
    }

    @Test func committedTextIsReplaceableExceptInMonacoAndClientsWithoutReplacement() {
        #expect(ClientProfile.forBundleIdentifier("com.apple.TextEdit").canReplaceCommittedText)
        #expect(ClientProfile.forBundleIdentifier("com.apple.Terminal").canReplaceCommittedText)
        #expect(ClientProfile.forBundleIdentifier("com.apple.dt.Xcode").canReplaceCommittedText)
        #expect(!ClientProfile.forBundleIdentifier("com.googlecode.iterm2").canReplaceCommittedText)
        #expect(!ClientProfile.forBundleIdentifier("com.jetbrains.WebStorm").canReplaceCommittedText)
        #expect(!ClientProfile(bundleIdentifier: "x", replacement: .none).canReplaceCommittedText)
    }

    static func vsCode() -> EngineHarness {
        let h = EngineHarness(bundleIdentifier: "com.microsoft.VSCode")
        h.buffer.ignoresReplacementRanges = true
        return h
    }

    @Test func vsCodeFlipOfEagerEnglishShowsCannotChangeInsteadOfDuplicating() {
        let h = Self.vsCode()
        h.detector.english("hello")
        h.type("hello")
        #expect(h.text == "hello")
        #expect(h.engine.token?.committed == 5, "eager English still commits")
        let calls = h.flip()
        #expect(calls.filter(\.isMutation).isEmpty, "no re-open: VS Code would print helloㅗ디ㅣㅐ")
        #expect(h.text == "hello")
        #expect(h.hud == HUDRequest(content: .cannotChange, anchor: .caret, immediate: true, lifetime: 1.2))
        #expect(h.engine.token?.locked == nil)
        #expect(h.notifications.isEmpty)
        h.press(.space)
        #expect(h.text == "hello ")
    }

    @Test func vsCodeFlipOfAMarkedWordStillWorks() {
        let h = Self.vsCode()
        EngineFlipTests.scriptGo(h.detector)
        h.engine.settings.appProfiles["com.microsoft.VSCode"] = .automatic
        h.type("go")
        #expect(h.marked == "해")
        #expect(h.flip() == [.mark("go", nil)])
    }

    @Test func vsCodeLastWordFlipShowsCannotChangeAndLearnsNothing() {
        let h = Self.vsCode()
        h.detector.english("world")
        h.type("world ")
        let calls = h.flip()
        #expect(!calls.contains { if case .string = $0 { true } else { false } }, "refused before reading")
        #expect(calls.filter(\.isMutation).isEmpty)
        #expect(h.text == "world ")
        #expect(h.hud?.content == .cannotChange)
        #expect(h.store.count == 0)
        #expect(!h.notifications.contains(.learningChanged))
    }

    @Test func vsCodeCaretAwayFromTheWordStillArmsTheNextWord() {
        // Re-review R1: only a flip at the word is refused; away from it, it arms the next word.
        let h = Self.vsCode()
        h.detector.english("hello")
        h.type("hello, ")
        #expect(h.text == "hello, ")
        h.flip()
        #expect(h.engine.oneShot == .korean)
        #expect(h.hud?.content == .oneShot(.korean))
    }

    @Test func vsCodeCommentAfterCodeArmsTheNextWord() {
        let h = Self.vsCode()
        h.detector.english("foo")
        h.type("foo();")
        h.press(.returnKey)
        h.type("// ")
        h.flip()
        #expect(h.engine.oneShot != nil)
        #expect(h.hud?.content != .cannotChange)
    }

    @Test func vsCodeNeverOffersTheFlipLastWordChip() {
        var settings = DuoSettings()
        for id in ["com.microsoft.VSCode", "com.apple.TextEdit"] { settings.appProfiles[id] = .automatic }
        func uncertain(_ h: EngineHarness) {
            h.detector.scores["dk"] = [.korean: -2000, .english: -9000]
            h.detector.finals["dk"] = [.korean: -2000, .english: -2300]
            h.type("dk ")
            #expect(h.text == "아 ")
        }
        let control = EngineHarness(settings: settings)
        uncertain(control)
        #expect(control.hud?.content == .flipLastWord(bar("아", .korean, offering: "dk", .english, currentFirst: true)))

        let h = EngineHarness(settings: settings, bundleIdentifier: "com.microsoft.VSCode")
        h.buffer.ignoresReplacementRanges = true
        uncertain(h)
        #expect(h.hud == nil)
        h.press(.backspace)
        #expect(h.hud == nil, "nor when Backspace returns to the word")
    }

    // MARK: Java clients (R17)

    @Test func javaClientsKeepTheWholeTokenMarkedAndLeaveMarkBeforeInsertToTheAdapter() {
        let h = EngineHarness(bundleIdentifier: "com.jetbrains.WebStorm")
        h.detector.english("const")
        let steps = h.type("const")
        #expect(steps.allSatisfy { $0.consumed && $0.mutations.count == 1 }, "no eager E, no replacement (R17)")
        #expect(h.marked == "const")
        let step = h.press(.space)
        #expect(step.calls == [.insert("const", nil)], "one insert; the adapter adds the Java mark")
        #expect(h.engine.clientProfile.needsMarkBeforeInsert)
        #expect(h.text == "const ")
    }
}
