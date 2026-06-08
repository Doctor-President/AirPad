#!/usr/bin/env python3
"""
Run diagnostics A (raw neighbor inspection in whitened high-dim space)
and B (dimensionality sweep: whitening → UMAP @ {2,5,8,10,15}D → HDBSCAN).

Whitening mirrors `SubstrateWhitening.fit`/`apply` (post-2026-05-29 fix):
  - mean(X) subtracted
  - SVD of the centered N×D matrix
  - keep = smallest k such that cumulative σ²[:k] / sum(σ²) ≥ 0.90
  - capped at max(1, N-2) (rank-saturation safety; never approaches keep = N-1)
  - W = V[:, :keep] / S[:keep]   (V = Vt.T from numpy SVD)
  - whitened = (X - mean) @ W       → N × keep

The prior shipped rule (1e-6 relative singular-value floor) is preserved as
`whiten_legacy()` for comparison.

UMAP hyperparameters mirror `UMAPHyperparameters.substrateWhitened`:
  n_neighbors=15, min_dist=0.05, spread=1.0, negative_sample_rate=5,
  random_state=42, learning_rate=1.0.
n_components varies in the sweep.

HDBSCAN: min_cluster_size=5, min_samples=2 — matches the app's
`SubstrateLayoutService.runClustering` defaults.
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
TOP_K_NEIGHBORS = 10
UMAP_SEED = 42

# Matches UMAPHyperparameters.substrateWhitened
UMAP_KWARGS = dict(
    n_neighbors=15,
    min_dist=0.05,
    spread=1.0,
    learning_rate=1.0,
    negative_sample_rate=5,
    random_state=UMAP_SEED,
    metric="euclidean",
    init="spectral",
)

# Matches SubstrateLayoutService.runClustering defaults
HDBSCAN_KWARGS = dict(
    min_cluster_size=5,
    min_samples=2,
    metric="euclidean",
)


CUM_VARIANCE_THRESHOLD = 0.90  # mirrors SubstrateWhitening.cumulativeVarianceThreshold


def whiten(X: np.ndarray, threshold: float = CUM_VARIANCE_THRESHOLD):
    """Mirror SubstrateWhitening.fit + apply (post-fix rule).

    keep = smallest k such that cumulative σ²[:k] / sum(σ²) >= threshold,
    capped at max(1, N-2) to stay clear of rank-saturation.
    """
    n, d = X.shape
    mean = X.mean(axis=0)
    Xc = X - mean
    U, S, Vt = np.linalg.svd(Xc, full_matrices=False)
    if S.size == 0 or S[0] <= 0:
        return None, 0, None
    total_var = float((S ** 2).sum())
    if total_var <= 0:
        return None, 0, None
    cum = np.cumsum(S ** 2) / total_var
    keep = int(np.searchsorted(cum, threshold) + 1)
    keep = min(keep, max(1, n - 2))
    if keep == 0:
        return None, 0, None
    V = Vt.T                       # D × min(N,D)
    W = V[:, :keep] / S[:keep]     # D × keep, divides each col by σ_j
    whitened = Xc @ W              # N × keep
    return whitened, keep, dict(mean=mean, W=W, singulars=S, max_sv=float(S[0]))


def cosine_neighbors(Xw: np.ndarray, top_k: int):
    """Returns (top_k_indices [N×k], top_k_sims [N×k]). Excludes self."""
    norms = np.linalg.norm(Xw, axis=1, keepdims=True)
    Xn = Xw / np.clip(norms, 1e-12, None)
    sims = Xn @ Xn.T
    np.fill_diagonal(sims, -np.inf)
    # argpartition for speed, then sort the top-k
    idx = np.argpartition(-sims, top_k, axis=1)[:, :top_k]
    rows = np.arange(sims.shape[0])[:, None]
    sorted_within = np.argsort(-sims[rows, idx], axis=1)
    top_idx = idx[rows, sorted_within]
    top_sim = sims[rows, top_idx]
    return top_idx, top_sim


def fmt_neighbors_md(titles, paths, top_idx, top_sim, out_path: Path,
                     whiten_keep: int, n_points: int):
    lines = []
    lines.append("# Diagnostic A — raw neighbor inspection (whitened space, pre-UMAP)\n")
    lines.append(f"- N = **{n_points}**, post-whitening dim K = **{whiten_keep}**")
    lines.append(f"- top-{TOP_K_NEIGHBORS} cosine neighbors per node, self excluded")
    lines.append(f"- inputs match shipped pipeline: block-pooled → summary/folksonomy → content")
    lines.append("")
    lines.append("**Read:** if a node's neighbors are semantically related, the embedder + whitening")
    lines.append("are producing usable geometry; any clustering failure is downstream (UMAP@2D collapse).")
    lines.append("If neighbors are unrelated, the embedder itself is the ceiling.\n")
    lines.append("---\n")
    for i in range(n_points):
        title = titles[i]
        path = paths[i]
        lines.append(f"## {i:03d}. {title}")
        lines.append(f"*selection: {path}*  ")
        lines.append("")
        for rank, (j, s) in enumerate(zip(top_idx[i], top_sim[i]), start=1):
            n_title = titles[int(j)]
            lines.append(f"{rank:2d}. `{s:+.4f}`  {n_title}")
        lines.append("")
    out_path.write_text("\n".join(lines))


def run_umap_hdbscan(Xw: np.ndarray, n_components: int):
    reducer = umap.UMAP(n_components=n_components, **UMAP_KWARGS)
    embedding = reducer.fit_transform(Xw)
    clusterer = hdbscan.HDBSCAN(**HDBSCAN_KWARGS)
    labels = clusterer.fit_predict(embedding)
    return embedding, labels


def fmt_sweep_md(titles, paths, sweep_results, out_path: Path, whiten_keep: int, n_points: int):
    lines = []
    lines.append("# Diagnostic B — dimensionality sweep\n")
    lines.append(f"- N = **{n_points}**, post-whitening dim K = **{whiten_keep}**")
    lines.append(f"- pipeline per config: PCA-whiten (K dims) → UMAP @ nComponents → HDBSCAN(min_cluster=5, min_samples=2)")
    lines.append(f"- UMAP: n_neighbors=15, min_dist=0.05, spread=1.0, negative_sample_rate=5, seed={UMAP_SEED}")
    lines.append(f"- **nComponents=2 is the baseline that mirrors the shipped fit.** If it reproduces the bad membership and higher D recovers it, the fault is the 2D bottleneck — not the embedder.\n")
    lines.append("## Summary table\n")
    lines.append("| nComponents | clusters | noise count | noise rate |")
    lines.append("|---:|---:|---:|---:|")
    for r in sweep_results:
        nc = r["n_components"]
        labels = np.asarray(r["labels"])
        n_total = len(labels)
        n_noise = int((labels == -1).sum())
        n_clusters = int(labels.max() + 1) if (labels >= 0).any() else 0
        rate = n_noise / max(n_total, 1)
        lines.append(f"| {nc} | {n_clusters} | {n_noise} | {rate:.1%} |")
    lines.append("")
    lines.append("---\n")

    for r in sweep_results:
        nc = r["n_components"]
        labels = np.asarray(r["labels"])
        n_total = len(labels)
        n_noise = int((labels == -1).sum())
        n_clusters = int(labels.max() + 1) if (labels >= 0).any() else 0
        rate = n_noise / max(n_total, 1)
        lines.append(f"## nComponents = {nc}")
        lines.append(f"- clusters: **{n_clusters}**, noise: **{n_noise}/{n_total}** ({rate:.1%})\n")
        # Group by label
        by_label: dict[int, list[int]] = {}
        for i, l in enumerate(labels):
            by_label.setdefault(int(l), []).append(i)
        # Non-noise clusters in label order
        for label in sorted(k for k in by_label if k >= 0):
            members = by_label[label]
            lines.append(f"### cluster {label} — {len(members)} members")
            for i in sorted(members, key=lambda j: titles[j].lower()):
                lines.append(f"- {titles[i]}  *(sel: {paths[i]})*")
            lines.append("")
        if -1 in by_label:
            noise = by_label[-1]
            lines.append(f"### noise — {len(noise)} members")
            for i in sorted(noise, key=lambda j: titles[j].lower()):
                lines.append(f"- {titles[i]}  *(sel: {paths[i]})*")
            lines.append("")
        lines.append("---\n")
    out_path.write_text("\n".join(lines))


def main():
    if not SNAPSHOT.exists():
        sys.exit(f"snapshot missing: {SNAPSHOT}\nRun 01_export_corpus.py first.")
    snap = json.load(open(SNAPSHOT))
    points = snap["trainingPoints"]
    titles = [p["title"] for p in points]
    paths = [p["selectionPath"] for p in points]
    X = np.asarray([p["inputVector"] for p in points], dtype=np.float64)
    n, d = X.shape
    print(f"loaded N={n}, D={d}, embedder_version={snap['embedderVersion']}")

    Xw, keep, params = whiten(X)
    if Xw is None:
        sys.exit("whitening degenerate")
    print(f"whitening: keep={keep} (max_sv={params['max_sv']:.4g})")

    # --- Diagnostic A ---
    print("running diagnostic A (cosine neighbors in whitened space)...")
    top_idx, top_sim = cosine_neighbors(Xw, TOP_K_NEIGHBORS)
    a_path = RESULTS / "neighbors.md"
    fmt_neighbors_md(titles, paths, top_idx, top_sim, a_path,
                     whiten_keep=keep, n_points=n)
    print(f"  wrote {a_path}")

    # --- Diagnostic B ---
    print("running diagnostic B (dimensionality sweep)...")
    sweep_results = []
    for nc in SWEEP_DIMS:
        print(f"  nComponents = {nc} ...")
        embedding, labels = run_umap_hdbscan(Xw, nc)
        sweep_results.append({
            "n_components": nc,
            "embedding": embedding,
            "labels": labels,
        })
    b_path = RESULTS / "sweep.md"
    fmt_sweep_md(titles, paths, sweep_results, b_path,
                 whiten_keep=keep, n_points=n)
    print(f"  wrote {b_path}")

    # Persist sweep machine-readable for the verdict script
    json_path = RESULTS / "sweep_results.json"
    json.dump({
        "nPoints": n,
        "inputDim": d,
        "whiteningKeep": keep,
        "configs": [
            {
                "nComponents": r["n_components"],
                "labels": [int(x) for x in r["labels"]],
                "titles": titles,
                "selectionPaths": paths,
            }
            for r in sweep_results
        ],
        "neighborsA": {
            "topK": TOP_K_NEIGHBORS,
            "topIdx": top_idx.tolist(),
            "topSim": [[float(s) for s in row] for row in top_sim],
            "titles": titles,
        }
    }, open(json_path, "w"))
    print(f"  wrote {json_path}")
    print("done.")


if __name__ == "__main__":
    main()
