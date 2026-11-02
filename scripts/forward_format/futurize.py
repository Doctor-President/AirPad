#!/usr/bin/env python3
"""1.0r S0a — turn a library folder into a "future" library: every known version field → 99, plus an unknown
field on every object we can reach (top level, array elements, node items). Prints what it changed.
Usage: futurize.py <library-root>"""
import json, os, sys

VERSION_KEYS = {"entry_schema_version", "version", "schemaVersion", "schema_version", "formatVersion",
                "card_text_version", "embedding_version", "embedder_version", "embedderVersion"}
FUT = 99

def mark(obj, tag):
    if isinstance(obj, dict):
        bumped = [k for k in obj if k in VERSION_KEYS and isinstance(obj[k], int)]
        for k in bumped: obj[k] = FUT
        obj["zz_future_field"] = tag
        return bumped
    return []

def futurize(path, rel):
    with open(path) as f: data = json.load(f)
    bumped, marked = [], 0
    if isinstance(data, dict):
        bumped += mark(data, rel); marked += 1
        for key in ("items", "definitions", "positions"):
            v = data.get(key)
            if isinstance(v, list):
                for el in v:
                    if isinstance(el, dict): bumped += mark(el, f"{rel}:{key}[]"); marked += 1
        if rel.endswith("territory_layout.json"):
            for k, v in data.items():
                if isinstance(v, dict): bumped += mark(v, f"{rel}:{k}"); marked += 1
    elif isinstance(data, list):
        for el in data:
            if isinstance(el, dict): bumped += mark(el, f"{rel}[]"); marked += 1
    with open(path, "w") as f: json.dump(data, f, indent=1, sort_keys=True)
    return sorted(set(bumped)), marked

root = sys.argv[1]
for dirpath, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d != "items"]
    for name in sorted(files):
        if not name.endswith(".json"): continue
        p = os.path.join(dirpath, name); rel = os.path.relpath(p, root)
        try: bumped, marked = futurize(p, rel)
        except Exception as e: print(f"SKIP {rel}: {e}"); continue
        if not rel.startswith("nodes/") or rel.count("/") == 2:
            print(f"FUT {rel}: versions→99 {bumped or '-'}; unknown field on {marked} object(s)")
