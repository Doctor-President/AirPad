#!/usr/bin/env swift
// SB139 Stage 4a step 4.5 — host-side parity check for the full UMAP fit.
//
// Mirrors `UMAP.fit` end-to-end: runs the entire Swift composition
// (deriveUMAPSeeds → computeKnnGraph → computeFuzzySimplicialSet →
// umapFindAB → umapRandomInit → umapOptimizeLayout) on the synth fixture
// and diffs the final Double embedding against the harness's umappp
// output coords.
//
// Distinct from swift_sgd_parity.swift in that this script does NOT
// consume the harness `--dump-intermediates` output — k-NN and fuzzy SS
// are computed in Swift, so a composition bug anywhere in the pipeline
// is detectable. swift_sgd_parity isolates SGD by starting from the
// harness's fuzzy SS; this script isolates the whole pipeline.
//
// Note: compares pre-Float-cast Double coords (the SGD output), NOT the
// Float coords that `UMAPFittedModel.trainingPoints[i].coord2D` persists.
// SubstrateCoord2D is Float by design for canvas use; bit-exact harness
// parity is a Double-space property.
//
// === ROLE: DIAGNOSTIC, NOT GATING (reclassified 2026-05-11) ===
// This script does NOT pass at byte-exact tolerance (maxAbsCoordErr~42
// on synth_50x4) and is not expected to. It is retained as a diagnostic
// reference, NOT a CI/parity gate. Use it to confirm the Swift pipeline
// produces a structurally valid UMAP embedding — not byte-identical
// coords. See `decisions.md` (harness root) 2026-05-11 entry for the
// full rationale.
//
// Root cause investigation (closed 2026-05-11, exhaustive):
//   • Per-step parity tests (rng, knn, find_ab, fuzzy w/ <1e-9, sgd
//     against harness fuzzy dump) all PASS at their advertised tolerances.
//   • Per-edge bitdiff of step 3 fuzzy SS shows ~40% of edges (358/898 on
//     synth_50x4) differ from harness by exactly 1 ULP (4.44e-16). The
//     other 540 are bit-exact.
//   • Full FMA audit of the harness arm64 binary's `neighbor_similarities`
//     lambda (337 lines of disassembly, 25+ FP ops surveyed) identified
//     ONE actionable FMA contraction at `neighbor_similarities.hpp:141`
//     (`deriv += d * current * invsigma2` → `fmadd d9, d0, d13, d9` at
//     binary offset 0x10000cf18). Mirroring it via `Double.addingProduct`
//     in Swift moved 38 edges from 1-ULP-off to bit-exact (540→578) and
//     reduced maxAbsCoordErr 42→32 — directionally correct, but partial.
//   • The remaining 320-edge drift has no further source-level FMA to
//     attribute it to. Combine_neighbor_sets's lone FMA is bit-equivalent
//     to Swift's special-case branch at mix_ratio=1.0. All other FP ops
//     in both phases are pure fadd/fsub/fmul/fdiv. Both Swift and clang
//     resolve `exp`/`log2` to libsystem_m.
//   • Best remaining hypothesis is libm-resolution drift between
//     `Foundation.exp/log2` (Swift) and `std::exp/log2` (clang/libc++)
//     on this macOS — both nominally call into libsystem_m, but the
//     evidence says they're not byte-identical for some inputs. Not
//     something AirPad code can fix.
//
// The partial FMA fix was reverted (see git log) because the residual
// drift compounds through 500 SGD epochs into orientation/basin
// differences anyway — partial mitigation has no operational value when
// the end-to-end target is unreachable. The unmitigated state is honest.
//
// What the Swift pipeline DOES guarantee (verified by per-step tests
// and `UMAPSelfTest`): structurally valid embedding — similar inputs
// cluster, dissimilar inputs separate, no NaN/Inf, no collapse. The
// specific coords differ from umappp's the way two umappp runs with
// different seeds would — different valid stochastic realization of the
// same UMAP fit.
//
// Diagnostic comparing Swift vs harness fuzzy at the edge level:
//   swift /tmp/swift_fuzzy_bitdiff.swift fixtures/synth_50x4.json \
//                                       results/synth_50x4.intermediates.json
//   → rows match (52/52), edge counts match (898/898),
//     540/898 bit-exact, 358/898 within 1 ULP, maxAbsErr=4.44e-16.
//
// Run from the harness root:
//   ./build/umappp-reference fit --input fixtures/synth_50x4.json \
//       --output results/synth_50x4.umappp.json
//   swift scripts/swift_fit_parity.swift \
//       fixtures/synth_50x4.json \
//       results/synth_50x4.umappp.json

import Foundation

// ===========================================================================
// MARK: - SplitMix64 + MersenneTwister64 (mirror of UMAPRandom.swift)
// ===========================================================================

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct MersenneTwister64 {
    private static let NN: Int = 312
    private static let MM: Int = 156
    private static let MATRIX_A: UInt64 = 0xB5026F5AA96619E9
    private static let UM: UInt64 = 0xFFFFFFFF80000000
    private static let LM: UInt64 = 0x000000007FFFFFFF
    private var mt: [UInt64]
    private var mti: Int

    init(seed: UInt64) {
        self.mt = [UInt64](repeating: 0, count: Self.NN)
        self.mt[0] = seed
        for i in 1..<Self.NN {
            let prev = self.mt[i &- 1]
            self.mt[i] = 6364136223846793005 &* (prev ^ (prev >> 62)) &+ UInt64(i)
        }
        self.mti = Self.NN
    }

    mutating func next() -> UInt64 {
        if mti >= Self.NN { refreshState() }
        var y = mt[mti]
        mti &+= 1
        y ^= (y >> 29) & 0x5555555555555555
        y ^= (y << 17) & 0x71D67FFFEDA60000
        y ^= (y << 37) & 0xFFF7EEE000000000
        y ^= (y >> 43)
        return y
    }

    private mutating func refreshState() {
        for i in 0..<(Self.NN - Self.MM) {
            let x = (mt[i] & Self.UM) | (mt[i &+ 1] & Self.LM)
            let mag: UInt64 = (x & 1) != 0 ? Self.MATRIX_A : 0
            mt[i] = mt[i &+ Self.MM] ^ (x >> 1) ^ mag
        }
        for i in (Self.NN - Self.MM)..<(Self.NN - 1) {
            let x = (mt[i] & Self.UM) | (mt[i &+ 1] & Self.LM)
            let mag: UInt64 = (x & 1) != 0 ? Self.MATRIX_A : 0
            mt[i] = mt[i &+ Self.MM &- Self.NN] ^ (x >> 1) ^ mag
        }
        let x = (mt[Self.NN - 1] & Self.UM) | (mt[0] & Self.LM)
        let mag: UInt64 = (x & 1) != 0 ? Self.MATRIX_A : 0
        mt[Self.NN - 1] = mt[Self.MM - 1] ^ (x >> 1) ^ mag
        mti = 0
    }

    static let standardUniformFactor: Double = 1.0 / (Double(UInt64.max) + 1.0)

    mutating func nextStandardUniform() -> Double {
        var result: Double
        repeat {
            let raw = self.next()
            result = Double(raw) * Self.standardUniformFactor
        } while result == 1.0
        return result
    }

    mutating func nextDiscreteUniform(bound: UInt64) -> UInt64 {
        precondition(bound > 0, "bound must be positive")
        let range = UInt64.max
        var draw = self.next()
        if draw > range &- bound {
            let limit = range &- ((range % bound) &+ 1)
            while draw > limit {
                draw = self.next()
            }
        }
        return draw % bound
    }
}

// ===========================================================================
// MARK: - umapRandomInit (mirror of UMAPRandom.swift)
// ===========================================================================

func umapRandomInit(
    numObs: Int,
    numDim: Int,
    seed: UInt64,
    scale: Double = 10.0
) -> [Double] {
    var rng = MersenneTwister64(seed: seed)
    let mult = scale * 2
    let negShift = -scale
    let total = numDim * numObs
    var vals = [Double](repeating: 0, count: total)
    for i in 0..<total {
        vals[i] = negShift.addingProduct(rng.nextStandardUniform(), mult)
    }
    return vals
}

// ===========================================================================
// MARK: - k-NN (mirror of UMAPGraph.swift, Double in/out)
// ===========================================================================

struct UMAPKnnEdge {
    var to: Int
    var distance: Double
}

func computeKnnGraph(vectors: [[Double]], k: Int) -> [[UMAPKnnEdge]] {
    let n = vectors.count
    let dim = vectors[0].count
    var graph = [[UMAPKnnEdge]](repeating: [], count: n)
    var pairs: [(to: Int, dist: Double)] = []
    pairs.reserveCapacity(n - 1)
    for i in 0..<n {
        pairs.removeAll(keepingCapacity: true)
        let vi = vectors[i]
        for j in 0..<n where j != i {
            let vj = vectors[j]
            var acc: Double = 0
            for d in 0..<dim {
                let diff = vi[d] - vj[d]
                acc += diff * diff
            }
            pairs.append((to: j, dist: acc.squareRoot()))
        }
        pairs.sort { lhs, rhs in
            if lhs.dist != rhs.dist { return lhs.dist < rhs.dist }
            return lhs.to < rhs.to
        }
        graph[i] = pairs.prefix(k).map { UMAPKnnEdge(to: $0.to, distance: $0.dist) }
    }
    return graph
}

// ===========================================================================
// MARK: - fuzzy simplicial set (mirror of UMAPFuzzySet.swift)
// ===========================================================================

struct UMAPFuzzyEdge {
    var to: Int
    var weight: Double
}

struct UMAPFuzzyOptions {
    var localConnectivity: Double = 1.0
    var bandwidth: Double = 1.0
    var minKDistScale: Double = 1e-3
    var mixRatio: Double = 1.0
}

func computeFuzzySimplicialSet(
    knn: [[UMAPKnnEdge]],
    options: UMAPFuzzyOptions = .init()
) -> [[UMAPFuzzyEdge]] {
    let n = knn.count

    var directed: [[(to: Int, weight: Double)]] = knn.map { row in
        row.map { (to: $0.to, weight: $0.distance) }
    }

    let rawConnectIndex = Int(options.localConnectivity)
    let interpolation = options.localConnectivity - Double(rawConnectIndex)

    for i in 0..<n {
        let numNeighbors = directed[i].count
        if numNeighbors == 0 { continue }

        var numZero = 0
        for edge in directed[i] {
            if edge.weight != 0 { break }
            numZero += 1
        }

        if numNeighbors - numZero <= rawConnectIndex {
            for kk in 0..<numNeighbors { directed[i][kk].weight = 1 }
            continue
        }

        let connectIndex = numZero + rawConnectIndex
        let lower: Double = connectIndex > 0 ? directed[i][connectIndex - 1].weight : 0
        let upper: Double = directed[i][connectIndex].weight
        let rho = lower + interpolation * (upper - lower)

        var activeDelta: [Double] = []
        var numLeRho = Double(numZero)
        for kk in numZero..<numNeighbors {
            let d = directed[i][kk].weight
            if d > rho {
                activeDelta.append(d - rho)
            } else {
                numLeRho += 1
            }
        }

        if activeDelta.isEmpty {
            for kk in 0..<numNeighbors { directed[i][kk].weight = 1 }
            continue
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

        var meanDist: Double = 0
        for edge in directed[i] { meanDist += edge.weight }
        meanDist /= Double(numNeighbors)
        sigma = max(options.minKDistScale * meanDist, sigma)

        let invSigma = 1 / sigma
        for kk in 0..<numNeighbors {
            let dist = directed[i][kk].weight
            if dist > rho {
                directed[i][kk].weight = Foundation.exp(-(dist - rho) * invSigma)
            } else {
                directed[i][kk].weight = 1
            }
        }
    }

    var w: [[Int: Double]] = directed.map { row in
        var dict: [Int: Double] = [:]
        dict.reserveCapacity(row.count)
        for e in row { dict[e.to] = e.weight }
        return dict
    }

    let mixRatio = options.mixRatio
    for i in 0..<n {
        let snapshot = Array(w[i])
        for (j, wij) in snapshot {
            if let wji = w[j][i] {
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

    var result = [[UMAPFuzzyEdge]](repeating: [], count: n)
    for i in 0..<n {
        var row = w[i].map { UMAPFuzzyEdge(to: $0.key, weight: $0.value) }
        row.sort { $0.to < $1.to }
        result[i] = row
    }
    return result
}

// ===========================================================================
// MARK: - find_ab (mirror of UMAPFindAB.swift)
// ===========================================================================

struct UMAPCurveFitParameters {
    let a: Double
    let b: Double
}

func umapFindAB(spread: Double, minDist: Double) -> UMAPCurveFitParameters {
    let grid = 300
    var gridX = [Double](repeating: 0, count: grid)
    var gridY = [Double](repeating: 0, count: grid)
    var logX = [Double](repeating: 0, count: grid)

    let delta = spread * 3.0 / Double(grid)
    for g in 0..<grid {
        gridX[g] = Double(g + 1) * delta
        logX[g] = Foundation.log(gridX[g])
        gridY[g] = gridX[g] <= minDist ? 1.0 : Foundation.exp(-(gridX[g] - minDist) / spread)
    }

    let limit: Double = 0.5
    let xHalf = Foundation.log(limit) * -spread + minDist
    let dHalf = limit / -spread
    var b = -dHalf * xHalf / (1.0 / limit - 1.0) / (2.0 * limit * limit)
    var a = (1.0 / limit - 1.0) / Foundation.pow(xHalf, 2.0 * b)

    var fitY = [Double](repeating: 0, count: grid)
    var xpow = [Double](repeating: 0, count: grid)
    var gridResid = [Double](repeating: 0, count: grid)

    func computeSS(_ A: Double, _ B: Double) -> Double {
        var ss: Double = 0
        for g in 0..<grid {
            xpow[g] = Foundation.pow(gridX[g], 2.0 * B)
            fitY[g] = 1.0 / (1.0 + A * xpow[g])
            gridResid[g] = gridY[g] - fitY[g]
            ss += gridResid[g] * gridResid[g]
        }
        return ss
    }

    var ss = computeSS(a, b)
    var lmDampener: Double = 0

    let gnIter = 50
    let maxDampener: Double = 1024
    let tol: Double = 1e-6

    for _ in 0..<gnIter {
        var da2: Double = 0
        var db2: Double = 0
        var dadb: Double = 0
        var daResid: Double = 0
        var dbResid: Double = 0

        for g in 0..<grid {
            let x2b = xpow[g]
            let oy = fitY[g]
            let resid = gridResid[g]
            let da = x2b * oy * oy
            let db = a * (logX[g] * 2.0) * da
            da2 += da * da
            db2 += db * db
            dadb += da * db
            daResid += da * resid
            dbResid += db * resid
        }

        var okay = false
        var candidateA: Double = 0
        var candidateB: Double = 0
        var ssNext: Double = 0

        while lmDampener < maxDampener {
            let mult = 1.0 + lmDampener
            let dampedDa2 = da2 * mult
            let dampedDb2 = db2 * mult
            let determinant = dampedDa2 * dampedDb2 - dadb * dadb
            let deltaA = -(daResid * dampedDb2 - dadb * dbResid) / determinant
            let deltaB = -(-daResid * dadb + dampedDa2 * dbResid) / determinant
            candidateA = a + deltaA
            candidateB = b + deltaB
            ssNext = computeSS(candidateA, candidateB)
            if ssNext < ss {
                okay = true
                lmDampener /= 2.0
                break
            }
            if lmDampener == 0 {
                lmDampener = Double.ulpOfOne
            } else {
                lmDampener *= 2.0
            }
        }

        if !okay { break }
        if ss - ssNext <= ss * tol { break }
        a = candidateA
        b = candidateB
        ss = ssNext
    }

    return UMAPCurveFitParameters(a: a, b: b)
}

// ===========================================================================
// MARK: - SGD (mirror of UMAPSGD.swift)
// ===========================================================================

struct UMAPEpochData {
    var cumulativeNumEdges: [Int]
    var edgeTargets: [Int]
    var epochsPerSample: [Double]
    var epochOfNextSample: [Double]
    var epochOfNextNegativeSample: [Double]
    var negativeSampleRate: Double
    var totalEpochs: Int
    var currentEpoch: Int = 0
    var numObs: Int { cumulativeNumEdges.count - 1 }
}

func similaritiesToEpochs(
    fuzzy: [[UMAPFuzzyEdge]],
    numEpochs: Int,
    negativeSampleRate: Double
) -> UMAPEpochData {
    let numObs = fuzzy.count
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
    for i in 0..<numObs {
        for edge in fuzzy[i] {
            if edge.weight >= limit {
                targets.append(edge.to)
                epochsPerSample.append(maxed / edge.weight)
            }
        }
        cumulative[i + 1] = targets.count
    }
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

@inline(__always)
func quickSquaredDistance(
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

@inline(__always)
func clampGradient(_ input: Double) -> Double {
    return Swift.min(Swift.max(input, -4), 4)
}

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
    let numObs = fuzzy.count
    precondition(embedding.count == numObs * numDim, "embedding length must equal numObs * numDim")
    var setup = similaritiesToEpochs(
        fuzzy: fuzzy,
        numEpochs: numEpochs,
        negativeSampleRate: negativeSampleRate
    )
    var rng = MersenneTwister64(seed: optimizeSeed)
    let limit = epochLimit ?? numEpochs

    embedding.withUnsafeMutableBufferPointer { embedBuf in
        let embed = embedBuf.baseAddress!
        var n = setup.currentEpoch
        while n < limit {
            let epoch = Double(n)
            let alpha = initialAlpha * (1.0 - epoch / Double(setup.totalEpochs))
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
                    let target = setup.edgeTargets[j]
                    let rightPos = embed.advanced(by: target * numDim)
                    let dist2Pos = quickSquaredDistance(left, rightPos, numDim: numDim)
                    let pd2b = Foundation.pow(dist2Pos, b)
                    let denomFactor = (1.0).addingProduct(a, pd2b)
                    let gradCoefPos = (-2 * a * b * pd2b) / (dist2Pos * denomFactor)
                    for d in 0..<numDim {
                        let l = left[d]
                        let r = rightPos[d]
                        let gradient = alpha * clampGradient(gradCoefPos * (l - r))
                        left[d] = l + gradient
                        rightPos[d] = r - gradient
                    }
                    let epochsPerNegativeSample = setup.epochsPerSample[j] / negativeSampleRate
                    let numNegSamples = Int(
                        (epoch - setup.epochOfNextNegativeSample[j]) / epochsPerNegativeSample
                    )
                    for _ in 0..<numNegSamples {
                        let sampled = Int(rng.nextDiscreteUniform(bound: UInt64(numObs)))
                        if sampled == i { continue }
                        let rightNeg = embed.advanced(by: sampled * numDim)
                        let dist2Neg = quickSquaredDistance(left, rightNeg, numDim: numDim)
                        let denomFactorNeg = (1.0).addingProduct(a, Foundation.pow(dist2Neg, b))
                        let gradCoefNeg = 2 * gamma * b / ((0.001 + dist2Neg) * denomFactorNeg)
                        for d in 0..<numDim {
                            let inner = clampGradient(gradCoefNeg * (left[d] - rightNeg[d]))
                            left[d] = left[d].addingProduct(alpha, inner)
                        }
                    }
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

// ===========================================================================
// MARK: - fixture schemas + driver
// ===========================================================================

struct FitFixture: Decodable {
    let rngSeed: UInt64
    let inputDimension: Int
    let hyperparameters: Hyperparameters
    let trainingPoints: [TrainingPoint]
    struct TrainingPoint: Decodable {
        let nodeID: String
        let inputVector: [Double]
    }
    struct Hyperparameters: Decodable {
        let nNeighbors: Int
        let spread: Double
        let minDist: Double
        let learningRate: Double
        let negativeSampleRate: Double
        let nEpochs: Int?
        // localConnectivity, bandwidth, mixRatio also present in the
        // fixture but hardcoded to umappp defaults in this script (matches
        // UMAP.fit's hardcoded defaults — see UMAP.swift fit() comment).
    }
}

struct UmappResult: Decodable {
    let trainingPoints: [Entry]
    struct Entry: Decodable {
        let nodeID: String
        let coord2D: Coord
    }
    struct Coord: Decodable { let x: Double; let y: Double }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: swift_fit_parity.swift <fit_fixture.json> <umappp_result.json>\n"
            .data(using: .utf8)!)
    exit(2)
}

let fit = try JSONDecoder().decode(
    FitFixture.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[1]))
)
let golden = try JSONDecoder().decode(
    UmappResult.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[2]))
)

let nobs = fit.trainingPoints.count
guard golden.trainingPoints.count == nobs else {
    print("FAIL: trainingPoints=\(nobs) but golden=\(golden.trainingPoints.count)")
    exit(1)
}

// === Mirror of UMAP.fit composition (UMAP.swift, step 4.5) ===

// Step 1 — seed derivation. Matches deriveUMAPSeeds(from: rngSeed).
var sm = SplitMix64(seed: fit.rngSeed)
let initSeed = sm.next()
let optSeed = sm.next()

// Step 2 — k-NN graph.
let vectors = fit.trainingPoints.map { $0.inputVector }
let knn = computeKnnGraph(vectors: vectors, k: fit.hyperparameters.nNeighbors)

// Step 3 — fuzzy SS with umappp defaults.
let fuzzy = computeFuzzySimplicialSet(knn: knn, options: UMAPFuzzyOptions())

// Step 4 — find_ab.
let ab = umapFindAB(spread: fit.hyperparameters.spread, minDist: fit.hyperparameters.minDist)
let a = ab.a
let b = ab.b

// Step 5 — random init.
let numDim = 2
let scale = 10.0
var embedding = umapRandomInit(numObs: nobs, numDim: numDim, seed: initSeed, scale: scale)

// Step 6 — SGD.
let numEpochs = chooseUMAPNumEpochs(numObs: nobs, override: fit.hyperparameters.nEpochs)
let t0 = Date()
umapOptimizeLayout(
    embedding: &embedding,
    fuzzy: fuzzy,
    numDim: numDim,
    a: a,
    b: b,
    gamma: 1.0,
    initialAlpha: fit.hyperparameters.learningRate,
    negativeSampleRate: fit.hyperparameters.negativeSampleRate,
    numEpochs: numEpochs,
    optimizeSeed: optSeed,
    epochLimit: nil
)
let elapsed = Date().timeIntervalSince(t0)

// === Diff against harness golden ===

var bitExactCount = 0
var maxAbsErr: Double = 0
var maxAbsErrPoint: String = ""
var maxAbsErrDim: String = ""
var absErrs: [Double] = []
absErrs.reserveCapacity(nobs * 2)

for i in 0..<nobs {
    let gotX = embedding[2 * i + 0]
    let gotY = embedding[2 * i + 1]
    let wantX = golden.trainingPoints[i].coord2D.x
    let wantY = golden.trainingPoints[i].coord2D.y
    if gotX.bitPattern == wantX.bitPattern { bitExactCount += 1 }
    if gotY.bitPattern == wantY.bitPattern { bitExactCount += 1 }
    let dx = abs(gotX - wantX)
    let dy = abs(gotY - wantY)
    absErrs.append(dx)
    absErrs.append(dy)
    if dx > maxAbsErr {
        maxAbsErr = dx
        maxAbsErrPoint = golden.trainingPoints[i].nodeID
        maxAbsErrDim = "x"
    }
    if dy > maxAbsErr {
        maxAbsErr = dy
        maxAbsErrPoint = golden.trainingPoints[i].nodeID
        maxAbsErrDim = "y"
    }
}

absErrs.sort()
let total = absErrs.count
func pct(_ p: Double) -> Double {
    let idx = Swift.min(total - 1, Int(p * Double(total)))
    return absErrs[idx]
}

let ceilingTolerance = 1e-6

print("Fit parity report — full-pipeline mirror of UMAP.fit (n=\(nobs), numDim=\(numDim), nEpochs=\(numEpochs))")
print("  a=\(a) b=\(b)")
print("  rngSeed=\(fit.rngSeed) initSeed=\(initSeed) optSeed=\(optSeed)")
print("  runtime: \(String(format: "%.2f", elapsed))s")
print("  bit-exact coords: \(bitExactCount)/\(total)")
print("  maxAbsCoordErr: \(maxAbsErr) (point=\(maxAbsErrPoint), dim=\(maxAbsErrDim))")
print("  abs-err distribution: median=\(pct(0.5)) p90=\(pct(0.9)) p99=\(pct(0.99))")

if maxAbsErr <= ceilingTolerance {
    print("PASS: maxAbsCoordErr=\(maxAbsErr) ≤ tolerance=\(ceilingTolerance)")
    exit(0)
} else {
    print("FAIL: maxAbsCoordErr=\(maxAbsErr) > tolerance=\(ceilingTolerance)")
    var withIdx: [(Double, Int, String)] = []
    for i in 0..<nobs {
        let gotX = embedding[2 * i + 0]
        let gotY = embedding[2 * i + 1]
        let wantX = golden.trainingPoints[i].coord2D.x
        let wantY = golden.trainingPoints[i].coord2D.y
        withIdx.append((abs(gotX - wantX), i, "x"))
        withIdx.append((abs(gotY - wantY), i, "y"))
    }
    withIdx.sort { $0.0 > $1.0 }
    print("worst offenders:")
    for k in 0..<Swift.min(10, withIdx.count) {
        let (e, i, dim) = withIdx[k]
        let got = dim == "x" ? embedding[2 * i + 0] : embedding[2 * i + 1]
        let want = dim == "x" ? golden.trainingPoints[i].coord2D.x : golden.trainingPoints[i].coord2D.y
        print("  point \(i) (\(golden.trainingPoints[i].nodeID)) \(dim): got=\(got) want=\(want) |Δ|=\(e)")
    }
    exit(1)
}
