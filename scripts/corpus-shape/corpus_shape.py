#!/usr/bin/env python3
"""
Corpus SHAPE metadata — Brief M. NUMBERS AND DISTRIBUTIONS ONLY.

PRIVACY CONTRACT (do not weaken): this script prints aggregate counts only. It
never prints a title, tag name, collection name, body text, URL, or any node
content. Collections are reported anonymised as A, B, C… ordered by node count;
T maps the letters himself. Read-only: opens files, never writes to the corpus.

On-disk schema (from AirPad source, verified 2026-09-17):
  <root>/nodes/<id>/node.json   — the node (JSON, ISO8601 dates, snake_case keys)
  <root>/nodes/<id>/card.json   — derived catalog card sidecar (presence only)
  <root>/collections.json       — [{id, name}]  (user + system collections)
  <root>/tags.json              — [Tag]  (name, is_canvas_anchor, …)
Node keys used: id, title, summary, tags[], is_meta, collection_ids[],
                items[] (each: type, content?), created_at, journal_date?
"""
import sys, os, json
from datetime import datetime, timezone
from statistics import median

ATOMIC_TYPES = {"rating", "field"}          # attributes, not "captures"
SYSTEM_COLLECTION_IDS = {"_corpus", "_journal", "_librarian_sessions"}


def parse_dt(s):
    if not isinstance(s, str):
        return None
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def bucket(n, edges, labels):
    for e, lab in zip(edges, labels):
        if n <= e:
            return lab
    return labels[-1]


def pct(part, whole):
    return f"{(100.0 * part / whole):.1f}%" if whole else "n/a"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents")
    nodes_dir = os.path.join(root, "nodes")

    out = []
    def p(s=""):
        out.append(s)

    p("===== AirPad CORPUS SHAPE — numbers only (Brief M) =====")
    p(f"root exists: {os.path.isdir(root)}   nodes/ exists: {os.path.isdir(nodes_dir)}")
    if not os.path.isdir(nodes_dir):
        p("nodes/ directory not found — nothing to count.")
        print("\n".join(out)); return

    # ---- side files: collections + tags ----
    def load_json(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f), None
        except FileNotFoundError:
            return None, "absent"
        except Exception as e:
            return None, type(e).__name__

    collections, coll_err = load_json(os.path.join(root, "collections.json"))
    tags_vocab, tags_err = load_json(os.path.join(root, "tags.json"))

    # anchor tag NAMES (used internally only; never printed)
    anchor_names = set()
    vocab_count = 0
    if isinstance(tags_vocab, list):
        vocab_count = len(tags_vocab)
        for t in tags_vocab:
            # Tag has no explicit CodingKeys → JSON uses synthesized camelCase
            # property names ("isCanvasAnchor"). Accept snake_case too, defensively.
            if isinstance(t, dict) and (t.get("isCanvasAnchor") or t.get("is_canvas_anchor")):
                anchor_names.add(t.get("name"))

    # collection id -> node-count accumulator; also keep which ids are system
    coll_ids = []
    coll_is_system = {}
    if isinstance(collections, list):
        for c in collections:
            if isinstance(c, dict) and "id" in c:
                cid = c["id"]
                coll_ids.append(cid)
                coll_is_system[cid] = (cid in SYSTEM_COLLECTION_IDS or str(cid).startswith("_"))

    # ---- walk nodes ----
    total_dirs = 0
    unreadable = 0
    not_downloaded = 0
    nodes = []            # parsed node dicts we could read
    have_card = 0

    with os.scandir(nodes_dir) as it:
        for entry in it:
            if not entry.is_dir():
                continue
            total_dirs += 1
            njson = os.path.join(entry.path, "node.json")
            if not os.path.exists(njson):
                # iCloud dataless placeholder?
                if os.path.exists(os.path.join(entry.path, ".node.json.icloud")):
                    not_downloaded += 1
                else:
                    unreadable += 1
                continue
            try:
                with open(njson, "r", encoding="utf-8") as f:
                    nd = json.load(f)
            except Exception:
                unreadable += 1
                continue
            nodes.append(nd)
            if os.path.exists(os.path.join(entry.path, "card.json")):
                have_card += 1

    total = len(nodes)

    # ---- OVERALL ----
    meta = sum(1 for n in nodes if n.get("is_meta") is True)
    non_meta = total - meta
    p("")
    p("## OVERALL")
    p(f"node dirs scanned: {total_dirs}   readable node.json: {total}   "
      f"unreadable: {unreadable}   icloud-not-downloaded: {not_downloaded}")
    p(f"meta nodes: {meta}   non-meta (rankable): {non_meta}")
    p(f"nodes with a card.json sidecar: {have_card}  ({pct(have_card, total)})")

    # ---- per-node derived ----
    def node_tags(n):
        t = n.get("tags")
        return t if isinstance(t, list) else []

    def node_collections(n):
        c = n.get("collection_ids")
        return c if isinstance(c, list) else []

    def node_items(n):
        it = n.get("items")
        return it if isinstance(it, list) else []

    def has_anchor(n):
        return any(tag in anchor_names for tag in node_tags(n))

    # ---- COLLECTION SHAPE ----
    p("")
    p("## COLLECTION SHAPE (anonymised A,B,C… by node count; names never printed)")
    if coll_err:
        p(f"collections.json: {coll_err} — cannot report collection shape.")
    else:
        membership = {cid: [] for cid in coll_ids}
        dangling = 0
        for n in nodes:
            for cid in node_collections(n):
                if cid in membership:
                    membership[cid].append(n)
                else:
                    dangling += 1
        user_ids = [cid for cid in coll_ids if not coll_is_system[cid]]
        sys_ids = [cid for cid in coll_ids if coll_is_system[cid]]
        # order user collections by node count desc
        user_sorted = sorted(user_ids, key=lambda c: len(membership[c]), reverse=True)
        p(f"total collections in file: {len(coll_ids)}  "
          f"(user: {len(user_ids)}, system: {len(sys_ids)})")
        p(f"dangling collection_ids on nodes (id not in file): {dangling}")
        p("letter | node_count | anchor-tag fraction")
        letters = []
        counts = []
        for i, cid in enumerate(user_sorted):
            lab = chr(ord('A') + i) if i < 26 else f"A{i}"
            members = membership[cid]
            cnt = len(members)
            counts.append(cnt)
            anch = sum(1 for m in members if has_anchor(m))
            p(f"  {lab:<4} | {cnt:<10} | {anch}/{cnt} ({pct(anch, cnt)})")
        if counts:
            p(f"user-collection node counts — median: {median(counts):.1f}   max: {max(counts)}   "
              f"collections with <5 nodes: {sum(1 for c in counts if c < 5)}")
        # system collections: report by count only (system names are app constants, still not printed)
        for cid in sys_ids:
            p(f"  [system collection] node_count: {len(membership[cid])}")

    # ---- FILED vs UNFILED ----
    p("")
    p("## FILED vs UNFILED")
    unfiled = [n for n in nodes if len(node_collections(n)) == 0]
    filed = total - len(unfiled)
    unfiled_with_tag = sum(1 for n in unfiled if len(node_tags(n)) > 0)
    unfiled_with_journal = sum(1 for n in unfiled if n.get("journal_date"))
    neither = sum(1 for n in unfiled if len(node_tags(n)) == 0 and len(node_collections(n)) == 0)
    neither_strict = sum(1 for n in unfiled
                         if len(node_tags(n)) == 0 and not n.get("journal_date"))
    p(f"in ≥1 user collection (collection_ids non-empty): {filed}")
    p(f"in NO collection (collection_ids empty): {len(unfiled)}")
    p(f"  …of those, with ≥1 tag: {unfiled_with_tag}")
    p(f"  …of those, with a journal_date (journal-filed): {unfiled_with_journal}")
    p(f"  …with NEITHER collection nor tag (placed on meaning alone): {neither}")
    p(f"  …with NEITHER collection, tag, NOR journal_date (strict): {neither_strict}")

    # ---- ITEM ACCRETION ----
    p("")
    p("## ITEM ACCRETION (items per node)")
    def dist_items(counts, label):
        b = {"0": 0, "1": 0, "2": 0, "3-5": 0, "6+": 0}
        for c in counts:
            if c == 0: b["0"] += 1
            elif c == 1: b["1"] += 1
            elif c == 2: b["2"] += 1
            elif c <= 5: b["3-5"] += 1
            else: b["6+"] += 1
        p(f"{label}: " + "  ".join(f"{k}={v}" for k, v in b.items())
          + f"   max={max(counts) if counts else 0}")
    all_counts = [len(node_items(n)) for n in nodes]
    payload_counts = [sum(1 for it in node_items(n)
                          if isinstance(it, dict) and it.get("type") not in ATOMIC_TYPES)
                      for n in nodes]
    dist_items(all_counts, "all items (incl. atomic rating/field)")
    dist_items(payload_counts, "payload items only (excl. atomic)  ← 'captures' accretion")

    # ---- TITLE LENGTH ----
    p("")
    p("## TITLE LENGTH (character counts)")
    tbuckets = {"0-20": 0, "21-40": 0, "41-60": 0, "61-80": 0, "81+": 0}
    empty_title = 0
    for n in nodes:
        t = n.get("title") or ""
        L = len(t)
        if L == 0: empty_title += 1
        tbuckets[bucket(L, [20, 40, 60, 80], ["0-20", "21-40", "41-60", "61-80", "81+"])] += 1
    p("  " + "  ".join(f"{k}={v}" for k, v in tbuckets.items()))
    p(f"  empty title (0 chars): {empty_title}")

    # ---- BODY LENGTH ----
    p("")
    p("## BODY LENGTH (character counts)")
    p("  definition A = 'written text' = summary + concatenated .text item content")
    p("  definition B = summary only  (summary is often FM-generated; shown for contrast)")
    def body_written(n):
        L = len(n.get("summary") or "")
        for it in node_items(n):
            if isinstance(it, dict) and it.get("type") == "text":
                L += len(it.get("content") or "")
        return L
    bb_edges = [0, 100, 300, 800, 2000]
    bb_labels = ["0", "1-100", "101-300", "301-800", "801-2000", "2000+"]
    def dist_body(vals, label):
        b = {lab: 0 for lab in bb_labels}
        for v in vals:
            if v == 0: b["0"] += 1
            elif v <= 100: b["1-100"] += 1
            elif v <= 300: b["101-300"] += 1
            elif v <= 800: b["301-800"] += 1
            elif v <= 2000: b["801-2000"] += 1
            else: b["2000+"] += 1
        p(f"  {label}: " + "  ".join(f"{k}={v}" for k, v in b.items()))
    dist_body([body_written(n) for n in nodes], "A written text")
    dist_body([len(n.get("summary") or "") for n in nodes], "B summary only")

    # ---- CAPTURE DATES ----
    p("")
    p("## CAPTURE DATES (from created_at, UTC)")
    dts = [d for d in (parse_dt(n.get("created_at")) for n in nodes) if d]
    undated = total - len(dts)
    if dts:
        earliest = min(dts); latest = max(dts)
        p(f"earliest: {earliest.date().isoformat()}   latest: {latest.date().isoformat()}   "
          f"undated/unparseable: {undated}")
        by_month = {}
        by_day = {}
        for d in dts:
            ym = f"{d.year:04d}-{d.month:02d}"
            by_month[ym] = by_month.get(ym, 0) + 1
            day = d.date().isoformat()
            by_day[day] = by_day.get(day, 0) + 1
        p("nodes per month:")
        for ym in sorted(by_month):
            p(f"  {ym}: {by_month[ym]}")
        busiest = max(by_day.values())
        n_busiest = sum(1 for v in by_day.values() if v == busiest)
        p(f"busiest single day: {busiest} nodes  (days tied at that max: {n_busiest})")
    else:
        p(f"no parseable created_at dates ({undated} nodes).")

    # ---- NODE / ITEM TYPES ----
    p("")
    p("## ITEM TYPES (across all items in the corpus)")
    type_counts = {}
    nodes_with_type = {}
    for n in nodes:
        seen = set()
        for it in node_items(n):
            if not isinstance(it, dict):
                continue
            ty = it.get("type", "?")
            type_counts[ty] = type_counts.get(ty, 0) + 1
            seen.add(ty)
        for ty in seen:
            nodes_with_type[ty] = nodes_with_type.get(ty, 0) + 1
    total_items = sum(type_counts.values())
    p(f"total items: {total_items}")
    for ty in sorted(type_counts, key=lambda k: type_counts[k], reverse=True):
        p(f"  {ty:<12} items={type_counts[ty]:<6} nodes-containing={nodes_with_type.get(ty,0)}")

    # ---- TAGS ----
    p("")
    p("## TAGS")
    tag_node_count = {}
    tags_per_node = []
    for n in nodes:
        tset = set(node_tags(n))
        tags_per_node.append(len(tset))
        for tag in tset:
            tag_node_count[tag] = tag_node_count.get(tag, 0) + 1
    distinct_applied = len(tag_node_count)
    used_once = sum(1 for v in tag_node_count.values() if v == 1)
    p(f"tags.json vocabulary size: {vocab_count}"
      + (f"  ({tags_err})" if tags_err else "")
      + f"   |   anchor tags (is_canvas_anchor): {len(anchor_names)}")
    p(f"distinct tags actually applied to nodes: {distinct_applied}")
    p(f"tags applied to exactly 1 node: {used_once}")
    p(f"median tags per node: {median(tags_per_node):.1f}   max: {max(tags_per_node) if tags_per_node else 0}"
      f"   nodes with 0 tags: {sum(1 for c in tags_per_node if c == 0)}")

    p("")
    p("===== END =====")
    print("\n".join(out))


if __name__ == "__main__":
    main()
