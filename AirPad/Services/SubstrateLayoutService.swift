import Foundation

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
@MainActor
final class SubstrateLayoutService {

    // MARK: - Singleton

    static let shared = SubstrateLayoutService()

    private init() {}

    // MARK: - State

    /// Currently-loaded fitted UMAP model. Nil until `load()` finds one
    /// on disk or `fit()` produces a fresh one. `project(node:)` consults
    /// this directly.
    private(set) var fittedModel: UMAPFittedModel?

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
        hyperparameters: UMAPHyperparameters = .default,
        targetConstraints: TargetConstraints? = nil
    ) async throws -> UMAPFittedModel {
        let inputs: [(nodeID: String, vector: [Float])] = allNodes.compactMap { node in
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

        // Detached so UMAP math doesn't block main. State mutation
        // happens after we hop back.
        let model = try await Task.detached(priority: .userInitiated) {
            try UMAP.fit(
                trainingInputs: inputs,
                hyperparameters: hyperparameters,
                rngSeed: seed,
                targetConstraints: targetConstraints,
                fitVersion: fitVersion
            )
        }.value

        self.fittedModel = model
        self.lastActivityAt = Date()
        try persist()
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
        let coord = try UMAP.transform(inputVector: v, through: model)
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
        let url = Self.fittedModelURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        self.lastActivityAt = Date()
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
}
