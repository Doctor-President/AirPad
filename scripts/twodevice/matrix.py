#!/usr/bin/env python3
"""Mac batch B1e — the two-device matrix: two Simulators, one library (scratch), a stand-in for iCloud between them.

    matrix.py <app> <udidA> <udidB> <out_dir>        (CONTROL=1: the merge off — the positive control must lose text)

Device A is named "iPhone", device B "Mac" (B stands in for the Mac copy: a sandboxed Mac app can't share a folder
with a Simulator). Each runs the DEBUG build on its own replica (`-TwoDeviceRoot`), driven through the app's command
channel (`-TwoDeviceCommands`, the same store paths the UI uses); `fakecloud.py` syncs the replicas. `-UITestLibrary`
keeps the library empty (no Sample Library), so every scenario starts from entries it creates.

Per scenario: what's expected, what each device shows after things go quiet, and the byte check: every text any
command wrote (note bodies, titles, summaries) must still exist, verbatim, on BOTH devices — in the entry or in its
version history — unless the scenario deleted it on purpose. Results: <out>/matrix.json + matrix.md.
"""
import json, os, subprocess, sys, time, uuid

APP, UA, UB, OUT = sys.argv[1:5]
BUNDLE = "com.doctorpresident.airpad"
H = os.path.abspath(OUT)
os.makedirs(H, exist_ok=True)
SIMS = {"A": UA, "B": UB}
NAMES = {"A": "iPhone", "B": "Mac"}
seq = [0]


def sh(*a, check=False):
    return subprocess.run(a, capture_output=True, text=True, check=check)


def launch(r, extra=()):
    d = os.path.join(H, r)
    for sub in ("library", "cmd"):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    sh("xcrun", "simctl", "terminate", SIMS[r], BUNDLE)
    args = ["-TwoDeviceRoot", os.path.join(d, "library"), "-TwoDeviceCommands", os.path.join(d, "cmd"),
            "-SyncDeviceID", f"dev{r}", "-SyncDeviceName", NAMES[r], "-SyncPollSeconds", "1", "-UITestLibrary",
            *(["-SyncMergeOffForControl"] if os.environ.get("CONTROL") else []), *extra]
    log = open(os.path.join(d, "app.log"), "a")
    p = subprocess.Popen(["xcrun", "simctl", "launch", "--console-pty", "--terminate-running-process", SIMS[r], BUNDLE, *args],
                         stdout=log, stderr=subprocess.STDOUT)
    return p


def cmd(r, op, timeout=90, **kw):
    seq[0] += 1
    cid = f"{seq[0]:04d}-{uuid.uuid4().hex[:6]}"
    c = {"id": cid, "op": op, **kw}
    cdir = os.path.join(H, r, "cmd")
    tmp = os.path.join(cdir, f".tmp-{cid}")
    json.dump(c, open(tmp, "w"))
    os.replace(tmp, os.path.join(cdir, f"cmd-{cid}.json"))
    done = os.path.join(cdir, f"done-{cid}.json")
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(done):
            time.sleep(0.05)
            return json.load(open(done)).get("result")
        time.sleep(0.2)
    raise TimeoutError(f"{r} {op} timed out")


def offline(r, on):
    p = os.path.join(H, r, "offline")
    if on:
        open(p, "w").close()
    elif os.path.exists(p):
        os.remove(p)


def quiet(min_quiet=4.0, timeout=120):
    """Until the stand-in for iCloud has had nothing to do for `min_quiet` s (the apps poll every 1 s)."""
    t0 = time.time()
    calm_since = None
    while time.time() - t0 < timeout:
        try:
            _, n = open(os.path.join(H, "fakecloud.status")).read().split()
            n = int(n)
        except Exception:
            n = 1
        now = time.time()
        if n == 0:
            calm_since = calm_since or now
            if now - calm_since >= min_quiet:
                return True
        else:
            calm_since = None
        time.sleep(0.3)
    return False


def settle():
    quiet()
    for r in "AB":
        cmd(r, "rescan")
    time.sleep(2.5)
    quiet()


def entry(dump, eid):
    return next((n for n in dump["nodes"] if n["id"] == eid), None)


def texts_of(n):
    if not n:
        return set()
    out = {n["title"], n["summary"]} | {i["content"] for i in n["items"]} | set(n.get("version_values", []))
    return {t for t in out if t}


def content(n):
    if not n:
        return None
    return {"title": n["title"], "summary": n["summary"], "items": [(i["id"], i["content"]) for i in n["items"]]}


results = []


def scenario(name, setup, expect, written, check, deleted_ok=()):
    print(f"== {name}", flush=True)
    t0 = time.time()
    eid = setup()
    settle()
    da, db = cmd("A", "dump"), cmd("B", "dump")
    ea, eb = entry(da, eid), entry(db, eid)
    lost = {}
    for r, e in (("A", ea), ("B", eb)):
        have = texts_of(e)
        missing = [w for w in written if w not in have and w not in deleted_ok]
        if missing:
            lost[r] = missing
    same = content(ea) == content(eb)
    ok, observed = check(ea, eb)
    res = {"scenario": name, "expected": expect, "observed": observed, "pass": bool(ok and same and not lost),
           "nothing_lost": not lost, "lost": lost, "devices_agree": same, "seconds": round(time.time() - t0, 1),
           "A": ea, "B": eb}
    results.append(res)
    print(f"   {'PASS' if res['pass'] else 'FAIL'} · agree={same} · lost={lost or 'none'} · {observed}", flush=True)
    json.dump(results, open(os.path.join(H, "matrix.json"), "w"), indent=1, ensure_ascii=False)


def new_entry(title, text):
    eid = f"E-{uuid.uuid4().hex[:8]}"
    cmd("A", "new_entry", entry=eid, item=f"{eid}-i1", title=title, text=text)
    settle()
    assert entry(cmd("B", "dump"), eid), f"{eid} never reached B"
    return eid


def note(e, item):
    return next((i["content"] for i in (e or {}).get("items", []) if i["id"] == item), None)


# ---------------------------------------------------------------- run
fc = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "fakecloud.py"), H, "A", "B"])
try:
    for r in "AB":
        sh("xcrun", "simctl", "boot", SIMS[r])
        sh("xcrun", "simctl", "install", SIMS[r], APP, check=True)
    launch("A")
    cmd("A", "dump", timeout=180)
    launch("B")
    cmd("B", "dump", timeout=180)

    # S1 — both online, alternating edits.
    def s1():
        e = new_entry("S1 alternating", "S1 start")
        cmd("A", "set_text", entry=e, item=f"{e}-i1", text="S1 start · A1"); settle()
        cmd("B", "set_text", entry=e, item=f"{e}-i1", text="S1 start · A1 · B1"); settle()
        cmd("A", "set_title", entry=e, title="S1 title from A"); settle()
        cmd("B", "add_item", entry=e, item=f"{e}-i2", text="S1 B's new note")
        s1.e = e
        return e
    scenario("S1 both online, alternating edits", s1,
             "every edit arrives on the other device; no versions kept",
             ["S1 start · A1 · B1", "S1 title from A", "S1 B's new note"],
             lambda a, b: (note(a, f"{s1.e}-i1") == "S1 start · A1 · B1" and a["title"] == "S1 title from A"
                           and note(a, f"{s1.e}-i2") == "S1 B's new note" and not a["versions"],
                           f"title={a and a['title']!r} i1={note(a, f'{s1.e}-i1')!r} i2={note(a, f'{s1.e}-i2')!r} versions={len((a or {}).get('versions', []))}"))

    # S2 — both offline, the SAME note edited on both, then reconnect.
    def s2():
        e = new_entry("S2 offline same note", "S2 base")
        offline("A", True); offline("B", True)
        cmd("A", "set_text", entry=e, item=f"{e}-i1", text="S2 written on the iPhone, offline")
        time.sleep(1.5)
        cmd("B", "set_text", entry=e, item=f"{e}-i1", text="S2 written on the Mac, offline (later)")
        time.sleep(1.5)
        offline("A", False); offline("B", False)
        s2.e = e
        return e
    scenario("S2 both offline, same note, reconnect", s2,
             "the later edit (Mac) wins; the iPhone's text is kept in Versions on both, with the quiet note",
             ["S2 written on the iPhone, offline", "S2 written on the Mac, offline (later)"],
             lambda a, b: (note(a, f"{s2.e}-i1") == "S2 written on the Mac, offline (later)"
                           and any("S2 written on the iPhone" in v for v in a.get("version_values", []))
                           and a["note"] != "",
                           f"note={note(a, f'{s2.e}-i1')!r} versions={[v['label'] + ' from ' + v['from'] for v in a['versions']]} quiet-note={a['note']!r}"))

    # S3 — an offline edit vs an online delete.
    def s3():
        e = new_entry("S3 edit vs delete", "S3 base")
        offline("A", True)
        cmd("A", "set_text", entry=e, item=f"{e}-i1", text="S3 edited offline on the iPhone")
        cmd("B", "delete_entry", entry=e)
        quiet()
        time.sleep(1)
        offline("A", False)
        s3.e = e
        return e
    scenario("S3 offline edit vs online delete", s3,
             "the edit isn't lost: the entry comes back on both with the iPhone's text",
             ["S3 edited offline on the iPhone"],
             lambda a, b: (note(a, f"{s3.e}-i1") == "S3 edited offline on the iPhone" and b is not None,
                           f"A has it={a is not None} B has it={b is not None} text={note(a, f'{s3.e}-i1')!r}"))

    # S4 — a new entry on both, offline.
    def s4():
        offline("A", True); offline("B", True)
        ea, eb = f"E-{uuid.uuid4().hex[:8]}", f"E-{uuid.uuid4().hex[:8]}"
        cmd("A", "new_entry", entry=ea, item=f"{ea}-i1", title="S4 from the iPhone", text="S4 iPhone body")
        cmd("B", "new_entry", entry=eb, item=f"{eb}-i1", title="S4 from the Mac", text="S4 Mac body")
        offline("A", False); offline("B", False)
        s4.ea, s4.eb = ea, eb
        return ea
    def s4check(a, b):
        db = cmd("B", "dump"); da = cmd("A", "dump")
        both = all(entry(d, x) for d in (da, db) for x in (s4.ea, s4.eb))
        return both, f"both entries on both devices={both}; counts A={da['count']} B={db['count']}"
    scenario("S4 a new entry on both (offline)", s4, "both entries on both devices", ["S4 iPhone body", "S4 from the iPhone"], s4check)

    # S5 — a background enrichment racing a user edit (the user's title is older than the model's).
    def s5():
        e = new_entry("S5 start title", "S5 body")
        offline("A", True); offline("B", True)
        cmd("B", "set_title", entry=e, title="S5 title the user typed on the Mac")
        time.sleep(1.5)
        cmd("A", "enrich", entry=e, title="S5 model's title (later)", summary="S5 model's summary")
        offline("A", False); offline("B", False)
        s5.e = e
        return e
    scenario("S5 background enrichment racing a user edit", s5,
             "the user's title wins although the model wrote later; the model's summary (untouched by the user) is kept",
             ["S5 title the user typed on the Mac", "S5 model's summary", "S5 body"],
             lambda a, b: (a["title"] == "S5 title the user typed on the Mac" and a["summary"] == "S5 model's summary",
                           f"title={a['title']!r} summary={a['summary']!r}"),
             deleted_ok=("S5 start title",))

    # S6 — the entry is OPEN on A with unsaved typing while B edits it (another note + the title).
    def s6():
        e = new_entry("S6 open on the iPhone", "S6 body")
        cmd("A", "add_item", entry=e, item=f"{e}-i2", text="S6 second note")
        settle()
        cmd("A", "type", entry=e, item=f"{e}-i1", text="S6 body + typed on the iPhone, not yet saved")
        cmd("B", "set_text", entry=e, item=f"{e}-i2", text="S6 second note, edited on the Mac")
        cmd("B", "set_title", entry=e, title="S6 title from the Mac")
        s6.e = e
        return e
    scenario("S6 entry open on A (unsaved typing) while B edits it", s6,
             "A's typing is saved and merged (not overwritten, not lost); B's note + title arrive on A",
             ["S6 body + typed on the iPhone, not yet saved", "S6 second note, edited on the Mac", "S6 title from the Mac"],
             lambda a, b: (note(a, f"{s6.e}-i1") == "S6 body + typed on the iPhone, not yet saved"
                           and note(a, f"{s6.e}-i2") == "S6 second note, edited on the Mac" and a["title"] == "S6 title from the Mac",
                           f"i1={note(a, f'{s6.e}-i1')!r} i2={note(a, f'{s6.e}-i2')!r} title={a['title']!r}"),
             deleted_ok=("S6 body", "S6 second note"))

    # S6b — the SAME note: typing on A (unsaved) while B saves that note.
    def s6b():
        e = new_entry("S6b same note", "S6b body")
        cmd("B", "set_text", entry=e, item=f"{e}-i1", text="S6b body, saved on the Mac first")
        time.sleep(0.2)
        cmd("A", "type", entry=e, item=f"{e}-i1", text="S6b body, typed on the iPhone (newer, unsaved)")
        s6b.e = e
        return e
    scenario("S6b same note typed on A while B saved it", s6b,
             "newest wins (A's typing, saved when B's change arrives); B's text kept in Versions",
             ["S6b body, saved on the Mac first", "S6b body, typed on the iPhone (newer, unsaved)"],
             lambda a, b: (note(a, f"{s6b.e}-i1") == "S6b body, typed on the iPhone (newer, unsaved)",
                           f"i1={note(a, f'{s6b.e}-i1')!r} versions={[v['label'] + ' from ' + v['from'] for v in a['versions']]}"),
             deleted_ok=("S6b body",))

    # S7 — restore a kept version (from S2) on B; it reaches A.
    def s7():
        e = s2.e
        d = cmd("B", "dump")
        v = next(x for x in entry(d, e)["versions"] if x["state"] == "new")
        cmd("B", "restore", entry=e, version=v["id"])
        s7.e = e
        return e
    scenario("S7 restore a kept version (one tap) on B", s7,
             "the iPhone's S2 text is back in the note on both; the Mac's text is now the kept version",
             ["S2 written on the iPhone, offline", "S2 written on the Mac, offline (later)"],
             lambda a, b: (note(a, f"{s2.e}-i1") == "S2 written on the iPhone, offline",
                           f"i1={note(a, f'{s2.e}-i1')!r} versions={[(v['label'], v['state']) for v in a['versions']]}"))
finally:
    fc.terminate()
    for r in "AB":
        sh("xcrun", "simctl", "terminate", SIMS[r], BUNDLE)

md = ["| scenario | expected | observed | nothing lost | devices agree | result |", "|---|---|---|---|---|---|"]
for r in results:
    md.append(f"| {r['scenario']} | {r['expected']} | {r['observed'].replace('|', '/')} | {'yes' if r['nothing_lost'] else 'NO: ' + json.dumps(r['lost'], ensure_ascii=False)} | {'yes' if r['devices_agree'] else 'NO'} | {'PASS' if r['pass'] else 'FAIL'} |")
open(os.path.join(H, "matrix.md"), "w").write("\n".join(md) + "\n")
print("\n".join(md))
print(f"{sum(r['pass'] for r in results)}/{len(results)} PASS")
