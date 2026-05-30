import Foundation

// SB139 Stage 4b.4 — stability + EOM cluster selection + labels + probabilities.
//
// Reference port: `hdbscan/_hdbscan_tree.pyx` lines 164–878
// (compute_stability + max_lambdas + bfs_from_cluster_tree +
// TreeUnionFind + do_labelling + get_probabilities + get_stability_scores
// + get_clusters). The condensed tree from 4b.3 feeds in; this stage
// emits flat-clustering labels and per-point membership probabilities.
//
// **Supported config (4b.4 + leaf-on-8d extension):**
//   - cluster_selection_method = .eom OR .leaf
//   - cluster_selection_epsilon = 0.0 OR positive (epsilon-merge of
//     EOM-selected or leaf-selected clusters; mirrors upstream
//     `_epsilon_search_fast`)
//   - allow_single_cluster = false (forward-compat hook only)
//   - match_reference_implementation = false
//   - max_cluster_size = 0 (unbounded)
//   - cluster_selection_epsilon_max = +inf
//
// Leaf + epsilon land together because the substrate diagnostic
// (2026-05-29 cluster-cut-sweep) proved the post-whitening-fix
// 112-node residual is a cut-policy artifact, not a density-gap
// ceiling: EOM on the same vectors picks 2 clusters, leaf surfaces
// 7–12 title-coherent regions. See
// `feedback_nlcontextual_embedding_cluster_ceiling`.
//
// `allow_single_cluster` stays gated — no caller needs it yet.
//
// **FMA discipline:** stability accumulator
// `result_arr[i] += (λ - births[parent]) * child_size` (line 235 upstream)
// is one C statement that clang will FMA-contract; Swift mirrors with
// `addingProduct` per the 4a feedback memory rule.
//
// **TreeUnionFind ≠ Linkage UnionFind.** Upstream uses two distinct
// union-find variants: this stage uses union-by-rank with recursive
// path compression; 4b.2's `UnionFind` uses union-by-size with
// iterative path compression. Independent struct, no reuse.
//
// **Strict-greater EOM tie-break** (line 826 upstream):
// `subtree_stability > stability[node]` ⇒ children win; tie ⇒ parent wins.
// Mirrored exactly.
//
// **Cluster ID renumbering** (line 871 upstream):
// `cluster_map = {c: n for n, c in enumerate(sorted(list(clusters)))}`.
// Selected internal IDs sorted ascending → renumbered 0..k-1. These
// renumbered IDs are NOT stable across re-fits; the cross-fit identity
// machinery (bipartite max-overlap, 70% threshold) belongs to the
// `SubstrateCluster` persistence layer, not HDBSCAN itself.
//
// Validated against
// `hdbscan-reference-harness/scripts/swift_cluster_parity.swift`.

@available(iOS 17.0, *)
extension HDBSCAN {

    // MARK: - Public result envelope

    /// Cluster-selection methods. EOM keeps the largest stable ancestor
    /// when a parent's stability exceeds the sum of its children's. LEAF
    /// keeps every leaf node of the cluster tree (rows with `childSize >
    /// 1`), surfacing finer structure where EOM would collapse it into
    /// the ancestor. See `feedback_nlcontextual_embedding_cluster_ceiling`
    /// for why AirPad's substrate needs leaf.
    enum ClusterSelectionMethod: String, Codable {
        case eom
        case leaf
    }

    /// Final flat-clustering result. Per-point arrays are length n.
    /// `selectedClusterStabilityScores` is length k (renumbered cluster
    /// count); index `i` is the score for cluster `i`, where cluster `i`
    /// originates from internal ID `selectedInternalClusterIDs[i]`.
    struct FitResult: Equatable {
        let labels: [Int]
        let probabilities: [Double]
        let selectedClusterStabilityScores: [Double]
        let selectedInternalClusterIDs: [Int]
        let condensedTree: [CondensedTreeRow]
    }

    // MARK: - TreeUnionFind

    /// Union-find with union-by-rank + recursive path compression.
    /// Mirrors `TreeUnionFind` from `_hdbscan_tree.pyx` lines 304-338.
    /// The 4b.2 `UnionFind` is union-by-size and lives in HDBSCANLinkage;
    /// these are independent, do not share.
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
            if rank[xRoot] < rank[yRoot] {
                parent[xRoot] = yRoot
            } else if rank[xRoot] > rank[yRoot] {
                parent[yRoot] = xRoot
            } else {
                parent[yRoot] = xRoot
                rank[xRoot] += 1
            }
        }

        mutating func find(_ x: Int) -> Int {
            if parent[x] != x {
                parent[x] = find(parent[x])
            }
            return parent[x]
        }
    }

    // MARK: - compute_stability

    /// Per-cluster raw stability values.
    ///
    /// Mirrors `compute_stability` from `_hdbscan_tree.pyx` lines 164-241.
    /// Returns `{internalClusterID: stability}` for every internal cluster
    /// (root inclusive). The root cluster's stability is 0 by definition
    /// (`births[smallest_cluster] = 0.0` then no row has the root as a
    /// child, so the accumulator never fires for it... wait, that's not
    /// right — the root IS a parent of its first-level children, so
    /// `result_arr[0]` does accumulate).
    static func computeStability(_ condensed: [CondensedTreeRow]) -> [Int: Double] {
        precondition(!condensed.isEmpty, "HDBSCAN.computeStability: empty condensed tree")

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

        // births[c] = min lambda across rows where c is the child. Built by
        // sorting (child, lambda) ascending and scanning. Each leaf and
        // each non-root internal cluster appears as a child exactly once,
        // so the scan reads a single (child, lambda) pair per id. Sort key
        // mirrors numpy's structured `np.sort(... axis=0)`: primary child,
        // tie-break lambda. (Ties on (child, lambda) don't occur — children
        // are unique in the condensed tree.)
        var childLambdaPairs = condensed.map {
            (child: $0.child, lambda: $0.isInfiniteLambda ? Double.infinity : $0.lambdaVal)
        }
        childLambdaPairs.sort { a, b in
            if a.child != b.child { return a.child < b.child }
            return a.lambda < b.lambda
        }

        var births = [Double](repeating: .nan, count: largestChild + 1)
        var currentChild = -1
        var minLambda: Double = 0
        for pair in childLambdaPairs {
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
        if currentChild != -1 {
            births[currentChild] = minLambda
        }
        births[smallestCluster] = 0.0

        var resultArr = [Double](repeating: 0, count: numClusters)
        for r in condensed {
            let lambda_ = r.isInfiniteLambda ? Double.infinity : r.lambdaVal
            let resultIndex = r.parent - smallestCluster
            // FMA mirror of upstream's one-statement `+=` (line 235).
            // C: result_arr[i] += (λ - births[p]) * child_size; clang
            // contracts to fused multiply-add. Swift contracts only via
            // explicit addingProduct.
            let delta = lambda_ - births[r.parent]
            resultArr[resultIndex] = resultArr[resultIndex]
                .addingProduct(delta, Double(r.childSize))
        }

        var result = [Int: Double]()
        result.reserveCapacity(numClusters)
        for i in 0..<numClusters {
            result[smallestCluster + i] = resultArr[i]
        }
        return result
    }

    // MARK: - max_lambdas

    /// Per-parent max lambda (the "deaths" array consumed by
    /// `getProbabilities`). Mirrors `max_lambdas` from `_hdbscan_tree.pyx`
    /// lines 259-301. Indexed by parent ID; entries for non-parent IDs
    /// stay 0.
    static func maxLambdas(_ condensed: [CondensedTreeRow]) -> [Double] {
        var largestParent = 0
        for r in condensed {
            if r.parent > largestParent { largestParent = r.parent }
        }
        var deaths = [Double](repeating: 0, count: largestParent + 1)

        // Sort (parent, lambda) ascending. Ties on parent allowed; max is
        // associative/commutative so order within group is irrelevant.
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
        if currentParent != -1 {
            deaths[currentParent] = maxLambda
        }
        return deaths
    }

    // MARK: - EOM selection

    /// BFS walk over the cluster_tree (rows with `childSize > 1`) starting
    /// at `bfsRoot`. Returns visited internal cluster IDs in layer order.
    /// Mirrors `bfs_from_cluster_tree` from `_hdbscan_tree.pyx` lines 244-256.
    private static func bfsFromClusterTree(
        _ clusterTree: [CondensedTreeRow], bfsRoot: Int
    ) -> [Int] {
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

    /// EOM cluster selection. Mirrors the `eom` branch of `get_clusters`
    /// at `_hdbscan_tree.pyx` lines 820-832 under our pinned config.
    ///
    /// Returns the sorted-ascending list of selected internal cluster IDs
    /// and the post-EOM stability dict (mutated for ELIMINATED parents
    /// only — selected clusters' values are unchanged).
    ///
    /// **Strict-greater tie-break:** `subtree_stability > stability[node]`
    /// kills the parent. Ties keep the parent and kill descendants.
    static func eomSelect(
        condensed: [CondensedTreeRow],
        stability: [Int: Double]
    ) -> (selectedInternalIDs: [Int], stabilityPostEOM: [Int: Double]) {
        var stab = stability
        let clusterTree = condensed.filter { $0.childSize > 1 }
        // node_list = sorted(stability.keys(), reverse=True)[:-1]
        // — descending by internal ID, drop the smallest (root cluster).
        var nodeList = stab.keys.sorted(by: >)
        if !nodeList.isEmpty {
            nodeList.removeLast()
        }
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
                for subNode in bfsFromClusterTree(clusterTree, bfsRoot: node) {
                    if subNode != node {
                        isCluster[subNode] = false
                    }
                }
            }
        }

        let selected = isCluster
            .filter { $0.value }
            .map { $0.key }
            .sorted()
        return (selected, stab)
    }

    // MARK: - Leaf selection

    /// Build `{parent: [children]}` from the cluster_tree rows. Mirrors
    /// `_build_parent_to_children` from `_hdbscan_tree.pyx` lines 643-655.
    private static func buildParentToChildren(_ clusterTree: [CondensedTreeRow]) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for r in clusterTree {
            result[r.parent, default: []].append(r.child)
        }
        return result
    }

    /// Build `{child: (parent, lambda_val)}` from the cluster_tree rows.
    /// Mirrors `_build_child_lookup` from `_hdbscan_tree.pyx` lines 658-666.
    /// Lambda is the row's death lambda (where the child detached from
    /// its parent); 1/lambda is its ε.
    private static func buildChildLookup(
        _ clusterTree: [CondensedTreeRow]
    ) -> [Int: (parent: Int, lambda: Double)] {
        var result: [Int: (parent: Int, lambda: Double)] = [:]
        for r in clusterTree {
            let lam = r.isInfiniteLambda ? Double.infinity : r.lambdaVal
            result[r.child] = (r.parent, lam)
        }
        return result
    }

    /// BFS over a parent→children dict. Mirrors `_bfs_from_dict` from
    /// `_hdbscan_tree.pyx` lines 669-681. Used by `epsilonSearchFast` to
    /// mark sub-nodes as processed when a leaf climbs to an ancestor.
    private static func bfsFromDict(_ parentToChildren: [Int: [Int]], root: Int) -> [Int] {
        var result: [Int] = []
        var toProcess = [root]
        while !toProcess.isEmpty {
            result.append(contentsOf: toProcess)
            var nextLayer: [Int] = []
            for node in toProcess {
                if let children = parentToChildren[node] {
                    nextLayer.append(contentsOf: children)
                }
            }
            toProcess = nextLayer
        }
        return result
    }

    /// DFS finding leaves of the cluster_tree (internal cluster nodes
    /// with no further-subdivided children). Mirrors
    /// `_get_leaves_from_dict` from `_hdbscan_tree.pyx` lines 684-694.
    private static func getLeavesFromDict(_ parentToChildren: [Int: [Int]], root: Int) -> [Int] {
        var leaves: [Int] = []
        var stack = [root]
        while let node = stack.popLast() {
            if let children = parentToChildren[node] {
                stack.append(contentsOf: children)
            } else {
                leaves.append(node)
            }
        }
        return leaves
    }

    /// Climb up from `leaf`, returning the first ancestor whose birth-ε
    /// exceeds `clusterSelectionEpsilon`. Stops if we reach the
    /// cluster_tree root (no ancestor crosses the threshold) — under
    /// `allowSingleCluster=false` we return the most-recent below-ε node
    /// rather than collapsing to the root. Iterative to avoid the
    /// recursion in upstream's `_traverse_upwards_fast`
    /// (`_hdbscan_tree.pyx` lines 697-716).
    private static func traverseUpwardsFast(
        childLookup: [Int: (parent: Int, lambda: Double)],
        clusterSelectionEpsilon: Double,
        leaf: Int,
        allowSingleCluster: Bool,
        root: Int
    ) -> Int {
        var current = leaf
        while true {
            guard let info = childLookup[current] else { return current }
            let parent = info.parent
            if parent == root {
                return allowSingleCluster ? parent : current
            }
            guard let parentInfo = childLookup[parent] else { return current }
            let parentEps = 1.0 / parentInfo.lambda
            if parentEps > clusterSelectionEpsilon {
                return parent
            }
            current = parent
        }
    }

    /// Epsilon-merge a candidate set of clusters: any cluster whose own
    /// birth-ε is below the threshold climbs to its first above-threshold
    /// ancestor and substitutes; sub-nodes of that ancestor are marked
    /// processed so they're not re-emitted as siblings. Mirrors
    /// `_epsilon_search_fast` from `_hdbscan_tree.pyx` lines 719-745.
    /// Applies symmetrically to EOM-selected and leaf-selected sets.
    private static func epsilonSearchFast(
        leaves: Set<Int>,
        childLookup: [Int: (parent: Int, lambda: Double)],
        parentToChildren: [Int: [Int]],
        clusterSelectionEpsilon: Double,
        allowSingleCluster: Bool,
        root: Int
    ) -> Set<Int> {
        var selectedClusters: [Int] = []
        var processed: Set<Int> = []
        for leaf in leaves {
            guard let info = childLookup[leaf] else { continue }
            let eps = 1.0 / info.lambda
            if eps < clusterSelectionEpsilon {
                if !processed.contains(leaf) {
                    let epsilonChild = traverseUpwardsFast(
                        childLookup: childLookup,
                        clusterSelectionEpsilon: clusterSelectionEpsilon,
                        leaf: leaf,
                        allowSingleCluster: allowSingleCluster,
                        root: root
                    )
                    selectedClusters.append(epsilonChild)
                    for subNode in bfsFromDict(parentToChildren, root: epsilonChild) where subNode != epsilonChild {
                        processed.insert(subNode)
                    }
                }
            } else {
                selectedClusters.append(leaf)
            }
        }
        return Set(selectedClusters)
    }

    /// Leaf cluster selection. Mirrors the `leaf` branch of `get_clusters`
    /// at `_hdbscan_tree.pyx` lines 1013-1034.
    ///
    /// Unlike EOM, leaf selection does NOT mutate the stability dict —
    /// no parent's stability is reassigned to its subtree sum, because
    /// leaf selects the bottom of every tree branch by construction.
    /// Returns the sorted-ascending internal cluster IDs. The empty-tree
    /// fallback is degenerate (returns empty); under `allowSingleCluster
    /// = false` upstream collapses to no selection in that case too.
    static func leafSelect(
        condensed: [CondensedTreeRow],
        clusterSelectionEpsilon: Double = 0.0
    ) -> [Int] {
        let clusterTree = condensed.filter { $0.childSize > 1 }
        if clusterTree.isEmpty { return [] }

        let parentToChildren = buildParentToChildren(clusterTree)
        let childLookup = buildChildLookup(clusterTree)
        guard let ctRoot = clusterTree.map(\.parent).min() else { return [] }

        let leaves = Set(getLeavesFromDict(parentToChildren, root: ctRoot))
        if leaves.isEmpty { return [] }

        let selected: Set<Int>
        if clusterSelectionEpsilon != 0.0 {
            selected = epsilonSearchFast(
                leaves: leaves,
                childLookup: childLookup,
                parentToChildren: parentToChildren,
                clusterSelectionEpsilon: clusterSelectionEpsilon,
                allowSingleCluster: false,
                root: ctRoot
            )
        } else {
            selected = leaves
        }
        return selected.sorted()
    }

    /// Apply an epsilon-merge pass over the EOM-selected set. Used only
    /// when both `cluster_selection_method == .eom` and
    /// `clusterSelectionEpsilon > 0`. Mirrors the EOM-post-process block
    /// at `_hdbscan_tree.pyx` lines 996-1011.
    static func epsilonMergeEOMSelection(
        eomSelected: [Int],
        condensed: [CondensedTreeRow],
        clusterSelectionEpsilon: Double
    ) -> [Int] {
        let clusterTree = condensed.filter { $0.childSize > 1 }
        if clusterTree.isEmpty || eomSelected.isEmpty { return eomSelected }

        let parentToChildren = buildParentToChildren(clusterTree)
        let childLookup = buildChildLookup(clusterTree)
        guard let ctRoot = clusterTree.map(\.parent).min() else { return eomSelected }

        // Upstream: if EOM selected only the cluster_tree root, skip
        // epsilon entirely (allowSingleCluster=false → keep EOM selection
        // as-is so we don't accidentally promote anything).
        if eomSelected.count == 1 && eomSelected[0] == ctRoot {
            return eomSelected
        }

        let merged = epsilonSearchFast(
            leaves: Set(eomSelected),
            childLookup: childLookup,
            parentToChildren: parentToChildren,
            clusterSelectionEpsilon: clusterSelectionEpsilon,
            allowSingleCluster: false,
            root: ctRoot
        )
        return merged.sorted()
    }

    // MARK: - do_labelling

    /// Assign each leaf point to a renumbered cluster ID (or -1 for noise).
    /// Mirrors `do_labelling` from `_hdbscan_tree.pyx` lines 418-485 under
    /// pinned config (no `allow_single_cluster`, no
    /// `match_reference_implementation`).
    static func doLabelling(
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
        let numPoints = rootCluster  // by condense_tree's construction

        var uf = TreeUnionFind(size: maxParent + 1)
        for r in condensed {
            if !selectedClusters.contains(r.child) {
                uf.union(r.parent, r.child)
            }
        }

        var result = [Int](repeating: -1, count: numPoints)
        for n in 0..<numPoints {
            let cluster = uf.find(n)
            if cluster < rootCluster {
                // Unreachable under our setup (root_cluster == numPoints,
                // leaves are < root_cluster, and union by rank promotes
                // higher-rank roots). Defensive -1 matches upstream.
                result[n] = -1
            } else if cluster == rootCluster {
                // Component rooted at the tree root — point has no
                // selected-cluster ancestor → noise.
                result[n] = -1
            } else {
                result[n] = clusterMap[cluster] ?? -1
            }
        }
        return result
    }

    // MARK: - get_probabilities

    /// Per-point membership probability. Mirrors `get_probabilities` from
    /// `_hdbscan_tree.pyx` lines 488-526.
    /// Edge case: `deaths[cluster] == 0` OR `λ` infinite → probability 1.0.
    static func getProbabilities(
        condensed: [CondensedTreeRow],
        reverseClusterMap: [Int: Int],
        labels: [Int],
        deaths: [Double]
    ) -> [Double] {
        var rootCluster = Int.max
        for r in condensed {
            if r.parent < rootCluster { rootCluster = r.parent }
        }
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

    // MARK: - get_stability_scores

    /// Per-selected-cluster normalized stability. Mirrors
    /// `get_stability_scores` from `_hdbscan_tree.pyx` lines 587-601.
    ///
    /// Result length = number of selected clusters (k). Index i is the
    /// score for renumbered cluster i.
    static func getStabilityScores(
        labels: [Int],
        selectedInternalIDs: [Int],
        stability: [Int: Double],
        maxLambda: Double,
        maxLambdaIsInfinite: Bool
    ) -> [Double] {
        let k = selectedInternalIDs.count
        var result = [Double](repeating: 1.0, count: k)
        // cluster_size = sum(labels == n) per renumbered label n.
        var sizeByLabel = [Int](repeating: 0, count: k)
        for x in labels where x >= 0 && x < k {
            sizeByLabel[x] += 1
        }
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

    /// Helper: `np.max(tree['lambda_val'])` under our split-encoding
    /// schema. Returns (maxFiniteValue, anyInfinite). When `anyInfinite`
    /// is true, the Python `np.isinf(max_lambda)` check fires regardless
    /// of the finite max.
    static func maxLambdaInCondensed(_ condensed: [CondensedTreeRow]) -> (max: Double, isInfinite: Bool) {
        var maxVal: Double = 0
        var anyInfinite = false
        for r in condensed {
            if r.isInfiniteLambda {
                anyInfinite = true
                continue
            }
            if r.lambdaVal > maxVal { maxVal = r.lambdaVal }
        }
        return (maxVal, anyInfinite)
    }

    // MARK: - Orchestrator

    /// End-to-end HDBSCAN fit on an N-D point cloud. Composes 4b.1 (mutual
    /// reachability) → 4b.2 (MST + SLT) → 4b.3 (condense) → 4b.4 (stability
    /// + EOM/leaf selection + labels + probabilities). Dimension-agnostic
    /// via `pairwiseEuclideanDistance`.
    ///
    /// **Hyperparameters:**
    /// - `minClusterSize`: minimum cluster size to admit a branch.
    /// - `minSamples`: defaults to `minClusterSize` per upstream's
    ///   `hdbscan_.py:714-715` (`None → min_cluster_size`). Clamped to
    ///   `min(n - 1, raw)`, floored at 1.
    /// - `clusterSelectionMethod`: `.eom` (default) or `.leaf`. See the
    ///   enum doc — leaf is the AirPad substrate path post-2026-05-29.
    /// - `clusterSelectionEpsilon`: ε threshold below which adjacent
    ///   selected clusters merge to their first above-ε ancestor.
    ///   Default 0 = no merge.
    /// - `allowSingleCluster`: not yet supported. Precondition-asserted
    ///   false; the slot exists for forward-compat parity with upstream.
    static func fit(
        coords: [[Double]],
        minClusterSize: Int,
        minSamples: Int? = nil,
        clusterSelectionMethod: ClusterSelectionMethod = .eom,
        allowSingleCluster: Bool = false,
        clusterSelectionEpsilon: Double = 0.0
    ) -> FitResult {
        precondition(!allowSingleCluster,
                     "HDBSCAN.fit: allow_single_cluster=true not yet supported")
        precondition(clusterSelectionEpsilon >= 0.0,
                     "HDBSCAN.fit: cluster_selection_epsilon must be >= 0")
        let n = coords.count
        precondition(n >= 2, "HDBSCAN.fit: need at least 2 points")

        // min_samples resolution mirrors hdbscan_.py:714-715.
        let raw = minSamples ?? minClusterSize
        var minPoints = Swift.min(n - 1, raw)
        if minPoints == 0 { minPoints = 1 }

        let distanceMatrix = pairwiseEuclideanDistance(coords)
        let mr = mutualReachability(distanceMatrix: distanceMatrix, minPoints: minPoints)
        let slt = singleLinkageTree(mr)
        let condensed = condenseTree(slt, minClusterSize: minClusterSize)

        let stability = computeStability(condensed)

        // Branch on selection method. EOM optionally post-merges with
        // epsilon; LEAF takes leaves of the cluster_tree and (if eps > 0)
        // merges below-ε leaves up to their first above-ε ancestor.
        // Stability dict is mutated only by EOM (parents whose subtree
        // outscores them get reassigned to subtree-sum) — leaf reads
        // stability unchanged for the per-cluster score pass below.
        let selectedInternalIDs: [Int]
        let stabilityForScoring: [Int: Double]
        switch clusterSelectionMethod {
        case .eom:
            let (eomSelected, stabilityPostEOM) = eomSelect(
                condensed: condensed, stability: stability
            )
            if clusterSelectionEpsilon > 0 {
                selectedInternalIDs = epsilonMergeEOMSelection(
                    eomSelected: eomSelected,
                    condensed: condensed,
                    clusterSelectionEpsilon: clusterSelectionEpsilon
                )
            } else {
                selectedInternalIDs = eomSelected
            }
            stabilityForScoring = stabilityPostEOM
        case .leaf:
            selectedInternalIDs = leafSelect(
                condensed: condensed,
                clusterSelectionEpsilon: clusterSelectionEpsilon
            )
            stabilityForScoring = stability
        }

        var clusterMap = [Int: Int]()
        var reverseClusterMap = [Int: Int]()
        clusterMap.reserveCapacity(selectedInternalIDs.count)
        reverseClusterMap.reserveCapacity(selectedInternalIDs.count)
        for (i, c) in selectedInternalIDs.enumerated() {
            clusterMap[c] = i
            reverseClusterMap[i] = c
        }

        let labels = doLabelling(
            condensed: condensed,
            selectedClusters: Set(selectedInternalIDs),
            clusterMap: clusterMap
        )
        let deaths = maxLambdas(condensed)
        let probabilities = getProbabilities(
            condensed: condensed,
            reverseClusterMap: reverseClusterMap,
            labels: labels,
            deaths: deaths
        )
        let (maxLam, maxLamIsInf) = maxLambdaInCondensed(condensed)
        let stabilityScores = getStabilityScores(
            labels: labels,
            selectedInternalIDs: selectedInternalIDs,
            stability: stabilityForScoring,
            maxLambda: maxLam,
            maxLambdaIsInfinite: maxLamIsInf
        )

        return FitResult(
            labels: labels,
            probabilities: probabilities,
            selectedClusterStabilityScores: stabilityScores,
            selectedInternalClusterIDs: selectedInternalIDs,
            condensedTree: condensed
        )
    }
}
