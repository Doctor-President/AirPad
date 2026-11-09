#!/usr/bin/env python3
"""Mac batch B1e — a stand-in for iCloud between two replicas of one library (scratch only).

    fakecloud.py <H> A B      # runs until killed; H/<R>/library are the replicas, H/cloud the "server"

Each replica is online unless H/<R>/offline exists. Per replica it remembers each file's hash at the last sync, so it
knows who changed what:
- changed only on the replica → upload; changed only in the cloud → download (deletions too);
- changed on both → the cloud's version stays current and the replica's is kept as a CONFLICT version, as iCloud
  does: for an entry `nodes/<id>/.conflicts/<R>-<t>.json`, for a library file `.conflicts/<name>/<R>-<t>.json`
  (the app's DEBUG stand-in for NSFileVersion). A local delete vs a cloud edit → the edit comes back; a local edit vs
  a cloud delete → the edit is uploaded again. (Apple doesn't document iCloud's choice for edit-vs-delete; this is
  the no-loss reading. T's real two-device pass covers it.)
Writes are atomic (temp + rename). It logs every action to H/fakecloud.log and the number of actions per pass to
H/fakecloud.status, so the runner can wait until things are quiet.

What it can't reproduce: iCloud's timing, placeholders it decides to evict, its coordination with the app (the app
learns of changes here by its DEBUG poll, not by NSFilePresenter), and its real conflict rules.
"""
import hashlib, json, os, shutil, sys, time

H = sys.argv[1]
REPLICAS = sys.argv[2:]
CLOUD = os.path.join(H, "cloud")
os.makedirs(CLOUD, exist_ok=True)
LOG = open(os.path.join(H, "fakecloud.log"), "a", buffering=1)
state = {}
for r in REPLICAS:
    p = os.path.join(H, f"state-{r}.json")
    state[r] = json.load(open(p)) if os.path.exists(p) else {}


def log(msg):
    LOG.write(f"{time.strftime('%H:%M:%S')} {msg}\n")


def files(root):
    out = set()
    for d, dirs, fs in os.walk(root):
        for f in fs:
            if f.startswith(".fc-tmp") or f == ".DS_Store" or f.endswith(".tmp") or ".sb-" in f or f == ".harness-not-current":   # + Foundation's atomic-write temps; the not-current marker is per replica
                continue
            out.add(os.path.relpath(os.path.join(d, f), root))
    return out


def h(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except (FileNotFoundError, IsADirectoryError):
        return None


def put(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = os.path.join(os.path.dirname(dst), f".fc-tmp-{os.getpid()}-{time.time_ns()}")
    try:
        shutil.copyfile(src, tmp)
    except FileNotFoundError:   # the app replaced or removed it mid-pass: the next pass sees the new state
        return
    os.replace(tmp, dst)


def rm(path, root):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    d = os.path.dirname(path)
    while d.startswith(root) and d != root:
        try:
            os.rmdir(d)          # only if empty
        except OSError:
            break
        d = os.path.dirname(d)


def conflict_path(p, r):
    t = time.time_ns()
    parts = p.split(os.sep)
    if len(parts) >= 3 and parts[0] == "nodes" and parts[-1] == "node.json":
        return os.path.join("nodes", parts[1], ".conflicts", f"{r}-{t}.json")
    if len(parts) == 1 and p.endswith(".json"):
        return os.path.join(".conflicts", p, f"{r}-{t}.json")
    return None


def sync(r):
    lib = os.path.join(H, r, "library")
    os.makedirs(lib, exist_ok=True)
    last = state[r]
    actions = 0
    for p in sorted(files(lib) | files(CLOUD) | set(last)):
        rp, cp = os.path.join(lib, p), os.path.join(CLOUD, p)
        a, c, l = h(rp), h(cp), last.get(p)
        if a == c:
            if a is None: last.pop(p, None)
            else: last[p] = a
            continue
        ra, cc = a != l, c != l
        if ra and not cc:
            if a is None: rm(cp, CLOUD); log(f"{r} ↑ delete {p}")
            else: put(rp, cp); log(f"{r} ↑ {p}")
            last[p] = a
        elif cc and not ra:
            if c is None: rm(rp, lib); log(f"{r} ↓ delete {p}")
            else: put(cp, rp); log(f"{r} ↓ {p}")
            last[p] = c
        else:
            if a is None:            # deleted here, edited in the cloud → the edit comes back
                put(cp, rp); last[p] = c; log(f"{r} ↓ {p} (cloud edit beats local delete)")
            elif c is None:          # edited here, deleted in the cloud → uploaded again
                put(rp, cp); last[p] = a; log(f"{r} ↑ {p} (local edit beats cloud delete)")
            else:
                cpath = conflict_path(p, r)
                if cpath:
                    put(rp, os.path.join(CLOUD, cpath)); log(f"{r} CONFLICT {p} → cloud keeps its version, {r}'s kept as {cpath}")
                else:
                    log(f"{r} CONFLICT {p} → cloud keeps its version (no conflict copy for this kind of file)")
                put(cp, rp); last[p] = c
        actions += 1
    json.dump(last, open(os.path.join(H, f"state-{r}.json"), "w"))
    return actions


while True:
    n = 0
    for r in REPLICAS:
        if not os.path.exists(os.path.join(H, r, "offline")):
            n += sync(r)
    with open(os.path.join(H, "fakecloud.status"), "w") as f:
        f.write(f"{time.time()} {n}\n")
    time.sleep(0.3)
