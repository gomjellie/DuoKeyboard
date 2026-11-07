"""Character n-gram LM over the shared Duo keystroke alphabet.

Interpolated modified Kneser-Ney (Chen & Goodman 1998, KenLM conventions:
single <s>, n-grams that start with <s> keep raw counts), converted to the
ARPA backoff form, pruned by weighted difference, then quantized to integer
millinats for bit-exact runtime scoring.

Symbols (6 bits each, shared by both models):
    0 pad (never stored)   1 <s>   2 </s>
    3..28  a..z   (unshifted key, or a shifted key whose 두벌식 jamo is unchanged)
    29..35 Q W E R T O P  (shifted; only ever produced by Korean normalisation)
    36     apostrophe
V = 35 predictable symbols (everything except pad and <s>).
"""

from __future__ import annotations

import math
from collections import defaultdict

BOS, EOS = 1, 2
SHIFTED = "QWERTOP"
SYM = {c: 3 + i for i, c in enumerate("abcdefghijklmnopqrstuvwxyz")}
SYM.update({c: 29 + i for i, c in enumerate(SHIFTED)})
SYM["'"] = 36
SYM_CHR = {v: k for k, v in SYM.items()}
V = 35
BITS = 6
MASK = (1 << BITS) - 1


def syms(keys: str) -> list[int]:
    return [SYM[c] for c in keys]


def pack(seq) -> int:
    k = 0
    for s in seq:
        k = (k << BITS) | s
    return k


def first_sym(key: int, n: int) -> int:
    return key >> (BITS * (n - 1))


def suffix(key: int, n: int) -> int:
    """drop the oldest symbol of an n-gram"""
    return key & ((1 << (BITS * (n - 1))) - 1)


class KNModel:
    """Float model in backoff form: lp[n][key] = ln P(w|h), bow[n][key] = ln gamma(h)."""

    def __init__(self, order: int):
        self.N = order
        self.lp: list[dict[int, float]] = [dict() for _ in range(order + 1)]
        self.bow: list[dict[int, float]] = [dict() for _ in range(order + 1)]
        self.raw: list[dict[int, float]] = [dict() for _ in range(order + 1)]

    # ---- training ----
    @classmethod
    def train(cls, words: dict[str, float], order: int, exponent: float = 1.0) -> "KNModel":
        N = order
        raw = [defaultdict(float) for _ in range(N + 1)]
        for w, c in words.items():
            if c <= 0:
                continue
            wt = c ** exponent if exponent != 1.0 else c
            wt = max(1, round(wt))
            seq = [BOS] + syms(w) + [EOS]
            L = len(seq)
            for i in range(1, L):
                k = 0
                for n in range(1, N + 1):
                    j = i - n + 1
                    if j < 0:
                        break
                    k = k | (seq[j] << (BITS * (n - 1)))  # prepend
                    raw[n][k] += wt
        # adjusted counts
        adj = [dict() for _ in range(N + 1)]
        adj[N] = dict(raw[N])
        for n in range(N - 1, 0, -1):
            cont = defaultdict(int)
            for k in raw[n + 1]:
                cont[suffix(k, n + 1)] += 1
            a = adj[n]
            for k, c in raw[n].items():
                a[k] = c if (first_sym(k, n) == BOS or k not in cont) else cont[k]
        # discounts per order
        D = [None] * (N + 1)
        for n in range(1, N + 1):
            cc = [0] * 5
            for c in adj[n].values():
                ic = int(round(c))
                if 1 <= ic <= 4:
                    cc[ic] += 1
            n1, n2, n3, n4 = (max(x, 1) for x in cc[1:5])
            Y = n1 / (n1 + 2 * n2)
            D[n] = (0.0, max(0.05, 1 - 2 * Y * n2 / n1), max(0.05, 2 - 3 * Y * n3 / n2), max(0.05, 3 - 4 * Y * n4 / n3))
        # context sums
        m = cls(N)
        m.raw = [dict(r) for r in raw]
        prev_p: dict[int, float] = {}
        for n in range(1, N + 1):
            S = defaultdict(float)
            Nk = defaultdict(lambda: [0, 0, 0])
            for k, c in adj[n].items():
                h = k >> BITS
                S[h] += c
                ic = int(round(c))
                Nk[h][0 if ic <= 1 else (1 if ic == 2 else 2)] += 1
            d1, d2, d3 = D[n][1], D[n][2], D[n][3]
            gamma = {h: (d1 * v[0] + d2 * v[1] + d3 * v[2]) / S[h] for h, v in Nk.items()}
            p: dict[int, float] = {}
            for k, c in adj[n].items():
                h = k >> BITS
                ic = int(round(c))
                d = d1 if ic <= 1 else (d2 if ic == 2 else d3)
                lower = (1.0 / V) if n == 1 else prev_p[suffix(k, n)]
                p[k] = max(c - d, 0.0) / S[h] + gamma[h] * lower
            if n == 1:
                g0 = gamma[0]
                for s in range(2, 2 + V):  # dense unigram over V
                    if s not in p:
                        p[s] = g0 / V
                # renormalise tiny numeric drift
                z = sum(p.values())
                p = {k: v / z for k, v in p.items()}
            for k, v in p.items():
                m.lp[n][k] = math.log(v)
            if n >= 2:
                for h, g in gamma.items():
                    m.bow[n - 1][h] = math.log(g)
            prev_p = p
        # <s> as a context needs an entry in order 1
        m.lp[1].setdefault(BOS, 0.0)
        return m

    # ---- scoring (float) ----
    def cond(self, hist: list[int], w: int) -> float:
        """ln P(w | hist) with hist truncated to N-1 symbols (hist[0] may be <s>)."""
        h = hist[-(self.N - 1):] if self.N > 1 else []
        acc = 0.0
        while True:
            n = len(h) + 1
            k = pack(h + [w])
            v = self.lp[n].get(k)
            if v is not None and not (n == 1 and w == BOS):
                return acc + v
            if not h:
                raise KeyError(w)
            acc += self.bow[n - 1].get(pack(h), 0.0)
            h = h[1:]

    # ---- pruning ----
    def prune(self, thresholds: dict[int, float]) -> None:
        """Weighted-difference pruning: drop (h,w) if raw(h,w)*(lnP - ln P_backoff) < theta_n.
        Contexts of kept higher-order n-grams are always kept. Then backoff weights
        are re-normalised bottom-up."""
        N = self.N
        needed: set[int] = set()
        for n in range(N, 1, -1):
            th = thresholds.get(n)
            lp, bow_lo = self.lp[n], self.bow[n - 1]
            raw = self.raw[n]
            next_needed: set[int] = set()
            if th is not None:
                drop = []
                for k, v in lp.items():
                    if k in needed:
                        continue
                    h = k >> BITS
                    w = k & MASK
                    lower = self._cond_key(suffix(k, n), n - 1)
                    bo = bow_lo.get(h, 0.0) + lower
                    if raw.get(k, 0) * (v - bo) < th:
                        drop.append(k)
                for k in drop:
                    del lp[k]
                    self.bow[n].pop(k, None)
            for k in lp:
                next_needed.add(k >> BITS)
            needed = next_needed
        self.renormalise()

    def _cond_key(self, key: int, n: int) -> float:
        seq = []
        k = key
        for _ in range(n):
            seq.append(k & MASK)
            k >>= BITS
        seq.reverse()
        return self.cond(seq[:-1], seq[-1])

    def renormalise(self) -> None:
        N = self.N
        for n in range(2, N + 1):
            kids = defaultdict(list)
            for k in self.lp[n]:
                kids[k >> BITS].append(k)
            newbow = {}
            for h in list(self.bow[n - 1].keys()):
                ks = kids.get(h)
                if not ks:
                    continue  # no children left -> pure backoff, bow = 0
                num = 1.0 - sum(math.exp(self.lp[n][k]) for k in ks)
                den = 1.0 - sum(math.exp(self._cond_key(suffix(k, n), n - 1)) for k in ks)
                num = max(num, 1e-12)
                den = max(den, 1e-12)
                newbow[h] = math.log(num / den)
            self.bow[n - 1] = newbow
            # every context with children must exist as an n-gram entry of order n-1
            for h in newbow:
                if h not in self.lp[n - 1]:
                    raise AssertionError(f"context {h} of order {n-1} missing")

    def sizes(self) -> list[int]:
        return [len(self.lp[n]) for n in range(1, self.N + 1)]
