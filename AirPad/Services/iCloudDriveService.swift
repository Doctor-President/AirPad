import Foundation

/// Handles all read/write operations for AirPad's iCloud Drive storage.
/// Falls back to the local Documents directory when iCloud is unavailable.
actor iCloudDriveService {

    private let containerIdentifier = "iCloud.com.doctorpresident.airpad"

    private var rootURL: URL?

    /// True when storage is available (iCloud or local fallback).
    private(set) var isAvailable = false

    /// True when operating on the local Documents directory instead of iCloud.
    private(set) var usingLocalFallback = false

    // MARK: - Setup

    func setup() async {
        if await trySetupICloud() { return }
        trySetupLocalFallback()
    }

    private func trySetupICloud() async -> Bool {
        let identifier = containerIdentifier
        // url(forUbiquityContainerIdentifier:) can block — keep it on this actor's executor
        // which is off the main thread.
        let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: identifier)
        guard let containerURL else { return false }

        let root = containerURL.appendingPathComponent("Documents")
        do {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("nodes"),
                withIntermediateDirectories: true
            )
            rootURL = root
            isAvailable = true
            usingLocalFallback = false
            return true
        } catch {
            return false
        }
    }

    private func trySetupLocalFallback() {
        guard let localDocs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }

        let root = localDocs.appendingPathComponent("AirPad")
        do {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("nodes"),
                withIntermediateDirectories: true
            )
            rootURL = root
            isAvailable = true
            usingLocalFallback = true
        } catch {
            isAvailable = false
        }
    }

    // MARK: - Nodes

    func saveNode(_ node: Node) throws {
        let root = try requireRoot()
        let nodeDir = root.appendingPathComponent("nodes/\(node.id)")
        try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        let data = try JSONEncoder.airPad.encode(node)
        try data.write(to: nodeDir.appendingPathComponent("node.json"), options: .atomic)
    }

    func loadAllNodes() throws -> [Node] {
        let root = try requireRoot()
        let nodesDir = root.appendingPathComponent("nodes")

        let contents = try FileManager.default.contentsOfDirectory(
            at: nodesDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )

        return try contents.compactMap { nodeDir in
            let fileURL = nodeDir.appendingPathComponent("node.json")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder.airPad.decode(Node.self, from: data)
        }
    }

    // MARK: - Media files

    /// Copies a media file (audio, image, video) into the node's `items/` subdirectory.
    /// - Parameters:
    ///   - nodeID: The node that owns this item.
    ///   - itemID: The item's UUID (used as the filename base).
    ///   - sourceURL: Temporary file to copy from.
    ///   - fileExtension: e.g. `"m4a"`, `"jpg"`.
    func saveItemFile(nodeID: String, itemID: String, sourceURL: URL, fileExtension: String) throws {
        let root = try requireRoot()
        let itemsDir = root.appendingPathComponent("nodes/\(nodeID)/items")
        try FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        let destURL = itemsDir.appendingPathComponent("\(itemID).\(fileExtension)")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
    }

    // MARK: - Tags

    func saveTags(_ tags: [Tag]) throws {
        let root = try requireRoot()
        let data = try JSONEncoder.airPad.encode(tags)
        try data.write(to: root.appendingPathComponent("tags.json"), options: .atomic)
    }

    func loadTags() throws -> [Tag] {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("tags.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.airPad.decode([Tag].self, from: data)
    }

    // MARK: - File resolution

    /// Returns the absolute URL for a relative item path within a node's folder.
    /// e.g. relativePath = "items/abc123.m4a"
    func resolveItemPath(nodeID: String, relativePath: String) -> URL? {
        guard let root = rootURL else { return nil }
        return root.appendingPathComponent("nodes/\(nodeID)/\(relativePath)")
    }

    // MARK: - Canvas layout

    func saveCanvasLayout(_ layout: CanvasLayout) throws {
        let root = try requireRoot()
        let data = try JSONEncoder.airPad.encode(layout)
        try data.write(to: root.appendingPathComponent("canvas_layout.json"), options: .atomic)
    }

    func loadCanvasLayout() throws -> CanvasLayout? {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("canvas_layout.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.airPad.decode(CanvasLayout.self, from: data)
    }

    // MARK: - Corpus index

    func saveCorpusIndex(_ index: CorpusIndex) throws {
        let root = try requireRoot()
        let data = try JSONEncoder.airPad.encode(index)
        try data.write(to: root.appendingPathComponent("corpus_index.json"), options: .atomic)
    }

    func loadCorpusIndex() throws -> CorpusIndex {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("corpus_index.json")
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.airPad.decode(CorpusIndex.self, from: data)
    }

    // MARK: - Destructive operations

    /// Deletes every node directory (and all contained media), then recreates an empty
    /// `nodes/` folder, saves an empty canvas layout, and saves an empty tag list.
    func deleteAllData() throws {
        let root = try requireRoot()
        let nodesDir = root.appendingPathComponent("nodes")
        if FileManager.default.fileExists(atPath: nodesDir.path) {
            try FileManager.default.removeItem(at: nodesDir)
        }
        try FileManager.default.createDirectory(at: nodesDir, withIntermediateDirectories: true)
        let emptyLayout = CanvasLayout(version: 1, updatedAt: Date(), positions: [:])
        try saveCanvasLayout(emptyLayout)
        try saveTags([])
    }

    // MARK: - Helpers

    private func requireRoot() throws -> URL {
        guard let root = rootURL else { throw ServiceError.storageUnavailable }
        return root
    }

    enum ServiceError: Error {
        case storageUnavailable
    }
}

// MARK: - JSON helpers

extension JSONEncoder {
    static let airPad: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let airPad: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
