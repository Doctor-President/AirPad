#!/usr/bin/env python3
"""
Cluster-cleanup param sweep on the post-fix whitened+UMAP@8D embedding.

Follow-up to 05_cluster_cut_sweep.py. That sweep proved leaf surfaces
12 coherent clusters at the shipped mcs=5/ms=2/ε=0 config — but ~1/3 of
those clusters are grab-bags (cluster 6 dreams+TikTok+cop-drama, cluster
7 tech+Korean-Ground-Beef+to-do) and small coherent groups (e.g. the
two near-identical Middle-earth morality notes) get orphaned to noise
because mcs=5 won't form clusters below 5 nodes.

This sweep walks the leaf-method parameter knee:
  cluster_selection_method = 'leaf' (throughout)
  min_cluster_size ∈ {2, 3, 4, 5}
  min_samples ∈ {1, 2}
  cluster_selection_epsilon ∈ {0.0, plus 3 small ε values picked
    from the condensed-tree's distribution of leaf-boundary distances
    so the eps row is calibrated to the actual density gaps in this
    embedding rather than guessed in absolute units}

Per config emits cluster count, noise %, and FULL membership by node
title. Companion reads the title-lists to decide whether any config
meaningfully beats the current 12-cluster/20%-noise baseline.

Reuses the same whitening + UMAP fit pipeline as 05 so the embedding is
byte-identical; the only thing varying is the HDBSCAN cut.
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

CUM_VARIANCE_THRESHOLD = 0.90
UMAP_SEED = 42
N_COMPONENTS = 8

UMAP_KWARGS = dict(
    n_components=N_COMPONENTS,
    n_neighbors=15,
    min_dist=0.05,
    spread=1.0,
    learning_rate=1.0,
    negative_sample_rate=5,
    random_state=UMAP_SEED,
    metric="euclidean",
    init="spectral",
)


def whiten(X, threshold=CUM_VARIANCE_THRESHOLD):
    n, _d = X.shape
    mean = X.mean(axis=0)
    Xc = X - mean
    U, S, Vt = np.linalg.svd(Xc, full_matrices=False)
    if S.size == 0 or S[0] <= 0:
        return None, 0
    total_var = float((S ** 2).sum())
    if total_var <= 0:
        return None, 0
    cum = np.cumsum(S ** 2) / total_var
    keep = int(np.searchsorted(cum, threshold) + 1)
    keep = min(keep, max(1, n - 2))
    V = Vt.T
    W = V[:, :keep] / S[:keep]
    return Xc @ W, keep


def sweep_one(embedding, mcs, ms, eps):
    cl = hdbscan.HDBSCAN(
        min_cluster_size=mcs,
        min_samples=ms,
        cluster_selection_method="leaf",
        cluster_selection_epsilon=eps,
        metric="euclidean",
    )
    labels = cl.fit_predict(embedding)
    n_total = len(labels)
    n_noise = int((labels == -1).sum())
    n_clusters = int(labels.max() + 1) if (labels >= 0).any() else 0
    return dict(
        method="leaf",
        mcs=mcs,
        ms=ms,
        eps=eps,
        n_clusters=n_clusters,
        n_noise=n_noise,
        n_total=n_total,
        labels=[int(x) for x in labels],
    )


def pick_epsilons_from_tree(embedding, mcs_for_probe=2, ms_for_probe=1):
    """Read the distribution of leaf-cluster boundary distances off the
    condensed tree of a maximally-fine fit and return 3 small ε values
    that fall inside the small-distance tail. These are 1/λ at internal
    cluster-node births — the actual density gaps at which leaves bud
    off in this embedding, so they're calibrated to the spectrum we're
    cutting rather than guessed in absolute units.
    """
    probe = hdbscan.HDBSCAN(
        min_cluster_size=mcs_for_probe,
        min_samples=ms_for_probe,
        cluster_selection_method="leaf",
        metric="euclidean",
    )
    probe.fit(embedding)
    arr = probe.condensed_tree_.to_numpy()
    # cluster nodes appear as children with child_size > 1; their lambda_val
    # at that row is the lambda_birth, which inverts to ε_birth = 1/λ.
    dists = []
    for row in arr:
        if int(row["child_size"]) > 1:
            lam = float(row["lambda_val"])
            if lam > 0:
                dists.append(1.0 / lam)
    dists = np.asarray(dists, dtype=np.float64)
    if dists.size == 0:
        return []
    # Take 3 quantiles inside the small half — q25/q40/q60 of the full
    # distribution covers "merge a few near-leaves" through "merge most
    # leaf pairs". Beyond q60 we'd be undoing the leaf cut entirely.
    qs = np.quantile(dists, [0.25, 0.40, 0.60])
    # Round to 4 decimals for table legibility.
    return [float(round(q, 4)) for q in qs]


def format_cluster_block(titles, labels):
    by_label: dict[int, list[int]] = {}
    for i, l in enumerate(labels):
        by_label.setdefault(int(l), []).append(i)
    out = []
    for lbl in sorted(k for k in by_label if k >= 0):
        members = sorted(by_label[lbl], key=lambda j: titles[j].lower())
        out.append((lbl, [titles[i] for i in members]))
    if -1 in by_label:
        noise = sorted(by_label[-1], key=lambda j: titles[j].lower())
        out.append((-1, [titles[i] for i in noise]))
    return out


def write_sweep_md(titles, configs, out_path: Path, whiten_keep, n_points, epsilons):
    lines = []
    lines.append("# Cluster-cleanup param sweep — leaf on post-fix whitened+UMAP@8D\n")
    lines.append(f"- N = **{n_points}**, post-whitening dim K = **{whiten_keep}**, UMAP nComponents = **{N_COMPONENTS}**")
    lines.append(f"- UMAP hyperparameters mirror substrate display (n_neighbors=15, min_dist=0.05, spread=1.0, seed={UMAP_SEED})")
    lines.append("- Single UMAP fit; HDBSCAN sweep below applied to the **same** embedding")
    lines.append("- All configs use `cluster_selection_method=leaf`")
    lines.append(f"- ε values: `0.0` plus tree-derived `{epsilons}` (1/λ at internal cluster-node births in the leaf condensed tree, q25/q40/q60 of the distribution)")
    lines.append("")
    lines.append("**Read.** Shipped commit-3 default is `leaf mcs=5 ms=2 ε=0` → 12 clusters, 24/120 noise. Target: a config where the crisp clusters (recipes / AirPad-UX / canvas-architecture / cosmology) stay intact AND grab-bags (cluster 6, cluster 7 from the previous sweep) tighten AND small coherent pairs (Middle-earth morality, etc.) get reclaimed from noise. As mcs drops, noise should fall and the grab-bags should split into something coherent — until it shatters into confetti. Find that knee.")
    lines.append("")
    lines.append("## Summary table\n")
    lines.append("| mcs | ms |   ε   | clusters | noise | noise rate |")
    lines.append("|---:|---:|---:|---:|---:|---:|")
    for r in configs:
        lines.append(
            f"| {r['mcs']} | {r['ms']} | {r['eps']:.4f} | "
            f"{r['n_clusters']} | {r['n_noise']} | {r['n_noise']/max(r['n_total'],1):.1%} |"
        )
    lines.append("")
    lines.append("---\n")
    for r in configs:
        head = f"## mcs={r['mcs']} · ms={r['ms']} · ε={r['eps']:.4f}"
        lines.append(head)
        lines.append(f"- clusters: **{r['n_clusters']}**, noise: **{r['n_noise']}/{r['n_total']}** ({r['n_noise']/max(r['n_total'],1):.1%})\n")
        for lbl, members in format_cluster_block(titles, r["labels"]):
            head2 = f"### noise — {len(members)} members" if lbl == -1 else f"### cluster {lbl} — {len(members)} members"
            lines.append(head2)
            for t in members:
                lines.append(f"- {t}")
            lines.append("")
        lines.append("---\n")
    out_path.write_text("\n".join(lines))


def main():
    if not SNAPSHOT.exists():
        sys.exit(f"snapshot missing: {SNAPSHOT}\nRun 01_export_corpus.py first.")
    snap = json.load(open(SNAPSHOT))
    points = snap["trainingPoints"]
    titles = [p["title"] for p in points]
    X = np.asarray([p["inputVector"] for p in points], dtype=np.float64)
    n, d = X.shape
    print(f"loaded N={n}, D={d}")

    Xw, keep = whiten(X)
    if Xw is None:
        sys.exit("whitening degenerate")
    print(f"whitening keep={keep}")

    print(f"fitting UMAP @ {N_COMPONENTS}D once...")
    reducer = umap.UMAP(**UMAP_KWARGS)
    embedding = reducer.fit_transform(Xw)

    print("picking ε values from condensed tree...")
    epsilons = pick_epsilons_from_tree(embedding)
    print(f"  ε candidates: {epsilons}")
    eps_grid = [0.0] + epsilons

    configs = []
    for mcs in (2, 3, 4, 5):
        for ms in (1, 2):
            for eps in eps_grid:
                r = sweep_one(embedding, mcs, ms, eps)
                configs.append(r)
                print(f"  leaf mcs={mcs} ms={ms} eps={eps:.4f} → {r['n_clusters']} clusters, {r['n_noise']}/{r['n_total']} noise")

    sweep_path = RESULTS / "cluster_cleanup_param_sweep.md"
    write_sweep_md(titles, configs, sweep_path, keep, n, epsilons)
    print(f"  wrote {sweep_path}")

    json_path = RESULTS / "cluster_cleanup_param_sweep.json"
    json.dump({
        "nPoints": n,
        "whiteningKeep": keep,
        "nComponents": N_COMPONENTS,
        "umapSeed": UMAP_SEED,
        "epsilonsFromTree": epsilons,
        "configs": configs,
        "titles": titles,
    }, open(json_path, "w"))
    print(f"  wrote {json_path}")
    print("done.")


if __name__ == "__main__":
    main()
