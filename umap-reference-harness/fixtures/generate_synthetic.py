#!/usr/bin/env python3
# SB139 Stage 4a — UMAP reference harness fixture generator.
#
# Produces synthetic JSON fixtures used by both the C++ reference and the
# Swift implementation. Deterministic from numpy seed 42. Commit the JSON
# outputs alongside this script so the harness re-runs without Python in
# the loop — Python is only needed when fixtures are regenerated.

import json
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def make_cluster_input(n_per_cluster, n_clusters, dim, cluster_sep, jitter, seed):
    """Plant `n_clusters` clusters in `dim`-D, each `n_per_cluster` points
    with `jitter` standard deviation around a center at `cluster_sep` along
    one axis. Returns (nodeIDs, vectors)."""
    rng = np.random.default_rng(seed)
    centers = np.zeros((n_clusters, dim))
    for k in range(n_clusters):
        centers[k, k % dim] = cluster_sep * (1 + k // dim)
    pts = []
    ids = []
    for k in range(n_clusters):
        for j in range(n_per_cluster):
            pts.append(centers[k] + rng.normal(0, jitter, size=dim))
            ids.append(f"c{k}_p{j}")
    return ids, np.array(pts)


def write_fixture(path, ids, vectors, rng_seed=42, hyperparameters=None):
    if hyperparameters is None:
        hyperparameters = {
            "nComponents": 2,
            "nNeighbors": 15,
            "minDist": 0.1,
            "spread": 1.0,
            "learningRate": 1.0,
            "negativeSampleRate": 5.0,
            "nEpochs": None,
            "mixRatio": 1.0,
            "localConnectivity": 1.0,
            "bandwidth": 1.0,
        }
    payload = {
        "hyperparameters": hyperparameters,
        "rngSeed": rng_seed,
        "inputDimension": int(vectors.shape[1]),
        "trainingPoints": [
            {"nodeID": ids[i], "inputVector": [float(v) for v in vectors[i]]}
            for i in range(len(ids))
        ],
    }
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"wrote {path}  ({len(ids)} points, dim={vectors.shape[1]})")


def main():
    # synth_50x4: 4 clusters of 12-13 points in 4D (~50 total),
    # well-separated, small jitter. UMAP should produce visually distinct
    # clusters; useful for eyeballing first-cut results.
    ids, vectors = make_cluster_input(
        n_per_cluster=13, n_clusters=4, dim=4,
        cluster_sep=5.0, jitter=0.3, seed=42,
    )
    write_fixture(os.path.join(HERE, "synth_50x4.json"), ids, vectors)

    # synth_200x16: 8 clusters of 25 points in 16D, larger jitter so
    # cluster boundaries are softer. Closer to "real corpus" geometry.
    ids, vectors = make_cluster_input(
        n_per_cluster=25, n_clusters=8, dim=16,
        cluster_sep=3.0, jitter=0.6, seed=4242,
    )
    write_fixture(os.path.join(HERE, "synth_200x16.json"), ids, vectors)


if __name__ == "__main__":
    main()
