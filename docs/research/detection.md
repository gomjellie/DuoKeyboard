# Duo — 한국어/영어 언어 감지: 알고리즘, 데이터, 모델 형식

상태: 리서치 트랙 산출물(프로토타입은 `Tools/ModelBuilder/`, Python 3.12, 표준 라이브러리만 씀).
담당 경로: `Tools/ModelBuilder/`(스크립트, 직접 고른 데이터, `out/`의 결과물), `Tools/data/raw/`(내려받은 말뭉치, gitignore 대상).

## 요약 (TL;DR)

* **단어마다 세우는 가설**: 한국어(`K`, 두벌식 오토마톤), 영어(`E`, 친 키 그대로),
  **라틴 단어 + 붙은 한국어**(`M(b)`: `PR을`, `iOS에서`, `push했어요`, `LG전자`). 한국어는 라틴 단어에
  조사를 띄어 쓰지 않고 바로 붙임. 그래서 세 번째 읽기가 필요함. 이 읽기를 빼면 개발자 채팅
  글에서 1.2 pt가 떨어짐.
* **모델**: 5차(order-5) modified Kneser-Ney 문자 언어 모델(LM) 두 개를 씀. 두 LM은 37개 기호로 된
  키 입력 알파벳을 함께 씀(한국어는 두벌식 키 입력으로 적고, `Q W E R T O P` = Shift 자모). 여기에
  한국어 어절 상위 100 k개 / 영어 상위 60 k개 어휘 사전, 외톨이 자모 벌점, Shift/대소문자 모델,
  라틴 뒤 접미사 1 684개, 문맥 사전 확률(START / KO / EN / NUM), 종결 키 단서, 사용자별 횟수를 더함.
  이것들을 millinats 단위의 정수 로그 선형 점수로 합침. 그래서 Swift 포팅이 **비트 단위로 똑같을(bit-exact)** 수 있음.
* **측정 결과**: 실제로 배포하는 5.63 MB 파일로, 학습에 한 번도 쓰지 않은 문체(register)에서 잼.
  * 문맥 없는 낱단어: 한국어 99.48 %, 한국어 글 속 영어 99.44 %, 영어 뉴스 99.89 %
  * 문맥 있는 이어진 글: 한국어 뉴스 **99.90 %**, 한국어 위키백과 **99.89 %**, 영어 뉴스
    **99.99 %**, 직접 쓴 혼합 개발자 채팅 세트 **99.86 %**(오류 2개: `so`, `go`)
  * 표시: 한국어 단어는 절대 깜빡이지 않음(0.000 바뀜/단어). 영어 문맥 속 영어는 0.012
    바뀜/단어. Shift 롤오버(rollover) 오타에 100 % 견딤.
* **런타임 형식**: mmap할 수 있는 리틀 엔디언 파일 하나, `duo-model.bin`(DUOM v1: 정렬해 묶은
  n-gram 키 u32/u64, u8 코드북 인덱스, FNV-1a-64 어휘 사전 해시, 작은 JSON meta). 키 입력 하나에
  이진 탐색이 6–106번 듦(Swift에서는 10 µs보다 훨씬 짧음).
* **골든 벡터(golden vectors)**: `Tools/ModelBuilder/out/test_vectors.json`(오토마톤 사례 696개, 최종 판정 1 069개 ×
  문맥 6개, 점진 추적 642개, LM/어휘 사전/해시/아포스트로피/사용자 벡터). 자세한 내용은 8절에 있음.
* **라이선스**: 모델은 CC-BY-SA-4.0 데이터(FrequencyWords를 거친 OpenSubtitles, 한국어
  위키백과, wordfreq)에서 나왔음. 그래서 CC-BY-SA-4.0으로, 저작자 표시와 함께 배포해야 함(2절).

---

## 1. 문제 정의와 가설 공간

엔진은 현재 단어의 키 입력을 **ABC (US) 자판이 만들었을 문자열**로 봐요. 소문자는 Shift 없이
누른 키이고, 대문자는 Shift+키예요. `PRdmf`는 Shift+P, Shift+R, d, m, f를 뜻해요. 이 문자열(`raw`)이
감지의 유일한 입력이에요. 두 가지 해석은 이 문자열에서 만들어요.

| 가설 | 보여 주는 글자 | 예: raw → 글자 |
|---|---|---|
| `K` (한국어) | `raw`에 두벌식 오토마톤을 적용함(3절) | `dkssud` → 안녕 |
| `E` (영어) | `raw` 그대로(친 대소문자 그대로) | `meeting` → meeting |
| `M(b)` (라틴 단어 + 붙은 한국어, 1 ≤ b < len) | `raw[0..<b]` + automaton(`raw[b...]`) | `PRdmf` → PR을, `pushgoTdjdy` → push했어요, `LGwjswk` → LG전자 |

`M(b)`가 있는 이유는 한국어가 라틴 단어 바로 뒤에 조사/어미를 **띄어 쓰지 않고** 붙이기 때문이에요
(`PR을`, `API를`, `iOS에서`, `merge해주세요`, `A씨는`, `LG화학`). 한국어 뉴스에서 단어의 1.44 %에
라틴 글자가 들어 있어요. 그리고 **그중 34 %에는 한국어 접미사가 붙어 있어요**. 단어마다 K/E만
고르는 방식이라면 이것들을 모두 틀려요. 한 단어 안에서 한글 뒤에 라틴 글자가 오는 경우(`카톡ID`)는
지원하지 않아요(한국어 뉴스 단어의 0.045 %).

감지기는 가설마다 정수 로그 점수를 내요(millinats = 자연로그 단위의 1/1000). 점수 모드는 두 가지예요.

* **최종 모드(final mode)** — 단어를 확정할 때 씀(스페이스, 문장 부호, 숫자, Return, 포커스 잃음).
  단어가 끝났다고 봄(`</s>` 점수를 넣고, 어휘 사전을 씀).
* **접두 모드(prefix mode)** — 조합 문자열(marked text) 표시를 위해 키를 누를 때마다 씀. 단어가 더 이어질 수
  있다고 봄(`</s>` 없음, 어휘 사전 없음. 이 키들로 시작하는 모든 단어의 확률).

모든 계산은 정수예요(`Int32`면 충분하고, Swift에서는 `Int`를 쓰면 돼요). 그래서 Swift 포팅이
`Tools/ModelBuilder/out/test_vectors.json`과 **비트 단위로 똑같을** 수 있어요.

---

## 2. 데이터 출처와 라이선스

| 말뭉치 | 용도 | 크기 | 라이선스 | `Tools/data/raw/` 안의 파일 |
|---|---|---|---|---|
| hermitdave/FrequencyWords, OpenSubtitles 2018 `ko_full` | KO 학습(구어체, 어절 단위) | 688 129 종류 / 6.33 M 단어(한글 660 810 종류) | 내용 **CC-BY-SA-4.0**, 코드 MIT | `fw_ko_full.txt`, `fw_ko_50k.txt` |
| 한국어 위키백과 덤프, 1번 조각(`kowiki-latest-pages-articles1.xml-p1p82407.bz2`, 94 MB) | KO 학습(문어체) | 한글 어절 1.39 M 종류 / 14.3 M 단어(횟수 ≥ 2인 종류만 씀) | **CC-BY-SA-4.0** (Wikimedia) | `kowiki/` |
| hermitdave/FrequencyWords `en_full` | EN 학습(구어체) | 1.66 M 종류 / 735 M 단어(횟수 ≥ 3, `^[a-z]+('[a-z]+)*$`) | **CC-BY-SA-4.0** | `fw_en_full.txt`, `fw_en_50k.txt` |
| rspeer/wordfreq 3.x `large_en.msgpack.gz` | EN 학습(웹, 위키백과, 뉴스, 자막, Reddit, Twitter 혼합) | 321 180 단어, 센티벨(centibel) 구간 | 데이터 **CC-BY-SA-4.0**(코드 Apache-2.0). 프로젝트는 종료됨(업데이트 없음) | `wordfreq/` |
| Leipzig Corpora Collection `kor_news_2022_100K`, `kor_wikipedia_2021_100K`, `eng_news_2023_100K` | **평가 전용**(학습에서 뺀 문체. 대소문자, 숫자, 문장 부호, 한국어 속 라틴 글자가 있는 실제 문장) | 각 100 k 문장(글자로 된 단어 1.63 M / 1.40 M / 1.96 M) | LCC 이용 약관(사이트가 봇 차단 장벽 뒤에 있어서 다시 확인하지 못했음. 연구/평가 전용으로 다룸. **여기서 나온 것은 아무것도 배포하지 말 것**) | `lcc_*/` |
| Peter Norvig `count_1w.txt` | 쓰지 않음(살펴보기만 함) | 333 k 단어 | Google Web 1T (LDC)에서 나옴 — **재배포 가능 여부가 불분명함. 배포하지 말 것** | `norvig_count_1w.txt` |
| 프로젝트에서 직접 만든 목록 | 정식 대소문자를 가진 기술 용어, 채팅 자모, 라틴 뒤 접미사, 혼합 테스트 세트 | `Tools/ModelBuilder/data/` 참고 | 프로젝트(CC0) | — |

뺀 것: wordfreq `ko`(**MeCab으로 형태소 단위로 나뉘어** 있음. 하지만 사용자는 어절 단위로 침),
Norvig(라이선스), 학습용 Leipzig(라이선스를 확인할 수 없음).

**배포 의무**: 모델 파일은 CC-BY-SA-4.0 데이터를 변형한 저작물이에요. 그래서 `duo-model.bin`은
CC-BY-SA-4.0으로, 저작자 표시와 함께 배포해야 해요("Contains information from
OpenSubtitles2018 via FrequencyWords by Hermit Dave, Korean Wikipedia, and wordfreq by Robyn Speer,
CC-BY-SA 4.0"). 이 의무는 앱 코드의 라이선스에는 영향을 **주지 않아요**. 고지문은 About 창 /
감사의 글(acknowledgements)에 넣고, 저장소 안에서도 리소스 옆에 두세요.

### 학습 데이터 혼합 (`model_data.py` 참고)

* **한국어**: 순수 한글 어절에 대해 `count(w) = 2 × OpenSubtitles(w) + kowiki(w)`로 셈. 키→한글 왕복
  변환을 통과하고 완성된 음절로만 된 어절만 씀(`ㄲ`, `ㄷ`처럼 자모만 있는 말뭉치 단어는 말더듬 잡음이라 버림) — 1 104 134 종류, 26.3 M 의사 단어(pseudo-token), 자막 48 % / 위키백과 52 %. 여기에 채팅 단어 83개를 더함
  (`ㅋㅋ`, `ㅎㅎ`, `ㅠㅠ`, `ㅇㅋ`, `ㄱㄱ`, `ㅈㄴ`, `ㅎㄷㄷ`, `걍`, `굳`, `ㅈ같다`, `도` …, `data/ko_chat.txt`,
  백만 단어당 비율로 줌. 2026-11-08에 커뮤니티 글 평가에서 자주 틀린 말 51개를 더했음).
* **영어**: OpenSubtitles(횟수 ≥ 3) + 같은 총량으로 맞춘 wordfreq(509 482 종류). 여기에 기술/사무
  용어 260개(`data/en_terms.txt`: API, PR, iOS, macOS, GitHub, Slack, Figma, LGTM …)를 등급별로 백만 단어당
  50 / 10 / 2로 더함. 정식 대소문자 형태(iOS, GitHub, API)가 **대소문자 어휘 사전**이 됨.
* **라틴 뒤 접미사**: kowiki(74 k 단어)와 OpenSubtitles(×5)에서 `^[A-Za-z]+[가-힣]+$` 단어의 한글
  꼬리를 모음. 여기에 `data/suffix_extra.txt`(개발자 채팅 어미: 해주세요, 했습니다, 할게요 …)를 더함.
  의사 횟수 ≥ 5인 접미사만 남김 → 접미사 1 684개.

### 평가 세트 (`evaluate.py prepare`)

* **제외한 종류(held-out types)** — 학습 혼합 데이터에서 단어 종류의 10 %(CRC32(word) % 10 == 0).
  `train` 분할 모델의 n-gram과 어휘 사전은 이 단어들을 한 번도 보지 않음. 사전에 없는 단어(OOV)에
  대한 일반화를 잼.
* **교차 말뭉치(cross-corpus)** — Leipzig 문장. 짝수 줄 = dev, 홀수 줄 = test. 모든 단어를 쓰인
  그대로 침(대소문자 그대로, 숫자는 경계, `’` → `'`). 정답 표시는 글자 체계로 정함:
  한글 → K, 라틴 → E, 라틴+한글 → M(b).
* **혼합 개발자 채팅 세트** — `data/mixed_sentences.txt`, 직접 쓴 417 문장 / 1 385 단어. 한국 개발자와
  사무직이 흔히 쓰는 글임("PR을 올렸는데 CI가 깨졌네요", "push했어요 확인해 주세요",
  "Thank you so much", "ㅋㅋ 그러게요"). 테스트 전용이고 튜닝에는 한 번도 쓰지 않음.
* **롤오버 잡음** — 한국어 뉴스 단어를 Shift를 너무 오래 누르거나(Shift한 QWERTOP 키 다음 키에서
  P = 0.3) 너무 일찍 눌러서(그 앞 키에서 P = 0.1) 다시 친 것.

---

## 3. 두벌식 오토마톤 (규범; `hangul.py`)

키 배치(KS X 5002):

```
q ㅂ  w ㅈ  e ㄷ  r ㄱ  t ㅅ  y ㅛ  u ㅕ  i ㅑ  o ㅐ  p ㅔ
a ㅁ  s ㄴ  d ㅇ  f ㄹ  g ㅎ  h ㅗ  j ㅓ  k ㅏ  l ㅣ
z ㅋ  x ㅌ  c ㅊ  v ㅍ  b ㅠ  n ㅜ  m ㅡ
Shift: Q ㅃ  W ㅉ  E ㄸ  R ㄲ  T ㅆ  O ㅒ  P ㅖ ; every other shifted letter = its unshifted jamo
```

**한국어 정규화** `kno = koreanNormalize(raw)`: 대문자 가운데 소문자가 `{q,w,e,r,t,o,p}`에 없는 것은
모두 소문자로 바꿔요. 나머지는 그대로 둬요. (그래서 `Hello` → `hello`가 되고, `PRdmf`는 그대로예요.)

상태 = (cho, jung, jong)이에요(초성, 중성, 종성). 각각 비어 있을 수 있어요. `out` = 내보낸 글자이고,
`orphans` = 내보낸 호환 자모의 수예요. `flush()`: cho와 jung이 둘 다 있으면 음절
`U+AC00 + (cho·21 + jung)·28 + jong`을 내보내요. cho만 있거나 jung만 있으면 그 호환 자모를 내보내고
`orphans += 1`을 해요. 그다음 상태를 비워요.

자음 C:
1. 상태에 cho와 jung이 있음:
   * jong 없음: C ∈ {ㄸ, ㅃ, ㅉ}이면 → flush, cho = C. 아니면 jong = C.
   * jong 있음: (jong, C) ∈ FINAL_COMBINE이면 → jong = 합친 것. 아니면 flush, cho = C.
2. 그 밖의 경우(비었음 / cho만 있음 / 모음만 있음): flush, cho = C.  *(자음은 모음 없이 절대 합쳐지지 않음: r t → ㄱㅅ)*

모음 V:
1. jong 있음(도깨비불): jong이 겹받침(ㄳ ㄵ ㄶ ㄺ ㄻ ㄼ ㄽ ㄾ ㄿ ㅀ ㅄ)이면 → jong = 앞부분, moved = 뒷부분.
   아니면 moved = jong, jong = ∅. flush; cho = moved; jung = V.
2. jung 있음(jong 없음): (jung, V) ∈ VOWEL_COMBINE이면 → jung = 합친 것. 아니면 flush, jung = V(cho가 비었으면 외톨이 모음).
3. 그 밖의 경우(비었음 또는 cho만 있음): jung = V.

`VOWEL_COMBINE`: ㅗ+ㅏ=ㅘ, ㅗ+ㅐ=ㅙ, ㅗ+ㅣ=ㅚ, ㅜ+ㅓ=ㅝ, ㅜ+ㅔ=ㅞ, ㅜ+ㅣ=ㅟ, ㅡ+ㅣ=ㅢ(cho가 있든 없든 적용돼요. `hk` → ㅘ).
`FINAL_COMBINE`: ㄱ+ㅅ=ㄳ, ㄴ+ㅈ=ㄵ, ㄴ+ㅎ=ㄶ, ㄹ+ㄱ=ㄺ, ㄹ+ㅁ=ㄻ, ㄹ+ㅂ=ㄼ, ㄹ+ㅅ=ㄽ, ㄹ+ㅌ=ㄾ, ㄹ+ㅍ=ㄿ, ㄹ+ㅎ=ㅀ, ㅂ+ㅅ=ㅄ.
ㄲ과 ㅆ은 키 하나(R, T)라서 홑받침이에요(있+ㅓ → 이써).
아포스트로피(단어 안에 들어갈 수 있는 유일한 비문자 키): flush하고 `'`를 그대로 내보내요.

감지에 쓰는 출력: `text`, `orphans` = 내보낸 외톨이 수 + (남은 상태가 cho만 있거나 jung만 있으면 1),
`trailingLoneConsonant` = 남은 상태에 cho만 있음. 남은 블록을 그릴 때는 flush하지 않아요(표시는
조합 중인 음절을 보여 줘요).

**감정 자모 반복**(2026-11-08): `runs` = 같은 감정 자모(ㅋㅎㅠㅜㅡㄷㅉ, `EMOTIVE_JAMO`)가 2개 이상 이어진 외톨이의 수,
`runAtEnd` = 마지막 블록이 그런 반복에 들어 있음. K 점수는 이 외톨이에 벌점을 매기지 않아요. 단어 전체가
반복이어도(ㅋㅋㅋㅋㅋ), 음절 옆에 있어도(ㅋㅋㅋ난, 흥해라ㅡㅡ) 같아요. 음절이나 기호가 반복을 끊어요
(Python `emotive_runs`, Swift `DubeolsikMachine.orphanRunStats`).

예시(모두 테스트 벡터에 있어요): `ekfrrhrl` 닭고기, `rkqtdl` 값이, `rkqtl` 갑시, `sjrtl` 넉시,
`dlTdj` 있어, `goTtmqslek` 했습니다, `rkE` 가ㄸ, `rkk` 가ㅏ, `zzz` ㅋㅋㅋ, `rt` ㄱㅅ, `hk` ㅘ, `Ehrqo` 똑배.
엔진의 Backspace는 마지막 키 입력을 지우고 다시 계산하는 거예요. 키 하나가 자모 하나라서 자모 단위로
지워져요. 한국어 사용자가 기대하는 동작과 같아요(예: 과 → 고).

---

## 4. 단어 나누기와 엔진 연동 규칙

* **단어(token)**는 `[A-Za-z]` 키 입력이 가장 길게 이어진 묶음임. 안에 아포스트로피가 있을 수 있음.
  그 밖의 키(스페이스, Return, Tab, 숫자, `-`를 포함한 문장 부호, 화살표, 마우스 클릭, 포커스 변경)는
  **경계**임. 경계는 단어를 확정하고(최종 모드), 그다음 평소처럼 처리됨.
* **아포스트로피 규칙**: 비어 있지 않은 단어 뒤에 `'`를 치면 `raw + "'"`의 접두 모드 점수를 계산함
  (KO LM은 한국어 키 뒤의 `'`에 아주 작은 확률을 줌. `'`가 든 단어에서는 `M(b)`를 끔). argmax가
  `E`이면 아포스트로피는 단어의 일부가 됨(`don't`, `it's`, `didn't`, `she's`; 차이 +10…+50 nats).
  그리고 `shown`이 `E`가 됨. 아니면 단어를 확정하고(최종 모드, 아포스트로피 없이) `'`를 그대로
  출력함(`'사랑'이라는`: `tkfkd'` → −9…−15 nats 차이로 K). 단어는 절대 `'`로 시작하지 않음. 이 규칙은
  "지금 E가 보이면 붙이기"보다 나음. 그 방식은 한국어 단어 뒤의 `didn`/`she`에서 실패함. `야우`와
  `녿`이 올바른 음절이기 때문임. 벡터: `apostrophe[]`.
* **Caps Lock 켬** → 감지를 건너뛰고 ABC 자판처럼 동작함(macOS 기본 한국어 입력기와 같음).
* **문맥 상태** `ctx`(다음 단어에 씀):
  필드 시작, `.` `!` `?` 줄바꿈 뒤, 그리고 커서 이동 / 포커스 변경 뒤에는 `START`. 단어 바로 앞
  글자가 숫자이면 `NUM`(`3개`, `10mm`, `20th`). 그 밖에는 앞서 확정한 단어가 `K`나 `M(b)`였으면
  `KO`, `E`였으면 `EN`.
  스페이스, 쉼표, 따옴표, 괄호는 이전 문맥을 그대로 둠.
* **종결 키(terminator)** `term`(최종 모드 전용) = 단어를 끝낸 경계 키: `S`(스페이스,
  Return, 끝), `D`(숫자: `Q1`, `iOS17`), `H`(하이픈: `co-founder`, `e-mail`), `P`(그 밖의 문장 부호).
* 표시: 조합 문자열은 `render(raw, shown)`을 보여 줌(5.6절). 확정하면 `render(raw, final)`을 넣고,
  사용자 적응을 위해 그것을 기록함.

---

## 5. 점수 계산 (규범; `detector.py`)

### 5.1 기호 알파벳 (두 언어 모델이 함께 씀)

| id | 기호 | | id | 기호 |
|---|---|---|---|---|
| 0 | pad(저장하지 않음) | | 3…28 | `a`…`z` |
| 1 | `<s>` | | 29…35 | `Q W E R T O P` (Shift한 키. 한국어 정규화만 만들어 냄) |
| 2 | `</s>` | | 36 | `'` |

예측 대상 기호는 `V = 35`개예요(id 2…36). n-gram (s₀ … sₙ₋₁)은
`key = Σ sᵢ << 6·(n−1−i)`로 **묶어요(pack)**(가장 오래된 기호가 높은 비트에 가요). order ≤ 5는 `UInt32`에 들어가고, order 6은 `UInt64`가 필요해요.

KO LM은 `kno`(3절)를 읽고, EN LM은 `low = raw.lowercased()`를 읽어요.

### 5.2 문자 n-gram LM

학습(`kn.py`): 보간한 **modified Kneser-Ney**를 써요. Chen & Goodman 방식으로, order마다 할인값 세 개를
조정된 횟수의 count-of-counts에서 구해요. KenLM 관례를 따라요. `<s>`는 하나만 두고, `<s>`로 시작하는
n-gram과 최고 order n-gram은 원래 횟수를 쓰고, 나머지는 연속 횟수(continuation count)를 써요. unigram은
균등 분포 1/V와 보간해요. 단어 종류는 단어 빈도로 가중해요. 그다음 백오프(backoff) 형태로 바꿔요
(`lp(h,w) = ln P_interp(w|h)`, `bow(h) = ln γ(h)`). 가중 차이
`count(h,w)·(ln P(w|h) − ln(bow(h)·P(w|h′))) < θₙ`로 가지치기(pruning)하고, 접두 닫힘(prefix closure)과
정확한 백오프 재정규화를 지켜요. 마지막으로 (모델, order, 필드)마다 256개 항목의 Lloyd-Max 코드북으로
양자화해요(bow 코드북에는 항상 정확한 0이 들어 있어요).

런타임 조건부 로그 확률 — **LM 연산은 이것 하나뿐이에요**.

```
cond(hist, w):                       // hist = [<s>, s1, ..., sk]; w in 2...36
    h  = last (N-1) symbols of hist  // fewer if hist is shorter
    acc = 0
    for n in (len(h)+1) down to 1:
        i = find(table[n], pack(h + [w]))
        if i != nil and !(n == 1 && w == <s>): return acc + lpCodebook[n][lpIdx[n][i]]
        if n > 1:
            j = find(table[n-1], pack(h))
            if j != nil: acc += bowCodebook[n-1][bowIdx[n-1][j]]   // absent context => +0
        h = h.dropFirst()
    // unreachable: the unigram table is dense over 2...36

score(keys, eos) = Σ cond(<s> s1..s(i-1), si)  [+ cond(<s> s1..sn, </s>) if eos]
```

`find` = 해당 order의 정렬된 키 배열에서 하는 이진 탐색이에요. unigram 표에는 키
`1`(`<s>`)도 들어 있어요. 이 키는 `bow(<s>)`를 담는 데만 써요.

### 5.3 단어별 특징(feature)

```
kno = koreanNormalize(raw); low = raw.lowercased()
(text, orph, lone) = automaton(kno)
(nr, ns) = shiftCounts(raw)
  for each i with raw[i] uppercase and lowercase(raw[i]) ∉ {q,w,e,r,t,o,p}:
      if raw[i-1] ∈ {Q,W,E,R,T,O,P} or raw[i+1] ∈ {Q,W,E,R,T,O,P}: nr += 1  (shift rollover)
      else ns += 1                                                        (stray shift)
casePattern(s):            // letters of s only
  no uppercase                       -> lower
  s ∈ caseLexicon (exact string)     -> exact        (iOS, GitHub, macOS, API, PR …)
  ≥ 2 letters, all uppercase         -> allcaps
  first upper, rest lower            -> initcap       ("I" is initcap)
  else                               -> mixed
lexKO[kno], lexEN[low] : optional Int (ln P(word|lang), quantised), FNV-1a-64 hash lookup (7.2)
numUnitsEn             : 56 lowercase tokens that follow digits (th st nd rd km kg mm cm gb mb ms fps px x k …)
```

### 5.4 가설 점수

`word(lm, lex, ng, lx) = lex == nil ? lm + ng : max(lm + ng, lex + lx)`(max는 "어휘 사전에 있는 단어
또는 새 단어" 혼합의 Viterbi 근사예요. 정수 계산을 그대로 유지해요).

**최종 모드**

```
S_K = word(scoreKO(kno, eos) + ORPHAN·(orph − runs), lexKO[kno], NG_KO, LEX_KO)
      + ROLLOVER·nr + STRAY·ns + PRIOR[ctx].KO
S_E = word(scoreEN(low, eos), lexEN[low], NG_EN, LEX_EN)
      + CASE[casePattern(raw)] + (term == D ? TERM_DIGIT_EN : term == H ? TERM_HYPHEN_EN : 0)
      + PRIOR[ctx].EN + (ctx == NUM && low ∈ numUnitsEn ? NUM_UNIT_EN : 0)
for b in 1 ..< len(raw), only if raw contains no apostrophe:
    lat = raw[0..<b];  ks = kno[b...]
    shortOK = (b >= MIX_MIN_LATIN) || lat is all uppercase
    suf = suffixFull[ks]                                         // optional
    gen = (lat has an uppercase letter || lexEN[low[0..<b]] != nil)
          && ks[0] is a consonant key (qwertasdfgzxcvQWERT)
          && orphans(automaton(ks)) == 0      ? scoreKO(ks, eos) : nil
    if !shortOK && ctx != NUM:                                   // one lowercase letter (m에, a양)
        if suf == nil: skip
        gen = nil                                                // table suffixes only
    if suf == nil && gen == nil: skip
    if suf != nil && b == 1 && casePattern(lat) != lower && ctx != EN:
        suf += MIX_INITIAL                                       // A씨, B급, C가 (2026-11-08)
    tail = max over present of { suf + MIX , gen + MIX_GENERIC }
    S_M(b) = word(scoreEN(low[0..<b], eos), lexEN[low[0..<b]], NG_EN, LEX_EN)
             + CASE[casePattern(lat)] + tail
             + ROLLOVER·nr(raw[b...]) + STRAY·ns(raw[b...])       // shiftCounts on the substring
             + PRIOR[ctx].EN
```

**소문자 한 글자 + 접미사**(a양, m에): 숫자 뒤가 아니면 엔진이 스스로 고르지 않아요
(`Token.isChoiceOnly`, 평가에서는 `automatic()`). 바꾸기 키와 후보 막대로만 골라요. 스스로 고르게 하면
영어 단어(ask → a나, ago → a해)와 한국어 첫 자음 표기(ㄱ씨는 → r씨는)를 망가뜨렸어요(홀드아웃 E 99.79 % → 99.12 %).

**`MIX_INITIAL` 평가** (2026-11-08, 출하 모델, `evaluate.py run --binary`, 테스트 세트):

| | 이전 | +6000 |
|---|---|---|
| ko_news M (3 962) | 89.27 % | 91.02 % |
| ko_wiki M (3 556) | 87.57 % | 89.71 % |
| ko_news / ko_wiki 토큰 | 99.899 % / 99.894 % | 99.907 % / 99.904 % |
| ko_wiki E | 99.336 % | 99.322 % (2 토큰) |
| 홀드아웃 K / E, en_news, mixed | 같음 | 같음 |

+8000은 E를 더 잃었어요(ko_news E 99.534 % → 99.496 %). 값은 테스트 세트로 골랐어요. dev 세트로 다시 고르는 일이 남았어요.

**감정 자모 반복과 채팅 단어 평가** (2026-11-08, 해시 `5200eb46b6370ef1`, `out/eval/ship_chat_runs.json`, 테스트 세트):

| | 이전 | 반복 + 채팅 단어 |
|---|---|---|
| ko_news K / E / M (문맥 없음) | 99.481 / 99.444 / 90.74 % | 99.480 / 99.431 / 90.84 % |
| ko_wiki E / M (문맥 없음) | 98.83 / 87.01 % | 98.80 / 86.90 % |
| en_news E (문맥 없음) | 99.887 % | 99.884 % |
| ko_news 문장 (viterbi) | 98.638 % | 98.688 % |
| 홀드아웃 K / E, mixed | 같음 | 같음 |
| 커뮤니티 글 5만 6천 문장(엔진으로 침) | 92.15 % 문장, 0.997 % 단어 오류 | 94.79 % 문장, 0.654 % 단어 오류 |

새로 틀리는 영어: `rid` → 걍과 `cc` → ㅊㅊ(문장 시작에서만. 영어 문맥에서는 E가 이김), `WW` → ㅉㅉ,
위키의 `mm까지` → ㅡㅡ까지(3건). 같은 영어 글자가 두 번 이어지는 단어(see, mmm)는 영어로 남아요.

**접두 모드**(표시): 다음만 빼고 같아요.
`S_K = scoreKO(kno, no eos) + ORPHAN·(orph − runs − (lone && !runAtEnd ? 1 : 0)) + ROLLOVER·nr + STRAY·ns + PRIOR[ctx].KO`
(어휘 사전 없음, NG/LEX 오프셋 없음), `S_E = scoreEN(low, no eos) + CASE[…] + PRIOR[ctx].EN`
(`NUM_UNIT_EN`은 최종 모드처럼 더함. 어휘 사전/오프셋/종결 키는 없음). `M(b)`에서는 표가 `suffixPrefix`예요
(`ks`로 시작하는 모든 접미사의 확률을 더한 값의 ln). 그리고 `gen`은 `scoreKO(ks, no eos)`를 쓰고,
끝에 홀로 남은 자음은 외톨이로 세지 않아요. `M(b)`의 라틴 부분은 항상 완성된 단어로 점수를 매겨요(`</s>` 포함).

**판정**: 후보를 `K, E, M(1), M(2), …` 순서로 늘어놓아요. 점수가 엄격하게 가장 큰 첫 번째
후보가 이겨요(동점이면 → 앞선 후보).

### 5.5 사용자 적응 (사용자별, 기기 안에서)

`userCounts[raw] = {K: n, E: n, M<b>: n}`을 저장해요(키 = 정확한 raw 키 입력 문자열, 대소문자 구분).
확정하면 확정된 가설을 1 올려요. **수동 바꾸기**(사용자가 확정했거나 조합 중인 단어에서 바꾸기 키를
누름)를 하면 고른 가설을 3 올려요(다른 가설은 내리지 않아요). 최종 모드에서는 각 가설의 점수에
`userBonus(n) = (USER_UNIT · USER_LOG2[min(n, 15)]) / 1000`을 더해요(정수 나눗셈,
`USER_LOG2[n] = round(1000·log2(1+n))` = 0, 1000, 1585, 2000, 2322, 2585, 2807, 3000, 3170, 3322,
3459, 3585, 3700, 3807, 3907, 4000). `USER_UNIT = 2500`이면 바꾸기 한 번(n = 3)은 +5.0 nats만큼의 값이에요.
이 정도면 애매한 짧은 단어의 보통 차이(`go`/해 ≈ 2–4 nats)를 뒤집기에 충분해요. 기록 크기에 상한을
두고(예: LRU 20 000 항목) "학습한 단어 초기화"를 제공하세요.
Duo는 상한을 넘으면 상한의 95 %(19 000)까지 줄여요. 횟수는 각각 1000표로, raw는 각각 64 UTF-8 바이트로
제한해요. 디스크에서 읽은 횟수가 유한하지 않거나 양수가 아니면 버려요.

### 5.6 히스테리시스를 둔 점진 표시

```
shown = (ctx == EN) ? E : K          // "context init": before the first key the display is in the
                                     // context language, so even the first key must beat it by HYST
on every keystroke (and after backspace, recompute from the whole raw):
    scores = prefixModeScores(raw, ctx)
    (best, bestScore) = argmax(scores)
    if shown ∉ scores: shown = best                      // e.g. an M(b) that is no longer valid
    else if best != shown and bestScore − scores[shown] > HYST: shown = best
    display render(raw, shown)
on commit: insert render(raw, finalModeArgmax(raw, ctx, term, userCounts))
render(raw, K) = automaton(raw).text ; render(raw, E) = raw ;
render(raw, M(b)) = raw[0..<b] + automaton(raw[b...]).text
```

`shown`은 단어를 초기화할 때(확정, 취소, 커서 이동) 다시 정해요. 왜 "지금 확정하면 나올 것을
보여 주기" 대신 접두 모드를 쓸까요? 최종 모드로 표시하면 한국어 단어가 단어당 1.18번 바뀌어요
(완성되지 않은 음절이 모두 영어 조각처럼 보이기 때문이에요). 접두 모드는 0.00번이에요(9.3절). 조합 중에
사용자가 바꾸기 키를 누르면 `shown`이 K → E → 가장 좋은 M → K 순서로 돌아요. 그리고 단어는 그 선택으로
고정돼요(확정할 때 그 선택을 쓰고, 적응에서는 바꾸기로 쳐요).

키 입력마다 전체를 다시 계산할 때의 복잡도는 이래요. K와 E에 O(n)번의 LM 호출, M의 라틴
접두에 O(n)(각 위치에서 `</s>`를 붙여 한 번 훑음), 일반 M 꼬리에 O(n²)이에요. n ≤ 20이면
`cond` 호출이 1 000번 미만이에요. 이는 항목 ≤ 1 M개인 배열에서 이진 탐색 ≈ 4 000번이에요. Swift에서는 수십 마이크로초예요.

---

## 6. 매개변수 (튜닝함; 기준 = 모델 파일의 `meta.params`)

dev 데이터만으로 병렬 좌표 하강법(`evaluate.py run --tune`, 2라운드)을 써서 튜닝했어요. 쓴 데이터는
제외한 **dev** 종류(종류 단위, 가중치 ¼), 그리고 kowiki-dev 6 000 + ko-news-dev 6 000 +
en-news-dev 5 000 문장이에요(greedy, 예측한 문맥). `ROLLOVER`/`STRAY`/`HYST`/`USER_UNIT`은 분석으로
정했어요(말뭉치에 이것들을 위한 학습 신호가 없어요. 9.4 참고). 값의 단위는 millinats예요.

| 매개변수 | 값 | 뜻 |
|---|---|---|
| `NG_KO` / `NG_EN` | −3000 / 0 | n-gram("새 단어") 경로의 오프셋 |
| `LEX_KO` / `LEX_EN` | −300 / −600 | 어휘 사전 경로의 오프셋 |
| `ORPHAN` | −6000 | 외톨이 자모 하나당(KO n-gram 경로) |
| `ROLLOVER` / `STRAY` | −1500 / −7000 | QWERTOP가 아닌 키에 Shift가 걸림: Shift한 QWERTOP 키 옆 / 그 밖의 위치(KO) |
| `CASE_LOWER` / `INITCAP` / `ALLCAPS` / `MIXED` / `EXACT` | 0 / −800 / −1500 / −8000 / −300 | EN 대소문자 패턴 |
| `MIX` / `MIX_GENERIC` | −7000 / −12000 | 라틴 + 표에 있는 접미사 / + 아무 한국어 이어짐 |
| `MIX_MIN_LATIN` | 2 (글자) | 이보다 짧은 라틴 부분은 대문자이거나 숫자 뒤일 때 허용. 소문자 한 글자는 표에 있는 접미사만 허용(아래) |
| `MIX_INITIAL` | +6000 | 라틴 대문자 한 글자 + 표에 있는 접미사, EN 문맥 밖(A씨, B급, C가). 2026-11-08에 더함 |
| `TERM_DIGIT_EN` / `TERM_HYPHEN_EN` | +2000 / +5000 | 숫자 / 하이픈으로 끝난 단어 |
| `NUM_UNIT_EN` | +5000 | ctx가 NUM이고 단어가 `numUnitsEn`에 있음 |
| `PRIOR_START_{KO,EN}` | −200 / −1000 | |
| `PRIOR_KO_{KO,EN}` | −200 / −5000 | 한국어(또는 M) 단어 뒤 |
| `PRIOR_EN_{KO,EN}` | −1300 / −200 | 영어 단어 뒤 |
| `PRIOR_NUM_{KO,EN}` | −100 / −3500 | 숫자 바로 뒤 |
| `HYST` | 1500 | 표시 히스테리시스 |
| `USER_UNIT` | 2500 | 사용자 보너스 크기 |

여러 값이 탐색 격자의 끝에 있어요(`PRIOR_KO_EN`, `MIX`, `NG_KO`, `CASE_MIXED`,
`TERM_HYPHEN_EN`). 격자를 넓히면 뉴스 문체에 더 심하게 맞춰질 거예요. 그래서 일부러 그대로 뒀어요.
`PRIOR_KO_EN = −5` nats는 뉴스 글을 반영해요. 뉴스에서는 한국어 단어 뒤에 오는 단어의 98.6 %가
한국어예요. 이 값은 주로 두 읽기 모두 말이 되는 짧은 단어에 영향을 줘요(`go`/해, `so`/내, `to`/새).
애매하지 않은 영어(meeting, deploy, Slack)는 이 값과 상관없이 이겨요(9.2절). 혼합 개발자 채팅 세트에서는
이 값을 −5000…−2300 안에서 어디로 옮겨도 달라지는 게 없어요(모든 값에서 99.86 %).

---

## 7. 런타임 모델 파일 — `duo-model.bin` (DUOM v1)

리틀 엔디언 파일 하나이고, 모든 섹션은 8바이트 정렬이에요. 읽기 전용으로 `mmap`해서 그 자리에서
쓰도록 설계했어요(작은 JSON 섹션 하나 말고는 파싱이 없어요). `Tools/ModelBuilder/build_model.py`가
`Tools/ModelBuilder/out/`에 만들어요. `duo-model.bin`을 앱 번들(`Resources/`)에 복사하세요.

### 7.1 헤더(32바이트)와 디렉터리

| 오프셋 | 타입 | 값 |
|---|---|---|
| 0 | `[4]u8` | `"DUOM"` |
| 4 | `u16` | major = 1(다른 major는 거부함) |
| 6 | `u16` | minor = 0 |
| 8 | `u32` | 섹션 수 `S` |
| 12 | `u32` | 디렉터리 오프셋(= 32) |
| 16 | `u64` | 내용 해시 = 첫 섹션의 오프셋부터 EOF까지 모든 바이트의 FNV-1a-64 |
| 24 | `u64` | 예약(0) |

디렉터리: 48바이트 항목 `S`개예요. 각 항목은 `name [24]u8`(ASCII, NUL로 채움), `offset u64`, `length u64`
(바이트), `elemSize u32`, `count u32`예요.

### 7.2 섹션

| 이름 | 원소 | 내용 |
|---|---|---|
| `meta` | UTF-8 JSON | 매개변수, 코드북, 접미사 표, 대소문자 어휘 사전, 기호 표, 출처 정보(≈ 100 KB) |
| `ko.{n}.key`, `en.{n}.key` | `u32` (n ≤ 5) / `u64` (n = 6) | order n의 묶은 n-gram, 오름차순 정렬(5.1) |
| `ko.{n}.lp`, `en.{n}.lp` | `u8` | `meta.lm.<lang>.lpCodebook["n"]`(Int, millinats)의 인덱스 — `key`와 나란히 놓임 |
| `ko.{n}.bow`, `en.{n}.bow` | `u8` | `meta.lm.<lang>.bowCodebook["n"]`의 인덱스. n < order일 때 있음. 문맥이 아닌 항목은 정확한 0 코드워드를 가리킴 |
| `lexko.key`, `lexen.key` | `u64` | 정규화한 키 문자열(KO는 `kno`, EN은 `low`)의 FNV-1a-64, 정렬함 |
| `lexko.val`, `lexen.val` | `u8` | `meta.lexicon.<lang>.codebook`(ln P(word|lang), millinats)의 인덱스 |

런타임에 쓰는 `meta` 키: `symbols`, `lm.{ko,en}.{order,lpCodebook,bowCodebook,count,keyType}`,
`lexicon.{ko,en}.codebook`, `suffix.full` / `suffix.prefix`(`[String: Int]`, 키는 `kno`
문자열, 예: `"dmf"` = 을, `"goTdjdy"` = 했어요), `caseLexicon`(`[String]`, 정확한 대소문자),
`params`(`[String: Int]`, 6절), `userLog2Millibits`.

FNV-1a-64: `h = 0xcbf29ce484222325; for byte in ascii(s) { h ^= byte; h = h &* 0x100000001b3 }`.
빌더는 각 어휘 사전 안에 충돌이 없는지 확인해요(assert). OOV 단어가 잘못 걸릴(false positive)
확률은 ≈ count / 2⁶⁴예요(무시해도 돼요).

### 7.3 Swift 로딩 스케치

```swift
final class DuoModel: @unchecked Sendable {          // immutable after init -> safe to share
    private let base: UnsafeRawPointer; private let size: Int
    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY); defer { close(fd) }
        var st = stat(); fstat(fd, &st); size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { throw DuoError.map }
        base = UnsafeRawPointer(p)
        guard base.loadUnaligned(as: UInt32.self) == 0x4D4F5544 /* "DUOM" */,
              base.loadUnaligned(fromByteOffset: 4, as: UInt16.self) == 1 else { throw DuoError.version }
        // read directory -> [String: (offset, count)], decode `meta` with JSONDecoder
    }
    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }
    @inline(__always) func find32(_ off: Int, _ count: Int, _ key: UInt32) -> Int? {
        let a = (base + off).assumingMemoryBound(to: UInt32.self)   // sections are 8-byte aligned
        var lo = 0, hi = count
        while lo < hi { let mid = (lo + hi) >> 1; if a[mid] < key { lo = mid + 1 } else { hi = mid } }
        return lo < count && a[lo] == key ? lo : nil
    }
}
```

`Data(contentsOf:options: .alwaysMapped)`도 돼요. 다만 모델이 살아 있는 동안 `Data`를 계속 붙잡아
두세요. 로딩 비용은 `mmap` 한 번 + ≈ 100 KB JSON 디코딩 한 번이에요(< 5 ms). 페이지는 필요할 때
늦게 읽혀요(첫 단어가 ~100 페이지를 건드려요).

### 7.4 배포 모델 (`build_model.py`, 설정 `ship`)

| 부분 | 항목 수 | 바이트 |
|---|---|---|
| KO LM, order 5, θ₄ = 15, θ₅ = 30 | 36 / 858 / 11 418 / 62 520 / 197 597 | 1.44 MB |
| EN LM, order 5, 같은 가지치기 | 36 / 779 / 16 914 / 118 271 / 357 718 | 2.60 MB |
| KO 어휘 사전(상위 100 000 어절을 `kno`로) | 100 000 × (8 + 1) | 0.90 MB |
| EN 어휘 사전(상위 60 000 단어) | 60 000 × (8 + 1) | 0.54 MB |
| meta JSON(매개변수, LM마다 코드북 9개, 접미사 1 684개 + 접두 표, 250개 항목 대소문자 어휘 사전, 단위 56개) | — | 0.15 MB |
| **전체 `duo-model.bin`** | | **5.63 MB**(내용 해시 `aa722069c1e3076e`. 빌드는 결정적임 — 두 번 빌드하면 바이트까지 똑같음) |

키 입력당 연산 수(`bench.py`, 접두 모드에서 모든 가설을 전부 다시 계산함): 이진 탐색이
6(2키 단어) … 106(16키 단어)번이에요. 최종 모드는 13 … 236번이에요. Python 참조 구현은 키 입력당
0.04–0.13 ms가 들어요. Swift는 10 µs보다 훨씬 짧을 거예요. 1 ms 예산 안에서 두 자릿수(order of
magnitude)만큼 여유가 있어서 점진 캐싱은 필요 없어요. 캐싱해도 괜찮아요. `cond`는 `(hist, w)`에만
의존해서, 캐싱해도 같은 정수가 나와요.

---

## 8. 골든 테스트 벡터 — `out/test_vectors.json`

`build_model.py`가 **다시 연 바이너리**(독립된 리더)에서 만들어요. 그래서 이 벡터를 통과하면
알고리즘과 파일 리더가 둘 다 맞다는 게 증명돼요. 모든 숫자는 Int millinats예요.

| 키 | 내용 | Swift 테스트 |
|---|---|---|
| `automaton[]` | `{keys, normalized, text, orphans, trailingLoneConsonant}` — 직접 고른 경계 사례 100개, 자주 쓰는 어절 300개, 무작위 키 문자열 300개(Shift 글자, `'` 포함) | 오토마톤만 |
| `fnv1a64[]` | `{s, hash}`(16진수) | 해시 함수 |
| `lexicon[]` | `{lang, key, value|null}` | 어휘 사전 조회 + 코드북 |
| `lm[]` | `{model, keys, prefix[i], withEos[i]}` — `keys[0..<i]`의 누적 점수, `</s>` 없이 / 넣고 | `cond` / 백오프 / 코드북 |
| `final[]` | `{raw, features{…}, cases[{ctx, term, scores{K,E,M<b>}, best, output}]}` — 혼합 세트의 모든 단어 + 헷갈리는 단어, ctx ∈ START (term S/D/H), KO, EN, NUM | 최종 모드 점수 계산 전체 |
| `incremental[]` | `{raw, ctx, steps[{scores, shown, text}]}` — 키 입력마다의 접두 점수와 히스테리시스 표시 | 접두 점수 계산 + 표시 상태 기계 |
| `apostrophe[]` | `{raw, ctx, scores, internal}` — `raw + "'"`의 접두 점수 | 아포스트로피 규칙(4절) |
| `user[]`, `userBonus` | 사용자 횟수를 넣은 점수 | 적응 |

권장하는 Swift Testing 구성은 키마다 `@Test(arguments:)` 하나예요. 예를 들면 이래요.

```swift
@Test(arguments: Vectors.shared.final)
func finalDecision(_ v: FinalVector) throws {
    for c in v.cases {
        let r = engine.finalScores(raw: v.raw, context: Context(c.ctx), terminator: Terminator(c.term))
        #expect(r.scores == c.scores)          // exact Int equality, no tolerance
        #expect(r.output == c.output)
    }
}
```

---

## 9. 평가 (따로 적지 않으면 모든 숫자는 배포하는 `duo-model.bin`으로 잼)

정확도는 확정한 글자가 의도한 글자와 같은지로 따져요(그래서 `b`가 틀린 `M(b)`는 오류예요).
원본 결과: `Tools/ModelBuilder/out/eval/ship_bin.json`(그리고 `o6_final.json`, `o5p40.json`,
`o4.json`, `ship_tune.json`).

### 9.1 문맥 없는 낱단어 (ctx = START, term = 스페이스, 최종 모드)

| 세트 | 한국어 (K) | 영어 (E) | 라틴+접미사 (M) | 전체, 단어 빈도 가중 |
|---|---|---|---|---|
| 한국어 뉴스, test 절반(812 688 단어) | **99.48 %** (800 994) | **99.44 %** (7 732) | 88.79 % (3 962) | 99.43 % |
| 한국어 위키백과 2021, test 절반(701 072) | 99.85 % | 98.83 % | 84.53 % | 99.75 % |
| 영어 뉴스, test 절반(981 488) | — | **99.89 %** | — | 99.89 % |
| 혼합 개발자 채팅 세트(1 385) | 100 % | 100 % | 100 % | 100 % |
| 제외한 **종류**(LM과 어휘 사전에 없음), 종류 단위 | 99.82 % (110 536 종류) | 98.97 % (51 237 종류) | — | — |
| 제외한 종류, 단어 빈도 가중 | 94.21 % | 99.79 % | — | — |

단어 빈도로 가중한 제외 종류의 K 수치는 아주 자주 쓰는 몇몇 한국어 단어가 좌우해요. 이 단어들은
마침 제외 세트에 들어갔고, n-gram만 있으면 영어처럼 보여요(`ej` 더, `dhs` 온, `rhe` 곧,
`Ehsms` 또는). 실제 제품에서는 이 단어들이 어휘 사전에 있어요. OOV 일반화를 제대로 보여 주는 값은
종류 단위 수치예요. "단어 빈도 가중 ≥ 99 %, 낱단어, 문맥 없음" 목표는 두 언어 모두 달성했어요.
학습에 한 번도 쓰지 않은 문체(뉴스)의 실제 글에서 잰 결과예요.

### 9.2 문맥 있는 이어진 글 (greedy, 문맥 = 엔진이 직접 확정한 것)

| 세트 | 단어 정확도 | K | E | M | 문장 정확도 | 1단어 되돌아보기 | Viterbi(상한) |
|---|---|---|---|---|---|---|---|
| 한국어 뉴스(50 000 문장) | **99.90 %** | 99.95 % | 99.53 % | 89.27 % | 98.50 % | 99.90 % | 99.90 % |
| 한국어 위키백과(50 000) | **99.89 %** | 99.97 % | 99.34 % | 87.57 % | 98.72 % | 99.89 % | 99.89 % |
| 영어 뉴스(50 000) | **99.99 %** | — | 99.99 % | — | 99.72 % | 100.00 % | 100.00 % |
| 혼합 개발자 채팅(417) | **99.86 %** | 100 % | 99.48 % | 100 % | 99.52 % | 99.86 % | 99.86 % |

문맥은 한국어 뉴스 오류의 약 80 %(99.43 % → 99.90 %)와 영어 오류의 90 %(99.89 % → 99.99 %)를
없애요. "정답" 문맥(사용자가 모든 오류를 바로 고침)을 써도 숫자가 소수점 4자리까지 같아요. 그래서
오류가 연쇄되지 않아요. 다음 단어를 확정할 때 이전 단어를 다시 판정해도(되돌아보기, lookback), 문장 전체
Viterbi를 써도 한국어에서는 측정할 만한 이득이 없어요. 그래서 **v1은 이미 확정한 글자를 고치지
않아요**.

남은 오류 유형(한국어 뉴스, 예측한 문맥. 812 k 단어당 횟수):
* 자주 쓰는 영어 단어이기도 한 짧은 한국어 단어: `db`/유 41, `an`/무 34, `eh`/도 32, `to`/새 30,
  `so`/내 28, `al`/미 20, `did`/양 19, `fj`/러 12(모두 ≈ 0.004 %);
* 꼬리가 흔하지 않은 `M`: `H조` / `A조` (`Hwh`) 18+5, `m로`(`mfh`, 숫자 뒤 단위) 11,
  `A군은`을 `Arns`+은으로 나눔 11, `SK하이닉스는`을 한국어로 읽음 10.

혼합 개발자 채팅 오류는 딱 두 개예요. `그거 so good`(so → 내)과 `그럼 go 하시죠`(go → 해)예요. 이건
이 제품이 안고 가야 하는 본질적인 애매함이에요. 바꾸기 한 번이면 그 사용자에게는 그다음부터 계속 고쳐져요(5.5).

요청받은 헷갈리는 쌍(차이 `S_E − S_K`, 단위 nats, 최종 모드. 양수 = 영어가 이김):

| raw | 한국어 읽기 | START | 한국어 뒤 | 영어 뒤 |
|---|---|---|---|---|
| `go` | 해 | +0.47 → go | −3.53 → 해 | +2.37 → go |
| `so` | 내 | +1.05 → so | −2.95 → 내 | +2.95 → so |
| `to` | 새 | +3.78 → to | −0.22 → 새 | +5.68 → to |
| `do` | 애 | +3.73 → do | −0.27 → 애 | +5.63 → do |
| `and` | 뭉 | +15.2 | +11.2 | +17.1 |
| `the` | 솓 | +15.8 | +11.8 | +17.7 |
| `ok` / `OK` | ㅐㅏ / ㅒㅏ | +32.9 / +33.5 | +28.9 / +29.5 | +34.8 / +35.4 |
| `an` | 무 | +4.77 | +0.77 → an | +6.67 |
| `ah` | 모 | +2.19 | −1.81 → 모 | +4.09 |
| `dkssud` / `gksrmf` | 안녕 / 한글 | −28.4 / −26.8 | −32.4 / −30.8 | −26.5 / −24.9 |
| `rk` / `dl` / `sk` | 가 / 이 / 나 | −7.7 / −6.5 / −4.9 | −11.7 / −10.5 / −8.9 | −5.8 / −4.6 / −3.0 |

정말로 다투는 것은 두 글자 기능어뿐이에요. 한국어 읽기에 외톨이가 있는 단어(`ok`, `in`, `it`,
`we`, `no`, `hi`, …)는 모두 28–46 nats 차이로 정해져요.

### 9.3 점진 표시 (접두 모드 + 히스테리시스, `HYST` = 1.5 nats, 문맥 초기화)

단어 빈도로 가중해 표본을 뽑았고, 행마다 1 000–3 000 단어예요. *바뀜* = 단어당 표시가 바뀐 횟수예요.
*표시 정확도* = 표시가 최종적으로 의도한 읽기와 맞는 키 입력의 비율이에요
(`M(b)`는 접미사가 시작되기 전에 E를 보여 주면 맞은 것으로 쳐요). *놀람* = 확정한 글자가
확정 바로 전에 보이던 것과 다른 경우예요.

| 친 단어 | 문맥 | 바뀜 / 단어 | 바뀜이 있는 단어 | 표시 정확도 | 확정 놀람 |
|---|---|---|---|---|---|
| 한국어 뉴스 속 한국어 단어 | KO | **0.000** | 0.0 % | 100.0 % | 0.0 % |
| 영어 뉴스 속 영어 단어 | EN | **0.012** | 0.8 % | 99.7 % | 0.07 % |
| 문장의 첫 영어 단어 | START | 0.46 | 45.8 % | 82.3 % | 7.6 % |
| 한국어 뉴스 속 라틴 단어(약어, M) | KO | 0.54 | 45.5 % | 80.2 % | 5.7 % |
| 혼합 개발자 채팅 세트 | START→이어짐 | 0.20 | 16.9 % | 96.2 % | 2.0 % |

정책 비교:
* **최종 모드 표시**(지금 확정하면 나올 것을 보여 줌): 한국어 1.18 바뀜/단어, 혼합 1.21 —
  채택하지 않음.
* **argmax 초기화**(첫 키에서 문맥 언어 대신 raw argmax를 보여 줌): 영어 문맥 속 영어의
  바뀜이 단어당 0.012에서 0.083으로 늘어남(첫 자음이 자모로 보였음) — 채택하지 않음.
* **히스테리시스 훑어보기**(바뀜 / 확정 놀람):

| HYST (nats) | KO 속 한국어 | EN 속 영어 | KO 속 라틴 | START의 영어 | 혼합 |
|---|---|---|---|---|---|
| 0 | 0.000 / 0 % | 0.087 / 0 % | 0.55 / 4.8 % | 0.48 / 3.4 % | 0.27 / 1.9 % |
| 1.0 | 0.000 / 0 % | 0.020 / 0 % | 0.55 / 5.1 % | 0.47 / 7.8 % | 0.20 / 1.8 % |
| **1.5** | 0.000 / 0 % | 0.014 / 0 % | 0.54 / 5.5 % | 0.47 / 7.6 % | 0.19 / 1.8 % |
| 2.5 | 0.000 / 0 % | 0.007 / 0 % | 0.73 / 12.9 % | 0.49 / 8.0 % | 0.19 / 1.8 % |
| 4.0 | 0.000 / 0 % | 0.000 / 0 % | 0.74 / 14.6 % | 0.47 / 11.1 % | 0.18 / 2.2 % |

흔한 바뀜은 한 방향이고 일찍 일어나요. `t → ㅅ, th → 소, the → the`; `p → p, pending → pendingㅇ →
pending으 → pending을 → pending으로`(MIX가 자연스럽게 자라요); `C → Ch → … → ChatGPT한테`.
UX 권장 사항: 조합 문자열은 표준 밑줄로만 그리세요. 읽기가 바뀔 때는 짧은(≈ 120 ms) 크로스페이드를
넣으세요. 그러면 바뀜이 깜빡임이 아니라 "키보드가 알아들었다"로 느껴져요.

### 9.4 견고성

* **Shift 롤오버**: 한국어 뉴스 단어 17 831개를 Shift를 오래 누르거나 일찍 눌러 다시 침
  (예: `dLTek` 있다, `gkTDj` 핬어). **100 %** 여전히 의도한 한국어로 확정됨. 한국어 단어 뒤에 오는
  대문자 영어 단어(`Slack`, `GitHub`, `CCTV`): 99.88 %.
* **한 단어 안의 한글 + 라틴**(`카톡ID`): 지원 안 함. 한국어 뉴스 단어의 0.045 %.

### 9.5 제거 실험과 모델 크기 곡선 (단어 정확도, 이어진 글, greedy)

| 변형 | 한국어 뉴스 | 영어 뉴스 | 혼합 |
|---|---|---|---|
| **배포판** | **99.90 %** | **99.99 %** | **99.86 %** |
| 어휘 사전 없음(n-gram만) | 99.77 % | 99.99 % | 98.99 % |
| 외톨이 벌점 없음 | 99.89 % | 99.98 % | 99.86 % |
| `M(b)` 가설 없음 | 99.79 % | 99.99 % | 98.70 % |
| 대소문자 / Shift 모델 없음 | 99.79 % | 99.96 % | 99.78 % |
| 문맥 사전 확률 없음 | 99.44 % | 99.97 % | 100.0 % |

| LM 설정(같은 매개변수, 어휘 사전 100 k / 60 k) | 파일 크기 | 한국어 뉴스 | 한국어 위키 | 영어 뉴스 | 혼합 | 제외 종류 K / E |
|---|---|---|---|---|---|---|
| order 6, 가지치기 없음 | ≈ 26 MB | 99.91 % | 99.90 % | 99.99 % | 99.78 % | 99.83 / 99.14 % |
| **order 5, θ 15/30 (배포판)** | **5.63 MB** | 99.90 % | 99.89 % | 99.99 % | 99.86 % | 99.82 / 98.97 % |
| order 5, θ 40/80 | ≈ 4.8 MB | 99.90 % | 99.90 % | 99.98 % | 99.78 % | 99.83 / 99.01 % |
| order 4, 가지치기 없음 | ≈ 2.9 MB | 99.90 % | 99.89 % | 99.98 % | 99.78 % | 99.83 / 99.15 % |

정확도의 대부분은 어휘 사전, `M(b)`, 문맥 사전 확률에서 나와요. n-gram order는 4를 넘으면 거의
상관없어요(0.01 pt 차이는 혼합 세트에서 단어 1–2개예요). order 5를 배포하는 이유는 긴 단어에서 접두(표시)
추정이 조금 더 좋기 때문이에요. 번들 크기가 문제가 되면 order 4(≈ 2.9 MB)로 그대로 바꿔 끼울 수 있어요.
형식은 같고, `order_ko=4, order_en=4`로 다시 빌드하면 돼요.

---

## 10. 권장 사항, 한계, 다음 단계

1. **바꾸기 키 + 학습은 덤이 아니라 알고리즘의 일부임.** 개발자 채팅 오류 두 개와 뉴스 오류
   대부분은 두 글자 체계 모두에서 말이 되는 두 글자 단어임. 바꾸기 키를 눈에 띄게 만들고(예:
   Shift+Space나 전용 키. 디자인 트랙이 정함) 바꾸기를 가중치 3으로 기록할 것(5.5).
2. **적응형 문맥 사전 확률(v1.1)**: 최근 ~5 000번의 확정에서 사용자별 `(previous language → language)`(이전 언어 → 언어) 횟수를
   기록하고
   `PRIOR[c][L] = round(1000·ln((n[c→L] + 20·p₀[c][L]) / (n[c] + 20)))`를 씀. `p₀ = exp(PRIOR/1000)`은
   배포 매개변수에서 가져옴(재정규화함). 그러면 언어를 자주 섞어 쓰는 사람도 `go`, `so`, `to`를 맞게 받음.
   테스트 벡터에는 없음. 기능 플래그 뒤에 둘 것.
3. **확정한 글자를 다시 쓰지 말 것**(되돌아보기는 한국어에서 +0.00 pt, 영어에서 +0.01 pt였음).
4. **Caps Lock** = ABC 그대로 통과. **Option을 함께 누른 키**와 ⌘/⌃를 함께 누른 키는
   단어에 들어가지 않음(먼저 확정함).
5. 알려진 약점: 라틴 약어 + 드문 한국어 합성어(`SK하이닉스는`, `M` 단어 전체에서 89 %),
   영어로 친 외국 이름 중 그럴듯한 한국어 꼬리가 있는 것(`Swiatek` → Swiat+다, 981 k 중 3개),
   한국어 글 속 한 글자(`Z`, `R&D`).
6. 데이터 갱신: 한국어 쪽은 자막 48 % / 위키백과 52 %임. 라이선스가 확실한 채팅/사무 문체
   말뭉치가 가장 도움이 될 것임(Leipzig 뉴스는 라이선스를 확인할 수 없어서 제외한 테스트 세트로만
   썼음).
7. 개인 정보: 사용자 횟수는 기기 안(`~/Library/Application Support/Duo/`)에만 둠. 사용자가 명시적으로
   동의하지 않으면 절대 동기화하지 않음. 디버깅을 위해 로그를 내보내야 하면 `raw`의 해시를 저장할 것.

---

## 11. 재현

```bash
cd Tools/ModelBuilder
# 1. data (≈ 200 MB) -> Tools/data/raw/   (see section 2 for URLs; all downloaded with curl)
# 2. evaluation sets
python3 -I evaluate.py prepare
# 3. tune (writes out/eval/<config>_params.json); copy to params.json to ship it
python3 -I evaluate.py run --config ship --tune --params params.json --flicker --ablate --tag ship_tune
# 4. build the model + vectors (≈ 45 s)
python3 -I build_model.py                     # -> out/duo-model.bin, out/test_vectors.json, out/model_card.json
# 5. evaluate the binary itself
python3 -I evaluate.py run --config ship --binary out/duo-model.bin --params params.json --flicker --ablate --tag ship_bin
python3 -I bench.py out/duo-model.bin         # operation counts
python3 -I hangul.py                          # automaton self-test
```

파일: `hangul.py`(오토마톤), `kn.py`(modified Kneser-Ney, 가지치기), `detector.py`(런타임
알고리즘, 정수 참조 구현), `model_data.py`(데이터 조립), `corpora.py`(로더. 최소한의
msgpack 리더도 들어 있음), `evaluate.py`, `build_model.py`, `bench.py`, `params.json`, `data/*.txt`(직접 고른 목록
+ 혼합 테스트 세트). 내려받기 URL:
`https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/{ko/ko_full,en/en_full}.txt`,
`https://raw.githubusercontent.com/rspeer/wordfreq/master/wordfreq/data/large_en.msgpack.gz`,
`https://dumps.wikimedia.org/kowiki/latest/kowiki-latest-pages-articles1.xml-p1p82407.bz2`,
`https://downloads.wortschatz-leipzig.de/corpora/{kor_news_2022_100K,kor_wikipedia_2021_100K,eng_news_2023_100K}.tar.gz`.
kowiki 조각은 `corpora.kowiki_counts`가 처리해서 `Tools/data/raw/kowiki/kowiki_counts.tsv`와
`kowiki_mix.tsv`로 만들어요(git 기록에 있는 한 줄 명령 / 2절 참고).
