import Foundation

// SB139 Stage 4a step 6 — newcomer transform.
//
// Project a single new (un-fit) input vector into a saved UMAP embedding
// without re-optimizing the training positions. Standard naive UMAP
// transform: brute-force Euclidean k-NN against the saved training set,
// smoothed-exponential per-point weights via the same σ binary search
// that fit-time fuzzy SS uses (`computeFuzzyRowWeights`), normalize,
// weighted-average the k neighbors' 2D coords.
//
// **Weighting choice (smoothed-exponential vs inverse-distance, decided
// 2026-05-11):** reusing the σ-search machinery keeps newcomer placement
// internally consistent with fit-time topology. In dense clusters σ
// shrinks → fast decay → newcomer pulled toward its single closest match
// rather than averaged into the centroid. In sparse regions σ grows →
// softer averaging across more neighbors. Naïve inverse-distance would
// over-pull newcomers toward dense clusters; smoothed-exponential applies
// the same local-density adaptation UMAP itself uses.
//
// **No C++ reference path.** umappp v3.3.2 ships `Status::run` (SGD) and
// `initialize()` — no `transform`, no `umap.transform`, no newcomer-
// projection API at all. Step 6 has no byte-parity surface against the
// reference harness (confirmed by header survey + grep, 2026-05-11).
// Validation: T14 self-test (transform-then-refit round-trip with
// cluster-adaptive tolerance), not parity scripts.
//
// **Stage 4 design contract:** "New nodes project through the saved
// model — they land at their honest spot without disturbing existing
// positions." Geometric precision concerns (newcomer crowding) are
// handled separately by the canvas-side local force-directed nudge;
// transform's job is the initial honest-spot placement.
//
// **Numerical contract.** Distances + weights computed in Double using
// the same Euclidean accumulator and σ search as fit. Final weighted
// average accumulated in Double, then cast to Float at the
// SubstrateCoord2D boundary — mirrors fit's Double-internals /
// Float-coord precision floor. Inherits libm-drift from fuzzy SS via
// `computeFuzzyRowWeights`; for transform alone (no SGD cascade) drift
// stays sub-ULP and does not affect placement at any meaningful scale.

/// Project a single new input vector through a saved UMAP fitted model.
/// Returns the 2D coord in Double precision; callers cast to Float at
/// the SubstrateCoord2D boundary. Public entry point lives on the
/// `UMAP` enum (`UMAP.transform`); this free function is the heavy-
/// lifting implementation, matching the file split convention used by
/// `umapOptimizeLayout`, `computeKnnGraph`, etc.
///
/// `UMAP.transform` validates `inputVector.count == model.inputDimension`
/// before calling in. No further preconditions: a model that successfully
/// completed `UMAP.fit` already satisfies `trainingPoints.count >
/// hyperparameters.nNeighbors`.
func umapTransform(
    inputVector: [Float],
    through model: UMAPFittedModel
) -> (x: Double, y: Double) {
    let k = model.hyperparameters.nNeighbors

    // Pre-convert query to Double once. Training vectors stay Float in
    // memory and are widened in the inner loop — at AirPad scale
    // (~200 nodes × 512 dim) the inner accumulator dominates cost, not
    // the Float→Double cast. Matches `computeKnnGraph`'s accumulator
    // strategy (Double squared-difference, sqrt at the end) so transform
    // is consistent with fit-time k-NN on identical inputs.
    let q: [Double] = inputVector.map(Double.init)
    let dim = q.count
    let trainingCount = model.trainingPoints.count

    var pairs: [(to: Int, dist: Double)] = []
    pairs.reserveCapacity(trainingCount)
    for j in 0..<trainingCount {
        let tv = model.trainingPoints[j].inputVector
        var acc: Double = 0
        for d in 0..<dim {
            let diff = q[d] - Double(tv[d])
            acc += diff * diff
        }
        pairs.append((to: j, dist: acc.squareRoot()))
    }

    // Sort by (distance ASC, index ASC) — same tiebreak as
    // `computeKnnGraph`, so transform's "find k-NN" stays bit-consistent
    // with fit's "find k-NN" given identical inputs.
    pairs.sort { lhs, rhs in
        if lhs.dist != rhs.dist { return lhs.dist < rhs.dist }
        return lhs.to < rhs.to
    }

    let neighbors = Array(pairs.prefix(k))
    let neighborDists = neighbors.map { $0.dist }

    // Smoothed-exponential weights via the shared σ-search helper.
    // Defaults match what `UMAP.fit` hardcodes at the fit call site
    // (UMAP.swift:82, `UMAPFuzzyOptions()`): local_connectivity=
    // bandwidth=mix_ratio=1.0, min_k_dist_scale=1e-3. Transform must
    // use the same defaults or newcomer placement diverges from
    // fit-time topology.
    let weights = computeFuzzyRowWeights(
        sortedDistances: neighborDists,
        options: UMAPFuzzyOptions()
    )

    // Normalize and weighted-average the k 2D coords. Sum is guaranteed
    // positive by `computeFuzzyRowWeights` invariants (rho-fallback path
    // returns all 1s; smoothed path's exp() output is positive — for
    // numerically reasonable inputs σ is floored to avoid underflow), so
    // no guard for weightSum==0.
    var weightSum: Double = 0
    for w in weights { weightSum += w }

    var x: Double = 0
    var y: Double = 0
    for (idx, neighbor) in neighbors.enumerated() {
        let coord = model.trainingPoints[neighbor.to].coord2D
        let w = weights[idx] / weightSum
        x += w * Double(coord.x)
        y += w * Double(coord.y)
    }
    return (x, y)
}
