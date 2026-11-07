# Duo: Interaction and UX Specification (v1)

Status: decided spec for v1 implementation. Owner: UX track. Target: macOS 26 Tahoe, InputMethodKit, Swift 6.
Every decision below gives the chosen behavior and a one-line rationale. Items marked **(verify)** need a quick QA check on a real machine; they do not change the design.

---

## 0. Decisions at a glance

| # | Topic | Decision | Rationale |
|---|---|---|---|
| D1 | What the user sees | **WYSIWYG.** The committed text is always exactly what was on screen (marked text) at the moment of commit. Duo never silently converts a word at the boundary. | Users of MS Office 한/영 자동 고침 most dislike conversions they never saw happen. |
| D2 | Composition model | A word is a **token** that moves through phases: **U** (undecided, whole token marked) → **E** (English decided, commit eagerly, pass the rest of the letters raw) / **K** (Korean decided, behaves exactly like Apple 2-Set: finished syllables commit, only the current syllable stays marked) / **L** (literal: URL, email, path or code, commit and pass raw until whitespace). | Keeps marked text short, so autocomplete, search-as-you-type, terminals and web "Enter" handling behave the same as they do with Apple's own Korean IM. |
| D3 | Flip key | **Right ⌘ tap** by default (press and release under 300 ms with nothing in between). Alternatives in Settings: Right ⌥ tap, Double ⇧ tap, ⇧Space, Caps Lock (experimental). **Never Tab.** | The right thumb is on it, it is almost never used alone, many Korean Mac users already map Right ⌘ to 한/영, and it cannot collide with typing. |
| D4 | Flip semantics | One key, context-sensitive: (a) composing → swap the current token to its alternative and lock it; (b) caret right after a word Duo just committed → replace that word (replacementRange); (c) nothing to flip → force the language of the **next** word (one-shot) and show a 한/A badge. | Fits both habits: "fix what I typed" and the old "press 한/영 first, then type". |
| D5 | Undo of a conversion | Flip is its own inverse (tap again). **Backspace is never overloaded.** It always deletes, and right after a commit the HUD offers "flip last word". | Overloading Backspace changes how fast people delete, and most users would find that surprising. |
| D6 | Learning | Each explicit flip records a vote on the exact typed key string (case-sensitive). One flip wins on the next occurrence unless the model is extremely sure; two flips always win. Votes have a 60-day half-life. | Corrections should stick quickly (iOS-like), but one accidental flip of "the" should not break it. |
| D7 | Secure input | If `IsSecureEventInputEnabled()` is true, Duo never composes and never shows the HUD. Keys pass through raw. | Marked text in a password field would show the password, and a Hangul conversion would break it. |
| D8 | Terminals | Default profile **Direct**: keys pass straight through. Right ⌘ tap enters Bilingual for the current line, and Return or Esc returns to Direct. | vim, less, fzf, htop and REPLs need every key immediately, and Korean in a shell is the exception. |
| D9 | Caps Lock | Caps Lock ON = **English lock** (raw uppercase, no composition). | Korean has no case, so ALL-CAPS is unambiguous English intent and needs no new concept. |
| D10 | Mixed words | Supported automatically: English stem + Korean suffix (API를, React컴포넌트, push했어), and Korean + English when a capital letter starts the English part (갤럭시S24). Other Korean→English joins are scoped out, and the user commits with → before continuing. | Particles attached to English nouns are everywhere in Korean writing, especially for developers. |
| D11 | Digits | Digits always commit the pending token and pass through. Letters after a digit start a new token with a counter/unit prior (3시, 10개, 3pm, 4K). | Digits are never ambiguous, and the counter/unit prior handles the common cases. |
| D12 | HUD | A Liquid Glass capsule under the caret shows the one alternative plus the flip-key glyph. It appears only when ambiguity is real (alternative ≥ 20%) and the user pauses for 300 ms. Once shown it stays until commit, and it never appears during autorepeat, in secure input, in Direct mode or with an invalid caret rect. | Teaches the feature without flashing on every word. |
| D13 | Menu bar | No extra MenuBarExtra. Duo uses only the input menu (`IMKInputController.menu()`). | One icon in the menu bar is the Apple way. |

---

## 1. Research findings

### 1.1 iOS/iPadOS bilingual keyboards (the reference experience)
- Multilingual typing dates to iOS 10: with two keyboards added, prediction and autocorrect work for both languages without switching ([AppleInsider](https://forums.appleinsider.com/discussion/193710), [Cult of Mac](https://www.cultofmac.com/how-to/how-to-set-up-multilingual-typing-in-ios-10)). Apple's guide wording: *"you can type in two languages without having to switch between keyboards… automatically switches between the two languages you use most often"*, and the feature is not available for all languages ([Apple iPhone User Guide](https://support.apple.com/en-ph/guide/iphone/iph73b71eb/ios)).
- **iOS 18 added a Korean + English "multiscript" keyboard** (WWDC24: "type Korean and English characters in a unified experience") ([TechCrunch](https://techcrunch.com/2024/07/02/apple-adds-support-for-new-languages-across-lock-screen-keyboard-and-search-on-ios-18), [WWDC24 10185 notes](https://wwdcnotes.com/documentation/wwdc24-10185-build-multilingualready-apps/)). Behavior reported by Korean users ([extrememanual](https://extrememanual.net/54072)):
  - QWERTY keys with **Hangul as the main label and a small Latin letter at the top right**, and **no 한/영 key**.
  - The language is inferred from the letter sequence. For example "ghdrlfehd" → 홍길동.
  - The suggestion bar is the correction channel (pick the intended word). That is the iOS analog of Duo's HUD + flip.
  - It is set up as a Korean keyboard layout option "이중 언어 (한국어 및 영어)".
- Known complaints about the iOS bilingual keyboard:
  - "constantly fighting me in the wrong language", and autocorrect stuck in one language ([r/iOSBeta](https://lr.eu.psf.lt/r/iOSBeta/comments/1dcvps5/ios_18_db1_now_supports_multilingual_keyboard)).
  - Compound vowels hard to type ([Apple Community KR](https://discussionskorea.apple.com/thread/256109234)).
  - Web/UIKit apps misbehaving with the bilingual keyboard's composition: `onChange` firing several times and stale text when apps mutate `text` during composition ([dev forum 765324](https://developer.apple.com/forums/thread/765324), [767894](https://developer.apple.com/forums/thread/767894)).
  - **Lessons:** keep composition semantics identical to the plain Korean IM wherever possible (D2), and give the user one reliable manual override (D3).
- Apple's dev guidance: avoid mutating text during marked text. `textInputContextIdentifier` lets keyboards remember language per context (Messages example). Duo's per-app prior is the Mac analog.

### 1.2 macOS 26: no bilingual Korean/English mode exists
- No Apple bilingual or auto-switch typing on macOS was found. The zsh-hangul author also notes that the iPhone has a bilingual keyboard and the Mac does not ([GeekNews](https://news.hada.io/topic?id=22660)).
- What macOS 26 does have:
  - Input-source switching via Caps Lock, Globe/fn, ⌃Space (previous source) and ⌃⌥Space (next source) ([Apple Korean IM guide, macOS 26](https://support.apple.com/ar-bh/guide/korean-input-method/him001/104/mac/26)).
  - "Automatically switch to a document's input source" ([Apple](https://support.apple.com/en-au/guide/mac-help/mchl84525d76/26/mac)).
- Tahoe-era switching bugs:
  - ⌃Space needs 2–3 presses ([thread](https://discussions.apple.com/thread/256254361)).
  - Switching fails in Open/Save dialogs after 26.3 ([thread](https://discussions.apple.com/thread/256247006)).
  - The source reverts when focus changes ([thread](https://discussions.apple.com/thread/256144071)).
  - Duo's single-source model avoids this whole class of problems. That is a selling point for onboarding.

### 1.3 Apple's macOS Korean 2-Set input method (parity baseline)
From Apple's guide for macOS 26 ([him001](https://support.apple.com/ar-bh/guide/korean-input-method/him001/104/mac/26)) and common knowledge of its behavior:
- Layouts: 2-Set (default), 3-Set, 3-Set 390, GongjinCheong Romaja, HNC Romaja.
- Settings: candidate font size; Hanja input format; **"Delete by: Jaso (letter by letter while composing) or Gulja (whole syllable)"**.
- **Option-Return** = Hanja conversion of the longest match before the cursor. Esc closes the candidate window and restores the text.
- Caps Lock switching is a system option: "Use the Caps Lock key to switch to and from [last used Latin input source]". It is unreliable with third-party IMs ([daleseo](https://daleseo.com/macos-korean-input/)).
- **Only the current syllable is marked.**
  - Space, Return, Tab, arrows, punctuation, Esc and ⌘/⌃ shortcuts commit the syllable and then the key acts normally (pass-through).
  - A click or focus change commits.
  - Backspace while composing removes one jamo (Jaso mode). After commit, the app deletes whole syllables.
- The **` key types ₩** in 2-Set, and there is no option to turn this off. Developers patch it with `~/Library/KeyBindings/DefaultKeyBinding.dict` (`"₩" = ("insertText:", "`");`) ([gist](https://gist.github.com/redism/43bc51cab62269fa97a220a7bb5e1103), [daleseo](https://daleseo.com/macos-korean-input/)).
- Vim problem: normal-mode commands are plain letters, so a Korean IM composes them (gureum has a "Vi-mode: Esc switches to Roman" option) ([daleseo/gureum](https://daleseo.com/gureum/), [gureum source](https://github.com/gureum/gureum)).
- Web/Electron "Enter while composing" bugs are widespread:
  - Last character re-sent or dropped: a Claude Code VS Code extension ([PR](https://gh.r-mj.com/andrepimenta/claude-code-chat/pull/146)), Warp terminal ([issue 8919](https://upd.dev/warpdotdev/warp/issues/8919): "Native macOS apps are NOT affected", workaround: press → before Enter), and Firefox ([1632597](https://bugzilla.mozilla.org/show_bug.cgi?id=1632597)).
  - **Implication:** apps are tuned for "one marked syllable then Enter". Duo must not mark long runs at Return time. That is the reason for D2's eager phases.

### 1.4 Windows / Office "한/영 자동 고침"
- On a word boundary it converts a word typed in the wrong layout ("gksrmf" → 한글). Office has an exception list under 자동 고침 옵션 → 예외 항목 → 한/영 자동 고침, and the setting is shared by Word, Excel, PowerPoint and Outlook ([wikidocs](https://wikidocs.net/228455), [bluesharehub](https://bluesharehub.com/엑셀-한영-자동고침-옵션해제-한영-자동변환데이터/)).
- Top complaint: product/inventory codes and abbreviations get converted silently ([oppadu](https://www.oppadu.com/shorts/%ec%97%91%ec%85%80-%ed%95%9c%ea%b8%80-%ec%98%81%ec%96%b4-%eb%b0%94%eb%80%9c/)), and the most common advice is "turn it off".
- **Lessons:** no invisible post-hoc conversion (D1); codes, URLs and identifiers go literal (§4.4); learned exceptions replace the exception list (§5.5).

### 1.5 Punto Switcher, Caramba and Korean Mac utilities
- **Punto Switcher (Yandex)** ([Mac help](https://yandex.ru/support/punto-mac), [Mac settings](https://yandex.ru/support2/punto-mac/ru/settings)):
  - Dictionary-based detection. It switches after a few letters "or waits until the word is finished".
  - Hotkey to cancel the last conversion / convert the selection.
  - "Don't switch after Tab and Enter".
  - "Remember layout per application".
  - Rules (never-switch words) with **exact / starts-with / contains** matching and a case-sensitive option.
  - **Self-learning: offers to create a rule after the user cancels auto-switching of the same 3+ letter combination more than once.**
  - Program exclusion list, and sounds for "auto-switch" and "auto-switch cancelled".
  - On Windows the last word is fixed with Pause/Break and the selection with Shift+Break ([habr](https://habr.com/ru/articles/39353/comments/), [overclockers](https://overclockers.ru/softnews/amp/17695/Punto_Switcher_2.9_avtoperekljuchenie_raskladki_klaviatury)).
  - The Pause/Break hotkey conflicts with apps ([Notepad++ forum](https://community.notepad-plus-plus.org/post/93621)).
- **Caramba Switcher** (by Punto's author) ([lifehacker](https://lifehacker.ru/caramba-switcher/), [iguides](https://www.iguides.ru/main/os/caramba_switcher/)):
  - **One single setting** instead of Punto's 96.
  - Double ⇧ re-switches the last word, and ⌥⇧ converts the selection.
  - It recognizes passwords.
  - It turns itself off in games and programming environments.
  - User comments complain about unwanted hotkey triggers in browser forms.
- **Korean Mac tools:**
  - Enko: select text, press a hotkey, dkssudgktpdy→안녕하세요 ([App Store](https://apps.apple.com/kr/app/enko-%EC%98%81%ED%95%9C-%EC%98%A4%ED%83%80-%EB%B3%80%ED%99%98%EA%B8%B0/id6746715150?l=ko)).
  - LangSwitcher (open source; KakaoTalk→Korean, Terminal→English) ([damoang](https://damoang.net/macmoang/7280)).
  - Input Source Pro (per app and per website) ([GitHub](https://github.com/Sailfishc/inputsourcepro)).
  - zsh-hangul: converts mistyped Hangul commands (ㅊㅇ→cd), **skips text inside quotes**, skips pasted text and skips AI tools ([GeekNews](https://news.hada.io/topic?id=22660)).
  - A late-1990s IE toolbar turned ㅈㅈㅈ into "www." (same thread).
- **Lessons:**
  1. Strong defaults and very few settings (Caramba).
  2. Per-app memory (Punto, LangSwitcher).
  3. Learn from repeated cancellations (Punto).
  4. Never touch passwords or code (Caramba).
  5. Fix the last word with one key (all of them).
  6. Selection conversion is a separate, deliberate action (Enko).

### 1.6 Failure modes and the countermeasure for each

| Failure mode seen in the wild | Duo countermeasure |
|---|---|
| Silent conversion of codes, abbreviations or URLs | WYSIWYG (D1). L phase for URL/email/path/code. Digit rules. Learned overrides. |
| Wrong language "fights" the user | Hysteresis while typing (§2.4). A flip locks the token. Learning (§5.5). |
| Passwords converted | Secure input bypass (D7). Mixed-token rules. Terminal Direct profile. |
| Enter duplicating or dropping the last composed text in web apps | Eager E/K phases keep at most one syllable (or ≤2 lookahead keys) marked at Return, the same as Apple 2-Set. |
| Vim/TUI keys swallowed by composition | Direct profile in terminals (D8). Esc commits and passes through. |
| Hotkey conflicts (Pause/Break, Shift+Space, Tab) | Right ⌘ tap detected from flagsChanged. The modifier event is never consumed. |
| Hard to undo | Flip toggles. Cmd+Z still works because commits are plain inserts. |

---

## 2. Core model

### 2.1 Terms
- **Key event**: a `keyDown` NSEvent delivered to `handle(_:client:)`. Duo works on **keys** (keyCode + Shift state), not characters. It maps them to the US QWERTY Latin letter and to the 두벌식 jamo:
  - `q ㅂ w ㅈ e ㄷ r ㄱ t ㅅ y ㅛ u ㅕ i ㅑ o ㅐ p ㅔ`
  - `a ㅁ s ㄴ d ㅇ f ㄹ g ㅎ h ㅗ j ㅓ k ㅏ l ㅣ`
  - `z ㅋ x ㅌ c ㅊ v ㅍ b ㅠ n ㅜ m ㅡ`
  - Shifted: `Q ㅃ W ㅉ E ㄸ R ㄲ T ㅆ O ㅒ P ㅖ`. Every other shifted letter gives the base jamo, the same as Apple.
- **Token**: the maximal run of letter keys (plus joiners, §4.2) since the last boundary.
- **Interpretation**: the Hangul string (2-Set automaton output) or the Latin string (the literal letters with case) of a token, or a 2-segment mix (§4.5).
- **Commit**: `client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))`.
- **Mark**: `client.setMarkedText(attr, selectionRange: NSRange(location: attr.length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))`.

### 2.2 Phases of a token

| Phase | Entered when | What is marked | What is committed | Flip |
|---|---|---|---|---|
| **U** Undecided | Token starts. Both hypotheses are alive and the loser's posterior is ≥ 1%. | The whole token, shown in the current best interpretation. | Nothing yet. | Swap the marked text. Always works. |
| **E** English decided | The Korean parse is structurally dead (§2.3), or P(KO) < 1% after ≥ 2 keys, or a capital letter on a non-QWERTOP key and P(KO) < 5%. | At most the ≤2-key **suffix lookahead** after a complete English word (§4.5). Otherwise nothing. | The Latin prefix, eagerly. Later letters pass through raw (`handle` returns false). | Replace the committed range plus the marked part via replacementRange, if the client supports it (§5.3). |
| **K** Korean decided | P(EN) < 1% after ≥ 2 keys, or learned KO for this key string. | The current syllable only (Apple 2-Set parity). | Finished syllables, eagerly, exactly like Apple 2-Set. | Same as E. |
| **L** Literal | URL/email/path/code trigger (§4.4). | Nothing. | The token as Latin (marked Hangul is replaced if needed), then raw pass-through until whitespace or Return. | Disabled (HUD hidden). |

Rules:
- Phases only move forward within a token (U→E, U→K, U→L, E→L), except for the E→K suffix split (§4.5), which starts a new sub-token.
- Thresholds (1%, 5%, 2 keys) live in one `PhasePolicy` struct and are tuned by the engine track.
- In the **Direct** profile (terminals by default) there are no tokens at all. Every key passes through.

### 2.3 Structural validity of a Korean parse
The Korean hypothesis is **well-formed** if the automaton output matches `JamoRun? Syllable* JamoRun?`:
- `JamoRun` = one or more consonant-only jamo, or ㅠ/ㅜ-only jamo. Examples: ㅋㅋ, ㅠㅠ, ㅇㅋ, and the leading ㅋㅋㅋ in "ㅋㅋㅋ좋아".
- A trailing lone consonant is always allowed because it is "in progress".

The hypothesis is **dead** (it can never become well-formed by appending) if:
- a standalone vowel appears anywhere except inside a ㅠ/ㅜ run (e.g. `h`→ㅗ at token start, `o`→ㅐ after a vowel-final syllable when no compound vowel exists), or
- an orphan consonant sits between two syllables.

Dead-in-U immediately forces E. In K phase a later typo does **not** flip to English. It shows jamo like Apple does, because Korean was already decided.

### 2.4 Display stability (hysteresis)
- In U phase, the displayed language changes mid-token only if (a) the displayed hypothesis becomes dead, or (b) the other hypothesis beats it by **Δ ≥ 1.0 logit** (about 73/27).
- The first key of a token shows the language given by the context prior (§6).
- After an explicit flip the token is **locked**: no automatic re-interpretation until commit.
- Backspace never changes the displayed language. Deleting keys only re-runs the automaton inside the displayed language.

---

## 3. Key handling table

Legend:
- **No comp**: no token in progress.
- **U**: token marked.
- **E/K**: partially committed.
- **Pass** means `handle` returns `false`, so the app gets the key after Duo commits. Apple 2-Set uses the same order, so apps' existing Korean-IME workarounds apply.
- **Consume** means `handle` returns `true`.
- "Commit-as-shown" means commit the marked text exactly as displayed (D1).

| Key class | No comp | U phase (token marked) | E / K phase | Consumed? |
|---|---|---|---|---|
| Letter a–z | Start a token (§6 prior). In L phase or Direct profile: pass raw. | Append the key and re-interpret with hysteresis. Update the HUD. | E: pass raw (unless suffix lookahead, §4.5). K: run the 2-Set automaton, commit finished syllables, mark the current one. | Consume (E raw: Pass) |
| Shift+letter | Same as a letter. A capital on a non-QWERTOP key (A S D F G H J K L Z X C V B N M U I Y) adds **+2.0 logit English** evidence. Shift+Q/W/E/R/T/O/P adds none (ㅃㅉㄸㄲㅆㅒㅖ). | Same. A lower→upper transition inside a token (camelCase) adds +3.0 English. | Same as letter. | Consume |
| Digits 0–9 (main row) | Pass. Set `afterDigit` context for the next token (§6.4). | Resolve the token (single-jamo token with no vowel → Latin, e.g. v1, x2; otherwise commit-as-shown), then pass. | Commit the marked syllable or lookahead, then pass. | Pass |
| `'` apostrophe | Pass (opening quote). | If the displayed language is EN or U-with-EN-alive: buffer as a **tentative joiner** (§4.2). If KO is displayed: commit-as-shown, then pass. | E: tentative joiner. K: commit, then pass. | Joiner: Consume. Otherwise Pass. |
| `-` hyphen | Pass. | Same as apostrophe (e-mail, well-known, co-founder). | Same. | as above |
| `.` period | Pass. | Tentative joiner if not Korean-decided. The next key decides: a letter makes the token **dotted** → L phase (node.js, e.g., github.com). Space, Return, punctuation or a digit makes it sentence punctuation: commit-as-shown + ".". | K: commit, then pass (다.그래서 keeps working). | as above |
| `@` | Token-start `@` → L phase (mentions, @user). | `@` attached to letters → the whole token becomes **literal Latin** (marked Hangul is replaced with the Latin keys) → L. | E/K: replace committed Hangul via replacementRange when supported, otherwise leave it. Then L. | Pass after L switch |
| `/` `~` `:` `_` `\` `=` `?` `&` `#` `%` (code/URL chars) | Token-start `/` `~` `:` `\` → L (slash commands, paths, :emoji:). Token-start `#` → **not** literal (Korean hashtags #맛집). | `_` or `://` after letters → L. `/` or `:` after an EN-displayed token → tentative joiner (a letter or digit next → L). After a KO-displayed token: commit, then pass (그/그녀). | Same rules. | Pass (joiner: Consume) |
| Other punctuation `, ; ! ? ( ) [ ] { } " < > \| + * ^ $` | Pass. | Commit-as-shown, then pass. | Commit, then pass. | Pass |
| ` (grave) | Pass. Types ` (setting "` key types ₩" defaults to OFF; when ON, ` gives ₩ and ⌥` gives `). | Commit, then pass. | Commit, then pass. | Pass |
| Space | Pass. | Commit-as-shown, then pass the space. | Commit the marked part, then pass. | Pass |
| Shift+Space | Pass (space). | Default: same as Space. If chosen as the flip key: flip (§5) and consume. | Same. | Pass / Consume if flip |
| Return, keypad Enter, ⇧Return | Pass. | Commit-as-shown, then pass. Reset momentum to the app prior in chat-class apps (message sent). | Commit, then pass. In the Terminal profile: leave Bilingual and go back to Direct. | Pass |
| ⌥Return | Pass. | Commit, then pass (reserved for Hanja conversion in v2). | Commit, then pass. | Pass |
| Tab, ⇧Tab | Pass. | Commit-as-shown, then pass (completion and form navigation still work). | Commit, then pass. | Pass |
| Escape | Pass. | Commit-as-shown, then pass (vim leaves insert mode, dialogs close). Next-token prior gets an English bias in Code/Terminal profiles. | Commit, then pass. Terminal profile: back to Direct. | Pass |
| Backspace (⌫) | Pass. If the caret is right after the last Duo commit (+ boundary), the HUD shows the "flip last word" chip (§7). | Remove the last **keystroke** and re-run the automaton in the displayed language: jamo-level in Korean (닭→달→다→ㄷ), letter-level in English. If the buffer becomes empty: `setMarkedText("")` and **consume** (do not delete an extra character). | Delete from the marked part first. When the marked part is empty: pass, and pop one committed key from the token history (Korean: one syllable's keys) so flip stays accurate. | Consume while marked, otherwise Pass |
| ⌥⌫, ⌘⌫ | Pass. | Commit, then pass (deletes the just-committed word or line, as intended). | Commit, then pass. | Pass |
| Forward Delete (fn⌫, keypad Del) | Pass. | Commit, then pass. | Commit, then pass. | Pass |
| ← → ↑ ↓ | Pass. | Commit-as-shown, then pass. **→ at the end of text = "commit without space"** (the documented way to join 앱+store). | Commit, then pass. | Pass |
| Home, End, PgUp, PgDn, F1–F19 | Pass. | Commit, then pass. | Commit, then pass. | Pass |
| ⌘+any key | Pass. | Commit-as-shown, then pass (⌘A, ⌘C, ⌘V, ⌘Z and ⌘S act on committed text). | Commit, then pass. | Pass |
| ⌃+any key (emacs bindings, ⌃C in terminals) | Pass. | Commit, then pass. | Commit, then pass. | Pass |
| ⌥+letter / ⌥+digit (å ∫ ç ∂ ™ £ ¢) | Pass (the system's U.S. layout makes the character). If it is a **dead key** (⌥e ⌥` ⌥u ⌥i ⌥n), the **next key also passes raw** so é, ü and ñ compose. | Commit, then pass. | Commit, then pass. | Pass |
| ⌃⌘Space (emoji), Globe/fn tap | Pass. | On a `flagsChanged` with `.function` or a ⌃⌘Space keyDown: commit first so the emoji lands after the word, then pass. | Same. | Pass |
| Caps Lock toggle (`flagsChanged`, keyCode 57) | ON: English lock, every letter passes raw (uppercase from the layout). | Commit-as-shown first, then enter the lock. | Same. | Never consumed |
| Right ⌘ tap (default flip) | Flip (§5.2 case c or b). | Flip the token (§5.2 case a). | Flip the whole token (§5.3). | `flagsChanged` is **never consumed**. The tap is detected and acted on. |
| Other modifier presses (⇧ ⌃ ⌥ ⌘ alone) | Ignored. | Ignored (a held ⇧ does not commit). | Ignored. | Never consumed |
| Numeric keypad digits and operators | Pass. | Commit, then pass. | Commit, then pass. | Pass |
| Key autorepeat (`event.isARepeat`) | Letters: append as normal (ㅋㅋㅋㅋ by holding z). Backspace: per-keystroke delete, then pass-through deleting once the buffer is empty. Arrows and others: as above. | HUD is suppressed while repeats arrive and re-evaluated 300 ms after the last repeat. | Same. | as base key |
| Mouse click anywhere, focus change, app switch, ⌘Tab | n/a | `commitComposition(_:)` commits as shown. If the client already unmarked the text (it kept the string), just sync state and do not insert twice. | Same. | n/a |
| Secure input active (`IsSecureEventInputEnabled()`) | Return `false` for **everything**, with no HUD. If a token was in progress when secure input turned on: commit it first. | Same. | Same. | Pass |

Implementation notes:
- `recognizedEvents(_:)` returns `Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)`.
- Key codes (Carbon `kVK_*`): Return 36, Tab 48, Space 49, Delete 51, Escape 53, RightCommand 54, Command 55, Shift 56, CapsLock 57, Option 58, Control 59, RightShift 60, RightOption 61, RightControl 62, Function 63, KeypadEnter 76, ForwardDelete 117, Home 115, End 119, PageUp 116, PageDown 121, ←123 →124 ↓125 ↑126, Grave 50.
- Device-side modifier bits in `modifierFlags.rawValue`: LCmd 0x08, RCmd 0x10, LShift 0x02, RShift 0x04, LAlt 0x20, RAlt 0x40, LCtl 0x01, RCtl 0x2000.
- Dead-key detection: `UCKeyTranslate` with the U.S. `kTISPropertyUnicodeKeyLayoutData`. A non-zero `deadKeyState` after ⌥+key sets `passNextKeyRaw = true`.
- State resync: on every `handle`, if Duo believes it has marked text but `client.markedRange().location == NSNotFound` (the app cleared the field, e.g. Slack after send), drop the token silently. Do not re-insert.

---

## 4. Word-boundary and buffering rules

### 4.1 What is buffered
- **Buffered**: letter keys (with Shift state) and tentative joiners `' - . : /` (only under the conditions in §3).
- **Never buffered**: digits, whitespace, Return, Tab, other punctuation, ⌥ characters, and keypad keys.
- **Cap**: 32 keys per token. On the 33rd key, force the phase decision (best hypothesis), commit it and continue, so a held key or a long run never becomes a giant underline.

### 4.2 Tentative joiners (`'`, `-`, `.`, `:`, `/` after English)
- A joiner is appended to the marked text as itself. The next key resolves it:
  - **Letter** → the joiner joins the token and the token is English/literal:
    - `'` and `-` → English continues (don't, I'm, e-mail).
    - `.` `:` `/` → L phase (node.js, localhost:3000, github.com/foo).
  - **Anything else** → the joiner was punctuation: commit the token as shown, then the joiner, then handle the new key.
- **Rationale:** the joiner is always shown and resolution never changes what is already on screen, except that a Hangul display that was still U can become Latin. That case is the expected one for URLs.

### 4.3 Korean-decided tokens never take joiners
- In K phase, `.` `'` `-` `/` `:` commit and pass (했다.그래서, '안녕', 그/그녀, 참고: 내용).
- **Rationale:** Korean prose uses these characters as punctuation, and an inside-word Korean joiner basically does not exist.

### 4.4 Literal (L phase) triggers
These are strong signals, and any one is enough:
1. Token-start `/`, `~`, `\`, `:`, `@`. Also `./` and `../`.
2. `@` immediately after letters (email local part). The token becomes Latin even if it was showing Hangul (dkssud@ → dkssud@).
3. `://` anywhere. `www.` at token start.
4. A dotted token: letter `.` letter where the token before the `.` was EN or U-with-EN-alive.
5. `_` inside a token (snake_case, SCREAMING_CASE).
6. A token containing ≥ 2 case transitions or mixing letters with code characters (`=`, `<`, `>`, `{`, `}` attached).

In L phase Duo commits the token and passes every key raw until Space, Tab or Return, so address-bar and Slack autocompletion get real characters.
- Paste never goes through the IME, so pasted URLs are unaffected.
- `#` at token start is **not** literal: Korean hashtags are common, and English hashtags resolve on their own (#general → E phase at the 2nd key).

### 4.5 Mixed-language tokens (segmentation)
- **EN→KO (automatic).** In E phase, once the committed Latin prefix forms a **complete English unit**, Duo opens a lookahead when a consonant key arrives (q w e r t a s d f g z x c v and ⇧QWERT). A complete English unit is:
  - a lexicon word,
  - an all-caps acronym ≥ 2 letters,
  - a Capitalized or camelCase word, or
  - a learned word.
- The lookahead key is **marked** (≤ 2 keys) and displayed as:
  - Latin, if the context momentum is English;
  - the jamo, if the momentum is Korean or the prefix is an acronym (API, PR, URL).
- When the next key is a vowel key and "prefix + these keys" is not a plausible English continuation (not a lexicon prefix), the lookahead becomes a new **K-phase sub-token** (React + 커 → React컴포넌트, API + 르 → API를, push + 해 → push했어).
- If the continuation is plausible English (pushed, Reacts, users), the lookahead keys commit as Latin.
- A vowel key right after the English prefix can never start Korean, so it passes raw (username, Reactive).
- **KO→EN (automatic only on a capital).** In K phase, a ⇧+non-QWERTOP letter starts an English sub-token (갤럭시S24, 아이폰Pro is resolved by deadness, 카톡ID).
- **KO→EN otherwise (scoped out in v1).** "앱store" typed in one go shows Korean jamo garbage. Documented workaround: type 앱, press →, then type store. A v2 candidate keeps orphan jamo runs marked so they can be re-segmented.
- **Max 2 segments per token in v1.**
- **Rationale:** English stem + Korean particle or 하다-verb covers the overwhelming majority of real mixed tokens, and the capital rule covers product names.

### 4.6 Identifiers and code
- **camelCase** (useState, getElementById): English by the transition rule. The Korean parse usually dies within 1–3 keys, so E phase commits eagerly and IntelliSense sees real characters.
- **snake_case**: L (rule 5).
- **kebab-case** (my-component): English via the hyphen joiner.
- **Dotted** (`os.path`, `self.view`): L.
- In **Code-profile apps**, Korean stays fully available (comments and strings): the prior only shifts the ambiguous words.

---

## 5. The flip mechanism

### 5.1 Flip key choice

| Candidate | Verdict | Reason |
|---|---|---|
| **Right ⌘ tap** | **Default** | Reached by the right thumb without moving the hand. Used alone it does nothing in macOS. A common Karabiner mapping for 한/영 on Mac, so the muscle memory exists. Detected from `flagsChanged` without TCC. |
| Right ⌥ tap | Alternative | Same properties. It suits keyboards whose right ⌘ is awkward (some external keyboards). |
| Double ⇧ tap (within 300 ms) | Alternative | Caramba precedent. A single ⇧ tap is too accidental, a double is fine. |
| ⇧Space | Alternative, off by default | Fast typists still hold ⇧ when they hit Space after a capital or after ㅆ (갔 + Space), so accidental flips are real. Windows refugees can enable it. |
| Caps Lock | Experimental alternative | The LED toggles, Apple keyboards add a caps-lock delay that swallows quick taps, and the system "Use Caps Lock to switch…" option can steal it. When it is chosen, D9 (English lock) is disabled. |
| Tab | **Rejected** | Shell/IDE completion, form navigation and indentation. |
| ⌃Space / ⌃⌥Space | **Rejected** | System input-source shortcuts that are intercepted before the IME. |
| Globe/fn | **Rejected** | Owned by the system (emoji / change input source / dictation). |

**Tap detection (exact):**
1. Arm on a `flagsChanged` where `keyCode == 54` and the RCmd device bit becomes set, with no other modifier held.
2. Disarm if any `keyDown` arrives, any other modifier changes, more than 300 ms pass (configurable 200–500 in Advanced), or `NSEvent.pressedMouseButtons != 0` at release (⌘-click).
3. Fire on the release `flagsChanged` (the RCmd bit is cleared) while still armed.
4. Never consume the `flagsChanged` event, so apps keep a correct modifier state.

### 5.2 Flip semantics (one key, three cases, checked in this order)

**(a) A token is in progress (U, E or K phase).**
- Replace the token's on-screen text with its top alternative and **lock** the token in that language. Do not commit: the user can keep typing (go → 해, then `s` → 핸).
- In U phase only marked text changes, so it always works. In E/K phase see §5.3.
- A second tap flips back and keeps the lock.
- The alternative is the best interpretation of the other language. For a mixed token it is all-Latin.

**(b) No token, and the caret is right after the last Duo commit.**
- Conditions: same client, `client.selectedRange()` equals the location recorded after the commit, and no key other than modifiers, Backspace over the boundary character, or flips has happened since.
- Replace that committed word and keep the boundary character: "go␣" → "해␣", "안녕␣" → "dkssud␣". The boundary is not retyped.
- This also applies when the user Backspaced over the trailing space (caret right after the word).
- Validity window: until the next letter key, click, focus change, or 30 s.

**(c) Nothing to flip.**
- Arm a **one-shot language for the next token** that is the opposite of the current context prior. The HUD shows a 한 or A badge for 900 ms, and the next token starts locked in that language.
- A second tap cancels.
- In the Terminal profile, (c) toggles Direct ↔ Bilingual for the line instead (§6.6).

**Selection conversion is deliberately not on a single tap.** If the user holds ⌘ meaning to copy, changes their mind and releases, a single tap would rewrite their selected text.
- Instead: the input-menu item **"선택한 텍스트 한↔A 변환"** (Convert Selected Text) and an optional **double tap** of the flip key while a selection exists.
- Selection conversion uses the 2-Set mapping both ways (dkssud ↔ 안녕) and is capped at 2,000 characters.

### 5.3 Replacing committed text (cases a in E/K, and b)
1. Compute the expected range: `R = NSRange(location: caret - boundaryLen - committedLen, length: committedLen)`.
2. Verify: `client.attributedSubstring(from: R)?.string == committedText`. If `selectedRange()` returns `NSNotFound`, the client cannot do random access.
3. On success: `client.insertText(newText, replacementRange: R)`, then restore the caret after the boundary. Cocoa clients do this naturally because the replacement keeps the following text.
4. On failure (Terminal, some Java/Qt apps, games): do nothing to the text and show the HUD message **"여기서는 바꿀 수 없어요 · Can't change text here"** for 1.2 s. Remember `replacementUnsupported` per bundle ID for the session, so the HUD stops offering case (b) there.
- **Rationale:** never guess and never send synthetic Backspaces. That would need Accessibility and could corrupt text.

### 5.4 "Undo auto-conversion"
- With WYSIWYG there is no hidden auto-conversion, so undo is just flip:
  - while composing → case (a);
  - right after commit → case (b).
- After an **uncertain commit** (the alternative had P ≥ 35%), the HUD shows the "flip last word" chip **without being asked** for 1.6 s, the analog of the iOS/macOS autocorrect revert bubble.
- Backspace right after a commit also brings the chip back.
- Backspace itself is never redefined (D5): after a commit it deletes the space and then whole syllables or letters, exactly like Apple 2-Set and ABC.
- ⌘Z works as in any app, because commits are ordinary inserts.

### 5.5 Learning
- **Key**: the exact typed Latin string of the whole token, including case, after the commit (e.g. `go`, `Go`, `zzz`, `dkssud`).
- **Mixed tokens**: the learned key is the segment the user flipped.
- **Store**: `[key: LearnedEntry(ko: Double, en: Double, lastUsed: Date)]`.
- **Events**:
  - Explicit flip committed in language X: `X += 1.0`. If the user flips and then deletes the whole token, nothing is learned.
  - Implicit acceptance (committed without a flip while the HUD was showing an alternative ≥ 20%): `displayed += 0.25`.
  - Flipping back within the same token cancels the vote.
- **Decay**: half-life 60 days, applied lazily at read time: `count * 0.5^(age/60d)`. Entries below 0.1 in both languages are evicted. LRU cap of 50,000 entries.
- **Bias added to the engine logit** (positive = Korean): `β·(ln(1+ko) − ln(1+en))` with β = 3.0.
  - One flip gives ≈ 2.1 logit, which overturns anything but very confident cases.
  - Two flips give ≈ 3.3 logit, which wins for practically any token.
  - The engine treats a learned margin > 2.0 as a lock-in for live display too.
- **Never learned**:
  - L-phase tokens;
  - tokens typed under secure input;
  - Direct mode;
  - tokens of length 1;
  - when "학습 일시 정지" (Pause Learning) is on;
  - per-app learning disabled for that app.
- **Scope**: learning is **global**. Per-app memory is only a prior (§6.5), which keeps the user's corrections consistent everywhere.
- **Rationale for no confirmation**: Punto asks after two cancellations, but a quiet learn is the Apple way. The Settings ▸ Learned Words list keeps it inspectable and reversible.

---

## 6. Context rules

All context enters the engine as a **prior logit** for the next token (positive = Korean). The total prior is clamped to ±2.5, so structural and lexical evidence still dominates.

### 6.1 Language momentum
- `prior = appPrior + momentum`, where `momentum = clamp(λ · lastWordSign · 1.5, ±1.5)`.
- `lastWordSign` is +1 for Korean and −1 for English.

| Situation | λ |
|---|---|
| Same sentence | 0.7 |
| After `. ! ? …` followed by a space | 0.4 |
| After a newline | 0.3 |
| After Return in a chat-class app (a message was sent) | 0 (reset to the app prior) |
| After focus change or app switch | 0 |
| After a one-shot flip (§5.2c) | The next token is locked. Momentum then follows its result at λ = 0.9. |

### 6.2 Sentence start
- No special Korean prior. English evidence arrives naturally from capitalization (non-QWERTOP capitals give +2.0).
- Sentence-start capitals on QWERTOP keys (So, To, We, Tom) get +1.0 English instead of 0, because T, W and Q at sentence start are far likelier to be English capitals than ㅆㅉㅃ.

### 6.3 Parentheses and quotes
- `(` directly attached to a Korean word (컴포넌트(component)) gives −0.8 (English gloss pattern).
- A quote character resets momentum to the app prior (quoted text is often the other language).
- After the closing bracket or quote, the momentum of the text before it is restored.

### 6.4 After digits (`afterDigit` context)
- The next token is scored with a **counter/unit table**:
  - **Korean counters** (+2.0 KO if exact): 시 분 초 개 명 번 등 위 층 살 원 만 억 천 백 일 월 년 주 회 차 배 장 권 잔 병 대 마리 시간 개월 주년 분기 학년 박 퍼센트 도.
  - **English units** (+2.0 EN if exact): am pm st nd rd th px pt em rem ms s h m k K M G GB MB KB TB x D fps Hz kHz GHz mAh mm cm km kg g ml L.
- A single-jamo result with no vowel after a digit resolves to Latin (2x, 3D, 4K).

### 6.5 Per-app profiles and learned per-app bias
- The profile is chosen by `client.bundleIdentifier()`.
- `appPrior = profilePrior + learnedAppBias`.
- `learnedAppBias = clamp(EMA(lastWordSign, α=0.05) · 1.0, ±1.0)` is stored per bundle ID and updated at each commit (not in L phase).

| Profile | Default prior | Default apps (bundle IDs; verify the IDs) |
|---|---|---|
| **Direct** (terminal) | n/a: raw keys, Bilingual on demand | com.apple.Terminal, com.googlecode.iterm2, dev.warp.Warp-Stable, com.mitchellh.ghostty, net.kovidgoyal.kitty, org.alacritty, com.github.wez.wezterm, co.zeit.hyper |
| **English-first** (code) | −1.0 | com.apple.dt.Xcode, com.microsoft.VSCode, com.todesktop.230313mzl4w4u92 (Cursor), dev.zed.Zed, com.jetbrains.* (prefix), com.sublimetext.4, com.panic.Nova, com.barebones.bbedit |
| **Korean-first** | +1.0 | com.kakao.KakaoTalkMac, com.hancom.office.hwp* (prefix), jp.naver.line.mac |
| **Automatic** | 0 + onboarding base (§8.1 step 4: 한국어 위주 +0.7 / 반반 0 / English −0.7) | everything else (Slack, Messages, Notion, Safari, Chrome, Mail, Pages…) |

- **Rationale:** Messengers and documents vary by user, so the learned EMA handles them. Only the categories with near-universal behavior get a hard-coded prior.
- The user can override any app in Settings ▸ Apps or from the input menu.

### 6.6 Terminal (Direct) profile details
- **Default**: every key passes raw. Duo is invisible.
- **Flip tap** enters **Bilingual-for-this-line** (the full Duo model with prior 0). The HUD shows a persistent small 한 badge near the caret.
- **Return or Esc** leaves Bilingual and goes back to Direct (gureum vi-mode analog). A second flip tap with no token also leaves Bilingual.
- Users can set a terminal to Bilingual permanently in Settings.
- **Rationale:** interactive TUIs (vim normal mode, less, fzf live filter, htop, Claude Code CLI) need keys immediately, and a Korean commit message is a deliberate act.
- Compatibility flag `returnAsCR` (default off; verify for Warp's dropped-character bug): when Return arrives with a marked syllable in a terminal, commit with `insertText(syllable + "\r")` and consume.

### 6.7 Secure text and passwords
- `IsSecureEventInputEnabled()` (Carbon HIToolbox) is checked at every `handle` and `activateServer`. If true: commit any pending token, then pass everything raw. No marked text, no HUD, no learning.
- Password fields in Cocoa (NSSecureTextField) and in browsers enable secure event input while focused.
- Side effect: apps that keep secure input on globally (Terminal or iTerm2 "Secure Keyboard Entry", some password managers) disable Korean there. Settings ▸ Troubleshooting shows a live row: **"보안 키보드 입력이 켜져 있어 한글 조합이 꺼졌어요 (Terminal ▸ 보안 키보드 입력)"**.
- Passwords in non-secure prompts (sudo in a terminal) are covered by the Direct profile.

### 6.8 Fields that do not support marked text
- If `setMarkedText` leaves `client.markedRange().location == NSNotFound`, mark the client `noMarkedText`.
- From then on Duo uses **commit-immediately** mode for it: finished Hangul syllables commit at once and the current syllable or token is previewed in the HUD only. Flip uses §5.3.

---

## 7. HUD (hint capsule)

### 7.1 What it is
- A borderless **non-activating `NSPanel`**:
  - `styleMask: [.nonactivatingPanel, .borderless]`, `isFloatingPanel = true`, `becomesKeyOnlyIfNeeded = true`, `hidesOnDeactivate = false`
  - `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`
  - `level = max(client.windowLevel() + 1, NSWindow.Level.popUpMenu.rawValue)`
- It hosts SwiftUI through `NSHostingView`. The content uses Liquid Glass: `.glassEffect(.regular.interactive(), in: .capsule)`, or `NSGlassEffectView` in AppKit.
- With Reduce Transparency on, the system substitutes an opaque material. With Increase Contrast, add a 1 px separator stroke.

### 7.2 Content

| State | Content (left → right) |
|---|---|
| U-phase alternative | the alternative text (13 pt, SF Pro / Apple SD Gothic Neo via the system font, `.primary`) · a keycap glyph `⌘` (11 pt, `.secondary`, in a 16×16 rounded keycap; the glyph follows the chosen flip key: ⌘ ⌥ ⇧⇧ ⇧␣ ⇪) |
| Flip-last-word chip (§5.4) | `↺` (11 pt) · the alternative of the last word · keycap |
| One-shot next language (§5.2c) | badge **한** or **A** only (15 pt semibold), 900 ms |
| Terminal Bilingual | persistent small badge **한** (11 pt), at 60% opacity |
| Flip failure | "여기서는 바꿀 수 없어요" (12 pt, `.secondary`), 1.2 s |

- Clicking the alternative text in the capsule performs the flip, like tapping an iOS suggestion.
- The capsule is 26 pt tall with 10 pt horizontal padding and a maximum width of 320 pt (the text truncates in the middle).

### 7.3 When it is shown or hidden
- **Show** when all of these hold:
  - the token is in U phase;
  - P(alternative) ≥ 0.20;
  - the token has ≥ 2 keys, or 1 key if the key is in the collision list (a, i, e, x…);
  - no keystroke for **300 ms**.
- **Once shown, stay up** and update the content in place while the token continues, even through fast typing. Do not hide between keys, to avoid flashing.
- **Hide**: fade out 120 ms on commit, on E/K/L transition, on secure input (immediately, no animation), on focus change, or on Esc.
- **Appear**: fade in 150 ms ease-out plus scale 0.97 → 1.0 (spring response 0.25, damping 0.9). With Reduce Motion: fade only.
- **Content update**: crossfade 100 ms. The width animates with `.smooth(duration: 0.15)`.
- **Uncertain-commit chip**: appears immediately (no delay), lives 1.6 s, then fades over 200 ms. It is cancelled by the next letter key.
- **Never show**:
  - during secure input;
  - in Direct mode (except the explicit 한 badge);
  - during autorepeat;
  - when the caret rect is invalid (zero size, origin (0,0), or off every screen);
  - when "힌트 표시" is off. Failure messages and the terminal badge still show, because they are feedback for an action the user took.
- Full-screen games: they do not use text input clients, so the IME is not engaged. No special rule.

### 7.4 Position
1. `client.attributes(forCharacterIndex: markedStart, lineHeightRectangle: &rect)` returns screen coordinates with a bottom-left origin. Use index 0 of the marked range, or the start of the last committed word for the chip.
2. Place the capsule's leading edge at `rect.minX − 10` (text-aligned) and its top 6 pt below `rect.minY`.
3. If it would cross `screen.visibleFrame.minY`, place it 6 pt above `rect.maxY` instead.
4. Clamp horizontally into `visibleFrame` with an 8 pt inset. Use the `NSScreen` whose frame contains the rect's midpoint.
5. Do not move the capsule while it is visible unless the line rect changes by more than 2 pt. This prevents jitter.

### 7.5 Accessibility
- When VoiceOver is running (`NSWorkspace.shared.isVoiceOverEnabled`), each flip posts `NSAccessibility.post(element: NSApp, notification: .announcementRequested, userInfo: [.announcement: "해, 한국어로 바꿈", .priority: NSAccessibilityPriorityLevel.high.rawValue])`.
- The HUD itself is `accessibilityHidden` so it never steals VoiceOver focus.

---

## 8. Host app: onboarding, settings, input menu

### 8.1 Onboarding (first launch; one window of 640×520 with `.windowStyle(.hiddenTitleBar)` and a Liquid Glass background)
The copy is Korean first, with English shown when the system language is not Korean. Each step has a primary button on the bottom right and a "나중에" (Later) link where relevant.

1. **Welcome.**
   - Hero: a live text field already running the Duo engine in-process (DuoCore linked into the app). An animated demo types `dkssudgktpdy` → "안녕하세요" and `hello` → "hello", then gives the field to the user: "직접 쳐 보세요" (Try it).
   - Title: **"한영 전환 없이, 그냥 쓰세요."** Sub: "Duo는 입력하는 단어를 보고 한국어인지 영어인지 알아서 판단해요."
   - **Rationale:** users try the product before touching System Settings, and it works without TCC.
2. **Add Duo as an input source.**
   - Button "Duo 켜기". It calls `TISRegisterInputSource(bundleURL)`, then `TISCreateInputSourceList` filtered on `kTISPropertyInputSourceID`, `TISEnableInputSource`, `TISSelectInputSource`.
   - On failure, open `x-apple.systempreferences:com.apple.Keyboard-Settings.extension` (verify) with a 3-frame illustrated guide: Text Input ▸ Edit… ▸ + ▸ Korean ▸ Duo.
   - Live status row: "Duo가 켜져 있어요" with a green check, polled through TIS every 1 s.
3. **Make Duo your only keyboard (recommended).**
   - Explain: "다른 입력 소스가 있으면 Caps Lock이나 ⌃Space가 Duo에서 벗어나게 해요."
   - Button "다른 입력 소스 끄기" lists the enabled sources with toggles (2-Set Korean, ABC…) and calls `TISDisableInputSource` for the ones checked.
   - Only allowed if Duo reports `kTISPropertyInputSourceIsASCIICapable == true`. Otherwise keep ABC and explain.
   - Also tell the user to turn off "Caps Lock 키로 ABC 전환", since it cannot be changed programmatically.
4. **Typing style.**
   - Segmented control "주로 쓰는 언어": 한국어 위주 / 반반 / English (sets the Automatic base prior).
   - Toggle "개발자예요 (터미널·코드 에디터 최적화)": ON enables the Direct and English-first profiles, OFF sets every app to Automatic.
5. **Flip key.**
   - Shows a large keyboard illustration with Right ⌘ highlighted: "단어가 잘못 나오면 오른쪽 ⌘를 톡." The prompt asks the user to tap it now.
   - The host app detects the tap with `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)`, which needs no permission inside its own window, and animates a check.
   - If no tap is seen within 8 s: "이 키보드에선 오른쪽 ⌘를 못 찾았어요. 다른 키를 골라 주세요" with the alternatives from §5.1.
6. **Practice (4 tasks, each checked live in the playground field).**
   - "안녕하세요 Duo를 써봐요" (mixed).
   - "macOS 26 업데이트" (digits plus English).
   - Type `go` in a Korean sentence and flip it to 해.
   - Type a wrong word, press Space, then flip the last word.
7. **Done.** "이제 어디서나 그냥 쓰면 돼요." Buttons: "설정 열기", "완료".

### 8.2 Settings window (`NavigationSplitView` with a sidebar, `Form` with `.formStyle(.grouped)`, macOS 26 style; standard ⌘, opens it)
- **일반 (General)**
  - Flip key: picker with the §5.1 choices. Tap window: Advanced slider 200–500 ms.
  - 힌트 표시 (Show hints): on.
  - "애매한 단어 확정 후 되돌리기 제안" (uncertain-commit chip): on.
  - 백스페이스 단위 (Backspace while composing): 자소 (default) / 글자. These match Apple's "Jaso/Gulja".
  - "` 키로 ₩ 입력": off.
  - Embedded "Try it" playground field at the top.
- **앱별 설정 (Apps)**
  - A list of apps seen so far (icon and name) with a profile popup per app: 자동 / 한국어 우선 / English 우선 / 직접 입력 (터미널 방식).
  - A tiny bar shows the learned bias ("최근 한국어 68%").
  - "+" adds an app through an NSOpenPanel on /Applications.
  - "기본값 복원" (restore defaults).
- **학습한 단어 (Learned Words)**
  - A searchable `Table` with columns 입력 키 (dkssud) | 결과 (안녕) | 횟수 | 마지막 사용.
  - Swipe or Delete key removes an entry. "모두 지우기" asks for confirmation.
  - Toggle "학습하기" (learning on).
- **개인정보 (Privacy)**
  - "Duo는 모든 판단을 Mac 안에서 해요. 입력한 문장은 저장하지 않고, 학습에는 단어별 횟수만 남아요."
  - The data location is shown. Buttons: Export (JSON) and Erase. The IME target has no network entitlement.
- **문제 해결 (Troubleshooting)**
  - Live checks: Duo enabled; other sources enabled; Caps Lock switching on; Secure Keyboard Entry active in some app (§6.7); the current app's profile.
  - "Duo 다시 시작" (relaunch the IME process).
- **정보 (About)**: version, acknowledgements, link to help.

### 8.3 Input menu (`IMKInputController.menu()`)
The menu stays short, like Apple's Korean IM menu.

| Item | Behavior |
|---|---|
| **Duo 설정…** | Opens the host app's Settings |
| — | — |
| **현재 앱: ‹App Name›** ▸ (radio) 자동 · 한국어 우선 · English 우선 · 직접 입력 | Writes the per-app profile |
| **선택한 텍스트 한↔A 변환** | §5.2 selection conversion |
| ✓ **힌트 표시** | Toggle |
| **학습 일시 정지** | Toggle (checkmark when paused) |
| — | — |
| **Duo 도움말** | Help page in the host app |

- Info.plist essentials (the infra track confirms them): one input mode named "Duo", `TISIntendedLanguage` = `ko`, and a template icon reading "한A" (16 pt, template, PDF).
- The icon is static: Duo is one source with no visible mode, so the menu bar never "flickers" between 한 and A.

---

## 9. Edge cases (expected behavior = test vectors)

- Keys are US-QWERTY keystrokes and ␣ is Space.
- Context codes: **N** = neutral prior (Automatic, no momentum), **KO+** = Korean momentum, **EN+** = English momentum.
- "→" in the Expected column means "display while typing → committed".

| # | Keys | Context | Expected | Rule |
|---|---|---|---|---|
| 1 | `dkssudgktpdy␣` | N | 안녕하세요␣ (K phase by `dk`, Apple-style syllable commits) | §2.2 |
| 2 | `rkskekfk␣` | N | 가나다라␣ | §2.2 |
| 3 | `gksrmf␣` | N | 한글␣ | §2.2 |
| 4 | `rkatkgkqslek␣` | N | 감사합니다␣ | §2.2 |
| 5 | `hello␣` | KO+ | hello␣ (KO dead at `h` → E, raw) | §2.3 |
| 6 | `Hello␣` | sentence start | Hello␣ | §6.2 |
| 7 | `zzz␣` | N, KO+, or EN+ | ㅋㅋㅋ␣ (jamo-run class prior +2.0 KO beats momentum; learnable) | §2.3, §5.5 |
| 8 | `bb␣` | any | ㅠㅠ␣ | jamo run |
| 9 | `nn␣` | any | ㅜㅜ␣ | jamo run |
| 10 | `gg␣` | KO+ / EN+ | ㅎㅎ / gg (collision list; HUD shows the other) | §6.1 |
| 11 | `dz␣` | any | ㅇㅋ␣ | jamo run |
| 12 | `eeee␣` | N | ㄷㄷㄷㄷ␣ | jamo run |
| 13 | `lol␣` | any | lol␣ (ㅣㅐㅣ dead) | §2.3 |
| 14 | `OK␣` | any | OK␣ (⇧K non-QWERTOP; ㅒㅏ dead) | §3 |
| 15 | `ok␣` | any | ok␣ | §2.3 |
| 16 | `iPhone␣` | KO+ | iPhone␣ (camelCase) | §3 |
| 17 | `macOS␣` | KO+ | macOS␣ | §3 |
| 18 | `IT␣` | KO+ | IT␣ (⇧I strong EN) | §3 |
| 19 | `PR␣` | KO+ | PR␣ (ㅖㄲ dead) | §2.3 |
| 20 | `go␣` | EN+ / KO+ | go␣ / 해␣ (true ambiguity; HUD offers the alternative) | §6.1 |
| 21 | `so␣` `do␣` `to␣` | EN+ / KO+ | so/내, do/애, to/새 (same rule as #20) | §6.1 |
| 22 | `So␣` | any | So␣ (⇧S) | §6.2 |
| 23 | `To␣` | sentence start | To␣ (QWERTOP capital at sentence start +1.0 EN; 쌔 rare) | §6.2 |
| 24 | `a␣` / `I␣` / `i␣` | KO+ | a / I / i (single-letter collision list favors English) | §7.3 |
| 25 | `the␣` / `and␣` | KO+ | the / and (솓, 뭉 are valid but rare) | lexicon |
| 26 | `dl␣` | EN+ | 이␣ (very frequent KO; "dl" weak EN) | lexicon |
| 27 | `Reactzjavhsjsxm␣` | any | React → React컴 → … → React컴포넌트␣ | §4.5 |
| 28 | `APIfmf␣` | KO+ | API → API르 → API를␣ | §4.5 |
| 29 | `PRdptj␣` | any | PR에서␣ | §4.5 |
| 30 | `pushgoTdj␣` | any | push했어␣ | §4.5 |
| 31 | `pushed␣` / `users␣` | any | pushed / users (lookahead commits as Latin) | §4.5 |
| 32 | `roffjrtlS24` | any | 갤럭시S24 | §4.5 capital rule |
| 33 | `dkdlvhs16` | any | 아이폰16 | §3 digits |
| 34 | `doq` → `store` | any | 앱store (→ = commit without space) | §4.5 scope |
| 35 | `doqstore␣` | any | 앱ㄴ색ㄷ… (known v1 limitation; the flip gives all-Latin "doqstore") | §4.5 |
| 36 | `github.com/foo␣` | KO+ | github.com/foo␣ (dotted → L) | §4.4 |
| 37 | `user@example.com` | any | user@example.com | §4.4 |
| 38 | `dkssud@example.com` | any | 안녕 shown, then `@` → dkssud@example.com (the committed "안" is replaced via replacementRange; if the client cannot do that, the result is 안녕@example.com and the HUD says it can't change the text here) | §4.4 rule 2, §5.3 |
| 39 | `~/Library` | any | ~/Library | §4.4 |
| 40 | `https://apple.com` | any | literal | §4.4 |
| 41 | `/help␣` | Slack | /help (slash command raw) | §4.4 |
| 42 | `@minsu` | Slack | @minsu (mention autocompletion works because the keys are raw) | §4.4 |
| 43 | `:smile:` | Slack | :smile: (emoji picker works) | §4.4 |
| 44 | `#aktwlq␣` | any | #맛집␣ (`#` not literal) | §4.4 |
| 45 | `e.g.␣` | KO+ | e.g.␣ | §4.2 |
| 46 | `node.js␣` | any | node.js␣ | §4.2 |
| 47 | `U.S.␣` | any | U.S.␣ | §4.2 |
| 48 | `ek.rmfotj␣` | KO+ | 다.그래서␣ (K phase: `.` commits) | §4.3 |
| 49 | `don't␣` / `I'm␣` | any | don't / I'm | §4.2 |
| 50 | `'dkssud'␣` | any | '안녕'␣ | §4.3 |
| 51 | `e-mail␣` / `my-component␣` | any | e-mail / my-component | §4.2 |
| 52 | `user_name` | any | user_name (L) | §4.4 |
| 53 | `getElementById` | VS Code | raw from the 1st or 2nd key (E phase); IntelliSense live | §4.6 |
| 54 | `3tl␣` | any | 3시␣ | §6.4 |
| 55 | `10ro␣` | any | 10개␣ | §6.4 |
| 56 | `2rodnjf␣` | any | 2개월␣ | §6.4 |
| 57 | `5qns␣` / `1emd␣` / `30ch␣` | any | 5분 / 1등 / 30초 | §6.4 |
| 58 | `3pm␣` / `10am␣` | KO+ | 3pm / 10am | §6.4 |
| 59 | `4K␣` / `5G␣` / `3D␣` | any | 4K / 5G / 3D | §6.4 |
| 60 | `4th␣` | KO+ | 4th (unit table beats 4소) | §6.4 |
| 61 | `iOS26␣` / `macOS␣26` | any | iOS26 / macOS 26 | §3 digits |
| 62 | `v1.2` / `mp3` / `B2B` | KO+ | v1.2 / mp3 / B2B (lone jamo before a digit → Latin) | §3 digits |
| 63 | `rlaalstn␣` | any | 김민수␣ | lexicon / names |
| 64 | `tkvkfl` + Return | Spotlight | 사파리 committed, then Return opens Safari | §3 Return |
| 65 | `Dkssudgktpdy␣` | KO+ | 안녕하세요␣ (an accidental ⇧D is strong but not a veto; HUD offers "Dkssudgktpdy") | §3 Shift |
| 66 | `dlTek␣` / `rkTek␣` | any | 있다 / 갔다 (⇧T = ㅆ) | §2.1 |
| 67 | `ekfr` then ⌫⌫⌫⌫ | any | 닭 → 달 → 다 → ㄷ → (empty, ⌫ consumed) | §3 Backspace |
| 68 | `dkssud␣` then ⌫ | any | the space is deleted (passed through); the HUD chip shows "↺ dkssud ⌘" | §5.4 |
| 69 | `go` then R⌘ then `s␣` | EN+ | go → 해 (locked) → 핸␣; the learning vote for `gos`=KO | §5.2a |
| 70 | `go␣` then R⌘ | TextEdit | "go␣" → "해␣"; learns `go`=KO +1 | §5.2b |
| 71 | `go␣` then R⌘ | Terminal (Bilingual) | unchanged; HUD "여기서는 바꿀 수 없어요" | §5.3 |
| 72 | R⌘ with an empty field, then `go␣` | EN+ prior | badge 한, then 해␣ (one-shot) | §5.2c |
| 73 | `dkssud12` | password field | dkssud12 raw: no marked text, no HUD, no learning | §6.7 |
| 74 | `ls -al` Return | Terminal | raw (Direct) | §6.6 |
| 75 | R⌘ `qjrm tnwjd` Return | Terminal | 버그 수정 then Return; back to Direct | §6.6 |
| 76 | `dd`, `:wq` | vim in Terminal | raw, executes immediately | §6.6 |
| 77 | Caps Lock on, `asap␣` | any | ASAP␣ raw | D9 |
| 78 | ⌥e then `e` | any | é (dead key; the next key passes raw) | §3 Option |
| 79 | `dkssud` then ⌃⌘Space, pick 😀 | any | 안녕😀 (commit before the picker) | §3 Globe |
| 80 | hold `z` (autorepeat) | KO+ | ㅋㅋㅋㅋㅋㅋ… with no HUD during repeat | §3 autorepeat |
| 81 | `dkssu`, click elsewhere | any | 안녀 committed as shown | §3 mouse |
| 82 | `go`, ⌘A | EN+ | "go" committed, then select all | §3 ⌘ |
| 83 | `gkdl` Return | KakaoTalk / web chat | 하이 sent; only "이" was marked at Return (Apple parity) | §1.3, D2 |
| 84 | 40× `a` without a boundary | any | forced decision at key 33; no giant underline | §4.1 |
| 85 | `dkssud`, the app clears the field (Slack after send) | Slack | state reset silently; no ghost re-insert | §3 resync |
| 86 | `xptmxm` ⇧Space | flip = ⇧Space | 테스트 → flip → "xptmxm" | §5.1 |
| 87 | `xptmxm` ⇧Space | default | 테스트␣ (⇧Space = Space) | §3 |
| 88 | `ehdgo` ⌥Return | any | 동해 committed, then ⌥Return passed (Hanja is v2) | §3 |
| 89 | ` key | any | ` (not ₩) unless the setting is on | §3 |
| 90 | `rt␣` | KO+ / EN+ | ㄱㅅ / rt | collision list |
| 91 | `// APIfmf` | Xcode | // API를 (Korean stays available in English-first apps) | §4.6 |
| 92 | selection "dkssud", menu ▸ 선택한 텍스트 한↔A 변환 | TextEdit | 안녕 | §5.2 |

---

## 10. Implementation and testing notes (no TCC needed)

- **Engine boundary.** DuoCore (a Swift package) exposes a pure reducer:
  - `func reduce(_ state: TokenState, _ input: KeyInput, _ ctx: Context) -> (TokenState, [ClientAction])`
  - `ClientAction` cases: `.mark(String)`, `.commit(String)`, `.replace(range:, with:)`, `.pass`, `.consume`, `.hud(HUDState)`.
  - Every row of §3 and every vector of §9 becomes a Swift Testing case: `@Test(arguments: vectors) func edgeCase(_ v: Vector)`.
- **Fake client.** `protocol TextClient` mirrors the IMKTextInput methods Duo uses: `insertText(_:replacementRange:)`, `setMarkedText(_:selectionRange:replacementRange:)`, `selectedRange()`, `markedRange()`, `attributedSubstring(from:)`, `attributes(forCharacterIndex:lineHeightRectangle:)`, `bundleIdentifier()`, `windowLevel()`.
  - `FakeTextClient` backs it with a String. Configurable `supportsReplacement` and `supportsMarkedText` flags cover the Terminal and Java cases.
  - The real `IMKInputController` subclass is a thin adapter.
- **HUD and onboarding visuals.**
  - Render the SwiftUI views offscreen with `ImageRenderer` for snapshot tests. Liquid Glass may render flat offscreen, so assert layout and text, not pixels.
  - For the host app's own windows, `NSView.bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` captures pixels **without Screen Recording permission**, because it is the app's own view.
- **Tap detector.** Make it a pure state machine fed with `(keyCode, deviceFlags, timestamp, mouseButtons)`. Test the timing edges at 299 / 301 ms, ⌘-click, and ⌘C.
- **Learning store.** Use a JSON file in the app-group container shared by the IME and the host app. Write with a debounce of 2 s. All access goes through an actor.

## 11. Open items for v2
- Hanja conversion on ⌥Return with a candidate window, for parity with Apple.
- KO→EN re-segmentation without a capital (앱store).
- A three-candidate HUD with arrow-key selection for mixed tokens.
- Per-website priors in browsers (needs Accessibility, so out of scope for v1).
- 3-Set layouts.

## Sources
- Apple Korean IM guide (macOS 26): https://support.apple.com/ar-bh/guide/korean-input-method/him001/104/mac/26
- Apple input-source settings (macOS 26): https://support.apple.com/en-au/guide/mac-help/mchl84525d76/26/mac
- Apple iPhone keyboards guide: https://support.apple.com/en-ph/guide/iphone/iph73b71eb/ios
- iOS 18 Korean+English keyboard: https://techcrunch.com/2024/07/02/apple-adds-support-for-new-languages-across-lock-screen-keyboard-and-search-on-ios-18 · https://wwdcnotes.com/documentation/wwdc24-10185-build-multilingualready-apps/ · https://extrememanual.net/54072
- Bilingual keyboard bugs: https://developer.apple.com/forums/thread/765324 · https://developer.apple.com/forums/thread/767894 · https://discussionskorea.apple.com/thread/256109234 · https://lr.eu.psf.lt/r/iOSBeta/comments/1dcvps5/ios_18_db1_now_supports_multilingual_keyboard
- macOS 26 switching bugs: https://discussions.apple.com/thread/256254361 · https://discussions.apple.com/thread/256247006 · https://discussions.apple.com/thread/256144071
- macOS Korean setup, Caps Lock, Vim, ₩: https://daleseo.com/macos-korean-input/ · https://daleseo.com/gureum/ · https://gist.github.com/redism/43bc51cab62269fa97a220a7bb5e1103
- Enter/composition bugs: https://gh.r-mj.com/andrepimenta/claude-code-chat/pull/146 · https://upd.dev/warpdotdev/warp/issues/8919 · https://bugzilla.mozilla.org/show_bug.cgi?id=1632597
- Office 한/영 자동 고침: https://wikidocs.net/228455 · https://www.oppadu.com/shorts/%ec%97%91%ec%85%80-%ed%95%9c%ea%b8%80-%ec%98%81%ec%96%b4-%eb%b0%94%eb%80%9c/
- Punto Switcher: https://yandex.ru/support/punto-mac · https://yandex.ru/support2/punto-mac/ru/settings · https://habr.com/ru/articles/39353/comments/ · https://community.notepad-plus-plus.org/post/93621
- Caramba Switcher: https://lifehacker.ru/caramba-switcher/ · https://www.iguides.ru/main/os/caramba_switcher/
- Korean Mac tools: https://news.hada.io/topic?id=22660 · https://apps.apple.com/kr/app/enko-%EC%98%81%ED%95%9C-%EC%98%A4%ED%83%80-%EB%B3%80%ED%99%98%EA%B8%B0/id6746715150?l=ko · https://damoang.net/macmoang/7280 · https://github.com/Sailfishc/inputsourcepro
