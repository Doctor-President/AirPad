#!/usr/bin/env swift
// SB139 Stage 4a step 2 — host-side k-NN parity check.
//
// Loads the synthetic fixture + harness intermediates, computes the same
// brute-force k-NN that `AirPad/Services/UMAP/UMAPGraph.swift` does, and
// diffs row-by-row against the harness output. Tolerance: 1e-10 absolute
// on each distance, exact match on neighbor index.
//
// Run from the harness root:
//   ./build/umappp-reference fit \
//       --input fixtures/synth_50x4.json \
//       --output results/synth_50x4.umappp.json \
//       --dump-intermediates results/synth_50x4.intermediates.json
//   swift scripts/swift_knn_parity.swift fixtures/synth_50x4.json \
//                                        results/synth_50x4.intermediates.json

import Foundation

// --- algorithm (mirror of UMAPGraph.swift; keep in sync) ---

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

// --- fixture + intermediates schemas ---

struct FixtureInput: Decodable {
    struct Point: Decodable { let nodeID: String; let inputVector: [Double] }
    struct Hyper: Decodable { let nNeighbors: Int }
    let hyperparameters: Hyper
    let trainingPoints: [Point]
}

struct Intermediates: Decodable {
    struct Edge: Decodable { let to: Int; let distance: Double }
    let knnGraph: [[Edge]]
}

// --- driver ---

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: swift_knn_parity.swift <fixture.json> <intermediates.json>\n".data(using: .utf8)!)
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
let swiftKnn = computeKnnGraph(vectors: vectors, k: k)

guard intermediates.knnGraph.count == swiftKnn.count else {
    print("FAIL: row count mismatch swift=\(swiftKnn.count) harness=\(intermediates.knnGraph.count)")
    exit(1)
}

let distanceTolerance = 1e-10
var diffs: [String] = []
var maxAbsDistanceErr: Double = 0

for i in 0..<swiftKnn.count {
    let expected = intermediates.knnGraph[i]
    let got = swiftKnn[i]
    if expected.count != got.count {
        diffs.append("row \(i): length mismatch got=\(got.count) expected=\(expected.count)")
        continue
    }
    for j in 0..<expected.count {
        let e = expected[j]
        let g = got[j]
        if e.to != g.to {
            diffs.append("row \(i) pos \(j): to mismatch got=\(g.to) expected=\(e.to) (gotDist=\(g.distance) expDist=\(e.distance))")
        }
        let err = abs(e.distance - g.distance)
        maxAbsDistanceErr = max(maxAbsDistanceErr, err)
        if err > distanceTolerance {
            diffs.append("row \(i) pos \(j): distance err=\(err) got=\(g.distance) expected=\(e.distance)")
        }
    }
}

if diffs.isEmpty {
    print("k-NN PARITY OK · n=\(swiftKnn.count) k=\(k) maxAbsDistanceErr=\(maxAbsDistanceErr)")
} else {
    print("k-NN PARITY FAIL · \(diffs.count) diffs · maxAbsDistanceErr=\(maxAbsDistanceErr)")
    for d in diffs.prefix(20) { print("  " + d) }
    if diffs.count > 20 { print("  ... and \(diffs.count - 20) more") }
    exit(1)
}
