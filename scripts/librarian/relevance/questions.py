#!/usr/bin/env python3
"""Sweep 2b · 3.2 — the questions: cases (+ 3.1's wordings when present) → turns with labels, the E / P split, and the
`-EmbedDump` input.

  questions.py emit --out <path> [--fifo] [--libs bench,sample,fixture]   write the embed input (a FIFO for private text)
  questions.py summary [--libs ...]                                        counts per library (IDs and numbers only)

Each question carries: case ID, wording index, library, type, mode, the supporting node IDs, facts, whether it is a
follow-up (recorded `retrievalAugmented` or `rules.followUp`: its search text depends on stage 1, so its own row),
and the texts to embed: the question, the question with its names removed (S6e), the augmented text (follow-ups).

Fixture questions (cases-fixture-gk.json, CC-written, and the gauntlet cases that name an entry) are held as Private:
they reach the app only through a named pipe and are never written as text.
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (BENCHMARK, OUT, REPO, Private, names_and_predicate, say, strip_names, tokens_a,
                    refuse_forbidden_ports)

RETR = {"bench": REPO / "build/sweep2a/retr-bench/results.json",
        "sample": REPO / "build/sweep2a/retr-sample/results.json",
        "fixture": REPO / "build/sweep2a/retr-fixture-gk/results.json"}
CASES = {"bench": BENCHMARK / "cases-bench.json", "sample": BENCHMARK / "cases-sample.json",
         "fixture": BENCHMARK / "cases-fixture-gk.json"}
GAUNTLET = REPO / "scripts/gauntlet/cases.json"
NO_EVIDENCE = {"gk-irrelevant", "gk-irrelevant-overlap", "no-match", "no-match-named", "news-library"}
FRANCE_IDS = {"bench": ["G1"], "sample": ["SP-FR"], "fixture": ["TG1"]}
# The Sample France probe (design §1): the same question as bench G1 / fixture TG1, added to the Sample set.
SAMPLE_PROBE = {"id": "SP-FR", "type": "gk-irrelevant", "question": "What is the capital of France?", "facts": [["paris"]],
                "supports": []}


def wordings_path(lib):
    """3.1's wordings, if that file exists tonight: {turnID: [wording, ...]} (or {"turns": {...}})."""
    d = Path(os.environ.get("RELEVANCE_WORDINGS_DIR", BENCHMARK))
    for name in (f"wordings-{lib}.json", f"cases-{lib}-wordings.json"):
        if (d / name).is_file():
            return d / name
    return None


def load_wordings(lib):
    p = wordings_path(lib)
    if not p:
        return {}
    d = json.loads(p.read_text(encoding="utf-8"))
    d = d.get("turns", d)
    return {k: [w for w in v if isinstance(w, str) and w.strip()] for k, v in d.items() if isinstance(v, list)}


def load_recorded(lib, results=None):
    p = Path(results) if results else RETR[lib]
    if not p.is_file():
        return None, {}
    r = json.loads(p.read_text(encoding="utf-8"))
    return r, {row["id"]: row for row in r.get("rows", [])}


def build(lib_name, lib, key_map, results=None, wordings=True, gauntlet_entries=True):
    """The questions for one library. `lib` is the loaded Library (fixture: in memory, Private)."""
    private = lib.private
    wrap = Private if private else str
    doc = json.loads(CASES[lib_name].read_text(encoding="utf-8"))
    _, rows = load_recorded(lib_name, results)
    words = load_wordings(lib_name) if wordings else {}
    turns = []
    for chat in doc["chats"]:
        prev = None
        for i, t in enumerate(chat["turns"]):
            turns.append((chat["id"], i, t, prev))
            prev = t["question"]
    if lib_name == "sample":
        turns.append(("probe", 0, SAMPLE_PROBE, None))
    unresolved = []
    if lib_name == "fixture" and gauntlet_entries and GAUNTLET.is_file():
        # Gauntlet cases that name an entry (`entry`): the label is that entry, resolved here in memory by title (or
        # an ID prefix). The `entry` field may be a placeholder; an unresolved case is counted by ID and left out.
        g = json.loads(GAUNTLET.read_text(encoding="utf-8"))
        by_title = {}
        for nid, title in lib.titles.items():
            by_title.setdefault(str(title).strip().lower(), nid)
        for chat in g.get("chats", []):
            for c in chat.get("cases", []):
                if not c.get("entry"):
                    continue
                e = str(c["entry"]).strip()
                nid = by_title.get(e.lower()) or next((n for n in lib.node_ids if n.upper().startswith(e.upper())
                                                       and len(e) >= 8), None)
                if not nid:
                    unresolved.append(c["id"])
                    continue
                turns.append(("gauntlet", 0, {"id": c["id"], "type": "gauntlet-named", "question": c["question"],
                                              "supports": [nid], "facts": [], "_ids": True}, None))
    out = []
    for chat_id, idx, t, prev in turns:
        row = rows.get(t["id"], {})
        rec = row.get("record") or {}
        mode = t.get("mode", "library")
        sup = t.get("supports") or []
        sup_ids = sup if t.get("_ids") else [key_map[k] for k in sup if k in key_map]
        missing = [k for k in sup if not t.get("_ids") and k not in key_map]
        augmented = bool(rec.get("retrievalAugmented"))
        followup = augmented or bool((rec.get("rules") or {}).get("followUp"))
        has_record = bool(rec) and rec.get("passages") is not None
        texts = [t["question"]] + (words.get(t["id"], []) if wordings else [])
        for w, text in enumerate(texts):
            q = wrap(text)
            E, P, _ = names_and_predicate(text, tokens_a)
            out.append({
                "qid": f"{lib_name}|{t['id']}|{w}", "case": t["id"], "chat": chat_id, "wording": w, "lib": lib_name,
                "type": t.get("type", ""), "mode": mode, "supports": sup_ids, "supports_missing": missing,
                "evidence": bool(sup_ids) and t.get("type") not in NO_EVIDENCE,
                "no_evidence": t.get("type") in NO_EVIDENCE or (not sup and mode == "library"),
                "facts": [[wrap(s) for s in alts] for alts in t.get("facts", [])],
                "followup": followup, "augmented": augmented, "recorded": has_record and w == 0,
                "text": q, "text_noE": wrap(strip_names(text)) if E else None,
                "text_aug": wrap(f"{text}\n{prev}") if (augmented and prev) else None,
                "has_names": bool(E), "france": t["id"] in FRANCE_IDS.get(lib_name, []),
                "private": private,
            })
    return out, {"unresolved_gauntlet": unresolved, "wordings_file": str(wordings_path(lib_name) or "")}


def embed_lines(questions):
    """(id, text) for the -EmbedDump input: every question, its name-stripped form, its augmented form."""
    for q in questions:
        yield q["qid"] + "|q", q["text"]
        if q["text_noE"]:
            yield q["qid"] + "|noE", q["text_noE"]
        if q["text_aug"]:
            yield q["qid"] + "|aug", q["text_aug"]


def write_embed_input(path, lines, fifo=False):
    """Writes JSON lines. With fifo=True the path must be a named pipe (blocks until the app opens it)."""
    path = Path(path)
    if fifo:
        if not path.exists():
            os.mkfifo(path)
        if not stat.S_ISFIFO(path.stat().st_mode):
            raise SystemExit(f"{path} is not a named pipe")
    else:
        if any(isinstance(t, Private) for _, t in lines):
            raise SystemExit("refusing: private questions go through --fifo only")
    n = 0
    with open(path, "w", encoding="utf-8") as f:
        for i, t in lines:
            f.write(json.dumps({"id": i, "text": str(t)}, ensure_ascii=False) + "\n")
            n += 1
    return n


def load_vectors(path):
    import numpy as np
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                r = json.loads(line)
                v = np.asarray(r["vec"], dtype=np.float32)
                n = float(np.linalg.norm(v))
                if not v.size or n == 0:
                    continue   # an empty or zero vector: the question reads as "no vector", never as zeros
                out[r["id"]] = v / n if n > 0 else v
    return out


def main():
    refuse_forbidden_ports()
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["emit", "summary"])
    ap.add_argument("--out")
    ap.add_argument("--fifo", action="store_true")
    ap.add_argument("--libs", default="bench,sample,fixture")
    ap.add_argument("--bench-nodes")
    ap.add_argument("--bench-root")
    ap.add_argument("--sample-nodes")
    ap.add_argument("--fixture-nodes")
    ap.add_argument("--no-wordings", action="store_true")
    a = ap.parse_args()
    import export
    lines, counts = [], {}
    for name in a.libs.split(","):
        lib, keymap = export.open_library(name, a)
        qs, info = build(name, lib, keymap, wordings=not a.no_wordings)
        counts[name] = {"questions": len(qs), "cases": len({q["case"] for q in qs}),
                        "evidence": sum(q["evidence"] and q["mode"] == "library" and not q["followup"] for q in qs),
                        "no_evidence": sum(q["no_evidence"] and q["mode"] == "library" and not q["followup"] for q in qs),
                        "followup": sum(q["followup"] for q in qs), "general": sum(q["mode"] != "library" for q in qs),
                        "unresolved_gauntlet": info["unresolved_gauntlet"],
                        "wordings": "3.1 wordings" if info["wordings_file"] else "original wordings only",
                        "supports_missing": sorted({k for q in qs for k in q["supports_missing"]})[:20]}
        lines += list(embed_lines(qs))
    if a.cmd == "summary":
        say(json.dumps(counts, indent=1))
        return
    n = write_embed_input(a.out, lines, fifo=a.fifo)
    say(f"embed input: {n} lines → {'named pipe' if a.fifo else a.out}")


if __name__ == "__main__":
    main()
