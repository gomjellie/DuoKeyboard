# InputMethodKit과 텍스트 입력 소스(Text Input Sources): Duo 플랫폼 조사

트랙: IMK와 TIS 플랫폼 조사. 대상: arm64의 macOS 26.6.2 (Tahoe), Xcode 27.2, Swift 6.4.2, SDK `MacOSX27.2.sdk`.
날짜: 2026-11-07.

모든 주장에는 아래 라벨 중 하나를 붙였어요:
- **[SDK]**: `MacOSX27.2.sdk`의 헤더에서 읽음.
- **[RUNTIME]**: 이 기기(macOS 26.6.2)에서 코드를 실행해 관찰함.
- **[VERIFIED]**: 내가 이 기기에서 직접 컴파일하거나 실행함.
- **[REF]**: 오픈소스 입력기나 공개 이슈에서 가져옴. 링크를 붙임.
- **[INFERRED]**: 내 추론이며 확인하지 않음.

---

## 0. 결정 요약

| # | 결정 | 이유 |
|---|---|---|
| D1 | `~/Library/Input Methods/`에 전통적인 **IMK 앱 번들**로 배포함. | Apple 자체 입력기는 비공개 앱 확장(`NSExtensionPointIdentifier = com.apple.textinputmethod-services`, `IMKExtension*` 클래스)으로 옮겨 갔음. 이 경로에는 공개 헤더가 없어서 서드파티는 앱 형태를 써야 함. [RUNTIME][SDK] |
| D2 | Apple의 단일 모드 AinuIM을 따라 **입력 모드를 하나** 선언함. 부모 ID는 `com.inkyuoh.inputmethod.Duo`, 모드 ID는 `com.inkyuoh.inputmethod.Duo.Bilingual`. **지금** 정해야 함. | 모드가 있으면 모드별 `TISIconLabels`, 스크립트, 이름을 가질 수 있음. 선택 가능한 ID를 나중에 바꾸면 모든 사용자가 입력 소스를 다시 추가해야 함. 2.4절 참고. |
| D3 | 컨트롤러 클래스 이름을 `@objc(DuoInputController)`로 정하고 `@MainActor`로 선언함. IMK 오버라이드는 **모두** `nonisolated`로 두고, `MainActor.assumeIsolated`로 메인 액터로 넘어감(macSKK 패턴). | Swift 6 모드에서 두 가지 `SWIFT_DEFAULT_ACTOR_ISOLATION` 설정 모두 깨끗하게 컴파일된 유일한 패턴임. [VERIFIED] 4.9절 참고. |
| D4 | `handle(_:client:)`와 `recognizedEvents = [.keyDown, .flagsChanged, .leftMouseDown]`로 입력을 처리함. 마우스 다운 때의 확정은 직접 함. | `.keyDown` 말고 다른 값을 반환하면 IMK에 내장된 클릭 시 확정이 꺼짐. [SDK] |
| D5 | `true`를 반환하기 전에 `handle()` 안에서 조합 문자열(marked text)을 **동기로** 설정함. 비동기로 넘어간 뒤에 설정하지 않음. | iTerm2는 `handle`이 반환된 직후 조합 문자열이 있는지 보고 입력기가 키를 썼는지 판단함. 늦게 갱신하면 첫 글자가 두 번 찍힘. [REF azooKey #357] |
| D6 | "확정한 단어 바꾸기" 기능은 **검증한** 범위에 `setMarkedText(_:selectionRange:replacementRange:)`나 `insertText(_:replacementRange:)`를 써서 구현함. 먼저 `attributedSubstring(from:)`로 확인함. 클라이언트 정책으로 허용 여부를 정함: 전체 지원, 캐럿 앞만 지원(Terminal), 미지원(iTerm2, Hyper, Java/JetBrains). | macSKK의 "確定アンドゥ"(확정 취소) 알고리즘이며, Cocoa, WebKit, Chromium에서 동작함. [REF] 5절 참고. |
| D7 | `kTISNotifySelectedKeyboardInputSourceChanged`를 감시하다가, 선택된 입력 소스가 더 이상 Duo가 아니면 확정하고 UI를 숨김. | macOS 26에서는 다른 프로세스가 `TISSelectInputSource`를 호출해도 `deactivateServer`가 **불리지 않음**. [REF squirrel #1140/#1142] |
| D8 | 로컬 작업에서는 **ad-hoc**(`CODE_SIGN_IDENTITY = "-"`)으로 서명함. v1에는 샌드박스 없음. 입력기 타깃에 `ENABLE_DEBUG_DYLIB = NO`를 설정함. | 키체인에 있는 유일한 인증서 "Apple Development: Inkyu Oh (4MRK2Z3J94)"는 **`CSSMERR_TP_CERT_REVOKED`**로 나옴. 실제 Team ID(OU)는 4MRK2Z3J94가 아니라 **`DKZ2M6YKUP`**임. 지금 설치된 ad-hoc 빌드는 등록, 켜기, 실행이 모두 됨. [RUNTIME] |
| D9 | TCC 없는 종단 간(end-to-end) 테스트에서는 `open`으로 띄운 **활성** 호스트 앱의 `window.sendEvent(_:)`에 `NSEvent(cgEvent: CGEvent(keyboardEventSource:virtualKey:keyDown:))`를 보냄. `NSEvent.keyEvent(...)` 이벤트는 입력기에 **닿지 않음**. | Apple 두벌식(2-Set Korean)으로 확인함: "한글"이 나옴. [VERIFIED] 7절 참고. |
| D10 | 설정 UI는 입력기가 `NSWorkspace`로 띄우는 **별도의 일반 앱**에 둠. 입력기 번들은 `LSUIElement`로 유지함. | macOS 14+의 협조적 활성화(cooperative activation) 아래에서는 백그라운드 입력기나 에이전트 입력기가 안정적으로 활성화되지 않음. [INFERRED: macSKK 코드와 Apple KoreanIM의 컨테이너 구성에서 추론] |

---

## 1. SDK에 실제로 들어 있는 것 (MacOSX27.2.sdk)

### 1.1 헤더

- `InputMethodKit.framework/Headers/`에는 `InputMethodKit.h`, `IMKServer.h`, `IMKInputController.h`, `IMKCandidates.h`가 있음. 모듈 맵은 `framework module InputMethodKit [extern_c] { umbrella header ... }`임. [SDK]
  - 헤더에는 아직 "Copyright (c) 2006"이 적혀 있음. 가장 새로운 가용성 매크로는 `AVAILABLE_MAC_OS_X_VERSION_10_7_AND_LATER`임. **nullability 주석도, `NS_SWIFT_UI_ACTOR`/`@MainActor`도, `Sendable` 주석도 없음**. **IMK에는 10.7 이후 새로 생기거나 deprecated된 것이 하나도 없음.**
- `IMKTextInput`은 IMK에 **없음**. `IMKUnicodeTextInput`, `IMKLocationToOffsetMappingMode`(`kIMKMouseTrackingMode = 1<<0`, `kIMKNearestBoundaryMode = 1<<1`), `IMKTextOrientationName`과 함께 `Carbon.framework/.../HIToolbox.framework/Headers/IMKInputSession.h`에 있음. [SDK]
- `HIToolbox/TextInputSources.h`(2006–2008)에 TIS API 전체가 있고, 모두 10.5부터 쓸 수 있음. 새로 추가된 것은 `kTISPropertyIconImageURL`에 붙은 메모 하나뿐임. TIS는 `-[NSBundle imageForResource:]`를 쓰므로, plist의 경로 확장자가 틀려도(예: 파일은 `.tiff`인데 `.png`로 적음) 그대로 찾아짐. Apple KoreanIM이 이 동작에 기댐: plist에는 `2SetKorean.png`라고 적고 실제로는 `2SetKorean.tiff`를 넣어 배포함. [SDK][RUNTIME]
- `HIToolbox/TextServices.h`는 `ts*` plist 키를 `CFSTR` 매크로로 정의함. TSM 문서 속성 태그(`kTSMDocumentInputSourceOverridePropertyTag = 'inis'`, `kTSMDocumentEnabledInputSourcesPropertyTag = 'enis'`, `kTSMDocumentSupportDocumentAccessPropertyTag = 'dapy'`)와 `kTextServiceInputModePropertyTag`도 정의함. [SDK]
- `AE.framework/.../AERegistry.h`는 `kTSMHiliteCaretPosition=1`, `RawText=2`, `SelectedRawText=3`, `ConvertedText=4`, `SelectedConvertedText=5`, `BlockFillText=6`, `OutlineText=7`, `SelectedText=8`, `NoHilite=9`를 정의함. [SDK]
- AppKit의 `NSTextInputClient.h`에는 `NSTextCursorAccessoryPlacement`, `unionRectInVisibleSelectedRange`, `documentVisibleRect`(macOS 14)와 `supportsAdaptiveImageGlyph`, `insertAdaptiveImageGlyph(_:replacementRange:)`(macOS 15)가 추가됨. `NSTextInputContext.h`에는 `textInputClientWillStartScrollingOrZooming`, `…DidEndScrollingOrZooming`(14.0)과 `textInputClientDidUpdateSelection`, `textInputClientDidScroll`(15.4)이 추가됨. 모두 클라이언트 쪽 API라서 우리 호스트 앱이나 테스트 앱에만 의미가 있음. [SDK]
- `NSGlassEffectView`와 `NSGlassEffectContainerView`는 macOS 26.0에 나왔고, `style`, `cornerRadius`, `tintColor`, `contentView`를 가짐. **`effectIsInteractive`는 `API_AVAILABLE(macos(27.0))`임**. SDK는 macOS 27이지만 사용자는 26.6을 쓰므로, 27 전용 API는 모두 `if #available(macOS 27, *)`가 필요함. [SDK]

### 1.2 Swift로 가져온 API 표면 (`swift-synthesize-interface` 결과) [VERIFIED]

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

두 `selectionRange()` 출처가 서로 달라요. 런타임에서 새 컨트롤러의 기본값은 `{0,0}`을 반환해요. 반면 헤더는 기본값이 선택 영역을 "조합 문자열 끝"에 둔다고 말해요. 어느 쪽에도 기대지 마세요. `client.setMarkedText`를 직접 호출할 때는 `selectionRange`를 명시해서 넘기세요. [RUNTIME]

런타임에서 `mark(forStyle:at:)`은 아래 속성을 반환해요. 스타일 2(raw text)에는 밑줄이 없어서 클라이언트가 기본 모양을 써요: [RUNTIME]
- 2 → `NSMarkedClauseSegment=1`
- 3 → `NSUnderline=3`(굵게)과 짙은 회색 밑줄 색
- 4 → `NSUnderline=1`
- 5 → `NSUnderline=2`(굵게 또는 이중)
- 8과 9 → 절(clause) 속성만

### 1.3 macOS 26.6.2의 비공개 런타임 표면 (의존하지 말 것; `responds(to:)`로만 확인할 것) [RUNTIME]

- IMK 이미지에는 `_IMKServerLegacy`, `_IMKServerModern`과 `_IPMDServerClientWrapperLegacy`, `_IPMDServerClientWrapperModern`이 들어 있음. 프레임워크가 런타임에 어느 쪽을 쓸지 고름. modern 쪽은 NSXPC를 쓰고 `imklaunchagent`에 체크인함(`registerIMKXPCEndpointWithLaunchAgent`).
- `sender`/클라이언트 객체는 `_IPMDServerClientWrapperModern`임. 여러 비공개 셀렉터에 응답함:
  - `isSecureMode`
  - `isIncrementalSearchInputContext`: 검색 필드를 감지함.
  - `isBottomLineInputContext`
  - `isTextPlaceholderAwareInputContext`
  - `processIdentifier`
  - `markedCharacterCount`
  - `windowEffectiveAppearance`와 `viewEffectiveAppearance`: 패널의 라이트/다크를 고를 때 씀.
  - `replyTimeout`과 `setReplyTimeout:`: DKST는 100 ms로 설정해서, 멈춘 클라이언트가 입력기를 얼리지 못하게 함.
  - `supportsChromaticMarkedText`
  - `keyboardType`
  - `isAutomaticSpellingCorrectionEnabled_WithAvailability:`와 그 형제 셀렉터들.
- `IMKInputController`에도 비공개 `leftContextWithLength:`, `rightContextWithLength:`, `contextWithDelta:`, `invalidateClientGeometry`가 있음.
- 비공개 테스트 클래스 `IMKSimulatorApplication`, `IMKSimulatorController`, `IMKSimulatorInputClient`, `IMKSimulatorTextView`가 있음. Apple 자체 후보 UI가 Liquid Glass에 쓰는 `IMKUIGlassView`도 있음.
- Apple 한국어 입력기는 비공개 `textDocument` 프록시에 `showsComposingTextAsMarkedText`를 물어서 직접 조합과 조합 문자열 방식 중 하나를 고른다고 함. [REF DKST `InputController+ClientPolicy.m`] 여기서는 그 셀렉터가 `IMKInputController`에 **없어서** 쓸 수 없음.

---

## 2. Info.plist

### 2.1 키 레퍼런스

| 키 | 위치 | 타입 | 의미 / 메모 |
|---|---|---|---|
| `CFBundleIdentifier` | 최상위 | 문자열 | **`.inputmethod.`**이 들어가야 함. 모든 입력기가 따르는 관례이고, TIS가 이것으로 번들을 분류함. 우리 ID는 `com.inkyuoh.inputmethod.Duo`. [REF 튜토리얼; 참고한 모든 입력기] |
| `CFBundlePackageType` | 최상위 | `APPL` | 입력기는 애플리케이션임. |
| `CFBundleName` / `CFBundleDisplayName` | 최상위 | 문자열 | 모드 없는 입력기에서는 **이것이 입력 소스 이름임**. `CFBundleName` = PRODUCT_NAME이라서 TIS가 설치된 Duo를 "DuoInputMethod"로 보여 줌. `InfoPlist.strings`에서 현지화함. [RUNTIME] |
| `NSPrincipalClass` | 최상위 | `NSApplication` | 모든 입력기가 이것을 씀. 서브클래스도 됨. 예: azooKey의 `$(PRODUCT_MODULE_NAME).NSManualApplication`. |
| `LSUIElement` | 최상위 | bool | **이것을 씀.** Apple은 KoreanIM, TCIM, SCIM, AinuIM, TamilIM에 `LSUIElement=1`을 설정함. UI 창과 활성화를 허용함. |
| `LSBackgroundOnly` | 최상위 | bool | 피함. 백그라운드 전용 앱은 활성화가 `.prohibited`됨. Apple 팔레트 입력기 "Assistive Control"만 이것을 씀. 현재 Duo 빌드는 `LSBackgroundOnly=true`를 설정함; **지워야 함**. Fire와 azooKey는 두 키를 모두 설정하고, Squirrel은 `LSBackgroundOnly=false`로 설정함. |
| `LSMinimumSystemVersion` | 최상위 | 문자열 | `26.0` |
| `NSSupportsSuddenTermination` | 최상위 | bool | Apple KoreanIM은 `false`, AinuIM은 `true`를 씀. 종료할 때 학습 저장소가 플러시될 수 있게 `false`를 씀. |
| `InputMethodConnectionName` | 최상위 | 문자열 | Mach/XPC 서비스 이름이며 고유해야 함. Apple의 옛 샘플은 "마침표와 공백은 허용되지 않는다"고 적음. 요즘 Apple 입력기는 이 규칙을 따르지 않음: Ainu는 `com.apple.inputmethod.Ainu.IMK_Connection`, macSKK는 `net.mtgto.inputmethod.macSKK_Connection`을 씀. `$(PRODUCT_BUNDLE_IDENTIFIER)_Connection`을 씀. `IMKServer(name:)`에도 **같은 문자열**을 넘김. |
| `InputMethodServerControllerClass` | 최상위 | 문자열 | 컨트롤러 클래스의 런타임 이름이며 `NSClassFromString`으로 찾음. `@objc(DuoInputController)`를 쓰고 `DuoInputController`라고 적거나, `$(PRODUCT_MODULE_NAME).DuoInputController`라고 적음(Squirrel, azooKey, Fire). |
| `InputMethodServerDelegateClass` | 최상위 | 문자열 | 선택 사항임; AinuIM은 생략함. 대부분의 입력기는 컨트롤러 클래스로 설정함. IMK 상수: `IMKControllerClass`, `IMKDelegateClass`, `IMKModeDictionary`. |
| `InputMethodServerPreferencesWindowControllerClass` | 최상위 | 문자열 | 기본 `showPreferences(_:)`에서만 쓰임. 이 메서드는 `preferences.nib`을 불러옴. 우리에겐 필요 없음. [SDK] |
| `InputMethodType` | 최상위 | 문자열 | `palette`만 있음. 키보드 입력기에서는 생략함. [RUNTIME: CharacterPalette, DictationIM, PressAndHold…] |
| `ComponentInvisibleInSystemUI` | 최상위 | bool | 팔레트 전용임. 헤더에 "키보드 입력기는 항상 보인다"고 적혀 있음. [SDK] |
| `TISInputSourceID` | 최상위 / 모드 | 문자열 | 최상위: 기본값은 번들 ID임. 모드 수준: **부모 ID에 접미사를 붙인 값이어야 함**. Fire는 모드 ID가 번들 ID와 같을 때 추가 목록에서 모드가 빠지는 문제를 겪음. [SDK][REF Fire dev-log 2026-09-23] |
| `TISIntendedLanguage` | 최상위 / 모드 | BCP-47 | `ko`. 이 값 덕분에 추가 시트에서 Duo가 한국어 아래에 놓임. [SDK] |
| `tsInputMethodCharacterRepertoireKey` | 최상위 | [ISO 15924] | `["Hang","Latn"]`. Apple 한국어 입력기는 `["Hang"]`, Gureum은 `["Latn","Kore","Hang"]`, macSKK는 `["Hira","Kana","Latn"]`. |
| `tsInputMethodIconFileKey` | 최상위 | Resources 안의 파일 | 입력기 아이콘이며, 자기 아이콘이 없는 모드도 이것을 씀. [SDK] |
| `tsInputMethodAlternateIconFileKey` | 최상위 | 파일 | 선택 사항인 강조 상태 변형. [SDK] |
| `TISIconIsTemplate` | 최상위 / 모드 | bool | `true`면 시스템이 메뉴 막대, 라이트/다크, 강조 상태에 맞게 아이콘 색을 입힘. Apple은 입력기 11개에 설정함. 문서화되지 않음. [RUNTIME] |
| `TICapsLockLanguageSwitchCapable` | 최상위 / 모드 | bool | `true`이고 사용자가 "Use Caps Lock to switch to and from ABC"(Caps Lock으로 ABC 전환)를 켰다면, 시스템이 Caps Lock을 가져가서 Duo ⇄ ABC를 전환함. Apple 한국어 입력기는 `true`로 설정함. **Duo는 `false`로 시작함**: 전환은 절대 원하지 않고, Caps Lock을 바꾸기 키(flip key) 후보로 비워 둘 수 있음. UX에서 결정함. |
| `TISParticipatesInTouchBar` | 최상위 | bool | Apple 중국어 입력기만 쓰고, Touch Bar는 이제 쓰이지 않음. 생략함. |
| `TISUnifiedUIForInputMethodEnabling` | 최상위 | bool | Apple 중국어·일본어 입력기만 쓰는 비공개 키임. 생략함. |
| `TISDoubleSpaceSubstitution` | 모드 | 문자열 | Apple 한국어 입력기는 `". "`. 이 모드에서 시스템의 "스페이스 두 번으로 마침표 넣기"를 켬. UX에서 원하면 넣음. [RUNTIME] |
| `TISIconLabels` | 모드 | dict | **문서화되지 않음.** Apple 한국어 입력기에는 `{Primary: "한"}`, TCIM에는 `{Primary: "倉頡"}`, Ainu에는 `{CustomIcon: "Ainu@2x.pdf"}`가 있음. macOS 14+ 입력 소스 표시기와 메뉴에서 아이콘의 라벨로 쓰임. 서드파티 지원은 **확인하지 않음**; 확인할 화면 기록(Screen Recording) 권한이 없음. 실제 아이콘과 함께 넣어 배포함. [RUNTIME] |
| `ComponentInputModeDict` | 최상위 | dict | `tsInputModeListKey`(modeID → dict)와 `tsVisibleInputModeOrderedArrayKey`(array)를 담음. 헤더에 따르면 "컴포넌트 번들의 Info.plist에도 있어야" 함. [SDK] |
| `tsInputModeScriptKey` | 모드 | 문자열 | `smKorean`, 또는 Squirrel, Fire, Ainu처럼 `smUnicodeScript`. `smKorean`을 씀. |
| `tsInputModePrimaryInScriptKey` | 모드 | bool | `true`. |
| `tsInputModeIsVisibleKey` | 모드 | bool | `true`. |
| `tsInputModeDefaultStateKey` | 모드 | bool | `true`: 부모가 켜지면 모드도 켜짐. |
| `tsInputModeMenuIconFileKey` / `…AlternateMenuIconFileKey` / `…PaletteIconFileKey` | 모드 | 파일 | 메뉴 막대 아이콘, 강조 아이콘, 팔레트 아이콘. |
| `tsInputModeCharacterRepertoireKey` | 모드 | 배열 | `["Hang","Latn"]`. |
| `tsInputModeKeyEquivalentKey` / `…ModifiersKey` | 모드 | 문자열 / int | 선택 사항인 전환 단축키; TCIM은 `4608` = ⌃⌥(`controlKey`, `optionKey`)를 씀. 생략함. |
| `tsInputModeJISKeyboardShortcutKey` | 모드 | int | JIS 英数·かな 키 전용. 생략함. |

### 2.2 권장 Info.plist (입력기 타깃)

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

모드 없는 빌드라면 `ComponentInputModeDict`를 빼세요. 그러면 입력 소스 ID는 번들 ID가 되고, 타입은 `TISTypeKeyboardInputMethodWithoutModes`가 돼요. 지금 설치된 것이 이 형태예요. [RUNTIME]

`ko.lproj/InfoPlist.strings` / `en.lproj/InfoPlist.strings`:

```
"CFBundleName" = "Duo";
"CFBundleDisplayName" = "Duo";
"com.inkyuoh.inputmethod.Duo.Bilingual" = "Duo 한·영";    /* en: "Duo – Korean & English" */
```

Apple은 `InfoPlist.strings`에서 모드 이름의 키로 **모드 ID**를 써요. 예를 들면 `"com.apple.inputmethod.Korean.2SetKorean" = "두벌식"`이에요. 입력기 이름은 `CFBundleName`("한국어")에서 와요. [RUNTIME: KIM_Extension InfoPlist.loctable]

### 2.3 메뉴 막대 아이콘

- Apple의 형식은 **다중 표현 TIFF**임: 72 dpi의 16×16 px와 144 dpi의 32×32 px를 한 파일에 담음(`2SetKorean.tiff`, `Ainu.tiff`). `tiffutil -info`로 측정함. [RUNTIME]
- PNG로 만듦: `tiffutil -cathidpicheck DuoMenuIcon.png DuoMenuIcon@2x.png -out DuoMenuIcon.tiff`.
- PDF도 됨. Squirrel과 Fire는 `tsInputModeMenuIconFileKey`에 `rime.pdf`/`fire.pdf`를 씀; Ainu는 `TISIconLabels.CustomIcon`이 `Ainu@2x.pdf`를 가리킴.
- 투명 픽셀 위에 순수한 검정 글리프를 그리고 `TISIconIsTemplate=true`를 설정함. 그러면 시스템이 라이트, 다크, 강조 상태를 처리함.
- 글리프는 약 16×16 pt 안에 두고 여백은 1 pt 정도로 둠. Apple의 새 라벨은 둥근 사각형 안의 텍스트이며, `TISIconLabels.Primary`가 이것을 그림.
- 현재 설치된 Duo에 대해 `kTISPropertyIconImageURL`은 `MenuIcon.tiff`를 알려 줌. [RUNTIME]
- 이름은 메뉴 막대 드롭다운과 시스템 설정 → 키보드 → 텍스트 입력 → 입력 소스에 나옴. 모드 없는 입력기에서는 `CFBundleName`이, 모드가 있으면 `InfoPlist.strings`의 모드 ID 문자열이 이름이 됨.
- macOS 14+는 포커스를 받거나 전환할 때 캐럿 옆에 작은 입력 소스 표시 말풍선도 보여 줌. 아이콘이나 라벨을 씀. 사용자는 `defaults write kCFPreferencesAnyApplication TSMLanguageIndicatorEnabled 0`으로 끌 수 있음. Duo가 자체 캐럿 HUD를 그린다면 이 점을 염두에 둠. [REF]

### 2.4 모드 하나, 아니면 모드 없음?

- **모드를 둘 때** (Apple의 단일 모드 Ainu, Squirrel, macSKK, Gureum 방식):
  - 모드 수준의 `TISIconLabels`, `tsInputModeScriptKey`, 현지화된 모드 이름을 얻음. "한국어 전용" 같은 나중 모드를 넣을 여지도 생김.
  - 부모 `com.inkyuoh.inputmethod.Duo`는 `TISTypeKeyboardInputMethodModeEnabled`가 됨. 부모는 선택할 수 없고 모드만 선택할 수 있음.
  - 설치 프로그램은 부모를 켜고, 모드를 켜고, 모드를 선택해야 함.
- **모드 없이**: 더 단순하고 이미 동작함. 선택 가능한 ID는 번들 ID임.
- 나중에 바꾸면 호환성이 깨지는 변경임. 사용자가 입력 소스를 다시 추가해야 하기 때문임.
- **권장:** 지금 모드 하나로 감(D2).

---

## 3. 설치, 등록, 켜기, 다시 불러오기, 서명

### 3.1 위치와 등록

- 사용자별: `~/Library/Input Methods/Duo.app`(root 필요 없음). 시스템 전체: `/Library/Input Methods/`.
- `TISRegisterInputSource(CFURL)`는 이 두 디렉터리의 번들을 "등록하는 데만 쓸 수 있음". 빌드 산출물 경로가 아니라 **최종 설치 경로**를 등록함. [SDK]
- 지금 이 기기의 상태:
  - `~/Library/Input Methods/DuoInputMethod.app`은 실제 디렉터리이고 ad-hoc 서명됨.
  - TIS는 `com.inkyuoh.inputmethod.Duo`를 `InputMethodWithoutModes`이자 켜진 상태로 보여 줌.
  - `com.apple.HIToolbox AppleEnabledInputSources`에 `{ "Bundle ID" = "com.inkyuoh.inputmethod.Duo"; InputSourceKind = "Keyboard Input Method"; }`가 들어 있음.
  - `~/Library/Input Methods/DuoInputMethod.app/Contents/MacOS/DuoInputMethod` 프로세스가 실행 중임.
  - 따라서 등록, 켜기, 실행에 로그아웃이 필요 없었음. [RUNTIME]
- 심볼릭 링크도 됨. Amazon Q는 `~/Library/Input Methods/CodeWhispererInputMethod.app`을 심볼릭 링크로 설치함. 다만 지금은 링크 대상이 없음.

### 3.2 켜기와 선택 (Swift 6, `-default-isolation MainActor`에서 컴파일과 실행을 확인함)

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

- 모드 입력기의 순서: `TISRegisterInputSource(url)` → 부모 ID 켜기 → 모드 ID 켜기 → 모드 ID 선택. 모드와 부모가 둘 다 켜져 있지 않으면 선택이 실패함. [SDK]
- 변경은 `DistributedNotificationCenter.default().addObserver(…, name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), …, suspensionBehavior: .deliverImmediately)`로 감시함. `kTISNotifyEnabledKeyboardInputSourcesChanged`는 켜기/끄기 변경을 알려 줌. [REF Fire]
- `kTISPropertyInputSourceIsEnabled`는 믿을 수 없음:
  - `TISEnableInputSource` 뒤에도 **호출한 프로세스 안에서는 갱신되지 않음**. [REF Fire `InputSource.swift`]
  - macOS 12+에서는 사용자가 입력 소스를 지운 뒤에도 `true`로 남을 수 있음. 그래서 vChewing은 조건 없이 켬. [REF vChewing]
- **확인 창** (보고된 내용이며 여기서 확인하지 않음):
  - macOS 12부터는 서드파티 입력기에 대해 `TISRegisterInputSource`나 `TISEnableInputSource`가 실행되는 순간, 시스템 설정에서 허용할지 묻는 확인 창이 사용자에게 뜸. [REF vChewing 커밋 "Fix IME activation issues on macOS 12"]
  - Fire 코드의 설명: "켜면 시스템 설정이 열리고 확인을 요청함. 사용자가 확인한 뒤에야 입력기를 선택할 수 있음. 이미 켜져 있으면 다시 켜지 말 것. 그러지 않으면 대화상자가 반복됨."
  - 우리 Duo는 오늘 켜졌음. 대화상자가 떴는지는 모름. 사용자가 한 번 클릭해야 한다고 보고 계획함.
  - UI 조작이 불가능할 때의 대안: `com.apple.HIToolbox`의 `AppleEnabledInputSources`에 직접 씀. 지원되지 않는 방법이고, TIS 서버가 다시 읽은 뒤에야 반영되며, 로그아웃이 필요할 수도 있음. [INFERRED]
- 입력기는 아래를 쓰지 **않는** 한 손쉬운 사용(Accessibility), 입력 모니터링(Input Monitoring), 화면 기록(Screen Recording) 권한이 전혀 필요 없음:
  - `IOHIDManager`: Gureum이 Caps Lock과 오른쪽 ⌘에 씀. 입력 모니터링 확인 창을 띄움.
  - `CGEventTap`이나 `CGEventPost`.
  - `AXUIElement`.

### 3.3 로그아웃과 새로 고침

- Apple DTS(포럼 스레드 775526, 2026년 6월): "사용자가 로그오프하지 않으면 시스템 설정이 더 이상 새 입력 소스를 인식하지 않는다. 로그오프를 피할 방법은 보이지 않는다." 이 문제는 시스템 설정 목록과 추가 시트에만 영향을 줌. TIS를 통한 켜기와 선택은 여전히 바로 동작함. [REF]
- `killall TextInputMenuAgent`로 **메뉴 막대 목록을 새로 고친** 뒤, 켜기 전에 약 0.5 s 기다림. **`imklaunchagent`는 절대 죽이지 않음**: 죽이면 실행 중인 모든 클라이언트는 재시작할 때까지 모든 입력기와 연결이 끊김. [REF vChewing `InstallerVMProtocol.swift`]
- **재설치 후 다시 불러오기:**
  1. `ditto build/Duo.app ~/Library/Input\ Methods/Duo.app`로 새 번들을 덮어 복사함.
  2. `killall DuoInputMethod`(또는 실행 파일 이름)를 실행함. 실행 중인 입력기는 종료될 때까지 옛 코드를 그대로 씀.
  3. Duo가 선택된 상태에서 다음에 텍스트 필드에 포커스가 가면, `imklaunchagent`가 필요할 때 입력기를 다시 띄움.
  4. `Info.plist`가 바뀌었다면(모드, 아이콘, 이름) `TISRegisterInputSource(url)`를 다시 호출하고 `killall TextInputMenuAgent`를 실행함. 일부 캐시는 로그아웃할 때까지 남을 수 있음.
  - vChewing은 번들을 바꾼 *뒤에* 옛 인스턴스를 종료함. 그래야 다시 뜨는 것이 새 코드임.
- 깔끔한 개발 루프:
  ```sh
  xcodebuild … && ditto "$PRODUCTS/Duo.app" "$HOME/Library/Input Methods/Duo.app" \
    && killall -q DuoInputMethod; killall -q TextInputMenuAgent
  ```
  로그(TCC 필요 없음): `log stream --style compact --predicate 'subsystem == "com.inkyuoh.inputmethod.Duo"'`.

### 3.4 코드 서명, hardened runtime, 샌드박스

- **ad-hoc 서명으로 충분함.** 설치된 Duo는 `Signature=adhoc`, `TeamIdentifier=not set`이고, 등록, 켜기, 실행, 세션 수신이 모두 됨. 로컬에서 빌드한 번들에는 격리(quarantine) 속성이 없어서 Gatekeeper가 막지 않음. [RUNTIME]
  - DKST도 테스트 빌드를 ad-hoc으로 배포함. [REF]
- **키체인 인증서는 의심스러움.** `security find-identity -v -p codesigning`은 `"Apple Development: Inkyu Oh (4MRK2Z3J94)" (CSSMERR_TP_CERT_REVOKED)`를 보여 줌. 인증서 subject는 `OU=DKZ2M6YKUP`이고 2027-07-22까지 유효함. [RUNTIME]
  - **Team ID는 DKZ2M6YKUP**임. `4MRK2Z3J94`는 CN 접미사일 뿐임.
  - 인증서가 폐기됨으로 나오므로, 이것으로 서명하면 AMFI나 launchd가 거부하는 바이너리가 나올 수 있음.
  - **`CODE_SIGN_IDENTITY="-"`, `CODE_SIGN_STYLE=Manual`, `DEVELOPMENT_TEAM=""`을 씀.**
- hardened runtime은 로컬 사용에는 필요 없음; 나중에 공증(notarization)할 때 필요함. 켠 상태에서 `com.apple.security.cs.disable-library-validation`은 서명 안 된 플러그인을 불러올 때만 필요함(Squirrel이 그렇게 함). ad-hoc과 hardened runtime을 함께 써도 동작함.
- **샌드박스**는 선택 사항임. 켠다면 아래를 추가함:
  ```xml
  <key>com.apple.security.temporary-exception.mach-register.global-name</key>
  <string>com.inkyuoh.inputmethod.Duo_Connection</string>
  ```
  연결 이름을 정확히 그대로 씀. macSKK와 azooKey는 이 방식으로 샌드박스를 켠 채 배포하고, 설정 앱과 상태를 공유할 때 `com.apple.security.application-groups`를 씀. v1 권장: 샌드박스 없음. 설정은 `UserDefaults(suiteName: "com.inkyuoh.inputmethod.Duo")`나 Application Support 파일로 공유하고, 변경은 `DistributedNotificationCenter` post로 알림.
- **Xcode 디버그 dylib.** 현재 설치본에는 `MacOS/DuoInputMethod.debug.dylib`와 `__preview.dylib`가 있음(Debug에서는 `ENABLE_DEBUG_DYLIB` 기본값이 YES). 동작은 하지만, 입력기 타깃에 `ENABLE_DEBUG_DYLIB = NO`와 `ENABLE_PREVIEWS = NO`를 설정함. 그러면 Mach-O가 하나가 되고, `killall`과 크래시 로그가 단순해지고, 시스템이 띄우는 프로세스에 프리뷰 스텁이 들어가지 않음. [RUNTIME][INFERRED]

---

## 4. Swift 6에서 IMKInputController 쓰기

### 4.1 main.swift (최상위 코드는 MainActor)

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

- `IMKServer(name:bundleIdentifier:)`는 `Info.plist`에서 컨트롤러와 델리게이트 클래스 이름을 읽은 뒤 연결을 등록함. [SDK]
- **클라이언트 입력 세션마다 컨트롤러가 하나씩 생김**. 즉 앱마다, 텍스트 뷰나 필드마다 하나씩임. 컨트롤러는 많고 수명이 짧음. 엔진, 학습 저장소, 패널은 **공유 싱글턴**에 둠. 컨트롤러는 얇게 유지하고, 클라이언트 프록시를 오래 강하게 참조하지 않음.
  - vChewing은 Swift가 XPC 클라이언트 프록시를 retain하지 않도록 클라이언트 호출을 ObjC MRC로 옮기기까지 함. [REF]
  - azooKey는 보이지 않는 창 약 80개를 누수했고, 이 때문에 WindowServer에 부하가 걸려 창 드래그가 망가짐. 재사용하는 패널을 **하나만** 만듦. [REF azooKey #348]

### 4.2 어떤 입력 진입점을 쓸지

- IMK는 서로 배타적인 세 가지 방식을 제공함: 키 바인딩(`inputText(_:client:)`와 `didCommand(by:client:)`), 풀어 쓴 키(`inputText(_:key:modifiers:client:)`), 원시 이벤트(`handle(_:client:)`). **`handle(_:client:)`를 씀**: `.flagsChanged`와 마우스 이벤트까지 전달하는 유일한 방식임. [SDK]
- Duo가 이벤트를 소비하면 `true`를 반환함. 앱이 처리하게 하려면 `false`를 반환함. 단어를 끝내는 키라면 **`false`를 반환하기 전에 항상 대기 중인 텍스트를 확정함**.
- `event`는 `nil`일 수 있음(예: 문자 뷰어에서 올 때). guard로 막음. [REF macSKK]
- **`recognizedEvents(_:)`**:
  - 기본값: `NSEvent.EventTypeMask.keyDown`(1024). 이 기본값이면 사용자가 조합 밖의 텍스트를 클릭할 때 IMK가 스스로 확정함. [SDK][RUNTIME]
  - Shift 탭이나 오른쪽 ⌘ 바꾸기 키 같은 수정 키 탭을 보려면 `Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown]).rawValue)`를 반환함.
  - **이렇게 하면 IMK의 자동 클릭 시 확정이 더 이상 돌지 않음.** Gureum처럼 `handle`에서 `.leftMouseDown`을 받을 때 확정함. `.flagsChanged`는 "`handleEvent:`로만 동작함". [REF Gureum `InputReceiver.swift`]
- 수정 키 다루기 원칙:
  - `.deviceIndependentFlagsMask`로 마스킹함.
  - 화살표 키에는 `.numericPad`와 `.function`이 붙음. 한글로 매핑할 때는 `.capsLock`을 무시함.
  - ⌘와 ⌃ 조합은 **확정한 뒤에** 그대로 넘김. 그러지 않으면 ⌘A, ⌘X, Enter가 마지막 음절이 빠진 텍스트에 적용됨(Gureum #924, #180).
  - Option 조합도 확정한 뒤 넘김.
- **자동 반복:** `event.isARepeat`. 반복 입력은 일반 키 입력처럼 다루되, 비싼 작업은 줄임: 단어 점수 재계산은 프레임당 최대 한 번. 백스페이스 자동 반복은 자모를 지우고, 이어서 글자를 지우고, 버퍼가 비면 그대로 넘겨야 함.
- **키보드 레이아웃:**
  - 입력기가 선택되면, 입력기가 `TISSetInputMethodKeyboardLayoutOverride`나 `client.overrideKeyboard(withKeyboardNamed:)`를 호출하지 않는 한 TSM은 "가장 최근에 쓴 ASCII 가능 키보드 레이아웃"으로 이벤트를 변환함. [SDK]
  - Duo에서는 물리적인 두벌식 위치(`HIToolbox/Events.h`의 `kVK_ANSI_*`)를 기준으로 **`event.keyCode`에서 한글 자모를** 얻음.
  - **라틴 문자는 `event.characters`에서** 얻음. 그러면 Dvorak으로 영어를 치는 사용자도 존중함.
  - 키 입력마다 둘 다 저장함. 라틴 문자에 QWERTY를 강제하고 싶은 게 아니라면 키보드를 오버라이드하지 않음; Gureum은 강제함.

### 4.3 생명 주기 콜백

| 콜백 | 시점 | Duo 동작 |
|---|---|---|
| `init(server:delegate:client:)` | 새 클라이언트 세션. 참고: 옛 OS에서는 init 중에 `client()`가 nil일 수 있음; `inputClient` 매개변수를 씀. [REF vChewing] | `bundleIdentifier()`를 한 번만 캐시하고(XPC 왕복이므로) 클라이언트 정책을 계산함(6절). |
| `activateServer(_:)` | 이 클라이언트에서 Duo가 활성화됨: 포커스가 오거나 Duo가 선택됨. | 상태를 초기화함. 아무것도 보여 주지 않음. 첫 키 입력이 활성화와 경쟁하므로 빠르게 끝냄. `super`를 호출함. |
| `deactivateServer(_:)` | 포커스가 떠나거나, 앱이 바뀌거나, 메뉴로 입력기를 바꿈. | `commitComposition(sender)`, 패널 숨기기, `super` 호출. 다른 프로세스의 `TISSelectInputSource`에 대해서는 **macOS 26에서 불리지 않음**. `kTISNotifySelectedKeyboardInputSourceChanged` 옵저버에서도 확정함. [REF squirrel #1140/#1142] |
| `commitComposition(_:)` | 클라이언트가 지금 끝내라고 요청함. 예: 클릭, 코드로 바꾼 포커스. | `client.insertText(buffer, replacementRange: notFound)`를 **동기로** 호출한 뒤 비움. 버퍼가 비었으면 호출하지 않음. |
| `cancelComposition()` | 직접 구현한 Esc 처리. 기본 구현은 `originalString`을 삽입함. | `client.setMarkedText("", …)` 호출 후 비우는 쪽을 권장함. |
| `inputControllerWillClose()` | 세션 종료(10.7+). | 확정하거나 플러시하고, 참조를 버림. |
| `hidePalettes()` | 시스템이 UI를 숨기라고 요청함. | 패널을 숨김. |
| `menu()` | 텍스트 입력 메뉴를 그리기 직전. | `NSMenu`를 반환함. 하위 메뉴는 무시됨. [REF macSKK] 액션 메서드는 정보 딕셔너리를 받음: `sender[kIMKCommandMenuItemName]`은 `NSMenuItem`, `sender[kIMKCommandClientName]`은 클라이언트임. |
| `setValue(_:forTag:client:)` | 모드 변경: `tag == kTextServiceInputModePropertyTag`, `value` = 모드 ID 문자열. | 모드를 저장함. 바뀌면 확정함. |
| `showPreferences(_:)` | 액션이 `showPreferences:`인 "환경설정…"(Preferences…) 항목. | 설정 앱을 띄움. |
| `composedString(_:)` / `originalString(_:)` | IMK 자체의 `updateComposition()`과 `cancelComposition()`이 씀. | `setMarkedText`를 직접 다루더라도, 안전을 위해 현재 버퍼와 원시 키를 반환함. |

### 4.4 조합 다루기

```swift
let notFound = NSRange(location: NSNotFound, length: NSNotFound)
// show/update the word buffer (marked text); caret at end; one clause, plain underline
let s = NSAttributedString(string: display, attributes: mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: display.utf16.count)) as? [NSAttributedString.Key: Any] ?? [:])
client.setMarkedText(s, selectionRange: NSRange(location: display.utf16.count, length: 0), replacementRange: notFound)
// commit
client.insertText(committed, replacementRange: notFound)
```

- `selectionRange`는 조합 문자열 기준임. `replacementRange`는 **문서 기준**임. `{NSNotFound, …}`는 현재 선택 영역이나 조합 범위를 뜻함. [SDK]
- Chromium에서는 `selectionRange.length == 0`을 유지하고, 선택되지 않은 절 하나만 씀. 조합 안의 선택 범위나 선택 스타일이 "파란 상자" 강조의 유력한 원인임. [REF Gureum #880]
- **Chromium 웹 콘텐츠는 키 이벤트 하나를 처리하는 동안 보낸 `setMarkedText` 중 *마지막* 것만 적용함.** 키 이벤트마다 `setMarkedText`를 정확히 하나만 보냄. [REF macSKK `InputController.swift`]
- 조합 중인 것이 없을 때는 `insertText("")`나 `setMarkedText("")`를 절대 보내지 않음. 선택 영역을 덮어씀. Office에서 Shift+화살표로 선택한 텍스트가 이렇게 사라짐. [REF Gureum #3]

### 4.5 떠 있는 패널을 위한 캐럿 사각형

```swift
var rect = NSRect.zero
_ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect) // screen coords, Cocoa (bottom-left origin), width≈1, height=line height
// alternative: client.firstRect(forCharacterRange: client.markedRange(), actualRange: nil)
let level = NSWindow.Level(rawValue: Int(client.windowLevel()) + 1)        // place panel above the client window
```

- `index`는 인라인 세션 기준이고, 0은 조합이나 선택 영역의 시작임. 0이 아닌 인덱스는 가끔 실패함. [SDK][REF macSKK]
- 어떤 클라이언트는 `.zero`를 반환함. 마지막으로 얻은 정상 사각형을 쓰거나, 패널을 보여 주지 않음.
- 알맞은 디스플레이에 머물도록 `NSScreen.screens.first { $0.frame.contains(rect.origin) }`를 씀. azooKey는 여기서 다중 디스플레이 버그를 낸 적이 있음. [REF azooKey #322]
- 패널 레시피 [INFERRED, 입력기의 일반적인 관행]:
  - `NSPanel(styleMask: [.borderless, .nonactivatingPanel])`
  - `isFloatingPanel = true`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, `false`를 반환하는 `canBecomeKey` 오버라이드
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`
  - `level` = 클라이언트 레벨 + 1
  - macOS 26에서는 콘텐츠를 `NSGlassEffectView`에 넣음.

### 4.6 클라이언트 식별과 보안 입력

- `client.bundleIdentifier()`는 nil일 수 있음(예: Android 에뮬레이터). 클라이언트 객체마다 캐시함: XPC 왕복이고, 포커스는 클라이언트 사이를 오감. [REF macSKK, DKST]
- **암호 필드:**
  - `NSSecureTextField`와 웹 암호 필드는 컨텍스트를 로마자 입력 소스로 제한함(`NSTextInputContext.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]`). TSM은 ASCII 레이아웃으로 바꾸고, Duo는 ASCII 가능 입력 소스가 아니므로 **Duo는 호출되지 않음**. [SDK][INFERRED]
    - **[2026-11-09 확인함]** Duo는 ASCII 가능 입력 소스임(critique V2). 그래도 보안 입력이 켜지면 macOS가 Duo를 끄고 입력 메뉴에서 흐리게 보여 줌. 같은 때 2-Set Korean(ASCII 불가)은 고를 수 있었음. 막는 기준은 ASCII 가능 여부가 아님
  - 다층 방어: 활성화될 때마다, 그리고 첫 키마다 `IsSecureEventInputEnabled()`(Carbon, `CarbonEventsCore.h`)를 확인함. true를 반환하면 모든 입력을 그대로 넘기고 **학습 저장소에 절대 넣지 않음**.
  - 클라이언트 래퍼는 비공개 `isSecureMode`에도 응답함; `responds(to:)`로 확인함.
  - `IsSecureEventInputEnabled()`는 전역 값이라 Terminal의 "Secure Keyboard Entry"(보안 키보드 입력)를 켜도 true가 됨. 처음에는 개인정보 보호 쪽으로 보수적인 동작이라 괜찮다고 보았음. **[2026-11-09 확인함]** 실제로는 보안 입력을 쥔 앱이 뒤에 있어도 모든 앱에서 Duo를 쓸 수 없음. 쥔 프로세스는 레지스트리 루트 `IOConsoleUsers`의 `kCGSSessionSecureInputPID`에 있음(비공개 키).
- **검색 필드**(Spotlight, Finder, Alfred, Raycast, Safari 주소 막대)는 확정 전까지 조합 문자열로 검색하지 않음. Gureum #180에서는 검색 결과가 "마지막 음절이 빠진" 상태로 나옴. 비공개 `isIncrementalSearchInputContext`로 이런 필드를 감지함. 정책은 6절 참고.

### 4.7 마우스와 포커스

- 클라이언트 안의 클릭은 (우리 마스크에서) `handle()`에 `.leftMouseDown`으로 오거나, `mouseDown(onCharacterIndex:…)`로 옴. 확정하고 `false`를 반환해서 클릭이 계속 캐럿을 옮기게 함. [REF Gureum]
- 같은 앱 안에서 포커스가 바뀌면 옛 컨트롤러에 `commitComposition`이나 `deactivateServer`, 또는 둘 다 불림. 새 필드에는 새 컨트롤러나 세션이 생김.
- macOS 26에서 코드로 입력 소스를 바꾸면 둘 다 불리지 않으므로, TIS 알림에 기댐(D7).
- 코드로 입력기*로* 전환하면 포커스가 옮겨질 때까지 컨트롤러가 활성화되지 않을 수 있음. 그동안 키는 가공 없이 그대로 통과함. [REF squirrel #1162]

### 4.8 macOS 26/27의 시스템 오버레이

위젯 갤러리, 알림 센터 같은 시스템 오버레이는 레거시 IMK 입력 컨텍스트를 약 150 ms 안에 폐기해요. Apple의 확장 기반 입력기는 거기서도 동작해요. 플랫폼 한계이니 알려진 문제로 문서에 남기세요. [REF squirrel #1196]

### 4.9 Swift 6 엄격한 동시성: 테스트한 사실과 동작하는 패턴 [VERIFIED, Swift 6.4.2 / SDK 27.2]

테스트한 내용:

- **`-typecheck`는 region isolation 검사를 돌리지 않음.** "sending 'self' risks causing data races" 같은 오류는 전체 컴파일(`-c`나 빌드)에서만 나옴. 항상 빌드함.
- IMK API는 `Sendable` 없이 **nonisolated**로 들어옴. `NSMenu`는 Sendable이 아니고, `client` 매개변수는 `Any!`임.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`(Xcode 26+ 템플릿 기본값)에서는 평범한 `class X: IMKInputController`가 다음 오류로 실패함: `main actor-isolated initializer 'init(server:delegate:client:)' has different actor isolation from nonisolated overridden declaration`. `handle`, `recognizedEvents`, `commitComposition`, 암시적 `init()`에서도 같은 오류가 남.
- 오버라이드에 `@MainActor`를 붙여도 같은 오류로 실패함.
- 클래스를 `nonisolated`로 만들고 `MainActor.assumeIsolated { … }` 안에서 `self`, `event`, `client`를 캡처하면 `sending 'self'/'event'/'client' risks causing data races`로 실패함. 두 가지 격리 기본값 모두에서 전체 컴파일 때 나는 오류임.
- **아래 패턴은 Swift 6 모드에서 경고 0개로 빌드됨.** 설정 세 가지에서 확인함: 기본 `nonisolated`, `-default-isolation MainActor`, 그리고 `NonisolatedNonsendingByDefault`와 `InferIsolatedConformances`를 함께 켠 경우.
- 목(mock) 클라이언트에서 올바르게 실행됨: "gk"가 `{0,2}` 범위의 조합 문자열이 된 뒤 스페이스로 확정됐고, 메뉴도 항목을 반환함. macSKK의 패턴임(macSKK는 `SWIFT_VERSION = 6.0`을 설정함). [REF macSKK `InputController.swift`]

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

대안:
- vChewing(Swift 6.4, 기본 MainActor 격리)은 ObjC 오버레이 헤더 `IMKSwift.h`를 함께 배포함. 이 헤더는 `#pragma clang attribute push(__attribute__((swift_attr("@MainActor"))), apply_to = any(objc_method, objc_property))` 아래에서 nullability를 더해 IMK를 다시 선언함. Swift가 서브클래싱할 ObjC 서브클래스 `IMKInputSessionController`도 제공함. 호출하는 쪽 코드는 깔끔해지지만 ObjC 타깃이 하나 늘고, 일부는 비공개 IMK 내부를 건드림. [REF] **Duo에는 필요 없음.**
- Squirrel은 `SWIFT_VERSION = 5.0`과 `SWIFT_STRICT_CONCURRENCY = targeted`로 문제를 피함. 우리 기준에는 못 미침.

---

## 5. 이미 확정한 텍스트 바꾸기 ("방금 확정한 단어 바꾸기")

### 5.1 동작 원리

- `insertText(_:replacementRange:)`와 `setMarkedText(_:selectionRange:replacementRange:)`는 **문서 기준** `replacementRange`를 받음.
- `selectedRange()`는 현재 선택 영역을 반환하며, 이것도 문서 기준임. `{NSNotFound, NSNotFound}`는 클라이언트가 TSM 문서 접근을 지원하지 않는다는 뜻이고, 이때 대체 범위는 **무시됨**: 텍스트가 캐럿 위치에 삽입되어 중복됨. [SDK]
- 무엇이든 바꾸기 전에 `attributedSubstring(from:)`이나 `string(from:actualRange:)`로 범위를 검증함. 문서 접근이 없는 클라이언트에서는 둘 다 nil이나 엉뚱한 값을 반환함.
- Apple 자체 한국어 입력기는 macOS 26에서 대체(replacement)에 의존함. 평범한 `NSTextView`에서는 **조합 문자열 없이** 조합함: "ㅎ→하→한→한ㄱ→한그→한글"이 대체로 쌓이는 동안 `hasMarkedText()`가 계속 false였음. 필요한 클라이언트에서는 조합 문자열로 바꿈. [RUNTIME][REF DKST]

### 5.2 알고리즘 (macSKK `kakuteiUndo`와 `fixedTextRange` 이식)

1. **확정할 때** 먼저 텍스트를 기록함: `lastCommit = (text: committedWord + boundary, location: markedRange().location ?? selectedRange().location before insert, rawKeys, alternateInterpretation)`.
   - 경계 문자(스페이스나 문장 부호)도 기록에 포함함. NSTextView는 캐럿을 삽입한 텍스트 뒤에 두므로, 대체 범위가 단어만 덮으면 캐럿이 스페이스 앞으로 되돌아감.
2. **버퍼가 빈 상태에서 바꾸기 키를 누르면:**
   - `sel = client.selectedRange()`. `sel.location != NSNotFound && sel.length == 0`을 요구함. 선택 영역이 비어 있지 않으면 되돌리기가 아니라 재변환을 뜻함.
   - 후보 위치는 순서대로 `lastCommit.location`, 그다음 `sel.location - len(lastCommit.text)`. 기억한 위치를 우선하고, 안 되면 캐럿 바로 앞 텍스트로 물러남.
   - 각 위치 `l ≥ 0`에 대해 `client.attributedSubstring(from: NSRange(l, len))?.string == lastCommit.text`일 때만 받아들임.
3. **대체:**
   - 방법 A, 다시 조합으로 열기(macSKK): `client.setMarkedText(flipped, selectionRange: NSRange(location: flippedLen, length: 0), replacementRange: r)`. 단어가 다시 편집 가능한 조합 문자열이 되고, 두 번째 바꾸기는 공짜로 되며, 다음 경계에서 `insertText(_, notFound)`로 확정됨. 범위는 **첫 번째** `setMarkedText`에만 지정하고, 이후에는 `notFound`를 씀. 키 이벤트마다 `setMarkedText`는 **하나만** 보냄(Chromium).
   - 방법 B, 바로 대체: `client.insertText(flipped + boundary, replacementRange: r)`. 더 단순하지만, 다시 기록하지 않으면 한 번 더 바꿔서 되돌릴 수 없음.
4. 바꾸기에 성공하면 그 수정을 학습기에 넣음. 캐럿 이동, 클릭, 다른 키가 오면 `lastCommit`을 무효화함.

### 5.3 클라이언트 지원 표

| 클라이언트 | 대체 지원 | 출처 | 정책 |
|---|---|---|---|
| Cocoa `NSTextView`/`NSTextField`(TextEdit, Notes, Mail, Xcode 편집기 등) | 전체 지원 | [SDK]; `NSTextView`로 테스트함 | `.full` |
| WebKit / Safari (`com.apple.Safari`, `com.apple.WebKit.*`) | 전체 지원; DKST는 WebKit에서 "직접 조합 범위를 신뢰함" | [REF DKST] | `.full`. 단, WebKit에서는 성급한 키보드 오버라이드를 피함 |
| Chromium (Chrome, Edge, Brave, Arc `company.thebrowser.Browser`, Whale `com.naver.Whale`, Vivaldi, Opera) | 동작함; macSKK 기본값 `.full`이 Chrome을 포함함. 특이점: 키 이벤트마다 마지막 `setMarkedText`만 적용됨 | [REF macSKK] | `.full`과 이벤트당 `setMarkedText` 하나 |
| Electron (VS Code `com.microsoft.VSCode`, Slack, Notion, Discord…) | Chromium과 같음(VS Code는 숨은 textarea를 씀). `Contents/Frameworks/Electron Framework.framework`로 감지함 | [REF DKST 감지 방식]; 지원 여부는 [INFERRED] | `.full`, `attributedSubstring`으로 검증함 |
| Terminal.app (`com.apple.Terminal`) | **캐럿 앞만 지원**: 다른 범위는 무시됨 | [REF macSKK `ReplacementRangeSupport`] | `.beforeCaretOnly` |
| iTerm2 (`com.googlecode.iterm2`), Hyper (`co.zeit.hyper`) | **미지원**: 조합 문자열을 항상 커서 위치에 그림; 위치를 화면 셀 단위로 셈 | [REF macSKK] | `.unsupported` |
| Java/JetBrains (IntelliJ `com.jetbrains.*`, Android Studio `com.google.android.studio`, 모든 JBR 앱) | **미지원**: `AWTView.insertText`가 `replacementRange`를 무시함(JDK-8257650). JDK-8195675(2024) 전까지는 조합 문자열 없이 보낸 짧은 insertText 단일 호출이 버려졌음 | [REF OpenJDK] | `.unsupported`; 또한 `insertText(x)` 전에 항상 `setMarkedText(x)` |
| Microsoft Office | 알 수 없음. 예전부터 불안정했음(선택 영역 손실, Excel 입력) | [REF Gureum #3, #237] | 먼저 검증; 일치하지 않으면 거부 |
| 알 수 없는 클라이언트 | 먼저 검증 | | `attributedSubstring` 확인이 성공할 때만 `.full` |

대체를 지원하지 않을 때의 **대안**: 입력기는 손쉬운 사용 권한 없이는 클라이언트에 백스페이스를 보낼 수 없어요(`CGEventPost`에는 TCC가 필요해요). 그래서 둘 중 하나를 골라요:
- 눈에 띄지 않는 HUD를 보여 줌("이 앱에서는 되돌리기를 지원하지 않아요"), 또는
- 그런 앱에서 확정을 늦추는 앱별 설정을 둠.

확인 없이 대체하지 마세요. 그런 클라이언트에서는 중복 삽입이 돼요.

---

## 6. 호환성 함정과 대응

| 함정 | 원인 | 대응 |
|---|---|---|
| 웹 채팅 앱과 검색 막대에서 **Enter가 마지막 음절을 잃거나 중복함**; Terminal이 Return을 삼킴 | Gureum의 Terminal 버그: 입력기가 확정하면서 Return을 *소비함*(#1). 조합 중에 `keydown` Enter를 처리하는 웹 페이지(`isComposing`/`keyCode 229`)는 자기 핸들러가 돈 뒤에야 확정을 봄. | Return, Tab, Esc, 화살표, ⌘/⌃ 조합, 기능 키에서는 **먼저 `insertText`로 확정한 뒤 `false`를 반환함**. 그러면 앱이 `compositionend` 뒤에 진짜 키를 받음. "\n"을 직접 삽입하지 않음. |
| ⌘A, ⌘X, 검색이 확정을 보지 못함(Finder, Alfred, Spotlight가 "구름입력"을 마지막 음절 없이 검색함) | 단축키가 실행되거나 검색이 필드를 읽을 때 텍스트가 아직 조합 중임. [REF Gureum #924, #180] | 수정 키 조합을 넘기기 전에 확정함. 검색 컨텍스트(`isIncrementalSearchInputContext`, 또는 번들 ID `com.apple.Spotlight`, `com.runningwithcrayons.Alfred`, `com.raycast.macos`)에서는 키 입력마다 확정하는 방식("직접 모드", 아래 참고)을 고려함. |
| 조합 중인 텍스트 위의 Chromium "파란 상자" | 조합 문자열 안의 선택 범위나 선택된 절 스타일. [REF Gureum #880] | `selectionRange = (len, 0)`, 절 하나, `kTSMHiliteConvertedText`(밑줄 한 줄)나 raw 스타일. |
| Chromium/Electron 조합 타이밍 버그; 실행 직후 첫 글자가 자모나 라틴 문자로 쪼개짐 | 웹 뷰와 입력기의 런 루프가 비동기로 동기화됨; 첫 포커스는 분류하기 어려움. [REF DKST] | `handle` 안에서 동기로 `setMarkedText`. 실행할 때 엔진을 미리 데움. 키 이벤트당 `setMarkedText` 하나. |
| **iTerm2에서 첫 글자가 두 번 찍힘** | iTerm2는 `handle`이 `true`를 반환한 직후 조합 문자열을 확인함. [REF azooKey #357] | `true`를 반환하기 전에 항상 조합 문자열을 설정함(또는 삽입함). 비동기 작업으로 미루지 않음. |
| JetBrains/Java: 확정한 짧은 문자열이 버려짐, Shift+Space가 스페이스를 넣음, 조합이 이상함 | AWT는 조합 문자열 없는 짧은 `insertText`를 무시하고, `replacementRange`도 무시함. [REF OpenJDK JDK-8195675/8257650, Gureum #149/#852/#829] | Java 클라이언트에는 macSKK가 `com.jetbrains.intellij`에 하듯 `insertText(text)` 바로 전에 항상 `setMarkedText(text)`를 보냄. Java는 번들 ID 접두사 `com.jetbrains.`, `com.google.android.studio`, 또는 앱 안의 `Contents/jbr`로 감지함. Gureum의 "JDK 호환 모드"는 모든 글자를 조합 중으로 다룸. |
| Terminal의 조합 문자열과 대체 | Terminal은 조합 문자열을 커서 위치에 그리고, 캐럿에서 끝나는 대체만 따름. | `.beforeCaretOnly` 정책. Return은 확정 뒤 그대로 넘김. |
| Microsoft Office: Shift+화살표가 선택 영역을 지움; Excel 입력이 이상함 | 조합 중인 것이 없을 때 빈 `setMarkedText`/`insertText`를 보냄. [REF Gureum #3, #237] | 버퍼가 비었으면 아무것도 보내지 않음. 이동 키에는 `false`를 반환함. |
| Things나 Messages: Shift로 시작한 첫 글자가 가공 없이 삽입됨 | 일부 앱은 조합 중인 첫 글자를 확정해 버림. [REF macSKK `treatFirstCharacterAsMarkedText`] | Duo 메뉴에 앱별 호환성 토글을 둠(macSKK는 이런 토글을 `menu()`에 노출함). |
| Kitty/Alacritty: 모드 전환 키가 글자를 흘림 | 빈 조합 문자열을 처리하지 못하는 터미널 에뮬레이터. [REF macSKK `insertBlankString`] | Duo가 모드 키를 추가하지 않는 한 필요 없음. |
| Spotlight/Raycast 패널 | 컨텍스트 메뉴와 후보 메뉴가 오동작함. [REF vChewing 거부 목록 `com.apple.Spotlight`, `com.raycast.macos`] | 패널을 `client.windowLevel()+1`에 둠. 거기서는 컨텍스트 메뉴를 피함. |
| 시스템 오버레이(위젯, 알림 센터) | macOS 26/27에서 레거시 IMK 컨텍스트가 폐기됨. [REF squirrel #1196] | 알려진 한계. |
| 코드로 입력 소스 전환(macism, Input Source Pro, vim 플러그인) | macOS 26에서 `deactivateServer`도 활성화도 일어나지 않음. [REF squirrel #1140/#1162] | TIS 알림 옵저버 → 확정하고 숨김. |
| Shift+Space | 시스템 단축키가 아님(⌃Space / ⌃⌥Space가 시스템 단축키임). JetBrains에서는 전환할 때 스페이스가 입력됨. [REF Gureum #829] | 바꾸기 키가 된다면: 실제로 바꾸기나 확정이 일어났을 때**만** 소비하고(`return true`), 버퍼가 비었을 때는 절대 소비하지 않음. |
| **Caps Lock** | `TICapsLockLanguageSwitchCapable=true`이고 사용자 설정이 켜져 있으면, 시스템이 짧은 누름을 가로채 ABC로 전환함. 그렇지 않으면 Caps Lock은 `.flagsChanged`로 오고 `.capsLock`을 설정함. LED를 켜고 끄려면 `IOHIDManager`가 필요하고, 이것은 입력 모니터링 확인 창을 띄움. [REF Gureum `InputMethodServer.swift`] | plist에 `false`. 자모를 매핑할 때는 `.capsLock`을 무시하고, 영어 신호로 다룸. IOKit은 쓰지 않음. |
| **Fn/Globe 키** | `kVK_Function`(63)은 `.function`이 붙은 `.flagsChanged`로 오지만, 시스템 설정의 "Press 🌐 to…"(입력 전환, 이모지, 받아쓰기)도 이 키에 반응함. | 바꾸기를 Fn/Globe에 묶지 않음. |
| 디스플레이 잠자기나 유휴 상태: 사용자가 앱을 바꿀 때까지 메뉴에 ABC만 보임 | macOS 결함. [REF macSKK #112] | 알려진 문제. |
| 오른쪽 ⌘/⌥를 바꾸기 키로 쓰기 | `.flagsChanged`로만 보임. 중간에 다른 키가 없을 때 `keyCode`(54 = 오른쪽 ⌘, 61 = 오른쪽 ⌥)로 왼쪽과 오른쪽을 구분함. | 탭은 다른 키 없이 약 300 ms 안에 flagsChanged 눌림과 뗌이 이어지는 것을 뜻함. |
| 암호 | 4.6절 참고. | 그대로 넘김. 절대 학습하지 않음. |

**직접 조합 대 조합 문자열 방식 (전략적 선택):**

- Apple(macOS 26)과 DKST는 Cocoa와 WebKit 클라이언트에서 대체 범위를 써서 밑줄 없이 **직접** 조합함. Chromium/Electron, Java, 터미널, 그리고 `selectedRange()`가 `NSNotFound`를 반환하는 클라이언트에서는 **조합 문자열**로 물러남. [RUNTIME][REF DKST `shouldUseMarkedTextForClient`]
- Duo v1은 **어디서나 조합 문자열**을 씀: 튼튼하고 단순하며, 단어가 "대기 중"임이 눈에 보여서 바꾸기 UX에 잘 맞음.
- v2에서는 같은 클라이언트 정책 표를 바탕으로 검색 필드와 Cocoa/WebKit용 직접 모드를 더할 수 있음. 증분 검색에서 더 잘 동작하게 하려는 것임.

---

## 7. TCC 없이 테스트하기

### 7.1 실제 TSM → IMK 경로를 거치는 종단 간 테스트 [VERIFIED]

준비: `NSTextView`를 first responder로 둔 임시 AppKit 호스트 앱(`Probe.app`)을 썼어요. 선택된 입력 소스는 Apple 두벌식이었어요. 앱은 키 시퀀스 g k s r m f ⌫ ⏎를 보냈어요.

| 전달 방법 | 호스트가 활성이고 키 창인가 | 결과 |
|---|---|---|
| `window.sendEvent(NSEvent.keyEvent(with:.keyDown, …, characters:"g", keyCode:5))` | 예 | `"gksrmf"`: **입력기를 건너뜀**(원시 문자가 삽입됨) |
| `textView.keyDown(with: NSEvent.keyEvent…)` | 예 | `"gksrmf"`: 건너뜀 |
| `textView.inputContext!.handleEvent(NSEvent.keyEvent…)` | 아니요 | `"gksrmf"`: 건너뜀 |
| `NSApp.postEvent(NSEvent.keyEvent…)` | 아니요 | `"gksrmf"`: 건너뜀 |
| **`window.sendEvent(NSEvent(cgEvent: CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: k, keyDown: true)!)!)`** + key-up | **예** | **`"한글"` → ⌫ → `"한그"` → ⏎ → `"한그\n"`: 입력기 조합이 완전히 동작함** ✅ |
| 같은 CGEvent 경로 | **아니요**(직접 실행, 비활성) | `"ㅎㅏㄴㄱㅡㄹ"`: 이벤트는 입력기에 닿았지만(자모로 매핑됨) **조합되지 않음**. 키 창도 활성도 아닌 컨텍스트에서는 문서 접근이 깨짐. |
| `CGEvent.postToPid(getpid())` | 예 | 아무것도 전달되지 않음(TCC 없이는 버려짐) |

결론:

1. 이벤트는 **실제 CGEvent 기반 키 이벤트**여야 함. `NSEvent.keyEvent(...)`는 곧바로 `insertText`로 넘어감. 추정 원인: TSM은 키보드 타입이나 소스가 있는 CGEvent가 필요함. [INFERRED]
2. `window.sendEvent`를 씀. 프로세스 안에서 돌므로 손쉬운 사용 권한이 필요 없음.
3. 호스트는 **키 창이 있는 활성 앱이어야 함**. LaunchServices로 띄움(`open -W -n Probe.app --args …`). 셸에서 직접 시작한 프로세스는 macOS 14+ 협조적 활성화 아래에서 활성화를 거부당함; `NSApp.isActive`가 계속 false였음.
4. 입력기의 `insertText`는 XPC로 오므로, 이벤트마다 런 루프를 약 50–150 ms 돌려 줌.
5. Apple 입력기는 `NSTextView`에서 조합 문자열을 보여 주지 않았음. `textView.string`으로 단언하고, `hasMarkedText()`/`markedRange()` 단언은 Duo에만 씀.

하네스 핵심 코드 (컴파일하고 실행함):

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

추가 메모:
- `NSTextInputContext.selectedKeyboardInputSource`는 설정할 수 있음. `kTISPropertyInputSourceID` 문자열을 씀(`keyboardInputSources`가 켜진 입력 소스를 나열함). [SDK]
- 대안은 `TISSelectInputSource`임. `TSMSetDocumentProperty(TSMGetActiveDocument(), …)`로 쓰는 `kTSMDocumentInputSourceOverridePropertyTag`('inis')도 있음; 둘 다 64비트용이고, 헤더에는 "TSMDocument가 이미 활성이면 … 지정한 입력 소스가 선택된다"고 적혀 있음. [SDK]
- 하네스는 `open`으로 띄운 번들 앱으로 실행함. stdout이 연결되지 않으므로 결과는 셸이 읽을 파일에 씀.
- 호스트가 활성화된다면 **XCTest/Swift Testing 호스트 앱**으로도 동작함; `NSApp.isActive`를 단언함. [INFERRED]
- 주의: 하네스는 포커스를 빼앗고 전역 입력 소스를 바꿈. 사람이나 다른 에이전트가 타이핑하는 동안에는 돌리지 않음. 끝나면 이전 입력 소스로 되돌림.
- Chromium, Terminal, Office는 이 방법으로 조작할 수 없음. *다른* 앱에 이벤트를 보내려면 손쉬운 사용 권한이 필요함. 아래의 클라이언트 정책 단위 테스트와 수동 확인으로 다룸.

### 7.2 목 클라이언트로 컨트롤러 단위 테스트하기 [VERIFIED]

- `DuoInputController(server: nil, delegate: nil, client: nil)`는 `IMKServer`도 `NSApplication`도 없는 평범한 프로세스에서 동작함. `handle(_:client:)`, `commitComposition(_:)`, `menu()`가 모두 목 클라이언트로 실행됨.
- 키 이벤트는 `NSEvent.keyEvent(...)`로 만듦. 여기서는 TSM이 끼지 않으므로 괜찮음.

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

클라이언트 정책을 다루는 목 변형:
- `NotFoundClient`: `selectedRange`가 `NSNotFound`를 반환하고 대체를 무시함. 문서 접근이 없는 경우를 흉내 냄.
- `TerminalLikeClient`: 캐럿에서 끝나는 범위만 따름.
- `JavaLikeClient`: `replacementRange`를 무시하고, 조합 중인 것이 없을 때 UTF-16 단위 2개 이하의 `insertText`를 무시함.
- `ChromiumLikeClient`: 흉내 낸 키마다 마지막 `setMarkedText`만 적용함.

Gureum은 다른 길을 택해요. ObjC `MockInputClient : NSTextView <IMKTextInput, IMKUnicodeTextInput>`를 써서 조합 문자열과 대체에 실제 텍스트 시스템을 재사용해요. XCTest에서 `inputText(_:key:modifiers:client:)`로 컨트롤러를 구동해요. [REF Gureum `GureumTests/MockInputClient.m`, `MockApp.swift`] 이걸 Swift로 하면 `NSTextView`의 `validAttributesForMarkedText` 프로퍼티, 그리고 레이블이 다른 `setMarkedText(_:selectedRange:…)`와 충돌해요. 이 방식을 원하면 ObjC로 작성하세요.

구조:
- 엔진(두벌식 오토마톤, 점수기, 학습기)**과 컨트롤러**를 프레임워크나 SPM 타깃(예: `DuoKit`)에 넣음. 입력기 앱과 테스트가 둘 다 이것을 링크함.
- 프레임워크가 로드되면 `NSClassFromString("DuoInputController")`는 여전히 `@objc(DuoInputController)`를 통해 찾아짐.
- 그러면 Swift Testing이 호스트 앱 없이 프로세스 안에서 엔진과 컨트롤러를 다룸. 7.1절은 작은 스모크 테스트 묶음으로 남겨 둠.

---

## 8. 출처

SDK 헤더(`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk/System/Library/Frameworks/…`):
- `InputMethodKit.framework/Headers/IMKServer.h`, `IMKInputController.h`, `IMKCandidates.h`, `InputMethodKit.h`, `Modules/module.modulemap`
- `Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/IMKInputSession.h`, `TextInputSources.h`, `TextServices.h`, `CarbonEventsCore.h` (`IsSecureEventInputEnabled`), `CarbonEvents.h` (`kEventParamTextInputSendReplaceRange`)
- `CoreServices.framework/.../AE.framework/.../AERegistry.h` (`kTSMHilite*`)
- `AppKit.framework/Headers/NSTextInputClient.h`, `NSTextInputContext.h`, `NSGlassEffectView.h`

살펴본 시스템 번들(읽기 전용): `/System/Library/Input Methods/KoreanIM.app/Contents/PlugIns/KIM_Extension.appex/Contents/Info.plist`와 `InfoPlist.loctable`, `AinuIM.app`, `TCIM.app`, `SCIM.app`, `JapaneseIM-*.app`.

오픈소스 입력기(shallow clone, 2026년 11월):
- macSKK (Swift 6): https://github.com/mtgto/macSKK, 파일 `macSKK/InputController.swift`, `macSKK/StateMachine.swift` (`kakuteiUndo`, `fixedTextRange`, `ReplacementRangeSupport`), `macSKK/macSKK.entitlements`
- Gureum: https://github.com/gureum/gureum, 파일 `OSXCore/InputController.swift`, `OSXCore/InputReceiver.swift`, `OSXCore/InputMethodServer.swift`, `GureumTests/MockInputClient.m`, `GureumTests/MockApp.swift`, `OSX/Info.plist`
- Squirrel: https://github.com/rime/squirrel, 파일 `resources/Info.plist`, `sources/InputSource.swift`, `resources/Squirrel.entitlements`
- Fire: https://github.com/qwertyyb/Fire, 파일 `Fire/InputSource.swift`, `docs/dev-logs/2026-09-23-input-source-missing-from-add-list.md`
- azooKey-Desktop: https://github.com/azooKey/azooKey-Desktop, 파일 `azooKeyMac/Info.plist`, `azooKeyMac/azooKeyMac.entitlements`
- vChewing: https://github.com/vChewing/vChewing-macOS, 파일 `Packages/vChewing_IMKUtils/Sources/IMKSwiftModernHeaders/include/IMKSwift.h`, `Packages/vChewing_InstallerAssembly4Darwin/.../InstallerVMProtocol.swift`
- DKST: https://github.com/DINKIssTyle/DINKIssTyle-IME-macOS, 파일 `Sources/InputController+ClientPolicy.m`, `Docs/INPUT-SYNC-VALIDATION.md`

이슈와 스레드:
- 로그아웃에 관한 Apple DTS 답변: https://developer.apple.com/forums/thread/775526
- Squirrel #1140 (macOS 26에서 코드로 전환할 때 `deactivateServer`가 불리지 않음): https://github.com/rime/squirrel/issues/1140; 수정 PR #1142: https://github.com/rime/squirrel/pull/1142
- Squirrel #1162 (코드로 전환할 때 활성화되지 않음): https://github.com/rime/squirrel/issues/1162
- Squirrel #1196 (시스템 오버레이가 레거시 IMK 컨텍스트를 폐기함): https://github.com/rime/squirrel/issues/1196
- azooKey #357 (비동기 조합 문자열 때문에 iTerm2에서 첫 글자가 두 번 찍힘): https://github.com/azooKey/azooKey-Desktop/issues/357
- azooKey #348 (보이지 않는 창 누수): https://github.com/azooKey/azooKey-Desktop/issues/348
- azooKey #385 (26.6.2에서 `setMarkedText` CFEqual(NULL)로 호스트 크래시; nil이 아닌 문자열과 속성을 넘길 것): https://github.com/azooKey/azooKey-Desktop/issues/385
- Gureum 이슈: https://github.com/gureum/gureum/issues/880, /924, /180, /1, /3, /237, /149, /852, /829
- OpenJDK: https://bugs.openjdk.org/browse/JDK-8257650 및 https://bugs.openjdk.org/browse/JDK-8195675 (수정: https://github.com/openjdk/jdk/pull/17921)
- Apple NumberInput 샘플 (연결 이름 주석): https://developer.apple.com/library/archive/samplecode/NumberInput_IMKit_Sample/Listings/trunk_NumberInput_4_main_m.html
- vChewing macOS 12 켜기 확인 창 (커밋 "Fix IME activation issues on macOS 12"): https://testgitea.trustie.net/floraachy/vChewing-macOS/commit/883dc6144662b19f11ca0838a37ba258af5114d1
- MDN `isComposing`/229 설명: https://developer.mozilla.org/en-US/docs/Web/API/Element/keydown_event
