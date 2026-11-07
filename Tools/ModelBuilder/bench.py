"""Operation counts / timing of the reference engine on the serialized model.

    python3 -I bench.py out/duo-model.bin
"""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import build_model
import detector as D


def main(path):
    t = time.perf_counter()
    m, p, meta = build_model.load_binary(path)
    load_ms = (time.perf_counter() - t) * 1000
    counter = {"search": 0}
    for lm in (m.lm_ko, m.lm_en):
        orig = lm._find

        def wrapped(n, key, _o=orig):
            counter["search"] += 1
            return _o(n, key)
        lm._find = wrapped
    words = ["go", "dkssud", "meeting", "PRdmf", "dkssudgktpdy", "pushgoTdjdy", "rkatkgkqslek",
             "LGwjswksms", "Kubernetes", "tnrhgktuTtmqslek", "deployment", "configuration"]
    print(f"load (python, incl. JSON meta parse): {load_ms:.1f} ms")
    print(f"{'word':18s} {'n':>3s} {'searches/key (prefix)':>22s} {'searches (final)':>17s} {'py ms/key':>10s}")
    for w in words:
        counter["search"] = 0
        t = time.perf_counter()
        for i in range(1, len(w) + 1):
            f = D.features(m, w[:i], p, False)
            D.hyp_scores(f, p, "KO", False)
        el = (time.perf_counter() - t) * 1000 / len(w)
        sp = counter["search"] / len(w)
        counter["search"] = 0
        f = D.features(m, w, p, True)
        D.hyp_scores(f, p, "KO", True)
        print(f"{w:18s} {len(w):3d} {sp:22.0f} {counter['search']:17d} {el:10.2f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(build_model.OUT, "duo-model.bin"))
