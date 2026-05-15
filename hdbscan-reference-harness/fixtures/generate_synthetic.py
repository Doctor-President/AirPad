#!/usr/bin/env python3
"""Generate the committed synthetic 2D fixture deterministically.

Output: `fixtures/synth_planted4_2d.json` — 4 planted Gaussian clusters
of 50 points each in 2D (n=200), well-separated centroids on a square,
modest isotropic noise. Mirrors AirPad's post-UMAP geometry: 2D, low
ambient dim, identifiable cluster structure with some boundary noise.

Deterministic via NumPy's `default_rng(seed=42)`. Re-running this script
overwrites the fixture; commit the result for parity.

Usage (from harness root, with venv active):
    python3 fixtures/generate_synthetic.py
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np


SEED = 42
N_PER_CLUSTER = 50
N_CLUSTERS = 4
NOISE_STDEV = 0.35

# Centroids on a square. Spacing chosen so cluster separation is comfortably
# above 3*sigma — each cluster reads as its own region post-density-estimation.
CENTROIDS = np.array(
    [
        [-3.0, -3.0],
        [+3.0, -3.0],
        [-3.0, +3.0],
        [+3.0, +3.0],
    ],
    dtype=np.float64,
)


def generate() -> dict:
    rng = np.random.default_rng(SEED)
    points = []
    for ci in range(N_CLUSTERS):
        centroid = CENTROIDS[ci]
        for pi in range(N_PER_CLUSTER):
            offset = rng.normal(loc=0.0, scale=NOISE_STDEV, size=2)
            coord = centroid + offset
            points.append(
                {
                    "nodeID": f"c{ci}_p{pi}",
                    "coord": [float(coord[0]), float(coord[1])],
                }
            )

    return {
        "hyperparameters": {
            "min_cluster_size": 8,
            "min_samples": None,
            "cluster_selection_method": "eom",
            "cluster_selection_epsilon": 0.0,
            "allow_single_cluster": False,
        },
        "algorithmPath": "generic",
        "matchReferenceImplementation": False,
        "inputDimension": 2,
        "points": points,
    }


def main() -> None:
    out = Path(__file__).resolve().parent / "synth_planted4_2d.json"
    payload = generate()
    with out.open("w") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
    print(f"wrote {out} ({len(payload['points'])} points, "
          f"{N_CLUSTERS} planted clusters, seed={SEED})")


if __name__ == "__main__":
    main()
