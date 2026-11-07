# Duo v1 — implementation spec (binding)

Duo is a macOS 26 InputMethodKit input method that types Korean (두벌식) and English from one
keyboard without switching. Every word is scored in both readings while you type and committed in
the language you meant. A flip key fixes the rare miss and teaches Duo.

**Precedence:** this file › `docs/research/critique.md` (decisions R1–R21 are binding) › the four
research docs (`detection.md`, `ux-spec.md`, `imk-platform.md`, `ui-design.md`). When a research
doc disagrees with the critique, the critique wins. When the critique disagrees with this file,
this file wins. UX-spec numeric constants are superseded by DET `meta.params` (R8). UX §9 rows are
*expected outcomes to check*, not formulas.

---

## 1. Product rules (short)

1. **One input source.** Duo is ASCII-capable and replaces both ABC and 2-Set. Caps Lock on means raw
   uppercase English (D9). Password fields get raw keys, no composition, no HUD and no learning (R5).
2. **Whole-token composition** (R1). A token is a run of letters plus an internal `'` (DET §4). It
   stays marked until a boundary, displayed with DET prefix mode plus hysteresis (`HYST = 1500`), and
   is committed with the DET final-mode argmax (R2). Eager **English** commit is allowed (R1.2).
   Eager Korean is off in v1.
3. **Never silently different.** If the committed reading differs from what was shown, or the final
   margin is ≤ 619, show the "↺ flip last word" chip (R2).
4. **Flip** = right ⌘ tap by default (R3). Three cases: the token being composed, the word just
   committed (verified replace), or nothing to flip (one-shot next-word language) (ux §5.2, R11).
5. **Learning** follows R7: votes keyed by `(raw, ctx)`, flip +3, an ambiguous implicit commit +1,
   60-day decay, applied in prefix *and* final mode.
6. **Apple-grade feel:**
   - No flicker: Korean never changes reading mid-word.
   - No lag: scoring takes ≤ 300 µs p99, with one XPC call per key.
   - No surprise: Backspace is never overloaded.
   - The UI is Liquid Glass and everything is localized (Korean first, English second).

---

## 2. Architecture

```
Packages/DuoCore (SwiftPM, macOS 26, Swift 6 language mode)
  DuoCore  (pure; Foundation only)
    Hangul/      두벌식 automaton, Keystroke, layout            [A]
    Contracts/   shared types — LEAD ONLY, do not edit           [lead]
    Detection/   DuoModel (mmap DUOM v1), LM, lexicon, scorer   [A]
    Engine/      CompositionEngine, tap detector, learning,
                 client profiles, BufferTextClient, converter   [B]
  DuoKit   (AppKit/Carbon integration shared by IME + host)
    DuoIDs, SettingsStore                     LEAD ONLY          [lead]
    InputSourceManager, InputMethodInstaller  (existing; D may extend)
    KeyEventMapper, LearningPersistence                          [B]
    KeyScript (harness DSL, existing)                            [C]
DuoInputMethod/   IMK app: controller adapter, HUD, menu, plist  [C]
Duo/              host app: onboarding, settings, playground    [D]
DuoHarness/       E2E harness (existing)                         [C]
Tests/E2E/        E2E case files                                 [integration]
project.yml, Package.swift, Makefile, Tools/scripts              [lead; request changes]
```

**Runtime objects (IME process):** `main.swift` creates the singletons before `NSApp.run()`:
- `DuoDetector` (mmaps `duo-model.bin` from the IME bundle);
- `LearningStore` (loaded from `learning.json`, with persistence through `LearningWriter`);
- `DuoSettings` (reloaded on `settingsChanged` and in `activateServer`);
- the HUD controller.

Each `DuoInputController` (one per client session) owns one `CompositionEngine` (R14).

**Host app:** links DuoCore and DuoKit and embeds `DuoInputMethod.app` at
`Contents/Library/Input Methods/` (already wired in `project.yml`). Its in-process playground loads
the model from that embedded bundle (R21) and runs a `CompositionEngine` against a
`BufferTextClient` when Duo is not the selected input source.

---

## 3. Contracts (already in the tree; they compile)

| File | Contents |
|---|---|
| `DuoCore/Contracts/DetectionContract.swift` | `Hypothesis` (K/E/M(b), `.key` "K"/"E"/"M3"), `ScriptLanguage`, `LanguageContext` (START/KO/EN/NUM), `Terminator` (S/D/H/P), `ScoredHypothesis`, `HypothesisScores` (`best` uses the DET tie rule), `UserCounts`, `protocol LanguageDetector`, `Margins` (1386 / 619 / 4595) |
| `DuoCore/Contracts/EngineContract.swift` | `KeyEvent` (letters by ANSI position, `Modifiers`, `isRepeat`, `isDeadKey`, `timestamp`, `KeyEvent.typing("…")` for tests), `ModifierEvent`, `@MainActor protocol TextClient`, `ReplacementSupport`, `HUDRequest` (content/anchor/immediate/lifetime/pulse), `CommitReason`, `EngineNotification` |
| `DuoCore/Contracts/SettingsContract.swift` | `FlipKey`, `BackspaceUnit`, `AppProfile`, `DuoSettings` (tolerant Codable), `LearningEntry`, `LearningSnapshot` (on-disk JSON schema) |
| `DuoKit/DuoIDs.swift` | bundle ids, suite `com.inkyuoh.Duo.shared`, notification names, file locations (R6) |
| `DuoKit/SettingsStore.swift` | load/save/observe settings, seen-apps list |

Placeholder implementations that keep the public API compiling:
- `DuoDetector` [A]
- `CompositionEngine`, `ClientProfile`, `LearningStore`, `BufferTextClient`, `SelectionConverter`,
  `KeyEventMapper`, `LearningFile`/`LearningWriter` [B]

Owners **replace the bodies** and may add API, but must keep every signature already declared.
Contract types are frozen. If you truly need a change, put a shim in your own files and report it
under "contract requests".

---

## 4. Engine behaviour (B implements; the IME and playground only adapt)

### 4.1 State (per engine)

- `token`: `raw` (ABC string, letters plus internal `'`) and `ctx` (frozen at token start).
  - `committed c`: how many leading raw chars are already committed as Latin by eager E, 0 if none.
  - `shown`: Hypothesis; `autoShown` is what hysteresis would show.
  - `locked: Hypothesis?` and `lockedOriginal`.
  - `startedAt`.
- `contextTracker`:
  - previous committed hypothesis;
  - "previous char was a digit";
  - "at sentence start" (field start, after `.!?` + whitespace, after Return, after navigation, mouse
    or focus change, after Tab);
  - "at word start".
- `literal: Bool` (L phase), `passNextRaw` (dead key), `capsLockOn`, `bilingualLine` (Direct profile).
- `oneShot: ScriptLanguage?`.
- `lastCommit`:
  - `text`, `raw`, `hypothesis`, `ctx`;
  - `alternative` (with its render);
  - `endLocation` = `selectedRange().location` right after the insert, and `boundaryLength`;
  - `time`, `clientBundleID`.
- `tapDetector` (pure, for the flip key per `settings.flipKey`).

### 4.2 Context for a new token (DET §4, R9)

- `NUM` if the previous character was a digit.
- `START` at sentence start.
- Otherwise `KO` if the previous committed hypothesis was K or M, `EN` if it was E.

Spaces, commas, quotes and brackets keep the context. `biasKO` = profile bias (koreanFirst +1000,
englishFirst −1000, automatic 0) + `settings.languageBias`, clamped to ±1500. It goes to the detector
on every call.

### 4.3 Letter keys

1. **Bypass.** If secure input is on (the adapter passes it via `CommitReason.secureInput` and stops
   calling), Direct without `bilingualLine`, literal, Caps Lock on (unless `flipKey == .capsLock`),
   `passNextRaw` or any of ⌘⌃⌥: commit any token first, then return `false`. ⌥ letters commit and
   pass. A dead key sets `passNextRaw` for the following key.
   - **Caps Lock flip key (D9).** With `flipKey == .capsLock` and the lock on, the app would type
     these letters uppercase: the engine inserts `key.latin` itself and consumes the key instead
     (the eager-E tail, L, the letter after `.`, Direct). ⌥ letters and the key after a dead key stay
     raw.
2. **Cap.** On the 33rd key, final-commit the token (term S), then start a new one.
3. **New token.**
   - `shown` = `oneShot` (and `locked`) if set, else `ctx == .english ? E : K` (DET "context init").
   - A new token also clears `lastCommit` validity for flip case (b), except as noted in §4.7.
4. **Append and score.** Append the key and compute `prefixScores` with `user = learning.counts(raw, ctx)`.
   - **Consistent hypotheses:** with `c > 0`, only `E` and `M(b)` with `b ≥ c`; with `c == 0`, all.
   - **Hysteresis (DET §5.6), unless locked:**
     - if `shown` is not consistent or not present, `shown = best`;
     - else if `best.score − score(shown) > HYST`, `shown = best`.
   - When `shown` changed by itself, set the HUD `pulse`.
5. **Eager-E state** (`c == raw.count − 1`, everything before this key committed):
   - **Reopen** if `detector.canAttachKorean(raw: raw, latinCount: c)`: consume, and mark
     `render(shown)` minus the first `c` chars. Hysteresis starts from `E`.
   - **Otherwise** pass the key raw (`return false`) and set `c += 1`. The app inserts it; the
     keyboard is ABC through `overrideKeyboard`.
6. **Marked state** — eager-E commit happens when all of these hold:
   - `settings.eagerEnglishCommit`;
   - `clientProfile.replacement != .none` (R17);
   - not locked, and `shown == .english`;
   - `score(E) − max(other consistent) ≥ Margins.eagerCommit` (prefix mode).
   - **Then** `insertText(raw[c...])` (consume), `c = raw.count`.
   - **Else** `setMarkedText(render(shown).dropFirst(c))` (consume).
7. **HUD.** If the token is marked and `settings.showHints`, emit `.alternative`:
   - the text is `render(alt)`; `eligible` = `!isRepeat` and margin ≤ 1386 and (≥ 2 keys or the
     1-key collision set `a e i o u x`);
   - otherwise `hud = nil` while composing.
   - The alternative (R11), always with a render that differs from the shown one:
     - shown K → E, or the best M if it is a real contender;
     - shown E → K, or the best M if it is a real contender;
     - shown M → E.
     - A real contender beats the other pure reading and is within `Margins.eagerCommit` (P ≥ 1 %)
       of the shown one. Otherwise the runner-up mix is noise (사랑 → `tk랑`, test → `tesㅅ`), and
       a user who flips wants the plain other reading. Real mixes (PR을, git을) are shown already or
       pass the test.

### 4.4 Apostrophe `'` (DET §4)

- **Inside a token, not in L:** if `prefixScores(raw + "'")` argmax is E, append `'` (`shown = E`),
  mark or eager-commit as in §4.3, and consume.
- **Otherwise:** final-commit with term P, then pass `'`.
- **No token:** pass.

### 4.5 Boundaries (everything else), R18 #2

Any key that is not a letter or token-internal `'`:
1. Final-commit the token in the same `handle` call, as one `insertText`, then return `false` so the
   app handles the key.
2. The terminator is:
   - `D` for digit keys (main row; keypad digits count as digits too);
   - `H` for `-`;
   - `S` for space, Return, Tab, Esc, arrows, navigation, F-keys, ⌘/⌃ shortcuts;
   - `P` otherwise.
3. **Never** insert `"\n"` or `" "` yourself. Pass the key.
4. **Special keys:**
   - **Backspace (marked part present):** remove the last keystroke (`jaso`) or the keys of the last
     syllable block (`gulja`, K/M readings), recompute, and keep `shown` unless it became
     inconsistent (Backspace never changes language, UX §2.4).
     - If the marked part becomes empty with `c == 0`: `setMarkedText("")`, drop the token, consume.
     - If it becomes empty with `c > 0`: `setMarkedText("")`, consume.
   - **Backspace with nothing marked:**
     - with a token whose `c > 0`, drop the last raw char, `c -= 1`, and pass;
     - with no token, pass. If `lastCommit` is still adjacent (caret == end + boundaryLength), it stays
       valid and the chip may show (§4.8). `.beforeCaretOnly` clients (Terminal) re-anchor instead:
       the `len` units before `caret − boundaryLength` must equal `lastCommit.text`, and that becomes
       the new end, because the end recorded at commit can trail the shell's echo.
   - **⇧Space with `flipKey == .shiftSpace`:** flip, consume. Autorepeats are consumed without a
     flip. In L, ⇧Space is a plain space: it ends L and passes.
   - **`` ` `` with `graveTypesWon`:** commit, then `insertText("₩")`, consume.
   - **Return or Esc in Direct with `bilingualLine`:** commit, end `bilingualLine`, pass.

### 4.6 Literal (L) phase (R9)

While `literal`, letters and keys pass raw (nothing marked) and the flip does nothing. L ends (the
key passes) on:
- whitespace, Return, Tab or Esc;
- Backspace that deletes past the trigger (the engine counts the UTF-16 units typed since L began,
  trigger included), and ⌥⌫;
- arrows, navigation keys, and ⌘/⌃/fn shortcuts (⌘A ⌫ and moving to another line start clean).
Forward Delete and F-keys keep L.

Triggers:
- **At word start:** `/ ~ \ : @`, and `.` followed by `/` or `.` (`./`, `../`).
- **`@` inside a token:** commit `raw` as Latin (the E render, even if K was shown), pass `@`, enter L.
- **`_` inside a token:** commit as Latin, pass `_`, enter L.
- A Korean reading the user chose (a flip lock on K/M, or a Korean one-shot) wins over the `@`, `_`
  and `www.` rules: the token commits as chosen, like any punctuation, and L does not start (ㅠ_ㅠ).
- **`:` after a token committed as E, then `/`:** L.
- **A letter right after `.` when the previous token committed as E** (node.js, github.com, www.):
  L, and that letter passes raw.

`#` is not literal.

### 4.7 Flip (tap fired, or ⇧Space)

**(a) Token present.**
- Target:
  - if `locked` exists, toggle between `lockedOriginal` and the R11 alternative;
  - else `alt` (R11), with `lockedOriginal = shown`.
- If `c > 0`, the committed Latin must be re-opened:
  - `R = (markedStart or caret) − c ..< marked end`;
  - verify `client.string(in: committed part) == raw[0..<c]`;
  - then `setMarkedText(render(target), replacementRange: R)` and `c = 0`.
  - If verification fails, or the client cannot replace committed text
    (`!clientProfile.canReplaceCommittedText`, §4.10), show `.cannotChange` and change nothing.
- Else `setMarkedText(render(target))`.
- Lock, then notify `.flipped`.

**(b) No token and `lastCommit` valid.**
- Valid means:
  - same bundle id;
  - not older than 30 s;
  - no letter, mouse, or focus change since;
  - an empty selection at the word: `selectedRange().location ∈ {end, end + boundaryLength}`.
    `.beforeCaretOnly` clients measure back from the caret instead (word + boundary, then the bare
    word), since their end can trail the echo;
  - the text there starts with `lastCommit.text` (UTF-16 exact); the rest is the boundary.
- Caret away from the word (or a selection): this is case (c).
- Caret at the word but `!clientProfile.canReplaceCommittedText` (Monaco): `.cannotChange`, before
  any read or write, and nothing is learned.
- If valid: `insertText(render(alt) + boundary, replacementRange: (start, caret − start))`, so the
  caret stays after the boundary in every client.
  - Learning: +3 for alt at `(raw, ctx)`, or cancel the previous vote if this flips back.
  - Update `lastCommit` so a second tap flips back, then notify.
- If invalid but there was a recent commit: `.cannotChange`.

**(c) Otherwise.**
- `oneShot = opposite(context language)` and HUD `.oneShot(lang)` (immediate, 0.9 s).
- A second tap cancels.
- In Direct, toggle `bilingualLine` instead (HUD `.bilingualLine`).

### 4.8 Commit (boundary, or `commit(_ reason:)`)

1. **Choose:**
   - `h = locked ?? finalScores(...).best(where: consistent)`;
   - `text = render(h).dropFirst(c)`;
   - `insertText(text)` (skip when empty and nothing is marked, R18 #3).
2. **Record `lastCommit`.**
   - `endLocation` comes from `selectedRange()` when `replacement != .none`. This is one extra XPC
     call, only at commits.
   - If it is nil, `lastCommit` is not flippable (a flip shows `.cannotChange`).
3. **Chip:**
   - condition: `settings.offerUndoAfterCommit`, `canReplaceCommittedText`, not locked, and
     (`h != shown` or the final margin to the best other render ≤ 619);
   - `hud = .flipLastWord(render(alt))` with `immediate`, `lifetime 1.6`, anchor
     `.location(end − len)`;
   - else `hud = nil`.
4. **Learning.**
   - **Locked:** if `locked != lockedOriginal`, add +3 to `locked`. Flipping back to the original
     cancels.
   - **Not locked:** if final margin ≤ 1386, add +1 to `h`.
   - **Never learned:** `raw.count < 2`, literal, Direct, paused or disabled, secure input.
5. **Context:** update the context tracker and clear the token.
6. **Reasons:** `mouse`, `deactivate` and `secureInput` also invalidate `lastCommit` and set
   sentence-start context. `commitComposition` keeps the context.
7. **Every `commit(reason)` with a marked part asks `markedRange()` first.** If the client says
   nothing is marked, it already ended the composition (kept the string, or cleared the field):
   drop the token, insert nothing. Outside an IMK callback (TIS notification, menu, global
   monitor) the IME adapter answers with its own mark when the client says none, because those
   answers can be stale.

### 4.9 Robustness

- **Resync (R18 #7).** If a token is marked and > 1 s passed since the last key, check
  `client.markedRange()` before applying the key. If it is nil, drop the token silently, with no
  insert. Caps Lock and fn commits resync the same way first.
- **Tap detector (R3).**
  - Arm: `keyCode == 54` (or 61 for right ⌥), `.command` (or `.option`) clear→set, and no other
    device-independent modifier.
  - Fire: same keyCode and the flag clears within `flipTapWindowMs`.
  - Disarm: any keyDown, any other modifier change, `pressedMouseButtons != 0`, or a timeout. Also
    disarm when `flags & 0x08` (left ⌘) is set for right ⌘.
  - Ignore keyCode 0.
  - `doubleShift`: two shift taps within the window. `capsLock`: each keyCode-57 flagsChanged fires.
- **Never consume** `flagsChanged`.
- **Modifier routing (IME).** Chromium/Electron deliver every `flagsChanged` twice: a copy with the
  same keyCode and device-independent flags within 0.2 s is dropped. Clients that never forward
  modifiers are served by a global `.flagsChanged` monitor (no permission needed), used only while
  the session has not forwarded one itself. A key or click between press and release that the window
  server counted (`CGEventSource.counterForEventType`) makes it a chord, not a tap.

### 4.10 Client profiles (`ClientProfile.forBundleIdentifier`)

| Default | Bundle ids |
|---|---|
| **englishFirst + isTerminal** (R10) | `com.apple.Terminal` (replacement `.beforeCaretOnly`), `com.googlecode.iterm2` (`.none`), `com.stablyai.orca`, `com.cmuxterm.app`, `com.mitchellh.ghostty`, `dev.warp.Warp-Stable`, `net.kovidgoyal.kitty`, `org.alacritty`, `com.github.wez.wezterm`, `co.zeit.hyper` (`.none`) |
| **englishFirst** | `com.apple.dt.Xcode`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`, `dev.zed.Zed`, `com.sublimetext.4`, `com.panic.Nova`, `com.barebones.bbedit`, `com.jetbrains.*` (`.none` and `needsMarkBeforeInsert`), `com.google.android.studio` (Java) |
| **koreanFirst** | `com.kakao.KakaoTalkMac`, `com.hancom.office.hwp*`, `jp.naver.line.mac` |
| **automatic** | everything else |

Direct is never a default; it is opt-in through the menu or Settings.

`canReplaceCommittedText` is `false` for replacement `.none` and for Monaco editors, which ignore
`replacementRange` in both `setMarkedText` and `insertText` (verified live): `com.microsoft.VSCode`,
`com.microsoft.VSCodeInsiders`, `com.todesktop.230313mzl4w4u92` (Cursor), `com.vscodium`,
`com.exafunction.windsurf`, `com.visualstudio.code.oss`. They keep eager English (IntelliSense needs
real text) but never re-open, flip committed text, or show the chip. Only VS Code and Cursor are
English-first by default.

---

## 5. Tracks

Each track works in its **own copy** of the repo and syncs only the paths it owns back into
`/Users/user/orca/zlqhem` when done (see §6).

### A — Detection port (`Packages/DuoCore/Sources/DuoCore/{Hangul,Detection}/`, `Tests/DuoCoreTests/{Hangul*,Detection*}`)

1. Port `Tools/ModelBuilder/detector.py` and `hangul.py` to Swift, bit-exact with
   `Tests/DuoCoreTests/Resources/test_vectors.json`. Every key must pass with exact `Int` equality:
   `automaton`, `fnv1a64`, `lexicon`, `lm`, `final`, `incremental`, `apostrophe`, `user`, `userBonus`.
   - Align the existing automaton with DET §3: `ㄸㅃㅉ` never as finals, `'` handling, `orphans`,
     `trailingLoneConsonant`, Korean normalisation. Keep existing tests passing, or fix them where
     DET is normative.
2. `DuoModel`:
   - mmap, header and directory validation, `meta` JSON decode;
   - binary search over packed keys;
   - codebooks; `userLog2Millibits` read from meta.
3. `DuoDetector`:
   - implements `LanguageDetector`;
   - user bonus in prefix mode too (R7);
   - `biasKO` on `S_K`;
   - `canAttachKorean` per the contract doc comment.
4. Performance:
   - a Swift Testing benchmark with p99 over 32-key tokens, prefix and final mode;
   - target ≤ 300 µs in release (`swift test -c release`) and report the Debug number;
   - no allocations on the hot path beyond small arrays;
   - cache n-gram lookups per token if needed (allowed by DET §7.4).
5. A unit test that checks the model content hash `aa722069c1e3076e`.

### B — Composition engine (`Sources/DuoCore/Engine/`, `Sources/DuoKit/{KeyEventMapper,LearningPersistence}.swift`, `Tests/DuoCoreTests/Engine*`)

1. Implement §4 completely. Engine tests use the real `BufferTextClient` and a scripted
   `FakeDetector` (in test sources) for logic.
2. Write `EngineScenarioTests` covering the ux-spec §9 vectors that make sense under the critique,
   using the **real** `DuoDetector`.
   - Load the model from `DuoInputMethod/Resources/duo-model.bin` via `#filePath`.
   - Use `.enabled(if:)` so they skip while the detector is a placeholder (its `contentHash ==
     "placeholder"`).
   - Mark expectations DET can't meet as `withKnownIssue`, with a reason.
3. `LearningStore` (R7): decay, LRU 20 000, `counts(raw:context:)` with
   `n_eff = Int((Σ…).rounded())`, recording API, `onChange`.
4. `LearningWriter` actor: 2 s debounce, atomic writes, `flush()`.
5. `KeyEventMapper`:
   - ANSI keycode → letter or character for the ABC layout, with Shift;
   - keypad set; dead keys ⌥e ⌥` ⌥u ⌥i ⌥n;
   - `.capsLock`, `.function` and other modifiers.
   - Reuse the tables in `KeyScript.swift` (read-only) or move them into a new file of yours.
6. `SelectionConverter`: Hangul ↔ keys (DubeolsikLayout), per script run, capped at 2 000.
7. `ClientProfile` table (§4.10).

### C — Input method (`DuoInputMethod/**`, `DuoHarness/**`, `Sources/DuoKit/KeyScript.swift`, `Tools/IconGen/**`)

1. **Controller adapter** (`DuoInputController`):
   - follow the R14 concurrency shape, rebinding IMK args before `MainActor.assumeIsolated` (V6);
   - `recognizedEvents` includes mouse-down types (R4);
   - check secure input first (R5);
   - `activateServer`:
     - `overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.ABC")`, falling back to `…US`;
     - reload settings and record the seen app;
     - reset the engine profile;
   - `deactivateServer` commits and hides the HUD;
   - `commitComposition`;
   - observe `kTISNotifySelectedKeyboardInputSourceChanged` (R18 #6);
   - forward `EngineNotification.flipped` as a distributed notification;
   - `IMKTextInput` → `TextClient` adapter: R18 #4 non-nil attributed strings with
     `kTSMHiliteConvertedText` underline, selection `(len, 0)`, and Java mark-before-insert;
   - VoiceOver announcement on flip (ux §7.5).
2. **HUD** (ui-design §2, R12):
   - a non-activating glass capsule;
   - level `max(client.windowLevel()+1, popUpMenu)`;
   - 300 ms appear delay for non-immediate requests, latch while composing, 140 ms hide debounce;
   - lifetimes and pulse; tested placement geometry;
   - caret rect fetched only when showing or updating;
   - hide on screen sleep or session resign;
   - Reduce Motion and Increase Contrast.
3. **Input menu** per R13: flat, Korean labels, actions wired:
   - "Duo 설정…" opens `com.inkyuoh.Duo` (`NSWorkspace` by bundle id);
   - the per-app profile radio writes `settings.appProfiles`;
   - selection conversion;
   - the hints toggle and pause-learning toggle.
4. **Info.plist** (R6, R19):
   - `LSUIElement`;
   - `CFBundleName` / `CFBundleDisplayName` "Duo";
   - `InfoPlist.strings` in ko and en;
   - `TISIconIsTemplate`, plus `TISIconLabels` `Primary = "가A"`;
   - keep `TICapsLockLanguageSwitchCapable = false`;
   - **stay mode-less** (R19 experiment deferred);
   - `NSSupportsSuddenTermination = false`, and flush learning on terminate.
5. **Menu icon:** regenerate the template TIFF (16 + 32 px) with `Tools/IconGen`.
6. **DebugInjector** (DEBUG only):
   - OR device bits into flagsChanged per V3 (`{rcmd}` 0x10 …);
   - support mouse-down injection (`{click}`) so the R4 path is testable;
   - stays DEBUG-only.
7. Use DuoCore and DuoKit only through their public APIs.

### D — Host app (`Duo/**`)

1. A SwiftUI app per ui-design §3 merged with critique P2:
   - **Onboarding** (4 steps):
     1. welcome, with a hero morph and a live playground field;
     2. Duo 켜기 via `InputMethodInstaller.install(from: embeddedBundleURL)`, with a live status
        checklist polled every 1 s and a deep link fallback;
     3. try it: practice tasks plus right-⌘ tap detection through a local `flagsChanged` monitor;
        offer alternatives after 8 s;
     4. done.
   - **Settings** (sidebar):
     - 일반: status and troubleshooting rows, flip key, hints, undo chip, Backspace unit, ₩ toggle,
       language-bias slider, eager English toggle;
     - 앱별 설정: seen apps plus profile picker;
     - 학습: toggle, searchable table from `LearningFile.load()`, delete or reset via learning
       command notifications, or a direct write when the IME isn't running;
     - 정보: version, privacy copy, acknowledgements including `duo-model.LICENSE.txt` and CC BY-SA
       text.
2. **Playground:**
   - when Duo is not the selected source, a custom `NSView` (`inputContext` nil) driving
     `CompositionEngine` + `BufferTextClient` through `KeyEventMapper`, and drawing its own marked
     underline;
   - when Duo is selected, a plain `NSTextView`;
   - the flip challenge listens for `DuoIDs.Notifications.flipped`.
3. **App icon:** an Icon Composer `AppIcon.icon` in `Duo/Resources` (ui-design §4; verify with
   `actool` through the build).
4. **Localization:** String Catalog (`Localizable.xcstrings`), Korean source and English, for every
   user-visible string.
5. Liquid Glass throughout (`.glassEffect`, `.buttonStyle(.glass)`), native controls,
   accessibility labels, both appearances.

### Integration (after A–D)

1. Sync, `make project`, build every scheme, `swift test` green (vectors bit-exact), and the
   scenario tests run against the real model.
2. Install the Debug IME and run E2E cases (`Tests/E2E/cases.json`) through DuoHarness.
3. Fix integration bugs.
4. Always restore the user's input source afterwards (`com.apple.inputmethod.Korean.2SetKorean`).

---

## 6. Workspace and safety rules for every agent

- **Workspace.** Create your copy with
  `rsync -a --exclude build --exclude Duo.xcodeproj --exclude Tools/data/raw /Users/user/orca/zlqhem/ <ws>/`.
  Build and test **only** inside `<ws>`:
  - `cd <ws>/Packages/DuoCore && swift test --scratch-path <ws>/build/spm`;
  - `cd <ws> && xcodegen generate --quiet && xcodebuild -project Duo.xcodeproj -scheme <S> -derivedDataPath <ws>/build/dd build`.
- **Sync back when done:** `rsync -a --delete` of **only your owned paths** into
  `/Users/user/orca/zlqhem/`. Never touch other paths there. List the synced paths in your report.
- **Machine state:**
  - Never install the IME, change or select input sources, kill system processes, or use computer
    use or screen capture in tracks A–D. The user is typing on this machine.
  - Integration and QA phases may do so, and must restore the input source.
- **Repo:** never read or print `.env`. Never commit, push or create branches.
- **Code:**
  - Swift 6 strict concurrency, with zero warnings in your own files.
  - Doc comments on public API; no dead code; no TODOs without a reason.
  - Korean UI copy in the ux-spec voice ("~해요").

## 7. Definition of done (v1)

- `swift test` is green and bit-exact on all DET vectors; the engine and scenario suites pass, with
  documented known issues only.
- Every scheme builds with zero warnings in our sources.
- E2E harness cases pass through real IMK.
- Real-app checks via Orca computer use (TextEdit, Safari or Chrome, Terminal, Notes):
  - `안녕하세요`, `hello`, `PR을`, flip, Backspace and Return behave as specified;
  - the HUD appears and is positioned under the caret.
- The host app installs, enables and selects Duo from a clean state. Onboarding and Settings look
  native in light and dark.
