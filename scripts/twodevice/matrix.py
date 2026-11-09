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
            *(["-SyncMergeOffForControl"] if os.environ.get("CONTROL") else []),
            *(["-SyncTombstonesOffForControl", "-SyncLegacyHeaderFlushForControl"] if os.environ.get("CONTROL_F1") else []),
            *(["-SyncLegacyTypingForControl", "-SyncNoDraftsForControl"] if os.environ.get("CONTROL_F2") else []),
            *(["-SyncNoCatchUpFollowForControl"] if os.environ.get("CONTROL_F3") else []),
            *extra]
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


def cmd_async(r, op, **kw):
    """Send a command without waiting; returns a function that waits for its result."""
    seq[0] += 1
    cid = f"{seq[0]:04d}-{uuid.uuid4().hex[:6]}"
    cdir = os.path.join(H, r, "cmd")
    tmp = os.path.join(cdir, f".tmp-{cid}")
    json.dump({"id": cid, "op": op, **kw}, open(tmp, "w"))
    os.replace(tmp, os.path.join(cdir, f"cmd-{cid}.json"))
    done = os.path.join(cdir, f"done-{cid}.json")
    def wait(timeout=120):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if os.path.exists(done):
                time.sleep(0.05)
                return json.load(open(done)).get("result")
            time.sleep(0.2)
        raise TimeoutError(f"{r} {op} timed out")
    return wait


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
    only = [x for x in os.environ.get("ONLY", "").split(",") if x]   # ONLY=S12,S10 runs just those
    if only and name.split()[0] not in only:
        return
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

    # ---- batch B fix-up F1 (T's pass step 10: deletes came back) ----
    def gone_everywhere(*ids):
        da, db = cmd("A", "dump"), cmd("B", "dump")
        left = {r: [x for x in ids if entry(d, x)] for r, d in (("A", da), ("B", db))}
        return not left["A"] and not left["B"], f"still there: A={left['A'] or 'none'} B={left['B'] or 'none'}"

    # S8 — informed delete: one entry the Mac edited (its header still open), one the Mac made; the iPhone deletes both.
    def s8():
        e1 = new_entry("S8 one", "S8 one body")
        cmd("B", "open_header", entry=e1, title="S8 one (Mac)"); settle()
        e2 = f"E-{uuid.uuid4().hex[:8]}"
        cmd("B", "new_entry", entry=e2, item=f"{e2}-i1", title="", text="S8 four body, made on the Mac")
        cmd("B", "open_header", entry=e2, title="S8 four (Mac)"); settle()
        assert entry(cmd("A", "dump"), e2), "S8: the Mac's entry never reached the iPhone"
        cmd("A", "delete_entry", entry=e1); cmd("A", "delete_entry", entry=e2)
        settle()
        cmd("B", "enrich", entry=e2, title="S8 model title", summary="S8 model summary")   # a background pass after
        settle(); time.sleep(2); settle()
        s8.e1, s8.e2 = e1, e2
        return e1
    scenario("S8 informed delete (Mac edited one, made the other; iPhone deletes both)", s8,
             "both stay deleted on both devices", [], lambda a, b: gone_everywhere(s8.e1, s8.e2))

    # S8b — a background pass on a device that hadn't seen the delete yet (offline), then it reconnects.
    def s8b():
        e = new_entry("S8b background vs delete", "S8b body")
        offline("B", True)
        cmd("A", "delete_entry", entry=e); quiet()
        cmd("B", "enrich", entry=e, title="S8b model title (offline)", summary="S8b model summary")
        time.sleep(1.5)
        offline("B", False)
        settle(); time.sleep(2); settle()
        s8b.e = e
        return e
    scenario("S8b background write offline vs an online delete", s8b,
             "a background pass never brings an entry back: deleted on both", [], lambda a, b: gone_everywhere(s8b.e))

    # S9 — the reverse direction: the Mac deletes an entry the iPhone made and edited (header open).
    def s9():
        e = new_entry("S9 reverse", "S9 body")
        cmd("A", "set_text", entry=e, item=f"{e}-i1", text="S9 body · edited on the iPhone")
        cmd("A", "open_header", entry=e, title="S9 title (iPhone)"); settle()
        cmd("B", "delete_entry", entry=e)
        settle(); time.sleep(2); settle()
        s9.e = e
        return e
    scenario("S9 reverse: the Mac deletes, the iPhone had edited it", s9,
             "deleted on both", [], lambda a, b: gone_everywhere(s9.e))

    # ---- batch B fix-up F2 (T's pass: half-typed text synced) ----
    def whole(seen, final, start):
        """Every value the other device showed: the start, the final, or the final cut at a word boundary."""
        bad = [v for v in seen if v != start and not (final.startswith(v) and (len(v) == len(final) or final[len(v)] == " "))]
        return bad

    # S10 — A types a note and a title key by key, hesitating mid-word (1.3 s) and getting echoes of its own writes
    # mid-word; B watches the whole time.
    def s10():
        e = new_entry("", "S10 start.")
        watch = cmd_async("B", "watch", entry=e, seconds=40)
        time.sleep(1)
        cmd("A", "keystrokes", entry=e, item=f"{e}-i1", text=" Mac change made here, then more", key_ms=110,
            hesitate={"3": 1.3, "8": 1.2, "16": 2.4}, echo_at=[2, 7, 20], timeout=120)
        cmd("A", "title_keys", entry=e, text="2D one (Mac)", key_ms=110, hesitate={"1": 1.3, "5": 1.2}, echo_at=[1, 4], timeout=120)
        settle()
        seen = watch(timeout=120)
        s10.e, s10.seen = e, seen
        return e
    def s10check(a, b):
        final_note, final_title = "S10 start. Mac change made here, then more", "2D one (Mac)"
        bad_n = whole(s10.seen["notes"], final_note, "S10 start.")
        bad_t = whole(s10.seen["titles"], final_title, "")
        ok = not bad_n and not bad_t and note(b, f"{s10.e}-i1") == final_note and b["title"] == final_title
        return ok, f"B saw notes={s10.seen['notes']} titles={s10.seen['titles']}; partial: notes={bad_n or 'none'} titles={bad_t or 'none'}"
    scenario("S10 typing key by key on A: B never sees a partial word", s10,
             "B shows only whole edits (the start, whole words, the final)", [], s10check)

    # S11 — typing that never reached the library (the app is killed before the pause) comes back on the next launch.
    def s11():
        e = new_entry("S11 crash", "S11 body")
        cmd("A", "type", entry=e, item=f"{e}-i1", text="S11 body + typed, then the app was killed")
        cmd("A", "flush_drafts")
        sh("xcrun", "simctl", "terminate", SIMS["A"], BUNDLE)
        time.sleep(2)
        launch("A")
        cmd("A", "dump", timeout=180)
        settle()
        s11.e = e
        return e
    scenario("S11 a crash before the pause: the draft is recovered", s11,
             "the typed text is saved on the next launch and reaches B", ["S11 body + typed, then the app was killed"],
             lambda a, b: (note(a, f"{s11.e}-i1") == "S11 body + typed, then the app was killed",
                           f"A={note(a, f'{s11.e}-i1')!r} B={note(b, f'{s11.e}-i1')!r}"),
             deleted_ok=("S11 body",))

    # ---- batch B fix-up F3 (T's pass: a card kept the old note text after a Restore on the other device) ----
    # S12 — the other device's version lands while iCloud still reports the entry as downloading, and then becomes
    # current WITHOUT a watcher callback (as iCloud can). A (not open there) must still show it: every view reads the
    # store, so the store's copy is what the card shows (the cardrefresh.py stills prove the views follow the store).
    def s12():
        e = new_entry("S12 card refresh", "S12 old text")
        marker = os.path.join(H, "A", "library", "nodes", e, ".harness-not-current")
        open(marker, "w").close()
        cmd("B", "set_text", entry=e, item=f"{e}-i1", text="S12 new text from the other device")
        quiet(); time.sleep(15); quiet()           # B's follow-up background writes land too (still "downloading" on A)
        before = note(entry(cmd("A", "dump"), e), f"{e}-i1")
        os.remove(marker)                          # iCloud finishes: no callback, no file change
        t0 = time.time(); after = before
        while time.time() - t0 < 15 and after != "S12 new text from the other device":
            time.sleep(0.5); after = note(entry(cmd("A", "dump"), e), f"{e}-i1")
        s12.e, s12.before, s12.secs = e, before, round(time.time() - t0, 1)
        return e
    scenario("S12 a version that lands silently reaches the card", s12,
             "A's copy (what its card shows) updates within a few seconds of the file becoming current",
             ["S12 new text from the other device"],
             lambda a, b: (note(a, f"{s12.e}-i1") == "S12 new text from the other device",
                           f"while downloading A showed {s12.before!r}; current after {s12.secs}s → {note(a, f'{s12.e}-i1')!r}"),
             deleted_ok=("S12 old text",))
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
