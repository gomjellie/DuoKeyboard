"""Evaluation + tuning harness for the Duo detector.

    python3 -I evaluate.py prepare            # build eval sets (cached under Tools/data/raw/_cache/eval)
    python3 -I evaluate.py run [--tune] [--config NAME]

Results are written to Tools/ModelBuilder/out/eval/<config>.json.
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import os
import random
import re
import sys
import time
from collections import Counter, defaultdict
from dataclasses import replace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # scripts run with python3 -I

import corpora
import detector as D
import model_data as md

EVAL = os.path.join(md.CACHE, "eval")
OUT = os.path.join(md.HERE, "out", "eval")
LEIP = {
    "ko_news": os.path.join(md.RAW, "lcc_kor_news_2022_100K", "kor_news_2022_100K", "kor_news_2022_100K-sentences.txt"),
    "ko_wiki": os.path.join(md.RAW, "lcc_kor_wikipedia_2021_100K", "kor_wikipedia_2021_100K", "kor_wikipedia_2021_100K-sentences.txt"),
    "en_news": os.path.join(md.RAW, "lcc_eng_news_2023_100K", "eng_news_2023_100K", "eng_news_2023_100K-sentences.txt"),
}


# ------------------------------------------------------------------ prepare --

def sentence_items(text: str, stats: Counter):
    """[("tok", keys, gold, num, term) | ("eos",) | ("brk",)]
    num: token immediately preceded by a digit; term: S/D/H/P (what ends the token)."""
    text = text.replace("’", "'").replace("‘", "'")
    items = []
    for mt in D._TOK.finditer(text):
        t = mt.group(0)
        st, en = mt.start(), mt.end()
        if t in ".!?\n":
            items.append(("eos",)); continue
        if not (re.match(r"[A-Za-z]", t) or re.match(r"[가-힣ㄱ-ㅣ]", t)):
            continue  # separator: punctuation, digits, symbols
        if re.match(r"[가-힣ㄱ-ㅣ]+[A-Za-z]+$", t):
            stats["unsupported"] += 1; items.append(("brk",)); continue
        g = D.gold_keys(t)
        if g is None:
            stats["untypable"] += 1; items.append(("brk",)); continue
        num = st > 0 and text[st - 1].isdigit()
        nx = text[en] if en < len(text) else " "
        term = "S" if nx.isspace() else ("D" if nx.isdigit() else ("H" if nx == "-" else "P"))
        items.append(("tok", g[0], D.hyp_key(g[1]), int(num), term))
        stats["tok"] += 1; stats["num"] += num; stats["term_" + term] += 1
    return items


def prepare():
    os.makedirs(EVAL, exist_ok=True)
    # Leipzig sentences: even line index -> dev, odd -> test
    for name, path in LEIP.items():
        for part in ("dev", "test"):
            stats = Counter()
            sents = []
            for i, s in enumerate(corpora.leipzig_sentences(path)):
                if (i % 2 == 0) != (part == "dev"):
                    continue
                sents.append(sentence_items(s, stats))
            with open(os.path.join(EVAL, f"{name}_{part}.json"), "w") as f:
                json.dump(sents, f, ensure_ascii=False)
            print(name, part, len(sents), dict(stats))
    # synthetic mixed set
    stats = Counter(); sents = []
    with open(os.path.join(md.DATA, "mixed_sentences.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            sents.append(sentence_items(line.strip(), stats))
    with open(os.path.join(EVAL, "mixed_test.json"), "w") as f:
        json.dump(sents, f, ensure_ascii=False)
    print("mixed", len(sents), dict(stats))
    # held-out types (in-domain, OOV generalisation)
    ko = md.korean_counts(); en = md.english_counts()
    from hangul import roundtrip_keys
    for part in ("dev", "test"):
        rows = []
        for w, n in ko.items():
            if md.split_of(w) == part:
                rows.append([roundtrip_keys(w), "K", n])
        for w, n in en.items():
            if md.split_of(w) == part:
                rows.append([w, "E", n])
        with open(os.path.join(EVAL, f"heldout_{part}.json"), "w") as f:
            json.dump(rows, f)
        print("heldout", part, len(rows))


def load(name):
    with open(os.path.join(EVAL, name + ".json")) as f:
        return json.load(f)


def words_from_sentences(sents) -> list:
    c = Counter()
    for s in sents:
        for it in s:
            if it[0] == "tok":
                c[(it[1], it[2])] += 1
    return [[k, g, n] for (k, g), n in c.items()]


# ------------------------------------------------------------- features --

_M = None
_P = None


def _init(m, p):
    global _M, _P
    _M, _P = m, p


def _feat(raw):
    return D.features(_M, raw, _P, True)


def compute_features(model, params, raws, procs=10):
    raws = sorted(set(raws))
    ctx = mp.get_context("fork")
    _init(model, params)
    with ctx.Pool(procs) as pool:
        fs = pool.map(_feat, raws, chunksize=2000)
    return dict(zip(raws, fs))


# ---------------------------------------------------------------- metrics --

def eval_words(rows, F, p, ctx="START"):
    """rows: [keys, gold, count]. Returns per-class token/type accuracy and error list."""
    tok = defaultdict(lambda: [0, 0]); typ = defaultdict(lambda: [0, 0])
    errs = []
    for k, g, n in rows:
        h, _ = D.best(D.hyp_scores(F[k], p, ctx, True))
        ok = D.hyp_key(h) == g
        cls = g[0]
        tok[cls][0] += n * ok; tok[cls][1] += n
        typ[cls][0] += ok; typ[cls][1] += 1
        if not ok:
            errs.append((n, k, g, D.hyp_key(h)))
    errs.sort(reverse=True)
    res = {c: {"tok_acc": tok[c][0] / tok[c][1], "tok_n": tok[c][1], "type_acc": typ[c][0] / typ[c][1], "type_n": typ[c][1]} for c in tok}
    return res, errs


def _ctx_for(tok, prev_ctx):
    return "NUM" if tok[3] else prev_ctx


def decode(sent, F, p, mode="greedy", gold_ctx=False):
    """Returns list of (gold, predicted_hyp) for the tokens of one sentence.
    mode: greedy (commit-time decision only), lookback (re-decide previous word when the
    next one commits), viterbi (whole-sentence optimum; upper bound)."""
    out = []
    seg = []  # tokens of the current eos-delimited segment
    def flush_seg():
        if not seg:
            return
        if mode == "viterbi":
            dp = {"START": (0, [])}
            for tok in seg:
                new = {}
                for c, (sc, path) in dp.items():
                    for h, s_ in D.hyp_scores(F[tok[1]], p, _ctx_for(tok, c), True, None, tok[4]):
                        nc = D.next_ctx(h); v = sc + s_
                        if nc not in new or v > new[nc][0]:
                            new[nc] = (v, path + [h])
                dp = new
            path = max(dp.values(), key=lambda x: x[0])[1]
            out.extend((tok[2], h) for tok, h in zip(seg, path))
        else:
            ctx = "START"; prev = None  # prev = (tok, ctx_used, hyp)
            for tok in seg:
                c = _ctx_for(tok, ctx)
                if mode == "lookback" and prev is not None:
                    ptok, pctx, _ = prev
                    best_v = None
                    for h1, s1 in D.hyp_scores(F[ptok[1]], p, pctx, True, None, ptok[4]):
                        c2 = _ctx_for(tok, D.next_ctx(h1))
                        h2, s2 = D.best(D.hyp_scores(F[tok[1]], p, c2, True, None, tok[4]))
                        if best_v is None or s1 + s2 > best_v:
                            best_v, bh1, bh2, bc2 = s1 + s2, h1, h2, c2
                    out[-1] = (ptok[2], bh1)
                    h, c = bh2, bc2
                else:
                    h, _ = D.best(D.hyp_scores(F[tok[1]], p, c, True, None, tok[4]))
                out.append((tok[2], h))
                prev = (tok, c, h)
                ctx = D.next_ctx(hyp_from_key(tok[2]) if gold_ctx else h)
        seg.clear()
    for it in sent:
        if it[0] == "eos":
            flush_seg()
        elif it[0] == "tok":
            seg.append(it)
    flush_seg()
    return out


def eval_sentences(sents, F, p, gold_ctx=False, mode="greedy"):
    n = ok = 0
    per = defaultdict(lambda: [0, 0])
    errs = Counter()
    sent_ok = 0
    for s in sents:
        all_ok = True
        res = decode(s, F, p, mode, gold_ctx)
        toks = [it for it in s if it[0] == "tok"]
        for it, (g, h) in zip(toks, res):
            hk = D.hyp_key(h)
            good = hk == g
            n += 1; ok += good
            per[g[0]][0] += good; per[g[0]][1] += 1
            if not good:
                errs[(it[1], g, hk)] += 1; all_ok = False
        sent_ok += all_ok
    return {"tok_acc": ok / max(n, 1), "n": n, "sent_acc": sent_ok / max(len(sents), 1),
            "per_class": {c: v[0] / v[1] for c, v in per.items()},
            "per_class_n": {c: v[1] for c, v in per.items()}}, errs


def hyp_from_key(g):
    return ("E",) if g == "E" else (("K",) if g == "K" else ("M", int(g[1:])))


def eval_flicker(model, p, rows, ctx="START", limit=4000, seed=7, policy="prefix", init="context"):
    """Incremental display behaviour on a token-weighted sample of (keys, gold)."""
    rnd = random.Random(seed)
    pop = [(k, g) for k, g, n in rows]
    w = [n for _, _, n in rows]
    sample = rnd.choices(pop, weights=w, k=limit)
    eng = D.Engine(model, p)
    flips = 0; words_with_flip = 0; keystrokes = 0; correct_disp = 0
    surprise = 0; n = 0
    for k, g in sample:
        tr = eng.display_trace(k, ctx, policy, init)
        f = sum(1 for a, b in zip(tr, tr[1:]) if a != b)
        flips += f; words_with_flip += f > 0
        gh = hyp_from_key(g)
        for i, h in enumerate(tr, 1):
            exp = gh if gh[0] != "M" or i > gh[1] else ("E",)
            correct_disp += h == exp
        keystrokes += len(tr)
        fh, _ = eng.final(k, ctx)
        surprise += fh != tr[-1]
        n += 1
    return {"flips_per_word": flips / n, "words_with_flip": words_with_flip / n,
            "display_acc_per_keystroke": correct_disp / keystrokes, "commit_surprise": surprise / n, "n": n}


# ----------------------------------------------------------------- tuning --

TUNABLE = {
    "NG_KO": [-3000, -2000, -1500, -1000, -600, -300, 0], "LEX_KO": [-600, -300, -100, 0, 300],
    "NG_EN": [-1500, -1000, -600, -300, 0, 300, 600], "LEX_EN": [-600, -300, -100, 0, 300],
    "ORPHAN": [-14000, -11000, -8000, -6000, -4000, -3000, -2000],
    "CASE_INITCAP": [-4000, -3000, -2500, -1500, -800], "CASE_ALLCAPS": [-5000, -3500, -2500, -1500],
    "CASE_MIXED": [-8000, -6000, -4000], "CASE_EXACT": [-1000, -300, 0],
    "MIX": [-7000, -5500, -4000, -3000, -2000, -1500, -1000, -500, 0],
    "MIX_GENERIC": [-20000, -16000, -12000, -9000, -7000, -6000, -5000, -4000],
    "TERM_DIGIT_EN": [0, 1000, 2000, 3000, 5000], "TERM_HYPHEN_EN": [0, 1000, 2000, 3000, 5000],
    "PRIOR_NUM_KO": [-600, -300, -100], "PRIOR_NUM_EN": [-3500, -2500, -1500, -1000, -500],
    "NUM_UNIT_EN": [0, 2000, 4000, 6000, 9000],
    "PRIOR_START_KO": [-400, -200, -100], "PRIOR_START_EN": [-3000, -2500, -2000, -1700, -1300, -1000, -700, -400],
    "PRIOR_KO_KO": [-200, -100, -50], "PRIOR_KO_EN": [-5000, -4500, -4000, -3500, -3000, -2500, -2300, -2000, -1500],
    "PRIOR_EN_KO": [-2500, -2000, -1600, -1300, -1000, -700], "PRIOR_EN_EN": [-600, -400, -300, -200, -100],
}


def add_rollover_noise(keys: str, rnd: random.Random, p_after=0.3, p_before=0.1) -> str:
    """Simulate Shift held too long / pressed too early around a shifted QWERTOP key."""
    out = list(keys)
    for i, c in enumerate(keys):
        if c in "QWERTOP":
            if i + 1 < len(keys) and keys[i + 1].islower() and keys[i + 1] not in "qwertop" and rnd.random() < p_after:
                out[i + 1] = keys[i + 1].upper()
            if i > 0 and keys[i - 1].islower() and keys[i - 1] not in "qwertop" and rnd.random() < p_before:
                out[i - 1] = keys[i - 1].upper()
    return "".join(out)


def objective(p, dev):
    """weighted mean token error rate over the dev suites (lower is better)."""
    errs = []
    for kind, data, F in dev:
        if kind == "words":
            # type-level, class-balanced: token weighting of held-out types is dominated by a
            # handful of very frequent held-out words (then/than) and is too noisy to tune on
            r, _ = eval_words(data, F, p)
            errs.append(0.25 * (1 - 0.5 * (r["K"]["type_acc"] + r["E"]["type_acc"])))
        else:
            r, _ = eval_sentences(data, F, p)
            errs.append(1 - r["tok_acc"])
    return sum(errs) / len(errs), errs


_DEV = None


def _obj_worker(q):
    return objective(q, _DEV)[0]


def tune(p, dev, rounds=2):
    """Coordinate descent; the candidate values of one parameter are scored in parallel."""
    global _DEV
    _DEV = dev
    best_v, parts = objective(p, dev)
    print(f"[tune] start {best_v:.5f} {[round(e,5) for e in parts]}", flush=True)
    ctx = mp.get_context("fork")
    with ctx.Pool(min(10, max(len(g) for g in TUNABLE.values()))) as pool:
        for r in range(rounds):
            improved = False
            for name, grid in TUNABLE.items():
                cur = getattr(p, name)
                cands = [v for v in sorted(set(grid + [cur])) if v != cur]
                qs = [replace(p, **{name: v}) for v in cands]
                vals = pool.map(_obj_worker, qs)
                for q, v, val in zip(qs, cands, vals):
                    if val < best_v - 1e-7:
                        best_v, p, improved = val, q, True
                print(f"[tune] r{r} {name}={getattr(p, name)} -> {best_v:.5f}", flush=True)
            if not improved:
                break
    return p, best_v


# -------------------------------------------------------------------- run --

CONFIGS = {
    "o6": dict(order_ko=6, order_en=6),
    "o5": dict(order_ko=5, order_en=5),
    "o4": dict(order_ko=4, order_en=4),
    "o6_exp05": dict(order_ko=6, order_en=6, exp_ko=0.5, exp_en=0.5),
    "o6_pruned": dict(order_ko=6, order_en=6, prune_ko={6: 40.0, 5: 25.0, 4: 10.0}, prune_en={6: 40.0, 5: 25.0, 4: 10.0}),
    "o5_pruned": dict(order_ko=5, order_en=5, prune_ko={5: 25.0, 4: 10.0}, prune_en={5: 25.0, 4: 10.0}),
    # size-constrained candidates (threshold for order n = th * (n - 3))
    "ship": None,  # filled from build_model.SHIP_CONFIGS
    "o5p5": dict(order_ko=5, order_en=5, prune_ko={4: 5.0, 5: 10.0}, prune_en={4: 5.0, 5: 10.0}, lex_ko_k=100_000, lex_en_k=60_000),
    "k6p40e5p15": dict(order_ko=6, order_en=5, prune_ko={4: 40.0, 5: 80.0, 6: 120.0}, prune_en={4: 15.0, 5: 30.0}, lex_ko_k=100_000, lex_en_k=60_000),
    "o5p15": dict(order_ko=5, order_en=5, prune_ko={4: 15.0, 5: 30.0}, prune_en={4: 15.0, 5: 30.0}, lex_ko_k=100_000, lex_en_k=60_000),
    "o5p40": dict(order_ko=5, order_en=5, prune_ko={4: 40.0, 5: 80.0}, prune_en={4: 40.0, 5: 80.0}, lex_ko_k=100_000, lex_en_k=60_000),
    "o4": dict(order_ko=4, order_en=4, lex_ko_k=100_000, lex_en_k=60_000),
    "o5p5_lex50": dict(order_ko=5, order_en=5, prune_ko={4: 5.0, 5: 10.0}, prune_en={4: 5.0, 5: 10.0}, lex_ko_k=50_000, lex_en_k=30_000),
}


def fmt_words(r):
    return {c: {k: (round(v, 5) if isinstance(v, float) else v) for k, v in d.items()} for c, d in r.items()}


def run(config: str, do_tune: bool, params_in: str | None, flicker: bool, ablate: bool, binary: str | None = None, tag: str | None = None):
    t0 = time.time()
    cfg = CONFIGS[config]
    if cfg is None:
        import build_model
        cfg = build_model.SHIP_CONFIGS[config]
    os.makedirs(OUT, exist_ok=True)
    p = D.Params()
    if params_in:
        with open(params_in) as f:
            p = D.Params(**json.load(f))
    # --- held-out-type model (train split) ---
    m_tr = md.build(split="train", **cfg)
    ho_dev, ho_test = load("heldout_dev"), load("heldout_test")
    F_tr = compute_features(m_tr, p, [r[0] for r in ho_dev + ho_test])
    print(f"[t] train-split model + feats {time.time()-t0:.0f}s", flush=True)
    # --- shipping model (all data); optionally the serialized binary itself ---
    if binary:
        import build_model
        m, _, _meta = build_model.load_binary(binary)
        m.meta.update(ko_sizes=_meta["lm"]["ko"]["count"], en_sizes=_meta["lm"]["en"]["count"])
    else:
        m = md.build(**cfg)
    suites = {n: load(n) for n in ("ko_news_dev", "ko_news_test", "ko_wiki_dev", "ko_wiki_test", "en_news_dev", "en_news_test", "mixed_test")}
    for n in list(suites):
        suites[n] = [[tuple(it) for it in s_] for s_ in suites[n]]
    raws = set()
    for s in suites.values():
        for sent in s:
            for it in sent:
                if it[0] == "tok":
                    raws.add(it[1])
    F = compute_features(m, p, raws)
    print(f"[t] full model + feats ({len(raws)} types) {time.time()-t0:.0f}s", flush=True)
    # dev suites: held-out dev types (train-split model) + ko_wiki_dev + en_news_dev sentences
    rnd = random.Random(1)
    dev = [("words", ho_dev, F_tr),
           ("sents", rnd.sample(suites["ko_wiki_dev"], 6000), F),
           ("sents", rnd.sample(suites["ko_news_dev"], 6000), F),
           ("sents", rnd.sample(suites["en_news_dev"], 5000), F)]
    if do_tune:
        p, v = tune(p, dev)
        with open(os.path.join(OUT, f"{config}_params.json"), "w") as f:
            json.dump(p.to_dict(), f, indent=1)
    config = tag or config
    res = {"config": config, "binary": binary, "cfg": {k: str(v) for k, v in cfg.items()}, "params": p.to_dict(),
           "sizes": {"ko": m.meta["ko_sizes"], "en": m.meta["en_sizes"]}}
    # --- reports ---
    r, errs = eval_words(ho_test, F_tr, p)
    res["heldout_test_words"] = fmt_words(r)
    res["heldout_test_top_errors"] = [list(e) for e in errs[:40]]
    for name in ("ko_news_test", "ko_wiki_test", "en_news_test", "mixed_test"):
        rows = words_from_sentences(suites[name])
        r, errs = eval_words(rows, F, p)
        res[f"{name}_words_nocontext"] = fmt_words(r)
        res[f"{name}_top_word_errors"] = [list(e) for e in errs[:40]]
        for gc in (False, True):
            r, errs = eval_sentences(suites[name], F, p, gold_ctx=gc)
            res[f"{name}_sent_{'goldctx' if gc else 'predctx'}"] = r
            if not gc:
                res[f"{name}_sent_top_errors"] = [[k, g, h, n] for (k, g, h), n in errs.most_common(40)]
        for mode in ("lookback", "viterbi"):
            r, _ = eval_sentences(suites[name], F, p, mode=mode)
            res[f"{name}_sent_{mode}"] = r
    rnd2 = random.Random(5)
    ko_rows_all = [x for x in words_from_sentences(suites["ko_news_test"]) if x[1] == "K"]
    noisy = []
    for k, g, n in ko_rows_all:
        k2 = add_rollover_noise(k, rnd2)
        if k2 != k:
            noisy.append([k2, g, n])
    Fn = compute_features(m, p, [r[0] for r in noisy])
    rr, ee = eval_words(noisy, Fn, p, "KO")
    caps = [x for x in words_from_sentences(suites["en_news_test"]) if any(c.isupper() for c in x[0])]
    rc, ec = eval_words(caps, F, p, "KO")
    res["rollover_noise_ko_news"] = {"ko_tok_acc_ctxKO": round(rr["K"]["tok_acc"], 5), "n_tok": rr["K"]["tok_n"],
                                     "top_errors": [list(e) for e in ee[:15]],
                                     "en_capitalised_tok_acc_ctxKO": round(rc["E"]["tok_acc"], 5)}
    if flicker:
        ko_rows = [x for x in words_from_sentences(suites["ko_news_test"]) if x[1] == "K"]
        en_rows = words_from_sentences(suites["en_news_test"])
        mix_rows = words_from_sentences(suites["mixed_test"])
        latin_in_ko = [x for x in words_from_sentences(suites["ko_news_test"]) if x[1] != "K"]
        res["flicker"] = {
            "ko_news_K": eval_flicker(m, p, ko_rows, "KO", 3000),
            "ko_news_latin": eval_flicker(m, p, latin_in_ko, "KO", 1500),
            "en_news": eval_flicker(m, p, en_rows, "EN", 3000),
            "en_news_START": eval_flicker(m, p, en_rows, "START", 1500),
            "mixed": eval_flicker(m, p, mix_rows, "START", 1500),
        }
        res["flicker"]["en_news_argmaxinit"] = eval_flicker(m, p, en_rows, "EN", 1500, init="argmax")
        res["flicker"]["ko_news_latin_argmaxinit"] = eval_flicker(m, p, latin_in_ko, "KO", 1500, init="argmax")
        res["flicker"]["mixed_argmaxinit"] = eval_flicker(m, p, mix_rows, "START", 1500, init="argmax")
        res["flicker"]["ko_news_K_finalpolicy"] = eval_flicker(m, p, ko_rows, "KO", 1500, policy="final")
        res["flicker"]["en_news_finalpolicy"] = eval_flicker(m, p, en_rows, "EN", 1500, policy="final")
        res["flicker"]["mixed_finalpolicy"] = eval_flicker(m, p, mix_rows, "START", 1500, policy="final")
        for hy in (0, 1000, 1500, 2500, 4000):
            q = replace(p, HYST=hy)
            res["flicker"][f"hyst{hy}_ko_news_K"] = eval_flicker(m, q, ko_rows, "KO", 1000)
            res["flicker"][f"hyst{hy}_ko_news_latin"] = eval_flicker(m, q, latin_in_ko, "KO", 1000)
            res["flicker"][f"hyst{hy}_en_news_EN"] = eval_flicker(m, q, en_rows, "EN", 1000)
            res["flicker"][f"hyst{hy}_en_news_START"] = eval_flicker(m, q, en_rows, "START", 1000)
            res["flicker"][f"hyst{hy}_mixed"] = eval_flicker(m, q, mix_rows, "START", 1000)
    if ablate:
        abl = {}
        for name, q in {
            "no_lexicon": replace(p, LEX_KO=-10**7, LEX_EN=-10**7),
            "no_orphan_penalty": replace(p, ORPHAN=0),
            "no_mix": replace(p, MIX=-10**7),
            "no_case_model": replace(p, CASE_INITCAP=0, CASE_ALLCAPS=0, CASE_MIXED=0, CASE_EXACT=0, ROLLOVER=0, STRAY=0),
            "no_context": replace(p, PRIOR_KO_KO=p.PRIOR_START_KO, PRIOR_KO_EN=p.PRIOR_START_EN, PRIOR_EN_KO=p.PRIOR_START_KO, PRIOR_EN_EN=p.PRIOR_START_EN),
        }.items():
            a = {}
            for sname in ("ko_news_test", "en_news_test", "mixed_test"):
                rr, _ = eval_sentences(suites[sname], F, q)
                a[sname] = round(rr["tok_acc"], 5)
            rr, _ = eval_words(ho_test, F_tr, q)
            a["heldout_K"] = round(rr["K"]["tok_acc"], 5); a["heldout_E"] = round(rr["E"]["tok_acc"], 5)
            abl[name] = a
        res["ablation"] = abl
    res["elapsed_s"] = round(time.time() - t0)
    with open(os.path.join(OUT, f"{config}.json"), "w") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    summary(res)


def summary(res):
    print("=" * 70)
    print(res["config"], res["sizes"])
    ho = res["heldout_test_words"]
    print(f"held-out types  K tok {ho['K']['tok_acc']:.4f} type {ho['K']['type_acc']:.4f} | E tok {ho['E']['tok_acc']:.4f} type {ho['E']['type_acc']:.4f}")
    for name in ("ko_news_test", "ko_wiki_test", "en_news_test", "mixed_test"):
        w = res[f"{name}_words_nocontext"]
        s1 = res[f"{name}_sent_predctx"]; s2 = res[f"{name}_sent_goldctx"]
        print(f"{name:14s} words(noctx): " + " ".join(f"{c}:{d['tok_acc']:.4f}(n={d['tok_n']})" for c, d in sorted(w.items()))
              + f" | sent pred-ctx {s1['tok_acc']:.4f} gold-ctx {s2['tok_acc']:.4f} lookback {res[name+'_sent_lookback']['tok_acc']:.4f} viterbi {res[name+'_sent_viterbi']['tok_acc']:.4f} "
              + str({k: round(v, 4) for k, v in s1['per_class'].items()}))
    if "flicker" in res:
        for k, v in res["flicker"].items():
            print("flicker", k, {a: round(b, 4) for a, b in v.items()})
    if "ablation" in res:
        for k, v in res["ablation"].items():
            print("ablation", k, v)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["prepare", "run"])
    ap.add_argument("--config", default="o6")
    ap.add_argument("--tune", action="store_true")
    ap.add_argument("--params")
    ap.add_argument("--flicker", action="store_true")
    ap.add_argument("--ablate", action="store_true")
    ap.add_argument("--binary", help="evaluate the serialized model file instead of an in-memory build")
    ap.add_argument("--tag", help="name for the result files")
    a = ap.parse_args()
    if a.cmd == "prepare":
        prepare()
    else:
        run(a.config, a.tune, a.params, a.flicker, a.ablate, a.binary, a.tag)
