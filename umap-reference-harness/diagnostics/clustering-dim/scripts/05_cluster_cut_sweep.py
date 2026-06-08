#!/usr/bin/env python3
"""
Cluster-cut sweep on the post-fix whitened+UMAP@8D embedding.

Tests whether the ~112-node residual blob from the post-fix sweep is
a genuine flat density-gap ceiling (CC's verdict) or coherent
sub-topics that HDBSCAN's default `eom` cut declines to surface
(companion's challenge).

Pipeline (single fit, then HDBSCAN sweep over it):
  corpus → whiten(0.90 cum-variance) → UMAP @ 8D → HDBSCAN sweep

HDBSCAN sweep matrix:
  cluster_selection_method ∈ {'eom', 'leaf'}
  min_cluster_size         ∈ {2, 3, 4, 5}
  min_samples              ∈ {1, 2}
  cluster_selection_epsilon ∈ {0.0}   plus a small ε sweep on
    the leaf config most likely to over-split if any of the above
    fractures the blob into title-soup.

Per config exported: cluster count, noise rate, and membership
by node title (legible — not label integers).

Also extracts the condensed tree from the default eom fit so we
can see, structurally, whether the residual blob ever surfaces
non-recipe candidate clusters at any lambda (proof or
disproof of CC's "density-gap ceiling").
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
    n, d = X.shape
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
    if keep == 0:
        return None, 0
    V = Vt.T
    W = V[:, :keep] / S[:keep]
    return Xc @ W, keep


def sweep_one(embedding, method, mcs, ms, eps):
    cl = hdbscan.HDBSCAN(
        min_cluster_size=mcs,
        min_samples=ms,
        cluster_selection_method=method,
        cluster_selection_epsilon=eps,
        metric="euclidean",
    )
    labels = cl.fit_predict(embedding)
    n_total = len(labels)
    n_noise = int((labels == -1).sum())
    n_clusters = int(labels.max() + 1) if (labels >= 0).any() else 0
    return dict(
        method=method,
        mcs=mcs,
        ms=ms,
        eps=eps,
        n_clusters=n_clusters,
        n_noise=n_noise,
        n_total=n_total,
        labels=[int(x) for x in labels],
    )


def format_cluster_block(titles, paths, labels):
    """Return list of (label, member_titles) sorted: clusters by id, noise last."""
    by_label: dict[int, list[int]] = {}
    for i, l in enumerate(labels):
        by_label.setdefault(int(l), []).append(i)
    out = []
    for lbl in sorted(k for k in by_label if k >= 0):
        members = sorted(by_label[lbl], key=lambda j: titles[j].lower())
        out.append((lbl, [(titles[i], paths[i]) for i in members]))
    if -1 in by_label:
        noise = sorted(by_label[-1], key=lambda j: titles[j].lower())
        out.append((-1, [(titles[i], paths[i]) for i in noise]))
    return out


def write_sweep_md(titles, paths, configs, out_path: Path, whiten_keep, n_points):
    lines = []
    lines.append("# Cluster-cut sweep — post-fix whitened+UMAP@8D embedding\n")
    lines.append(f"- N = **{n_points}**, post-whitening dim K = **{whiten_keep}**, UMAP nComponents = **{N_COMPONENTS}**")
    lines.append(f"- UMAP hyperparameters mirror substrate (n_neighbors=15, min_dist=0.05, spread=1.0, seed={UMAP_SEED})")
    lines.append(f"- Single UMAP fit; HDBSCAN sweep below applied to the **same** embedding")
    lines.append(f"- Compares cluster_selection_method ∈ {{eom, leaf}} × min_cluster_size ∈ {{2,3,4,5}} × min_samples ∈ {{1,2}}")
    lines.append("")
    lines.append("**Read.** The shipped pipeline uses `eom, mcs=5, ms=2, eps=0.0` (top of the table). If finer cuts produce coherent title groupings the bucket was never one mass — only EOM's cut policy made it one. If finer cuts only ever produce label-soup the bucket is genuinely continuous.")
    lines.append("")
    lines.append("## Summary table\n")
    lines.append("| method | mcs | ms |   ε   | clusters | noise | noise rate |")
    lines.append("|:---|---:|---:|---:|---:|---:|---:|")
    for r in configs:
        lines.append(
            f"| {r['method']} | {r['mcs']} | {r['ms']} | {r['eps']:.2f} | "
            f"{r['n_clusters']} | {r['n_noise']} | {r['n_noise']/max(r['n_total'],1):.1%} |"
        )
    lines.append("")
    lines.append("---\n")
    for r in configs:
        head = f"## {r['method']} · mcs={r['mcs']} · ms={r['ms']} · ε={r['eps']:.2f}"
        lines.append(head)
        lines.append(f"- clusters: **{r['n_clusters']}**, noise: **{r['n_noise']}/{r['n_total']}** ({r['n_noise']/max(r['n_total'],1):.1%})\n")
        for lbl, members in format_cluster_block(titles, paths, r["labels"]):
            head2 = f"### noise — {len(members)} members" if lbl == -1 else f"### cluster {lbl} — {len(members)} members"
            lines.append(head2)
            for t, _p in members:
                lines.append(f"- {t}")
            lines.append("")
        lines.append("---\n")
    out_path.write_text("\n".join(lines))


def write_condensed_tree_md(clusterer, titles, out_path: Path):
    """Write a structural view of the condensed tree from the eom-default fit.

    For each candidate cluster node (child_size >= min_cluster_size), show
    its lambda persistence (lambda_birth → max child lambda) and its member
    titles. Persistence × size is HDBSCAN's stability score — large stable
    candidates are what EOM prefers. If only the recipe cluster has high
    stability, that's evidence the residual is genuinely continuous.
    """
    ct = clusterer.condensed_tree_
    arr = ct.to_numpy()  # structured array: parent, child, lambda_val, child_size

    n_points = clusterer.labels_.shape[0]

    # child_size > 1 → cluster node; child_size == 1 → individual point falling out.
    # parent_of maps every node (cluster or leaf) to its parent cluster node.
    parent_of: dict[int, int] = {int(row["child"]): int(row["parent"]) for row in arr}

    # lambda_birth of a cluster node = the lambda at which it first appears,
    # which is the lambda_val on the row where it is the `child`. The synthetic
    # root never appears as a `child` so it has no birth row — give it lambda 0.
    lambda_birth: dict[int, float] = {}
    for row in arr:
        child = int(row["child"])
        if int(row["child_size"]) > 1:
            lambda_birth[child] = float(row["lambda_val"])

    # For each leaf point (child_size == 1, child < n_points), walk the parent
    # chain and record the leaf id under every cluster ancestor.
    leaf_cluster_membership: dict[int, list[int]] = {}
    for row in arr:
        if int(row["child_size"]) != 1:
            continue
        leaf_id = int(row["child"])
        if leaf_id >= n_points:
            continue
        node = int(row["parent"])
        seen = set()
        while node not in seen:
            leaf_cluster_membership.setdefault(node, []).append(leaf_id)
            seen.add(node)
            if node not in parent_of:
                break
            node = parent_of[node]

    rows = []
    for cnode_id, leaves in leaf_cluster_membership.items():
        lam = lambda_birth.get(cnode_id, 0.0)
        size = len(leaves)
        stability_proxy = lam * size  # EOM-like score
        rows.append((cnode_id, lam, size, stability_proxy, leaves))
    rows.sort(key=lambda r: -r[3])

    lines = []
    lines.append("# Condensed-tree evidence — eom default fit (mcs=5, ms=2)\n")
    lines.append(f"- N = **{n_points}**, fit on the same post-fix whitened+UMAP@{N_COMPONENTS}D embedding the sweep uses")
    lines.append("- Each row is a node in the condensed cluster hierarchy with ≥ 2 descendant leaves")
    lines.append("- λ_birth = density level at which the cluster appears; stability proxy ≈ λ_birth × size")
    lines.append("- Top of the list = candidates EOM is most likely to pick. If only the recipe candidate has high stability, the residual blob has no internal density structure HDBSCAN can latch onto.")
    lines.append("")
    for cnode_id, lam, size, stab, leaves in rows[:30]:
        titles_in = sorted({titles[i] for i in leaves}, key=str.lower)
        lines.append(f"## node {cnode_id} — size {size}, λ_birth = {lam:.4f}, stability ≈ {stab:.2f}")
        for t in titles_in:
            lines.append(f"- {t}")
        lines.append("")
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
    print(f"loaded N={n}, D={d}")

    Xw, keep = whiten(X)
    if Xw is None:
        sys.exit("whitening degenerate")
    print(f"whitening keep={keep}")

    print(f"fitting UMAP @ {N_COMPONENTS}D once...")
    reducer = umap.UMAP(**UMAP_KWARGS)
    embedding = reducer.fit_transform(Xw)

    configs = []
    for method in ("eom", "leaf"):
        for mcs in (2, 3, 4, 5):
            for ms in (1, 2):
                r = sweep_one(embedding, method, mcs, ms, 0.0)
                configs.append(r)
                print(f"  {method} mcs={mcs} ms={ms} eps=0.00 → {r['n_clusters']} clusters, {r['n_noise']}/{r['n_total']} noise")

    # Targeted epsilon follow-up on the leaf config most likely to over-split
    # (mcs=2, ms=1, eom and leaf). Only run if leaf over-split → many clusters.
    leaf_min = [r for r in configs if r["method"] == "leaf" and r["mcs"] == 2 and r["ms"] == 1][0]
    if leaf_min["n_clusters"] >= 8:
        for eps in (0.05, 0.10, 0.20, 0.40):
            r = sweep_one(embedding, "leaf", 2, 1, eps)
            configs.append(r)
            print(f"  leaf mcs=2 ms=1 eps={eps:.2f} → {r['n_clusters']} clusters, {r['n_noise']}/{r['n_total']} noise")

    # Write the sweep results
    sweep_path = RESULTS / "cluster_cut_sweep.md"
    write_sweep_md(titles, paths, configs, sweep_path, keep, n)
    print(f"  wrote {sweep_path}")

    # Condensed tree on the shipped default config
    print("extracting condensed tree from eom mcs=5 ms=2 fit...")
    clusterer_default = hdbscan.HDBSCAN(
        min_cluster_size=5,
        min_samples=2,
        cluster_selection_method="eom",
        metric="euclidean",
    )
    clusterer_default.fit(embedding)
    ct_path = RESULTS / "condensed_tree.md"
    write_condensed_tree_md(clusterer_default, titles, ct_path)
    print(f"  wrote {ct_path}")

    json_path = RESULTS / "cluster_cut_sweep.json"
    json.dump({
        "nPoints": n,
        "whiteningKeep": keep,
        "nComponents": N_COMPONENTS,
        "umapSeed": UMAP_SEED,
        "configs": configs,
        "titles": titles,
        "selectionPaths": paths,
    }, open(json_path, "w"))
    print(f"  wrote {json_path}")
    print("done.")


if __name__ == "__main__":
    main()
