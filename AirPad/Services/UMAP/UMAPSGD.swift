import Foundation

// SB139 Stage 4a steps 4.3 + 4.4 — UMAP SGD (optimize_layout) and the
// resumable `Status` wrapper around it.
//
// Mirrors umappp v3.3.2's serial `optimize_layout` (and the upstream
// `similarities_to_epochs` CSR builder it consumes) in pure Swift. Three
// public surfaces:
//
// 1. `umapOptimizeLayout(...)` — one-shot SGD entry point. Builds a
//    `UMAPStatus` internally, runs SGD to completion, discards the
//    Status. The existing 4.3 caller surface; behavior unchanged.
// 2. `UMAPStatus` — value-type wrapper mirroring `umappp::Status`
//    (Status.hpp:25-141). Holds the CSR EpochData + MT19937-64 RNG +
//    immutable SGD params. `mutating run(embedding:&, epochLimit:)`
//    advances `currentEpoch` toward `epochLimit`, so SGD can be paused
//    and resumed across `run` calls.
// 3. `umapInitializeStatus(...)` — factory mirroring the SGD-relevant
//    slice of `umappp::initialize()`. Builds the EpochData via
//    `similaritiesToEpochs` and seeds the RNG from `optimizeSeed`.
//
// The SGD loop body is extracted into a single `fileprivate runSGDEpochs`
// helper shared by both surfaces, so the resumable path and the one-shot
// path execute byte-identical code.
//
// **Numerical contract** with the C++ reference: bit-exact through the
// RNG (MT19937-64 + `nextDiscreteUniform`), the FMA-bearing arithmetic
// (`addingProduct` everywhere clang's `-ffp-contract=on` fuses a single
// `a*b ± c` statement), and the transcendental gradient math
// (`pow(dist2, b)` and `pow(dist2, b-1)` per edge update). Apple's Darwin
// libm `pow` is bit-identical to Apple clang's libc++ `pow` for these
// inputs — confirmed at 4.3 with `maxAbsCoordErr = 0.0` on 52 nodes ×
// 500 epochs.
//
// **FMA discipline.** Clang's `-ffp-contract=on` (default) fuses
// `a*b ± c` only *within a single statement*. Where umappp uses a named
// temporary (`const Float_ gradient = alpha * clamp(...); l += gradient;`)
// there is a statement boundary and no fusion — Swift uses plain `+=`.
// Where umappp inlines (`left[d] += alpha * clamp(...)`) the entire
// expression is one statement — Swift uses `.addingProduct`. See
// `feedback_swift_mirrors_clang_fma_contraction.md` for the rule.
//
// **Source pins (umappp v3.3.2):**
//   include/umappp/optimize_layout.hpp:48-92    (similarities_to_epochs)
//   include/umappp/optimize_layout.hpp:95-110   (quick_squared_distance, clamp)
//   include/umappp/optimize_layout.hpp:116-185  (serial optimize_layout)
//   include/umappp/Status.hpp:25-141            (Status wrapper)
//   include/umappp/initialize.hpp:27-47         (choose_num_epochs)
//   include/aarand/aarand.hpp:126-167           (discrete_uniform)

// MARK: - EpochData (CSR fuzzy graph + epoch schedules)

/// Mirrors umappp's `EpochData<Index_, Float_>` (optimize_layout.hpp:28-45).
/// CSR-style fuzzy adjacency plus per-edge sampling schedules. Constructed
/// by `similaritiesToEpochs(...)` once at the start of SGD, mutated
/// per-epoch by the SGD loop as edges fire.
struct UMAPEpochData {
    /// CSR indptrs: edges of obs i live at `[cumulativeNumEdges[i], cumulativeNumEdges[i+1])`.
    /// Size = numObs + 1, last entry = total edge count.
    var cumulativeNumEdges: [Int]

    /// CSR column indices: `edgeTargets[e]` is the neighbor of the
    /// owning observation for edge e.
    var edgeTargets: [Int]

    /// Per-edge sampling rate. `epochsPerSample[e] = maxWeight / weight`.
    /// Edges with weight < maxWeight/totalEpochs were filtered out
    /// (those edges would never fire even once).
    var epochsPerSample: [Double]

    /// Per-edge "when do I next sample positive?" running counter. Init =
    /// `epochsPerSample`. Incremented by `epochsPerSample[e]` after each
    /// fire. Edge fires this epoch iff `epochOfNextSample[e] <= epoch`.
    var epochOfNextSample: [Double]

    /// Per-edge "when do I next sample negatives?" running counter.
    /// Init = `epochsPerSample[e] / negativeSampleRate`. Incremented
    /// after each fire by `numNegSamples * epochsPerNegativeSample`.
    var epochOfNextNegativeSample: [Double]

    var negativeSampleRate: Double
    var totalEpochs: Int
    var currentEpoch: Int = 0

    var numObs: Int { cumulativeNumEdges.count - 1 }
}

// MARK: - similarities_to_epochs (CSR builder)

/// Mirror of umappp's `similarities_to_epochs` (optimize_layout.hpp:48-92).
///
/// Translates fuzzy SS weights into an epoch sampling schedule. Edges
/// with weight below `maxWeight / numEpochs` are dropped — those would
/// never fire even once within the epoch budget. Retained edges get
/// `epochsPerSample[e] = maxWeight / weight`, so the highest-weight
/// edge fires every epoch and weaker edges fire less often.
///
/// Deterministic float math (no RNG). Bit-exact achievable: only floating
/// divisions, all routed through the hardware divide instruction. Both
/// the harness (Apple clang libc++) and Swift (Darwin libm) use the same
/// IEEE 754 division on the same hardware.
private func similaritiesToEpochs(
    fuzzy: [[UMAPFuzzyEdge]],
    numEpochs: Int,
    negativeSampleRate: Double
) -> UMAPEpochData {
    let numObs = fuzzy.count

    // Pass 1: find max weight and total edge count.
    var maxed: Double = 0
    var totalCount: Int = 0
    for row in fuzzy {
        totalCount += row.count
        for edge in row {
            if edge.weight > maxed { maxed = edge.weight }
        }
    }

    let limit = maxed / Double(numEpochs)
    var cumulative = [Int](repeating: 0, count: numObs + 1)
    var targets: [Int] = []
    var epochsPerSample: [Double] = []
    targets.reserveCapacity(totalCount)
    epochsPerSample.reserveCapacity(totalCount)

    // Pass 2: filter + emit CSR.
    for i in 0..<numObs {
        for edge in fuzzy[i] {
            if edge.weight >= limit {
                targets.append(edge.to)
                epochsPerSample.append(maxed / edge.weight)
            }
        }
        cumulative[i + 1] = targets.count
    }

    // Init running counters.
    let epochOfNextSample = epochsPerSample
    var epochOfNextNegativeSample = epochsPerSample
    for j in 0..<epochOfNextNegativeSample.count {
        epochOfNextNegativeSample[j] /= negativeSampleRate
    }

    return UMAPEpochData(
        cumulativeNumEdges: cumulative,
        edgeTargets: targets,
        epochsPerSample: epochsPerSample,
        epochOfNextSample: epochOfNextSample,
        epochOfNextNegativeSample: epochOfNextNegativeSample,
        negativeSampleRate: negativeSampleRate,
        totalEpochs: numEpochs,
        currentEpoch: 0
    )
}

// MARK: - choose_num_epochs

/// Mirror of `umappp::choose_num_epochs` (initialize.hpp:27-47). When the
/// caller doesn't specify, picks 500 epochs for n ≤ 10000 and a smaller
/// budget that decreases asymptotically toward 200 for larger corpora.
/// For AirPad's projected n ≤ 10K, always returns 500.
func chooseUMAPNumEpochs(numObs: Int, override: Int? = nil) -> Int {
    if let v = override { return v }
    let limit = 10000
    let minimal = 200
    let maximal = 300
    if numObs <= limit {
        return minimal + maximal
    } else {
        let scaled = ceil(Double(maximal) * Double(limit) / Double(numObs))
        return minimal + Int(scaled)
    }
}

// MARK: - quick_squared_distance + clamp

/// Mirror of `quick_squared_distance` (optimize_layout.hpp:94-103).
/// Sum of squared per-dim deltas, floored at the smallest positive double
/// `Double.ulpOfOne` to avoid division-by-zero in gradient denominators
/// when two points coincide.
///
/// **FMA hazard:** `dist2 += delta * delta` is single-statement
/// `c = c + a*b` shape; clang fuses to fma under `-ffp-contract=on`.
/// Swift mirrors with `addingProduct(delta, delta)`.
@inline(__always)
private func quickSquaredDistance(
    _ left: UnsafePointer<Double>,
    _ right: UnsafePointer<Double>,
    numDim: Int
) -> Double {
    var dist2: Double = 0
    for d in 0..<numDim {
        let delta = left[d] - right[d]
        dist2 = dist2.addingProduct(delta, delta)
    }
    let dist_eps = Double.ulpOfOne
    return Swift.max(dist_eps, dist2)
}

/// Mirror of `clamp` (optimize_layout.hpp:106-110). Saturates gradient
/// magnitude at ±4 to prevent SGD blow-up.
@inline(__always)
private func clampGradient(_ input: Double) -> Double {
    let minGradient: Double = -4
    let maxGradient: Double = 4
    return Swift.min(Swift.max(input, minGradient), maxGradient)
}

// MARK: - runSGDEpochs (shared SGD loop body)

/// Per-epoch SGD body extracted from `umappp::optimize_layout`
/// (optimize_layout.hpp:116-185) for reuse between the one-shot
/// `umapOptimizeLayout` entry point and the resumable
/// `UMAPStatus.run(...)` wrapper. Bit-identical to the umappp serial
/// path; mutates `setup.currentEpoch`, `setup.epochOfNextSample[j]`,
/// `setup.epochOfNextNegativeSample[j]`, the `rng` state, and the
/// `embedding` array in place.
///
/// **Algorithm per epoch:**
/// 1. `alpha = initialAlpha * (1 - epoch/totalEpochs)` — linear decay to 0.
/// 2. For each observation i and each of its CSR edges j:
///    - Skip if `epochOfNextSample[j] > epoch`.
///    - Positive sample: attractive force pulls `left` and `right` along
///      `(left - right)`, scaled by `grad_coef = -2ab·d²ᵇ / (d² (a·d²ᵇ+1))`
///      and `alpha`, clamped to [-4, 4] per dim.
///    - Negative sampling: for each of `num_neg_samples` draws of a random
///      observation, repulsive force pushes `left` away from that random
///      point, scaled by `grad_coef = 2γb / ((0.001 + d²)(a·d²ᵇ+1))`.
///      Self-skips (sampled == i) DO consume an RNG draw but apply no
///      update; the scheduler still advances by `num_neg_samples * eps`.
///    - Advance `epochOfNextSample[j]` and `epochOfNextNegativeSample[j]`.
///
/// **FMA application** (per-statement mirror of clang's `-ffp-contract=on`):
/// - Attractive: `gradient` is a named temporary across three statements
///   → no fma fusion clang-side; Swift uses plain `+=` / `-=`.
/// - Repulsive: `left[d] += alpha * clamp(...)` is one statement,
///   fma-fused after clamp inlining clang-side; Swift uses `addingProduct`.
/// - `dist2 += delta*delta` in `quickSquaredDistance`: fma.
/// - `a*pd2b + 1.0`: fma.
/// - `epochOfNextNegativeSample[j] += num_neg_samples * eps`: fma.
fileprivate func runSGDEpochs(
    embedding: inout [Double],
    setup: inout UMAPEpochData,
    rng: inout MersenneTwister64,
    numDim: Int,
    a: Double,
    b: Double,
    gamma: Double,
    initialAlpha: Double,
    negativeSampleRate: Double,
    epochLimit: Int
) {
    let numObs = setup.numObs
    let totalEpochs = setup.totalEpochs

    embedding.withUnsafeMutableBufferPointer { embedBuf in
        let embed = embedBuf.baseAddress!

        var n = setup.currentEpoch
        while n < epochLimit {
            let epoch = Double(n)
            let alpha = initialAlpha * (1.0 - epoch / Double(totalEpochs))

            for i in 0..<numObs {
                let rowStart = setup.cumulativeNumEdges[i]
                let rowEnd = setup.cumulativeNumEdges[i + 1]
                let left = embed.advanced(by: i * numDim)

                var j = rowStart
                while j < rowEnd {
                    if setup.epochOfNextSample[j] > epoch {
                        j += 1
                        continue
                    }

                    // ===== Attractive (positive) sample =====
                    let target = setup.edgeTargets[j]
                    let rightPos = embed.advanced(by: target * numDim)
                    let dist2Pos = quickSquaredDistance(left, rightPos, numDim: numDim)
                    let pd2b = Foundation.pow(dist2Pos, b)
                    // `a*pd2b + 1.0` is one statement clang-side → fma.
                    let denomFactor = (1.0).addingProduct(a, pd2b)
                    let gradCoefPos = (-2 * a * b * pd2b) / (dist2Pos * denomFactor)

                    for d in 0..<numDim {
                        let l = left[d]
                        let r = rightPos[d]
                        // Named-temporary form (three statements) clang-side
                        // → NO fma fusion. Mirror with plain `+=` / `-=`.
                        let gradient = alpha * clampGradient(gradCoefPos * (l - r))
                        left[d] = l + gradient
                        rightPos[d] = r - gradient
                    }

                    // ===== Negative sampling =====
                    let epochsPerNegativeSample = setup.epochsPerSample[j] / negativeSampleRate
                    let numNegSamples = Int(
                        (epoch - setup.epochOfNextNegativeSample[j]) / epochsPerNegativeSample
                    )

                    for _ in 0..<numNegSamples {
                        let sampled = Int(rng.nextDiscreteUniform(bound: UInt64(numObs)))
                        if sampled == i { continue }

                        let rightNeg = embed.advanced(by: sampled * numDim)
                        let dist2Neg = quickSquaredDistance(left, rightNeg, numDim: numDim)
                        // `a*pow(dist2, b) + 1.0` is one statement clang-side → fma.
                        let denomFactorNeg = (1.0).addingProduct(a, Foundation.pow(dist2Neg, b))
                        let gradCoefNeg = 2 * gamma * b / ((0.001 + dist2Neg) * denomFactorNeg)

                        for d in 0..<numDim {
                            // Single-statement `left[d] += alpha * clamp(...)`
                            // is fma-eligible after clamp inlines clang-side.
                            // Mirror with `.addingProduct` on `left[d]`.
                            let inner = clampGradient(gradCoefNeg * (left[d] - rightNeg[d]))
                            left[d] = left[d].addingProduct(alpha, inner)
                        }
                    }

                    // Advance scheduler. `setup.epochOfNextNegativeSample[j] +=
                    // numNegSamples * epochsPerNegativeSample` is single-
                    // statement `c += a*b` → fma clang-side.
                    setup.epochOfNextSample[j] += setup.epochsPerSample[j]
                    setup.epochOfNextNegativeSample[j] = setup.epochOfNextNegativeSample[j]
                        .addingProduct(Double(numNegSamples), epochsPerNegativeSample)

                    j += 1
                }
            }

            n += 1
        }
        setup.currentEpoch = n
    }
}

// MARK: - umapOptimizeLayout (one-shot SGD entry point)

/// SB139 Stage 4a step 4.3 — UMAP SGD one-shot entry point.
///
/// Builds a `UMAPStatus` internally and runs SGD from epoch 0 to
/// `epochLimit ?? numEpochs`. Caller does not see the Status; this is
/// the convenience surface for tests and the eventual `fit()` pipeline
/// that doesn't need pause/resume semantics.
///
/// **Inputs:**
/// - `embedding`: initial 2D coords from `umapRandomInit`, flattened
///   column-major (length = numObs * numDim). Mutated in place.
/// - `fuzzy`: symmetric fuzzy SS from `computeFuzzySimplicialSet`.
/// - `a`, `b`: curve-fit params from `findAB` (e.g., 1.5769, 0.8951 at
///   spread=1.0/min_dist=0.1).
/// - `gamma`: `repulsion_strength` (umappp default 1.0).
/// - `initialAlpha`: `learning_rate` (umappp default 1.0).
/// - `negativeSampleRate`: draws per positive edge per fire (umappp
///   default 5).
/// - `numEpochs`: total epochs (typically `chooseUMAPNumEpochs`).
/// - `optimizeSeed`: MT19937-64 seed for negative sampling (umappp's
///   `Options.optimize_seed`, distinct from `initialize_seed`).
/// - `epochLimit`: run up to this epoch (default = numEpochs). Must lie
///   in `[0, numEpochs]` — Status enforces this contract.
func umapOptimizeLayout(
    embedding: inout [Double],
    fuzzy: [[UMAPFuzzyEdge]],
    numDim: Int,
    a: Double,
    b: Double,
    gamma: Double = 1.0,
    initialAlpha: Double = 1.0,
    negativeSampleRate: Double = 5.0,
    numEpochs: Int,
    optimizeSeed: UInt64,
    epochLimit: Int? = nil
) {
    var status = umapInitializeStatus(
        fuzzy: fuzzy,
        numDim: numDim,
        a: a,
        b: b,
        gamma: gamma,
        initialAlpha: initialAlpha,
        negativeSampleRate: negativeSampleRate,
        numEpochs: numEpochs,
        optimizeSeed: optimizeSeed
    )
    status.run(embedding: &embedding, epochLimit: epochLimit ?? numEpochs)
}

// MARK: - UMAPStatus (epoch-resumable wrapper)

/// SB139 Stage 4a step 4.4 — epoch-resumable wrapper around UMAP SGD.
///
/// Mirrors `umappp::Status<Index, Float>` (Status.hpp:25-141). Holds the
/// CSR fuzzy graph + per-edge sampling schedules (`UMAPEpochData`), the
/// MT19937-64 negative-sampling RNG state, and the immutable SGD params.
/// `currentEpoch` advances through `run(...)` calls, so SGD can be paused
/// (e.g., to render progress) and resumed.
///
/// **Construction:** via `umapInitializeStatus(...)` factory (mirrors
/// `umappp::initialize()`). The Status holds enough state to resume; no
/// need to re-pass fuzzy / params to subsequent `run` calls.
///
/// **Resume contract:** `run(embedding:epochLimit:)` advances
/// `currentEpoch` from its current value to `epochLimit`. The caller owns
/// `embedding` and must pass the same array (with the same contents the
/// previous `run` left in it) across calls — the wrapper does not retain
/// or copy it.
///
/// **Bit-exact parity:** by construction. The SGD loop body is the
/// shared `runSGDEpochs` helper that `umapOptimizeLayout` also calls;
/// no math is duplicated.
struct UMAPStatus {
    fileprivate var setup: UMAPEpochData
    fileprivate var rng: MersenneTwister64
    fileprivate let a: Double
    fileprivate let b: Double
    fileprivate let gamma: Double
    fileprivate let initialAlpha: Double
    fileprivate let negativeSampleRate: Double

    /// Number of dimensions of the embedding (typically 2).
    let numDim: Int

    /// Number of epochs already performed.
    var epoch: Int { setup.currentEpoch }

    /// Total epochs that `run(...)` can perform.
    var numEpochs: Int { setup.totalEpochs }

    /// Number of observations in the embedding.
    var numObservations: Int { setup.numObs }

    /// Number of dimensions of the embedding (alias of `numDim`, mirrors
    /// `umappp::Status::num_dimensions()`).
    var numDimensions: Int { numDim }

    /// Advance SGD from `epoch` up to `epochLimit`. On return,
    /// `epoch == epochLimit`. `embedding` is mutated in place
    /// (column-major, size `numObservations * numDim`).
    ///
    /// **Contract** (mirror of umappp Status::run docs): `epochLimit`
    /// must lie in `[epoch, numEpochs]`. Calling with `epochLimit ==
    /// epoch` is a no-op.
    mutating func run(embedding: inout [Double], epochLimit: Int) {
        precondition(
            embedding.count == numObservations * numDim,
            "embedding length \(embedding.count) must equal numObservations * numDim = \(numObservations * numDim)"
        )
        precondition(
            epochLimit >= epoch && epochLimit <= numEpochs,
            "epochLimit \(epochLimit) must be in [\(epoch), \(numEpochs)]"
        )

        runSGDEpochs(
            embedding: &embedding,
            setup: &setup,
            rng: &rng,
            numDim: numDim,
            a: a,
            b: b,
            gamma: gamma,
            initialAlpha: initialAlpha,
            negativeSampleRate: negativeSampleRate,
            epochLimit: epochLimit
        )
    }

    /// Advance SGD to completion (`epochLimit = numEpochs`). Convenience
    /// for the one-shot case; identical to `run(embedding:&,
    /// epochLimit: numEpochs)`.
    mutating func run(embedding: inout [Double]) {
        run(embedding: &embedding, epochLimit: numEpochs)
    }
}

// MARK: - umapInitializeStatus (factory)

/// Build a `UMAPStatus` ready to run SGD. Mirrors the SGD-relevant slice
/// of `umappp::initialize()` — builds the CSR EpochData via
/// `similaritiesToEpochs`, seeds the negative-sampling RNG from
/// `optimizeSeed`, and packages immutable SGD params. The embedding
/// itself is NOT held by Status; the caller owns it and passes it to
/// each `run(...)` call.
func umapInitializeStatus(
    fuzzy: [[UMAPFuzzyEdge]],
    numDim: Int,
    a: Double,
    b: Double,
    gamma: Double = 1.0,
    initialAlpha: Double = 1.0,
    negativeSampleRate: Double = 5.0,
    numEpochs: Int,
    optimizeSeed: UInt64
) -> UMAPStatus {
    let setup = similaritiesToEpochs(
        fuzzy: fuzzy,
        numEpochs: numEpochs,
        negativeSampleRate: negativeSampleRate
    )
    let rng = MersenneTwister64(seed: optimizeSeed)
    return UMAPStatus(
        setup: setup,
        rng: rng,
        a: a,
        b: b,
        gamma: gamma,
        initialAlpha: initialAlpha,
        negativeSampleRate: negativeSampleRate,
        numDim: numDim
    )
}
