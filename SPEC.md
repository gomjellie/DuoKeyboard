# Duo v1 — 구현 명세

Duo는 macOS 15 이상의 InputMethodKit 입력기예요. 키보드 하나로 한국어(두벌식)와 영어를 전환 없이 쳐요. 치는 동안 단어마다 두 언어의 읽기에 점수를 매기고, 사용자가 뜻한 언어로 확정해요. 드물게 틀리면 바꾸기 키나 후보 막대로 고치고, Duo는 그 선택을 학습해요.

이 문서는 엔진, 입력기, 호스트 앱이 지킬 규칙을 적은 구현 명세예요. 규칙이 바뀌면 코드와 함께 이 문서를 고쳐요. 코드 주석이 가리키는 `SPEC.md`의 절 번호(4.7절, 4.11절, 5절 B.6, 5절 C.1 등)는 이 문서의 절 번호예요. 그래서 1절부터 7절까지의 번호는 바꾸지 않아요.

**우선순위.** 이 문서가 가장 앞서요. 그다음은 `docs/research/critique.md`이고, 그 결정 R1–R21은 구속력이 있어요. 마지막은 연구 문서 네 개(`detection.md`, `ux-spec.md`, `imk-platform.md`, `ui-design.md`)예요. 연구 문서가 critique와 다르면 critique를 따라요. critique가 이 문서와 다르면 이 문서를 따라요. UX의 숫자 상수는 DET `meta.params`가 대체해요(R8). UX 9절의 표는 확인할 *기대 결과*이고 공식이 아니에요.

**약어.** DET는 `docs/research/detection.md`, UX는 `docs/research/ux-spec.md`, IMK는 `docs/research/imk-platform.md`, UI는 `docs/research/ui-design.md`예요. R·P·U·V로 시작하는 번호는 `critique.md`의 결정과 항목이에요. UX의 결정은 D1–D13으로 불러요. 점수 단위는 millinats(1/1000 nat)예요.

---

## 0. 저장소 구조

```
/
├─ Makefile                  # 개발 작업 (make help)
├─ project.yml               # XcodeGen 명세 → Duo.xcodeproj (생성물, git에 넣지 않음)
├─ CLAUDE.md                 # 커밋과 문서 규칙
├─ README.md                 # 제품 소개, 기능 둘러보기, 빠른 시작
├─ SPEC.md                   # 이 문서
├─ docs/
│  ├─ STATUS.md              # v1 진행 상황, 테스트 수치, 실제 앱 QA, 알려진 문제
│  └─ research/              # critique, detection, ux-spec, imk-platform, ui-design
├─ Packages/DuoCore/         # SwiftPM 패키지 (macOS 15, Swift 6 언어 모드)
│  ├─ Sources/DuoCore/       # 순수 엔진 (Foundation만): Hangul/, Contracts/, Detection/, Engine/
│  ├─ Sources/DuoKit/        # 입력기와 호스트 앱이 함께 쓰는 AppKit/Carbon 통합: HUD/, Host/, …
│  └─ Tests/DuoCoreTests/    # Swift Testing: 감지, 엔진, HUD 규칙, 저장, 설치. Resources/test_vectors.json
├─ DuoInputMethod/           # IMK 입력기 앱 (com.inkyuoh.inputmethod.Duo)
│  ├─ Sources/               # main.swift, App/, Controller/, HUD/, Debug/ (DEBUG 전용)
│  ├─ Resources/             # duo-model.bin, duo-model.LICENSE.txt, MenuIcon.tiff, Localizable.xcstrings, ko/en.lproj
│  └─ Info.plist
├─ Duo/                      # 호스트 앱 (com.inkyuoh.Duo): 온보딩, 설정, 연습장
│  ├─ Sources/               # App/, Onboarding/, Settings/, Playground/, Models/, Design/, Debug/
│  ├─ Resources/             # AppIcon.icon (Icon Composer), Localizable.xcstrings
│  ├─ Tests/                 # 호스트 앱 모델 테스트 (DuoTests 타깃)
│  └─ Tools/                 # check-strings.py (문자열 카탈로그 검사), MakeAppIcon.swift (앱 아이콘 생성)
├─ DuoHarness/               # E2E 하네스 앱 (com.inkyuoh.Duo.Harness)
├─ Tests/E2E/cases.json      # 실제 IMK 경로로 도는 E2E 사례 70개
├─ Tools/
│  ├─ ModelBuilder/          # 언어 모델 빌더 (Python 3 표준 라이브러리). detector.py, hangul.py가 기준 구현
│  ├─ IconGen/               # 입력 소스 아이콘 생성기 (make_menu_icon.swift)
│  ├─ scripts/               # build.sh, install-ime.sh, e2e.sh
│  └─ data/raw/              # 내려받은 말뭉치 (git에 넣지 않음)
└─ build/                    # 빌드 산출물 (git에 넣지 않음): spm/, dd/, e2e/, Release/Duo.app
```

- 도구: macOS 26.6.2, Xcode 27.2, Swift 6.4.2, XcodeGen 2.46.0, Python 3(표준 라이브러리만).
- 언어 설정: Swift 6 언어 모드, 엄격한 동시성 검사(`SWIFT_STRICT_CONCURRENCY: complete`). 패키지는 `swift-tools-version: 6.2`.
- 배포 대상: macOS 15.0. 버전은 `MARKETING_VERSION` 1.0.0.
  - macOS 26 전용 API(Liquid Glass `.glassEffect`, `.buttonStyle(.glass)`, `SliderTick`)는 `#available(macOS 26.0, *)` 안에서만 씀. 그 아래에서는 `.regularMaterial` 표면(테두리와 그림자), `.bordered` 버튼, 눈금 없는 100 단위 슬라이더를 씀.
  - macOS 15에서는 실행해 보지 않았음(확인한 환경은 26.6.2).
- 서명: ad-hoc(`CODE_SIGN_IDENTITY: "-"`)과 hardened runtime. 따로 서명한 디버그 dylib를 거부하므로 `ENABLE_DEBUG_DYLIB: NO`(R20, V5).
- 개발 언어: `ko`. 문자열은 String Catalog(`Localizable.xcstrings`)에 둠.

| 대상 | 값 (`DuoKit/DuoIDs.swift`) |
|---|---|
| 입력기 번들, 입력 소스 ID | `com.inkyuoh.inputmethod.Duo` |
| 호스트 앱 | `com.inkyuoh.Duo` |
| 하네스 | `com.inkyuoh.Duo.Harness` |
| 공유 설정 | `UserDefaults(suiteName: "com.inkyuoh.Duo.shared")`, 키 `settings.v1`(JSON 하나), `seenApps.v1`(최근 순, 200개까지) |
| 학습 파일 | `~/Library/Application Support/Duo/learning.json` |
| 로그 subsystem | `com.inkyuoh.inputmethod.Duo` (범주: `runtime`, `ime`, `menu`, `hud`, `learning`, `install`) |

| 명령 | 하는 일 |
|---|---|
| `make help` | 작업 목록을 보여 줌 |
| `make project` | `project.yml`에서 `Duo.xcodeproj`를 다시 만듦 (`xcodegen generate --quiet`) |
| `make test` | DuoCore와 DuoKit 단위 테스트 (`swift test`, scratch `build/spm`) |
| `make build` | 프로젝트를 만들고 DuoInputMethod, DuoHarness, Duo를 Debug로 빌드함 |
| `make build-release` | 프로젝트를 만들고 Duo를 Release로 빌드함 |
| `make install` | Debug 입력기를 빌드해서 `~/Library/Input Methods`에 설치함 (`install-ime.sh`) |
| `make e2e` | 설치하고 DuoHarness를 빌드한 뒤 실제 IMK 경로로 E2E 사례를 돌림 (`e2e.sh`) |
| `make app` | Release 호스트 앱을 `build/Release/Duo.app`에 둠 |
| `make model` | 말뭉치에서 언어 모델을 다시 만듦 (`python3 Tools/ModelBuilder/build_model.py`) |
| `make clean` | `build`와 `Duo.xcodeproj`를 지움 |

---

## 1. 제품 규칙 (요약)

1. **입력 소스 하나.** Duo는 ASCII를 칠 수 있는 입력 소스이고 ABC와 2-Set을 모두 대신함.
   - Caps Lock을 켜면 영어 대문자를 그대로 침(UX D9). 바꾸기 키가 Caps Lock이면 누를 때마다 바꾸기임.
   - 암호 칸에는 키를 그대로 넘김. 조합, HUD, 학습이 모두 없음(R5).
2. **단어 전체 조합**(R1). 단어는 글자 키가 이어진 묶음이고, 안에 `'`가 있을 수 있음(DET 4절).
   - 경계 키가 올 때까지 단어 전체를 조합 문자열로 둠.
   - 표시는 DET 접두 모드와 히스테리시스(`HYST` = 1500)로 정함.
   - 확정은 DET 최종 모드의 argmax로 정함(R2).
   - 영어 즉시 확정은 허용함(R1.2, 4.3절). 한국어 즉시 확정은 v1에서 끔.
3. **조용히 다르지 않음.** 확정한 읽기가 보이던 읽기와 다르거나 최종 모드 점수 차가 619 이하이면 마지막 단어의 후보 막대를 보여 줌(R2, 4.8절, 4.11절).
4. **바꾸기와 고르기.**
   - 바꾸기 키는 기본으로 오른쪽 ⌘ 톡임(R3). 경우는 셋임: 조합 중인 단어, 방금 확정한 단어(확인한 뒤 바꿈), 바꿀 것이 없음(다음 단어의 언어를 정함)(UX 5.2절, R11).
   - 단어를 치는 동안 다른 읽기가 그럴듯하면(P ≥ 5 %) 후보 막대가 스스로 뜸. `alwaysShowChoices`면 늘 뜸. 바꾸기 키를 누르면 어느 단어든 막대가 번호를 달고 뜸. 바꾸기 키는 막대를 차례로 돌고, 바꾸기 키를 누른 채 숫자(⌘3), 바꾸기 뒤의 숫자, 클릭으로 읽기를 고름(4.11절).
5. **학습**은 R7을 따름.
   - 표는 `(raw, ctx)`마다 셈. 바꾸기와 후보 고르기는 +3이고, 애매한 암묵 확정은 +1임. 반감기는 60일임.
   - 접두 모드와 최종 모드에 모두 씀.
   - 라틴 단어의 학습을 그 단어에 어미가 붙은 형태로 넘기는 일은 후보 막대의 점수에만 씀(4.11절).
6. **Apple 수준의 느낌:**
   - 깜박임 없음: 단어 중간에 읽기가 저절로 바뀌는 건 다른 읽기가 `HYST`보다 크게 앞설 때뿐임. 사용자가 정한 읽기는 자동으로 바뀌지 않음. 라틴 읽기를 고른 뒤 이어지는 어미만 예외임(4.11절).
   - 지연 없음: 점수 계산은 p99 300 µs 이하임. 보통은 키 하나에 XPC 호출을 한 번만 함(R15).
   - 놀람 없음: Backspace에 다른 기능을 겹쳐 싣지 않음.
   - UI는 Liquid Glass이고, 모든 문구를 현지화함(한국어 먼저, 영어 다음).

---

## 2. 아키텍처

```
Packages/DuoCore (SwiftPM, macOS 15, Swift 6 언어 모드)
  DuoCore  (순수, Foundation만)
    Hangul/      두벌식 오토마톤, Keystroke, 자판 표                         [A]
    Contracts/   공유 타입. 리드만 고침                                      [lead]
    Detection/   DuoDetector, DuoModel (DUOM v1 mmap), 문자 LM, 사전, 점수     [A]
    Engine/      CompositionEngine (+Typing, +Flip, +Commit, +Choice),
                 EngineState, FlipTapDetector, LearningStore, ClientProfile,
                 BufferTextClient, SelectionConverter                         [B]
  DuoKit   (입력기와 호스트 앱이 함께 쓰는 AppKit/Carbon 통합)
    DuoIDs, SettingsStore                          리드만 고침               [lead]
    InputSourceManager, InputMethodInstaller       (처음부터 있었음, D가 넓힐 수 있음)
    KeyEventMapper, LearningPersistence                                       [B]
    KeyScript (하네스 키 DSL)                                                 [C]
    HUD/         HUDGeometry, HUDTimeline, HUDPresentation, HUDSizing,
                 HUDAnnouncement, SelectionConversionCheck                     [C]
    ModifierRouting (입력기의 수정 키 규칙. 단위 테스트를 위해 DuoKit에 둠)       [C]
    Host/        HostFlow, HostRequest, InputMethodState, AppCatalog,
                 LearnedWords, LearningEditor, PlaygroundSession              [D]
DuoInputMethod/   IMK 앱: 컨트롤러 어댑터, HUD, 입력 메뉴, plist               [C]
Duo/              호스트 앱: 온보딩, 설정, 연습장                              [D]
DuoHarness/       E2E 하네스                                                  [C]
Tests/E2E/        E2E 사례 파일                                              [통합]
project.yml, Package.swift, Makefile, Tools/scripts                          [lead, 변경은 요청]
```

**입력기 프로세스의 런타임 객체.** `main.swift`는 `NSApplication`과 앱 델리게이트를 먼저 만들어요. 그다음 `NSApp.run()` 전에 `DuoRuntime.shared.start()`를 불러요. 첫 컨트롤러가 생기기 전에 아래 싱글턴이 모두 준비돼요.

- `DuoDetector`: 입력기 번들의 `duo-model.bin`을 mmap함. 파일이 없거나 깨졌으면 `nil`이고, 모든 키를 그대로 넘김(ABC로 쳐짐).
- `LearningStore`: `learning.json`에서 불러옴. `LearningWriter`가 저장함(5절 B.3, B.4).
- `DuoSettings`: `settingsChanged` 알림과 `activateServer`에서 다시 읽음.
- HUD 컨트롤러(`CompositionHUDController`) 하나와 `ModifierRouter` 하나.
- 강제할 자판 ID: `com.apple.keylayout.ABC`, 없으면 `com.apple.keylayout.US`(R16).

`DuoInputController`는 클라이언트 세션마다 하나씩 생겨요. 컨트롤러마다 `CompositionEngine` 하나와 `IMKTextClient` 하나를 가져요(R14). 감지기, 학습 저장소, 설정은 함께 써요.

**호스트 앱.** DuoCore와 DuoKit을 링크하고, `DuoInputMethod.app`을 `Contents/Library/Input Methods/`에 넣어요(`project.yml`). 연습장은 그 번들에서 모델을 불러와요(R21). Duo가 선택된 입력 소스가 아니면 연습장은 `BufferTextClient`를 상대로 `CompositionEngine`을 돌려요(`PlaygroundSession`).

**프로세스 사이 알림.** 모두 분산 알림(`DistributedNotificationCenter`)이고, 받는 쪽은 바로 전달받아요.

| 알림 | 방향 | 내용 |
|---|---|---|
| `com.inkyuoh.Duo.settingsChanged` | 설정을 저장한 쪽 → 다른 프로세스 | 설정 JSON이 바뀜. 내용 없음 |
| `com.inkyuoh.Duo.learning.command` | 호스트 → 입력기 | `op` = `remove`(`raw`, 선택 `ctx`) 또는 `removeAll` |
| `com.inkyuoh.Duo.learning.changed` | 입력기 → 호스트 | 학습 파일을 다시 씀. 저장에 실패하면 `ok` = `"false"` |
| `com.inkyuoh.Duo.event.flipped` | 입력기 → 호스트 | 단어를 바꿈. `to` = `korean` 또는 `english`. 글자는 보내지 않음 |
| `com.inkyuoh.Duo.ping` / `.pong` | 호스트 → 입력기 → 호스트 | 살아 있는지 확인. `pong`에 `version`, `modelLoaded` |
| `com.inkyuoh.Duo.host.showSettings` / `.showGuide` | 입력기 → 호스트 | 설정 창이나 안내를 엶. 호스트가 꺼져 있으면 `--duo-show-settings` / `--duo-show-guide`로 실행함 |

---

## 3. 계약 (트리에 있고 컴파일됨)

| 파일 | 내용 |
|---|---|
| `DuoCore/Contracts/DetectionContract.swift` | `Hypothesis`(K/E/M(b), `.key` "K"/"E"/"M3", `.language`), `ScriptLanguage`, `LanguageContext`(START/KO/EN/NUM), `Terminator`(S/D/H/P), `ScoredHypothesis`, `HypothesisScores`(`best`는 DET의 동점 규칙), `UserCounts`, `protocol LanguageDetector`(`finalScores`, `prefixScores`, `choiceScores`, `render`, `canAttachKorean`, `parameters`), `Margins` |
| `DuoCore/Contracts/EngineContract.swift` | `KeyEvent`(글자는 ANSI 위치, `Modifiers`, `isRepeat`, `isDeadKey`, `timestamp`, 테스트용 `KeyEvent.typing("…")`), `ModifierEvent`, `@MainActor protocol TextClient`, `ReplacementSupport`, `HUDRequest`(content/anchor/immediate/lifetime/pulse), `HUDReading`, `HUDChoice`(readings/selected/alternate), `CommitReason`, `EngineNotification` |
| `DuoCore/Contracts/SettingsContract.swift` | `FlipKey`, `BackspaceUnit`, `AppProfile`, `DuoSettings`(너그러운 Codable: 키마다, `appProfiles`는 앱마다 기본값으로 물러남), `LearningEntry`, `LearningSnapshot`(디스크 JSON 형식) |
| `DuoKit/DuoIDs.swift` | 번들 ID, 공유 설정 이름, 알림 이름, 파일 위치(R6) |
| `DuoKit/SettingsStore.swift` | 설정 읽기·저장·관찰, 본 앱 목록. 이 빌드가 모르는 키와 프로필은 저장된 그대로 둠 |

`Margins`는 확률 기준을 점수 차로 옮긴 값이에요(R8). 보이는 읽기와 가장 나은 다른 읽기, 두 읽기만 놓고 softmax를 계산해요.

| 이름 | 값 | 확률 | 쓰는 곳 |
|---|---|---|---|
| `Margins.uncertainCommit` | 619 | 다른 읽기 P ≥ 35 % | 확정 뒤 마지막 단어의 후보 막대 (4.8절) |
| `Margins.hudAlternative` | 1386 | 다른 읽기 P ≥ 20 % | 암묵 학습 +1 (4.8절) |
| `Margins.hudCandidates` | 2944 | 다른 읽기 P ≥ 5 % | 치는 중 후보 막대가 스스로 뜸 (4.11절 4) |
| `Margins.eagerCommit` | 4595 | 다른 읽기 P < 1 % | 영어 즉시 확정 (4.3절), 섞인 읽기가 진짜 경쟁자인지 (4.3절 7) |

`LanguageDetector.choiceScores`는 조합 중인 단어의 후보 막대에 쓰는 최종 모드 점수예요. 기본 구현은 `finalScores(…, terminator: .space, …)`이고 `DuoDetector`도 그 기본 구현을 써요. 후보 막대의 점수와 확정의 점수를 호출하는 쪽에서 구별하려고 요구 사항을 따로 뒀어요.

계약을 구현하는 타입은 아래와 같아요.

- `DuoDetector` [A]
- `CompositionEngine`, `ClientProfile`, `LearningStore`, `BufferTextClient`, `SelectionConverter`, `KeyEventMapper`, `LearningFile`/`LearningWriter` [B]

구현하는 쪽은 **본문을 채우고** API를 더할 수 있어요. 하지만 이미 선언한 시그니처는 모두 지켜야 해요. 계약 타입은 고정이에요. 꼭 바꿔야 하면 자기 파일에 shim을 두고 "계약 변경 요청"으로 보고해요.

---

## 4. 엔진 동작 (B가 구현함. 입력기와 연습장은 맞춰 붙이기만 함)

엔진의 상수는 아래와 같아요. 점수 상수는 3절 `Margins`에 있어요.

| 이름 | 값 | 뜻 |
|---|---|---|
| `HYST` | 1500 (`meta.params`) | 표시 히스테리시스 |
| `maxTokenLength` | 32 | 단어 하나의 최대 키 수 |
| `eagerMinimumKeys` | 3 | 영어 즉시 확정에 필요한 최소 키 수 |
| `latinSplitMargin` | 11 000 (11 nats) | 대문자가 한국어 단어를 끝내려면 K가 다른 읽기보다 이만큼 높아야 함 (4.3절 8) |
| `latinMergeMargin` | 6 000 (6 nats) | 대문자로 시작한 단어가 K로 이만큼 앞서면 앞 단어와 다시 합침 (4.3절 8) |
| `maxCandidates` | 5 | 후보 막대의 최대 읽기 수 |
| `candidateFloor` | 10 000 (10 nats) | 두 모드 모두에서 1등보다 이만큼 넘게 뒤진 읽기는 목록에서 뺌. 늘 넣는 읽기는 빼지 않음 (4.11절 2) |
| `segmentMinimumKeys` / `maxSegmentKeys` | 2 / 30 | 끝 읽기에서 앞부분과 끝의 최소 키 수 / 끝의 최대 키 수(`maxTokenLength − segmentMinimumKeys`) (4.11절 14) |
| `segmentHeadMargin` | 3 000 (3 nats) | 끝 읽기의 앞부분이 그 언어로 읽혀야 하는 접두 점수 차 (4.11절 14) |
| `segmentAutoKeys` | 10 | 이만큼 긴 단어는 키마다 끝 읽기를 찾음. 짧은 단어는 바꾸기 키를 쓴 뒤에 찾음 (4.11절 14) |
| `segmentMargin` | 6 000 (6 nats) | 끝 읽기가 첫 바꾸기 대상이 되려면 원래 읽기와 다른 문자 읽기를 모두 이만큼 앞서야 함. 막대를 스스로 띄우는 점수 차이기도 함 (4.11절 14) |
| `maxSegmentRows` | 2 | 후보 막대의 끝 읽기 최대 수 |
| `chipLifetime` | 4 s | 마지막 단어 후보 막대의 수명 |
| `lastCommitLifetime` | 30 s | 확정한 단어를 바꿀 수 있는 시간 |
| `LearningStore.flipVotes` / `implicitVotes` | 3 / 1 | 학습 표 |
| `LearningStore.halfLife` | 60일 | 학습 감쇠 |
| `LearningStore.capacity` | 20 000 | 학습 항목 상한 |

### 4.1 상태 (엔진마다)

- `token` (`Token`):
  - `raw`(ABC 문자열: 글자와 단어 안의 `'`), `count`, `ctx`(단어 시작 때 고정).
  - `committed`(이 문서의 c): 영어 즉시 확정으로 이미 라틴 문자로 확정한 앞쪽 raw 글자 수. 없으면 0.
  - `shown`: 화면의 읽기.
  - `scores`: 키마다 한 번 계산하는 접두 모드 점수. 표시, 즉시 확정, HUD, 바꾸기에 다시 씀. 즉시 확정 상태에서 키를 그대로 넘기는 동안은 `nil`.
  - `locked`, `lockedOriginal`: 바꾸기나 고르기로 정한 읽기, 그리고 처음 바꾸기 전에 보이던 읽기.
  - `lockedLatin`: 사용자가 E나 M(b)를 골라 라틴으로 확인한 키 수(4.11절).
  - `keptByChoice`: 후보 막대에서 보이던 읽기를 그대로 고름.
  - `choicesRevealed`: 단어를 치는 동안 바꾸기 키를 눌렀거나(오른쪽 ⌘/⌥) 어느 바꾸기 키로든 바꿨음. 단어가 끝날 때까지 막대가 번호를 달고 뜸(4.11절 5).
  - `languageLock`: 다음 단어 언어(4.7절 c)로 정한 언어.
  - `latinStart`: 한국어 단어를 끝낸 대문자로 시작한 단어(4.3절 8). K를 허용하지 않음.
  - `splitHead`: 그 대문자가 끝낸 한국어 단어와 넣은 글. 다시 열 때 씀. 확정한 글을 바꿀 수 있는 앱에서만 둠. 끝 읽기를 고를 때 확정한 한국어 앞부분도 같은 방법으로 둠(4.11절 14). 그때는 합칠 때 잠글 읽기(`joinReading`), 나누기 전 단어의 원래 읽기, 나누기 전 단어의 접두 모드 점수(`PrefixMemo`)도 둠.
  - `dotted`: 점 단어(4.6절). 영어로 확정한 단어를 끝낸 `.` 바로 다음 글자로 시작한 단어. K를 허용하지 않음.
  - `snakePiece`: `_` 조각(4.6절). 영어로 확정한 단어를 끝낸 `_` 바로 다음 글자로 시작한 단어. K를 허용하지 않음.
  - `segmentTail`: 끝 읽기를 골라 시작한 단어(4.11절 14). 학습하지 않음.
  - `marked`: 엔진이 마지막으로 보낸 조합 문자열(`""` = 없음).
  - `lastKeyAt`: 마지막 키의 `KeyEvent.timestamp`.
- `context` (`ContextTracker`):
  - 앞서 확정한 단어의 언어(K와 M은 한국어);
  - "바로 앞 글자가 숫자";
  - "문장 시작": 필드 시작, `.!?` 뒤의 공백(사이에 닫는 따옴표나 괄호가 와도 됨), Return, Tab, 화살표와 이동 키, 마우스나 포커스 변경 뒤;
  - "단어 시작";
  - 단어 시작에서 친 `.`의 수(`./`, `../`);
  - "영어 단어를 끝낸 `.` 바로 뒤", "영어 단어를 끝낸 `_` 바로 뒤", "영어 단어를 끝낸 `:` 바로 뒤", "단어 시작에서 친 `~` 바로 뒤".
- `literal`과 `literalLength`(L 단계, 4.6절), `literalAfterCommit`(점 단어 경계에서 시작한 L), `contextBeforeLiteral`(L을 시작한 키 앞의 문맥), `passNextRaw`(데드 키), `capsLockOn`, `bilingualLine`(Direct 프로필).
- `oneShot: ScriptLanguage?`.
- `lastCommit` (`LastCommit`):
  - `text`, `length`(UTF-16), `raw`, `context`, `hypothesis`;
  - `alternative`와 그 렌더 `alternativeText`;
  - `endLocation` = 넣은 직후의 `selectedRange().location`, `boundaryLength`;
  - `time`, `clientBundleID`;
  - `committedHypothesis`와 `committedVotes`: 처음 확정한 읽기와 그때 기록한 표;
  - `segmentsChecked`: 끝 읽기를 찾았는지(4.8절 2). `hypothesis`와 `alternative`는 단어 전체의 읽기이거나 끝 읽기임;
  - `eagerLatin`: 확정 전에 즉시 확정한 라틴 키 수. 바꾸기 (b)의 끝 읽기도 이 키들을 한국어 앞부분으로 읽지 않음;
  - `appliedVotes`: 지금 이 단어 몫으로 저장소에 있는 표;
  - `learnable`: 이 단어를 바꿔서 학습할 수 있는지.
- `tap` (`FlipTapDetector`): `settings.flipKey`에 맞춘 순수 톡 감지기.

### 4.2 새 단어의 문맥 (DET 4절, R9)

- 바로 앞 글자가 숫자이면 `NUM`.
- 문장 시작이면 `START`.
- 그 밖에는 앞서 확정한 단어가 K나 M이면 `KO`, E이면 `EN`. 앞선 단어가 없으면 `START`.

공백, 쉼표, 따옴표, 괄호는 문맥을 그대로 둬요. 앱이 그대로 친 글자(L 단계, Caps Lock, 데드 키 뒤)는 영어 단어로 쳐요.

`biasKO`는 프로필 사전 확률과 `settings.languageBias`(±1000)를 더해서 ±1500으로 자른 값이에요. 프로필 사전 확률은 koreanFirst +1000, englishFirst −1000, automatic과 direct 0이에요. 엔진은 감지기를 부를 때마다 `biasKO`를 넘겨요.

### 4.3 글자 키

1. **우회.** 아래 경우에는 진행 중인 단어를 먼저 확정하고 `false`를 반환함. 앱이 키를 처리함.
   - 보안 입력이 켜짐: 어댑터가 `CommitReason.secureInput`으로 확정하고 엔진을 더 부르지 않음(R5).
   - Direct 프로필이고 `bilingualLine`이 꺼짐. 프로필이 Direct로 바뀌기 전에 조합하던 단어도 먼저 확정함.
   - L 단계, `passNextRaw`(데드 키 다음 키), ⌘나 ⌃, fn과 글자 키.
   - Caps Lock이 켜짐(`flipKey == .capsLock`이면 예외).
   - ⌥ 글자: 확정하고 넘김. ⌥ 데드 키(⌥e, `` ⌥` ``, ⌥u, ⌥i, ⌥n)는 다음 키에 `passNextRaw`를 켬.
   - **Caps Lock 바꾸기 키(D9).** `flipKey == .capsLock`이고 잠금이 켜지면 앱은 그 글자를 대문자로 침. 그래서 엔진이 `key.latin`을 직접 넣고 키를 소비함. 엔진이 글자를 넣는 곳: 영어 즉시 확정 뒤의 꼬리, L, Direct. ⌥ 글자와 데드 키 다음 키는 그대로 넘김.
2. **상한.** 33번째 키에서 단어를 최종 확정하고(종결 키 S) 새 단어를 시작함.
   - **마지막 음절 넘기기:** 아래가 모두 맞으면 마지막 음절만 남기고 확정하고, 그 음절의 키로 새 단어를 시작함. 띄어 쓰지 않은 긴 한국어가 음절 중간에서 끊기지 않음(감서 + ㅇ → 감성, 영화 + ㅈ → 영홪 + ㅣ → 영화지).
     - 33번째 키가 대문자로 라틴 단어를 시작하지 않음(4.3절 8);
     - 모두 라틴으로 확정한 부분이 없음(c == 0)이고 마지막 키가 글자임;
     - 읽기(`locked`, 없으면 `shown`)가 K이거나, 마지막 음절 앞에 한국어가 남는 M(b)임;
     - 33번째 키가 마지막 음절을 바꿈: 받침을 더하거나(가 + ㅇ), 받침을 다음 음절로 넘기거나(강 + ㅏ), 모음을 합침(고 + ㅏ). 새 음절을 시작하는 키(같음 + ㅋ, 다 + ㅠ)에서는 넘길 것이 없고, 넘긴 음절만으로는 읽기가 나빠짐(dmaz).
   - 앞부분은 화면의 읽기를 그대로 넣음. 단어의 일부라서 최종 모드로 다시 매기지 않고, 학습, 확정 직후 막대, 바꾸기 경우 (b)도 없음(4.3절 8의 앞 단어 확정과 같음). 새 단어는 `languageLock`을 이어받음.
3. **새 단어.**
   - `ctx`를 4.2절대로 정함.
   - `oneShot`이 있으면 그 언어를 단어의 `languageLock`으로 옮기고 `oneShot`을 지움. 그 언어의 읽기만 허용하고, 히스테리시스는 그 안에서 돔.
   - `shown` = `languageLock` 언어의 순수 읽기(K 또는 E). 없으면 `ctx == .english ? E : K`(DET "문맥 초기화").
   - 글자 키를 받을 때마다 `lastCommit`을 지움. 앞 단어의 바꾸기 경우 (b)가 끝남.
4. **덧붙이고 점수 매기기.** 키를 덧붙이고 `prefixScores`를 계산함. `user` = `learning.counts(raw, ctx)`(학습을 끄면 `nil`).
   - **일관된 읽기:** c > 0이면 `E`와 b ≥ c인 `M(b)`만. c == 0이면 모두. **허용되는 읽기**는 여기에 `languageLock`의 언어 조건을 더한 것임. `latinStart`(4.3절 8), `dotted`, `snakePiece`(4.6절)이면 K를 빼고, 숫자 뒤가 아니면 소문자 한 글자 + 접미사인 M(1)(a양, `Token.isChoiceOnly`)도 뺌. 이 M(1)은 바꾸기 키와 후보 막대로만 고름. 스스로 고르면 ask → a나, ㄱ씨는 → r씨는처럼 틀렸음(DET 매개변수 `MIX_INITIAL`과 함께 detection.md 참고).
   - 라틴을 고른 뒤라면 어미 규칙(4.11절 7)을 먼저 적용함.
   - **히스테리시스(DET 5.6절).** 잠겼으면 `shown = locked`. 아니면:
     - `shown`이 허용되지 않거나 점수가 없으면 `shown` = 허용되는 읽기 중 `best`;
     - 아니면 `best.score − score(shown) > HYST`일 때 `shown = best`.
   - 키가 2개 이상이고 `shown`이 저절로 바뀌었으면 HUD `pulse`를 켬.
5. **즉시 확정 상태**(c == raw.count − 1: 이 키 앞은 모두 라틴으로 확정됨):
   - **다시 열기:** `raw`에 `'`가 없고 `detector.canAttachKorean(raw: raw, latinCount: c)`이면 키를 소비함. 점수를 매기고 `shown = E`에서 히스테리시스를 시작함. `render(shown)`에서 앞 c글자를 뺀 부분을 조합 문자열로 씀.
   - **그 밖:** 키를 그대로 넘기고(`return false`) c += 1. 앱이 글자를 넣음. 자판은 `overrideKeyboard`로 ABC임. 점수는 계산하지 않음.
6. **조합 상태.** 아래가 모두 맞으면 영어 즉시 확정을 함.
   - `settings.eagerEnglishCommit`;
   - `clientProfile.replacement != .none`(R17);
   - 잠기지 않음(`locked`도 `languageLock`도 없음), `shown == .english`;
   - 키가 3개 이상(`eagerMinimumKeys`);
   - 접두 모드에서 `score(E) − max(다른 일관된 읽기) ≥ Margins.eagerCommit`;
   - 마지막 키가 한국어가 붙을 수 있는 자음 키가 아님: `canAttachKorean(raw, count − 1)`이 거짓(`'`가 든 단어는 검사하지 않음). 그래야 `M(b)`가 일관된 채 남음(`reject` + 된);
   - 최종 모드(종결 키 S)의 argmax도 E임(R2). 접두 모드는 홀로 선 ㅠ/ㅜ에 벌점을 주지만, 최종 모드에서 `bb`/`nn`은 ㅠㅠ/ㅜㅜ임.
   - **맞으면** `insertText(raw[c...])`(소비), c = raw.count.
   - **아니면** `setMarkedText(render(shown).dropFirst(c))`(소비).

   뒤의 세 조건(키 수, 자음 키, 최종 모드)은 critique U7을 지키려고 더했어요. 배포 모델로 DET의 섞인 개발 채팅 세트를 돌리면, 앞의 조건만으로는 즉시 확정이 없을 때보다 단어 7개를 더 틀렸어요(99.35 % 대 99.86 %). 세 조건을 더하면 정확도가 즉시 확정이 없을 때와 같아요. 그래도 3키 이상인 영어 단어마다 약 71 %를 경계 전에 확정해요. 최종 점수 계산은 앞의 싼 조건을 모두 통과한 키에서만 해요.
7. **HUD.** 단어가 조합 중이고 `settings.showHints`이면 후보 막대(4.11절)를 담은 `.alternative`를 냄. 앵커는 `.markedText`임. HUD 자격(`eligible`)은 4.11절 4를 따름. 후보 막대를 만들 수 없으면 조합 중에 `hud = nil`.
   - 바꾸기 키의 대상(R11)은 늘 보이는 읽기와 렌더가 다름:
     - K를 보이면 E, 또는 진짜 경쟁자인 가장 나은 M;
     - E를 보이면 K, 또는 진짜 경쟁자인 가장 나은 M;
     - M을 보이면 E.
   - 진짜 경쟁자인 M: 다른 순수 읽기보다 점수가 높거나 같고, 보이는 읽기와의 차가 `Margins.eagerCommit`(P ≥ 1 %) 이하임.
   - 그렇지 않은 2등 섞인 읽기는 잡음임(사랑 → `tk랑`, test → `tesㅅ`). 바꾸는 사용자는 "이 문자 계열이 아님"이라고 말한 것이라 다른 순수 읽기를 원함. 진짜 섞인 단어(PR을, git을)는 이미 보이거나 이 검사를 통과함.
8. **쌍자음 없는 대문자**(한A, 삼성SDI). ⇧로 친 글자 키 중 두벌식에서 ⇧가 다른 자모를 만들지 않는 키(Q W E R T O P를 뺀 A–Z)는 라틴 대문자로 봄. 한국어를 칠 때는 이 키에 ⇧를 누를 일이 없음.
   - 근거: K, E, M(b) 중 한글 뒤에 라틴이 오는 읽기는 없음(DET 1절). 그래서 한 단어로는 한ㅁ이나 gksA만 나옴.
   - **나누기:** 아래가 모두 맞으면 진행 중인 단어를 확정하고 대문자로 새 단어를 시작함. 새 단어는 `latinStart`를 켬.
     - 단어가 있고, 모두 라틴으로 확정한 상태가 아니고, 바로 앞 키가 대문자가 아님. ㅆ 같은 ⇧ 자모 뒤에 ⇧를 늦게 뗀 경우(했 + D)는 겹쳐 누름이라 그대로 조합함. 모두 대문자인 단어(SKT)도 이 조건으로 나뉘지 않음;
     - 단어가 한국어로 읽힘: 사용자가 한국어를 골랐거나(`koreanChosen`), `shown == K`이고 접두 점수에서 K가 다른 모든 읽기보다 `latinSplitMargin`(11000) 이상 높음. 카멜 표기의 짧은 앞부분(to 새, do 애, did 양, db 유, z ㅋ)은 이보다 낮아서 한 단어로 남음(toString, doSomething). 한 키 단어(d, r, q)도 낮아서 ⇧를 일찍 누른 있어(`dLTdj`)가 그대로임;
     - `locked`가 E가 아니고 `languageLock`이 영어가 아님;
     - 대문자를 더한 `raw`의 접두 점수에서 허용되는 읽기 중 1위가 E가 아님. E이면 영어 단어 안의 대문자임(GitHub, iOS, McDonald).
   - **앞 단어 확정:** 화면의 읽기를 그대로 넣음. 대문자는 단어의 끝이 아니라서 최종 모드로 다시 매기지 않고, 학습 표, 확정 직후 막대, 바꾸기 경우 (b)도 없음.
   - **`latinStart`:** 허용되는 읽기에서 K를 뺌. E와 M(b)는 남아서 SDI, API를을 이어 침. 바꾸기 키는 K를 고를 수 있음(정말 한ㅁ을 칠 때).
   - **다시 열기** (`splitHead`가 있을 때. 앞 단어가 아직 조합 문자열 바로 앞에 있는지 `string(in:)`으로 확인하고, 4.7절 (a)처럼 조합 문자열을 먼저 지운 뒤 앞 단어 범위를 `setMarkedText`로 바꿈):
     - ⌫가 새 단어를 비우면 앞 단어가 다시 조합 중이 됨(`gksA` ⌫ `k` → 하나).
     - 새 단어의 두 번째 키부터, K가 허용되는 읽기보다 `latinMergeMargin`(6000) 이상 높으면 대문자는 잘못 누른 ⇧였음. 앞 단어와 다시 한 단어가 됨(안녕하세요의 G). 라틴 단어(A를, SDI가, API를, B마트)는 K가 1.7냇 넘게 앞서지 않음.
   - **나누지 않는 것과 한계:**
     - Q W E R T O P 대문자(ㅃㅉㄸㄲㅆㅒㅖ)와 소문자로 시작하는 라틴(`카톡id`)은 나누지 않음. 한국어로도 그럴듯해서임.
     - 두 키 이상인 단어에서 ⇧를 한 키 일찍 누르면 나뉨(`dhKTdj` → 오KT어). API, HR, IT처럼 Q W E R T O P가 이어지는 약어와 키로 구별할 수 없어서 약어를 택함. ⌫로 대문자를 지우면 다시 합쳐짐.

### 4.4 아포스트로피 `'` (DET 4절)

- **단어 안, L이 아님:** 단어가 32키 미만이고 E를 막는 잠금이 없을 때(`locked`가 없거나 E, `languageLock`이 없거나 영어) `prefixScores(raw + "'")`의 argmax가 E이면 `'`를 덧붙이고 `shown = E`로 함.
  - 4.3절처럼 조합 문자열로 쓰거나 즉시 확정하고 소비함.
  - 단어를 이미 모두 확정한 상태면 앱이 `'`를 넣음(c += 1).
- **그 밖:** 종결 키 P로 최종 확정하고 `'`를 넘김.
- **단어 없음:** 넘김.

### 4.5 경계 (그 밖의 모든 키), R18 #2

글자도 아니고 단어 안의 `'`도 아닌 키는 아래처럼 처리해요.

1. 같은 `handle` 호출 안에서 단어를 최종 확정함. `insertText` 한 번으로 넣고 `false`를 반환해서 앱이 키를 처리하게 함.
2. 종결 키:
   - `D`: 숫자 키(윗줄. 키패드 숫자도 숫자로 침);
   - `H`: `-`(키패드 포함);
   - `S`: 스페이스, Return, Tab, Esc, 화살표, 이동 키, Forward Delete, F-키, ⌘/⌃ 단축키, 알 수 없는 키;
   - `P`: 그 밖의 문장 부호, ⌥와 함께 친 키, 데드 키 다음 키.
3. `"\n"`이나 `" "`를 **절대** 직접 넣지 않음. 키를 넘김.
4. **특수 키:**
   - **Backspace (조합 문자열 있음):** 마지막 키 입력 하나(`jaso`)나 마지막 음절 블록의 키(`gulja`, K/M 읽기)를 지우고 다시 계산함. `shown`은 허용되지 않게 된 때가 아니면 그대로 둠(Backspace는 언어를 바꾸지 않음, UX 2.4절).
     - 고른 M(b)의 한국어 꼬리가 모두 지워지면 잠금은 E가 됨. 감지기가 점수를 주지 않는 M(b)라도 형태가 맞으면 그대로 둠.
     - 조합 문자열이 비고 c == 0이면 `setMarkedText("")`, 단어를 버리고 소비함.
     - 조합 문자열이 비고 c > 0이면 `setMarkedText("")` 후 소비함.
   - **Backspace (조합 문자열 없음):**
     - 모두 확정한 단어(c > 0)가 있으면 마지막 raw 글자를 지우고 c −= 1, 키를 넘김.
     - 단어가 없으면 넘김. `lastCommit`이 아직 바로 앞에 있으면(빈 선택, 캐럿 == end + boundaryLength) 유효하게 남고, 마지막 단어의 후보 막대가 다시 뜰 수 있음(4.8절). 아니면 `lastCommit`을 지움.
     - `.beforeCaretOnly` 클라이언트(Terminal)는 다시 맞춤. `caret − boundaryLength` 앞의 `len` 단위가 `lastCommit.text`와 같아야 하고, 그 자리가 새 끝이 됨. 확정 때 기록한 끝이 셸의 에코보다 늦을 수 있기 때문임.
   - **⇧Space, `flipKey == .shiftSpace`:** 바꾸고 소비함. ⌃⌥⌘ 없이 ⇧만 눌러야 함. 자동 반복은 바꾸지 않고 소비함. L에서는 평범한 스페이스임: L을 끝내고 넘김.
   - **`` ` ``, `graveTypesWon`:** 확정하고 같은 `insertText`로 `₩`를 붙여 넣고 소비함. `` ⌥` ``(데드 키)는 확정하고 `` ` ``를 넣고 소비함.
   - **Return이나 Esc, Direct에서 `bilingualLine`:** 확정하고 `bilingualLine`을 끝내고 넘김.
   - **바꾸기 키(오른쪽 ⌘·⌥)를 누른 채 숫자 1–9, 조합 중인 단어의 후보 막대가 있음:** `handle`이 맨 먼저 `selectReading`으로 그 번호의 읽기를 고르고 소비함(4.11절 5). 앱의 단축키로 넘기지 않음.
   - **⌘/⌃ 단축키:** 확정하고 넘김. 글자를 치지 않으므로 문맥은 그대로 둠. L은 끝냄.
   - **숫자 1–9, 번호 붙은 후보 막대가 보임(그 단어에서 바꾸기 키를 누르거나 고르기를 한 뒤):** 입력기와 연습장이 `handle`보다 먼저 `selectReading`으로 읽기를 고름(4.11절 5). `.notOnBar`이면 숫자는 엔진으로 가서 종결 키 D로 단어를 끝냄.

### 4.6 리터럴(L) 단계 (R9)

`literal`인 동안 글자와 키는 그대로 넘어가요. 조합 문자열은 없어요. 바꾸기 키와 후보 고르기는 점 단어 경계 바로 뒤(아래)가 아니면 아무것도 하지 않아요. L은 아래 키에서 끝나요(그 키는 넘겨요).

- 공백, Return, Tab, Esc;
- 트리거까지 지우는 Backspace(엔진이 L 시작 뒤 친 UTF-16 단위를 트리거 포함해서 셈), ⌥⌫. 조합 중인 단어 없이 친 트리거(`/ \ :`, 경로 머리 다음 `/`, `https:/`)를 지우면 문맥도 그 트리거 앞으로 돌아감. 그래서 같은 트리거를 다시 치면 L로 다시 들어감(`~/` ⌫ `/`);
- 화살표, 이동 키, ⌘/⌃/fn 단축키(⌘A ⌫, 다른 줄 처음으로 가기는 깨끗하게 시작함);
- 마우스, 비활성화, 보안 입력으로 하는 확정.

Forward Delete와 F-키는 L을 유지해요.

트리거는 아래와 같아요. 대부분 사용자가 단어 시작에 친 기호예요. 그 앞의 단어를 다시 정하지 않아요.

- **단어 시작:** `/ \ :`.
- **단어 시작의 경로 머리 다음 `/`:** `.` 한두 개(`./`, `../`)나 `~` 하나(`~/`) 바로 뒤의 `/`. L은 그 `/`부터 시작하고, L 길이도 `/`부터 셈. 그래서 `~/` 뒤 Backspace는 L을 끝내고 `~`만 남김. `/`를 다시 치면 L로 다시 들어감.
- **E로 확정한 단어 뒤 `:`, 그다음 `/`**(https://).
- **E로 확정한 점 단어 뒤의 `.`이 아닌 경계**(github.com/foo, example.com:8080, node.js,): 그 경계 키부터 L임. 점 단어는 아래에 있음.
- **단어 안의 `@`:** `raw`를 라틴으로 확정하고(K가 보였어도 E 렌더) `@`를 넘기고 L로 들어감. 전자 우편 주소로 봄. 한국 사용자의 아이디는 한국어 이름을 영문 자판으로 친 경우가 많음(dkssud@example.com).
- **`www` 다음 `.`:** 라틴으로 확정하고 `.`을 넘기고 L로 들어감.
- 사용자가 고른 한국어 읽기(K/M 바꾸기 잠금, 한국어 다음 단어 언어)는 `@`, `www.` 규칙보다 앞섬. 단어는 다른 문장 부호 앞처럼 고른 대로 확정되고 L은 시작하지 않음(ㅠ@ㅠ). 한국어 다음 단어 언어로 시작한 단어는 점 단어도 `_` 조각도 아님(hello.가).
- `@`, `www.`의 라틴 확정은 학습하지 않고 바꾸기 대상도 남기지 않음(`lastCommit = nil`).

아래 기호는 트리거가 아니에요. 자동으로 정한 결과를 늘 바꾸기 키로 고칠 수 있게 하려고 L을 쓰지 않아요.

- **`_`:** 다른 문장 부호처럼 단어를 끝냄(종결 키 P, 4.5절). 단어는 잠금과 고른 읽기를 따라 최종 모드로 확정하고, 학습하고, `lastCommit`을 남김. 그래서 `_` 바로 뒤의 바꾸기 키(4.7절 b)가 그 단어를 바꿈. `_` 뒤 조각은 새 단어이고 문맥은 앞 조각의 언어임(user_id, 보고서_최종.hwp, ㅠ_ㅠ).
  - **`_` 조각**(`Token.snakePiece`): 앞 조각을 E로 확정한 `_` 바로 다음 글자로 시작하는 단어. 접두 점수에서 K가 다른 모든 읽기보다 `snakeKoreanMargin`(6 000) 이상 앞서기 전까지 K를 스스로 고르지 않음. 바꾸기 키나 후보 막대로는 고름. 점 단어와 달리 경계에서 L로 들어가지 않음. 그래서 `max_len)` 뒤의 은도 조합됨. 예: src_dir, my_z, KakaoTalk_Chat_홍길동.
    - 근거: 배포 모델, 자동 프로필의 EN 문맥에서 혼자 한국어로 읽히는 조각(dir, fn)의 K 우위는 5.1냇 이하이고, 두 음절 한국어 단어(사랑, 안녕)는 둘째 키에서 8냇을 넘음. 흔한 한국어 단어 2000개를 영어 조각과 `_` 뒤에 치면 프로필마다 7~13개가 바꾸기 키를 기다림.
  - 첫 조각은 혼자 쓸 때처럼 읽힘(dir_name → 약_name, gh_token → 호_token, rm_rf → 그_rf). 한국어 뒤의 짧은 단어(go, so, do, to, db)도 `_` 앞에서 해, 내, 애, 새, 유로 읽힘. 공백 앞과 같은 모호성임. `_` 앞에서 바꾸거나, 확정한 글을 바꿀 수 있는 앱에서는 `_` 바로 뒤에 바꿈.
  - 키가 영어 같은 한국어 단어(해준, 겨우)는 영어 조각 뒤 `_` 다음에서 바꾸기 키가 필요함.
- **단어 시작의 `@`:** 넘기기만 함. 뒤의 이름은 보통 단어임(@홍길동, @param, @types/node).
- **단어 시작의 `~`:** 바로 뒤가 `/`가 아니면 문장 부호임(~하자, ~~강조~~).
- **`#`:** 문장 부호임(#맛집).

**점 단어**(`Token.dotted`)는 앞 단어를 E로 확정한 `.` 바로 다음 글자로 시작하는 단어예요. 확장자, 도메인 조각, 머리글자가 여기에 들어가요.

- 보통 단어처럼 조합함. 문맥은 EN임(4.2절).
- K는 바꾸기 키나 후보 막대로만 고름(`latinStart`와 같음). E와 M(b)는 스스로 고름(notes.txt라는, package.json에, L.A의).
  - 근거: 배포 모델의 최종 모드에서 ac(ㅁㅊ), gg(ㅎㅎ)가 K로 이김. 접두 모드에서 도메인과 확장자 조각의 K 우위는 7냇 이하였음.
- 접두 점수에서 K가 다른 모든 읽기보다 `latinSplitMargin`(11 000) 이상 앞서면 점 단어가 아님. `.`이 문장을 끝낸 것으로 보고 K를 허용함(ok.알겠어).
- `.`에서 E로 확정되면 다음 글자가 다시 점 단어를 시작함(news.example.com이네).
- `.`이 아닌 경계에서 E로 확정되면 그 경계 키부터 L임(위). M(b)로 확정되면 보통 문장 부호임.
- 그 L이 경계 키 하나만 친 동안은 바꾸기 키, 마지막 단어의 후보 막대 클릭, ⌘숫자가 4.7절 b처럼 점 단어와 경계를 바꾸고 L을 끝냄(op.gg/ → op.ㅎㅎ/). 확정한 글을 바꿀 수 없는 앱에서는 바꿀 수 없다는 안내를 띄우고 L을 둠. 다른 키를 치면 L 안이라 바꿀 수 없음.

L 안에서는 바꾸기 키가 점 단어 경계 바로 뒤가 아니면 아무것도 하지 않아요(4.7절). 남은 트리거마다 바꾸기 키가 닿는 곳은 아래와 같아요.

- 단어 시작 `/ \ :`, 경로 머리 다음 `/`, `https:/`: 사용자가 친 기호에서 L이 시작함. 그 앞의 단어는 보통 확정이라 L 전까지 바꿀 수 있음. L 안에서 친 글자는 고칠 수 없음.
- 점 단어 뒤 경계: 점 단어는 조합하는 동안 바꿀 수 있음. 경계 키 바로 뒤에도 바꿀 수 있음(경우 b). 그 뒤에 친 키가 있으면 L이라 바꿀 수 없음.
- 단어 안의 `@`, `www.`: 보이던 읽기를 라틴으로 바꿔 확정하고 `lastCommit`도 없음. 바꾸기 키로 고칠 수 없음. 그 전에 한국어를 골랐을 때만 고른 읽기가 남음.

### 4.7 바꾸기 (톡을 감지했거나 ⇧Space)

바꾸기는 먼저 HUD 요청을 지워요. L 단계에서는 점 단어 경계 바로 뒤(4.6절)에 (b)만 하고, 그 밖에는 아무것도 하지 않아요.

**(a) 진행 중인 단어가 있음.**
- 조합 문자열이 있고 마지막 키에서 1 s가 지났으면 먼저 `markedRange()`를 물음. 메뉴나 테스트처럼 이벤트 시각이 없으면 늘 물음. 클라이언트에 조합 문자열이 없으면 단어를 조용히 버리고 (b), (c)로 넘어감.
- 대상을 고르기 전에 `choicesRevealed`를 켬. 그래서 어느 바꾸기 키든 오른쪽 ⌘를 누를 때 보이는 막대(끝 읽기 포함)에서 대상을 고름(4.11절 5).
- 대상(`flipTarget`): 후보 막대(4.11절 2)에서 지금 읽기의 다음 읽기(`alternate`, 4.11절 1). 마지막 읽기 다음은 첫 읽기(원래 읽기)임.
  - 앞부분을 확정하는 끝 읽기(나누기 줄)는 원래 읽기에서 하는 첫 바꾸기일 때만 대상임. 그 밖에는 건너뜀;
  - 대상이 끝 읽기면 아래 대신 4.11절 14의 나누기를 함;
  - 끝 읽기로 시작한 단어를 원래 읽기(K)로 바꾸면 한국어 앞부분과 다시 합치고, 단어 막대에서 나누기 다음 읽기로 감(4.11절 14);
  - 막대는 원래 읽기, 첫 바꾸기 대상(4.11절 2. 보통 R11 대안) 순서로 시작하므로 첫 바꾸기는 그 대상으로 감. 읽기가 둘이면 두 읽기를 오감;
  - 막대가 없으면(고를 수 있는 읽기가 하나) 원래 읽기(`lockedOriginal ?? shown`)의 R11 대안. 바꿀 수 없는 이유를 보여 주려고 씀;
  - 처음 바꿀 때 `lockedOriginal = shown`.
- 대상이 즉시 확정한 라틴과 맞지 않으면(c > 0이고 일관되지 않음) 확정한 라틴을 다시 열어야 함:
  - `!clientProfile.canReplaceCommittedText`(4.10절)이면 `.cannotChange`를 보여 주고 아무것도 바꾸지 않음;
  - `R = (조합 시작 또는 캐럿) − c ..< (조합 시작 또는 캐럿)`: 확정한 c글자;
  - `client.string(in: R) == raw[0..<c]`인지 확인함. 다르면 `.cannotChange`;
  - 맞으면 조합 문자열이 있을 때 먼저 `setMarkedText("")`로 지우고, `setMarkedText(render(target), replacementRange: R)`, c = 0. NSTextView(TextEdit)는 조합 중에는 교체 범위를 무시하고 조합 문자열만 바꿈(실제로 확인함: thanks + 바꾸기가 thank소무ㅏㄴ이 되었음).
- 그 밖에는 `setMarkedText(render(target).dropFirst(c))`.
- 잠금: `locked = shown = target`, `lockedLatin` 갱신, `keptByChoice`와 `languageLock`을 지움. `.flipped`를 알리고 후보 막대를 다시 냄.

**(b) 단어가 없고 `lastCommit`이 유효함.**
- 유효 조건:
  - 같은 번들 ID;
  - 30 s 이내;
  - 그 뒤로 글자, 마우스, 포커스 변경이 없음;
  - 단어 자리의 빈 선택: `selectedRange().location ∈ {end, end + boundaryLength}`. `.beforeCaretOnly` 클라이언트는 캐럿에서 거꾸로 잼(단어 + 경계, 그다음 단어만). 끝이 에코보다 늦을 수 있기 때문임;
  - 그 자리 글자가 `lastCommit.text`로 시작함(UTF-16 단위로 정확히). 나머지는 경계임.
- 캐럿이 단어에서 떨어졌거나 선택이 있으면 (c)임.
- 캐럿이 단어에 있지만 `!clientProfile.canReplaceCommittedText`(Monaco, Orca)이면 읽기나 쓰기 전에 `.cannotChange`. 학습도 없음.
- `endLocation`이 없거나, 지금 `selectedRange()`가 없거나, 글자가 맞지 않으면 `.cannotChange`.
- 유효하면 `insertText(render(alt) + boundary, replacementRange: (start, caret − start))`. 어느 클라이언트에서나 캐럿이 경계 뒤에 남음.
  - 대안을 아직 끝 읽기와 견주지 않았으면(`segmentsChecked`가 거짓) 먼저 견줌(4.8절 2). 즉시 확정했던 라틴 키(`eagerLatin`)는 한국어 앞부분으로 읽지 않음. 조합 중의 바꾸기 (a)와 같음.
  - 학습: 이 단어가 지금까지 기록한 표를 취소함. 처음 확정한 읽기로 되돌리는 바꾸기면 그때의 표를 다시 기록함. 아니면 학습할 수 있을 때 `(raw, ctx)`의 alt에 +3. alt가 끝 읽기면 새 표는 없음.
  - 두 번째 톡이 되돌리도록 `lastCommit`을 바꿈(읽기와 대안을 맞바꾸고 시각을 갱신함). 문맥 언어를 alt의 언어로 하고 알림.

**(c) 그 밖.**
- `oneShot` = 문맥 언어의 반대. 문맥이 `EN`이면 한국어, 그 밖에는 영어임.
- HUD `.oneShot(lang)`: 즉시, 0.9 s.
- 이미 `oneShot`이 있으면 두 번째 톡이 취소함.
- Direct에서는 대신 `bilingualLine`을 켜고 끔(HUD `.bilingualLine`).

`.cannotChange`는 "여기서는 바꿀 수 없어요" 메시지예요. 즉시 나타나고 1.2 s 동안 보여요.

### 4.8 확정 (경계, 또는 `commit(_ reason:)`)

1. **고르기:**
   - `h = locked ?? finalScores(...).best(where: 허용됨)`. 허용되는 읽기가 없으면 허용될 때 `shown`, 아니면 E;
   - `text = render(h).dropFirst(c)`, 뒤에 붙는 글자(`₩`, `` ` ``)가 있으면 이어 붙임;
   - `insertText(text)`. 빈 글이고 조합 문자열도 없으면 보내지 않음(R18 #3).
2. **`lastCommit` 기록.**
   - 키로 확정할 때와 `commitComposition`일 때만, 그리고 단어에 대안이 있을 때만 기록함.
   - `endLocation`은 `replacement != .none`일 때 `selectedRange()`에서 가져옴. 확정 때만 생기는 XPC 호출 한 번임. Monaco도 위치는 알려 주므로 기록함. 그래서 캐럿이 단어에서 떨어진 바꾸기는 거기서도 (c)임.
   - `endLocation`이 `nil`이면 바꿀 수 없음(바꾸기가 `.cannotChange`).
   - 대안: 잠기지 않았으면 최종 모드 점수로 고른 R11 대안. 잠겼으면 `lockedOriginal`(h와 다를 때). `lockedOriginal`이 h와 같거나 없으면 접두 모드 점수로 고른 R11 대안.
   - 끝 읽기(4.11절 14)가 확정한 읽기 h와 그 대안을 최종 모드 척도로 모두 `segmentMargin` 넘게 앞서면 끝 읽기가 대안임. 끝 읽기 목록은 조합 중 막대와 같음(`listedSegments`: 최종 모드 1등과 10냇 이내, 글이 다른 것 2개까지). 잠기지 않은 단어 가운데 10키 이상(`segmentAutoKeys`)이거나 3의 막대가 뜰 확정에서만 확정할 때 찾음. 그 밖에는 바꾸기 (b)를 하거나 ⌫로 막대가 다시 뜰 때 찾음. 막대는 클릭과 바꾸기가 할 일을 보여 줌.
3. **마지막 단어의 후보 막대:**
   - 조건: 키로 확정함, `settings.offerUndoAfterCommit`, `canReplaceCommittedText`, `endLocation`이 있음, 잠기지 않음(`languageLock`도 없음), 그리고 아래 중 하나:
     - `render(shown)`이 확정한 글과 다름;
     - 최종 모드에서 다른 가장 나은 읽기와의 점수 차 ≤ 619;
     - 10키 이상이고, 대안이 끝 읽기이며, 단어 전체의 K 글이 안에서 깨짐: 글 끝의 자모 묶음 앞에 낱자모가 있음(`hasJamoBeforeItsEnd`. 중간에두히ㅑ노는 해당, 이거정말재밌는데ㅠ는 아님). 최종 모드는 맞게 친 채팅 끝의 ㅠ, ㅎㅎ를 외톨이로 깎으므로, 끝 읽기가 6냇 앞선다는 것만으로는 맞는 단어에도 막대가 떴음.
   - `hud = .flipLastWord`: 확정한 읽기와 대안을 담은 후보 막대(4.11절). `immediate`, `lifetime 4`, 앵커 `.location(end − len)`.
   - 아니면 `hud = nil`.
4. **학습.**
   - **잠김, 다른 읽기로 바꿈:** `locked != lockedOriginal`이면 `locked`에 +3.
     - 고른 읽기가 b ≥ 2인 M(b)이면 라틴 부분 `raw[0..<b]`에도 M(b) +3을 기록함(어간 표, 4.11절 8).
     - 원래 읽기로 되돌아가면 표가 없음.
   - **잠김, 보이던 읽기를 후보 막대에서 고름:** 이 경계의 최종 모드 argmax가 다른 읽기였으면 `locked`에 +3. 명시적인 고침이기 때문임.
   - **다음 단어 언어:** 최종 모드 argmax의 언어가 정한 언어와 다르면 h에 +3.
   - **잠기지 않음:** 최종 모드 점수 차 ≤ 1386이면 h에 +1.
   - **학습하지 않음:** `raw.count < 2`, 리터럴, Direct, 학습 끔이나 일시 정지, 보안 입력, 끝 읽기로 시작한 단어(`segmentTail`).
5. **문맥:** 문맥 추적기에 h의 언어를 기록하고 단어를 지움.
6. **이유:** `mouse`, `deactivate`, `secureInput`은 `lastCommit`도 지우고 문장 시작 문맥으로 둠. L, `passNextRaw`, `oneShot`, `bilingualLine`도 끝냄. `commitComposition`은 문맥을 그대로 둠.
7. **조합 문자열이 있는 `commit(reason)`은 먼저 `markedRange()`를 물음.**
   - 클라이언트가 조합 문자열이 없다고 하면 이미 조합을 끝낸 것임(문자열을 남겼거나 필드를 비움). 단어를 버리고 아무것도 넣지 않음.
   - IMK 콜백 밖(TIS 알림, 메뉴, 전역 모니터)에서는 클라이언트가 없다고 해도 입력기 어댑터가 자기 조합 문자열로 답함. 그 답은 낡았을 수 있기 때문임(4.9절).

### 4.9 견고성

- **다시 맞추기(R18 #7).** 단어가 조합 중이고 마지막 키에서 1 s 넘게 지났으면 키를 적용하기 전에 `client.markedRange()`를 확인함. `nil`이면 단어를 조용히 버림(넣지 않음). Caps Lock과 fn 확정도 먼저 같은 방법으로 맞춤.
- **Caps Lock과 fn.**
  - `flipKey != .capsLock`일 때 Caps Lock을 켜면 단어를 먼저 확정함(영어 잠금, D9, Apple 한국어 입력기와 같음).
  - 단어가 있을 때 fn(지구본)을 누르면 확정함. 이모지 선택기나 받아쓰기가 넣는 글자보다 단어가 앞에 옴.
  - 두 경우 모두 후보 막대를 먼저 지움.
- **톡 감지기(R3, `FlipTapDetector`).**
  - 준비: `keyCode == 54`(오른쪽 ⌥면 61)에서 `.command`(`.option`)가 꺼짐 → 켜짐. 다른 수정 키를 누르고 있지 않고, 왼쪽 장치 비트(⌘ 0x08, ⌥ 0x20)가 없음.
  - 발사: 같은 keyCode에서 플래그가 `flipTapWindowMs`(200–500, 기본 300) 안에 꺼짐. 그때도 다른 수정 키와 왼쪽 장치 비트가 없음.
  - 해제: 키다운, 다른 수정 키 변화, `pressedMouseButtons != 0`, 시간 초과. 후보 막대의 숫자 고르기와 클릭도 해제함.
  - 누르고 있음(`isFlipKeyHeld`): 오른쪽 ⌘(⌥)를 준비 조건대로 눌렀고 아직 떼지 않음. 시간 초과나 키다운으로는 꺼지지 않고, 떼거나 다른 수정 키가 바뀌거나 클릭하면 꺼짐. 다른 바꾸기 키에서는 늘 꺼져 있음.
  - keyCode 0은 무시함(원격 데스크톱 도구가 보냄).
  - `doubleShift`: 창 안의 ⇧ 톡 두 번. 두 번째는 첫 번째를 뗀 뒤 창 안에 눌러야 함.
  - `capsLock`: keyCode 57 `flagsChanged`마다 발사함.
  - `shiftSpace`: 키다운이라 엔진이 처리함(4.5절). 감지기는 발사하지 않음.
- `flagsChanged`는 **절대** 소비하지 않음.
- **수정 키 경로(입력기의 `ModifierRouter`, 규칙은 DuoKit `ModifierRouting`).**
  - Chromium/Electron은 `flagsChanged`를 두 번 보냄(약 2 ms 간격). 같은 keyCode와 장치 무관 플래그가 0.2 s 안에 다시 오면 복사본으로 보고 버림.
  - 수정 키를 넘기지 않는 클라이언트는 전역 `.flagsChanged` 모니터(권한 불필요)가 대신함. 그 세션이 IMK로 수정 키를 하나 넘기기 전까지만, 그리고 클라이언트가 맨 앞 앱이고 Duo가 선택됐을 때만 씀.
  - 누름과 뗌 사이에 윈도 서버가 센 키나 클릭(`CGEventSource.counterForEventType`)이 있으면 톡이 아니라 함께 누르기(chord)임. Cocoa 앱은 ⌘ 단축키를 입력기를 부르지 않고 메뉴로 보내기 때문임. 수정 키 이벤트보다 늦게 눌린 키는 다음 변화의 몫으로 넘김.
- **조합 범위를 믿을 수 없는 클라이언트(`IMKTextClient`).**
  - 세션의 첫 조합 문자열 바로 뒤에 `markedRange()`를 한 번 확인함. `NSNotFound`이거나 길이가 다르면 그 세션 동안 클라이언트의 "조합 없음"을 믿지 않고 자기 조합 문자열로 답함.
  - IMK 콜백 밖에서 묶은 클라이언트도 같음. 그 답은 낡았을 수 있음(TextEdit에서 확인함). 이 확인은 콜백 밖에서 하지 않음.

### 4.10 클라이언트 프로필 (`ClientProfile.forBundleIdentifier`)

| 기본값 | 번들 ID |
|---|---|
| **automatic + isTerminal** (R10) | `com.apple.Terminal`(replacement `.beforeCaretOnly`), `com.googlecode.iterm2`(`.none`), `com.stablyai.orca`, `com.cmuxterm.app`, `com.mitchellh.ghostty`, `dev.warp.Warp-Stable`, `net.kovidgoyal.kitty`, `org.alacritty`, `com.github.wez.wezterm`(모두 `.full`), `co.zeit.hyper`(`.none`) |
| **englishFirst** | `com.apple.dt.Xcode`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`(Cursor), `dev.zed.Zed`, `com.sublimetext.4`, `com.panic.Nova`, `com.barebones.bbedit` |
| **englishFirst** (Java) | `com.jetbrains.*`, `com.google.android.studio`(`.none`, `needsMarkBeforeInsert`) |
| **koreanFirst** | `com.kakao.KakaoTalkMac`, `com.hancom.office.hwp*`, `jp.naver.line.mac` |
| **automatic** | 그 밖의 모든 앱(`.full`) |

터미널은 2026-11-08부터 automatic이에요(처음에는 englishFirst). Duo 사용자는 한국어에 영어를 섞어 쓰고, 터미널에서도 한국어 프롬프트를 많이 쳐요. 터미널 명령과 프롬프트 70줄은 세 프로필에서 똑같이 쳐졌고, 실제 카카오톡 대화는 englishFirst에서 문장 정확도가 1.4–1.6 %p 낮았어요.

Direct는 기본값이 아니에요. 입력 메뉴나 설정에서 직접 골라야 해요. 사용자가 고른 프로필(`settings.appProfiles`)이 기본값보다 앞서요. 알려지지 않은 앱도 `.full`로 시작하지만, 바꾸기는 모두 쓰기 전에 확인해요.

`canReplaceCommittedText`는 아래 앱에서 `false`예요.

| 이유 | 번들 ID |
|---|---|
| replacement `.none` | iTerm2, Hyper, JetBrains IDE, Android Studio |
| Monaco: `setMarkedText`와 `insertText` 모두 `replacementRange`를 무시함(실제로 확인함) | `com.microsoft.VSCode`, `com.microsoft.VSCodeInsiders`, `com.todesktop.230313mzl4w4u92`(Cursor), `com.vscodium`, `com.exafunction.windsurf`, `com.visualstudio.code.oss` |
| xterm.js: 셸에 확정한 글자를 바꿀 수 없음(`xtermTerminals`) | `com.stablyai.orca` |

`canReplaceCommittedText`가 `false`이면 아래처럼 동작해요.

- 즉시 확정한 라틴을 다시 열지 않음. 그 라틴과 맞지 않는 읽기로 바꾸면 `.cannotChange`(4.7절 a).
- 확정한 단어를 바꾸지 않음. 캐럿이 단어에 있으면 `.cannotChange`(4.7절 b).
- 마지막 단어의 후보 막대를 띄우지 않음(4.8절).
- 후보 막대는 즉시 확정한 라틴과 맞는 읽기만 보여 줌(4.11절).
- 조합 중인 단어는 그대로 바꿀 수 있음.
- `replacement != .none`이면 영어 즉시 확정은 그대로 함. IntelliSense가 실제 글자를 봐야 하기 때문임.

Orca에서는 확정한 단어를 바꾸면 새 읽기가 옛 읽기 뒤에 붙었어요(사용자 보고: 이상하게dltkdgkrp). 조합 문자열은 잘 동작해요. Orca 말고 다른 xterm.js 터미널은 확인하지 않았어요. 그래서 `xtermTerminals`에는 Orca만 있어요. Monaco 편집기 가운데 기본값이 영어 우선인 앱은 VS Code와 Cursor뿐이에요. 나머지는 `.automatic`이에요.

### 4.11 후보 막대 (`HUDChoice`)

단어를 치는 동안 그 단어의 읽기들을 보여 줘요. 다른 읽기가 그럴듯하면 막대가 스스로 뜨고, 설정(`alwaysShowChoices`)을 켜면 Pinyin 입력기의 후보 창처럼 단어마다 첫 키부터 떠요. 어느 쪽이든 바꾸기 키를 누르면 번호를 달고 떠요. 바꾸기 키는 막대를 왼쪽부터 차례로 돌고, 첫 바꾸기는 보통 R11의 대안으로 가요(2). 끝만 다른 문자로 읽는 읽기(14)가 원래 읽기와 다른 문자 읽기를 모두 6냇 넘게 앞서면 첫 바꾸기가 그 읽기로 가요. 4키 이상이면 짧은 단어도 그래요(사지너ㅔㅎ → 사진jpg). 이 절은 critique R12의 "마우스 없음"을 대체해요.

1. **내용.** `.alternative`(조합 중인 단어)와 `.flipLastWord`(방금 확정한 단어)는 `HUDChoice`를 담음:
   - `readings`: 표시 순서대로 놓은 `HUDReading`(글과 언어). 두 개 이상. 끝 읽기(14)는 단어 전체의 글과 끝의 언어를 담음;
   - `selected`: 문서에 있는 읽기의 위치;
   - `alternate`: 바꾸기 키가 바꿀 읽기의 위치(`selected`의 다음, 끝에서는 0). 앞부분을 확정하는 끝 읽기 줄(`ChoiceReading.split`)은 건너뜀. 다만 원래 읽기(0)에서 1번 줄은 건너뛰지 않음(첫 바꾸기 대상이 그 줄일 때);
   - `numbered`: 숫자 키가 읽기를 고름. 그 단어에서 바꾸기나 고르기를 했거나(`locked != nil`) 바꾸기 키를 눌렀을 때(`choicesRevealed`)만 켬.
2. **조합 중인 단어의 목록**(`choiceList`):
   - 늘 넣음: 원래 읽기(`lockedOriginal ?? shown`), 첫 바꾸기 대상, 원래 읽기의 R11 대안(접두 모드), 보이는 읽기, 라틴을 고른 뒤의 라틴 + 어미 읽기 `M(lockedLatin)`(그 뒤에 키가 있고 `'`가 없을 때);
   - 첫 바꾸기 대상: 원래 읽기의 R11 대안. 접두 모드의 R11 대안이 순수 읽기(K, E)이고 최종 모드 점수로 고른 R11 대안이 M(b)이면 그 M(b). 그 M(b)는 원래 읽기와 4.6냇(`Margins.eagerCommit`) 안이고 순수 읽기보다 높아야 함. 접두 모드는 단어 끝을 매기지 않아 M(b)를 묻었음. 실제 모델에서는 문장 시작이나 영어 뒤에서 헷가 → gpt가가 되고, 한국어 뒤에서는 gptrk가 먼저임. 끝 읽기(14)가 원래 읽기와 이 대상을 최종 모드 척도로 모두 `segmentMargin`(6냇) 넘게 앞서면 그 끝 읽기;
   - 그 밖에 접두 모드나 최종 모드(`choiceScores`)에서 점수가 있는 K, E, M(b) 가운데, 그 모드의 1등과 10 nats(`candidateFloor`) 이내인 읽기;
   - 끝 읽기(14)를 찾는 단어면 최종 모드 1등과 10 nats 이내인 끝 읽기를 점수 순으로 2개(`maxSegmentRows`)까지(`listedSegments`). 확정(4.8절 2)과 바꾸기 (b)도 같은 목록을 씀;
   - 즉시 확정한 라틴과 맞지 않는 읽기는 클라이언트가 그 라틴을 다시 열 수 있을 때만 넣음;
   - 렌더가 같은 두 읽기는 한 줄만 둠. 늘 넣는 쪽을 남김;
   - 순서: 원래 읽기, 첫 바꾸기 대상, 나머지는 접두 모드 점수가 높은 순(끝 읽기는 최종 모드 1등과의 차를 접두 모드 1등에 옮긴 값). 점수 없는 읽기는 뒤. 같으면 K, 끝 읽기, M(b)(b 오름차순), E(`displayRank`). 바꾸기 키가 이 순서로 돎;
   - 최대 5개(`maxCandidates`). 넘치면 늘 넣는 읽기가 아닌 것을 뒤에서부터 뺌;
   - 두 개 미만이면 후보 막대가 없음.
   - 단어가 그대로인 동안 바꾸기나 고르기는 선택만 옮기고 순서를 바꾸지 않음(원래 읽기가 고정됨). 짧은 단어는 바꾸기 키를 처음 쓸 때 끝 읽기가 더해짐(5). 클릭으로 고르기만 하면 더해지지 않음.
   - R11 대안을 앞세우는 이유: 점수 순으로 두면 잡음 섞인 읽기(사랑 → tk랑, 한글 → gks글)가 반대 언어보다 앞서기도 함. 섞인 읽기가 순수 읽기보다 6냇 넘게 앞서면 먼저 두는 규칙도 시험했지만, 내일(`sodlf`) → so일처럼 틀려서 버렸음.
   - 점수에는 라틴 앞부분의 학습을 넘긴 값을 씀(8).
3. **마지막 단어의 목록:** 읽기 두 개만 둠. 확정한 읽기와 그 대안(4.8절 2)임. 순서는 K, M(b), E(`displayRank`). 번호는 없음.
4. **HUD 자격**(`eligible`): 자동 반복 키가 아니고 아래 가운데 하나이면 얻음. 요청은 자격과 상관없이 늘 냄.
   - `alwaysShowChoices`가 켜짐. 첫 키부터, 읽기 점수 차와 상관없이 뜸;
   - 사용자가 그 단어의 읽기를 골랐음(`locked != nil`, 바꾸기나 고르기);
   - 단어를 치는 동안 바꾸기 키를 눌렀음(`choicesRevealed`, 5);
   - 접두 모드에서 목록의 다른 읽기가 보이는 읽기와 `Margins.hudCandidates`(2944, P ≥ 5 %) 안에 있거나, M(b) 읽기가 최종 모드(`choiceScores`)에서 그만큼 가까움. 그리고 단어가 2키 이상이거나 1키 충돌 단어(`a e i o u x`)임.
   - 10키 이상인 단어에서, 끝 읽기(14)가 보이는 읽기보다 최종 모드 척도와 접두 모드 척도 모두에서 `segmentMargin`(6냇) 넘게 높음. 끝이 한국어로 자음만이거나 ㅜ, ㅠ, ㅡ만인 읽기(ㅋㅋ, ㅇㅋ, ㅠㅠ, ㅡㅡ)는 빼고 셈. 접두 모드로도 견주는 이유: 최종 모드는 다음 키가 채울 음절(그런데요즘 + ㅇ)을 외톨이로 깎음.
   - 기다림 없이 다음 타이머 틱에 나타남(`HUDTimeline.Timing.appearDelay` = 0). 키 이벤트 안에서 바로 띄우면 입력기에서 패널이 화면에 오르지 않았음. 한번 뜨면 단어를 확정할 때까지 그 자리에서 갱신됨(5절 C.2).
   - 경위: 2026-11-07까지는 P ≥ 5 %일 때만, 300 ms 멈춘 뒤에 떴음. 2026-11-08 낮에 "바로, 늘 보여 달라"는 요청으로 늘 바로 뜨게 했음. 같은 날 밤 "늘 뜨는 것도 불편하니 필요해 보일 때만, 늘 보기는 설정으로"라는 요청으로 지금 규칙이 되었음.
5. **숫자 키.** 조합 중인 단어의 후보 막대는 그 단어에서 바꾸기 키를 누르거나 고르기를 한 뒤(`HUDChoice.numbered`)에 읽기에 1, 2, 3 … 번호를 닮. 그 전의 숫자는 글자임(갤럭시S24, 아이폰16, iOS26).
   - **바꾸기 키를 누르는 순간**(`isFlipKeyHeld`가 켜짐, `revealChoices`): 조합 중인 단어의 막대를 번호와 함께 띄움. 막대가 스스로 뜨지 않았던 단어도 뜸. 글자는 바꾸지 않음. 키만 떼면(톡) 지금처럼 다음 읽기로 바꿈.
   - 누르는 순간이 없는 바꾸기 키(⇧Space, ⇧ 두 번, Caps Lock, 메뉴)는 바꾸는 순간에 `choicesRevealed`를 켬(4.7절 a). 그래서 어느 키든 첫 바꾸기 대상이 같음.
   - **누른 채 숫자**(`readingChordIndex`): 바꾸기 키가 오른쪽 ⌘면 ⌘1–⌘9, 오른쪽 ⌥면 ⌥1–⌥9가 그 번호의 읽기를 고름. ⇧·⌃이나 다른 쪽 수정 키가 함께 눌렸으면 고르지 않음. 막대가 있으면 키를 늘 소비하고, 번호가 막대보다 크면 아무 일도 하지 않음. 고르기가 톡을 해제하므로 키를 떼도 바꾸지 않음. 막대가 화면에 보였는지는 보지 않음(사용자가 일부러 누른 조합 키임).
   - TextEdit와 Chrome에서 단어를 치는 중의 오른쪽 ⌘+숫자는 입력기의 `handle`에 옴(2026-11-08 확인). 앱 메뉴가 ⌘+숫자를 먼저 가져가는 앱에서는 이 조합이 오지 않음.
   - 번호 붙은 막대가 화면에 보이는 동안 윗줄 숫자 1–9(⌘⌃⌥ 없이)가 그 번호의 읽기를 고름(`HUDPresentation.readingIndex(for:)`).
   - 입력기는 막대가 페이드인(140 ms)을 마친 뒤부터 숫자를 받음(`CompositionHUDController.seenRequest`). 연습장은 번호가 붙었는지만 봄.
   - `.notOnBar`: 엔진이 그사이 요청을 바꿨거나 그 번호가 없음. 숫자는 글자로 쳐짐.
   - `.refused`: 클라이언트가 조합 문자열을 잃었거나 라틴을 다시 열 수 없음. 숫자는 막대를 겨눈 키라서 글자로 치지 않음. `.cannotChange`가 뜨면 VoiceOver도 읽음.
   - 마지막 단어의 막대에는 번호가 없음. 확정한 단어 뒤에 친 숫자는 글자임.
6. **고르기**(`selectReading(at:on:client:)`). `on`은 사용자가 본 요청임. 엔진의 지금 요청과 다르면 무시함(패널이 아직 옛 막대를 보여 줄 수 있음).
   - 조합 중인 단어: 조합 문자열이 있으면 먼저 `markedRange()`를 물음. 없으면 단어를 버리고 아무것도 바꾸지 않음.
   - 다른 읽기를 고르면 4.7절 (a)처럼 그 읽기로 바꾸고 잠금.
   - 보이는 읽기를 고르면 그 읽기로 잠금(`keptByChoice`). 확정 때 모델이 다른 읽기를 확정했을 것이면 +3을 기록함(4.8절 4).
   - 마지막 단어: 다른 읽기를 고르면 4.7절 (b)처럼 그 단어를 바꿈. 바뀌면 선택을 옮긴 막대를 같은 수명으로 다시 띄움. 사용자가 결과를 보고 되돌릴 수 있음. 바꾸기 창이 지났거나 캐럿이 움직였으면 `.cannotChange`를 보여 줌.
   - 다음 단어 언어(경우 c)는 켜지 않음. 클릭은 키 이벤트 밖에서 오므로 사라진 단어는 그대로 둠.
   - 학습은 바꾸기 키와 같음.
7. **라틴 뒤 어미**(`continueAfterLatinChoice`). 사용자가 앞 b키를 라틴으로 정하면(E나 M(b)를 고름) 그 뒤의 키마다 E와 M(b) 사이를 다시 정함.
   - 예: `cmd`(E로 고름) + `fh` → cmd로, 여기에 + `s` → cmds. `zlqhem` + `dms` → zlqhem은, 여기에 + `x` → zlqhemdmsx.
   - 어미(`render(M(b))`에서 b 뒤)는 완성된 한글 음절(U+AC00–U+D7A3)이어야 함. 낱자모가 남으면 영어를 이어 치는 것으로 봄.
   - 두 읽기에 점수가 있으면, E가 M(b)를 `HYST`보다 크게 앞서지 않는 한 M(b).
   - M(b)에 점수가 없으면(라틴 부분이 사전 단어가 아님), 키들이 여전히 영어로 가장 잘 읽히지 않는 한 M(b). 기준은 1등과 E의 점수 차가 `HYST`보다 큰지임.
   - 원래 읽기로 되돌린 뒤 바꾸기 키는 사용자가 마지막으로 고른 읽기로 감(cmd로 → 층로 → cmd로).
   - Backspace는 감지기가 점수를 주지 않는 M(b)도 형태가 맞으면 그대로 둠(zlqhem은 ⌫ → zlqhem으).
   - 사용자가 라틴을 고르지 않았으면 이 규칙은 없음. `cmdfh`는 그대로 층로임.
8. **라틴 단어 학습 넘기기**(후보 막대 전용):
   - **어간 표:** 바꾼 M(b)(b ≥ 2)를 확정하면 라틴 부분 `raw[0..<b]`에도 M(b) +3을 기록함. b키짜리 맨 단어는 M(b)를 점수로 매기지 않음. 그래서 go를을 골라도 다음 go는 그대로 해임.
   - **넘기기:** 후보 막대의 점수는 `userCounts(carryLatinPrefixes: true)`를 씀. `raw`의 라틴 앞부분(2키 이상, `raw`보다 짧음, `'`로 끝나지 않음)마다 그 앞부분의 E 표와 어간 표를 더한 값의 절반(올림)을 M(앞부분 길이)에 더함. 예: `cmd`에 E 3표 → `cmdfh`의 M(3)에 2.
   - 넘기기는 막대의 목록과 순서에만 씀. 표시와 확정은 단어 자신의 학습만 씀. 그래서 `cmd`를 영어로 배운 뒤에도 층로는 층로로 쳐지고, cmd로는 막대에 있어서 바꾸기 키나 숫자 키로 고를 수 있음.
9. **그리기**(입력기 HUD와 연습장이 같음):
   - 읽기마다 번호(조합 중인 단어), 16 pt 언어 배지(한 주황, A 파랑), 글;
   - 선택한 읽기는 그 언어 색을 입힌 알약 위에 둠. 마우스를 올린 것과 헷갈리지 않게 함;
   - 다른 읽기는 평범하게 둠. 읽기가 두 개면 포인터가 막대 위에 있을 때 다른 읽기에 옅은 중립 알약을 깖;
   - 읽기가 셋 이상이면 글을 더 짧게 자름(최대 폭 110 pt);
   - 끝에 바꾸기 키의 키캡. 오른쪽 ⌘와 오른쪽 ⌥는 "오른쪽 ⌘"처럼 쪽을 적음(영어 "Right ⌘"). 왼쪽 키도 기호가 같기 때문임;
   - 선택이 바뀌면 알약이 미끄러져 옮겨 감. 순서가 그대로이기 때문임.
10. **패널.**
    - HUD 패널은 후보 막대를 보이는 동안, 그리고 포인터가 캡슐 위에 있을 때만 클릭을 받음. 투명한 여백이 글자 쪽 클릭을 먹지 않음.
    - 첫 클릭을 키 창이 되지 않고 받음. 클라이언트가 포커스를 지킴.
    - 입력기 프로세스는 활성 앱이 되지 않음. 그래서 막대가 떠 있는 동안 mouse-moved 모니터(전역과 로컬, 권한 불필요)로 포인터를 따라감.
11. **포인터.**
    - 포인터가 막대 위에 있는 동안 수명이 다하지 않음.
    - 벗어나면 원래 마감에 숨지만, 그때부터 0.8 s보다 빨리 숨지는 않음.
    - 엔진이 요청한 숨기기(다음 키, 확정)는 그대로 일어남.
    - 배지와 메시지는 포인터를 받지 않음. 사라진 HUD는 포인터를 잊음.
12. **위치**(`HUDGeometry.followable`). HUD는 아래를 모두 만족하는 캐럿 사각형만 따라감:
    - 모든 값이 유한하고 비정규 수가 아님(1.6e-314 같은 XPC 쓰레기 값);
    - 주 디스플레이의 왼쪽 아래 모서리(가로 1 pt, 세로 한 줄 이내)도 클라이언트 창의 모서리도 아님(Chromium의 "캐럿 없음" 답);
    - 크기가 음수가 아니고 1000 pt 이하임;
    - 클라이언트의 화면 위 창 안에 있음(`ClientWindows`, 8 pt 여유). Finder를 위해 데스크톱 창도 넣음. 창을 모르면 받아들임;
    - 어느 디스플레이에도 없는 사각형은 위쪽 원점 y로 먼저 뒤집어 봄.
    - 아니면 HUD를 띄우지 않음.
    - `.location` 앵커는 단어의 사각형과 캐럿 줄이 다른 줄이면 캐럿 줄로 옮김(`HUDGeometry.wordRect`). TextEdit은 확정 직후 `firstRect`를 한 줄 어긋나게 답함. Return 뒤에는 캐럿이 정말 다음 줄에 있으므로 단어 사각형을 그대로 씀.
    - **xterm.js 터미널**(`ClientProfile.compositionAtFocusedElement`, Orca): `.markedText`와 `.caret` 앵커는 먼저 클라이언트의 포커스 요소 위치를 씀(`FocusedElementLocator`).
      - xterm.js는 조합 문자열 시작(조합이 없으면 커서)에 숨은 textarea를 둠. 그 요소가 `AXDOMClassList`에 `xterm-helper-textarea`를 가질 때만 그 `AXPosition`과 `AXSize`를 읽음. 글은 읽지 않음.
      - Orca가 IMK에 주는 사각형은 그 textarea 안의 글자 배치로 계산되어 단어마다 +15 … +102 pt(한 번은 −271 pt) 어긋났음. `firstRect`는 쓰레기 값을 돌려줌. 접근성 위치는 16개 단어 모두 화면과 맞았음(2026-11-08 실측).
      - 입력기에 손쉬운 사용 권한이 있어야 함. 없으면 지금처럼 IMK 사각형을 씀.
      - 읽기는 전용 직렬 큐에서 함. IMK 콜백 안에서는 클라이언트의 메인 스레드가 입력기를 기다리므로, 동기 질의는 시간 제한에 걸려 실패했음. 자리 계산은 마지막으로 읽은 위치를 쓰고 다시 읽음. 위치가 바뀌면 떠 있는 HUD를 옮기고 포인터 상태를 다시 계산함(`refreshPlacement`).
      - 읽기의 답은 셋임: 입력 칸의 위치, 입력 칸이 아님(다른 입력란에 포커스, 또는 권한 없음: 저장한 위치를 지우고 IMK 사각형을 씀), 답 없음(저장한 위치를 그대로 둠).
      - 활성화 때와 조합 중이 아닐 때의 키다운에서 읽기를 시작하고, 그 답이 올 때까지 위치를 "모름"으로 둠(`hudPlacementIsPending`). 모르는 동안 HUD는 앞 단어 자리에 뜨지 않음: `.show`는 미루고, 떠 있던 막대는 알파 0으로 숨김. 답이 오거나 150 ms(`placementWait`)가 지나면 띄움. 숨긴 동안 숫자 키와 클릭은 막대를 고르지 않음.
      - 활성화마다 세대 번호를 올려, 그 전에 시작한 읽기의 답은 버림. pid는 활성화한 앱이 맨 앞 앱이면 그 앱의 것을 씀.
      - Electron은 보조 앱이 요청하기 전에는 웹 접근성 트리를 만들지 않음. 앱마다 한 번 `AXManualAccessibility`를 켬. 그 앱은 접근성 트리를 유지하는 비용을 냄.
      - 다른 앱에는 접근성으로 묻지 않음.
13. **수정 키 확정.** Caps Lock과 fn은 다른 키처럼 막대를 먼저 지우고 단어를 확정함. 사라진 단어의 막대가 남지 않음.
14. **끝 읽기**(`CompositionEngine+Segment.swift`). 띄어 쓰지 않은 긴 단어에서 캐럿부터 거꾸로 읽어, 끝만 다른 문자로 읽는 읽기. 사용자 요청: "cmd를 누른 위치, 즉 뒤에서부터 읽어서 영어가 될 법하면 그쪽만 영어로, 한국어가 될 법하면 그쪽만 한국어로 시도하는 제안".
   - **두 가지:**
     - 한국어 앞부분 + 끝의 다른 읽기(`ChoiceReading.split`): 앞부분은 K, 끝은 따로 친 단어로서 K가 아닌 읽기(E 또는 M(b)). 중간에 + english → 중간에english, 중간에 + english가. 즉시 확정한 라틴이 없을 때만;
     - 라틴 앞부분 + 한국어 끝 M(b): 감지기가 점수를 주지 않는 M(b)만(라틴이 사전 단어가 아니고 대문자도 없으며 끝이 접미사가 아님. regex쓰면).
   - **나누는 자리:** 끝은 2–30키(`segmentMinimumKeys`, `maxSegmentKeys`), 앞부분은 2키 이상, `'`가 없는 단어. 32키 단어의 모든 자리를 봄. 16키까지만 볼 때는 영어 뒤에 한국어를 이어 치면(중간에english가섞여있어도) 영어 첫 키가 범위 밖으로 밀려, 영어 가운데를 자르는 끝 읽기가 첫 바꾸기였음.
   - **조건:**
     - 앞부분을 따로 친 접두 모드 점수에서 그 언어(K 또는 E)가 1등이고 2등보다 `segmentHeadMargin`(3냇) 넘게 높음;
     - 한국어 앞부분은 완성된 음절로 끝남. 모두 자모(ㅋㅋㅋ)면 됨. 중간ㅇ + penglish처럼 음절을 가르지 않음;
     - 끝을 따로 친 최종 모드 점수(`choiceScores`, 문맥은 앞부분의 언어)에서 그 읽기가 끝의 다른 쪽 읽기보다 높음(E나 M(b) > K, 또는 K > 나머지);
     - 라틴 앞부분이면 끝이 완성된 한글 음절 2개 이상임. 한 음절 끝은 접미사라 감지기가 매김.
     - 끝의 K 글이 자음만이거나 ㅜ, ㅠ, ㅡ만이면(ㅋㅋ, ㅇㅋ, ㅠㅠ, ㅡㅡ) 막대에만 넣음(`mayLead`가 거짓). 첫 바꾸기나 막대 띄우기에 쓰지 않음. 한국어 채팅인데 단어 전체의 최종 모드 점수가 외톨이로 깎기 때문임.
   - **점수:** 앞부분의 접두 모드 점수 + 끝의 최종 모드 점수. 단어 전체의 최종 모드 점수와 견줌. 끝을 앞에 이어 한 단어로 읽을 때의 점수가 아니라 따로 친 단어로 매기므로, 끝의 문맥 사전 확률이 문자를 바꾸는 값을 냄.
   - **첫 바꾸기:** 원래 읽기와 첫 바꾸기 대상(2)을 모두 `segmentMargin`(6냇) 넘게 앞서는 끝 읽기만 첫 바꾸기 대상임. 원래 읽기와 견주지 않으면 맞게 보인 단어가 엉터리 끝 읽기로 갔음(그러면 → 그럼us, 안녕을 확정하고 바꾸면 안sud). 문턱 고르기(카카오톡 대화 말뭉치 토큰, 틀리게 보인 토큰에서 맞는 첫 바꾸기 / 맞게 보인 토큰에서 엉터리 첫 바꾸기): 차 > 0이면 112 / 213, 3냇이면 99 / 66, 6냇이면 92 / 23. 사이트 댓글에서는 33 / 103, 24 / 29, 21 / 12.
   - **찾는 때:** 단어에서 바꾸기 키를 썼거나(`choicesRevealed`, 5) 단어가 10키 이상(`segmentAutoKeys`)일 때, 그리고 확정(4.8절 2)과 바꾸기 (b). 클릭으로 고르기만 한 짧은 단어는 찾지 않음. 앞부분 점수는 키마다 계산한 접두 모드 점수를 다시 씀(`PrefixMemo`). 끝은 나누는 자리마다 감지기를 한 번 부름. release로 32키 단어의 키마다 p50 69 µs, p99 370 µs, 최대 615 µs, 합치기 한 번은 p99 525 µs(`DetectionBenchmarkTests`). 예산은 키마다 1 ms임.
   - **고르기(나누기, `splitToken`):** 앞부분을 늘 K로 확정함. 단어가 E로 보였어도 같음(ghldmlzoom → 회의 + zoom). 4.3절 8의 앞 단어 확정처럼 최종 모드, 학습, 막대, 바꾸기 (b)가 없음. 그다음 끝을 새 단어로 조합함. 새 단어는 고른 읽기로 잠기고(`locked`, `lockedLatin`), 원래 읽기는 K임. 클라이언트 호출은 `insertText`(앞부분) 한 번과 `setMarkedText`(끝) 한 번이고 교체 범위가 없음. 그래서 확정한 글을 바꿀 수 없는 앱에서도 나뉨.
     - 라틴을 고른 뒤라서 어미 규칙(7)이 이어짐: english + `rk` → english가.
     - 끝을 원래 읽기(K)로 바꾸면 한국어 앞부분과 다시 합침(`joinSegmentTail`). 4.3절 8의 다시 열기처럼 조합 문자열을 먼저 확정하고, 교체 범위로 앞부분과 끝을 한 조합 문자열로 바꿈.
     - 합친 단어는 나누기 전 막대에서 나누기 줄 다음의 단어 전체 읽기(`joinReading`. 다음이 없으면 원래 읽기)로 잠기고, 원래 읽기는 나누기 전과 같음. 그래서 막대 순서가 그대로이고 바꾸기 키가 이어서 돎: 중간에두히ㅑ노 → 중간에english(나누기) → 끝의 다른 읽기들 → wndrksdpenglish(합침) → 중간에두히ㅑ노.
     - 끝의 막대에서 원래 읽기 줄은 합친 단어의 글과 언어를 보여 줌(`joinTarget`). 클릭, 숫자, 바꾸기 키가 모두 그 줄이 보여 주는 대로 함.
     - 합친 단어가 32키(`maxTokenLength`)를 넘거나 확정한 글을 바꿀 수 없는 앱이면 합치지 않고 끝만 K가 됨(사진ㅓㅔㅎ). 그 줄도 끝만의 K 글을 보여 줌.
     - 합칠 때 나누기 전의 `PrefixMemo`를 되살려 합친 단어의 막대를 빨리 만듦.
     - ⌫로 끝을 모두 지우면 앞부분이 다시 조합 중이 됨(4.3절 8과 같음).
     - 끝 단어(`segmentTail`)는 학습하지 않고, 그 확정의 바꾸기 (b)도 학습하지 않음. 끝 단어는 다시 나누지 않음. 바꾸기 키가 끝의 읽기를 돈 뒤 원래 읽기 줄에서 합침.
   - **확정한 단어:** 4.8절 2의 대안이 끝 읽기일 수 있음. 조합 중과 같은 목록, 같은 첫 바꾸기 규칙, 같은 즉시 확정 라틴 규칙을 씀. 바꾸기 (b)는 단어 + 경계를 끝 읽기의 글로 바꾸고, 이 단어가 기록한 표를 취소만 함. 끝 읽기 때문에 마지막 단어 막대가 스스로 뜨는 것은 K 글이 안에서 깨진 단어뿐임(4.8절 3).
   - **평가**(카카오톡 대화 말뭉치 토큰, 카카오톡 프로필. 토큰마다 새 엔진에서 문맥을 맞춰 치고, 확정 전에 바꾸기):
     - 틀리게 보인 토큰 1382개 가운데 첫 바꾸기로 맞는 것: R11만 쓰는 이전 규칙 871 → 1025(+160, −6);
     - 맞게 보인 토큰 23 901개 가운데 첫 바꾸기가 이전 규칙과 다른 것 83개(2의 M(b) 첫 바꾸기 규칙 포함);
     - 바꾸기 키를 10번 누르는 동안 보이던 읽기로 돌아오지 않거나 첫 바꾸기 뒤에 나누는 토큰: 0개;
     - 사이트 댓글(TextEdit 프로필), 틀리게 보인 558개: 327 → 385(+59, −1). 맞게 보인 20 971개 중 첫 바꾸기가 다른 것 71개;
     - 확정한 단어(카카오톡 대화 말뭉치를 줄마다 문맥을 이어 친 단어 168 094개): 끝 읽기 때문에만 뜬 마지막 단어 막대는 맞는 단어에 19번, 틀린 단어에 32번(기대값 24번). 맞게 확정한 단어 가운데 바꾸기 (b)가 R11과 다른 것 166개. 틀린 단어 3145개 중 바꾸기 (b)가 기대값을 내는 것 2251 → 2293;
     - 일반 어휘(FrequencyWords 한국어 6000개, 영어 4000개, 문맥 셋, TextEdit, VS Code, 카카오톡): 맞게 보인 단어의 첫 바꾸기가 끝 읽기인 것 0개. 맞게 확정한 단어의 바꾸기 (b)가 R11과 다른 것 0개(TextEdit, 카카오톡. VS Code는 바꾸기 (b)를 하지 않음);
     - 자동 입력은 바뀌지 않음.
   - **한계:**
     - 나누기는 한 번만 함: 한국어 + 영어 + 한국어(중간에english가섞여)는 끝 단어 english가로 이어 치거나, 영어 직후에 바꿔야 함;
     - 첫 바꾸기 규칙의 6냇 때문에, 원래 읽기나 다른 문자 읽기가 끝 읽기보다 6냇 넘게 뒤지지 않으면 끝 읽기는 막대에만 있음. 단어 전체의 K 글이 완성된 음절로만 되어 있으면 자주 그럼. 숫자 키나 클릭으로 고름;
     - 앞부분을 확정하는 끝 읽기는 첫 바꾸기로만 바꾸기 키가 들어감. 막대의 다른 끝 읽기는 숫자 키나 클릭으로 고름. ⇧Space, ⇧ 두 번, Caps Lock 사용자는 클릭만 할 수 있음;
     - 확정한 글을 바꿀 수 없는 앱(VS Code, Orca, Java, iTerm2)에서는 나누기가 앞부분을 바로 확정하고, 되돌릴 수 없음;
     - 앞부분이 영어 단어이기도 하면(cot → 챗) 앞부분 조건에 걸려 챗GPT로 같은 끝 읽기가 없을 수 있음.

---

## 5. 트랙

트랙마다 저장소의 **자기 사본**에서 일하고, 끝나면 자기 경로만 `/Users/user/orca/zlqhem`로 되돌려 맞춰요(6절). v1의 A–D 트랙과 통합은 끝났어요. 진행 상황과 남은 문제는 `docs/STATUS.md`에 있어요. 아래 항목은 각 영역이 지켜야 할 요구 사항으로 남겨 둬요.

### A — 감지 이식 (`Packages/DuoCore/Sources/DuoCore/{Hangul,Detection}/`, `Tests/DuoCoreTests/{Hangul*,Detection*}`)

1. `Tools/ModelBuilder/detector.py`와 `hangul.py`를 Swift로 이식함. `Tests/DuoCoreTests/Resources/test_vectors.json`과 비트 단위로 같아야 함. 모든 키가 `Int` 값으로 정확히 같아야 함: `automaton`, `fnv1a64`, `lexicon`, `lm`, `final`, `incremental`, `apostrophe`, `user`, `userBonus`.
   - 기존 오토마톤을 DET 3절에 맞춤: `ㄸㅃㅉ`는 받침이 되지 않음, `'` 처리, `orphans`, `trailingLoneConsonant`, 한국어 정규화. 기존 테스트를 통과시키거나, DET가 규범인 곳에서는 테스트를 고침.
2. `DuoModel`:
   - mmap, 헤더와 디렉터리 검증, `meta` JSON 디코딩;
   - 묶은 키에서 이진 탐색;
   - 코드북. `userLog2Millibits`는 `meta`에서 읽음.
3. `DuoDetector`:
   - `LanguageDetector`를 구현함;
   - 접두 모드에도 사용자 보너스(R7);
   - `S_K`에 `biasKO`;
   - 계약 문서 주석대로 `canAttachKorean`;
   - `choiceScores`는 계약의 기본 구현(최종 모드, 종결 키 S)을 씀.
4. 성능:
   - 32키 단어로 접두 모드와 최종 모드의 p99를 재는 Swift Testing 벤치마크;
   - release(`swift test -c release`)에서 300 µs 이하가 목표. Debug 숫자도 보고함;
   - 핫 경로에서 작은 배열 말고는 할당하지 않음;
   - 필요하면 단어마다 n-gram 조회를 캐시함(DET 7.4절이 허용함).
5. 모델 내용 해시 `ce5bb10c9a6c025b`를 확인하는 단위 테스트.

### B — 조합 엔진 (`Sources/DuoCore/Engine/`, `Sources/DuoKit/{KeyEventMapper,LearningPersistence}.swift`, `Tests/DuoCoreTests/Engine*`)

1. 4절을 모두 구현함. 엔진 테스트는 실제 `BufferTextClient`와 테스트 소스의 대본형 `FakeDetector`로 논리를 검증함.
2. `EngineScenarioTests`: critique에서도 말이 되는 UX 9절 벡터를 **실제** `DuoDetector`로 다룸.
   - `#filePath`로 `DuoInputMethod/Resources/duo-model.bin`에서 모델을 불러옴.
   - 감지기가 자리표시(`contentHash == "placeholder"`)인 동안은 `.enabled(if:)`로 건너뜀.
   - DET가 맞출 수 없는 기대는 이유와 함께 `withKnownIssue`로 표시함.
3. `LearningStore`(R7):
   - 감쇠, LRU 20 000(넘으면 95 %까지 줄임);
   - `n_eff = Int((Σ…).rounded())`로 계산하는 `counts(raw:context:)`;
   - 기록 API(취소할 수 있는 `LearningVote`를 돌려줌), `onChange`;
   - 표는 1000, raw는 64 UTF-8 바이트로 제한함. 유한하지 않거나 양수가 아닌 값은 버림.
4. `LearningWriter` actor: 2 s 디바운스(첫 변경 뒤 최대 10 s), 원자적 쓰기, 성공 여부를 돌려주는 `flush()`.
   - `LearningFile`은 읽을 수 없는 항목을 하나씩 건너뜀. 빠진 것이 있거나 더 새 형식이면 원본을 `learning.corrupt-<UTC 시각>.json`으로 남김. 파일 전체를 읽을 수 없으면 불러올 때 그 이름으로 옮김.
   - 모두 지우기는 이 복사본도 지움. 복사본에도 사용자가 잊으라고 한 단어가 있기 때문임.
5. `KeyEventMapper`:
   - ANSI 키 코드 → ABC 자판의 글자나 문자, Shift 포함;
   - 키패드 묶음. 데드 키 ⌥e, `` ⌥` ``, ⌥u, ⌥i, ⌥n;
   - `.capsLock`, `.function`과 다른 수정 키.
   - `KeyScript.swift`의 표를 읽기 전용으로 다시 쓰거나 자기 새 파일로 옮김.
6. `SelectionConverter`: 문자 계열 구간마다 한글 ↔ 키(DubeolsikLayout), 2 000자 상한.
7. `ClientProfile` 표(4.10절).

### C — 입력기 (`DuoInputMethod/**`, `DuoHarness/**`, `Sources/DuoKit/KeyScript.swift`, `Tools/IconGen/**`)

1. **컨트롤러 어댑터**(`DuoInputController`):
   - R14 동시성 구조를 따름. `MainActor.assumeIsolated` 전에 IMK 인자를 다시 묶음(V6);
   - `recognizedEvents`에 키다운, `flagsChanged`, 마우스 다운 종류를 넣음(R4). `flagsChanged`를 받으면 IMK가 클릭에서 스스로 확정하지 않으므로 클릭이 `handle`로 옴;
   - 보안 입력을 가장 먼저 확인함(R5). 켜져 있으면 확정하고 HUD를 숨기고 키를 넘김;
   - `activateServer`:
     - `overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.ABC")`, 없으면 `…US`;
     - 설정을 다시 읽고 본 앱을 기록함(`com.inkyuoh.`로 시작하는 앱은 빼고);
     - 엔진 프로필을 새로 정함;
   - `deactivateServer`는 확정하고 HUD를 숨김;
   - `commitComposition`;
   - `kTISNotifySelectedKeyboardInputSourceChanged`를 관찰함(R18 #6, `DuoRuntime`). macOS 26은 다른 프로세스가 입력 소스를 바꿀 때 `deactivateServer`를 부르지 않음;
   - `EngineNotification.flipped`를 분산 알림 `com.inkyuoh.Duo.event.flipped`로 보냄;
   - 번호 붙은 후보 막대가 보이면(그 단어에서 바꾸기나 고르기를 한 뒤) 숫자 키를 `selectReading`으로 보냄(4.11절 5). 막대 클릭은 IMK 콜백 밖에서 클라이언트를 묶고 같은 API를 부름;
   - `IMKTextInput` → `TextClient` 어댑터(`IMKTextClient`):
     - R18 #4: nil이 아닌 attributed string과 `kTSMHiliteConvertedText` 밑줄;
     - 선택 `(len, 0)`, 한 마디(R18 #5);
     - 쉬는 동안 빈 mark나 insert를 보내지 않음(R18 #3);
     - Java 클라이언트는 insert 바로 앞에 같은 글로 mark함(R17);
     - 조합 범위 확인과 콜백 밖 묶기(4.9절);
   - 바꾸기 때 VoiceOver 알림(UX 7.5절). 단어를 바꾸지 못한 바꾸기 키 누름도 그 결과를 읽음: 바꿀 수 없음, 다음 단어 언어, 다음 단어 언어 취소, Bilingual 켬과 끔.
2. **HUD**(UI 2절, R12):
   - 키 창이 되지 않는 유리 캡슐 패널. 프로세스에 하나만 둠;
   - 레벨 `min(max(client.windowLevel() + 1, popUpMenu), shielding − 1)`;
   - 즉시가 아닌 요청은 기다림 없이 다음 타이머 틱에 나타남(`appearDelay` = 0, 2026-11-08 전에는 300 ms). 조합 중에는 붙들어 둠. 숨기기 디바운스 140 ms. 페이드인 140 ms(동작 줄이기 80 ms), 페이드아웃 100 ms;
   - 배지나 메시지가 떠 있으면 새 단어의 후보 막대는 그것을 숨긴 뒤 다음 틱에 뜸. Bilingual 줄 배지는 그 줄에서 계속 보임;
   - 수명과 펄스. 배치 계산과 시간 규칙은 순수 코드로 테스트함(`HUDGeometry`, `HUDTimeline`);
   - 후보 막대는 클릭을 받고 포인터 아래에서 수명을 붙듦(4.11절);
   - 캐럿 사각형은 보이거나 갱신할 때만 가져옴(R15). xterm.js 터미널은 포커스 요소의 위치를 백그라운드에서 읽음(4.11절 12);
   - 화면 잠자기, 세션 비활성, Space 전환, 디스플레이 변경에서 숨김;
   - 동작 줄이기, 대비 증가, 투명도 줄이기를 따름.
3. **입력 메뉴**(R13): 평평하게, 한국어 이름표, 동작을 연결함:
   - "Duo 설정…": `HostRequest.showSettings()`. 실행 중인 Duo.app에는 `com.inkyuoh.Duo.host.showSettings`를 보내고, 아니면 `--duo-show-settings`로 실행함. 온보딩을 마치지 않았어도 설정이 열림;
   - "현재 앱: …" 머리 아래 앱별 프로필 네 항목(자동, 한국어 우선, English 우선, 직접 입력)이 `settings.appProfiles`에 씀. 프로필을 고르면 조합 중인 단어를 먼저 확정함;
   - "선택한 텍스트 한↔A 변환": 바꿀 것이 없으면 경고음, 앱이 글자를 바꿀 수 없으면 "여기서는 바꿀 수 없어요";
   - "힌트 표시"와 "학습 일시 정지"(학습을 끄면 비활성);
   - "Duo 도움말": `HostRequest.showGuide()`.
4. **Info.plist**(R6, R19):
   - `LSUIElement`;
   - `CFBundleName` / `CFBundleDisplayName` "Duo";
   - ko와 en의 `InfoPlist.strings`;
   - `TISIconIsTemplate = true`(템플릿), `TISIconLabels` `Primary = "한A"`. 입력 메뉴와 캐럿 옆 알약은 Duo를 이 라벨이 아니라 아이콘 그림으로 그림;
   - `TICapsLockLanguageSwitchCapable = false`를 유지함;
   - **입력 모드 없이 둠**(R19. 2026-11-08에 실험함. 아래 캐럿 옆 표시 참고);
   - `NSSupportsSuddenTermination = false`. 종료할 때와 SIGTERM에서 학습을 저장함.
   - 캐럿 옆 표시: macOS 26의 캐럿 옆 입력 소스 표시는 Duo를 초록 알약 안의 흰 "한A" 타일로 그림. 글자는 뚫려서 초록으로 보임(macOS 26.6.2에서 확인함). ⌘Space 목록에는 이름 "Duo"가 보임.
   - 이 표시를 그리는 `CursorUIViewService`는 로그인 동안 Duo의 예전 모습을 들고 있음. 아이콘을 바꾼 빌드를 설치한 뒤에는 `killall -KILL CursorUIViewService`나 로그아웃이 있어야 새 모습이 보임. 강제 종료한 서비스는 앱이 새로 연결할 때 다시 뜸.
   - 입력 모드는 필요 없음. 입력 메뉴와 ⌘Space 목록은 서드파티 입력기를 상위 입력기 항목으로만 다룸. 허용 목록에 모드 항목만 두면 Duo가 꺼짐.
5. **메뉴 아이콘:** `Tools/IconGen/make_menu_icon.swift`로 `MenuIcon.tiff`를 다시 만듦.
   - 템플릿: 검은 22×16 pt 타일(모서리 반지름 4 pt)에서 semibold "한A"(최대 12 pt, 잉크 폭 19 pt 이하)를 투명하게 뚫음;
   - 22×16 px(72 dpi)와 44×32 px(144 dpi) 두 장을 `tiffutil -cathidpicheck`로 묶음.
   - 크기와 글자는 macOS 26 입력 메뉴가 애플 입력 소스에 그리는 라벨 알약(22×16 pt)에 맞춤. 메뉴와 메뉴 막대가 템플릿을 칠하므로 밝은 모드에서는 검은 타일, 다크 모드에서는 밝은 타일임.
6. **DebugInjector**(DEBUG 전용):
   - V3대로 `flagsChanged`에 장치 비트를 OR함(`{rcmd}` 0x10 …);
   - 마우스 다운 주입(`{click}`)을 지원해서 R4 경로를 시험함. `{press:…}`와 `{release:…}`로 함께 누르기(오른쪽 ⌘ + C)를 침;
   - DuoHarness가 맨 앞 앱이고 그 텍스트 뷰가 클라이언트일 때만 주입함. 키마다 다시 확인함;
   - DEBUG 전용으로 남김.
7. DuoCore와 DuoKit은 공개 API로만 씀.

### D — 호스트 앱 (`Duo/**`)

1. UI 3절과 critique P2를 합친 SwiftUI 앱:
   - **온보딩**(4단계):
     1. 환영: 히어로 변형 애니메이션과 실제 연습장 칸;
     2. Duo 켜기: `InputMethodInstaller.install(from: embeddedBundleURL)`, 1 s마다 갱신하는 상태 체크리스트(‘Duo 입력기 복사’, ‘입력 소스로 등록’, ‘macOS에서 허용’, ‘입력 소스 켜기’, ‘Duo로 전환’), 딥 링크 대안;
        - 켜기는 macOS의 허용 창("Allow “Duo” to enable “Duo”?")을 거침. 설치기는 허용 목록을 직접 쓰지 않음;
        - 허용을 최대 60 s 기다림(`InstallRecovery`). TIS가 거절하면 2 s 뒤 오류를 보여 줌. 시스템 설정이 꺼져 있었으면 4 s 뒤 한 번 더 요청함;
     3. 써보기: 연습 과제(‘안녕하세요 Duo를 써봐요’, ‘macOS 26 업데이트’, 치는 중인 단어 바꾸기, 방금 확정한 단어 바꾸기)와 바꾸기 키 톡 감지. 로컬 이벤트 모니터(권한 불필요)와 `FlipTapDetector`로 설정한 바꾸기 키(기본 오른쪽 ⌘)를 봄. 8 s 안에 누르지 않으면 다른 키를 제안함;
     4. 끝.
   - **설정**(사이드바):
     - 일반: 연습장 칸(‘써보기’), 상태와 문제 해결 줄, 바꾸기 키, 힌트, 확정 후 바꾸기 제안, Backspace 단위, ₩ 토글, 언어 편향 슬라이더, ‘탭 인식 시간’(바꾸기 키의 톡 창), 영어 즉시 확정 토글;
     - 앱별 설정: 본 앱 목록과 프로필 고르기;
     - 학습: 토글, `LearningFile.load()`로 만든 검색 가능한 표(확신도 막대), 학습 명령 알림으로 지우기나 초기화(50개씩 보내고 ping → pong으로 확인), 입력기가 실행 중이 아니면 파일에 직접 씀;
     - 정보: 버전, 개인 정보 문구, `duo-model.LICENSE.txt`와 CC BY-SA 문구를 담은 감사의 글, Duo 제거(입력 소스에서 빼고 입력기를 지움. 설정과 학습한 단어는 남음).
2. **연습장:**
   - Duo가 선택된 입력 소스가 아니면 자체 `NSView`(`inputContext` nil)가 `KeyEventMapper`를 거쳐 `CompositionEngine` + `BufferTextClient`(`PlaygroundSession`)를 몲. 조합 밑줄과 후보 막대를 직접 그림;
   - 연습장의 후보 막대는 엔진의 요청을 바로 보여 줌. 읽기 목록, 번호, 클릭, 포인터 규칙은 4.11절과 같음. 숫자 키는 번호가 붙은 막대에서만 받음;
   - Duo가 선택돼 있으면 평범한 `NSTextView`;
   - 바꾸기 과제는 `DuoIDs.Notifications.flipped`를 들음.
3. **앱 아이콘:** `Duo/Resources`의 Icon Composer `AppIcon.icon`(UI 4절). `Duo/Tools/MakeAppIcon.swift`로 만들고, 빌드의 `actool`로 확인함.
4. **현지화:** String Catalog(`Localizable.xcstrings`). 원문은 한국어, 번역은 영어. 사용자에게 보이는 모든 문자열이 대상임. `Duo/Tools/check-strings.py`가 코드의 키가 모두 카탈로그에 영어 번역과 함께 있는지 검사함.
5. 어디서나 Liquid Glass(`.glassEffect`, `.buttonStyle(.glass)`), 기본 컨트롤, 접근성 이름표, 밝은 모드와 어두운 모드.

### 통합 (A–D 뒤)

1. 맞추고, `make project`, 모든 스킴을 빌드하고, `swift test`를 통과시킴(벡터는 비트 단위로 같음). 시나리오 테스트는 실제 모델로 돎.
2. Debug 입력기를 설치하고 DuoHarness로 E2E 사례(`Tests/E2E/cases.json`)를 돌림.
3. 통합 버그를 고침.
4. 끝나면 늘 사용자의 입력 소스(`com.apple.inputmethod.Korean.2SetKorean`)를 되돌려 둠.

---

## 6. 모든 에이전트의 작업 공간과 안전 규칙

- **작업 공간.** 사본은 `rsync -a --exclude build --exclude Duo.xcodeproj --exclude Tools/data/raw /Users/user/orca/zlqhem/ <ws>/`로 만듦. 빌드와 테스트는 `<ws>` 안에서**만** 함:
  - `cd <ws>/Packages/DuoCore && swift test --scratch-path <ws>/build/spm`;
  - `cd <ws> && xcodegen generate --quiet && xcodebuild -project Duo.xcodeproj -scheme <S> -derivedDataPath <ws>/build/dd build`.
- **끝나면 되돌려 맞추기:** **자기 경로만** `rsync -a --delete`로 `/Users/user/orca/zlqhem/`에 맞춤. 그곳의 다른 경로는 건드리지 않음. 맞춘 경로를 보고서에 적음.
- **기기 상태:**
  - A–D 트랙에서는 입력기를 설치하지 않고, 입력 소스를 바꾸거나 고르지 않고, 시스템 프로세스를 끄지 않음. computer use와 화면 캡처도 쓰지 않음. 사용자가 이 기기로 입력하고 있음.
  - 통합과 QA 단계는 할 수 있음. 그때는 반드시 입력 소스를 되돌려 둠.
- **저장소:** `.env`를 읽거나 출력하지 않음. 커밋, 푸시, 브랜치 만들기를 하지 않음. 커밋 규칙은 `CLAUDE.md`에 있음.
- **코드:**
  - Swift 6 엄격한 동시성. 자기 파일의 경고 0개.
  - 공개 API에 문서 주석. 죽은 코드 없음. 이유 없는 TODO 없음.
  - 한국어 UI 문구는 UX의 말투("~해요").

## 7. 완료 기준 (v1)

- `swift test`가 통과하고 모든 DET 벡터와 비트 단위로 같음. 엔진과 시나리오 묶음이 통과함. 알려진 문제는 문서로 남긴 것만 있음.
- 모든 스킴이 우리 소스 경고 0개로 빌드됨.
- E2E 하네스 사례가 실제 IMK를 거쳐 통과함.
- Orca computer use로 실제 앱을 확인함(TextEdit, Safari나 Chrome, Terminal, 메모):
  - `안녕하세요`, `hello`, `PR을`, 바꾸기, Backspace, Return이 명세대로 동작함;
  - HUD가 나타나고 캐럿 아래에 놓임.
- 호스트 앱이 깨끗한 상태에서 Duo를 설치하고, 켜고, 선택함. 온보딩과 설정이 밝은 모드와 어두운 모드에서 기본 앱처럼 보임.

지금 수치는 아래와 같아요. 자세한 기록은 `docs/STATUS.md`에 있어요.

| 검사 | 명령 | 결과 |
|---|---|---|
| DuoCore·DuoKit 단위 테스트 | `make test` (`swift test`, debug) | 50개 묶음의 테스트 600개 통과, 알려진 문제 2개 |
| 호스트 앱 테스트 | `xcodebuild test -project Duo.xcodeproj -scheme Duo -destination 'platform=macOS' -derivedDataPath build/dd` | 11개 묶음의 테스트 50개 통과 |
| live E2E | `make e2e` | 70/70 |
| 문자열 카탈로그 | `Duo/Tools/check-strings.py build/dd/Build/Intermediates.noindex/Duo.build/Debug/Duo.build` | 206/206개 키 |
| DET 골든 벡터 | `make test` | 비트 단위로 같음, 모델 해시 `ce5bb10c9a6c025b` |
| 점수 계산 시간 | `swift test -c release` (벤치마크, release에서만 300 µs 예산을 검사함) | 2차 수정 때 접두 p99 15.6 µs, 최종 p99 17.1 µs. 최신 작업 뒤에는 다시 재지 않음 |

알려진 문제 2개는 UX의 기대와 DET의 결과가 다른 시나리오 행이에요(`withKnownIssue`, R8). 그 밖의 실패는 없어요.
