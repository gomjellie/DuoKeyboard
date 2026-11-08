"""Training-data assembly + model construction shared by evaluate.py and build_model.py."""

from __future__ import annotations

import math
import os
import re
import zlib
from collections import Counter

import corpora
import kn
from detector import DetectorModel, RuntimeLM
from hangul import is_hangul_word, roundtrip_keys, korean_normalize

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = corpora.RAW
DATA = os.path.join(HERE, "data")
CACHE = os.path.join(RAW, "_cache")

EN_WORD = re.compile(r"^[a-z]+(?:'[a-z]+)*$")
TIER_PER_MILLION = {1: 50.0, 2: 10.0, 3: 2.0}


def _read_tsv(path):
    c = Counter()
    with open(path, encoding="utf-8") as f:
        for line in f:
            w, n = line.rstrip("\n").split("\t")
            c[w] = int(n)
    return c


def _write_tsv(path, c):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for w, n in c.most_common():
            f.write(f"{w}\t{n}\n")


def is_syllable_word(w: str) -> bool:
    return bool(w) and all(0xAC00 <= ord(ch) <= 0xD7A3 for ch in w)


def num_units_en() -> set[str]:
    out = set()
    with open(os.path.join(DATA, "num_units_en.txt"), encoding="utf-8") as f:
        for line in f:
            t = line.strip()
            if t and not t.startswith("#"):
                out.add(t.lower())
    return out


def split_of(word: str) -> str:
    h = zlib.crc32(word.encode("utf-8")) % 10
    return "test" if h == 0 else ("dev" if h == 1 else "train")


def korean_counts() -> Counter:
    """Hangul eojeol -> pseudo-count (2 x OpenSubtitles + kowiki chunk-1 [count>=2] + chat words)."""
    c = korean_corpus_counts()
    total = sum(c.values())
    with open(os.path.join(DATA, "ko_chat.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            w, pm = line.rstrip("\n").split("\t")
            if roundtrip_keys(w) is not None:
                c[w] += max(1, round(float(pm) * total / 1e6))
    return c


def korean_corpus_counts() -> Counter:
    """The corpus part of `korean_counts`, cached: `data/ko_chat.txt` is added on every call, so an
    edit there reaches the next build without clearing the cache."""
    path = os.path.join(CACHE, "ko_corpus_counts.tsv")
    if os.path.exists(path):
        return _read_tsv(path)
    fw = corpora.load_fw(os.path.join(RAW, "fw_ko_full.txt"))
    wiki = _read_tsv(os.path.join(RAW, "kowiki", "kowiki_counts.tsv"))
    c = Counter()
    # corpus tokens: complete syllables only (jamo-only corpus tokens are stutters/noise such as
    # "ㄲ", "ㄷ"); chat jamo come exclusively from the curated list below
    for w, n in fw.items():
        if is_syllable_word(w):
            c[w] += 2 * n
    for w, n in wiki.items():
        if n >= 2 and is_syllable_word(w):
            c[w] += n
    c = Counter({w: n for w, n in c.items() if roundtrip_keys(w) is not None})
    _write_tsv(path, c)
    return c


def english_terms():
    terms = []
    with open(os.path.join(DATA, "en_terms.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            t, tier = line.rstrip("\n").split("\t")
            terms.append((t, int(tier)))
    return terms


def english_counts() -> Counter:
    """lowercase word -> pseudo-count (OpenSubtitles en [>=3] + wordfreq large_en scaled to same total + terms)."""
    path = os.path.join(CACHE, "en_counts.tsv")
    if os.path.exists(path):
        return _read_tsv(path)
    fw = corpora.load_fw(os.path.join(RAW, "fw_en_full.txt"), min_count=3)
    fw = Counter({w: n for w, n in fw.items() if EN_WORD.match(w)})
    tot = sum(fw.values())
    wf = corpora.load_wordfreq(os.path.join(RAW, "wordfreq", "large_en.msgpack.gz"), total=tot)
    c = Counter(fw)
    for w, n in wf.items():
        w = w.replace("’", "'")
        if EN_WORD.match(w):
            c[w] += n
    total = sum(c.values())
    for t, tier in english_terms():
        lw = t.lower()
        if EN_WORD.match(lw):
            c[lw] += max(1, round(TIER_PER_MILLION[tier] * total / 1e6))
    _write_tsv(path, c)
    return c


def suffix_counts() -> Counter:
    path = os.path.join(CACHE, "suffix_counts.tsv")
    if os.path.exists(path):
        return _read_tsv(path)
    R = re.compile(r"^([A-Za-z]+)([가-힣]+)$")
    c = Counter()
    for w, n in _read_tsv(os.path.join(RAW, "kowiki", "kowiki_mix.tsv")).items():
        m = R.match(w)
        if m:
            c[m.group(2)] += n
    for w, n in corpora.load_fw(os.path.join(RAW, "fw_ko_full.txt")).items():
        m = R.match(w)
        if m:
            c[m.group(2)] += 5 * n
    with open(os.path.join(DATA, "suffix_extra.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            s, n = line.rstrip("\n").split("\t")
            c[s] += int(n)
    c = Counter({s: n for s, n in c.items() if n >= 5 and roundtrip_keys(s) is not None})
    _write_tsv(path, c)
    return c


def to_keys_ko(c: Counter) -> Counter:
    out = Counter()
    for w, n in c.items():
        k = roundtrip_keys(w)
        if k is not None:
            out[korean_normalize(k)] += n
    return out


def lexicon(counts: Counter, top_k: int) -> dict[str, int]:
    total = sum(counts.values())
    return {w: int(round(1000 * math.log(n / total))) for w, n in counts.most_common(top_k)}


def suffix_tables(sc: Counter) -> tuple[dict[str, int], dict[str, int]]:
    keys = Counter()
    for s, n in sc.items():
        keys[korean_normalize(roundtrip_keys(s))] += n
    total = sum(keys.values())
    full = {k: int(round(1000 * math.log(n / total))) for k, n in keys.items()}
    pref = Counter()
    for k, n in keys.items():
        for i in range(1, len(k) + 1):
            pref[k[:i]] += n
    prefix = {k: int(round(1000 * math.log(n / total))) for k, n in pref.items()}
    return full, prefix


def case_lexicon() -> set[str]:
    return {t for t, _ in english_terms() if any(ch.isupper() for ch in t)}


def build(order_ko=6, order_en=6, exp_ko=1.0, exp_en=1.0, prune_ko=None, prune_en=None,
          lex_ko_k=150_000, lex_en_k=80_000, split: str | None = None, codebook=True,
          verbose=True) -> DetectorModel:
    """split=None -> all data (shipping); split='train' -> train types only (for held-out eval)."""
    ko = korean_counts()
    en = english_counts()
    if split:
        ko = Counter({w: n for w, n in ko.items() if split_of(w) == split})
        en = Counter({w: n for w, n in en.items() if split_of(w) == split})
    ko_k = to_keys_ko(ko)
    if verbose:
        print(f"[data] ko types={len(ko_k)} tokens={sum(ko_k.values())}  en types={len(en)} tokens={sum(en.values())}", flush=True)
    mko = kn.KNModel.train(ko_k, order_ko, exp_ko)
    if prune_ko:
        mko.prune(prune_ko)
    men = kn.KNModel.train(en, order_en, exp_en)
    if prune_en:
        men.prune(prune_en)
    if verbose:
        print(f"[lm] ko sizes={mko.sizes()} en sizes={men.sizes()}", flush=True)
    lko = RuntimeLM.from_kn(mko, codebook)
    len_ = RuntimeLM.from_kn(men, codebook)
    sf, sp = suffix_tables(suffix_counts())
    return DetectorModel(
        lm_ko=lko, lm_en=len_,
        lex_ko=lexicon(ko_k, lex_ko_k), lex_en=lexicon(en, lex_en_k),
        case_lex=case_lexicon(), suf_full=sf, suf_prefix=sp, num_units=num_units_en(),
        meta=dict(order_ko=order_ko, order_en=order_en, exp_ko=exp_ko, exp_en=exp_en,
                  prune_ko=prune_ko, prune_en=prune_en, lex_ko_k=lex_ko_k, lex_en_k=lex_en_k,
                  split=split, ko_sizes=mko.sizes(), en_sizes=men.sizes()),
    )
