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

    private var dismissedThreadDescriptions: Set<String> = []

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

        // INSTRUMENTATION: Set up gate diagnostic log
        let logDateFormatter = DateFormatter()
        logDateFormatter.dateFormat = "yyyyMMdd"
        let logDate = logDateFormatter.string(from: Date())
        let logPath = NSHomeDirectory() + "/Documents/AirPad/Logs/gate_diagnostic_\(logDate).log"
        var logEntries: [String] = []

        // Phase 0a — character threshold + heuristic fragment filter (synchronous)
        // INSTRUMENTED VERSION: track every entry through all layers
        let rawBlocks = text
            .components(separatedBy: "\n\n")
            .map { block -> String in
                block
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^[\\-•\\*]\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        var candidateTexts: [String] = []
        var heuristicFragments: [String] = []

        for block in rawBlocks {
            let inputTruncated = String(block.prefix(150))
            let inputLength = block.count

            // Layer 1: Character threshold
            let layer1Pass = inputLength >= BatchParser.minChars
            let layer1Result = layer1Pass ? "pass" : "fail_too_short"

            if !layer1Pass {
                // Silently dropped by char threshold
                let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_1_result\":\"\(layer1Result)\",\"layer_2_result\":\"skipped\",\"layer_3_invoked\":false,\"layer_3_result\":null,\"final_decision\":\"reject\",\"final_state\":\"silently_dropped\"}"
                logEntries.append(logLine)
                continue
            }

            // Layer 2: Heuristic fragment filter
            let layer2Pass = !BatchParser.isFragment(block)
            let layer2Result = layer2Pass ? "pass" : "fail_fragment"

            if layer2Pass {
                candidateTexts.append(block)
                // Don't log yet - Layer 3 decision pending
            } else {
                heuristicFragments.append(block)
                let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_1_result\":\"\(layer1Result)\",\"layer_2_result\":\"\(layer2Result)\",\"layer_3_invoked\":false,\"layer_3_result\":null,\"final_decision\":\"reject\",\"final_state\":\"review_queue_heuristic\"}"
                logEntries.append(logLine)
            }
        }

        print("[Batch] Phase 0a: \(candidateTexts.count) candidates, \(heuristicFragments.count) heuristic fragments")

        if !heuristicFragments.isEmpty {
            let rejected = heuristicFragments.map {
                RejectedBlock(id: UUID().uuidString, text: $0, reason: .heuristic,
                              importTimestamp: timestamp, rejectedAt: Date())
            }
            reviewQueue.append(contentsOf: rejected)
            print("[Batch] Phase 0a: added \(rejected.count) heuristic rejections to reviewQueue")
        }

        guard !candidateTexts.isEmpty else {
            // INSTRUMENTATION: Write log even on early return
            do {
                let logContent = logEntries.joined(separator: "\n")
                try logContent.write(toFile: logPath, atomically: true, encoding: .utf8)
                print("[Batch][DIAGNOSTIC] Gate log written to: \(logPath)")
                print("[Batch][DIAGNOSTIC] Total entries logged: \(logEntries.count)")
            } catch {
                print("[Batch][DIAGNOSTIC] Failed to write log: \(error)")
            }
            print("[Batch] Nothing passed heuristic gate — returning early")
            return
        }

        // Phase 0b — Foundation Model coherence check (concurrent, iOS 26.0+ only)
        var coherentTexts: [String] = candidateTexts
        var incoherentTexts: [String] = []

        if #available(iOS 26.0, *) {
            let aiSvc = AIService()
            importBatchProgress = (0, candidateTexts.count)
            print("[Batch] Phase 0b: running coherence checks on \(candidateTexts.count) candidates")
            var coherent: [String] = []
            var incoherent: [String] = []
            // INSTRUMENTATION: Track Layer 3 results for logging
            var layer3Results: [String: Bool?] = [:]
            await withTaskGroup(of: (String, Bool?).self) { group in
                for candidate in candidateTexts {
                    group.addTask { await (candidate, aiSvc.checkCoherence(candidate)) }
                }
                var checked = 0
                for await (candidateText, result) in group {
                    checked += 1
                    importBatchProgress = (checked, candidateTexts.count)
                    layer3Results[candidateText] = result
                    if result == false {
                        incoherent.append(candidateText)
                        print("[Batch] Phase 0b: coherence FAIL (\(candidateText.prefix(40))…)")
                    } else {
                        coherent.append(candidateText)
                    }
                }
            }
            coherentTexts = coherent
            incoherentTexts = incoherent

            // INSTRUMENTATION: Log all candidates with Layer 3 results
            for candidate in candidateTexts {
                let inputTruncated = String(candidate.prefix(150))
                let inputLength = candidate.count
                let layer3Result = layer3Results[candidate]
                let layer3ResultStr: String
                let finalDecision: String
                let finalState: String

                if let result = layer3Result {
                    layer3ResultStr = result ? "pass_coherent" : "fail_incoherent"
                    finalDecision = result ? "commit" : "reject"
                    finalState = result ? "in_corpus" : "review_queue_coherence"
                } else {
                    // nil means model unavailable - treated as pass
                    layer3ResultStr = "null_model_unavailable"
                    finalDecision = "commit"
                    finalState = "in_corpus"
                }

                let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_1_result\":\"pass\",\"layer_2_result\":\"pass\",\"layer_3_invoked\":true,\"layer_3_result\":\"\(layer3ResultStr)\",\"final_decision\":\"\(finalDecision)\",\"final_state\":\"\(finalState)\"}"
                logEntries.append(logLine)
            }
        } else {
            // INSTRUMENTATION: iOS < 26.0 - Layer 3 not available
            for candidate in candidateTexts {
                let inputTruncated = String(candidate.prefix(150))
                let inputLength = candidate.count
                let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_1_result\":\"pass\",\"layer_2_result\":\"pass\",\"layer_3_invoked\":false,\"layer_3_result\":\"skipped_ios_version\",\"final_decision\":\"commit\",\"final_state\":\"in_corpus\"}"
                logEntries.append(logLine)
            }
        }

        if !incoherentTexts.isEmpty {
            let rejected = incoherentTexts.map {
                RejectedBlock(id: UUID().uuidString, text: $0, reason: .coherence,
                              importTimestamp: timestamp, rejectedAt: Date())
            }
            reviewQueue.append(contentsOf: rejected)
            print("[Batch] Phase 0b: added \(rejected.count) coherence rejections to reviewQueue")
        }

        let parsedNodes = BatchParser.makeNodes(texts: coherentTexts, importTimestamp: timestamp)
        print("[Batch] Phase 0 done: \(parsedNodes.count) nodes to import")

        // INSTRUMENTATION: Write log even on early return
        if parsedNodes.isEmpty {
            do {
                let logContent = logEntries.joined(separator: "\n")
                try logContent.write(toFile: logPath, atomically: true, encoding: .utf8)
                print("[Batch][DIAGNOSTIC] Gate log written to: \(logPath)")
                print("[Batch][DIAGNOSTIC] Total entries logged: \(logEntries.count)")
            } catch {
                print("[Batch][DIAGNOSTIC] Failed to write log: \(error)")
            }
            print("[Batch] Nothing passed coherence gate — returning early")
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
            let angle = Double(index) / Double(total) * 2 * .pi * 2.5
            let radius = 80.0 + Double(index) * 8.0
            newLayout.positions[node.id] = CanvasPosition(x: cos(angle) * radius, y: sin(angle) * radius)

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
        print("[Batch] Phase 3 done: store.nodes \(beforeCount) → \(nodes.count)")

        importBatchProgress = nil

        // Explicit sync token — fires onChange(of: store.canvasNeedsSync) in CanvasView
        // as belt-and-suspenders in case the onChange(of: store.nodes) chain was coalesced
        // or stale during the import.
        canvasNeedsSync = UUID()
        print("[Batch] canvasNeedsSync fired")

        if nodes.count >= 10 {
            Task { await triggerThreadAnalysis() }
        }

        // INSTRUMENTATION: Write diagnostic log
        do {
            let logContent = logEntries.joined(separator: "\n")
            try logContent.write(toFile: logPath, atomically: true, encoding: .utf8)
            print("[Batch][DIAGNOSTIC] Gate log written to: \(logPath)")
            print("[Batch][DIAGNOSTIC] Total entries logged: \(logEntries.count)")
        } catch {
            print("[Batch][DIAGNOSTIC] Failed to write log: \(error)")
        }

        // Phase 4 — AI title/summary in background; suppress tag sheet for batch
        let savedIDs = savedNodes.map { $0.id }
        print("[Batch] Kicking off AI for \(savedIDs.count) nodes (suppressTagSheet=true)")
        Task {
            for id in savedIDs {
                print("[Batch][AI] Processing \(id)")
                await processNodeWithAI(nodeID: id, suppressTagSheet: true)
            }
            print("[Batch][AI] All done")
        }
    }

    // MARK: - Gate diagnostic helpers

    /// Escapes a string for JSON embedding (replaces quotes, backslashes, newlines)
    private func escapeJSON(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
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
        // Check if cache exists and is still valid
        if let cache = uberNodeCache,
           !cache.shouldInvalidate(currentNodeCount: nodes.count) {
            return  // Cache is still fresh
        }

        // Generate new clusters
        let service = UberNodeService()
        uberNodeCache = service.generateClusters(from: nodes)

        if let cache = uberNodeCache {
            print("[UberNode] Generated \(cache.clusters.count) clusters from \(nodes.count) nodes")
        } else {
            print("[UberNode] No viable clusters (need 2+ nodes per tag)")
        }
    }

    /// Force regeneration of Über-node clusters (ignores cache validity).
    func invalidateUberNodeClusters() {
        uberNodeCache = nil
        refreshUberNodeClusters()
    }

    // MARK: - File resolution

    func itemFileURL(for item: NodeItem, nodeID: String) async -> URL? {
        guard let file = item.file else { return nil }
        return await service.resolveItemPath(nodeID: nodeID, relativePath: file)
    }
}
