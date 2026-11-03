#!/usr/bin/env python3
"""1.0r S0a — compare a futurized library snapshot (before) with the same folder after this build ran.
Per file: written or not; each version field before → after; unknown fields kept / dropped; probe text.
Usage: diff.py <before-root> <after-root>"""
import json, os, sys, hashlib

VERSION_KEYS = {"entry_schema_version", "version", "schemaVersion", "schema_version", "formatVersion",
                "card_text_version", "embedding_version", "embedder_version", "embedderVersion"}

def walk(root):
    out = {}
    for dp, ds, fs in os.walk(root):
        ds[:] = [d for d in ds if d != "items"]
        for n in fs:
            if n.endswith(".json"): out[os.path.relpath(os.path.join(dp, n), root)] = os.path.join(dp, n)
    return out

def versions(o, acc, path=""):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in VERSION_KEYS and isinstance(v, int): acc.setdefault(k, set()).add(v)
            versions(v, acc, path + "/" + k)
    elif isinstance(o, list):
        for v in o: versions(v, acc, path)
    return acc

def load(p):
    with open(p, "rb") as f: raw = f.read()
    try: return raw, json.loads(raw)
    except Exception: return raw, None

b, a = walk(sys.argv[1]), walk(sys.argv[2])
rows = []
for rel in sorted(set(b) | set(a)):
    if rel not in a: rows.append((rel, "DELETED", "", "", "")); continue
    if rel not in b: rows.append((rel, "NEW", "", "", "")); continue
    rb, jb = load(b[rel]); ra, ja = load(a[rel])
    if jb == ja:
        continue  # untouched (or rewritten identically)
    vb, va = versions(jb, {}), versions(ja, {})
    vtxt = "; ".join(f"{k} {sorted(vb.get(k, []))}→{sorted(va.get(k, []))}" for k in sorted(set(vb) | set(va))) or "-"
    ub, ua = rb.count(b"zz_future_field"), ra.count(b"zz_future_field")
    probe = "yes" if b"FWDPROBE" in ra else ""
    rows.append((rel, "REWRITTEN", vtxt, f"{ub}→{ua}", probe))
print("| file | what happened | version fields before→after | unknown fields before→after | edit text |")
print("|---|---|---|---|---|")
for r in rows: print("| " + " | ".join(r) + " |")
print(f"\n{len(rows)} changed of {len(set(b)|set(a))} json files")
