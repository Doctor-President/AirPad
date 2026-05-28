import Foundation
import Observation

/// SB139 Stage 4c2 commit 1 — persistent cluster identity across HDBSCAN
/// refits.
///
/// HDBSCAN renumbers its internal cluster labels on every fit; without
/// persistence, the canvas color regions visibly flip when the model is
/// re-fit (palette slot keyed on raw label), user-renamed labels orphan
/// when their cluster's label number changes, and the 4d refresh story
/// breaks. This registry assigns a stable `UUID` and a stable `paletteSlot`
/// to each cluster on first appearance, then reuses them across refits
/// when membership overlap holds.
///
/// **Matching metric:** recall on prior =
/// `|prior_members ∩ current_members| / |prior_members|`. Threshold seeded
/// at `0.70` per Consultation #3, tunable from `SubstrateInspectView`.
/// Rationale recorded in `Ops/workstreams/ws-semantic-substrate.md` —
/// "carry over" reads more naturally as recall on prior than Jaccard.
///
/// **Match algorithm:** greedy max-recall pair scan; at our cluster
/// counts (≈5–15 per fit) this equals the Hungarian-optimal assignment
/// in essentially all cases.
///
/// **Palette slot policy:** monotonic counter, never freed. Display
/// cycles via `paletteSlot % SubstrateColoringPass.clusterPalette.count`
/// so the bounded two-color palette is preserved as slots grow. Avoids
/// thrash from a flickering cluster repeatedly dissolving and reappearing.
///
/// **Lifecycle:** lazy-load on first method call; persist after every
/// `resolvePersistentIDs`. Mirrors `SubstrateLayoutService` so a single
/// service-init flow doesn't have to know about both.
@available(iOS 17.0, *)
struct SubstrateClusterIdentity: Codable, Hashable, Identifiable {
    /// Stable across refits. Assigned at first appearance, never reused.
    let id: UUID
    /// Index into `SubstrateColoringPass.clusterPalette` (mod count).
    /// Monotonic; never freed. Stable for the life of this identity.
    var paletteSlot: Int
    /// Diagnostic — fit version when this identity first appeared.
    var firstSeenFitVersion: Int
    /// Diagnostic — most recent fit version where this identity matched
    /// a current HDBSCAN cluster. Lags `lastFitVersion` for dissolved
    /// clusters; the matcher can still rediscover them via `memberNodeIDs`.
    var lastSeenFitVersion: Int
    /// Most recent matched fit's member set. Sorted for deterministic
    /// disk encoding. Recomputed as a `Set` inside the matcher.
    var memberNodeIDs: [String]
    /// Cached count = `memberNodeIDs.count`. Carried separately so the
    /// dev inspect view can render without materializing the array.
    var memberCount: Int
    /// Human-readable label for this cluster. `nil` until the label
    /// service generates one (Commit C) or the user assigns one
    /// (Commit E). Once set, never overwritten by the label service —
    /// staleness gating is "never re-label unless explicitly cleared"
    /// (T decision, 2026-05-28). Clearing is via `clearLabel`.
    var label: String?
    /// How `label` was produced. Nil iff `label` is nil. The label
    /// service refuses to overwrite `.user` even when membership shifts.
    var labelSource: LabelSource?
    /// Wall-clock at label assignment. Diagnostic — not consulted for
    /// staleness; carries forward across refits with the label itself.
    var labelGeneratedAt: Date?
}

/// Origin of an identity's label. `.fm` is the Foundation-Models-generated
/// default; `.user` indicates a manual rename via the inspect surface and
/// is treated as authoritative — the label service must not overwrite it.
@available(iOS 17.0, *)
enum LabelSource: String, Codable, Hashable {
    case fm
    case user
}

@available(iOS 17.0, *)
private struct SubstrateClusterRegistryFile: Codable {
    /// File schema version. Bump on migration; today only 1.
    var formatVersion: Int
    /// Matches `SubstrateService.currentEmbeddingVersion`. Mismatch on
    /// load → discard and start fresh; mirrors the UMAP file's versioned-
    /// filename pattern.
    var embeddingVersion: Int
    /// Highest fit version observed. Diagnostic.
    var lastFitVersion: Int
    /// Next palette slot to hand out.
    var nextPaletteSlot: Int
    /// All identities, including dissolved ones (so a reappearing cluster
    /// can rediscover its identity via the matcher).
    var identities: [SubstrateClusterIdentity]
    /// Persisted tunable so a relaunch keeps the user's chosen value.
    /// Optional for forward compat with files written before this field.
    var matchThreshold: Double?
}

@available(iOS 17.0, *)
@Observable
@MainActor
final class SubstrateClusterRegistry {

    // MARK: - Singleton

    static let shared = SubstrateClusterRegistry()

    private init() {}

    // MARK: - State

    /// All identities keyed by UUID. Includes dissolved clusters (kept so
    /// they can be re-matched on reappearance via their member snapshot).
    private(set) var identities: [UUID: SubstrateClusterIdentity] = [:]

    /// Monotonic slot counter. Hands out the next slot to fresh clusters.
    private(set) var nextPaletteSlot: Int = 0

    /// Highest fit version seen across all calls. Diagnostic.
    private(set) var lastFitVersion: Int = 0

    /// Lazy-load gate. Flipped on first call to any public method.
    private var loadedFromDisk: Bool = false

    /// Recall-on-prior threshold for the bipartite max-overlap match.
    /// `overlap(P, C) = |P ∩ C| / |P|` — fraction of prior members that
    /// reappear in the candidate current cluster. 0.70 per Consultation #3.
    /// Persisted so the dev inspect view's stepper survives relaunch.
    var matchThreshold: Double = 0.70

    // MARK: - Resolve

    /// Map current HDBSCAN cluster labels → persistent UUIDs.
    ///
    /// - Parameters:
    ///   - currentLabels: HDBSCAN output index-aligned with `nodeIDs`.
    ///     `-1` denotes noise.
    ///   - nodeIDs: node IDs index-aligned with `currentLabels`.
    ///   - fitVersion: `UMAPFittedModel.fitVersion` of the current fit.
    /// - Returns: `[UUID?]` index-aligned with the inputs. Noise → `nil`.
    ///
    /// Mutates the registry (insert/update identities, advance
    /// `nextPaletteSlot`) and persists to disk. Idempotent given the same
    /// inputs and starting state.
    @discardableResult
    func resolvePersistentIDs(
        currentLabels: [Int],
        nodeIDs: [String],
        fitVersion: Int
    ) -> [UUID?] {
        precondition(currentLabels.count == nodeIDs.count,
                     "currentLabels.count must equal nodeIDs.count")
        ensureLoaded()

        // Group node IDs by current HDBSCAN label, dropping noise.
        var currentMembersByLabel: [Int: Set<String>] = [:]
        for (i, label) in currentLabels.enumerated() where label >= 0 {
            currentMembersByLabel[label, default: []].insert(nodeIDs[i])
        }
        let currentLabelSet = currentMembersByLabel.keys.sorted()

        // Candidate pairs over (prior identity, current label) with
        // recall ≥ matchThreshold. Pre-materialize prior member sets
        // once per identity so the inner loop is intersection-only.
        struct Candidate {
            let priorID: UUID
            let label: Int
            let recall: Double
        }
        var candidates: [Candidate] = []
        for prior in identities.values {
            guard !prior.memberNodeIDs.isEmpty else { continue }
            let priorMembers = Set(prior.memberNodeIDs)
            for label in currentLabelSet {
                guard let members = currentMembersByLabel[label] else { continue }
                let intersection = priorMembers.intersection(members).count
                let recall = Double(intersection) / Double(priorMembers.count)
                if recall >= matchThreshold {
                    candidates.append(Candidate(
                        priorID: prior.id,
                        label: label,
                        recall: recall
                    ))
                }
            }
        }

        // Greedy max-recall match. Tie-break by smaller HDBSCAN label so
        // ties resolve deterministically across launches.
        candidates.sort { lhs, rhs in
            if lhs.recall != rhs.recall { return lhs.recall > rhs.recall }
            if lhs.label != rhs.label { return lhs.label < rhs.label }
            return lhs.priorID.uuidString < rhs.priorID.uuidString
        }

        var labelToPriorID: [Int: UUID] = [:]
        var matchedPriorIDs: Set<UUID> = []
        for c in candidates {
            if labelToPriorID[c.label] != nil { continue }
            if matchedPriorIDs.contains(c.priorID) { continue }
            labelToPriorID[c.label] = c.priorID
            matchedPriorIDs.insert(c.priorID)
        }

        // Update matched identities; assign fresh UUIDs to unmatched
        // current labels in ascending-label order so palette slot
        // assignment is deterministic.
        for label in currentLabelSet {
            let members = (currentMembersByLabel[label] ?? []).sorted()
            if let priorID = labelToPriorID[label], var existing = identities[priorID] {
                existing.memberNodeIDs = members
                existing.memberCount = members.count
                existing.lastSeenFitVersion = fitVersion
                identities[priorID] = existing
            } else {
                let fresh = SubstrateClusterIdentity(
                    id: UUID(),
                    paletteSlot: nextPaletteSlot,
                    firstSeenFitVersion: fitVersion,
                    lastSeenFitVersion: fitVersion,
                    memberNodeIDs: members,
                    memberCount: members.count
                )
                identities[fresh.id] = fresh
                labelToPriorID[label] = fresh.id
                nextPaletteSlot += 1
            }
        }

        lastFitVersion = max(lastFitVersion, fitVersion)
        do {
            try persist()
        } catch {
            print("[SubstrateClusterRegistry] persist failed: \(error)")
        }

        // Build the index-aligned output.
        var result = [UUID?](repeating: nil, count: currentLabels.count)
        for (i, label) in currentLabels.enumerated() where label >= 0 {
            result[i] = labelToPriorID[label]
        }
        return result
    }

    // MARK: - Lookups

    /// Palette slot for an identity. Nil if the identity is unknown.
    func paletteSlot(for id: UUID) -> Int? {
        identities[id]?.paletteSlot
    }

    /// Single identity lookup. Nil if unknown.
    func identity(for id: UUID) -> SubstrateClusterIdentity? {
        identities[id]
    }

    /// Label for an identity. Nil if unknown or unlabeled.
    func label(for id: UUID) -> String? {
        identities[id]?.label
    }

    // MARK: - Label mutation
    //
    // Two write paths exist: `setLabel` is called by the label service
    // (Commit C, source `.fm`) and the inspect-surface rename (Commit E,
    // source `.user`); `clearLabel` is called by the inspect surface's
    // "clear label" affordance and re-opens the identity to a future
    // `.fm` regeneration. Staleness policy: the label service must
    // gate its calls on `identity.label == nil` — this registry does
    // not enforce "don't overwrite" on `setLabel` so the user-rename
    // path can replace either kind.
    //
    // Both mutators persist synchronously so a label survives a crash
    // immediately after assignment.

    /// Assign or replace a label for an identity. No-op if the identity
    /// is unknown. Persists the registry on success.
    func setLabel(persistentID: UUID, label: String, source: LabelSource) {
        ensureLoaded()
        guard var identity = identities[persistentID] else { return }
        identity.label = label
        identity.labelSource = source
        identity.labelGeneratedAt = Date()
        identities[persistentID] = identity
        do {
            try persist()
        } catch {
            print("[SubstrateClusterRegistry] setLabel persist failed: \(error)")
        }
    }

    /// Null every `.fm`-sourced label across the registry, leaving
    /// `.user` renames untouched. Returns the count of identities that
    /// were cleared so the caller can decide whether a regeneration
    /// pass is worth kicking off. Persists once at the end (single
    /// write, not per-identity).
    @discardableResult
    func clearAllFMLabels() -> Int {
        ensureLoaded()
        var cleared = 0
        for (id, identity) in identities where identity.labelSource == .fm {
            var copy = identity
            copy.label = nil
            copy.labelSource = nil
            copy.labelGeneratedAt = nil
            identities[id] = copy
            cleared += 1
        }
        if cleared > 0 {
            do {
                try persist()
            } catch {
                print("[SubstrateClusterRegistry] clearAllFMLabels persist failed: \(error)")
            }
        }
        return cleared
    }

    /// Clear the label on an identity, re-opening it to a future `.fm`
    /// regeneration. No-op if the identity is unknown.
    func clearLabel(persistentID: UUID) {
        ensureLoaded()
        guard var identity = identities[persistentID] else { return }
        identity.label = nil
        identity.labelSource = nil
        identity.labelGeneratedAt = nil
        identities[persistentID] = identity
        do {
            try persist()
        } catch {
            print("[SubstrateClusterRegistry] clearLabel persist failed: \(error)")
        }
    }

    /// All identities sorted by first-seen-fit then palette slot for the
    /// dev inspect view's identity table.
    func allIdentities() -> [SubstrateClusterIdentity] {
        identities.values.sorted { lhs, rhs in
            if lhs.firstSeenFitVersion != rhs.firstSeenFitVersion {
                return lhs.firstSeenFitVersion < rhs.firstSeenFitVersion
            }
            if lhs.paletteSlot != rhs.paletteSlot {
                return lhs.paletteSlot < rhs.paletteSlot
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Persistence

    /// Read the registry from disk on first method call. Silently falls
    /// back to a fresh registry on any read failure — corruption must not
    /// block a fit; the next resolve will rewrite the file from the new
    /// state. Logged to console.
    private func ensureLoaded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        do {
            try load()
        } catch {
            print("[SubstrateClusterRegistry] load failed (\(error)); starting fresh")
            identities = [:]
            nextPaletteSlot = 0
            lastFitVersion = 0
        }
    }

    /// Load the on-disk registry into memory.
    ///
    /// - Returns: true if a file existed and decoded; false if the file
    ///   was absent or its `embeddingVersion` no longer matches
    ///   `SubstrateService.currentEmbeddingVersion` (a future embedder
    ///   bump invalidates by mismatch rather than silent reuse).
    /// - Throws: decoding errors (corruption). Caller may treat as
    ///   fall-through-to-fresh.
    @discardableResult
    func load() throws -> Bool {
        let url = Self.fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let file = try decoder.decode(SubstrateClusterRegistryFile.self, from: data)
        if file.embeddingVersion != SubstrateService.currentEmbeddingVersion {
            identities = [:]
            nextPaletteSlot = 0
            lastFitVersion = 0
            return false
        }
        var byID: [UUID: SubstrateClusterIdentity] = [:]
        byID.reserveCapacity(file.identities.count)
        for identity in file.identities { byID[identity.id] = identity }
        identities = byID
        nextPaletteSlot = file.nextPaletteSlot
        lastFitVersion = file.lastFitVersion
        if let t = file.matchThreshold { matchThreshold = t }
        return true
    }

    /// Persist the current registry to disk. Atomic write.
    func persist() throws {
        let file = SubstrateClusterRegistryFile(
            formatVersion: 1,
            embeddingVersion: SubstrateService.currentEmbeddingVersion,
            lastFitVersion: lastFitVersion,
            nextPaletteSlot: nextPaletteSlot,
            identities: allIdentities(),
            matchThreshold: matchThreshold
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        let url = Self.fileURL()
        try data.write(to: url, options: .atomic)
    }

    /// Discard in-memory state and remove the on-disk file. Called by
    /// `SubstrateLayoutService.clear()` so identity does not survive a
    /// model reset.
    func clear() throws {
        identities = [:]
        nextPaletteSlot = 0
        lastFitVersion = 0
        loadedFromDisk = true
        let url = Self.fileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - On-disk location

    /// Sibling to `SubstrateLayoutService.fittedModelURL()` in the same
    /// `SubstrateLayout` directory under Application Support. Filename
    /// includes the embedder version so a bump invalidates the file by
    /// mismatch.
    static func fileURL() -> URL {
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
        return dir.appendingPathComponent("cluster_identities_v\(SubstrateService.currentEmbeddingVersion).json")
    }
}
