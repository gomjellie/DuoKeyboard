# Duo

Duo는 macOS 26용 입력기예요. 키보드 하나로 한국어(두벌식)와 영어를 한/영 전환 없이 써요. 단어를 치는 동안 두 언어의 읽기를 함께 점수 매기고, 단어가 끝나면 뜻한 언어로 확정해요. `dkssudgktpdy hello`를 치면 `안녕하세요 hello`가 되고, `PRdmf`는 `PR을`이 돼요. 드물게 틀리면 바꾸기 키(기본 오른쪽 ⌘ 톡)를 한 번 눌러 고쳐요. 고친 단어는 이 Mac 안에서 학습해요. 읽기가 애매한 단어에는 번호를 단 후보 막대가 떠서 숫자 키로 고를 수 있어요. 호스트 앱은 설치와 켜기, 설정, 연습장을 맡아요. 목표는 전환 키 없이 두 언어를 Apple 입력기 수준으로 쓰는 거예요. 한국어 단어는 치는 중에 깜빡이지 않고, 키 하나의 점수 계산은 300 µs 안에 끝나고, Backspace는 지우기만 해요.

- 구현 명세: [`SPEC.md`](./SPEC.md)
- 진행 상황과 알려진 문제: [`docs/STATUS.md`](./docs/STATUS.md)
- 연구 문서: [`docs/research/`](./docs/research) — 언어 판별(`detection.md`), 입력 동작과 UX(`ux-spec.md`), InputMethodKit(`imk-platform.md`), UI와 시각 디자인(`ui-design.md`), 검토와 결정(`critique.md`)

---

## 목차

1. [기능 둘러보기](#기능-둘러보기)
2. [빠른 시작](#빠른-시작)
3. [설정 항목](#설정-항목)
4. [키보드 단축키](#키보드-단축키)
5. [아키텍처](#아키텍처)
6. [언어 판별 모델](#언어-판별-모델)
7. [테스트와 검증](#테스트와-검증)
8. [알려진 제한](#알려진-제한)
9. [참고한 솔루션](#참고한-솔루션)

---

## 기능 둘러보기

### 전환 없이 그냥 쓰기

Duo는 입력 소스 하나로 ABC와 2-Set Korean을 함께 대신해요. 단어(글자와 단어 안의 `'`가 이어진 것)는 경계 키가 올 때까지 통째로 조합 문자열로 남아요. 경계 키가 오면 Duo가 단어를 `insertText` 한 번으로 확정하고, 경계 키는 앱이 그대로 처리해요. 아래 예는 모두 E2E 사례(`Tests/E2E/cases.json`)에 있어요.

| 친 키 | 결과 | 읽기 |
|---|---|---|
| `dkssudgktpdy` Space | 안녕하세요 | 한국어(K) |
| `hello` Space | hello | 영어(E). 치는 동안 바로 확정됨 |
| `dkssud PRdmf` Space | 안녕 PR을 | 라틴 단어 + 붙은 조사(M(b)) |
| `pushgoTdj` Space | push했어 | 라틴 단어 + 붙은 어미 |
| `tkatjdSDIrk` Space | 삼성SDI가 | 한국어 단어 뒤의 대문자는 새 라틴 단어를 시작함(쌍자음 없는 키) |
| `dhsmf PRdmf dhffuTsmsep CIrk RowuTspdy.` | 오늘 PR을 올렸는데 CI가 깨졌네요. | 한 문장에 세 읽기가 섞임 |
| `3tl` Space | 3시 | 숫자 뒤 문맥 |
| `macOS 26` Space | macOS 26 | 대소문자 어휘 사전 |
| `don't` Space | don't | 단어 안의 `'` |
| `zzz` Space | ㅋㅋㅋ | 채팅 자모 |

- **치는 동안 읽기를 보여 줌.** 접두 모드 점수와 히스테리시스(1.5 nats)로 고름. 한국어 단어는 치는 중에 읽기가 바뀌지 않음
- **몰래 다르게 확정하지 않음.** 확정할 때는 최종 모드 점수로 고름. 확정한 읽기가 보이던 것과 다르거나 차이가 작으면(다른 읽기 P ≥ 35 %) 마지막 단어의 후보 막대를 띄움
- **영어는 일찍 확정함.** 세 키 이상이고 영어가 확실하면(다른 읽기 P < 1 %) 치는 동안 확정함. 자동 완성과 IntelliSense가 실제 글자를 봄. 끝에 한국어가 붙을 수 있는 자음 키에서는 기다림
- **문맥을 씀.** 새 단어는 숫자 뒤, 문장 시작, 한국어 뒤, 영어 뒤 중 하나의 문맥으로 시작함. 앱 프로필과 언어 감지 슬라이더가 한국어 쪽 점수를 더하거나 뺌(합쳐서 ±1500 millinats 안)
- 단어는 32키까지임. 33번째 키에서 앞 단어를 확정하고 새 단어를 시작함

### 주소, 경로, 코드는 그대로(리터럴)

| 친 키 | 결과 |
|---|---|
| `user@example.com` | user@example.com |
| `github.com/foo` | github.com/foo |
| `https://apple.com` | https://apple.com |
| `~/Library` | ~/Library |

- 단어 첫머리의 `/ ~ \ : @`, `./`, `../`에서 리터럴이 시작됨
- 단어 안의 `@`, `_`, 그리고 `www.`는 그 단어를 라틴 글자로 확정하고 리터럴로 들어감
- 영어로 확정한 단어 바로 뒤 `.` 다음 글자(node.js, github.com)와 영어 단어 뒤의 `:/`도 리터럴임
- 리터럴 중에는 키가 그대로 가고 바꾸기 키는 아무 일도 하지 않음
- 공백, Return, Tab, Esc, 화살표, 이동 키, ⌘/⌃/fn 단축키, ⌥⌫, 시작 글자까지 지우는 Backspace에서 리터럴이 끝남. Forward Delete와 F 키는 리터럴을 유지함
- 사용자가 고른 한국어 읽기가 이 규칙보다 앞섬. `b` 바꾸기 `_` `b` 바꾸기 Space → ㅠ_ㅠ
- `#`은 리터럴이 아님

### 바꾸기 키

바꾸기 키는 기본으로 오른쪽 ⌘ 톡이에요. 누른 뒤 다른 키 없이 300 ms 안에 떼면 톡으로 쳐요. 키 하나가 상황에 따라 세 가지로 동작해요.

| 상황 | 동작 | 예 |
|---|---|---|
| (a) 단어를 치는 중 | 다른 읽기로 바꾸고 그 읽기로 고정함. 한 번 더 누르면 돌아옴 | `hello go` 바꾸기 Space → hello 해 |
| (b) 방금 확정한 단어 바로 뒤에 캐럿이 있음 | 그 단어를 다른 읽기로 바꿈. 바꾸기 전에 문서의 글자를 확인함. 한 번 더 누르면 돌아옴 | `hello so` Space 바꾸기 → hello 내 |
| (c) 바꿀 단어가 없음 | 다음 단어 하나를 문맥과 반대 언어로 정하고 한/A 배지를 띄움. 한 번 더 누르면 취소됨 | 문장 처음에서 바꾸기 `rkskek` Space → rkskek |

- (b)는 같은 앱에서 30초 안이고, 그 뒤로 글자, 클릭, 포커스 변화가 없을 때만 됨
- 직접 입력 프로필에서는 (c) 대신 그 줄의 한영 자동을 켜고 끔
- 영어를 일찍 확정한 단어도 바꿀 수 있음. 확정한 글자를 다시 열어 바꿈. `dkssud hello` 바꾸기 Space → 안녕 ㅗ디ㅣㅐ
- 누르는 사이에 다른 키나 클릭이 있으면 톡이 아님. 오른쪽 ⌘ + C는 복사로 동작함
- Backspace에는 다른 기능을 겹치지 않음. 확정 직후 Backspace로 경계 글자를 지우면 그 단어를 다시 바꿀 수 있고 마지막 단어의 후보 막대가 뜸
- 확정한 글자를 바꿀 수 없는 앱에서는 "여기서는 바꿀 수 없어요"를 띄우고 아무것도 바꾸지 않음([앱 프로필](#앱-프로필) 참고)
- 바꾸기는 학습이 됨([학습](#학습) 참고)

### 후보 막대와 숫자 키

읽기가 둘 이상 그럴듯한 단어에는 캐럿 아래에 후보 막대가 떠요. 막대는 Liquid Glass 캡슐이에요. 읽기마다 언어 배지(한 주황, A 파랑)가 붙고, 치는 중인 단어의 막대에는 번호도 붙어요. 지금 문서에 있는 읽기는 그 언어 색의 알약 위에 있어요. 끝에는 바꾸기 키의 키캡이 있어요.

| 친 키 | 보이는 읽기 | 후보 막대 | 고르면 |
|---|---|---|---|
| `worksdlftneh` | 재간일수도 | 1 재간일수도 · 2 works일수도 … | `2` → works일수도 |
| `cmdfh` | 층로 | 1 층로 · 2 cmd로 … | `2` → cmd로 |
| `cmdrk` | 층가 | 1 층가 · 2 cmd가 … | `2` → cmd가 |

- 치는 중인 단어의 후보 막대는 K, E, M(b) 읽기를 최대 5개까지 보여 줌. 접두 모드 점수가 높은 순서로 1부터 번호를 붙임
- 두 모드 모두에서 가장 좋은 읽기보다 10 nats 넘게 뒤진 읽기는 뺌. 보이는 읽기와 바꾸기 키가 바꿀 읽기는 늘 남음
- 막대는 다른 읽기가 보이는 읽기에 가까울 때 뜸. 접두 모드에서 P ≥ 5 %(`Margins.hudCandidates` = 2944)이거나, M(b) 읽기가 최종 모드에서 그만큼 가까울 때임. 사용자가 읽기를 골랐을 때도 뜸
- 두 키 이상이어야 함. 한 키 단어는 `a e i o u x`만 뜸
- 치다가 300 ms 멈추면 나타남. 한 번 뜨면 그 단어를 치는 동안 남음
- **숫자 키 1–9**는 번호를 단 후보 막대가 다 나타난 동안 그 번호의 읽기를 고름. 막대에 없는 번호, ⌘·⌃·⌥와 함께 누른 숫자, 막대가 나타나는 중(페이드 인 140 ms)의 숫자는 평소처럼 입력됨
- 막대에 있는 읽기를 고르지 못하면(조합 문자열이 사라졌거나 확정한 글자를 다시 열지 못함) 숫자를 입력하지 않음
- 읽기를 클릭해도 고름. 클릭해도 앱이 포커스를 잃지 않음
- 고른 읽기는 바꾸기 키를 누른 것처럼 고정되고 학습됨
- 보이는 읽기를 골라도 고정됨. 이때는 경계에서 다른 읽기로 확정됐을 단어만 학습함
- 바꾸기 키는 막대가 있어도 한 읽기로만 바꿈. 읽기를 고른 뒤에 누르면 처음 읽기로 돌아가고, 한 번 더 누르면 고른 읽기로 다시 감
- **마지막 단어의 후보 막대**: 확정한 읽기가 보이던 것과 달랐거나 애매했으면 확정한 단어 아래에 두 읽기를 번호 없이 보여 줌. 4초 동안 뜨고 포인터가 올라가 있으면 사라지지 않음. 다른 읽기를 클릭하면 확정한 단어를 바꿈. 이때 숫자는 글자로 입력됨
- HUD는 앱이 알려 준 캐럿 사각형이 올바르고 그 앱의 창 안에 있을 때만 따라감. 아니면 뜨지 않음

### 영어로 고른 단어 뒤의 조사

앞의 몇 키를 영어(또는 라틴 단어 + 한국어)로 고른 뒤 이어 치면, 키마다 "모두 영어"와 "라틴 단어 + 한국어 끝"을 다시 견줘요.

- `cmd` → 층. 바꾸기 → cmd. 이어서 `fh` → cmd로. Space → cmd로
- 같은 상황에서 `s`를 이으면 cmds가 됨
- 한국어 끝은 완성된 음절이어야 함. 자모 하나만 붙으면 영어를 계속 치는 것으로 봄
- 아무것도 고르지 않고 `cmdfh`를 치면 층로가 됨. 층도 말이 되기 때문임

### 학습

Duo는 고친 단어를 이 Mac 안에서 기억해요. 문장은 저장하지 않고, 친 키 문자열과 문맥별 표만 남겨요. Duo는 인터넷에 연결하지 않아요.

- 표는 (친 키, 문맥)마다 읽기별로 셈. 반감기는 60일임
- 바꾸기 키나 후보 막대로 고르면 +3표, 애매했던 단어(다른 읽기 P ≥ 20 %)를 그대로 확정하면 +1표
- 바꾼 단어를 다시 되돌리면 그 표를 취소함
- 라틴 단어 + 끝(cmd로)을 고르면 라틴 부분(`cmd`)에도 M(b) 표 +3을 남김. `cmd` 단독에는 M(3) 읽기가 없음. 그래서 이 표가 `cmd`를 영어로 바꾸지 않음
- 후보 막대의 점수에서만 라틴 앞부분(`cmd`)이 받은 영어 표와 M(b) 표를 더해, 그 절반(올림)을 M(b) 읽기(cmd로)에 얹음. 보이는 읽기와 확정에는 쓰지 않음. 그래서 `cmd`를 영어로 배워도 `cmdfh`는 층로로 입력되고, cmd로는 숫자 하나로 고를 수 있음
- 배우지 않는 경우: 한 키 단어, 리터럴, 직접 입력, 학습을 끄거나 멈췄을 때, 보안 입력
- 항목은 20,000개까지임. 넘으면 오래 쓰지 않은 것부터 지워 95 %로 줄임. 읽기 하나의 표는 1,000표까지, 친 키는 64바이트(UTF-8)까지임
- 설정 ▸ 학습에서 끄거나, 배운 단어를 찾아 지우거나, 모두 지움. 입력 메뉴의 `학습 일시 정지`로 잠시 멈춤

### 앱 프로필

앱마다 Duo가 먼저 생각할 언어를 정해요. 사용자가 고른 값이 없으면 앱 종류에 따른 기본값을 써요. 직접 입력은 기본값이 아니고, 사용자가 입력 메뉴나 설정에서 고를 때만 써요.

| 프로필 | 동작 | 기본으로 쓰는 앱 |
|---|---|---|
| 자동 | 단어마다 판단함. 치우침 0 | 아래에 없는 모든 앱 |
| 한국어 우선 | 한국어 쪽 점수 +1000 millinats | 카카오톡, LINE, 한컴오피스 한글 |
| English 우선 | 한국어 쪽 점수 −1000 millinats | 터미널(Terminal, iTerm2, Orca, cmux, Ghostty, Warp, kitty, Alacritty, WezTerm, Hyper), 코드 편집기(Xcode, VS Code, Cursor, Zed, Sublime Text, Nova, BBEdit), JetBrains IDE, Android Studio |
| 직접 입력 | 키를 그대로 보냄. 바꾸기 키를 누르면 그 줄만 한영 자동이 됨. Return이나 Esc에서 끝남 | 없음 |

어떤 앱은 이미 쓴 글자를 바꾸지 못해요. Duo는 그런 앱의 목록을 갖고 있어요(`Packages/DuoCore/Sources/DuoCore/Engine/ClientProfile.swift`).

| 앱 | 제약 |
|---|---|
| Terminal | 캐럿 앞 글자만 바꿀 수 있음. 마지막 단어는 캐럿에서 거꾸로 재서 찾음 |
| iTerm2, Hyper, JetBrains IDE, Android Studio | 글자를 바꾸지 못함. 영어를 일찍 확정하지 않고, 확정한 단어를 바꾸지 않음 |
| Orca(xterm.js) | `replacementRange`를 무시함. 조합 중인 단어는 바꿀 수 있음. 영어는 일찍 확정하지만 확정한 글자를 다시 열거나 바꾸지 않고, 마지막 단어의 후보 막대를 띄우지 않음 |
| VS Code, VS Code Insiders, Cursor, VSCodium, Windsurf, Code OSS(Monaco) | `replacementRange`를 무시함. 영어는 일찍 확정하지만 확정한 글자를 다시 열거나 바꾸지 않고, 마지막 단어의 후보 막대를 띄우지 않음 |

### Caps Lock, 보안 입력, 그 밖의 키

- **Caps Lock**: 켜면 조합 중인 단어를 먼저 확정하고, 그 뒤 글자는 영어 대문자로 그대로 입력됨. `rk` Caps Lock `ok` Caps Lock Space → 가OK. 바꾸기 키가 Caps Lock이면 누를 때마다 바꾸기임
- **보안 입력**: 암호 칸처럼 보안 키보드 입력이 켜지면 조합하지 않음. 키가 그대로 가고 HUD와 학습도 없음
- **fn(Globe)**: 조합 중인 단어를 먼저 확정함. 이모지 선택기와 받아쓰기가 그 뒤에 글자를 넣음
- **⌘, ⌃ 단축키**: 단어를 확정한 뒤 앱에 넘김. ⌘A, ⌘C가 마지막 음절까지 든 글에 적용됨
- **⌥ + 글자**: 단어를 확정하고 그대로 보냄. ⌥e 같은 데드 키 다음 키도 그대로 감(é)
- **클릭**: 조합 중인 단어를 확정하고, 클릭은 캐럿을 옮김
- **`` ` `` 키**: 설정을 켜면 Apple 두벌식처럼 ₩를 입력함. 기본은 꺼짐
- **멈춘 뒤 다시 치기**: 1초 넘게 멈췄다가 키를 치면 앱에 조합 문자열이 남아 있는지 확인함. 앱이 지웠으면(메시지를 보낸 뒤 등) 단어를 조용히 버림
- **입력 소스 바꾸기**: 조합 중인 단어를 한 번만 확정함

### 선택한 텍스트 한↔A 변환

- 입력 메뉴에서 고름. 선택 영역을 글자 종류별로 나눠 바꿈
- 한글 → 두벌식 키(안녕 → dkssud), 라틴 글자 → 한글(dkssud → 안녕). 공백, 숫자, 문장 부호, 이모지는 그대로 둠
- 두벌식으로 친 글은 두 번 바꾸면 원래대로 돌아옴
- 2,000자까지임. 선택이 없거나 더 길면 경고음이 남
- 글자를 바꿀 수 없는 앱에서는 "여기서는 바꿀 수 없어요"를 띄움

### 입력 메뉴

메뉴 막대의 입력 메뉴에서 Duo를 고르면 아래 항목이 보여요. IMK는 하위 메뉴를 무시해서 모두 한 단계에 있어요.

| 항목 | 동작 |
|---|---|
| Duo 설정… | 호스트 앱의 설정 창을 엶. 온보딩을 마치기 전에도 열림 |
| 현재 앱: (앱 이름) | 제목. 아래 네 항목이 이 앱의 프로필임 |
| 자동 · 한국어 우선 · English 우선 · 직접 입력 | 지금 앱의 프로필을 고름. 조합 중인 단어를 먼저 확정함 |
| 선택한 텍스트 한↔A 변환 | 선택 영역을 변환함 |
| 힌트 표시 | 치는 중 후보 막대를 켜고 끔(`showHints`) |
| 학습 일시 정지 | 학습을 잠시 멈춤. 학습을 끈 상태에서는 고를 수 없음 |
| Duo 도움말 | 호스트 앱의 시작 안내를 엶 |

### 호스트 앱

호스트 앱 `Duo.app`은 입력기를 안에 담고 있어요(`Contents/Library/Input Methods/DuoInputMethod.app`). 온보딩을 아직 마치지 않았거나 Duo가 설치되거나 켜져 있지 않으면 온보딩 창이 떠요. 아니면 설정 창이 떠요. 온보딩을 한 번 마친 사용자는 `Duo 켜기` 단계부터 봐요. 화면은 Liquid Glass와 기본 컨트롤로 그리고, 라이트와 다크 모드를 모두 지원해요. 문자열은 한국어가 원본이고 영어로도 옮겨져 있어요.

**온보딩(4단계)**

1. 환영: "한영 전환 없이, 그냥 쓰세요." `dkssud` → 안녕, `hello` → hello로 바뀌는 애니메이션과 바로 쳐 보는 연습장이 있음
2. Duo 켜기: 버튼 하나로 설치함. 체크리스트(Duo 입력기 복사 → 입력 소스로 등록 → macOS에서 허용 → 입력 소스 켜기 → Duo로 전환)가 1초마다 상태를 따라감. 실패하면 키보드 설정으로 가는 버튼을 보여 줌. 새 버전이 들어 있으면 업데이트를 제안함
3. 써보기: 연습장에서 과제 네 개를 하면 바로 체크됨. 바꾸기 키 안내 카드가 키를 누르는지 확인하고, 8초 안에 누르지 않으면 다른 키를 제안함
   - ‘안녕하세요 Duo를 써봐요’ 입력하기
   - ‘macOS 26 업데이트’ 입력하기
   - 한국어 문장 속 go를 쓰는 중에 go ↔ 해 바꾸기
   - 단어를 쓰고 Space를 누른 다음, 그 단어 바꾸기
4. 완료: 입력 메뉴, 바꾸기 키, 기기 안 처리를 한 번 더 알려 줌. vim이나 less를 자주 쓰면 터미널을 직접 입력으로 바꾸라고 권하고, 앱별 설정으로 가는 버튼을 둠

**설정(사이드바)**

| 창 | 내용 |
|---|---|
| 일반 | 연습장(써보기), 상태(설치, 입력 소스, 현재 입력 소스, 버전, 업데이트, 보안 입력 안내), 바꾸기 키, 입력 옵션, 언어 감지 슬라이더, 고급(탭 인식 시간, 확실한 영어는 바로 확정), 문제 해결(Duo 다시 시작, 키보드 설정 열기…) |
| 앱별 설정 | 네 프로필 설명, Duo로 입력한 앱과 실행 중인 다른 앱의 프로필, 기본값 복원… |
| 학습 | 학습하기 스위치, 멈춤 안내와 다시 시작, 학습한 단어 목록(입력 키, 결과, 문맥, 확신도, 마지막 사용), 검색, 삭제, 모두 지우기… |
| 정보 | 버전, 개인 정보 안내, 데이터 위치(Finder에서 보기), 언어 모델 데이터 라이선스(CC BY-SA 4.0), 감사의 말, Duo 제거… |

- ⌘,는 설정 창을 엶. 도움말 메뉴에 `Duo 시작하기 안내`와 `키보드 설정 열기…`가 있음
- Duo가 선택된 상태에서 설치, 업데이트, `Duo 다시 시작`을 하면 다른 키보드 입력 소스로 바꿨다가 약 0.3초 뒤에 Duo로 돌아옴. 앞에 있는 앱이 새 입력기에 다시 붙게 하려는 동작임
- `Duo 제거…`는 입력 소스에서 Duo를 빼고 입력기를 지움. 설정과 학습한 단어는 남음
- 학습한 단어 목록의 삭제와 모두 지우기는 입력기가 돌고 있으면 입력기에 명령으로 보내고, 아니면 파일에 직접 씀. 모두 지우기는 복구용 사본(`learning.corrupt-*.json`)도 지움
- 확신도는 단어가 받은 표를 감지기의 로그 척도로 그린 막대임

**연습장**

- Duo가 지금 입력 소스가 아니면 앱 안의 엔진(`CompositionEngine` + `BufferTextClient`)으로 동작함. 조합 문자열 밑줄과 후보 막대를 직접 그리고, 숫자 키로 고르기도 됨
- Duo가 지금 입력 소스면 일반 텍스트 뷰를 쓰고 실제 입력기가 처리함
- 두 방식을 오가도 친 글자가 남음
- 언어 모델은 앱에 든 입력기 번들에서 읽음

**VoiceOver와 손쉬운 사용**

- HUD는 VoiceOver 포커스를 가져가지 않음. 대신 바꾸기를 소리로 알림. 예: "해, 한국어로 바꿈"
- 바꾸기 키의 다른 결과도 알림: "여기서는 바꿀 수 없어요", "다음 단어는 한국어", "다음 단어는 영어", "다음 단어 언어 지정 취소", "이 줄은 한영 자동", "직접 입력으로 돌아감"
- 연습장은 VoiceOver 텍스트 영역이고 바꾸기를 알림
- HUD는 동작 줄이기, 투명도 줄이기, 대비 증가 설정을 따름. 환영 애니메이션은 동작 줄이기에서 멈춘 그림으로 바뀜

---

## 빠른 시작

필요한 것: **macOS 26**(배포 대상 26.0, 확인한 환경 26.6.2), **Xcode 27.2**, **XcodeGen 2.46.0**. 언어 모델을 다시 만들 때만 **Python 3**이 필요해요(표준 라이브러리만 써요).

```sh
make project      # project.yml로 Duo.xcodeproj를 만들어요(XcodeGen)
make test         # DuoCore·DuoKit 단위 테스트(swift test)
make app          # Release 호스트 앱을 build/Release/Duo.app에 만들어요(입력기가 안에 들어 있어요)
```

| 명령 | 하는 일 |
|---|---|
| `make help` | 주요 명령 목록을 보여 줌 |
| `make project` | `project.yml`로 `Duo.xcodeproj`를 다시 만듦(`xcodegen generate --quiet`) |
| `make test` | `Packages/DuoCore`에서 `swift test`를 돌림. 중간 파일은 `build/spm` |
| `make build` | `DuoInputMethod`, `DuoHarness`, `Duo`를 Debug로 빌드함 |
| `make build-release` | `Duo`(입력기 포함)를 Release로 빌드함 |
| `make install` | Debug 입력기를 빌드해 `~/Library/Input Methods`에 넣고 옛 입력기 서버를 멈춤 |
| `make e2e` | `install` 다음 하네스를 빌드하고 실제 IMK 경로로 E2E 사례를 돌림. 보고서는 `build/e2e/report.json` |
| `make app` | `build-release` 다음 `build/Release/Duo.app`으로 복사함 |
| `make model` | 말뭉치로 언어 모델을 다시 만듦(`Tools/ModelBuilder/build_model.py`) |
| `make clean` | `build`와 `Duo.xcodeproj`를 지움 |

### 입력기와 호스트 앱 설치

호스트 앱으로 설치하는 것이 기본 경로예요.

1. `make app`으로 `build/Release/Duo.app`을 만들고, `~/Applications` 같은 곳에 두고 엶
2. 온보딩의 `Duo 켜기`를 누름. 호스트 앱이 안에 든 입력기를 `~/Library/Input Methods`에 복사하고, 입력 소스로 등록하고 켬
3. 호스트 앱이 시스템 설정 ▸ 키보드를 열고, macOS가 허용 여부를 물음(영문 macOS: "Allow “Duo” to enable “Duo”?"). **허용**을 누름
4. 호스트 앱은 허용을 60초까지 기다림. 시스템 설정이 실행 중이 아니었으면 4초 뒤 한 번 더 요청함. 허용하면 Duo로 전환하고 앞으로 돌아옴

허용을 받지 못하면 "macOS의 허용을 받지 못했어요…"가 떠요. 이때는 시스템 설정 ▸ 키보드 ▸ 텍스트 입력의 `편집…`에서 + 버튼으로 한국어 ▸ Duo를 추가해도 돼요. 켤 때 Duo는 입력 소스 허용 목록을 직접 쓰지 않아요. 사용자가 허용하면 macOS가 써요.

개발할 때는 `make install`로 Debug 입력기만 바꿔 넣어요.

- 이 스크립트(`Tools/scripts/install-ime.sh`)는 번들을 바꾸고 옛 서버를 멈춤. 입력 소스를 켜지는 않음. 처음에는 호스트 앱이나 시스템 설정으로 켬
- 다시 설치하면 Duo를 쓰던 앱은 ABC로 입력됨. 그 앱이 앞에 있을 때 Duo를 다시 고르거나(⌃Space 두 번, 메뉴 막대), 다른 앱에 갔다 오면 다시 붙음
- `make e2e`는 Duo를 고르고 1분 안쪽 동안 포커스를 가져감. 누가 치는 중에는 돌리지 않음
- 하네스는 끝나면 이전 입력 소스로 돌려놓음. 학습은 빈 저장소로 돌리고 사용자의 `learning.json`을 되돌려 둠
- 실행이 중간에 끊기면 원래 입력 소스를 직접 골라 되돌림. 이 개발 기기에서는 `com.apple.inputmethod.Korean.2SetKorean`임

---

## 설정 항목

설정은 `DuoSettings` 하나예요(`Packages/DuoCore/Sources/DuoCore/Contracts/SettingsContract.swift`). 호스트 앱과 입력기가 `UserDefaults(suiteName: "com.inkyuoh.Duo.shared")`의 `settings.v1` 키에 JSON 하나로 함께 써요. 빠진 키나 읽지 못한 값은 그 키만 기본값으로 읽고, `appProfiles`는 앱 하나씩 읽어요.

| 필드 | 기본값 | 값 | 바꾸는 곳 | 설명 |
|---|---|---|---|---|
| `flipKey` | `rightCommand` | `rightCommand`, `rightOption`, `doubleShift`, `shiftSpace`, `capsLock` | 일반 ▸ 바꾸기 키 | 단어를 바꾸는 키 |
| `flipTapWindowMs` | `300` | 200–500(10 ms 단위) | 일반 ▸ 고급 ▸ 탭 인식 시간 | 이 시간 안에 눌렀다 떼면 톡. 오른쪽 ⌘, 오른쪽 ⌥, ⇧ 두 번에만 씀 |
| `showHints` | `true` | 켬/끔 | 일반 ▸ 입력 ▸ 입력 중 힌트 보기, 입력 메뉴 ▸ 힌트 표시 | 치는 중 후보 막대. 꺼도 실패 안내와 배지는 뜸 |
| `offerUndoAfterCommit` | `true` | 켬/끔 | 일반 ▸ 입력 ▸ 확정 후 바꾸기 제안 | 마지막 단어의 후보 막대. 애매하거나 보이던 것과 다르게 확정한 단어에 뜸 |
| `backspaceUnit` | `jaso` | `jaso`(자소), `gulja`(글자) | 일반 ▸ 입력 ▸ 백스페이스 단위 | 조합 중 Backspace가 지우는 단위 |
| `graveTypesWon` | `false` | 켬/끔 | 일반 ▸ 입력 ▸ `` ` `` 키로 ₩ 입력 | `` ` `` 키로 ₩를 입력함 |
| `languageBias` | `0` | −1000(English)–+1000(한국어). 슬라이더는 100 단위 | 일반 ▸ 언어 감지 ▸ 자주 쓰는 언어 | 모든 앱에서 한국어 쪽 점수에 더함 |
| `eagerEnglishCommit` | `true` | 켬/끔 | 일반 ▸ 고급 ▸ 확실한 영어는 바로 확정 | 확실한 영어를 치는 동안 확정함 |
| `learningEnabled` | `true` | 켬/끔 | 학습 ▸ 학습하기 | 학습 전체를 켜고 끔. 끄면 배운 표도 쓰지 않음 |
| `learningPaused` | `false` | 켬/끔 | 입력 메뉴 ▸ 학습 일시 정지, 학습 ▸ 다시 시작 | 새로 배우는 것만 잠시 멈춤 |
| `appProfiles` | `{}` | 번들 ID → `automatic`, `koreanFirst`, `englishFirst`, `direct` | 앱별 설정, 입력 메뉴 | 앱별 프로필. 없는 앱은 기본값을 씀 |
| `hasCompletedOnboarding` | `false` | 켬/끔 | 온보딩 완료 | 온보딩을 마쳤는지 |

---

## 키보드 단축키

### 바꾸기 키

| 설정 값 | 이름 | 키캡 | 누르는 법 |
|---|---|---|---|
| `rightCommand`(기본) | 오른쪽 Command | ⌘ | 톡. 눌렀다가 탭 인식 시간(기본 300 ms) 안에 뗌 |
| `rightOption` | 오른쪽 Option | ⌥ | 톡 |
| `doubleShift` | Shift 두 번 | ⇧ ⇧ | 탭 인식 시간 안에 ⇧를 두 번 톡 |
| `shiftSpace` | Shift + Space | ⇧ Space | 누를 때마다 바꿈. 길게 눌러 반복되는 입력은 무시함. 리터럴 중에는 평범한 Space임 |
| `capsLock` | Caps Lock | ⇪ | 누를 때마다 바꿈. 이때 Caps Lock은 영어 고정이 아님 |

톡 사이에 다른 키, 클릭, 다른 수정 키가 끼면 톡이 아니에요. 오른쪽 ⌘ 톡은 왼쪽 ⌘를 함께 누르고 있으면 톡이 아니에요.

### 입력 중 키

| 키 | 동작 |
|---|---|
| `1`–`9` | 번호를 단 후보 막대가 보일 때 그 번호의 읽기를 고름 |
| 클릭(후보 막대) | 그 읽기를 고름. 마지막 단어의 후보 막대에서는 확정한 단어를 바꿈 |
| ⌫ | 조합 중: 자소면 키 하나(닭 → 달 → 다 → ㄷ), 글자면 마지막 음절 하나를 지움. 언어는 바뀌지 않음. 조합 중이 아니면 앱이 지움 |
| Space, Return, Tab, Esc, 문장 부호, 숫자, 화살표 | 단어를 확정하고 키는 앱이 처리함 |
| ⌘/⌃ 단축키 | 단어를 확정하고 앱에 넘김 |
| Caps Lock | 단어를 확정하고 그 뒤 글자를 영어 대문자로 그대로 입력함(바꾸기 키가 Caps Lock이 아닐 때) |
| fn(Globe) | 단어를 확정함 |
| `` ` `` | `graveTypesWon`을 켜면 ₩ |
| Return, Esc(직접 입력의 한영 자동 줄) | 그 줄의 한영 자동을 끝냄 |
| ⌘,(호스트 앱) | 설정 창을 엶 |

---

## 아키텍처

```
zlqhem/
├─ Makefile                     # make help, project, test, build, build-release, install, e2e, app, model, clean
├─ project.yml                  # XcodeGen: DuoInputMethod, Duo, DuoTests, DuoHarness
├─ Packages/DuoCore/            # SwiftPM 패키지(macOS 26, Swift 6 언어 모드)
│  ├─ Sources/DuoCore/          # 순수 엔진(Foundation만 씀)
│  │  ├─ Hangul/                # 두벌식 오토마톤, 키 입력, 자판
│  │  ├─ Detection/             # DuoModel(mmap, DUOM v1), 문자 LM, 어휘 사전, DuoDetector, 히스테리시스
│  │  ├─ Engine/                # CompositionEngine(+Typing, +Commit, +Flip, +Choice), ClientProfile,
│  │  │                         # LearningStore, FlipTapDetector, SelectionConverter, BufferTextClient
│  │  └─ Contracts/             # 공유 타입: 가설과 점수, Margins, 키 이벤트, HUD 요청, DuoSettings
│  ├─ Sources/DuoKit/           # 입력기와 호스트 앱이 함께 쓰는 AppKit·Carbon 연동
│  │  ├─ *.swift                # DuoIDs, SettingsStore, InputSourceManager, InputMethodInstaller,
│  │  │                         # KeyEventMapper, LearningPersistence, ModifierRouting, KeyScript
│  │  ├─ HUD/                   # HUDGeometry, HUDTimeline, HUDPresentation, HUDSizing, HUDAnnouncement,
│  │  │                         # SelectionConversionCheck
│  │  └─ Host/                  # HostFlow, HostRequest, InputMethodState, AppCatalog, LearningEditor,
│  │                            # LearnedWords, PlaygroundSession
│  └─ Tests/DuoCoreTests/       # Swift Testing: 오토마톤, 감지, 엔진, 시나리오, HUD, 저장, 설치, E2E 미러
├─ DuoInputMethod/              # IMK 입력기 앱(LSUIElement)
│  ├─ Sources/main.swift        # 싱글턴과 IMKServer를 만들고 앱을 돌림
│  ├─ Sources/App/              # AppDelegate, DuoRuntime(감지기, 학습, 설정, HUD 싱글턴), Log
│  ├─ Sources/Controller/       # DuoInputController, IMKTextClient, InputMenu, ModifierRouter, VoiceOverAnnouncer
│  ├─ Sources/HUD/              # CompositionHUDController, CompositionHUDPanel, CompositionHUDView, ClientWindows
│  ├─ Sources/Debug/            # DebugInjector(DEBUG 빌드에만 들어감)
│  ├─ Resources/                # duo-model.bin, duo-model.LICENSE.txt, MenuIcon.tiff, 문자열
│  └─ Info.plist
├─ Duo/                         # 호스트 앱(SwiftUI)
│  ├─ Sources/                  # App, Onboarding, Settings, Playground, Models, Design, Debug
│  ├─ Resources/                # AppIcon.icon(Icon Composer), Localizable.xcstrings
│  ├─ Tests/                    # 호스트 모델 테스트(DuoTests)
│  └─ Tools/                    # check-strings.py, MakeAppIcon.swift
├─ DuoHarness/                  # E2E 하네스 앱
├─ Tests/E2E/cases.json         # 실제 IMK 경로로 도는 E2E 사례 51개
├─ Tools/
│  ├─ ModelBuilder/             # 언어 모델 빌더와 평가(Python 3, 표준 라이브러리만)
│  ├─ IconGen/                  # 입력 소스 아이콘 생성기(make_menu_icon.swift)
│  └─ scripts/                  # build.sh, install-ime.sh, e2e.sh
├─ SPEC.md                      # 구현 명세
└─ docs/                        # STATUS.md, research/
```

### 모듈

| 모듈 | 종류 | 역할 |
|---|---|---|
| `DuoCore` | SwiftPM 라이브러리 | 두벌식 오토마톤, 언어 판별(`DuoDetector`), 조합 엔진(`CompositionEngine`), 학습 저장소, 앱 프로필, 선택 영역 변환. Foundation만 쓰고 앱과는 `TextClient`로만 말함 |
| `DuoKit` | SwiftPM 라이브러리 | 입력기와 호스트 앱이 함께 씀. ID와 설정 저장, 입력 소스 설치·켜기·선택, 키 이벤트 변환, 학습 파일 읽기·쓰기, HUD 배치·시간·표시 규칙, 호스트 앱 흐름 |
| `DuoInputMethod` | IMK 앱 | 클라이언트 세션마다 `CompositionEngine` 하나를 두는 `DuoInputController`, HUD 패널, 입력 메뉴, VoiceOver 알림 |
| `Duo` | SwiftUI 앱 | 온보딩, 설정, 연습장. `DuoInputMethod.app`을 안에 담아 설치함 |
| `DuoTests` | 테스트 번들 | 호스트 앱 모델 테스트. Duo.app을 띄우지 않음 |
| `DuoHarness` | 앱 | Duo를 고르고 자기 텍스트 뷰에 키 스크립트를 보냄. 입력기의 DEBUG 주입 훅이 실제 컨트롤러로 키를 넣음 |
| `Tools` | 스크립트 | 모델 빌더(Python), 아이콘 생성기(Swift 스크립트), 빌드·설치·E2E 스크립트 |

### 스택

| 영역 | 사용 기술(버전) |
|---|---|
| 플랫폼 | macOS 26(배포 대상 26.0), 확인한 환경 macOS 26.6.2 |
| 빌드 | Xcode 27.2(macOS 27.2 SDK), XcodeGen 2.46.0, make |
| 언어 | Swift 6.4.2, Swift 6 언어 모드, 엄격한 동시성 검사(`complete`), SwiftPM tools 6.2 |
| 입력기 | InputMethodKit, Carbon HIToolbox(TIS 입력 소스 API), AppKit(`NSPanel`), SwiftUI(HUD 그리기) |
| 호스트 앱 | SwiftUI, Liquid Glass(`.glassEffect`, `.buttonStyle(.glass)`), String Catalog(한국어 원본, 영어), Icon Composer `.icon` |
| 테스트 | Swift Testing(`swift test`, `xcodebuild test`), DuoHarness(E2E) |
| 모델 빌더 | Python 3 표준 라이브러리만 |
| 서명 | ad-hoc(`CODE_SIGN_IDENTITY = -`), hardened runtime |
| 버전 | `MARKETING_VERSION` 1.0.0 |

### 데이터와 로그

| 무엇 | 위치 | 비고 |
|---|---|---|
| 설정 | `~/Library/Preferences/com.inkyuoh.Duo.shared.plist`의 `settings.v1` | 호스트 앱과 입력기가 함께 씀. 바뀌면 `settingsChanged` 알림을 보냄 |
| Duo로 입력한 앱 | 같은 도메인의 `seenApps.v1` | 200개까지. 앱별 설정에 보임 |
| 학습 | `~/Library/Application Support/Duo/learning.json`(버전 1) | 입력기가 돌 때는 입력기만 씀. 변경을 2초 모아서 원자적으로 씀. 입력기가 돌지 않으면 호스트 앱이 삭제와 모두 지우기를 파일에 직접 씀 |
| 복구 사본 | `~/Library/Application Support/Duo/learning.corrupt-<UTC>.json` | 읽지 못한 항목이 있으면 원본을 남김. 모두 지우기가 지움 |
| 언어 모델 | `DuoInputMethod.app/Contents/Resources/duo-model.bin` | 입력기가 mmap함. 연습장은 호스트 앱 안의 입력기 번들에서 읽음 |
| 로그 | subsystem `com.inkyuoh.inputmethod.Duo` | 범주 `runtime`, `ime`, `menu`, `hud`, `learning`, `install`. 친 글자는 저장되는 수준의 로그에 남기지 않음 |

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "com.inkyuoh.inputmethod.Duo"'
```

---

## 언어 판별 모델

Duo의 언어 판별(DET)은 단어의 키 입력을 ABC 자판이 만들었을 문자열(`raw`)로 봐요. `PRdmf`는 Shift+P, Shift+R, d, m, f예요. 이 문자열 하나로 가설 세 개에 정수 로그 점수(millinats, 자연로그의 1/1000)를 매겨요. 정수만 써서 Swift 구현이 Python 참조 구현(`Tools/ModelBuilder/detector.py`)과 비트 단위로 같아요. 자세한 내용은 [`docs/research/detection.md`](./docs/research/detection.md)에 있어요.

| 가설 | 보여 주는 글자 | 예 |
|---|---|---|
| `K`(한국어) | `raw`에 두벌식 오토마톤을 적용함 | `dkssud` → 안녕 |
| `E`(영어) | `raw` 그대로(친 대소문자 그대로) | `meeting` → meeting |
| `M(b)`(라틴 단어 + 붙은 한국어) | 앞 `b`글자는 그대로, 나머지에 오토마톤 | `PRdmf` → PR을, `pushgoTdjdy` → push했어요, `LGwjswk` → LG전자 |

한국어는 라틴 단어 뒤에 조사와 어미를 띄우지 않고 붙여요. 그래서 세 번째 가설이 필요해요. 이 가설을 빼면 혼합 개발자 채팅에서 1.2 pt가 떨어져요.

- 점수 요소: 5차 modified Kneser-Ney 문자 LM 두 개(한국어, 영어. 37개 기호의 키 입력 알파벳을 함께 씀), 한국어 상위 100,000 어절과 영어 상위 60,000 단어 어휘 사전, 외톨이 자모 벌점, Shift·대소문자 모델, 라틴 뒤 접미사 1,684개, 문맥 사전 확률(START, KO, EN, NUM), 종결 키 단서, 사용자 학습 횟수
- 접두 모드는 단어가 이어질 수 있다고 보고 점수를 냄. 조합 중 표시에 씀
- 최종 모드는 단어가 끝났다고 보고 어휘 사전까지 씀. 확정에 씀
- 동점이면 `K, E, M(1), M(2), …` 순서에서 앞선 가설이 이김

엔진은 아래 기준값을 써요(`Packages/DuoCore/Sources/DuoCore/Contracts/DetectionContract.swift`의 `Margins`, 모델 `meta.params`의 `HYST`).

| 이름 | 값(millinats) | 뜻 | 쓰는 곳 |
|---|---|---|---|
| `uncertainCommit` | 619 | 다른 읽기 P ≥ 35 % | 확정 뒤 마지막 단어의 후보 막대 |
| `hudAlternative` | 1386 | 다른 읽기 P ≥ 20 % | 확정할 때 +1표 |
| `hudCandidates` | 2944 | 다른 읽기 P ≥ 5 % | 치는 중 후보 막대 |
| `eagerCommit` | 4595 | 다른 읽기 P < 1 % | 영어 바로 확정, 바꾸기가 고르는 섞인 읽기 |
| `HYST` | 1500 | 표시 히스테리시스 | 보이는 읽기를 바꾸는 문턱 |

### 모델 파일

`duo-model.bin`(DUOM v1)은 mmap할 수 있는 리틀 엔디언 파일 하나예요. 빌드는 결정적이라 두 번 빌드해도 바이트까지 같아요.

| 부분 | 크기 |
|---|---|
| 한국어 LM(order 5, 가지치기, 양자화) | 1.44 MB |
| 영어 LM | 2.60 MB |
| 한국어 어휘 사전(100,000 어절) | 0.90 MB |
| 영어 어휘 사전(60,000 단어) | 0.54 MB |
| meta JSON(매개변수, 코드북, 접미사, 대소문자 어휘 사전, 단위 56개) | 0.15 MB |
| **전체** | **5.63 MB**, 내용 해시 `5c028cbea247bcc5` |

### 정확도

배포하는 파일로, 학습에 쓰지 않은 문체에서 쟀어요.

| 세트 | 단어 정확도 |
|---|---|
| 문맥 없는 낱단어: 한국어 뉴스의 한국어 / 한국어 글 속 영어 / 영어 뉴스 | 99.48 % / 99.44 % / 99.89 % |
| 이어진 글: 한국어 뉴스 | 99.90 % |
| 이어진 글: 한국어 위키백과 | 99.89 % |
| 이어진 글: 영어 뉴스 | 99.99 % |
| 이어진 글: 직접 쓴 혼합 개발자 채팅(417문장, 1,385단어) | 99.86 %(오류 2개: `so`, `go`) |
| 표시 깜빡임: 한국어 단어 / 영어 문맥 속 영어 | 0.000 / 0.012 바뀜/단어 |

### 데이터와 라이선스

| 데이터 | 용도 | 라이선스 |
|---|---|---|
| OpenSubtitles2018 단어 빈도(Hermit Dave의 FrequencyWords) | 한국어·영어 학습(구어체) | CC BY-SA 4.0 |
| 한국어 위키백과 덤프 1번 조각 | 한국어 학습(문어체) | CC BY-SA 4.0 |
| wordfreq(Robyn Speer) `large_en` | 영어 학습 | 데이터 CC BY-SA 4.0 |
| 직접 만든 목록(`Tools/ModelBuilder/data/`): 기술 용어, 채팅 자모, 접미사, 혼합 테스트 세트 | 학습과 테스트 | 프로젝트(CC0) |
| Leipzig Corpora Collection 뉴스·위키백과 문장 | 평가 전용. 배포하지 않음 | LCC 이용 약관 |

모델 파일은 CC BY-SA 4.0 데이터를 변형한 저작물이라 같은 라이선스로, 저작자 표시와 함께 배포해요. 고지문은 `DuoInputMethod/Resources/duo-model.LICENSE.txt`에 있고 설정 ▸ 정보에도 보여요. Duo 앱 코드는 이 라이선스와 상관없어요.

모델을 다시 만들려면 말뭉치(약 200 MB)를 `Tools/data/raw/`에 내려받고 `make model`을 돌려요. 결과는 `Tools/ModelBuilder/out/`에 생기고, `duo-model.bin`은 `DuoInputMethod/Resources/`로, `test_vectors.json`은 `Packages/DuoCore/Tests/DuoCoreTests/Resources/`로 복사해서 써요. 내려받을 주소와 평가 명령은 detection.md 11절에 있어요.

---

## 테스트와 검증

| 검사 | 명령 | 결과 |
|---|---|---|
| 패키지 단위 테스트(debug) | `make test` | 46개 묶음, 491개 테스트 통과. 알려진 문제 4개 |
| 호스트 앱 테스트 | `xcodebuild test -scheme Duo` | 11개 묶음, 50개 테스트 통과 |
| 실제 IMK E2E | `make e2e` | 51/51 |
| E2E 미러(`E2ECaseMirrorTests`) | `make test`에 들어 있음 | 51개 사례를 프로세스 안에서 실제 모델로 다시 돌림 |
| DET 골든 벡터 | `make test`에 들어 있음 | Python 참조 구현과 비트 단위로 같음. 모델 해시 `5c028cbea247bcc5` |
| 문자열 카탈로그 | `Duo/Tools/check-strings.py` | 206/206 키 |
| 점수 계산 벤치마크(release, 단독 실행) | `swift test -c release` | p99 접두 15.6 µs, 최종 17.1 µs, 둘을 합쳐 32.7 µs. 예산 300 µs. 2차 수정 때 잰 값이고 최신 작업 뒤에는 다시 재지 않음(docs/STATUS.md) |

알려진 문제 4개는 DET가 UX 기대와 다른 시나리오예요(`withKnownIssue`, [알려진 제한](#알려진-제한) 참고). 실제 앱 QA는 TextEdit, Safari, Chrome의 textarea와 contenteditable, Terminal(zsh), VS Code, 호스트 앱 온보딩에서 실제 키 입력으로 했어요(docs/STATUS.md).

```sh
make test                                                     # swift test(debug), build/spm
cd Packages/DuoCore && swift test -c release --scratch-path ../../build/spm-rel   # 벤치마크 포함
xcodebuild test -project Duo.xcodeproj -scheme Duo -destination 'platform=macOS' -derivedDataPath build/dd
make e2e                                                      # 설치 + 하네스 + 실제 실행
Tools/scripts/e2e.sh -e "dkssud{space}"                       # 한 번만 돌리는 스크립트
Duo/Tools/check-strings.py build/dd/Build/Intermediates.noindex/Duo.build/Debug/Duo.build
```

- 새 E2E 사례는 `Tests/E2E/cases.json`에 더하고 `make test`부터 돌림. 미러가 실제 실행과 같은 학습 순서로 사례를 다시 돌림
- 한 사례의 바꾸기는 뒤 사례에서 학습된 상태로 남음. 앞 사례가 바꾸지 않은 단어를 씀
- 키 스크립트 문법(`DuoKit/KeyScript.swift`): 글자 그대로, `{space} {S-space} {ret} {tab} {esc} {bs} {del}`, 화살표(`{left}` 등)와 `{home} {end}`, `{rcmd}` 같은 수정 키 톡과 `{caps}`, `{cmd+a}` 같은 동시 누름, `{press:rcmd}c{release:rcmd}` 같은 누르고 있기, `{wait:ms}`, `{click}`

---

## 알려진 제한

- **아이콘이 바뀐 뒤 캐럿 옆 표시가 예전 모습으로 보일 수 있음.** macOS 26은 입력 소스를 바꿀 때 캐럿 옆에 알약을 띄움. Duo는 초록 알약 안에 흰 "한A" 타일로 보임. 메뉴 막대와 입력 메뉴에는 애플 입력 소스와 같은 크기의 템플릿 알약(`TISIconIsTemplate = true`)이 보여서 밝은 모드와 다크 모드를 따라 색이 바뀜. ⌘Space 목록에는 이름 "Duo"가 보임
  - 이 알약을 그리는 `CursorUIViewService`는 로그인 동안 예전 모습을 들고 있음. 아이콘이 바뀐 빌드를 설치한 뒤 예전 아이콘이나 빈 알약이 보이면 `killall -KILL CursorUIViewService`를 실행하거나 로그아웃함. 강제 종료한 뒤 알약이 뜨지 않으면 앱 하나를 새로 실행함. 화면 잠금으로는 고쳐지지 않음
- **다시 설치한 뒤 다시 연결해야 함.** `make install`이나 `install-ime.sh` 뒤에는 Duo를 쓰던 앱이 ABC로 입력됨. 그 앱이 앞에 있을 때 Duo를 다시 고르거나 다른 앱에 갔다 와야 함. 호스트 앱의 설치, 업데이트, 다시 시작은 이 재선택을 직접 함. 뒤에 있던 앱은 다음 포커스 변화 때 다시 붙음
- **확정한 글자를 바꿀 수 없는 앱.** Monaco 편집기(VS Code와 그 갈래), iTerm2, Hyper, JetBrains IDE, Android Studio, Orca에서는 확정한 단어를 바꾸지 못함. "여기서는 바꿀 수 없어요"를 띄움
  - xterm.js 터미널 중에는 Orca만 목록(`ClientProfile.xtermTerminals`)에 있음. 다른 xterm.js 터미널은 확인하지 않았음
- **DET가 UX 기대와 다른 경우(알려진 문제 3개).**
  - 영어 뒤의 `gg`, `rt`는 ㅎㅎ, ㄱㅅ이 됨
  - 문장 처음의 `eeee`는 라틴 글자로 남음
- **한글 바로 뒤의 라틴은 쌍자음 없는 대문자로 시작할 때만 나뉨.** 한A, 삼성SDI, 갤럭시S24, 그런데API를은 됨
  - 소문자나 Q W E R T O P 대문자로 시작하면 한 단어로 읽힘. `카톡id`(`zkxhrid`)는 카토걍, 카카오T(`zkzkdhT`)는 카카옸이 됨
  - 라틴 대문자 한 글자 + 조사나 호칭(A씨, A양, A군, B급, S가)은 한국어 문장에서 맞게 나옴. 영어 문장 안에서는 영어 이름처럼 남음(`Arns`)
  - 소문자 한 글자 + 조사(a양, a군)는 스스로 고르지 않음. 바꾸기 키나 후보 막대로 고름. `adid`는 바꾸기 키가 ㅁ양으로 감
  - 앞 단어가 짧아서 한국어로 약하게 읽히면 나누지 않음. 새, 애, 해는 to, do, go와 키가 같음. 그래서 toString, doSomething은 그대로 남음
  - 한국어 단어 안에서 ⇧를 잘못 누르면 단어가 나뉠 수 있음(`gksrMf` → 한ㄱMf). ⌫로 대문자를 지우면 다시 합쳐짐. 뒤 키가 한국어로 분명하면 저절로 합쳐짐(`dkssudGktpdy` → 안녕하세요)
- **ㅠㅠ, ㅜㅜ(`bb`, `nn`)는 치는 동안 라틴 글자로 보임.** 확정은 맞고 마지막 단어의 후보 막대가 뜸
- **IMK 콜백 밖의 답은 낡았을 수 있음.** 메뉴 동작, 입력 소스가 바뀔 때의 확정, 전역 모니터 경로, 후보 막대 클릭은 콜백 밖에서 돎. 이때 앱의 `selectedRange`와 `attributedSubstring`이 낡았을 수 있음. 선택한 텍스트 한↔A 변환 자체는 실제 앱에서 아직 확인하지 않음
- **E2E는 주입 경로임.** 키가 실제 컨트롤러에 닿지만 TSM 키 라우팅은 거치지 않음. 창 서버의 동시 누름(chord) 검사, Chromium의 중복 `flagsChanged`, ⇧Space·Caps Lock 바꾸기 키, 직접 입력 프로필, 자동 반복은 단위 테스트로만 확인함
- **실제 앱에서 확인하지 않은 것.** VoiceOver 알림, 1x 디스플레이에서 처음 뜨는 HUD 크기, 데스크톱 공간(Space) 전환과 디스플레이 변경 때 숨기기, Orca 자체, Chrome·Safari의 클릭 경로
- **입력기 단위 테스트 타깃이 없음.** 순수한 라우팅 규칙은 DuoKit에서 테스트함. IMK 어댑터, 메뉴, DebugInjector 제한, 입력기의 학습 쓰기, HUD 패널은 빌드와 E2E로만 확인함
- **새 형식의 학습 파일.** 버전 1보다 새 `learning.json`은 읽을 수 있는 것만 읽고, 다음 변경 때 버전 1로 다시 씀. 원본은 `learning.corrupt-*.json`으로 남고 모두 지우기만 이 사본을 지움
- **`terminateRunningServer()`는 막힘.** 옛 서버를 기다리며 4초까지 걸리고, 다시 고르기에 약 0.3초가 더 걸림. 호스트 앱은 메인 스레드 밖에서 부름
- **연습장의 Caps Lock + ⇧.** `BufferTextClient`는 Caps Lock + ⇧ 글자를 소문자로 다루지만 macOS ABC는 대문자를 냄. 여기에 기대는 테스트는 없음
- **`LearningWriter` 디바운스 테스트는 실제로 기다림.** 여기서는 안정적이지만 부하가 큰 CI에서는 흔들릴 수 있음

---

## 참고한 솔루션

연구 문서(`docs/research/`)에서 살펴본 제품과 입력기예요.

| 솔루션 | 가져온 아이디어 |
|---|---|
| **iOS 18 한국어·영어 이중 언어 키보드** | 한/영 키 없이 글자 순서로 언어를 추론하는 경험. 추천 막대에서 원하는 단어를 고르는 방식은 후보 막대와 바꾸기 키가 됨 |
| **Apple macOS 두벌식 입력기** | 동등성 기준. 자소/글자 삭제 단위, `` ` `` 키로 ₩, 경계 키에서 확정하고 통과시키기, 16/32 px 다중 표현 TIFF 아이콘 |
| **MS Office 한/영 자동 고침** | 반면교사. 보이지 않는 사후 변환을 하지 않음. 코드, URL, 식별자는 리터럴로 둠. 예외 목록 대신 학습함 |
| **Punto Switcher** | 앱별 기억, 같은 변환을 되돌리면 배우기, 마지막 단어 고치기와 선택 영역 변환을 따로 둠 |
| **Caramba Switcher** | 기본값은 강하게, 설정은 적게. ⇧ 두 번으로 마지막 단어 바꾸기. 암호는 건드리지 않음 |
| **Enko** | 선택한 글자만 바꾸는 변환(dkssudgktpdy → 안녕하세요). 선택한 텍스트 한↔A 변환이 됨 |
| **LangSwitcher, Input Source Pro** | 앱별 언어(카카오톡 → 한국어, Terminal → 영어). 앱 프로필 기본값이 됨 |
| **Karabiner 한/영 매핑** | 많은 Mac 사용자가 오른쪽 ⌘를 한/영에 씀. 기본 바꾸기 키를 오른쪽 ⌘ 톡으로 고른 근거임 |
| **Gureum** | 마우스 클릭을 `handle`에서 받아 확정하기, `activateServer`에서 ABC 자판으로 `overrideKeyboard`하기 |
| **macSKK** | 확정 취소(確定アンドゥ): 검증한 범위로 확정한 단어를 바꿈. IMK 메뉴는 하위 메뉴를 무시함. `nonisolated` + `MainActor.assumeIsolated` 패턴 |
| **Squirrel(Rime)** | keyCode 0 `flagsChanged` 무시, macOS 26에서 코드로 입력 소스를 바꾸면 `deactivateServer`가 불리지 않는 문제와 TIS 알림 감시. HUD 창 레벨은 Squirrel의 `CGShieldingWindowLevel`을 따르지 않음. 잠금 화면 위에 뜨기 때문임. 대신 `max(앱 창 레벨 + 1, popUpMenu)`를 씀 |
| **azooKey-Desktop** | `handle` 안에서 조합 문자열을 동기로 설정하기(iTerm2 첫 글자 중복), nil이 아닌 attributed string 넘기기(26.6.2 크래시), HUD 패널 하나만 재사용하기 |
| **vChewing, Fire** | 서드파티 입력 소스를 켤 때 뜨는 macOS 허용 창, 이미 켜졌으면 다시 켜지 않기, 번들을 바꾼 뒤에 옛 서버 멈추기 |
