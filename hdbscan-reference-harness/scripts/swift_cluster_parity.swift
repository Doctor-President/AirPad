#!/usr/bin/env swift
// SB139 Stage 4b.4 — host-side cluster-selection parity check.
//
// Loads the harness intermediates JSON (now including stabilityPreEOM,
// stabilityPostEOM, selectedInternalClusterIDs, clusterMap, labels,
// probabilities, selectedClusterStabilityScores), runs the Swift port
// of `AirPad/Services/HDBSCAN/HDBSCANCluster.swift`, and diffs.
//
// Target gates (bit-exact under our pinned config):
//   1. computeStability output vs harness `stabilityPreEOM`.
//   2. eomSelect post-EOM dict vs harness `stabilityPostEOM`.
//   3. selectedInternalClusterIDs identical.
//   4. doLabelling output vs harness `labels` (post-permutation under
//      our deterministic ordering, expected exact since both use the
//      same sorted ascending renumbering).
//   5. getProbabilities output vs harness `probabilities` (tolerance
//      ≤1e-12 safety; no transcendentals → expected bit-exact).
//   6. getStabilityScores vs harness `selectedClusterStabilityScores`.
//
// The Swift mirrors below MUST stay in sync with HDBSCANCluster.swift.
//
// Prereqs (run from harness root):
//   source venv/bin/activate
//   python3 scripts/hdbscan_reference.py intermediates \
//       --input fixtures/synth_planted4_2d.json \
//       --output results/synth_planted4_2d.intermediates.json
//   swift scripts/swift_cluster_parity.swift \
//       fixtures/synth_planted4_2d.json \
//       results/synth_planted4_2d.intermediates.json

import Foundation

// MARK: - Schema mirrors (decode-only)

struct ExpectedCondensedRow: Decodable {
    let parent: Int
    let child: Int
    let lambdaVal: Double
    let isInfiniteLambda: Bool
    let childSize: Int
}

struct Intermediates: Decodable {
    struct Inner: Decodable {
        let condensedTree: [ExpectedCondensedRow]
        let condensedTreeMinClusterSize: Int
        let stabilityPreEOM: [String: Double]
        let stabilityPostEOM: [String: Double]
        let selectedInternalClusterIDs: [Int]
        let clusterMap: [String: Int]
        let labels: [Int]
        let probabilities: [Double]
        let selectedClusterStabilityScores: [Double]
    }
    let intermediates: Inner
}

// MARK: - Swift mirrors (keep in sync with HDBSCANCluster.swift)

struct CondensedTreeRow {
    let parent: Int
    let child: Int
    let lambdaVal: Double
    let isInfiniteLambda: Bool
    let childSize: Int
}

struct TreeUnionFind {
    var parent: [Int]
    var rank: [Int]
    init(size: Int) {
        self.parent = Array(0..<size)
        self.rank = [Int](repeating: 0, count: size)
    }
    mutating func union(_ x: Int, _ y: Int) {
        let xRoot = find(x)
        let yRoot = find(y)
        if rank[xRoot] < rank[yRoot] { parent[xRoot] = yRoot }
        else if rank[xRoot] > rank[yRoot] { parent[yRoot] = xRoot }
        else { parent[yRoot] = xRoot; rank[xRoot] += 1 }
    }
    mutating func find(_ x: Int) -> Int {
        if parent[x] != x { parent[x] = find(parent[x]) }
        return parent[x]
    }
}

func computeStability(_ condensed: [CondensedTreeRow]) -> [Int: Double] {
    var largestChild = condensed[0].child
    var smallestCluster = condensed[0].parent
    var largestParent = condensed[0].parent
    for r in condensed {
        if r.child > largestChild { largestChild = r.child }
        if r.parent < smallestCluster { smallestCluster = r.parent }
        if r.parent > largestParent { largestParent = r.parent }
    }
    if largestChild < smallestCluster { largestChild = smallestCluster }
    let numClusters = largestParent - smallestCluster + 1

    var pairs = condensed.map {
        (child: $0.child, lambda: $0.isInfiniteLambda ? Double.infinity : $0.lambdaVal)
    }
    pairs.sort { a, b in
        if a.child != b.child { return a.child < b.child }
        return a.lambda < b.lambda
    }
    var births = [Double](repeating: .nan, count: largestChild + 1)
    var currentChild = -1
    var minLambda: Double = 0
    for pair in pairs {
        let child = pair.child
        let lambda_ = pair.lambda
        if child == currentChild {
            minLambda = Swift.min(minLambda, lambda_)
        } else if currentChild != -1 {
            births[currentChild] = minLambda
            currentChild = child
            minLambda = lambda_
        } else {
            currentChild = child
            minLambda = lambda_
        }
    }
    if currentChild != -1 { births[currentChild] = minLambda }
    births[smallestCluster] = 0.0

    var resultArr = [Double](repeating: 0, count: numClusters)
    for r in condensed {
        let lambda_ = r.isInfiniteLambda ? Double.infinity : r.lambdaVal
        let resultIndex = r.parent - smallestCluster
        let delta = lambda_ - births[r.parent]
        resultArr[resultIndex] = resultArr[resultIndex]
            .addingProduct(delta, Double(r.childSize))
    }
    var result = [Int: Double]()
    for i in 0..<numClusters { result[smallestCluster + i] = resultArr[i] }
    return result
}

func maxLambdas(_ condensed: [CondensedTreeRow]) -> [Double] {
    var largestParent = 0
    for r in condensed where r.parent > largestParent { largestParent = r.parent }
    var deaths = [Double](repeating: 0, count: largestParent + 1)
    var pairs = condensed.map {
        (parent: $0.parent, lambda: $0.isInfiniteLambda ? Double.infinity : $0.lambdaVal)
    }
    pairs.sort { a, b in
        if a.parent != b.parent { return a.parent < b.parent }
        return a.lambda < b.lambda
    }
    var currentParent = -1
    var maxLambda: Double = 0
    for pair in pairs {
        let p = pair.parent
        let lam = pair.lambda
        if p == currentParent {
            maxLambda = Swift.max(maxLambda, lam)
        } else if currentParent != -1 {
            deaths[currentParent] = maxLambda
            currentParent = p
            maxLambda = lam
        } else {
            currentParent = p
            maxLambda = lam
        }
    }
    if currentParent != -1 { deaths[currentParent] = maxLambda }
    return deaths
}

func bfsFromClusterTree(_ clusterTree: [CondensedTreeRow], bfsRoot: Int) -> [Int] {
    var result = [Int]()
    var toProcess = [bfsRoot]
    while !toProcess.isEmpty {
        result.append(contentsOf: toProcess)
        let frontier = Set(toProcess)
        var nextLayer = [Int]()
        for r in clusterTree where frontier.contains(r.parent) {
            nextLayer.append(r.child)
        }
        toProcess = nextLayer
    }
    return result
}

func eomSelect(
    condensed: [CondensedTreeRow],
    stability: [Int: Double]
) -> (selectedInternalIDs: [Int], stabilityPostEOM: [Int: Double]) {
    var stab = stability
    let clusterTree = condensed.filter { $0.childSize > 1 }
    var nodeList = stab.keys.sorted(by: >)
    if !nodeList.isEmpty { nodeList.removeLast() }
    var isCluster = [Int: Bool]()
    for c in nodeList { isCluster[c] = true }
    for node in nodeList {
        var subtreeStability: Double = 0
        for r in clusterTree where r.parent == node {
            subtreeStability += stab[r.child] ?? 0
        }
        let parentStability = stab[node] ?? 0
        if subtreeStability > parentStability {
            isCluster[node] = false
            stab[node] = subtreeStability
        } else {
            for subNode in bfsFromClusterTree(clusterTree, bfsRoot: node) where subNode != node {
                isCluster[subNode] = false
            }
        }
    }
    let selected = isCluster.filter { $0.value }.map { $0.key }.sorted()
    return (selected, stab)
}

func doLabelling(
    condensed: [CondensedTreeRow],
    selectedClusters: Set<Int>,
    clusterMap: [Int: Int]
) -> [Int] {
    var rootCluster = Int.max
    var maxParent = 0
    for r in condensed {
        if r.parent < rootCluster { rootCluster = r.parent }
        if r.parent > maxParent { maxParent = r.parent }
    }
    let numPoints = rootCluster
    var uf = TreeUnionFind(size: maxParent + 1)
    for r in condensed where !selectedClusters.contains(r.child) {
        uf.union(r.parent, r.child)
    }
    var result = [Int](repeating: -1, count: numPoints)
    for n in 0..<numPoints {
        let cluster = uf.find(n)
        if cluster < rootCluster { result[n] = -1 }
        else if cluster == rootCluster { result[n] = -1 }
        else { result[n] = clusterMap[cluster] ?? -1 }
    }
    return result
}

func getProbabilities(
    condensed: [CondensedTreeRow],
    reverseClusterMap: [Int: Int],
    labels: [Int],
    deaths: [Double]
) -> [Double] {
    var rootCluster = Int.max
    for r in condensed where r.parent < rootCluster { rootCluster = r.parent }
    let numPoints = rootCluster
    var result = [Double](repeating: 0, count: numPoints)
    for r in condensed {
        let point = r.child
        if point >= rootCluster { continue }
        let clusterNum = labels[point]
        if clusterNum == -1 { continue }
        guard let cluster = reverseClusterMap[clusterNum] else { continue }
        let maxLambda = deaths[cluster]
        if maxLambda == 0.0 || r.isInfiniteLambda {
            result[point] = 1.0
        } else {
            let lambda_ = Swift.min(r.lambdaVal, maxLambda)
            result[point] = lambda_ / maxLambda
        }
    }
    return result
}

func getStabilityScores(
    labels: [Int],
    selectedInternalIDs: [Int],
    stability: [Int: Double],
    maxLambda: Double,
    maxLambdaIsInfinite: Bool
) -> [Double] {
    let k = selectedInternalIDs.count
    var result = [Double](repeating: 1.0, count: k)
    var sizeByLabel = [Int](repeating: 0, count: k)
    for x in labels where x >= 0 && x < k { sizeByLabel[x] += 1 }
    for (n, c) in selectedInternalIDs.enumerated() {
        let clusterSize = sizeByLabel[n]
        if maxLambdaIsInfinite || maxLambda == 0.0 || clusterSize == 0 {
            result[n] = 1.0
        } else {
            result[n] = (stability[c] ?? 0) / (Double(clusterSize) * maxLambda)
        }
    }
    return result
}

func maxLambdaInCondensed(_ condensed: [CondensedTreeRow]) -> (max: Double, isInfinite: Bool) {
    var maxVal: Double = 0
    var anyInfinite = false
    for r in condensed {
        if r.isInfiniteLambda { anyInfinite = true; continue }
        if r.lambdaVal > maxVal { maxVal = r.lambdaVal }
    }
    return (maxVal, anyInfinite)
}

// MARK: - Driver

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: swift_cluster_parity.swift <fixture.json> <intermediates.json>\n".data(using: .utf8)!
    )
    exit(2)
}

let inter = try JSONDecoder().decode(
    Intermediates.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[2]))
)
let inner = inter.intermediates

let condensed: [CondensedTreeRow] = inner.condensedTree.map {
    CondensedTreeRow(
        parent: $0.parent, child: $0.child,
        lambdaVal: $0.lambdaVal, isInfiniteLambda: $0.isInfiniteLambda,
        childSize: $0.childSize
    )
}
let expectedPre = Dictionary(uniqueKeysWithValues:
    inner.stabilityPreEOM.map { (Int($0.key)!, $0.value) }
)
let expectedPost = Dictionary(uniqueKeysWithValues:
    inner.stabilityPostEOM.map { (Int($0.key)!, $0.value) }
)
let expectedSelectedInternal = inner.selectedInternalClusterIDs
let expectedLabels = inner.labels
let expectedProbs = inner.probabilities
let expectedStabScores = inner.selectedClusterStabilityScores

// Stage 1 — computeStability bit-exact vs stabilityPreEOM.
let stabilityGot = computeStability(condensed)
var preDiffs = 0
var maxPreAbsErr: Double = 0
for (k, v) in expectedPre {
    let g = stabilityGot[k] ?? .nan
    let err = abs(g - v)
    if err > maxPreAbsErr { maxPreAbsErr = err }
    if g != v { preDiffs += 1 }
}
if stabilityGot.count != expectedPre.count {
    print("stage 1 FAIL · count mismatch got=\(stabilityGot.count) expected=\(expectedPre.count)")
    exit(1)
}
print("stage 1 · computeStability · diffs=\(preDiffs) / \(expectedPre.count) maxAbs=\(maxPreAbsErr)")

// Stage 2 — eomSelect produces matching post-EOM dict + selected IDs.
let (selectedInternalIDs, stabilityPostEOM) = eomSelect(condensed: condensed, stability: stabilityGot)
var postDiffs = 0
var maxPostAbsErr: Double = 0
for (k, v) in expectedPost {
    let g = stabilityPostEOM[k] ?? .nan
    let err = abs(g - v)
    if err > maxPostAbsErr { maxPostAbsErr = err }
    if g != v { postDiffs += 1 }
}
print("stage 2a · stabilityPostEOM · diffs=\(postDiffs) / \(expectedPost.count) maxAbs=\(maxPostAbsErr)")

let selectedMatch = (selectedInternalIDs == expectedSelectedInternal)
print("stage 2b · selectedInternalClusterIDs · " +
      "match=\(selectedMatch) · got=\(selectedInternalIDs.count) expected=\(expectedSelectedInternal.count)")
if !selectedMatch {
    print("  got=\(selectedInternalIDs)")
    print("  expected=\(expectedSelectedInternal)")
}

// Stage 3 — doLabelling bit-exact vs labels.
var clusterMap = [Int: Int]()
var reverseClusterMap = [Int: Int]()
for (i, c) in selectedInternalIDs.enumerated() {
    clusterMap[c] = i
    reverseClusterMap[i] = c
}
let labelsGot = doLabelling(
    condensed: condensed,
    selectedClusters: Set(selectedInternalIDs),
    clusterMap: clusterMap
)
var labelDiffs = 0
for i in 0..<expectedLabels.count {
    if labelsGot[i] != expectedLabels[i] { labelDiffs += 1 }
}
print("stage 3 · doLabelling · diffs=\(labelDiffs) / \(expectedLabels.count)")
if labelDiffs > 0 {
    var samples: [(idx: Int, got: Int, exp: Int)] = []
    for i in 0..<expectedLabels.count where labelsGot[i] != expectedLabels[i] {
        samples.append((i, labelsGot[i], expectedLabels[i]))
        if samples.count >= 10 { break }
    }
    for s in samples { print("  point \(s.idx): got=\(s.got) expected=\(s.exp)") }
}

// Stage 4 — getProbabilities bit-exact vs probabilities (tol 1e-12).
let deaths = maxLambdas(condensed)
let probsGot = getProbabilities(
    condensed: condensed,
    reverseClusterMap: reverseClusterMap,
    labels: labelsGot,
    deaths: deaths
)
var probDiffs = 0
var maxProbAbsErr: Double = 0
for i in 0..<expectedProbs.count {
    let err = abs(probsGot[i] - expectedProbs[i])
    if err > maxProbAbsErr { maxProbAbsErr = err }
    if err > 1e-12 { probDiffs += 1 }
}
print("stage 4 · getProbabilities · diffs(>1e-12)=\(probDiffs) / \(expectedProbs.count) maxAbs=\(maxProbAbsErr)")

// Stage 5 — getStabilityScores bit-exact vs selectedClusterStabilityScores.
let (maxLam, maxLamIsInf) = maxLambdaInCondensed(condensed)
let stabScoresGot = getStabilityScores(
    labels: labelsGot,
    selectedInternalIDs: selectedInternalIDs,
    stability: stabilityPostEOM,
    maxLambda: maxLam,
    maxLambdaIsInfinite: maxLamIsInf
)
var stabScoreDiffs = 0
var maxStabAbsErr: Double = 0
for i in 0..<expectedStabScores.count {
    let err = abs(stabScoresGot[i] - expectedStabScores[i])
    if err > maxStabAbsErr { maxStabAbsErr = err }
    if stabScoresGot[i] != expectedStabScores[i] { stabScoreDiffs += 1 }
}
print("stage 5 · getStabilityScores · diffs=\(stabScoreDiffs) / \(expectedStabScores.count) maxAbs=\(maxStabAbsErr)")

let allGreen =
    preDiffs == 0 &&
    postDiffs == 0 &&
    selectedMatch &&
    labelDiffs == 0 &&
    probDiffs == 0 &&
    stabScoreDiffs == 0

if allGreen {
    print("cluster-selection PARITY OK · bit-exact across all five stages")
    exit(0)
} else {
    print("cluster-selection PARITY DRIFT · check diffs above")
    exit(0)
}
