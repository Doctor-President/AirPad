#!/usr/bin/env python3
"""Batch B fix-up F3 — a remote change must refresh every view showing the entry (T: after a Restore on the iPhone the
Mac's CARD kept the old note text until the entry was opened). Two Simulators + fakecloud, as matrix.py:
A shows the Cards view (`VIEW=-OpenCardView`, or -OpenListView / -OpenMap), B changes the entry. A's screen is
captured after each step and A's store dump says what the card SHOULD show.

    cardrefresh.py <app> <udidA> <udidB> <out>
"""
import json, os, subprocess, sys, time, uuid
APP, UA, UB, OUT = sys.argv[1:5]
BUNDLE = "com.doctorpresident.airpad"
H = os.path.abspath(OUT); os.makedirs(H, exist_ok=True)
SIMS = {"A": UA, "B": UB}; NAMES = {"A": "Mac", "B": "iPhone"}; seq = [0]
def sh(*a, check=False): return subprocess.run(a, capture_output=True, text=True, check=check)
def launch(r, extra=()):
    d = os.path.join(H, r)
    for sub in ("library", "cmd"): os.makedirs(os.path.join(d, sub), exist_ok=True)
    sh("xcrun", "simctl", "terminate", SIMS[r], BUNDLE)
    args = ["-TwoDeviceRoot", os.path.join(d, "library"), "-TwoDeviceCommands", os.path.join(d, "cmd"), "-SyncDeviceID", f"dev{r}",
            "-SyncDeviceName", NAMES[r], "-SyncPollSeconds", "1", "-UITestLibrary", "-EmbedCPUOnly", *extra]
    log = open(os.path.join(d, "app.log"), "a")
    return subprocess.Popen(["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", SIMS[r], BUNDLE, *args], stdout=log, stderr=subprocess.STDOUT)
def cmd(r, op, timeout=90, **kw):
    seq[0] += 1; cid = f"{seq[0]:04d}-{uuid.uuid4().hex[:6]}"; cdir = os.path.join(H, r, "cmd")
    tmp = os.path.join(cdir, f".tmp-{cid}"); json.dump({"id": cid, "op": op, **kw}, open(tmp, "w")); os.replace(tmp, os.path.join(cdir, f"cmd-{cid}.json"))
    done = os.path.join(cdir, f"done-{cid}.json"); t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(done): time.sleep(0.05); return json.load(open(done)).get("result")
        time.sleep(0.2)
    raise TimeoutError(op)
def offline(r, on):
    p = os.path.join(H, r, "offline")
    if on: open(p, "w").close()
    elif os.path.exists(p): os.remove(p)
def quiet(q=4.0, timeout=60):
    t0 = time.time(); calm = None
    while time.time() - t0 < timeout:
        try: n = int(open(os.path.join(H, "fakecloud.status")).read().split()[1])
        except Exception: n = 1
        now = time.time()
        if n == 0:
            calm = calm or now
            if now - calm >= q: return
        else: calm = None
        time.sleep(0.3)
def settle():
    quiet(); [cmd(r, "rescan") for r in "AB"]; time.sleep(2.5); quiet()
def shot(name): sh("xcrun", "simctl", "io", SIMS["A"], "screenshot", os.path.join(H, f"{name}.png"))
def note(r, e):
    n = next((x for x in cmd(r, "dump")["nodes"] if x["id"] == e), None)
    return n and n["items"][0]["content"]
fc = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "fakecloud.py"), H, "A", "B"])
steps = []
try:
    for r in "AB": sh("xcrun", "simctl", "boot", SIMS[r]); sh("xcrun", "simctl", "install", SIMS[r], APP, check=True)
    launch("A", os.environ.get("VIEW", "-OpenCardView").split()); cmd("A", "dump", timeout=180)
    launch("B"); cmd("B", "dump", timeout=180)
    e = f"E-{uuid.uuid4().hex[:8]}"
    cmd("A", "new_entry", entry=e, item=f"{e}-i1", title="F3 card", text="F3 OLD body text, written first")
    settle(); time.sleep(3); shot("1-start"); steps.append(("start", note("A", e)))
    cmd("B", "set_text", entry=e, item=f"{e}-i1", text="F3 NEW body text from the iPhone")
    settle(); time.sleep(2); shot("2-after-remote-edit"); steps.append(("remote edit", note("A", e)))
    offline("A", True); offline("B", True)
    cmd("A", "set_text", entry=e, item=f"{e}-i1", text="F3 Mac text, offline")
    time.sleep(1.5)
    cmd("B", "set_text", entry=e, item=f"{e}-i1", text="F3 iPhone text, offline (later)")
    offline("A", False); offline("B", False)
    settle(); time.sleep(2); shot("3-after-conflict"); steps.append(("conflict merged", note("A", e)))
    v = next(x for x in next(n for n in cmd("B", "dump")["nodes"] if n["id"] == e)["versions"] if x["state"] == "new")
    cmd("B", "restore", entry=e, version=v["id"])
    settle(); time.sleep(2); shot("4-after-remote-restore"); steps.append(("remote restore", note("A", e)))
finally:
    fc.terminate()
json.dump(steps, open(os.path.join(H, "steps.json"), "w"), indent=1)
for s in steps: print(s)
