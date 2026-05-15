#!/usr/bin/env swift
// SB139 Stage 4a step 4.4 — host-side parity check for the resumable
// `UMAPStatus` SGD wrapper.
//
// Mirrors the post-4.4 AirPad/Services/UMAP/UMAPSGD.swift end-to-end —
// `runSGDEpochs` shared body, `umapOptimizeLayout` one-shot delegate,
// `UMAPStatus` resumable wrapper, `umapInitializeStatus` factory. Runs
// two parity surfaces against the same harness fixture set:
//
//   A. One-shot regression (via refactored `umapOptimizeLayout`)
//      → diff against `results/synth_50x4.umappp.json`.
//      Confirms the 4.3 refactor preserves bit-exactness.
//
//   B. Status resume (init → run(limit:250) → run(limit:500))
//      → diff partial at 250 against `results/synth_50x4.limit250.umappp.json`,
//      diff final at 500 against `results/synth_50x4.umappp.json`.
//      Confirms umappp's resume-via-Status semantics are mirrored.
//
// Run from the harness root, after the harness fixtures are generated:
//   ./build/umappp-reference fit --input fixtures/synth_50x4.json \
//       --output results/synth_50x4.umappp.json \
//       --dump-intermediates results/synth_50x4.intermediates.json
//   ./build/umappp-reference fit --input fixtures/synth_50x4.json \
//       --output results/synth_50x4.limit250.umappp.json \
//       --epoch-limit 250
//   swift scripts/swift_status_parity.swift \
//       fixtures/synth_50x4.json \
//       results/synth_50x4.intermediates.json \
//       results/synth_50x4.umappp.json \
//       results/synth_50x4.limit250.umappp.json

import Foundation

// ===========================================================================
// MARK: - SplitMix64 + MersenneTwister64 (copy of UMAPRandom.swift)
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
// MARK: - umapRandomInit (copy of UMAPRandom.swift)
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
// MARK: - SGD (copy of refactored UMAPSGD.swift — 4.3 + 4.4)
// ===========================================================================

struct UMAPFuzzyEdge {
    var to: Int
    var weight: Double
}

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

// 4.4 — extracted SGD loop body, shared between one-shot and Status.
func runSGDEpochs(
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

// 4.4 — resumable wrapper mirroring umappp::Status.
struct UMAPStatus {
    var setup: UMAPEpochData
    var rng: MersenneTwister64
    let a: Double
    let b: Double
    let gamma: Double
    let initialAlpha: Double
    let negativeSampleRate: Double
    let numDim: Int

    var epoch: Int { setup.currentEpoch }
    var numEpochs: Int { setup.totalEpochs }
    var numObservations: Int { setup.numObs }
    var numDimensions: Int { numDim }

    mutating func run(embedding: inout [Double], epochLimit: Int) {
        precondition(
            embedding.count == numObservations * numDim,
            "embedding length must equal numObservations * numDim"
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

    mutating func run(embedding: inout [Double]) {
        run(embedding: &embedding, epochLimit: numEpochs)
    }
}

// 4.4 — factory mirroring umappp::initialize() SGD-relevant slice.
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

// 4.3 — one-shot entry point, now delegating to UMAPStatus.
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

// ===========================================================================
// MARK: - find_ab (copy of UMAPFindAB.swift)
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
// MARK: - fixture schemas + driver
// ===========================================================================

struct FitFixture: Decodable {
    let rngSeed: UInt64
    let inputDimension: Int
    let hyperparameters: Hyperparameters
    let trainingPoints: [TrainingPoint]
    struct TrainingPoint: Decodable { let nodeID: String }
    struct Hyperparameters: Decodable {
        let spread: Double
        let minDist: Double
        let learningRate: Double
        let negativeSampleRate: Double
        let nEpochs: Int?
    }
}

struct IntermediatesFixture: Decodable {
    let fuzzySimplicialSet: [[FuzzyEdgeJSON]]
    struct FuzzyEdgeJSON: Decodable {
        let to: Int
        let weight: Double
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

// --- driver ---

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write(
        ("usage: swift_status_parity.swift <fit_fixture.json> <intermediates.json>"
        + " <umappp_final.json> <umappp_partial_at_250.json>\n").data(using: .utf8)!)
    exit(2)
}

let fit = try JSONDecoder().decode(
    FitFixture.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[1]))
)
let im = try JSONDecoder().decode(
    IntermediatesFixture.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[2]))
)
let goldenFinal = try JSONDecoder().decode(
    UmappResult.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[3]))
)
let goldenPartial = try JSONDecoder().decode(
    UmappResult.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[4]))
)

let nobs = fit.trainingPoints.count
let numDim = 2
let scale = 10.0
let partialEpoch = 250  // must match how the partial fixture was generated

guard im.fuzzySimplicialSet.count == nobs else {
    print("FAIL: trainingPoints=\(nobs) but fuzzySimplicialSet rows=\(im.fuzzySimplicialSet.count)")
    exit(1)
}
guard goldenFinal.trainingPoints.count == nobs,
      goldenPartial.trainingPoints.count == nobs else {
    print("FAIL: golden row counts mismatch")
    exit(1)
}

// Derive seeds via SplitMix64 — mirrors harness src/main.cpp.
var sm = SplitMix64(seed: fit.rngSeed)
let initSeed = sm.next()
let optSeed = sm.next()

let fuzzy: [[UMAPFuzzyEdge]] = im.fuzzySimplicialSet.map { row in
    row.map { UMAPFuzzyEdge(to: $0.to, weight: $0.weight) }
}

let ab = umapFindAB(spread: fit.hyperparameters.spread, minDist: fit.hyperparameters.minDist)
let numEpochs = chooseUMAPNumEpochs(numObs: nobs, override: fit.hyperparameters.nEpochs)

// Diff helper: returns (bitExactCount, maxAbsErr, total).
func diff(_ got: [Double], _ golden: UmappResult, label: String) -> (Int, Double, Int) {
    var bitExact = 0
    var maxAbsErr: Double = 0
    var worstPoint = ""
    var worstDim = ""
    for i in 0..<nobs {
        let gx = got[2 * i + 0], gy = got[2 * i + 1]
        let wx = golden.trainingPoints[i].coord2D.x, wy = golden.trainingPoints[i].coord2D.y
        if gx.bitPattern == wx.bitPattern { bitExact += 1 }
        if gy.bitPattern == wy.bitPattern { bitExact += 1 }
        let dx = abs(gx - wx), dy = abs(gy - wy)
        if dx > maxAbsErr {
            maxAbsErr = dx; worstPoint = golden.trainingPoints[i].nodeID; worstDim = "x"
        }
        if dy > maxAbsErr {
            maxAbsErr = dy; worstPoint = golden.trainingPoints[i].nodeID; worstDim = "y"
        }
    }
    let total = nobs * 2
    print("  [\(label)] bit-exact \(bitExact)/\(total), maxAbsErr=\(maxAbsErr) (point=\(worstPoint), dim=\(worstDim))")
    return (bitExact, maxAbsErr, total)
}

print("4.4 Status parity report — synth_50x4 (n=\(nobs), numDim=\(numDim), nEpochs=\(numEpochs), partialEpoch=\(partialEpoch))")
print("  a=\(ab.a) b=\(ab.b)")
print("  initSeed=\(initSeed) optSeed=\(optSeed)")

// ----- Path A: one-shot regression via refactored umapOptimizeLayout -----
var embA = umapRandomInit(numObs: nobs, numDim: numDim, seed: initSeed, scale: scale)
let tA0 = Date()
umapOptimizeLayout(
    embedding: &embA,
    fuzzy: fuzzy,
    numDim: numDim,
    a: ab.a,
    b: ab.b,
    gamma: 1.0,
    initialAlpha: fit.hyperparameters.learningRate,
    negativeSampleRate: fit.hyperparameters.negativeSampleRate,
    numEpochs: numEpochs,
    optimizeSeed: optSeed,
    epochLimit: nil
)
let tA = Date().timeIntervalSince(tA0)
print("  Path A (one-shot via umapOptimizeLayout) elapsed: \(String(format: "%.2f", tA))s")
let (bitA, maxA, totA) = diff(embA, goldenFinal, label: "A: final coords vs umappp")

// ----- Path B: Status resume (init → run(250) → diff partial → run(500) → diff final) -----
var embB = umapRandomInit(numObs: nobs, numDim: numDim, seed: initSeed, scale: scale)
var status = umapInitializeStatus(
    fuzzy: fuzzy,
    numDim: numDim,
    a: ab.a,
    b: ab.b,
    gamma: 1.0,
    initialAlpha: fit.hyperparameters.learningRate,
    negativeSampleRate: fit.hyperparameters.negativeSampleRate,
    numEpochs: numEpochs,
    optimizeSeed: optSeed
)

precondition(status.epoch == 0, "fresh status should be at epoch 0")
precondition(status.numEpochs == numEpochs, "status.numEpochs should match numEpochs")
precondition(status.numObservations == nobs, "status.numObservations should match nobs")
precondition(status.numDimensions == numDim, "status.numDimensions should match numDim")

let tB0 = Date()
status.run(embedding: &embB, epochLimit: partialEpoch)
let tBmid = Date().timeIntervalSince(tB0)
precondition(status.epoch == partialEpoch, "after run(limit:\(partialEpoch)), epoch should be \(partialEpoch), is \(status.epoch)")
print("  Path B mid (epoch=\(status.epoch)) elapsed: \(String(format: "%.2f", tBmid))s")
let (bitBmid, maxBmid, totBmid) = diff(embB, goldenPartial, label: "B-mid: partial coords vs umappp --epoch-limit \(partialEpoch)")

let tB1 = Date()
status.run(embedding: &embB)
let tBfull = Date().timeIntervalSince(tB1)
precondition(status.epoch == numEpochs, "after run() to completion, epoch should be \(numEpochs), is \(status.epoch)")
print("  Path B end (epoch=\(status.epoch)) elapsed from \(partialEpoch): \(String(format: "%.2f", tBfull))s")
let (bitBend, maxBend, totBend) = diff(embB, goldenFinal, label: "B-end: final coords vs umappp")

// ----- Verdict -----
let ceilingTolerance = 0.0  // 4.3 precision floor was 0.0; 4.4 must hold it.
let allGreen =
    maxA <= ceilingTolerance
    && maxBmid <= ceilingTolerance
    && maxBend <= ceilingTolerance

if allGreen {
    print("PASS: all three parity surfaces (A: one-shot, B-mid: resume@\(partialEpoch), B-end: resumed-to-completion) bit-exact (maxAbsErr=0.0)")
    exit(0)
} else {
    print("FAIL: at least one parity surface drifted")
    print("  A: \(maxA), B-mid: \(maxBmid), B-end: \(maxBend), tolerance: \(ceilingTolerance)")
    exit(1)
}
