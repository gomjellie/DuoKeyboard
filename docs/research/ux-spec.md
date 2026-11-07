# Duo: 입력 동작과 UX 명세 (v1)

상태: v1 구현용으로 결정한 명세. 담당: UX 트랙. 대상: macOS 26 Tahoe, InputMethodKit, Swift 6.
아래 결정마다 고른 동작과 한 줄 근거를 적었어요. **(확인 필요)** 표시 항목은 실제 기기에서 간단한 QA 확인이 필요해요. 확인 결과로 설계가 바뀌지는 않아요.

---

## 0. 결정 한눈에 보기

| # | 주제 | 결정 | 근거 |
|---|---|---|---|
| D1 | 사용자에게 보이는 것 | **WYSIWYG.** 확정되는 글자는 늘 확정 순간 화면에 보이던 조합 문자열(marked text) 그대로임. Duo는 경계에서 단어를 몰래 변환하지 않음. | MS Office 한/영 자동 고침 사용자가 가장 싫어하는 건 눈으로 보지 못한 변환임. |
| D2 | 조합 모델 | 단어(**token**)는 여러 단계를 거침: **U**(미정, 단어 전체가 조합 문자열) → **E**(영어로 결정, 바로 확정하고 나머지 글자는 그대로 통과) / **K**(한국어로 결정, Apple 두벌식과 똑같이 동작: 완성된 음절은 확정되고 현재 음절만 조합 문자열로 남음) / **L**(리터럴: URL, 이메일, 경로, 코드. 확정하고 공백이 나올 때까지 그대로 통과). | 조합 문자열이 짧게 유지됨. 그래서 자동 완성, 입력 중 검색, 터미널, 웹의 "Enter" 처리가 Apple 한국어 입력기를 쓸 때와 똑같이 동작함. |
| D3 | 바꾸기 키 | 기본값은 **오른쪽 ⌘ 톡**(사이에 다른 입력 없이 300 ms 안에 눌렀다 뗌). 설정에서 고를 수 있는 대안: 오른쪽 ⌥ 톡, ⇧ 두 번 톡, ⇧Space, Caps Lock(실험적). **Tab은 절대 안 씀.** | 오른손 엄지가 이미 그 위에 있음. 단독으로 쓰는 일이 거의 없음. 많은 한국 Mac 사용자가 이미 오른쪽 ⌘를 한/영에 매핑해 씀. 타이핑과 부딪힐 일도 없음. |
| D4 | 바꾸기 의미 | 키 하나가 상황에 따라 다르게 동작함: (a) 조합 중 → 현재 단어를 다른 해석으로 바꾸고 고정함, (b) Duo가 방금 확정한 단어 바로 뒤에 캐럿이 있음 → 그 단어를 바꿈(replacementRange), (c) 바꿀 것이 없음 → **다음** 단어의 언어를 한 번만 강제하고 한/A 배지를 보여 줌. | 두 습관 모두에 맞음: "친 걸 고치기"와 예전 방식인 "한/영을 먼저 누르고 치기". |
| D5 | 변환 되돌리기 | 바꾸기는 스스로를 되돌림(한 번 더 톡). **Backspace에 다른 기능을 겹치지 않음.** Backspace는 늘 지우기만 함. 확정 직후에는 HUD가 "마지막 단어 바꾸기"를 제안함. | Backspace에 기능을 겹치면 지우는 속도감이 달라짐. 대부분의 사용자가 놀랄 것임. |
| D6 | 학습 | 명시적으로 바꿀 때마다 실제로 친 키 문자열(대소문자 구분)에 한 표를 기록함. 모델이 아주 확신하지 않는 한, 한 번 바꾸면 다음번에 그 결과가 이김. 두 번 바꾸면 항상 이김. 표의 반감기는 60일. | 고친 결과는 빨리 자리 잡아야 함(iOS처럼). 하지만 "the"를 실수로 한 번 바꿨다고 망가지면 안 됨. |
| D7 | 보안 입력 | `IsSecureEventInputEnabled()`가 true면 Duo는 조합하지 않고 HUD도 띄우지 않음. 키는 그대로 통과함. | 암호 필드에 조합 문자열이 생기면 암호가 화면에 보임. 한글로 변환되면 암호가 틀어짐. |
| D8 | 터미널 | 기본 프로필은 **Direct**(직접 입력): 키가 그대로 통과함. 오른쪽 ⌘ 톡을 하면 현재 줄만 Bilingual(이중 언어)로 들어감. Return이나 Esc를 누르면 Direct로 돌아감. | vim, less, fzf, htop, REPL은 모든 키를 바로 받아야 함. 셸에서 한국어를 쓰는 건 예외적인 경우임. |
| D9 | Caps Lock | Caps Lock 켜짐 = **영어 고정**(조합 없이 대문자 그대로). | 한국어에는 대소문자가 없음. 그래서 전부 대문자면 분명한 영어 의도이고, 새 개념도 필요 없음. |
| D10 | 섞인 단어 | 자동 지원: 영어 어간 + 한국어 접미사(API를, React컴포넌트, push했어), 그리고 영어 부분이 대문자로 시작하는 한국어 + 영어(갤럭시S24). 그 밖의 한국어→영어 연결은 범위에서 뺌. 이때 사용자는 →로 확정한 뒤 이어서 침. | 영어 명사에 조사가 붙는 일은 한국어 글에서 아주 흔함. 개발자는 더 그럼. |
| D11 | 숫자 | 숫자는 늘 진행 중인 단어를 확정하고 통과함. 숫자 뒤의 글자는 수 단위(counter/unit) 사전 확률(prior)을 가진 새 단어를 시작함(3시, 10개, 3pm, 4K). | 숫자는 절대 모호하지 않음. 흔한 경우는 수 단위 사전 확률이 처리함. |
| D12 | HUD | 캐럿 아래의 Liquid Glass 캡슐이 다른 해석 하나와 바꾸기 키 기호를 보여 줌. 정말 모호하고(다른 해석 ≥ 20%) 사용자가 300 ms 멈출 때만 나타남. 한 번 뜨면 확정까지 유지됨. 자동 반복 중, 보안 입력 중, Direct 모드, 캐럿 사각형이 잘못됐을 때는 절대 안 뜸. | 단어마다 깜빡이지 않으면서 기능을 알려 줌. |
| D13 | 메뉴 막대 | MenuBarExtra를 따로 두지 않음. Duo는 입력 메뉴(`IMKInputController.menu()`)만 씀. | 메뉴 막대에 아이콘 하나만 두는 게 Apple 방식임. |

---

## 1. 조사 결과

### 1.1 iOS/iPadOS 이중 언어 키보드 (기준이 되는 경험)
- 다국어 입력은 iOS 10부터 있었음: 키보드 두 개를 추가하면 전환 없이 두 언어 모두 예측과 자동 수정이 동작함([AppleInsider](https://forums.appleinsider.com/discussion/193710), [Cult of Mac](https://www.cultofmac.com/how-to/how-to-set-up-multilingual-typing-in-ios-10)). Apple 설명서 문구: *"키보드를 전환하지 않고도 두 가지 언어로 입력할 수 있습니다… 가장 자주 사용하는 두 언어 사이를 자동으로 전환합니다"*. 이 기능은 모든 언어에서 쓸 수 있지는 않음([Apple iPhone 사용 설명서](https://support.apple.com/en-ph/guide/iphone/iph73b71eb/ios)).
- **iOS 18에 한국어 + 영어 "멀티스크립트" 키보드가 추가됨**(WWDC24: "한국어와 영어 문자를 하나로 통합된 경험에서 입력") ([TechCrunch](https://techcrunch.com/2024/07/02/apple-adds-support-for-new-languages-across-lock-screen-keyboard-and-search-on-ios-18), [WWDC24 10185 노트](https://wwdcnotes.com/documentation/wwdc24-10185-build-multilingualready-apps/)). 한국 사용자들이 전한 동작([extrememanual](https://extrememanual.net/54072)):
  - QWERTY 키에 **한글이 주 표기이고 오른쪽 위에 작은 라틴 문자**가 있음. **한/영 키는 없음**.
  - 언어는 글자 순서로 추론함. 예: "ghdrlfehd" → 홍길동.
  - 추천 막대가 수정 수단임(원하는 단어를 고름). Duo의 HUD + 바꾸기에 해당하는 iOS 방식임.
  - 한국어 키보드 자판 옵션 "이중 언어 (한국어 및 영어)"로 설정함.
- iOS 이중 언어 키보드에 대해 알려진 불만:
  - "계속 엉뚱한 언어로 나랑 싸운다", 자동 수정이 한 언어에 갇힘([r/iOSBeta](https://lr.eu.psf.lt/r/iOSBeta/comments/1dcvps5/ios_18_db1_now_supports_multilingual_keyboard)).
  - 겹모음을 치기 어려움([Apple Community KR](https://discussionskorea.apple.com/thread/256109234)).
  - 웹/UIKit 앱이 이중 언어 키보드의 조합과 잘 맞지 않음: 조합 중에 앱이 `text`를 바꾸면 `onChange`가 여러 번 불리고 오래된 글자가 남음([개발자 포럼 765324](https://developer.apple.com/forums/thread/765324), [767894](https://developer.apple.com/forums/thread/767894)).
  - **교훈:** 조합 방식은 가능한 한 일반 한국어 입력기와 똑같이 유지함(D2). 사용자에게는 믿을 만한 수동 바꾸기 수단 하나를 줌(D3).
- Apple 개발 지침: 조합 문자열이 있는 동안 텍스트를 바꾸지 말 것. `textInputContextIdentifier`로 키보드가 맥락별 언어를 기억할 수 있음(메시지 앱 예시). Duo의 앱별 사전 확률이 Mac에서 같은 역할을 함.

### 1.2 macOS 26: 한국어/영어 이중 언어 모드가 없음
- macOS에서 Apple의 이중 언어 입력이나 자동 전환 입력은 찾지 못함. zsh-hangul 작성자도 iPhone에는 이중 언어 키보드가 있고 Mac에는 없다고 짚음([GeekNews](https://news.hada.io/topic?id=22660)).
- macOS 26에 있는 것:
  - Caps Lock, Globe/fn, ⌃Space(이전 소스), ⌃⌥Space(다음 소스)로 입력 소스 전환([Apple 한국어 입력기 설명서, macOS 26](https://support.apple.com/ar-bh/guide/korean-input-method/him001/104/mac/26)).
  - "문서의 입력 소스로 자동 전환"([Apple](https://support.apple.com/en-au/guide/mac-help/mchl84525d76/26/mac)).
- Tahoe 시기의 전환 버그:
  - ⌃Space를 2–3번 눌러야 함([스레드](https://discussions.apple.com/thread/256254361)).
  - 26.3 이후 열기/저장 대화상자에서 전환이 안 됨([스레드](https://discussions.apple.com/thread/256247006)).
  - 포커스가 바뀌면 입력 소스가 원래대로 돌아감([스레드](https://discussions.apple.com/thread/256144071)).
  - Duo는 입력 소스 하나만 쓰는 모델이라 이런 문제를 통째로 피함. 온보딩에서 내세울 장점임.

### 1.3 Apple macOS 한국어 두벌식 입력기 (동등성 기준)
Apple의 macOS 26 설명서([him001](https://support.apple.com/ar-bh/guide/korean-input-method/him001/104/mac/26))와 널리 알려진 동작을 바탕으로 정리했어요:
- 자판: 두벌식(기본), 세벌식, 세벌식 390, 공진청 로마자, HNC 로마자.
- 설정: 후보 글꼴 크기, 한자 입력 형식, **"삭제 단위: 자소(조합 중 낱자 단위) 또는 글자(음절 전체)"**.
- **Option-Return** = 커서 앞에서 가장 길게 맞는 부분을 한자로 변환함. Esc는 후보 창을 닫고 글자를 되돌림.
- Caps Lock 전환은 시스템 옵션임: "Caps Lock 키로 [마지막으로 사용한 라틴 입력 소스]로 전환 및 해제". 서드파티 입력기에서는 믿기 어려움([daleseo](https://daleseo.com/macos-korean-input/)).
- **현재 음절만 조합 문자열로 표시됨.**
  - Space, Return, Tab, 화살표, 문장 부호, Esc, ⌘/⌃ 단축키는 음절을 확정한 다음 원래대로 동작함(통과).
  - 클릭이나 포커스 변경도 확정함.
  - 조합 중 Backspace는 자모 하나를 지움(자소 모드). 확정 후에는 앱이 음절 단위로 지움.
- 두벌식에서는 **` 키가 ₩를 입력함**. 이걸 끄는 옵션은 없음. 개발자들은 `~/Library/KeyBindings/DefaultKeyBinding.dict`(`"₩" = ("insertText:", "`");`)로 고쳐 씀([gist](https://gist.github.com/redism/43bc51cab62269fa97a220a7bb5e1103), [daleseo](https://daleseo.com/macos-korean-input/)).
- Vim 문제: 노멀 모드 명령은 평범한 글자라서 한국어 입력기가 이를 조합해 버림(gureum에는 "Vi 모드: Esc로 로마자 전환" 옵션이 있음) ([daleseo/gureum](https://daleseo.com/gureum/), [gureum 소스](https://github.com/gureum/gureum)).
- 웹/Electron의 "조합 중 Enter" 버그가 널리 퍼져 있음:
  - 마지막 글자가 다시 보내지거나 사라짐: Claude Code VS Code 확장([PR](https://gh.r-mj.com/andrepimenta/claude-code-chat/pull/146)), Warp 터미널([이슈 8919](https://upd.dev/warpdotdev/warp/issues/8919): "macOS 네이티브 앱은 영향을 받지 않음", 우회 방법: Enter 전에 → 누르기), Firefox([1632597](https://bugzilla.mozilla.org/show_bug.cgi?id=1632597)).
  - **시사점:** 앱들은 "조합 중인 음절 하나 + Enter"에 맞춰져 있음. Duo는 Return 시점에 긴 조합 문자열을 남기면 안 됨. D2에서 바로 확정하는 단계를 둔 이유임.

### 1.4 Windows / Office "한/영 자동 고침"
- 단어 경계에서 잘못된 자판으로 친 단어를 변환함("gksrmf" → 한글). Office에는 자동 고침 옵션 → 예외 항목 → 한/영 자동 고침에 예외 목록이 있음. 이 설정은 Word, Excel, PowerPoint, Outlook이 함께 씀([wikidocs](https://wikidocs.net/228455), [bluesharehub](https://bluesharehub.com/엑셀-한영-자동고침-옵션해제-한영-자동변환데이터/)).
- 가장 큰 불만: 제품/재고 코드와 약어가 몰래 변환됨([oppadu](https://www.oppadu.com/shorts/%ec%97%91%ec%85%80-%ed%95%9c%ea%b8%80-%ec%98%81%ec%96%b4-%eb%b0%94%eb%80%9c/)). 가장 흔한 조언은 "꺼라"임.
- **교훈:** 보이지 않는 사후 변환은 하지 않음(D1). 코드, URL, 식별자는 리터럴로 처리함(4.4절). 예외 목록 대신 학습한 예외를 씀(5.5절).

### 1.5 Punto Switcher, Caramba, 한국 Mac 유틸리티
- **Punto Switcher (Yandex)** ([Mac 도움말](https://yandex.ru/support/punto-mac), [Mac 설정](https://yandex.ru/support2/punto-mac/ru/settings)):
  - 사전 기반으로 감지함. 몇 글자 뒤에 전환하거나 "단어가 끝날 때까지 기다림".
  - 마지막 변환 취소 / 선택 영역 변환 단축키가 있음.
  - "Tab과 Enter 뒤에는 전환하지 않기".
  - "앱별로 자판 기억하기".
  - 규칙(절대 전환하지 않을 단어)은 **정확히 일치 / 시작 일치 / 포함** 방식으로 맞추고, 대소문자 구분 옵션이 있음.
  - **자가 학습: 같은 3글자 이상 조합의 자동 전환을 사용자가 두 번 이상 취소하면 규칙을 만들자고 제안함.**
  - 프로그램 제외 목록이 있음. "자동 전환"과 "자동 전환 취소"에 소리가 남.
  - Windows에서는 Pause/Break로 마지막 단어를, Shift+Break로 선택 영역을 고침([habr](https://habr.com/ru/articles/39353/comments/), [overclockers](https://overclockers.ru/softnews/amp/17695/Punto_Switcher_2.9_avtoperekljuchenie_raskladki_klaviatury)).
  - Pause/Break 단축키는 앱과 충돌함([Notepad++ 포럼](https://community.notepad-plus-plus.org/post/93621)).
- **Caramba Switcher**(Punto 제작자가 만듦) ([lifehacker](https://lifehacker.ru/caramba-switcher/), [iguides](https://www.iguides.ru/main/os/caramba_switcher/)):
  - Punto의 설정 96개 대신 **설정이 딱 하나**임.
  - ⇧ 두 번으로 마지막 단어를 다시 전환하고, ⌥⇧로 선택 영역을 변환함.
  - 암호를 알아봄.
  - 게임과 프로그래밍 환경에서는 스스로 꺼짐.
  - 사용자 댓글에는 브라우저 양식에서 단축키가 원치 않게 눌린다는 불만이 있음.
- **한국 Mac 도구:**
  - Enko: 글자를 선택하고 단축키를 누르면 dkssudgktpdy→안녕하세요([App Store](https://apps.apple.com/kr/app/enko-%EC%98%81%ED%95%9C-%EC%98%A4%ED%83%80-%EB%B3%80%ED%99%98%EA%B8%B0/id6746715150?l=ko)).
  - LangSwitcher(오픈 소스, 카카오톡→한국어, Terminal→영어) ([damoang](https://damoang.net/macmoang/7280)).
  - Input Source Pro(앱별, 웹사이트별) ([GitHub](https://github.com/Sailfishc/inputsourcepro)).
  - zsh-hangul: 한글로 잘못 친 명령을 변환함(ㅊㅇ→cd). **따옴표 안의 글자는 건너뜀**. 붙여 넣은 글자와 AI 도구도 건너뜀([GeekNews](https://news.hada.io/topic?id=22660)).
  - 1990년대 후반의 IE 툴바는 ㅈㅈㅈ을 "www."로 바꿔 줬음(같은 스레드).
- **교훈:**
  1. 기본값은 강하게, 설정은 아주 적게(Caramba).
  2. 앱별 기억(Punto, LangSwitcher).
  3. 반복된 취소에서 학습(Punto).
  4. 암호와 코드는 절대 건드리지 않음(Caramba).
  5. 마지막 단어는 키 하나로 고침(모두 공통).
  6. 선택 영역 변환은 따로, 의도해서 하는 동작임(Enko).

### 1.6 실패 유형과 각각의 대응책

| 실제로 보인 실패 유형 | Duo의 대응책 |
|---|---|
| 코드, 약어, URL이 몰래 변환됨 | WYSIWYG(D1). URL/이메일/경로/코드는 L 단계. 숫자 규칙. 학습한 재정의. |
| 엉뚱한 언어가 사용자와 "싸움" | 입력 중 히스테리시스(2.4절). 바꾸면 단어가 고정됨. 학습(5.5절). |
| 암호가 변환됨 | 보안 입력 우회(D7). 섞인 단어 규칙. 터미널 Direct 프로필. |
| 웹 앱에서 Enter가 마지막 조합 글자를 중복하거나 빠뜨림 | 바로 확정하는 E/K 단계 덕분에 Return 시점의 조합 문자열은 많아야 음절 하나(또는 보류 키 ≤2개)임. Apple 두벌식과 같음. |
| Vim/TUI 키를 조합이 삼켜 버림 | 터미널은 Direct 프로필(D8). Esc는 확정하고 통과함. |
| 단축키 충돌(Pause/Break, Shift+Space, Tab) | 오른쪽 ⌘ 톡은 flagsChanged로 감지함. 수정자 키 이벤트는 절대 소비하지 않음. |
| 되돌리기 어려움 | 바꾸기는 토글임. 확정은 평범한 삽입이라 Cmd+Z도 그대로 동작함. |

---

## 2. 핵심 모델

### 2.1 용어
- **키 이벤트**: `handle(_:client:)`로 전달되는 `keyDown` NSEvent. Duo는 문자가 아니라 **키**(keyCode + Shift 상태)를 다룸. 키를 US QWERTY 라틴 문자와 두벌식 자모에 대응시킴:
  - `q ㅂ w ㅈ e ㄷ r ㄱ t ㅅ y ㅛ u ㅕ i ㅑ o ㅐ p ㅔ`
  - `a ㅁ s ㄴ d ㅇ f ㄹ g ㅎ h ㅗ j ㅓ k ㅏ l ㅣ`
  - `z ㅋ x ㅌ c ㅊ v ㅍ b ㅠ n ㅜ m ㅡ`
  - Shift 조합: `Q ㅃ W ㅉ E ㄸ R ㄲ T ㅆ O ㅒ P ㅖ`. 나머지 Shift 글자는 Apple과 똑같이 기본 자모가 나옴.
- **단어(token)**: 마지막 경계 이후 이어진 글자 키(연결 문자 포함, 4.2절)의 가장 긴 연속.
- **해석**: 단어의 한글 문자열(두벌식 오토마타 출력)이나 라틴 문자열(대소문자를 살린 글자 그대로), 또는 두 구간이 섞인 형태(4.5절).
- **확정(commit)**: `client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))`.
- **조합 표시(mark)**: `client.setMarkedText(attr, selectionRange: NSRange(location: attr.length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))`.

### 2.2 단어의 단계

| 단계 | 들어가는 조건 | 조합 문자열로 표시되는 것 | 확정되는 것 | 바꾸기 |
|---|---|---|---|---|
| **U** 미정 | 단어가 시작됨. 두 가설이 모두 살아 있고, 지는 쪽의 사후 확률(posterior)이 ≥ 1%. | 단어 전체. 현재 가장 나은 해석으로 보여 줌. | 아직 없음. | 조합 문자열을 맞바꿈. 항상 동작함. |
| **E** 영어 결정 | 한국어 분석이 구조상 죽음(2.3절), 또는 키 ≥ 2개 뒤 P(KO) < 1%, 또는 QWERTOP 외 키의 대문자이면서 P(KO) < 5%. | 완전한 영어 단어 뒤의 ≤2키 **접미 보류 키(lookahead)**(4.5절)까지만. 그 밖에는 없음. | 라틴 접두부를 바로 확정함. 이후 글자는 그대로 통과함(`handle`이 false를 반환). | 클라이언트가 지원하면 replacementRange로 확정된 범위와 조합 중인 부분을 바꿈(5.3절). |
| **K** 한국어 결정 | 키 ≥ 2개 뒤 P(EN) < 1%, 또는 이 키 문자열에 학습된 KO가 있음. | 현재 음절만(Apple 두벌식과 동등). | 완성된 음절을 바로 확정함. Apple 두벌식과 똑같음. | E와 같음. |
| **L** 리터럴 | URL/이메일/경로/코드 트리거(4.4절). | 없음. | 단어를 라틴 문자로 확정함(필요하면 조합 중인 한글을 바꿈). 그 뒤 공백이나 Return까지 그대로 통과함. | 꺼짐(HUD 숨김). |

규칙:
- 한 단어 안에서 단계는 앞으로만 감(U→E, U→K, U→L, E→L). 예외는 E→K 접미 분리(4.5절)이며, 이때는 새 하위 단어가 시작됨.
- 임계값(1%, 5%, 키 2개)은 `PhasePolicy` 구조체 하나에 모아 두고 엔진 트랙이 조정함.
- **Direct** 프로필(기본적으로 터미널)에서는 단어 자체가 없음. 모든 키가 통과함.

### 2.3 한국어 분석의 구조적 유효성
오토마타 출력이 `JamoRun? Syllable* JamoRun?`에 맞으면 한국어 가설은 **올바른 형태(well-formed)**예요:
- `JamoRun` = 자음만으로 된 자모 하나 이상, 또는 ㅠ/ㅜ만으로 된 자모. 예: ㅋㅋ, ㅠㅠ, ㅇㅋ, "ㅋㅋㅋ좋아" 앞의 ㅋㅋㅋ.
- 끝에 홀로 남은 자음은 "입력 중"이므로 항상 허용됨.

다음 경우에는 가설이 **죽은(dead)** 상태예요(뒤에 무엇을 붙여도 올바른 형태가 될 수 없음):
- ㅠ/ㅜ 연속 안이 아닌 곳에 홀로 선 모음이 나타남(예: 단어 시작의 `h`→ㅗ, 겹모음이 안 되는 모음 끝 음절 뒤의 `o`→ㅐ), 또는
- 두 음절 사이에 홀로 남은 자음이 끼어 있음.

U 단계에서 죽으면 바로 E로 넘어가요. K 단계에서는 나중에 오타가 나도 영어로 넘어가지 **않아요**. 이미 한국어로 결정했으니 Apple처럼 자모를 그대로 보여 줘요.

### 2.4 표시 안정성 (히스테리시스)
- U 단계에서 단어 중간에 표시 언어가 바뀌는 건 두 경우뿐임: (a) 표시 중인 가설이 죽음, (b) 다른 가설이 **Δ ≥ 1.0 logit**(약 73/27) 차이로 앞섬.
- 단어의 첫 키는 맥락 사전 확률(6절)이 정한 언어로 보여 줌.
- 명시적으로 바꾼 뒤에는 단어가 **고정됨**: 확정할 때까지 자동 재해석이 없음.
- Backspace는 표시 언어를 절대 바꾸지 않음. 키를 지우면 표시 중인 언어 안에서만 오토마타를 다시 돌림.

---

## 3. 키 처리 표

범례:
- **조합 없음**: 진행 중인 단어가 없음.
- **U**: 단어가 조합 문자열로 표시됨.
- **E/K**: 일부가 확정됨.
- **통과(Pass)**는 `handle`이 `false`를 반환한다는 뜻임. 그래서 Duo가 확정한 뒤 앱이 키를 받음. Apple 두벌식도 같은 순서라서, 앱에 이미 있는 한국어 입력기 대응 코드가 그대로 적용됨.
- **소비(Consume)**는 `handle`이 `true`를 반환한다는 뜻임.
- "보이는 대로 확정"은 조합 문자열을 화면에 보이는 그대로 확정한다는 뜻임(D1).

| 키 종류 | 조합 없음 | U 단계 (단어가 조합 중) | E / K 단계 | 소비 여부 |
|---|---|---|---|---|
| 글자 a–z | 단어를 시작함(6절 사전 확률). L 단계나 Direct 프로필에서는 그대로 통과. | 키를 덧붙이고 히스테리시스를 적용해 다시 해석함. HUD를 갱신함. | E: 그대로 통과(접미 보류 키인 경우 제외, 4.5절). K: 두벌식 오토마타를 돌려 완성된 음절은 확정하고 현재 음절은 조합 문자열로 표시함. | 소비 (E에서 그대로 보낼 때: 통과) |
| Shift+글자 | 글자와 같음. QWERTOP 외 키(A S D F G H J K L Z X C V B N M U I Y)의 대문자는 **영어 쪽 +2.0 logit** 근거를 더함. Shift+Q/W/E/R/T/O/P는 더하지 않음(ㅃㅉㄸㄲㅆㅒㅖ). | 같음. 단어 안에서 소문자→대문자로 바뀌면(camelCase) 영어 쪽 +3.0을 더함. | 글자와 같음. | 소비 |
| 숫자 0–9 (윗줄) | 통과. 다음 단어를 위해 `afterDigit` 맥락을 설정함(6.4절). | 단어를 정리한 뒤 통과(모음 없는 단일 자모 단어 → 라틴 문자, 예: v1, x2. 그 밖에는 보이는 대로 확정). | 조합 중인 음절이나 보류 키를 확정한 뒤 통과. | 통과 |
| `'` 아포스트로피 | 통과(여는 따옴표). | 표시 언어가 EN이거나 EN이 살아 있는 U면: **임시 연결 문자**로 버퍼에 둠(4.2절). KO가 표시 중이면: 보이는 대로 확정한 뒤 통과. | E: 임시 연결 문자. K: 확정한 뒤 통과. | 연결 문자: 소비. 그 밖에는 통과. |
| `-` 하이픈 | 통과. | 아포스트로피와 같음(e-mail, well-known, co-founder). | 같음. | 위와 같음 |
| `.` 마침표 | 통과. | 한국어로 결정되지 않았으면 임시 연결 문자. 다음 키가 정함: 글자가 오면 단어가 **점 포함** 단어가 됨 → L 단계(node.js, e.g., github.com). Space, Return, 문장 부호, 숫자가 오면 문장 부호임: 보이는 대로 확정 + ".". | K: 확정한 뒤 통과(다.그래서도 그대로 동작함). | 위와 같음 |
| `@` | 단어 시작의 `@` → L 단계(멘션, @user). | 글자에 붙은 `@` → 단어 전체가 **리터럴 라틴 문자**가 됨(조합 중인 한글을 라틴 키로 바꿈) → L. | E/K: 지원하면 확정된 한글을 replacementRange로 바꾸고, 아니면 그대로 둠. 그다음 L. | L로 바꾼 뒤 통과 |
| `/` `~` `:` `_` `\` `=` `?` `&` `#` `%` (코드/URL 문자) | 단어 시작의 `/` `~` `:` `\` → L(슬래시 명령, 경로, :emoji:). 단어 시작의 `#` → 리터럴 **아님**(한국어 해시태그 #맛집). | 글자 뒤의 `_`나 `://` → L. EN으로 표시된 단어 뒤의 `/`나 `:` → 임시 연결 문자(다음에 글자나 숫자가 오면 → L). KO로 표시된 단어 뒤: 확정한 뒤 통과(그/그녀). | 같은 규칙. | 통과 (연결 문자: 소비) |
| 그 밖의 문장 부호 `, ; ! ? ( ) [ ] { } " < > \| + * ^ $` | 통과. | 보이는 대로 확정한 뒤 통과. | 확정한 뒤 통과. | 통과 |
| ` (그레이브) | 통과. `를 입력함(설정 "` 키로 ₩ 입력"의 기본값은 끔. 켜면 `는 ₩, ⌥`는 `를 입력함). | 확정한 뒤 통과. | 확정한 뒤 통과. | 통과 |
| Space | 통과. | 보이는 대로 확정한 뒤 스페이스를 통과시킴. | 조합 중인 부분을 확정한 뒤 통과. | 통과 |
| Shift+Space | 통과(스페이스). | 기본값: Space와 같음. 바꾸기 키로 골랐다면: 바꾸고(5절) 소비함. | 같음. | 통과 / 바꾸기면 소비 |
| Return, 키패드 Enter, ⇧Return | 통과. | 보이는 대로 확정한 뒤 통과. 채팅류 앱에서는 모멘텀을 앱 사전 확률로 되돌림(메시지를 보냈으므로). | 확정한 뒤 통과. Terminal 프로필에서는 Bilingual을 끝내고 Direct로 돌아감. | 통과 |
| ⌥Return | 통과. | 확정한 뒤 통과(v2의 한자 변환용으로 남겨 둠). | 확정한 뒤 통과. | 통과 |
| Tab, ⇧Tab | 통과. | 보이는 대로 확정한 뒤 통과(자동 완성과 양식 이동은 그대로 동작함). | 확정한 뒤 통과. | 통과 |
| Escape | 통과. | 보이는 대로 확정한 뒤 통과(vim은 입력 모드를 나가고 대화상자는 닫힘). Code/Terminal 프로필에서는 다음 단어의 사전 확률이 영어 쪽으로 기움. | 확정한 뒤 통과. Terminal 프로필: Direct로 돌아감. | 통과 |
| Backspace (⌫) | 통과. 캐럿이 Duo의 마지막 확정(+ 경계) 바로 뒤에 있으면 HUD가 "마지막 단어 바꾸기" 칩을 보여 줌(7절). | 마지막 **키 입력**을 지우고 표시 언어로 오토마타를 다시 돌림: 한국어는 자모 단위(닭→달→다→ㄷ), 영어는 글자 단위. 버퍼가 비면: `setMarkedText("")` 후 **소비**함(글자를 하나 더 지우지 않음). | 조합 중인 부분부터 지움. 조합 중인 부분이 비면: 통과시키고, 바꾸기가 정확하도록 단어 기록에서 확정된 키를 하나 꺼냄(한국어: 음절 하나 분량의 키). | 조합 중이면 소비, 아니면 통과 |
| ⌥⌫, ⌘⌫ | 통과. | 확정한 뒤 통과(의도대로 방금 확정한 단어나 줄을 지움). | 확정한 뒤 통과. | 통과 |
| Forward Delete (fn⌫, 키패드 Del) | 통과. | 확정한 뒤 통과. | 확정한 뒤 통과. | 통과 |
| ← → ↑ ↓ | 통과. | 보이는 대로 확정한 뒤 통과. **글 끝에서 → = "띄우지 않고 확정"**(앱+store를 붙이는 공식 방법). | 확정한 뒤 통과. | 통과 |
| Home, End, PgUp, PgDn, F1–F19 | 통과. | 확정한 뒤 통과. | 확정한 뒤 통과. | 통과 |
| ⌘+아무 키 | 통과. | 보이는 대로 확정한 뒤 통과(⌘A, ⌘C, ⌘V, ⌘Z, ⌘S는 확정된 글자에 적용됨). | 확정한 뒤 통과. | 통과 |
| ⌃+아무 키 (emacs 바인딩, 터미널의 ⌃C) | 통과. | 확정한 뒤 통과. | 확정한 뒤 통과. | 통과 |
| ⌥+글자 / ⌥+숫자 (å ∫ ç ∂ ™ £ ¢) | 통과(시스템의 U.S. 자판이 문자를 만듦). **데드 키**(⌥e ⌥` ⌥u ⌥i ⌥n)면 **다음 키도 그대로 통과**시켜 é, ü, ñ가 조합되게 함. | 확정한 뒤 통과. | 확정한 뒤 통과. | 통과 |
| ⌃⌘Space (이모지), Globe/fn 톡 | 통과. | `.function`이 담긴 `flagsChanged`나 ⌃⌘Space keyDown이 오면: 이모지가 단어 뒤에 들어가도록 먼저 확정한 뒤 통과. | 같음. | 통과 |
| Caps Lock 토글 (`flagsChanged`, keyCode 57) | 켜짐: 영어 고정. 모든 글자가 그대로 통과함(자판이 대문자를 만듦). | 먼저 보이는 대로 확정한 뒤 고정 상태로 들어감. | 같음. | 절대 소비하지 않음 |
| 오른쪽 ⌘ 톡 (기본 바꾸기 키) | 바꾸기(5.2절 경우 c 또는 b). | 단어를 바꿈(5.2절 경우 a). | 단어 전체를 바꿈(5.3절). | `flagsChanged`는 **절대 소비하지 않음**. 톡을 감지해서 동작만 함. |
| 그 밖의 수정자 키 누름 (⇧ ⌃ ⌥ ⌘ 단독) | 무시. | 무시(⇧를 누르고 있어도 확정하지 않음). | 무시. | 절대 소비하지 않음 |
| 숫자 키패드의 숫자와 연산자 | 통과. | 확정한 뒤 통과. | 확정한 뒤 통과. | 통과 |
| 키 자동 반복 (`event.isARepeat`) | 글자: 평소처럼 덧붙임(z를 누르고 있으면 ㅋㅋㅋㅋ). Backspace: 키 입력 단위로 지우다가, 버퍼가 비면 통과시켜 지움. 화살표 등: 위와 같음. | 반복 입력이 들어오는 동안 HUD를 숨기고, 마지막 반복 300 ms 뒤에 다시 판단함. | 같음. | 원래 키와 같음 |
| 아무 곳 마우스 클릭, 포커스 변경, 앱 전환, ⌘Tab | 해당 없음 | `commitComposition(_:)`이 보이는 대로 확정함. 클라이언트가 이미 조합 표시를 풀었다면(문자열은 남김) 상태만 맞추고 두 번 삽입하지 않음. | 같음. | 해당 없음 |
| 보안 입력 켜짐 (`IsSecureEventInputEnabled()`) | **모든 것**에 `false`를 반환하고 HUD도 없음. 보안 입력이 켜질 때 진행 중인 단어가 있었다면: 먼저 확정함. | 같음. | 같음. | 통과 |

구현 참고:
- `recognizedEvents(_:)`는 `Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)`를 반환함.
- 키 코드(Carbon `kVK_*`): Return 36, Tab 48, Space 49, Delete 51, Escape 53, RightCommand 54, Command 55, Shift 56, CapsLock 57, Option 58, Control 59, RightShift 60, RightOption 61, RightControl 62, Function 63, KeypadEnter 76, ForwardDelete 117, Home 115, End 119, PageUp 116, PageDown 121, ←123 →124 ↓125 ↑126, Grave 50.
- `modifierFlags.rawValue`의 기기별 수정자 비트: LCmd 0x08, RCmd 0x10, LShift 0x02, RShift 0x04, LAlt 0x20, RAlt 0x40, LCtl 0x01, RCtl 0x2000.
- 데드 키 감지: U.S. `kTISPropertyUnicodeKeyLayoutData`로 `UCKeyTranslate`를 호출함. ⌥+키 뒤 `deadKeyState`가 0이 아니면 `passNextKeyRaw = true`로 설정함.
- 상태 재동기화: `handle`마다 확인함. Duo는 조합 문자열이 있다고 보는데 `client.markedRange().location == NSNotFound`이면(앱이 필드를 비움, 예: 전송 후의 Slack) 단어를 조용히 버림. 다시 삽입하지 않음.

---

## 4. 단어 경계와 버퍼 규칙

### 4.1 버퍼에 두는 것
- **버퍼에 둠**: 글자 키(Shift 상태 포함)와 임시 연결 문자 `' - . : /`(3절의 조건일 때만).
- **절대 버퍼에 두지 않음**: 숫자, 공백, Return, Tab, 그 밖의 문장 부호, ⌥ 문자, 키패드 키.
- **상한**: 단어당 키 32개. 33번째 키에서 단계를 강제로 결정하고(가장 나은 가설) 확정한 뒤 이어 감. 그래서 키를 누르고 있거나 길게 이어 쳐도 거대한 밑줄이 생기지 않음.

### 4.2 임시 연결 문자 (영어 뒤의 `'`, `-`, `.`, `:`, `/`)
- 연결 문자(joiner)는 그 문자 그대로 조합 문자열에 덧붙음. 다음 키가 처리 방식을 정함:
  - **글자** → 연결 문자가 단어에 합쳐지고, 단어는 영어/리터럴이 됨:
    - `'`와 `-` → 영어가 이어짐(don't, I'm, e-mail).
    - `.` `:` `/` → L 단계(node.js, localhost:3000, github.com/foo).
  - **그 밖의 키** → 연결 문자는 문장 부호였던 것임: 단어를 보이는 대로 확정하고, 이어서 연결 문자를 확정한 뒤 새 키를 처리함.
- **근거:** 연결 문자는 늘 화면에 보이고, 처리 결과가 이미 화면에 있는 글자를 바꾸지 않음. 예외는 아직 U 단계였던 한글 표시가 라틴 문자로 바뀌는 경우임. URL에서는 이게 기대하는 동작임.

### 4.3 한국어로 결정된 단어는 연결 문자를 받지 않음
- K 단계에서 `.` `'` `-` `/` `:`는 확정하고 통과함(했다.그래서, '안녕', 그/그녀, 참고: 내용).
- **근거:** 한국어 글에서는 이 문자들을 문장 부호로 씀. 한국어 단어 안에 들어가는 연결 문자는 사실상 없음.

### 4.4 리터럴(L 단계) 트리거
모두 강한 신호예요. 하나만 있어도 충분해요:
1. 단어 시작의 `/`, `~`, `\`, `:`, `@`. `./`와 `../`도 해당함.
2. 글자 바로 뒤의 `@`(이메일 로컬 파트). 한글로 보이던 중이어도 단어가 라틴 문자가 됨(dkssud@ → dkssud@).
3. 어디든 있는 `://`. 단어 시작의 `www.`.
4. 점 포함 단어: 글자 `.` 글자 형태이고, `.` 앞의 단어가 EN이었거나 EN이 살아 있는 U였음.
5. 단어 안의 `_`(snake_case, SCREAMING_CASE).
6. 대소문자 전환이 ≥ 2번 있거나, 글자와 코드 문자가 섞인 단어(`=`, `<`, `>`, `{`, `}`가 붙음).

L 단계에서 Duo는 단어를 확정하고 Space, Tab, Return까지 모든 키를 그대로 통과시켜요. 그래서 주소 막대와 Slack 자동 완성이 실제 문자를 받아요.
- 붙여 넣기는 입력기를 거치지 않으므로 붙여 넣은 URL은 영향받지 않음.
- 단어 시작의 `#`는 리터럴이 **아님**: 한국어 해시태그가 흔하고, 영어 해시태그는 알아서 정해짐(#general → 2번째 키에서 E 단계).

### 4.5 언어가 섞인 단어 (구간 나누기)
- **EN→KO (자동).** E 단계에서 확정된 라틴 접두부가 **완전한 영어 단위**가 되면, 자음 키(q w e r t a s d f g z x c v, ⇧QWERT)가 올 때 Duo가 보류 키를 염. 완전한 영어 단위는 다음과 같음:
  - 어휘 사전(lexicon)에 있는 단어,
  - 전부 대문자인 ≥ 2글자 약어,
  - 첫 글자가 대문자이거나 camelCase인 단어, 또는
  - 학습한 단어.
- 보류 키는 **조합 문자열로 표시**되며(≤ 2키), 다음처럼 보임:
  - 맥락 모멘텀이 영어면 라틴 문자,
  - 모멘텀이 한국어이거나 접두부가 약어(API, PR, URL)면 자모.
- 다음 키가 모음 키이고 "접두부 + 이 키들"이 그럴듯한 영어 연속이 아니면(어휘 사전의 접두부가 아니면), 보류 키는 새 **K 단계 하위 단어**가 됨(React + 커 → React컴포넌트, API + 르 → API를, push + 해 → push했어).
- 그럴듯한 영어 연속이면(pushed, Reacts, users) 보류 키는 라틴 문자로 확정됨.
- 영어 접두부 바로 뒤의 모음 키는 한국어를 시작할 수 없으므로 그대로 통과함(username, Reactive).
- **KO→EN (대문자일 때만 자동).** K 단계에서 ⇧+QWERTOP 외 글자가 오면 영어 하위 단어가 시작됨(갤럭시S24, 아이폰Pro는 죽음 판정으로 정해짐, 카톡ID).
- **그 밖의 KO→EN (v1 범위 밖).** "앱store"를 한 번에 치면 깨진 한국어 자모가 보임. 문서화된 우회 방법: 앱을 치고 →를 누른 뒤 store를 침. v2 후보 방안은 홀로 남은 자모 연속을 조합 문자열로 남겨 다시 나눌 수 있게 하는 것임.
- **v1에서는 단어당 구간 최대 2개.**
- **근거:** 실제로 섞인 단어는 거의 다 영어 어간 + 한국어 조사 또는 하다 동사임. 제품 이름은 대문자 규칙이 맡음.

### 4.6 식별자와 코드
- **camelCase**(useState, getElementById): 전환 규칙으로 영어가 됨. 한국어 분석은 보통 1–3키 안에 죽음. 그래서 E 단계가 바로 확정하고 IntelliSense가 실제 문자를 받음.
- **snake_case**: L(규칙 5).
- **kebab-case**(my-component): 하이픈 연결 문자로 영어가 됨.
- **점 포함**(`os.path`, `self.view`): L.
- **Code 프로필 앱**에서도 한국어를 온전히 쓸 수 있음(주석과 문자열): 사전 확률은 모호한 단어만 기울게 함.

---

## 5. 바꾸기 방식

### 5.1 바꾸기 키 고르기

| 후보 | 판정 | 이유 |
|---|---|---|
| **오른쪽 ⌘ 톡** | **기본값** | 손을 옮기지 않고 오른손 엄지로 닿음. macOS에서 단독으로 누르면 아무 일도 없음. Mac에서 한/영용으로 흔히 쓰는 Karabiner 매핑이라 손에 익은 사람이 많음. TCC 없이 `flagsChanged`로 감지함. |
| 오른쪽 ⌥ 톡 | 대안 | 특성이 같음. 오른쪽 ⌘가 불편한 키보드(일부 외장 키보드)에 맞음. |
| ⇧ 두 번 톡 (300 ms 안에) | 대안 | Caramba 선례. ⇧ 한 번 톡은 실수로 누르기 쉽고, 두 번은 괜찮음. |
| ⇧Space | 대안, 기본으로 꺼짐 | 빨리 치는 사람은 대문자나 ㅆ(갔 + Space) 뒤에 ⇧를 누른 채 Space를 치기도 함. 그래서 실수로 바뀌는 일이 실제로 생김. Windows에서 넘어온 사용자는 켜서 쓸 수 있음. |
| Caps Lock | 실험적 대안 | LED가 켜졌다 꺼짐. Apple 키보드는 Caps Lock 지연이 있어 빠른 톡을 삼킴. 시스템의 "Caps Lock으로 전환…" 옵션이 키를 가로챌 수 있음. 이 키를 고르면 D9(영어 고정)는 꺼짐. |
| Tab | **제외** | 셸/IDE 자동 완성, 양식 이동, 들여쓰기에 쓰임. |
| ⌃Space / ⌃⌥Space | **제외** | 입력기보다 먼저 가로채지는 시스템 입력 소스 단축키임. |
| Globe/fn | **제외** | 시스템이 씀(이모지 / 입력 소스 변경 / 받아쓰기). |

**톡 감지 (정확한 규칙):**
1. `keyCode == 54`이고 RCmd 기기 비트가 켜지며 다른 수정자 키가 눌려 있지 않은 `flagsChanged`에서 대기 상태로 들어감.
2. 다음 중 하나면 대기를 풂: `keyDown`이 옴, 다른 수정자 키가 바뀜, 300 ms가 넘게 지남(고급 설정에서 200–500으로 조정 가능), 뗄 때 `NSEvent.pressedMouseButtons != 0`(⌘-클릭).
3. 대기 상태에서 떼는 `flagsChanged`(RCmd 비트가 꺼짐)가 오면 실행함.
4. `flagsChanged` 이벤트는 절대 소비하지 않음. 그래야 앱이 수정자 키 상태를 바르게 유지함.

### 5.2 바꾸기 의미 (키 하나, 경우 셋, 이 순서로 확인)

**(a) 진행 중인 단어가 있음(U, E, K 단계).**
- 화면에 보이는 단어를 가장 나은 다른 해석으로 바꾸고, 그 언어로 단어를 **고정함**. 확정하지 않음: 사용자는 계속 칠 수 있음(go → 해, 이어서 `s` → 핸).
- U 단계에서는 조합 문자열만 바뀌므로 항상 동작함. E/K 단계는 5.3절 참고.
- 한 번 더 톡 하면 원래대로 바뀌고 고정은 유지됨.
- 다른 해석은 반대 언어의 가장 나은 해석임. 섞인 단어라면 전부 라틴 문자임.

**(b) 단어가 없고, 캐럿이 Duo의 마지막 확정 바로 뒤에 있음.**
- 조건: 같은 클라이언트임. `client.selectedRange()`가 확정 뒤 기록한 위치와 같음. 그 뒤로 수정자 키, 경계 문자를 지우는 Backspace, 바꾸기 말고는 다른 키가 없었음.
- 확정된 그 단어를 바꾸고 경계 문자는 그대로 둠: "go␣" → "해␣", "안녕␣" → "dkssud␣". 경계 문자를 다시 입력하지 않음.
- 사용자가 뒤의 스페이스를 Backspace로 지운 경우(캐럿이 단어 바로 뒤)에도 적용됨.
- 유효 기간: 다음 글자 키, 클릭, 포커스 변경, 또는 30 s까지.

**(c) 바꿀 것이 없음.**
- 현재 맥락 사전 확률과 반대인 **다음 단어 한 번용 언어**를 준비함. HUD가 900 ms 동안 한 또는 A 배지를 보여 주고, 다음 단어는 그 언어로 고정된 채 시작함.
- 한 번 더 톡 하면 취소됨.
- Terminal 프로필에서는 (c)가 대신 그 줄의 Direct ↔ Bilingual을 전환함(6.6절).

**선택 영역 변환은 일부러 한 번 톡에 넣지 않았어요.** 사용자가 복사하려고 ⌘를 누르다가 마음을 바꿔 떼면, 한 번 톡이 선택한 글자를 바꿔 버려요.
- 대신: 입력 메뉴 항목 **"선택한 텍스트 한↔A 변환"**(Convert Selected Text)과, 선택 영역이 있을 때 바꾸기 키 **두 번 톡**(선택 사항)을 씀.
- 선택 영역 변환은 두벌식 대응표를 양방향으로 씀(dkssud ↔ 안녕). 최대 2,000자까지.

### 5.3 확정된 글자 바꾸기 (E/K 단계의 경우 a, 그리고 경우 b)
1. 예상 범위를 계산함: `R = NSRange(location: caret - boundaryLen - committedLen, length: committedLen)`.
2. 검증함: `client.attributedSubstring(from: R)?.string == committedText`. `selectedRange()`가 `NSNotFound`를 반환하면 그 클라이언트는 임의 접근을 못 함.
3. 성공하면: `client.insertText(newText, replacementRange: R)` 후 캐럿을 경계 뒤로 되돌림. Cocoa 클라이언트는 바꿔도 뒤의 글자가 남으므로 자연스럽게 이렇게 됨.
4. 실패하면(Terminal, 일부 Java/Qt 앱, 게임): 글자는 건드리지 않고 HUD 메시지 **"여기서는 바꿀 수 없어요 · Can't change text here"**를 1.2 s 동안 보여 줌. 세션 동안 번들 ID별로 `replacementUnsupported`를 기억해서, 그 앱에서는 HUD가 경우 (b)를 더 제안하지 않음.
- **근거:** 짐작하지 않고, 가짜 Backspace도 보내지 않음. 그러려면 손쉬운 사용 권한이 필요하고 글자가 망가질 수 있음.

### 5.4 "자동 변환 되돌리기"
- WYSIWYG라서 숨은 자동 변환이 없음. 그래서 되돌리기는 그냥 바꾸기임:
  - 조합 중 → 경우 (a),
  - 확정 직후 → 경우 (b).
- **애매한 확정**(다른 해석의 P ≥ 35%) 뒤에는 HUD가 **요청 없이도** "마지막 단어 바꾸기" 칩을 1.6 s 동안 보여 줌. iOS/macOS 자동 수정의 되돌리기 말풍선에 해당함.
- 확정 직후 Backspace를 눌러도 칩이 다시 나타남.
- Backspace 자체는 절대 재정의하지 않음(D5): 확정 뒤에는 스페이스를 지우고, 이어서 음절이나 글자 단위로 지움. Apple 두벌식, ABC와 똑같음.
- 확정은 평범한 삽입이라 ⌘Z가 여느 앱처럼 동작함.

### 5.5 학습
- **키**: 확정 뒤 단어 전체에 대해 실제로 친 라틴 문자열. 대소문자 포함(예: `go`, `Go`, `zzz`, `dkssud`).
- **섞인 단어**: 사용자가 바꾼 구간을 학습 키로 씀.
- **저장소**: `[key: LearnedEntry(ko: Double, en: Double, lastUsed: Date)]`.
- **이벤트**:
  - 명시적으로 바꿔서 언어 X로 확정함: `X += 1.0`. 바꾼 뒤 단어 전체를 지우면 아무것도 학습하지 않음.
  - 암묵적 수락(HUD가 ≥ 20%인 다른 해석을 보여 주는데 바꾸지 않고 확정함): `displayed += 0.25`.
  - 같은 단어 안에서 다시 원래대로 바꾸면 표가 취소됨.
- **감쇠**: 반감기 60일. 읽을 때 지연 적용함: `count * 0.5^(age/60d)`. 두 언어 모두 0.1 미만인 항목은 제거함. LRU 상한은 50,000개.
- **엔진 logit에 더하는 편향**(양수 = 한국어): `β·(ln(1+ko) − ln(1+en))`, β = 3.0.
  - 한 번 바꾸면 ≈ 2.1 logit. 아주 확신하는 경우가 아니면 다 뒤집음.
  - 두 번 바꾸면 ≈ 3.3 logit. 사실상 어떤 단어든 이김.
  - 엔진은 학습 차이가 > 2.0이면 입력 중 표시에서도 고정으로 다룸.
- **학습하지 않는 경우**:
  - L 단계 단어,
  - 보안 입력 중에 친 단어,
  - Direct 모드,
  - 길이 1인 단어,
  - "학습 일시 정지"(Pause Learning)가 켜져 있을 때,
  - 그 앱의 앱별 학습이 꺼져 있을 때.
- **범위**: 학습은 **전역**임. 앱별 기억은 사전 확률일 뿐임(6.5절). 그래서 사용자가 고친 결과가 어디서나 똑같이 적용됨.
- **확인을 묻지 않는 근거**: Punto는 두 번 취소하면 물어봄. 하지만 조용히 학습하는 게 Apple 방식임. 설정 ▸ 학습한 단어 목록에서 확인하고 되돌릴 수 있음.

---

## 6. 맥락 규칙

모든 맥락은 다음 단어의 **사전 확률 logit(prior logit)**으로 엔진에 들어가요(양수 = 한국어). 전체 사전 확률은 ±2.5로 제한해요. 그래서 구조와 어휘 근거가 여전히 더 크게 작용해요.

### 6.1 언어 모멘텀
- `prior = appPrior + momentum`. 여기서 `momentum = clamp(λ · lastWordSign · 1.5, ±1.5)`.
- `lastWordSign`은 한국어면 +1, 영어면 −1.

| 상황 | λ |
|---|---|
| 같은 문장 | 0.7 |
| `. ! ? …` 다음에 스페이스가 온 뒤 | 0.4 |
| 줄바꿈 뒤 | 0.3 |
| 채팅류 앱에서 Return 뒤(메시지를 보냄) | 0 (앱 사전 확률로 초기화) |
| 포커스 변경이나 앱 전환 뒤 | 0 |
| 한 번용 바꾸기(5.2절c) 뒤 | 다음 단어가 고정됨. 그 뒤 모멘텀은 λ = 0.9로 그 결과를 따름. |

### 6.2 문장 시작
- 한국어 쪽 특별 사전 확률은 없음. 영어 근거는 대문자에서 자연스럽게 나옴(QWERTOP 외 대문자는 +2.0).
- 문장 시작에서 QWERTOP 키의 대문자(So, To, We, Tom)는 0 대신 영어 쪽 +1.0을 받음. 문장 시작의 T, W, Q는 ㅆㅉㅃ보다 영어 대문자일 가능성이 훨씬 높기 때문임.

### 6.3 괄호와 따옴표
- 한국어 단어에 바로 붙은 `(`(컴포넌트(component))는 −0.8을 줌(영어 병기 패턴).
- 따옴표 문자는 모멘텀을 앱 사전 확률로 초기화함(인용한 글은 반대 언어인 경우가 많음).
- 닫는 괄호나 따옴표 뒤에는 그 앞 글의 모멘텀을 되살림.

### 6.4 숫자 뒤 (`afterDigit` 맥락)
- 다음 단어는 **수 단위 표(counter/unit table)**로 점수를 매김:
  - **한국어 단위명사**(정확히 맞으면 KO +2.0): 시 분 초 개 명 번 등 위 층 살 원 만 억 천 백 일 월 년 주 회 차 배 장 권 잔 병 대 마리 시간 개월 주년 분기 학년 박 퍼센트 도.
  - **영어 단위**(정확히 맞으면 EN +2.0): am pm st nd rd th px pt em rem ms s h m k K M G GB MB KB TB x D fps Hz kHz GHz mAh mm cm km kg g ml L.
- 숫자 뒤에서 모음 없는 단일 자모 결과는 라틴 문자로 정해짐(2x, 3D, 4K).

### 6.5 앱별 프로필과 학습한 앱별 편향
- 프로필은 `client.bundleIdentifier()`로 고름.
- `appPrior = profilePrior + learnedAppBias`.
- `learnedAppBias = clamp(EMA(lastWordSign, α=0.05) · 1.0, ±1.0)`는 번들 ID별로 저장하고 확정할 때마다 갱신함(L 단계 제외).

| 프로필 | 기본 사전 확률 | 기본 앱 (번들 ID, ID 확인 필요) |
|---|---|---|
| **Direct** (터미널) | 해당 없음: 키 그대로, 필요할 때 Bilingual | com.apple.Terminal, com.googlecode.iterm2, dev.warp.Warp-Stable, com.mitchellh.ghostty, net.kovidgoyal.kitty, org.alacritty, com.github.wez.wezterm, co.zeit.hyper |
| **English-first** (코드) | −1.0 | com.apple.dt.Xcode, com.microsoft.VSCode, com.todesktop.230313mzl4w4u92 (Cursor), dev.zed.Zed, com.jetbrains.* (접두사), com.sublimetext.4, com.panic.Nova, com.barebones.bbedit |
| **Korean-first** | +1.0 | com.kakao.KakaoTalkMac, com.hancom.office.hwp* (접두사), jp.naver.line.mac |
| **Automatic** | 0 + 온보딩 기본값 (8.1절 4단계: 한국어 위주 +0.7 / 반반 0 / English −0.7) | 그 밖의 모든 앱 (Slack, Messages, Notion, Safari, Chrome, Mail, Pages…) |

- **근거:** 메신저와 문서는 사용자마다 다름. 그래서 학습한 EMA가 맡음. 거의 모두가 똑같이 쓰는 분류에만 고정 사전 확률을 줌.
- 사용자는 설정 ▸ 앱별 설정이나 입력 메뉴에서 어떤 앱이든 직접 지정할 수 있음.

### 6.6 터미널(Direct) 프로필 세부 사항
- **기본**: 모든 키가 그대로 통과함. Duo는 보이지 않음.
- **바꾸기 톡**을 하면 **이 줄만 Bilingual**로 들어감(사전 확률 0인 전체 Duo 모델). HUD가 캐럿 근처에 작은 한 배지를 계속 보여 줌.
- **Return이나 Esc**를 누르면 Bilingual을 끝내고 Direct로 돌아감(gureum Vi 모드와 비슷함). 단어 없이 바꾸기 톡을 한 번 더 해도 Bilingual이 끝남.
- 설정에서 터미널을 항상 Bilingual로 둘 수 있음.
- **근거:** 대화형 TUI(vim 노멀 모드, less, fzf 실시간 필터, htop, Claude Code CLI)는 키를 바로 받아야 함. 한국어 커밋 메시지는 의도해서 쓰는 것임.
- 호환성 플래그 `returnAsCR`(기본 꺼짐, Warp의 글자 누락 버그에 대해 확인 필요): 터미널에서 조합 중인 음절이 있을 때 Return이 오면 `insertText(syllable + "\r")`로 확정하고 소비함.

### 6.7 보안 텍스트와 암호
- `handle`과 `activateServer` 때마다 `IsSecureEventInputEnabled()`(Carbon HIToolbox)를 확인함. true면: 진행 중인 단어를 확정한 뒤 모든 것을 그대로 통과시킴. 조합 문자열, HUD, 학습 모두 없음.
- Cocoa(NSSecureTextField)와 브라우저의 암호 필드는 포커스가 있는 동안 보안 이벤트 입력을 켬.
- 부작용: 보안 입력을 전역으로 켜 두는 앱(Terminal이나 iTerm2의 "Secure Keyboard Entry", 일부 암호 관리자)에서는 한국어가 꺼짐. 설정 ▸ 문제 해결에 실시간 상태 줄이 보임: **"보안 키보드 입력이 켜져 있어 한글 조합이 꺼졌어요 (Terminal ▸ 보안 키보드 입력)"**.
- 보안이 아닌 프롬프트의 암호(터미널의 sudo)는 Direct 프로필이 맡음.

### 6.8 조합 문자열을 지원하지 않는 필드
- `setMarkedText` 뒤에도 `client.markedRange().location == NSNotFound`이면 그 클라이언트를 `noMarkedText`로 표시함.
- 그 뒤로 Duo는 그 클라이언트에 **즉시 확정** 모드를 씀: 완성된 한글 음절은 바로 확정하고, 현재 음절이나 단어는 HUD에서만 미리 보여 줌. 바꾸기는 5.3절을 따름.

---

## 7. HUD (힌트 캡슐)

### 7.1 정체
- 테두리 없는 **앱을 활성화하지 않는(non-activating) `NSPanel`**:
  - `styleMask: [.nonactivatingPanel, .borderless]`, `isFloatingPanel = true`, `becomesKeyOnlyIfNeeded = true`, `hidesOnDeactivate = false`
  - `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`
  - `level = max(client.windowLevel() + 1, NSWindow.Level.popUpMenu.rawValue)`
- `NSHostingView`로 SwiftUI를 담음. 내용은 Liquid Glass를 씀: `.glassEffect(.regular.interactive(), in: .capsule)`, AppKit에서는 `NSGlassEffectView`.
- 투명도 줄이기가 켜져 있으면 시스템이 불투명한 재질로 바꿈. 대비 증가가 켜져 있으면 1 px 구분 테두리를 더함.

### 7.2 내용

| 상태 | 내용 (왼쪽 → 오른쪽) |
|---|---|
| U 단계의 다른 해석 | 다른 해석 글자(13 pt, 시스템 글꼴의 SF Pro / Apple SD Gothic Neo, `.primary`) · 키캡 기호 `⌘`(11 pt, `.secondary`, 16×16 둥근 키캡 안. 기호는 고른 바꾸기 키를 따름: ⌘ ⌥ ⇧⇧ ⇧␣ ⇪) |
| 마지막 단어 바꾸기 칩 (5.4절) | `↺` (11 pt) · 마지막 단어의 다른 해석 · 키캡 |
| 다음 단어 한 번용 언어 (5.2절c) | 배지 **한** 또는 **A**만 (15 pt semibold), 900 ms |
| 터미널 Bilingual | 계속 보이는 작은 배지 **한** (11 pt), 불투명도 60% |
| 바꾸기 실패 | "여기서는 바꿀 수 없어요" (12 pt, `.secondary`), 1.2 s |

- 캡슐 안의 다른 해석 글자를 클릭하면 바꾸기가 실행됨. iOS 추천 단어를 누르는 것과 같음.
- 캡슐은 높이 26 pt, 좌우 여백 10 pt, 최대 너비 320 pt임(글자가 넘치면 가운데를 줄여 표시함).

### 7.3 보이고 숨는 때
- 다음을 모두 만족하면 **보여 줌**:
  - 단어가 U 단계임,
  - P(다른 해석) ≥ 0.20,
  - 단어의 키가 ≥ 2개임. 그 키가 충돌 목록(a, i, e, x…)에 있으면 1개도 됨,
  - **300 ms** 동안 키 입력이 없음.
- **한 번 뜨면 계속 떠 있음**. 단어가 이어지는 동안 빠르게 쳐도 그 자리에서 내용만 갱신함. 깜빡임을 막으려고 키 사이에 숨기지 않음.
- **숨김**: 확정, E/K/L 전환, 보안 입력(즉시, 애니메이션 없음), 포커스 변경, Esc 때 120 ms 동안 흐려지며 사라짐.
- **나타남**: 150 ms ease-out 페이드 인과 크기 0.97 → 1.0(spring response 0.25, damping 0.9). 동작 줄이기가 켜져 있으면 페이드만 씀.
- **내용 갱신**: 100 ms 크로스페이드. 너비는 `.smooth(duration: 0.15)`로 애니메이션함.
- **애매한 확정 칩**: 바로 나타나고(지연 없음) 1.6 s 동안 있다가 200 ms에 걸쳐 사라짐. 다음 글자 키를 누르면 취소됨.
- **절대 보여 주지 않음**:
  - 보안 입력 중,
  - Direct 모드(명시적인 한 배지는 예외),
  - 자동 반복 중,
  - 캐럿 사각형이 잘못됐을 때(크기 0, 원점 (0,0), 또는 모든 화면 밖),
  - "힌트 표시"가 꺼져 있을 때. 단, 실패 메시지와 터미널 배지는 보여 줌. 사용자가 한 동작에 대한 피드백이기 때문임.
- 전체 화면 게임: 텍스트 입력 클라이언트를 쓰지 않아서 입력기가 끼어들지 않음. 특별 규칙 없음.

### 7.4 위치
1. `client.attributes(forCharacterIndex: markedStart, lineHeightRectangle: &rect)`는 왼쪽 아래가 원점인 화면 좌표를 반환함. 조합 범위의 인덱스 0을 씀. 칩이면 마지막으로 확정한 단어의 시작을 씀.
2. 캡슐의 앞쪽 가장자리를 `rect.minX − 10`(글자에 맞춤)에, 위쪽을 `rect.minY`보다 6 pt 아래에 둠.
3. `screen.visibleFrame.minY`를 넘어가게 되면 대신 `rect.maxY`보다 6 pt 위에 둠.
4. 가로로는 8 pt 안쪽 여백을 두고 `visibleFrame` 안으로 제한함. 사각형의 중점을 포함하는 `NSScreen`을 씀.
5. 보이는 동안에는 줄 사각형이 2 pt 넘게 바뀌지 않는 한 캡슐을 옮기지 않음. 떨림을 막기 위함임.

### 7.5 손쉬운 사용
- VoiceOver가 켜져 있으면(`NSWorkspace.shared.isVoiceOverEnabled`) 바꿀 때마다 `NSAccessibility.post(element: NSApp, notification: .announcementRequested, userInfo: [.announcement: "해, 한국어로 바꿈", .priority: NSAccessibilityPriorityLevel.high.rawValue])`를 보냄.
- HUD 자체는 `accessibilityHidden`이라 VoiceOver 포커스를 절대 뺏지 않음.

---

## 8. 호스트 앱: 온보딩, 설정, 입력 메뉴

### 8.1 온보딩 (첫 실행. `.windowStyle(.hiddenTitleBar)`와 Liquid Glass 배경을 쓴 640×520 창 하나)
문구는 한국어가 먼저이고, 시스템 언어가 한국어가 아니면 영어를 보여 줘요. 단계마다 오른쪽 아래에 주 버튼이 있고, 필요한 곳에는 "나중에"(Later) 링크가 있어요.

1. **환영.**
   - 메인 영역: Duo 엔진이 프로세스 안에서 이미 돌아가는 실제 텍스트 필드(앱에 DuoCore를 링크함). 애니메이션 데모가 `dkssudgktpdy` → "안녕하세요", `hello` → "hello"를 친 다음 필드를 사용자에게 넘김: "직접 쳐 보세요"(Try it).
   - 제목: **"한영 전환 없이, 그냥 쓰세요."** 부제: "Duo는 입력하는 단어를 보고 한국어인지 영어인지 알아서 판단해요."
   - **근거:** 사용자가 시스템 설정을 건드리기 전에 제품을 써 볼 수 있음. TCC 없이도 동작함.
2. **Duo를 입력 소스로 추가.**
   - 버튼 "Duo 켜기". `TISRegisterInputSource(bundleURL)`를 호출한 뒤 `kTISPropertyInputSourceID`로 거른 `TISCreateInputSourceList`, `TISEnableInputSource`, `TISSelectInputSource`를 차례로 호출함.
   - 실패하면 `x-apple.systempreferences:com.apple.Keyboard-Settings.extension`(확인 필요)을 열고 3컷 그림 안내를 보여 줌: 텍스트 입력 ▸ 편집… ▸ + ▸ 한국어 ▸ Duo.
   - 실시간 상태 줄: 초록색 체크와 함께 "Duo가 켜져 있어요". TIS로 1 s마다 확인함.
3. **Duo를 유일한 키보드로 만들기(권장).**
   - 설명: "다른 입력 소스가 있으면 Caps Lock이나 ⌃Space가 Duo에서 벗어나게 해요."
   - 버튼 "다른 입력 소스 끄기"는 켜진 입력 소스를 토글과 함께 나열하고(두벌식, ABC…) 체크한 소스에 `TISDisableInputSource`를 호출함.
   - Duo가 `kTISPropertyInputSourceIsASCIICapable == true`를 보고할 때만 허용함. 아니면 ABC를 남기고 이유를 설명함.
   - "Caps Lock 키로 ABC 전환"도 끄라고 안내함. 이 설정은 프로그램으로 바꿀 수 없기 때문임.
4. **입력 스타일.**
   - 세그먼트 컨트롤 "주로 쓰는 언어": 한국어 위주 / 반반 / English(Automatic의 기본 사전 확률을 정함).
   - 토글 "개발자예요 (터미널·코드 에디터 최적화)": 켜면 Direct와 English-first 프로필을 쓰고, 끄면 모든 앱을 Automatic으로 둠.
5. **바꾸기 키.**
   - 오른쪽 ⌘를 강조한 큰 키보드 그림을 보여 줌: "단어가 잘못 나오면 오른쪽 ⌘를 톡." 안내 문구가 지금 눌러 보라고 함.
   - 호스트 앱은 `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)`로 톡을 감지하고 체크 표시 애니메이션을 보여 줌. 자기 창 안에서는 권한이 필요 없음.
   - 8 s 안에 톡이 없으면: 5.1절의 대안과 함께 "이 키보드에선 오른쪽 ⌘를 못 찾았어요. 다른 키를 골라 주세요"를 보여 줌.
6. **연습 (과제 4개, 각각 연습장 필드에서 실시간으로 확인함).**
   - "안녕하세요 Duo를 써봐요"(섞어 쓰기).
   - "macOS 26 업데이트"(숫자와 영어).
   - 한국어 문장 안에서 `go`를 치고 해로 바꾸기.
   - 틀린 단어를 치고 Space를 누른 뒤 마지막 단어를 바꾸기.
7. **완료.** "이제 어디서나 그냥 쓰면 돼요." 버튼: "설정 열기", "완료".

### 8.2 설정 창 (사이드바가 있는 `NavigationSplitView`, `.formStyle(.grouped)`를 쓴 `Form`, macOS 26 스타일. 표준 단축키 ⌘,로 열림)
- **일반 (General)**
  - 바꾸기 키: 5.1절 선택지가 있는 선택기. 톡 인식 시간: 고급 슬라이더 200–500 ms.
  - 힌트 표시 (Show hints): 켬.
  - "애매한 단어 확정 후 되돌리기 제안"(애매한 확정 칩): 켬.
  - 백스페이스 단위 (Backspace while composing): 자소(기본) / 글자. Apple의 "Jaso/Gulja"에 맞춤.
  - "` 키로 ₩ 입력": 끔.
  - 맨 위에 "Try it" 연습장 필드를 넣음.
- **앱별 설정 (Apps)**
  - 지금까지 본 앱 목록(아이콘과 이름)과 앱마다 프로필 팝업: 자동 / 한국어 우선 / English 우선 / 직접 입력 (터미널 방식).
  - 작은 막대가 학습한 편향을 보여 줌("최근 한국어 68%").
  - "+"로 /Applications를 여는 NSOpenPanel에서 앱을 추가함.
  - "기본값 복원"(restore defaults).
- **학습한 단어 (Learned Words)**
  - 검색할 수 있는 `Table`. 열: 입력 키 (dkssud) | 결과 (안녕) | 횟수 | 마지막 사용.
  - 밀기나 Delete 키로 항목을 지움. "모두 지우기"는 확인을 받음.
  - 토글 "학습하기"(학습 켬).
- **개인정보 (Privacy)**
  - "Duo는 모든 판단을 Mac 안에서 해요. 입력한 문장은 저장하지 않고, 학습에는 단어별 횟수만 남아요."
  - 데이터 위치를 보여 줌. 버튼: 내보내기(JSON), 지우기. 입력기 타깃에는 네트워크 권한(entitlement)이 없음.
- **문제 해결 (Troubleshooting)**
  - 실시간 점검: Duo 켜짐 여부, 다른 입력 소스 켜짐 여부, Caps Lock 전환 켜짐 여부, 어떤 앱에서 보안 키보드 입력이 켜져 있는지(6.7절), 현재 앱의 프로필.
  - "Duo 다시 시작"(입력기 프로세스를 다시 실행).
- **정보 (About)**: 버전, 감사의 글, 도움말 링크.

### 8.3 입력 메뉴 (`IMKInputController.menu()`)
메뉴는 Apple 한국어 입력기 메뉴처럼 짧게 유지해요.

| 항목 | 동작 |
|---|---|
| **Duo 설정…** | 호스트 앱의 설정을 엶 |
| — | — |
| **현재 앱: ‹앱 이름›** ▸ (라디오) 자동 · 한국어 우선 · English 우선 · 직접 입력 | 앱별 프로필을 기록함 |
| **선택한 텍스트 한↔A 변환** | 5.2절 선택 영역 변환 |
| ✓ **힌트 표시** | 토글 |
| **학습 일시 정지** | 토글 (일시 정지 중이면 체크 표시) |
| — | — |
| **Duo 도움말** | 호스트 앱의 도움말 페이지 |

- Info.plist 핵심 항목(인프라 트랙이 확인함): 이름이 "Duo"인 입력 모드 하나, `TISIntendedLanguage` = `ko`, "한A"라고 적힌 템플릿 아이콘(16 pt, 템플릿, PDF).
- 아이콘은 바뀌지 않음: Duo는 보이는 모드가 없는 입력 소스 하나라서, 메뉴 막대가 한과 A 사이에서 "깜빡이는" 일이 없음.

---

## 9. 엣지 케이스 (기대 동작 = 테스트 벡터)

- 키는 US-QWERTY 키 입력이고 ␣는 Space임.
- 맥락 기호: **N** = 중립 사전 확률(Automatic, 모멘텀 없음), **KO+** = 한국어 모멘텀, **EN+** = 영어 모멘텀.
- 기대 결과 열의 "→"는 "입력 중 표시 → 확정 결과"라는 뜻임.

| # | 키 | 맥락 | 기대 결과 | 규칙 |
|---|---|---|---|---|
| 1 | `dkssudgktpdy␣` | N | 안녕하세요␣ (`dk`에서 K 단계, Apple 방식 음절 확정) | 2.2절 |
| 2 | `rkskekfk␣` | N | 가나다라␣ | 2.2절 |
| 3 | `gksrmf␣` | N | 한글␣ | 2.2절 |
| 4 | `rkatkgkqslek␣` | N | 감사합니다␣ | 2.2절 |
| 5 | `hello␣` | KO+ | hello␣ (`h`에서 KO가 죽음 → E, 그대로) | 2.3절 |
| 6 | `Hello␣` | 문장 시작 | Hello␣ | 6.2절 |
| 7 | `zzz␣` | N, KO+, 또는 EN+ | ㅋㅋㅋ␣ (자모 연속 분류의 사전 확률 KO +2.0이 모멘텀을 이김. 학습 가능) | 2.3절, 5.5절 |
| 8 | `bb␣` | 모두 | ㅠㅠ␣ | 자모 연속 |
| 9 | `nn␣` | 모두 | ㅜㅜ␣ | 자모 연속 |
| 10 | `gg␣` | KO+ / EN+ | ㅎㅎ / gg (충돌 목록. HUD가 다른 쪽을 보여 줌) | 6.1절 |
| 11 | `dz␣` | 모두 | ㅇㅋ␣ | 자모 연속 |
| 12 | `eeee␣` | N | ㄷㄷㄷㄷ␣ | 자모 연속 |
| 13 | `lol␣` | 모두 | lol␣ (ㅣㅐㅣ 죽음) | 2.3절 |
| 14 | `OK␣` | 모두 | OK␣ (⇧K는 QWERTOP 외 키. ㅒㅏ 죽음) | 3절 |
| 15 | `ok␣` | 모두 | ok␣ | 2.3절 |
| 16 | `iPhone␣` | KO+ | iPhone␣ (camelCase) | 3절 |
| 17 | `macOS␣` | KO+ | macOS␣ | 3절 |
| 18 | `IT␣` | KO+ | IT␣ (⇧I는 강한 EN) | 3절 |
| 19 | `PR␣` | KO+ | PR␣ (ㅖㄲ 죽음) | 2.3절 |
| 20 | `go␣` | EN+ / KO+ | go␣ / 해␣ (진짜 모호함. HUD가 다른 해석을 제안함) | 6.1절 |
| 21 | `so␣` `do␣` `to␣` | EN+ / KO+ | so/내, do/애, to/새 (#20과 같은 규칙) | 6.1절 |
| 22 | `So␣` | 모두 | So␣ (⇧S) | 6.2절 |
| 23 | `To␣` | 문장 시작 | To␣ (문장 시작의 QWERTOP 대문자 EN +1.0. 쌔는 드묾) | 6.2절 |
| 24 | `a␣` / `I␣` / `i␣` | KO+ | a / I / i (한 글자 충돌 목록은 영어 쪽) | 7.3절 |
| 25 | `the␣` / `and␣` | KO+ | the / and (솓, 뭉은 유효하지만 드묾) | 어휘 사전 |
| 26 | `dl␣` | EN+ | 이␣ (아주 흔한 KO. "dl"은 약한 EN) | 어휘 사전 |
| 27 | `Reactzjavhsjsxm␣` | 모두 | React → React컴 → … → React컴포넌트␣ | 4.5절 |
| 28 | `APIfmf␣` | KO+ | API → API르 → API를␣ | 4.5절 |
| 29 | `PRdptj␣` | 모두 | PR에서␣ | 4.5절 |
| 30 | `pushgoTdj␣` | 모두 | push했어␣ | 4.5절 |
| 31 | `pushed␣` / `users␣` | 모두 | pushed / users (보류 키가 라틴 문자로 확정됨) | 4.5절 |
| 32 | `roffjrtlS24` | 모두 | 갤럭시S24 | 4.5절 대문자 규칙 |
| 33 | `dkdlvhs16` | 모두 | 아이폰16 | 3절 숫자 |
| 34 | `doq` → `store` | 모두 | 앱store (→ = 띄우지 않고 확정) | 4.5절 범위 |
| 35 | `doqstore␣` | 모두 | 앱ㄴ색ㄷ… (알려진 v1 한계. 바꾸면 전부 라틴 문자인 "doqstore"가 됨) | 4.5절 |
| 36 | `github.com/foo␣` | KO+ | github.com/foo␣ (점 포함 → L) | 4.4절 |
| 37 | `user@example.com` | 모두 | user@example.com | 4.4절 |
| 38 | `dkssud@example.com` | 모두 | 안녕이 보이다가 `@`에서 → dkssud@example.com (확정된 "안"을 replacementRange로 바꿈. 클라이언트가 못 하면 결과는 안녕@example.com이고, HUD가 여기서는 바꿀 수 없다고 알림) | 4.4절 규칙 2, 5.3절 |
| 39 | `~/Library` | 모두 | ~/Library | 4.4절 |
| 40 | `https://apple.com` | 모두 | 리터럴 | 4.4절 |
| 41 | `/help␣` | Slack | /help (슬래시 명령 그대로) | 4.4절 |
| 42 | `@minsu` | Slack | @minsu (키가 그대로 가서 멘션 자동 완성이 동작함) | 4.4절 |
| 43 | `:smile:` | Slack | :smile: (이모지 선택기가 동작함) | 4.4절 |
| 44 | `#aktwlq␣` | 모두 | #맛집␣ (`#`는 리터럴 아님) | 4.4절 |
| 45 | `e.g.␣` | KO+ | e.g.␣ | 4.2절 |
| 46 | `node.js␣` | 모두 | node.js␣ | 4.2절 |
| 47 | `U.S.␣` | 모두 | U.S.␣ | 4.2절 |
| 48 | `ek.rmfotj␣` | KO+ | 다.그래서␣ (K 단계: `.`가 확정함) | 4.3절 |
| 49 | `don't␣` / `I'm␣` | 모두 | don't / I'm | 4.2절 |
| 50 | `'dkssud'␣` | 모두 | '안녕'␣ | 4.3절 |
| 51 | `e-mail␣` / `my-component␣` | 모두 | e-mail / my-component | 4.2절 |
| 52 | `user_name` | 모두 | user_name (L) | 4.4절 |
| 53 | `getElementById` | VS Code | 1번째나 2번째 키부터 그대로 감(E 단계). IntelliSense가 실시간으로 동작함 | 4.6절 |
| 54 | `3tl␣` | 모두 | 3시␣ | 6.4절 |
| 55 | `10ro␣` | 모두 | 10개␣ | 6.4절 |
| 56 | `2rodnjf␣` | 모두 | 2개월␣ | 6.4절 |
| 57 | `5qns␣` / `1emd␣` / `30ch␣` | 모두 | 5분 / 1등 / 30초 | 6.4절 |
| 58 | `3pm␣` / `10am␣` | KO+ | 3pm / 10am | 6.4절 |
| 59 | `4K␣` / `5G␣` / `3D␣` | 모두 | 4K / 5G / 3D | 6.4절 |
| 60 | `4th␣` | KO+ | 4th (단위 표가 4소를 이김) | 6.4절 |
| 61 | `iOS26␣` / `macOS␣26` | 모두 | iOS26 / macOS 26 | 3절 숫자 |
| 62 | `v1.2` / `mp3` / `B2B` | KO+ | v1.2 / mp3 / B2B (숫자 앞의 홀로 선 자모 → 라틴 문자) | 3절 숫자 |
| 63 | `rlaalstn␣` | 모두 | 김민수␣ | 어휘 사전 / 이름 |
| 64 | `tkvkfl` + Return | Spotlight | 사파리가 확정된 뒤 Return이 Safari를 엶 | 3절 Return |
| 65 | `Dkssudgktpdy␣` | KO+ | 안녕하세요␣ (실수로 누른 ⇧D는 강한 근거지만 거부권은 아님. HUD가 "Dkssudgktpdy"를 제안함) | 3절 Shift |
| 66 | `dlTek␣` / `rkTek␣` | 모두 | 있다 / 갔다 (⇧T = ㅆ) | 2.1절 |
| 67 | `ekfr` 후 ⌫⌫⌫⌫ | 모두 | 닭 → 달 → 다 → ㄷ → (빈 상태, ⌫ 소비) | 3절 Backspace |
| 68 | `dkssud␣` 후 ⌫ | 모두 | 스페이스가 지워짐(통과). HUD 칩에 "↺ dkssud ⌘"가 보임 | 5.4절 |
| 69 | `go` 후 R⌘, 이어서 `s␣` | EN+ | go → 해 (고정) → 핸␣. `gos`=KO로 학습 표를 기록함 | 5.2절a |
| 70 | `go␣` 후 R⌘ | TextEdit | "go␣" → "해␣". `go`=KO +1 학습 | 5.2절b |
| 71 | `go␣` 후 R⌘ | Terminal (Bilingual) | 그대로. HUD "여기서는 바꿀 수 없어요" | 5.3절 |
| 72 | 빈 필드에서 R⌘, 이어서 `go␣` | EN+ 사전 확률 | 배지 한, 이어서 해␣ (한 번용) | 5.2절c |
| 73 | `dkssud12` | 암호 필드 | dkssud12 그대로: 조합 문자열, HUD, 학습 모두 없음 | 6.7절 |
| 74 | `ls -al` Return | Terminal | 그대로 (Direct) | 6.6절 |
| 75 | R⌘ `qjrm tnwjd` Return | Terminal | 버그 수정 후 Return. Direct로 돌아감 | 6.6절 |
| 76 | `dd`, `:wq` | Terminal의 vim | 그대로 가서 바로 실행됨 | 6.6절 |
| 77 | Caps Lock 켬, `asap␣` | 모두 | ASAP␣ 그대로 | D9 |
| 78 | ⌥e 후 `e` | 모두 | é (데드 키. 다음 키가 그대로 통과함) | 3절 Option |
| 79 | `dkssud` 후 ⌃⌘Space, 😀 선택 | 모두 | 안녕😀 (선택기를 열기 전에 확정) | 3절 Globe |
| 80 | `z` 누르고 있기(자동 반복) | KO+ | ㅋㅋㅋㅋㅋㅋ… 반복 중에는 HUD 없음 | 3절 자동 반복 |
| 81 | `dkssu`, 다른 곳 클릭 | 모두 | 안녀가 보이는 대로 확정됨 | 3절 마우스 |
| 82 | `go`, ⌘A | EN+ | "go" 확정 후 전체 선택 | 3절 ⌘ |
| 83 | `gkdl` Return | 카카오톡 / 웹 채팅 | 하이 전송. Return 시점에 "이"만 조합 중이었음(Apple과 동등) | 1.3절, D2 |
| 84 | 경계 없이 `a` 40번 | 모두 | 33번째 키에서 강제 결정. 거대한 밑줄 없음 | 4.1절 |
| 85 | `dkssud`, 앱이 필드를 비움(전송 후 Slack) | Slack | 상태를 조용히 초기화함. 유령 재삽입 없음 | 3절 재동기화 |
| 86 | `xptmxm` ⇧Space | 바꾸기 키 = ⇧Space | 테스트 → 바꾸기 → "xptmxm" | 5.1절 |
| 87 | `xptmxm` ⇧Space | 기본값 | 테스트␣ (⇧Space = Space) | 3절 |
| 88 | `ehdgo` ⌥Return | 모두 | 동해 확정 후 ⌥Return 통과(한자는 v2) | 3절 |
| 89 | ` 키 | 모두 | ` (₩ 아님, 설정을 켰을 때만 ₩) | 3절 |
| 90 | `rt␣` | KO+ / EN+ | ㄱㅅ / rt | 충돌 목록 |
| 91 | `// APIfmf` | Xcode | // API를 (English-first 앱에서도 한국어를 쓸 수 있음) | 4.6절 |
| 92 | 선택 영역 "dkssud", 메뉴 ▸ 선택한 텍스트 한↔A 변환 | TextEdit | 안녕 | 5.2절 |

---

## 10. 구현과 테스트 참고 (TCC 불필요)

- **엔진 경계.** DuoCore(Swift 패키지)는 순수 리듀서를 노출함:
  - `func reduce(_ state: TokenState, _ input: KeyInput, _ ctx: Context) -> (TokenState, [ClientAction])`
  - `ClientAction` 케이스: `.mark(String)`, `.commit(String)`, `.replace(range:, with:)`, `.pass`, `.consume`, `.hud(HUDState)`.
  - 3절의 모든 행과 9절의 모든 벡터가 Swift Testing 케이스가 됨: `@Test(arguments: vectors) func edgeCase(_ v: Vector)`.
- **가짜 클라이언트.** `protocol TextClient`는 Duo가 쓰는 IMKTextInput 메서드를 그대로 본뜸: `insertText(_:replacementRange:)`, `setMarkedText(_:selectionRange:replacementRange:)`, `selectedRange()`, `markedRange()`, `attributedSubstring(from:)`, `attributes(forCharacterIndex:lineHeightRectangle:)`, `bundleIdentifier()`, `windowLevel()`.
  - `FakeTextClient`는 String으로 이를 구현함. 설정 가능한 `supportsReplacement`, `supportsMarkedText` 플래그로 Terminal과 Java 경우를 다룸.
  - 실제 `IMKInputController` 하위 클래스는 얇은 어댑터임.
- **HUD와 온보딩 화면.**
  - 스냅샷 테스트용으로 `ImageRenderer`를 써서 SwiftUI 뷰를 화면 밖에서 렌더링함. Liquid Glass는 화면 밖에서 평평하게 그려질 수 있으니, 픽셀이 아니라 레이아웃과 글자를 검증함.
  - 호스트 앱 자신의 창은 `NSView.bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)`로 **화면 기록 권한 없이** 픽셀을 캡처함. 앱 자신의 뷰이기 때문임.
- **톡 감지기.** `(keyCode, deviceFlags, timestamp, mouseButtons)`를 입력받는 순수 상태 기계로 만듦. 299 / 301 ms 타이밍 경계, ⌘-클릭, ⌘C를 테스트함.
- **학습 저장소.** 입력기와 호스트 앱이 함께 쓰는 앱 그룹 컨테이너의 JSON 파일을 씀. 2 s 디바운스로 기록함. 모든 접근은 actor를 거침.

## 11. v2로 남긴 과제
- Apple과 동등하게, 후보 창이 있는 ⌥Return 한자 변환.
- 대문자 없는 KO→EN 다시 나누기(앱store).
- 섞인 단어용으로 화살표 키로 고르는 후보 3개짜리 HUD.
- 브라우저의 웹사이트별 사전 확률(손쉬운 사용 권한이 필요해서 v1 범위 밖).
- 세벌식 자판.

## 출처
- Apple 한국어 입력기 설명서 (macOS 26): https://support.apple.com/ar-bh/guide/korean-input-method/him001/104/mac/26
- Apple 입력 소스 설정 (macOS 26): https://support.apple.com/en-au/guide/mac-help/mchl84525d76/26/mac
- Apple iPhone 키보드 설명서: https://support.apple.com/en-ph/guide/iphone/iph73b71eb/ios
- iOS 18 한국어+영어 키보드: https://techcrunch.com/2024/07/02/apple-adds-support-for-new-languages-across-lock-screen-keyboard-and-search-on-ios-18 · https://wwdcnotes.com/documentation/wwdc24-10185-build-multilingualready-apps/ · https://extrememanual.net/54072
- 이중 언어 키보드 버그: https://developer.apple.com/forums/thread/765324 · https://developer.apple.com/forums/thread/767894 · https://discussionskorea.apple.com/thread/256109234 · https://lr.eu.psf.lt/r/iOSBeta/comments/1dcvps5/ios_18_db1_now_supports_multilingual_keyboard
- macOS 26 전환 버그: https://discussions.apple.com/thread/256254361 · https://discussions.apple.com/thread/256247006 · https://discussions.apple.com/thread/256144071
- macOS 한국어 설정, Caps Lock, Vim, ₩: https://daleseo.com/macos-korean-input/ · https://daleseo.com/gureum/ · https://gist.github.com/redism/43bc51cab62269fa97a220a7bb5e1103
- Enter/조합 버그: https://gh.r-mj.com/andrepimenta/claude-code-chat/pull/146 · https://upd.dev/warpdotdev/warp/issues/8919 · https://bugzilla.mozilla.org/show_bug.cgi?id=1632597
- Office 한/영 자동 고침: https://wikidocs.net/228455 · https://www.oppadu.com/shorts/%ec%97%91%ec%85%80-%ed%95%9c%ea%b8%80-%ec%98%81%ec%96%b4-%eb%b0%94%eb%80%9c/
- Punto Switcher: https://yandex.ru/support/punto-mac · https://yandex.ru/support2/punto-mac/ru/settings · https://habr.com/ru/articles/39353/comments/ · https://community.notepad-plus-plus.org/post/93621
- Caramba Switcher: https://lifehacker.ru/caramba-switcher/ · https://www.iguides.ru/main/os/caramba_switcher/
- 한국 Mac 도구: https://news.hada.io/topic?id=22660 · https://apps.apple.com/kr/app/enko-%EC%98%81%ED%95%9C-%EC%98%A4%ED%83%80-%EB%B3%80%ED%99%98%EA%B8%B0/id6746715150?l=ko · https://damoang.net/macmoang/7280 · https://github.com/Sailfishc/inputsourcepro
