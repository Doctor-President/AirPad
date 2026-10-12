#!/usr/bin/env python3
"""Brief CI-0 — category × model table from the probe store passes: `ci0_report.py <ci0_root> [--overrides=<json>] [--examples]`.

A row PASSES when its probe grader is PASS (a Q1 FLAG — no quotation — counts as a miss). "In packet" asks whether the
facts needed were in the packet at all (case `probe.evidence`), which splits a failure into
model-got-it-wrong (a facts layer can fix) vs the-facts-were-never-there (retrieval / index-level computation)."""
import json, os, re, sys, glob, collections
sys.path.insert(0, os.path.dirname(__file__))
import gauntlet as G

PG = {"ranges": "A6b", "window": "D1", "age": "D2", "identity": "O1", "count": "K1", "absent": "B1", "present": "B1", "value": "M1", "quote": "Q1"}
cm = json.load(open(os.path.join(os.path.dirname(__file__), "cases.json")))
probes = {c["id"]: c for ch in cm["chats"] if ch.get("_probe") for c in ch["cases"]}


def in_packet(case, turn):
    ev = case["probe"].get("evidence", [])
    pk = turn.get("userContent") or ""
    if isinstance(ev, dict) and ev.get("window"):
        p = case["probe"]
        return any(p["from"] <= d <= p["to"] for d in G.cand_dates(turn).values())
    if isinstance(ev, dict) and ev.get("countTerm"):
        n = sum(1 for blk in re.split(r"\n(?=\[\d+\])", pk) if re.search(r"\b" + ev["countTerm"] + r"\b", blk, re.I))
        return n >= case["probe"]["value"]
    return all(e.lower() in pk.lower() for e in ev) if ev else True


def row_pass(case, g):
    kind = case["probe"]["kind"]
    if kind == "ranges":   # required facts AND no mislabel
        a6, a6b = g["results"].get("A6", ("N/A",))[0], g["results"].get("A6b", ("N/A",))[0]
        return a6 in ("PASS", "N/A") and a6b in ("PASS", "N/A") and not (a6 == "N/A" and a6b == "N/A")
    return g["results"].get(PG[kind], ("N/A",))[0] == "PASS"


root = sys.argv[1]
ov_path = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--overrides=")), None)
overrides = {k: v for k, v in (json.load(open(ov_path)) if ov_path else {}).items() if not k.startswith("_")}
arms = sorted(d for d in glob.glob(os.path.join(root, "*")) if os.path.isdir(d))
res = collections.defaultdict(lambda: collections.defaultdict(list))   # cat → arm → [(case, run, pass, inpk, detail, answer)]
for a in arms:
    for pd in sorted(glob.glob(os.path.join(a, "r*"))):
        sr = G.load_json(os.path.join(pd, "store-rows.json"), {"rows": []})
        grades = G.load_json(os.path.join(pd, "grades.json"), {})
        for r in sr["rows"]:
            case = probes.get(r["case"])
            g = grades.get(f"{r['case']}.off.store")
            if not case or not g:
                continue
            t = G.load_json(os.path.join(pd, f"turn-{r['seq']:03d}.json"), {})
            ok = row_pass(case, g)
            ov = overrides.get(f"{os.path.basename(a)}/{os.path.basename(pd)}/{r['case']}")
            if ov:
                ok = ov["pass"]
            gid = "A6/A6b" if case["probe"]["kind"] == "ranges" else PG[case["probe"]["kind"]]
            det = "; ".join(f"{k}: {d}" for k, (s, d) in g["results"].items() if k in ("A6", "A6b", "D1", "D2", "O1", "K1", "B1", "M1", "Q1") and s in ("FAIL", "FLAG"))
            if ov:
                det = "CC read: " + ov["why"]
            res[case["category"]][os.path.basename(a)].append((r["case"], os.path.basename(pd), ok, in_packet(case, t), det, t.get("finalText", "")))
names = [os.path.basename(a) for a in arms]
print("| category | probes | " + " | ".join(names) + " |")
print("|---|---|" + "---|" * len(names))
for cat in sorted(res):
    cases = sorted({x[0] for arm in res[cat].values() for x in arm})
    cells = []
    for n in names:
        rows = res[cat].get(n, [])
        p = sum(1 for x in rows if x[2]); inpk = sum(1 for x in rows if x[3]); wrong_with = sum(1 for x in rows if not x[2] and x[3])
        cells.append(f"**{p}/{len(rows)}** pass · facts in packet {inpk}/{len(rows)} · wrong-with-facts {wrong_with}")
    print(f"| {cat} | {', '.join(cases)} | " + " | ".join(cells) + " |")
print()
print("Per probe (pass count over 3 runs):")
print("| probe | question | " + " | ".join(names) + " |")
print("|---|---|" + "---|" * len(names))
for cid, c in probes.items():
    cells = []
    for n in names:
        rows = [x for x in res[c["category"]].get(n, []) if x[0] == cid]
        cells.append(f"{sum(1 for x in rows if x[2])}/{len(rows)} (pk {sum(1 for x in rows if x[3])}/{len(rows)})")
    print(f"| {cid} | {c['question']} | " + " | ".join(cells) + " |")
if "--examples" in sys.argv:
    print("\nOne failure per failing category (prefer a failure WITH the facts in the packet):")
    for cat in sorted(res):
        fails = [(n, x) for n in names for x in res[cat].get(n, []) if not x[2]]
        if not fails:
            continue
        fails.sort(key=lambda f: not f[1][3])
        n, x = fails[0]
        print(f"\n### {cat} — {x[0]} · {n} · {x[1]} · facts in packet: {'yes' if x[3] else 'NO'}\n_{x[4][:300]}_\n\n> " + x[5][:600].replace("\n", "\n> "))
