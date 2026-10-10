#!/usr/bin/env python3
"""Brief CJ — run one gauntlet plan across N Simulators, then merge it back into ONE run dir for grading.

    shard.py split <run_dir> <n>   → <run_dir>/shard-solo (groups that must run ALONE, first) + shard-1..n
    shard.py merge <run_dir>       → turn/ui files renumbered into <run_dir>, logs concatenated

Groups that eject the model (A4 cold auto-load) run alone before the parallel phase: another shard's request
would load the model and the row would no longer be cold. Every other group is a separate app launch with no
state shared across launches, so groups are dealt round-robin, longest first (by turn count), keeping each
shard's groups in plan order. Merge renumbers `seq` (turn files and ui records) shard after shard; turns of one
launch stay contiguous, so the grader's previous-turn pairing (seq-1, same launchID) is unchanged.
"""
import glob, json, os, shutil, sys

def split(run_dir, n):
    cfg = json.load(open(os.path.join(run_dir, "config.json")))
    solo = [g for g in cfg["groups"] if g.get("eject")]
    rest = [g for g in cfg["groups"] if not g.get("eject")]
    order = {g["group"]: i for i, g in enumerate(rest)}
    bins = [[] for _ in range(n)]
    for g in sorted(rest, key=lambda g: -len(g["turns"])):
        min(bins, key=lambda b: sum(len(x["turns"]) for x in b)).append(g)
    shards = ([("shard-solo", solo)] if solo else []) + [(f"shard-{i + 1}", sorted(b, key=lambda g: order[g["group"]])) for i, b in enumerate(bins) if b]
    for name, groups in shards:
        d = os.path.join(run_dir, name)
        shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
        json.dump(dict(cfg, outDir=d, groups=groups), open(os.path.join(d, "config.json"), "w"), indent=2, ensure_ascii=False)
    print(" ".join(name for name, _ in shards))

def merge(run_dir):
    dirs = sorted(glob.glob(os.path.join(run_dir, "shard-*")), key=lambda p: (not p.endswith("-solo"), p))
    offset, logs = 0, []
    for d in dirs:
        turns = sorted(glob.glob(os.path.join(d, "turn-*.json")))
        for p in turns:
            t = json.load(open(p)); t["seq"] += offset
            json.dump(t, open(os.path.join(run_dir, "turn-%03d.json" % t["seq"]), "w"), indent=1, ensure_ascii=False)
        for p in glob.glob(os.path.join(d, "ui-*.json")):
            u = json.load(open(p)); u["seq"] = u.get("seq", 0) + offset; u["shard"] = os.path.basename(d)
            json.dump(u, open(os.path.join(run_dir, os.path.basename(p)), "w"), indent=2, sort_keys=True, ensure_ascii=False)
        for p in glob.glob(os.path.join(d, "hung-*")):
            shutil.copy(p, run_dir)
        if os.path.exists(os.path.join(d, "xcuitest.log")):
            logs.append(f"===== {os.path.basename(d)} =====\n" + open(os.path.join(d, "xcuitest.log"), errors="replace").read())
        offset += len(turns)
    open(os.path.join(run_dir, "xcuitest.log"), "w").write("\n".join(logs))
    print(f"merged {len(dirs)} shard dirs, {offset} turns")

if __name__ == "__main__":
    {"split": lambda: split(sys.argv[2], int(sys.argv[3])), "merge": lambda: merge(sys.argv[2])}[sys.argv[1]]()
