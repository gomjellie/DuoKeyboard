"""Community-text typing evaluation: build the corpora, then summarise and compare engine runs.

    python3 -I Tools/scripts/community_corpus.py prep
    python3 -I Tools/scripts/community_corpus.py report <run.tsv> [--base <older-run.tsv>] [--top N]

prep reads Tools/data/raw/community/ (not committed) and writes two corpora there, one sentence per
line as source<TAB>id<TAB>text with only characters a 두벌식 + ABC typist types:
  sentences.tsv  NSMC test set (nsmc_test.txt, CC0 1.0) + korean-hate-speech (khs_*.tsv, CC BY-SA 4.0)
  sites.tsv      site comments (*_comments.tsv, collected for evaluation only; see sources.md there)
Tools/scripts/corpus-typing.sh types a corpus through the engine; report reads its output.
"""
from __future__ import annotations

import argparse
import collections
import glob
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "Tools", "data", "raw", "community")
TYPABLE = re.compile(r"[가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9 !\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~]")
KOREAN = re.compile(r"[가-힣ㄱ-ㅎㅏ-ㅣ]")
JAMO = re.compile(r"[ㄱ-ㅎㅏ-ㅣ]")
SYLLABLE = re.compile(r"[가-힣]")
LATIN = re.compile(r"[A-Za-z]")


def clean(text: str) -> str:
    text = "".join(ch if TYPABLE.fullmatch(ch) else " " for ch in text)
    return re.sub(r" +", " ", text).strip()


def write(rows, name):
    out, dropped = [], 0
    for source, ident, text in rows:
        c = clean(text)
        if c and KOREAN.search(c):
            out.append((source, ident, c))
        else:
            dropped += 1
    path = os.path.join(RAW, name)
    with open(path, "w", encoding="utf-8") as f:
        for r in out:
            f.write("\t".join(r) + "\n")
    print(f"{path}: {len(out)} sentences ({dropped} without Korean dropped)")


def prep():
    rows = []
    with open(os.path.join(RAW, "nsmc_test.txt"), encoding="utf-8") as f:
        next(f)
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3 and parts[1].strip():
                rows.append(("nsmc", parts[0], parts[1]))
    for name in ("khs_train.tsv", "khs_dev.tsv"):
        with open(os.path.join(RAW, name), encoding="utf-8") as f:
            next(f)
            for i, line in enumerate(f):
                rows.append(("khs", f"{name[4:-4]}{i}", line.split("\t")[0]))
    write(rows, "sentences.tsv")
    rows = []
    for path in sorted(glob.glob(os.path.join(RAW, "*_comments.tsv"))):
        with open(path, encoding="utf-8") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 3:
                    rows.append(tuple(parts))
    write(rows, "sites.tsv")


def load(path):
    """{(source, id, expected): row}; row = source, id, reachable, correct, expected, produced, keys."""
    with open(path, encoding="utf-8") as f:
        return {(r[0], r[1], r[4]): r for r in (line.rstrip("\n").split("\t") for line in f)}


def word_errors(row):
    expected, produced = row[4].split(" "), row[5].split(" ")
    if len(expected) != len(produced):
        return None
    return [(e, p) for e, p in zip(expected, produced) if e != p]


def kind(word: str) -> str:
    if LATIN.search(word):
        return "latin + hangul" if KOREAN.search(word) else "latin"
    if JAMO.search(word):
        return "jamo + syllables" if SYLLABLE.search(word) else "jamo only"
    core = re.sub(r"[^가-힣]", "", word)
    if sum(len(unicodedata.normalize("NFD", ch)) for ch in core) > 32:
        return "long unspaced (>32 keys)"
    return "short Korean (<=2 syllables)" if len(core) <= 2 else "Korean 3+ syllables"


def report(path, base, top):
    rows = load(path)
    reach = [r for r in rows.values() if r[2] == "1"]
    ok = sum(r[3] == "1" for r in reach)
    words = wrong = 0
    errors, kinds, examples = collections.Counter(), collections.Counter(), collections.defaultdict(list)
    for r in reach:
        words += len(r[4].split(" "))
        if r[3] == "1":
            continue
        pairs = word_errors(r)
        if pairs is None:
            wrong += 1
            kinds["(word count differs)"] += 1
            continue
        for e, p in pairs:
            wrong += 1
            errors[(e, p)] += 1
            k = kind(e)
            kinds[k] += 1
            if len(examples[k]) < 8:
                examples[k].append(f"{e}→{p}")
    print(f"sentences {len(rows)}, typable {len(reach)} ({len(reach) / max(1, len(rows)):.1%}), "
          f"correct {ok} ({ok / max(1, len(reach)):.2%} of typable)")
    print(f"words {words}, wrong {wrong} ({wrong / max(1, words):.3%})")
    print("\nwrong words by kind:")
    for k, n in kinds.most_common():
        print(f"  {n:6d} {n / max(1, wrong):6.1%}  {k}   {'  '.join(examples[k])}")
    print(f"\ntop {top} wrong words (expected → produced):")
    for (e, p), n in errors.most_common(top):
        print(f"  {n:5d}  {e} → {p}")
    if base:
        old = load(base)
        better = [k for k, r in rows.items() if k in old and r[2] == "1" and r[3] == "1" and old[k][3] == "0"]
        worse = [k for k, r in rows.items() if k in old and r[2] == "1" and r[3] == "0" and old[k][3] == "1"]
        print(f"\nagainst {base}: {len(better)} sentences now correct, {len(worse)} now wrong")
        for k in worse[:top]:
            print(f"  worse: {rows[k][4].strip()}  →  {rows[k][5].strip()}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("prep")
    r = sub.add_parser("report")
    r.add_argument("run")
    r.add_argument("--base")
    r.add_argument("--top", type=int, default=30)
    a = ap.parse_args()
    if a.cmd == "prep":
        prep()
    else:
        report(a.run, a.base, a.top)


if __name__ == "__main__":
    sys.exit(main())
