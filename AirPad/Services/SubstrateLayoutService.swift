import Foundation
import Observation

/// SB139 Stage 4a — Substrate-derived canvas layout service.
///
/// Sibling to `SubstrateService` (Stage 1's embedding/similarity layer).
/// This service owns the *projection* step: 512-dim substrate vectors → 2D
/// canvas coordinates via UMAP, persisted across app launches so layout is
/// session-stable.
///
/// **Stage 4a scope (this scaffolding):**
/// - API surface for `fit`, `project(node:)`, `persist`, `load`.
/// - Persistence path and Codable model defined.
/// - UMAP implementation is stubbed (precondition-throws); sub-steps land
///   discretely per the Stage 4a checkpoint discipline.
/// - Behind `FeatureFlags.substrateLayout` (default off). Canvas continues
///   to read tag-driven positions from `LayoutService` until 4c1 flag flip.
///
/// **Stage 4b adds** clustering on the 2D coords. **Stage 4c1 flips the
/// flag and routes the canvas read path through this service's outputs.**
///
/// **Threading:** `@MainActor` matches `SubstrateService`. The heavy
/// `fit()` call dispatches its inner compute to `Task.detached` so we
/// don't block main; the actor itself owns state mutation back on main.
@available(iOS 17.0, *)
@Observable
@MainActor
final class SubstrateLayoutService {

    // MARK: - Singleton

    static let shared = SubstrateLayoutService()

    private init() {}

    // MARK: - Auto-fit threshold (4c1)

    /// Minimum count of rankable nodes required for substrate to be applicable.
    /// UMAP's default `n_neighbors = 15` becomes degenerate near n ≈ neighbors
    /// (every point neighbors every other point); 30 = ~2× margin and enough
    /// density for HDBSCAN to potentially find structure. Conservative seed,
    /// not load-bearing — tunable as the corpus grows. `nonisolated` so it
    /// can be referenced from default-parameter expressions evaluated off the
    /// main actor.
    nonisolated static let autoFitMinNodeCount: Int = 30

    // MARK: - State

    /// Currently-loaded fitted UMAP model. Nil until `load()` finds one
    /// on disk or `fit()` produces a fresh one. `project(node:)` consults
    /// this directly.
    private(set) var fittedModel: UMAPFittedModel?

    /// SB139 Stage 4c1 — HDBSCAN cluster labels for the currently-loaded
    /// fitted model's training points. Index-aligned with
    /// `fittedModel.trainingPoints`. `-1` is the noise label. Recomputed
    /// whenever a fit completes or a model loads; cleared on `clear()`.
    private(set) var clusterLabels: [Int]?

    /// SB139 Stage 4c2 commit 1 — persistent UUIDs for the currently-loaded
    /// cluster labels. Index-aligned with `clusterLabels` and
    /// `fittedModel.trainingPoints`. `nil` for noise points and when no
    /// fit has run yet. Sourced from `SubstrateClusterRegistry` after each
    /// `runClustering()`; stable across refits when membership overlap
    /// holds. Consumers (color, label, future user-rename) key on this
    /// rather than the raw HDBSCAN label.
    private(set) var persistentClusterIDs: [UUID?]?

    /// SB139 Stage 4c1.1 — per-node HSB color, keyed by node ID. Computed
    /// by `SubstrateColoringPass` from current placements + cluster
    /// labels. Refreshed in lockstep with `clusterLabels` (same generation).
    private(set) var colorHSB: [String: SubstrateColoringPass.HSB]?

    /// SB139 Stage 4c2 — pre-resolved block-pooled substrate vectors,
    /// keyed by node ID. Populated by `preloadBlockPooledVectors`; consulted
    /// by `substrateVector(for:)` ahead of the legacy summary/folksonomy
    /// path. The diagnostic that motivated this swap showed block-pooled
    /// vectors widen the inter-node cosine distribution from p10–p90 = 0.095
    /// to 0.153, which is the geometric headroom HDBSCAN needs to break
    /// past the 2-cluster ceiling on NLContextualEmbedding's compressed
    /// summary embeddings. Cached because block sidecars are actor-loaded
    /// (async) but `substrateVector(for:)` is sync; caller pre-loads once
    /// per fit. Nil ⇒ legacy summary path for every node (preserves
    /// pre-4c2 behavior when nothing has been preloaded).
    private(set) var blockPooledVectors: [String: [Float]]?

    /// SB139 Stage 4c1.3 — display-space canvas positions produced by the
    /// tethered relaxation pass. Spans ALL canvas-displayed nodes (substrate
    /// fit + non-substrate stragglers), not just substrate placements:
    /// non-rankable/meta/unembedded nodes still need to be collision-resolved
    /// against substrate-fit nodes or the cross-class pairs visibly overlap.
    /// Caller (CanvasView) supplies the full truth + radii inputs; this
    /// service just caches the output and tags it with an input fingerprint
    /// so the next `ensureRelaxation` call skips when nothing changed.
    private(set) var displayCanvasPositions: [String: CanvasPosition]?

    /// Fingerprint of the inputs (truth positions + radii) that produced
    /// `displayCanvasPositions`. Used to short-circuit recomputation when
    /// the canvas re-syncs without underlying input change. Nil → no cache,
    /// always recompute.
    private var relaxationInputHash: Int?

    /// Monotonic pulse that bumps on every fit, load, runClustering, or clear.
    /// Views that derive layout/color from this service observe `generation`
    /// to trigger re-renders without subscribing to specific large fields.
    private(set) var generation: Int = 0

    /// Wall-clock when the loaded model was last fit or projected
    /// against. Diagnostic surface for the dev inspect view.
    private(set) var lastActivityAt: Date?

    /// `fitVersion` to use for the next fresh fit. Starts at 1 on first
    /// install; bumps every full re-fit so each Node's
    /// `substrateLayoutVersion` records which fit produced its coord.
    private var nextFitVersion: Int {
        (fittedModel?.fitVersion ?? 0) + 1
    }

    // MARK: - Substrate vector selection
    //
    // UMAP requires a single 512-dim vector per node. AirPad's substrate
    // exposes three channels: summary, folksonomy, content. We mirror the
    // pair-similarity blend `SubstrateService.pairSimilarity` already uses
    // for thread candidates and the dev inspect view — average(summary,
    // folksonomy), falling back to content when neither summary nor
    // folksonomy is present (refused/thin content cases). This keeps the
    // canvas layout consistent with the similarity metric users already
    // see in rankings, while preserving coverage on refused nodes via the
    // content fallback. 2026-05-11 checkpoint decision.

    /// Pull the 512-dim vector this service uses as UMAP input for a
    /// given node. Returns nil only when no substrate channel is present
    /// (un-processed node, embedder load failure, etc.).
    ///
    /// Blend rule:
    /// - both summary + folksonomy present → element-wise mean
    /// - only one of summary/folksonomy → use that one
    /// - neither → fall back to `contextualContentEmbedding`
    /// - none of the three → nil (caller skips the node)
    func substrateVector(for node: Node) -> [Float]? {
        // SB139 Stage 4c2 — block-pooled vector takes precedence when
        // pre-resolved. Replaces (not augments) summary/folksonomy because
        // the diagnostic showed mean-pooling at the node level inherits
        // NLContextualEmbedding's compression; widening only emerges when
        // block embeddings *replace* the summary anchor entirely. Fallthrough
        // to the legacy path preserves coverage for nodes without a block
        // sidecar (e.g., pre-backfill ingests, refused-content nodes).
        if let cache = blockPooledVectors,
           let pooled = cache[node.id],
           !pooled.isEmpty {
            return pooled
        }
        let s = node.summaryEmbedding?.isEmpty == false ? node.summaryEmbedding : nil
        let f = node.folksonomyEmbedding?.isEmpty == false ? node.folksonomyEmbedding : nil
        switch (s, f) {
        case let (s?, f?):
            guard s.count == f.count else { return s }
            var out = [Float](repeating: 0, count: s.count)
            for i in 0..<s.count { out[i] = (s[i] + f[i]) * 0.5 }
            return out
        case let (s?, nil):
            return s
        case let (nil, f?):
            return f
        case (nil, nil):
            let c = node.contextualContentEmbedding
            return (c?.isEmpty == false) ? c : nil
        }
    }

    /// Pre-resolve block-pooled vectors for the given nodes and cache them
    /// for subsequent `substrateVector(for:)` calls. Sequential awaits
    /// across the storage actor — ~50–200 ms at corpus scale (n=123),
    /// dominated by sidecar I/O. Idempotent; overwrites any prior cache.
    /// Nodes without a sidecar are absent from the cache (caller's
    /// `substrateVector` falls through to summary/folksonomy).
    ///
    /// Mean pool is element-wise across all blocks per node. Blocks whose
    /// embedding dim disagrees with the first observed dim are dropped
    /// (defensive — shouldn't happen given one embedder version per sidecar).
    func preloadBlockPooledVectors(allNodes: [Node], store: CorpusStore) async {
        var cache: [String: [Float]] = [:]
        for node in allNodes {
            guard SubstrateService.shared.isRankable(node), !node.isMeta else { continue }
            guard let index = await store.blockIndex(forNodeID: node.id),
                  !index.blocks.isEmpty else { continue }
            let dim = index.blocks[0].embedding.count
            guard dim > 0 else { continue }
            var acc = [Float](repeating: 0, count: dim)
            var n = 0
            for block in index.blocks where block.embedding.count == dim {
                for k in 0..<dim { acc[k] += block.embedding[k] }
                n += 1
            }
            guard n > 0 else { continue }
            let inv = Float(1) / Float(n)
            for k in 0..<dim { acc[k] *= inv }
            cache[node.id] = acc
        }
        blockPooledVectors = cache
    }

    // MARK: - Fit

    /// Fit a fresh UMAP model across the given corpus. Heavy compute —
    /// inner work runs on `Task.detached`. Returns when persistence is
    /// complete.
    ///
    /// `targetConstraints` is the cluster-blessing forward-compat hook
    /// (Consultation #1). 4a's UMAP impl throws
    /// `targetConstraintsUnsupported` for non-nil — the parameter exists
    /// so cluster-blessing won't require an API/schema migration.
    ///
    /// - Throws: `UMAPError.notImplementedIn4aScaffolding` until UMAP
    ///   steps 1–4 land. `UMAPError.persistenceFailed` if write fails.
    @discardableResult
    func fit(
        allNodes: [Node],
        hyperparameters: UMAPHyperparameters = .substrateWhitened,
        targetConstraints: TargetConstraints? = nil
    ) async throws -> UMAPFittedModel {
        // Filter at the boundary: thin-content nodes produce false-positive
        // cosines that pollute downstream geometry; meta-nodes are synthetic
        // pulled-thread aggregations whose 2D placement would inflate local
        // density around their source clusters. Same discipline as
        // `ThreadService` and other top-K substrate consumers.
        // TODO(SB122/universal-node-model): swap to node.provenance == nil after meta-node refactor.
        let inputs: [(nodeID: String, vector: [Float])] = allNodes.compactMap { node in
            guard SubstrateService.shared.isRankable(node) else { return nil }
            guard !node.isMeta else { return nil }
            guard let v = substrateVector(for: node) else { return nil }
            return (node.id, v)
        }
        guard !inputs.isEmpty else {
            throw UMAPError.nodeLacksSubstrateVector(nodeID: "<corpus empty of substrate vectors>")
        }
        let dim = inputs[0].vector.count
        for input in inputs where input.vector.count != dim {
            throw UMAPError.dimensionMismatch(expected: dim, got: input.vector.count)
        }
        let seed = defaultRNGSeed()
        let fitVersion = nextFitVersion

        // SB139 Stage 4c2 — PCA whitening upstream of UMAP. NLContextualEmbedding
        // (and BERT-family embedders generally) compress into an anisotropic
        // cone; raw cosines on AirPad's corpus measured p10–p90 = 0.153 with
        // block-anchor pooling, well below HDBSCAN's separation floor.
        // Whitening re-spheres the empirical distribution so each principal
        // axis contributes equally — the geometry, not the model, is the
        // lever (see `feedback_nlcontextual_embedding_cluster_ceiling`).
        // Nil whitening (degenerate inputs, N<2) falls through to raw —
        // preserves pre-4c2 behavior for tiny corpora.
        let whitening = SubstrateWhitening.fit(vectors: inputs.map(\.vector))
        let umapInputs: [(nodeID: String, vector: [Float])]
        if let whitening {
            umapInputs = inputs.map { input in
                (input.nodeID, SubstrateWhitening.apply(vector: input.vector, transform: whitening))
            }
        } else {
            umapInputs = inputs
        }

        // Detached so UMAP math doesn't block main. State mutation
        // happens after we hop back.
        var model = try await Task.detached(priority: .userInitiated) {
            try UMAP.fit(
                trainingInputs: umapInputs,
                hyperparameters: hyperparameters,
                rngSeed: seed,
                targetConstraints: targetConstraints,
                fitVersion: fitVersion
            )
        }.value
        // Inject whitening params onto the returned model so `project(...)`
        // can re-apply them at newcomer transform time. `UMAP.fit` doesn't
        // know about whitening — it just stores the K-dim vectors it
        // received, and `inputDimension` reflects K automatically.
        model.whiteningMean = whitening?.mean
        model.whiteningMatrix = whitening?.matrix

        self.fittedModel = model
        self.lastActivityAt = Date()
        try persist()
        runClustering()
        generation &+= 1
        return model
    }

    // MARK: - Project

    /// Project a node through the currently-loaded fitted model. Returns
    /// nil when no model is loaded or the node has no substrate vector.
    /// Stage 4 design contract: the projected coord doesn't disturb
    /// other nodes' positions.
    ///
    /// - Throws: `UMAPError.noFittedModel` if no model is loaded.
    ///   `UMAPError.nodeLacksSubstrateVector` if the node has no input.
    ///   `UMAPError.notImplementedIn4aScaffolding` until step 6.
    func project(node: Node) throws -> SubstrateCoord2D {
        guard let model = fittedModel else { throw UMAPError.noFittedModel }
        guard let v = substrateVector(for: node) else {
            throw UMAPError.nodeLacksSubstrateVector(nodeID: node.id)
        }
        // SB139 Stage 4c2 — newcomer must traverse the same μ + W the
        // training set saw, else it lands in raw-space while every fit
        // point sits in whitened-space (silent geometric corruption).
        // Pre-v3 fits carry nil whitening params; raw passthrough then.
        let vForUmap: [Float]
        if let mean = model.whiteningMean, let matrix = model.whiteningMatrix {
            let transform = SubstrateWhitening.Transform(mean: mean, matrix: matrix)
            vForUmap = SubstrateWhitening.apply(vector: v, transform: transform)
        } else {
            vForUmap = v
        }
        let coord = try UMAP.transform(inputVector: vForUmap, through: model)
        self.lastActivityAt = Date()
        return coord
    }

    // MARK: - Persistence

    /// Persist the currently-loaded fitted model to disk. JSON via
    /// `Codable`. No-ops (no throw) if no model is loaded.
    func persist() throws {
        guard let model = fittedModel else { return }
        do {
            let url = Self.fittedModelURL()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(model)
            try data.write(to: url, options: .atomic)
        } catch {
            throw UMAPError.persistenceFailed(underlying: error)
        }
    }

    /// Load the fitted model from disk into `fittedModel`. Returns true
    /// if a model was loaded, false if no file existed. Throws if a file
    /// exists but is corrupt.
    @discardableResult
    func load() throws -> Bool {
        let url = Self.fittedModelURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let model = try decoder.decode(UMAPFittedModel.self, from: data)
            self.fittedModel = model
            self.lastActivityAt = Date()
            runClustering()
            generation &+= 1
            return true
        } catch {
            throw UMAPError.loadFailed(underlying: error)
        }
    }

    /// Discard the in-memory model and remove the on-disk copy. Used by
    /// the dev inspect view's "Reset fitted model" affordance and by 4d's
    /// refresh-undo if the snapshot is missing.
    func clear() throws {
        self.fittedModel = nil
        self.clusterLabels = nil
        self.persistentClusterIDs = nil
        self.colorHSB = nil
        self.displayCanvasPositions = nil
        self.relaxationInputHash = nil
        // SB139 Stage 4c2 — invalidate the block-pooled cache too. The next
        // fit's caller must re-preload; stale block-pooled vectors carried
        // across a clear would otherwise feed a fresh fit with the wrong
        // geometry. (Refused-content nodes preserve summary-path fallback.)
        self.blockPooledVectors = nil
        let url = Self.fittedModelURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        // SB139 Stage 4c2 commit 1 — identity must not survive a model
        // reset. The 4d undo path that needs to re-establish identity will
        // do so via the snapshot-restore flow, not the persisted registry.
        try? SubstrateClusterRegistry.shared.clear()
        self.lastActivityAt = Date()
        generation &+= 1
    }

    // MARK: - On-disk location

    /// Lives in Application Support so it's backed up but not surfaced in
    /// Files app browsing. Filename includes the embedder version so a
    /// future embedder bump invalidates the file by mismatch rather than
    /// silent reuse.
    static func fittedModelURL() -> URL {
        let fm = FileManager.default
        let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = root.appendingPathComponent("SubstrateLayout", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("umap_fitted_v\(SubstrateService.currentEmbeddingVersion).json")
    }

    // MARK: - RNG seeding

    /// Default seed for `fit()` when caller doesn't override. Fixed seed
    /// = deterministic across re-fits on the same corpus, which is what
    /// the brief asks for ("Saved UMAP model holds. ... Deliberate full
    /// re-fit triggered by Inbox prompt at threshold."). Reproducibility
    /// beats variance for AirPad's use case; if we ever want variance we
    /// can expose a "shuffle seed" affordance.
    private func defaultRNGSeed() -> [UInt64] {
        [0xA1B2C3D4E5F60718, 0x0F1E2D3C4B5A6978, 0x123456789ABCDEF0, 0xFEDCBA9876543210]
    }

    // MARK: - Clustering (SB139 Stage 4c1)

    /// Per-node view emitted to the canvas: 2D coord + cluster assignment.
    ///
    /// `clusterID == -1` is the HDBSCAN noise label and is session-local —
    /// HDBSCAN renumbers on every fit, so this value is valid only for the
    /// current `generation` and is retained as a diagnostic.
    ///
    /// `persistentClusterID` and `paletteSlot` are stable across refits via
    /// `SubstrateClusterRegistry` (recall-on-prior bipartite match at the
    /// registry's `matchThreshold`). Consumers that need cross-fit
    /// stability — color, label rendering, user renames — key on these.
    /// Both are `nil` for noise points (no cluster) and for placements
    /// produced before `SubstrateClusterRegistry` is wired through (defensive
    /// nil-handling at the callsite preserves the prior session-local
    /// behavior).
    struct CanvasPlacement {
        var nodeID: String
        var coord: SubstrateCoord2D
        var clusterID: Int
        var persistentClusterID: UUID?
        var paletteSlot: Int?
    }

    /// Run HDBSCAN on the currently-loaded fitted model's 2D coords. Pinned
    /// to `algorithm='generic'` (the only path implemented in 4b). Cheap
    /// at AirPad's corpus scale — milliseconds on 200 points. Called from
    /// `fit()` and `load()`; idempotent. No-op when no model is loaded or
    /// the model has fewer than 2 training points (HDBSCAN precondition).
    func runClustering(minClusterSize: Int = 5, minSamples: Int = 2) {
        guard let model = fittedModel else {
            clusterLabels = nil
            persistentClusterIDs = nil
            colorHSB = nil
            return
        }
        let pts = model.trainingPoints
        guard pts.count >= 2 else {
            clusterLabels = nil
            persistentClusterIDs = nil
            colorHSB = nil
            return
        }
        let coords: [[Double]] = pts.map { [Double($0.coord2D.x), Double($0.coord2D.y)] }
        let result = HDBSCAN.fit(
            coords: coords,
            minClusterSize: minClusterSize,
            minSamples: minSamples
        )
        clusterLabels = result.labels

        // SB139 Stage 4c2 commit 1 — resolve session-local HDBSCAN labels
        // to persistent UUIDs. Mutation and persistence are owned by the
        // registry; we just consume the index-aligned mapping.
        let nodeIDs = pts.map(\.nodeID)
        let persistentIDs = SubstrateClusterRegistry.shared.resolvePersistentIDs(
            currentLabels: result.labels,
            nodeIDs: nodeIDs,
            fitVersion: model.fitVersion
        )
        persistentClusterIDs = persistentIDs

        // 4c1.1 — color derives from placements (truth coord + cluster). Compute
        // once per fit/load so the canvas can read it imperatively per-node.
        // Palette slots come from the registry so color is stable across
        // refits even though `result.labels` renumbers.
        let registry = SubstrateClusterRegistry.shared
        let placements: [CanvasPlacement] = zip(pts, result.labels).enumerated().map { idx, pair in
            let (point, label) = pair
            let pid = persistentIDs[idx]
            let slot = pid.flatMap { registry.paletteSlot(for: $0) }
            return CanvasPlacement(
                nodeID: point.nodeID,
                coord: point.coord2D,
                clusterID: label,
                persistentClusterID: pid,
                paletteSlot: slot
            )
        }
        colorHSB = SubstrateColoringPass.map(placements)
        lastActivityAt = Date()
    }

    /// SB139 Stage 4c1 — single accessor consumed by the canvas. Returns
    /// nil when no model is loaded or clustering hasn't run yet. The
    /// returned array is index-aligned with the fitted model's training
    /// points (the order UMAP fit produced); each entry pairs node ID,
    /// 2D coord, and cluster label.
    func canvasPlacements() -> [CanvasPlacement]? {
        guard let model = fittedModel, let labels = clusterLabels else { return nil }
        let pts = model.trainingPoints
        guard pts.count == labels.count else { return nil }
        let pids = persistentClusterIDs
        let registry = SubstrateClusterRegistry.shared
        return zip(pts, labels).enumerated().map { idx, pair in
            let (point, label) = pair
            // Persistent IDs may legitimately lag clusterLabels by one
            // generation (rare, transitional). Defensive nil-handling
            // preserves the prior session-local behavior at the seam.
            let pid = (pids != nil && pids!.count == labels.count) ? pids![idx] : nil
            let slot = pid.flatMap { registry.paletteSlot(for: $0) }
            return CanvasPlacement(
                nodeID: point.nodeID,
                coord: point.coord2D,
                clusterID: label,
                persistentClusterID: pid,
                paletteSlot: slot
            )
        }
    }

    // MARK: - Auto-fit lifecycle (SB139 Stage 4c1)

    /// Substrate-as-baseline entry point: ensure a fitted model exists if
    /// the corpus is large enough to warrant one. Called by the canvas on
    /// appear when the substrate flag is on and no model is loaded.
    ///
    /// Behavior:
    /// - If a model is already loaded → no-op.
    /// - If rankable node count is below `threshold` → no-op. The canvas
    ///   falls back to legacy layout silently per Consultation 3.
    /// - Otherwise → run a fresh fit, persist, cluster. Caller's
    ///   `generation` observer fires when complete.
    ///
    /// Errors propagate from `fit()` (input dimension mismatch,
    /// persistence failure). Caller decides whether to surface or log.
    func ensureFittedIfPossible(
        allNodes: [Node],
        store: CorpusStore,
        threshold: Int = SubstrateLayoutService.autoFitMinNodeCount
    ) async throws {
        if fittedModel != nil { return }
        // SB139 Stage 4c2 — preload before the eligibility check so block-
        // only nodes (no summary/folksonomy) count toward threshold the
        // same way they'll count toward fit input. Without this the
        // threshold gate undercounts in the block-pooled regime.
        await preloadBlockPooledVectors(allNodes: allNodes, store: store)
        let rankableCount = allNodes.reduce(into: 0) { acc, node in
            if SubstrateService.shared.isRankable(node), !node.isMeta,
               substrateVector(for: node) != nil {
                acc += 1
            }
        }
        guard rankableCount >= threshold else { return }
        _ = try await fit(allNodes: allNodes)
    }

    // MARK: - Relaxation (SB139 Stage 4c1.3)

    /// Compute (or reuse) the relaxed display positions for the FULL set of
    /// canvas-displayed nodes — substrate-fit nodes' UMAP truth + non-fit
    /// nodes' tag-driven truth — so cross-class pairs collide-resolve too.
    ///
    /// Caller (CanvasView) owns the input assembly: it knows which nodes are
    /// substrate-fit (truth from `SubstrateCanvasLayoutAdapter`) and which
    /// aren't (truth from `store.canvasLayout.positions`). This service just
    /// runs PBD, caches the result, and fingerprints the inputs so a re-sync
    /// without input change skips the recompute.
    ///
    /// `nodeRadii` is keyed by node ID, in canvas points. Missing entries
    /// fall back to `SubstrateRelaxationPass.defaultRadius`.
    func ensureRelaxation(
        truthPositions: [String: CanvasPosition],
        nodeRadii: [String: CGFloat]
    ) {
        guard !truthPositions.isEmpty else {
            displayCanvasPositions = nil
            relaxationInputHash = nil
            return
        }
        let hash = Self.inputHash(truthPositions: truthPositions, nodeRadii: nodeRadii)
        if hash == relaxationInputHash, displayCanvasPositions != nil {
            return
        }
        let relaxed = SubstrateRelaxationPass.relax(
            truthPositions: truthPositions,
            nodeRadii: nodeRadii
        )
        displayCanvasPositions = relaxed
        relaxationInputHash = hash
        lastActivityAt = Date()
    }

    /// Deterministic fingerprint of relaxation inputs. Combines sorted node
    /// IDs with their truth coords and radii. PBD is deterministic given
    /// these three, so a matching fingerprint guarantees a matching output.
    private static func inputHash(
        truthPositions: [String: CanvasPosition],
        nodeRadii: [String: CGFloat]
    ) -> Int {
        var hasher = Hasher()
        let ids = truthPositions.keys.sorted()
        hasher.combine(ids.count)
        for id in ids {
            hasher.combine(id)
            if let p = truthPositions[id] {
                hasher.combine(p.x)
                hasher.combine(p.y)
            }
            if let r = nodeRadii[id] {
                hasher.combine(Double(r))
            }
        }
        return hasher.finalize()
    }
}
