import Foundation

// SB139 Stage 4b — HDBSCAN entry points.
//
// Thin namespace over the HDBSCAN pipeline. Sibling module to `UMAP`;
// consumes UMAP's 2D coords (`SubstrateLayoutService` outputs) and
// produces cluster labels + membership probabilities. The actual
// algorithm splits into discrete files landing per sub-step:
//
// - `HDBSCANReachability.swift` (4b.1, shipped): pairwise Euclidean
//   distance → core distance per point → mutual reachability matrix.
// - `HDBSCANLinkage.swift` (4b.2, shipped): minimum spanning tree via
//   Prim's on the mutual reachability matrix; UnionFind label() →
//   single-linkage tree.
// - `HDBSCANTree.swift` (4b.3, shipped): condense the single-linkage tree.
// - `HDBSCANCluster.swift` (4b.4): EOM cluster selection,
//   point-to-cluster labelling, membership probabilities.
//
// Reference: Python `hdbscan` package (scikit-learn-contrib), with
// pinned `algorithm='generic'` and `match_reference_implementation=False`.
// Per-phase parity validated against
// `hdbscan-reference-harness/scripts/swift_*_parity.swift`.
//
// Self-tests live in `HDBSCANSelfTest.swift`, surfaced via the
// `SubstrateInspectView` dev affordance.

@available(iOS 17.0, *)
enum HDBSCAN {
    // Top-level `fit` lands at 4b.4 once all four phases compose.
    // For 4b.1 the public surface is the mutual reachability primitives
    // in `HDBSCANReachability.swift`.
}
