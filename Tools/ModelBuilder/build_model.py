"""Build the Duo runtime model (DUOM v1) + golden test vectors.

    python3 -I Tools/ModelBuilder/build_model.py [--params params.json] [--config o5p]

Outputs (Tools/ModelBuilder/out/):
    duo-model.bin        single mmap-able little-endian file (format: docs/research/detection.md section 7)
    test_vectors.json    vectors the Swift engine must reproduce exactly
    model_card.json      sizes, hashes, provenance

The builder re-opens the written binary with an independent reader and derives
all test vectors from *that* reader, so the vectors validate the file format too.
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import random
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # scripts run with python3 -I

import detector as D
import kn
import model_data as md
from hangul import keys_to_hangul, korean_normalize, roundtrip_keys

HERE = md.HERE
OUT = os.path.join(HERE, "out")
MAGIC = b"DUOM"
VERSION = (1, 0)
HEADER_SIZE = 32
DIR_ENTRY = struct.Struct("<24sQQII")  # name, offset, length, elemSize, count  (48 bytes)
FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3
M64 = (1 << 64) - 1


def fnv1a64(s: str) -> int:
    h = FNV_OFFSET
    for b in s.encode("ascii"):
        h ^= b
        h = (h * FNV_PRIME) & M64
    return h


def key_format(n: int) -> str:
    return "I" if kn.BITS * n <= 32 else "Q"


# ------------------------------------------------------------------ write --

def serialize(model: D.DetectorModel, params: D.Params, path: str, provenance: dict) -> dict:
    sections: list[tuple[str, bytes, int, int]] = []
    meta = {
        "format": "DUOM", "version": list(VERSION), "units": "millinats (1/1000 natural log)",
        "symbols": {"<s>": kn.BOS, "</s>": kn.EOS, **{c: v for c, v in sorted(kn.SYM.items(), key=lambda x: x[1])}},
        "symbolBits": kn.BITS, "V": kn.V,
        "lm": {}, "lexicon": {},
        "suffix": {"full": dict(sorted(model.suf_full.items())), "prefix": dict(sorted(model.suf_prefix.items()))},
        "caseLexicon": sorted(model.case_lex),
        "numUnitsEn": sorted(model.num_units),
        "params": params.to_dict(),
        "userLog2Millibits": D.USER_LOG2,
        "provenance": provenance,
    }
    for tag, lm in (("ko", model.lm_ko), ("en", model.lm_en)):
        info = {"order": lm.N, "lpCodebook": {}, "bowCodebook": {}, "count": {}, "keyType": {}}
        for n in range(1, lm.N + 1):
            keys = sorted(lm.lp[n].keys())
            assert set(lm.bow[n]).issubset(lm.lp[n]), (tag, n)
            kf = key_format(n)
            sections.append((f"{tag}.{n}.key", struct.pack(f"<{len(keys)}{kf}", *keys), struct.calcsize(kf), len(keys)))
            sections.append((f"{tag}.{n}.lp", bytes(lm.lp_idx[n][k] for k in keys), 1, len(keys)))
            info["lpCodebook"][str(n)] = lm.cb_lp[n]
            info["count"][str(n)] = len(keys)
            info["keyType"][str(n)] = "u32" if kf == "I" else "u64"
            if n < lm.N:
                cb = lm.cb_bow[n]
                z = cb.index(0)
                sections.append((f"{tag}.{n}.bow", bytes(lm.bow_idx[n].get(k, z) for k in keys), 1, len(keys)))
                info["bowCodebook"][str(n)] = cb
        meta["lm"][tag] = info
    for tag, lex in (("ko", model.lex_ko), ("en", model.lex_en)):
        cb = D.uniform_codebook(list(lex.values()), k=256)
        ent = sorted((fnv1a64(k), D.quantize(v, cb)) for k, v in lex.items())
        hs = [h for h, _ in ent]
        assert len(set(hs)) == len(hs), f"FNV collision in {tag} lexicon"
        sections.append((f"lex{tag}.key", struct.pack(f"<{len(hs)}Q", *hs), 8, len(hs)))
        sections.append((f"lex{tag}.val", bytes(i for _, i in ent), 1, len(hs)))
        meta["lexicon"][tag] = {"count": len(hs), "codebook": cb, "hash": "fnv1a64(ascii normalized keys)"}
    meta_bytes = json.dumps(meta, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    sections.insert(0, ("meta", meta_bytes, 1, len(meta_bytes)))

    dir_off = HEADER_SIZE
    data_off = dir_off + DIR_ENTRY.size * len(sections)
    data_off = (data_off + 7) & ~7
    layout = []
    blob = bytearray()
    for name, b, es, cnt in sections:
        pad = (-(data_off + len(blob))) % 8
        blob += b"\0" * pad
        layout.append((name, data_off + len(blob), len(b), es, cnt))
        blob += b
    content_hash = FNV_OFFSET
    for byte in blob:  # FNV-1a 64 over everything after the directory padding
        content_hash ^= byte
        content_hash = (content_hash * FNV_PRIME) & M64
    header = MAGIC + struct.pack("<HHII", VERSION[0], VERSION[1], len(sections), dir_off) + struct.pack("<QQ", content_hash, 0)[:16]
    header = header[:HEADER_SIZE].ljust(HEADER_SIZE, b"\0")
    with open(path, "wb") as f:
        f.write(header)
        for name, off, ln, es, cnt in layout:
            f.write(DIR_ENTRY.pack(name.encode("ascii"), off, ln, es, cnt))
        f.write(b"\0" * (data_off - (HEADER_SIZE + DIR_ENTRY.size * len(sections))))
        f.write(blob)
    return {"sections": {n: {"offset": o, "bytes": l, "elemSize": e, "count": c} for n, o, l, e, c in layout},
            "contentHash": f"{content_hash:016x}", "fileBytes": os.path.getsize(path)}


# ------------------------------------------------------------------- read --

class BinLM(D.RuntimeLM):
    def __init__(self, mv: memoryview, sec: dict, meta: dict, tag: str):
        info = meta["lm"][tag]
        super().__init__(info["order"])
        self.keys, self.lpi, self.bowi = {}, {}, {}
        for n in range(1, self.N + 1):
            s = sec[f"{tag}.{n}.key"]
            fmt = "I" if info["keyType"][str(n)] == "u32" else "Q"
            self.keys[n] = mv[s["offset"]:s["offset"] + s["bytes"]].cast(fmt)
            s = sec[f"{tag}.{n}.lp"]
            self.lpi[n] = mv[s["offset"]:s["offset"] + s["bytes"]]
            if n < self.N:
                s = sec[f"{tag}.{n}.bow"]
                self.bowi[n] = mv[s["offset"]:s["offset"] + s["bytes"]]
            self.cb_lp[n] = info["lpCodebook"][str(n)]
            if n < self.N:
                self.cb_bow[n] = info["bowCodebook"][str(n)]

    def _find(self, n: int, key: int) -> int:
        a = self.keys[n]
        i = bisect.bisect_left(a, key)
        return i if i < len(a) and a[i] == key else -1

    def cond(self, hist: list[int], w: int) -> int:
        N = self.N
        h = hist[-(N - 1):] if N > 1 else []
        acc = 0
        hk = kn.pack(h)
        n = len(h) + 1
        while True:
            k = (hk << kn.BITS) | w
            i = self._find(n, k)
            if i >= 0 and not (n == 1 and w == kn.BOS):
                return acc + self.cb_lp[n][self.lpi[n][i]]
            if n > 1:
                j = self._find(n - 1, hk)
                if j >= 0:
                    acc += self.cb_bow[n - 1][self.bowi[n - 1][j]]
            n -= 1
            hk = kn.suffix(hk, n) if n > 1 else 0


class BinLex:
    def __init__(self, mv, sec, meta, tag):
        s = sec[f"lex{tag}.key"]
        self.keys = mv[s["offset"]:s["offset"] + s["bytes"]].cast("Q")
        s = sec[f"lex{tag}.val"]
        self.vals = mv[s["offset"]:s["offset"] + s["bytes"]]
        self.cb = meta["lexicon"][tag]["codebook"]

    def get(self, k: str, default=None):
        h = fnv1a64(k)
        i = bisect.bisect_left(self.keys, h)
        if i < len(self.keys) and self.keys[i] == h:
            return self.cb[self.vals[i]]
        return default

    def __contains__(self, k):
        return self.get(k) is not None


def load_binary(path: str) -> tuple[D.DetectorModel, D.Params, dict]:
    with open(path, "rb") as f:
        buf = f.read()
    mv = memoryview(buf)
    assert buf[:4] == MAGIC
    major, minor, count, dir_off = struct.unpack_from("<HHII", buf, 4)
    assert (major, minor) == VERSION
    sec = {}
    for i in range(count):
        name, off, ln, es, cnt = DIR_ENTRY.unpack_from(buf, dir_off + i * DIR_ENTRY.size)
        sec[name.rstrip(b"\0").decode("ascii")] = {"offset": off, "bytes": ln, "elemSize": es, "count": cnt}
    s = sec["meta"]
    meta = json.loads(bytes(mv[s["offset"]:s["offset"] + s["bytes"]]).decode("utf-8"))
    model = D.DetectorModel(
        lm_ko=BinLM(mv, sec, meta, "ko"), lm_en=BinLM(mv, sec, meta, "en"),
        lex_ko=BinLex(mv, sec, meta, "ko"), lex_en=BinLex(mv, sec, meta, "en"),
        case_lex=set(meta["caseLexicon"]),
        suf_full=meta["suffix"]["full"], suf_prefix=meta["suffix"]["prefix"],
        num_units=set(meta["numUnitsEn"]), meta=meta)
    return model, D.Params(**meta["params"]), meta


# ----------------------------------------------------------- test vectors --

AUTOMATON_CASES = [
    "dkssudgktpdy", "ekfrrhrl", "rkqt", "rkqtdl", "rkqtl", "dlTek", "dlTdj", "rhkr", "dnjs",
    "zzz", "bb", "rt", "hk", "rkk", "Ehrqo", "rkE", "rkEk", "dmlwk", "ahfmrpTek", "goTtmqslek",
    "sjrt", "sjrtl", "go", "so", "tk", "dhksfyehldjTtmqslek", "k", "r", "R", "Q", "QQ", "kk",
    "hko", "hkl", "nj", "njp", "nl", "ml", "mll", "rkfr", "rkfrk", "rkfa", "rkfq", "rkft",
    "rkfx", "rkfv", "rkfg", "rkqt", "rkst", "rksw", "rksg", "rkrt", "rkQ", "rkW", "rkR", "rkT",
    "rkRk", "rkTk", "dkssud'", "don't", "it's", "gks'rmf", "Hello", "HELLO", "iOS", "PRdmf",
    "rhkdrh", "dhkd", "dhks", "dnpfk", "dnpdl", "rmfjtj", "qkfrtm", "wlfrh", "dlfrdj", "tkfkd",
    "ehfr", "ehfrk", "dkf", "dkfr", "dkfrk", "rkqtdms", "djqtek", "djqtdj", "Tkd", "TkdTkd",
    "aaa", "lll", "hhh", "hkhk", "nlnl", "mlml", "qwertyuiop", "asdfghjkl", "zxcvbnm", "QWERTOP",
]


def vec_features(f: D.Feats):
    return {"koLm": f.ko_lm, "koLex": f.ko_lex, "koOrphans": f.ko_orph, "koRollover": f.ko_roll, "koStray": f.ko_stray,
            "enLm": f.en_lm, "enLex": f.en_lex, "enCase": D.CASE_NAMES[f.en_case], "enNumUnit": f.en_unit,
            "mix": [{"b": b, "enLm": lm, "enLex": lex, "enCase": D.CASE_NAMES[cp], "suffix": suf, "generic": gen,
                     "rollover": r2, "stray": s2, "shortOk": ok} for (b, lm, lex, cp, suf, gen, r2, s2, ok) in f.mix]}


def make_vectors(model: D.DetectorModel, p: D.Params, meta: dict, seed: int = 20261107) -> dict:
    rnd = random.Random(seed)
    tv: dict = {"modelContentHash": meta.get("_contentHash"), "params": p.to_dict(), "notes": "All scores are Int (millinats). See docs/research/detection.md."}
    # 1. automaton
    ko_words = [w for w, _ in md.korean_counts().most_common(20000)]
    sample_words = rnd.sample(ko_words, 300)
    cases = list(AUTOMATON_CASES) + [roundtrip_keys(w) for w in sample_words]
    alpha = "qwertyuiopasdfghjklzxcvbnm" * 3 + "QWERTOP" + "'"
    cases += ["".join(rnd.choice(alpha) for _ in range(rnd.randint(1, 10))) for _ in range(300)]
    tv["automaton"] = []
    for k in cases:
        txt, orph, lone = keys_to_hangul(k)
        tv["automaton"].append({"keys": k, "normalized": korean_normalize(k), "text": txt, "orphans": orph, "trailingLoneConsonant": lone})
    # 2. hashing + lexicon
    tv["fnv1a64"] = [{"s": s, "hash": f"{fnv1a64(s):016x}"} for s in ["", "a", "go", "dkssud", "dkssudgktpdy", "github", "don't", "goTtmqslek"]]
    lex_probe = ["go", "so", "the", "github", "zzzzqx", "dkssud", "gotTdj", "goTdj", "rkatkgkqslek", "dkssudgktpdy", "zz", "zzz", "bb", "don't"]
    tv["lexicon"] = [{"lang": "ko", "key": k, "value": model.lex_ko.get(k)} for k in lex_probe] + \
                    [{"lang": "en", "key": k, "value": model.lex_en.get(k)} for k in lex_probe]
    # 3. LM scores
    lm_probe = lex_probe + ["dkssudgktpdy", "Tkd", "QQQ", "'", "ab'cd", "x", "qwertyuiop", "goTtmqslek"]
    tv["lm"] = []
    for k in lm_probe:
        kk = korean_normalize(k)
        P, F = model.lm_ko.prefix_scores(kk)
        tv["lm"].append({"model": "ko", "keys": kk, "prefix": P, "withEos": F})
        lk = k.lower()
        P, F = model.lm_en.prefix_scores(lk)
        tv["lm"].append({"model": "en", "keys": lk, "prefix": P, "withEos": F})
    # 4. final decisions
    raws = set(["go", "so", "to", "do", "and", "the", "ok", "OK", "Ok", "dkssud", "dkssudgktpdy", "PRdmf", "PRdmf", "APIfmf",
                "iOSdptj", "pushgoTdjdy", "mergegownwktpdy", "zzz", "gg", "gkgk", "bb", "dd", "dz", "Hello", "HELLO", "hello",
                "I", "i", "a", "Q", "mm", "th", "LGwjswk", "SKgkdlslrtm", "don't", "it's", "we're", "can't", "LGTM", "Slack",
                "slack", "Figma", "GitHub", "github", "Github", "macOS", "MacOS", "dlTek", "dLTek", "dlTEk", "gkTdj", "gkTDj",
                "goTtmqslek", "rkatkgkqslek", "tnrhgktuTtmqslek", "Tl", "rk", "fh", "dmf", "fmf", "rtrt",
                "km", "GB", "fps", "st", "nd", "rd", "ro", "aud", "tl", "qns", "R", "ATlsms", "Kfldrm", "Rksms",
                # one Latin letter + a table suffix: MIX_INITIAL (uppercase), table-only Mix (lowercase)
                "ATl", "Adid", "ADid", "Arns", "Ark", "Hwh", "Csms", "Srk", "Sdp", "Ask", "Ago",
                "aTl", "adid", "arns", "mdp", "mfh", "hdml", "ask",
                # emotive jamo runs (no orphan charge) and chat words
                "zzzzzzzzzz", "zzzzsks", "gmdgofkmm", "bbbqnfjqek", "rkxspzzzz", "gggg", "eee", "see",
                "zz'zz", "mmm", "WW", "ws", "tq", "wrkxek", "rne"])
    with open(os.path.join(md.DATA, "mixed_sentences.txt"), encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#"):
                continue
            for kind, t in D.tokenize_sentence(line.strip()):
                if kind == "tok":
                    g = D.gold_keys(t)
                    if g:
                        raws.add(g[0])
    raws = sorted(raws)
    tv["final"] = []
    for raw in raws:
        f = D.features(model, raw, p, True)
        entry = {"raw": raw, "features": vec_features(f), "cases": []}
        for ctx in ("START", "KO", "EN", "NUM"):
            for term in (("S", "D", "H") if ctx == "START" else ("S",)):
                sc = D.hyp_scores(f, p, ctx, True, None, term)
                h, s = D.best(sc)
                entry["cases"].append({"ctx": ctx, "term": term, "scores": {D.hyp_key(a): b for a, b in sc},
                                       "best": D.hyp_key(h), "output": D.render(raw, h)})
        tv["final"].append(entry)
    # 5. prefix decisions + display traces
    tv["incremental"] = []
    eng = D.Engine(model, p)
    for raw in raws[:: max(1, len(raws) // 200)]:
        for ctx in ("START", "KO", "EN"):
            steps = []
            for i in range(1, len(raw) + 1):
                f = D.features(model, raw[:i], p, False)
                sc = D.hyp_scores(f, p, ctx, False)
                steps.append({"scores": {D.hyp_key(a): b for a, b in sc}})
            trace = eng.display_trace(raw, ctx)  # init='context' (shipped policy)
            for st, h, i in zip(steps, trace, range(1, len(raw) + 1)):
                st["shown"] = D.hyp_key(h); st["text"] = D.render(raw[:i], h)
            tv["incremental"].append({"raw": raw, "ctx": ctx, "steps": steps})
    # 6. apostrophe rule: internal iff argmax of prefix-mode scores of raw + "'" is E
    tv["apostrophe"] = []
    for raw in ["don", "it", "we", "I", "didn", "she", "can", "wasn", "couldn", "tkfkd", "dlrjt", "rmrj", "gksrmf",
                "dkssud", "qkqh", "Tkdl", "gkfn", "rock", "o", "rock", "ma"]:
        for ctx in ("START", "KO", "EN"):
            f = D.features(model, raw + "'", p, False)
            sc = D.hyp_scores(f, p, ctx, False)
            h, _ = D.best(sc)
            tv["apostrophe"].append({"raw": raw, "ctx": ctx, "scores": {D.hyp_key(a): b for a, b in sc},
                                     "internal": h == ("E",)})
    # 7. user adaptation
    tv["user"] = []
    for raw, counts in [("go", {"E": 1}), ("go", {"E": 3}), ("so", {"E": 2}), ("dkssud", {"E": 15}), ("PRdmf", {"E": 4}), ("to", {"K": 3}), ("gg", {"E": 40})]:
        f = D.features(model, raw, p, True)
        sc = D.hyp_scores(f, p, "KO", True, counts)
        h, _ = D.best(sc)
        tv["user"].append({"raw": raw, "ctx": "KO", "userCounts": counts, "scores": {D.hyp_key(a): b for a, b in sc}, "best": D.hyp_key(h), "output": D.render(raw, h)})
    tv["userBonus"] = {str(n): D.user_bonus(p, n) for n in range(0, 20)}
    return tv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--params", default=os.path.join(HERE, "params.json"))
    ap.add_argument("--config", default="ship")
    a = ap.parse_args()
    t0 = time.time()
    os.makedirs(OUT, exist_ok=True)
    p = D.Params()
    if os.path.exists(a.params):
        with open(a.params) as f:
            p = D.Params(**json.load(f))
    cfg = SHIP_CONFIGS[a.config]
    model = md.build(**cfg)
    prov = {
        "korean": "OpenSubtitles2018 via hermitdave/FrequencyWords ko_full (CC-BY-SA-4.0) x2 + Korean Wikipedia dump chunk 1 (CC-BY-SA-4.0), eojeol counts",
        "english": "OpenSubtitles2018 via hermitdave/FrequencyWords en_full (CC-BY-SA-4.0) + wordfreq 3.x large_en (CC-BY-SA-4.0)",
        "curated": "Tools/ModelBuilder/data/*.txt (project-authored)",
        "config": {k: str(v) for k, v in cfg.items()},
    }  # no timestamp: identical inputs -> byte-identical file (reproducible content hash)
    path = os.path.join(OUT, "duo-model.bin")
    info = serialize(model, p, path, prov)
    print(f"[bin] {path} {info['fileBytes']/1e6:.2f} MB hash {info['contentHash']}")
    bm, bp, meta = load_binary(path)
    meta["_contentHash"] = info["contentHash"]
    # cross-check binary reader against the in-memory runtime LM
    rnd = random.Random(3)
    probe = [w for w, _ in md.english_counts().most_common(3000)]
    for w in rnd.sample(probe, 300):
        assert bm.lm_en.score(w, True) == model.lm_en.score(w, True), w
    kprobe = list(model.lex_ko.keys())[:5000]
    for k in rnd.sample(kprobe, 300):
        assert bm.lm_ko.score(k, True) == model.lm_ko.score(k, True), k
    print("[bin] reader cross-check OK")
    tv = make_vectors(bm, bp, meta)
    with open(os.path.join(OUT, "test_vectors.json"), "w", encoding="utf-8") as f:
        json.dump(tv, f, ensure_ascii=False, indent=1)
    card = {"file": "duo-model.bin", **info, "params": p.to_dict(), "provenance": prov,
            "lmSizes": {"ko": model.meta["ko_sizes"], "en": model.meta["en_sizes"]},
            "lexicon": {"ko": len(model.lex_ko), "en": len(model.lex_en)},
            "suffixes": len(model.suf_full), "caseLexicon": len(model.case_lex)}
    with open(os.path.join(OUT, "model_card.json"), "w", encoding="utf-8") as f:
        json.dump(card, f, ensure_ascii=False, indent=1)
    print(f"[done] {time.time()-t0:.0f}s  vectors: automaton={len(tv['automaton'])} final={len(tv['final'])} incremental={len(tv['incremental'])}")


SHIP_CONFIGS = {
    # order-5 KN for both languages, weighted-difference pruning theta_4 = 15, theta_5 = 30,
    # lexicons = top 100k Korean eojeols / top 60k English words (see detection.md section 9.5)
    "ship": dict(order_ko=5, order_en=5, prune_ko={4: 15.0, 5: 30.0}, prune_en={4: 15.0, 5: 30.0},
                 lex_ko_k=100_000, lex_en_k=60_000),
}

if __name__ == "__main__":
    main()
