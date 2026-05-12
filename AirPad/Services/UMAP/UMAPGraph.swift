import Foundation

// SB139 Stage 4a step 2 — exact k-nearest-neighbors graph for UMAP.
//
// Brute-force Euclidean k-NN over the training set. At AirPad's corpus
// size (~200 nodes, 512-dim) this is O(N²·D) ≈ 20M float ops — under
// 100ms on a modern iPhone. The simpler algorithm is also exact, matching
// umappp's VpTree output bit-for-bit when no exact ties are present.
//
// **Numerical contract** with the C++ reference: accumulate squared
// differences as Double in a serial loop, then take sqrt. This is the
// canonical Euclidean implementation knncolle uses; deviating (e.g.,
// `||a-b||² = ||a||² - 2a·b + ||b||²` or SIMD-reduction with reassociation)
// can introduce ULP-level drift that snowballs through downstream steps.
// Tiebreak by ascending neighbor index when two distances are exactly
// equal. Validated by `UMAPSelfTest.testKnn*` against the C++ harness
// `--dump-intermediates` output.

/// One edge in the k-NN graph. `to` is the destination node's index in
/// the training set (0-based); `distance` is the raw Euclidean distance.
/// Reciprocal of the convention "weight" used after the fuzzy-simplicial
/// transformation lands in step 3.
struct UMAPKnnEdge: Hashable {
    var to: Int
    var distance: Double
}

/// Compute the exact k-NN graph for `vectors`. Returns an array of length
/// `vectors.count`; each inner array is the `k` nearest neighbors of that
/// row, sorted ascending by distance (with index-ascending tiebreak).
///
/// Precondition: every row in `vectors` has the same length and
/// `vectors.count > k`.
func computeKnnGraph(
    vectors: [[Float]],
    k: Int
) -> [[UMAPKnnEdge]] {
    precondition(k >= 1, "k must be ≥ 1")
    precondition(vectors.count > k, "vector count must exceed k")

    let n = vectors.count
    let dim = vectors[0].count
    // Pre-convert to Double once so the inner loop doesn't pay the
    // Float→Double conversion N² times. The accumulation must be Double
    // to match the C++ side's `Float_=double` parameterization.
    let v: [[Double]] = vectors.map { row in
        precondition(row.count == dim, "ragged input vectors")
        return row.map(Double.init)
    }

    var graph = [[UMAPKnnEdge]](repeating: [], count: n)
    var pairs: [(to: Int, dist: Double)] = []
    pairs.reserveCapacity(n - 1)

    for i in 0..<n {
        pairs.removeAll(keepingCapacity: true)
        let vi = v[i]
        for j in 0..<n where j != i {
            let vj = v[j]
            var acc: Double = 0
            for d in 0..<dim {
                let diff = vi[d] - vj[d]
                acc += diff * diff
            }
            pairs.append((to: j, dist: acc.squareRoot()))
        }
        // Sort by (distance ASC, index ASC). Swift's `sort` is not
        // guaranteed stable in stdlib pre-5.0; we make the tiebreak
        // explicit so behavior is deterministic.
        pairs.sort { lhs, rhs in
            if lhs.dist != rhs.dist { return lhs.dist < rhs.dist }
            return lhs.to < rhs.to
        }
        graph[i] = pairs.prefix(k).map { UMAPKnnEdge(to: $0.to, distance: $0.dist) }
    }
    return graph
}
