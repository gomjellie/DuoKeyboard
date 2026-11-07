# Duo research: completeness critique and resolutions

Track: completeness critic. Inputs: `imk-platform.md` (IMK), `ui-design.md` (UI), `detection.md` (DET), `ux-spec.md` (UX).
Date: 2026-11-07. Machine: macOS 26.6.2, Xcode 27.2, Swift 6.4.2, SDK `MacOSX27.2.sdk`.
I also read the current scaffold (`project.yml`, `DuoInputMethod/`, `DuoHarness/`, `Packages/DuoCore/`) and changed nothing outside this file.

Labels: **[VERIFIED-HERE]** means I ran or compiled it in this session. Probes are in
`/private/tmp/claude-501/-Users-user-orca-zlqhem/b8fa910a-9760-4366-944c-1b8329866082/scratchpad/critic/`.
**[SDK]** means read from a header. **[INFERRED]** means reasoning only.

---

## 0. Verified in this session (the claims that most change the implementation)

| # | Claim checked | Result | Consequence |
|---|---|---|---|
| V1 | IMK's commit-on-click when `recognizedEvents` also returns `.flagsChanged`. UX §3 and the current `DuoInputController` return `[.keyDown, .flagsChanged]` only. | **[SDK]** `IMKInputController.h`, `recognizedEvents:` says IMK's default mouse handling (send `commitComposition:` when the user clicks outside the composition) *"will only happen for input methods that return just NSKeyDownMask"*. | Right ⌘ needs `.flagsChanged`, so Duo **must** also take `.leftMouseDown` and commit by itself (R4). Otherwise a click leaves a stale buffer (a "ghost" composition). |
| V2 | IMK says Duo is not called in password fields "because Duo is not ASCII-capable" (§4.6). | **[VERIFIED-HERE]** TIS query (`flags.swift`): `com.inkyuoh.inputmethod.Duo asciiCapable=true`. Apple's `com.apple.inputmethod.Korean.2SetKorean asciiCapable=false`. The likely cause is `Latn` in `tsInputMethodCharacterRepertoireKey` [INFERRED]. | The premise is false. Duo can stay active in secure contexts, so the `IsSecureEventInputEnabled()` pass-through is **mandatory**, not defense in depth (R5). It also means UX onboarding step 3 ("Duo as the only keyboard") is allowed by TIS. |
| V3 | Right-⌘ tap detection. UX §5.1 arms on "keyCode 54 **and the RCmd device bit**". | **[SDK]** `IOLLEvent.h`: `NX_DEVICERCMDKEYMASK 0x10`, `LCMD 0x08`, `LSHIFT 0x02`, `RSHIFT 0x04`, `LALT 0x20`, `RALT 0x40`, `LCTL 0x01`, `RCTL 0x2000`; UX's table is correct. **[VERIFIED-HERE]** A flagsChanged built the way `DebugInjector.flagsEvent` builds it gives `type=12 keyCode=54 raw=0x100000`, i.e. **no 0x10 bit**. Setting `0x100010` explicitly round-trips through `NSEvent(cgEvent:)`. | As specced, the detector never fires in the lead's e2e harness. Key the detector on `keyCode` plus the device-independent `.command` transition. Use device bits only to spot a second modifier being held, and make the injector set them (R3). |
| V4 | Shared settings suite. IMK §3.4 suggests `UserDefaults(suiteName: "com.inkyuoh.inputmethod.Duo")`. | **[VERIFIED-HERE]** (`suite.swift`, embedded Info.plist): `UserDefaults(suiteName: <own bundle id>)` returns **nil** and logs *"Using your own bundle identifier as an NSUserDefaults suite name does not make sense and will not work"*. | Inside the IME, that suite is nil, and the UI code's `UserDefaults(suiteName:)!` would crash. Use a third name, `com.inkyuoh.Duo.shared` (R6). |
| V5 | Hardened runtime with ad-hoc signing. `project.yml` sets `ENABLE_HARDENED_RUNTIME: YES` while Debug builds produce `DuoInputMethod.debug.dylib`. | **[VERIFIED-HERE]** (`hr/`): an ad-hoc main executable with `--options runtime` plus an ad-hoc dylib makes dyld refuse to load it, with *"mapping process and mapped file (non-platform) have different Team IDs"* (exit 134). The 12:50 Debug build is still `flags=0x2(adhoc)` with no runtime flag, so it works **today** only because hardened runtime isn't being applied yet. | If hardened runtime ever takes effect (Release, a re-sign during embedding, `--deep`), an IME with any separate dylib or dynamic framework won't launch, and typing just does nothing. Set `ENABLE_DEBUG_DYLIB: NO` and `ENABLE_PREVIEWS: NO` on the IME and keep the SPM products static (R20). |
| V6 | Swift 6 hop pattern in the lead's current shape (`final class …: IMKInputController, @unchecked Sendable`). | **[VERIFIED-HERE]** (`ctl.swift`): capturing `event` or `client` straight into `MainActor.assumeIsolated` gives `sending 'event'/'client' risks causing data races` (a warning with `-swift-version 6` here). Rebinding with `nonisolated(unsafe) let e = event, c = client` first compiles cleanly with `-warnings-as-errors`. | Either IMK D3 or the lead's `@unchecked Sendable` shape is fine, but **always rebind IMK arguments** before the hop (R14). |
| V7 | The Python reference is bit-exact and portable. | **[VERIFIED-HERE]** In `detector.py` the runtime path is integer-only. The one `//` (`user_bonus`) has positive operands. `round()` appears only at build time, and `shift_counts` guards `i > 0` (no Python negative-index wrap). `render(K)` normalises Shift internally (`dLTek` gives 있다). | A Swift port with `Int` and truncating `/` matches the vectors. Read `USER_LOG2` from `meta.userLog2Millibits`; don't recompute it. |
| V8 | UX's "(verify)" deep link `x-apple.systempreferences:com.apple.Keyboard-Settings.extension`. | **[VERIFIED-HERE]** `/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex` has `CFBundleIdentifier = com.apple.Keyboard-Settings.extension` and `allowsXAppleSystemPreferencesURLScheme = true`. I didn't open it, to avoid taking the user's screen. | Keep it as the fallback link. |
| V9 | UX profile bundle IDs, checked against the apps installed here. | **[VERIFIED-HERE]** `com.apple.Terminal`, `com.googlecode.iterm2`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92` (Cursor), `dev.zed.Zed`, `com.jetbrains.WebStorm`, `com.kakao.KakaoTalkMac`, `com.tinyspeck.slackmacgap`, `com.google.Chrome`. Not on any list, yet the user's daily drivers: **`com.stablyai.orca` (Orca, Electron)** and **`com.cmuxterm.app` (cmux, native)**. | Both are terminal-class clients. Orca's terminals are Electron (probably xterm.js), so they get the Chromium rules **and** the terminal profile. Add both to the profile table and the manual QA list (R10, R18). |
| V10 | Can a passive log check confirm that real flagsChanged events reach `handle`? | `log show --debug` for subsystem `com.inkyuoh.inputmethod.Duo` returned nothing; debug-level messages aren't persisted. | **Still unverified.** See U1 for a test plan. |

---

## 1. P0: contradictions that block a coherent implementation

### R1. Composition model: UX "eager phases" vs DET "whole token, decided at the boundary"
**Issue.** The two specs describe different engines:
- UX D2 commits K-phase syllables eagerly (Apple parity) and commits E-phase Latin eagerly, passing later letters raw. Mixed words get their own heuristic lookahead (UX §4.5: "complete English unit" plus "≤ 2 keys").
- DET keeps the whole token. It shows the prefix-mode argmax with HYST = 1.5 nats and commits the **final-mode** argmax (lexicon plus `</s>`). Mixed words come from `M(b)` scoring.

Every DET accuracy number (99.90 / 99.89 / 99.99 / 99.86 %) assumes whole-token, final-mode decisions. Eager K commits are irreversible except through a replacement range, and nobody measured how often they fire too early. DET measured 80.2 % display accuracy and 0.54 flips/word for Latin tokens in Korean text, which are exactly the tokens where an early K lock commits jamo garbage. UX §2.3 then forbids escaping back to English ("In K phase a later typo does not flip to English").

**Decision.**
1. **The engine is DET.** The token is a run of letters plus an internal `'` under DET's rule. The display is prefix mode with hysteresis, and the commit is final mode. The whole token stays marked until a boundary, capped at 32 keys (UX §4.1).
2. **Eager E is allowed** (it's safe and helps IntelliSense and autocomplete). It triggers when the prefix-mode margin `S_E − max(S_K, S_M*) ≥ 4595` millinats (P < 1 %), or when UX's structural-deadness rule fires. Duo then commits the Latin typed so far and passes the following letters raw.
   - It reopens marked text only when a consonant key (`qwertasdfgzxcv` or `QWERT`) arrives and DET's `M(b)` gate holds for `b = committed length`: `lexEN[low[0..<b]] != nil`, or the Latin part has an uppercase letter, or `suffixPrefix[ks]` exists.
   - The tail is then scored as DET `S_M(b)` against `S_E(full)`, prefix mode for display and final mode at commit.
   - This is UX §4.5 written as DET formulas. Drop the separate UX lookahead heuristics.
3. **Eager K is OFF by default.** Turn it on only for the `search` client policy (Spotlight `com.apple.Spotlight`, Alfred `com.runningwithcrayons.Alfred`, Raycast `com.raycast.macos`, Safari's address bar if detectable). Revisit once DET replays the Leipzig and mixed sets through a Python `phase_trace` and reports irreversible-commit errors below 0.05 % of tokens.
4. Japanese and Chinese IMEs keep whole phrases marked in Chromium and Electron every day. The web Return bugs UX cites happen with any marked text, not only long runs, so commit-then-pass on Return (R18) is the mitigation either way.

### R2. Commit policy: UX D1 "WYSIWYG, never differs" vs DET "commit = final argmax"
**Issue.** DET measured *commit surprise*: what gets committed differs from what was on screen just before the commit. It is 7.6 % for the first English word of a sentence and 5.7 % for Latin tokens inside Korean text. Pure WYSIWYG would commit those display errors and give up the lexicon and `</s>` evidence that produces the 99.9 % figures.

**Decision.** At a boundary, commit the **final-mode argmax**. The boundary handler first replaces the marked text with the final reading and commits it, all inside the same `handle` call: one `insertText`, no `setMarkedText` first (R18). When final ≠ shown, show the **"↺ flip last word" chip** for 1.6 s (UX §5.4). Reword D1 from "never differs" to **"never differs silently"**. Accept DET's guidance that already-committed words are never re-decided.

### R3. Flip key: three different defaults
**Issue.**
- UX D3 defaults to a Right ⌘ tap and rejects Tab.
- UI uses `FlipKey { shiftSpace (default), rightCommand, rightOption, tab }`, HUD caps `["⇧","Space"]`, and a menu item labelled "Flip Current Word ⇧Space".
- DET §10 suggests "Shift+Space or a dedicated key".
- UX itself explains why ⇧Space misfires (⇧ is still held after ㅆ or a capital).

**Decision.**
- **Default to a Right ⌘ tap.** Use `enum FlipKey: String { case rightCommand, rightOption, doubleShift, shiftSpace, capsLock }`; delete `.tab`. The HUD default caps are `["⌘"]` and Settings labels it "오른쪽 ⌘".
- **Detector (pure state machine in DuoCore), driven by `flagsChanged`:**
  - **Arm** when `keyCode == 54` and `.command` goes from clear to set, and no other device-independent modifier is set.
  - **Fire** when `keyCode == 54` and `.command` clears within `tapWindow` (default 300 ms).
  - **Disarm** on any `keyDown`, any other modifier change, `NSEvent.pressedMouseButtons != 0`, or a timeout. Device bits are an *extra* check only: disarm if `raw & 0x08` (left ⌘) is also set.
  - Ignore `flagsChanged` with `keyCode == 0`; Squirrel notes that remote-desktop tools send these.
  - Expect the release to sometimes arrive late, with the next `keyDown` (Squirrel comment). In that case the tap is lost, which is the safe failure.
  - Never consume `flagsChanged`.
- **Harness:** `DebugInjector.flagsEvent` must OR in the device bit (`0x10` for `{rcmd}`, `0x08` for `{lcmd}`, and so on, per V3) so the e2e test is faithful.
- Optional, unverified: the F18 keyDown (`kVK_F18 = 79`) as an alias, for users whose Karabiner setup maps Right ⌘ to F18 for 한/영.

### R4. Mouse events (V1)
**Decision.** Return `recognizedEvents = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]`, the same set as Gureum `InputReceiver.swift:262`. In `handle`, a mouse type means commit as R2 describes, reset the token and the tap detector, invalidate `lastCommit`, and return `false`. UX §3's "Mouse click → commitComposition" row now depends on this; it is not IMK's default. Fix the current `DuoInputController.recognizedEvents` as well.

### R5. Secure input (V2)
**Decision.** At the top of every `handle` (before scoring) and in `activateServer`, check `IsSecureEventInputEnabled()`. It is a local call, not XPC. If it returns true:
- commit any pending token,
- return `false` for every key from then on,
- show no HUD and learn nothing.

Add a harness case with an `NSSecureTextField` driven through the TSM path (U1). That confirms whether TSM keeps Duo active there, now that Duo is ASCII-capable. Keep `Latn` in the repertoire; making Duo non-ASCII-capable would force users to keep ABC around. That reintroduces source switching (⌃Space, Caps Lock), which the product exists to avoid.

### R6. Identifiers and storage (V4 plus placeholders)
UI code uses placeholders (`app.duo.inputmethod`, `app.duo.shared`, `InputSourceStatus.bundleID = "app.duo.inputmethod"`). Settle on one table and keep it as constants in `DuoKit` (`enum DuoIDs`):

| Thing | Value |
|---|---|
| IME bundle ID | `com.inkyuoh.inputmethod.Duo` (already set in project.yml) |
| IME product/executable | Keep `DuoInputMethod`, so `killall DuoInputMethod` never hits the host app. Hard-code `CFBundleName`/`CFBundleDisplayName` = `Duo` in `DuoInputMethod/Info.plist` instead of `$(PRODUCT_NAME)`; the installed source is named "DuoInputMethod" today. Add `InfoPlist.strings` (ko, en). |
| Host app | Bundle ID `com.inkyuoh.Duo`, product `Duo.app`. It embeds the IME at `Contents/Library/Input Methods/DuoInputMethod.app`, which `InputMethodInstaller` already assumes. |
| Harness | `com.inkyuoh.Duo.Harness` (exists) |
| Selectable input source ID | `com.inkyuoh.inputmethod.Duo` today (mode-less). Switching to IMK's mode `com.inkyuoh.inputmethod.Duo.Bilingual` is R19. Code must always go through `InputSourceManager.primaryDuoSource()`, never a hard-coded ID. |
| Shared preferences | `UserDefaults(suiteName: "com.inkyuoh.Duo.shared")`. Never use either app's own bundle ID (V4). No app groups: an ad-hoc signature can't carry a team-prefixed group entitlement [INFERRED]. |
| Settings change IPC | Distributed notification `com.inkyuoh.Duo.settingsChanged`, posted with no payload. The IME re-reads on it and on `activateServer`. |
| Learning store | `~/Library/Application Support/Duo/learning.json`. The **IME is the only writer** (see R7). |
| Other notifications | Keep the existing `com.inkyuoh.Duo.debug.*` names. Add `com.inkyuoh.Duo.event.flipped` (no text payload) for the onboarding challenge. |
| Log subsystem | `com.inkyuoh.inputmethod.Duo` (exists) |

### R7. Learning: two incompatible formulas
**Issue.**
- UX §5.5: Double votes. A flip adds `+1`, implicit acceptance adds `+0.25`, bias is `β = 3·ln-ratio`, 60-day half-life, 50 k LRU, an actor, an app-group JSON file.
- DET §5.5: integer counts per hypothesis (`K`, `E`, `M<b>`). Commit adds `+1`, flip adds `+3`, bonus is `USER_UNIT · USER_LOG2[min(n,15)] / 1000`, 20 k LRU, and test vectors back it (`user[]`, `userBonus`).
- DET's "+1 on every commit" stores every word ever typed (a privacy problem and unbounded growth). It also lets habit outvote a correction: 15 English commits of `go` give +10.0 nats, while one flip to 해 gives +5.0. With UX-style flip-only votes and a context-free key, one flip of `go`→해 after Korean turns `go` into 해 in English sentences as well (EN context margin +2.37 − 5.0 < 0).
- DET applies the bonus in **final mode only**. A learned word therefore still displays the old reading while you type and flips at commit, which breaks R2.

**Decision.**
- Keep DET's **scoring** formula and vectors unchanged.
- **Store key** = `(raw, ctx)` with `ctx ∈ {START, KO, EN, NUM}`. The value is integer counts per hypothesis key (`"K"`, `"E"`, `"M<b>"`) plus `lastUsed`.
- **Updates:**
  - an explicit flip adds `+3` to the chosen hypothesis;
  - an implicit commit adds `+1` to the committed hypothesis **only if** the final margin was at most 1386 millinats (the alternative had ≥ 20 %);
  - flipping back inside the same token cancels the vote.
- **Never learned** (from UX): secure input, L phase, Direct, length-1 tokens, Pause Learning.
- **Decay:** the effective count is `n_eff = Int((Σ count·0.5^(age/60 d)).rounded())`, computed at read time, before the `USER_LOG2` lookup. That keeps the scorer integer.
- **Cap:** LRU 20 000.
- **Apply the user bonus in prefix mode too**, for an entry whose `raw` equals the current raw exactly. This means extending `detector.py` and regenerating `incremental[]` vectors before the Swift port.
- **Store concurrency:** see R14.

### R8. Scoring constants: one source of truth
**Issue.** UX invents a parallel logit system: momentum λ table, ±2.5 clamp, +2.0 for a non-QWERTOP capital, +3.0 for camelCase, Δ ≥ 1.0 logit hysteresis, a +2.0 counter table, sentence-start +1.0 EN. DET's `params` are tuned on held-out data: `PRIOR[ctx]`, `CASE_*`, `ROLLOVER`/`STRAY`, `NUM_UNIT_EN`, `HYST = 1500`.

**Decision.**
- DET `meta.params` is the only set of scoring constants. UX numeric constants are superseded, and the UX test vectors in §9 are expected outcomes to check against DET, not formulas.
- UX features with no DET equivalent all go into **one** additive term `appBiasKO` (millinats, clamped to ±1500), added to the KO score. It combines:
  - the per-app profile: English-first −1000, Korean-first +1000;
  - the global "language bias" slider (UI §3.3) mapped to ±1000;
  - the learned per-app EMA (UX §6.5), at most ±500.
- With `appBiasKO = 0` the golden vectors hold exactly.
- Quote and parenthesis rules (UX §6.3) wait until v1.1.
- **HUD thresholds in DET units**, with P from a 2-way softmax of shown vs the best other reading:
  - P(alt) ≥ 20 % means a margin ≤ **1386**;
  - "uncertain commit" (P ≥ 35 %) means a final margin ≤ **619**;
  - P < 1 % means a margin ≥ **4595**.
- The adaptive context prior (DET §10.2) goes to v1.1 behind a flag. DET's `PRIOR_KO_EN = −5000` reflects news text and will cost heavy code-switchers on `go`/`so`/`to`.

---

## 2. P1: decisions an implementer would otherwise get stuck on

### R9. Token boundaries, joiners, literal mode
- Use **DET's tokenizer**: letters, plus an internal `'` decided by DET's apostrophe rule. DET measured that rule as better than UX's "append iff EN is displayed".
- `-` is a boundary with `term = H` (DET `TERM_HYPHEN_EN = +5000` covers e-mail and co-founder). Drop UX's hyphen joiner.
- Keep **UX's L phase** as a gate in front of scoring, so DET isn't consulted while it is active:
  - token-start `/ ~ \ : @`, `./`, `../`;
  - `@` after letters;
  - `://`, `www.`;
  - a letter after `.` when the previous token committed as E;
  - `_` inside a token.

  In L phase every key passes raw until whitespace or Return. `#` is not literal.
- Digits are boundaries (`term = D`), and the next token gets `ctx = NUM` (DET). UX's counter and unit table is DET's `NUM` prior plus the 56 `numUnitsEn`. Don't add a second table.

### R10. Terminal default profile
**Issue.** UX D8 makes terminals Direct (raw keys; a Right-⌘ tap enables Korean for one line), to protect vim normal mode. This user drives Claude Code from terminals, and those prompts are mostly Korean (Orca `com.stablyai.orca`, cmux `com.cmuxterm.app`, Terminal, iTerm2). Direct would bring back exactly the mode switch the product promises to remove.

**Decision.**
- Terminal-class apps default to **Bilingual with an English-first prior** (`appBiasKO = −1000`).
- "직접 입력 (Direct)" is one click away in the input menu and in Settings ▸ Apps, and onboarding offers it ("vim·less를 자주 쓰나요?").
- Add the missing IDs: `com.stablyai.orca` (terminal class and Electron), `com.cmuxterm.app`, `com.mitchellh.ghostty`, `dev.warp.Warp-Stable`.
- Esc commits and passes, as specced.

### R11. Flip semantics and the HUD's single alternative
DET cycles K → E → best M → K; UX and UI have two states. **Decision: two states.** The alternative is the best-scoring hypothesis with a *different rendered string* in the other script class:
- shown K → best of {E, M};
- shown E → best of {K, M};
- shown M → E.

A flip locks the token. A second flip returns to the original and keeps the lock. The HUD shows exactly that alternative.

### R12. HUD: merged spec
- **When (UX rules, DET units):**
  - shown only while the token is marked, with P(alt) ≥ 20 % (margin ≤ 1386), and either ≥ 2 keys or a 1-key collision key (`a i e x`…);
  - appears after a **300 ms** pause, then stays and updates in place until commit;
  - hides after UI's **140 ms** debounce and 100 ms fade;
  - never during autorepeat, secure input, Direct mode, or with an invalid caret rect.
- **Look:** UI §2.2 (28 pt capsule, 20 pt badge `character`/`character.ko`, 14 pt medium text, keycaps). It replaces UX's 26 pt / 13 pt. Badge glyphs are 가/A everywhere (one-shot badge, menu icon, `TISIconLabels.Primary = "가A"`), replacing UX's "한/A".
- **Window:** UI's panel, except `level = max(client.windowLevel() + 1, NSWindow.Level.popUpMenu.rawValue)` instead of `CGShieldingWindowLevel()`, which sits above the lock screen. Hide on `NSWorkspace.screensDidSleepNotification` and `sessionDidResignActiveNotification`.
- **No mouse:** `ignoresMouseEvents = true`. Drop UX's "click the alternative to flip" in v1, because it needs a mouse-accepting panel in a never-active process. Use `.regular` glass, not `.interactive()` (click-through).
- **Caret rect:** `attributes(forCharacterIndex: 0, …)`, falling back to `firstRect(forCharacterRange: markedRange())`. Fetch it only when the HUD is about to show and on updates while it is visible, not on every keystroke (R15).
- DET §9.3's "cross-fade the marked text on a reading change" **can't be done**, because the client draws the marked text. Put the motion on the HUD only (UI's auto-flip pulse).

### R13. Input menu
IMK ignores submenus in `menu()` [REF macSKK]. UX's "현재 앱 ▸ (radio)" therefore has to be flat. The menu, top to bottom:
1. `Duo 설정…`
2. separator
3. a disabled header `현재 앱: ‹name›`
4. four items with a checkmark on the active one: 자동 · 한국어 우선 · English 우선 · 직접 입력
5. separator
6. `선택한 텍스트 한↔A 변환`
7. `✓ 힌트 표시`
8. `학습 일시 정지`
9. separator
10. `Duo 도움말`

Drop UI's "Flip Current Word ⇧Space" item. If it stays, its key label must follow the `FlipKey` setting.

### R14. Concurrency shape
- **Controller:** `@objc(DuoInputController)`, thin. Keep the lead's `@unchecked Sendable` shape or use IMK D3, but **rebind** `event`, `sender` and `client` with `nonisolated(unsafe)` before `MainActor.assumeIsolated` (V6). Build the full target; a typecheck-only pass hides region errors (IMK §4.9).
- **Engine (`DuoModel`):** immutable, mmap-backed `final class … : @unchecked Sendable`, scored **synchronously** on the main thread. No `await` anywhere on the keystroke path. Marked text must be set before `handle` returns (iTerm2 bug, IMK D5).
- **LearningStore:** UX §10 says "all access goes through an actor". That **conflicts** with the synchronous rule. Decision: a `@MainActor final class LearningStore` holding the in-memory dictionary (read synchronously while scoring). Persistence goes through a separate `actor LearningWriter`, which takes a `Sendable` snapshot struct, debounces it for 2 s and writes atomically (`Data.write(options: .atomic)`). Flush in `applicationWillTerminate` (`NSSupportsSuddenTermination = false`).
- **Edits from the host app** (delete an entry, reset): post `com.inkyuoh.Duo.learning.command` with `{op, raw, ctx}`. The IME applies it, writes, and posts `com.inkyuoh.Duo.learning.changed`. If no IME process is running (check with `NSRunningApplication.runningApplications(withBundleIdentifier:)`), the host may write the file directly.
- **State per controller and shared state:** token state, tap detector and `lastCommit` live in each controller (one per client session). Engine, store, HUD and settings are singletons created in `main.swift` before `NSApp.run()`.

### R15. Per-keystroke budget (XPC)
Every `client.*` call is a synchronous XPC round trip to the client app. Budget per keystroke:
- exactly one `setMarkedText` or `insertText`, plus nothing else, in the common case;
- `attributes(forCharacterIndex:)` only while the HUD is pending or visible;
- `bundleIdentifier()` once per controller.

Run UX §6.8's "`markedRange()` after `setMarkedText`" probe **once per client session**, not per key. Scoring has a 1 ms budget. Add a Swift Testing benchmark (p99 over a 32-key token, ≤ 300 µs) and build `DuoCore` with `-O` even in Debug (`SWIFT_OPTIMIZATION_LEVEL = -O` for the package target). The lead uses Debug builds every day, and `-Onone` costs 10–50×.

### R16. Keyboard layout
DET's `raw` is the ABC-layout string (lowercase means unshifted, uppercase means Shift+key). IMK §4.2 suggests taking Latin from `event.characters`, which honours Dvorak. That breaks the single shared `raw` and makes E-phase raw pass-through disagree with what was scored. **v1 decision:**
- derive `raw` from `keyCode` (ANSI positions) plus `.shift`, ignoring `.capsLock` (Caps Lock on means pass everything through);
- call `client.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.ABC")` in `activateServer`, as Gureum does, so raw pass-through matches the model;
- Dvorak and Colemak are out of scope for v1, and the docs should say so.

### R17. Clients that can't replace text
For `.unsupported` clients (iTerm2, Hyper, Java/JetBrains such as `com.jetbrains.WebStorm`) and Terminal's `.beforeCaretOnly`:
- force whole-token marking, including **no eager E**, so a flip while composing always works without a replacement range;
- disable flip case (b) and the uncertain-commit chip;
- for Java clients, call `setMarkedText(x)` before `insertText(x)`.

### R18. App-compat invariants (gathered from IMK and UX, so nobody has to dig for them)
1. Set marked text synchronously inside `handle`. Send one `setMarkedText` per key event (Chromium applies only the last one).
2. On Return, Tab, Esc, arrows, ⌘/⌃/⌥ combos, Fn, F-keys and digits: first `insertText(final)`, then return `false`. Never insert `"\n"` yourself.
3. Never send an empty `setMarkedText` or `insertText` while idle (Office). Clearing an active composition with an empty attributed string is fine.
4. Always pass a non-nil `NSAttributedString` with non-nil attributes (azooKey #385, a `CFEqual(NULL)` crash on 26.6.2).
5. Keep `selectionRange = (len, 0)` with one clause and `kTSMHiliteConvertedText` (single underline).
6. Observe `kTISNotifySelectedKeyboardInputSourceChanged`, and commit plus hide when the selected source isn't Duo (macOS 26 doesn't call `deactivateServer`).
7. State resync: if `markedRange().location == NSNotFound` while Duo thinks it is composing (for example Slack cleared the field), drop the token silently. Check it lazily on the next key, not with an extra call on every key.
8. Manual QA priority, based on what this user actually runs: **Orca (Electron terminal)**, cmux, Claude Code CLI inside both, VS Code/Cursor, Slack, KakaoTalk, Chrome, Notes/TextEdit, iTerm2, WebStorm, Spotlight.

### R19. Mode or no mode: experiment before committing
IMK D2 recommends adding a mode ("decide now"). There are no external users yet, so only the lead's machine is affected. The real risk is that the new mode ID can't be selected without a logout (Apple DTS says System Settings needs one; TIS might not). **Decision:** spend one quick experiment when the lead isn't typing:
1. register the bundle;
2. enable the parent, then the mode;
3. select `…Duo.Bilingual` through TIS;
4. type through the TSM-path harness (U1).

If that works with no logout, adopt the mode. Otherwise ship v1 mode-less and set `TISIconLabels`, `TISIconIsTemplate` and the icon at the top level.

Either way:
- `LSBackgroundOnly` → `LSUIElement`;
- `CFBundleName` = `Duo` (R6);
- leave out `TISDoubleSpaceSubstitution` in v1 (it adds a system behaviour nobody has tested);
- keep `TICapsLockLanguageSwitchCapable = false`.

### R20. Build settings (V5)
In `project.yml`, on the `DuoInputMethod` target:
- `ENABLE_DEBUG_DYLIB: NO`
- `ENABLE_PREVIEWS: NO`

Keep the `DuoCore`/`DuoKit` SPM products static, with no `type: .dynamic`.

If hardened runtime is kept for Release, two rules follow:
- sign the embedded IME **before** the host app;
- never use `codesign --deep`.

A separately signed ad-hoc dylib is refused under hardened runtime.

### R21. Model packaging and licence
- Copy `Tools/ModelBuilder/out/duo-model.bin` (5 632 872 bytes, content hash `aa722069c1e3076e`) to `DuoInputMethod/Resources/duo-model.bin`. **Commit the binary.** The corpora are gitignored, and rebuilding means downloading about 200 MB.
- The host app's in-process playground loads the model from the **embedded IME bundle** (`Contents/Library/Input Methods/DuoInputMethod.app/Contents/Resources/duo-model.bin`), so there's no second copy.
- Check the content hash in a unit test, not at runtime.
- Put the CC-BY-SA-4.0 attribution (DET §2) in `DuoInputMethod/Resources/duo-model.LICENSE.txt` and in Settings ▸ About ▸ Acknowledgements.
- Copy `test_vectors.json` (2.46 MB) into `Packages/DuoCore/Tests/DuoCoreTests/Resources/` as a test resource.

---

## 3. P2: merges and smaller gaps

- **Onboarding:** UI's 4-step frame, filled with UX content:
  1. Welcome: hero morph plus a live field.
  2. Turn on Duo: "Duo 켜기" through `InputSourceManager`; the deep link (V8) is the fallback.
  3. Try it: UX's 4 practice tasks plus Right-⌘ detection with `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)`. If no tap is seen in 8 s, offer the alternatives.
  4. Done.

  UX's typing-style and developer toggles move to Settings, with defaults from R8 and R10. Copy goes in a String Catalog, Korean first (project `developmentLanguage: ko`).
- **Playground double processing.** If Duo is selected *and* the playground also runs the in-process engine, keys are handled twice. **Decision:**
  - When Duo isn't the selected source, use a custom `NSView` whose `inputContext` returns `nil`. It feeds DuoCore's reducer and draws its own marked text.
  - Once Duo is selected, switch to a plain `NSTextView` so the real IME runs.
  - The flip challenge listens for `com.inkyuoh.Duo.event.flipped`.
- **Settings panes:** General (status and troubleshooting rows, flip key, hints, Backspace unit 자소/글자, the "` → ₩" toggle defaulting OFF, language-bias slider), Apps (per-app profiles), Learning (toggle, dictionary table, reset), About (privacy text and Acknowledgements). This replaces UI's 3 panes and UX's 6.
- **`InputSourceStatus` in the UI appendix:** delete it and use `DuoKit.InputSourceManager`. It filters on the placeholder `app.duo.inputmethod`.
- **Learned-word rows:** the result column is `render(raw, argmax over the learned hypotheses)`. Rows are per `(raw, ctx)`, shown grouped by `raw`.
- **ScreenCaptureKit:** the permission seen in UI §5 belongs to whichever process is "responsible" (the terminal or agent host). Use it only for our own windows, gate it with `CGPreflightScreenCaptureAccess()`, and never capture the user's screen or menu bar. CI and `xcodebuild` runs must rely on `ImageRenderer` plus the snapshot stand-in, and `cacheDisplay`.
- **Icon resemblance** to Apple Translate: low risk. Keep UI's fallback (a split keycap).
- **v2 backlog** (unchanged): Hanja on ⌥Return, KO→EN re-segmentation (앱store), `카톡ID`, 3-Set layouts, per-website priors.

---

## 4. Claims that matter and are still unverified (with the cheapest test)

| # | Claim | Who depends on it | How to verify without TCC |
|---|---|---|---|
| U1 | Real Right-⌘ `flagsChanged` (keyCode 54, raw `0x100010`) reaches Duo's `handle` through TSM in Cocoa, Chromium/Electron (Orca, VS Code) and Terminal. Squirrel's Shift-tap is production evidence for Cocoa. | R3 (default flip key) | Add a TSM-path mode to DuoHarness using IMK §7.1 (a `CGEvent` keyboard event with `type = .flagsChanged`, flags `0x100010`, then `window.sendEvent(NSEvent(cgEvent:))`, in an active host launched with `open`). Assert that Duo logs at `.info`, not `.debug`, or posts a debug notification. Other apps need a human: a 5-minute manual check with `log stream --predicate 'subsystem == "com.inkyuoh.inputmethod.Duo"'`. |
| U2 | TSM's behaviour for an ASCII-capable IM in `NSSecureTextField` and web password fields. | R5 | Same TSM-path harness with an `NSSecureTextField` first responder: does Duo's `handle` run, and is `IsSecureEventInputEnabled()` true? |
| U3 | A mode-based plist is selectable on 26.6.2 without logout. | R19 | The experiment described in R19. |
| U4 | `TISIconLabels.Primary` has an effect for third parties. | Icon polish | Low priority. A human looks at the menu bar. Don't capture the screen. |
| U5 | A one-time System Settings confirmation the first time `TISEnableInputSource` runs. | Onboarding step 2 | Observe on a clean user account; design step 2 to tolerate a prompt (poll status every 1 s). |
| U6 | Swift scoring is ≤ 10 µs per keystroke (DET extrapolated from Python 0.04–0.13 ms). | R15 | The benchmark test in R15. |
| U7 | The eager-E and M(b) gate (R1) keeps DET's accuracy. | R1 | DET replays the eval sets through a Python `phase_trace`. It reports accuracy, irreversible-commit errors and marked length at the boundary. |
| U8 | Orca (Electron, xterm.js) handles marked text plus commit-then-Return without duplicating the last character. | R10, R18 | Manual QA in Orca, the user's main terminal; keep the `returnAsCR` flag from UX §6.6 ready. |
| U9 | `isIncrementalSearchInputContext` and other private client selectors. | Search policy | Probe only with `responds(to:)`; ship with the bundle-ID list. |

---

## 5. Risk register (top items)

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| Eager-K commits jamo garbage that can't be undone in Korean context (Latin display accuracy 80 %) | High / high, if UX D2 is built as written | R1 (eager-K off by default) |
| Click leaves a stale buffer, giving ghost compositions | Certain / high, with the current `recognizedEvents` | R4 |
| Password keystrokes composed or learned | Medium / severe (V2) | R5 + U2 |
| IME silently fails to launch (dyld Team-ID refusal) | Medium / high (V5) | R20 |
| Settings never reach the IME (nil suite) | Certain if IMK §3.4 is followed (V4) | R6 |
| A flip learned in one context corrupts another (`go`→해 everywhere) | High / medium | R7 `(raw, ctx)` keys |
| Electron terminals (Orca) duplicate or drop the last syllable on Return | Medium / high for this user | R18 #2, U8 |
| Synchronous XPC calls make typing lag in slow clients | Medium / medium | R15 |
| HUD above the lock screen | Low / medium | R12 window level |
| macOS 26 programmatic switches skip `deactivateServer` | Known / medium | R18 #6 |
