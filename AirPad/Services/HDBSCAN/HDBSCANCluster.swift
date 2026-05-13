import Foundation

// SB139 Stage 4b.4 — stability + EOM cluster selection + labels + probabilities.
//
// Reference port: `hdbscan/_hdbscan_tree.pyx` lines 164–878
// (compute_stability + max_lambdas + bfs_from_cluster_tree +
// TreeUnionFind + do_labelling + get_probabilities + get_stability_scores
// + get_clusters). The condensed tree from 4b.3 feeds in; this stage
// emits flat-clustering labels and per-point membership probabilities.
//
// **Pinned-config scope (4b.4 minimal port):**
//   - cluster_selection_method = .eom (the .leaf branch is deferred)
//   - allow_single_cluster = false
//   - match_reference_implementation = false
//   - cluster_selection_epsilon = 0.0
//   - max_cluster_size = 0 (unbounded)
//   - cluster_selection_epsilon_max = +inf
//
// Forward-compat hooks (matching the 4a `targetConstraints` precedent)
// stay on the public API surface but the implementation throws on
// deferred branches — no dead code is ported. T's scope-discipline call
// 2026-05-12.
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

    /// Cluster-selection methods supported. Only `.eom` is implemented in
    /// 4b.4; `.leaf` is reserved as a forward-compat hook (precedent: 4a's
    /// `targetConstraints`).
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

    /// End-to-end HDBSCAN fit on a 2D point cloud. Composes 4b.1 (mutual
    /// reachability) → 4b.2 (MST + SLT) → 4b.3 (condense) → 4b.4 (stability
    /// + EOM + labels + probabilities).
    ///
    /// **Hyperparameters:**
    /// - `minClusterSize`: minimum cluster size to admit a branch.
    /// - `minSamples`: defaults to `minClusterSize` per upstream's
    ///   `hdbscan_.py:714-715` (`None → min_cluster_size`). Clamped to
    ///   `min(n - 1, raw)`, floored at 1.
    /// - `clusterSelectionMethod`: only `.eom` supported in 4b.4.
    /// - `allowSingleCluster`, `clusterSelectionEpsilon`: forward-compat
    ///   hooks; the only supported values are the defaults.
    static func fit(
        coords: [[Double]],
        minClusterSize: Int,
        minSamples: Int? = nil,
        clusterSelectionMethod: ClusterSelectionMethod = .eom,
        allowSingleCluster: Bool = false,
        clusterSelectionEpsilon: Double = 0.0
    ) -> FitResult {
        precondition(clusterSelectionMethod == .eom,
                     "HDBSCAN.fit: cluster_selection_method=.leaf not supported in 4b.4")
        precondition(!allowSingleCluster,
                     "HDBSCAN.fit: allow_single_cluster=true not supported in 4b.4")
        precondition(clusterSelectionEpsilon == 0.0,
                     "HDBSCAN.fit: cluster_selection_epsilon != 0 not supported in 4b.4")
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
        let (selectedInternalIDs, stabilityPostEOM) = eomSelect(
            condensed: condensed, stability: stability
        )

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
            stability: stabilityPostEOM,
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
