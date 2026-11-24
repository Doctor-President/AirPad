#!/usr/bin/env python3
"""Sweep 2b · 2.3 scene 2 — one summary row per run (Scene 1's bar): the recorder's 120 Hz link frames while input moves
the cards (scroll / scrollmove from the step to its settle, the 10 s trackpad hand), one-vsync share of frame gaps
(≤ 9.5 ms), gaps > 12.5 ms per 10 s of input, frames per whole second of the hand (min / median), main-thread CPU per
frame (vitals, input seconds), rest (10 s from last input + 0.5 s): passes / presents / drift ticks of the pass, field
redraws and process CPU from trial_cards.py's cards.txt. Numbers only.
   trial_cards_sum.py <run dir>..."""
import json, sys, re, collections, pathlib
for dd in sys.argv[1:]:
    d0 = pathlib.Path(dd); d = json.load(open(d0 / "recording.json")); off = d["wallOffset"]
    steps = []
    for l in open(d0 / "rperf.txt"):
        m = re.match(r"^(\S+) (\S+) visible \S+ settled (\S+) .* at (\d+)", l)
        if m: steps.append((m[1], m[2], m[3], int(m[4]) / 1000 - off))
    wins = []
    for lab, verb, settled, t in steps:
        if lab in ("cards-scroll", "cards-scrollmv"): wins.append((t, t + (float(settled) / 1000 if settled not in ("-", "0") else 1.0)))
        if lab == "cards-hand": hand = (t, t + 10.0); wins.append(hand)
    fr = d["frames"]
    gaps = [g for t, g in fr if any(a <= t < b for a, b in wins)]
    dur = sum(b - a for a, b in wins)
    one = 100 * sum(1 for g in gaps if g <= 9.5) / max(1, len(gaps)); late = sum(1 for g in gaps if g > 12.5)
    secs = [s for s in range(int(hand[0]) + 1, int(hand[1]))]
    per = collections.Counter(int(t) for t, g in fr)
    ps = sorted(per[s] for s in secs)
    vit = {int(v[0]): v for v in d.get("vitals", [])}
    allsecs = {s for a, b in wins for s in range(int(a) + 1, int(b))}
    mc = sorted(vit[s][3] * 10 / per[s] for s in allsecs if s in vit and per[s] >= 30)
    last = max(t for lab, verb, settled, t in steps if lab.startswith("cards-") and lab != "cards-rest")
    last = max(last, hand[1]); r0, r1 = last + 0.5, last + 10.5
    P = d.get("probe", [])
    rp = sum(1 for t, c, v in P if int(c) == 40 and r0 <= t < r1); rpr = sum(1 for t, c, v in P if int(c) == 42 and v > 0 and r0 <= t < r1)
    ticks = sum(1 for t, c, v in P if int(c) == 45 and v == 5 and r0 <= t < r1)
    ct = (d0 / "cards.txt").read_text() if (d0 / "cards.txt").exists() else ""
    m = re.search(r"field redraws \(BlobFieldTick\) (\d+)", ct); bt = m[1] if m else "?"
    m = re.search(r"process CPU % mean ([\d.]+)", ct); rcpu = m[1] if m else "?"
    arm = next((m[1].split("arm ")[-1] for m in d["marks"] if "cards trial arm" in m[1]), "?")
    busy = sum(1 for l in open(d0 / "quiet.log") if "BUSY" in l) if (d0 / "quiet.log").exists() else -1
    print(f"| {d0.name} | {arm} | {d['device'].get('windowPt')} | {one:.1f} % | {late / dur * 10:.1f} ({late} in {dur:.1f} s) |"
          f" {ps[0] if ps else '-'} / {ps[len(ps)//2] if ps else '-'} | {mc[len(mc)//2] if mc else float('nan'):.2f} |"
          f" passes {rp} · presents {rpr} · drift {ticks} · field redraws {bt} · CPU {rcpu} % (recorder on) | {busy} |")
