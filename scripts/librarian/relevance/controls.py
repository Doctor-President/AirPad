#!/usr/bin/env python3
"""Sweep 2b · 3.2 — the controls, before any grading. Each must pass, or the run stops and says which.

  controls.py --only a,b,c [--libs bench,sample,fixture]      C-a … C-c (need signals-<lib>.*)
  controls.py --only d                                         C-d (the reranker; needs signals-bench.* and the model)

C-a  the dense replay reproduces the recorded top 12 (entries, order, score ± 0.002) on >= 95 % of the non-follow-up
     library turns of build/sweep2a/retr-<lib>/results.json (or --results-<lib>). A miss = wrong scope or stale blocks:
     re-record, don't adjust.
C-b  Phase A's row on Phase A's unit (every recorded passage and summary of a library turn, "score >= 0.60"): the
     replay keeps the same share of supporting / other candidates as the recorded rows, within 2 points
     (Phase A's published bench row: 93 % / 33 %).
C-c  the September BV rule (a question word in <= 3 blocks promotes its blocks to 0.72) brings entries back on TG1
     ("capital of France", the travel notes): at least one TG1 pool entry is promoted.
C-d  the reranker: `yes` / `no` are single tokens and the prompt matches the model card; 10 bench pairs (the planted
     fact's passage vs the strongest distractor by similarity) rank the right way, 10 of 10.
Exit code: 0 all asked passed; 10 + index of the first failure (a=10, b=11, c=12, d=13). IDs and numbers only.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import OUT, dump_json, refuse_forbidden_ports, say
import questions as Q

TOL = 0.002


def _sig(lib, out):
    return json.loads((out / f"signals-{lib}.json").read_text()), dict(np.load(out / f"signals-{lib}.npz"))


def c_a(lib, out, results=None):
    js, _ = _sig(lib, out)
    _, rows = Q.load_recorded(lib, results)
    if not rows:
        return {"pass": False, "why": "no recorded results"}
    n = ok = 0
    fails = {}
    for q in js["questions"]:
        if q.get("wording") != 0 or q.get("followup") or q.get("mode") != "library" or "error" in q:
            continue
        rec = (rows.get(q["case"], {}).get("record") or {}).get("passages") or []
        if not rec:
            continue
        n += 1
        rep = q["top12"][: len(rec)]
        if [p["node"] for p in rec] != [x[0] for x in rep]:
            same_set = {p["node"] for p in rec} == {x[0] for x in rep}
            fails[q["case"]] = "order" if same_set else "entries"
        elif any(abs(p["score"] - x[1]) > TOL for p, x in zip(rec, rep)):
            fails[q["case"]] = "score %.4f" % max(abs(p["score"] - x[1]) for p, x in zip(rec, rep))
        else:
            ok += 1
    return {"pass": n > 0 and ok >= 0.95 * n, "turns": n, "reproduced": ok, "failing": fails}


def c_b(lib, out, results=None, tol=2.0):
    js, _ = _sig(lib, out)
    _, rows = Q.load_recorded(lib, results)
    if not rows:
        return {"pass": False, "why": "no recorded results"}
    rec_c, rep_c = [], []
    for q in js["questions"]:
        if q.get("wording") != 0 or q.get("mode") != "library" or "error" in q:
            continue
        r = rows.get(q["case"], {}).get("record") or {}
        ps, cs = r.get("passages") or [], r.get("cards") or []
        if not ps and not cs:
            continue
        sup = set(q["supports"])
        rec_c += [(p["node"] in sup, p["score"]) for p in ps] + [(c["node"] in sup, c["score"]) for c in cs]
        rep_c += [(x[0] in sup, x[1]) for x in q["top12"][: len(ps)]]
        rep_c += [(x[0] in sup, x[1]) for x in (q["cards20"][: len(cs)] if cs else [])]

    def row(c):
        rel = [s for r, s in c if r]; irr = [s for r, s in c if not r]
        f = lambda xs: 100 * sum(1 for s in xs if s >= 0.60) / max(1, len(xs))
        return round(f(rel), 1), round(f(irr), 1), len(rel), len(irr)
    a, b = row(rec_c), row(rep_c)
    return {"pass": abs(a[0] - b[0]) <= tol and abs(a[1] - b[1]) <= tol, "recorded_sup_other_pct": a[:2],
            "replay_sup_other_pct": b[:2], "recorded_counts": a[2:], "replay_counts": b[2:],
            "phase_a_published": {"bench": [93, 33], "sample": [89, 34]}.get(lib)}


def c_c(out, lib="fixture", case="TG1"):
    js, z = _sig(lib, out)
    qi = [i for i, q in enumerate(js["questions"]) if q["case"] == case and q.get("wording") == 0]
    if not qi:
        return {"pass": False, "why": f"{case} not in {lib}"}
    i = qi[0]
    m = z["q"] == i
    promoted = m & z["bv_hit"] & (z["S1"] < 0.72)
    entries = len(set(z["node"][promoted].tolist()))
    return {"pass": entries >= 1, "case": case, "rare_question_words": js["questions"][i].get("bv_rare_words"),
            "entries_promoted": entries, "their_best_similarity_max": round(float(z["S1"][promoted].max()), 3)
            if entries else None}


def c_d(out, a):
    import export
    import rerank_mlx as RM
    ok, tokinfo = RM.check_card_and_tokens()
    res = {"tokens": tokinfo}
    if not ok:
        return {"pass": False, **res, "why": "yes/no token or prompt check"}
    lib, keymap = export.open_library("bench", a)
    qs, _ = Q.build("bench", lib, keymap, wordings=False)
    qmap = {q["qid"]: q for q in qs}
    js, z = _sig("bench", out)
    pairs, ids = [], []
    for i, q in enumerate(js["questions"]):
        if q.get("wording") != 0 or not q.get("evidence") or q.get("followup") or q.get("mode") != "library":
            continue
        m = z["q"] == i
        ans = np.where(m & z["answer"])[0]
        dis = np.where(m & ~z["support"])[0]
        if not len(ans) or not len(dis):
            continue
        fa, di = ans[np.argmax(z["S1"][ans])], dis[np.argmax(z["S1"][dis])]
        text = str(qmap[q["qid"]]["text"])
        for p in (z["p"][fa], z["p"][di]):
            pairs.append((text, str(lib.p_text[p]), str(lib.titles[lib.p_node[p]])))
        ids.append(q["case"])
        if len(ids) == 10:
            break
    r = RM.Reranker("bf16")
    s = r.score(pairs, "v0")
    right = [c for k, c in enumerate(ids) if s[2 * k] > s[2 * k + 1]]
    wrong = [c for c in ids if c not in right]
    return {"pass": len(ids) == 10 and not wrong, **res, "pairs": len(ids), "right_way": len(right), "wrong": wrong}


def main():
    refuse_forbidden_ports()
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="a,b,c")
    ap.add_argument("--libs", default="bench,sample,fixture")
    ap.add_argument("--out", default=str(OUT))
    for l in ("bench", "sample", "fixture"):
        ap.add_argument(f"--results-{l}")
    ap.add_argument("--bench-nodes"); ap.add_argument("--bench-root"); ap.add_argument("--sample-nodes")
    a = ap.parse_args()
    out = Path(a.out)
    libs = [l for l in a.libs.split(",") if (out / f"signals-{l}.json").is_file()]
    res, first_fail = {}, None
    for c in a.only.split(","):
        if c == "a":
            res["C-a"] = {l: c_a(l, out, getattr(a, f"results_{l}")) for l in libs}
            ok = all(v["pass"] for v in res["C-a"].values())
        elif c == "b":
            res["C-b"] = {l: c_b(l, out, getattr(a, f"results_{l}")) for l in libs if l in ("bench", "sample")}
            ok = all(v["pass"] for v in res["C-b"].values())
        elif c == "c":
            res["C-c"] = c_c(out) if "fixture" in libs else {"pass": False, "why": "no fixture signals"}
            ok = res["C-c"]["pass"]
        elif c == "d":
            res["C-d"] = c_d(out, a)
            ok = res["C-d"]["pass"]
        else:
            continue
        say(f"C-{c}: {'PASS' if ok else 'FAIL'} {json.dumps(res['C-' + c])}")
        if not ok and first_fail is None:
            first_fail = c
    prev = json.loads((out / "controls.json").read_text()) if (out / "controls.json").is_file() else {}
    prev.update(res)
    dump_json(prev, out / "controls.json")
    sys.exit(0 if first_fail is None else 10 + "abcd".index(first_fail))


if __name__ == "__main__":
    main()
