import Foundation
import Accelerate

/// SB139 Stage 4c2 — PCA whitening for substrate vectors before UMAP.
///
/// **Why.** BERT-family embedders (NLContextualEmbedding, BGE, E5)
/// compress onto an anisotropic cone in their native 512-dim space.
/// AirPad's measured p10–p90 inter-node cosine spread was 0.095 with
/// summary-anchor pooling and 0.153 with block-anchor pooling (c2) —
/// both well below the ~0.30 separation HDBSCAN needs to break past
/// the 2-cluster ceiling. Whitening re-spheres the empirical
/// distribution: PCA decomposes the centered covariance, then each
/// principal axis is rescaled to unit variance so directions the
/// embedder collapsed get the same downstream weight as directions it
/// preserved. The lever is geometric, not model-quality — see
/// `feedback_nlcontextual_embedding_cluster_ceiling`.
///
/// **Output dim.** Rank-bounded at `min(N-1, D)` where N=training set
/// size and D=embedder dim (512). For AirPad's scale (~30–200 nodes)
/// the output is ~30–200 dims rather than D=512 — every dim is now a
/// real signal axis instead of one of the ~50 effective dims that
/// dominated raw cosine. Smaller-but-flatter beats large-but-skewed
/// for downstream k-NN.
///
/// **Persistence.** Caller (`SubstrateLayoutService`) carries the
/// fitted `Transform` on `UMAPFittedModel` (v3) so the same μ + W get
/// applied to new-node projections via `UMAP.transform`. Without
/// persistence, a newcomer would land in raw-space and `UMAP.transform`
/// would compare it against whitened training vectors — silent
/// corruption.
///
/// **Numerics.** SVD runs in Double via LAPACK `dgesvd_` for stability;
/// the persisted matrix is cast back to Float at storage (same precision
/// floor `UMAPFittedModel.trainingPoints[*].coordND` already accepts).
@available(iOS 17.0, *)
enum SubstrateWhitening {

    struct Transform {
        /// D-dim mean of the training set. Subtracted from every input
        /// before the matrix multiply.
        var mean: [Float]
        /// D × K whitening matrix `V · diag(1/s)` from the centered SVD.
        /// Stored row-major as `[D rows][K cols]` to match the per-row
        /// inner loop in `apply`. Applied via `(x - μ) · matrix` →
        /// K-dim output.
        var matrix: [[Float]]
        /// Whitened output dimensionality. Matches `matrix[0].count` and
        /// is what UMAP sees as its input dim post-whitening.
        var outputDim: Int { matrix.first?.count ?? 0 }
    }

    /// Singular-value floor relative to the largest singular value.
    /// Components below this are effectively zero variance — keeping
    /// them would multiply by 1/(tiny σ) and amplify numerical noise.
    /// Matches numpy.linalg.pinv's default rcond.
    private static let singularValueRelativeFloor: Double = 1e-6

    /// Fit PCA whitening to a training set of N D-dim vectors. Returns
    /// nil for degenerate inputs (N<2, D==0, dim mismatch, or all-zero
    /// singular values). Callers fall back to the raw-input UMAP path
    /// on nil — preserves pre-whitening behavior for tiny corpora.
    static func fit(vectors: [[Float]]) -> Transform? {
        let n = vectors.count
        guard n >= 2, let d = vectors.first?.count, d > 0 else { return nil }
        for v in vectors where v.count != d { return nil }

        // 1. Mean (D-dim).
        var mean = [Float](repeating: 0, count: d)
        for v in vectors {
            for i in 0..<d { mean[i] += v[i] }
        }
        let invN = Float(1) / Float(n)
        for i in 0..<d { mean[i] *= invN }

        // 2. Centered matrix X̃ in Double. Stored row-major (row i =
        //    vector i minus mean), which is byte-identical to a
        //    column-major (D × N) buffer — we hand LAPACK the same
        //    pointer and tell it the matrix is D × N, so it sees X̃ᵀ
        //    and computes X̃ᵀ = U_lap S V_lapᵀ. From X̃ᵀ = V S Uᵀ we
        //    get V_lap == V (right singular vectors of X̃), which is
        //    exactly what whitening needs.
        var xTilde = [Double](repeating: 0, count: n * d)
        for (row, v) in vectors.enumerated() {
            for col in 0..<d {
                xTilde[row * d + col] = Double(v[col] - mean[col])
            }
        }

        guard let (vColMajor, singulars) = lapackSVD(matrix: &xTilde, rows: d, cols: n) else {
            return nil
        }
        let maxSV = singulars.first ?? 0
        guard maxSV > 0 else { return nil }
        let cutoff = maxSV * singularValueRelativeFloor
        let keep = singulars.firstIndex(where: { $0 <= cutoff }) ?? singulars.count
        guard keep > 0 else { return nil }

        // 3. W = V[:, :keep] · diag(1/s[:keep]). V comes back column-
        //    major from LAPACK (D rows × keep cols, stride = D); we
        //    repack to row-major `[D][keep]` Float here so apply() can
        //    iterate D in the outer loop with cache-friendly K-dim row
        //    access in the inner loop.
        var matrix: [[Float]] = Array(
            repeating: [Float](repeating: 0, count: keep),
            count: d
        )
        for col in 0..<keep {
            let invS = Float(1.0 / singulars[col])
            for row in 0..<d {
                matrix[row][col] = Float(vColMajor[col * d + row]) * invS
            }
        }

        return Transform(mean: mean, matrix: matrix)
    }

    /// Apply a fitted transform to a single vector. Output dim equals
    /// `transform.outputDim`. Vector dimension must match the dim used
    /// at fit time — mismatch is a service-internal contract violation
    /// and triggers a precondition (caller boundary, not user boundary).
    static func apply(vector: [Float], transform: Transform) -> [Float] {
        let d = transform.mean.count
        precondition(vector.count == d,
                     "SubstrateWhitening.apply: vector dim \(vector.count) != fit dim \(d)")
        let k = transform.outputDim
        guard k > 0 else { return [] }
        var out = [Float](repeating: 0, count: k)
        for i in 0..<d {
            let centered = vector[i] - transform.mean[i]
            let row = transform.matrix[i]
            for j in 0..<k { out[j] += centered * row[j] }
        }
        return out
    }

    // MARK: - LAPACK adapter

    /// Wrap `dgesvd_` with `jobu='S'`, `jobvt='N'`. Returns the first
    /// `min(M,N)` columns of U in column-major layout plus the singular
    /// values in descending order. Returns nil on LAPACK error (`info != 0`).
    ///
    /// The input buffer is overwritten by LAPACK (standard convention) —
    /// caller passes `&` and treats the buffer as consumed.
    ///
    /// Uses the legacy Fortran-style `dgesvd_` symbol from clapack.h.
    /// The new C-style API in lapack.h has the same semantics but a
    /// different prototype; the legacy symbol is still exported in
    /// iOS 26 SDK and matches the pointer-passing convention this file
    /// already needs for the LDA/LDU integer parameters.
    private static func lapackSVD(
        matrix: inout [Double],
        rows: Int,
        cols: Int
    ) -> (uColMajor: [Double], singulars: [Double])? {
        var jobu: CChar = CChar(UInt8(ascii: "S"))
        var jobvt: CChar = CChar(UInt8(ascii: "N"))
        var m = __CLPK_integer(rows)
        var n = __CLPK_integer(cols)
        var lda = __CLPK_integer(rows)
        let kSV = min(rows, cols)
        var s = [Double](repeating: 0, count: kSV)
        var u = [Double](repeating: 0, count: rows * kSV)
        var ldu = __CLPK_integer(rows)
        var vt = [Double](repeating: 0, count: 1)  // unused; jobvt='N'
        var ldvt = __CLPK_integer(1)
        var info: __CLPK_integer = 0

        // Workspace query: lwork=-1 asks LAPACK to write the optimal
        // workspace size to work[0] without touching anything else.
        var workspaceQuery: Double = 0
        var lworkQuery = __CLPK_integer(-1)
        dgesvd_(&jobu, &jobvt, &m, &n, &matrix, &lda, &s,
                &u, &ldu, &vt, &ldvt, &workspaceQuery, &lworkQuery, &info)
        guard info == 0 else { return nil }

        let optimalSize = max(1, Int(workspaceQuery))
        var work = [Double](repeating: 0, count: optimalSize)
        var lwork = __CLPK_integer(optimalSize)
        dgesvd_(&jobu, &jobvt, &m, &n, &matrix, &lda, &s,
                &u, &ldu, &vt, &ldvt, &work, &lwork, &info)
        guard info == 0 else { return nil }

        return (u, s)
    }
}
