#!/usr/bin/env python3
"""Round 5 — Section 7 outlier table.

Filters:
  (a) Stage 4 noise/unclustered (HAC at fixed k=23 has none — confirmed).
  (b) Top-1 M_blend_centered cosine < 0.10.

Pulls per-node: title, content (first 200 chars), created_at, source, top neighbor.
Appends as Section 7 to summary-round5.md. No FM/embedding work.
"""
from __future__ import annotations
import json, os
from pathlib import Path

ROOT = Path("/Users/thomasjurgensen/Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents")
OUT = Path.home() / "Desktop/AirPad/fm-diagnostic-harness"
NODES_DIR = ROOT / "nodes"
SUMMARY = OUT / "summary-round5.md"
COSINE_THRESHOLD = 0.10


def extract_content(items: list) -> str:
    """Mirror AIService.extractContent / Node.swift extractContent."""
    parts = []
    for it in items or []:
        t = it.get("type")
        if t == "text":
            v = it.get("content")
        elif t in ("audio", "video"):
            v = it.get("transcript")
        elif t in ("image", "document"):
            v = it.get("description")
        elif t == "link":
            v = " ".join(s for s in [it.get("title"), it.get("preview")] if s)
        else:
            v = None
        if v:
            parts.append(v)
    return "\n".join(parts)


def load_nodes():
    by_id = {}
    for entry in sorted(os.listdir(NODES_DIR)):
        p = NODES_DIR / entry / "node.json"
        if not p.is_file():
            continue
        try:
            d = json.loads(p.read_text())
        except Exception as e:
            print(f"WARN decode {entry}: {e}")
            continue
        nid = d.get("id") or entry
        by_id[nid] = {
            "id": nid,
            "title": d.get("title") or "",
            "source": d.get("source") or "",
            "created_at": d.get("created_at") or "",
            "content": extract_content(d.get("items", [])),
        }
    return by_id


def main():
    nodes = load_nodes()
    print(f"loaded {len(nodes)} nodes")

    sim = json.loads((OUT / "corpus-similarity.json").read_text())
    sim_by_id = {r["nodeID"]: r for r in sim}
    clusters = json.loads((OUT / "corpus-clusters.json").read_text())
    cluster_sizes = {int(k): v for k, v in clusters["clusterSizes"].items()}
    assignment_by_id = {r["nodeID"]: r["clusterID"] for r in clusters["assignments"]}

    # (a) noise/unclustered — HAC at fixed k assigns every node, so this is empty.
    noise_ids = []  # populated only if a future runner uses HDBSCAN

    # (b) Top-1 M_blend cosine < 0.10. Includes nodes whose blend list is empty
    # (no defined neighbor at all — guardrail-refused so blend embedding missing).
    low_cosine = []
    no_blend = []
    for nid, row in sim_by_id.items():
        topb = row.get("topBlend") or []
        if not topb:
            no_blend.append((nid, None, None))
            continue
        top1 = topb[0]
        if top1["score"] < COSINE_THRESHOLD:
            low_cosine.append((nid, top1["nodeID"], top1["score"]))

    # Sort low-cosine by score asc (most isolated first), then by ID for stability.
    low_cosine.sort(key=lambda x: (x[2], x[0]))
    no_blend.sort(key=lambda x: x[0])

    def md_escape(s: str) -> str:
        return s.replace("|", "\\|").replace("\n", " ").replace("\r", " ")

    def first200(s: str) -> str:
        s = s.replace("\n", " ").replace("\r", " ").strip()
        if len(s) <= 200:
            return s
        return s[:200] + "…"

    def title_for(nid: str) -> str:
        n = nodes.get(nid)
        if n:
            return n.get("title") or ""
        return sim_by_id.get(nid, {}).get("title", "")

    L = []
    L.append("")
    L.append("## Section 7 — Outlier table (post-hoc)")
    L.append("")
    L.append("Two filters per the round-5 follow-up brief:")
    L.append("- (a) Stage 4 noise/unclustered.")
    L.append("- (b) Nodes whose top-1 M_blend_centered neighbor scores below 0.10.")
    L.append("")
    L.append(f"Cluster size distribution recap: largest=32, smallest=1 (singletons). HAC at fixed k={clusters['k']} assigns every node — there is no noise/unclustered bucket. (a) is empty by construction.")
    L.append("")

    L.append("### 7a — Noise/unclustered (Stage 4)")
    L.append("")
    if not noise_ids:
        L.append("_None — HAC with fixed k=23 assigns every node to a cluster._")
    L.append("")

    # Section 7b
    L.append(f"### 7b — Nodes whose top-1 M_blend_centered neighbor < {COSINE_THRESHOLD:.2f}")
    L.append("")
    L.append(f"Count: {len(low_cosine)}.")
    L.append("")
    L.append("| node | title | first 200 chars | created | source | cluster (size) | top neighbor | top score |")
    L.append("|---|---|---|---|---|---|---|---|")
    for nid, nb_id, score in low_cosine:
        n = nodes.get(nid, {})
        short = nid[:8]
        title = md_escape(n.get("title", title_for(nid)))
        content = md_escape(first200(n.get("content", "")))
        created = md_escape(n.get("created_at", ""))
        source = md_escape(n.get("source", ""))
        cid = assignment_by_id.get(nid, "—")
        csize = cluster_sizes.get(cid, "—") if isinstance(cid, int) else "—"
        nb_short = nb_id[:8] if nb_id else "—"
        nb_title = md_escape(title_for(nb_id) if nb_id else "")
        nb_label = f"{nb_short} {nb_title}" if nb_id else "—"
        L.append(f"| {short} | {title} | {content} | {created} | {source} | {cid} ({csize}) | {nb_label} | {score:.4f} |")
    L.append("")

    # Bonus 7c: nodes with no defined blend neighbor at all (refused → no
    # folksonomy/summary embedding → no blend pairs). Strictly speaking these
    # have score = undefined, not < 0.10, but they are functionally as
    # disconnected as an outlier gets and worth surfacing for the same reason.
    if no_blend:
        L.append("### 7c — Nodes with no defined M_blend neighbor (guardrail-refused; folksonomy + summary embedding both missing)")
        L.append("")
        L.append(f"Count: {len(no_blend)}.")
        L.append("")
        L.append("| node | title | first 200 chars | created | source | cluster (size) | content top-1 (score) |")
        L.append("|---|---|---|---|---|---|---|")
        for nid, _, _ in no_blend:
            n = nodes.get(nid, {})
            short = nid[:8]
            title = md_escape(n.get("title", title_for(nid)))
            content = md_escape(first200(n.get("content", "")))
            created = md_escape(n.get("created_at", ""))
            source = md_escape(n.get("source", ""))
            cid = assignment_by_id.get(nid, "—")
            csize = cluster_sizes.get(cid, "—") if isinstance(cid, int) else "—"
            # Substitute: top content-channel neighbor (since blend is missing).
            ctop = sim_by_id.get(nid, {}).get("topContent", [])
            if ctop:
                ct = ctop[0]
                ct_label = f"{ct['nodeID'][:8]} {md_escape(title_for(ct['nodeID']))} ({ct['score']:.4f})"
            else:
                ct_label = "—"
            L.append(f"| {short} | {title} | {content} | {created} | {source} | {cid} ({csize}) | {ct_label} |")
        L.append("")

    addition = "\n".join(L) + "\n"

    existing = SUMMARY.read_text() if SUMMARY.exists() else ""
    # Strip any prior Section 7 appended to make this idempotent.
    marker = "\n## Section 7 — Outlier table (post-hoc)"
    if marker in existing:
        existing = existing.split(marker, 1)[0].rstrip() + "\n"
    SUMMARY.write_text(existing + addition)
    print(f"appended Section 7 to {SUMMARY}")
    print(f"  7a noise/unclustered: 0 (none for HAC at fixed k)")
    print(f"  7b low-cosine (<{COSINE_THRESHOLD}): {len(low_cosine)}")
    print(f"  7c no-blend-neighbor (guardrail-refused both stages): {len(no_blend)}")


if __name__ == "__main__":
    main()
