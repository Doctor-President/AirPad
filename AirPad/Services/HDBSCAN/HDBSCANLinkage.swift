import Foundation

// SB139 Stage 4b.2 — MST + single-linkage tree.
//
// Reference port: `hdbscan/_hdbscan_linkage.pyx`. Three substance blocks:
//
//   - `mst_linkage_core(distance_matrix)` — Prim's on the dense mutual
//     reachability matrix. Returns `(n-1, 3)` rows
//     `[current_node, new_node, distance]`. NOTE: `current_node` is the
//     most-recently-added tree node, not necessarily the actual MST
//     source of `new_node` — `label()` only consumes UF-find of each
//     endpoint, so the distinction doesn't matter downstream. We mirror
//     the upstream recording convention bit-exactly so the per-row
//     pre-sort dump (`mstEdges` in the harness) is comparable.
//
//   - `UnionFind` — parent/size arrays of length `2N-1`, `next_label`
//     starts at `N`, union assigns `next_label` as new common parent
//     and increments. `fast_find` walks to root then path-compresses.
//
//   - `label(L)` — for each (sorted) edge, record
//     `[fast_find(a), fast_find(b), distance, size[aa] + size[bb]]`,
//     then union.
//
// Three divergence hazards from upstream tie-breaking, all mirrored:
//
//   1. `np.where(left < right, left, right)`: strict `<` → on equality
//      `right` (the new direct distance from `current_node`) wins.
//   2. `np.argmin(current_distances)`: first occurrence on ties — i.e.
//      lowest index in the (filtered) `current_labels` array wins.
//   3. Sort before label. Upstream uses `np.argsort` with default
//      kind (unstable, introsort). The harness pins `kind='stable'`
//      (timsort) and we mirror with index as a secondary key. On
//      `synth_planted4_2d.json` 14/199 MST edges share distances, so
//      we're inside tie territory — pinning stable makes the gate
//      deterministic on both sides. At 4b.4 we re-verify cluster
//      labels against `hdbscan.fit()` (which uses the default unstable
//      sort); at `min_cluster_size=8` the drift surface from these 14
//      ties is not expected to move any label.
//
// Validated against
// `hdbscan-reference-harness/scripts/swift_single_linkage_tree_parity.swift`.

@available(iOS 17.0, *)
extension HDBSCAN {

    /// MST edge in Prim discovery order. `a` is the most-recently-added
    /// tree node at the time `b` was selected (NOT a textbook MST
    /// source). Mirrors upstream `mst_linkage_core` recording.
    struct MSTEdge: Equatable {
        let a: Int
        let b: Int
        let distance: Double
    }

    /// Single-linkage tree row. `a` and `b` are UF labels (may be
    /// original-node IDs `< n` or merged-cluster labels `>= n`).
    /// Mirrors the `(n-1, 4)` array upstream's `label()` returns.
    struct SingleLinkageRow: Equatable {
        let a: Int
        let b: Int
        let distance: Double
        let size: Int
    }

    /// UnionFind variant from `_hdbscan_linkage.pyx::UnionFind`.
    ///
    /// `parent` and `size` are sized `2N - 1` because every label() call
    /// produces N-1 merges, each minting a new label `>= N`. `next_label`
    /// starts at N and increments per union. `parent[i] == -1` means
    /// `i` is a root.
    struct UnionFind {
        var parent: [Int]
        var size: [Int]
        var nextLabel: Int

        init(n: Int) {
            precondition(n >= 1, "HDBSCAN.UnionFind: n must be positive")
            self.parent = [Int](repeating: -1, count: 2 * n - 1)
            self.size = [Int](repeating: 1, count: n) + [Int](repeating: 0, count: n - 1)
            self.nextLabel = n
        }

        mutating func union(_ m: Int, _ n: Int) {
            // Upstream sets size[next_label] twice (once at top, once
            // again at the bottom of the method); the second is dead
            // code. We mirror the effective behavior.
            size[nextLabel] = size[m] + size[n]
            parent[m] = nextLabel
            parent[n] = nextLabel
            nextLabel += 1
        }

        /// Find with path compression. Mirrors the upstream tuple-swap
        /// pattern: walk to root, then set every node on the original
        /// path to point directly at root.
        ///
        /// Subtle divergence from upstream: the Python implementation's
        /// path-compression loop also fires when `node` is itself a
        /// root (`parent[node] == -1`). In that case the loop performs
        /// a stray write to `parent_arr[-1]`, which numpy interprets as
        /// the last array entry (`parent_arr[2N - 2]`) — a slot that is
        /// never observed downstream (label() doesn't reuse parent_arr
        /// after the merge). In Swift, `-1` would crash on subscript,
        /// so we gate the compression loop on `node != root`. The
        /// returned root is identical and no observable state diverges.
        mutating func fastFind(_ node: Int) -> Int {
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

    /// Prim's MST on a dense distance matrix.
    ///
    /// Returns `n - 1` edges in discovery order. Mirrors
    /// `mst_linkage_core` line-for-line including the right-wins-on-equal
    /// update and first-wins argmin.
    ///
    /// - Parameter distanceMatrix: n × n symmetric. Typically the
    ///   mutual reachability matrix from `HDBSCAN.mutualReachability`.
    /// - Returns: array of `n - 1` `MSTEdge` values in discovery order.
    static func mstLinkageCore(_ distanceMatrix: [[Double]]) -> [MSTEdge] {
        let n = distanceMatrix.count
        precondition(n > 1, "HDBSCAN.mstLinkageCore: need at least 2 points")

        var result = [MSTEdge]()
        result.reserveCapacity(n - 1)

        // Mirror upstream invariants:
        //   currentLabels: out-of-tree nodes (initially [0..<n], includes
        //     currentNode=0 which gets filtered on first iter).
        //   currentDistances[k]: min mr distance from any tree node to
        //     currentLabels[k]. Initially infinity.
        var currentLabels = Array(0..<n)
        var currentDistances = [Double](repeating: .infinity, count: n)
        var currentNode = 0

        for _ in 1..<n {
            // np.where(current_labels != current_node) — boolean mask
            // preserves order. Drop current_node and its distance entry.
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

            // Fuse the np.where update and the argmin into one pass.
            // np.where(left < right, left, right) — strict less-than so
            // ties take `right` (the new direct distance).
            // np.argmin uses strict less-than → first index of min wins.
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

    /// Apply UnionFind labelling to a sorted-by-distance MST.
    ///
    /// Mirrors `label(L)` from `_hdbscan_linkage.pyx`. Each input edge
    /// `(a, b, dist)` produces an output row
    /// `(fast_find(a), fast_find(b), dist, size[aa] + size[bb])`,
    /// followed by `union(aa, bb)`.
    ///
    /// - Parameter sortedEdges: MST edges sorted ascending by distance.
    /// - Returns: `(sortedEdges.count)` single-linkage rows.
    static func label(_ sortedEdges: [MSTEdge]) -> [SingleLinkageRow] {
        let nEdges = sortedEdges.count
        precondition(nEdges >= 1, "HDBSCAN.label: empty edge list")
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

    /// Full Phase B + C pipeline: MST → stable sort by distance → label.
    ///
    /// Mirrors `single_linkage(distance_matrix)` from
    /// `_hdbscan_linkage.pyx`. The sort uses original MST index as a
    /// secondary key to emulate `np.argsort(kind='stable')`. See the
    /// file header for the divergence note on upstream's default sort.
    ///
    /// - Parameter distanceMatrix: mutual reachability matrix.
    /// - Returns: `(n - 1)` single-linkage rows in sorted order.
    static func singleLinkageTree(_ distanceMatrix: [[Double]]) -> [SingleLinkageRow] {
        let edges = mstLinkageCore(distanceMatrix)
        // Stable sort: pair each edge with its discovery index, sort
        // by (distance, index), strip the index. Swift's sort is not
        // stable, but the secondary key makes the result deterministic.
        var indexed = edges.enumerated().map { (idx: $0.offset, edge: $0.element) }
        indexed.sort { lhs, rhs in
            if lhs.edge.distance != rhs.edge.distance {
                return lhs.edge.distance < rhs.edge.distance
            }
            return lhs.idx < rhs.idx
        }
        let sortedEdges = indexed.map { $0.edge }
        return label(sortedEdges)
    }
}
