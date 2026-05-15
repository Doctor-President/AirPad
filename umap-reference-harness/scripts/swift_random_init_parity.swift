#!/usr/bin/env swift
// SB139 Stage 4a step 4.2 — host-side parity check for umappp::random_init.
//
// Mirrors AirPad/Services/UMAP/UMAPRandom.swift's `umapRandomInit`. Loads
// the harness fit fixture (for rngSeed) and the regenerated intermediates
// (for the umappp-side `initialEmbedding` golden output), then reproduces
// the same flat embedding array Swift-side and asserts each per-coordinate
// IEEE 754 bit-pattern matches.
//
// Why bit-exact: `umappp::random_init` is `vals[i] = standard_uniform(rng)
// * (2*scale) - scale`. With `MersenneTwister64.nextStandardUniform()`
// already bit-exact against `aarand::standard_uniform<double>(mt19937_64)`,
// the only operations on top are integer-domain multiply (2*10=20, exactly
// representable) and subtract (10.0, exactly representable). Same hardware,
// same IEEE 754 round-to-nearest-even. Any drift here means a structural
// bug in the Swift mirror.
//
// Run from the harness root:
//   ./build/umappp-reference fit --input fixtures/synth_50x4.json \
//       --output results/synth_50x4.umappp.json \
//       --dump-intermediates results/synth_50x4.intermediates.json
//   swift scripts/swift_random_init_parity.swift \
//       fixtures/synth_50x4.json results/synth_50x4.intermediates.json

import Foundation

// --- SplitMix64 + MersenneTwister64 + nextStandardUniform (copy of UMAPRandom.swift) ---

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
}

// --- umapRandomInit (copy of UMAPRandom.swift) ---

func umapRandomInit(
    numObs: Int,
    numDim: Int,
    seed: UInt64,
    scale: Double = 10.0
) -> [Double] {
    var rng = MersenneTwister64(seed: seed)
    let mult = scale * 2
    let shift = scale
    let total = numDim * numObs
    var vals = [Double](repeating: 0, count: total)
    for i in 0..<total {
        // FMA hypothesis test: Swift `u * mult - shift` does separate
        // rounding; clang `u * mult - shift` contracts to fma(u, mult, -shift)
        // under default -ffp-contract=on. Use addingProduct to mirror.
        vals[i] = (-shift).addingProduct(rng.nextStandardUniform(), mult)
    }
    return vals
}

// --- fixture schemas ---

struct FitFixture: Decodable {
    let rngSeed: UInt64
    let inputDimension: Int
    let trainingPoints: [TrainingPoint]
    struct TrainingPoint: Decodable { let nodeID: String }
}

struct IntermediatesFixture: Decodable {
    let initialEmbedding: [Entry]
    struct Entry: Decodable {
        let nodeID: String
        let coord2D: Coord
    }
    struct Coord: Decodable { let x: Double; let y: Double }
}

// --- driver ---

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: swift_random_init_parity.swift <fit_fixture.json> <intermediates.json>\n"
            .data(using: .utf8)!)
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

let nobs = fit.trainingPoints.count
guard im.initialEmbedding.count == nobs else {
    print("FAIL: trainingPoints=\(nobs) but initialEmbedding=\(im.initialEmbedding.count)")
    exit(1)
}
guard zip(fit.trainingPoints, im.initialEmbedding).allSatisfy({ $0.nodeID == $1.nodeID }) else {
    print("FAIL: nodeID order mismatch between fit fixture and intermediates")
    exit(1)
}

// Derive umappp's initialize_seed from rngSeed via SplitMix64 (must match
// the harness `run_fit()` flow in src/main.cpp:169-171). The init seed is
// the first SplitMix64 draw; the second draw is the optimize seed (4.3).
var sm = SplitMix64(seed: fit.rngSeed)
let initSeed = sm.next()

let numDim = 2  // n_components, hardcoded in harness src/main.cpp:195
let scale = 10.0  // Options.initialize_random_scale default
let vals = umapRandomInit(numObs: nobs, numDim: numDim, seed: initSeed, scale: scale)

guard vals.count == numDim * nobs else {
    print("FAIL: umapRandomInit returned \(vals.count) values, expected \(numDim * nobs)")
    exit(1)
}

var diffs: [String] = []
for i in 0..<nobs {
    let gotX = vals[2 * i + 0]
    let gotY = vals[2 * i + 1]
    let wantX = im.initialEmbedding[i].coord2D.x
    let wantY = im.initialEmbedding[i].coord2D.y
    if gotX.bitPattern != wantX.bitPattern {
        diffs.append(
            "point \(i) (\(im.initialEmbedding[i].nodeID)) x: " +
            "got=\(gotX) (0x\(String(gotX.bitPattern, radix: 16))) " +
            "want=\(wantX) (0x\(String(wantX.bitPattern, radix: 16))) " +
            "|Δ|=\(abs(gotX - wantX))"
        )
    }
    if gotY.bitPattern != wantY.bitPattern {
        diffs.append(
            "point \(i) (\(im.initialEmbedding[i].nodeID)) y: " +
            "got=\(gotY) (0x\(String(gotY.bitPattern, radix: 16))) " +
            "want=\(wantY) (0x\(String(wantY.bitPattern, radix: 16))) " +
            "|Δ|=\(abs(gotY - wantY))"
        )
    }
}

if diffs.isEmpty {
    print("random-init PARITY OK · nobs=\(nobs) numDim=\(numDim) scale=\(scale) " +
          "initSeed=\(initSeed) · all \(numDim * nobs) coordinate bit-patterns match")
} else {
    print("random-init PARITY FAIL · \(diffs.count)/\(numDim * nobs) bit-pattern mismatches")
    for d in diffs.prefix(20) { print("  " + d) }
    if diffs.count > 20 { print("  ... and \(diffs.count - 20) more") }
    exit(1)
}
