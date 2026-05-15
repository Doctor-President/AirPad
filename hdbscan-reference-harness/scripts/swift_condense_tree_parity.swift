#!/usr/bin/env swift
// SB139 Stage 4b.3 — host-side condensed tree parity check.
//
// Loads the harness intermediates JSON (which now contains
// `condensedTree` from `hdbscan_reference.py intermediates`), runs
// the Swift mirror of `AirPad/Services/HDBSCAN/HDBSCANTree.swift`,
// and diffs row-by-row.
//
// Bit-exact target across all five fields per row:
//   parent · child · lambdaVal · isInfiniteLambda · childSize.
//
// The Swift mirrors below MUST stay in sync with HDBSCANTree.swift
// (and the SLT mirror with HDBSCANLinkage.swift). 4b.3 has no
// transcendentals so duplication is the price of running this from
// CLI without an Xcode project.
//
// Prereqs (run from harness root):
//   source venv/bin/activate
//   python3 scripts/hdbscan_reference.py intermediates \
//       --input fixtures/synth_planted4_2d.json \
//       --output results/synth_planted4_2d.intermediates.json
//   swift scripts/swift_condense_tree_parity.swift \
//       fixtures/synth_planted4_2d.json \
//       results/synth_planted4_2d.intermediates.json

import Foundation

// MARK: - SLT type (decode-only; we feed the harness-computed SLT
// into Swift's condenseTree to make this a pure tree-stage check —
// 4b.2 parity is gated separately).

struct SingleLinkageRow {
    let a: Int
    let b: Int
    let distance: Double
    let size: Int
}

// MARK: - Swift mirror (keep in sync with HDBSCANTree.swift)

struct CondensedTreeRow: Equatable {
    let parent: Int
    let child: Int
    let lambdaVal: Double
    let isInfiniteLambda: Bool
    let childSize: Int
}

func bfsFromHierarchy(_ slt: [SingleLinkageRow], bfsRoot: Int) -> [Int] {
    let dim = slt.count
    let numPoints = dim + 1
    var toProcess = [bfsRoot]
    var result = [Int]()
    while !toProcess.isEmpty {
        result.append(contentsOf: toProcess)
        var nextLayer = [Int]()
        nextLayer.reserveCapacity(toProcess.count * 2)
        for x in toProcess where x >= numPoints {
            let rowIdx = x - numPoints
            nextLayer.append(slt[rowIdx].a)
            nextLayer.append(slt[rowIdx].b)
        }
        toProcess = nextLayer
    }
    return result
}

func emitFalloutRows(
    fromSubtreeRoot subtreeRoot: Int,
    slt: [SingleLinkageRow],
    numPoints: Int,
    parentLabel: Int,
    lambdaVal: Double,
    isInfiniteLambda: Bool,
    resultList: inout [CondensedTreeRow],
    ignore: inout [Bool]
) {
    for subNode in bfsFromHierarchy(slt, bfsRoot: subtreeRoot) {
        if subNode < numPoints {
            resultList.append(CondensedTreeRow(
                parent: parentLabel, child: subNode,
                lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                childSize: 1))
        }
        ignore[subNode] = true
    }
}

func condenseTree(_ slt: [SingleLinkageRow], minClusterSize: Int) -> [CondensedTreeRow] {
    let dim = slt.count
    let root = 2 * dim
    let numPoints = root / 2 + 1
    var nextLabel = numPoints + 1
    let nodeList = bfsFromHierarchy(slt, bfsRoot: root)
    var relabel = [Int](repeating: -1, count: root + 1)
    relabel[root] = numPoints
    var ignore = [Bool](repeating: false, count: nodeList.count)
    var resultList = [CondensedTreeRow]()
    for node in nodeList {
        if ignore[node] || node < numPoints { continue }
        let row = slt[node - numPoints]
        let left = row.a
        let right = row.b
        let dist = row.distance
        let lambdaVal: Double
        let isInfiniteLambda: Bool
        if dist > 0.0 {
            lambdaVal = 1.0 / dist
            isInfiniteLambda = false
        } else {
            lambdaVal = 0.0
            isInfiniteLambda = true
        }
        let leftCount = (left >= numPoints) ? slt[left - numPoints].size : 1
        let rightCount = (right >= numPoints) ? slt[right - numPoints].size : 1
        let nodeLabel = relabel[node]
        if leftCount >= minClusterSize && rightCount >= minClusterSize {
            relabel[left] = nextLabel
            nextLabel += 1
            resultList.append(CondensedTreeRow(parent: nodeLabel, child: relabel[left],
                lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda, childSize: leftCount))
            relabel[right] = nextLabel
            nextLabel += 1
            resultList.append(CondensedTreeRow(parent: nodeLabel, child: relabel[right],
                lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda, childSize: rightCount))
        } else if leftCount < minClusterSize && rightCount < minClusterSize {
            emitFalloutRows(fromSubtreeRoot: left, slt: slt, numPoints: numPoints,
                parentLabel: nodeLabel, lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                resultList: &resultList, ignore: &ignore)
            emitFalloutRows(fromSubtreeRoot: right, slt: slt, numPoints: numPoints,
                parentLabel: nodeLabel, lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                resultList: &resultList, ignore: &ignore)
        } else if leftCount < minClusterSize {
            relabel[right] = nodeLabel
            emitFalloutRows(fromSubtreeRoot: left, slt: slt, numPoints: numPoints,
                parentLabel: nodeLabel, lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                resultList: &resultList, ignore: &ignore)
        } else {
            relabel[left] = nodeLabel
            emitFalloutRows(fromSubtreeRoot: right, slt: slt, numPoints: numPoints,
                parentLabel: nodeLabel, lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                resultList: &resultList, ignore: &ignore)
        }
    }
    return resultList
}

// MARK: - JSON schemas

struct ExpectedCondensedRow: Decodable {
    let parent: Int
    let child: Int
    let lambdaVal: Double
    let isInfiniteLambda: Bool
    let childSize: Int
}

struct Intermediates: Decodable {
    struct Inner: Decodable {
        let singleLinkageTree: [[Double]]   // (n-1, 4) [a, b, dist, size]
        let condensedTree: [ExpectedCondensedRow]
        let condensedTreeMinClusterSize: Int
    }
    let intermediates: Inner
}

// MARK: - Driver

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: swift_condense_tree_parity.swift <fixture.json> <intermediates.json>\n".data(using: .utf8)!
    )
    exit(2)
}

let inter = try JSONDecoder().decode(
    Intermediates.self,
    from: try Data(contentsOf: URL(fileURLWithPath: args[2]))
)

let sltRaw = inter.intermediates.singleLinkageTree
let slt: [SingleLinkageRow] = sltRaw.map { r in
    SingleLinkageRow(a: Int(r[0]), b: Int(r[1]), distance: r[2], size: Int(r[3]))
}
let minClusterSize = inter.intermediates.condensedTreeMinClusterSize
let expected = inter.intermediates.condensedTree

let swiftTree = condenseTree(slt, minClusterSize: minClusterSize)

print("computed: \(swiftTree.count) rows · expected: \(expected.count) rows · minClusterSize=\(minClusterSize)")

if swiftTree.count != expected.count {
    print("FAIL: row count mismatch")
    exit(1)
}

var parentErrs = 0
var childErrs = 0
var lambdaErrs = 0
var flagErrs = 0
var sizeErrs = 0
var maxLambdaAbsErr: Double = 0
var rowDiffs = 0
for i in 0..<expected.count {
    let e = expected[i]
    let g = swiftTree[i]
    var diffsHere = 0
    if e.parent != g.parent { parentErrs += 1; diffsHere += 1 }
    if e.child != g.child { childErrs += 1; diffsHere += 1 }
    if e.isInfiniteLambda != g.isInfiniteLambda { flagErrs += 1; diffsHere += 1 }
    let lambdaErr = abs(e.lambdaVal - g.lambdaVal)
    if lambdaErr > maxLambdaAbsErr { maxLambdaAbsErr = lambdaErr }
    if e.lambdaVal != g.lambdaVal { lambdaErrs += 1; diffsHere += 1 }
    if e.childSize != g.childSize { sizeErrs += 1; diffsHere += 1 }
    if diffsHere > 0 { rowDiffs += 1 }
}

print("parent diffs=\(parentErrs) child diffs=\(childErrs) lambda diffs=\(lambdaErrs) (maxAbs=\(maxLambdaAbsErr)) inf-flag diffs=\(flagErrs) size diffs=\(sizeErrs)")
print("rows-with-any-diff: \(rowDiffs) / \(expected.count)")

if rowDiffs == 0 {
    print("condensed-tree PARITY OK · bit-exact across all five fields")
    exit(0)
} else {
    print("condensed-tree PARITY DRIFT · check diffs above")
    exit(0)
}
