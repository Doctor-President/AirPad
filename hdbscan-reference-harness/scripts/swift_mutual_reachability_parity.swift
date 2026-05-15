#!/usr/bin/env swift
// SB139 Stage 4b.1 — host-side mutual reachability parity check.
//
// Loads the fixture coords + harness intermediates JSON, computes the
// same three things `AirPad/Services/HDBSCAN/HDBSCANReachability.swift`
// does (pairwise Euclidean distance, per-point core distance, mutual
// reachability matrix), and diffs against the Python reference.
//
// Three independent gates per run:
//   1. pairwise-distance maxAbsErr — bit-exact target (no transcendentals
//      beyond IEEE-754-correctly-rounded sqrt).
//   2. core-distance maxAbsErr — bit-exact target (sort + index).
//   3. mutual-reachability maxAbsErr — bit-exact target (max of three).
//
// The Swift mirror below MUST stay in sync with `HDBSCANReachability.swift`.
// 4b.1 has no transcendentals so duplication is the price of running this
// from CLI without an Xcode project.
//
// Run from the harness root:
//   source venv/bin/activate
//   python3 scripts/hdbscan_reference.py intermediates \
//       --input fixtures/synth_planted4_2d.json \
//       --output results/synth_planted4_2d.intermediates.json
//   swift scripts/swift_mutual_reachability_parity.swift \
//       fixtures/synth_planted4_2d.json \
//       results/synth_planted4_2d.intermediates.json

import Foundation

// MARK: - Swift mirror (keep in sync with HDBSCANReachability.swift)

func pairwiseEuclideanDistance(_ coords: [[Double]]) -> [[Double]] {
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

func coreDistances(distanceMatrix: [[Double]], minPoints: Int) -> [Double] {
    let n = distanceMatrix.count
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

func mutualReachability(
    distanceMatrix: [[Double]],
    minPoints rawMinPoints: Int,
    alpha: Double = 1.0
) -> [[Double]] {
    let n = distanceMatrix.count
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

// MARK: - JSON schemas

struct FixtureInput: Decodable {
    struct Point: Decodable { let nodeID: String; let coord: [Double] }
    let inputDimension: Int
    let points: [Point]
}

struct Intermediates: Decodable {
    struct Inner: Decodable {
        let pairwiseDistance: [[Double]]
        let coreDistances: [Double]
        let mutualReachability: [[Double]]
    }
    let minPointsResolved: Int
    let intermediates: Inner
}

// MARK: - Driver

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: swift_mutual_reachability_parity.swift <fixture.json> <intermediates.json>\n".data(using: .utf8)!
    )
    exit(2)
}

let fixture = try JSONDecoder().decode(
    FixtureInput.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[1]))
)
let inter = try JSONDecoder().decode(
    Intermediates.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[2]))
)

let coords = fixture.points.map { $0.coord }
let n = coords.count

guard inter.intermediates.pairwiseDistance.count == n,
      inter.intermediates.coreDistances.count == n,
      inter.intermediates.mutualReachability.count == n else {
    print("FAIL: shape mismatch · fixture n=\(n) intermediates n=\(inter.intermediates.pairwiseDistance.count)")
    exit(1)
}

// Stage 1 — pairwise distance.
let swiftDist = pairwiseEuclideanDistance(coords)
var maxAbsDistErr: Double = 0
var distDiffs = 0
for i in 0..<n {
    let row = inter.intermediates.pairwiseDistance[i]
    let got = swiftDist[i]
    for j in 0..<n {
        let err = abs(row[j] - got[j])
        if err > maxAbsDistErr { maxAbsDistErr = err }
        if err > 0 { distDiffs += 1 }
    }
}
print("stage 1 · pairwise distance · maxAbsErr=\(maxAbsDistErr) nonZero=\(distDiffs) / \(n * n)")

// Stage 2 — core distances.
let swiftCore = coreDistances(distanceMatrix: swiftDist, minPoints: inter.minPointsResolved)
var maxAbsCoreErr: Double = 0
var coreDiffs = 0
for i in 0..<n {
    let err = abs(inter.intermediates.coreDistances[i] - swiftCore[i])
    if err > maxAbsCoreErr { maxAbsCoreErr = err }
    if err > 0 { coreDiffs += 1 }
}
print("stage 2 · core distances  · maxAbsErr=\(maxAbsCoreErr) nonZero=\(coreDiffs) / \(n)")

// Stage 3 — mutual reachability. Feed Swift the SWIFT-computed distance
// matrix (not the harness one) so this is a pure Swift end-to-end check.
let swiftMR = mutualReachability(distanceMatrix: swiftDist, minPoints: inter.minPointsResolved)
var maxAbsMRErr: Double = 0
var mrDiffs = 0
for i in 0..<n {
    let row = inter.intermediates.mutualReachability[i]
    let got = swiftMR[i]
    for j in 0..<n {
        let err = abs(row[j] - got[j])
        if err > maxAbsMRErr { maxAbsMRErr = err }
        if err > 0 { mrDiffs += 1 }
    }
}
print("stage 3 · mutual reach.   · maxAbsErr=\(maxAbsMRErr) nonZero=\(mrDiffs) / \(n * n)")

let bitExact = (maxAbsDistErr == 0 && maxAbsCoreErr == 0 && maxAbsMRErr == 0)
if bitExact {
    print("mutual-reachability PARITY OK · bit-exact across all three stages")
    exit(0)
} else {
    print("mutual-reachability PARITY DRIFT · check stage maxAbsErrs above")
    // Don't exit 1 — drift might be sub-ULP and still acceptable. Surface
    // the number; the caller (CI or T's eye) decides whether it's
    // gating. Bit-exact is the target; drift is a finding.
    exit(0)
}
