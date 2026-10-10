#!/usr/bin/env python3
"""Brief CJ — run the inventory's launch-arg self-tests in the Simulator, one launch each, and judge each by its own
rule from selftests.tsv (done / pass / fail regexes over the RAW console lines — some verdicts sit on a continuation
line of a multi-line log). Host-free rows only unless --with-host-args is given.

    selftests.py [--sim UDID] [--app path/to/AirPad.app] [--only A,B] [--timeout 120] [--out dir] [--with-host-args "..."]

PASS needs: the done line seen, no fail line, at least one pass line (a `diagnostic` row is reported, not judged).
"""
import argparse, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
AIRPAD = os.path.abspath(os.path.join(HERE, "..", ".."))
ap = argparse.ArgumentParser()
ap.add_argument("--sim", default="1E797E28-B816-4CA3-B6B5-5E640671067D")
ap.add_argument("--app", default=os.path.join(AIRPAD, "build/gauntlet-dd/Build/Products/Debug-iphonesimulator/AirPad.app"))
ap.add_argument("--only", default="")
ap.add_argument("--timeout", type=int, default=120)
ap.add_argument("--out", default=os.path.join(AIRPAD, "build/inventory-runs/selftests-" + time.strftime("%Y%m%d-%H%M%S")))
ap.add_argument("--with-host-args", default="")
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
BID = "com.doctorpresident.airpad"
rows = [dict(zip(h, l.rstrip("\n").split("\t"))) for f in [open(os.path.join(HERE, "selftests.tsv"))]
        for h in [f.readline().rstrip("\n").split("\t")] for l in f if l.strip()]
only = set(filter(None, a.only.split(",")))
sim = lambda *x: subprocess.run(["xcrun", "simctl", *x], capture_output=True, text=True)
sim("boot", a.sim); sim("bootstatus", a.sim, "-b")
r = sim("install", a.sim, a.app)
if r.returncode: sys.exit(f"install failed: {r.stderr}")
results, t_all = [], time.time()
for row in rows:
    if only and row["name"] not in only: continue
    if row["needs"] == "host" and not a.with_host_args:
        results.append((row["name"], "SKIP", "needs a Host (--with-host-args)", 0)); continue
    args = row["launch_args"].split() + (a.with_host_args.split() if row["needs"] == "host" else []) + ["-EmbedCPUOnly"]
    log = os.path.join(a.out, row["name"] + ".log")
    sim("terminate", a.sim, BID)
    t0 = time.time()
    p = subprocess.Popen(["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", a.sim, BID, *args],
                         stdout=open(log, "w"), stderr=subprocess.STDOUT)
    done = re.compile(row["done_regex"])
    seen = False
    while time.time() - t0 < a.timeout:
        time.sleep(1)
        txt = open(log, errors="replace").read()
        if done.search(txt):
            time.sleep(2); seen = True; break
    p.kill(); sim("terminate", a.sim, BID)
    txt = open(log, errors="replace").read()
    dt = time.time() - t0
    if not seen:
        results.append((row["name"], "FAIL", f"no done line in {a.timeout}s", dt)); continue
    if row["needs"] == "diagnostic":
        results.append((row["name"], "DIAG", "printed — check by eye: " + row["notes"][:80], dt)); continue
    fails = [l for l in txt.splitlines() if row["fail_regex"] and re.search(row["fail_regex"], l)]
    passes = [l for l in txt.splitlines() if row["pass_regex"] and re.search(row["pass_regex"], l)]
    ok = not fails and passes
    results.append((row["name"], "PASS" if ok else "FAIL",
                    (fails[0].strip()[-160:] if fails else f"{len(passes)} pass line(s)" if passes else "no pass line"), dt))
with open(os.path.join(a.out, "summary.md"), "w") as f:
    f.write(f"| self-test | result | detail | s |\n|---|---|---|---|\n")
    for n, v, d, dt in results:
        f.write(f"| {n} | {v} | {d.replace('|', '/')} | {dt:.0f} |\n")
for n, v, d, dt in results:
    print(f"{v:4} {n:28} {dt:5.0f}s  {d[:110]}")
bad = [n for n, v, _, _ in results if v == "FAIL"]
print(f"\n{len(results)} run · {sum(v == 'PASS' for _, v, _, _ in results)} PASS · {len(bad)} FAIL · "
      f"{sum(v in ('DIAG', 'SKIP') for _, v, _, _ in results)} diag/skip · wall {time.time() - t_all:.0f}s → {a.out}")
sys.exit(1 if bad else 0)
