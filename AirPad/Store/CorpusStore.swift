import Foundation
import NaturalLanguage
import Observation
import UIKit

// MARK: - Seeded RNG (SB126 Stage 1)

/// Deterministic 64-bit RNG used for the random tier of neighborhood member
/// sampling. SplitMix64 seeded by an FNV-1a hash of the neighborhood ID, so
/// the same neighborhood draws the same 3 random members run-to-run unless
/// the trigger rule fires and re-samples.
fileprivate struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEADBEEFCAFEBABE : seed
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}

fileprivate func stableSeed(_ s: String) -> UInt64 {
    var h: UInt64 = 0xCBF29CE484222325
    for byte in s.utf8 {
        h ^= UInt64(byte)
        h = h &* 0x100000001B3
    }
    return h
}

// MARK: - Reprocess progress

/// Surface state for `reprocessUntaggedNodes`. SettingsView observes the
/// `reprocessing` property on CorpusStore to show progress and final counts.
struct ReprocessingState: Equatable {
    var total: Int
    var current: Int
    var tagged: Int
    var failed: Int
    var done: Bool
}

// MARK: - Backfill progress (SB137 Stage A — content embedding precondition)

/// Surface state for `backfillContentEmbeddings`. SettingsView observes the
/// `backfillingEmbeddings` property on CorpusStore to show progress + final counts.
struct BackfillEmbeddingState: Equatable {
    var total: Int
    var current: Int
    var populated: Int
    var skippedNoContent: Int
    var done: Bool
}

// MARK: - SB139 Stage 1 — substrate backfill progress

/// Surface state for `backfillSubstrate`. The dev inspect view observes this
/// to show batch progress and per-outcome counts. `pending` tracks how many
/// substrate-eligible nodes remain after the current batch finishes.
struct SubstrateBackfillState: Equatable {
    var batchTotal: Int
    var current: Int
    var succeeded: Int
    var guardrailRefused: Int
    var thinContent: Int
    /// FM `processSubstrate` call failed for a non-guardrail reason (decode
    /// error, transient FM unavailability, etc.). Content embedding may still
    /// have landed; summary/folksonomy are nil.
    var fmError: Int
    /// `NLContextualEmbedding` failed to load — no vectors at all on the node.
    var embedderError: Int
    var pendingAfter: Int
    var done: Bool
    var lastRunAt: Date?
}

/// Central state store for the AirPad corpus.
/// @MainActor ensures all mutations happen on the main thread, keeping SwiftUI observation correct.
@Observable
@MainActor
final class CorpusStore {

    var nodes: [Node] = []
    var tags: [Tag] = []
    var canvasLayout: CanvasLayout = CanvasLayout(version: 1, updatedAt: Date(), positions: [:])

    /// Node radii from latest layout computation (not persisted; recomputed on each layout pass)
    var nodeRadii: [String: CGFloat] = [:]

    /// Cached Über-node clusters (Tier 1: tag-only). Regenerates on invalidation.
    var uberNodeCache: UberNodeCache? = nil

    /// Cached neighborhoods (Louvain communities over tag co-occurrence). Regenerates on invalidation.
    var neighborhoodCache: NeighborhoodCache? = nil

    /// Persistent corpus index (neighborhood registry, tag layer, summary).
    /// Loaded from disk at startup; updated and re-saved whenever neighborhoods refresh.
    var corpusIndex: CorpusIndex = CorpusIndex.empty()

    /// Reference to CanvasState for drill-down filtering.
    var canvasState: CanvasState? = nil

    /// True when iCloud is unavailable and the app is writing to local storage instead.
    var iCloudUnavailable = false

    /// Set when AI processing suggests tags not yet in the vocabulary.
    /// CanvasView observes this and presents TagCreationSheet.
    var pendingTagSuggestions: TagSuggestionContext? = nil

    /// Non-nil while `reprocessUntaggedNodes` is running or has just finished.
    /// SettingsView observes this to surface progress + final counts inline.
    var reprocessing: ReprocessingState? = nil

    /// Non-nil while `backfillContentEmbeddings` is running or has just finished.
    /// SettingsView observes this to surface progress + final counts inline.
    var backfillingEmbeddings: BackfillEmbeddingState? = nil

    /// SB139 Stage 1 — non-nil while substrate backfill is running or just
    /// finished. The dev substrate inspect view observes this for progress.
    var substrateBackfill: SubstrateBackfillState? = nil

    /// Active filter + view mode. Persisted to UserDefaults.
    var filterState: FilterState = FilterState.load() {
        didSet { filterState.save() }
    }

    /// Thread suggestions waiting to be shown to the user (one at a time in UI).
    var pendingThreads: [ThreadSuggestion] = []

    /// True while NodeDetailView is on screen. ContentView reads this to hide the toggle pill.
    var isInDetailView = false

    /// Set by `appendEmptyTextItem` so the corresponding `TextEntryBody` can
    /// pull focus on its first render — that's how the in-node "+" → Text
    /// path lands the user directly in the editor (inline append pattern)
    /// instead of routing through `TextCaptureSheet`. Cleared by the body
    /// once consumed. Single-shot: only one entry can be pending at a time
    /// because the "+" menu can only fire one entry creation per tap.
    var pendingAutoFocusItemID: String? = nil

    /// Non-nil while a batch import is in progress. ContentView shows a progress banner.
    var importBatchProgress: (current: Int, total: Int)? = nil

    /// Incremented when a batch import finishes. CanvasView observes this to force a full resync
    /// with correct layout positions — belt-and-suspenders on top of onChange(of: nodes).
    var canvasNeedsSync = UUID()

    /// Blocks that failed the quality gate during batch import.
    /// Never silently discarded — user reviews from Settings.
    var reviewQueue: [RejectedBlock] = [] {
        didSet { saveReviewQueue() }
    }

    /// Reference to QuarantineStore for syncing quarantined entries.
    var quarantineStore: QuarantineStore?

    /// SB139 Stage 2 — session-only set of dismissed pair keys (pair key from
    /// `SubstrateThreadService.pairKey`). Cleared on app relaunch so the
    /// candidate stays in the pool per the brief's "one-time dismissal,
    /// candidate may surface again later" rule. Not persisted.
    private var dismissedThreadPairKeys: Set<String> = []

    /// Debounced cluster refresh task (Task 3)
    private var clusterRefreshTask: Task<Void, Never>?

    /// Nodes after applying the active filter and sort order.
    var filteredNodes: [Node] {
        var result = nodes

        if filterState.itemType != .all {
            result = result.filter { node in
                node.items.contains { item in
                    switch filterState.itemType {
                    case .all:      return true
                    case .voice:    return item.type == .audio
                    case .photo:    return item.type == .image
                    case .video:    return item.type == .video
                    case .text:     return item.type == .text
                    case .link:     return item.type == .link
                    case .document: return item.type == .document
                    }
                }
            }
        }

        if let tag = filterState.tagName {
            result = result.filter { $0.tags.contains(tag) }
        }

        switch filterState.threadStatus {
        case .all:         break
        case .threadsOnly: result = result.filter { !$0.threads.isEmpty || $0.isMeta }
        case .pulledOnly:  result = result.filter { $0.isMeta }
        }

        switch filterState.sortOrder {
        case .recency:
            result = result.sorted { $0.createdAt > $1.createdAt }
        case .thematic:
            result = result.sorted { ($0.tags.first ?? "zzz") < ($1.tags.first ?? "zzz") }
        }

        return result
    }

    /// Nodes visible on canvas after applying filters and drill-down state.
    /// When drilled into an Über-node, returns only its child nodes.
    var visibleNodes: [Node] {
        guard let drilledClusterID = canvasState?.drilledInto,
              let cluster = uberNodeCache?.clusters.first(where: { $0.id == drilledClusterID }) else {
            return filteredNodes
        }
        // Filter to only child nodes of the drilled-into cluster
        let childIDs = Set(cluster.childNodeIDs)
        return filteredNodes.filter { childIDs.contains($0.id) }
    }

    private let service = iCloudDriveService()
    private let layoutService = LayoutService()

    /// Suggestions surfaced by the Ghost Query Field. Built from the corpus summary if present,
    /// with a fixed fallback list so the field is never empty (e.g., on a fresh install).
    var ghostQuerySuggestions: [String] {
        var suggestions: [String] = []
        if let summary = corpusIndex.summary {
            let themeQuestions = summary.dominantThemes.prefix(3).map {
                "What patterns show up in my \($0.lowercased()) ideas?"
            }
            suggestions.append(contentsOf: themeQuestions)
            if let recent = summary.recentDominantTags.first {
                suggestions.append("What have I been thinking about with \(recent)?")
            }
            if let stale = summary.anomalies.staleTags.first {
                suggestions.append("What happened to my \(stale) ideas?")
            }
        }
        let fallbacks = [
            "What patterns show up in my work?",
            "What ideas keep coming back?",
            "What have I been avoiding?",
            "Where do my best ideas come from?",
            "What ideas keep coming back that I haven't acted on?"
        ]
        if suggestions.isEmpty { suggestions = fallbacks }
        return suggestions
    }

    // MARK: - Lifecycle

    func setup() async {
        reviewQueue = loadReviewQueue()
        await service.setup()
        let fallback = await service.usingLocalFallback
        let available = await service.isAvailable
        iCloudUnavailable = fallback
        guard available else { return }
        await load()
    }

    // MARK: - Load

    func load() async {
        // Import any nodes staged by the share extension first
        await importFromAppGroupInbox()
        do {
            let loaded = try await service.loadAllNodes()
            let layout = try await service.loadCanvasLayout()
            let loadedTags = try await service.loadTags()
            nodes = loaded.sorted { $0.createdAt > $1.createdAt }
            canvasLayout = layout ?? CanvasLayout(version: 1, updatedAt: Date(), positions: [:])
            let minimumViableTagCount = 8
            if loadedTags.count < minimumViableTagCount {
                let existingNames = Set(loadedTags.map { $0.name.lowercased() })
                let tier1 = Self.tier1SeedTags()
                let newTags = tier1.filter { !existingNames.contains($0.name.lowercased()) }
                tags = loadedTags + newTags
                await persistTags()
            } else {
                tags = loadedTags
            }
        } catch {
            print("[CorpusStore] Load error: \(error)")
        }
        // Load corpus index if available (graceful fallback to empty on first run)
        if let loadedIndex = try? await service.loadCorpusIndex() {
            // SB137 Stage A — first launch on schema v2: back up the v1 index and
            // bump version. The neighborhoodCache stays nil, so the immediately-
            // following refreshNeighborhoods() runs a full re-cluster against
            // the lift-weighted edge weights + isolate routing.
            if loadedIndex.version < CorpusIndex.currentVersion {
                print("[CorpusStore][SB137] Upgrading corpus_index from v\(loadedIndex.version) → v\(CorpusIndex.currentVersion); writing pre-stageA backup")
                try? await service.backupCorpusIndexForStageAUpgrade()
                var upgraded = loadedIndex
                upgraded.version = CorpusIndex.currentVersion
                corpusIndex = upgraded
            } else {
                corpusIndex = loadedIndex
            }
        }
        // Generate initial Über-node clusters
        refreshUberNodeClusters()
        // Generate initial neighborhoods
        refreshNeighborhoods()
        // SB139 Stage 1 — relabel pre-split `embedder_error` records. The
        // original implementation conflated two cases under one reason; if the
        // node has any vectors, the failure was on the FM side, not the
        // embedder load. One-time, idempotent migration.
        migrateEmbedderErrorLabels()
        // SB139 Stage 1 — recompute substrate corpus means from whatever
        // vectors landed in storage. Cheap (one pass over nodes) and avoids
        // persisting means to disk. Skipped silently if iOS < 17.
        if #available(iOS 17.0, *) {
            SubstrateService.shared.recomputeMeans(from: nodes)
            // SB139 Stage 2 — first surface for substrate-driven threads.
            // Means must be fresh first; that's the line above.
            refreshSubstrateThreadCandidates()
            // SB139 Stage 4c1 — substrate-as-baseline: load any saved UMAP fit
            // from disk and cluster it on the way in so the canvas sees a
            // placed corpus on first paint. Auto-fit when no model exists yet
            // is triggered by CanvasView on appear (not here — load() must not
            // block on a synchronous fit).
            do {
                _ = try SubstrateLayoutService.shared.load()
            } catch {
                print("[CorpusStore] Substrate model load error: \(error)")
            }
        }
        // Process any nodes that were captured by the share extension (no AI ran at capture time)
        await scanForUnprocessedNodes()
    }

    // MARK: - Add new nodes

    /// Saves an audio file, then saves the node. Use this for voice captures.
    func addNodeWithAudio(_ node: Node, audioURL: URL, audioItemID: String, position: CGPoint) async {
        do {
            try await service.saveItemFile(
                nodeID: node.id,
                itemID: audioItemID,
                sourceURL: audioURL,
                fileExtension: "m4a"
            )
        } catch {
            print("[CorpusStore] Audio file save error: \(error)")
        }
        await addNode(node, position: position)
    }

    func addNode(_ node: Node, position: CGPoint) async {
        var newLayout = canvasLayout
        newLayout.positions[node.id] = CanvasPosition(x: Double(position.x), y: Double(position.y))
        newLayout.updatedAt = Date()
        do {
            try await service.saveNode(node)
            try await service.saveCanvasLayout(newLayout)
            nodes.insert(node, at: 0)
            canvasLayout = newLayout
        } catch {
            print("[CorpusStore] Save error: \(error)")
        }
        // Refresh Über-node clusters (auto-invalidates at 5+ new nodes)
        refreshUberNodeClusters()
        // Refresh neighborhoods (may trigger layout recompute if structure changes)
        refreshNeighborhoods()
        // Single-node capture: recompute layout (inertia keeps existing nodes stable)
        recomputeAlgorithmicLayout(reason: "single-node capture")
        // Thread analysis is gated on batchProcessingComplete (end of Phase 4) — see batchImportText.
        // Single-node insert does not trigger evaluation against an incomplete corpus (SB123).
    }

    // MARK: - Update existing nodes

    func updateNode(_ updated: Node) async {
        guard let idx = nodes.firstIndex(where: { $0.id == updated.id }) else { return }
        nodes[idx] = updated
        do {
            try await service.saveNode(updated)
        } catch {
            print("[CorpusStore] Update error: \(error)")
        }
    }

    /// Stage 3.1a — lazy per-node migration to the entry-primitive schema.
    /// Called from `NodeDetailView.onAppear` so a node is only migrated when
    /// the user actually opens it; the corpus is never bulk-walked at launch.
    /// No-op when the node is already at the current schema version, so
    /// repeated calls during a session are cheap.
    func ensureEntrySchema(forNodeID nodeID: String) async {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var node = nodes[idx]
        let didMigrate = migrateEntrySchemaIfNeeded(&node)
        guard didMigrate else { return }
        nodes[idx] = node
        do {
            try await service.saveNode(node)
        } catch {
            print("[CorpusStore] ensureEntrySchema: saveNode error for \(nodeID): \(error)")
        }
    }

    // MARK: - Append items to existing nodes

    func appendItemToNode(nodeID: String, item: NodeItem) async {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[idx]
        updated.items.append(item)
        updated.updatedAt = Date()
        await updateNode(updated)
    }

    /// Updates the text content of an existing text-type item in a node.
    /// No-op if the node or item is missing, or the content is unchanged.
    /// Bumps the item's `updatedAt` alongside the node's — the per-entry
    /// timestamp field shipped in Stage 3.1a commit (a) and is now live.
    func updateTextItem(itemID: String, newContent: String, nodeID: String) async {
        guard let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[nodeIdx]
        guard let itemIdx = updated.items.firstIndex(where: { $0.id == itemID }),
              updated.items[itemIdx].type == .text,
              updated.items[itemIdx].content != newContent else { return }
        let now = Date()
        updated.items[itemIdx].content = newContent
        updated.items[itemIdx].updatedAt = now
        updated.updatedAt = now
        await updateNode(updated)
    }

    // MARK: - Entry-primitive actions (Stage 3.1a commit (b))

    /// Renames an entry's user-facing display name. Trims whitespace; no-op
    /// if the result is empty or unchanged from the current name. Bumps both
    /// the entry's and node's `updatedAt`.
    func renameEntry(itemID: String, newName: String, nodeID: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[nodeIdx]
        guard let itemIdx = updated.items.firstIndex(where: { $0.id == itemID }),
              updated.items[itemIdx].displayName != trimmed else { return }
        let now = Date()
        updated.items[itemIdx].displayName = trimmed
        updated.items[itemIdx].updatedAt = now
        updated.updatedAt = now
        await updateNode(updated)
    }

    /// Duplicates an entry in place (inserted immediately after the original).
    /// New entry gets a fresh UUID + timestamps; display name gets a " copy"
    /// suffix so the user can tell them apart in the card stack. Constructed
    /// via the memberwise init because `NodeItem.id` and `.createdAt` are
    /// `let`-bound. No-op if the node or item is missing.
    func duplicateEntry(itemID: String, nodeID: String) async {
        guard let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[nodeIdx]
        guard let itemIdx = updated.items.firstIndex(where: { $0.id == itemID }) else { return }
        let original = updated.items[itemIdx]
        let now = Date()
        let nameWithCopy: String? = original.displayName.map { "\($0) copy" }
        let copy = NodeItem(
            id: UUID().uuidString,
            type: original.type,
            createdAt: now,
            content: original.content,
            file: original.file,
            description: original.description,
            transcript: original.transcript,
            durationSeconds: original.durationSeconds,
            url: original.url,
            title: original.title,
            preview: original.preview,
            specializedType: original.specializedType,
            displayName: nameWithCopy,
            isExpanded: true,
            updatedAt: now
        )
        updated.items.insert(copy, at: itemIdx + 1)
        updated.updatedAt = now
        await updateNode(updated)
    }

    /// Deletes an entry from a node, cleaning up any associated media file
    /// on disk first. No-op if the node or item is missing.
    ///
    /// Stage 3.1b — `item.file` is the relative path inside the node folder
    /// (e.g. `"items/<itemID>.m4a"`); we parse the extension and hand off
    /// to `iCloudDriveService.deleteItemFile` so file resolution stays in
    /// one place. Failure modes per the 3.1b brief:
    ///   • Missing file → log the inconsistency, proceed to remove the
    ///     entry. This handles already-orphaned items from pre-3.1b corpora
    ///     and the never-saved-due-to-prior-failure case.
    ///   • Filesystem throw (permissions, disk full, root unavailable) →
    ///     abort the deletion so the user can retry; the entry stays
    ///     visible rather than leaving a silent orphaned file behind.
    func deleteEntry(itemID: String, nodeID: String) async {
        guard let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[nodeIdx]
        guard let itemIdx = updated.items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = updated.items[itemIdx]
        if let relativePath = item.file {
            let ext = (relativePath as NSString).pathExtension
            if !ext.isEmpty {
                do {
                    let removed = try await service.deleteItemFile(
                        nodeID: nodeID,
                        itemID: item.id,
                        fileExtension: ext
                    )
                    if !removed {
                        print("[CorpusStore] deleteEntry: media file missing for \(item.id) (\(relativePath)) — removing entry anyway")
                    }
                } catch {
                    print("[CorpusStore] deleteEntry: media file removal failed for \(item.id) (\(relativePath)): \(error) — aborting entry removal")
                    return
                }
            }
        }
        updated.items.remove(at: itemIdx)
        updated.updatedAt = Date()
        await updateNode(updated)
    }

    // MARK: - AT19.3c — Link entry OG fetch lifecycle

    /// AT19.3c — commits a URL on a link entry and clears any prior OG
    /// metadata so the next `applyOGFetch` (or lazy on-view refetch)
    /// starts clean. Does NOT delete a prior sidecar image from disk;
    /// that orphan is bounded (a user rarely re-edits a link URL) and
    /// stays out of the happy path until a re-edit cleanup pass is
    /// scoped explicitly.
    func setLinkEntryURL(nodeID: String, itemID: String, url: String) async {
        guard let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[nodeIdx]
        guard let itemIdx = updated.items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = updated.items[itemIdx]
        item.url = url
        item.ogTitle = nil
        item.ogDescription = nil
        item.ogSiteName = nil
        item.ogImageFile = nil
        item.ogFetchedAt = nil
        item.updatedAt = Date()
        updated.items[itemIdx] = item
        updated.updatedAt = Date()
        await updateNode(updated)
    }

    /// AT19.3c — writes an `OGMetadataService.fetch` result back to a
    /// link entry. Saves the sidecar image (if present) via
    /// `saveItemFile`, populates the five OG fields, and stamps
    /// `ogFetchedAt`. A nil `metadata` (service couldn't get anything
    /// useful) still stamps `ogFetchedAt` so the lazy-fallback retry only
    /// re-fires after the staleness window — without that stamp, every
    /// view would re-hit a known-bad URL.
    func applyOGFetch(nodeID: String, itemID: String, metadata: OGMetadata?) async {
        guard let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[nodeIdx]
        guard let itemIdx = updated.items.firstIndex(where: { $0.id == itemID }) else { return }
        var item = updated.items[itemIdx]

        var imageRelativePath: String? = nil
        if let metadata, let tempURL = metadata.imageTempURL, let ext = metadata.imageExtension {
            do {
                try await service.saveItemFile(
                    nodeID: nodeID,
                    itemID: item.id,
                    sourceURL: tempURL,
                    fileExtension: "og.\(ext)"
                )
                imageRelativePath = "items/\(item.id).og.\(ext)"
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                print("[CorpusStore] applyOGFetch: sidecar save failed for \(item.id): \(error)")
                // Continue — still record the textual fields even if the
                // image couldn't land.
            }
        }

        item.ogTitle = metadata?.title
        item.ogDescription = metadata?.description
        item.ogSiteName = metadata?.siteName
        item.ogImageFile = imageRelativePath
        item.ogFetchedAt = Date()
        updated.items[itemIdx] = item
        updated.updatedAt = Date()
        await updateNode(updated)
    }

    /// AT19.3c — resolves the on-disk URL for a link entry's OG sidecar
    /// image. Companion to `itemFileURL(for:nodeID:)` which only resolves
    /// `item.file`; OG images live under a parallel field.
    func ogImageFileURL(for item: NodeItem, nodeID: String) async -> URL? {
        guard let relativePath = item.ogImageFile else { return nil }
        return await service.resolveItemPath(nodeID: nodeID, relativePath: relativePath)
    }

    /// Stage 3.1b — moves an entry within a node's items array. Single
    /// persisted mutation per reorder cycle: the controller holds the
    /// transient drag state, the store sees one final commit. No-op if
    /// `from == to`, indices are out of range, or the node is missing.
    ///
    /// `entry.updatedAt` is *not* touched (reordering is not editing); only
    /// `node.updatedAt` bumps so the on-disk file reflects the new order.
    func moveEntry(nodeID: String, from: Int, to: Int) async {
        guard let updated = applyMoveEntry(nodeID: nodeID, from: from, to: to) else { return }
        do { try await service.saveNode(updated) } catch {
            print("[CorpusStore] moveEntry persist error: \(error)")
        }
    }

    /// Synchronous in-memory half of `moveEntry`. Returned so a UI flow can
    /// batch the array mutation with view-state compensation (e.g. the
    /// reorder-drag landing) in a single SwiftUI render tick, then persist
    /// to disk asynchronously via `persistNode(_:)`. Splitting the two halves
    /// is the difference between a smooth landing and a one-frame flash at
    /// `slotPitch × slotDelta` (T observed 2026-05-16).
    @discardableResult
    func applyMoveEntry(nodeID: String, from: Int, to: Int) -> Node? {
        guard let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return nil }
        var updated = nodes[nodeIdx]
        let count = updated.items.count
        guard from >= 0, from < count, to >= 0, to < count, from != to else { return nil }
        let item = updated.items.remove(at: from)
        updated.items.insert(item, at: to)
        updated.updatedAt = Date()
        nodes[nodeIdx] = updated
        return updated
    }

    /// Persists a node already mutated in memory. Pair with `applyMoveEntry`
    /// (or other sync mutators) when the call site needs to control exactly
    /// when the disk save runs relative to view-state changes.
    func persistNode(_ node: Node) async {
        do { try await service.saveNode(node) } catch {
            print("[CorpusStore] persistNode error: \(error)")
        }
    }

    /// Persists the collapsed/expanded state for an entry card. Does not
    /// bump the entry's `updatedAt` — collapse is UI state, not content
    /// edit. The node-level `updatedAt` still bumps so the on-disk file
    /// reflects the latest save. No-op if the state already matches.
    func setEntryExpanded(itemID: String, isExpanded: Bool, nodeID: String) async {
        guard let nodeIdx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[nodeIdx]
        guard let itemIdx = updated.items.firstIndex(where: { $0.id == itemID }),
              updated.items[itemIdx].isExpanded != isExpanded else { return }
        updated.items[itemIdx].isExpanded = isExpanded
        updated.updatedAt = Date()
        await updateNode(updated)
    }

    // MARK: - Entry creation (Stage 3.1a commit (c))

    /// Appends an empty `.text` entry to a node and flags it for autofocus
    /// so the `TextEntryBody` can raise the keyboard on first render. This
    /// is the inline-append path the in-node "+" → Text button uses; the
    /// `TextCaptureSheet` modal stays for canvas-level / QuikCapture entry
    /// where there's no card to land in. Returns the new item's ID so the
    /// caller can scroll-to or otherwise reference it if needed.
    @discardableResult
    func appendEmptyTextItem(nodeID: String) async -> String {
        let now = Date()
        let item = NodeItem(
            id: UUID().uuidString,
            type: .text,
            createdAt: now,
            content: "",
            displayName: nil,
            isExpanded: true,
            updatedAt: now
        )
        pendingAutoFocusItemID = item.id
        await appendItemToNode(nodeID: nodeID, item: item)
        return item.id
    }

    /// Appends a `.link` entry to a node. URL is stored verbatim; title and
    /// preview are left nil for AT19.3c web-clipping to populate. Display
    /// name is set to the URL's host when extractable, falling back to
    /// "Link" so the title row shows something readable even if the user
    /// pasted a bare path. No-op on empty/whitespace input.
    func appendLinkItem(nodeID: String, urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let host = URL(string: trimmed)?.host ?? trimmed
        let displayName = host.isEmpty ? "Link" : host
        let item = NodeItem(
            id: UUID().uuidString,
            type: .link,
            createdAt: Date(),
            url: trimmed,
            displayName: displayName,
            isExpanded: true,
            updatedAt: Date()
        )
        await appendItemToNode(nodeID: nodeID, item: item)
    }

    /// Appends a `.document` entry to a node. Copies the picked file into
    /// the corpus's `nodes/<id>/items/` directory via the existing
    /// `saveItemFile` path, then writes the NodeItem with `file` pointing
    /// at the new copy. Display name uses the original filename so the
    /// title row shows e.g. "annual-report.pdf"; the body keeps showing
    /// the corpus-side filename for technical context. No-op if the file
    /// can't be copied.
    func appendDocumentItem(nodeID: String, sourceURL: URL) async {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if needsScope { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let itemID = UUID().uuidString
        let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
        let originalFilename = sourceURL.lastPathComponent
        do {
            try await service.saveItemFile(
                nodeID: nodeID,
                itemID: itemID,
                sourceURL: sourceURL,
                fileExtension: ext
            )
        } catch {
            print("[CorpusStore] Document file save error: \(error)")
            return
        }
        let now = Date()
        let item = NodeItem(
            id: itemID,
            type: .document,
            createdAt: now,
            file: "items/\(itemID).\(ext)",
            displayName: originalFilename,
            isExpanded: true,
            updatedAt: now
        )
        await appendItemToNode(nodeID: nodeID, item: item)
    }

    func appendItemToNodeWithAudio(nodeID: String, item: NodeItem, audioURL: URL, audioItemID: String) async {
        do {
            try await service.saveItemFile(
                nodeID: nodeID,
                itemID: audioItemID,
                sourceURL: audioURL,
                fileExtension: "m4a"
            )
        } catch {
            print("[CorpusStore] Audio file save error: \(error)")
        }
        await appendItemToNode(nodeID: nodeID, item: item)
    }

    /// Creates a new image node or appends an image item to an existing node.
    func addImageItem(
        toNodeID targetNodeID: String?,
        imageData: Data,
        description: String,
        position: CGPoint
    ) async {
        let itemID = UUID().uuidString
        let filename = "\(itemID).jpg"
        let item = NodeItem(
            id: itemID,
            type: .image,
            createdAt: Date(),
            file: "items/\(filename)",
            description: description.isEmpty ? nil : description
        )

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try imageData.write(to: tmpURL)
        } catch {
            print("[CorpusStore] Image temp write error: \(error)")
            return
        }

        if let nodeID = targetNodeID, nodes.contains(where: { $0.id == nodeID }) {
            do {
                try await service.saveItemFile(nodeID: nodeID, itemID: itemID, sourceURL: tmpURL, fileExtension: "jpg")
            } catch {
                print("[CorpusStore] Image save error: \(error)")
            }
            try? FileManager.default.removeItem(at: tmpURL)
            await appendItemToNode(nodeID: nodeID, item: item)
        } else {
            let now = Date()
            let node = Node(
                id: UUID().uuidString,
                createdAt: now,
                updatedAt: now,
                title: description.isEmpty ? "Photo" : String(description.prefix(60)),
                summary: "",
                tags: [],
                mood: nil,
                isMeta: false,
                provenance: nil,
                threads: [],
                location: nil,
                items: [item],
                domain: nil,
                domainConfirmed: false,
                needsAIProcessing: true
            )
            do {
                try await service.saveItemFile(nodeID: node.id, itemID: itemID, sourceURL: tmpURL, fileExtension: "jpg")
            } catch {
                print("[CorpusStore] Image save error: \(error)")
            }
            try? FileManager.default.removeItem(at: tmpURL)
            await addNode(node, position: position)
        }
    }

    // MARK: - Tag management

    func addTag(_ tag: Tag) async {
        tags.append(tag)
        await persistTags()
        computeTagSimilarityIfNeeded(for: tag.name)
    }

    func updateTag(_ updated: Tag) async {
        guard let idx = tags.firstIndex(where: { $0.id == updated.id }) else { return }
        tags[idx] = updated
        await persistTags()
    }

    func deleteTag(id: UUID) async {
        tags.removeAll { $0.id == id }
        await persistTags()
    }

    /// Applies tag names to a node, merging with its existing tags (no duplicates).
    /// `source` records provenance in `tagSources` — never downgrades `.user` to `.model`.
    func applyTags(_ tagNames: [String], toNodeID nodeID: String, source: TagSource = .user) async {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[idx]
        for name in tagNames {
            if !updated.tags.contains(name) {
                updated.tags.append(name)
            }
            if source == .user || updated.tagSources[name] == nil {
                updated.tagSources[name] = TagOrigin(source: source)
            }
        }
        await updateNode(updated)
    }

    private func persistTags() async {
        do {
            try await service.saveTags(tags)
        } catch {
            print("[CorpusStore] Tags save error: \(error)")
        }
    }

    private static func tier1SeedTags() -> [Tag] {
        // Hex values match the 16-swatch palette in TagEditorSheet so users can
        // recreate any default by picking from the same picker.
        let seeds: [(String, String)] = [
            ("Idea",       "#007AFF"),  // blue
            ("Work",       "#8E8E93"),  // light gray
            ("Research",   "#00C7BE"),  // teal
            ("Learning",   "#32ADE6"),  // sky blue
            ("Technology", "#5856D6"),  // indigo
            ("Science",    "#34C759"),  // green
            ("Health",     "#FF3B30"),  // red
            ("Fitness",    "#FF9500"),  // orange
            ("Creative",   "#FF2D55"),  // hot pink
            ("Story",      "#AF52DE"),  // purple
            ("Art",        "#FF6B35"),  // orange-red
            ("Recipe",     "#FFCC00"),  // yellow
            ("Travel",     "#FFFFFF"),  // white
            ("Finance",    "#A2845E"),  // brown
            ("People",     "#FF6B35"),  // orange-red (paired w/ Art)
            ("Dream",      "#AF52DE"),  // purple (paired w/ Story)
            ("Memory",     "#636366"),  // dark gray
            ("Reference",  "#8E8E93"),  // light gray (paired w/ Work)
            ("Nature",     "#34C759"),  // green (paired w/ Science)
            ("Project",    "#007AFF")   // blue (paired w/ Idea)
        ]
        let now = Date()
        return seeds.map { (name, hex) in
            Tag(id: UUID(), name: name, colorHex: hex, createdAt: now, useCount: 0)
        }
    }

    // MARK: - AI processing

    /// Runs on-device AI processing on a node after capture (non-blocking).
    /// Pass `suppressTagSheet: true` during batch import to auto-create new tags silently
    /// instead of presenting TagCreationSheet to the user.
    /// `forceCorpusAware` overrides the FeatureFlags default; nil falls through to the flag.
    func processNodeWithAI(nodeID: String, suppressTagSheet: Bool = false, forceCorpusAware: Bool? = nil) async {
        print("[AI] processNodeWithAI called for \(nodeID) suppressTagSheet=\(suppressTagSheet)")
        guard #available(iOS 26.0, *) else {
            print("[AI] iOS 26.0 unavailable — skipping AI for \(nodeID)")
            return
        }
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return }

        let currentTags = tags
        let aiSvc = AIService()

        // SB126 Stage 2 — corpus-aware tagging path. Behind a feature flag so
        // legacy processNode stays bit-identical until validation phases A–G
        // sign off. Computes a node embedding, builds a deterministic context
        // window (top-K neighborhood digests + top-N tag digests), and runs a
        // single FM call producing all per-node fields plus an FM-suggested
        // neighborhood id.
        let useCorpusAware = forceCorpusAware ?? FeatureFlags.useCorpusAwareTagging
        let nodeEmbedding: [Float]? = useCorpusAware ? computeNodeEmbedding(for: node) : nil
        let aiResult: NodeAIOutput?
        if useCorpusAware {
            let neighborhoodDigests = prefilterNeighborhoods(for: node, nodeEmbedding: nodeEmbedding, K: 5)
            let tagDigests = topTagsForProcessNode(N: 12)
            let vocabulary = currentTags.map { $0.name }
            print("[AI][SB126] Corpus-aware path for \(nodeID): \(neighborhoodDigests.count) neighborhoods, \(tagDigests.count) tag digests")
            aiResult = await aiSvc.processNodeCorpusAware(
                node: node,
                neighborhoodDigests: neighborhoodDigests,
                tagDigests: tagDigests,
                fullVocabulary: vocabulary
            )
        } else {
            aiResult = await aiSvc.processNode(node, tagVocabulary: currentTags)
        }
        guard let result = aiResult else {
            // AI unavailable — apply a fallback title from raw content so the node isn't blank
            if var n = nodes.first(where: { $0.id == nodeID }) {
                let fallback = n.items.compactMap { item -> String? in
                    switch item.type {
                    case .text:          return item.content
                    case .audio, .video: return item.transcript
                    case .link:          return item.title ?? item.url
                    case .image, .document: return nil
                    }
                }.first(where: { !$0.isEmpty })
                if let fallback, n.title.isEmpty || n.title == "Photo" || n.title == "Voice note" {
                    n.title = String(fallback.prefix(40))
                }
                n.needsAIProcessing = false
                await updateNode(n)
            }
            return
        }

        guard var updated = nodes.first(where: { $0.id == nodeID }) else { return }

        updated.title   = result.title
        updated.summary = result.summary
        updated.mood    = result.mood
        if let domain = result.domain {
            updated.domain          = domain
            updated.domainConfirmed = false
        }
        // SB126 Stage 2 — persist deterministic-prefilter embedding and the
        // FM's neighborhood guess. Both are no-ops on the legacy path.
        if useCorpusAware {
            if let nodeEmbedding {
                updated.contentEmbedding = nodeEmbedding
            }
            if let fmNeighborhood = result.neighborhoodID,
               corpusIndex.neighborhoods[fmNeighborhood] != nil {
                updated.fmSuggestedNeighborhoodID = fmNeighborhood
            }
        }

        var existingTagNames: [String] = []
        var newTagNames: [String] = []
        for name in result.tags {
            if let storedTag = currentTags.first(where: { $0.name.lowercased() == name.lowercased() }) {
                existingTagNames.append(storedTag.name)  // use stored name to match tagColorMap keys exactly
            } else {
                newTagNames.append(name)
            }
        }
        updated.tags = existingTagNames
        for name in existingTagNames where updated.tagSources[name] == nil {
            updated.tagSources[name] = TagOrigin(source: .model)
        }
        updated.needsAIProcessing = false

        // SB139 Stage 1 — substrate pipeline runs alongside the tag pipeline.
        // Single FM call producing summary + folksonomy, then three embeddings
        // via NLContextualEmbedding. Bundled into the same updateNode write so
        // capture lands one save with everything.
        if FeatureFlags.substrateOnCapture {
            await runSubstratePipeline(on: &updated, aiSvc: aiSvc)
        }
        await updateNode(updated)

        if !newTagNames.isEmpty {
            if suppressTagSheet {
                // Batch-import path: auto-create new tags with neutral color, apply silently.
                for name in newTagNames {
                    let tag = Tag(
                        id: UUID(),
                        name: name,
                        colorHex: Tag.neutralColorHex,
                        createdAt: Date(),
                        useCount: 1
                    )
                    await addTag(tag)
                }
                await applyTags(newTagNames, toNodeID: nodeID, source: .model)
                print("[AI] Silent tag apply for \(nodeID): \(newTagNames)")
            } else {
                pendingTagSuggestions = TagSuggestionContext(
                    nodeID: nodeID,
                    newTagNames: newTagNames,
                    existingTagNames: existingTagNames
                )
            }
        }

        // SB139 Stage 2 — single-capture path refreshes substrate-driven
        // thread candidates now that this node's substrate is current. The
        // batch-import path suppresses this per-node refresh and triggers
        // one combined refresh at the end of Phase 4 (see batchImportText).
        if !suppressTagSheet, #available(iOS 17.0, *) {
            refreshSubstrateThreadCandidates()
        }
    }

    /// One-time migration: re-runs AI processing on nodes that have empty tag
    /// arrays but substantive content. Restores orphans captured during the
    /// pre-`63255a7` tag-filter window and populates `contentEmbedding` on the
    /// corpus-aware path so future Layer-1 routing has the field to read.
    /// Pass-default forces the corpus-aware path regardless of the user flag.
    func reprocessUntaggedNodes(useCorpusAware: Bool = true) async {
        let untagged = nodes.filter { $0.tags.isEmpty }
        let candidates = untagged.filter { hasSubstantiveContent($0) }
        let skipped = untagged.filter { !hasSubstantiveContent($0) }

        print("[Reprocess] Found \(candidates.count) untagged nodes with substantive content (\(skipped.count) thin-content nodes skipped)")
        for thin in skipped {
            print("[Reprocess] Skipping \(thin.id) — thin content")
        }

        reprocessing = ReprocessingState(total: candidates.count, current: 0, tagged: 0, failed: 0, done: false)
        guard !candidates.isEmpty else {
            reprocessing = ReprocessingState(total: 0, current: 0, tagged: 0, failed: 0, done: true)
            print("[Reprocess] Complete: 0 attempted, 0 tagged, 0 refused/failed")
            return
        }

        var taggedCount = 0
        var failedCount = 0

        for (idx, node) in candidates.enumerated() {
            await processNodeWithAI(
                nodeID: node.id,
                suppressTagSheet: true,
                forceCorpusAware: useCorpusAware
            )
            if let post = nodes.first(where: { $0.id == node.id }), !post.tags.isEmpty {
                taggedCount += 1
            } else {
                failedCount += 1
            }
            reprocessing = ReprocessingState(
                total: candidates.count,
                current: idx + 1,
                tagged: taggedCount,
                failed: failedCount,
                done: false
            )
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        print("[Reprocess] Complete: \(candidates.count) attempted, \(taggedCount) tagged, \(failedCount) refused/failed")
        reprocessing = ReprocessingState(
            total: candidates.count,
            current: candidates.count,
            tagged: taggedCount,
            failed: failedCount,
            done: true
        )
    }

    /// SB137 Stage A — populates `contentEmbedding` on nodes that lack it so
    /// the isolate-routing path has a vector to cosine-compare against
    /// neighborhood `descriptionEmbedding`s. Pure NLEmbedding pass: no FM
    /// call, no overwrite of user-curated `title` / `summary` / `mood` /
    /// `domain` / `tags`. After completion, force a neighborhood refresh so
    /// the substrate is exercised immediately.
    func backfillContentEmbeddings() async {
        let candidates = nodes.filter { ($0.contentEmbedding ?? []).isEmpty }
        print("[Backfill] Found \(candidates.count) nodes missing contentEmbedding")

        backfillingEmbeddings = BackfillEmbeddingState(
            total: candidates.count,
            current: 0,
            populated: 0,
            skippedNoContent: 0,
            done: false
        )
        guard !candidates.isEmpty else {
            backfillingEmbeddings = BackfillEmbeddingState(
                total: 0, current: 0, populated: 0, skippedNoContent: 0, done: true
            )
            print("[Backfill] Complete: nothing to do")
            return
        }

        var populated = 0
        var skippedNoContent = 0

        for (idx, node) in candidates.enumerated() {
            if let vec = computeNodeEmbedding(for: node), !vec.isEmpty {
                var updated = node
                updated.contentEmbedding = vec
                await updateNode(updated)
                populated += 1
            } else {
                skippedNoContent += 1
            }
            backfillingEmbeddings = BackfillEmbeddingState(
                total: candidates.count,
                current: idx + 1,
                populated: populated,
                skippedNoContent: skippedNoContent,
                done: false
            )
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        print("[Backfill] Complete: \(candidates.count) attempted, \(populated) populated, \(skippedNoContent) skipped (no embeddable content)")
        backfillingEmbeddings = BackfillEmbeddingState(
            total: candidates.count,
            current: candidates.count,
            populated: populated,
            skippedNoContent: skippedNoContent,
            done: true
        )

        // Force re-cluster against the freshly populated substrate so isolate
        // routing has something to chew on without requiring a relaunch.
        invalidateNeighborhoods()
    }

    // MARK: - SB139 Stage 1 — substrate pipeline

    /// SB139 Stage 1 cleanup — pre-split, `embedder_error` was overloaded for
    /// both NL embedder load failures (no vectors) and FM `processSubstrate`
    /// non-guardrail failures (content embedding still landed). This walks
    /// existing nodes and relabels the FM-side cases as `fm_error` so the
    /// retry button finds them. Idempotent: re-running on already-migrated
    /// records is a no-op because the symptom (embedder_error + any vector)
    /// can no longer occur under the post-split write path.
    private func migrateEmbedderErrorLabels() {
        var changed: [Node] = []
        for i in nodes.indices {
            guard nodes[i].embeddingFailureReason == "embedder_error" else { continue }
            let hasAnyVector =
                (nodes[i].summaryEmbedding?.isEmpty == false)
                || (nodes[i].folksonomyEmbedding?.isEmpty == false)
                || (nodes[i].contextualContentEmbedding?.isEmpty == false)
            guard hasAnyVector else { continue }
            nodes[i].embeddingFailureReason = "fm_error"
            changed.append(nodes[i])
        }
        guard !changed.isEmpty else { return }
        print("[Substrate] Migrated \(changed.count) embedder_error → fm_error (had vectors)")
        Task {
            for node in changed {
                do { try await service.saveNode(node) }
                catch { print("[Substrate] migration save error: \(error)") }
            }
        }
    }

    /// Runs the substrate FM call + three embeddings on the given node and
    /// mutates it in place. Per the brief:
    /// - Content < 20 chars → skip FM, set `embeddingFailureReason = "thin_content"`.
    ///   Content embedding may still be computed if there's any text at all.
    /// - Guardrail refusal (~4% expected) → set
    ///   `embeddingFailureReason = "guardrail_refused"`. Substrate vectors are
    ///   populated via the legacy-FM fallback chain (legacy summary or title
    ///   + user-provenance tags), not via raw-content embedding. See
    ///   `SubstrateService.legacyFallbackEmbeddings(for:)` and the
    ///   `ws-refused-content-fallback-chain` brief — the prior raw-content
    ///   fallback created a distributional bias between refused and blended
    ///   populations in the UMAP geography.
    /// - FM call non-guardrail failure → `embeddingFailureReason = "fm_error"`.
    ///   Content embedding still attempted; summary/folksonomy nil. The
    ///   legacy fallback is NOT applied here in V1 — `fm_error` is a smaller,
    ///   retry-bounded population and stays on the prior path until the
    ///   retirement workstream lands.
    /// - `NLContextualEmbedding` load failure → `embeddingFailureReason =
    ///   "embedder_error"`. No vectors on the node.
    /// - Success → all three embeddings populated, no failure reason.
    /// `embeddingVersion` is set to the current substrate version regardless
    /// of outcome, so this node won't be re-attempted by backfill until the
    /// version constant bumps.
    @available(iOS 26.0, *)
    private func runSubstratePipeline(on node: inout Node, aiSvc: AIService) async {
        let substrate = SubstrateService.shared
        let loaded = await substrate.ensureLoaded()

        let raw = extractNodeContent(node)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        node.embeddingVersion = SubstrateService.currentEmbeddingVersion

        // Thin content path — skip FM, but still try to embed whatever text
        // exists so similarity has at least the content channel to fall back on.
        if trimmed.count < SubstrateService.thinContentThreshold {
            node.embeddingFailureReason = "thin_content"
            node.fmErrorDetail = nil
            node.substrateSummary = nil
            node.folksonomy = nil
            node.summaryEmbedding = nil
            node.folksonomyEmbedding = nil
            if loaded, !trimmed.isEmpty, let v = substrate.embed(trimmed) {
                node.contextualContentEmbedding = v
            } else {
                node.contextualContentEmbedding = nil
            }
            return
        }

        // FM call — produces summary + folksonomy in one structured response.
        let outcome = await aiSvc.processSubstrate(content: raw)
        var failureReason: String? = nil
        var fmErrorDetail: FMErrorDetail? = nil
        var producedSummary: String? = nil
        var producedFolksonomy: [String]? = nil
        switch outcome {
        case .ok(let s, let f):
            producedSummary = s.isEmpty ? nil : s
            producedFolksonomy = f.isEmpty ? nil : f
        case .guardrailRefused:
            failureReason = "guardrail_refused"
        case .otherError(let detail):
            failureReason = "fm_error"
            fmErrorDetail = detail
            print("[Substrate] FM error on \(node.id): \(detail.errorType) — \(detail.debugDescription ?? "<no debugDescription>")")
        }
        node.substrateSummary = producedSummary
        node.folksonomy = producedFolksonomy

        // Embed whichever channels we have text for. Embedder load failure
        // is its own reason and overrides any prior FM-side reason — the
        // node ends up with no vectors at all.
        if !loaded {
            node.embeddingFailureReason = "embedder_error"
            node.fmErrorDetail = nil
            node.summaryEmbedding = nil
            node.folksonomyEmbedding = nil
            node.contextualContentEmbedding = nil
            return
        }

        // Refused branch: route through the legacy-FM fallback chain. The
        // substrate vectors carry the legacy summary + user-tags signal so
        // refused nodes share a distribution with blended nodes in the UMAP
        // geography. Content embedding is intentionally not populated here
        // — the prior raw-content path is what we're replacing.
        if failureReason == "guardrail_refused" {
            let fallback = substrate.legacyFallbackEmbeddings(for: node)
            node.summaryEmbedding = fallback.summary
            node.folksonomyEmbedding = fallback.folksonomy
            node.contextualContentEmbedding = nil
        } else {
            node.summaryEmbedding = producedSummary.flatMap { substrate.embed($0) }
            node.folksonomyEmbedding = producedFolksonomy
                .map { $0.joined(separator: ", ") }
                .flatMap { $0.isEmpty ? nil : substrate.embed($0) }
            node.contextualContentEmbedding = trimmed.isEmpty ? nil : substrate.embed(trimmed)
        }
        node.embeddingFailureReason = failureReason
        node.fmErrorDetail = fmErrorDetail

        // Bump the post-recompute counter and trigger a recompute when we cross
        // the threshold. Cheap to do inline; no scheduling needed at our corpus size.
        if node.contextualContentEmbedding != nil
            || node.summaryEmbedding != nil
            || node.folksonomyEmbedding != nil {
            substrate.registerNewEmbed()
            if substrate.shouldRecomputeMeans {
                substrate.recomputeMeans(from: nodes)
            }
        }
    }

    /// SB139 Stage 1 — substrate backfill control. Manual trigger, batched.
    /// Targets nodes where `embeddingVersion < currentEmbeddingVersion`
    /// (covers both pre-substrate captures and any future version bump).
    /// `batchSize` defaults to 10 per the brief; pass `Int.max` for a full
    /// corpus run. Recomputes means once at the end so similarity is fresh.
    func backfillSubstrate(batchSize: Int = 10) async {
        guard #available(iOS 26.0, *) else { return }
        let pending = nodes
            .filter { $0.embeddingVersion < SubstrateService.currentEmbeddingVersion }
            .sorted { $0.createdAt < $1.createdAt }
        await runSubstrateBatch(
            label: "SubstrateBackfill",
            pending: pending,
            batchSize: batchSize
        )
    }

    /// SB139 Stage 4b — apply the legacy-FM fallback chain to every node
    /// already marked `guardrail_refused`. Idempotent: re-running produces
    /// the same vectors because the inputs (legacy summary, title, user
    /// tags) are deterministic given the node's current state, and the
    /// failure reason stays `guardrail_refused` so the candidate set is
    /// stable. Skips the FM entirely — no per-node FM call needed since
    /// the legacy artifacts are already on disk.
    ///
    /// Used by the "Backfill refused-node fallback" affordance in
    /// `SubstrateInspectView` to bring the existing refused population onto
    /// the new chain without forcing a full re-capture.
    @available(iOS 17.0, *)
    func backfillRefusedNodesFallback() async {
        let substrate = SubstrateService.shared
        _ = await substrate.ensureLoaded()
        guard substrate.isLoaded else {
            print("[SubstrateRefusedBackfill] embedder unavailable — aborting")
            return
        }

        let pending = nodes.filter { $0.embeddingFailureReason == "guardrail_refused" }
        let total = pending.count
        print("[SubstrateRefusedBackfill] pending=\(total)")

        substrateBackfill = SubstrateBackfillState(
            batchTotal: total, current: 0, succeeded: 0,
            guardrailRefused: 0, thinContent: 0, fmError: 0, embedderError: 0,
            pendingAfter: total, done: false, lastRunAt: nil
        )

        guard total > 0 else {
            substrateBackfill = SubstrateBackfillState(
                batchTotal: 0, current: 0, succeeded: 0,
                guardrailRefused: 0, thinContent: 0, fmError: 0, embedderError: 0,
                pendingAfter: 0, done: true, lastRunAt: Date()
            )
            return
        }

        var processed = 0
        for (idx, node) in pending.enumerated() {
            guard var working = nodes.first(where: { $0.id == node.id }) else { continue }
            let fallback = substrate.legacyFallbackEmbeddings(for: working)
            working.summaryEmbedding = fallback.summary
            working.folksonomyEmbedding = fallback.folksonomy
            working.contextualContentEmbedding = nil
            // Preserve `embedding_failure_reason = "guardrail_refused"` as
            // historical provenance — the diagnostic export needs it to
            // group the population for hypothesis-3 validation.
            await updateNode(working)
            processed += 1

            substrateBackfill = SubstrateBackfillState(
                batchTotal: total,
                current: idx + 1,
                succeeded: processed,
                guardrailRefused: total,
                thinContent: 0, fmError: 0, embedderError: 0,
                pendingAfter: max(0, total - (idx + 1)),
                done: false, lastRunAt: nil
            )
        }

        substrate.recomputeMeans(from: nodes)

        substrateBackfill = SubstrateBackfillState(
            batchTotal: total,
            current: total,
            succeeded: processed,
            guardrailRefused: total,
            thinContent: 0, fmError: 0, embedderError: 0,
            pendingAfter: 0,
            done: true, lastRunAt: Date()
        )
        print("[SubstrateRefusedBackfill] complete: \(processed)/\(total) refused nodes re-embedded via legacy fallback")

        refreshSubstrateThreadCandidates()
    }

    /// SB139 Stage 1 — targeted retry for nodes that landed in `fm_error`.
    /// Same loop as `backfillSubstrate` but pre-filters by failure reason so
    /// we don't re-process the 132 healthy nodes. Useful for distinguishing
    /// transient FM unavailability from systematic prompt/schema issues.
    func retrySubstrateFMErrors(batchSize: Int = Int.max) async {
        guard #available(iOS 26.0, *) else { return }
        let pending = nodes
            .filter { $0.embeddingFailureReason == "fm_error" }
            .sorted { $0.createdAt < $1.createdAt }
        await runSubstrateBatch(
            label: "SubstrateRetryFMErrors",
            pending: pending,
            batchSize: batchSize
        )
    }

    /// Shared loop body for backfill and targeted retry. `pending` is the full
    /// candidate set (used for `pendingAfter` accounting); the batch is
    /// `prefix(batchSize)` of that set.
    @available(iOS 26.0, *)
    private func runSubstrateBatch(label: String, pending: [Node], batchSize: Int) async {
        let aiSvc = AIService()
        let substrate = SubstrateService.shared
        _ = await substrate.ensureLoaded()

        let target = Array(pending.prefix(max(0, batchSize)))
        print("[\(label)] pending=\(pending.count) targeting=\(target.count)")

        substrateBackfill = SubstrateBackfillState(
            batchTotal: target.count,
            current: 0,
            succeeded: 0,
            guardrailRefused: 0,
            thinContent: 0,
            fmError: 0,
            embedderError: 0,
            pendingAfter: pending.count,
            done: false,
            lastRunAt: nil
        )

        guard !target.isEmpty else {
            substrateBackfill = SubstrateBackfillState(
                batchTotal: 0, current: 0, succeeded: 0,
                guardrailRefused: 0, thinContent: 0, fmError: 0, embedderError: 0,
                pendingAfter: 0, done: true, lastRunAt: Date()
            )
            return
        }

        var succeeded = 0, refused = 0, thin = 0, fmErrored = 0, embedderErrored = 0

        for (idx, node) in target.enumerated() {
            // Re-fetch from `nodes` so we never overwrite a concurrent update.
            guard var working = nodes.first(where: { $0.id == node.id }) else { continue }
            await runSubstratePipeline(on: &working, aiSvc: aiSvc)
            await updateNode(working)

            switch working.embeddingFailureReason {
            case "guardrail_refused": refused += 1
            case "thin_content": thin += 1
            case "fm_error": fmErrored += 1
            case "embedder_error": embedderErrored += 1
            case nil: succeeded += 1
            default: break
            }

            substrateBackfill = SubstrateBackfillState(
                batchTotal: target.count,
                current: idx + 1,
                succeeded: succeeded,
                guardrailRefused: refused,
                thinContent: thin,
                fmError: fmErrored,
                embedderError: embedderErrored,
                pendingAfter: max(0, pending.count - (idx + 1)),
                done: false,
                lastRunAt: nil
            )
            // Light back-pressure between FM calls.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Recompute means once after the batch — cheaper than per-node and
        // gives Stage 2 / dev inspect view a consistent reference frame.
        substrate.recomputeMeans(from: nodes)

        substrateBackfill = SubstrateBackfillState(
            batchTotal: target.count,
            current: target.count,
            succeeded: succeeded,
            guardrailRefused: refused,
            thinContent: thin,
            fmError: fmErrored,
            embedderError: embedderErrored,
            pendingAfter: max(0, pending.count - target.count),
            done: true,
            lastRunAt: Date()
        )
        print("[\(label)] complete: \(succeeded) ok, \(refused) refused, \(thin) thin, \(fmErrored) fm_error, \(embedderErrored) embedder_error")

        // SB139 Stage 2 — backfill changed which pairs are rankable; refresh
        // the thread queue against the new substrate state.
        refreshSubstrateThreadCandidates()
    }

    /// Item-level threshold check used by `reprocessUntaggedNodes`. A node
    /// qualifies if at least one item passes the type-specific gate.
    private func hasSubstantiveContent(_ node: Node) -> Bool {
        guard !node.items.isEmpty else { return false }
        for item in node.items {
            switch item.type {
            case .text:
                if let c = item.content, meetsTextThreshold(c) { return true }
            case .audio:
                if let t = item.transcript, meetsTextThreshold(t) { return true }
            case .link:
                if let title = item.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if let url = item.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            case .image, .video, .document:
                continue
            }
        }
        return false
    }

    private func meetsTextThreshold(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        return words >= 4
    }

    /// On launch, process any nodes captured via the share extension (no AI ran at capture time).
    private func scanForUnprocessedNodes() async {
        let unprocessed = nodes.filter { $0.needsAIProcessing }
        for node in unprocessed {
            await processNodeWithAI(nodeID: node.id)
        }
    }

    /// Async FM coherence check for nodes deferred by the Router.
    /// Runs in background after import. Updates nodes based on FM verdict:
    /// - Coherent: leave as-is (normal AI processing will happen)
    /// - Incoherent: set needsReview flag for user confirmation
    /// - Model unavailable: treat as pass (don't block)
    private func processDeferredNodesWithFM(nodeIDs: [String]) async {
        guard #available(iOS 26.0, *) else {
            print("[FM] iOS 26.0 unavailable — skipping FM check for \(nodeIDs.count) nodes")
            return
        }

        print("[FM] Starting FM coherence check for \(nodeIDs.count) deferred nodes")
        let aiSvc = AIService()

        // Process in batches of 10 to avoid overwhelming the model
        let batchSize = 10
        for batchStart in stride(from: 0, to: nodeIDs.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, nodeIDs.count)
            let batch = Array(nodeIDs[batchStart..<batchEnd])

            await withTaskGroup(of: (String, Bool?).self) { group in
                for nodeID in batch {
                    group.addTask {
                        // Get node text
                        guard let node = await self.nodes.first(where: { $0.id == nodeID }) else {
                            return (nodeID, nil)
                        }
                        let text = node.items.compactMap { item -> String? in
                            switch item.type {
                            case .text: return item.content
                            case .audio, .video: return item.transcript
                            case .link: return item.title ?? item.url
                            case .image, .document: return item.description
                            }
                        }.filter { !$0.isEmpty }.joined(separator: "\n")

                        guard !text.isEmpty else {
                            return (nodeID, nil)
                        }

                        // Run FM coherence check
                        let result = await aiSvc.checkCoherence(text)
                        return (nodeID, result)
                    }
                }

                // Process results
                for await (nodeID, coherenceResult) in group {
                    guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
                    var node = nodes[idx]

                    switch coherenceResult {
                    case true:
                        // FM says coherent — leave node as-is, normal AI will process it
                        print("[FM] \(nodeID): COHERENT — keeping in corpus")

                    case false:
                        // FM says incoherent — flag for user review
                        print("[FM] \(nodeID): INCOHERENT — setting needsReview flag")
                        node.needsReview = true
                        await updateNode(node)

                    case nil:
                        // Model unavailable — treat as pass
                        print("[FM] \(nodeID): model unavailable — treating as pass")
                    }
                }
            }
        }

        print("[FM] FM coherence check complete for \(nodeIDs.count) nodes")
    }

    // MARK: - Thread surfacing

    /// SB139 Stage 2 — recompute the substrate-driven thread queue. Runs
    /// against current `nodes` and the in-memory dismissed-pair set.
    /// Deterministic; no FM call. Replaces the FM-driven `analyzeCorpus`
    /// path. Cheap at our corpus size (≤200 nodes ≈ 20K cosines, well under
    /// 100ms), so callers re-run it on each capture / backfill / pull.
    ///
    /// Behavior model: `pendingThreads` is a queue; ContentView shows
    /// `.first`. We replace the queue wholesale so the freshest top-K is
    /// always what surfaces next. Dismiss/pull triggers a refresh that
    /// removes the just-handled pair (dismissal via session set, pull via
    /// the new meta-node landing in `alreadyConnectedPairs`).
    @available(iOS 17.0, *)
    private func refreshSubstrateThreadCandidates() {
        let suggestions = SubstrateThreadService.candidates(
            in: nodes,
            dismissedPairKeys: dismissedThreadPairKeys
        )
        // Cap the visible queue. Brief calls for one-at-rest; we keep a
        // small head so the next-best is ready when the user dismisses
        // without paying for another full scan.
        pendingThreads = Array(suggestions.prefix(5))
    }

    /// Accept a thread suggestion — creates a meta-node and updates source node thread arrays.
    func pullThread(_ suggestion: ThreadSuggestion) async {
        pendingThreads.removeAll { $0.id == suggestion.id }

        let sourceNodes = suggestion.nodeIDs.compactMap { id in nodes.first { $0.id == id } }
        let sourceTitles = sourceNodes.map { $0.title }.joined(separator: ", ")
        let unionTags = Array(Set(sourceNodes.compactMap { $0.tags.first }))

        let now = Date()
        let metaNode = Node(
            id: UUID().uuidString,
            createdAt: now,
            updatedAt: now,
            title: suggestion.description,
            summary: "Connected from \(sourceTitles)",
            tags: unionTags,
            mood: nil,
            isMeta: true,
            provenance: suggestion.nodeIDs,
            threads: suggestion.nodeIDs,
            location: nil,
            items: [],
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: false
        )

        // Place meta-node at centroid of source nodes
        let positions = suggestion.nodeIDs.compactMap { canvasLayout.positions[$0] }
        let centroid: CGPoint
        if positions.isEmpty {
            centroid = CGPoint(x: Double.random(in: -80...80), y: Double.random(in: -80...80))
        } else {
            let cx = positions.map { $0.x }.reduce(0, +) / Double(positions.count)
            let cy = positions.map { $0.y }.reduce(0, +) / Double(positions.count)
            centroid = CGPoint(x: cx + Double.random(in: -25...25), y: cy + Double.random(in: -25...25))
        }

        // Bidirectional: update source nodes' threads arrays
        for nodeID in suggestion.nodeIDs {
            guard var source = nodes.first(where: { $0.id == nodeID }) else { continue }
            if !source.threads.contains(metaNode.id) {
                source.threads.append(metaNode.id)
                await updateNode(source)
            }
        }

        await addNode(metaNode, position: centroid)

        // SB139 Stage 2 — the just-pulled pair now lands in
        // `alreadyConnectedPairs` (via the new meta-node's provenance), so a
        // refresh drops it from the queue and surfaces the next candidate.
        if #available(iOS 17.0, *) {
            refreshSubstrateThreadCandidates()
        }
    }

    /// Dismiss a thread suggestion. Per the SB139 Stage 2 brief, dismissal
    /// is one-time: the surface card is removed, the pair key is added to
    /// the session-only dismissed set so the same pair won't reappear in
    /// this session, but the candidate stays in the pool and may surface
    /// again after relaunch.
    func dismissThread(_ suggestion: ThreadSuggestion) {
        if suggestion.nodeIDs.count == 2,
           #available(iOS 17.0, *) {
            let key = SubstrateThreadService.pairKey(suggestion.nodeIDs[0], suggestion.nodeIDs[1])
            dismissedThreadPairKeys.insert(key)
        }
        pendingThreads.removeAll { $0.id == suggestion.id }
    }

    /// Promote a meta-node to a true node. Irreversible.
    func promoteMetaNode(nodeID: String) async {
        guard var node = nodes.first(where: { $0.id == nodeID }), node.isMeta else { return }
        node.isMeta = false
        node.provenance = nil
        node.updatedAt = Date()
        await updateNode(node)
    }

    // MARK: - Share extension inbox import

    /// Reads nodes staged by the share extension in the App Group container and imports them.
    private func importFromAppGroupInbox() async {
        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.doctorpresident.airpad"
        ) else { return }

        let inbox = groupContainer.appendingPathComponent("AirPad/inbox")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for dir in dirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let nodeFile = dir.appendingPathComponent("node.json")
            guard let data = try? Data(contentsOf: nodeFile),
                  let node = try? JSONDecoder.airPad.decode(Node.self, from: data) else { continue }

            // Skip if already imported
            guard !nodes.contains(where: { $0.id == node.id }) else {
                try? FileManager.default.removeItem(at: dir)
                continue
            }

            do {
                try await service.saveNode(node)
            } catch {
                print("[CorpusStore] Inbox import error: \(error)")
                continue
            }

            // Copy any media files staged alongside the node JSON
            let itemsDir = dir.appendingPathComponent("items")
            if let mediaFiles = try? FileManager.default.contentsOfDirectory(
                at: itemsDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) {
                for mediaFile in mediaFiles {
                    let itemID = mediaFile.deletingPathExtension().lastPathComponent
                    let ext = mediaFile.pathExtension
                    try? await service.saveItemFile(
                        nodeID: node.id, itemID: itemID, sourceURL: mediaFile, fileExtension: ext
                    )
                }
            }

            try? FileManager.default.removeItem(at: dir)
            nodes.insert(node, at: 0)
        }
    }

    // MARK: - Batch import

    /// Parses `text` into nodes and saves them all to iCloud. Non-blocking: progress is
    /// reflected in `importBatchProgress` so the canvas can show a banner.
    /// Three-layer quality gate: (1) character threshold, (2) heuristic fragment detection,
    /// (3) Foundation Model coherence check. Failures collect in `reviewQueue`.
    func batchImportText(_ text: String) async {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())

        print("[Batch] Input text length: \(text.count) chars")

        // Diagnostic: Count segments from splitter
        let segments = BatchParser.splitText(text)
        print("[Batch] Splitter produced \(segments.count) segments from input text")

        // Prune expired quarantine entries (48-hour TTL)
        BatchParser.pruneExpiredQuarantined()
        quarantineStore?.pruneExpired()

        // Run text through the Router pipeline (Session 2+)
        let result = BatchParser.processText(text)

        print("[Batch] Router results: clean=\(result.commitClean.count), review=\(result.commitWithReview.count), quarantined=\(result.quarantined.count), deferredToFM=\(result.deferredToFM.count)")

        // Diagnostic: Log quarantined entry details
        if !result.quarantined.isEmpty {
            print("[Batch] Quarantined entries detail:")
            for (index, entry) in result.quarantined.enumerated() {
                print("[Batch]   [\(index+1)] reason=\(entry.reason), text=\(entry.rawText.prefix(50))...")
            }
        }

        // Create nodes from Router outcomes
        // commitClean: nodes without review flag
        var parsedNodes = BatchParser.makeNodes(texts: result.commitClean, importTimestamp: timestamp, needsReview: false)

        // commitWithReview: nodes with review flag set
        parsedNodes.append(contentsOf: BatchParser.makeNodes(texts: result.commitWithReview, importTimestamp: timestamp, needsReview: true))

        // deferredToFM: create nodes immediately, process with FM asynchronously after import
        let deferredNodes = BatchParser.makeNodes(texts: result.deferredToFM, importTimestamp: timestamp, needsReview: false)
        let deferredNodeIDs = deferredNodes.map { $0.id }
        parsedNodes.append(contentsOf: deferredNodes)

        // Store quarantined entries (NOT converted to nodes)
        for entry in result.quarantined {
            BatchParser.storeQuarantined(entry)
            quarantineStore?.add(entry)
        }

        print("[Batch] Created \(parsedNodes.count) nodes to import")

        guard !parsedNodes.isEmpty else {
            print("[Batch] No nodes to import — returning early")
            return
        }

        let total = parsedNodes.count
        importBatchProgress = (0, total)
        print("[Batch] Starting import. total=\(total) iCloudUnavailable=\(iCloudUnavailable)")

        // Phase 1 — save all nodes to disk; accumulate successfully-saved set.
        // Do NOT mutate store.nodes yet — we need canvasLayout ready first so that
        // when nodes land in the store and onChange fires, syncScene has correct positions.
        var savedNodes: [Node] = []
        var newLayout = canvasLayout
        for (index, node) in parsedNodes.enumerated() {
            // Task 4: Tag-overlap-aware placement instead of spiral
            newLayout.positions[node.id] = semanticPosition(
                for: node,
                existingLayout: newLayout,
                index: index,
                total: total
            )

            do {
                try await service.saveNode(node)
                savedNodes.append(node)
                print("[Batch] [\(index + 1)/\(total)] Saved \(node.id)")
            } catch {
                print("[Batch] [\(index + 1)/\(total)] SAVE ERROR \(node.id): \(error)")
            }
            importBatchProgress = (index + 1, total)
        }
        print("[Batch] Phase 1 done: \(savedNodes.count)/\(total) saved to disk")

        // Phase 2 — persist layout first so store.canvasLayout has all positions
        // before any onChange(of: store.nodes) fires in CanvasView.
        newLayout.updatedAt = Date()
        do {
            try await service.saveCanvasLayout(newLayout)
            canvasLayout = newLayout
            print("[Batch] Phase 2 done: layout persisted (\(newLayout.positions.count) positions)")
        } catch {
            print("[Batch] Phase 2 layout save ERROR: \(error)")
        }

        // Phase 3 — reset any active filter so newly imported nodes (which have no tags yet)
        // are visible immediately. Batch nodes have tags: [] — a tag filter would exclude all of them.
        let hadActiveFilter = filterState.activeFilterCount > 0
        if hadActiveFilter {
            filterState.tagName = nil
            filterState.itemType = .all
            filterState.threadStatus = .all
            print("[Batch] Cleared active filter so imported nodes are visible")
        }

        // Bulk-insert all saved nodes into store.nodes.
        // No await between inserts, so SwiftUI batches them into one onChange firing.
        // At this point canvasLayout is already correct, so syncScene will place nodes accurately.
        let beforeCount = nodes.count
        for node in savedNodes.reversed() {
            nodes.insert(node, at: 0)
        }
        let insertedCount = nodes.count - beforeCount
        print("[Batch] Phase 3 done: store.nodes \(beforeCount) → \(nodes.count) (inserted \(insertedCount) nodes)")
        print("[Batch] === IMPORT SUMMARY: \(segments.count) segments → \(result.commitClean.count) clean + \(result.commitWithReview.count) review + \(result.deferredToFM.count) deferred = \(parsedNodes.count) total nodes → \(insertedCount) successfully inserted, \(result.quarantined.count) quarantined ===")

        importBatchProgress = nil

        // Explicit sync token — fires onChange(of: store.canvasNeedsSync) in CanvasView
        // as belt-and-suspenders in case the onChange(of: store.nodes) chain was coalesced
        // or stale during the import.
        canvasNeedsSync = UUID()
        print("[Batch] canvasNeedsSync fired")

        // Phase 4 — AI title/summary in background; suppress tag sheet for batch
        let savedIDs = savedNodes.map { $0.id }
        print("[Batch] Kicking off AI for \(savedIDs.count) nodes (suppressTagSheet=true)")
        Task {
            for id in savedIDs {
                print("[Batch][AI] Processing \(id)")
                await processNodeWithAI(nodeID: id, suppressTagSheet: true)
                scheduleClusterRefresh()  // Task 3: debounced refresh
            }
            await flushClusterRefresh()  // Task 3: final guaranteed refresh
            refreshNeighborhoods()  // Refresh after all AI processing complete
            recomputeAlgorithmicLayout(reason: "batch import complete")  // Algorithmic layout after import
            print("[Batch][AI] All done")
            // SB139 Stage 2 — substrate-driven thread candidates. Per-node
            // refresh is suppressed during batch (suppressTagSheet=true);
            // we do one combined refresh now that the corpus is fully
            // processed. Deterministic, no FM call. SB123's `count >= 10`
            // gate retired with the FM threads path — substrate works on
            // any corpus size and just returns no candidates if nothing
            // qualifies.
            if #available(iOS 17.0, *) {
                refreshSubstrateThreadCandidates()
            }
        }

        // Phase 5 — Async FM coherence check for deferred entries
        if !deferredNodeIDs.isEmpty {
            let deferredIDs = deferredNodeIDs.filter { id in savedNodes.contains { $0.id == id } }
            print("[Batch] Kicking off async FM check for \(deferredIDs.count) deferred nodes")
            Task {
                await processDeferredNodesWithFM(nodeIDs: deferredIDs)
            }
        }
    }

    // MARK: - Gate diagnostic helpers

    /// TEST RUNNER: Process the test corpus through the Router pipeline
    func runGateDiagnosticTest() async {
        let testCorpusPath = NSHomeDirectory() + "/Desktop/AirPad/test_fixturess/corpus_test_master.md"

        guard let rawText = try? String(contentsOfFile: testCorpusPath, encoding: .utf8) else {
            print("[DIAGNOSTIC] Failed to read test corpus at: \(testCorpusPath)")
            return
        }

        print("[DIAGNOSTIC] Loaded test corpus: \(rawText.count) chars")
        print("[DIAGNOSTIC] Starting batch import through instrumented gate...")

        await batchImportText(rawText)

        print("[DIAGNOSTIC] Test run complete. Check log file for results.")
    }

    // MARK: - Destructive operations

    func deleteNode(id: String) async {
        await deleteNodes(ids: [id])
    }

    /// Batch delete. Removes nodes from disk + memory, cleans up dangling
    /// thread / provenance references on remaining nodes, drops canvas layout
    /// entries, and invalidates ephemeral caches. The substrate fitted model's
    /// `trainingPoints` snapshot is intentionally NOT pruned — it's a frozen
    /// fit-time artifact, and pruning it would cause `SubstrateCanvasLayoutAdapter`
    /// to re-normalize the min/max bounds and shift every surviving node on
    /// screen. Ghost entries in the snapshot are inert and clear on the next
    /// deliberate refit.
    func deleteNodes(ids: Set<String>) async {
        guard !ids.isEmpty else { return }

        for id in ids {
            do {
                try await service.deleteNode(id: id)
            } catch {
                print("[CorpusStore] deleteNodes error for \(id): \(error)")
            }
        }
        nodes.removeAll { ids.contains($0.id) }

        // Filter dangling NodeID references on remaining nodes. Source-node
        // `threads[]` carries meta-node IDs (set bidirectionally in pullThread);
        // meta-node `provenance[]` carries source-node IDs. Both can dangle
        // after a delete, so we filter both directions on every survivor and
        // re-persist only the ones that actually changed.
        var changedNodes: [Node] = []
        for index in nodes.indices {
            var node = nodes[index]
            var changed = false
            let filteredThreads = node.threads.filter { !ids.contains($0) }
            if filteredThreads.count != node.threads.count {
                node.threads = filteredThreads
                changed = true
            }
            if let provenance = node.provenance {
                let filteredProvenance = provenance.filter { !ids.contains($0) }
                if filteredProvenance.count != provenance.count {
                    node.provenance = filteredProvenance
                    changed = true
                }
            }
            if changed {
                node.updatedAt = Date()
                nodes[index] = node
                changedNodes.append(node)
            }
        }
        for node in changedNodes {
            do {
                try await service.saveNode(node)
            } catch {
                print("[CorpusStore] deleteNodes: saveNode error for \(node.id): \(error)")
            }
        }

        // Canvas layout positions: drop all deleted IDs in a single write.
        let hadAnyLayoutEntry = ids.contains { canvasLayout.positions[$0] != nil }
        if hadAnyLayoutEntry {
            var positions = canvasLayout.positions
            for id in ids { positions.removeValue(forKey: id) }
            let updated = CanvasLayout(version: canvasLayout.version, updatedAt: Date(), positions: positions)
            canvasLayout = updated
            do {
                try await service.saveCanvasLayout(updated)
            } catch {
                print("[CorpusStore] deleteNodes: layout save error: \(error)")
            }
        }

        // Ephemeral caches. Neighborhood + Über-node caches recompute on next
        // access from the new `nodes[]`; pending thread suggestions referencing
        // deleted IDs are dropped explicitly so the user doesn't see a
        // suggestion for a node that no longer exists.
        neighborhoodCache = nil
        uberNodeCache = nil
        pendingThreads.removeAll { suggestion in
            suggestion.nodeIDs.contains(where: { ids.contains($0) })
        }

        if let selected = canvasState?.selectedNodeID, ids.contains(selected) {
            canvasState?.selectedNodeID = nil
        }
        canvasNeedsSync = UUID()
    }

    /// Batch tag application. Idempotent — nodes already carrying `tagName` are
    /// unchanged. Registers `tagName` in the tag vocabulary if it isn't
    /// already there. Tags applied via this path carry `.user` provenance.
    func addTag(_ tagName: String, toNodes ids: Set<String>) async {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ids.isEmpty else { return }

        // Defensive: caller is expected to have registered the tag via
        // TagEditorSheet (which assigns a chosen color). If somehow we receive
        // a name not yet in vocabulary, register it with the neutral color so
        // the apply-to-nodes step doesn't drop the tag silently.
        if !tags.contains(where: { $0.name == trimmed }) {
            let newTag = Tag(
                id: UUID(),
                name: trimmed,
                colorHex: Tag.neutralColorHex,
                createdAt: Date(),
                useCount: 0
            )
            tags.append(newTag)
            do {
                try await service.saveTags(tags)
            } catch {
                print("[CorpusStore] addTag(batch): saveTags error: \(error)")
            }
        }

        var changedNodes: [Node] = []
        for index in nodes.indices {
            guard ids.contains(nodes[index].id) else { continue }
            var node = nodes[index]
            if node.tags.contains(trimmed) {
                continue
            }
            node.tags.append(trimmed)
            node.tagSources[trimmed] = TagOrigin(source: .user)
            node.updatedAt = Date()
            nodes[index] = node
            changedNodes.append(node)
        }
        for node in changedNodes {
            do {
                try await service.saveNode(node)
            } catch {
                print("[CorpusStore] addTag(batch): saveNode error for \(node.id): \(error)")
            }
        }
    }

    func clearAllData() async {
        do {
            try await service.deleteAllData()
        } catch {
            print("[CorpusStore] clearAllData error: \(error)")
        }
        nodes = []
        tags = []
        canvasLayout = CanvasLayout(version: 1, updatedAt: Date(), positions: [:])
        reviewQueue = []
        canvasNeedsSync = UUID()
    }

    // MARK: - Review queue

    func promoteRejectedBlock(_ block: RejectedBlock) async {
        let node = BatchParser.makeNodes(texts: [block.text], importTimestamp: block.importTimestamp).first!
        do {
            try await service.saveNode(node)
            nodes.insert(node, at: 0)
            removeFromReviewQueue(id: block.id)
            await processNodeWithAI(nodeID: node.id, suppressTagSheet: false)
        } catch {
            print("[ReviewQueue] Promote error: \(error)")
        }
    }

    func removeFromReviewQueue(id: String) {
        reviewQueue.removeAll { $0.id == id }
    }

    /// Rescues a quarantined entry by creating a Node and adding it to the corpus.
    /// Does NOT re-run through Router (user override).
    func rescueQuarantinedEntry(_ entry: BatchParser.QuarantinedEntry) async {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let source = "quarantine-rescue-\(timestamp)"

        // Create node directly from raw text
        let nodeID = UUID().uuidString
        let now = Date()
        let item = NodeItem(
            id: UUID().uuidString,
            type: .text,
            createdAt: now,
            content: entry.rawText
        )
        let node = Node(
            id: nodeID,
            createdAt: now,
            updatedAt: now,
            title: "",
            summary: "",
            tags: [],
            items: [item],
            needsAIProcessing: true,
            needsReview: false,
            source: source
        )

        // Save to disk and add to store
        do {
            try await service.saveNode(node)
            nodes.insert(node, at: 0)
            quarantineStore?.remove(entry)
            print("[Quarantine] Rescued entry as node \(nodeID)")
            // Process with AI (no tag sheet since these are usually low-quality)
            await processNodeWithAI(nodeID: node.id, suppressTagSheet: true)
        } catch {
            print("[Quarantine] ERROR rescuing entry: \(error)")
        }
    }

    private static let reviewQueueUDKey = "com.airpad.reviewQueue"

    private func saveReviewQueue() {
        if let data = try? JSONEncoder().encode(reviewQueue) {
            UserDefaults.standard.set(data, forKey: Self.reviewQueueUDKey)
        }
    }

    private func loadReviewQueue() -> [RejectedBlock] {
        guard let data = UserDefaults.standard.data(forKey: Self.reviewQueueUDKey),
              let queue = try? JSONDecoder().decode([RejectedBlock].self, from: data)
        else { return [] }
        return queue
    }

    // MARK: - Über-node clustering (Tier 1: tag-only)

    /// Generate or refresh Über-node clusters if needed.
    /// Called automatically after node additions when invalidation threshold is met.
    func refreshUberNodeClusters() {
        // Compute current fingerprint
        let service = UberNodeService()
        let currentFingerprint = service.corpusHash(from: nodes)

        // Check if cache exists and is still valid
        if let cache = uberNodeCache,
           !cache.shouldInvalidate(currentFingerprint: currentFingerprint) {
            return  // Cache is still fresh
        }

        // Generate new clusters
        uberNodeCache = service.generateClusters(from: nodes)

        if let cache = uberNodeCache {
            print("[UberNode] Generated \(cache.clusters.count) clusters from \(nodes.count) nodes")
        } else {
            print("[UberNode] No viable clusters (need weighted count >= 2.0)")
        }
    }

    /// Force regeneration of Über-node clusters (ignores cache validity).
    func invalidateUberNodeClusters() {
        uberNodeCache = nil
        refreshUberNodeClusters()
    }

    /// Schedule a debounced cluster refresh (Task 3: 500ms debounce).
    private func scheduleClusterRefresh() {
        clusterRefreshTask?.cancel()
        clusterRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            refreshUberNodeClusters()
            refreshNeighborhoods()
        }
    }

    /// Flush any pending debounced refresh and run immediately (Task 3).
    private func flushClusterRefresh() async {
        clusterRefreshTask?.cancel()
        clusterRefreshTask = nil
        refreshUberNodeClusters()
        refreshNeighborhoods()
    }

    // MARK: - Neighborhood detection

    /// Generate or refresh neighborhoods if needed.
    /// Called automatically after node additions when invalidation threshold is met.
    func refreshNeighborhoods() {
        // Compute current fingerprint
        let service = NeighborhoodService()
        let currentFingerprint = service.corpusFingerprint(from: nodes)

        // Check if cache exists and is still valid
        if let cache = neighborhoodCache,
           !cache.shouldInvalidate(currentFingerprint: currentFingerprint) {
            print("[Neighborhood] refreshNeighborhoods() called — cache valid: true, fingerprint match: true")
            return  // Cache is still fresh
        }

        let hadCache = neighborhoodCache != nil
        let previousNeighborhoodCount = neighborhoodCache?.neighborhoods.count ?? 0
        let previousLargestMemberCount = neighborhoodCache?.neighborhoods.first?.memberCount ?? 0
        print("[Neighborhood] refreshNeighborhoods() called — cache valid: false, fingerprint match: \(hadCache ? "false" : "n/a (no cache)")")

        // Build previous member sets from the persisted index so the service
        // can Jaccard-match fresh clusters to old ones (AT21 Cat A1).
        let previousMembers: [String: Set<String>] = corpusIndex.neighborhoods.mapValues { Set($0.members) }

        // SB137 Stage A — surface persisted description embeddings so the
        // service's isolate routing step can cosine-match isolate nodes to
        // substantive neighborhoods. Only entries with a non-empty embedding
        // are usable (newly formed clusters get one on the next refresh via
        // SB126 Stage 1's regenerate trigger).
        let persistedDescriptionEmbeddings: [String: [Float]] = corpusIndex.neighborhoods
            .compactMapValues { $0.descriptionEmbedding.isEmpty ? nil : $0.descriptionEmbedding }

        // SB126 Stage 1 — full pre-update snapshot. The trigger rule compares fresh
        // neighborhoods against this snapshot; the upsert step (carry-forward of
        // description/embedding/sampledMemberIDs) reads from the live state, which
        // is the same content until the upsert iteration overwrites it.
        let priorNeighborhoodSnapshot = corpusIndex.neighborhoods

        // Generate new neighborhoods
        neighborhoodCache = service.generateNeighborhoods(
            from: nodes,
            layoutPositions: canvasLayout.positions,
            previousMembers: previousMembers,
            persistedDescriptionEmbeddings: persistedDescriptionEmbeddings
        )

        if let cache = neighborhoodCache {
            let newNeighborhoodCount = cache.neighborhoods.count
            let newLargestMemberCount = cache.neighborhoods.first?.memberCount ?? 0
            print("[Neighborhood] Computed \(newNeighborhoodCount) neighborhoods from \(nodes.count) nodes (largest: \(newLargestMemberCount) members)")

            // Check if neighborhood structure changed significantly
            let countDelta = abs(newNeighborhoodCount - previousNeighborhoodCount)
            let largestCountChange = previousLargestMemberCount > 0 ?
                abs(Double(newLargestMemberCount - previousLargestMemberCount)) / Double(previousLargestMemberCount) : 0

            if countDelta >= 3 || largestCountChange >= 0.3 {
                print("[Neighborhood] Significant structure change detected (count Δ\(countDelta), largest member Δ\(String(format: "%.1f", largestCountChange * 100))%)")
                recomputeAlgorithmicLayout(reason: "neighborhood structure change")
            }

            updateCorpusIndexNeighborhoodLayer(cache: cache)
            updateCorpusIndexTagLayer()
            // SB137 Stage A — rewritten from scratch each refresh; not persisted
            // on the Node itself, so unattached status self-corrects when a
            // node gains routable signal.
            corpusIndex.unattachedNodes = cache.unattachedNodeIDs
            if !cache.unattachedNodeIDs.isEmpty {
                print("[Neighborhood][SB137] \(cache.unattachedNodeIDs.count) node(s) unattached after isolate routing")
            }
            if let diagnostics = cache.routingDiagnostics {
                logRoutingDiagnostics(diagnostics)
                Task {
                    try? await self.service.saveRoutingDiagnostics(diagnostics)
                }
            }
            corpusIndex.updatedAt = Date()
            let indexSnapshot = corpusIndex
            Task {
                try? await self.service.saveCorpusIndex(indexSnapshot)
            }
            regenerateNeighborhoodMetaIfNeeded(priorSnapshot: priorNeighborhoodSnapshot)
            Task {
                if #available(iOS 26.0, *) {
                    await refreshCorpusSummaryIfNeeded()
                }
            }
        } else {
            print("[Neighborhood] No viable neighborhoods (corpus too small or untagged)")
        }
    }

    /// Upserts neighborhood entries into the corpus index. Existing neighborhoods keep their
    /// hue, any FM-generated name, and the SB126 Stage 1 derived fields (`description`,
    /// `descriptionEmbedding`, `sampledMemberIDs`) — those are overwritten only when the
    /// trigger rule in `regenerateNeighborhoodMetaIfNeeded` fires for that neighborhood.
    /// After upsert, prunes any persisted entry whose ID isn't in the fresh Louvain output
    /// (AT21 Cat A2 — garbage collection).
    private func updateCorpusIndexNeighborhoodLayer(cache: NeighborhoodCache) {
        let freshIDs = Set(cache.neighborhoods.map { $0.id })
        let newNeighborhoods = cache.neighborhoods.filter { corpusIndex.neighborhoods[$0.id] == nil }
        let totalNew = newNeighborhoods.count
        var newIndex = 0

        for neighborhood in cache.neighborhoods {
            var tagFrequency: [String: Int] = [:]
            for memberID in neighborhood.memberNodeIDs {
                guard let node = nodes.first(where: { $0.id == memberID }) else { continue }
                for tag in node.tags {
                    tagFrequency[tag, default: 0] += 1
                }
            }
            let dominantTags = tagFrequency
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { $0.key }

            let existing = corpusIndex.neighborhoods[neighborhood.id]
            let hue: Double
            if let existing {
                hue = existing.hue
            } else {
                hue = totalNew > 0 ? (Double(newIndex) / Double(totalNew)) * 360.0 : 0.0
                newIndex += 1
            }

            // Preserve a non-fallback name across refreshes. Stable cluster IDs (Cat A1)
            // mean an FM-generated name attached to this ID is still valid; without this
            // preservation, every refresh would re-trigger the SB126 chain.
            let fallbackName = dominantTags.first ?? neighborhood.id
            let name: String
            if let existingName = existing?.name,
               existingName != neighborhood.id,
               !dominantTags.contains(existingName) {
                name = existingName
            } else {
                name = fallbackName
            }

            // SB126 Stage 1 — carry forward derived fields. The trigger-driven chain
            // overwrites these for the neighborhoods that actually need recomputation;
            // every other neighborhood keeps its persisted description, embedding, and
            // sampled members across refreshes.
            let description = existing?.description ?? ""
            let descriptionEmbedding = existing?.descriptionEmbedding ?? []
            let sampledMemberIDs = existing?.sampledMemberIDs ?? []

            // SB126 Stage 2 — descriptionAttempts carries forward, but a meaningful
            // dominant_tags shift resets it so a previously-stuck cluster gets a
            // fresh attempt budget against the new tag profile.
            let descriptionAttempts: Int = {
                guard let existing else { return 0 }
                let freshSet = Set(dominantTags)
                let priorSet = Set(existing.dominantTags)
                let union = freshSet.union(priorSet)
                if !union.isEmpty {
                    let jaccard = Double(freshSet.intersection(priorSet).count) / Double(union.count)
                    if (1.0 - jaccard) > 0.30 { return 0 }
                }
                return existing.descriptionAttempts
            }()

            corpusIndex.neighborhoods[neighborhood.id] = NeighborhoodIndexEntry(
                id: neighborhood.id,
                name: name,
                memberCount: neighborhood.memberCount,
                dominantTags: dominantTags,
                members: neighborhood.memberNodeIDs.sorted(),
                centroid: IndexPoint(x: Double(neighborhood.centroid.x), y: Double(neighborhood.centroid.y)),
                cohesionScore: 1.0,
                hue: hue,
                description: description,
                descriptionEmbedding: descriptionEmbedding,
                sampledMemberIDs: sampledMemberIDs,
                descriptionAttempts: descriptionAttempts
            )
        }

        // Garbage-collect persisted neighborhoods that didn't survive this Louvain pass.
        let stalePersistedIDs = corpusIndex.neighborhoods.keys.filter { !freshIDs.contains($0) }
        for staleID in stalePersistedIDs {
            corpusIndex.neighborhoods.removeValue(forKey: staleID)
        }
    }

    /// Regenerates the corpus summary via FM if missing or if the node count has drifted by 20+
    /// since the last summary. If the model is unavailable, leaves the existing summary in place.
    private func refreshCorpusSummaryIfNeeded() async {
        let prevCount = corpusIndex.summary?.nodeCount ?? 0
        let needsRefresh = corpusIndex.summary == nil || abs(nodes.count - prevCount) >= 20
        guard needsRefresh else { return }
        guard #available(iOS 26.0, *) else { return }
        let aiSvc = AIService()
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date.distantPast
        let recentCaptureCount = nodes.reduce(into: 0) { acc, node in
            if node.createdAt >= cutoff { acc += 1 }
        }
        guard let result = await aiSvc.generateCorpusSummary(
            index: corpusIndex,
            nodeCount: nodes.count,
            recentCaptureCount: recentCaptureCount
        ) else { return }
        let summary = CorpusSummary(
            nodeCount: nodes.count,
            tagCount: corpusIndex.tags.count,
            neighborhoodCount: corpusIndex.neighborhoods.count,
            dominantThemes: result.dominantThemes,
            recentDominantTags: result.recentDominantTags,
            anomalies: CorpusAnomalies(staleTags: result.staleTags),
            summaryText: result.summaryText,
            generatedAt: Date()
        )
        corpusIndex.summary = summary
        corpusIndex.updatedAt = Date()
        let snapshot = corpusIndex
        try? await service.saveCorpusIndex(snapshot)
    }

    /// SB126 Stage 1 — trigger-driven regeneration of neighborhood description,
    /// description embedding, sampled members, and name. The trigger rule fires
    /// per-neighborhood when ANY of:
    ///   - the cluster is genuinely new (no prior snapshot entry)
    ///   - the persisted description embedding is empty (legacy / never run)
    ///   - dominant_tags Jaccard distance vs. prior > 0.30
    ///   - member_count delta vs. prior ≥ 25%
    /// Otherwise the persisted derived fields carry forward unchanged. Runs as
    /// fire-and-forget so `refreshNeighborhoods` never blocks on FM calls.
    private func regenerateNeighborhoodMetaIfNeeded(priorSnapshot: [String: NeighborhoodIndexEntry]) {
        let candidates: [NeighborhoodIndexEntry] = corpusIndex.neighborhoods.values.compactMap { entry in
            guard !entry.dominantTags.isEmpty else { return nil }
            guard !entry.members.isEmpty else { return nil }

            let prior = priorSnapshot[entry.id]
            guard let prior else { return entry }                  // genuinely new

            // SB126 Stage 2 — empty-embedding retry is gated by descriptionAttempts.
            // Tech/Work-style clusters where Call A keeps returning nil reach the
            // ceiling and stop firing the chain until dominant_tags shifts (which
            // resets attempts to 0 in updateCorpusIndexNeighborhoodLayer).
            if prior.descriptionEmbedding.isEmpty && entry.descriptionAttempts < 3 {
                return entry
            }

            let freshSet = Set(entry.dominantTags)
            let priorSet = Set(prior.dominantTags)
            let union = freshSet.union(priorSet)
            if !union.isEmpty {
                let jaccard = Double(freshSet.intersection(priorSet).count) / Double(union.count)
                if (1.0 - jaccard) > 0.30 { return entry }
            }

            if prior.memberCount > 0 {
                let delta = abs(Double(entry.memberCount - prior.memberCount)) / Double(prior.memberCount)
                if delta >= 0.25 { return entry }
            }
            return nil
        }

        guard !candidates.isEmpty else {
            print("[Neighborhood][SB126] No neighborhoods triggered chain — derived fields carried forward")
            return
        }
        let candidateIDs = candidates.map { $0.id }
        print("[Neighborhood][SB126] Trigger fired for \(candidateIDs.count) of \(corpusIndex.neighborhoods.count) neighborhoods")

        Task {
            guard #available(iOS 26.0, *) else { return }
            let embedder = NLEmbedding.sentenceEmbedding(for: .english)
            if embedder == nil {
                print("[Neighborhood][SB126] NLEmbedding unavailable — descriptions land but embeddings won't")
            }
            let aiSvc = AIService()
            for id in candidateIDs {
                await runNeighborhoodChain(
                    neighborhoodID: id,
                    priorSnapshot: priorSnapshot,
                    embedder: embedder,
                    aiSvc: aiSvc
                )
            }
            print("[Neighborhood][SB126] Chain complete for \(candidateIDs.count) neighborhoods")
        }
    }

    /// Per-neighborhood orchestration: sample → Call A → embed → Call B → persist.
    /// Each successful step writes back to `corpusIndex.neighborhoods` and saves a
    /// snapshot so partial progress survives interruption.
    @available(iOS 26.0, *)
    private func runNeighborhoodChain(
        neighborhoodID: String,
        priorSnapshot: [String: NeighborhoodIndexEntry],
        embedder: NLEmbedding?,
        aiSvc: AIService
    ) async {
        guard var entry = corpusIndex.neighborhoods[neighborhoodID] else { return }
        let prior = priorSnapshot[neighborhoodID]

        // Treat a fallback-shaped prior name (id or dominant-tag) as "no real prior name."
        let priorName: String? = {
            guard let prior else { return nil }
            let n = prior.name
            if n.isEmpty || n == prior.id { return nil }
            if prior.dominantTags.contains(n) { return nil }
            return n
        }()
        let priorDescription: String? = {
            guard let prior, !prior.description.isEmpty else { return nil }
            return prior.description
        }()

        // Sample 8 members deterministically (3 central, 2 recent, 3 seeded random).
        let sampledIDs = sampleMemberIDs(for: entry)
        entry.sampledMemberIDs = sampledIDs

        let excerpts: [(title: String, snippet: String)] = sampledIDs.compactMap { nid in
            guard let node = nodes.first(where: { $0.id == nid }) else { return nil }
            let snippet = String(extractNodeContent(node).prefix(80))
            return (node.title, snippet)
        }
        let coPairs = topCoOccurrencePairs(for: entry.dominantTags, limit: 8)

        guard let description = await aiSvc.characterizeNeighborhood(
            dominantTags: entry.dominantTags,
            topCoOccurrences: coPairs,
            memberExcerpts: excerpts,
            priorName: priorName,
            priorDescription: priorDescription
        ) else {
            // SB126 Stage 2 — increment the per-cluster Call A backoff counter.
            // Once it hits 3 with no embedding, the trigger rule stops firing
            // for this cluster until dominant_tags shifts.
            let newAttempts = (corpusIndex.neighborhoods[neighborhoodID]?.descriptionAttempts ?? 0) + 1
            print("[Neighborhood][SB126] Call A returned nil for \(neighborhoodID) — descriptionAttempts → \(newAttempts)")
            corpusIndex.neighborhoods[neighborhoodID]?.sampledMemberIDs = sampledIDs
            corpusIndex.neighborhoods[neighborhoodID]?.descriptionAttempts = newAttempts
            corpusIndex.updatedAt = Date()
            let snapshot = corpusIndex
            try? await service.saveCorpusIndex(snapshot)
            return
        }
        entry.description = description
        // SB126 Stage 2 — Call A succeeded; reset the backoff counter.
        entry.descriptionAttempts = 0

        if let embedder, let vector = embedder.vector(for: description) {
            entry.descriptionEmbedding = vector.map { Float($0) }
        } else if embedder != nil {
            print("[Neighborhood][SB126] Embedding produced no vector for \(neighborhoodID)")
        }
        // If embedder == nil, leave any prior embedding in place rather than wipe it.

        // Sibling list = current peers (not self), excluding fallback names so the
        // model isn't anchored on dominant-tag stand-ins. Top 20 by memberCount.
        let siblingNames = corpusIndex.neighborhoods.values
            .filter { other in
                guard other.id != neighborhoodID else { return false }
                guard !other.name.isEmpty, other.name != other.id else { return false }
                if other.dominantTags.contains(other.name) { return false }
                return true
            }
            .sorted { $0.memberCount > $1.memberCount }
            .prefix(20)
            .map { $0.name }

        if let name = await aiSvc.nameNeighborhood(
            description: description,
            siblingNames: Array(siblingNames),
            priorName: priorName
        ) {
            entry.name = name
        } else {
            print("[Neighborhood][SB126] Call B returned nil for \(neighborhoodID) — keeping existing name")
        }

        corpusIndex.neighborhoods[neighborhoodID] = entry
        corpusIndex.updatedAt = Date()
        let snapshot = corpusIndex
        try? await service.saveCorpusIndex(snapshot)
    }

    /// SB126 Stage 1 — deterministic 3+3+2 member sampler. 3 most-central
    /// (highest dominant-tag-match count, tie-break oldest first), 2 most-recent
    /// (by createdAt), 3 random from the remainder seeded by the neighborhood ID
    /// so the same cluster draws the same random members run-to-run unless the
    /// trigger rule re-samples. Falls back to "all members" when fewer than 8.
    private func sampleMemberIDs(for entry: NeighborhoodIndexEntry) -> [String] {
        let memberNodes = entry.members.compactMap { id in
            nodes.first(where: { $0.id == id })
        }
        guard !memberNodes.isEmpty else { return [] }
        if memberNodes.count <= 8 {
            return memberNodes.map { $0.id }
        }

        let dominant = Set(entry.dominantTags)

        let scored = memberNodes.map { node -> (id: String, score: Int, ts: Date) in
            let score = node.tags.filter { dominant.contains($0) }.count
            return (node.id, score, node.createdAt)
        }
        let central = scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.ts < $1.ts
        }.prefix(3).map { $0.id }
        let centralSet = Set(central)

        let recent = memberNodes
            .filter { !centralSet.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(2)
            .map { $0.id }
        let chosenSet = centralSet.union(recent)

        var rng = SeededRNG(seed: stableSeed(entry.id))
        let pool = memberNodes.filter { !chosenSet.contains($0.id) }.map { $0.id }
        let random = pool.shuffled(using: &rng).prefix(3)

        return central + recent + Array(random)
    }

    /// SB126 Stage 1 — top tag co-occurrence pairs that involve any of the given
    /// dominant tags. Pulled from the persisted `co_occurrence` data populated
    /// by AT21. Pairs are canonicalized so A↔B and B↔A aren't double-counted.
    private func topCoOccurrencePairs(for dominantTags: [String], limit: Int) -> [(pair: String, count: Int)] {
        var pairs: [(pair: String, count: Int)] = []
        var seen = Set<String>()
        for tag in dominantTags {
            guard let entry = corpusIndex.tags[tag] else { continue }
            for relation in entry.coOccurrence {
                let canonical = [tag, relation.tag].sorted().joined(separator: "\u{1F}")
                if seen.insert(canonical).inserted {
                    let display = canonical.replacingOccurrences(of: "\u{1F}", with: " ↔ ")
                    pairs.append((pair: display, count: Int(relation.score)))
                }
            }
        }
        return pairs.sorted { $0.count > $1.count }.prefix(limit).map { $0 }
    }

    /// SB126 Stage 1 — node content extraction for member excerpts. Mirrors
    /// `AIService.extractContent` but stays on @MainActor so the sampler can
    /// call it without an actor hop.
    private func extractNodeContent(_ node: Node) -> String {
        node.items.compactMap { item -> String? in
            switch item.type {
            case .text:              return item.content
            case .audio, .video:     return item.transcript
            case .image, .document:  return item.description
            case .link:              return [item.title, item.preview].compactMap { $0 }.joined(separator: " ")
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - SB126 Stage 2 — corpus-aware processNode helpers

    /// Cosine similarity for two equal-length [Float] vectors. Returns 0 for
    /// degenerate inputs (mismatched length or zero magnitude) — the caller
    /// treats those as "no signal" and falls back to the lexical path.
    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    /// SB126 Stage 2 — sentence embedding for the node's extracted content.
    /// Returns nil when content is empty or NLEmbedding has no vector
    /// (e.g. very short or all-stopword content). Computed once per node
    /// during the corpus-aware path and persisted to `node.contentEmbedding`.
    private func computeNodeEmbedding(for node: Node) -> [Float]? {
        let raw = extractNodeContent(node)
        guard !raw.isEmpty else { return nil }
        guard let embedder = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        guard let vector = embedder.vector(for: raw) else { return nil }
        return vector.map { Float($0) }
    }

    /// SB126 Stage 2 — top-K neighborhood digests for the FM context window.
    /// Primary signal: cosine similarity between the node embedding and each
    /// neighborhood's `descriptionEmbedding`. Lexical fallback (token overlap
    /// against `dominantTags`) handles two cases: the node has no embedding,
    /// or no neighborhood has a description embedding yet (cold corpus).
    /// Excludes neighborhoods with empty `dominantTags` since they can't help
    /// the FM ground its tag choice.
    private func prefilterNeighborhoods(
        for node: Node,
        nodeEmbedding: [Float]?,
        K: Int = 5
    ) -> [NeighborhoodDigest] {
        let candidates = corpusIndex.neighborhoods.values.filter { !$0.dominantTags.isEmpty }
        guard !candidates.isEmpty else { return [] }

        let usableEmbeddings = candidates.contains { !$0.descriptionEmbedding.isEmpty }
        let scored: [(entry: NeighborhoodIndexEntry, score: Double)]

        if let nodeEmbedding, usableEmbeddings {
            scored = candidates.map { entry in
                let s = entry.descriptionEmbedding.isEmpty
                    ? 0.0
                    : cosine(nodeEmbedding, entry.descriptionEmbedding)
                return (entry, s)
            }
        } else {
            // Lexical fallback — token overlap between node content and the
            // neighborhood's dominant tags. Cheap and good enough as a backup.
            let raw = extractNodeContent(node).lowercased()
            let nodeTokens = Set(raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            scored = candidates.map { entry in
                let overlap = entry.dominantTags.reduce(0) { acc, tag in
                    nodeTokens.contains(tag.lowercased()) ? acc + 1 : acc
                }
                return (entry, Double(overlap))
            }
        }

        return scored
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(K)
            .map { (entry, _) in
                NeighborhoodDigest(
                    id: entry.id,
                    name: entry.name,
                    description: entry.description,
                    dominantTags: entry.dominantTags
                )
            }
    }

    /// SB126 Stage 2 — top-N tags by usage count, each annotated with its top-2
    /// co-occurring tags from the persisted index. Read from the existing tag
    /// layer so this is purely deterministic — no FM, no recompute.
    private func topTagsForProcessNode(N: Int = 12) -> [TagDigest] {
        corpusIndex.tags.values
            .sorted { $0.usageCount > $1.usageCount }
            .prefix(N)
            .map { entry in
                let topCo = entry.coOccurrence
                    .sorted { $0.score > $1.score }
                    .prefix(2)
                    .map { $0.tag }
                return TagDigest(
                    name: entry.name,
                    usageCount: entry.usageCount,
                    topCoOccurring: Array(topCo)
                )
            }
    }

    /// Fire-and-forget FM call to populate cold-start similarity for a newly added tag.
    /// SB126 Stage 3: narrowed to tags with `usage_count < 5` (lift takes over for
    /// established tags during index refresh). Idempotent: skips if `topSimilarTags`
    /// is already populated. Never blocks tag creation.
    private func computeTagSimilarityIfNeeded(for tagName: String) {
        let existingEntry = corpusIndex.tags[tagName]
        if let existingEntry, !existingEntry.topSimilarTags.isEmpty { return }
        let currentUsage = existingEntry?.usageCount ?? nodes.filter { $0.tags.contains(tagName) }.count
        guard currentUsage < 5 else { return }  // lift will populate during next refresh
        let existingNames = tags.map { $0.name }.filter { $0 != tagName }
        guard !existingNames.isEmpty else { return }
        Task {
            guard #available(iOS 26.0, *) else { return }
            let aiSvc = AIService()
            guard let relations = await aiSvc.computeTagSimilarity(newTag: tagName, existingTags: existingNames) else { return }
            let similarities: [TagSimilarity] = relations.map {
                TagSimilarity(tagID: $0.tag, lift: $0.score, similarityKind: nil)
            }
            if corpusIndex.tags[tagName] == nil {
                let usageCount = nodes.filter { $0.tags.contains(tagName) }.count
                let userSourced = nodes.contains { $0.tagSources[tagName]?.source == .user }
                corpusIndex.tags[tagName] = TagIndexEntry(
                    name: tagName,
                    usageCount: usageCount,
                    origin: userSourced ? .user : .model,
                    coOccurrence: [],
                    semanticSimilarity: [],
                    similarityKind: nil,
                    topSimilarTags: similarities
                )
            } else {
                corpusIndex.tags[tagName]?.topSimilarTags = similarities
            }
            corpusIndex.updatedAt = Date()
            let snapshot = corpusIndex
            try? await service.saveCorpusIndex(snapshot)
        }
    }

    /// Full recompute of the tag layer of the corpus index from current nodes (AT21 Cat B).
    /// Always runs on a full corpus pass — incremental maintenance is a known source of drift,
    /// and the corpus is small enough that recompute is cheap.
    ///
    /// - `usage_count`: number of nodes whose `tags` array contains the tag (Cat B1).
    /// - `origin`: `.user` if any node carries this tag with `.user` provenance in
    ///   `tagSources`, else `.model` (Cat B2).
    /// - `co_occurrence`: top 10 tags by joint occurrence count, sorted desc, stored as
    ///   `[TagRelation]` where `score` carries the integer count cast to Double (Cat B3).
    /// - `top_similar_tags` (SB126 Stage 3): deterministic lift-based similarity for tags
    ///   with `usage_count >= 5`. Cold-start tags carry forward FM-derived entries.
    ///
    /// `semanticSimilarity` is preserved across rebuilds — legacy field from pre-Stage-3.
    /// Stale entries (tags no longer in the live vocabulary) are dropped, mirroring the
    /// neighborhood layer's GC.
    private func updateCorpusIndexTagLayer() {
        // usage_count: corpus-wide count per tag name.
        var usageCount: [String: Int] = [:]
        for tag in tags { usageCount[tag.name] = 0 }
        for node in nodes {
            for tagName in node.tags {
                usageCount[tagName, default: 0] += 1
            }
        }

        // origin: any node carrying this tag with .user provenance flips it to .user.
        var hasUserOrigin = Set<String>()
        for node in nodes {
            for (tagName, origin) in node.tagSources where origin.source == .user {
                hasUserOrigin.insert(tagName)
            }
        }

        // co_occurrence: per-tag joint counts.
        var coOccurrence: [String: [String: Int]] = [:]
        for node in nodes {
            let nodeTags = node.tags
            guard nodeTags.count >= 2 else { continue }
            for i in 0..<nodeTags.count {
                for j in 0..<nodeTags.count where i != j {
                    coOccurrence[nodeTags[i], default: [:]][nodeTags[j], default: 0] += 1
                }
            }
        }

        // SB126 Stage 3 — N for the lift formula: nodes carrying at least one tag.
        let totalTaggedNodes = nodes.reduce(into: 0) { acc, node in
            if !node.tags.isEmpty { acc += 1 }
        }

        // Rebuild in place, preserving semanticSimilarity (legacy) and topSimilarTags
        // for cold-start tags (usage_count < 5). Lift-derived entries are recomputed
        // every refresh for established tags.
        for tag in tags {
            let existingSimilarity = corpusIndex.tags[tag.name]?.semanticSimilarity ?? []
            let existingTopSimilar = corpusIndex.tags[tag.name]?.topSimilarTags ?? []
            let count = usageCount[tag.name] ?? 0
            let origin: TagSource = hasUserOrigin.contains(tag.name) ? .user : .model

            let topCo: [TagRelation] = (coOccurrence[tag.name] ?? [:])
                .sorted { $0.value > $1.value }
                .prefix(10)
                .map { TagRelation(tag: $0.key, score: Double($0.value)) }

            let topSimilar: [TagSimilarity]
            if count >= 5 {
                topSimilar = computeLiftSimilarities(
                    for: tag.name,
                    usageCount: usageCount,
                    coOccurrence: coOccurrence,
                    totalTaggedNodes: totalTaggedNodes
                )
            } else {
                // Cold-start: preserve FM-derived entries until usage crosses 5.
                topSimilar = existingTopSimilar
            }

            corpusIndex.tags[tag.name] = TagIndexEntry(
                name: tag.name,
                usageCount: count,
                origin: origin,
                coOccurrence: topCo,
                semanticSimilarity: existingSimilarity,
                similarityKind: corpusIndex.tags[tag.name]?.similarityKind,
                topSimilarTags: topSimilar
            )
        }

        // Drop stale entries for tags no longer in the live vocabulary.
        let validNames = Set(tags.map { $0.name })
        for staleName in corpusIndex.tags.keys where !validNames.contains(staleName) {
            corpusIndex.tags.removeValue(forKey: staleName)
        }
    }

    /// SB126 Stage 3 — deterministic lift-based similarity for one tag.
    /// `lift(A, B) = (n_AB * N) / (n_A * n_B)`.
    /// Floors: lift > 1.5 (weak signal), n_AB >= 3 (spurious pairs from rare tags).
    /// Cap: top 5 by lift, descending. Caller guards with `n_A >= 5`.
    private func computeLiftSimilarities(
        for tagName: String,
        usageCount: [String: Int],
        coOccurrence: [String: [String: Int]],
        totalTaggedNodes: Int
    ) -> [TagSimilarity] {
        guard totalTaggedNodes > 0 else { return [] }
        let nA = usageCount[tagName] ?? 0
        guard nA > 0 else { return [] }
        let pairs = coOccurrence[tagName] ?? [:]
        var entries: [TagSimilarity] = []
        for (otherName, nAB) in pairs {
            guard nAB >= 3 else { continue }
            let nB = usageCount[otherName] ?? 0
            guard nB > 0 else { continue }
            let lift = (Double(nAB) * Double(totalTaggedNodes)) / (Double(nA) * Double(nB))
            guard lift > 1.5 else { continue }
            entries.append(TagSimilarity(tagID: otherName, lift: lift, similarityKind: nil))
        }
        entries.sort { $0.lift > $1.lift }
        return Array(entries.prefix(5))
    }

    /// Force regeneration of neighborhoods (ignores cache validity).
    func invalidateNeighborhoods() {
        neighborhoodCache = nil
        refreshNeighborhoods()
    }

    /// SB137 Stage A — emit a compact distribution summary for the routing pass
    /// so the cosine threshold can be tuned from console output without needing
    /// the sidecar JSON. Logs only the percentile cuts and totals, not every
    /// per-node sample (those go to `corpus_routing_diagnostics.json`).
    private func logRoutingDiagnostics(_ d: RoutingDiagnostics) {
        let isolateScores = d.isolateBestCosines.map { $0.bestCosine }
        let inClusterScores = d.inClusterCosines.map { $0.cosine }
        let routedAboveThreshold = isolateScores.filter { $0 >= d.thresholdUsed }.count

        print("""
        [Routing][SB137] threshold=\(String(format: "%.3f", d.thresholdUsed)) \
        isolates=\(d.totalIsolates) (with_emb=\(d.isolatesWithEmbedding), no_emb=\(d.isolatesNoEmbedding)) \
        routable_targets=\(d.routableTargetCount) routed=\(routedAboveThreshold)
        """)
        print("[Routing][SB137] isolate_cosines  \(percentileSummary(isolateScores))")
        print("[Routing][SB137] in_cluster_cos   \(percentileSummary(inClusterScores))")
    }

    private func percentileSummary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n=0" }
        let sorted = values.sorted()
        func pct(_ p: Double) -> Double {
            let idx = Int((p * Double(sorted.count - 1)).rounded())
            return sorted[max(0, min(sorted.count - 1, idx))]
        }
        let f = { (v: Double) in String(format: "%.3f", v) }
        return "n=\(sorted.count) min=\(f(sorted.first!)) p25=\(f(pct(0.25))) p50=\(f(pct(0.5))) p75=\(f(pct(0.75))) max=\(f(sorted.last!))"
    }

    // MARK: - Algorithmic layout

    /// Recompute layout using LayoutService and update canvasLayout.
    /// Converts from SpriteKit (y-up) to SwiftUI (y-down) convention.
    private func recomputeAlgorithmicLayout(reason: String) {
        print("[Layout] Computing algorithmic layout for \(nodes.count) nodes across \(neighborhoodCache?.neighborhoods.count ?? 0) neighborhoods — reason: \(reason)")

        // Convert existing layout to SpriteKit convention (y-up)
        let existingPositionsSK = canvasLayout.positions.mapValues { pos in
            CGPoint(x: pos.x, y: -pos.y)
        }

        // Compute new layout (positions + radii)
        let layoutResult = layoutService.computeAlgorithmicLayout(
            nodes: nodes,
            neighborhoodCache: neighborhoodCache,
            existingPositions: existingPositionsSK
        )

        // Store radii (not persisted; recomputed each pass)
        nodeRadii = layoutResult.radii

        // Convert back to SwiftUI convention (y-down) and update canvasLayout
        var newLayout = canvasLayout
        for (nodeID, posSK) in layoutResult.positions {
            newLayout.positions[nodeID] = CanvasPosition(x: posSK.x, y: -posSK.y)
        }
        newLayout.updatedAt = Date()

        // Persist to disk
        Task {
            do {
                try await service.saveCanvasLayout(newLayout)
                canvasLayout = newLayout
                canvasNeedsSync = UUID()
                print("[Layout] Animating \(layoutResult.positions.count) node positions")
            } catch {
                print("[Layout] ERROR saving layout: \(error)")
            }
        }
    }

    // MARK: - File resolution

    func itemFileURL(for item: NodeItem, nodeID: String) async -> URL? {
        guard let file = item.file else { return nil }
        return await service.resolveItemPath(nodeID: nodeID, relativePath: file)
    }

    // MARK: - Semantic placement (Task 4)

    /// Computes tag-overlap-aware position for a new node.
    /// - First import: organic scatter
    /// - Subsequent: near existing nodes with shared tags
    /// - No overlap: unoccupied region
    private func semanticPosition(for newNode: Node, existingLayout: CanvasLayout, index: Int, total: Int) -> CanvasPosition {
        let existingPositions = existingLayout.positions

        // First import (empty corpus) — relaxed organic scatter
        guard !existingPositions.isEmpty else {
            let jitterRadius = 200.0
            let jitterAngle = Double.random(in: 0...(2 * .pi))
            let jitterDist = Double.random(in: 0...jitterRadius)
            return CanvasPosition(
                x: cos(jitterAngle) * jitterDist,
                y: sin(jitterAngle) * jitterDist
            )
        }

        // If node has tags, find existing nodes with overlap
        if !newNode.tags.isEmpty {
            let nodesWithOverlap = nodes.filter { existingNode in
                existingPositions[existingNode.id] != nil &&
                !Set(existingNode.tags).isDisjoint(with: newNode.tags)
            }

            if !nodesWithOverlap.isEmpty {
                // Place near centroid of overlapping nodes
                let positions = nodesWithOverlap.compactMap { existingPositions[$0.id] }
                let cx = positions.map { $0.x }.reduce(0, +) / Double(positions.count)
                let cy = positions.map { $0.y }.reduce(0, +) / Double(positions.count)

                let offsetRadius = Double.random(in: 80...120)
                let offsetAngle = Double.random(in: 0...(2 * .pi))
                return CanvasPosition(
                    x: cx + cos(offsetAngle) * offsetRadius,
                    y: cy + sin(offsetAngle) * offsetRadius
                )
            }
        }

        // No tag overlap or no tags yet — find unoccupied region
        // Simple strategy: sample angles and pick one farthest from existing nodes
        var bestPosition = CanvasPosition(x: 0, y: 0)
        var maxMinDistance = 0.0

        for _ in 0..<8 {
            let angle = Double.random(in: 0...(2 * .pi))
            let radius = Double.random(in: 300...500)
            let candidate = CanvasPosition(x: cos(angle) * radius, y: sin(angle) * radius)

            // Find min distance to any existing node
            let minDist = existingPositions.values.map { pos in
                let dx = pos.x - candidate.x
                let dy = pos.y - candidate.y
                return sqrt(dx*dx + dy*dy)
            }.min() ?? .infinity

            if minDist > maxMinDistance {
                maxMinDistance = minDist
                bestPosition = candidate
            }
        }

        return bestPosition
    }
}
