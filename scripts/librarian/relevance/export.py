#!/usr/bin/env python3
"""Sweep 2b · 3.2 — the libraries: `nodes/<id>/blocks.json` + titles → vectors and an ID table.

  export.py copy-sim --udid <U>         copy the bench scratch library (and the Sample scratch) out of CC's Simulator
                                        (read only; never the fixture clone, which is read in place)
  export.py dump --lib bench|sample     write vectors (.npy) + an ID table (bench / Sample only, never the fixture)
  export.py summary --libs ...          counts (IDs and numbers only)

The fixture is read IN MEMORY only, and only with `--allow-fixture` (or RELEVANCE_ALLOW_FIXTURE=1, set by
run_night.sh): its text, titles and vectors are never written. Library sources:
  bench   OUT/lib-bench/nodes (copied by copy-sim), labels from the scratch's bench-notes.json
  sample  AirPad/Resources/SampleLibrary/nodes (the repo), or --sample-nodes
  fixture ~/Developer/fixtures/tom-corpus-2026-09-21/nodes, or --fixture-nodes
"""
from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (FIXTURE_DEFAULT, OUT, SAMPLE_NODES, bench_key_map, dump_json, load_library, refuse_forbidden_ports,
                    sample_key_map, say)

BUNDLE = "com.doctorpresident.airpad"


def app_data_container(udid):
    """The app's data container on a Simulator, from the container manager's metadata (no simctl, no boot)."""
    base = Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data/Containers/Data/Application"
    best = None
    for d in base.glob("*"):
        meta = d / ".com.apple.mobile_container_manager.metadata.plist"
        try:
            if plistlib.loads(meta.read_bytes()).get("MCMMetadataIdentifier") == BUNDLE:
                if best is None or d.stat().st_mtime > best.stat().st_mtime:
                    best = d
        except Exception:
            continue
    return best


def copy_sim(udid, out=OUT):
    c = app_data_container(udid)
    if not c:
        raise SystemExit(f"no {BUNDLE} container on Simulator {udid}")
    caches = c / "Library/Caches"
    done = {}
    for scratch, dest in (("AirPadUITestScratch", "lib-bench"), ("AirPadSampleDemoScratch", "lib-sample-scratch")):
        src = caches / scratch
        if not (src / "nodes").is_dir():
            done[dest] = 0
            continue
        d = out / dest
        if d.exists():
            shutil.rmtree(d)
        shutil.copytree(src / "nodes", d / "nodes")
        for f in ("bench-notes.json",):
            if (src / f).is_file():
                shutil.copy2(src / f, d / f)
        done[dest] = sum(1 for _ in (d / "nodes").iterdir())
    say(f"copied from the Simulator's app container: {done}")
    return done


def fixture_allowed(a=None):
    return bool(getattr(a, "allow_fixture", False)) or os.environ.get("RELEVANCE_ALLOW_FIXTURE") == "1"


def open_library(name, a=None):
    """(Library, supports-key → node ID map) for bench | sample | fixture."""
    g = (lambda k, d=None: getattr(a, k, None) or d)
    if name == "bench":
        nodes = Path(g("bench_nodes", OUT / "lib-bench" / "nodes"))
        lib = load_library(nodes, "bench")
        return lib, bench_key_map(lib, g("bench_root", nodes.parent))
    if name == "sample":
        lib = load_library(Path(g("sample_nodes", SAMPLE_NODES)), "sample")
        return lib, sample_key_map(lib)
    if name == "fixture":
        if not fixture_allowed(a):
            raise SystemExit("the fixture is read only with --allow-fixture (run_night.sh sets it)")
        lib = load_library(Path(g("fixture_nodes", FIXTURE_DEFAULT / "nodes")), "fixture", private=True)
        return lib, {}
    raise SystemExit(f"unknown library {name}")


def summary(lib):
    return {"entries": len(lib.node_ids), "passages": lib.n, "with_passages": len(set(lib.p_node)),
            "with_card_vector": len(lib.card_vecs), "private_left_out": getattr(lib, "skipped_private", 0),
            "zero_vectors": int((np.linalg.norm(lib.vecs, axis=1) == 0).sum()) if lib.n else 0}


def main():
    refuse_forbidden_ports()
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["copy-sim", "dump", "summary"])
    ap.add_argument("--udid")
    ap.add_argument("--lib")
    ap.add_argument("--libs", default="bench,sample")
    ap.add_argument("--out", default=str(OUT))
    ap.add_argument("--bench-nodes"); ap.add_argument("--bench-root"); ap.add_argument("--sample-nodes")
    ap.add_argument("--fixture-nodes"); ap.add_argument("--allow-fixture", action="store_true")
    a = ap.parse_args()
    if a.cmd == "copy-sim":
        copy_sim(a.udid, Path(a.out))
    elif a.cmd == "summary":
        res = {n: summary(open_library(n, a)[0]) for n in a.libs.split(",")}
        say(res)
    else:
        if a.lib == "fixture":
            raise SystemExit("refusing: the fixture is never written (read in memory only)")
        lib, keymap = open_library(a.lib, a)
        d = Path(a.out) / f"export-{a.lib}"
        d.mkdir(parents=True, exist_ok=True)
        np.save(d / "vectors.npy", lib.vecs)
        dump_json({"library": a.lib, "source": lib.source, "passages": [
            {"i": i, "node": lib.p_node[i], "block": lib.p_block[i], "text": lib.p_text[i]} for i in range(lib.n)],
            "titles": lib.titles, "keys": keymap, "summary": summary(lib)}, d / "ids.json")
        say(f"{a.lib}: {summary(lib)} → {d}")


if __name__ == "__main__":
    main()
