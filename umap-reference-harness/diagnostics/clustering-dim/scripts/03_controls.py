#!/usr/bin/env python3
"""
Control diagnostics that pin down which stage of the pipeline destroys
membership signal.

Why this exists: the primary run (02_run_diagnostic.py) showed that in
shipped-whitened space EVERY pairwise cosine is ~-1/N ≈ -0.008 — i.e. the
whitening transform with the 1e-6 relative cutoff is rank-saturating at
keep=N-1, which mathematically forces all pairs equidistant. UMAP's k-NN
graph then has nothing to bind on. We need raw (unwhitened) controls to
confirm the embedder itself produces structured geometry, and a stricter-
cutoff control to confirm whitening is fine in principle if the cutoff is
chosen for the (N,D) regime.

Produces:
- neighbors_raw.md       : top-10 cosine neighbors on RAW block-pooled vectors (pre-whitening)
- sweep_raw.md           : UMAP@{2,5,8,10,15}D + HDBSCAN on raw vectors (no whitening)
- whitening_sweep.md     : top-10 cosine neighbors at keep ∈ {5, 10, 20, 50, 119(shipped)}
                           — for a few probe nodes (recipes, tech, etc) — plus the
                           pairwise cosine p10/p50/p90 at each cutoff
- controls_results.json  : machine-readable for the verdict script
"""
import json
import sys
from pathlib import Path

import numpy as np
import umap
import hdbscan

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SNAPSHOT = ROOT / "fixtures" / "corpus_snapshot.json"
RESULTS = ROOT / "results"
RESULTS.mkdir(parents=True, exist_ok=True)

SWEEP_DIMS = [2, 5, 8, 10, 15]
TOP_K = 10
UMAP_SEED = 42

UMAP_KWARGS = dict(
    n_neighbors=15,
    min_dist=0.05,
    spread=1.0,
    learning_rate=1.0,
    negative_sample_rate=5,
    random_state=UMAP_SEED,
    metric="cosine",          # raw block-pooled vectors live on a cone — cosine is the right metric
    init="spectral",
)

HDBSCAN_KWARGS = dict(
    min_cluster_size=5,
    min_samples=2,
    metric="euclidean",       # HDBSCAN runs on UMAP-output euclidean coords (matches app)
)


def cosine_top_k(X: np.ndarray, k: int):
    norms = np.linalg.norm(X, axis=1, keepdims=True)
    Xn = X / np.clip(norms, 1e-12, None)
    sims = Xn @ Xn.T
    np.fill_diagonal(sims, -np.inf)
    idx = np.argpartition(-sims, k, axis=1)[:, :k]
    rows = np.arange(sims.shape[0])[:, None]
    sorted_within = np.argsort(-sims[rows, idx], axis=1)
    top_idx = idx[rows, sorted_within]
    top_sim = sims[rows, top_idx]
    return top_idx, top_sim, sims


def pairwise_cosine_stats(sims: np.ndarray):
    """Off-diagonal cosine stats (excluding self pairs)."""
    n = sims.shape[0]
    mask = ~np.eye(n, dtype=bool)
    flat = sims[mask]
    # Some entries were set to -inf for self-exclusion in top-k path —
    # rebuild cleanly here.
    return dict(
        n=int(flat.size),
        p10=float(np.percentile(flat, 10)),
        p50=float(np.percentile(flat, 50)),
        p90=float(np.percentile(flat, 90)),
        mean=float(flat.mean()),
        std=float(flat.std()),
    )


def whiten(X: np.ndarray, max_keep: int | None = None, rel_cutoff: float = 1e-6):
    """SubstrateWhitening-equivalent with optional explicit `max_keep` cap.
    When max_keep is None, uses the shipped 1e-6 relative cutoff."""
    mean = X.mean(axis=0)
    Xc = X - mean
    U, S, Vt = np.linalg.svd(Xc, full_matrices=False)
    if S.size == 0 or S[0] <= 0:
        return None, 0
    max_sv = float(S[0])
    cutoff = max_sv * rel_cutoff
    keep = int(np.sum(S > cutoff))
    if max_keep is not None:
        keep = min(keep, max_keep)
    if keep == 0:
        return None, 0
    V = Vt.T
    W = V[:, :keep] / S[:keep]
    return Xc @ W, keep


def write_neighbors_md(titles, paths, top_idx, top_sim, n, out_path: Path, header: str):
    lines = [header, ""]
    for i in range(n):
        lines.append(f"## {i:03d}. {titles[i]}")
        lines.append(f"*selection: {paths[i]}*  ")
        lines.append("")
        for rank, (j, s) in enumerate(zip(top_idx[i], top_sim[i]), start=1):
            lines.append(f"{rank:2d}. `{s:+.4f}`  {titles[int(j)]}")
        lines.append("")
    out_path.write_text("\n".join(lines))


def main():
    snap = json.load(open(SNAPSHOT))
    titles = [p["title"] for p in snap["trainingPoints"]]
    paths = [p["selectionPath"] for p in snap["trainingPoints"]]
    X = np.asarray([p["inputVector"] for p in snap["trainingPoints"]], dtype=np.float64)
    n, d = X.shape
    print(f"loaded N={n}, D={d}")

    # --- Raw cosine neighbors (control A0) ---
    print("computing raw cosine top-10 neighbors...")
    top_idx_raw, top_sim_raw, sims_raw = cosine_top_k(X, TOP_K)
    raw_stats = pairwise_cosine_stats(sims_raw)
    write_neighbors_md(
        titles, paths, top_idx_raw, top_sim_raw, n,
        RESULTS / "neighbors_raw.md",
        header=(
            "# Diagnostic A0 (control) — raw cosine neighbors, pre-whitening\n"
            f"- N = **{n}**, D = **{d}** (raw block-pooled 512-dim NLContextualEmbedding output)\n"
            "- this is what the embedder itself produces — no PCA whitening applied.\n"
            "- compare against `neighbors.md` (whitened, shipped pipeline). If neighbors\n"
            "  are coherent here but random there, the whitening config is the bug, not the embedder.\n"
            f"\nPairwise cosine off-diagonal: p10={raw_stats['p10']:.3f}, "
            f"p50={raw_stats['p50']:.3f}, p90={raw_stats['p90']:.3f}, "
            f"mean={raw_stats['mean']:.3f} ± {raw_stats['std']:.3f}\n"
        ),
    )

    # --- Raw-input UMAP sweep + HDBSCAN (control B0) ---
    print("running raw-input UMAP sweep + HDBSCAN (no whitening, cosine metric)...")
    raw_sweep = []
    for nc in SWEEP_DIMS:
        print(f"  nC = {nc}")
        reducer = umap.UMAP(n_components=nc, **UMAP_KWARGS)
        embedding = reducer.fit_transform(X)
        labels = hdbscan.HDBSCAN(**HDBSCAN_KWARGS).fit_predict(embedding)
        raw_sweep.append(dict(n_components=nc, labels=labels.tolist()))

    sweep_md_lines = [
        "# Diagnostic B0 (control) — dim sweep on RAW vectors (whitening bypassed)\n",
        f"- N = **{n}**, D = **{d}**",
        "- pipeline per config: raw block-pooled → UMAP @ nComponents (cosine metric) → HDBSCAN(min_cluster=5, min_samples=2)",
        f"- UMAP: n_neighbors=15, min_dist=0.05, spread=1.0, negative_sample_rate=5, metric=cosine, seed={UMAP_SEED}",
        "- whitening is **bypassed** — compare against `sweep.md` (whitened) to localize the fault.\n",
        "## Summary table\n",
        "| nComponents | clusters | noise count | noise rate |",
        "|---:|---:|---:|---:|",
    ]
    for r in raw_sweep:
        labels = np.asarray(r["labels"])
        nn = labels.size
        n_noise = int((labels == -1).sum())
        n_clusters = int(labels.max() + 1) if (labels >= 0).any() else 0
        rate = n_noise / max(nn, 1)
        sweep_md_lines.append(f"| {r['n_components']} | {n_clusters} | {n_noise} | {rate:.1%} |")
    sweep_md_lines.append("")
    sweep_md_lines.append("---\n")
    for r in raw_sweep:
        labels = np.asarray(r["labels"])
        nn = labels.size
        n_noise = int((labels == -1).sum())
        n_clusters = int(labels.max() + 1) if (labels >= 0).any() else 0
        rate = n_noise / max(nn, 1)
        sweep_md_lines.append(f"## nComponents = {r['n_components']}")
        sweep_md_lines.append(f"- clusters: **{n_clusters}**, noise: **{n_noise}/{nn}** ({rate:.1%})\n")
        by_label: dict[int, list[int]] = {}
        for i, l in enumerate(labels):
            by_label.setdefault(int(l), []).append(i)
        for label in sorted(k for k in by_label if k >= 0):
            members = by_label[label]
            sweep_md_lines.append(f"### cluster {label} — {len(members)} members")
            for i in sorted(members, key=lambda j: titles[j].lower()):
                sweep_md_lines.append(f"- {titles[i]}  *(sel: {paths[i]})*")
            sweep_md_lines.append("")
        if -1 in by_label:
            sweep_md_lines.append(f"### noise — {len(by_label[-1])} members")
            for i in sorted(by_label[-1], key=lambda j: titles[j].lower()):
                sweep_md_lines.append(f"- {titles[i]}  *(sel: {paths[i]})*")
            sweep_md_lines.append("")
        sweep_md_lines.append("---\n")
    (RESULTS / "sweep_raw.md").write_text("\n".join(sweep_md_lines))

    # --- Whitening cutoff sweep ---
    print("computing whitening cutoff sweep...")
    cutoff_keeps = [5, 10, 20, 50, 119]   # 119 = shipped 1e-6 cutoff result
    cutoff_summary = []
    cutoff_neighbors = []
    for k in cutoff_keeps:
        Xw, kept = whiten(X, max_keep=k)
        # sanity probe nodes: top-3 neighbors of node 0 + several manually picked
        if Xw is None:
            cutoff_summary.append(dict(keep=k, ok=False))
            continue
        ti, ts, sims = cosine_top_k(Xw, TOP_K)
        s = pairwise_cosine_stats(sims)
        cutoff_summary.append(dict(keep=kept, **s))
        cutoff_neighbors.append(dict(
            keep=kept,
            top_idx=ti.tolist(),
            top_sim=[[float(x) for x in row] for row in ts],
        ))

    lines = ["# Diagnostic A1 — whitening cutoff sweep (cosine geometry)\n"]
    lines.append("- shows what the **whitening configuration** does to the geometry at this (N, D) regime.")
    lines.append("- 'keep' = number of singular components retained (V[:,:keep] / σ[:keep]).")
    lines.append(f"- the shipped pipeline runs at keep = N-1 = 119 (1e-6 relative cutoff lets all surviving σ through).\n")
    lines.append("## Pairwise cosine summary at each cutoff\n")
    lines.append("| keep | n_pairs | p10 | p50 | p90 | mean ± std |")
    lines.append("|---:|---:|---:|---:|---:|---|")
    raw_pairs = pairwise_cosine_stats(sims_raw)
    lines.append(f"| raw (no whitening) | {raw_pairs['n']} | "
                 f"{raw_pairs['p10']:+.4f} | {raw_pairs['p50']:+.4f} | {raw_pairs['p90']:+.4f} | "
                 f"{raw_pairs['mean']:+.4f} ± {raw_pairs['std']:.4f} |")
    for s in cutoff_summary:
        if not s.get("ok", True) and "p10" not in s:
            lines.append(f"| {s['keep']} | (degenerate) | | | | |")
            continue
        lines.append(f"| {s['keep']} | {s['n']} | "
                     f"{s['p10']:+.4f} | {s['p50']:+.4f} | {s['p90']:+.4f} | "
                     f"{s['mean']:+.4f} ± {s['std']:.4f} |")
    lines.append("")
    lines.append("Reading: a healthy distribution has p10 < 0 << p90 (i.e. some pairs are far, some close).")
    lines.append("When `p10 ≈ p90 ≈ -1/N`, the cloud is rank-saturated and every pair is equidistant — UMAP has nothing to bind on.\n")

    # Spot-check: show top-5 neighbors at each cutoff for the first three probe nodes
    probe_nodes = list(range(min(5, n)))
    for i in probe_nodes:
        lines.append(f"\n## Probe: {titles[i]}\n")
        # Raw column
        lines.append(f"**raw (no whitening) top-5:**")
        for rank in range(min(5, TOP_K)):
            j = int(top_idx_raw[i][rank]); s = float(top_sim_raw[i][rank])
            lines.append(f"  - `{s:+.3f}` {titles[j]}")
        for w_entry in cutoff_neighbors:
            keep = w_entry["keep"]
            lines.append(f"\n**whitened, keep={keep}, top-5:**")
            for rank in range(min(5, TOP_K)):
                j = int(w_entry["top_idx"][i][rank])
                s = float(w_entry["top_sim"][i][rank])
                lines.append(f"  - `{s:+.3f}` {titles[j]}")
        lines.append("")
    (RESULTS / "whitening_sweep.md").write_text("\n".join(lines))

    # --- Machine-readable summary for the verdict script ---
    json.dump({
        "nPoints": n,
        "inputDim": d,
        "raw": {
            "cosineStats": raw_pairs,
            "topIdx": top_idx_raw.tolist(),
            "topSim": [[float(s) for s in row] for row in top_sim_raw],
            "titles": titles,
        },
        "rawSweep": raw_sweep,
        "whiteningCutoffSweep": cutoff_summary,
    }, open(RESULTS / "controls_results.json", "w"))
    print("done.")


if __name__ == "__main__":
    main()
