#!/usr/bin/env python3
"""Brief CJ — record a real UI run ONCE as replay scripts, so the driver can be re-run with no Host and no model.

    record_replay.py <live_run_dir> <out_dir>

For every chat group of the live run, the turn files of that launch (in order) become one replay file
`<out_dir>/<chat>.json` holding each turn's RAW deltas exactly as the model streamed them (answer + thinking
channels, `[n]` markers untouched). A turn that streamed nothing (e.g. the forced failure before a Retry) is
skipped: no model call happens for it on replay either. Prints the `--replay chat=file` flags and the case ids,
for `lab.sh` / `run.sh … --runs 1` with `--only`. The replay is the SAME input for both arms of a driver A/B;
it is not a proof the model would answer the same.
"""
import glob, json, os, sys

live, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
cfg = json.load(open(os.path.join(live, "config.json")))
turns = {}
for p in glob.glob(os.path.join(live, "turn-*.json")):
    t = json.load(open(p)); turns[t["seq"]] = t
flags, cases = [], []
for g in cfg["groups"]:
    chat = g["group"].rsplit(".", 2)[0]
    uis = [json.load(open(p)) for t in g["turns"] for p in [os.path.join(live, f"ui-{t['row']}.json")] if os.path.exists(p)]
    if not uis:
        continue
    launch = turns.get(uis[0]["seq"], {}).get("launchID")
    seqs = sorted(s for s, t in turns.items() if t.get("launchID") == launch)
    rp = []
    for s in seqs:
        raw = turns[s].get("raw") or []
        if not raw:
            continue
        rp.append({"deltas": [["t" if d.get("ch") == "thinking" else "a", d.get("s", "")] for d in raw], "delayMs": 4})
    if not rp:
        continue
    path = os.path.abspath(os.path.join(out, f"{chat}.json"))
    json.dump({"turns": rp}, open(path, "w"), indent=1, ensure_ascii=False)
    flags.append(f"{chat}={path}")
    cases += [t["case"] for t in g["turns"]]
print(" ".join(f"--replay {f}" for f in flags))
print("--only " + ",".join(dict.fromkeys(cases)))
