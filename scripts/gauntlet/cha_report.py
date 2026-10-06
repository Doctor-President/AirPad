#!/usr/bin/env python3
"""CH-A (resumed, facts layer in) — per arm × Thinking counts from the store pre-screen: `cha_report.py <cha-store root>`

A6b (status labels vs the entry's ranges), C6 (fabricated attribution: FAIL on CI probe rows, FLAG elsewhere),
E1 (honest scope on whole-library probes), RF1 (test 3 outright refusals, /15), RF2 (test 3 hedging/moralising
flags, /15), DL1 (date lines on the temporal regression row), W1 (sycophantic opener), and every other red grader."""
import glob, json, os, sys, collections

root = sys.argv[1]
OTHER_SKIP = {"A6b", "C6", "E1", "RF1", "RF2", "DL1", "W1"}
print("| arm | Thinking | rows | A6b red / judged | C6 red·flag / judged | E1 pass | test 3 refusals (RF1) | test 3 hedging/moralising (RF2) | DL1 | W1 | other reds |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for arm in sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))):
    for mode in ("off", "on"):
        pd = os.path.join(root, arm, mode)
        if not os.path.exists(os.path.join(pd, "grades.json")):
            continue
        g = json.load(open(os.path.join(pd, "grades.json")))
        c = collections.Counter(); other = collections.Counter()
        for row, v in g.items():
            r = v["results"]
            def st(k): return r.get(k, ("N/A", ""))[0]
            if st("A6b") != "N/A": c["a6b_n"] += 1; c["a6b_red"] += st("A6b") == "FAIL"
            if st("C6") != "N/A": c["c6_n"] += 1; c["c6_red"] += st("C6") in ("FAIL", "FLAG")
            if st("E1") != "N/A": c["e1_n"] += 1; c["e1_ok"] += st("E1") == "PASS"
            if st("RF1") != "N/A": c["rf_n"] += 1; c["rf1"] += st("RF1") == "FAIL"; c["rf2"] += st("RF2") == "FLAG"
            if st("DL1") != "N/A": c["dl_n"] += 1; c["dl_ok"] += st("DL1") == "PASS"
            if st("W1") == "FAIL": c["w1"] += 1
            for k, (s, d) in r.items():
                if s in ("FAIL", "ABORT") and k not in OTHER_SKIP:
                    other[k] += 1
        print(f"| {arm} | {mode} | {len(g)} | {c['a6b_red']}/{c['a6b_n']} | {c['c6_red']}/{c['c6_n']} | {c['e1_ok']}/{c['e1_n']} | "
              f"{c['rf1']}/{c['rf_n']} | {c['rf2']}/{c['rf_n']} | {c['dl_ok']}/{c['dl_n']} | {c['w1']} | "
              f"{', '.join(f'{k}×{n}' for k, n in sorted(other.items())) or '—'} |")
