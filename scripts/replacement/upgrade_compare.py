#!/usr/bin/env python3
"""Compare a library before (old build) and after (new build installed over it).
Usage: upgrade_compare.py <lib-old> <lib-new> <staged-entry-id>"""
import json, os, sys, glob
old, new, staged = sys.argv[1], sys.argv[2], sys.argv[3]
def nodes(root):
    out = {}
    for p in glob.glob(os.path.join(root, "nodes", "*", "node.json")):
        n = json.load(open(p)); out[n["id"]] = n
    return out
o, n = nodes(old), nodes(new)
lost = sorted(set(o) - set(n)); added = sorted(set(n) - set(o))
changed_user = []; ver = {}
for i in sorted(set(o) & set(n)):
    a, b = o[i], n[i]
    ver[(a.get("entry_schema_version"), b.get("entry_schema_version"))] = ver.get((a.get("entry_schema_version"), b.get("entry_schema_version")), 0) + 1
    for k in ("title", "summary", "tags", "created_at"):
        if a.get(k) != b.get(k): changed_user.append((i[:8], k))
    ia = {x["id"]: x.get("content") for x in a.get("items", [])}; ib = {x["id"]: x.get("content") for x in b.get("items", [])}
    if ia != ib: changed_user.append((i[:8], "items"))
files_old = {os.path.relpath(p, old) for p in glob.glob(os.path.join(old, "*.json"))}
files_new = {os.path.relpath(p, new) for p in glob.glob(os.path.join(new, "*.json"))}
print("| check | result |\n|---|---|")
print(f"| entries old → new | {len(o)} → {len(n)} |")
print(f"| entries lost | {len(lost)} {lost[:3]} |")
print(f"| entries added | {len(added)} {added[:3]} |")
print(f"| staged user entry present after update | {'yes' if staged in n else 'NO'}; text kept: {'yes' if staged in n and any('UPGRADEPROBE' in (x.get('content') or '') for x in n[staged].get('items', [])) else 'NO'} |")
print(f"| user fields changed (title/summary/tags/created_at/item text) | {len(changed_user)} {changed_user[:5]} |")
print(f"| entry_schema_version old→new (count) | {', '.join(f'{a}→{b}: {c}' for (a, b), c in sorted(ver.items(), key=str))} |")
print(f"| top-level library files old / new | {sorted(files_old)} / only-new: {sorted(files_new - files_old)} / gone: {sorted(files_old - files_new)} |")
for f in ("corpus_index.json", "field_definitions.json", "territory_layout.json", "canvas_layout.json"):
    for tag, root in (("old", old), ("new", new)):
        p = os.path.join(root, f)
        if os.path.exists(p):
            try: v = json.load(open(p)).get("version")
            except Exception: v = "?"
            print(f"| {f} version ({tag}) | {v} |")
