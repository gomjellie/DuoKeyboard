# Duo v1 — status (fix round 2 + lead re-review/QA pass, 2026-11-07)

## Summary

- **Fix round 2 is integrated** in one tree: the engine, input method, persistence/installer and host
  tracks (44 review findings), plus the integration fixes listed below.
- **Every scheme builds from clean with zero warnings in our sources**: DuoInputMethod, DuoHarness and
  Duo in Debug; DuoInputMethod and Duo in Release.
  - The Release IME is signed `adhoc,runtime` and has 0 `com.inkyuoh.Duo.debug` strings, as does the
    copy embedded in Duo.app. The Debug IME has 4.
- **Live E2E through real IMK: 51/51 cases pass** (`Tests/E2E/cases.json`: the 40 from round 1 plus
  11 new ones). The set passed 3 consecutive runs, two of them through `make e2e`. After every run
  the input source was back on `com.apple.inputmethod.Korean.2SetKorean`.
- **The Release build is installed for daily use**: the IME embedded in `build/Release/Duo.app` is in
  `~/Library/Input Methods`, and the host app is at `~/Applications/Duo.app`. Duo is enabled and
  listed in the input menu; the selected source was left on 2-Set Korean.
- **Lead pass after round 2** (below): the 7 re-review findings, a flip-alternative fix found in real
  apps, the enable/approval flow, and a host crash, each verified live.

## Test numbers

| Suite | Result |
|---|---|
| `swift test` (debug, `build/spm`) | 435 tests in 41 suites passed, 4 known issues, 0 failures |
| `swift test -c release` (`build/spm-rel`) | 435 tests in 41 suites passed, 4 known issues, 0 failures |
| Host tests (`xcodebuild test -scheme Duo`) | 50 tests in 11 suites passed |
| Live E2E (`make e2e`) | 51/51 (3 runs in round 2, 2 more after the lead pass) |
| E2E mirror (`E2ECaseMirrorTests`) | all 51 cases match the engine in-process |
| Benchmark, release (run alone) | prefix p99 15.6 µs, final p99 17.1 µs, prefix + final p99 32.7 µs (budget 300 µs) |
| DET golden vectors | unchanged, all pass (bit-exact; model hash `aa722069c1e3076e`) |

The 4 known issues are the `withKnownIssue` scenario rows below; there are no other failures.
Round 1 had 305 package tests in 28 suites and 16 host tests in 5 suites.

## Choice bar and HUD position (after the lead pass)

Two user reports, both handled with tests and checked live.

- **"WORKS came out as 쨰깐."** That was not Duo. The QA wrap-up had left the selected source on
  Apple's 2-Set Korean, where ⇧W ⇧O ⇧R ⇧K ⇧S is exactly 쨰깐. `AppleInputSourceHistory` showed 2-Set
  Korean right before Duo was selected again. With the real model Duo types WORKS (and TODO, DONE,
  README, TEST) at the sentence start, after Korean and after English, in TextEdit and with the
  Orca profile.
- **A word with two plausible readings needs a way to choose** (SPEC §4.11). The HUD is now a choice
  bar: both readings with their badges, the one in the document on a pill tinted with its language,
  then the flip key. A click on the other reading flips that word (the word being typed, or the word
  just committed) and teaches like the flip key. It never arms the next word. The bar stays up while
  the pointer is on it, and the last word's bar now lives 4 s instead of 1.6 s.
- **"A switch chip shows at the bottom left of the screen."** Some clients (seen in Orca) report a
  caret far from their text. The HUD now follows a caret rect only inside one of the client's
  on-screen windows (`HUDGeometry.isInsideClientWindow`, `ClientWindows`); otherwise it stays hidden.
  `place … caret (x, y, w, h)` debug lines in the `hud` category log every rect it follows.
- **The last word's chip covered the word in TextEdit.** Right after a commit TextEdit answers
  `firstRect` a line off (word at y 817, caret line at y 803). `HUDGeometry.wordRect` moves the word
  rect to the caret's line when the two disagree.

Live QA (Debug IME, 2026-11-07):
- TextEdit: `go` at a sentence start shows [가 해 | A go ⌘] under the marked text. Clicking go flips
  the marked word while TextEdit stays frontmost and key. After `go␣` the bar sits under the
  committed word, and clicking 해 replaced it with 해␣. The bar stays with the selection moved, and
  stays while the pointer is on it.
- VS Code (Monaco editor): the bar sits under the caret.
- Not checked live: Orca itself (this session's terminal; never typed into), Chrome and Safari click
  paths, the VoiceOver announcement after a click.

## Lead pass after round 2

Re-review findings (all with tests):
- **R1 (major) VS Code flip away from the word.** `endLocation` is recorded whenever the client
  reports positions; only a flip *at* the word is refused in Monaco, so `foo();⏎// ` + flip arms the
  next word again.
- **R4 Terminal ⌫ over the boundary.** `.beforeCaretOnly` clients re-anchor from the caret (the end
  recorded at commit trails the echo), so `hello␣` ⌫ flip gives `ㅗ디ㅣㅐ` (verified live in Terminal).
- **R5 / R3 Bilingual line.** Leaving Direct ends `bilingualLine` and its badge; the badge comes back
  only after a flip ran, not on a bare flip-key press (no false VoiceOver announcement).
- **Host:** a refused enable (`status != noErr`) shows its error after a 2 s grace instead of 30 s;
  the bottom bar no longer locks during 켜기; the strength footer and the unreadable-file message no
  longer promise what the code does not do.

Found in real apps:
- **Flip alternative (R11 refined).** A mixed reading is offered only when it is a real contender
  (beats the other pure reading and is within `Margins.eagerCommit` of the shown one). Before, 27 %
  of Korean words flipped to noise (사랑 → `tk랑`, 프로그램 → `vm로그램`) and English words to `tesㅅ`,
  `thankㄴ`, `wwㅈ`. Now 사랑 → `tkfkd`, test → `ㅅㄷㄴㅅ`, www → `ㅈㅈㅈ`; `PR을` is unchanged.
- **Enabling goes through macOS's approval prompt** (see Known issues for the history): the installer
  no longer writes the allow-list, opens System Settings ▸ Keyboard first, re-asks once 4 s into the
  wait when System Settings was not running (a cold launch can lose the prompt; a second enable
  never stacks a second prompt), waits up to 60 s, comes back to the front after Allow, and says
  "macOS의 허용을 받지 못했어요…" instead of "(오류 0)". The checklist step reads "macOS에서 허용".
- **Host crash on 켜기**: `InputSourceManager` queries (`isEnabled`, `isSelected`, …) ran TIS off the
  main thread from the installer's background queue and hit macOS 26's `dispatch_assert_queue`
  (SIGTRAP). Every query now hops to the main thread like the mutations.

Live QA after the pass (real HID events, Release and Debug IME): TextEdit, Safari, Chrome
textarea and contenteditable, Terminal (zsh line editor), VS Code, the host onboarding (cold start →
prompt → Allow → selected → try-it tasks → done), Settings ▸ General/Learning, Erase all. Also
checked: switching the input source while a word is marked commits it once; a click commits once;
right ⌘ + A is not a flip. The input menu lists 선택한 텍스트 한↔A 변환 (enabled), but the
conversion itself was not exercised live.

## What changed in round 2

### Engine (`Packages/DuoCore/Sources/DuoCore/Engine`)

- **Direct mid-word** (engine-1): when the profile becomes Direct while a word is marked, the word is
  committed before the next key passes.
- **An explicit Korean choice beats the literal rule** (engine-2): after a flip or a one-shot Korean
  word, `@`, `_` and `www.` keep that reading (`ㅠ_ㅠ`) instead of entering L.
- **L ends in more places** (engine-3): besides whitespace, also when Backspace deletes the trigger
  (tracked as a UTF-16 count), on arrows and navigation keys, on ⌘/⌃/fn shortcuts and on ⌥⌫.
  Forward Delete keeps L. The flip still does nothing in L.
- **Explicit commits check the client first** (engine-4): `commit(_:)` asks `markedRange()` for every
  reason, so nothing is inserted twice and no ghost appears in a cleared field. Caps Lock and fn
  commits resync after a 1 s pause.
- **Caps Lock as the flip key** (engine-5, imk-4): with the lock on, the engine inserts letters itself,
  in their typed case, for the eager English tail, L, Direct and the letter after `.`.
- **⇧Space as the flip key** (engine-6, engine-7): in L it is a plain space that ends L; autorepeats
  are swallowed.
- **Learning store hardening** (safety-2, safety-4): votes are capped at 1000 and raw keys at
  64 UTF-8 bytes, and non-finite or negative values are dropped. A vote of 1e20 used to crash the
  IME. Snapshot and eviction sort plain keys: about 5 ms at the 20 000-entry cap, down from about
  57 ms. Eviction now goes down to 95 %.
- **Clients that ignore replacement ranges** (qa-3): `ClientProfile.canReplaceCommittedText` is false
  for the Monaco editors (VS Code, Insiders, Cursor, VSCodium, Windsurf, Code OSS) and for
  `replacement == .none`. There a flip of committed text shows "cannot change" instead of duplicating
  it, and no last-word chip is offered.
- **Terminal last-word flip** (qa-2, the lead's fix): the word is measured back from the caret, and the
  flip checks the text. New tests model Terminal's trailing `selectedRange`.

### Input method (`DuoInputMethod`, `DuoKit/HUD`)

- **Modifier routing** (qa-1, imk-1): Chromium's duplicate `flagsChanged` events are dropped. The
  window-server counters tell a chord (⌘C routed to the menu) from a tap, and a key already counted
  is carried over to the next change. A global monitor covers clients that never forward modifiers.
- **Menu**: choosing an app profile commits the word first (imk-2). The selection converter beeps
  when there is nothing to convert and keeps the composition (hud-5).
- **Marked-range probe** (imk-5): a client that misreports its marked range is detected after its first
  mark, and its words are never dropped as if it had cleared them.
- **DebugInjector** (safety-8): it injects only while DuoHarness is frontmost and its own text view is
  the client, and it re-checks before every key.
- **HUD**: the chip is measured after layout and snapped to device pixels (hud-1). The Bilingual badge
  stays up while you type (hud-2). Feedback no longer lets an alternative skip the 300 ms pause
  (hud-3). The HUD hides on a Space switch and on a display change (hud-4). VoiceOver announces
  flip-key feedback: cannot change, the next word's language, one-shot cancelled, Bilingual on/off
  (hud-6).

### Persistence and installer (`DuoKit`)

- **`learning.json` recovery** (imk-6, safety-1): bad entries are skipped one at a time and
  out-of-range values repaired. If anything was left out, or the file is a newer format, the original
  is copied to `learning.corrupt-<UTC>.json`. An unreadable file is moved there before any write.
- **Write failures** (safety-6) are logged, and `LearningWriter.flush()` returns whether the file
  holds everything scheduled.
- **Settings** (safety-7): `appProfiles` decode one app at a time. Saving keeps keys and profiles this
  build cannot read, and `update()` writes only what changed. `SettingsContract.swift` changed only
  inside its decoder; the public API is the same.
- **Installer** (safety-5, host-6): the bundle is copied to `DuoInputMethod.app.installing`, swapped in
  with `replaceItemAt`, and only then is the old server stopped. The installer waits up to 4 s for it
  to exit.
- **Reconnect after install** (qa-4): after an install, an update or "Duo 다시 시작" while Duo is
  selected, the host switches to another enabled keyboard source and back about 0.3 s apart, so the
  frontmost app reconnects. `install-ime.sh` swaps with two renames, waits for the old server, and
  prints a reminder, because it cannot re-select the source itself.

### Host app (`Duo`, `DuoKit/Host`)

- **Learning edits** (safety-3): one user action is one edit. The commands are planned
  (`LearningEditor.commands(forgetting:stored:)`) and sent in bursts of 50, each confirmed by
  ping → pong, which stays below the ~256-post distributed notification queue. Without the IME there is
  one read and one atomic write. Forgotten rows stay hidden until the file no longer lists them.
- **Learning pane**: votes are clamped (safety-2, host side). The 횟수 column became 확신도 /
  Strength, a bar on the detector's log scale (host-12). The table reloads on `learningChanged` and
  when the app becomes active (host-8).
- **Practice and playground**: task 3 ticks on any flip of the word being typed (host-1). ⌘/⌃ menu
  shortcuts reach the engine first, so right ⌘ + C is a chord (host-3). Switching between engine and
  native mode keeps every character (host-4). The canvas is a VoiceOver text area and announces flips
  (host-10, VoiceOver half).
- **Install and onboarding**: a failure the user fixed in the input menu shows as done. The enable
  step waits for the system prompt, then selects (host-2). The auto-advance moves only from the enable
  step (host-5). Reopening keeps a minimized onboarding window on its step (host-7). Settings opens
  from `--duo-show-settings` and `com.inkyuoh.Duo.host.showSettings` (host-7). Polling runs only while
  someone can see it (host-9). ⏎ and Esc work on the enable step (host-11). The Apps pane always shows
  its section (host-13). The license link follows the app language (host-14).

### Integration (this pass)

- **Input menu ▸ "Duo 설정…"** calls `HostRequest.showSettings()`, so Settings opens even before
  onboarding is finished (host's request). The unused `HostApp` helper is gone.
- **IME learning writes** (host-8, safety-3, safety-6, safety-4, IME halves):
  - every `LearningWriter` write posts `learningChanged`, so an open Learning pane also follows what the
    IME learns while typing;
  - host commands are applied in memory at once, in order (the ping barrier still holds), and a burst
    costs one snapshot and one write, 100 ms after it ends. `LearningStore.remove`/`removeAll` (and
    `LearningStore.apply(_:)`) now return whether anything changed, and a burst that changed nothing
    writes nothing;
  - a failed save posts `learningChanged` with `ok = "false"` (`LearningChangedNotice`), and
    Settings ▸ 학습 says "학습 파일을 저장하지 못했어요. 디스크 공간과 권한을 확인해 주세요.";
  - the SIGTERM/quit flush logs "learning flushed" only when the write succeeded;
  - the startup log uses `learning.count` instead of building a snapshot.
- **Erase all deletes the recovery copies**: `LearningFile.removeBackups(besides:)` runs on a posted
  `removeAll` and on the host's direct erase-all. The copies hold words the user asked to forget.
  Removing single words keeps them.
- **Client calls outside an IMK callback** (risk from engine-4): the TIS source-change commit, menu
  actions and the global-monitor modifier path bind the client with `outsideCallback`. There a client's
  "nothing marked" no longer drops our marked word, because answers can be stale (live QA in TextEdit).
  This keeps the pre-round-2 behaviour on those paths. The marked-range probe is not run outside a
  callback either.
- **Bilingual badge after a flip that does nothing** (the IME track's API wish): `handleModifier`
  restores the badge as `handle` does. Before, a flip-key tap over literal text, or over a word with no
  other reading, cleared the badge while the line stayed bilingual, and VoiceOver said
  "직접 입력으로 돌아감".
- **ModifierRouter's rules moved to DuoKit** (`ModifierRouting.CopyFilter`, `.ActivityCounter`) with
  unit tests; the IME still has no test target. The behaviour is unchanged. The test for imk-1's
  carry-over fails with the round-1 rule.
- **Key DSL**: `{press:rcmd}` … `{release:rcmd}` hold a modifier, so the injector and its mirror can
  type chords such as right ⌘ + C. The injector and mirror share `KeyScript.flagsMasks`.
- **11 new E2E cases**: deleting `/` or `@` ends L; ⌘A ⌫ ends L; an arrow ends L; `ㅠ_ㅠ` and `ㅠ@ㅠ`
  after flips; right ⌘ + C after a word and while composing, then a real tap that still flips;
  right ⌘ + ⇧; re-opened eager English flipped there and back. Against the round-1 engine, the 6
  literal cases fail in the mirror. The chord cases guard the engine path, where the injector's keys
  always reach `engine.handle`.

## Live-QA facts (verified by the lead in real apps)

The apps were TextEdit, Safari, a Chrome textarea and contenteditable, Terminal with the zsh line
editor, and VS Code.

- Chromium hands every `flagsChanged` to the IME twice, about 2 ms apart. The IMK copy has no device
  bits and a later timestamp than the global monitor's.
- IMK client calls made outside an IMK `handle()` callback (for example from a global NSEvent
  monitor) see a stale cached `selectedRange` and a nil `attributedSubstring` in TextEdit.
- Terminal positions are UTF-16 units, not cells, but `selectedRange` trails until the shell echoes.
- VS Code/Monaco ignores `replacementRange` for both `setMarkedText` and `insertText`. Chrome, Safari,
  TextEdit and Terminal honour it.
- After the IME is reinstalled, running apps stay bound to the dead server until the source is
  re-selected while they are frontmost.

## Known issues and limitations

- **Reconnecting after a reinstall.** After `make install` or `install-ime.sh`, apps that were using Duo
  type plain ABC until Duo is re-selected while they are frontmost (⌃Space twice, or the menu bar), or
  until focus moves to another app and back. The script prints this reminder. The host app's
  install, update and restart do the re-selection themselves (`InputSourceManager.reselect`). Even
  then, apps in the background reconnect only on their next focus change.
- **Enabling goes through macOS's own prompt (fixed after round 2).** `TISEnableInputSource` on an
  unapproved third-party source opens System Settings ▸ Keyboard with "Allow “Duo” to enable “Duo”?";
  Allow writes the `AppleEnabledThirdPartyInputSources` allow-list. The installer used to write that
  list itself. Duo then typed, but macOS never put it in the menu-bar input menu (its items showed
  under the "Korean" header, with 2-Set Korean checked), and app switches could drop it. The installer
  now only calls enable and stops with `.enableFailed(noErr)` while the prompt is up; `InstallRecovery`
  waits up to 30 s for Allow (a refused enable shows its error after 2 s). Verified live: after
  disable → enable → Allow, Duo is listed in the menu with no logout, and stays mode-less (R19 not
  needed). A machine enabled the old way recovers the same way (or through 제거 and 켜기 in the app).
- **Outside-callback answers.** Menu actions, the TIS source-change commit and the monitor path all
  run outside `handle()`. They now trust our own mark, but `selectedRange` and `attributedSubstring`
  there can still be stale. Live check: in TextEdit, select text with the mouse and choose
  선택한 텍스트 한↔A 변환. If it beeps, the action sees the stale cache. Also switch the input source away
  while a word is marked; the word must be committed once.
- **E2E is the injector path**: keys reach the live controller, so marks and inserts travel the real
  IMK → NSTextInputClient path, but TSM key routing is not exercised (critique U1). What it cannot
  cover:
  - the window-server chord check (imk-1), because injected keys are not counted;
  - Chromium's duplicates;
  - cases that need other settings: ⇧Space or Caps Lock as the flip key, a Direct profile, autorepeat.
  These are covered by unit tests only.
- **Not verified live in this pass** (the rules allow no control of other apps):
  - HUD: chip size on first show and on a 1x display (hud-1); hiding on a Space switch or display
    change (hud-4);
  - VoiceOver: the announcements (hud-6, host-10);
  - the `misreports its marked range` log line, which a normal client should never trigger (imk-5);
  - host app: ⌘C/⌘A in the playground in engine mode; deleting 300+ learned rows with the IME running;
    a minimized onboarding window on step 3 reopened from the Dock; the U5 prompt wait; "Duo 설정…"
    before onboarding is finished;
  - Critique U1–U9 remain open.
- **DET beats the UX expectation** (scenario rows kept as `withKnownIssue`, critique R8):
  - `gg` and `rt` after English become ㅎㅎ / ㄱㅅ;
  - `eeee` at sentence start stays Latin;
  - `roffjrtlS24` becomes 갤럭신24 (Hangul followed by Latin in one token is unsupported).
- **ㅠㅠ / ㅜㅜ display Latin while typing** (`bb`/`nn`). The commit is correct and the flip chip appears.
- **SPEC wording trails the engine**, and the lead should update it:
  - §4.6: the new L endings, and `@`/`_`/`www.` after a Korean choice;
  - §4.5: ⇧Space in L and its autorepeat;
  - §4.8.6 / §4.9: commit checks `markedRange()` for every reason; Caps Lock and fn resync;
  - §4.3.5 / D9: with the Caps Lock flip key and the lock on, the engine inserts letters;
  - §4.10: `canReplaceCommittedText` and the Monaco list. VSCodeInsiders, VSCodium, Windsurf and Code OSS
    stay `.automatic`: the table lists only VS Code and Cursor as English-first;
  - detection.md §5.5: eviction to 95 %, the vote and raw-length caps.
- **No IME unit-test target.** The pure routing rules are now tested in DuoKit. The IMK adapter
  (`IMKTextClient` probe, outside-callback binding), the menu, DebugInjector confinement, `DuoRuntime`'s
  learning writes and the HUD panel are build-verified and covered by live E2E only.
- **Learning file policy.** A `learning.json` newer than version 1 loads what this build can read, is
  rewritten as version 1 on the next change, and its original is kept as a `learning.corrupt-*.json`
  copy. These copies are deleted only by Erase all.
- **`terminateRunningServer()` blocks** for up to 4 s while it waits for the old server (plus about
  0.3 s to re-select). The host calls it off the main thread.
- **Playground model**: `BufferTextClient` treats Caps Lock + ⇧ on a letter as lowercase, but macOS ABC
  gives uppercase. No test relies on it.
- **`LearningWriter` debounce tests use real sleeps**: they are stable here but could flake on a loaded
  CI machine.

## Logs

The subsystem is `com.inkyuoh.inputmethod.Duo`. The categories are `runtime`, `ime`, `menu`, `hud`,
`learning` (recovery, write failures) and `install` (copy failures, a server that did not exit).
Typed text is never logged at persisted levels, and no diagnostic logging is left in the sources.

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "com.inkyuoh.inputmethod.Duo"'
```

## How to run

```sh
make project                      # xcodegen generate --quiet
Tools/scripts/build.sh DuoInputMethod Debug   # also DuoHarness, Duo; Duo Release
make test                         # swift test (debug), scratch build/spm
cd Packages/DuoCore && swift test -c release --scratch-path ../../build/spm-rel   # + benchmarks
xcodebuild test -project Duo.xcodeproj -scheme Duo -destination 'platform=macOS' -derivedDataPath build/dd
make install                      # Debug IME → ~/Library/Input Methods (stops the old server)
make e2e                          # install + harness + live run; report in build/e2e/report.json
Tools/scripts/e2e.sh -e "dkssud{space}"       # one-off live script
Duo/Tools/check-strings.py build/dd/Build/Intermediates.noindex/Duo.build/Debug/Duo.build
```

- **Before a live run**: `make e2e` selects Duo and takes focus for under a minute. The harness restores
  the previous input source afterwards. Learning is isolated, and the user's `learning.json` is put back.
- **If a run is killed**: restore the source by hand by selecting
  `com.apple.inputmethod.Korean.2SetKorean` with TIS.
- **New E2E cases**: add them to `Tests/E2E/cases.json` and run `make test` first.
  `E2ECaseMirrorTests` replays them in-process with the real model, with the same learning order as the
  live run. A flip in one case is learned for the later ones, so use a word no earlier case flips.
- **Key DSL** (`DuoKit/KeyScript.swift`):
  - literal characters;
  - `{space} {S-space} {ret} {tab} {esc} {bs} {del}` and the arrows;
  - modifier taps such as `{rcmd}`, and `{caps}`;
  - chords such as `{cmd+a}`;
  - held modifiers: `{press:rcmd}c{release:rcmd}`;
  - `{wait:ms}` and `{click}`.
