import Foundation

// SB139 Stage 4a — UMAP data structures.
//
// Carries the persisted fitted-model state across app launches. UMAP fitting
// is heavy; we run it deliberately (corpus genesis, manual re-fit via dev
// inspect view in 4a, Inbox-prompted refresh in 4d) and persist the result.
// New nodes project through the saved model without re-optimizing positions.
//
// Persistence format: JSON via `Codable`. Chosen over binary plist because
// substrate compute dominates load time and JSON makes the model directly
// inspectable from the dev view. The training-set vector array is the bulk
// of file size; at 206 nodes × 512 floats × ~10 chars/float ≈ ~1MB.
// Acceptable. Re-evaluate if corpus grows past ~10K nodes.

// `SubstrateCoord2D` lives in `Models/SubstrateCoord2D.swift` — it's shared
// with the AirPadShare target via Node, so it sits next to Node rather than
// in this UMAP-internal file.

// MARK: - Hyperparameters

/// UMAP fit hyperparameters. Defaults match `umap-learn` so the C++
/// reference harness can be configured identically when generating golden
/// outputs.
///
/// `targetConstraints` is the cluster-blessing forward-compat hook
/// (Consultation #1, 2026-05-12). 4a's UMAP implementation precondition-
/// asserts this is nil; the parameter slot exists so cluster-blessing, if
/// it ever activates, doesn't require an API or schema migration.
struct UMAPHyperparameters: Codable, Hashable {
    /// Output dimensionality. Fixed at 2 for canvas use. Parameterized for
    /// validation against the C++ reference at other dimensionalities.
    var nComponents: Int
    /// k for the k-NN graph. UMAP default 15.
    var nNeighbors: Int
    /// Minimum spacing between projected points. UMAP default 0.1.
    var minDist: Double
    /// "Tightness" of the embedding around minDist. UMAP default 1.0.
    var spread: Double
    /// Initial learning rate for SGD optimization. UMAP default 1.0.
    var learningRate: Double
    /// Negative samples per positive sample in SGD. UMAP default 5.
    var negativeSampleRate: Int
    /// Total optimization epochs. UMAP default: scales with corpus
    /// size (200 for small, 500 for large). Nil = auto-pick at fit time.
    var nEpochs: Int?

    static let `default` = UMAPHyperparameters(
        nComponents: 2,
        nNeighbors: 15,
        minDist: 0.1,
        spread: 1.0,
        learningRate: 1.0,
        negativeSampleRate: 5,
        nEpochs: nil
    )
}

// MARK: - Target constraints (cluster-blessing forward-compat)

/// SB139 Consultation #1 — API-surface hook for `target_metric`-style
/// supervised UMAP. Not implemented in 4a. The
/// [cluster-blessing-deferred](Ops/workstreams/ws-cluster-blessing-deferred.md)
/// concept, if it activates, will populate this from accepted/rejected
/// cluster blessings; UMAP fit will then warp the neighbor graph toward
/// the blessed structure.
///
/// 4a's `SubstrateLayoutService.fit` precondition-asserts this is nil. The
/// parameter exists so no migration is needed if cluster-blessing ships.
struct TargetConstraints: Hashable {
    /// Cluster-class assignment per node ID. `0` is conventionally
    /// reserved for "unconstrained / no signal" so callers can include
    /// every node without forcing a constraint on most of them.
    let clusterClassByNodeID: [String: Int]
}

// MARK: - Fitted model

/// SB139 Stage 4a — persisted UMAP fit state.
///
/// Snapshot of everything needed to (a) reproduce the same 2D coords for
/// the training set across app launches, and (b) project new nodes through
/// the saved model via the project-through-saved-model path.
///
/// `fitVersion` bumps on every full re-fit. Each Node's
/// `substrateLayoutVersion` records the `fitVersion` it was projected
/// against, so we can detect stale coords against the active model.
struct UMAPFittedModel: Codable {
    /// Schema version of this Codable shape. Bumps when fields are added,
    /// removed, or change semantics — distinct from `fitVersion`, which
    /// bumps per-fit-instance. The decoder consults this first to dispatch
    /// future migrations. Mirrors `Node.embeddingVersion` schema-foresight.
    var schemaVersion: Int
    /// Monotonic per-app-install version. Starts at 1 on first fit.
    /// Bumps on every full re-fit. Persisted in the JSON so post-load
    /// matches against `Node.substrateLayoutVersion` work across launches.
    var fitVersion: Int
    /// Wall-clock at fit time. Diagnostic; not load-bearing.
    var fittedAt: Date
    /// Hyperparameters this model was fit with. Future re-fits should
    /// either match or explicitly invalidate.
    var hyperparameters: UMAPHyperparameters
    /// Seeded RNG state at fit-start. Saved so the same input produces
    /// the same coords on re-fit. Persisted as `[UInt64]` of length 4 to
    /// reserve room for a future xoshiro256**-shaped state without a
    /// schema migration. Stage 4a's UMAP machinery (MT19937-64 +
    /// SplitMix64) is single-seed; `UMAP.fit` consumes element [0]
    /// only — the remaining 3 elements are reserved-but-unused under
    /// the current RNG. Schema-locked in step 5 slice C.
    var rngSeed: [UInt64]
    /// Input dimensionality of the substrate vectors used at fit time
    /// (typically 512 for `NLContextualEmbedding(.english)`). Validated
    /// at load time against the current embedder dimension.
    var inputDimension: Int
    /// `find_ab` attractor-curve coefficients used during SGD optimization.
    /// Derived deterministically from `hyperparameters.minDist`/`spread`,
    /// so technically recomputable — persisted anyway for forward-compat
    /// with future SGD-based newcomer projection (Stage 4 design's "local
    /// force-directed nudge"), and to lock fit-time values against any
    /// future find_ab refinement.
    var a: Double
    /// Counterpart to `a`. See `a`.
    var b: Double
    /// Per-node training inputs and outputs. Order matters: indices into
    /// this array correspond to indices in the internal k-NN graph.
    var trainingPoints: [TrainingPoint]

    /// Per-node fit record: the 512-dim vector that went in, the projected
    /// coord that came out, and the canonical node ID this point represents.
    ///
    /// **SB139 Stage 4c2 c3 — N-D generalization.** `coordND` replaces the
    /// 4a/4b `coord2D` field so the model can carry projections at any
    /// `hyperparameters.nComponents`. Today every fit still runs at 2D
    /// (canvas display); consumers read `coord2D` via the computed
    /// accessor. The relaxation is architectural insurance for a future
    /// mid-D clustering pass or embedder swap (a 10D mid-D pivot was
    /// implemented + reverted same day after the diagnostic confirmed
    /// `NLContextualEmbedding`'s variance — not the projection dim — is
    /// the cluster-count ceiling). Custom `Codable` migrates v1 records
    /// (which serialized a `coord2D` object) to v2 (`coordND` array) at
    /// decode time so on-disk fits from before this change continue to
    /// load.
    struct TrainingPoint: Codable {
        var nodeID: String
        var inputVector: [Float]
        var coordND: [Float]

        /// 2D shorthand for canvas-display consumers. Reads the first two
        /// elements of `coordND`; precondition fails if the projection is
        /// 1D (which UMAP.fit doesn't produce — `nNeighbors` lower bound
        /// keeps the minimum useful `nComponents` at 2).
        var coord2D: SubstrateCoord2D {
            precondition(coordND.count >= 2, "TrainingPoint.coord2D requires coordND.count >= 2")
            return SubstrateCoord2D(x: coordND[0], y: coordND[1])
        }

        init(nodeID: String, inputVector: [Float], coordND: [Float]) {
            self.nodeID = nodeID
            self.inputVector = inputVector
            self.coordND = coordND
        }

        private enum CodingKeys: String, CodingKey {
            case nodeID, inputVector, coordND, coord2D
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.nodeID = try c.decode(String.self, forKey: .nodeID)
            self.inputVector = try c.decode([Float].self, forKey: .inputVector)
            if let nd = try c.decodeIfPresent([Float].self, forKey: .coordND) {
                self.coordND = nd
            } else {
                // v1 migration: legacy file shipped only `coord2D`.
                let xy = try c.decode(SubstrateCoord2D.self, forKey: .coord2D)
                self.coordND = [xy.x, xy.y]
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(nodeID, forKey: .nodeID)
            try c.encode(inputVector, forKey: .inputVector)
            try c.encode(coordND, forKey: .coordND)
        }
    }

    /// Current `schemaVersion` to stamp on freshly-fit models. Bump in
    /// lockstep with shape changes; older values trigger migration at
    /// load time. v2 — TrainingPoint emits `coordND: [Float]` instead of
    /// `coord2D: SubstrateCoord2D`; v1 decode is migrated transparently.
    static let currentSchemaVersion: Int = 2
}

// MARK: - Errors

enum UMAPError: Error, CustomStringConvertible {
    case noFittedModel
    case nodeLacksSubstrateVector(nodeID: String)
    case dimensionMismatch(expected: Int, got: Int)
    case persistenceFailed(underlying: Error)
    case loadFailed(underlying: Error)
    case targetConstraintsUnsupported
    case notImplementedIn4aScaffolding(step: String)

    var description: String {
        switch self {
        case .noFittedModel:
            return "No fitted UMAP model loaded. Run fit(allNodes:) first."
        case .nodeLacksSubstrateVector(let id):
            return "Node \(id) has no substrate vector available for UMAP."
        case .dimensionMismatch(let expected, let got):
            return "UMAP input dimension mismatch: expected \(expected), got \(got)."
        case .persistenceFailed(let err):
            return "UMAP persistence failed: \(err)"
        case .loadFailed(let err):
            return "UMAP load failed: \(err)"
        case .targetConstraintsUnsupported:
            return "Supervised UMAP (targetConstraints) is not implemented in Stage 4a — cluster-blessing remains deferred."
        case .notImplementedIn4aScaffolding(let step):
            return "UMAP \(step) is scaffolded but not yet implemented. See SB139 Stage 4a sub-tasks."
        }
    }
}
