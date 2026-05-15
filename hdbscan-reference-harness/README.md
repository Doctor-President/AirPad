# HDBSCAN reference harness — `hdbscan-reference-harness`

Permanent diagnostic infrastructure for AirPad's HDBSCAN port (SB139
Stage 4b). Sibling to `umap-reference-harness/`. The hand-rolled Swift
HDBSCAN in `AirPad/Services/UMAP/HDBSCAN/` (lands across 4b.1–4b.4) is
validated against `hdbscan` (the canonical McInnes/HealyJ Python
package) end-to-end and per-step using fixtures and outputs co-located
in this directory. Re-runnable any time a clustering question comes up
post-ship.

## Why it exists

HDBSCAN's algorithmic phases — mutual reachability, MST, condensed
tree, cluster selection — each have load-bearing tie-breakers and
hyperparameter contracts where a small Swift port deviation can change
cluster labels silently. This harness is the spec.

Unlike the UMAP harness (C++ port via CMake + libscran/umappp), the
HDBSCAN reference runs the Python `hdbscan` package directly — there's
no C++ porting target, the Python package *is* the reference
implementation. Setup is a venv, not a CMake build.

## Setup

One-time:

```sh
./scripts/setup_venv.sh
```

This creates `venv/` (gitignored), installs `hdbscan`, `numpy`,
`scipy`, `scikit-learn`, and `cython` build deps if not already
present, then verifies import.

## Regenerating fixtures

Synthetic fixtures live in `fixtures/`:

- `synth_planted4_2d.json` — 4 planted clusters of ≈50 points each in
  2D (n=200). Mirrors the post-UMAP geometry that AirPad's Stage 4b
  consumes — 2D coordinates, well-separated centroids, modest noise.

Committed. To regenerate deterministically:

```sh
source venv/bin/activate
python3 fixtures/generate_synthetic.py
```

The corpus snapshot (`fixtures/corpus_post_umap_filtered.json`) is
gitignored; regenerate it from the live AirPad corpus by exporting
UMAP coords via the dev inspect view's Stage 4b section (the affordance
added in 4b.0; export script lands at 4b.1 alongside parity scripts).

## Invocation

```sh
source venv/bin/activate
python3 scripts/hdbscan_reference.py fit \
    --input fixtures/synth_planted4_2d.json \
    --output results/synth_planted4_2d.hdbscan.json
```

Output JSON files land under `results/` (gitignored).

## Wire format — what gets diffed

Both the Python reference and the Swift `HDBSCAN.fit` (lands across
4b.1–4b.4) produce JSON files with the **same schema and key names**.
Field-level numerical diff is the test.

### Input (both sides read this)

```json
{
  "hyperparameters": {
    "min_cluster_size": 8,
    "min_samples": null,
    "cluster_selection_method": "eom",
    "cluster_selection_epsilon": 0.0,
    "allow_single_cluster": false
  },
  "algorithmPath": "generic",
  "matchReferenceImplementation": false,
  "inputDimension": 2,
  "points": [
    { "nodeID": "c0_p0", "coord": [0.13, -0.42] },
    ...
  ]
}
```

### Output (cluster labels + probabilities)

```json
{
  "fitterVersion": "hdbscan-<pkg-version>",
  "hyperparameters": { ...echoed... },
  "algorithmPath": "generic",
  "points": [
    {
      "nodeID": "c0_p0",
      "clusterLabel": 0,
      "probability": 0.87,
      "outlierScore": 0.12
    },
    ...
  ]
}
```

`clusterLabel == -1` denotes noise.

## Pinned configuration

Two hyperparameters are pinned at the harness CLI and at the Swift
service boundary; deviations from these surface immediately because
the JSON echoes them.

- **`algorithm='generic'`** — NOT `'best'`. `'best'` dispatches to
  Boruvka with an approximate MST at low input dimension, which would
  introduce a structural divergence the Swift port can't follow
  without an entirely separate MST implementation. Generic uses
  classical Prim's, which is what the Swift port mirrors.
- **`match_reference_implementation=False`** — pinned `False` because
  `True` enables a legacy path that does not match the publication
  semantics and is documented as for-compat-only. We match the
  *current* algorithm.

See `decisions.md` for the full rationale.

## What this harness deliberately does NOT do (yet)

- It does not invoke the Swift side — that's a separate Xcode SwiftPM
  self-test driven from the HDBSCAN module's `HDBSCANSelfTest.swift`
  (lands at 4b.1+).
- It does not compare outputs — that's a third script. Parity scripts
  (`scripts/swift_*_parity.swift` mirroring umap-reference-harness)
  land at 4b.1+.
- It does not yet snapshot real-corpus coords — that needs the dev
  inspect view's export-coords affordance, which the 4b.0 section
  adds. Export script lands at 4b.1.

4b.0 scope: the scaffolding above and nothing more.
