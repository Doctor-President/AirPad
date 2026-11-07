#!/usr/bin/env python3
"""Mac batch B2 — upgrade check: compare the library snapshots upgrade.sh took.

    compare_upgrade.py <out>     (before/, after-release/, after-edit/)

Per entry: the user's content (title, summary, tags, collections, created date, every item's id/type/text/file) must
be identical after the update, except the one edit made after it (which must be there, with the old build's edit).
Counts entries that now carry a revision stamp (`sync_revision`), and checks the library files kept their entries.
"""
import json, os, sys

OUT = sys.argv[1]
USER_KEYS = ["title", "summary", "tags", "collection_ids", "created_at", "is_journal_entry", "journal_date", "is_private"]
ITEM_KEYS = ["id", "type", "content", "file", "url", "transcript"]


def load(snap):
    root = os.path.join(OUT, snap)
    nodes = {}
    for d in os.listdir(os.path.join(root, "nodes")):
        p = os.path.join(root, "nodes", d, "node.json")
        if os.path.exists(p):
            n = json.load(open(p))
            nodes[n["id"]] = n
    agg = {}
    for f in ["tags.json", "collections.json", "chats.json", "field_definitions.json"]:
        p = os.path.join(root, f)
        if os.path.exists(p):
            v = json.load(open(p))
            agg[f] = len(v) if isinstance(v, list) else len(v.get("definitions", []))
    return nodes, agg


def user(n):
    return ({k: n.get(k) for k in USER_KEYS}, [{k: i.get(k) for k in ITEM_KEYS} for i in n.get("items", [])])


before, agg0 = load("before")
edited = open(os.path.join(OUT, "before", ".upgrade-edited")).read().strip()
ok = True
lines = []
for snap in ["after-release", "after-edit"]:
    after, agg = load(snap)
    missing = sorted(set(before) - set(after))
    changed = []
    for nid, n in before.items():
        if nid not in after:
            continue
        if user(n) != user(after[nid]) and not (snap == "after-edit" and nid == edited):
            changed.append(nid)
    stamped = sum(1 for n in after.values() if "sync_revision" in n)
    aggs_ok = all(agg.get(f, 0) >= c for f, c in agg0.items())
    good = not missing and not changed and aggs_ok
    ok &= good
    lines.append(f"{snap}: {len(after)}/{len(before)} entries · missing {len(missing)} · user content changed {len(changed)}"
                 f" · stamped {stamped} · library files {agg} (before {agg0}) · {'OK' if good else 'FAIL'}"
                 + (f" · changed: {changed[:5]}" if changed else ""))
    if snap == "after-edit":
        e = after.get(edited, {})
        texts = [i.get("content") or "" for i in e.get("items", [])]
        has_old = any("Edited on the old build before the update ✓" in t for t in texts)
        has_new = any("Edited on 1.0.2 after the update ✓" in t for t in texts)
        st = e.get("sync_revision", {})
        good = has_old and has_new and bool(st)
        ok &= good
        lines.append(f"the edited entry: old-build edit kept={has_old} · 1.0.2 edit saved={has_new} · stamped={bool(st)}"
                     f" (device {st.get('d', '-')}, {len(st.get('fp', {}))} field prints, {len(st.get('ifp', {}))} item prints) · {'OK' if good else 'FAIL'}")
print("\n".join(lines))
print("UPGRADE", "PASS" if ok else "FAIL")
open(os.path.join(OUT, "upgrade.txt"), "w").write("\n".join(lines) + "\nUPGRADE " + ("PASS" if ok else "FAIL") + "\n")
