import Foundation

// SB139 Stage 4b.1 — mutual reachability.
//
// Reference port: `hdbscan/_hdbscan_reachability.pyx::mutual_reachability`
// (Python hdbscan v0.8.42, dense path). Three substance lines in the
// upstream source:
//
//     core_distances = np.partition(distance_matrix, min_points, axis=0)[min_points]
//     stage1 = np.where(core_distances > distance_matrix, core_distances, distance_matrix)
//     result = np.where(core_distances > stage1.T, core_distances.T, stage1.T).T
//
// The two np.where lines collapse algebraically to
//     mr[i, j] = max(core[i], core[j], distance[i, j] / alpha).
// The matrix is symmetric; the diagonal is the core distance per point.
//
// Bit-exactness target. The only operations are subtraction, multiplication
// (squaring), summation, sqrt, and max. All are bit-exact in IEEE 754
// when the summation order matches the reference. We match
// `scipy.spatial.distance.cdist(metric='minkowski', p=2)` — the
// dispatch target of `sklearn.metrics.pairwise_distances(metric='minkowski', p=2)`,
// which is what `_hdbscan_generic` invokes at the orchestrator level.
// scipy's cdist sums along ascending k via a C loop; we mirror that.
//
// Validated against `hdbscan-reference-harness/scripts/swift_mutual_reachability_parity.swift`.

@available(iOS 17.0, *)
extension HDBSCAN {

    /// Compute the pairwise Euclidean distance matrix.
    ///
    /// Direct formulation: `d[i, j] = sqrt(sum_k (x[i, k] - x[j, k])^2)`.
    /// Mirrors `scipy.spatial.distance.cdist(X, X, metric='minkowski', p=2)`.
    /// Sums along ascending k (the dimension axis) to match scipy's C loop.
    ///
    /// - Parameter coords: n × d coordinates. d must be uniform across rows.
    /// - Returns: n × n symmetric matrix with zero diagonal.
    static func pairwiseEuclideanDistance(_ coords: [[Double]]) -> [[Double]] {
        let n = coords.count
        if n == 0 { return [] }
        let d = coords[0].count
        var result = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            let xi = coords[i]
            for j in (i + 1)..<n {
                let xj = coords[j]
                var sum = 0.0
                for k in 0..<d {
                    let diff = xi[k] - xj[k]
                    sum += diff * diff
                }
                let dist = sum.squareRoot()
                result[i][j] = dist
                result[j][i] = dist
            }
        }
        return result
    }

    /// Per-point core distance: distance from each point to its
    /// `minPoints`-th nearest other point.
    ///
    /// Mirrors `np.partition(distance_matrix, min_points, axis=0)[min_points]`.
    /// The self-distance 0 occupies index 0 of each sorted column, so
    /// index `[minPoints]` selects the `minPoints`-th nearest *other* point.
    ///
    /// Implementation uses a full sort per column rather than
    /// np.partition's partial selection. The kth value is identical
    /// regardless (and ties are value-equal, not identity-equal); n is
    /// small enough that O(n log n) per column is irrelevant for AirPad.
    ///
    /// - Parameters:
    ///   - distanceMatrix: n × n symmetric, zero diagonal.
    ///   - minPoints: column index after sort; caller is responsible for
    ///     clamping (orchestrator applies `min(n - 1, raw)` upstream).
    static func coreDistances(distanceMatrix: [[Double]], minPoints: Int) -> [Double] {
        let n = distanceMatrix.count
        precondition(n > 0, "HDBSCAN.coreDistances: empty distance matrix")
        precondition(minPoints >= 0 && minPoints < n,
                     "HDBSCAN.coreDistances: minPoints=\(minPoints) out of range for n=\(n)")
        var result = [Double](repeating: 0, count: n)
        var column = [Double](repeating: 0, count: n)
        for j in 0..<n {
            for i in 0..<n {
                column[i] = distanceMatrix[i][j]
            }
            column.sort()
            result[j] = column[minPoints]
        }
        return result
    }

    /// Mutual reachability matrix.
    ///
    /// `mr[i, j] = max(core[i], core[j], distance[i, j] / alpha)`.
    /// Symmetric; diagonal equals core distance per point.
    ///
    /// Mirrors `mutual_reachability(distance_matrix, min_points, alpha)`.
    /// Applies the upstream clamp `min_points = min(n - 1, raw)` so
    /// callers can pass through whatever the orchestrator hands them.
    ///
    /// - Parameters:
    ///   - distanceMatrix: n × n symmetric, zero diagonal.
    ///   - minPoints: pre-clamp; this function applies `min(n - 1, raw)`.
    ///   - alpha: distance divisor; 1.0 is the pin and the upstream default.
    static func mutualReachability(
        distanceMatrix: [[Double]],
        minPoints rawMinPoints: Int,
        alpha: Double = 1.0
    ) -> [[Double]] {
        let n = distanceMatrix.count
        precondition(n > 0, "HDBSCAN.mutualReachability: empty distance matrix")
        let minPoints = min(n - 1, rawMinPoints)
        let core = coreDistances(distanceMatrix: distanceMatrix, minPoints: minPoints)
        var result = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        let applyAlpha = (alpha != 1.0)
        for i in 0..<n {
            let ci = core[i]
            for j in 0..<n {
                let d = applyAlpha ? distanceMatrix[i][j] / alpha : distanceMatrix[i][j]
                var m = ci
                let cj = core[j]
                if cj > m { m = cj }
                if d > m { m = d }
                result[i][j] = m
            }
        }
        return result
    }
}
