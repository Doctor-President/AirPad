import Foundation

// SB139 Stage 4b.3 — condense_tree.
//
// Reference port: `hdbscan/_hdbscan_tree.pyx` lines 14-161
// (`bfs_from_hierarchy` + `condense_tree`). The single-linkage tree
// from 4b.2 is condensed by collapsing "runt" branches whose child
// count falls below `min_cluster_size`. Output is an edge list
// `(parent, child, lambdaVal, isInfiniteLambda, childSize)` in
// BFS-from-root emission order.
//
// Algorithm shape (T-confirmed during source-read):
//
//   bfs_from_hierarchy(slt, root) produces a global BFS order over
//   the SLT, including internal AND leaf node IDs. Length = 2n - 1.
//
//   condense_tree walks that order. Each unignored internal node
//   dispatches by (leftCount, rightCount) against minClusterSize:
//
//     Case A — both ≥ : real bifurcation. Both children get fresh
//              `next_label`s; emit (parentLabel, childLabel, λ, count)
//              per child.
//     Case B — both <  : runt-runt. Parent dies. Emit one row per
//              leaf descendant of each subtree as
//              (parentLabel, leaf, λ, 1). Mark all sub_nodes ignored.
//     Case C — left <  : right continues the parent.
//              relabel[right] = relabel[node]. Left subtree's leaves
//              emit absorption rows. Right is revisited later by the
//              outer BFS loop with the inherited label.
//     Case D — right <  : symmetric.
//
//   lambdaValue = 1 / dist when dist > 0, else +infinity. The
//   infinity case lands at `isInfiniteLambda = true` with
//   `lambdaVal = 0.0` (schema-locked sentinel; the bool is the
//   source of truth).
//
// Persistence schema (locked by T 2026-05-12):
//   - schemaVersion lives on the envelope, not the row.
//   - Row: (parent: Int, child: Int, lambdaVal: Double,
//          isInfiniteLambda: Bool, childSize: Int).
//   - Rows preserved in BFS emission order on disk; sort only on display.
//
// No FMA-eligible patterns inside condense_tree itself. The flagged
// `result_arr[result_index] += (lambda_ - births[parent]) * child_size`
// lives in compute_stability (4b.4 territory).
//
// Validated against
// `hdbscan-reference-harness/scripts/swift_condense_tree_parity.swift`.

@available(iOS 17.0, *)
extension HDBSCAN {

    /// One row of the condensed tree edge list.
    ///
    /// Persisted to disk as part of `SubstrateCluster.condensedTree`.
    /// `Codable` conformance synthesizes JSON in the schema T locked
    /// in: `lambdaVal` carries `0.0` when `isInfiniteLambda == true`,
    /// the flag is the source of truth.
    struct CondensedTreeRow: Codable, Equatable {
        let parent: Int
        let child: Int
        let lambdaVal: Double
        let isInfiniteLambda: Bool
        let childSize: Int
    }

    /// Breadth-first traversal of the single-linkage tree rooted at
    /// `bfsRoot`, returning a flat list of node IDs in visitation order.
    ///
    /// Mirrors `bfs_from_hierarchy` from `_hdbscan_tree.pyx` lines 14-40.
    /// Internal node IDs are `≥ numPoints` (= slt.count + 1); leaf
    /// IDs are `< numPoints`. Internal nodes are mapped to their SLT
    /// row index via `id - numPoints`, then both children
    /// `(slt[idx].a, slt[idx].b)` are appended to the next layer.
    ///
    /// - Parameters:
    ///   - slt: single-linkage tree from `HDBSCAN.singleLinkageTree`.
    ///   - bfsRoot: starting node ID; typically `2 * (n - 1)` for a
    ///     full traversal from the root cluster.
    /// - Returns: visited node IDs in BFS order.
    static func bfsFromHierarchy(_ slt: [SingleLinkageRow], bfsRoot: Int) -> [Int] {
        let dim = slt.count
        let numPoints = dim + 1
        var toProcess = [bfsRoot]
        var result = [Int]()
        while !toProcess.isEmpty {
            result.append(contentsOf: toProcess)
            // Project the current frontier down to SLT row indices for
            // any internal nodes (drop leaves). Mirror numpy's row-major
            // flatten by appending (a, b) in order.
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

    /// Condense a single-linkage tree by collapsing branches whose
    /// child count falls below `minClusterSize`.
    ///
    /// Mirrors `condense_tree(hierarchy, min_cluster_size)` from
    /// `_hdbscan_tree.pyx` lines 43-161 bit-exactly.
    ///
    /// - Parameters:
    ///   - slt: single-linkage tree from `HDBSCAN.singleLinkageTree`.
    ///     Must have at least one row (n ≥ 2).
    ///   - minClusterSize: minimum child count to admit a branch as a
    ///     real cluster. Matches `min_cluster_size` upstream.
    /// - Returns: edge list in BFS emission order.
    static func condenseTree(
        _ slt: [SingleLinkageRow],
        minClusterSize: Int
    ) -> [CondensedTreeRow] {
        let dim = slt.count
        precondition(dim >= 1, "HDBSCAN.condenseTree: empty SLT")
        precondition(minClusterSize >= 1,
                     "HDBSCAN.condenseTree: minClusterSize must be ≥ 1, got \(minClusterSize)")

        let root = 2 * dim          // 2(n-1)
        let numPoints = root / 2 + 1 // n
        var nextLabel = numPoints + 1

        let nodeList = bfsFromHierarchy(slt, bfsRoot: root)

        // `relabel` is keyed by original-tree node ID (0..2n-2). Only
        // internal-node positions are written; leaf positions are
        // never read. Upstream uses np.empty (uninitialised); we
        // initialise to -1 for explicitness — never observed.
        var relabel = [Int](repeating: -1, count: root + 1)
        relabel[root] = numPoints

        var ignore = [Bool](repeating: false, count: nodeList.count)
        var resultList = [CondensedTreeRow]()

        for node in nodeList {
            if ignore[node] || node < numPoints {
                continue
            }
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
                lambdaVal = 0.0   // sentinel — the flag is truth
                isInfiniteLambda = true
            }

            let leftCount = (left >= numPoints) ? slt[left - numPoints].size : 1
            let rightCount = (right >= numPoints) ? slt[right - numPoints].size : 1

            let nodeLabel = relabel[node]

            if leftCount >= minClusterSize && rightCount >= minClusterSize {
                // Case A — both ≥ : real bifurcation.
                relabel[left] = nextLabel
                nextLabel += 1
                resultList.append(CondensedTreeRow(
                    parent: nodeLabel, child: relabel[left],
                    lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                    childSize: leftCount))
                relabel[right] = nextLabel
                nextLabel += 1
                resultList.append(CondensedTreeRow(
                    parent: nodeLabel, child: relabel[right],
                    lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                    childSize: rightCount))
            } else if leftCount < minClusterSize && rightCount < minClusterSize {
                // Case B — both < : runt-runt, parent dies.
                emitFalloutRows(
                    fromSubtreeRoot: left,
                    slt: slt, numPoints: numPoints,
                    parentLabel: nodeLabel,
                    lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                    resultList: &resultList, ignore: &ignore)
                emitFalloutRows(
                    fromSubtreeRoot: right,
                    slt: slt, numPoints: numPoints,
                    parentLabel: nodeLabel,
                    lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                    resultList: &resultList, ignore: &ignore)
            } else if leftCount < minClusterSize {
                // Case C — left < : right inherits the parent label.
                relabel[right] = nodeLabel
                emitFalloutRows(
                    fromSubtreeRoot: left,
                    slt: slt, numPoints: numPoints,
                    parentLabel: nodeLabel,
                    lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                    resultList: &resultList, ignore: &ignore)
            } else {
                // Case D — right < : left inherits.
                relabel[left] = nodeLabel
                emitFalloutRows(
                    fromSubtreeRoot: right,
                    slt: slt, numPoints: numPoints,
                    parentLabel: nodeLabel,
                    lambdaVal: lambdaVal, isInfiniteLambda: isInfiniteLambda,
                    resultList: &resultList, ignore: &ignore)
            }
        }
        return resultList
    }

    /// Helper: BFS the subtree at `subtreeRoot`, emit one fallout row
    /// per leaf descendant, mark every visited node as ignored.
    /// Centralises the Case B/C/D inner loop (upstream Python writes
    /// it inline; the duplication makes the case-dispatch read smaller
    /// in Swift).
    private static func emitFalloutRows(
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
}
