"""Duo language detector -- reference implementation of the runtime algorithm.

Everything here is integer arithmetic in millinats (1/1000 natural-log unit) so
that the Swift port can be bit-exact.  See docs/research/detection.md.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field, asdict

import kn
from hangul import hangul_to_keys, keys_to_hangul, korean_normalize, SHIFT_MEANINGFUL

QWERTOP_UP = set("QWERTOP")

# ------------------------------------------------------------------ params --

@dataclass
class Params:
    # word model: max(ngram + NG_*, lexicon + LEX_*)
    NG_KO: int = -300
    LEX_KO: int = -100
    NG_EN: int = -300
    LEX_EN: int = -100
    ORPHAN: int = -4000          # per orphan jamo (n-gram path only)
    ROLLOVER: int = -1500        # Shift on a non-QWERTOP key adjacent to a shifted QWERTOP key (KO hyp)
    STRAY: int = -7000           # any other Shift on a non-QWERTOP key (KO hyp)
    CASE_LOWER: int = 0
    CASE_INITCAP: int = -2500
    CASE_ALLCAPS: int = -3500
    CASE_MIXED: int = -6000
    CASE_EXACT: int = -300       # exact-case match in the case lexicon (iOS, GitHub, API)
    MIX: int = -1500             # Latin word + attached Korean suffix
    MIX_MIN_LATIN: int = 2       # Latin part length >= 2, or a single uppercase letter (any length after a digit);
                                 # a single lowercase letter only with a table suffix (m에, h의)
    MIX_INITIAL: int = 0         # single uppercase letter + table suffix outside EN context (A씨, B양, C가)
    MIX_GENERIC: int = -6000     # Latin word + any Korean continuation scored by the Korean LM
    TERM_DIGIT_EN: int = 0       # token terminated by a digit ("Q1", "iOS17")
    TERM_HYPHEN_EN: int = 0      # token terminated by '-' ("co-founder", "e-mail")
    # context prior ln P(lang | previous token language)
    PRIOR_START_KO: int = -200
    PRIOR_START_EN: int = -1700
    PRIOR_KO_KO: int = -100
    PRIOR_KO_EN: int = -2300
    PRIOR_EN_KO: int = -1300
    PRIOR_EN_EN: int = -300
    PRIOR_NUM_KO: int = -300     # token immediately preceded by a digit ("3개", "10mm", "20th")
    PRIOR_NUM_EN: int = -1500
    NUM_UNIT_EN: int = 5000      # ctx NUM and lowercase token in the unit list (th, km, GB, fps ...)
    HYST: int = 1500             # display hysteresis margin
    USER_UNIT: int = 2500        # user bonus = USER_UNIT * log2(1+n)  (n capped at 15)

    def prior(self, ctx: str, lang: str) -> int:
        return getattr(self, f"PRIOR_{ctx}_{lang}")

    def to_dict(self):
        return asdict(self)


CASE_LOWER, CASE_INITCAP, CASE_ALLCAPS, CASE_MIXED, CASE_EXACT = range(5)
CASE_NAMES = ["lower", "initcap", "allcaps", "mixed", "exact"]


def case_pattern(s: str, case_lex: set[str]) -> int:
    letters = [c for c in s if c.isalpha()]
    if not any(c.isupper() for c in letters):
        return CASE_LOWER
    if s in case_lex:
        return CASE_EXACT
    if len(letters) >= 2 and all(c.isupper() for c in letters):
        return CASE_ALLCAPS
    if letters[0].isupper() and not any(c.isupper() for c in letters[1:]):
        return CASE_INITCAP
    return CASE_MIXED


def case_cost(p: Params, pat: int) -> int:
    return (p.CASE_LOWER, p.CASE_INITCAP, p.CASE_ALLCAPS, p.CASE_MIXED, p.CASE_EXACT)[pat]


def shift_counts(raw: str) -> tuple[int, int]:
    """(rollover, stray) counts of Shift on keys whose 두벌식 jamo is unaffected by Shift."""
    nr = ns = 0
    n = len(raw)
    for i, c in enumerate(raw):
        if c.isupper() and c.lower() not in SHIFT_MEANINGFUL:
            if (i > 0 and raw[i - 1] in QWERTOP_UP) or (i + 1 < n and raw[i + 1] in QWERTOP_UP):
                nr += 1
            else:
                ns += 1
    return nr, ns


# ------------------------------------------------------------ runtime LM --

def lloyd_codebook(values: list[float], k: int = 256, iters: int = 8) -> list[int]:
    """1-D Lloyd-Max codebook (sorted, integer millinats, unique)."""
    vs = sorted(values)
    if len(set(round(v) for v in vs)) <= k:
        return sorted(set(round(v) for v in vs))
    n = len(vs)
    cb = [vs[min(n - 1, int((i + 0.5) * n / k))] for i in range(k)]
    import bisect
    for _ in range(iters):
        cb = sorted(set(cb))
        mids = [(cb[i] + cb[i + 1]) / 2 for i in range(len(cb) - 1)]
        sums = [0.0] * len(cb); cnts = [0] * len(cb)
        for v in vs:
            j = bisect.bisect_left(mids, v)
            sums[j] += v; cnts[j] += 1
        cb = [sums[i] / cnts[i] if cnts[i] else cb[i] for i in range(len(cb))]
    return sorted(set(int(round(c)) for c in cb))


def uniform_codebook(values: list[float], k: int = 256) -> list[int]:
    """k evenly spaced levels over [min, max] (sorted, integer millinats, unique). Lexicon values use it:
    Lloyd-Max spends its levels on the many rare words and merges the most frequent ones into one
    coarse top level, which is where the detector needs precision (이, 내, the, so)."""
    lo, hi = min(values), max(values)
    return sorted(set(int(round(lo + (hi - lo) * i / (k - 1))) for i in range(k)))


def quantize(v: float, cb: list[int]) -> int:
    """index of nearest codebook value; ties -> lower index"""
    import bisect
    j = bisect.bisect_left(cb, v)
    if j <= 0:
        return 0
    if j >= len(cb):
        return len(cb) - 1
    return j - 1 if (v - cb[j - 1]) <= (cb[j] - v) else j


class RuntimeLM:
    """Integer backoff LM: lp[n][key] -> millinats, bow[n][key] -> millinats."""

    def __init__(self, N: int):
        self.N = N
        self.lp: list[dict[int, int]] = [dict() for _ in range(N + 1)]
        self.bow: list[dict[int, int]] = [dict() for _ in range(N + 1)]
        self.cb_lp: list[list[int]] = [[] for _ in range(N + 1)]
        self.cb_bow: list[list[int]] = [[] for _ in range(N + 1)]
        self.lp_idx: list[dict[int, int]] = [dict() for _ in range(N + 1)]
        self.bow_idx: list[dict[int, int]] = [dict() for _ in range(N + 1)]

    @classmethod
    def from_kn(cls, m: kn.KNModel, codebook: bool = True) -> "RuntimeLM":
        r = cls(m.N)
        for n in range(1, m.N + 1):
            lpm = {k: v * 1000.0 for k, v in m.lp[n].items()}
            bwm = {k: v * 1000.0 for k, v in m.bow[n].items()}
            if codebook:
                cb = lloyd_codebook(list(lpm.values()))
                r.cb_lp[n] = cb
                for k, v in lpm.items():
                    i = quantize(v, cb); r.lp_idx[n][k] = i; r.lp[n][k] = cb[i]
                if bwm or n < m.N:
                    cbb = lloyd_codebook(list(bwm.values()), k=255) if bwm else []
                    # exact 0 must be representable: entries that are not contexts store bow 0
                    if 0 not in cbb:
                        cbb = sorted(cbb + [0])
                    r.cb_bow[n] = cbb
                    for k, v in bwm.items():
                        i = quantize(v, cbb); r.bow_idx[n][k] = i; r.bow[n][k] = cbb[i]
            else:
                r.lp[n] = {k: int(round(v)) for k, v in lpm.items()}
                r.bow[n] = {k: int(round(v)) for k, v in bwm.items()}
        return r

    def cond(self, hist: list[int], w: int) -> int:
        N = self.N
        h = hist[-(N - 1):] if N > 1 else []
        acc = 0
        hk = kn.pack(h)
        n = len(h) + 1
        while True:
            k = (hk << kn.BITS) | w
            v = self.lp[n].get(k)
            if v is not None and not (n == 1 and w == kn.BOS):
                return acc + v
            acc += self.bow[n - 1].get(hk, 0) if n > 1 else 0
            n -= 1
            hk = kn.suffix(hk, n) if n > 1 else 0

    def score(self, keys: str, eos: bool) -> int:
        hist = [kn.BOS]
        t = 0
        for s in kn.syms(keys):
            t += self.cond(hist, s)
            hist.append(s)
        if eos:
            t += self.cond(hist, kn.EOS)
        return t

    def prefix_scores(self, keys: str) -> tuple[list[int], list[int]]:
        """cumulative prefix scores P[i] = score(keys[:i], eos=False) and F[i] = with </s>."""
        hist = [kn.BOS]
        P = [0]; F = [self.cond(hist, kn.EOS)]
        t = 0
        for s in kn.syms(keys):
            t += self.cond(hist, s)
            hist.append(s)
            P.append(t)
            F.append(t + self.cond(hist, kn.EOS))
        return P, F

    def num_entries(self) -> int:
        return sum(len(d) for d in self.lp[1:])


# ---------------------------------------------------------------- model --

@dataclass
class DetectorModel:
    lm_ko: RuntimeLM
    lm_en: RuntimeLM
    lex_ko: dict[str, int]          # korean-normalized keys -> ln P millinats
    lex_en: dict[str, int]          # lowercase latin -> ln P millinats
    case_lex: set[str]              # exact-case strings (iOS, GitHub, API ...)
    suf_full: dict[str, int]        # korean-normalized suffix keys -> ln P(suffix) millinats
    suf_prefix: dict[str, int]      # every prefix of a suffix -> ln sum P millinats
    num_units: set[str] = field(default_factory=set)  # lowercase Latin tokens typical after a digit
    meta: dict = field(default_factory=dict)


# ------------------------------------------------------------- features --

@dataclass
class Feats:
    raw: str
    ko_lm: int
    ko_lex: int | None
    ko_orph: int
    ko_roll: int
    ko_stray: int
    en_lm: int
    en_lex: int | None
    en_case: int
    mix: list  # (b, en_lm, en_lex, en_case, suf, gen, roll, stray, short_ok)
    en_unit: bool = False


KEY_IS_CONSONANT = set("qwertasdfgzxcvQWERT")

# Jamo that chat repeats for laughter and feelings (ㅋㅋㅋ, ㅎㅎ, ㅠㅠ, ㅜㅜ, ㅡㅡ, ㄷㄷ, ㅉㅉ). A run of two or
# more of the same one is not charged as orphans, alone or next to syllables (ㅋㅋㅋ난, 흥해라ㅡㅡ).
EMOTIVE_JAMO = set("ㅋㅎㅠㅜㅡㄷㅉ")
# Jamo chat repeats for emphasis (ㅇㅇㅇㅇ, ㄱㄱㄱ, ㄴㄴㄴ, ㅊㅊㅊ): free from three on. Two of them are often
# part of an abbreviation (ㄱㅇㅇ) and stay in that piece.
REPEAT_JAMO = set("ㅇㄱㄴㅊㅅㅍ")
# ㅠ and ㅜ count as the same jamo in such a run (ㅠㅜㅜ).
CRY_JAMO = set("ㅠㅜ")
# Keyboard-mash laughter: a whole run of these with at least two ㅋ (ㅋㄱㅋㄱㄱㅋ, ㅋㄲㅋㅅㅋ).
MASH_JAMO = set("ㅋㄱㄲㄷㅅㅎ")
# One of these alone right after a syllable (올ㅋ, 굿ㅋ굿).
TRAIL_JAMO = set("ㅋㅎ")


def _is_jamo(ch: str) -> bool:
    return "\u3131" <= ch <= "\u3163"


def _is_syllable(ch: str) -> bool:
    return "\uac00" <= ch <= "\ud7a3"


def jamo_pieces(text: str) -> list[tuple[int, int, bool]]:
    """(start, end, free) for the pieces of every maximal run of jamo in `text`, in order.

    free: not charged as orphans whatever the lexicon says -- the whole run as mash laughter, a single
    ㅋ/ㅎ after a syllable, a run of >= 2 of one emotive jamo (ㅠ = ㅜ) or >= 3 of one repeated jamo. The
    jamo between such runs form one piece each (free = False)."""
    out = []
    n, i = len(text), 0
    while i < n:
        if not _is_jamo(text[i]):
            i += 1
            continue
        j = i
        while j < n and _is_jamo(text[j]):
            j += 1
        run = text[i:j]
        if run.count("ㅋ") >= 2 and all(c in MASH_JAMO for c in run):
            out.append((i, j, True))
        elif j - i == 1 and run in TRAIL_JAMO and i > 0 and _is_syllable(text[i - 1]):
            out.append((i, j, True))
        else:
            start, k = i, i
            while k < j:
                cls = "ㅠ" if text[k] in CRY_JAMO else text[k]
                e = k + 1
                while e < j and ("ㅠ" if text[e] in CRY_JAMO else text[e]) == cls:
                    e += 1
                if (text[k] in EMOTIVE_JAMO and e - k >= 2) or (text[k] in REPEAT_JAMO and e - k >= 3):
                    if start < k:
                        out.append((start, k, False))
                    out.append((k, e, True))
                    start = e
                k = e
            if start < j:
                out.append((start, j, False))
        i = j
    return out


def _lex_piece(m: DetectorModel, piece: str) -> bool:
    return len(piece) >= 2 and m.lex_ko.get(korean_normalize(hangul_to_keys(piece))) is not None


def chat_runs(m: DetectorModel, text: str) -> tuple[int, bool]:
    """(orphans the K reading is not charged for, whether the last character is one of them):
    the free pieces of `jamo_pieces`, and each other piece of >= 2 jamo that is a Korean lexicon word
    (ㄹㅇ, ㅈㄹ, ㅂㅅ): ㅈㄹ하고, 뭔ㅅㅂ, ㄹㅇㅋㅋ."""
    exempt, last = 0, False
    for a, b, free in jamo_pieces(text):
        if free or _lex_piece(m, text[a:b]):
            exempt += b - a
            last = last or b == len(text)
    return exempt, last


def features(m: DetectorModel, raw: str, p: Params, final: bool = True) -> Feats:
    kno = korean_normalize(raw)
    low = raw.lower()
    txt, orph, lone = keys_to_hangul(kno)
    runs, run_at_end = chat_runs(m, txt)
    nr, ns = shift_counts(raw)
    if final:
        ko_lm = m.lm_ko.score(kno, True)
        ko_lex = m.lex_ko.get(kno)
        en_lm = m.lm_en.score(low, True)
        en_lex = m.lex_en.get(low)
        ko_orph = orph - runs
    else:
        ko_lm = m.lm_ko.score(kno, False)
        ko_lex = None
        en_lm = m.lm_en.score(low, False)
        en_lex = None
        ko_orph = orph - runs - (1 if lone and not run_at_end else 0)
    en_case = case_pattern(raw, m.case_lex)
    mix = []
    if len(raw) >= 2 and "'" not in raw:
        _, F = m.lm_en.prefix_scores(low)
        table = m.suf_full if final else m.suf_prefix
        for b in range(1, len(raw)):
            lat = raw[:b]
            short_ok = len(lat) >= p.MIX_MIN_LATIN or lat.isupper()
            ks = kno[b:]
            suf = table.get(ks)
            en_lex_l = m.lex_en.get(low[:b])
            gen = None
            if lat != low[:b] or en_lex_l is not None:
                _, o2, lone2 = keys_to_hangul(ks)
                if (o2 if final else o2 - (1 if lone2 else 0)) == 0 and kno[b] in KEY_IS_CONSONANT:
                    gen = m.lm_ko.score(ks, final)
            if suf is None and gen is None:
                continue
            r2, s2 = shift_counts(raw[b:])
            mix.append((b, F[b], en_lex_l, case_pattern(lat, m.case_lex), suf, gen, r2, s2, short_ok))
    return Feats(raw, ko_lm, ko_lex, ko_orph, nr, ns, en_lm, en_lex, en_case, mix, low in m.num_units)


def word_score(lm: int, lex: int | None, ng_off: int, lex_off: int) -> int:
    a = lm + ng_off
    if lex is not None:
        b = lex + lex_off
        return a if a >= b else b
    return a


def hyp_scores(f: Feats, p: Params, ctx: str, final: bool = True, user: dict | None = None,
               term: str = "S") -> list[tuple[tuple, int]]:
    """[(hyp, score)] in tie-break order: KO, EN, MIX(b ascending).
    ctx in START/KO/EN/NUM; term (final only) in S(space/end)/D(digit)/H(hyphen)/P(other)."""
    out = []
    if final:
        ko = word_score(f.ko_lm + p.ORPHAN * f.ko_orph, f.ko_lex, p.NG_KO, p.LEX_KO)
        en = word_score(f.en_lm, f.en_lex, p.NG_EN, p.LEX_EN)
        if term == "D":
            en += p.TERM_DIGIT_EN
        elif term == "H":
            en += p.TERM_HYPHEN_EN
    else:
        ko = f.ko_lm + p.ORPHAN * f.ko_orph
        en = f.en_lm
    pk, pe = p.prior(ctx, "KO"), p.prior(ctx, "EN")
    ko += p.ROLLOVER * f.ko_roll + p.STRAY * f.ko_stray + pk
    en += case_cost(p, f.en_case) + pe
    if ctx == "NUM" and f.en_unit:
        en += p.NUM_UNIT_EN
    out.append((("K",), ko))
    out.append((("E",), en))
    for (b, lm, lex, cp, suf, gen, r2, s2, short_ok) in f.mix:
        if not short_ok and ctx != "NUM":
            if suf is None:
                continue
            gen = None  # a single lowercase letter takes table suffixes only
        a = suf + p.MIX if suf is not None else None
        if a is not None and b == 1 and cp != CASE_LOWER and ctx != "EN":
            a += p.MIX_INITIAL
        g = gen + p.MIX_GENERIC if gen is not None else None
        tail = a if g is None or (a is not None and a >= g) else g
        s = word_score(lm, lex, p.NG_EN, p.LEX_EN) + case_cost(p, cp) + tail \
            + p.ROLLOVER * r2 + p.STRAY * s2 + pe
        out.append((("M", b), s))
    if user:
        out = [(h, s + user_bonus(p, user.get(hyp_key(h), 0))) for h, s in out]
    return out


def automatic(raw: str, ctx: str, scored: list[tuple[tuple, int]]) -> list[tuple[tuple, int]]:
    """The readings the engine picks by itself (SPEC.md 4.3절 4): all but one lowercase Latin letter +
    a suffix outside NUM (a양), which only the flip key or the choice bar picks. As a reading of its
    own it mostly mistakes English words (ask, ago) and Korean initials (ㄱ씨는)."""
    if ctx == "NUM" or not raw[:1].islower():
        return scored
    return [(h, s) for h, s in scored if h != ("M", 1)]


def best(scored: list[tuple[tuple, int]]) -> tuple[tuple, int]:
    bh, bs = scored[0]
    for h, s in scored[1:]:
        if s > bs:
            bh, bs = h, s
    return bh, bs


def hyp_key(h: tuple) -> str:
    return "K" if h[0] == "K" else ("E" if h[0] == "E" else f"M{h[1]}")


USER_LOG2 = [round(1000 * math.log2(1 + n)) for n in range(16)]  # millibits table


def user_bonus(p: Params, n: int) -> int:
    n = min(max(n, 0), 15)
    return (p.USER_UNIT * USER_LOG2[n]) // 1000


def render(raw: str, h: tuple) -> str:
    if h[0] == "E":
        return raw
    if h[0] == "K":
        return keys_to_hangul(raw)[0]
    b = h[1]
    return raw[:b] + keys_to_hangul(raw[b:])[0]


def next_ctx(h: tuple) -> str:
    return "EN" if h[0] == "E" else "KO"


class Engine:
    def __init__(self, model: DetectorModel, params: Params):
        self.m = model
        self.p = params

    def final(self, raw: str, ctx: str = "START", user: dict | None = None, term: str = "S"):
        f = features(self.m, raw, self.p, True)
        sc = hyp_scores(f, self.p, ctx, True, user, term)
        h, s = best(sc)
        return h, sc

    def display_trace(self, raw: str, ctx: str = "START", policy: str = "prefix", init: str = "context") -> list[tuple]:
        """Displayed hypothesis after each keystroke (hysteresis on top of prefix- or
        final-mode scores).  init='context': before the first key the display is assumed to be
        in the context language (E after an English word, K otherwise), so the first key must
        beat it by HYST; init='argmax': the first key shows the raw argmax."""
        shown = (("E",) if ctx == "EN" else ("K",)) if init == "context" else None
        trace = []
        fin = policy == "final"
        for i in range(1, len(raw) + 1):
            f = features(self.m, raw[:i], self.p, fin)
            sc = hyp_scores(f, self.p, ctx, fin)
            d = dict(sc)
            bh, bs = best(sc)
            if shown is None or shown not in d:
                shown = bh
            elif bh != shown and bs - d[shown] > self.p.HYST:
                shown = bh
            trace.append(shown)
        return trace


# ------------------------------------------------------------ tokenizer --

_TOK = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*[가-힣ㄱ-ㅣ]*|[가-힣ㄱ-ㅣ]+[A-Za-z]*|[.!?\n]|[^\sA-Za-z가-힣ㄱ-ㅣ]")


def tokenize_sentence(s: str):
    """Yields ("tok", text) / ("eos", ch) / ("sep", ch).  Hangul followed by Latin is
    flagged ("unsupported", text)."""
    s = s.replace("’", "'").replace("‘", "'")
    for m in _TOK.finditer(s):
        t = m.group(0)
        if t in ".!?\n":
            yield ("eos", t)
        elif re.match(r"[A-Za-z]", t) or re.match(r"[가-힣ㄱ-ㅣ]", t):
            if re.match(r"[가-힣ㄱ-ㅣ]+[A-Za-z]+$", t):
                yield ("unsupported", t)
            else:
                yield ("tok", t)
        else:
            yield ("sep", t)


def gold_keys(tok: str):
    """(raw keystrokes, gold hypothesis) or None if the token cannot be typed."""
    from hangul import roundtrip_keys
    m = re.match(r"^([A-Za-z']*)([가-힣ㄱ-ㅣ]*)$", tok)
    if not m:
        return None
    lat, han = m.group(1), m.group(2)
    if han:
        k = roundtrip_keys(han)
        if k is None:
            return None
        if lat:
            return lat + k, ("M", len(lat))
        return k, ("K",)
    return lat, ("E",)
