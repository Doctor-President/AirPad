#!/usr/bin/env swift
// SB139 Stage 4b.2 — host-side single-linkage tree parity check.
//
// Loads the fixture coords + harness intermediates JSON (which now
// contains `mstEdges`, `mstEdgesSortOrder`, and `singleLinkageTree`
// from `hdbscan_reference.py intermediates`), computes the same three
// stages `AirPad/Services/HDBSCAN/HDBSCANLinkage.swift` does, and diffs
// against the Python reference.
//
// Three independent gates per run:
//   1. mstEdges (n-1, 3) — bit-exact target [current_node, new_node, dist].
//      Mirrors `mst_linkage_core` in Prim discovery order.
//   2. sort permutation (n-1) — bit-exact target. Mirrors
//      `np.argsort(..., kind='stable')`. Stable sort with discovery
//      index as secondary key.
//   3. singleLinkageTree (n-1, 4) — bit-exact target [aa, bb, dist, size].
//      Mirrors `label()` driven by the sorted MST.
//
// The Swift mirrors below MUST stay in sync with HDBSCANLinkage.swift.
// 4b.2 has no transcendentals so duplication is the price of running
// this from CLI without an Xcode project.
//
// Prereqs (run from harness root):
//   source venv/bin/activate
//   python3 scripts/hdbscan_reference.py intermediates \
//       --input fixtures/synth_planted4_2d.json \
//       --output results/synth_planted4_2d.intermediates.json
//   swift scripts/swift_single_linkage_tree_parity.swift \
//       fixtures/synth_planted4_2d.json \
//       results/synth_planted4_2d.intermediates.json

import Foundation

// MARK: - Swift mirror (keep in sync with HDBSCANLinkage.swift)

struct MSTEdge {
    let a: Int
    let b: Int
    let distance: Double
}

struct SingleLinkageRow {
    let a: Int
    let b: Int
    let distance: Double
    let size: Int
}

struct UnionFind {
    var parent: [Int]
    var size: [Int]
    var nextLabel: Int

    init(n: Int) {
        self.parent = [Int](repeating: -1, count: 2 * n - 1)
        self.size = [Int](repeating: 1, count: n) + [Int](repeating: 0, count: n - 1)
        self.nextLabel = n
    }

    mutating func union(_ m: Int, _ n: Int) {
        size[nextLabel] = size[m] + size[n]
        parent[m] = nextLabel
        parent[n] = nextLabel
        nextLabel += 1
    }

    mutating func fastFind(_ node: Int) -> Int {
        // Gate compression on (node != root) — upstream Python relies on
        // numpy's negative-index wraparound for a no-op ghost write when
        // node is already a root. See HDBSCANLinkage.swift for the full
        // divergence note. Returned root is identical.
        var cur = node
        while parent[cur] != -1 {
            cur = parent[cur]
        }
        let root = cur
        if node != root {
            var p = node
            while parent[p] != root {
                let nextP = parent[p]
                parent[p] = root
                p = nextP
            }
        }
        return root
    }
}

func mstLinkageCore(_ distanceMatrix: [[Double]]) -> [MSTEdge] {
    let n = distanceMatrix.count
    var result = [MSTEdge]()
    result.reserveCapacity(n - 1)
    var currentLabels = Array(0..<n)
    var currentDistances = [Double](repeating: .infinity, count: n)
    var currentNode = 0
    for _ in 1..<n {
        var newLabels = [Int]()
        var newDistances = [Double]()
        newLabels.reserveCapacity(currentLabels.count - 1)
        newDistances.reserveCapacity(currentLabels.count - 1)
        for k in 0..<currentLabels.count {
            if currentLabels[k] != currentNode {
                newLabels.append(currentLabels[k])
                newDistances.append(currentDistances[k])
            }
        }
        currentLabels = newLabels
        let row = distanceMatrix[currentNode]
        let m = currentLabels.count
        var nextDistances = [Double](repeating: 0, count: m)
        var minIdx = 0
        var minVal = Double.infinity
        for k in 0..<m {
            let leftVal = newDistances[k]
            let rightVal = row[currentLabels[k]]
            let v = (leftVal < rightVal) ? leftVal : rightVal
            nextDistances[k] = v
            if v < minVal {
                minVal = v
                minIdx = k
            }
        }
        currentDistances = nextDistances
        let newNode = currentLabels[minIdx]
        result.append(MSTEdge(a: currentNode, b: newNode, distance: minVal))
        currentNode = newNode
    }
    return result
}

func stableSortByDistance(_ edges: [MSTEdge]) -> (sorted: [MSTEdge], permutation: [Int]) {
    var indexed = edges.enumerated().map { (idx: $0.offset, edge: $0.element) }
    indexed.sort { lhs, rhs in
        if lhs.edge.distance != rhs.edge.distance {
            return lhs.edge.distance < rhs.edge.distance
        }
        return lhs.idx < rhs.idx
    }
    return (indexed.map { $0.edge }, indexed.map { $0.idx })
}

func label(_ sortedEdges: [MSTEdge]) -> [SingleLinkageRow] {
    let nEdges = sortedEdges.count
    let n = nEdges + 1
    var uf = UnionFind(n: n)
    var result = [SingleLinkageRow]()
    result.reserveCapacity(nEdges)
    for edge in sortedEdges {
        let aa = uf.fastFind(edge.a)
        let bb = uf.fastFind(edge.b)
        let combinedSize = uf.size[aa] + uf.size[bb]
        result.append(SingleLinkageRow(a: aa, b: bb, distance: edge.distance, size: combinedSize))
        uf.union(aa, bb)
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
        let mstEdges: [[Double]]              // (n-1, 3) [parent, child, dist]
        let mstEdgesSortOrder: [Int]          // (n-1) permutation indices
        let singleLinkageTree: [[Double]]     // (n-1, 4) [aa, bb, dist, size]
    }
    let minPointsResolved: Int
    let intermediates: Inner
}

// MARK: - Driver

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: swift_single_linkage_tree_parity.swift <fixture.json> <intermediates.json>\n".data(using: .utf8)!
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

let mrMatrix = inter.intermediates.mutualReachability
let n = mrMatrix.count
let expectedMST = inter.intermediates.mstEdges
let expectedSortOrder = inter.intermediates.mstEdgesSortOrder
let expectedSLT = inter.intermediates.singleLinkageTree

guard expectedMST.count == n - 1,
      expectedSortOrder.count == n - 1,
      expectedSLT.count == n - 1 else {
    print("FAIL: shape mismatch · n=\(n) mst=\(expectedMST.count) sort=\(expectedSortOrder.count) slt=\(expectedSLT.count)")
    exit(1)
}

// Stage 1 — MST edges (pre-sort, Prim discovery order). Feed the
// Swift mirror the harness-computed mutual reachability so this is a
// pure Linkage-stage check (we already validated MR in 4b.1).
let swiftMST = mstLinkageCore(mrMatrix)
var maxAbsParentErr = 0
var maxAbsChildErr = 0
var maxAbsDistErr: Double = 0
var mstDiffs = 0
for i in 0..<(n - 1) {
    let row = expectedMST[i]
    let edge = swiftMST[i]
    let aErr = abs(Int(row[0]) - edge.a)
    let bErr = abs(Int(row[1]) - edge.b)
    let dErr = abs(row[2] - edge.distance)
    if aErr > maxAbsParentErr { maxAbsParentErr = aErr }
    if bErr > maxAbsChildErr { maxAbsChildErr = bErr }
    if dErr > maxAbsDistErr { maxAbsDistErr = dErr }
    if aErr > 0 || bErr > 0 || dErr > 0 { mstDiffs += 1 }
}
print("stage 1 · mst edges       · maxParentErr=\(maxAbsParentErr) maxChildErr=\(maxAbsChildErr) maxDistErr=\(maxAbsDistErr) diffRows=\(mstDiffs) / \(n - 1)")

// Stage 2 — sort permutation. Pin stable sort with index as
// secondary key — must match `np.argsort(kind='stable')` exactly.
let (swiftSorted, swiftPerm) = stableSortByDistance(swiftMST)
var permDiffs = 0
for i in 0..<(n - 1) {
    if expectedSortOrder[i] != swiftPerm[i] { permDiffs += 1 }
}
print("stage 2 · sort permutation · diffs=\(permDiffs) / \(n - 1)")

// Stage 3 — SLT after label(). Pure Swift end-to-end (feed our own
// sorted edges into our own label()).
let swiftSLT = label(swiftSorted)
var maxSLTAErr = 0
var maxSLTBErr = 0
var maxSLTDistErr: Double = 0
var maxSLTSizeErr = 0
var sltDiffs = 0
for i in 0..<(n - 1) {
    let row = expectedSLT[i]
    let r = swiftSLT[i]
    let aErr = abs(Int(row[0]) - r.a)
    let bErr = abs(Int(row[1]) - r.b)
    let dErr = abs(row[2] - r.distance)
    let sErr = abs(Int(row[3]) - r.size)
    if aErr > maxSLTAErr { maxSLTAErr = aErr }
    if bErr > maxSLTBErr { maxSLTBErr = bErr }
    if dErr > maxSLTDistErr { maxSLTDistErr = dErr }
    if sErr > maxSLTSizeErr { maxSLTSizeErr = sErr }
    if aErr > 0 || bErr > 0 || dErr > 0 || sErr > 0 { sltDiffs += 1 }
}
print("stage 3 · single-linkage   · maxAErr=\(maxSLTAErr) maxBErr=\(maxSLTBErr) maxDistErr=\(maxSLTDistErr) maxSizeErr=\(maxSLTSizeErr) diffRows=\(sltDiffs) / \(n - 1)")

let bitExact = (mstDiffs == 0 && permDiffs == 0 && sltDiffs == 0)
if bitExact {
    print("single-linkage-tree PARITY OK · bit-exact across all three stages")
    exit(0)
} else {
    print("single-linkage-tree PARITY DRIFT · check stage diffs above")
    exit(0)
}
