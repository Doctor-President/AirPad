# clustering-dimensionality-diagnostic

Diagnostic extension to `umap-reference-harness`. Answers the brief at
`~/Desktop/Ops/briefs/clustering-dimensionality-diagnostic.md` — does AirPad's
wrong-membership scattering come from the 2D UMAP collapse (fixable pipeline
bug) or from NLContextualEmbedding's compressed geometry (embedder bug)?

Python-only — bit-exactness vs the shipped Swift pipeline doesn't matter for a
go/no-go diagnostic. The C++ harness has no HDBSCAN integration and adding one
would cost more than it returns here.

## Re-running

```sh
# one-time
python3.13 -m venv .venv
.venv/bin/pip install numpy scikit-learn umap-learn hdbscan

# every time the corpus changes substantively
.venv/bin/python scripts/01_export_corpus.py    # → fixtures/corpus_snapshot.json
.venv/bin/python scripts/02_run_diagnostic.py   # → results/neighbors.md, sweep.md
.venv/bin/python scripts/03_controls.py         # → results/neighbors_raw.md, sweep_raw.md, whitening_sweep.md
.venv/bin/python scripts/04_verdict.py          # → results/verdict.md
```

`fixtures/corpus_snapshot.json` and everything under `results/` are gitignored
(same pattern as the parent harness).

## What lives where

- `scripts/01_export_corpus.py` — reads
  `~/Library/Mobile Documents/iCloud~com~doctorpresident~airpad/Documents/nodes/*/`
  and produces a snapshot that mirrors `SubstrateLayoutService.substrateVector(for:)`
  + the fit-time `isRankable && !isMeta` filter exactly. Block-pooled vector
  takes precedence over summary+folksonomy, matching SB139 Stage 4c2.
- `scripts/02_run_diagnostic.py` — the brief's diagnostic A (whitened-space
  cosine neighbors) + diagnostic B (whitening → UMAP @ {2,5,8,10,15}D →
  HDBSCAN(5,2)). Whitening mirrors `SubstrateWhitening.fit` exactly (centered
  SVD, σ_max × 1e-6 cutoff, W = V[:,:keep] / σ[:keep]).
- `scripts/03_controls.py` — controls the brief didn't ask for but the
  primary results needed:
  - **A0**: raw (pre-whitening) cosine top-10 neighbors. What the embedder
    itself produces.
  - **B0**: UMAP @ {2,5,8,10,15} + HDBSCAN on **raw** vectors (no whitening,
    cosine metric). Apples-to-apples dim sweep.
  - **A1**: cosine geometry at whitening cutoffs `keep ∈ {5, 10, 20, 50, 119}`.
    Reveals the rank-saturation in the shipped 119 setting.
- `scripts/04_verdict.py` — reads everything, writes `results/verdict.md`.

## Why the controls were necessary

The primary diagnostic (A as spec'd in the brief) found that **every pairwise
cosine in the whitened space is −1/N ≈ −0.0083**. That's the algebraic
signature of `whitened = U[:, :keep]` when `keep = N − 1` — the shipped 1e-6
relative cutoff is too lax at AirPad's (N=120, D=512) regime, so every
singular component survives and dividing by σ blows up the noise axes to
match the signal axes. UMAP runs on an isotropic point cloud where the k-NN
graph is RNG-driven.

This means the brief's framing (embedder vs 2D collapse) can't distinguish
its two hypotheses, because BOTH branches of the comparison run on the same
degenerate input. The controls (raw + cutoff sweep) restore the measurement.

Verdict in `results/verdict.md`.
