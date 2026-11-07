# InputMethodKit and Text Input Sources: platform research for Duo

Track: IMK and TIS platform research. Target: macOS 26.6.2 (Tahoe) on arm64, Xcode 27.2, Swift 6.4.2, SDK `MacOSX27.2.sdk`.
Date: 2026-11-07.

Every claim carries one of these labels:
- **[SDK]**: read from a header in `MacOSX27.2.sdk`.
- **[RUNTIME]**: observed on this machine (macOS 26.6.2) by running code.
- **[VERIFIED]**: compiled or run by me on this machine.
- **[REF]**: taken from an open-source IME or a public issue, with a link.
- **[INFERRED]**: my reasoning, not verified.

---

## 0. Decisions in brief

| # | Decision | Why |
|---|---|---|
| D1 | Ship as a classic **IMK app bundle** in `~/Library/Input Methods/`. | Apple's own IMs moved to private app extensions (`NSExtensionPointIdentifier = com.apple.textinputmethod-services`, `IMKExtension*` classes). That path has no public headers, so third parties must use the app form. [RUNTIME][SDK] |
| D2 | Declare **one input mode**, following Apple's single-mode AinuIM. Parent ID `com.inkyuoh.inputmethod.Duo`, mode ID `com.inkyuoh.inputmethod.Duo.Bilingual`. Decide this **now**. | A mode gives per-mode `TISIconLabels`, a script, and a name. Changing the selectable ID later forces every user to re-add the input source. See §2.4. |
| D3 | Name the controller class `@objc(DuoInputController)` and declare it `@MainActor`. Give **every** IMK override `nonisolated`, then hop to the main actor with `MainActor.assumeIsolated` (the macSKK pattern). | This is the only pattern that compiled cleanly in Swift 6 mode under both `SWIFT_DEFAULT_ACTOR_ISOLATION` settings. [VERIFIED] See §4.9. |
| D4 | Handle input with `handle(_:client:)` and `recognizedEvents = [.keyDown, .flagsChanged, .leftMouseDown]`. Commit on mouse down yourself. | Once you return anything other than `.keyDown`, IMK's built-in commit-on-click is disabled. [SDK] |
| D5 | Set marked text **synchronously** inside `handle()` before returning `true`. Never set it from an async hop. | iTerm2 decides whether the IME used a key by looking for marked text right after `handle` returns. A late update produces a doubled first character. [REF azooKey #357] |
| D6 | Implement the "flip committed word" feature with `setMarkedText(_:selectionRange:replacementRange:)` or `insertText(_:replacementRange:)` on a **verified** range. Check `attributedSubstring(from:)` first. Gate it by client policy: full, before-caret-only (Terminal), or unsupported (iTerm2, Hyper, Java/JetBrains). | This is the macSKK "確定アンドゥ" (commit undo) algorithm, and it works in Cocoa, WebKit and Chromium. [REF] See §5. |
| D7 | Watch `kTISNotifySelectedKeyboardInputSourceChanged` and commit and hide the UI when the selected source is no longer Duo. | On macOS 26, a `TISSelectInputSource` from another process does **not** call `deactivateServer`. [REF squirrel #1140/#1142] |
| D8 | Sign **ad-hoc** (`CODE_SIGN_IDENTITY = "-"`) for local work. No sandbox in v1. Set `ENABLE_DEBUG_DYLIB = NO` on the IME target. | The only identity in the keychain, "Apple Development: Inkyu Oh (4MRK2Z3J94)", reports **`CSSMERR_TP_CERT_REVOKED`**. Its real Team ID (OU) is **`DKZ2M6YKUP`**, not 4MRK2Z3J94. The ad-hoc build that is installed now registers, enables and runs. [RUNTIME] |
| D9 | For TCC-free end-to-end tests, send `NSEvent(cgEvent: CGEvent(keyboardEventSource:virtualKey:keyDown:))` to `window.sendEvent(_:)` in an **active** host app launched with `open`. `NSEvent.keyEvent(...)` events **do not** reach the IME. | Verified with Apple's 2-Set Korean: it produced "한글". [VERIFIED] See §7. |
| D10 | Put Settings UI in a **separate regular app** that the IME launches through `NSWorkspace`. The IME bundle stays `LSUIElement`. | A background or agent IME can't activate reliably under macOS 14+ cooperative activation. [INFERRED from macSKK code and Apple KoreanIM's container layout] |

---

## 1. What the SDK actually contains (MacOSX27.2.sdk)

### 1.1 Headers

- `InputMethodKit.framework/Headers/` holds `InputMethodKit.h`, `IMKServer.h`, `IMKInputController.h` and `IMKCandidates.h`. The module map is `framework module InputMethodKit [extern_c] { umbrella header ... }`. [SDK]
  - The headers still say "Copyright (c) 2006". The newest availability macro is `AVAILABLE_MAC_OS_X_VERSION_10_7_AND_LATER`. There are **no nullability annotations, no `NS_SWIFT_UI_ACTOR`/`@MainActor`, and no `Sendable` annotations**. **Nothing in IMK is new or deprecated since 10.7.**
- `IMKTextInput` is **not** in IMK. It lives in `Carbon.framework/.../HIToolbox.framework/Headers/IMKInputSession.h`, together with `IMKUnicodeTextInput`, `IMKLocationToOffsetMappingMode` (`kIMKMouseTrackingMode = 1<<0`, `kIMKNearestBoundaryMode = 1<<1`) and `IMKTextOrientationName`. [SDK]
- `HIToolbox/TextInputSources.h` (2006–2008) has the full TIS API, all available since 10.5. The one newer addition is a note on `kTISPropertyIconImageURL`. TIS uses `-[NSBundle imageForResource:]`, so a wrong path extension in the plist (for example `.png` when the file is `.tiff`) still resolves. Apple's KoreanIM relies on this: its plist says `2SetKorean.png` but ships `2SetKorean.tiff`. [SDK][RUNTIME]
- `HIToolbox/TextServices.h` defines the `ts*` plist keys as `CFSTR` macros, the TSM document property tags (`kTSMDocumentInputSourceOverridePropertyTag = 'inis'`, `kTSMDocumentEnabledInputSourcesPropertyTag = 'enis'`, `kTSMDocumentSupportDocumentAccessPropertyTag = 'dapy'`) and `kTextServiceInputModePropertyTag`. [SDK]
- `AE.framework/.../AERegistry.h` defines `kTSMHiliteCaretPosition=1`, `RawText=2`, `SelectedRawText=3`, `ConvertedText=4`, `SelectedConvertedText=5`, `BlockFillText=6`, `OutlineText=7`, `SelectedText=8` and `NoHilite=9`. [SDK]
- AppKit's `NSTextInputClient.h` gained `NSTextCursorAccessoryPlacement`, `unionRectInVisibleSelectedRange` and `documentVisibleRect` (macOS 14), plus `supportsAdaptiveImageGlyph` and `insertAdaptiveImageGlyph(_:replacementRange:)` (macOS 15). `NSTextInputContext.h` gained `textInputClientWillStartScrollingOrZooming` and `…DidEndScrollingOrZooming` (14.0), plus `textInputClientDidUpdateSelection` and `textInputClientDidScroll` (15.4). These are client-side APIs and matter only for our host or test app. [SDK]
- `NSGlassEffectView` and `NSGlassEffectContainerView` arrived in macOS 26.0, with `style`, `cornerRadius`, `tintColor` and `contentView`. **`effectIsInteractive` is `API_AVAILABLE(macos(27.0))`**. The SDK is macOS 27 but the user runs 26.6, so every 27-only API needs `if #available(macOS 27, *)`. [SDK]

### 1.2 Swift import surface (from `swift-synthesize-interface`) [VERIFIED]

```swift
open class IMKServer : NSObject {
  public init!(name: String!, bundleIdentifier: String!)
  public init!(name: String!, controllerClass: AnyClass!, delegateClass: AnyClass!)
  open func bundle() -> Bundle!
  open func paletteWillTerminate() -> Bool          // 10.7
  open func lastKeyEventWasDeadKey() -> Bool        // 10.7
}
open class IMKInputController : NSObject, IMKStateSetting, IMKMouseHandling {
  public init!(server: IMKServer!, delegate: Any!, client inputClient: Any!)
  open func updateComposition()
  open func cancelComposition()
  open func compositionAttributes(at range: NSRange) -> NSMutableDictionary!
  open func selectionRange() -> NSRange          // runtime default {0,0} (header claims "end of marked text")
  open func replacementRange() -> NSRange        // default {NSNotFound, NSNotFound}
  open func mark(forStyle style: Int, at range: NSRange) -> [AnyHashable : Any]!
  open func doCommand(by aSelector: Selector!, command infoDictionary: [AnyHashable : Any]!)
  open func hidePalettes()
  open func menu() -> NSMenu!
  open func delegate() -> Any!;  open func setDelegate(_:)
  open func server() -> IMKServer!
  open func client() -> (any IMKTextInput & NSObjectProtocol)!
  open func inputControllerWillClose()           // 10.7
  open func annotationSelected(_:forCandidate:); candidateSelectionChanged(_:); candidateSelected(_:)
}
// IMKStateSetting (implemented by IMKInputController, override these):
func activateServer(_ sender: Any!); func deactivateServer(_ sender: Any!)
func value(forTag tag: Int, client sender: Any!) -> Any!
func setValue(_ value: Any!, forTag tag: Int, client sender: Any!)
func modes(_ sender: Any!) -> [AnyHashable : Any]!
func recognizedEvents(_ sender: Any!) -> Int     // default = NSEvent.EventTypeMask.keyDown (1024) [RUNTIME]
func showPreferences(_ sender: Any!)
// IMKMouseHandling:
func mouseDown(onCharacterIndex:coordinate:withModifier:continueTracking:client:) -> Bool
func mouseUp(onCharacterIndex:coordinate:withModifier:client:) -> Bool
func mouseMoved(onCharacterIndex:coordinate:withModifier:client:) -> Bool
// Informal IMKServerInput (declared as `extension NSObject`, override in subclass):
func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool
func inputText(_ string: String!, client sender: Any!) -> Bool
func handle(_ event: NSEvent!, client sender: Any!) -> Bool
func didCommand(by aSelector: Selector!, client sender: Any!) -> Bool
func composedString(_ sender: Any!) -> Any!
func originalString(_ sender: Any!) -> NSAttributedString!
func commitComposition(_ sender: Any!)
func candidates(_ sender: Any!) -> [Any]!
// IMKTextInput (client proxy; all methods required):
func insertText(_ string: Any!, replacementRange: NSRange)
func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange)
func selectedRange() -> NSRange; func markedRange() -> NSRange
func attributedSubstring(from range: NSRange) -> NSAttributedString!
func length() -> Int
func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int
func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable : Any]!
func validAttributesForMarkedText() -> [Any]!
func overrideKeyboard(withKeyboardNamed: String!); func selectMode(_ modeIdentifier: String!)
func supportsUnicode() -> Bool; func bundleIdentifier() -> String!; func windowLevel() -> CGWindowLevel
func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool
func uniqueClientIdentifierString() -> String!                         // 10.7
func string(from range: NSRange, actualRange: NSRangePointer!) -> String!  // 10.7
func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect // 10.7
```

The two `selectionRange()` sources disagree. At runtime a fresh controller's default returns `{0,0}`, while the header says the default puts the selection "at the end of the marked text". Don't rely on either. Pass an explicit `selectionRange` when you call `client.setMarkedText` yourself. [RUNTIME]

At runtime `mark(forStyle:at:)` returns these attributes. Style 2 (raw text) carries no underline, so the client uses its default look: [RUNTIME]
- 2 → `NSMarkedClauseSegment=1`
- 3 → `NSUnderline=3` (thick) plus a dark-gray underline color
- 4 → `NSUnderline=1`
- 5 → `NSUnderline=2` (thick or double)
- 8 and 9 → clause attribute only

### 1.3 Private runtime surface on macOS 26.6.2 (do not depend on it; probe with `responds(to:)` only) [RUNTIME]

- The IMK image contains `_IMKServerLegacy` and `_IMKServerModern`, plus `_IPMDServerClientWrapperLegacy` and `_IPMDServerClientWrapperModern`. The framework picks the variant at runtime. The modern variant uses NSXPC and checks in with `imklaunchagent` (`registerIMKXPCEndpointWithLaunchAgent`).
- The `sender`/client object is `_IPMDServerClientWrapperModern`. It answers several private selectors:
  - `isSecureMode`
  - `isIncrementalSearchInputContext`: detects search fields.
  - `isBottomLineInputContext`
  - `isTextPlaceholderAwareInputContext`
  - `processIdentifier`
  - `markedCharacterCount`
  - `windowEffectiveAppearance` and `viewEffectiveAppearance`: pick light or dark for the panel.
  - `replyTimeout` and `setReplyTimeout:`: DKST sets 100 ms so a hung client can't freeze the IME.
  - `supportsChromaticMarkedText`
  - `keyboardType`
  - `isAutomaticSpellingCorrectionEnabled_WithAvailability:` and its siblings.
- `IMKInputController` also has private `leftContextWithLength:`, `rightContextWithLength:`, `contextWithDelta:` and `invalidateClientGeometry`.
- Private test classes `IMKSimulatorApplication`, `IMKSimulatorController`, `IMKSimulatorInputClient` and `IMKSimulatorTextView` exist, along with `IMKUIGlassView`, which Apple's own candidate UI uses for Liquid Glass.
- Apple's Korean IM reportedly asks a private `textDocument` proxy for `showsComposingTextAsMarkedText` to choose between direct and marked composition. [REF DKST `InputController+ClientPolicy.m`] That selector is **not** on `IMKInputController` here, so we can't use it.

---

## 2. Info.plist

### 2.1 Key reference

| Key | Level | Type | Meaning / notes |
|---|---|---|---|
| `CFBundleIdentifier` | top | string | Must contain **`.inputmethod.`**. This is a convention every IME follows; TIS uses it to classify the bundle. Our ID is `com.inkyuoh.inputmethod.Duo`. [REF tutorials; all reference IMEs] |
| `CFBundlePackageType` | top | `APPL` | The IM is an application. |
| `CFBundleName` / `CFBundleDisplayName` | top | string | **This is the input source name** for a mode-less IM. TIS shows the installed Duo as "DuoInputMethod" because `CFBundleName` = PRODUCT_NAME. Localize it in `InfoPlist.strings`. [RUNTIME] |
| `NSPrincipalClass` | top | `NSApplication` | Every IME uses this. A subclass also works, e.g. azooKey's `$(PRODUCT_MODULE_NAME).NSManualApplication`. |
| `LSUIElement` | top | bool | **Use this.** Apple sets KoreanIM, TCIM, SCIM, AinuIM and TamilIM to `LSUIElement=1`. It allows UI windows and activation. |
| `LSBackgroundOnly` | top | bool | Avoid it. A background-only app is `.prohibited` from activation. Only Apple's palette IM "Assistive Control" uses it. The current Duo build sets `LSBackgroundOnly=true`; **remove it**. Fire and azooKey set both keys, Squirrel sets `LSBackgroundOnly=false`. |
| `LSMinimumSystemVersion` | top | string | `26.0` |
| `NSSupportsSuddenTermination` | top | bool | Apple KoreanIM uses `false`, AinuIM uses `true`. Use `false` so a learning store can flush on exit. |
| `InputMethodConnectionName` | top | string | Name of the Mach/XPC service; it must be unique. Apple's old sample says "periods and spaces are not allowed". Modern Apple IMs ignore that rule: Ainu uses `com.apple.inputmethod.Ainu.IMK_Connection`, macSKK uses `net.mtgto.inputmethod.macSKK_Connection`. Use `$(PRODUCT_BUNDLE_IDENTIFIER)_Connection`. Pass the **same string** to `IMKServer(name:)`. |
| `InputMethodServerControllerClass` | top | string | Runtime name of the controller class, resolved with `NSClassFromString`. Either use `@objc(DuoInputController)` and write `DuoInputController`, or write `$(PRODUCT_MODULE_NAME).DuoInputController` (Squirrel, azooKey, Fire). |
| `InputMethodServerDelegateClass` | top | string | Optional; AinuIM leaves it out. Most IMEs set it to the controller class. IMK constants: `IMKControllerClass`, `IMKDelegateClass`, `IMKModeDictionary`. |
| `InputMethodServerPreferencesWindowControllerClass` | top | string | Used only by the default `showPreferences(_:)`, which loads `preferences.nib`. We don't need it. [SDK] |
| `InputMethodType` | top | string | Only `palette` exists. Leave it out for a keyboard IM. [RUNTIME: CharacterPalette, DictationIM, PressAndHold…] |
| `ComponentInvisibleInSystemUI` | top | bool | Palettes only. The header says "Keyboard input methods are always visible". [SDK] |
| `TISInputSourceID` | top / mode | string | Top level: defaults to the bundle ID. Mode level: **must be the parent ID plus a suffix**. Fire found its mode missing from the Add list when the mode ID equalled the bundle ID. [SDK][REF Fire dev-log 2026-09-23] |
| `TISIntendedLanguage` | top / mode | BCP-47 | `ko`. This places Duo under 한국어 in the Add sheet. [SDK] |
| `tsInputMethodCharacterRepertoireKey` | top | [ISO 15924] | `["Hang","Latn"]`. Apple Korean has `["Hang"]`, Gureum `["Latn","Kore","Hang"]`, macSKK `["Hira","Kana","Latn"]`. |
| `tsInputMethodIconFileKey` | top | file in Resources | The IM icon, also used by any mode that has no icon of its own. [SDK] |
| `tsInputMethodAlternateIconFileKey` | top | file | Optional highlighted variant. [SDK] |
| `TISIconIsTemplate` | top / mode | bool | `true` makes the system tint the icon for the menu bar, light/dark and highlight. Apple sets it on 11 IMs. Undocumented. [RUNTIME] |
| `TICapsLockLanguageSwitchCapable` | top / mode | bool | If `true` and the user has turned on "Use Caps Lock to switch to and from ABC", the system takes over Caps Lock to toggle Duo ⇄ ABC. Apple Korean sets `true`. **For Duo, start with `false`**: we never want a switch, and it keeps Caps Lock free as a possible flip key. Decide this in UX. |
| `TISParticipatesInTouchBar` | top | bool | Only Apple's Chinese IMs use it, and the Touch Bar is obsolete. Leave it out. |
| `TISUnifiedUIForInputMethodEnabling` | top | bool | Used only by Apple's Chinese and Japanese IMs, private. Leave it out. |
| `TISDoubleSpaceSubstitution` | mode | string | `". "` in Apple Korean. This turns on the system's "double-space inserts period" for the mode. Include it if UX wants it. [RUNTIME] |
| `TISIconLabels` | mode | dict | **Undocumented.** `{Primary: "한"}` appears in Apple Korean, `{Primary: "倉頡"}` in TCIM, and `{CustomIcon: "Ainu@2x.pdf"}` in Ainu. It labels the icon in the macOS 14+ input-source indicator and menu. Third-party support is **unverified**; we have no Screen Recording to check. Ship it alongside a real icon. [RUNTIME] |
| `ComponentInputModeDict` | top | dict | Holds `tsInputModeListKey` (modeID → dict) and `tsVisibleInputModeOrderedArrayKey` (array). The header says it "must also be present in the component bundle's Info.plist". [SDK] |
| `tsInputModeScriptKey` | mode | string | `smKorean`, or `smUnicodeScript` as Squirrel, Fire and Ainu use. Use `smKorean`. |
| `tsInputModePrimaryInScriptKey` | mode | bool | `true`. |
| `tsInputModeIsVisibleKey` | mode | bool | `true`. |
| `tsInputModeDefaultStateKey` | mode | bool | `true`: the mode is enabled when its parent is enabled. |
| `tsInputModeMenuIconFileKey` / `…AlternateMenuIconFileKey` / `…PaletteIconFileKey` | mode | file | Menu-bar icon, highlighted icon, and palette icon. |
| `tsInputModeCharacterRepertoireKey` | mode | array | `["Hang","Latn"]`. |
| `tsInputModeKeyEquivalentKey` / `…ModifiersKey` | mode | string / int | Optional switching shortcut; TCIM uses `4608` = ⌃⌥ (`controlKey`, `optionKey`). Leave it out. |
| `tsInputModeJISKeyboardShortcutKey` | mode | int | JIS 英数 and かな keys only. Leave it out. |

### 2.2 Recommended Info.plist (IME target)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleIdentifier</key><string>com.inkyuoh.inputmethod.Duo</string>
  <key>CFBundleName</key><string>Duo</string>
  <key>CFBundleDisplayName</key><string>Duo</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(MARKETING_VERSION)</string>
  <key>CFBundleVersion</key><string>$(CURRENT_PROJECT_VERSION)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsSuddenTermination</key><false/>

  <key>InputMethodConnectionName</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)_Connection</string>
  <key>InputMethodServerControllerClass</key><string>DuoInputController</string>
  <key>InputMethodServerDelegateClass</key><string>DuoInputController</string>

  <key>TISInputSourceID</key><string>com.inkyuoh.inputmethod.Duo</string>
  <key>TISIntendedLanguage</key><string>ko</string>
  <key>TISIconIsTemplate</key><true/>
  <key>TICapsLockLanguageSwitchCapable</key><false/>
  <key>tsInputMethodCharacterRepertoireKey</key>
  <array><string>Hang</string><string>Latn</string></array>
  <key>tsInputMethodIconFileKey</key><string>DuoMenuIcon.tiff</string>

  <key>ComponentInputModeDict</key>
  <dict>
    <key>tsInputModeListKey</key>
    <dict>
      <key>com.inkyuoh.inputmethod.Duo.Bilingual</key>
      <dict>
        <key>TISInputSourceID</key><string>com.inkyuoh.inputmethod.Duo.Bilingual</string>
        <key>TISIntendedLanguage</key><string>ko</string>
        <key>TISIconIsTemplate</key><true/>
        <key>TISIconLabels</key><dict><key>Primary</key><string>가A</string></dict>
        <key>TISDoubleSpaceSubstitution</key><string>. </string>
        <key>tsInputModeScriptKey</key><string>smKorean</string>
        <key>tsInputModePrimaryInScriptKey</key><true/>
        <key>tsInputModeIsVisibleKey</key><true/>
        <key>tsInputModeDefaultStateKey</key><true/>
        <key>tsInputModeCharacterRepertoireKey</key>
        <array><string>Hang</string><string>Latn</string></array>
        <key>tsInputModeMenuIconFileKey</key><string>DuoMenuIcon.tiff</string>
        <key>tsInputModeAlternateMenuIconFileKey</key><string>DuoMenuIcon.tiff</string>
        <key>tsInputModePaletteIconFileKey</key><string>DuoMenuIcon.tiff</string>
      </dict>
    </dict>
    <key>tsVisibleInputModeOrderedArrayKey</key>
    <array><string>com.inkyuoh.inputmethod.Duo.Bilingual</string></array>
  </dict>
</dict>
</plist>
```

For a mode-less build, drop `ComponentInputModeDict`. The input source ID is then the bundle ID, and its type is `TISTypeKeyboardInputMethodWithoutModes`, which is what is installed today. [RUNTIME]

`ko.lproj/InfoPlist.strings` / `en.lproj/InfoPlist.strings`:

```
"CFBundleName" = "Duo";
"CFBundleDisplayName" = "Duo";
"com.inkyuoh.inputmethod.Duo.Bilingual" = "Duo 한·영";    /* en: "Duo – Korean & English" */
```

Apple keys mode names by the **mode ID** in `InfoPlist.strings`, for example `"com.apple.inputmethod.Korean.2SetKorean" = "두벌식"`. The IM name comes from `CFBundleName` ("한국어"). [RUNTIME: KIM_Extension InfoPlist.loctable]

### 2.3 Menu-bar icon

- Apple's format is a **multi-representation TIFF**: 16×16 px at 72 dpi plus 32×32 px at 144 dpi in one file (`2SetKorean.tiff`, `Ainu.tiff`). Measured with `tiffutil -info`. [RUNTIME]
- Build it from PNGs: `tiffutil -cathidpicheck DuoMenuIcon.png DuoMenuIcon@2x.png -out DuoMenuIcon.tiff`.
- A PDF also works. Squirrel and Fire use `rime.pdf`/`fire.pdf` in `tsInputModeMenuIconFileKey`; Ainu points `TISIconLabels.CustomIcon` at `Ainu@2x.pdf`.
- Draw a pure-black glyph on transparent pixels and set `TISIconIsTemplate=true`. The system then handles light, dark and highlighted states.
- Keep the glyph within about 16×16 pt with roughly 1 pt of padding. Apple's newer labels are text inside a rounded rectangle, which is what `TISIconLabels.Primary` renders.
- `kTISPropertyIconImageURL` currently reports `MenuIcon.tiff` for the installed Duo. [RUNTIME]
- The name appears in the menu-bar drop-down and in System Settings → Keyboard → Text Input → Input Sources. That name is `CFBundleName` for a mode-less IM, or the mode-ID string from `InfoPlist.strings`.
- macOS 14+ also shows a small input-source indicator bubble at the caret on focus and on switching. It uses the icon or label. Users can turn it off with `defaults write kCFPreferencesAnyApplication TSMLanguageIndicatorEnabled 0`. Keep this in mind if Duo draws its own caret HUD. [REF]

### 2.4 One mode or none?

- **With a mode**, following Apple's single-mode Ainu, Squirrel, macSKK and Gureum:
  - You get a mode-level `TISIconLabels`, `tsInputModeScriptKey`, a localized mode name, and room for future modes such as "Korean only".
  - The parent `com.inkyuoh.inputmethod.Duo` becomes `TISTypeKeyboardInputMethodModeEnabled`. It is not select-capable; only the mode is.
  - Installers must enable the parent, then the mode, then select the mode.
- **Without a mode**: simpler, and already working. The selectable ID is the bundle ID.
- Switching later is a breaking change, because users must re-add the source.
- **Recommendation:** one mode now (D2).

---

## 3. Install, register, enable, reload, sign

### 3.1 Location and registration

- Per user: `~/Library/Input Methods/Duo.app` (no root). System-wide: `/Library/Input Methods/`.
- `TISRegisterInputSource(CFURL)` "can only be used to register" bundles in those two directories. Register the **final installed path**, not the build products path. [SDK]
- What happens on this machine now:
  - `~/Library/Input Methods/DuoInputMethod.app` is a real directory, ad-hoc signed.
  - TIS lists `com.inkyuoh.inputmethod.Duo` as `InputMethodWithoutModes` and enabled.
  - `com.apple.HIToolbox AppleEnabledInputSources` contains `{ "Bundle ID" = "com.inkyuoh.inputmethod.Duo"; InputSourceKind = "Keyboard Input Method"; }`.
  - The process `~/Library/Input Methods/DuoInputMethod.app/Contents/MacOS/DuoInputMethod` is running.
  - So no logout was needed for registration, enabling or running. [RUNTIME]
- Symlinks also work. Amazon Q installs `~/Library/Input Methods/CodeWhispererInputMethod.app` as a symlink, though the target is now missing.

### 3.2 Enable and select (Swift 6, verified to compile and run under `-default-isolation MainActor`)

```swift
import Carbon
enum InputSources {
  static func property<T>(_ s: TISInputSource, _ key: CFString) -> T? {
    guard let raw = TISGetInputSourceProperty(s, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
  }
  static func sources(id: String, includeAllInstalled: Bool = true) -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() else { return [] }
    return (list as NSArray).map { $0 as! TISInputSource }
  }
  static func isEnabled(_ s: TISInputSource) -> Bool { property(s, kTISPropertyInputSourceIsEnabled) ?? false }
  static func currentID() -> String? {
    property(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
  }
  @discardableResult static func register(bundleAt url: URL) -> OSStatus { TISRegisterInputSource(url as CFURL) }
  @discardableResult static func enableAndSelect(id: String) -> Bool {
    guard let s = sources(id: id).first else { return false }
    if !isEnabled(s) { _ = TISEnableInputSource(s) }    // for a mode IM: enable parent first, then mode
    guard let fresh = sources(id: id).first else { return false }  // re-query: flags are cached per process
    return TISSelectInputSource(fresh) == noErr          // paramErr if not enabled / not select-capable
  }
}
```

- Order for a mode IM: `TISRegisterInputSource(url)` → enable parent ID → enable mode ID → select mode ID. Selecting fails unless the mode and its parent are both enabled. [SDK]
- Watch for changes with `DistributedNotificationCenter.default().addObserver(…, name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), …, suspensionBehavior: .deliverImmediately)`. `kTISNotifyEnabledKeyboardInputSourcesChanged` reports enable/disable changes. [REF Fire]
- `kTISPropertyInputSourceIsEnabled` is unreliable:
  - After `TISEnableInputSource` it **does not update in the calling process**. [REF Fire `InputSource.swift`]
  - On macOS 12+ it can stay `true` after the user removed the source. vChewing therefore enables unconditionally. [REF vChewing]
- **Prompts** (reported, not verified here):
  - Since macOS 12, the moment `TISRegisterInputSource` or `TISEnableInputSource` runs for a third-party IM, the user sees a confirmation to allow it in System Settings. [REF vChewing commit "Fix IME activation issues on macOS 12"]
  - Fire's code says: "enable opens System Settings and asks for confirmation; after the user confirms, the IM can be selected. If it's already enabled don't enable again or the dialog repeats."
  - Our Duo did get enabled today; I don't know whether a dialog appeared. Plan for a one-time user click.
  - Fallback if no UI interaction is possible: write `AppleEnabledInputSources` in `com.apple.HIToolbox` directly. This is unsupported, takes effect only after the TIS server re-reads, and might need logout. [INFERRED]
- An IME never needs Accessibility, Input Monitoring or Screen Recording, as long as it does **not** use:
  - `IOHIDManager`: Gureum uses it for Caps Lock and right-⌘, and it triggers the Input Monitoring prompt.
  - `CGEventTap` or `CGEventPost`.
  - `AXUIElement`.

### 3.3 Logout and refresh

- Apple DTS (forum thread 775526, June 2026): "without the user logging off the system, System Settings doesn't pick up a new input source any more. I don't see anything that can avoid the logoff." This affects the System Settings list and the Add sheet only. Enable and select through TIS still work immediately. [REF]
- **Refresh the menu-bar list** with `killall TextInputMenuAgent`, then wait about 0.5 s before enabling. **Never kill `imklaunchagent`**: every running client then loses its connection to all IMs until that client is restarted. [REF vChewing `InstallerVMProtocol.swift`]
- **Reload after reinstall:**
  1. Copy the new bundle over with `ditto build/Duo.app ~/Library/Input\ Methods/Duo.app`.
  2. Run `killall DuoInputMethod`, or the executable name. A running IME keeps its old code until it is killed.
  3. The next focused text field with Duo selected relaunches it on demand through `imklaunchagent`.
  4. If `Info.plist` changed (modes, icons, names), call `TISRegisterInputSource(url)` again and then `killall TextInputMenuAgent`. Some caches may persist until logout.
  - vChewing kills the old instance *after* swapping the bundle so that whatever relaunches is the new code.
- Clean dev loop:
  ```sh
  xcodebuild … && ditto "$PRODUCTS/Duo.app" "$HOME/Library/Input Methods/Duo.app" \
    && killall -q DuoInputMethod; killall -q TextInputMenuAgent
  ```
  Logs, which need no TCC: `log stream --style compact --predicate 'subsystem == "com.inkyuoh.inputmethod.Duo"'`.

### 3.4 Code signing, hardened runtime, sandbox

- **Ad-hoc signing works.** The installed Duo is `Signature=adhoc`, `TeamIdentifier=not set`, and it registers, enables, launches and receives sessions. Locally built bundles carry no quarantine, so Gatekeeper doesn't block them. [RUNTIME]
  - DKST ships its test builds ad-hoc too. [REF]
- **The keychain identity is suspect.** `security find-identity -v -p codesigning` shows `"Apple Development: Inkyu Oh (4MRK2Z3J94)" (CSSMERR_TP_CERT_REVOKED)`. The cert subject is `OU=DKZ2M6YKUP` and it is valid until 2027-07-22. [RUNTIME]
  - The **Team ID is DKZ2M6YKUP**. `4MRK2Z3J94` is only the CN suffix.
  - Because the cert reports as revoked, signing with it may produce binaries that AMFI or launchd refuse.
  - **Use `CODE_SIGN_IDENTITY="-"`, `CODE_SIGN_STYLE=Manual`, `DEVELOPMENT_TEAM=""`.**
- Hardened runtime is not required for local use; it is required for notarization later. With it on, `com.apple.security.cs.disable-library-validation` is needed only if we load unsigned plug-ins (Squirrel does). Ad-hoc plus hardened runtime works.
- **Sandbox** is optional. If you enable it, add:
  ```xml
  <key>com.apple.security.temporary-exception.mach-register.global-name</key>
  <string>com.inkyuoh.inputmethod.Duo_Connection</string>
  ```
  Use exactly the connection name. macSKK and azooKey ship sandboxed this way, and use `com.apple.security.application-groups` to share state with a Settings app. Recommendation for v1: no sandbox. Share settings through `UserDefaults(suiteName: "com.inkyuoh.inputmethod.Duo")` or an Application Support file, and push changes with a `DistributedNotificationCenter` post.
- **Xcode debug dylib.** The current install has `MacOS/DuoInputMethod.debug.dylib` and `__preview.dylib` (`ENABLE_DEBUG_DYLIB` defaults to YES in Debug). It works, but set `ENABLE_DEBUG_DYLIB = NO` and `ENABLE_PREVIEWS = NO` on the IME target. You get one Mach-O, simpler `killall` and crash logs, and no preview stub in a process the system launches. [RUNTIME][INFERRED]

---

## 4. IMKInputController in Swift 6

### 4.1 main.swift (top-level code is MainActor)

```swift
import Cocoa
import InputMethodKit

let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as! String
// Must be created before NSApp.run(); keep a strong global reference for the process lifetime.
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier!)
let delegate = AppDelegate()                 // builds the shared engine, panels, TIS observers
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
```

- `IMKServer(name:bundleIdentifier:)` reads the controller and delegate class names from `Info.plist`, then registers the connection. [SDK]
- **One controller is created per client input session**, which means per text view or field in each app. Controllers are many and short-lived. Keep the engine, the learning store and the panels in **shared singletons**. Controllers stay thin and hold no long-lived strong reference to the client proxy.
  - vChewing even moved client calls into ObjC MRC to avoid Swift retaining XPC client proxies. [REF]
  - azooKey leaked about 80 invisible windows, which loaded WindowServer and broke window dragging. Create **one** reusable panel. [REF azooKey #348]

### 4.2 Which input entry point

- IMK offers three mutually exclusive styles: key bindings (`inputText(_:client:)` plus `didCommand(by:client:)`), unpacked keys (`inputText(_:key:modifiers:client:)`), or raw events (`handle(_:client:)`). **Use `handle(_:client:)`**: it is the only one that also delivers `.flagsChanged` and mouse events. [SDK]
- Return `true` when Duo consumes the event. Return `false` to let the app process it. Always **commit pending text before returning `false`** for keys that end a word.
- `event` can be `nil`, for example from the Character Viewer. Guard for it. [REF macSKK]
- **`recognizedEvents(_:)`**:
  - Default: `NSEvent.EventTypeMask.keyDown` (1024). With that default, IMK itself commits when the user clicks in the text outside the composition. [SDK][RUNTIME]
  - Return `Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown]).rawValue)` to see modifier taps such as a Shift-tap or a right-⌘ flip key.
  - **When you do, IMK's automatic commit-on-click no longer runs.** Commit in `handle` on `.leftMouseDown`, as Gureum does. `.flagsChanged` "works only through `handleEvent:`". [REF Gureum `InputReceiver.swift`]
- Modifier hygiene:
  - Mask with `.deviceIndependentFlagsMask`.
  - Arrow keys carry `.numericPad` and `.function`. Ignore `.capsLock` when mapping Hangul.
  - Pass ⌘ and ⌃ combos through **after committing**. Otherwise ⌘A, ⌘X or Enter act on text without the last syllable (Gureum #924, #180).
  - Option combos also commit and then pass through.
- **Autorepeat:** `event.isARepeat`. Treat a repeat like a normal keystroke, but throttle expensive work: re-score the word at most once per frame. Backspace autorepeat must keep deleting jamo, then letters, then pass through once the buffer is empty.
- **Keyboard layout:**
  - When an IM is selected, TSM translates events with the "most-recently-used ASCII-capable keyboard layout" unless the IM calls `TISSetInputMethodKeyboardLayoutOverride` or `client.overrideKeyboard(withKeyboardNamed:)`. [SDK]
  - For Duo, derive **Hangul jamo from `event.keyCode`**, using the physical 두벌식 positions (`kVK_ANSI_*` in `HIToolbox/Events.h`).
  - Derive **Latin from `event.characters`**. That respects a user who types English on Dvorak.
  - Store both per keystroke. Don't override the keyboard unless you want to force QWERTY for Latin; Gureum does force it.

### 4.3 Lifecycle callbacks

| Callback | When | Duo action |
|---|---|---|
| `init(server:delegate:client:)` | A new client session. Note: `client()` may be nil during init on old OSes; use the `inputClient` parameter. [REF vChewing] | Cache `bundleIdentifier()` once (it is an XPC round-trip) and compute the client policy (§6). |
| `activateServer(_:)` | Duo becomes active for this client: focus arrives, or Duo is selected. | Reset state. Show nothing. Keep it fast, because the first keystroke races activation. Call `super`. |
| `deactivateServer(_:)` | Focus leaves, the app switches, or the IM is switched through the menu. | `commitComposition(sender)`, hide panels, call `super`. **On macOS 26 it is NOT called** for out-of-process `TISSelectInputSource`. Also commit from the `kTISNotifySelectedKeyboardInputSourceChanged` observer. [REF squirrel #1140/#1142] |
| `commitComposition(_:)` | The client asks you to finish now, e.g. on a click or a programmatic focus change. | `client.insertText(buffer, replacementRange: notFound)` **synchronously**, then clear. Don't call it with an empty buffer. |
| `cancelComposition()` | Your own Esc handling. Its default inserts `originalString`. | Prefer `client.setMarkedText("", …)` followed by clearing. |
| `inputControllerWillClose()` | Session teardown (10.7+). | Commit or flush, and drop references. |
| `hidePalettes()` | The system asks you to hide UI. | Hide panels. |
| `menu()` | The Text Input menu is about to draw. | Return an `NSMenu`. Submenus are ignored. [REF macSKK] Action methods receive an info dictionary: `sender[kIMKCommandMenuItemName]` is the `NSMenuItem`, `sender[kIMKCommandClientName]` the client. |
| `setValue(_:forTag:client:)` | Mode changes: `tag == kTextServiceInputModePropertyTag`, `value` = mode ID string. | Store the mode. Commit if it changes. |
| `showPreferences(_:)` | The "Preferences…" item, if its action is `showPreferences:`. | Launch the Settings app. |
| `composedString(_:)` / `originalString(_:)` | Used by IMK's own `updateComposition()` and `cancelComposition()`. | Return the current buffer and the raw keys for safety, even if we drive `setMarkedText` directly. |

### 4.4 Driving the composition

```swift
let notFound = NSRange(location: NSNotFound, length: NSNotFound)
// show/update the word buffer (marked text); caret at end; one clause, plain underline
let s = NSAttributedString(string: display, attributes: mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: display.utf16.count)) as? [NSAttributedString.Key: Any] ?? [:])
client.setMarkedText(s, selectionRange: NSRange(location: display.utf16.count, length: 0), replacementRange: notFound)
// commit
client.insertText(committed, replacementRange: notFound)
```

- `selectionRange` is relative to the marked string. `replacementRange` is **document-relative**. `{NSNotFound, …}` means the current selection or marked range. [SDK]
- In Chromium, keep `selectionRange.length == 0` and use one non-selected clause. A selected range or style inside the composition is the likely cause of the "blue box" highlight. [REF Gureum #880]
- **Chromium web content applies only the *last* `setMarkedText` sent while it handles one key event.** Send exactly one `setMarkedText` per key event. [REF macSKK `InputController.swift`]
- Never send `insertText("")` or `setMarkedText("")` when nothing is composing. It replaces the selection. Office lost selected text on Shift+Arrow this way. [REF Gureum #3]

### 4.5 Caret rectangle for the floating panel

```swift
var rect = NSRect.zero
_ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect) // screen coords, Cocoa (bottom-left origin), width≈1, height=line height
// alternative: client.firstRect(forCharacterRange: client.markedRange(), actualRange: nil)
let level = NSWindow.Level(rawValue: Int(client.windowLevel()) + 1)        // place panel above the client window
```

- `index` is relative to the inline session, and 0 means the start of the composition or selection. Indices other than 0 sometimes fail. [SDK][REF macSKK]
- Some clients return `.zero`. Fall back to the last good rect, or don't show the panel.
- Use `NSScreen.screens.first { $0.frame.contains(rect.origin) }` to stay on the right display. azooKey shipped a multi-display bug here. [REF azooKey #322]
- Panel recipe [INFERRED, standard IME practice]:
  - `NSPanel(styleMask: [.borderless, .nonactivatingPanel])`
  - `isFloatingPanel = true`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, a `canBecomeKey` override that returns `false`
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`
  - `level` = client level + 1
  - Content in `NSGlassEffectView` on macOS 26.

### 4.6 Client identity and secure input

- `client.bundleIdentifier()` can be nil, for example in the Android emulator. Cache it per client object: it is an XPC round-trip, and focus moves between clients. [REF macSKK, DKST]
- **Password fields:**
  - `NSSecureTextField` and web password fields restrict the context to Roman sources (`NSTextInputContext.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]`). TSM switches to an ASCII layout and **Duo is not called**, because Duo is not ASCII-capable. [SDK][INFERRED]
  - Defense in depth: on every activation and on each first key, check `IsSecureEventInputEnabled()` (Carbon, `CarbonEventsCore.h`). If it returns true, pass everything through and **never feed the learning store**.
  - The client wrapper also answers private `isSecureMode`; probe it with `responds(to:)`.
  - `IsSecureEventInputEnabled()` is global, so Terminal's "Secure Keyboard Entry" also makes it true. That is acceptable: it is privacy-conservative.
- **Search fields** (Spotlight, Finder, Alfred, Raycast, Safari's address bar) don't run the search on marked text until commit. Gureum #180 saw search results "missing the last syllable". The private `isIncrementalSearchInputContext` detects these. See §6 for the policy.

### 4.7 Mouse and focus

- A click inside the client arrives as `.leftMouseDown` in `handle()` (with our mask), or through `mouseDown(onCharacterIndex:…)`. Commit and return `false` so the click still moves the caret. [REF Gureum]
- A focus change inside the same app produces `commitComposition` and/or `deactivateServer` on the old controller. A new controller or session is created for the new field.
- A programmatic source switch on macOS 26 calls neither, so rely on the TIS notification (D7).
- A programmatic switch *into* the IME may fail to activate the controller until focus moves. Keys then pass through raw. [REF squirrel #1162]

### 4.8 System overlays on macOS 26/27

The widget gallery, Notification Center and other system overlays dispose legacy-IMK input contexts within about 150 ms. Apple's extension-based IMs still work there. This is a platform limitation; document it as a known issue. [REF squirrel #1196]

### 4.9 Swift 6 strict concurrency: tested facts and the working pattern [VERIFIED with Swift 6.4.2 / SDK 27.2]

What I tested:

- **`-typecheck` does not run region-isolation checks.** Errors like "sending 'self' risks causing data races" show up only in a full compile (`-c` or a build). Always build.
- IMK APIs are imported as **nonisolated** with no `Sendable`, `NSMenu` is not Sendable, and the `client` parameter is `Any!`.
- With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (the Xcode 26+ template default), a plain `class X: IMKInputController` fails with: `main actor-isolated initializer 'init(server:delegate:client:)' has different actor isolation from nonisolated overridden declaration`. The same error appears for `handle`, `recognizedEvents`, `commitComposition`, and the implicit `init()`.
- Marking an override `@MainActor` fails with the same error.
- Making the class `nonisolated` and capturing `self`, `event` or `client` in `MainActor.assumeIsolated { … }` fails with `sending 'self'/'event'/'client' risks causing data races`. This is a full-compile error under both isolation defaults.
- **The pattern below builds with zero warnings in Swift 6 mode** under three settings: default `nonisolated`, `-default-isolation MainActor`, and also with `NonisolatedNonsendingByDefault` plus `InferIsolatedConformances`.
- It ran correctly against a mock client: "gk" was marked `{0,2}` and committed with a space, and the menu returned its items. This is macSKK's pattern (macSKK sets `SWIFT_VERSION = 6.0`). [REF macSKK `InputController.swift`]

```swift
import Cocoa
import InputMethodKit

@MainActor
@objc(DuoInputController)                       // runtime name == Info.plist InputMethodServerControllerClass
final class DuoInputController: IMKInputController {
    private let composer = Composer()           // @MainActor type
    private static let notFound = NSRange(location: NSNotFound, length: NSNotFound)

    /// IMK calls controllers on the main thread (not documented; macSKK logs if not).
    private nonisolated func onMain<T: Sendable>(_ work: @MainActor (DuoInputController) -> T) -> T {
        nonisolated(unsafe) let this = self
        if Thread.isMainThread { return MainActor.assumeIsolated { work(this) } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { work(this) } }
    }

    nonisolated override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
    }
    nonisolated override init() { super.init() }   // required under default MainActor isolation

    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown]).rawValue)
    }

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        nonisolated(unsafe) let event = event          // non-Sendable IMK args: rebind, use synchronously
        nonisolated(unsafe) let sender = sender
        return onMain { this in
            guard let event, let client = sender as? (any IMKTextInput & NSObjectProtocol) else { return false }
            return this.handleKey(event, client: client)   // MainActor-isolated implementation
        }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let sender = sender
        onMain { this in this.commit(to: sender as? (any IMKTextInput & NSObjectProtocol)) }
    }

    nonisolated override func menu() -> NSMenu! {     // non-Sendable return: pass out via nonisolated(unsafe) var
        nonisolated(unsafe) var result: NSMenu?
        onMain { this in result = this.buildMenu() }
        return result
    }
    // activateServer / deactivateServer / setValue / inputControllerWillClose / composedString:
    // same shape: `nonisolated override`, rebind args, `onMain { … }`, call `super` where relevant.

    @objc func showSettings(_ sender: Any?) { /* sender is [kIMKCommandMenuItemName: NSMenuItem, kIMKCommandClientName: client] */ }
    private func handleKey(_ e: NSEvent, client: any IMKTextInput & NSObjectProtocol) -> Bool { … }
    private func commit(to client: (any IMKTextInput & NSObjectProtocol)?) { … }
    private func buildMenu() -> NSMenu { … }
}
```

Alternatives:
- vChewing (Swift 6.4, default MainActor isolation) ships an ObjC overlay header, `IMKSwift.h`. It re-declares IMK under `#pragma clang attribute push(__attribute__((swift_attr("@MainActor"))), apply_to = any(objc_method, objc_property))` with nullability added, plus an `IMKInputSessionController` ObjC subclass for Swift to subclass. This is cleaner at call sites but adds an ObjC target, and parts of it touch private IMK internals. [REF] **Not needed for Duo.**
- Squirrel avoids the problem with `SWIFT_VERSION = 5.0` and `SWIFT_STRICT_CONCURRENCY = targeted`. That doesn't meet our bar.

---

## 5. Replacing already-committed text ("flip the word I just committed")

### 5.1 Mechanics

- `insertText(_:replacementRange:)` and `setMarkedText(_:selectionRange:replacementRange:)` accept a **document-relative** `replacementRange`.
- `selectedRange()` returns the current selection, also document-relative. `{NSNotFound, NSNotFound}` means the client doesn't support TSM document access, and then the replacement range is **ignored**: the text is inserted at the caret, which duplicates it. [SDK]
- Verify the range with `attributedSubstring(from:)` or `string(from:actualRange:)` before replacing anything. Both return nil or garbage on clients without document access.
- Apple's own Korean IM depends on replacement on macOS 26. In a plain `NSTextView` it composes **without any marked text**: `hasMarkedText()` stayed false while "ㅎ→하→한→한ㄱ→한그→한글" built up through replacement. It switches to marked text for clients that need it. [RUNTIME][REF DKST]

### 5.2 Algorithm (port of macSKK `kakuteiUndo` and `fixedTextRange`)

1. **At commit**, record the text first: `lastCommit = (text: committedWord + boundary, location: markedRange().location ?? selectedRange().location before insert, rawKeys, alternateInterpretation)`.
   - Include the boundary character (space or punctuation) in the record. NSTextView puts the caret after the inserted text, so if the replacement covers only the word, the caret jumps back before the space.
2. **On the flip key with an empty buffer:**
   - `sel = client.selectedRange()`. Require `sel.location != NSNotFound && sel.length == 0`. A non-empty selection means re-conversion, not undo.
   - Candidate locations, in order: `lastCommit.location`, then `sel.location - len(lastCommit.text)`. Prefer the remembered position, and fall back to the text just before the caret.
   - For each location `l ≥ 0`, accept it only if `client.attributedSubstring(from: NSRange(l, len))?.string == lastCommit.text`.
3. **Replace:**
   - Option A, reopen as composition (macSKK): `client.setMarkedText(flipped, selectionRange: NSRange(location: flippedLen, length: 0), replacementRange: r)`. The word becomes editable marked text again, a second flip is free, and the next boundary commits it with `insertText(_, notFound)`. Specify the range **only on the first** `setMarkedText`; later ones use `notFound`. Send only **one** `setMarkedText` per key event (Chromium).
   - Option B, replace directly: `client.insertText(flipped + boundary, replacementRange: r)`. This is simpler, but it can't be undone by flipping again unless you re-record.
4. After a successful flip, feed the correction to the learner. Invalidate `lastCommit` on any caret move, click or other key.

### 5.3 Client support matrix

| Client | Replacement support | Source | Policy |
|---|---|---|---|
| Cocoa `NSTextView`/`NSTextField` (TextEdit, Notes, Mail, Xcode editor and so on) | full | [SDK]; tested `NSTextView` | `.full` |
| WebKit / Safari (`com.apple.Safari`, `com.apple.WebKit.*`) | full; DKST "trusts direct composition range" for WebKit | [REF DKST] | `.full`, but avoid eager keyboard override on WebKit |
| Chromium (Chrome, Edge, Brave, Arc `company.thebrowser.Browser`, Whale `com.naver.Whale`, Vivaldi, Opera) | works; macSKK default `.full` covers Chrome. Quirk: only the last `setMarkedText` per key event is applied | [REF macSKK] | `.full` plus one `setMarkedText` per event |
| Electron (VS Code `com.microsoft.VSCode`, Slack, Notion, Discord…) | same as Chromium (hidden textarea in VS Code). Detect with `Contents/Frameworks/Electron Framework.framework` | [REF DKST detection]; [INFERRED] support | `.full`, verify with `attributedSubstring` |
| Terminal.app (`com.apple.Terminal`) | **before-caret only**: other ranges are ignored | [REF macSKK `ReplacementRangeSupport`] | `.beforeCaretOnly` |
| iTerm2 (`com.googlecode.iterm2`), Hyper (`co.zeit.hyper`) | **unsupported**: marked text always drawn at the cursor; positions counted in screen cells | [REF macSKK] | `.unsupported` |
| Java/JetBrains (IntelliJ `com.jetbrains.*`, Android Studio `com.google.android.studio`, any JBR app) | **unsupported**: `AWTView.insertText` ignores `replacementRange` (JDK-8257650). Single short insertText calls without marked text were dropped until JDK-8195675 (2024) | [REF OpenJDK] | `.unsupported`; also always `setMarkedText(x)` before `insertText(x)` |
| Microsoft Office | unknown and historically fragile (selection loss, Excel input) | [REF Gureum #3, #237] | verify-first; deny on mismatch |
| Unknown | verify-first | | `.full` only if the `attributedSubstring` check succeeds |

**Fallback** when replacement is unsupported: an IME cannot send Backspace to the client without Accessibility (`CGEventPost` needs TCC). So either:
- show a subtle HUD ("이 앱에서는 되돌리기를 지원하지 않아요"), or
- keep a per-app setting to delay commits in those apps.

Never replace blindly: in those clients it would insert a duplicate.

---

## 6. Compatibility pitfalls and mitigations

| Pitfall | Cause | Mitigation |
|---|---|---|
| **Enter loses or duplicates the last syllable** in web chat apps and search bars; Terminal swallows Return | Gureum's Terminal bug: the IME committed and *consumed* Return (#1). Web pages that handle `keydown` Enter while composing (`isComposing`/`keyCode 229`) see the commit after their handler. | On Return, Tab, Esc, arrows, ⌘/⌃ combos and function keys: **commit with `insertText` first, then return `false`** so the app gets the real key after `compositionend`. Never insert "\n" yourself. |
| Commit not seen by ⌘A, ⌘X or search (Finder, Alfred, Spotlight search "구름입력" without the last syllable) | Text still marked when the shortcut runs or the search reads the field. [REF Gureum #924, #180] | Commit before passing any modifier combo. In search contexts (`isIncrementalSearchInputContext`, or bundle IDs `com.apple.Spotlight`, `com.runningwithcrayons.Alfred`, `com.raycast.macos`), consider committing per keystroke ("direct mode", see below). |
| Chromium "blue box" over composing text | A selected range or selected-clause style inside the marked text. [REF Gureum #880] | `selectionRange = (len, 0)`, one clause, `kTSMHiliteConvertedText` (single underline) or raw style. |
| Chromium/Electron composition timing bugs; first character after launch splits into jamo or Latin | Web view and IME run loops sync asynchronously; the first focus is hard to classify. [REF DKST] | Synchronous `setMarkedText` inside `handle`. Warm up the engine at launch. One `setMarkedText` per key event. |
| **iTerm2 first character doubled** | iTerm2 checks for marked text right after `handle` returns `true`. [REF azooKey #357] | Always set marked text (or insert) before returning `true`. Never defer to async work. |
| JetBrains/Java: committed short strings dropped, Shift+Space adds a space, odd composition | AWT ignores short `insertText` without marked text and ignores `replacementRange`. [REF OpenJDK JDK-8195675/8257650, Gureum #149/#852/#829] | For Java clients, always `setMarkedText(text)` immediately before `insertText(text)`, as macSKK does for `com.jetbrains.intellij`. Detect Java by bundle-ID prefix `com.jetbrains.`, `com.google.android.studio`, or `Contents/jbr` inside the app. Gureum's "JDK compatibility mode" treats every character as composing. |
| Terminal marked text and replacement | Terminal draws marked text at the cursor and honors only replacements that end at the caret. | `.beforeCaretOnly` policy. Return passes through after commit. |
| Microsoft Office: Shift+Arrow deletes the selection; Excel input oddities | An empty `setMarkedText`/`insertText` sent while nothing is composing. [REF Gureum #3, #237] | Send nothing when the buffer is empty. Return `false` for navigation keys. |
| Things or Messages: a Shift-first character is inserted raw | Some apps commit the first marked character. [REF macSKK `treatFirstCharacterAsMarkedText`] | Keep a per-app compatibility toggle in the Duo menu (macSKK exposes these in `menu()`). |
| Kitty/Alacritty: mode-change keys leak characters | Terminal emulators that don't handle empty marked text. [REF macSKK `insertBlankString`] | Not needed unless Duo adds a mode key. |
| Spotlight/Raycast panels | Context menus and candidate menus misbehave. [REF vChewing deny-list `com.apple.Spotlight`, `com.raycast.macos`] | Place the panel at `client.windowLevel()+1`. Avoid context menus there. |
| System overlays (widgets, Notification Center) | Legacy IMK contexts disposed on macOS 26/27. [REF squirrel #1196] | Known limitation. |
| Programmatic source switching (macism, Input Source Pro, vim plugins) | No `deactivateServer` or activation on macOS 26. [REF squirrel #1140/#1162] | TIS notification observer → commit and hide. |
| Shift+Space | Not a system shortcut (⌃Space / ⌃⌥Space are). In JetBrains it typed a space during switching. [REF Gureum #829] | If it becomes the flip key: consume it (`return true`) **only** when a flip or commit actually happened, never on an empty buffer. |
| **Caps Lock** | With `TICapsLockLanguageSwitchCapable=true` and the user setting on, the system steals short presses to switch to ABC. Otherwise Caps Lock arrives as `.flagsChanged` and sets `.capsLock`. Driving the LED needs `IOHIDManager`, which triggers the Input Monitoring prompt. [REF Gureum `InputMethodServer.swift`] | `false` in the plist. Ignore `.capsLock` when mapping jamo; treat it as an English signal. Don't use IOKit. |
| **Fn/Globe key** | `kVK_Function` (63) arrives as `.flagsChanged` with `.function`, but System Settings "Press 🌐 to…" (input switch, emoji, dictation) also acts on it. | Never bind flip to Fn/Globe. |
| Display sleep or idle: menu shows only ABC until the user switches apps | macOS glitch. [REF macSKK #112] | Known issue. |
| Right ⌘/⌥ as a flip key | Seen only as `.flagsChanged`. Distinguish left from right by `keyCode` (54 = right ⌘, 61 = right ⌥) with no intervening key. | A tap means flagsChanged down then up within about 300 ms with no other key. |
| Passwords | See §4.6. | Pass through. Never learn. |

**Direct vs marked composition (strategic choice):**

- Apple (macOS 26) and DKST compose **directly**, with no underline, in Cocoa and WebKit clients, using replacement ranges. They fall back to **marked text** for Chromium/Electron, Java, terminals, and clients whose `selectedRange()` returns `NSNotFound`. [RUNTIME][REF DKST `shouldUseMarkedTextForClient`]
- For Duo, v1 = **marked text everywhere**: it is robust and simple, and the word is visibly "pending", which suits the flip UX.
- v2 can add direct mode for search fields and Cocoa/WebKit, behind the same client-policy table, for better behavior in incremental search.

---

## 7. TCC-free testing

### 7.1 End-to-end through the real TSM → IMK path [VERIFIED]

Setup: a scratch AppKit host app (`Probe.app`) with an `NSTextView` as first responder. The selected input source was Apple's 2-Set Korean. The app sent the key sequence g k s r m f ⌫ ⏎.

| Delivery method | Host active and key | Result |
|---|---|---|
| `window.sendEvent(NSEvent.keyEvent(with:.keyDown, …, characters:"g", keyCode:5))` | yes | `"gksrmf"`: **the IME was bypassed** (raw characters inserted) |
| `textView.keyDown(with: NSEvent.keyEvent…)` | yes | `"gksrmf"`: bypassed |
| `textView.inputContext!.handleEvent(NSEvent.keyEvent…)` | no | `"gksrmf"`: bypassed |
| `NSApp.postEvent(NSEvent.keyEvent…)` | no | `"gksrmf"`: bypassed |
| **`window.sendEvent(NSEvent(cgEvent: CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: k, keyDown: true)!)!)`** + key-up | **yes** | **`"한글"` → ⌫ → `"한그"` → ⏎ → `"한그\n"`: full IME composition** ✅ |
| same CGEvent path | **no** (launched directly, not active) | `"ㅎㅏㄴㄱㅡㄹ"`: events reached the IME (jamo mapped) but **didn't combine**. A context that isn't key or active breaks document access. |
| `CGEvent.postToPid(getpid())` | yes | nothing delivered (dropped without TCC) |

Conclusions:

1. Events must be **real CGEvent-backed key events**. `NSEvent.keyEvent(...)` is passed straight to `insertText`. Probable cause: TSM needs the CGEvent with a keyboard type or source. [INFERRED]
2. Use `window.sendEvent`. It is in-process, so no Accessibility is needed.
3. The host **must be the active app with a key window**. Launch it through LaunchServices (`open -W -n Probe.app --args …`). A process started directly from a shell is refused activation under macOS 14+ cooperative activation; `NSApp.isActive` stayed false.
4. Allow about 50–150 ms of run loop after each event, because the IME's `insertText` arrives through XPC.
5. Apple's IM showed no marked text in `NSTextView`. Assert on `textView.string`, and assert on `hasMarkedText()`/`markedRange()` only for Duo.

Harness core (compiled and run):

```swift
func sendKey(_ vk: CGKeyCode, flags: CGEventFlags = [], to window: NSWindow) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let cg = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down)!
        cg.flags = flags                       // e.g. .maskShift for ㅃ/ㅆ…, .maskCommand for shortcuts
        window.sendEvent(NSEvent(cgEvent: cg)!)
    }
}
// Precondition checks before typing:
precondition(NSApp.isActive && window.isKeyWindow && window.firstResponder === textView)
// Select Duo for the test (global selection; restore afterwards):
let previous = textView.inputContext?.selectedKeyboardInputSource
textView.inputContext?.selectedKeyboardInputSource = "com.inkyuoh.inputmethod.Duo.Bilingual" // or the mode-less ID
textView.inputContext?.deactivate(); textView.inputContext?.activate()   // works around activation not following a programmatic select (squirrel #1162)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
// … type, wait, assert on textView.string / textView.markedRange() …
textView.inputContext?.selectedKeyboardInputSource = previous
```

Additional notes:
- `NSTextInputContext.selectedKeyboardInputSource` is settable. It uses `kTISPropertyInputSourceID` strings (`keyboardInputSources` lists the enabled ones). [SDK]
- The alternative is `TISSelectInputSource`. There is also `kTSMDocumentInputSourceOverridePropertyTag` ('inis') through `TSMSetDocumentProperty(TSMGetActiveDocument(), …)`; both are 64-bit and their header says "if the TSMDocument is already active … the specified input source is selected". [SDK]
- Run the harness as a bundled app launched with `open`, and write results to a file the shell reads, because stdout isn't connected.
- It also works as the **XCTest/Swift Testing host app** if the host is activated; assert `NSApp.isActive`. [INFERRED]
- Caution: the harness steals focus and changes the global input source. Don't run it while a human or another agent is typing. Restore the previous source when done.
- Chromium, Terminal or Office can't be driven this way. Sending events to *other* apps needs Accessibility. Cover them with the client-policy unit tests below plus manual checks.

### 7.2 Unit-testing the controller with a mock client [VERIFIED]

- `DuoInputController(server: nil, delegate: nil, client: nil)` works in a plain process, with no `IMKServer` and no `NSApplication`. `handle(_:client:)`, `commitComposition(_:)` and `menu()` all ran with a mock client.
- Build key events with `NSEvent.keyEvent(...)`. These are fine here because no TSM is involved.

```swift
final class MockClient: NSObject, IMKTextInput {
    let text = NSMutableString()
    var marked = NSRange(location: NSNotFound, length: 0), selection = NSRange(location: 0, length: 0)
    var log: [String] = []                                  // record call order for assertions
    private func str(_ s: Any!) -> String { (s as? NSAttributedString)?.string ?? (s as? String) ?? "" }
    func insertText(_ string: Any!, replacementRange: NSRange) {
        let s = str(string); log.append("insert(\(s),\(replacementRange))")
        let r = replacementRange.location != NSNotFound ? replacementRange : (marked.location != NSNotFound ? marked : selection)
        text.replaceCharacters(in: r, with: s)
        selection = NSRange(location: r.location + (s as NSString).length, length: 0); marked = NSRange(location: NSNotFound, length: 0)
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let s = str(string); log.append("mark(\(s),\(selectionRange),\(replacementRange))")
        let r = replacementRange.location != NSNotFound ? replacementRange : (marked.location != NSNotFound ? marked : selection)
        text.replaceCharacters(in: r, with: s); let n = (s as NSString).length
        marked = n == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: r.location, length: n)
        selection = NSRange(location: r.location + min(selectionRange.location, n), length: 0)
    }
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { marked }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { NSAttributedString(string: text.substring(with: range)) }
    func length() -> Int { text.length }
    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { lineRect?.pointee = NSRect(x: 100, y: 100, width: 1, height: 17); return [:] }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    var bundleID = "test.mock"; func bundleIdentifier() -> String! { bundleID }   // vary to test client policies
    func windowLevel() -> CGWindowLevel { CGWindowLevelForKey(.normalWindow) }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "mock-1" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { actualRange?.pointee = range; return text.substring(with: range) }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { NSRect(x: 100, y: 100, width: 1, height: 17) }
}
```

Mock variants to cover the client policies:
- `NotFoundClient`: `selectedRange` returns `NSNotFound` and replacement is ignored. Simulates no document access.
- `TerminalLikeClient`: honors only ranges that end at the caret.
- `JavaLikeClient`: ignores `replacementRange`, and ignores `insertText` of 2 or fewer UTF-16 units when nothing is marked.
- `ChromiumLikeClient`: applies only the last `setMarkedText` per simulated key.

Gureum takes another route: an ObjC `MockInputClient : NSTextView <IMKTextInput, IMKUnicodeTextInput>`, which reuses the real text system for marked text and replacement. It drives the controller through `inputText(_:key:modifiers:client:)` in XCTest. [REF Gureum `GureumTests/MockInputClient.m`, `MockApp.swift`] Doing this in Swift clashes with `NSTextView`'s `validAttributesForMarkedText` property and its differently labeled `setMarkedText(_:selectedRange:…)`. Write it in ObjC if you want it.

Structure:
- Put the engine (2-set automaton, scorer, learner) **and the controller** in a framework or SPM target, e.g. `DuoKit`, that both the IME app and the tests link.
- `NSClassFromString("DuoInputController")` still resolves through `@objc(DuoInputController)` once the framework is loaded.
- Swift Testing then covers the engine and controller in-process with no host app. Keep §7.1 for a small smoke suite.

---

## 8. Sources

SDK headers (`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk/System/Library/Frameworks/…`):
- `InputMethodKit.framework/Headers/IMKServer.h`, `IMKInputController.h`, `IMKCandidates.h`, `InputMethodKit.h`, `Modules/module.modulemap`
- `Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/IMKInputSession.h`, `TextInputSources.h`, `TextServices.h`, `CarbonEventsCore.h` (`IsSecureEventInputEnabled`), `CarbonEvents.h` (`kEventParamTextInputSendReplaceRange`)
- `CoreServices.framework/.../AE.framework/.../AERegistry.h` (`kTSMHilite*`)
- `AppKit.framework/Headers/NSTextInputClient.h`, `NSTextInputContext.h`, `NSGlassEffectView.h`

System bundles inspected (read-only): `/System/Library/Input Methods/KoreanIM.app/Contents/PlugIns/KIM_Extension.appex/Contents/Info.plist` and `InfoPlist.loctable`, `AinuIM.app`, `TCIM.app`, `SCIM.app`, `JapaneseIM-*.app`.

Open-source IMEs (shallow clones, Nov 2026):
- macSKK (Swift 6): https://github.com/mtgto/macSKK, files `macSKK/InputController.swift`, `macSKK/StateMachine.swift` (`kakuteiUndo`, `fixedTextRange`, `ReplacementRangeSupport`), `macSKK/macSKK.entitlements`
- Gureum: https://github.com/gureum/gureum, files `OSXCore/InputController.swift`, `OSXCore/InputReceiver.swift`, `OSXCore/InputMethodServer.swift`, `GureumTests/MockInputClient.m`, `GureumTests/MockApp.swift`, `OSX/Info.plist`
- Squirrel: https://github.com/rime/squirrel, files `resources/Info.plist`, `sources/InputSource.swift`, `resources/Squirrel.entitlements`
- Fire: https://github.com/qwertyyb/Fire, files `Fire/InputSource.swift`, `docs/dev-logs/2026-09-23-input-source-missing-from-add-list.md`
- azooKey-Desktop: https://github.com/azooKey/azooKey-Desktop, files `azooKeyMac/Info.plist`, `azooKeyMac/azooKeyMac.entitlements`
- vChewing: https://github.com/vChewing/vChewing-macOS, files `Packages/vChewing_IMKUtils/Sources/IMKSwiftModernHeaders/include/IMKSwift.h`, `Packages/vChewing_InstallerAssembly4Darwin/.../InstallerVMProtocol.swift`
- DKST: https://github.com/DINKIssTyle/DINKIssTyle-IME-macOS, files `Sources/InputController+ClientPolicy.m`, `Docs/INPUT-SYNC-VALIDATION.md`

Issues and threads:
- Apple DTS on logout: https://developer.apple.com/forums/thread/775526
- Squirrel #1140 (no `deactivateServer` on programmatic switch, macOS 26): https://github.com/rime/squirrel/issues/1140; fix PR #1142: https://github.com/rime/squirrel/pull/1142
- Squirrel #1162 (no activation on programmatic switch): https://github.com/rime/squirrel/issues/1162
- Squirrel #1196 (system overlays dispose legacy IMK contexts): https://github.com/rime/squirrel/issues/1196
- azooKey #357 (iTerm2 doubled first character from async marked text): https://github.com/azooKey/azooKey-Desktop/issues/357
- azooKey #348 (leaked invisible windows): https://github.com/azooKey/azooKey-Desktop/issues/348
- azooKey #385 (`setMarkedText` CFEqual(NULL) host crash on 26.6.2; pass non-nil strings and attributes): https://github.com/azooKey/azooKey-Desktop/issues/385
- Gureum issues: https://github.com/gureum/gureum/issues/880, /924, /180, /1, /3, /237, /149, /852, /829
- OpenJDK: https://bugs.openjdk.org/browse/JDK-8257650 and https://bugs.openjdk.org/browse/JDK-8195675 (fix: https://github.com/openjdk/jdk/pull/17921)
- Apple NumberInput sample (connection-name comment): https://developer.apple.com/library/archive/samplecode/NumberInput_IMKit_Sample/Listings/trunk_NumberInput_4_main_m.html
- vChewing macOS 12 enable prompt (commit "Fix IME activation issues on macOS 12"): https://testgitea.trustie.net/floraachy/vChewing-macOS/commit/883dc6144662b19f11ca0838a37ba258af5114d1
- MDN `isComposing`/229 notes: https://developer.mozilla.org/en-US/docs/Web/API/Element/keydown_event
