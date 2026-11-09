# Duo 리서치: 완전성 비평과 해결안

트랙: 완전성 비평. 입력 문서: `imk-platform.md` (IMK), `ui-design.md` (UI), `detection.md` (DET), `ux-spec.md` (UX).
날짜: 2026-11-07. 머신: macOS 26.6.2, Xcode 27.2, Swift 6.4.2, SDK `MacOSX27.2.sdk`.
현재 스캐폴드(`project.yml`, `DuoInputMethod/`, `DuoHarness/`, `Packages/DuoCore/`)도 읽었어요. 이 파일 밖에서는 아무것도 바꾸지 않았어요.

표시: **[여기서 확인함]**은 이 세션에서 직접 실행하거나 컴파일했다는 뜻이에요. 프로브는
`/private/tmp/claude-501/-Users-user-orca-zlqhem/b8fa910a-9760-4366-944c-1b8329866082/scratchpad/critic/`에 있어요.
**[SDK]**는 헤더에서 읽었다는 뜻이에요. **[추론]**은 추론만 했다는 뜻이에요.

---

## 0. 이 세션에서 확인한 것 (구현을 가장 많이 바꾸는 주장)

| # | 확인한 주장 | 결과 | 영향 |
|---|---|---|---|
| V1 | `recognizedEvents`가 `.flagsChanged`도 돌려줄 때 IMK의 클릭 시 확정 동작. UX 3절과 현재 `DuoInputController`는 `[.keyDown, .flagsChanged]`만 돌려줌. | **[SDK]** `IMKInputController.h`의 `recognizedEvents:` 설명에 따르면 IMK의 기본 마우스 처리(사용자가 조합 밖을 클릭하면 `commitComposition:`을 보냄)는 NSKeyDownMask만 돌려주는 입력기에서만 일어남: *"will only happen for input methods that return just NSKeyDownMask"*. | 오른쪽 ⌘에는 `.flagsChanged`가 필요함. 그래서 Duo는 `.leftMouseDown`도 **반드시** 받아서 직접 확정해야 함(R4). 그렇지 않으면 클릭 뒤에 낡은 버퍼가 남음("유령" 조합). |
| V2 | IMK 문서는 "Duo가 ASCII 입력 가능(ASCII-capable)이 아니어서" 암호 필드에서 Duo가 호출되지 않는다고 함(4.6절). | **[여기서 확인함]** TIS 조회(`flags.swift`): `com.inkyuoh.inputmethod.Duo asciiCapable=true`. Apple의 `com.apple.inputmethod.Korean.2SetKorean asciiCapable=false`. 원인은 `tsInputMethodCharacterRepertoireKey`에 든 `Latn`일 가능성이 큼 [추론]. | 전제가 틀림. UX 온보딩 3단계("Duo를 유일한 키보드로")를 TIS가 허용한다는 뜻이기도 함. **[2026-11-09 실제 앱에서 확인함, 정정]** 처음에는 "Duo가 보안 입력 상황에서도 활성 상태로 남을 수 있으니 `IsSecureEventInputEnabled()` 통과 처리가 필수"라고 보았음(R5). 실제로는 보안 입력이 켜지면 macOS가 Duo를 바로 끄고 입력 메뉴에서 흐리게 보여 줌. Duo 로그에서 `activate … secure=true` 뒤 1~2 ms 안에 `deactivate`가 왔음(Chrome, Orca). 같은 때 ABC와 2-Set Korean은 고를 수 있었음. 막는 기준은 ASCII 입력 가능 여부가 아님. 통과 처리는 activate가 먼저 오는 짧은 틈을 막는 다층 방어로 남김. |
| V3 | 오른쪽 ⌘ 탭 감지. UX 5.1절은 "keyCode 54 **그리고 RCmd 장치 비트**"일 때 준비(arm)함. | **[SDK]** `IOLLEvent.h`: `NX_DEVICERCMDKEYMASK 0x10`, `LCMD 0x08`, `LSHIFT 0x02`, `RSHIFT 0x04`, `LALT 0x20`, `RALT 0x40`, `LCTL 0x01`, `RCTL 0x2000`; UX의 표는 맞음. **[여기서 확인함]** `DebugInjector.flagsEvent`와 같은 방식으로 만든 flagsChanged는 `type=12 keyCode=54 raw=0x100000`을 줌. 즉 **0x10 비트가 없음**. `0x100010`을 직접 설정하면 `NSEvent(cgEvent:)`를 거쳐도 그대로 유지됨. | 명세대로라면 리드의 e2e 하네스에서 감지기가 한 번도 발동하지 않음. 감지기는 `keyCode`와 장치 독립 `.command` 전환을 기준으로 삼아야 함. 장치 비트는 두 번째 수식키가 눌려 있는지 알아낼 때만 쓰고, 인젝터가 이 비트를 설정하게 해야 함(R3). |
| V4 | 공유 설정 스위트(suite). IMK 3.4절은 `UserDefaults(suiteName: "com.inkyuoh.inputmethod.Duo")`를 제안함. | **[여기서 확인함]** (`suite.swift`, 내장 Info.plist): `UserDefaults(suiteName: <own bundle id>)`는 **nil**을 돌려주고 *"Using your own bundle identifier as an NSUserDefaults suite name does not make sense and will not work"* 로그를 남김. | 입력기 안에서는 그 스위트가 nil임. 그래서 UI 코드의 `UserDefaults(suiteName:)!`는 크래시가 남. 제3의 이름 `com.inkyuoh.Duo.shared`를 써야 함(R6). |
| V5 | 애드혹(ad-hoc) 서명과 hardened runtime. `project.yml`은 `ENABLE_HARDENED_RUNTIME: YES`를 설정하지만 Debug 빌드는 `DuoInputMethod.debug.dylib`를 만듦. | **[여기서 확인함]** (`hr/`): `--options runtime`을 단 애드혹 메인 실행 파일과 애드혹 dylib을 함께 쓰면 dyld가 로드를 거부함. 메시지는 *"mapping process and mapped file (non-platform) have different Team IDs"*임(exit 134). 12:50 Debug 빌드는 여전히 `flags=0x2(adhoc)`이고 runtime 플래그가 없음. 그래서 **지금** 동작하는 건 hardened runtime이 아직 적용되지 않았기 때문일 뿐임. | hardened runtime이 언젠가 적용되면(Release, 내장 중 재서명, `--deep`) 별도 dylib이나 동적 프레임워크가 있는 입력기는 실행되지 않음. 타이핑해도 아무 일도 안 일어남. 입력기에 `ENABLE_DEBUG_DYLIB: NO`와 `ENABLE_PREVIEWS: NO`를 설정하고 SPM 제품은 정적으로 유지해야 함(R20). |
| V6 | 리드의 현재 형태(`final class …: IMKInputController, @unchecked Sendable`)에서 쓰는 Swift 6 홉(hop) 패턴. | **[여기서 확인함]** (`ctl.swift`): `event`나 `client`를 `MainActor.assumeIsolated`에 바로 캡처하면 `sending 'event'/'client' risks causing data races`가 나옴(여기서는 `-swift-version 6`에서 경고). 먼저 `nonisolated(unsafe) let e = event, c = client`로 다시 바인딩하면 `-warnings-as-errors`로도 깨끗하게 컴파일됨. | IMK D3이든 리드의 `@unchecked Sendable` 형태든 괜찮음. 다만 홉 전에 **항상 IMK 인자를 다시 바인딩**해야 함(R14). |
| V7 | Python 참조 구현은 비트 단위로 정확하고 이식 가능함. | **[여기서 확인함]** `detector.py`의 런타임 경로는 정수만 씀. 하나뿐인 `//`(`user_bonus`)는 피연산자가 양수임. `round()`는 빌드 시점에만 나오고, `shift_counts`는 `i > 0`을 확인함(Python 음수 인덱스 순환 없음). `render(K)`는 내부에서 Shift를 정규화함(`dLTek`은 있다가 됨). | `Int`와 버림 `/`를 쓰는 Swift 포트는 벡터와 일치함. `USER_LOG2`는 다시 계산하지 말고 `meta.userLog2Millibits`에서 읽어야 함. |
| V8 | UX의 "(확인 필요)" 딥 링크 `x-apple.systempreferences:com.apple.Keyboard-Settings.extension`. | **[여기서 확인함]** `/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex`의 `CFBundleIdentifier = com.apple.Keyboard-Settings.extension`이고 `allowsXAppleSystemPreferencesURLScheme = true`임. 사용자 화면을 빼앗지 않으려고 직접 열지는 않았음. | 대체 링크로 유지함. |
| V9 | UX 프로필 번들 ID를 여기 설치된 앱과 대조함. | **[여기서 확인함]** `com.apple.Terminal`, `com.googlecode.iterm2`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92` (Cursor), `dev.zed.Zed`, `com.jetbrains.WebStorm`, `com.kakao.KakaoTalkMac`, `com.tinyspeck.slackmacgap`, `com.google.Chrome`. 어떤 목록에도 없지만 사용자가 매일 쓰는 앱: **`com.stablyai.orca` (Orca, Electron)**, **`com.cmuxterm.app` (cmux, 네이티브)**. | 둘 다 터미널 계열 클라이언트임. Orca의 터미널은 Electron(아마 xterm.js)이라서 Chromium 규칙**과** 터미널 프로필을 모두 받음. 둘 다 프로필 표와 수동 QA 목록에 추가해야 함(R10, R18). |
| V10 | 수동적인 로그 확인만으로 실제 flagsChanged 이벤트가 `handle`에 도달하는지 확인할 수 있는가? | 서브시스템 `com.inkyuoh.inputmethod.Duo`에 대한 `log show --debug`는 아무것도 돌려주지 않았음. debug 수준 메시지는 저장되지 않음. | **아직 확인 안 됨.** 테스트 계획은 U1 참고. |

---

## 1. P0: 일관된 구현을 막는 모순

### R1. 조합 모델: UX "즉시 확정 단계(eager phases)" vs DET "단어 전체를 경계에서 결정"
**문제.** 두 명세는 서로 다른 엔진을 설명해요.
- UX D2는 K 단계 음절을 즉시 확정함(Apple과 같음). E 단계 라틴 문자도 즉시 확정하고, 이후 글자는 그대로 통과시킴. 혼합 단어는 별도의 휴리스틱 미리 보기(lookahead)를 씀(UX 4.5절: "완전한 영어 단위" 더하기 "≤ 2 키").
- DET는 단어 전체를 유지함. 화면에는 접두 모드(prefix mode) argmax를 HYST = 1.5 nats로 보여 주고, 확정은 **최종 모드(final mode)** argmax(어휘 사전과 `</s>` 포함)로 함. 혼합 단어는 `M(b)` 점수로 만들어짐.

DET의 모든 정확도 수치(99.90 / 99.89 / 99.99 / 99.86 %)는 단어 전체를 최종 모드로 결정한다고 가정해요. 즉시 K 확정은 대체 범위(replacement range)로만 되돌릴 수 있어요. 그리고 너무 일찍 확정되는 일이 얼마나 자주 생기는지 아무도 측정하지 않았어요. DET는 한국어 문장 속 라틴 단어에서 화면 표시 정확도 80.2 %, 단어당 0.54회 바뀜을 측정했어요. 바로 이 단어들에서 이른 K 잠금이 엉터리 자모를 확정해요. 게다가 UX 2.3절은 영어로 다시 빠져나가는 것을 금지해요("K 단계에서는 나중의 오타가 영어로 바뀌지 않음").

**결정.**
1. **엔진은 DET임.** 단어는 글자의 연속에 DET 규칙에 따른 내부 `'`를 더한 것임. 화면 표시는 히스테리시스가 있는 접두 모드이고, 확정은 최종 모드임. 단어 전체는 경계가 올 때까지 조합 문자열(marked text)로 남고, 최대 32 키까지임(UX 4.1절).
2. **즉시 E는 허용함**(안전하고 IntelliSense와 자동 완성에 도움이 됨). 접두 모드 여유(margin) `S_E − max(S_K, S_M*) ≥ 4595` 밀리냇(P < 1 %)이거나, UX의 구조적 막힘(structural-deadness) 규칙이 발동하면 작동함. 그러면 Duo는 지금까지 친 라틴 문자를 확정하고, 이후 글자는 그대로 통과시킴.
   - 자음 키(`qwertasdfgzxcv` 또는 `QWERT`)가 오고, `b = committed length`에 대해 DET의 `M(b)` 조건이 성립할 때만 조합 문자열을 다시 엶. 조건: `lexEN[low[0..<b]] != nil`이거나, 라틴 부분에 대문자가 있거나, `suffixPrefix[ks]`가 있음.
   - 그러면 뒷부분은 DET `S_M(b)`로 점수를 매겨 `S_E(full)`과 비교함. 화면 표시는 접두 모드, 확정 시에는 최종 모드임.
   - 이것은 UX 4.5절을 DET 수식으로 다시 쓴 것임. 별도의 UX 미리 보기 휴리스틱은 버림.
3. **즉시 K는 기본으로 꺼 둠.** `search` 클라이언트 정책에서만 켬(Spotlight `com.apple.Spotlight`, Alfred `com.runningwithcrayons.Alfred`, Raycast `com.raycast.macos`, 감지할 수 있다면 Safari 주소창). DET가 Leipzig 세트와 혼합 세트를 Python `phase_trace`로 재생해서, 되돌릴 수 없는 확정 오류가 단어의 0.05 % 미만이라고 보고하면 다시 검토함.
4. 일본어·중국어 입력기는 Chromium과 Electron에서 매일 구절 전체를 조합 문자열로 유지함. UX가 인용한 웹 Return 버그는 긴 조합뿐 아니라 모든 조합 문자열에서 일어남. 그래서 어느 쪽이든 Return에서 확정 후 통과(R18)가 완화책임.

### R2. 확정 정책: UX D1 "보이는 대로(WYSIWYG), 절대 다르지 않음" vs DET "확정 = 최종 argmax"
**문제.** DET는 *확정 놀람(commit surprise)*을 측정했어요. 확정되는 내용이 확정 직전 화면에 보이던 것과 다른 경우예요. 문장 첫 영어 단어에서는 7.6 %, 한국어 문장 속 라틴 단어에서는 5.7 %예요. 순수한 WYSIWYG는 이런 표시 오류를 그대로 확정해요. 그리고 99.9 % 수치를 만드는 어휘 사전과 `</s>` 근거도 버리게 돼요.

**결정.** 경계에서는 **최종 모드 argmax**를 확정해요. 경계 처리기는 먼저 조합 문자열을 최종 읽기로 바꾸고 확정해요. 이 모든 일은 같은 `handle` 호출 안에서 일어나요. `insertText`는 한 번만 보내고, 그 전에 `setMarkedText`는 보내지 않아요(R18). 최종 결과가 화면에 보이던 것과 다르면 **"↺ flip last word" 칩**을 1.6 s 동안 보여 줘요(UX 5.4절). D1의 문구는 "절대 다르지 않음"에서 **"조용히 다르지 않음(never differs silently)"**으로 바꿔요. 이미 확정된 단어는 다시 결정하지 않는다는 DET의 지침을 받아들여요.

### R3. 바꾸기 키: 서로 다른 기본값 세 개
**문제.**
- UX D3은 오른쪽 ⌘ 탭을 기본으로 하고 Tab은 거부함.
- UI는 `FlipKey { shiftSpace (default), rightCommand, rightOption, tab }`, HUD 키캡 `["⇧","Space"]`, "Flip Current Word ⇧Space"라는 메뉴 항목을 씀.
- DET 10절은 "Shift+Space 또는 전용 키"를 제안함.
- UX 스스로 ⇧Space가 왜 잘못 발동하는지 설명함(ㅆ이나 대문자 뒤에 ⇧가 아직 눌려 있음).

**결정.**
- **기본값은 오른쪽 ⌘ 탭으로 함.** `enum FlipKey: String { case rightCommand, rightOption, doubleShift, shiftSpace, capsLock }`를 쓰고 `.tab`은 지움. HUD 기본 키캡은 `["⌘"]`이고, 설정에서는 "오른쪽 ⌘"로 표시함.
- **감지기(DuoCore 안의 순수 상태 기계), `flagsChanged`로 구동함:**
  - `keyCode == 54`이고, `.command`가 꺼짐에서 켜짐으로 바뀌고, 다른 장치 독립 수식키가 켜져 있지 않으면 **준비(arm)**함.
  - `keyCode == 54`이고 `tapWindow`(기본 300 ms) 안에 `.command`가 꺼지면 **발동(fire)**함.
  - `keyDown`이 오거나, 다른 수식키가 바뀌거나, `NSEvent.pressedMouseButtons != 0`이거나, 시간이 초과되면 **해제(disarm)**함. 장치 비트는 *추가* 확인용일 뿐임: `raw & 0x08`(왼쪽 ⌘)도 켜져 있으면 해제함.
  - `keyCode == 0`인 `flagsChanged`는 무시함. Squirrel에 따르면 원격 데스크톱 도구가 이런 이벤트를 보냄.
  - 키 떼기가 가끔 늦게, 다음 `keyDown`과 함께 올 수 있음(Squirrel 주석). 그러면 탭을 놓치는데, 이건 안전한 실패임.
  - `flagsChanged`는 절대 소비하지 않음.
- **하네스:** e2e 테스트가 실제와 같도록 `DebugInjector.flagsEvent`는 장치 비트를 OR로 넣어야 함(V3에 따라 `{rcmd}`는 `0x10`, `{lcmd}`는 `0x08` 등).
- 선택 사항, 확인 안 됨: F18 keyDown(`kVK_F18 = 79`)을 별칭으로 씀. Karabiner 설정에서 오른쪽 ⌘를 한/영용 F18로 바꿔 둔 사용자를 위한 것임.

### R4. 마우스 이벤트 (V1)
**결정.** `recognizedEvents = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]`를 돌려줘요. Gureum `InputReceiver.swift:262`와 같은 집합이에요. `handle`에 마우스 종류의 이벤트가 오면 R2에서 설명한 대로 확정해요. 그리고 단어와 탭 감지기를 초기화하고, `lastCommit`을 무효로 하고, `false`를 돌려줘요. UX 3절의 "마우스 클릭 → commitComposition" 행은 이제 이 처리에 달려 있어요. IMK 기본 동작이 아니에요. 현재 `DuoInputController.recognizedEvents`도 고쳐요.

### R5. 보안 입력 (V2)
**결정.** 모든 `handle`의 맨 앞(점수 계산 전)과 `activateServer`에서 `IsSecureEventInputEnabled()`를 확인해요. XPC가 아닌 로컬 호출이에요. true를 돌려주면 이렇게 해요.
- 대기 중인 단어를 확정함,
- 그때부터 모든 키에 `false`를 돌려줌,
- HUD를 보이지 않고 아무것도 학습하지 않음.

TSM 경로로 구동하는 `NSSecureTextField` 하네스 케이스를 추가해요(U1). 이제 Duo가 ASCII 입력 가능하니, 거기서 TSM이 Duo를 활성 상태로 두는지 이 케이스로 확인해요. 문자 목록(repertoire)에는 `Latn`을 그대로 둬요. Duo를 ASCII 입력 불가로 만들면 사용자가 ABC를 계속 켜 둬야 해요. 그러면 입력 소스 전환(⌃Space, Caps Lock)이 다시 생겨요. 이 제품은 바로 그걸 없애려고 만들었어요.

**2026-11-09 정정(V2).** 실제 앱에서는 보안 입력이 켜지면 macOS가 Duo를 꺼요. 그동안 입력 메뉴에서도 Duo를 고를 수 없어요. 어느 앱이 켜든 모든 앱에 걸려요. 그래서 호스트 앱은 보안 키보드 입력을 켠 앱의 이름을 보여 줘요(`SecureInputOwner`).

### R6. 식별자와 저장소 (V4와 임시값)
UI 코드는 임시값(`app.duo.inputmethod`, `app.duo.shared`, `InputSourceStatus.bundleID = "app.duo.inputmethod"`)을 써요. 표 하나로 정하고, `DuoKit`의 상수(`enum DuoIDs`)로 유지해요.

| 항목 | 값 |
|---|---|
| 입력기 번들 ID | `com.inkyuoh.inputmethod.Duo` (project.yml에 이미 설정됨) |
| 입력기 제품/실행 파일 | `DuoInputMethod`를 유지함. 그래야 `killall DuoInputMethod`가 호스트 앱을 건드리지 않음. `DuoInputMethod/Info.plist`에서 `$(PRODUCT_NAME)` 대신 `CFBundleName`/`CFBundleDisplayName` = `Duo`로 직접 지정함. 지금 설치된 입력 소스 이름은 "DuoInputMethod"임. `InfoPlist.strings`(ko, en)를 추가함. |
| 호스트 앱 | 번들 ID `com.inkyuoh.Duo`, 제품 `Duo.app`. 입력기를 `Contents/Library/Input Methods/DuoInputMethod.app`에 내장함. `InputMethodInstaller`도 이미 그렇게 가정함. |
| 하네스 | `com.inkyuoh.Duo.Harness` (있음) |
| 선택 가능한 입력 소스 ID | 지금은 `com.inkyuoh.inputmethod.Duo`(모드 없음). IMK 모드 `com.inkyuoh.inputmethod.Duo.Bilingual`로 바꾸는 건 R19에서 다룸. 코드는 하드코딩한 ID 대신 항상 `InputSourceManager.primaryDuoSource()`를 거쳐야 함. |
| 공유 환경설정 | `UserDefaults(suiteName: "com.inkyuoh.Duo.shared")`. 어느 앱이든 자기 번들 ID는 쓰지 않음(V4). 앱 그룹은 쓰지 않음: 애드혹 서명에는 팀 접두사가 붙은 그룹 권한(entitlement)을 넣을 수 없음 [추론]. |
| 설정 변경 IPC | 분산 알림(distributed notification) `com.inkyuoh.Duo.settingsChanged`, 페이로드 없이 보냄. 입력기는 이 알림을 받을 때와 `activateServer`에서 설정을 다시 읽음. |
| 학습 저장소 | `~/Library/Application Support/Duo/learning.json`. **쓰는 쪽은 입력기뿐임**(R7 참고). |
| 기타 알림 | 기존 `com.inkyuoh.Duo.debug.*` 이름을 유지함. 온보딩 도전 과제용으로 `com.inkyuoh.Duo.event.flipped`(텍스트 페이로드 없음)를 추가함. |
| 로그 서브시스템 | `com.inkyuoh.inputmethod.Duo` (있음) |

### R7. 학습: 서로 맞지 않는 공식 두 개
**문제.**
- UX 5.5절: Double 값으로 표를 셈. 바꾸기는 `+1`, 암묵적 수용은 `+0.25`를 더함. 편향은 `β = 3·ln-ratio`, 반감기 60일, 50 k LRU, 액터(actor), 앱 그룹 JSON 파일.
- DET 5.5절: 가설(`K`, `E`, `M<b>`)별 정수 횟수. 확정은 `+1`, 바꾸기는 `+3`을 더함. 보너스는 `USER_UNIT · USER_LOG2[min(n,15)] / 1000`, 20 k LRU이고, 테스트 벡터(`user[]`, `userBonus`)가 뒷받침함.
- DET의 "확정할 때마다 +1"은 지금까지 친 모든 단어를 저장함(개인정보 문제이고, 끝없이 커짐). 또 습관이 수정을 이기게 됨: `go`를 영어로 15번 확정하면 +10.0 nats, 해로 한 번 바꾸면 +5.0임. UX식 바꾸기 전용 표와 문맥 없는 키를 쓰면, 한국어 뒤에서 `go`→해로 한 번 바꾼 것 때문에 영어 문장에서도 `go`가 해가 됨(EN 문맥 여유 +2.37 − 5.0 < 0).
- DET는 보너스를 **최종 모드에서만** 적용함. 그래서 학습된 단어도 타이핑하는 동안에는 예전 읽기로 보이다가 확정할 때 바뀜. 이는 R2를 깨뜨림.

**결정.**
- DET의 **점수** 공식과 벡터는 그대로 둠.
- **저장 키** = `(raw, ctx)`, `ctx ∈ {START, KO, EN, NUM}`. 값은 가설 키(`"K"`, `"E"`, `"M<b>"`)별 정수 횟수와 `lastUsed`임.
- **갱신:**
  - 명시적 바꾸기는 선택한 가설에 `+3`을 더함;
  - 암묵적 확정은 최종 여유가 1386 밀리냇 이하일 때**만** 확정한 가설에 `+1`을 더함(다른 쪽 확률이 ≥ 20 %였음);
  - 같은 단어 안에서 다시 바꿔 되돌리면 그 표는 취소됨.
- **학습하지 않음**(UX 기준): 보안 입력, L 단계, 직접 입력(Direct), 길이 1 단어, 학습 일시 정지.
- **감쇠:** 실효 횟수는 `n_eff = Int((Σ count·0.5^(age/60 d)).rounded())`임. 읽을 때, `USER_LOG2` 조회 전에 계산함. 그래야 점수 계산이 정수로만 됨.
- **상한:** LRU 20 000.
- `raw`가 현재 raw와 정확히 같은 항목에는 **사용자 보너스를 접두 모드에서도 적용함**. 그러려면 Swift 포팅 전에 `detector.py`를 확장하고 `incremental[]` 벡터를 다시 만들어야 함.
- **저장소 동시성:** R14 참고.

### R8. 점수 상수: 기준은 하나만
**문제.** UX는 별도의 로짓(logit) 체계를 새로 만들어요. 관성(momentum) λ 표, ±2.5 고정(clamp), QWERTOP이 아닌 대문자에 +2.0, camelCase에 +3.0, Δ ≥ 1.0 로짓 히스테리시스, +2.0 수량사(counter) 표, 문장 시작 EN +1.0이 있어요. DET의 `params`는 홀드아웃 데이터로 조정한 값이에요: `PRIOR[ctx]`, `CASE_*`, `ROLLOVER`/`STRAY`, `NUM_UNIT_EN`, `HYST = 1500`.

**결정.**
- DET `meta.params`가 유일한 점수 상수 집합임. UX의 수치 상수는 대체됨. UX 9절의 테스트 벡터는 공식이 아니라, DET 결과와 대조할 기대 결과임.
- DET에 대응하는 것이 없는 UX 기능은 모두 **하나의** 덧셈 항 `appBiasKO`(밀리냇, ±1500으로 고정)로 모아 KO 점수에 더함. 다음을 합침:
  - 앱별 프로필: 영어 우선 −1000, 한국어 우선 +1000;
  - 전역 "언어 편향" 슬라이더(UI 3.3절)를 ±1000으로 매핑한 값;
  - 학습된 앱별 EMA(UX 6.5절), 최대 ±500.
- `appBiasKO = 0`이면 골든 벡터가 정확히 맞음.
- 따옴표와 괄호 규칙(UX 6.3절)은 v1.1로 미룸.
- **DET 단위로 쓴 HUD 임계값.** P는 표시된 읽기와 가장 좋은 다른 읽기의 2-way softmax로 구함:
  - P(alt) ≥ 20 %는 여유 ≤ **1386**을 뜻함;
  - "불확실한 확정"(P ≥ 35 %)은 최종 여유 ≤ **619**를 뜻함;
  - P < 1 %는 여유 ≥ **4595**를 뜻함.
- 적응형 문맥 사전 확률(DET 10.2절)은 v1.1로 미루고 플래그 뒤에 둠. DET의 `PRIOR_KO_EN = −5000`은 뉴스 텍스트를 반영한 값임. 그래서 언어를 자주 섞어 쓰는 사람은 `go`/`so`/`to`에서 손해를 봄.

---

## 2. P1: 정해 두지 않으면 구현자가 막히는 결정

### R9. 단어 경계, 연결 문자, 리터럴 모드
- **DET의 단어 분리기(tokenizer)**를 씀: 글자, 그리고 DET의 아포스트로피 규칙으로 정하는 내부 `'`. DET 측정으로는 이 규칙이 UX의 "EN이 표시될 때만 붙임"보다 나음.
- `-`는 `term = H`인 경계임(DET `TERM_HYPHEN_EN = +5000`이 e-mail과 co-founder를 처리함). UX의 하이픈 연결 문자는 버림.
- **UX의 L 단계**는 점수 계산 앞의 관문으로 유지함. 그래서 L 단계가 켜져 있는 동안에는 DET를 거치지 않음:
  - 단어 시작의 `/ ~ \ : @`, `./`, `../`;
  - 글자 뒤의 `@`;
  - `://`, `www.`;
  - 이전 단어가 E로 확정됐을 때 `.` 뒤의 글자;
  - 단어 안의 `_`.

  L 단계에서는 공백이나 Return이 올 때까지 모든 키를 그대로 통과시킴. `#`은 리터럴이 아님.
  - 바뀜: 단어 시작의 `@`, `/` 앞이 아닌 `~`, E 뒤 `.` 다음 글자, 단어 안의 `_`는 이제 트리거가 아님. 지금 규칙은 SPEC.md 4.6절에 있음.
- 숫자는 경계이고(`term = D`), 다음 단어는 `ctx = NUM`을 받음(DET). UX의 수량사·단위 표는 DET의 `NUM` 사전 확률과 56개 `numUnitsEn`으로 대신함. 두 번째 표는 만들지 않음.

### R10. 터미널 기본 프로필
**문제.** UX D8은 vim 일반 모드를 보호하려고 터미널을 직접 입력(Direct)으로 만들어요(키를 그대로 보내고, 오른쪽 ⌘ 탭을 하면 한 줄 동안 한국어를 켬). 이 사용자는 터미널에서 Claude Code를 쓰고, 그 프롬프트는 대부분 한국어예요(Orca `com.stablyai.orca`, cmux `com.cmuxterm.app`, Terminal, iTerm2). 직접 입력은 제품이 없애겠다고 약속한 바로 그 모드 전환을 다시 가져와요.

**결정.**
- 터미널 계열 앱의 기본값은 **영어 우선 사전 확률을 쓴 이중 언어(Bilingual)**임(`appBiasKO = −1000`).
- "직접 입력 (Direct)"은 입력 메뉴와 설정 ▸ 앱에서 한 번 클릭으로 켤 수 있음. 온보딩에서도 권함("vim·less를 자주 쓰나요?").
- 빠진 ID를 추가함: `com.stablyai.orca`(터미널 계열이자 Electron), `com.cmuxterm.app`, `com.mitchellh.ghostty`, `dev.warp.Warp-Stable`.
- Esc는 명세대로 확정하고 통과시킴.

### R11. 바꾸기 의미와 HUD의 단일 대안
DET는 K → E → 최선의 M → K로 순환해요. UX와 UI는 상태가 두 개예요. **결정: 두 상태.** 대안은 다른 문자 계열에서 *렌더링된 문자열이 다른* 가설 중 점수가 가장 높은 것이에요.
- 표시가 K → {E, M} 중 최선;
- 표시가 E → {K, M} 중 최선;
- 표시가 M → E.

바꾸기를 하면 단어가 잠겨요. 두 번째 바꾸기는 원래대로 돌아가고 잠금은 유지해요. HUD는 정확히 그 대안을 보여 줘요.

### R12. HUD: 합친 명세
- **언제 보이나 (UX 규칙, DET 단위):**
  - 단어가 조합 문자열로 있는 동안에만 보임. 조건은 P(alt) ≥ 20 %(여유 ≤ 1386)이고, 키가 ≥ 2개이거나 1키 충돌 키(`a i e x`…)일 때임;
  - **300 ms** 멈춘 뒤 나타나고, 그다음에는 확정할 때까지 그 자리에서 갱신됨;
  - UI의 **140 ms** 디바운스와 100 ms 페이드 뒤에 숨음;
  - 자동 반복, 보안 입력, 직접 입력 모드, 캐럿 사각형이 유효하지 않을 때는 절대 보이지 않음.
- **모양:** UI 2.2절(28 pt 캡슐, 20 pt 배지 `character`/`character.ko`, 14 pt medium 텍스트, 키캡). UX의 26 pt / 13 pt를 대체함. 배지 글리프는 어디서나 가/A임(일회성 배지, 메뉴 아이콘, `TISIconLabels.Primary = "가A"`). UX의 "한/A"를 대체함.
- **창:** UI의 패널을 쓰되, 잠금 화면보다 위에 뜨는 `CGShieldingWindowLevel()` 대신 `level = max(client.windowLevel() + 1, NSWindow.Level.popUpMenu.rawValue)`를 씀. `NSWorkspace.screensDidSleepNotification`과 `sessionDidResignActiveNotification`에서 숨김.
- **마우스 없음:** `ignoresMouseEvents = true`. v1에서는 UX의 "대안을 클릭해서 바꾸기"를 버림. 절대 활성화되지 않는 프로세스에서 마우스를 받는 패널이 필요하기 때문임. `.interactive()`가 아닌 `.regular` 글래스를 씀(클릭 통과).
- **캐럿 사각형:** `attributes(forCharacterIndex: 0, …)`를 쓰고, 안 되면 `firstRect(forCharacterRange: markedRange())`로 대체함. 매 키 입력마다 가져오지 않음. HUD가 막 보이려 할 때와, 보이는 동안 갱신할 때만 가져옴(R15).
- DET 9.3절의 "읽기가 바뀔 때 조합 문자열을 크로스페이드"는 **할 수 없음**. 조합 문자열은 클라이언트가 그리기 때문임. 움직임은 HUD에만 줌(UI의 자동 바꾸기 펄스).

### R13. 입력 메뉴
IMK는 `menu()`의 하위 메뉴를 무시해요 [참고 macSKK]. 그래서 UX의 "현재 앱 ▸ (라디오)"는 펼쳐서 한 단계로 만들어야 해요. 메뉴는 위에서 아래로 이렇게 구성해요.
1. `Duo 설정…`
2. 구분선
3. 비활성 헤더 `현재 앱: ‹name›`
4. 활성 항목에 체크 표시가 붙는 네 항목: 자동 · 한국어 우선 · English 우선 · 직접 입력
5. 구분선
6. `선택한 텍스트 한↔A 변환`
7. `✓ 힌트 표시`
8. `학습 일시 정지`
9. 구분선
10. `Duo 도움말`

UI의 "Flip Current Word ⇧Space" 항목은 버려요. 남긴다면 키 표시는 `FlipKey` 설정을 따라야 해요.

### R14. 동시성 구조
- **컨트롤러:** `@objc(DuoInputController)`, 얇게 만듦. 리드의 `@unchecked Sendable` 형태를 유지하거나 IMK D3을 씀. 어느 쪽이든 `MainActor.assumeIsolated` 전에 `event`, `sender`, `client`를 `nonisolated(unsafe)`로 **다시 바인딩**함(V6). 전체 타깃을 빌드함. 타입 검사만 하면 영역(region) 오류가 드러나지 않음(IMK 4.9절).
- **엔진(`DuoModel`):** 불변이고 mmap 기반인 `final class … : @unchecked Sendable`. 메인 스레드에서 **동기적으로** 점수를 계산함. 키 입력 경로 어디에도 `await`가 없음. 조합 문자열은 `handle`이 돌아가기 전에 설정해야 함(iTerm2 버그, IMK D5).
- **LearningStore:** UX 10절은 "모든 접근은 액터를 거침"이라고 함. 이는 동기 규칙과 **충돌함**. 결정: 메모리 내 딕셔너리를 담은 `@MainActor final class LearningStore`를 씀(점수 계산 중 동기적으로 읽음). 저장은 별도의 `actor LearningWriter`가 맡음. 이 액터는 `Sendable` 스냅샷 구조체를 받아 2 s 디바운스하고, 원자적으로 씀(`Data.write(options: .atomic)`). `applicationWillTerminate`에서 플러시함(`NSSupportsSuddenTermination = false`).
- **호스트 앱에서 하는 편집**(항목 삭제, 초기화): `{op, raw, ctx}`와 함께 `com.inkyuoh.Duo.learning.command`를 보냄. 입력기가 이를 적용하고, 파일에 쓰고, `com.inkyuoh.Duo.learning.changed`를 보냄. 실행 중인 입력기 프로세스가 없으면(`NSRunningApplication.runningApplications(withBundleIdentifier:)`로 확인) 호스트 앱이 파일에 직접 써도 됨.
- **컨트롤러별 상태와 공유 상태:** 단어 상태, 탭 감지기, `lastCommit`은 각 컨트롤러(클라이언트 세션마다 하나)에 있음. 엔진, 저장소, HUD, 설정은 `NSApp.run()` 전에 `main.swift`에서 만드는 싱글턴임.

### R15. 키 입력당 예산 (XPC)
모든 `client.*` 호출은 클라이언트 앱으로 가는 동기 XPC 왕복이에요. 키 입력당 예산은 이래요.
- 일반적인 경우 `setMarkedText` 또는 `insertText` 딱 하나, 그 밖에는 없음;
- `attributes(forCharacterIndex:)`는 HUD가 대기 중이거나 보이는 동안에만;
- `bundleIdentifier()`는 컨트롤러당 한 번.

UX 6.8절의 "`setMarkedText` 뒤에 `markedRange()`" 프로브는 키마다 하지 말고 **클라이언트 세션당 한 번**만 해요. 점수 계산 예산은 1 ms예요. Swift Testing 벤치마크(32키 단어에서 p99 ≤ 300 µs)를 추가해요. 그리고 Debug에서도 `DuoCore`를 `-O`로 빌드해요(패키지 타깃에 `SWIFT_OPTIMIZATION_LEVEL = -O`). 리드는 매일 Debug 빌드를 쓰고, `-Onone`은 10–50× 느려요.

### R16. 키보드 배열
DET의 `raw`는 ABC 배열 문자열이에요(소문자는 Shift 없이, 대문자는 Shift+키). IMK 4.2절은 라틴 문자를 `event.characters`에서 가져오자고 제안해요. 이러면 Dvorak을 따르게 돼요. 하지만 하나뿐인 공유 `raw`가 깨지고, E 단계에서 그대로 통과시키는 raw가 점수를 매긴 내용과 달라져요. **v1 결정:**
- `raw`는 `keyCode`(ANSI 위치)와 `.shift`로 만들고 `.capsLock`은 무시함(Caps Lock이 켜져 있으면 모든 키를 통과시킴);
- Gureum처럼 `activateServer`에서 `client.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.ABC")`를 호출함. 그래야 그대로 통과시키는 raw가 모델과 맞음;
- Dvorak과 Colemak은 v1 범위 밖이고, 문서에도 그렇게 적어야 함.

### R17. 텍스트를 바꿀 수 없는 클라이언트
`.unsupported` 클라이언트(iTerm2, Hyper, `com.jetbrains.WebStorm` 같은 Java/JetBrains)와 Terminal의 `.beforeCaretOnly`에는 이렇게 해요.
- 단어 전체를 조합 문자열로 유지하도록 강제하고 **즉시 E도 하지 않음**. 그래야 조합 중 바꾸기가 대체 범위 없이도 항상 동작함;
- 바꾸기 경우 (b)와 불확실한 확정 칩을 끔;
- Java 클라이언트에서는 `insertText(x)` 전에 `setMarkedText(x)`를 호출함.

### R18. 앱 호환 불변 규칙 (IMK와 UX에서 모아 둠. 아무도 찾아 헤매지 않게)
1. 조합 문자열은 `handle` 안에서 동기적으로 설정함. 키 이벤트당 `setMarkedText`는 한 번만 보냄(Chromium은 마지막 것만 적용함).
2. Return, Tab, Esc, 화살표, ⌘/⌃/⌥ 조합, Fn, F 키, 숫자에서는 먼저 `insertText(final)`을 하고 `false`를 돌려줌. `"\n"`을 직접 넣지 않음.
3. 대기 중(idle)에는 빈 `setMarkedText`나 `insertText`를 보내지 않음(Office). 진행 중인 조합을 빈 attributed string으로 지우는 건 괜찮음.
4. 항상 nil이 아닌 `NSAttributedString`을 넘기고, 속성도 nil이 아니어야 함(azooKey #385, 26.6.2에서 `CFEqual(NULL)` 크래시).
5. `selectionRange = (len, 0)`, 절(clause) 하나, `kTSMHiliteConvertedText`(밑줄 한 줄)를 유지함.
6. `kTISNotifySelectedKeyboardInputSourceChanged`를 관찰하고, 선택된 입력 소스가 Duo가 아니면 확정하고 숨김(macOS 26은 `deactivateServer`를 호출하지 않음).
7. 상태 재동기화: Duo는 조합 중이라고 생각하는데 `markedRange().location == NSNotFound`이면(예: Slack이 입력란을 비움) 단어를 조용히 버림. 매 키마다 추가 호출하지 말고, 다음 키가 올 때 미뤄서(lazily) 확인함.
8. 이 사용자가 실제로 쓰는 앱 기준의 수동 QA 우선순위: **Orca (Electron 터미널)**, cmux, 두 곳 안의 Claude Code CLI, VS Code/Cursor, Slack, KakaoTalk, Chrome, Notes/TextEdit, iTerm2, WebStorm, Spotlight.

### R19. 모드를 둘까 말까: 정하기 전에 실험하기
IMK D2는 모드를 추가하라고 권해요("지금 결정"). 아직 외부 사용자가 없어서 영향을 받는 건 리드의 머신뿐이에요. 진짜 위험은 새 모드 ID를 로그아웃 없이 선택하지 못할 수도 있다는 점이에요(Apple DTS는 시스템 설정에는 로그아웃이 필요하다고 해요. TIS는 필요 없을 수도 있어요). **결정:** 리드가 타이핑하지 않을 때 빠른 실험을 한 번 해요.
1. 번들을 등록함;
2. 부모를 켜고, 그다음 모드를 켬;
3. TIS로 `…Duo.Bilingual`을 선택함;
4. TSM 경로 하네스로 타이핑함(U1).

로그아웃 없이 동작하면 모드를 채택해요. 그렇지 않으면 v1은 모드 없이 내보내고, `TISIconLabels`, `TISIconIsTemplate`, 아이콘을 최상위에 설정해요.

어느 쪽이든 이렇게 해요.
- `LSBackgroundOnly` → `LSUIElement`;
- `CFBundleName` = `Duo` (R6);
- v1에서는 `TISDoubleSpaceSubstitution`을 빼 둠(아무도 테스트하지 않은 시스템 동작이 추가됨);
- `TICapsLockLanguageSwitchCapable = false`를 유지함.

### R20. 빌드 설정 (V5)
`project.yml`의 `DuoInputMethod` 타깃에 다음을 설정해요.
- `ENABLE_DEBUG_DYLIB: NO`
- `ENABLE_PREVIEWS: NO`

`DuoCore`/`DuoKit` SPM 제품은 정적으로 유지하고, `type: .dynamic`은 쓰지 않아요.

Release에서 hardened runtime을 유지한다면 규칙 두 개가 따라와요.
- 내장 입력기를 호스트 앱보다 **먼저** 서명함;
- `codesign --deep`은 절대 쓰지 않음.

따로 서명한 애드혹 dylib은 hardened runtime에서 거부돼요.

### R21. 모델 패키징과 라이선스
- `Tools/ModelBuilder/out/duo-model.bin`(5 632 872 바이트, 내용 해시 `aa722069c1e3076e`)을 `DuoInputMethod/Resources/duo-model.bin`으로 복사함. **바이너리를 커밋함.** 말뭉치는 gitignore되어 있고, 다시 빌드하려면 약 200 MB를 내려받아야 함.
- 호스트 앱의 프로세스 내 연습장(playground)은 **내장 입력기 번들**(`Contents/Library/Input Methods/DuoInputMethod.app/Contents/Resources/duo-model.bin`)에서 모델을 불러옴. 그래서 두 번째 사본이 없음.
- 내용 해시는 런타임이 아니라 단위 테스트에서 확인함.
- CC-BY-SA-4.0 저작자 표시(DET 2절)를 `DuoInputMethod/Resources/duo-model.LICENSE.txt`와 설정 ▸ 정보 ▸ 감사의 글에 넣음.
- `test_vectors.json`(2.46 MB)을 테스트 리소스로 `Packages/DuoCore/Tests/DuoCoreTests/Resources/`에 복사함.

---

## 3. P2: 합칠 것과 작은 빈틈

- **온보딩:** UI의 4단계 틀에 UX 내용을 채움:
  1. 환영: 히어로 모프(morph)와 실시간 입력란.
  2. Duo 켜기: `InputSourceManager`를 통한 "Duo 켜기". 딥 링크(V8)는 대체 수단.
  3. 써 보기: UX의 연습 과제 4개와, `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)`를 쓴 오른쪽 ⌘ 감지. 8 s 안에 탭이 감지되지 않으면 다른 방법을 제안함.
  4. 완료.

  UX의 타이핑 스타일·개발자 토글은 설정으로 옮기고, 기본값은 R8과 R10을 따름. 문구는 String Catalog에 한국어를 먼저 넣음(프로젝트 `developmentLanguage: ko`).
- **연습장 이중 처리.** Duo가 선택되어 있고 *동시에* 연습장도 프로세스 내 엔진을 돌리면 키가 두 번 처리됨. **결정:**
  - Duo가 선택된 입력 소스가 아니면 `inputContext`가 `nil`을 돌려주는 커스텀 `NSView`를 씀. 이 뷰는 DuoCore의 리듀서(reducer)에 입력을 넣고, 조합 문자열을 직접 그림.
  - Duo가 선택되면 실제 입력기가 동작하도록 평범한 `NSTextView`로 바꿈.
  - 바꾸기 도전 과제는 `com.inkyuoh.Duo.event.flipped`를 들음.
- **설정 창(pane):** 일반(상태와 문제 해결 행, 바꾸기 키, 힌트, Backspace 단위 자소/글자, 기본값이 OFF인 "` → ₩" 토글, 언어 편향 슬라이더), 앱(앱별 프로필), 학습(토글, 사전 표, 초기화), 정보(개인정보 문구와 감사의 글). 이는 UI의 3개 창과 UX의 6개 창을 대체함.
- **UI 부록의 `InputSourceStatus`:** 지우고 `DuoKit.InputSourceManager`를 씀. 이 타입은 임시값 `app.duo.inputmethod`로 걸러 냄.
- **학습된 단어 행:** 결과 열은 `render(raw, argmax over the learned hypotheses)`임. 행은 `(raw, ctx)`마다 하나이고, `raw`로 묶어서 보여 줌.
- **ScreenCaptureKit:** UI 5절에서 본 권한은 "책임(responsible)" 프로세스(터미널이나 에이전트 호스트)에 속함. 우리 창에만 쓰고, 쓰기 전에 `CGPreflightScreenCaptureAccess()`로 확인하고, 사용자 화면이나 메뉴 막대는 절대 캡처하지 않음. CI와 `xcodebuild` 실행은 `ImageRenderer`와 스냅샷 대체물, `cacheDisplay`에 의존해야 함.
- Apple 번역 앱과 **아이콘이 닮은 점:** 위험 낮음. UI의 대안(쪼개진 키캡)을 유지함.
- **v2 백로그**(변경 없음): ⌥Return으로 한자, KO→EN 재분할(앱store), `카톡ID`, 세벌식(3-Set) 배열, 웹사이트별 사전 확률.

---

## 4. 중요하지만 아직 확인 안 된 주장 (가장 싼 테스트와 함께)

| # | 주장 | 의존하는 곳 | TCC 없이 확인하는 방법 |
|---|---|---|---|
| U1 | 실제 오른쪽 ⌘ `flagsChanged`(keyCode 54, raw `0x100010`)가 Cocoa, Chromium/Electron(Orca, VS Code), Terminal에서 TSM을 거쳐 Duo의 `handle`에 도달함. Squirrel의 Shift 탭은 Cocoa에 대한 실사용 증거임. | R3 (기본 바꾸기 키) | IMK 7.1절을 써서 DuoHarness에 TSM 경로 모드를 추가함(`type = .flagsChanged`, flags `0x100010`인 `CGEvent` 키보드 이벤트를 만들고 `window.sendEvent(NSEvent(cgEvent:))`를 호출함. `open`으로 띄운 활성 호스트에서 함). Duo가 `.debug`가 아닌 `.info`로 로그를 남기는지, 또는 디버그 알림을 보내는지 검사함. 다른 앱은 사람이 확인해야 함: `log stream --predicate 'subsystem == "com.inkyuoh.inputmethod.Duo"'`로 5분 동안 수동 확인. |
| U2 | `NSSecureTextField`와 웹 암호 필드에서, ASCII 입력 가능한 입력기에 대한 TSM의 동작. | R5 | 같은 TSM 경로 하네스에서 `NSSecureTextField`를 first responder로 둠. Duo의 `handle`이 실행되는지, `IsSecureEventInputEnabled()`가 true인지 확인함. |
| U3 | 모드 기반 plist를 26.6.2에서 로그아웃 없이 선택할 수 있음. | R19 | R19에 설명한 실험. |
| U4 | `TISIconLabels.Primary`가 서드파티에도 효과가 있음. | 아이콘 다듬기 | 우선순위 낮음. 사람이 메뉴 막대를 봄. 화면은 캡처하지 않음. |
| U5 | `TISEnableInputSource`를 처음 실행할 때 시스템 설정 확인 창이 한 번 뜸. | 온보딩 2단계 | 깨끗한 사용자 계정에서 관찰함. 2단계는 확인 창이 떠도 문제없게 설계함(1 s마다 상태 확인). |
| U6 | Swift 점수 계산이 키 입력당 ≤ 10 µs임(DET가 Python 0.04–0.13 ms에서 추정함). | R15 | R15의 벤치마크 테스트. |
| U7 | 즉시 E와 M(b) 조건(R1)이 DET의 정확도를 유지함. | R1 | DET가 평가 세트를 Python `phase_trace`로 재생함. 정확도, 되돌릴 수 없는 확정 오류, 경계에서의 조합 문자열 길이를 보고함. |
| U8 | Orca(Electron, xterm.js)가 조합 문자열과 확정 후 Return을 마지막 글자 중복 없이 처리함. | R10, R18 | 사용자의 주 터미널인 Orca에서 수동 QA. UX 6.6절의 `returnAsCR` 플래그를 준비해 둠. |
| U9 | `isIncrementalSearchInputContext`와 기타 비공개 클라이언트 셀렉터. | 검색 정책 | `responds(to:)`로만 프로브함. 출시는 번들 ID 목록으로 함. |

---

## 5. 위험 목록 (주요 항목)

| 위험 | 가능성 / 영향 | 완화책 |
|---|---|---|
| 즉시 K가 한국어 문맥에서 되돌릴 수 없는 엉터리 자모를 확정함(라틴 표시 정확도 80 %) | 높음 / 높음, UX D2를 적힌 대로 만들면 | R1 (즉시 K 기본 꺼짐) |
| 클릭 뒤 낡은 버퍼가 남아 유령 조합이 생김 | 확실 / 높음, 현재 `recognizedEvents`로는 | R4 |
| 암호 키 입력이 조합되거나 학습됨 | 중간 / 심각 (V2) | R5 + U2 |
| 입력기가 조용히 실행되지 않음(dyld Team-ID 거부) | 중간 / 높음 (V5) | R20 |
| 설정이 입력기에 닿지 않음(nil 스위트) | IMK 3.4절을 따르면 확실 (V4) | R6 |
| 한 문맥에서 학습한 바꾸기가 다른 문맥을 망침(어디서나 `go`→해) | 높음 / 중간 | R7 `(raw, ctx)` 키 |
| Electron 터미널(Orca)이 Return에서 마지막 음절을 중복하거나 빠뜨림 | 중간 / 이 사용자에게는 높음 | R18 #2, U8 |
| 동기 XPC 호출 때문에 느린 클라이언트에서 타이핑이 지연됨 | 중간 / 중간 | R15 |
| HUD가 잠금 화면 위에 뜸 | 낮음 / 중간 | R12 창 레벨 |
| macOS 26에서 프로그램으로 전환하면 `deactivateServer`가 호출되지 않음 | 알려짐 / 중간 | R18 #6 |
