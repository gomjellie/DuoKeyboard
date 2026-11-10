import AppKit
import DuoCore
import DuoKit
import InputMethodKit

/// The Text Input menu (critique R13). IMK ignores submenus, so the per-app profile is a flat group
/// of four checkmarked items under a disabled header. Every action reaches the controller through
/// IMK with an info dictionary (`kIMKCommandMenuItemName`, `kIMKCommandClientName`) as the sender.
extension DuoInputController {
    nonisolated override func menu() -> NSMenu! {
        nonisolated(unsafe) var menu: NSMenu?
        onMain { menu = $0.buildMenu() }
        return menu
    }

    private func buildMenu() -> NSMenu {
        let settings = DuoRuntime.shared.settings
        let menu = NSMenu(title: "Duo")
        menu.autoenablesItems = false

        menu.addItem(item(String(localized: "Duo 설정…"), #selector(openSettings(_:))))
        menu.addItem(.separator())

        let hasApp = !bundleIdentifier.isEmpty
        let header = NSMenuItem(title: String(localized: "현재 앱: \(appDisplayName)"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let clientProfile = ClientProfile.forBundleIdentifier(bundleIdentifier)
        let current = clientProfile.effectiveProfile(settings)
        for (index, profile) in AppProfile.allCases.enumerated() {
            let entry = item(profile.menuTitle, #selector(selectAppProfile(_:)))
            entry.tag = index
            entry.state = hasApp && profile == current ? .on : .off
            entry.isEnabled = hasApp
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        let sendWithReturn = item(String(localized: "Enter로 바로 보내기"), #selector(toggleSendWithReturn(_:)))
        sendWithReturn.state = hasApp && clientProfile.usesInline(settings) ? .on : .off
        sendWithReturn.isEnabled = hasApp && clientProfile.supportsInline
        sendWithReturn.indentationLevel = 1
        menu.addItem(sendWithReturn)
        menu.addItem(.separator())

        menu.addItem(item(String(localized: "선택한 텍스트 한↔A 변환"), #selector(convertSelection(_:))))
        let hints = item(String(localized: "힌트 표시"), #selector(toggleHints(_:)))
        hints.state = settings.showHints ? .on : .off
        menu.addItem(hints)
        let always = item(String(localized: "후보 늘 보기"), #selector(toggleAlwaysShowChoices(_:)))
        always.state = settings.alwaysShowChoices ? .on : .off
        always.isEnabled = settings.showHints
        always.indentationLevel = 1
        menu.addItem(always)
        let pause = item(String(localized: "학습 일시 정지"), #selector(togglePauseLearning(_:)))
        pause.state = settings.learningPaused ? .on : .off
        pause.isEnabled = settings.learningEnabled
        menu.addItem(pause)
        menu.addItem(.separator())

        menu.addItem(item(String(localized: "Duo 도움말"), #selector(openHelp(_:))))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.isEnabled = true
        return item
    }

    /// The client app's display name (Finder name without `.app`), or its bundle id.
    private var appDisplayName: String {
        guard !bundleIdentifier.isEmpty else { return String(localized: "알 수 없음") }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // MARK: Actions (IMK sends them on the main thread with an info dictionary)

    @objc nonisolated func openSettings(_ sender: Any?) {
        // Duo.app opens Settings for this request even before onboarding is finished (review host-7).
        onMain { _ in
            Log.menu.info("opening the host app's settings")
            HostRequest.showSettings()
        }
    }

    @objc nonisolated func openHelp(_ sender: Any?) {
        // Duo.app shows its setup guide for this request (launch argument or, when it already runs,
        // a distributed notification); see DuoKit `HostRequest`.
        onMain { _ in
            Log.menu.info("opening the host app's guide")
            HostRequest.showGuide()
        }
    }

    @objc nonisolated func selectAppProfile(_ sender: Any?) {
        let tag = MenuSender.item(sender)?.tag ?? -1
        nonisolated(unsafe) let client = MenuSender.client(sender)
        onMain { $0.setAppProfile(tag: tag, clientHint: client) }
    }

    @objc nonisolated func toggleSendWithReturn(_ sender: Any?) {
        nonisolated(unsafe) let client = MenuSender.client(sender)
        onMain { $0.switchSendWithReturn(clientHint: client) }
    }

    @objc nonisolated func toggleHints(_ sender: Any?) {
        onMain { _ in
            DuoRuntime.shared.updateSettings { $0.showHints.toggle() }
            Log.menu.info("hints \(DuoRuntime.shared.settings.showHints ? "on" : "off", privacy: .public)")
        }
    }

    @objc nonisolated func toggleAlwaysShowChoices(_ sender: Any?) {
        onMain { _ in
            DuoRuntime.shared.updateSettings { $0.alwaysShowChoices.toggle() }
            let on = DuoRuntime.shared.settings.alwaysShowChoices
            Log.menu.info("always show choices \(on ? "on" : "off", privacy: .public)")
        }
    }

    @objc nonisolated func togglePauseLearning(_ sender: Any?) {
        onMain { _ in
            DuoRuntime.shared.updateSettings { $0.learningPaused.toggle() }
            Log.menu.info("learning paused=\(DuoRuntime.shared.settings.learningPaused, privacy: .public)")
        }
    }

    @objc nonisolated func convertSelection(_ sender: Any?) {
        nonisolated(unsafe) let client = MenuSender.client(sender)
        onMain { $0.convertSelection(in: client) }
    }

    private func setAppProfile(tag: Int, clientHint: (any IMKTextInput & NSObjectProtocol)?) {
        guard !bundleIdentifier.isEmpty, AppProfile.allCases.indices.contains(tag) else { return }
        // Commit the word being typed under the old profile first: choosing the menu item moves no
        // focus and clicks nothing in the client, so nothing else ends the composition, and a
        // Direct profile would otherwise let the next key replace the marked word.
        if let proxy = clientHint ?? client() {
            withEngineClient(proxy) { engine, client in
                if engine.isComposing { engine.commit(.commitComposition, client: client) }
            }
        }
        DuoRuntime.shared.hud.forceHide()
        let profile = AppProfile.allCases[tag]
        let bundleID = bundleIdentifier
        DuoRuntime.shared.updateSettings { $0.appProfiles[bundleID] = profile }
        Log.menu.info("profile for \(bundleID, privacy: .public) = \(profile.rawValue, privacy: .public)")
    }

    /// "Enter로 바로 보내기" for the current app (SPEC.md 4.10절): `settings.inlineApps`.
    private func switchSendWithReturn(clientHint: (any IMKTextInput & NSObjectProtocol)?) {
        guard !bundleIdentifier.isEmpty, ClientProfile.forBundleIdentifier(bundleIdentifier).supportsInline else { return }
        // As for a profile: the word being typed ends first, so the next word starts in the new mode.
        if let proxy = clientHint ?? client() {
            withEngineClient(proxy) { engine, client in
                if engine.isComposing { engine.commit(.commitComposition, client: client) }
            }
        }
        DuoRuntime.shared.hud.forceHide()
        let bundleID = bundleIdentifier
        DuoRuntime.shared.updateSettings { settings in
            if settings.inlineApps.remove(bundleID) == nil { settings.inlineApps.insert(bundleID) }
        }
        let on = DuoRuntime.shared.settings.inlineApps.contains(bundleID)
        Log.menu.info("send with Return for \(bundleID, privacy: .public) \(on ? "on" : "off", privacy: .public)")
    }

    /// "선택한 텍스트 한↔A 변환" (ux-spec §5.2): converts the selection with `SelectionConverter` and
    /// replaces it in one `insertText` with a verified replacement range.
    private func convertSelection(in clientHint: (any IMKTextInput & NSObjectProtocol)?) {
        guard let proxy = clientHint ?? client() else { return }
        let replacement = ClientProfile.forBundleIdentifier(bundleIdentifier).replacement
        // Check before committing anything: while a word is marked the selection is the caret inside
        // it, so there is usually nothing to convert, and the composition must then stay as it is.
        guard var range = usableSelection(proxy, replacement: replacement) else { return }
        // Finish any composition first, so the selection is real committed text.
        var composed = false
        withEngineClient(proxy) { engine, client in
            composed = engine.isComposing
            if composed { engine.commit(.commitComposition, client: client) }
        }
        if composed {
            guard let committed = usableSelection(proxy, replacement: replacement) else { return }
            range = committed
        }
        guard let text = proxy.attributedSubstring(from: range)?.string, (text as NSString).length == range.length else {
            return cannotConvert("client did not return the selected text")
        }
        let converted = SelectionConverter.convert(text)
        guard converted != text else {
            Log.menu.info("selection conversion: nothing to convert")
            return
        }
        proxy.insertText(converted as NSString, replacementRange: range)
        Log.menu.info("converted a selection of \(range.length, privacy: .public) units")
    }

    /// The selection to convert, or `nil` after telling the user why there is none: the standard
    /// beep when nothing is selected (or too much), the HUD message when the app cannot replace text.
    private func usableSelection(_ proxy: any IMKTextInput & NSObjectProtocol,
                                 replacement: ReplacementSupport) -> NSRange? {
        switch SelectionConversionCheck.check(replacement: replacement, selection: proxy.selectedRange()) {
        case .convert(let range):
            return range
        case .nothingToConvert:
            Log.menu.info("selection conversion: no usable selection")
            NSSound.beep()
            return nil
        case .cannotChange:
            cannotConvert("client cannot replace text")
            return nil
        }
    }

    /// The client cannot replace text, or did not return the selected text: "여기서는 바꿀 수 없어요"
    /// on screen and, with VoiceOver, spoken.
    private func cannotConvert(_ reason: String) {
        Log.menu.info("selection conversion unavailable: \(reason, privacy: .public)")
        let request = HUDRequest(content: .cannotChange, anchor: .caret, immediate: true, lifetime: 1.2)
        DuoRuntime.shared.hud.present(request, from: self, trigger: .feedback)
        VoiceOverAnnouncer.announce(.cannotChange)
    }
}

/// Unpacks IMK's menu-action sender (an info dictionary; a bare `NSMenuItem` from older paths).
private enum MenuSender {
    static func item(_ sender: Any?) -> NSMenuItem? {
        if let item = sender as? NSMenuItem { return item }
        return (sender as? [AnyHashable: Any])?[kIMKCommandMenuItemName] as? NSMenuItem
    }

    static func client(_ sender: Any?) -> (any IMKTextInput & NSObjectProtocol)? {
        (sender as? [AnyHashable: Any])?[kIMKCommandClientName] as? (any IMKTextInput & NSObjectProtocol)
    }
}

private extension AppProfile {
    /// R13 menu labels.
    var menuTitle: String {
        switch self {
        case .automatic: String(localized: "자동")
        case .koreanFirst: String(localized: "한국어 우선")
        case .englishFirst: String(localized: "English 우선")
        case .direct: String(localized: "직접 입력")
        }
    }
}
