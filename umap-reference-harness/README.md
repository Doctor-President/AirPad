# UMAP reference harness — `umap-reference-harness`

Permanent diagnostic infrastructure for AirPad's UMAP implementation (SB139
Stage 4a). The hand-rolled Swift UMAP in `AirPad/Services/UMAP/` is
validated against `libscran/umappp` end-to-end and per-step using fixtures
and outputs co-located in this directory. Re-runnable any time a substrate
question comes up post-ship.

## Why it exists

UMAP's numerically subtle pieces (smooth k-NN sigma binary search, fuzzy
simplicial set construction, SGD with negative sampling) make end-to-end
diff-against-spec the only reliable safety net. This harness is the spec.

## Building

One-time setup:

```sh
brew install cmake          # if not already installed
```

Configure + build (pulls umappp v3.3.2 + nlohmann/json v3.11.3 + their
transitive deps via CMake FetchContent on first run; ~5 min cold, instant
on rebuild):

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8
```

Produces `build/umappp-reference`.

## Regenerating fixtures

Two synthetic fixtures live in `fixtures/`:

- `synth_50x4.json` — 4 planted clusters of 13 points in 4D (52 total).
  Useful for eyeball-checking first results.
- `synth_200x16.json` — 8 clusters of 25 points in 16D (200 total). Closer
  to AirPad's real corpus geometry.

Both are committed. To regenerate them deterministically:

```sh
python3 fixtures/generate_synthetic.py
```

Requires `numpy`. The corpus snapshot (`fixtures/corpus_snapshot.json`) is
gitignored; regenerate it from the live AirPad corpus when needed.

## Invocation

```sh
./build/umappp-reference fit \
    --input fixtures/synth_50x4.json \
    --output results/synth_50x4.umappp.json \
    --dump-intermediates results/synth_50x4.intermediates.json
```

Output JSON files land under `results/` (gitignored).

## Wire format — what gets diffed

Both the C++ binary and the Swift `UMAP.fit` produce JSON files with the
**same schema and key names**. Field-level numerical diff is the test.

### Input (both sides read this)

```json
{
  "hyperparameters": {
    "nComponents": 2,
    "nNeighbors": 15,
    "minDist": 0.1,
    "spread": 1.0,
    "learningRate": 1.0,
    "negativeSampleRate": 5.0,
    "nEpochs": null,
    "mixRatio": 1.0,
    "localConnectivity": 1.0,
    "bandwidth": 1.0
  },
  "rngSeed": 42,
  "inputDimension": 4,
  "trainingPoints": [
    { "nodeID": "c0_p0", "inputVector": [4.97, 0.01, -0.13, 0.06] },
    ...
  ]
}
```

### Output (final 2D coords)

```json
{
  "fitterVersion": "umappp-3.3.2",
  "hyperparameters": { ...echoed... },
  "rngSeed": 42,
  "trainingPoints": [
    { "nodeID": "c0_p0", "coord2D": { "x": 1.23, "y": -0.45 } },
    ...
  ]
}
```

### Intermediates (per-step bisection)

```json
{
  "fitterVersion": "umappp-3.3.2",
  "knnGraph": [
    [ { "to": 17, "distance": 0.13 }, ... ],   // row i = neighbors of node i
    ...
  ],
  "fuzzySimplicialSet": [
    [ { "to": 17, "weight": 0.87 }, ... ],     // after symmetrization
    ...
  ],
  "initialEmbedding": [
    { "nodeID": "c0_p0", "coord2D": { "x": 0.01, "y": -0.02 } },
    ...
  ]
}
```

## Seed expansion — keeping C++ and Swift in lockstep

The JSON `rngSeed` is a scalar `uint64`. Both sides expand it via SplitMix64
(Vigna's standard) in **documented order**:

1. `state := rngSeed`
2. `initialize_seed := splitmix64(&state)` — goes into umappp's
   `Options.initialize_seed` (C++) and the Swift spectral-init RNG.
3. `optimize_seed := splitmix64(&state)` — goes into umappp's
   `Options.optimize_seed` (C++) and the Swift SGD `xoshiro256**` state
   vector (further-expanded into 4 words via three more SplitMix64 calls
   to fill `s[0..3]`).

SplitMix64 step:

```c
state += 0x9E3779B97F4A7C15;
z = state;
z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
return z ^ (z >> 31);
```

C++ implementation: `SplitMix64` class in `src/json_io.{h,cpp}`.
Swift implementation: `UMAPRandom.swift` (Stage 4a step 1).

## Validating the Swift implementation

After running both sides on the same fixture, diff per file. Tolerance is
field-specific — k-NN graph distances should agree to 1e-12; fuzzy SS
weights to ~1e-9 (transcendental ops accumulate FP error); final coords to
a few units of last-place (SGD with the same seed and integer arithmetic
ordering is mostly bit-identical but spectral init via irlba uses LAPACK
which may differ between Apple Accelerate and Eigen — surface that
divergence here when it appears).

## What this harness deliberately does NOT do

- It does not embed `corpus_snapshot.json` — that's regenerated from the
  live AirPad iCloud corpus by a sibling script (TODO when corpus
  snapshotting actually ships in Stage 4 dev inspect view extensions).
- It does not invoke the Swift side — that's a separate Xcode SwiftPM
  self-test driven from `SubstrateSelfTest.swift`.
- It does not compare outputs — that's a third script. The harness
  produces JSON; the comparison is mechanical and separate.
