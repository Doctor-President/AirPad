import Foundation

// SB139 Stage 4b — HDBSCAN correctness checks fired from the dev inspect view.
//
// Mirrors `UMAPSelfTest` pattern: in-process assertions, no XCTest, returns
// a one-line summary suitable for inline display. Each phase of the HDBSCAN
// pipeline gets a parity test against the canonical Python `hdbscan`
// package via `hdbscan-reference-harness/`.
//
// Coverage:
//   Phase 4b.1 (mutual reachability) — T1-T3: hand-computed 4-point case
//                                             structural invariants on random fixture
//                                             min_points upstream clamp
//   Phase 4b.2 (MST + SLT)           — T4-T6: hand-computed MST on 4-point case
//                                             hand-computed SLT on same case
//                                             UnionFind path-compression invariants
//   Phase 4b.3 (condense_tree)       — T7:    hand-computed condense_tree on
//                                             4-point case at minClusterSize=1
//                                             (Case A throughout) and =2
//                                             (Cases B and D combined).
//   Phase 4b.4 (stability+EOM+labels) — T8:    hand-traced degenerate path
//                                             (4-point mcs=2 → all noise)
//                                             plus structural-invariant
//                                             check on a 9-point fixture
//                                             with three tight clusters.
//
// The host-side `swift_*_parity.swift` scripts are the heavyweight gates
// (n=200 fixture, bit-exact diff vs Python). The in-app cases here are
// lightweight regression tripwires: small inputs where expected values are
// obvious by inspection or follow from invariants.

@available(iOS 17.0, *)
@MainActor
enum HDBSCANSelfTest {

    static func run() -> String {
        var failures: [String] = []
        var ran = 0

        // T1 — hand-computed 4-point case (Phase 4b.1).
        // Points: (0,0) (1,0) (0,1) (5,5). Pairwise Euclidean distances:
        //   d(0,1)=1, d(0,2)=1, d(0,3)=√50,
        //   d(1,2)=√2, d(1,3)=√41, d(2,3)=√41.
        // With minPoints=2 (2nd-nearest other point, self at index 0):
        //   col 0 sorted [0, 1, 1, √50] → core[0] = 1.
        //   col 1 sorted [0, 1, √2, √41] → core[1] = √2.
        //   col 2 sorted [0, 1, √2, √41] → core[2] = √2.
        //   col 3 sorted [0, √41, √41, √50] → core[3] = √41.
        // Mutual reachability spot checks:
        //   mr[0,1] = max(1, √2, 1)   = √2
        //   mr[0,3] = max(1, √41, √50) = √50
        //   mr[1,2] = max(√2, √2, √2) = √2
        //   mr[1,3] = max(√2, √41, √41) = √41
        //   diagonal: mr[i,i] = core[i].
        ran += 1
        if let err = handComputedCase() {
            failures.append("T1: \(err)")
        }

        // T2 — structural invariants on a random fixture. Symmetric,
        // diagonal equals core distance, non-negative everywhere, finite
        // everywhere.
        ran += 1
        if let err = structuralInvariants(n: 25, dim: 2, minPoints: 5, seed: 0xA1B2C3D4) {
            failures.append("T2: \(err)")
        }

        // T3 — upstream clamp `min_points = min(n - 1, raw)`. Passing
        // minPoints = n (out of range) must clamp to n - 1 without trapping.
        // Mirrors `_hdbscan_reachability.pyx` line 43.
        ran += 1
        if let err = minPointsClamp() {
            failures.append("T3: \(err)")
        }

        // T4 — hand-computed MST on the 4-point case (Phase 4b.2.A).
        // Continuing from T1 (mr matrix established):
        //   Prim's iter 1: currentNode=0 → drop 0; left=[∞,∞,∞] vs
        //     right=[√2,√2,√50]; new dists=[√2,√2,√50]; argmin first=0
        //     → newNode=1, record (0,1,√2).
        //   Prim's iter 2: currentNode=1 → drop 1; left=[√2,√50] vs
        //     right=[√2,√41]; on tie at pos 0, right wins (√2); pos 1
        //     right wins (√41 < √50); new dists=[√2,√41]; argmin=0 →
        //     newNode=2, record (1,2,√2).
        //   Prim's iter 3: currentNode=2 → drop 2; left=[√41] vs
        //     right=[√41]; tie → right wins (√41); newNode=3, record
        //     (2,3,√41).
        ran += 1
        if let err = handComputedMST() {
            failures.append("T4: \(err)")
        }

        // T5 — hand-computed SLT on the same 4-point case (Phase 4b.2.C).
        // Sorted MST (stable): [(0,1,√2), (1,2,√2), (2,3,√41)] — ties
        // preserve discovery order.
        //   Row 0: fastFind(0)=0, fastFind(1)=1, size 1+1=2, union → 4.
        //   Row 1: fastFind(1)=4 (chase parent), fastFind(2)=2, size 2+1=3, union → 5.
        //   Row 2: fastFind(2)=5, fastFind(3)=3, size 3+1=4, union → 6.
        // Result: [(0,1,√2,2), (4,2,√2,3), (5,3,√41,4)].
        ran += 1
        if let err = handComputedSLT() {
            failures.append("T5: \(err)")
        }

        // T6 — UnionFind path-compression invariants. After fastFind on a
        // deeply-nested chain, the original node's parent must point
        // directly at the root. Also: fastFind on a root must not crash
        // (the Python negative-index quirk gate).
        ran += 1
        if let err = unionFindInvariants() {
            failures.append("T6: \(err)")
        }

        // T7 — hand-computed condense_tree on the same 4-point case
        // (Phase 4b.3). Two sub-cases exercise the four-case dispatch:
        //   minClusterSize=1 — every count ≥ 1, so Case A fires at every
        //     internal node. Six rows total — two per merge.
        //   minClusterSize=2 — exercises Case D at the top two merges
        //     (right child is a singleton) and Case B at the bottom merge
        //     (both children are leaves). Four rows total, all under
        //     parentLabel=4 (the root after relabel-inheritance chain).
        ran += 1
        if let err = handComputedCondenseTree() {
            failures.append("T7: \(err)")
        }

        // T8a — hand-traced 4-point degenerate path at mcs=2. Condensed
        // tree from T7's mcs=2 case has root cluster 4 with four singleton
        // children. EOM: nodeList = sorted([4], reverse).dropLast = [];
        // no clusters selected → labels all -1, probabilities all 0,
        // selectedClusterStabilityScores empty, selectedInternalClusterIDs
        // empty.
        ran += 1
        if let err = handComputedAllNoise() {
            failures.append("T8a: \(err)")
        }

        // T8b — structural invariants on a 9-point fixture with three
        // tight, well-separated clusters of 3 points each. At mcs=2 we
        // expect at least one non-noise cluster. Validates lengths,
        // label range, probability range, score count, and that selected
        // internal IDs are sorted ascending (renumbering precondition).
        ran += 1
        if let err = structuralInvariantsForFit() {
            failures.append("T8b: \(err)")
        }

        if failures.isEmpty {
            return "HDBSCAN self-test OK · \(ran) tests"
        } else {
            return "HDBSCAN self-test FAIL · \(failures.count) of \(ran) · " + failures.joined(separator: " | ")
        }
    }

    // MARK: - T1

    private static func handComputedCase() -> String? {
        let coords: [[Double]] = [
            [0, 0],
            [1, 0],
            [0, 1],
            [5, 5],
        ]
        let dist = HDBSCAN.pairwiseEuclideanDistance(coords)
        let core = HDBSCAN.coreDistances(distanceMatrix: dist, minPoints: 2)
        let mr = HDBSCAN.mutualReachability(distanceMatrix: dist, minPoints: 2)

        let sqrt2 = Double(2).squareRoot()
        let sqrt41 = Double(41).squareRoot()
        let sqrt50 = Double(50).squareRoot()

        // Bit-exact: every operation here (subtraction, multiplication,
        // sqrt) is IEEE-754 deterministic. Float `==` is the right
        // shape — drift would be a real bug, not noise.
        let expectedCore: [Double] = [1, sqrt2, sqrt2, sqrt41]
        for i in 0..<4 {
            if core[i] != expectedCore[i] {
                return "core[\(i)] got=\(core[i]) expected=\(expectedCore[i])"
            }
        }

        let expectedMR: [[Double]] = [
            [1,     sqrt2, sqrt2, sqrt50],
            [sqrt2, sqrt2, sqrt2, sqrt41],
            [sqrt2, sqrt2, sqrt2, sqrt41],
            [sqrt50, sqrt41, sqrt41, sqrt41],
        ]
        for i in 0..<4 {
            for j in 0..<4 {
                if mr[i][j] != expectedMR[i][j] {
                    return "mr[\(i),\(j)] got=\(mr[i][j]) expected=\(expectedMR[i][j])"
                }
            }
        }
        return nil
    }

    // MARK: - T2

    private static func structuralInvariants(n: Int, dim: Int, minPoints: Int, seed: UInt64) -> String? {
        var state = seed
        func next() -> Double {
            // SplitMix64-derived uniform [0,1) so the random fixture is
            // deterministic and reproducible without pulling in the
            // SubstrateLayoutService RNG. Mirrors UMAPRandom's pattern.
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z >> 11) / Double(1 << 53)
        }
        var coords = [[Double]]()
        coords.reserveCapacity(n)
        for _ in 0..<n {
            var row = [Double]()
            row.reserveCapacity(dim)
            for _ in 0..<dim { row.append(next()) }
            coords.append(row)
        }
        let dist = HDBSCAN.pairwiseEuclideanDistance(coords)
        let core = HDBSCAN.coreDistances(distanceMatrix: dist, minPoints: minPoints)
        let mr = HDBSCAN.mutualReachability(distanceMatrix: dist, minPoints: minPoints)

        for i in 0..<n {
            if mr[i][i] != core[i] {
                return "diagonal mr[\(i),\(i)]=\(mr[i][i]) expected core=\(core[i])"
            }
            for j in 0..<n {
                if mr[i][j] != mr[j][i] {
                    return "asymmetry mr[\(i),\(j)]=\(mr[i][j]) mr[\(j),\(i)]=\(mr[j][i])"
                }
                if mr[i][j] < 0 || !mr[i][j].isFinite {
                    return "non-finite/negative mr[\(i),\(j)]=\(mr[i][j])"
                }
            }
        }
        return nil
    }

    // MARK: - T3

    // MARK: - T4

    private static func handComputedMST() -> String? {
        let coords: [[Double]] = [[0, 0], [1, 0], [0, 1], [5, 5]]
        let dist = HDBSCAN.pairwiseEuclideanDistance(coords)
        let mr = HDBSCAN.mutualReachability(distanceMatrix: dist, minPoints: 2)
        let mst = HDBSCAN.mstLinkageCore(mr)

        let sqrt2 = Double(2).squareRoot()
        let sqrt41 = Double(41).squareRoot()

        let expected: [HDBSCAN.MSTEdge] = [
            HDBSCAN.MSTEdge(a: 0, b: 1, distance: sqrt2),
            HDBSCAN.MSTEdge(a: 1, b: 2, distance: sqrt2),
            HDBSCAN.MSTEdge(a: 2, b: 3, distance: sqrt41),
        ]
        if mst.count != expected.count {
            return "mst.count=\(mst.count) expected=\(expected.count)"
        }
        for i in 0..<expected.count {
            if mst[i] != expected[i] {
                return "mst[\(i)] got=(\(mst[i].a),\(mst[i].b),\(mst[i].distance)) " +
                       "expected=(\(expected[i].a),\(expected[i].b),\(expected[i].distance))"
            }
        }
        return nil
    }

    // MARK: - T5

    private static func handComputedSLT() -> String? {
        let coords: [[Double]] = [[0, 0], [1, 0], [0, 1], [5, 5]]
        let dist = HDBSCAN.pairwiseEuclideanDistance(coords)
        let mr = HDBSCAN.mutualReachability(distanceMatrix: dist, minPoints: 2)
        let slt = HDBSCAN.singleLinkageTree(mr)

        let sqrt2 = Double(2).squareRoot()
        let sqrt41 = Double(41).squareRoot()

        let expected: [HDBSCAN.SingleLinkageRow] = [
            HDBSCAN.SingleLinkageRow(a: 0, b: 1, distance: sqrt2, size: 2),
            HDBSCAN.SingleLinkageRow(a: 4, b: 2, distance: sqrt2, size: 3),
            HDBSCAN.SingleLinkageRow(a: 5, b: 3, distance: sqrt41, size: 4),
        ]
        if slt.count != expected.count {
            return "slt.count=\(slt.count) expected=\(expected.count)"
        }
        for i in 0..<expected.count {
            if slt[i] != expected[i] {
                return "slt[\(i)] got=(\(slt[i].a),\(slt[i].b),\(slt[i].distance),\(slt[i].size)) " +
                       "expected=(\(expected[i].a),\(expected[i].b),\(expected[i].distance),\(expected[i].size))"
            }
        }
        return nil
    }

    // MARK: - T6

    private static func unionFindInvariants() -> String? {
        // Build a 3-deep chain: 0 → 4 → 5 (root) via two unions.
        var uf = HDBSCAN.UnionFind(n: 4)

        // First call on a root must not crash and must return the node.
        let r0 = uf.fastFind(0)
        if r0 != 0 { return "fastFind(0) on fresh root got=\(r0) expected=0" }

        // Build the chain: union 0,1 → label 4. Union 4,2 → label 5.
        uf.union(0, 1)
        uf.union(4, 2)
        // parent[0]=4, parent[1]=4, parent[4]=5, parent[2]=5, parent[5]=-1.

        // fastFind on a chain-tail node should return the root AND
        // compress the path so parent[0] points directly at 5.
        let root = uf.fastFind(0)
        if root != 5 { return "fastFind(0) after chain got=\(root) expected=5" }
        if uf.parent[0] != 5 {
            return "path compression failed: parent[0]=\(uf.parent[0]) expected=5"
        }
        // node 4 (intermediate) should also point at 5 now, since it was
        // on the path. (Originally parent[4]=5 already, so no change.)
        if uf.parent[4] != 5 {
            return "parent[4] drift: got=\(uf.parent[4]) expected=5"
        }
        return nil
    }

    // MARK: - T7

    private static func handComputedCondenseTree() -> String? {
        let coords: [[Double]] = [[0, 0], [1, 0], [0, 1], [5, 5]]
        let dist = HDBSCAN.pairwiseEuclideanDistance(coords)
        let mr = HDBSCAN.mutualReachability(distanceMatrix: dist, minPoints: 2)
        let slt = HDBSCAN.singleLinkageTree(mr)

        let sqrt2 = Double(2).squareRoot()
        let sqrt41 = Double(41).squareRoot()
        let lam2 = 1.0 / sqrt2
        let lam41 = 1.0 / sqrt41

        // numPoints = 4, root = 6. BFS order over SLT: [6,5,3,4,2,0,1].
        // SLT rows: (0,1,√2,2), (4,2,√2,3), (5,3,√41,4).
        //
        // minClusterSize=1: every count ≥ 1, Case A at all three internal
        // nodes. nextLabel starts at 5 and ticks: 5,6,7,8,9,10.
        //   node 6 (row 2, λ=1/√41): relabel[5]=5, emit (4,5,1/√41,3);
        //                            relabel[3]=6, emit (4,6,1/√41,1).
        //   node 5 (row 1, λ=1/√2): relabel[4]=7, emit (5,7,1/√2,2);
        //                           relabel[2]=8, emit (5,8,1/√2,1).
        //   node 4 (row 0, λ=1/√2): relabel[0]=9, emit (7,9,1/√2,1);
        //                           relabel[1]=10, emit (7,10,1/√2,1).
        let condensedA = HDBSCAN.condenseTree(slt, minClusterSize: 1)
        let expectedA: [HDBSCAN.CondensedTreeRow] = [
            .init(parent: 4, child: 5, lambdaVal: lam41, isInfiniteLambda: false, childSize: 3),
            .init(parent: 4, child: 6, lambdaVal: lam41, isInfiniteLambda: false, childSize: 1),
            .init(parent: 5, child: 7, lambdaVal: lam2, isInfiniteLambda: false, childSize: 2),
            .init(parent: 5, child: 8, lambdaVal: lam2, isInfiniteLambda: false, childSize: 1),
            .init(parent: 7, child: 9, lambdaVal: lam2, isInfiniteLambda: false, childSize: 1),
            .init(parent: 7, child: 10, lambdaVal: lam2, isInfiniteLambda: false, childSize: 1),
        ]
        if condensedA.count != expectedA.count {
            return "mcs=1 row count got=\(condensedA.count) expected=\(expectedA.count)"
        }
        for i in 0..<expectedA.count {
            if condensedA[i] != expectedA[i] {
                return "mcs=1 row \(i) got=\(condensedA[i]) expected=\(expectedA[i])"
            }
        }

        // minClusterSize=2:
        //   node 6 (row 2, λ=1/√41): left=5,right=3; leftCount=3,rightCount=1.
        //     Case D — relabel[5]=4 (inherit), emit fallout for right=3:
        //     bfs([3])=[3], leaf → emit (4,3,1/√41,1), ignore[3]=true.
        //   node 5 (row 1, λ=1/√2): nodeLabel=relabel[5]=4. left=4,right=2;
        //     leftCount=2,rightCount=1. Case D — relabel[4]=4 (inherit),
        //     emit fallout for right=2: emit (4,2,1/√2,1), ignore[2]=true.
        //   node 4 (row 0, λ=1/√2): nodeLabel=relabel[4]=4. left=0,right=1;
        //     leftCount=1,rightCount=1. Case B — both runts. emit fallout
        //     for left=0: emit (4,0,1/√2,1). emit fallout for right=1:
        //     emit (4,1,1/√2,1).
        let condensedB = HDBSCAN.condenseTree(slt, minClusterSize: 2)
        let expectedB: [HDBSCAN.CondensedTreeRow] = [
            .init(parent: 4, child: 3, lambdaVal: lam41, isInfiniteLambda: false, childSize: 1),
            .init(parent: 4, child: 2, lambdaVal: lam2, isInfiniteLambda: false, childSize: 1),
            .init(parent: 4, child: 0, lambdaVal: lam2, isInfiniteLambda: false, childSize: 1),
            .init(parent: 4, child: 1, lambdaVal: lam2, isInfiniteLambda: false, childSize: 1),
        ]
        if condensedB.count != expectedB.count {
            return "mcs=2 row count got=\(condensedB.count) expected=\(expectedB.count)"
        }
        for i in 0..<expectedB.count {
            if condensedB[i] != expectedB[i] {
                return "mcs=2 row \(i) got=\(condensedB[i]) expected=\(expectedB[i])"
            }
        }
        return nil
    }

    // MARK: - T8a

    private static func handComputedAllNoise() -> String? {
        let coords: [[Double]] = [[0, 0], [1, 0], [0, 1], [5, 5]]
        let fit = HDBSCAN.fit(coords: coords, minClusterSize: 2)

        let expectedLabels = [-1, -1, -1, -1]
        if fit.labels != expectedLabels {
            return "labels got=\(fit.labels) expected=\(expectedLabels)"
        }
        let expectedProbs = [0.0, 0.0, 0.0, 0.0]
        if fit.probabilities != expectedProbs {
            return "probabilities got=\(fit.probabilities) expected=\(expectedProbs)"
        }
        if !fit.selectedClusterStabilityScores.isEmpty {
            return "selectedClusterStabilityScores not empty: \(fit.selectedClusterStabilityScores)"
        }
        if !fit.selectedInternalClusterIDs.isEmpty {
            return "selectedInternalClusterIDs not empty: \(fit.selectedInternalClusterIDs)"
        }
        return nil
    }

    // MARK: - T8b

    private static func structuralInvariantsForFit() -> String? {
        // Three tight clusters of 3 points each, far apart in 2D.
        let coords: [[Double]] = [
            [0.0, 0.0], [0.1, 0.0], [0.0, 0.1],          // cluster A near origin
            [10.0, 0.0], [10.1, 0.0], [10.0, 0.1],       // cluster B near (10,0)
            [0.0, 10.0], [0.1, 10.0], [0.0, 10.1],       // cluster C near (0,10)
        ]
        let fit = HDBSCAN.fit(coords: coords, minClusterSize: 2)
        let n = coords.count
        let k = fit.selectedInternalClusterIDs.count

        if fit.labels.count != n {
            return "labels.count=\(fit.labels.count) expected=\(n)"
        }
        if fit.probabilities.count != n {
            return "probabilities.count=\(fit.probabilities.count) expected=\(n)"
        }
        if fit.selectedClusterStabilityScores.count != k {
            return "scores.count=\(fit.selectedClusterStabilityScores.count) expected=\(k)"
        }
        for (i, label) in fit.labels.enumerated() {
            if label < -1 || label >= k {
                return "labels[\(i)]=\(label) out of range [-1, \(k))"
            }
        }
        for (i, p) in fit.probabilities.enumerated() {
            if p < 0 || p > 1 || !p.isFinite {
                return "probabilities[\(i)]=\(p) out of [0,1]"
            }
        }
        let ids = fit.selectedInternalClusterIDs
        for i in 1..<ids.count {
            if ids[i] <= ids[i - 1] {
                return "selectedInternalClusterIDs not sorted ascending: \(ids)"
            }
        }
        // Must find at least one non-noise label given the planted structure.
        if k > 0 && !fit.labels.contains(where: { $0 >= 0 }) {
            return "k=\(k) but no non-noise labels assigned"
        }
        return nil
    }

    // MARK: - T3

    private static func minPointsClamp() -> String? {
        // n=4 points; ask for minPoints=4 (out of range, must clamp to 3).
        let coords: [[Double]] = [[0, 0], [1, 0], [0, 1], [5, 5]]
        let dist = HDBSCAN.pairwiseEuclideanDistance(coords)
        // Unclamped call would trap on coreDistances precondition;
        // mutualReachability applies the clamp first.
        let mr = HDBSCAN.mutualReachability(distanceMatrix: dist, minPoints: 4)

        // With clamp → minPoints=3, core[j] = farthest distance from j
        // (3rd nearest other = last sorted index for n=4 with self at 0).
        // For point 0: max distance is √50 (to point 3) → core[0] = √50.
        let expectedCore0 = Double(50).squareRoot()
        if mr[0][0] != expectedCore0 {
            return "clamp failed: mr[0,0]=\(mr[0][0]) expected core[0]=\(expectedCore0)"
        }
        return nil
    }
}
