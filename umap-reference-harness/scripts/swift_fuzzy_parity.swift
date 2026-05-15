#!/usr/bin/env swift
// SB139 Stage 4a step 3 — host-side fuzzy simplicial set parity check.
//
// Loads the synthetic fixture + harness intermediates, computes the same
// fuzzy simplicial set that `AirPad/Services/UMAP/UMAPFuzzySet.swift`
// does (σ binary search → probabilistic symmetrization), and diffs
// against the harness output. Tolerance: 1e-9 absolute on each weight
// (relaxed from k-NN's 1e-10 because of transcendental ops).
//
// Run from the harness root:
//   ./build/umappp-reference fit \
//       --input fixtures/synth_50x4.json \
//       --output results/synth_50x4.umappp.json \
//       --dump-intermediates results/synth_50x4.intermediates.json
//   swift scripts/swift_fuzzy_parity.swift fixtures/synth_50x4.json \
//                                          results/synth_50x4.intermediates.json

import Foundation

// --- k-NN (mirror of UMAPGraph.swift; needed as input to fuzzy step) ---

struct KnnEdge {
    var to: Int
    var distance: Double
}

func computeKnnGraph(vectors: [[Double]], k: Int) -> [[KnnEdge]] {
    let n = vectors.count
    let dim = vectors[0].count
    var graph = [[KnnEdge]](repeating: [], count: n)
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
        graph[i] = pairs.prefix(k).map { KnnEdge(to: $0.to, distance: $0.dist) }
    }
    return graph
}

// --- fuzzy SS (mirror of UMAPFuzzySet.swift; keep in sync) ---

struct FuzzyEdge {
    var to: Int
    var weight: Double
}

struct FuzzyOptions {
    var localConnectivity: Double = 1.0
    var bandwidth: Double = 1.0
    var minKDistScale: Double = 1e-3
    var mixRatio: Double = 1.0
}

func computeFuzzySimplicialSet(
    knn: [[KnnEdge]],
    options: FuzzyOptions = .init()
) -> [[FuzzyEdge]] {
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
            for k in 0..<numNeighbors { directed[i][k].weight = 1 }
            continue
        }

        let connectIndex = numZero + rawConnectIndex
        let lower: Double = connectIndex > 0 ? directed[i][connectIndex - 1].weight : 0
        let upper: Double = directed[i][connectIndex].weight
        let rho = lower + interpolation * (upper - lower)

        var activeDelta: [Double] = []
        var numLeRho = Double(numZero)
        for k in numZero..<numNeighbors {
            let d = directed[i][k].weight
            if d > rho {
                activeDelta.append(d - rho)
            } else {
                numLeRho += 1
            }
        }
        if activeDelta.isEmpty {
            for k in 0..<numNeighbors { directed[i][k].weight = 1 }
            continue
        }

        var sigma = activeDelta.last!
        var lo: Double = 0
        var hi: Double = .greatestFiniteMagnitude
        let target = Foundation.log2(Double(numNeighbors + 1)) * options.bandwidth

        for _ in 0..<64 {
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
            if abs(diff) < 1e-5 { break }
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
        for k in 0..<numNeighbors {
            let dist = directed[i][k].weight
            if dist > rho {
                directed[i][k].weight = Foundation.exp(-(dist - rho) * invSigma)
            } else {
                directed[i][k].weight = 1
            }
        }
    }

    var w: [[Int: Double]] = directed.map { row in
        var dict: [Int: Double] = [:]
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

    var result = [[FuzzyEdge]](repeating: [], count: n)
    for i in 0..<n {
        var row = w[i].map { FuzzyEdge(to: $0.key, weight: $0.value) }
        row.sort { $0.to < $1.to }
        result[i] = row
    }
    return result
}

// --- fixture + intermediates schemas ---

struct FixtureInput: Decodable {
    struct Point: Decodable { let nodeID: String; let inputVector: [Double] }
    struct Hyper: Decodable {
        let nNeighbors: Int
        let localConnectivity: Double
        let bandwidth: Double
        let mixRatio: Double
    }
    let hyperparameters: Hyper
    let trainingPoints: [Point]
}

struct Intermediates: Decodable {
    struct Edge: Decodable { let to: Int; let weight: Double }
    let fuzzySimplicialSet: [[Edge]]
}

// --- driver ---

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: swift_fuzzy_parity.swift <fixture.json> <intermediates.json>\n".data(using: .utf8)!)
    exit(2)
}

let input = try JSONDecoder().decode(
    FixtureInput.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[1]))
)
let intermediates = try JSONDecoder().decode(
    Intermediates.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[2]))
)

let vectors = input.trainingPoints.map { $0.inputVector }
let k = input.hyperparameters.nNeighbors
let knn = computeKnnGraph(vectors: vectors, k: k)
let opts = FuzzyOptions(
    localConnectivity: input.hyperparameters.localConnectivity,
    bandwidth: input.hyperparameters.bandwidth,
    minKDistScale: 1e-3,
    mixRatio: input.hyperparameters.mixRatio
)
let swiftFuzzy = computeFuzzySimplicialSet(knn: knn, options: opts)

guard intermediates.fuzzySimplicialSet.count == swiftFuzzy.count else {
    print("FAIL: row count mismatch swift=\(swiftFuzzy.count) harness=\(intermediates.fuzzySimplicialSet.count)")
    exit(1)
}

let weightTolerance = 1e-9
var diffs: [String] = []
var maxAbsWeightErr: Double = 0

for i in 0..<swiftFuzzy.count {
    let expected = intermediates.fuzzySimplicialSet[i]
    let got = swiftFuzzy[i]
    if expected.count != got.count {
        diffs.append("row \(i): length mismatch got=\(got.count) expected=\(expected.count)")
        continue
    }
    for j in 0..<expected.count {
        let e = expected[j]
        let g = got[j]
        if e.to != g.to {
            diffs.append("row \(i) pos \(j): to mismatch got=\(g.to) expected=\(e.to)")
            continue
        }
        let err = abs(e.weight - g.weight)
        maxAbsWeightErr = max(maxAbsWeightErr, err)
        if err > weightTolerance {
            diffs.append("row \(i) pos \(j) (to=\(e.to)): weight err=\(err) got=\(g.weight) expected=\(e.weight)")
        }
    }
}

if diffs.isEmpty {
    print("fuzzy-SS PARITY OK · n=\(swiftFuzzy.count) maxAbsWeightErr=\(maxAbsWeightErr)")
} else {
    print("fuzzy-SS PARITY FAIL · \(diffs.count) diffs · maxAbsWeightErr=\(maxAbsWeightErr)")
    for d in diffs.prefix(20) { print("  " + d) }
    if diffs.count > 20 { print("  ... and \(diffs.count - 20) more") }
    exit(1)
}
