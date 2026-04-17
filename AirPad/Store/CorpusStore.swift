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

    private let service = iCloudDriveService()

    // MARK: - Lifecycle

    func setup() async {
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
    func batchImportText(_ text: String) async {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let parsedNodes = BatchParser.parse(text: text, importTimestamp: timestamp)

        print("[Batch] Input text length: \(text.count) chars")
        print("[Batch] BatchParser produced \(parsedNodes.count) node(s)")
        guard !parsedNodes.isEmpty else {
            print("[Batch] Nothing to import — returning early")
            return
        }

        let total = parsedNodes.count
        importBatchProgress = (0, total)
        print("[Batch] Starting import of \(total) node(s). iCloudUnavailable=\(iCloudUnavailable)")

        var successCount = 0
        var newLayout = canvasLayout
        for (index, node) in parsedNodes.enumerated() {
            let angle = Double(index) / Double(total) * 2 * .pi * 2.5
            let radius = 80.0 + Double(index) * 8.0
            let pos = CanvasPosition(x: cos(angle) * radius, y: sin(angle) * radius)
            newLayout.positions[node.id] = pos

            do {
                try await service.saveNode(node)
                nodes.insert(node, at: 0)
                successCount += 1
                print("[Batch] [\(index + 1)/\(total)] Saved node \(node.id) — store.nodes.count now \(nodes.count)")
            } catch {
                print("[Batch] [\(index + 1)/\(total)] SAVE ERROR for node \(node.id): \(error)")
            }
            importBatchProgress = (index + 1, total)
        }

        print("[Batch] Save loop done. \(successCount)/\(total) nodes saved. Saving layout…")
        newLayout.updatedAt = Date()
        do {
            try await service.saveCanvasLayout(newLayout)
            canvasLayout = newLayout
            print("[Batch] Layout saved OK")
        } catch {
            print("[Batch] Layout save ERROR: \(error)")
        }

        importBatchProgress = nil
        print("[Batch] Progress cleared. Final store.nodes.count = \(nodes.count)")

        if nodes.count >= 10 {
            Task { await triggerThreadAnalysis() }
        }

        // AI title/summary in background — suppress tag sheet so new tags are auto-created silently
        let savedIDs = parsedNodes.map { $0.id }
        print("[Batch] Kicking off AI for \(savedIDs.count) node(s) with suppressTagSheet=true")
        Task {
            for id in savedIDs {
                print("[Batch][AI] Processing node \(id)")
                await processNodeWithAI(nodeID: id, suppressTagSheet: true)
            }
            print("[Batch][AI] All AI processing complete")
        }
    }

    // MARK: - File resolution

    func itemFileURL(for item: NodeItem, nodeID: String) async -> URL? {
        guard let file = item.file else { return nil }
        return await service.resolveItemPath(nodeID: nodeID, relativePath: file)
    }
}
