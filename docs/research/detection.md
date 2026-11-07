# Duo — Korean/English language detection: algorithm, data, model format

Status: research track deliverable (prototype in `Tools/ModelBuilder/`, Python 3.12, stdlib only).
Owner paths: `Tools/ModelBuilder/` (scripts, curated data, outputs in `out/`), `Tools/data/raw/` (downloaded corpora, gitignored).

## TL;DR

* **Hypotheses per word**: Korean (`K`, 두벌식 automaton), English (`E`, keys as typed), and
  **Latin word + attached Korean** (`M(b)`: `PR을`, `iOS에서`, `push했어요`, `LG전자`). Korean attaches
  particles to Latin words with no space, so this third reading is needed: removing it costs 1.2 pt on
  dev-chat text.
* **Model**: two order-5 modified-Kneser-Ney character LMs over a shared 37-symbol keystroke
  alphabet (Korean as 두벌식 keystrokes, `Q W E R T O P` = shifted jamo), plus top-100 k Korean eojeol /
  top-60 k English lexicons, orphan-jamo penalty, shift/case model, 1 684 Latin-attached suffixes,
  context prior (START / KO / EN / NUM), terminator cue and per-user counts. These are combined as an
  integer log-linear score in millinats, so the Swift port can be **bit-exact**.
* **Measured** on the shipped 5.63 MB file, on registers never used in training:
  * single words, no context: Korean 99.48 %, English-in-Korean-text 99.44 %, English news 99.89 %
  * running text with context: Korean news **99.90 %**, Korean Wikipedia **99.89 %**, English news
    **99.99 %**, hand-written mixed dev-chat set **99.86 %** (2 errors: `so`, `go`)
  * display: Korean words never flicker (0.000 flips/word); English in English context 0.012
    flips/word; 100 % robust to Shift-rollover typos.
* **Runtime format**: one mmap-able little-endian file `duo-model.bin` (DUOM v1: sorted packed
  n-gram keys u32/u64, u8 codebook indices, FNV-1a-64 lexicon hashes, small JSON meta). Each keystroke
  costs 6–106 binary searches (well under 10 µs in Swift).
* **Golden vectors**: `Tools/ModelBuilder/out/test_vectors.json` (696 automaton cases, 1 069 final
  decisions × 6 contexts, 642 incremental traces, LM/lexicon/hash/apostrophe/user vectors). Section 8 has the details.
* **License**: the model is derived from CC-BY-SA-4.0 data (OpenSubtitles via FrequencyWords, Korean
  Wikipedia, wordfreq), so ship it with attribution under CC-BY-SA-4.0 (section 2).

---

## 1. Problem statement and hypothesis space

The engine sees the keystrokes of the current word as the string the **ABC (US) layout would have
produced**: lowercase letter = unshifted key, uppercase letter = Shift+key. `PRdmf` means
Shift+P, Shift+R, d, m, f. This string (`raw`) is the only input to detection; the two
interpretations are derived from it:

| hypothesis | rendered text | example raw → text |
|---|---|---|
| `K` (Korean) | 두벌식 automaton applied to `raw` (section 3) | `dkssud` → 안녕 |
| `E` (English) | `raw` itself (case as typed) | `meeting` → meeting |
| `M(b)` (Latin word + attached Korean, 1 ≤ b < len) | `raw[0..<b]` + automaton(`raw[b...]`) | `PRdmf` → PR을, `pushgoTdjdy` → push했어요, `LGwjswk` → LG전자 |

`M(b)` exists because Korean attaches particles/endings directly to Latin words with **no space**
(`PR을`, `API를`, `iOS에서`, `merge해주세요`, `A씨는`, `LG화학`). In Korean news 1.44 % of tokens
contain Latin letters and **34 % of those carry an attached Korean suffix** — a pure per-word K/E
switch would get every one of them wrong. Hangul followed by Latin inside one token (`카톡ID`) is
not supported (0.045 % of Korean-news tokens).

The detector produces, for every hypothesis, an integer log-score (millinats = 1/1000 natural-log
unit). Two scoring modes exist:

* **final mode** — used when the word is committed (space, punctuation, digit, Return, focus loss):
  the word is complete (`</s>` scored, lexicon used).
* **prefix mode** — used after every keystroke for the marked-text display: the word may continue
  (no `</s>`, no lexicon; probability of all words that start with these keys).

All arithmetic is integer (`Int32` is sufficient; Swift should use `Int`), so the Swift port can be
**bit-exact** with `Tools/ModelBuilder/out/test_vectors.json`.

---

## 2. Data sources and licenses

| corpus | used for | size | license | file(s) in `Tools/data/raw/` |
|---|---|---|---|---|
| hermitdave/FrequencyWords, OpenSubtitles 2018 `ko_full` | KO training (spoken register, eojeol tokens) | 688 129 types / 6.33 M tokens (660 810 Hangul types) | content **CC-BY-SA-4.0**, code MIT | `fw_ko_full.txt`, `fw_ko_50k.txt` |
| Korean Wikipedia dump, chunk 1 (`kowiki-latest-pages-articles1.xml-p1p82407.bz2`, 94 MB) | KO training (written register) | 1.39 M Hangul eojeol types / 14.3 M tokens (types with count ≥ 2 used) | **CC-BY-SA-4.0** (Wikimedia) | `kowiki/` |
| hermitdave/FrequencyWords `en_full` | EN training (spoken) | 1.66 M types / 735 M tokens (count ≥ 3, `^[a-z]+('[a-z]+)*$`) | **CC-BY-SA-4.0** | `fw_en_full.txt`, `fw_en_50k.txt` |
| rspeer/wordfreq 3.x `large_en.msgpack.gz` | EN training (web, Wikipedia, news, subtitles, Reddit, Twitter mix) | 321 180 words, centibel buckets | data **CC-BY-SA-4.0** (code Apache-2.0); project is sunset (no updates) | `wordfreq/` |
| Leipzig Corpora Collection `kor_news_2022_100K`, `kor_wikipedia_2021_100K`, `eng_news_2023_100K` | **evaluation only** (held-out register, real sentences with case, digits, punctuation, Latin-in-Korean) | 100 k sentences each (1.63 M / 1.40 M / 1.96 M letter tokens) | LCC terms of use (site is behind an anti-bot wall, could not be re-verified; treat as research/eval-only, **do not ship anything derived from it**) | `lcc_*/` |
| Peter Norvig `count_1w.txt` | not used (inspected only) | 333 k words | derived from Google Web 1T (LDC) — **redistribution status unclear, do not ship** | `norvig_count_1w.txt` |
| project-authored lists | tech terms with canonical case, chat jamo, Latin-attached suffixes, mixed test set | see `Tools/ModelBuilder/data/` | project (CC0) | — |

Rejected: wordfreq `ko` (it is **MeCab-tokenised** into morphemes, but users type eojeols),
Norvig (license), Leipzig for training (license unverifiable).

**Shipping obligation**: the model file is an adaptation of CC-BY-SA-4.0 data, so `duo-model.bin`
must be distributed under CC-BY-SA-4.0 with attribution ("Contains information from
OpenSubtitles2018 via FrequencyWords by Hermit Dave, Korean Wikipedia, and wordfreq by Robyn Speer,
CC-BY-SA 4.0"). This does **not** affect the app's code license; put the notice in the About
window / acknowledgements and next to the resource in the repo.

### Training mixtures (see `model_data.py`)

* **Korean**: `count(w) = 2 × OpenSubtitles(w) + kowiki(w)` over pure-Hangul eojeols that survive the
  keys→Hangul round trip and consist of complete syllables only (jamo-only corpus tokens such as `ㄲ`, `ㄷ` are stutter noise and were dropped) — 1 104 134 types, 26.3 M pseudo-tokens, 48 % subtitles / 52 % Wikipedia — plus 32 chat-jamo tokens
  (`ㅋㅋ`, `ㅎㅎ`, `ㅠㅠ`, `ㅇㅋ`, `ㄱㄱ` …, `data/ko_chat.txt`, given per-million rates).
* **English**: OpenSubtitles(count ≥ 3) + wordfreq scaled to the same total (509 482 types),
  plus 260 tech/office terms (`data/en_terms.txt`: API, PR, iOS, macOS, GitHub, Slack, Figma, LGTM …)
  at 50 / 10 / 2 per million by tier. Canonical-case forms (iOS, GitHub, API) form the **case lexicon**.
* **Suffixes after Latin**: Hangul tails of `^[A-Za-z]+[가-힣]+$` tokens in kowiki (74 k tokens) and
  OpenSubtitles (×5), plus `data/suffix_extra.txt` (dev-chat endings: 해주세요, 했습니다, 할게요 …);
  suffixes with pseudo-count ≥ 5 kept → 1 684 suffixes.

### Evaluation sets (`evaluate.py prepare`)

* **Held-out types** — 10 % of word types (CRC32(word) % 10 == 0) of the training mixtures, never
  seen by the n-grams or the lexicon of the `train`-split model. Measures OOV generalisation.
* **Cross-corpus** — Leipzig sentences, even lines = dev, odd lines = test. Every token is typed
  exactly as written (case, digits as boundaries, `’` → `'`). Gold label from script:
  Hangul → K, Latin → E, Latin+Hangul → M(b).
* **Mixed dev-chat set** — `data/mixed_sentences.txt`, 417 hand-written sentences / 1 385 tokens
  typical of Korean developers and office workers ("PR을 올렸는데 CI가 깨졌네요", "push했어요 확인해 주세요",
  "Thank you so much", "ㅋㅋ 그러게요"). Test only, never tuned on.
* **Rollover noise** — Korean news words re-typed with Shift held too long (P = 0.3 on the key after a
  shifted QWERTOP key) or pressed too early (P = 0.1 on the key before).

---

## 3. 두벌식 automaton (normative; `hangul.py`)

Key map (KS X 5002):

```
q ㅂ  w ㅈ  e ㄷ  r ㄱ  t ㅅ  y ㅛ  u ㅕ  i ㅑ  o ㅐ  p ㅔ
a ㅁ  s ㄴ  d ㅇ  f ㄹ  g ㅎ  h ㅗ  j ㅓ  k ㅏ  l ㅣ
z ㅋ  x ㅌ  c ㅊ  v ㅍ  b ㅠ  n ㅜ  m ㅡ
Shift: Q ㅃ  W ㅉ  E ㄸ  R ㄲ  T ㅆ  O ㅒ  P ㅖ ; every other shifted letter = its unshifted jamo
```

**Korean normalisation** `kno = koreanNormalize(raw)`: every uppercase letter whose lowercase is not
in `{q,w,e,r,t,o,p}` is lowercased; everything else unchanged. (So `Hello` → `hello`, `PRdmf` stays.)

State = (cho, jung, jong), each possibly empty; `out` = emitted characters; `orphans` = number of
compatibility jamo emitted. `flush()`: if cho and jung → emit syllable `U+AC00 + (cho·21 + jung)·28 + jong`;
else if only cho or only jung → emit that compatibility jamo and `orphans += 1`; clear state.

Consonant C:
1. state has cho and jung:
   * no jong: if C ∈ {ㄸ, ㅃ, ㅉ} → flush, cho = C; else jong = C.
   * jong set: if (jong, C) ∈ FINAL_COMBINE → jong = combined; else flush, cho = C.
2. otherwise (empty / cho only / vowel only): flush, cho = C.  *(consonants never combine without a vowel: r t → ㄱㅅ)*

Vowel V:
1. jong set (도깨비불): if jong is compound (ㄳ ㄵ ㄶ ㄺ ㄻ ㄼ ㄽ ㄾ ㄿ ㅀ ㅄ) → jong = first part, moved = second
   part; else moved = jong, jong = ∅. flush; cho = moved; jung = V.
2. jung set (no jong): if (jung, V) ∈ VOWEL_COMBINE → jung = combined; else flush, jung = V (cho empty → orphan vowel).
3. otherwise (empty or cho only): jung = V.

`VOWEL_COMBINE`: ㅗ+ㅏ=ㅘ, ㅗ+ㅐ=ㅙ, ㅗ+ㅣ=ㅚ, ㅜ+ㅓ=ㅝ, ㅜ+ㅔ=ㅞ, ㅜ+ㅣ=ㅟ, ㅡ+ㅣ=ㅢ (applies with or without cho; `hk` → ㅘ).
`FINAL_COMBINE`: ㄱ+ㅅ=ㄳ, ㄴ+ㅈ=ㄵ, ㄴ+ㅎ=ㄶ, ㄹ+ㄱ=ㄺ, ㄹ+ㅁ=ㄻ, ㄹ+ㅂ=ㄼ, ㄹ+ㅅ=ㄽ, ㄹ+ㅌ=ㄾ, ㄹ+ㅍ=ㄿ, ㄹ+ㅎ=ㅀ, ㅂ+ㅅ=ㅄ.
ㄲ and ㅆ are single keys (R, T) and therefore simple finals (있+ㅓ → 이써).
Apostrophe (the only non-letter allowed inside a token): flush, emit `'` literally.

Outputs used by detection: `text`, `orphans` = orphans emitted + (1 if the pending state is cho-only
or jung-only), `trailingLoneConsonant` = pending state is cho-only. Rendering of the pending block
does not flush (display shows the composing syllable).

Examples (all in the test vectors): `ekfrrhrl` 닭고기, `rkqtdl` 값이, `rkqtl` 갑시, `sjrtl` 넉시,
`dlTdj` 있어, `goTtmqslek` 했습니다, `rkE` 가ㄸ, `rkk` 가ㅏ, `zzz` ㅋㅋㅋ, `rt` ㄱㅅ, `hk` ㅘ, `Ehrqo` 똑배.
Backspace in the engine = drop the last keystroke and recompute (each key is one jamo, so this is
jamo-wise deletion and matches what Korean users expect, e.g. 과 → 고).

---

## 4. Tokenisation and engine integration rules

* A **token** is a maximal run of `[A-Za-z]` keystrokes, optionally with internal apostrophes. Any
  other key (space, Return, Tab, digit, punctuation including `-`, arrows, mouse click, focus change)
  is a **boundary**: it commits the token (final mode) and is then handled normally.
* **Apostrophe rule**: when `'` is typed after a non-empty token, compute the prefix-mode scores of
  `raw + "'"` (the KO LM gives `'` a tiny probability after Korean keys; `M(b)` is disabled for tokens
  containing `'`). If the argmax is `E`, the apostrophe becomes part of the token (`don't`, `it's`,
  `didn't`, `she's`; margins +10…+50 nats), and `shown` becomes `E`. Otherwise commit the token
  (final mode, without the apostrophe) and output `'` literally (`'사랑'이라는`: `tkfkd'` → K by
  −9…−15 nats). A token never starts with `'`. This beats "append iff E is currently shown", which fails
  for `didn`/`she` after a Korean word because `야우` and `녿` are valid syllables. Vectors: `apostrophe[]`.
* **Caps Lock on** → bypass detection, behave like the ABC layout (matches macOS' own Korean IME).
* **Context state** `ctx` for the next token:
  `START` at the beginning of the field, after `.` `!` `?` newline, and after any cursor movement /
  focus change; `NUM` if the character immediately before the token is a digit (`3개`, `10mm`, `20th`);
  otherwise `KO` if the previous committed token was `K` or `M(b)`, `EN` if it was `E`.
  Spaces, commas, quotes, brackets keep the previous context.
* **Terminator** `term` (final mode only) = the boundary key that ended the token: `S` (space,
  Return, end), `D` (digit: `Q1`, `iOS17`), `H` (hyphen: `co-founder`, `e-mail`), `P` (other punctuation).
* Display: the marked text shows `render(raw, shown)` (section 5.6). Commit inserts
  `render(raw, final)` and records it for user adaptation.

---

## 5. Scoring (normative; `detector.py`)

### 5.1 Symbol alphabet (shared by both language models)

| id | symbol | | id | symbol |
|---|---|---|---|---|
| 0 | pad (never stored) | | 3…28 | `a`…`z` |
| 1 | `<s>` | | 29…35 | `Q W E R T O P` (shifted; produced only by Korean normalisation) |
| 2 | `</s>` | | 36 | `'` |

`V = 35` predictable symbols (ids 2…36). An n-gram (s₀ … sₙ₋₁) is **packed** as
`key = Σ sᵢ << 6·(n−1−i)` (oldest symbol in the high bits); orders ≤ 5 fit in `UInt32`, order 6 needs `UInt64`.

The KO LM reads `kno` (section 3), the EN LM reads `low = raw.lowercased()`.

### 5.2 Character n-gram LMs

Training (`kn.py`): interpolated **modified Kneser-Ney** (Chen & Goodman; three discounts per order
from count-of-counts of the adjusted counts, KenLM conventions: one `<s>`, n-grams starting with
`<s>` and highest-order n-grams use raw counts, others use continuation counts; unigram interpolated
with uniform 1/V), word types weighted by their token frequency, then converted to backoff form
(`lp(h,w) = ln P_interp(w|h)`, `bow(h) = ln γ(h)`), pruned by weighted difference
`count(h,w)·(ln P(w|h) − ln(bow(h)·P(w|h′))) < θₙ` with prefix closure and exact backoff
re-normalisation, and quantised with a 256-entry Lloyd-Max codebook per (model, order, field)
(the bow codebook always contains exact 0).

Runtime conditional log-probability — **this is the only LM operation**:

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

`find` = binary search in the sorted key array of that order. The unigram table also contains key
`1` (`<s>`) whose only purpose is to carry `bow(<s>)`.

### 5.3 Per-token features

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

### 5.4 Hypothesis scores

`word(lm, lex, ng, lx) = lex == nil ? lm + ng : max(lm + ng, lex + lx)` (max = Viterbi
approximation of the mixture "in-lexicon word or novel word", keeps integer arithmetic).

**Final mode**

```
S_K = word(scoreKO(kno, eos) + ORPHAN·orph, lexKO[kno], NG_KO, LEX_KO)
      + ROLLOVER·nr + STRAY·ns + PRIOR[ctx].KO
S_E = word(scoreEN(low, eos), lexEN[low], NG_EN, LEX_EN)
      + CASE[casePattern(raw)] + (term == D ? TERM_DIGIT_EN : term == H ? TERM_HYPHEN_EN : 0)
      + PRIOR[ctx].EN + (ctx == NUM && low ∈ numUnitsEn ? NUM_UNIT_EN : 0)
for b in 1 ..< len(raw), only if raw contains no apostrophe:
    lat = raw[0..<b];  ks = kno[b...]
    shortOK = (b >= MIX_MIN_LATIN) || lat is all uppercase ;  if !shortOK && ctx != NUM: skip
    suf = suffixFull[ks]                                         // optional
    gen = (lat has an uppercase letter || lexEN[low[0..<b]] != nil)
          && ks[0] is a consonant key (qwertasdfgzxcvQWERT)
          && orphans(automaton(ks)) == 0      ? scoreKO(ks, eos) : nil
    if suf == nil && gen == nil: skip
    tail = max over present of { suf + MIX , gen + MIX_GENERIC }
    S_M(b) = word(scoreEN(low[0..<b], eos), lexEN[low[0..<b]], NG_EN, LEX_EN)
             + CASE[casePattern(lat)] + tail
             + ROLLOVER·nr(raw[b...]) + STRAY·ns(raw[b...])       // shiftCounts on the substring
             + PRIOR[ctx].EN
```

**Prefix mode** (display): identical except
`S_K = scoreKO(kno, no eos) + ORPHAN·(orph − (lone ? 1 : 0)) + ROLLOVER·nr + STRAY·ns + PRIOR[ctx].KO`
(no lexicon, no NG/LEX offsets), `S_E = scoreEN(low, no eos) + CASE[…] + PRIOR[ctx].EN`
(+ `NUM_UNIT_EN` as in final mode; no lexicon/offsets/terminator), and for `M(b)` the table is `suffixPrefix` (ln of the summed probability
of all suffixes starting with `ks`) and `gen` uses `scoreKO(ks, no eos)` with the trailing lone
consonant not counted as an orphan. The Latin part of `M(b)` is always scored complete (with `</s>`).

**Decision**: candidates are enumerated in the order `K, E, M(1), M(2), …`; the winner is the first
candidate with the strictly greatest score (ties → earlier).

### 5.5 User adaptation (per-user, on-device)

Store `userCounts[raw] = {K: n, E: n, M<b>: n}` (key = exact raw keystroke string, case-sensitive).
On commit, increment the committed hypothesis by 1; on a **manual flip** (user presses the flip key on
a committed or composing word) increment the chosen hypothesis by 3 (and do not decrement others).
In final mode add `userBonus(n) = (USER_UNIT · USER_LOG2[min(n, 15)]) / 1000` (integer division,
`USER_LOG2[n] = round(1000·log2(1+n))` = 0, 1000, 1585, 2000, 2322, 2585, 2807, 3000, 3170, 3322,
3459, 3585, 3700, 3807, 3907, 4000) to each hypothesis' score. With `USER_UNIT = 2500` one flip
(n = 3) is worth +5.0 nats, enough to override the typical margin of an ambiguous short word
(`go`/해 ≈ 2–4 nats). Cap the store (e.g. LRU 20 000 entries) and expose "Reset learned words".
Duo evicts down to 95 % of the cap (19 000) when it is exceeded, caps each count at 1000 votes and each
raw at 64 UTF-8 bytes, and drops non-finite or non-positive counts read from disk.

### 5.6 Incremental display with hysteresis

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

`shown` is re-initialised when the token is reset (commit, cancel, cursor move). Why prefix mode and
not "show what a commit would produce now": with final-mode display Korean words flip 1.18× per word
(every incomplete syllable looks like an English fragment), prefix mode gives 0.00 flips (section 9.3). If the user presses the flip
key while composing, `shown` cycles K → E → best M → K and the token is locked to that choice
(the commit then uses it, and counts as a flip for adaptation).

Complexity per keystroke with full recomputation: O(n) LM calls for K and E, O(n) for the Latin
prefixes of M (one pass with `</s>` at each position), O(n²) for the generic M tails. For n ≤ 20 this
is < 1 000 `cond` calls ≈ 4 000 binary searches in ≤ 1 M-entry arrays — tens of microseconds in Swift.

---

## 6. Parameters (tuned; source of truth = `meta.params` in the model file)

Tuned by parallel coordinate descent (`evaluate.py run --tune`, 2 rounds) on dev data only:
held-out **dev** types (type-level, weight ¼), 6 000 kowiki-dev + 6 000 ko-news-dev + 5 000
en-news-dev sentences (greedy, predicted context). `ROLLOVER`/`STRAY`/`HYST`/`USER_UNIT` were set by
analysis (no training signal for them in the corpora; see 9.4). Values in millinats.

| param | value | meaning |
|---|---|---|
| `NG_KO` / `NG_EN` | −3000 / 0 | offset of the n-gram ("novel word") path |
| `LEX_KO` / `LEX_EN` | −300 / −600 | offset of the lexicon path |
| `ORPHAN` | −6000 | per orphan jamo (KO n-gram path) |
| `ROLLOVER` / `STRAY` | −1500 / −7000 | Shift on a non-QWERTOP key next to a shifted QWERTOP key / elsewhere (KO) |
| `CASE_LOWER` / `INITCAP` / `ALLCAPS` / `MIXED` / `EXACT` | 0 / −800 / −1500 / −8000 / −300 | EN case pattern |
| `MIX` / `MIX_GENERIC` | −7000 / −12000 | Latin + suffix from the table / + any Korean continuation |
| `MIX_MIN_LATIN` | 2 (letters) | shorter Latin parts only if uppercase, or after a digit |
| `TERM_DIGIT_EN` / `TERM_HYPHEN_EN` | +2000 / +5000 | token ended by a digit / hyphen |
| `NUM_UNIT_EN` | +5000 | ctx NUM and token in `numUnitsEn` |
| `PRIOR_START_{KO,EN}` | −200 / −1000 | |
| `PRIOR_KO_{KO,EN}` | −200 / −5000 | after a Korean (or M) word |
| `PRIOR_EN_{KO,EN}` | −1300 / −200 | after an English word |
| `PRIOR_NUM_{KO,EN}` | −100 / −3500 | right after a digit |
| `HYST` | 1500 | display hysteresis |
| `USER_UNIT` | 2500 | user bonus scale |

Several values sit at the edge of the search grid (`PRIOR_KO_EN`, `MIX`, `NG_KO`, `CASE_MIXED`,
`TERM_HYPHEN_EN`); widening the grid would fit the news register even harder, so they were left there
deliberately. `PRIOR_KO_EN = −5` nats reflects news text, where 98.6 % of tokens after a Korean word are
Korean. It mostly affects short words that are valid in both readings (`go`/해, `so`/내, `to`/새);
unambiguous English (meeting, deploy, Slack) wins regardless (section 9.2). On the mixed dev-chat set,
moving it anywhere in −5000…−2300 changes nothing (99.86 % at every value).

---

## 7. Runtime model file — `duo-model.bin` (DUOM v1)

One little-endian file, every section 8-byte aligned, designed to be `mmap`ped read-only and used
in place (no parsing except one small JSON section). Built by `Tools/ModelBuilder/build_model.py`
into `Tools/ModelBuilder/out/`; copy `duo-model.bin` into the app bundle (`Resources/`).

### 7.1 Header (32 bytes) and directory

| offset | type | value |
|---|---|---|
| 0 | `[4]u8` | `"DUOM"` |
| 4 | `u16` | major = 1 (reject other majors) |
| 6 | `u16` | minor = 0 |
| 8 | `u32` | section count `S` |
| 12 | `u32` | directory offset (= 32) |
| 16 | `u64` | content hash = FNV-1a-64 over all bytes from the first section's offset to EOF |
| 24 | `u64` | reserved (0) |

Directory: `S` entries of 48 bytes: `name [24]u8` (ASCII, NUL-padded), `offset u64`, `length u64`
(bytes), `elemSize u32`, `count u32`.

### 7.2 Sections

| name | element | content |
|---|---|---|
| `meta` | UTF-8 JSON | params, codebooks, suffix tables, case lexicon, symbol table, provenance (≈ 100 KB) |
| `ko.{n}.key`, `en.{n}.key` | `u32` (n ≤ 5) / `u64` (n = 6) | sorted ascending packed n-grams of order n (5.1) |
| `ko.{n}.lp`, `en.{n}.lp` | `u8` | index into `meta.lm.<lang>.lpCodebook["n"]` (Int, millinats) — parallel to `key` |
| `ko.{n}.bow`, `en.{n}.bow` | `u8` | index into `meta.lm.<lang>.bowCodebook["n"]`; present for n < order; entries that are not contexts point at the exact-0 codeword |
| `lexko.key`, `lexen.key` | `u64` | sorted FNV-1a-64 of the normalised key string (`kno` for KO, `low` for EN) |
| `lexko.val`, `lexen.val` | `u8` | index into `meta.lexicon.<lang>.codebook` (ln P(word|lang), millinats) |

`meta` keys used at runtime: `symbols`, `lm.{ko,en}.{order,lpCodebook,bowCodebook,count,keyType}`,
`lexicon.{ko,en}.codebook`, `suffix.full` / `suffix.prefix` (`[String: Int]`, keys are `kno`
strings, e.g. `"dmf"` = 을, `"goTdjdy"` = 했어요), `caseLexicon` (`[String]`, exact case),
`params` (`[String: Int]`, section 6), `userLog2Millibits`.

FNV-1a-64: `h = 0xcbf29ce484222325; for byte in ascii(s) { h ^= byte; h = h &* 0x100000001b3 }`.
The builder asserts there are no collisions inside each lexicon. A false positive for an OOV word
has probability ≈ count / 2⁶⁴ (negligible).

### 7.3 Swift loading sketch

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

`Data(contentsOf:options: .alwaysMapped)` also works but keep the `Data` alive for the model's
lifetime. Load cost is one `mmap` + one ≈ 100 KB JSON decode (< 5 ms); pages fault in lazily
(the first word touches ~100 pages).

### 7.4 Shipped model (`build_model.py`, config `ship`)

| part | entries | bytes |
|---|---|---|
| KO LM, order 5, θ₄ = 15, θ₅ = 30 | 36 / 858 / 11 418 / 62 520 / 197 597 | 1.44 MB |
| EN LM, order 5, same pruning | 36 / 779 / 16 914 / 118 271 / 357 718 | 2.60 MB |
| KO lexicon (top 100 000 eojeols as `kno`) | 100 000 × (8 + 1) | 0.90 MB |
| EN lexicon (top 60 000 words) | 60 000 × (8 + 1) | 0.54 MB |
| meta JSON (params, 9 codebooks per LM, 1 684 suffixes + prefix table, 250-entry case lexicon, 56 units) | — | 0.15 MB |
| **total `duo-model.bin`** | | **5.63 MB** (content hash `aa722069c1e3076e`; the build is deterministic — two builds are byte-identical) |

Operation count per keystroke (`bench.py`, full recomputation of all hypotheses in prefix mode):
6 (2-key word) … 106 (16-key word) binary searches; final mode 13 … 236. The Python reference
needs 0.04–0.13 ms per keystroke; Swift should be well under 10 µs, two orders of magnitude inside the
1 ms budget, so no incremental caching is needed (it is allowed, because `cond` depends only on
`(hist, w)`, so caching yields identical integers).

---

## 8. Golden test vectors — `out/test_vectors.json`

Derived by `build_model.py` from the **re-opened binary** (independent reader), so passing them
proves both the algorithm and the file reader. All numbers are Int millinats.

| key | content | Swift test |
|---|---|---|
| `automaton[]` | `{keys, normalized, text, orphans, trailingLoneConsonant}` — 100 hand-picked edge cases, 300 frequent eojeols, 300 random key strings (incl. shifted letters, `'`) | automaton only |
| `fnv1a64[]` | `{s, hash}` (hex) | hash function |
| `lexicon[]` | `{lang, key, value|null}` | lexicon lookup + codebook |
| `lm[]` | `{model, keys, prefix[i], withEos[i]}` — cumulative score of `keys[0..<i]` without / with `</s>` | `cond` / backoff / codebooks |
| `final[]` | `{raw, features{…}, cases[{ctx, term, scores{K,E,M<b>}, best, output}]}` — every token of the mixed set + confusables, for ctx ∈ START (term S/D/H), KO, EN, NUM | full final-mode scorer |
| `incremental[]` | `{raw, ctx, steps[{scores, shown, text}]}` — per keystroke prefix scores and the hysteresis display | prefix scorer + display state machine |
| `apostrophe[]` | `{raw, ctx, scores, internal}` — prefix scores of `raw + "'"` | apostrophe rule (section 4) |
| `user[]`, `userBonus` | scores with user counts | adaptation |

Recommended Swift Testing layout: one `@Test(arguments:)` per key, e.g.

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

## 9. Evaluation (all numbers measured on the shipped `duo-model.bin` unless noted)

Accuracy = the committed text equals the intended text (so `M(b)` with the wrong `b` is an error).
Raw results: `Tools/ModelBuilder/out/eval/ship_bin.json` (plus `o6_final.json`, `o5p40.json`,
`o4.json`, `ship_tune.json`).

### 9.1 Single words without context (ctx = START, term = space, final mode)

| set | Korean (K) | English (E) | Latin+suffix (M) | all, token-weighted |
|---|---|---|---|---|
| Korean news, test half (812 688 tokens) | **99.48 %** (800 994) | **99.44 %** (7 732) | 88.79 % (3 962) | 99.43 % |
| Korean Wikipedia 2021, test half (701 072) | 99.85 % | 98.83 % | 84.53 % | 99.75 % |
| English news, test half (981 488) | — | **99.89 %** | — | 99.89 % |
| Mixed dev-chat set (1 385) | 100 % | 100 % | 100 % | 100 % |
| Held-out **types** (OOV for LM and lexicon), type-level | 99.82 % (110 536 types) | 98.97 % (51 237 types) | — | — |
| Held-out types, token-weighted | 94.21 % | 99.79 % | — | — |

The token-weighted held-out K number is dominated by a few very frequent Korean words that happen to be
held out and that look like English when only n-grams are available (`ej` 더, `dhs` 온, `rhe` 곧,
`Ehsms` 또는). In production those words are in the lexicon; the type-level number is the meaningful
measure of OOV generalisation. Target "≥ 99 % token-weighted, single words, no context" is met for both
languages on real text from a register never used in training (news).

### 9.2 Running text with context (greedy, context = what the engine itself committed)

| set | token acc. | K | E | M | sentence acc. | 1-word lookback | Viterbi (bound) |
|---|---|---|---|---|---|---|---|
| Korean news (50 000 sent.) | **99.90 %** | 99.95 % | 99.53 % | 89.27 % | 98.50 % | 99.90 % | 99.90 % |
| Korean Wikipedia (50 000) | **99.89 %** | 99.97 % | 99.34 % | 87.57 % | 98.72 % | 99.89 % | 99.89 % |
| English news (50 000) | **99.99 %** | — | 99.99 % | — | 99.72 % | 100.00 % | 100.00 % |
| Mixed dev-chat (417) | **99.86 %** | 100 % | 99.48 % | 100 % | 99.52 % | 99.86 % | 99.86 % |

Context removes about 80 % of the Korean-news errors (99.43 % → 99.90 %) and 90 % of the English ones
(99.89 % → 99.99 %). With "gold" context (the user fixes every error immediately) the numbers are
identical to 4 decimals, so errors do not cascade. Re-deciding the previous word when the next one
commits (lookback) or a whole-sentence Viterbi brings nothing measurable on Korean, so **v1 does not
modify already committed text**.

Remaining error classes (Korean news, predicted context; count per 812 k tokens):
* short Korean words that are frequent English words: `db`/유 41, `an`/무 34, `eh`/도 32, `to`/새 30,
  `so`/내 28, `al`/미 20, `did`/양 19, `fj`/러 12 (all ≈ 0.004 %);
* `M` with an unusual tail: `H조` / `A조` (`Hwh`) 18+5, `m로` (`mfh`, unit after a digit) 11,
  `A군은` parsed as `Arns`+은 11, `SK하이닉스는` read as Korean 10.

Mixed dev-chat errors: exactly two, `그거 so good` (so → 내) and `그럼 go 하시죠` (go → 해) — the
inherent ambiguity this product has to live with; one flip fixes it for that user from then on (5.5).

Requested confusion pairs (margin `S_E − S_K` in nats, final mode; positive = English wins):

| raw | Korean reading | START | after Korean | after English |
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

Only the two-letter function words are genuinely contested; everything with an orphan in its Korean
reading (`ok`, `in`, `it`, `we`, `no`, `hi`, …) is decided by 28–46 nats.

### 9.3 Incremental display (prefix mode + hysteresis, `HYST` = 1.5 nats, context init)

Sampled token-weighted, 1 000–3 000 words per row. *flips* = display changes per word;
*display acc.* = fraction of keystrokes whose display matches the eventual intended reading
(for `M(b)`, showing E before the suffix starts counts as correct); *surprise* = the committed text
differs from what was displayed just before the commit.

| words typed | context | flips / word | words with a flip | display acc. | commit surprise |
|---|---|---|---|---|---|
| Korean words in Korean news | KO | **0.000** | 0.0 % | 100.0 % | 0.0 % |
| English words in English news | EN | **0.012** | 0.8 % | 99.7 % | 0.07 % |
| first English word of a sentence | START | 0.46 | 45.8 % | 82.3 % | 7.6 % |
| Latin tokens inside Korean news (acronyms, M) | KO | 0.54 | 45.5 % | 80.2 % | 5.7 % |
| mixed dev-chat set | START→running | 0.20 | 16.9 % | 96.2 % | 2.0 % |

Policy comparisons:
* **Final-mode display** (show what a commit would produce now): Korean 1.18 flips/word, mixed 1.21 —
  rejected.
* **Argmax init** (first key shows the raw argmax instead of the context language): English-in-English
  flips rise from 0.012 to 0.083 per word (the first consonant was shown as jamo) — rejected.
* **Hysteresis sweep** (flips / commit surprise):

| HYST (nats) | Korean in KO | English in EN | Latin in KO | English at START | mixed |
|---|---|---|---|---|---|
| 0 | 0.000 / 0 % | 0.087 / 0 % | 0.55 / 4.8 % | 0.48 / 3.4 % | 0.27 / 1.9 % |
| 1.0 | 0.000 / 0 % | 0.020 / 0 % | 0.55 / 5.1 % | 0.47 / 7.8 % | 0.20 / 1.8 % |
| **1.5** | 0.000 / 0 % | 0.014 / 0 % | 0.54 / 5.5 % | 0.47 / 7.6 % | 0.19 / 1.8 % |
| 2.5 | 0.000 / 0 % | 0.007 / 0 % | 0.73 / 12.9 % | 0.49 / 8.0 % | 0.19 / 1.8 % |
| 4.0 | 0.000 / 0 % | 0.000 / 0 % | 0.74 / 14.6 % | 0.47 / 11.1 % | 0.18 / 2.2 % |

Typical flips are one-way and early: `t → ㅅ, th → 소, the → the`; `p → p, pending → pendingㅇ →
pending으 → pending을 → pending으로` (MIX grows naturally); `C → Ch → … → ChatGPT한테`.
UX recommendation: render the marked text with the standard underline only, and animate a reading
change with a short (≈ 120 ms) cross-fade so a flip reads as "the keyboard understood you" rather than
as flicker.

### 9.4 Robustness

* **Shift rollover**: 17 831 Korean-news tokens re-typed with Shift held over / pressed early
  (e.g. `dLTek` 있다, `gkTDj` 핬어): **100 %** still committed as the intended Korean. Capitalised English
  words after a Korean word (`Slack`, `GitHub`, `CCTV`): 99.88 %.
* **Hangul + Latin in one token** (`카톡ID`): unsupported, 0.045 % of Korean-news tokens.

### 9.5 Ablations and model-size curve (token accuracy, running text, greedy)

| variant | Korean news | English news | mixed |
|---|---|---|---|
| **shipped** | **99.90 %** | **99.99 %** | **99.86 %** |
| no lexicon (n-grams only) | 99.77 % | 99.99 % | 98.99 % |
| no orphan penalty | 99.89 % | 99.98 % | 99.86 % |
| no `M(b)` hypotheses | 99.79 % | 99.99 % | 98.70 % |
| no case / shift model | 99.79 % | 99.96 % | 99.78 % |
| no context prior | 99.44 % | 99.97 % | 100.0 % |

| LM config (same params, lexicons 100 k / 60 k) | file size | Korean news | Korean wiki | English news | mixed | held-out types K / E |
|---|---|---|---|---|---|---|
| order 6, unpruned | ≈ 26 MB | 99.91 % | 99.90 % | 99.99 % | 99.78 % | 99.83 / 99.14 % |
| **order 5, θ 15/30 (shipped)** | **5.63 MB** | 99.90 % | 99.89 % | 99.99 % | 99.86 % | 99.82 / 98.97 % |
| order 5, θ 40/80 | ≈ 4.8 MB | 99.90 % | 99.90 % | 99.98 % | 99.78 % | 99.83 / 99.01 % |
| order 4, unpruned | ≈ 2.9 MB | 99.90 % | 99.89 % | 99.98 % | 99.78 % | 99.83 / 99.15 % |

The lexicon, `M(b)` and the context prior carry most of the accuracy; the n-gram order hardly matters
beyond 4 (differences of 0.01 pt are 1–2 tokens on the mixed set). Order 5 is shipped for its slightly
better prefix (display) estimates on long words. If bundle size ever matters, order 4 (≈ 2.9 MB) is a
drop-in fallback: same format, rebuild with `order_ko=4, order_en=4`.

---

## 10. Recommendations, limitations and next steps

1. **Flip key + learning is part of the algorithm, not an extra.** The two dev-chat errors and most of
   the news errors are two-letter words valid in both scripts. Make the flip key prominent (e.g.
   Shift+Space or a dedicated key; design track decides) and record flips with weight 3 (5.5).
2. **Adaptive context prior (v1.1)**: keep per-user counts of `(previous language → language)` over
   the last ~5 000 commits and use
   `PRIOR[c][L] = round(1000·ln((n[c→L] + 20·p₀[c][L]) / (n[c] + 20)))`, with `p₀ = exp(PRIOR/1000)`
   from the shipped params (renormalised). Heavy code-switchers will then get `go`, `so` and `to` right.
   Not in the test vectors; gate it behind a feature flag.
3. **Do not rewrite committed text** (lookback gave +0.00 pt on Korean, +0.01 pt on English).
4. **Caps Lock** = ABC pass-through; **Option-modified keys** and keys with ⌘/⌃ are not part of
   tokens (commit first).
5. Known weak spots: Latin acronym + rare Korean compound (`SK하이닉스는`, 89 % on `M` tokens overall),
   foreign names typed in English that contain a plausible Korean tail (`Swiatek` → Swiat+다, 3 in 981 k),
   single letters in Korean text (`Z`, `R&D`).
6. Data refresh: the Korean side is 48 % subtitles / 52 % Wikipedia. A licensed chat/office-register
   corpus would help most (Leipzig news was used only as a held-out test set because its license could not
   be verified).
7. Privacy: user counts stay on device (`~/Library/Application Support/Duo/`), never synced without an
   explicit opt-in; store hashes of `raw` if logs must be exported for debugging.

---

## 11. Reproduction

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

Files: `hangul.py` (automaton), `kn.py` (modified Kneser-Ney, pruning), `detector.py` (runtime
algorithm, integer reference), `model_data.py` (data assembly), `corpora.py` (loaders incl. a minimal
msgpack reader), `evaluate.py`, `build_model.py`, `bench.py`, `params.json`, `data/*.txt` (curated lists
+ mixed test set). Download URLs:
`https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/{ko/ko_full,en/en_full}.txt`,
`https://raw.githubusercontent.com/rspeer/wordfreq/master/wordfreq/data/large_en.msgpack.gz`,
`https://dumps.wikimedia.org/kowiki/latest/kowiki-latest-pages-articles1.xml-p1p82407.bz2`,
`https://downloads.wortschatz-leipzig.de/corpora/{kor_news_2022_100K,kor_wikipedia_2021_100K,eng_news_2023_100K}.tar.gz`.
The kowiki chunk is processed by `corpora.kowiki_counts` into `Tools/data/raw/kowiki/kowiki_counts.tsv`
and `kowiki_mix.tsv` (see the one-liner in the git history / section 2).
