import Foundation

// SB139 Stage 4a step 3 — fuzzy simplicial set construction.
//
// Converts the k-NN distance graph from step 2 into a weighted, symmetric
// adjacency suitable for the SGD optimization in step 4. Two phases mirror
// umappp v3.3.2 exactly:
//
//   Phase 1 (per-row σ binary search):
//     Find σᵢ such that Σⱼ exp(-(distᵢⱼ - ρᵢ)/σᵢ) = log₂(k+1) · bandwidth.
//     ρᵢ is the local_connectivity-th non-zero distance (default: closest
//     non-self neighbor). Convert each row's distances to weights:
//     wᵢⱼ = exp(-(distᵢⱼ - ρᵢ)/σᵢ) when distᵢⱼ > ρᵢ, else 1.0.
//
//   Phase 2 (probabilistic symmetrization):
//     For each unordered (i, j) pair, combine the directed weights
//     wᵢⱼ and wⱼᵢ into a single symmetric weight w̃ᵢⱼ. With mix_ratio=1
//     (the umappp default and our setting): w̃ = wᵢⱼ + wⱼᵢ - wᵢⱼ·wⱼᵢ
//     (probabilistic union). Unilateral edges keep their original weight
//     on both sides.
//
// **Numerical contract** with the C++ reference: this is the first step
// in the pipeline that uses transcendental ops (exp, log2), so per-edge
// agreement degrades from k-NN's sub-ULP to ~1e-9. The σ binary search
// converges within 1e-5 of the target sum, and the final exp() call
// inherits that uncertainty. Validated by `swift_fuzzy_parity.swift` and
// `UMAPSelfTest.testFuzzy*` against `intermediates.json`.
//
// Source pins (umappp v3.3.2):
//   include/umappp/neighbor_similarities.hpp
//   include/umappp/combine_neighbor_sets.hpp

struct UMAPFuzzyEdge: Hashable {
    var to: Int
    var weight: Double
}

struct UMAPFuzzyOptions {
    /// Distance to the `local_connectivity`-th nearest non-identical
    /// neighbor becomes ρᵢ — the cutoff below which edges have weight 1.
    /// Fractional values interpolate between the `floor`-th and
    /// `ceil`-th distances. umappp default: 1.0.
    var localConnectivity: Double = 1.0
    /// Multiplies the σ-search target `log₂(k+1)`. umappp default: 1.0.
    var bandwidth: Double = 1.0
    /// Floor on σ relative to the per-row mean distance, guarding
    /// against degenerate σ→0 when most distances cluster near ρᵢ.
    /// umappp default: 1e-3.
    var minKDistScale: Double = 1e-3
    /// Probabilistic-union weight in [0, 1]. 1.0 = full union (umappp
    /// default and AirPad's setting), 0.0 = product only.
    var mixRatio: Double = 1.0
}

/// Compute per-point fuzzy weights for one row of sorted-ascending
/// distances to a node's k neighbors. Extracted from Phase 1 of
/// `computeFuzzySimplicialSet` so the same σ-search machinery can drive
/// both fit-time fuzzy SS and newcomer transform (step 6).
///
/// Returns a weight row of the same length and order as the input. The σ
/// binary search and smoothed-exponential weight formula mirror umappp
/// `neighbor_similarities.hpp` per-row. Refactoring is non-behavioral —
/// `computeFuzzySimplicialSet` now delegates Phase 1 to this helper,
/// preserving bit-identical output. Validated by T8/T9 + parity scripts.
///
/// Precondition: `sortedDistances` is sorted ascending. The helper
/// tolerates empty input (returns []) for caller convenience; in practice
/// both fit (rows are k≥1) and transform (k from hyperparameters ≥1)
/// pass non-empty rows.
func computeFuzzyRowWeights(
    sortedDistances: [Double],
    options: UMAPFuzzyOptions = .init()
) -> [Double] {
    let numNeighbors = sortedDistances.count
    if numNeighbors == 0 { return [] }

    let rawConnectIndex = Int(options.localConnectivity)
    let interpolation = options.localConnectivity - Double(rawConnectIndex)

    var numZero = 0
    for d in sortedDistances {
        if d != 0 { break }
        numZero += 1
    }

    // If fewer non-zero neighbors than the connect index, ρ is undefined
    // within range. umappp's fallback: all weights = 1.
    if numNeighbors - numZero <= rawConnectIndex {
        return [Double](repeating: 1, count: numNeighbors)
    }

    // ρ = interpolation between distances at (connectIdx-1) and
    // connectIdx (0-based). For local_connectivity=1, interpolation=0,
    // so ρ = distance at index numZero (first non-zero neighbor).
    let connectIndex = numZero + rawConnectIndex
    let lower: Double = connectIndex > 0 ? sortedDistances[connectIndex - 1] : 0
    let upper: Double = sortedDistances[connectIndex]
    let rho = lower + interpolation * (upper - lower)

    var activeDelta: [Double] = []
    var numLeRho = Double(numZero)
    for k in numZero..<numNeighbors {
        let d = sortedDistances[k]
        if d > rho {
            activeDelta.append(d - rho)
        } else {
            numLeRho += 1
        }
    }

    if activeDelta.isEmpty {
        return [Double](repeating: 1, count: numNeighbors)
    }

    var sigma = activeDelta.last!
    var lo: Double = 0
    var hi: Double = .greatestFiniteMagnitude
    let target = Foundation.log2(Double(numNeighbors + 1)) * options.bandwidth

    let maxIter = 64
    let tol = 1e-5
    for _ in 0..<maxIter {
        var observed = numLeRho
        var deriv: Double = 0
        let invSigma = 1 / sigma
        let invSigma2 = invSigma * invSigma
        for d in activeDelta {
            let cur = Foundation.exp(-d * invSigma)
            observed += cur
            deriv += d * cur * invSigma2
        }
        let diff = observed - target
        if abs(diff) < tol { break }

        if diff > 0 { hi = sigma } else { lo = sigma }

        var newtonOK = false
        if deriv != 0 {
            let altSigma = sigma - (diff / deriv)
            if altSigma > lo && altSigma < hi {
                sigma = altSigma
                newtonOK = true
            }
        }
        if !newtonOK {
            if diff > 0 {
                sigma += (lo - sigma) / 2
            } else if hi == .greatestFiniteMagnitude {
                sigma *= 2
            } else {
                sigma += (hi - sigma) / 2
            }
        }
    }

    // Floor σ at a fraction of the mean distance. mean_dist is taken
    // over ALL neighbors (including zero-distance ones), matching
    // umappp's accumulator over `all_neighbors`.
    var meanDist: Double = 0
    for d in sortedDistances { meanDist += d }
    meanDist /= Double(numNeighbors)
    sigma = max(options.minKDistScale * meanDist, sigma)

    let invSigma = 1 / sigma
    var weights = [Double](repeating: 0, count: numNeighbors)
    for k in 0..<numNeighbors {
        let dist = sortedDistances[k]
        if dist > rho {
            weights[k] = Foundation.exp(-(dist - rho) * invSigma)
        } else {
            weights[k] = 1
        }
    }
    return weights
}

/// Construct the fuzzy simplicial set from a k-NN graph. The output is a
/// symmetric weighted neighbor list where each row may have MORE entries
/// than the input row (symmetrization can add back-edges).
///
/// Precondition: each row of `knn` is sorted ascending by distance.
func computeFuzzySimplicialSet(
    knn: [[UMAPKnnEdge]],
    options: UMAPFuzzyOptions = .init()
) -> [[UMAPFuzzyEdge]] {
    let n = knn.count

    // Working representation: same shape as input, but the `weight`
    // field starts as distance and is mutated in place to fuzzy weight,
    // matching the C++ `NeighborList<Index_, Float_>` reuse pattern.
    var directed: [[(to: Int, weight: Double)]] = knn.map { row in
        row.map { (to: $0.to, weight: $0.distance) }
    }

    // --- Phase 1: σ binary search per row ---
    //
    // Delegates to `computeFuzzyRowWeights` so the same machinery drives
    // both this code path and `UMAP.transform` (step 6). Bit-identical to
    // the prior inline loop body — extracted, not rewritten.

    for i in 0..<n {
        let numNeighbors = directed[i].count
        if numNeighbors == 0 { continue }
        let distances = directed[i].map { $0.weight }
        let weights = computeFuzzyRowWeights(sortedDistances: distances, options: options)
        for k in 0..<numNeighbors { directed[i][k].weight = weights[k] }
    }

    // --- Phase 2: probabilistic symmetrization ---
    //
    // We use a dictionary-of-dictionaries to mirror the C++ in-place
    // mutation semantics without the `last[]`/`original[]` bookkeeping
    // (which exists only to keep the C++ implementation O(E) rather than
    // O(E·k) via sorted linear scans — irrelevant at AirPad's scale).

    var w: [[Int: Double]] = directed.map { row in
        var dict: [Int: Double] = [:]
        dict.reserveCapacity(row.count)
        for e in row { dict[e.to] = e.weight }
        return dict
    }

    let mixRatio = options.mixRatio
    for i in 0..<n {
        // Snapshot keys; mutations during this outer iter shouldn't
        // affect what we iterate over. Back-edges added in earlier
        // outer iters DO appear here — they harmlessly hit the
        // bilateral-skip branch (i > j).
        let snapshot = Array(w[i])
        for (j, wij) in snapshot {
            if let wji = w[j][i] {
                // Bilateral — process each unordered pair exactly once.
                if i < j {
                    let product = wij * wji
                    let combined: Double
                    if mixRatio == 1.0 {
                        combined = wij + wji - product
                    } else if mixRatio == 0.0 {
                        combined = product
                    } else {
                        combined = mixRatio * (wij + wji - product) + (1 - mixRatio) * product
                    }
                    w[i][j] = combined
                    w[j][i] = combined
                }
            } else {
                // Unilateral — add back-edge (mix_ratio=1), scale both
                // sides (general mix), or delete (mix_ratio=0).
                if mixRatio == 1.0 {
                    w[j][i] = wij
                } else if mixRatio == 0.0 {
                    w[i][j] = nil
                } else {
                    let scaled = wij * mixRatio
                    w[i][j] = scaled
                    w[j][i] = scaled
                }
            }
        }
    }

    // Final sort by neighbor index. Downstream SGD expects sorted rows.
    var result = [[UMAPFuzzyEdge]](repeating: [], count: n)
    for i in 0..<n {
        var row = w[i].map { UMAPFuzzyEdge(to: $0.key, weight: $0.value) }
        row.sort { $0.to < $1.to }
        result[i] = row
    }
    return result
}
