"""Duo -- 두벌식 (KS X 5002) keystroke <-> Hangul conversion.

Keystrokes are represented exactly as the characters the ABC (US) layout
would have produced: lowercase letter = unshifted key, uppercase letter =
Shift+key.  So "PRdmf" means Shift+P, Shift+R, d, m, f.

The automaton is deliberately simple and deterministic so the Swift
implementation can be bit-exact (see docs/research/detection.md, section 3):
  * consonants never combine while no vowel is present ("ㄱ"+"ㅅ" -> "ㄱㅅ")
  * vowels combine (ㅗ+ㅏ=ㅘ ...) with or without an initial consonant
  * 도깨비불: a final consonant moves to the next syllable when a vowel
    follows; a compound final splits and only its 2nd part moves
  * ㄸ ㅃ ㅉ can never be a final consonant
  * anything that cannot be part of a syllable is emitted as a
    compatibility jamo ("orphan")
"""

from __future__ import annotations

# --- key tables -----------------------------------------------------------

KEY_TO_JAMO = {
    "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ",
    "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
    "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ",
    "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
    "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
    "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ",
}
SHIFT_MEANINGFUL = set("qwertop")  # shifted form differs in 두벌식
JAMO_TO_KEY = {v: k for k, v in KEY_TO_JAMO.items()}

CHO = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"
JUNG = "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ"
JONG = [""] + list("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
CONSONANTS = set("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
VOWELS = set(JUNG)

VOWEL_COMBINE = {
    ("ㅗ", "ㅏ"): "ㅘ", ("ㅗ", "ㅐ"): "ㅙ", ("ㅗ", "ㅣ"): "ㅚ",
    ("ㅜ", "ㅓ"): "ㅝ", ("ㅜ", "ㅔ"): "ㅞ", ("ㅜ", "ㅣ"): "ㅟ",
    ("ㅡ", "ㅣ"): "ㅢ",
}
VOWEL_SPLIT = {v: k for k, v in VOWEL_COMBINE.items()}
FINAL_COMBINE = {
    ("ㄱ", "ㅅ"): "ㄳ", ("ㄴ", "ㅈ"): "ㄵ", ("ㄴ", "ㅎ"): "ㄶ",
    ("ㄹ", "ㄱ"): "ㄺ", ("ㄹ", "ㅁ"): "ㄻ", ("ㄹ", "ㅂ"): "ㄼ",
    ("ㄹ", "ㅅ"): "ㄽ", ("ㄹ", "ㅌ"): "ㄾ", ("ㄹ", "ㅍ"): "ㄿ",
    ("ㄹ", "ㅎ"): "ㅀ", ("ㅂ", "ㅅ"): "ㅄ",
}
FINAL_SPLIT = {v: k for k, v in FINAL_COMBINE.items()}
NOT_FINAL = set("ㄸㅃㅉ")


def compose(cho: str, jung: str, jong: str = "") -> str:
    return chr(0xAC00 + (CHO.index(cho) * 21 + JUNG.index(jung)) * 28 + JONG.index(jong))


class Automaton:
    """Incremental 두벌식 automaton.  feed() one jamo at a time."""

    __slots__ = ("out", "cho", "jung", "jong", "orphans")

    def __init__(self) -> None:
        self.out: list[str] = []
        self.cho = ""
        self.jung = ""
        self.jong = ""
        self.orphans = 0  # orphan jamo already flushed to out

    # -- helpers --
    def _flush(self) -> None:
        if self.cho and self.jung:
            self.out.append(compose(self.cho, self.jung, self.jong))
        elif self.cho:
            self.out.append(self.cho)
            self.orphans += 1
        elif self.jung:
            self.out.append(self.jung)
            self.orphans += 1
        self.cho = self.jung = self.jong = ""

    def flush(self) -> None:
        self._flush()

    def literal(self, ch: str) -> None:
        self._flush()
        self.out.append(ch)

    def feed(self, j: str) -> None:
        if j in CONSONANTS:
            if self.cho and self.jung:
                if not self.jong:
                    if j in NOT_FINAL:
                        self._flush(); self.cho = j
                    else:
                        self.jong = j
                else:
                    comb = FINAL_COMBINE.get((self.jong, j))
                    if comb:
                        self.jong = comb
                    else:
                        self._flush(); self.cho = j
            else:  # empty, cho-only or vowel-only
                self._flush(); self.cho = j
        else:  # vowel
            if self.jong:  # 도깨비불
                sp = FINAL_SPLIT.get(self.jong)
                if sp:
                    self.jong, moved = sp
                else:
                    moved = self.jong; self.jong = ""
                self._flush(); self.cho = moved; self.jung = j
            elif self.jung:
                comb = VOWEL_COMBINE.get((self.jung, j))
                if comb:
                    self.jung = comb
                else:
                    self._flush(); self.jung = j
            else:  # empty or cho-only
                self.jung = j

    def pending_is_lone_consonant(self) -> bool:
        return bool(self.cho) and not self.jung

    def pending_orphan(self) -> int:
        return 1 if (bool(self.cho) != bool(self.jung)) else 0

    def text(self) -> str:
        """Committed text + rendering of the pending block (non-destructive)."""
        if self.cho and self.jung:
            tail = compose(self.cho, self.jung, self.jong)
        else:
            tail = self.cho or self.jung
        return "".join(self.out) + tail


def korean_normalize(keys: str) -> str:
    """Shift on keys whose shifted 두벌식 jamo is identical is dropped."""
    return "".join(c if (c.islower() or c == "'" or c.lower() in SHIFT_MEANINGFUL) else c.lower() for c in keys)


def keys_to_hangul(keys: str) -> tuple[str, int, bool]:
    """Returns (text, orphan_count_total, trailing_lone_consonant).

    orphan_count_total counts every compatibility jamo in the output
    (including a trailing one).  Non-letter characters are emitted literally
    and break syllable composition.
    """
    a = Automaton()
    for c in korean_normalize(keys):
        j = KEY_TO_JAMO.get(c)
        if j is None:
            a.literal(c)
        else:
            a.feed(j)
    lone = a.pending_is_lone_consonant()
    orph = a.orphans + a.pending_orphan()
    return a.text(), orph, lone


def hangul_to_keys(word: str) -> str | None:
    """Canonical 두벌식 key sequence for a Hangul string (None if impossible)."""
    out = []
    for ch in word:
        o = ord(ch)
        if 0xAC00 <= o <= 0xD7A3:
            s = o - 0xAC00
            cho, jung, jong = CHO[s // 588], JUNG[(s % 588) // 28], JONG[s % 28]
            out.append(JAMO_TO_KEY[cho])
            for v in VOWEL_SPLIT.get(jung, (jung,)):
                out.append(JAMO_TO_KEY[v])
            if jong:
                for f in FINAL_SPLIT.get(jong, (jong,)):
                    out.append(JAMO_TO_KEY[f])
        elif ch in JAMO_TO_KEY:
            out.append(JAMO_TO_KEY[ch])
        elif ch in VOWEL_SPLIT:
            out.extend(JAMO_TO_KEY[v] for v in VOWEL_SPLIT[ch])
        else:
            return None
    return "".join(out)


def is_hangul_word(w: str) -> bool:
    return bool(w) and all(0xAC00 <= ord(c) <= 0xD7A3 or 0x3131 <= ord(c) <= 0x3163 for c in w)


def roundtrip_keys(word: str) -> str | None:
    """Keys for `word` only if the automaton reproduces `word` exactly."""
    k = hangul_to_keys(word)
    if k is None:
        return None
    return k if keys_to_hangul(k)[0] == word else None


if __name__ == "__main__":
    tests = [
        ("dkssudgktpdy", "안녕하세요"), ("ekfrrhrl", "닭고기"), ("rkqt", "값"),
        ("rkqtdl", "값이"), ("rkqtl", "갑시"), ("dlTek", "있다"), ("dlTdj", "있어"),
        ("rhkr", "곽"), ("dnjs", "원"), ("zzz", "ㅋㅋㅋ"), ("bb", "ㅠㅠ"),
        ("rt", "ㄱㅅ"), ("hk", "ㅘ"), ("rkk", "가ㅏ"), ("Ehrqo", "똑배"),
        ("rkE", "가ㄸ"), ("rkEk", "가따"), ("dmlwk", "의자"), ("ahfmrpTek", "모르겠다"),
        ("goTtmqslek", "했습니다"), ("sjrt", "넋"), ("sjrtl", "넉시"), ("go", "해"),
        ("so", "내"), ("tk", "사"), ("dhksfyehldjTtmqslek", "완료되었습니다"),
    ]
    for k, want in tests:
        got = keys_to_hangul(k)[0]
        assert got == want, (k, got, want)
        if is_hangul_word(want) and want not in ("ㄱㅅ",):
            assert roundtrip_keys(want) is not None or want in ("가ㅏ", "가ㄸ"), want
    print("hangul self-test OK")
