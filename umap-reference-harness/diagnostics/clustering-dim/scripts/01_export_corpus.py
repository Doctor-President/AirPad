#!/usr/bin/env python3
"""
Export `corpus_snapshot.json` from the live AirPad iCloud corpus.

Mirrors `SubstrateLayoutService.substrateVector(for:)` + the fit-time filter
(`isRankable` && !is_meta && substrateVector != nil) so the diagnostic sees
the same input set the shipped pipeline does.

Input-selection precedence (matches Swift exactly):
  1. block-pooled (element-wise mean of all blocks in blocks.json), if blocks
     exist and share a positive dim. (`SubstrateLayoutService.preloadBlockPooledVectors`)
  2. (summary + folksonomy) / 2 if both present and same dim
  3. summary alone if folksonomy missing
  4. folksonomy alone if summary missing
  5. contextual_content_embedding fallback
  6. else: skip

Filter:
  - drop is_meta == True
  - drop embedding_failure_reason == "thin_content"  (matches `SubstrateService.isRankable`)

Source: ~/Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents/nodes/<uuid>/{node.json, blocks.json}

Output schema (gitignored fixture; mirrors the harness convention):
{
  "embedderVersion": <int>,             # max observed embedding_version
  "inputDimension": <int>,              # 512 expected
  "trainingPoints": [
    {
      "nodeID": "<uuid>",
      "title": "<string>",
      "selectionPath": "block-pooled" | "summary+folksonomy" | "summary" | "folksonomy" | "content",
      "inputVector": [<dim floats>]
    },
    ...
  ],
  "droppedCounts": {
    "isMeta": <int>,
    "thinContent": <int>,
    "noSubstrateVector": <int>,
    "guardrailRefused": <int>     # diagnostic only; these still ship if they have a content fallback
  }
}
"""
import json
import os
import sys
from pathlib import Path

ICLOUD_ROOT = Path.home() / "Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents/nodes"

OUT_PATH = Path(__file__).resolve().parent.parent / "fixtures" / "corpus_snapshot.json"


def mean_pool(vectors):
    """Element-wise mean. All vectors must share dim. Returns list[float]."""
    if not vectors:
        return None
    dim = len(vectors[0])
    if dim == 0:
        return None
    acc = [0.0] * dim
    n = 0
    for v in vectors:
        if len(v) != dim:
            continue
        for i in range(dim):
            acc[i] += v[i]
        n += 1
    if n == 0:
        return None
    inv = 1.0 / n
    return [a * inv for a in acc]


def block_pooled(node_dir: Path):
    """Mirror `SubstrateLayoutService.preloadBlockPooledVectors`: mean of all
    block embeddings whose dim matches blocks[0].embedding count and dim > 0."""
    bjson = node_dir / "blocks.json"
    if not bjson.exists():
        return None
    try:
        data = json.load(open(bjson))
    except Exception:
        return None
    blocks = data.get("blocks") or []
    if not blocks:
        return None
    first_emb = blocks[0].get("embedding") or []
    dim = len(first_emb)
    if dim == 0:
        return None
    vecs = []
    for b in blocks:
        emb = b.get("embedding") or []
        if len(emb) == dim:
            vecs.append(emb)
    return mean_pool(vecs)


def select_substrate_vector(node, node_dir: Path):
    """Returns (vector, path_tag) or (None, None) when no channel exists."""
    pooled = block_pooled(node_dir)
    if pooled is not None and len(pooled) > 0:
        return pooled, "block-pooled"

    summary = node.get("summary_embedding") or []
    folksonomy = node.get("folksonomy_embedding") or []
    s = summary if len(summary) > 0 else None
    f = folksonomy if len(folksonomy) > 0 else None

    if s is not None and f is not None:
        if len(s) != len(f):
            return s, "summary"   # mirrors Swift: returns `s` on dim mismatch
        avg = [(a + b) * 0.5 for a, b in zip(s, f)]
        return avg, "summary+folksonomy"
    if s is not None:
        return s, "summary"
    if f is not None:
        return f, "folksonomy"

    content = node.get("contextual_content_embedding") or []
    if len(content) > 0:
        return content, "content"
    return None, None


def is_rankable(node):
    return node.get("embedding_failure_reason") != "thin_content"


def main():
    if not ICLOUD_ROOT.exists():
        sys.exit(f"iCloud root not found: {ICLOUD_ROOT}")

    points = []
    dropped = {
        "isMeta": 0,
        "thinContent": 0,
        "noSubstrateVector": 0,
        "guardrailRefused": 0,
    }
    embedder_version = 0
    expected_dim = None

    node_dirs = sorted(p for p in ICLOUD_ROOT.iterdir() if p.is_dir())
    for node_dir in node_dirs:
        njson = node_dir / "node.json"
        if not njson.exists():
            continue
        try:
            node = json.load(open(njson))
        except Exception as e:
            print(f"WARN: failed to parse {njson}: {e}", file=sys.stderr)
            continue

        if node.get("is_meta") is True:
            dropped["isMeta"] += 1
            continue
        if not is_rankable(node):
            dropped["thinContent"] += 1
            continue
        if node.get("embedding_failure_reason") == "guardrail_refused":
            dropped["guardrailRefused"] += 1  # diagnostic; still considered for fit

        vec, path_tag = select_substrate_vector(node, node_dir)
        if vec is None:
            dropped["noSubstrateVector"] += 1
            continue

        if expected_dim is None:
            expected_dim = len(vec)
        elif len(vec) != expected_dim:
            # Dim mismatch across the corpus would be a corpus-level bug;
            # surface but don't silently include.
            print(f"WARN: {node_dir.name} dim {len(vec)} != expected {expected_dim} — skipping", file=sys.stderr)
            dropped["noSubstrateVector"] += 1
            continue

        ev = node.get("embedding_version") or 0
        if isinstance(ev, int):
            embedder_version = max(embedder_version, ev)

        points.append({
            "nodeID": node.get("id") or node_dir.name,
            "title": node.get("title") or "(untitled)",
            "selectionPath": path_tag,
            "inputVector": vec,
        })

    out = {
        "embedderVersion": embedder_version,
        "inputDimension": expected_dim or 0,
        "trainingPoints": points,
        "droppedCounts": dropped,
    }
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    json.dump(out, open(OUT_PATH, "w"))
    print(f"wrote {OUT_PATH}")
    print(f"  N = {len(points)}, D = {expected_dim}")
    print(f"  embedder_version = {embedder_version}")
    print(f"  dropped: {dropped}")
    paths = {}
    for p in points:
        paths[p["selectionPath"]] = paths.get(p["selectionPath"], 0) + 1
    print(f"  selectionPath histogram: {paths}")


if __name__ == "__main__":
    main()
