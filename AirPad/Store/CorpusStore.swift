import Foundation
import Observation
import UIKit

/// Central state store for the AirPad corpus.
/// @MainActor ensures all mutations happen on the main thread, keeping SwiftUI observation correct.
@Observable
@MainActor
final class CorpusStore {

    var nodes: [Node] = []
    var tags: [Tag] = []
    var canvasLayout: CanvasLayout = CanvasLayout(version: 1, updatedAt: Date(), positions: [:])

    /// Cached Über-node clusters (Tier 1: tag-only). Regenerates on invalidation.
    var uberNodeCache: UberNodeCache? = nil

    /// Cached neighborhoods (Louvain communities over tag co-occurrence). Regenerates on invalidation.
    var neighborhoodCache: NeighborhoodCache? = nil

    /// Reference to CanvasState for drill-down filtering.
    var canvasState: CanvasState? = nil

    /// True when iCloud is unavailable and the app is writing to local storage instead.
    var iCloudUnavailable = false

    /// Set when AI processing suggests tags not yet in the vocabulary.
    /// CanvasView observes this and presents TagCreationSheet.
    var pendingTagSuggestions: TagSuggestionContext? = nil

    /// Active filter + view mode. Persisted to UserDefaults.
    var filterState: FilterState = FilterState.load() {
        didSet { filterState.save() }
    }

    /// Thread suggestions waiting to be shown to the user (one at a time in UI).
    var pendingThreads: [ThreadSuggestion] = []

    /// True while NodeDetailView is on screen. ContentView reads this to hide the toggle pill.
    var isInDetailView = false

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

    private var dismissedThreadDescriptions: Set<String> = []

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
            tags = loadedTags
        } catch {
            print("[CorpusStore] Load error: \(error)")
        }
        // Generate initial Über-node clusters
        refreshUberNodeClusters()
        // Generate initial neighborhoods
        refreshNeighborhoods()
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
        // Refresh neighborhoods
        refreshNeighborhoods()
        // Trigger corpus-wide thread analysis once we have enough nodes
        if nodes.count >= 10 {
            Task { await triggerThreadAnalysis() }
        }
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

    // MARK: - Append items to existing nodes

    func appendItemToNode(nodeID: String, item: NodeItem) async {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[idx]
        updated.items.append(item)
        updated.updatedAt = Date()
        await updateNode(updated)
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
    func applyTags(_ tagNames: [String], toNodeID nodeID: String) async {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var updated = nodes[idx]
        for name in tagNames where !updated.tags.contains(name) {
            updated.tags.append(name)
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

    // MARK: - AI processing

    /// Runs on-device AI processing on a node after capture (non-blocking).
    /// Pass `suppressTagSheet: true` during batch import to auto-create new tags silently
    /// instead of presenting TagCreationSheet to the user.
    func processNodeWithAI(nodeID: String, suppressTagSheet: Bool = false) async {
        print("[AI] processNodeWithAI called for \(nodeID) suppressTagSheet=\(suppressTagSheet)")
        guard #available(iOS 26.0, *) else {
            print("[AI] iOS 26.0 unavailable — skipping AI for \(nodeID)")
            return
        }
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return }

        let currentTags = tags
        let aiSvc = AIService()
        guard let result = await aiSvc.processNode(node, tagVocabulary: currentTags) else {
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
        updated.needsAIProcessing = false
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
                await applyTags(newTagNames, toNodeID: nodeID)
                print("[AI] Silent tag apply for \(nodeID): \(newTagNames)")
            } else {
                pendingTagSuggestions = TagSuggestionContext(
                    nodeID: nodeID,
                    newTagNames: newTagNames,
                    existingTagNames: existingTagNames
                )
            }
        }
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

    /// Trigger corpus-wide thread analysis. Runs in background; never blocks node save.
    private func triggerThreadAnalysis() async {
        guard #available(iOS 26.0, *) else { return }
        let currentNodes = nodes
        let currentTags = tags
        let dismissed = dismissedThreadDescriptions
        let existingDescriptions = Set(pendingThreads.map { $0.description })

        let threadSvc = ThreadService()
        let suggestions = await threadSvc.analyzeCorpus(nodes: currentNodes, tags: currentTags)

        let newSuggestions = suggestions.filter { s in
            !dismissed.contains(s.description) && !existingDescriptions.contains(s.description)
        }
        if !newSuggestions.isEmpty {
            pendingThreads.append(contentsOf: newSuggestions)
        }
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
    }

    /// Dismiss a thread suggestion — never show it again.
    func dismissThread(_ suggestion: ThreadSuggestion) {
        dismissedThreadDescriptions.insert(suggestion.description)
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

        if nodes.count >= 10 {
            Task { await triggerThreadAnalysis() }
        }

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
            print("[Batch][AI] All done")
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
        }
    }

    /// Flush any pending debounced refresh and run immediately (Task 3).
    private func flushClusterRefresh() async {
        clusterRefreshTask?.cancel()
        clusterRefreshTask = nil
        refreshUberNodeClusters()
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
            return  // Cache is still fresh
        }

        // Generate new neighborhoods
        neighborhoodCache = service.generateNeighborhoods(from: nodes, layoutPositions: canvasLayout.positions)

        if let cache = neighborhoodCache {
            let largestCount = cache.neighborhoods.first?.memberCount ?? 0
            print("[Neighborhood] Computed \(cache.neighborhoods.count) neighborhoods from \(nodes.count) nodes (largest: \(largestCount) members)")
        } else {
            print("[Neighborhood] No viable neighborhoods (corpus too small or untagged)")
        }
    }

    /// Force regeneration of neighborhoods (ignores cache validity).
    func invalidateNeighborhoods() {
        neighborhoodCache = nil
        refreshNeighborhoods()
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
