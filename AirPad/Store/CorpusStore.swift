import Foundation
import Observation

// MARK: - Filter state

enum ViewMode: String, CaseIterable {
    case graph, list
}

enum SortOrder: String, CaseIterable {
    case recency, thematic
}

enum MediaTypeFilter: String, CaseIterable {
    case all, voice, photo, video, text, link, document
}

enum ThreadFilter: String, CaseIterable {
    case all, threadsOnly, pulledOnly
}

struct FilterState {
    var sortOrder: SortOrder = .recency
    var mediaType: MediaTypeFilter = .all
    var tagName: String? = nil          // nil = all tags
    var threadFilter: ThreadFilter = .all

    var isActive: Bool {
        sortOrder != .recency || mediaType != .all || tagName != nil || threadFilter != .all
    }
}

// MARK: - Store

/// Central state store for the AirPad corpus.
/// @MainActor ensures all mutations happen on the main thread, keeping SwiftUI observation correct.
@Observable
@MainActor
final class CorpusStore {

    var nodes: [Node] = []
    var tags: [Tag] = []
    var canvasLayout: CanvasLayout = CanvasLayout(version: 1, updatedAt: Date(), positions: [:])

    // MARK: - View state (persisted)

    var viewMode: ViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }

    var filterState: FilterState = FilterState() {
        didSet { persistFilterState() }
    }

    /// Nodes after applying the active filter state.
    var filteredNodes: [Node] {
        var result = nodes

        // Tag filter
        if let tag = filterState.tagName {
            result = result.filter { $0.tags.contains(tag) }
        }

        // Media type filter
        switch filterState.mediaType {
        case .all:      break
        case .voice:    result = result.filter { $0.items.contains(where: { $0.type == .audio }) }
        case .photo:    result = result.filter { $0.items.contains(where: { $0.type == .image }) }
        case .video:    result = result.filter { $0.items.contains(where: { $0.type == .video }) }
        case .text:     result = result.filter { $0.items.contains(where: { $0.type == .text }) }
        case .link:     result = result.filter { $0.items.contains(where: { $0.type == .link }) }
        case .document: result = result.filter { $0.items.contains(where: { $0.type == .document }) }
        }

        // Thread filter
        switch filterState.threadFilter {
        case .all:         break
        case .threadsOnly: result = result.filter { !$0.threads.isEmpty || $0.isMeta }
        case .pulledOnly:  result = result.filter { $0.isMeta }
        }

        // Sort order
        switch filterState.sortOrder {
        case .recency:
            result.sort { $0.createdAt > $1.createdAt }
        case .thematic:
            result.sort { lhs, rhs in
                let l = lhs.tags.first ?? ""
                let r = rhs.tags.first ?? ""
                if l == r { return lhs.createdAt > rhs.createdAt }
                return l < r
            }
        }

        return result
    }

    /// True when iCloud is unavailable and the app is writing to local storage instead.
    var iCloudUnavailable = false

    /// Set when AI processing suggests tags not yet in the vocabulary.
    /// CanvasView observes this and presents TagCreationSheet.
    var pendingTagSuggestions: TagSuggestionContext? = nil

    private let service = iCloudDriveService()

    // MARK: - Init (restores persisted view/filter state)

    init() {
        let stored = UserDefaults.standard.string(forKey: "viewMode") ?? ""
        viewMode = ViewMode(rawValue: stored) ?? .graph
        filterState = FilterState(
            sortOrder:    SortOrder(rawValue: UserDefaults.standard.string(forKey: "filter_sortOrder") ?? "") ?? .recency,
            mediaType:    MediaTypeFilter(rawValue: UserDefaults.standard.string(forKey: "filter_mediaType") ?? "") ?? .all,
            tagName:      UserDefaults.standard.string(forKey: "filter_tagName"),
            threadFilter: ThreadFilter(rawValue: UserDefaults.standard.string(forKey: "filter_threadFilter") ?? "") ?? .all
        )
    }

    private func persistFilterState() {
        UserDefaults.standard.set(filterState.sortOrder.rawValue,    forKey: "filter_sortOrder")
        UserDefaults.standard.set(filterState.mediaType.rawValue,    forKey: "filter_mediaType")
        UserDefaults.standard.set(filterState.tagName,               forKey: "filter_tagName")
        UserDefaults.standard.set(filterState.threadFilter.rawValue, forKey: "filter_threadFilter")
    }

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

        // Write image to temp file for copyItem
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
                domainConfirmed: false
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

    /// Runs Foundation Model processing on a node after capture (non-blocking).
    /// Updates title, summary, mood, domain, and applies / surfaces new tags.
    func processNodeWithAI(nodeID: String) async {
        guard #available(iOS 18.1, *) else { return }
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return }

        let currentTags = tags
        let aiSvc = AIService()
        guard let result = await aiSvc.processNode(node, tagVocabulary: currentTags) else { return }

        // Node may have changed while AI was running — refetch index
        guard var updated = nodes.first(where: { $0.id == nodeID }) else { return }

        updated.title   = result.title
        updated.summary = result.summary
        updated.mood    = result.mood
        if let domain = result.domain {
            updated.domain          = domain
            updated.domainConfirmed = false
        }

        // Sort suggested tags into existing vs new
        var existingTagNames: [String] = []
        var newTagNames: [String] = []
        for name in result.tags {
            if currentTags.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                existingTagNames.append(name)
            } else {
                newTagNames.append(name)
            }
        }
        updated.tags = existingTagNames
        await updateNode(updated)

        // Surface tag creation sheet for any new tags the AI invented
        if !newTagNames.isEmpty {
            pendingTagSuggestions = TagSuggestionContext(
                nodeID: nodeID,
                newTagNames: newTagNames,
                existingTagNames: existingTagNames
            )
        }
    }

    // MARK: - File resolution

    func itemFileURL(for item: NodeItem, nodeID: String) async -> URL? {
        guard let file = item.file else { return nil }
        return await service.resolveItemPath(nodeID: nodeID, relativePath: file)
    }
}
