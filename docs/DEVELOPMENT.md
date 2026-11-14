# Duo 개발 문서

빌드, 개발용 설치, 테스트, 릴리스 순서를 적은 문서입니다.
구현 명세는 [SPEC.md](../SPEC.md)에, 진행 상황과 경위는 [STATUS.md](STATUS.md)에 있습니다.

## 빌드 환경

- macOS 26, Xcode 27.2, XcodeGen 2.46.0, make가 필요합니다.
- 배포 대상은 macOS 15.0입니다.
- 언어 모델을 다시 만들 때만 Python 3이 필요합니다. 표준 라이브러리만 씁니다.

```sh
make project   # project.yml로 Duo.xcodeproj 만들기
make test      # DuoCore·DuoKit 단위 테스트
make app       # build/Release/Duo.app 만들기
```

| 명령 | 하는 일 |
|---|---|
| `make project` | `project.yml`로 `Duo.xcodeproj`를 다시 만듭니다(`xcodegen generate --quiet`). |
| `make test` | `Packages/DuoCore`에서 `swift test`를 돌립니다. 중간 파일은 `build/spm`에 둡니다. |
| `make build` | `DuoInputMethod`, `DuoHarness`, `Duo`를 Debug로 빌드합니다. |
| `make build-release` | `Duo`(입력기 포함)를 Release로 빌드합니다. |
| `make install` | Debug 입력기를 `~/Library/Input Methods`에 넣고 옛 입력기 서버를 멈춥니다. |
| `make e2e` | `install` 다음 하네스를 빌드하고, 실제 IMK 경로로 E2E 사례를 돌립니다. |
| `make app` | `build-release` 다음 `build/Release/Duo.app`으로 복사합니다. |
| `make dist` | 내려받기 사이트 묶음을 `build/dist`에 만듭니다. |
| `make deploy` | `make dist` 다음 `build/dist`를 GitHub Pages에 올립니다. |
| `make model` | 말뭉치로 언어 모델을 다시 만듭니다. |
| `make clean` | `build`와 `Duo.xcodeproj`를 지웁니다. |

## 개발용 설치

처음 한 번은 호스트 앱으로 입력 소스를 켭니다.

1. `make app`으로 만든 `build/Release/Duo.app`을 엽니다.
2. 온보딩에서 **Duo 켜기**를 누르고, macOS가 물으면 **허용**을 누릅니다.
3. `Tools/scripts/dev-signing.sh setup`을 한 번 실행합니다. 그 뒤 Debug 입력기를 고정 인증서로 서명해서, 손쉬운 사용 허용이 재설치 뒤에도 남습니다.

그다음부터는 `make install`로 Debug 입력기만 바꿔 넣습니다.

- `make install`은 번들을 바꾸고 옛 서버를 멈춥니다. 입력 소스를 켜지는 않습니다.
- 다시 설치하면 Duo를 쓰던 앱은 ABC로 입력됩니다. 그 앱이 앞에 있을 때 Duo를 다시 고르면(⌃Space 두 번) 다시 붙습니다.

### 켜기가 안 될 때

- 허용을 받지 못하면 시스템 설정 ▸ 키보드 ▸ 텍스트 입력의 **편집…**에서 + 버튼으로 한국어 ▸ Duo를 추가합니다.
- 시스템 설정 ▸ 키보드는 입력 소스 캐시를 따로 둡니다. 이 캐시가 낡으면 허용 창이 뜨지 않고 + 목록에도 Duo가 없습니다. Duo는 켤 때와 앱을 열 때 이 캐시를 확인하고, 낡았으면 지웁니다(`KeyboardSettingsCache`).
- 제거한 뒤 다시 켜면 메뉴 막대의 입력 메뉴에서 Duo가 빠질 수 있습니다. Duo는 켤 때, 앱을 열 때, 입력기가 처음 활성화될 때 이 목록을 확인하고 Duo를 다시 넣습니다(`InputMenuList`).
- 원인과 확인한 내용은 [STATUS.md](STATUS.md)에 있습니다.

## 테스트

| 검사 | 명령 |
|---|---|
| 패키지 단위 테스트 | `make test` |
| 호스트 앱 테스트 | `xcodebuild test -project Duo.xcodeproj -scheme Duo -destination 'platform=macOS' -derivedDataPath build/dd` |
| 실제 IMK E2E | `make e2e` |
| E2E 한 번만 | `Tools/scripts/e2e.sh -e "dkssud{space}"` |
| 문자열 카탈로그 | `Duo/Tools/check-strings.py build/dd/Build/Intermediates.noindex/Duo.build/Debug/Duo.build` |
| 점수 계산 벤치마크 | `cd Packages/DuoCore && swift test -c release --scratch-path ../../build/spm-rel` |

- `make test`에는 E2E 미러(`E2ECaseMirrorTests`)와 DET 골든 벡터가 들어 있습니다. 골든 벡터는 Swift 구현이 Python 참조 구현(`Tools/ModelBuilder/detector.py`)과 비트 단위로 같은지 봅니다.
- 점수 계산 예산은 키 하나에 300 µs(p99)입니다. 끝 읽기를 후보 막대에 둔 32키 단어는 1 ms입니다.

### E2E

- `make e2e`는 Duo를 고르고 1분 가까이 포커스를 가져갑니다. 누가 치는 중에는 돌리지 않습니다.
- 하네스는 끝나면 이전 입력 소스로 돌려놓습니다. 학습은 빈 저장소로 돌리고, 사용자의 `learning.json`을 되돌려 둡니다.
- 실행이 중간에 끊기면 원래 입력 소스를 직접 골라 되돌립니다.
- 보고서는 `build/e2e/report.json`에 생깁니다.
- 새 사례는 `Tests/E2E/cases.json`에 더하고 `make test`부터 돌립니다. 미러가 실제 실행과 같은 학습 순서로 사례를 다시 돌립니다.
- 한 사례의 바꾸기는 뒤 사례에서 학습된 상태로 남습니다. 뒤 사례에는 앞 사례가 바꾸지 않은 단어를 씁니다.

키 스크립트 문법(`Packages/DuoCore/Sources/DuoKit/KeyScript.swift`):

| 쓰는 법 | 뜻 |
|---|---|
| `abc` | 글자 그대로 |
| `{space}` `{S-space}` `{ret}` `{tab}` `{esc}` `{bs}` `{del}` | 특수 키 |
| `{left}` `{right}` `{up}` `{down}` `{home}` `{end}` | 이동 키 |
| `{rcmd}` `{caps}` | 수정 키 톡 |
| `{cmd+a}` | 동시 누름 |
| `{press:rcmd}c{release:rcmd}` | 누르고 있기 |
| `{wait:ms}` | 기다리기 |
| `{click}` | 클릭 |

## 데이터와 로그

| 무엇 | 위치 |
|---|---|
| 설정 | `~/Library/Preferences/com.inkyuoh.Duo.shared.plist`의 `settings.v1` |
| Duo로 입력한 앱 | 같은 도메인의 `seenApps.v1`(200개까지) |
| 학습 | `~/Library/Application Support/Duo/learning.json` |
| 학습 복구 사본 | `~/Library/Application Support/Duo/learning.corrupt-<UTC>.json` |
| 언어 모델 | `DuoInputMethod.app/Contents/Resources/duo-model.bin` |
| 로그 | subsystem `com.inkyuoh.inputmethod.Duo`, 범주 `runtime` `ime` `menu` `hud` `learning` `install` |

- 학습 파일은 입력기가 돌 때는 입력기만 씁니다. 입력기가 돌지 않으면 호스트 앱이 삭제와 모두 지우기를 직접 씁니다.
- 로그에는 친 글자를 남기지 않습니다.

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "com.inkyuoh.inputmethod.Duo"'
```

## 설정

설정은 `DuoSettings` 하나입니다(`Packages/DuoCore/Sources/DuoCore/Contracts/SettingsContract.swift`).
호스트 앱과 입력기가 `settings.v1` 키에 JSON 하나로 함께 씁니다. 빠진 키나 읽지 못한 값은 그 키만 기본값으로 읽습니다.

| 필드 | 기본값 | 값 | 바꾸는 곳 |
|---|---|---|---|
| `flipKey` | `rightCommand` | `rightCommand`, `rightOption`, `doubleShift`, `shiftSpace`, `capsLock` | 일반 ▸ 바꾸기 키 |
| `flipTapWindowMs` | `300` | 200–500(10 ms 단위) | 일반 ▸ 고급 ▸ 탭 인식 시간 |
| `showHints` | `true` | 켬/끔 | 일반 ▸ 입력 ▸ 입력 중 힌트 보기 |
| `alwaysShowChoices` | `false` | 켬/끔 | 일반 ▸ 입력 ▸ 후보 늘 보기 |
| `offerUndoAfterCommit` | `true` | 켬/끔 | 일반 ▸ 입력 ▸ 확정 후 바꾸기 제안 |
| `backspaceUnit` | `jaso` | `jaso`, `gulja` | 일반 ▸ 입력 ▸ 백스페이스 단위 |
| `graveTypesWon` | `false` | 켬/끔 | 일반 ▸ 입력 ▸ `` ` `` 키로 ₩ 입력 |
| `languageBias` | `0` | −1000(English)–+1000(한국어) | 일반 ▸ 언어 감지 ▸ 자주 쓰는 언어 |
| `eagerEnglishCommit` | `true` | 켬/끔 | 일반 ▸ 고급 ▸ 확실한 영어는 바로 확정 |
| `learningEnabled` | `true` | 켬/끔 | 학습 ▸ 학습하기 |
| `learningPaused` | `false` | 켬/끔 | 입력 메뉴 ▸ 학습 일시 정지 |
| `appProfiles` | `{}` | 번들 ID → `automatic`, `koreanFirst`, `englishFirst`, `direct` | 앱별 설정, 입력 메뉴 |
| `inlineApps` | `[]` | 번들 ID 목록 | 앱별 설정, 입력 메뉴 ▸ Enter로 바로 보내기 |
| `hasCompletedOnboarding` | `false` | 켬/끔 | 온보딩 완료 |

## 언어 모델

1. 말뭉치(약 200 MB)를 `Tools/data/raw/`에 내려받습니다. 주소는 [detection.md](research/detection.md) 11절에 있습니다.
2. `make model`을 실행합니다. 결과는 `Tools/ModelBuilder/out/`에 생깁니다.
3. `duo-model.bin`을 `DuoInputMethod/Resources/`로, `test_vectors.json`을 `Packages/DuoCore/Tests/DuoCoreTests/Resources/`로 복사합니다.
4. 데모 장면을 다시 만듭니다([데모 장면](#데모-장면) 참고).

- 빌드는 결정적입니다. 두 번 빌드해도 바이트까지 같습니다.
- 커뮤니티 글을 엔진으로 쳐 보는 평가는 `Tools/scripts/corpus-typing.sh`로 돌립니다(detection.md 11절).
- 정확도, 모델 구성, 학습 데이터와 라이선스는 [detection.md](research/detection.md)에 있습니다.

## 릴리스

GitHub Pages(<https://gomjellie.github.io/DuoKeyboard/>)에서 배포합니다.

- `install.sh`가 `Duo.zip`을 받고 SHA-256을 맞춰 본 뒤 `~/Applications/Duo.app`을 바꾸고 엽니다.
- 앱은 ad-hoc 서명이고 Apple 공증을 받지 않았습니다. 브라우저로 받은 파일은 Gatekeeper가 막고, `curl`로 받은 파일은 막지 않습니다. 그래서 설치 명령을 기본 경로로 둡니다.
- Pages는 저장소 설정에서 `gh-pages` 브랜치를 고르면 켜집니다. 로그인 없는 `curl`이 파일을 받을 수 있어야 설치 명령과 자동 업데이트가 됩니다.

### 새 버전 올리기

1. `project.yml`의 `CURRENT_PROJECT_VERSION`을 올립니다. 설치된 Duo는 자기보다 새 버전만 받습니다.
2. `make deploy`를 실행합니다.
   - `make dist`가 Release 빌드를 만들고, `Tools/dist`의 틀에 버전, 크기, SHA-256, 사이트 주소를 채웁니다. 서명한 `update.json`도 씁니다.
   - 그다음 `Tools/scripts/deploy-pages.sh`가 `build/dist`를 `gh-pages` 브랜치에 커밋 하나로 올립니다. 브랜치를 매번 새로 써서 옛 `Duo.zip`이 쌓이지 않습니다.
3. 설치 명령으로 설치해 봅니다. Pages는 올린 뒤 1분쯤 지나야 바뀌고, 파일을 10분 캐시합니다. 그동안 `Duo.zip`과 `install.sh`의 SHA-256이 어긋나 설치가 멈출 수 있습니다. 잠시 뒤 다시 실행합니다.

| 환경 변수 | 기본값 |
|---|---|
| `DIST_URL` | `https://gomjellie.github.io/DuoKeyboard` |
| `DUO_UPDATE_KEY` | `~/.config/duo/update-ed25519.key` |

### 자동 업데이트

- 사이트의 `update.json`이 가장 새 `Duo.zip`의 버전, 크기, SHA-256, Ed25519 서명을 알려 줍니다.
- 입력기는 인터넷에 연결하지 않습니다. 하루에 한 번 호스트 앱에 확인을 부탁합니다. 호스트 앱이 꺼져 있으면 `--duo-update-check`로 창 없이 엽니다.
- 호스트 앱이 zip을 받아 크기, SHA-256, 서명을 확인합니다. 푼 뒤에는 번들 식별자, 버전, 코드 서명을 확인합니다.
- 설치는 호스트 앱이 끝난 뒤 작은 zsh 스크립트가 합니다. 복사에 실패하면 옛 번들을 되돌립니다.
- 입력기는 키보드가 15초 조용할 때만 바꿉니다. 치고 있는 단어가 끊기지 않게 하려는 것입니다.
- 다른 피드로 시험하려면 아래 명령을 씁니다. 서명과 "지금보다 새 버전" 조건은 그대로입니다.

```sh
defaults write com.inkyuoh.Duo.shared update.feedURL -string <주소>/update.json
```

### 서명 키

앱이 ad-hoc 서명이라 코드 서명으로는 만든 사람을 알 수 없습니다. 그래서 릴리스 키로 zip에 서명합니다.

- 공개 키는 `AppUpdate.publicKey`에 있습니다.
- 비밀 키는 `~/.config/duo/update-ed25519.key`(권한 600)에 있고, 저장소에 넣지 않습니다.
- **비밀 키를 잃으면 설치된 Duo는 새 버전을 받지 못합니다.** 새 키를 넣은 버전을 설치 명령으로 한 번 다시 설치해야 합니다. 키를 꼭 백업합니다.

### 데모 장면

안내 페이지의 입력 데모(`Tools/dist/demo.js`)는 같은 키를 한글 모드와 Duo로 친 결과를 나란히 보여 줍니다.
장면 데이터 `Tools/dist/demo-frames.json`은 `DemoFramesTests`가 실제 엔진과 모델로 만듭니다. 엔진이나 모델을 바꾸면 다시 만듭니다.

```sh
cd Packages/DuoCore && DUO_DEMO_FRAMES_OUT=$PWD/../../Tools/dist/demo-frames.json swift test --filter DemoFrames
```

## 알려진 제한

### 확인하지 않은 환경

- macOS 15에서는 실행해 보지 않았습니다. 빌드와 테스트는 통과하지만, 확인한 환경은 macOS 26뿐입니다.
  - macOS 26 전용 화면 API는 macOS 26에서만 씁니다. 그 아래에서는 유리 대신 반투명 머티리얼, 유리 버튼 대신 `.bordered` 버튼, 눈금 슬라이더 대신 눈금 없는 슬라이더를 씁니다.
  - 입력 메뉴 아이콘, 캐럿 옆 입력 소스 표시, 켜기 허용 창, Orca 입력 칸 위치 읽기가 macOS 15에서 같은지는 모릅니다.
- 확인한 빌드는 ad-hoc 서명 빌드뿐입니다. Developer ID로 서명하고 공증한 빌드도 같은지는 모릅니다.
- 실제 앱에서 확인하지 않은 것: VoiceOver 알림, 1x 디스플레이에서 처음 뜨는 HUD 크기, 데스크톱 공간 전환과 디스플레이 변경 때 숨기기, Orca 자체, Chrome·Safari의 클릭 경로, 선택한 텍스트 한↔A 변환, 텔레그램에서 Enter로 바로 보내기

### 앱과 macOS의 제약

- 보안 키보드 입력이 켜지면 macOS가 Duo를 끕니다. Duo가 피할 수 없습니다. 켠 프로세스는 `ioreg -l -w 0 | grep kCGSSessionSecureInputPID`로 찾습니다.
- Monaco 편집기(VS Code와 그 갈래), iTerm2, Hyper, JetBrains IDE, Android Studio, Orca에서는 확정한 단어를 바꾸지 못합니다. xterm.js 터미널 중에는 Orca만 목록(`ClientProfile.xtermTerminals`)에 있습니다.
- 아이콘을 바꾼 빌드를 설치한 뒤 캐럿 옆 알약이 예전 모습으로 보일 수 있습니다. `CursorUIViewService`가 로그인 동안 예전 모습을 들고 있기 때문입니다. `killall -KILL CursorUIViewService`를 실행하거나 로그아웃합니다. 알약이 뜨지 않으면 앱 하나를 새로 실행합니다.
- 다시 설치한 뒤에는 Duo를 쓰던 앱이 ABC로 입력됩니다. 호스트 앱의 설치, 업데이트, 다시 시작은 맨 앞 앱에서 Duo를 다시 고릅니다. 뒤에 있던 앱은 앞으로 와도 저절로 다시 붙지 않습니다. `e2e.sh`도 끝날 때 입력기를 멈추므로 같은 일이 생깁니다.
- IMK 콜백 밖의 답은 낡았을 수 있습니다. 메뉴 동작, 입력 소스가 바뀔 때의 확정, 전역 모니터 경로, 후보 막대 클릭이 콜백 밖에서 돕니다. 이때 앱의 `selectedRange`와 `attributedSubstring`이 낡았을 수 있습니다.
- Enter로 바로 보내기를 켠 앱에서는 ⌘Z가 단어 단위가 아니라 키 단위로 되돌릴 수 있습니다. 앱이 단어를 바꾸면 Duo는 보지 못한 키나 클릭이 있었을 때, 또는 1초 넘게 멈췄을 때만 알아챕니다.

### 언어 판별

- 테스트의 알려진 문제 2개(`withKnownIssue`)는 영어 뒤의 `gg`, `rt`가 ㅎㅎ, ㄱㅅ이 되는 경우입니다.
- 문장 처음의 소문자 `so`는 "내"가 됩니다. 한국어 글에서 훨씬 흔하기 때문입니다. 영어 단어 뒤에서는 so로 남습니다.
- 한국어 문맥에서 홀로 친 `m` `W` `d` `r` `w` `q` `l`은 ㅡ ㅉ ㅇ ㄱ ㅈ ㅂ ㅣ가 됩니다. 영어 단어 뒤, 문장 처음, 숫자 바로 뒤에서는 라틴 글자로 남습니다.
- 메시지 하나로 친 낱자모 ㅇ, ㄱ은 `d`, `r`로 남습니다.
- 치는 중의 표시와 확정이 다를 수 있습니다. 표시는 어휘 사전을 쓰지 않습니다. 그래서 `ai가`는 Space 전까지 "먀가"로 보이다가 ai가로 확정되고, 후보 막대가 뜹니다.
- ㅠㅠ, ㅜㅜ(`bb`, `nn`)는 치는 동안 라틴 글자로 보입니다. 확정은 맞고, 마지막 단어의 후보 막대가 뜹니다.
- 한글 바로 뒤의 라틴 글자는 쌍자음 없는 대문자로 시작할 때만 나뉩니다(한A, 삼성SDI).
  - 소문자나 Q W E R T O P 대문자로 시작하면 한 단어로 읽힙니다. `zkxhrid`는 "카토걍"이 됩니다.
  - 소문자 한 글자 + 조사(a양, a군)는 스스로 고르지 않습니다. 바꾸기 키나 후보 막대로 고릅니다.
  - 앞 단어가 짧으면 나누지 않습니다. 새, 애, 해는 to, do, go와 키가 같아서, toString과 doSomething은 그대로 남습니다.
  - 한국어 단어 안에서 ⇧를 잘못 누르면 단어가 나뉠 수 있습니다(`gksrMf` → 한ㄱMf). ⌫로 대문자를 지우면 다시 합쳐집니다.
- 끝 읽기는 한 번만 나눕니다. 한국어 + 영어 + 한국어(중간에english가섞여)는 영어를 친 직후에 바꾸거나, 영어 끝을 고른 뒤 이어 칩니다.

### 리터럴과 `_`

- 단어 안의 `@` 앞 단어는 한국어로 보였어도 라틴 글자로 확정되고, 바꾸기 키로 고칠 수 없습니다. 한국어로 남기려면 `@` 앞에서 바꾸기 키를 누릅니다.
- `_` 첫 조각은 혼자 읽힌 대로 확정됩니다(`dir_name` → 약_name). `_` 바로 뒤에서 바꾸기 키로 고칩니다.
- 영어 조각 바로 뒤의 짧은 한국어 낱말 일부(해준, 힘이)는 바꾸기 키가 필요합니다.
- 단어 첫머리의 `\`는 리터럴입니다. `\n`이 한국어 문맥에서 ㅜ가 되지 않게 하려는 것입니다.

### 테스트와 구현

- E2E는 주입 경로입니다. 키가 실제 컨트롤러에 닿지만 TSM 키 라우팅은 거치지 않습니다. 창 서버의 동시 누름 검사, Chromium의 중복 `flagsChanged`, ⇧Space·Caps Lock 바꾸기 키, 직접 입력 프로필, 자동 반복은 단위 테스트로만 확인합니다.
- 입력기 단위 테스트 타깃이 없습니다. 순수한 라우팅 규칙은 DuoKit에서 테스트합니다. IMK 어댑터, 메뉴, `DebugInjector`, 입력기의 학습 쓰기, HUD 패널은 빌드와 E2E로만 확인합니다.
- 버전 1보다 새 `learning.json`은 읽을 수 있는 것만 읽고, 다음 변경 때 버전 1로 다시 씁니다. 원본은 `learning.corrupt-*.json`으로 남습니다.
- `terminateRunningServer()`는 옛 서버를 기다리며 4초까지 막힙니다. 다시 고르기에 약 0.3초가 더 걸립니다. 호스트 앱은 메인 스레드 밖에서 부릅니다.
- 연습장의 `BufferTextClient`는 Caps Lock + ⇧ 글자를 소문자로 다룹니다. macOS ABC는 대문자를 냅니다. 여기에 기대는 테스트는 없습니다.
- `LearningWriter` 디바운스 테스트는 실제로 기다립니다. 부하가 큰 CI에서는 흔들릴 수 있습니다.
