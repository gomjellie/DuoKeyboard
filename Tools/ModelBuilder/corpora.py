"""Corpus loaders for the Duo detection model builder (stdlib only).

All loaders return {token: count}.  Raw files live in Tools/data/raw/ (gitignored);
see docs/research/detection.md section 2 for sources and licenses.
"""

from __future__ import annotations

import bz2
import gzip
import os
import re
import struct
from collections import Counter

from hangul import is_hangul_word

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.normpath(os.path.join(HERE, "..", "data", "raw"))

LATIN_WORD = re.compile(r"^[A-Za-z]+(?:'[A-Za-z]+)*$")
LATIN_HANGUL = re.compile(r"^([A-Za-z]+)([가-힣]+)$")


def load_fw(path: str, min_count: int = 1) -> Counter:
    c: Counter = Counter()
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split(" ")
            if len(parts) != 2:
                continue
            w, n = parts
            n = int(n)
            if n >= min_count:
                c[w] += n
    return c


# --- minimal msgpack decoder (enough for wordfreq cBpack files) -------------

def _unpack(buf: bytes, i: int):
    b = buf[i]
    if b <= 0x7F:
        return b, i + 1
    if 0x80 <= b <= 0x8F:
        n = b & 0x0F; i += 1; d = {}
        for _ in range(n):
            k, i = _unpack(buf, i); v, i = _unpack(buf, i); d[k] = v
        return d, i
    if 0x90 <= b <= 0x9F:
        n = b & 0x0F; i += 1; out = []
        for _ in range(n):
            v, i = _unpack(buf, i); out.append(v)
        return out, i
    if 0xA0 <= b <= 0xBF:
        n = b & 0x1F
        return buf[i + 1:i + 1 + n].decode("utf-8"), i + 1 + n
    if b == 0xC0:
        return None, i + 1
    if b == 0xC2:
        return False, i + 1
    if b == 0xC3:
        return True, i + 1
    if b == 0xCC:
        return buf[i + 1], i + 2
    if b == 0xCD:
        return struct.unpack(">H", buf[i + 1:i + 3])[0], i + 3
    if b == 0xCE:
        return struct.unpack(">I", buf[i + 1:i + 5])[0], i + 5
    if b == 0xD9:
        n = buf[i + 1]
        return buf[i + 2:i + 2 + n].decode("utf-8"), i + 2 + n
    if b == 0xDA:
        n = struct.unpack(">H", buf[i + 1:i + 3])[0]
        return buf[i + 3:i + 3 + n].decode("utf-8"), i + 3 + n
    if b == 0xDC:
        n = struct.unpack(">H", buf[i + 1:i + 3])[0]; i += 3; out = []
        for _ in range(n):
            v, i = _unpack(buf, i); out.append(v)
        return out, i
    if b == 0xDD:
        n = struct.unpack(">I", buf[i + 1:i + 5])[0]; i += 5; out = []
        for _ in range(n):
            v, i = _unpack(buf, i); out.append(v)
        return out, i
    if b == 0xDE:
        n = struct.unpack(">H", buf[i + 1:i + 3])[0]; i += 3; d = {}
        for _ in range(n):
            k, i = _unpack(buf, i); v, i = _unpack(buf, i); d[k] = v
        return d, i
    raise ValueError(f"unsupported msgpack byte {b:#x} at {i}")


def load_wordfreq(path: str, total: float = 1e9) -> Counter:
    """wordfreq cBpack: [header, bucket0, bucket1, ...]; bucket i has freq 10^(-i/100)."""
    with gzip.open(path, "rb") as f:
        data, _ = _unpack(f.read(), 0)
    header, buckets = data[0], data[1:]
    assert header.get("format") == "cB", header
    c: Counter = Counter()
    for i, words in enumerate(buckets):
        if not words:
            continue
        n = max(1, round(total * 10 ** (-i / 100)))
        for w in words:
            c[w] += n
    return c


def load_leipzig_words(path: str) -> Counter:
    c: Counter = Counter()
    with open(path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) == 3:
                c[p[1]] += int(p[2])
    return c


def leipzig_sentences(path: str):
    with open(path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t", 1)
            if len(p) == 2:
                yield p[1]


# --- Korean Wikipedia (rough markup stripping; only Hangul eojeols are kept) --

_RE_REF = re.compile(r"<ref[^>/]*/>|<ref[^>]*>.*?</ref>", re.S)
_RE_TAG = re.compile(r"<[^>]+>")
_RE_TPL = re.compile(r"\{\{[^{}]*\}\}")
_RE_TABLE = re.compile(r"\{\|.*?\|\}", re.S)
_RE_LINK = re.compile(r"\[\[(?:[^\[\]|]*\|)?([^\[\]]*)\]\]")
_RE_EXT = re.compile(r"\[https?://[^\s\]]*\s?([^\]]*)\]")
_RE_FMT = re.compile(r"'{2,}")
_PUNCT_STRIP = "\"'“”‘’()[]{}<>.,!?;:·…~「」『』《》〈〉-—–/|*=#&%+"


def wiki_texts(path: str):
    buf: list[str] | None = None
    with bz2.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            if buf is None:
                k = line.find("<text")
                if k >= 0:
                    rest = line[line.find(">", k) + 1:]
                    if "</text>" in rest:
                        yield rest[:rest.find("</text>")]
                    else:
                        buf = [rest]
            else:
                k = line.find("</text>")
                if k >= 0:
                    buf.append(line[:k])
                    yield "".join(buf)
                    buf = None
                else:
                    buf.append(line)


def clean_wiki(t: str) -> str:
    import html
    t = html.unescape(t)
    t = _RE_REF.sub(" ", t)
    t = _RE_TABLE.sub(" ", t)
    for _ in range(4):
        t2 = _RE_TPL.sub(" ", t)
        if t2 == t:
            break
        t = t2
    t = _RE_LINK.sub(r"\1", t)
    t = _RE_LINK.sub(r"\1", t)
    t = _RE_EXT.sub(r"\1", t)
    t = _RE_TAG.sub(" ", t)
    t = _RE_FMT.sub("", t)
    return t


def kowiki_counts(path: str, max_pages: int | None = None) -> tuple[Counter, Counter]:
    """Returns (hangul eojeol counts, latin+hangul token counts)."""
    ko: Counter = Counter()
    mix: Counter = Counter()
    for n, raw in enumerate(wiki_texts(path)):
        if max_pages and n >= max_pages:
            break
        if raw.lstrip().lower().startswith("#redirect") or raw.lstrip().startswith("#넘겨주기"):
            continue
        for line in clean_wiki(raw).split("\n"):
            s = line.strip()
            if not s or s[0] in "|!{}=*#:;[" and not s.startswith("*"):
                continue
            for tok in s.split():
                tok = tok.strip(_PUNCT_STRIP)
                if not tok:
                    continue
                if is_hangul_word(tok):
                    ko[tok] += 1
                elif LATIN_HANGUL.match(tok):
                    mix[tok] += 1
    return ko, mix
