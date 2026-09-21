import Foundation

/// Brief N §2 — first-run seeding of the bundled sample library.
///
/// PURE file operations over an explicit `(containerRoot, bundleRoot)` pair, with
/// no app state and no actor, so the whole mechanism is testable off any live
/// store (see `-SampleSeedSelfTest`, which runs it against a throwaway temp dir).
///
/// Bundle layout — a folder reference `SampleLibrary/` in the app bundle:
/// ```
///   SampleLibrary/nodes/<id>/node.json     (+ optional card.json, items/…)
///   SampleLibrary/collections.json  tags.json  field_definitions.json  chats.json
/// ```
/// The seeder COPIES each node dir verbatim (so a BAKED `card.json` and any media
/// sidecars ride along when present, and are simply absent when they are not —
/// per T's §5 ruling the seeder must work either way) and MERGES the four side
/// files into whatever the container already holds (so the app's own default
/// collections/tags survive alongside the sample). A durable marker
/// `sample_library.json` in the container records EXACTLY what was seeded, so
/// removal is precise and never touches the user's own nodes.
///
/// Marker semantics: the marker is a file in the iCloud/local Documents container,
/// NOT UserDefaults — UserDefaults is wiped on delete+reinstall, but the container
/// (when iCloud-backed) survives a reinstall along with the seeded nodes, so a
/// file marker is what keeps seeding idempotent against reinstall. In the
/// local-only case a reinstall wipes the container (marker + nodes together) and
/// the sample correctly re-seeds.
enum SampleLibrarySeeder {
    static let markerName = "sample_library.json"
    static let manifestVersion = 1

    /// The record of exactly what a seed pass wrote — drives precise removal.
    struct Manifest: Codable {
        var version: Int
        var seededAt: Date?
        var collectionIDs: [String]
        var nodeIDs: [String]
        var tagIDs: [String]
        var fieldDefinitionIDs: [String]
        var chatIDs: [String]
    }

    // MARK: - Gate

    /// Seed only on a genuinely fresh, empty install: no marker AND no nodes yet.
    /// (An existing user with nodes but no marker — e.g. every pre-seed install,
    /// including T's dev corpus — is never seeded over.)
    static func shouldSeed(containerRoot: URL) -> Bool {
        !markerExists(containerRoot: containerRoot) && nodesDirIsEmpty(containerRoot: containerRoot)
    }

    static func markerExists(containerRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: containerRoot.appendingPathComponent(markerName).path)
    }

    /// Brief U — the marker file IS the manifest; decode it so the store can read
    /// the seeded node/collection ids (the separator between the sample and the
    /// user's own corpus), not only delete by them. nil when absent/corrupt.
    static func loadManifest(containerRoot: URL) -> Manifest? {
        let url = containerRoot.appendingPathComponent(markerName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.airPad.decode(Manifest.self, from: data)
    }

    static func nodesDirIsEmpty(containerRoot: URL) -> Bool {
        let nodesDir = containerRoot.appendingPathComponent("nodes")
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: nodesDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        // A node "exists" iff its dir carries a node.json.
        return !dirs.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("node.json").path)
        }
    }

    /// The bundled sample-library folder, or nil if it wasn't bundled.
    static func bundledLibraryURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "SampleLibrary", withExtension: nil)
    }

    // MARK: - Seed

    /// Copies every bundled node dir into the container and merges the side files.
    /// Returns (and writes) the manifest of what was seeded. Idempotent per node
    /// dir (an existing dir of the same id is replaced). Side-file merges dedup by
    /// id (collections / field defs / chats) or by name (tags), so re-running is safe.
    @discardableResult
    static func seed(containerRoot: URL, bundleRoot: URL, now: Date = Date()) throws -> Manifest {
        let fm = FileManager.default
        let dec = JSONDecoder.airPad

        // 1) Copy node dirs verbatim — node.json + any baked card.json / items/ ride along.
        let bundleNodes = bundleRoot.appendingPathComponent("nodes")
        let containerNodes = containerRoot.appendingPathComponent("nodes")
        try fm.createDirectory(at: containerNodes, withIntermediateDirectories: true)
        var seededNodeIDs: [String] = []
        let nodeDirs = (try? fm.contentsOfDirectory(
            at: bundleNodes, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for dir in nodeDirs {
            guard fm.fileExists(atPath: dir.appendingPathComponent("node.json").path) else { continue }
            let id = dir.lastPathComponent
            let dest = containerNodes.appendingPathComponent(id)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: dir, to: dest)
            seededNodeIDs.append(id)
        }

        // 2) Collections — merge, dedup by id.
        var seededCollectionIDs: [String] = []
        if let data = bundleData(bundleRoot, "collections.json"),
           let sample = try? dec.decode([NodeCollection].self, from: data) {
            var existing = (try? loadCollections(containerRoot)) ?? []
            let ids = Set(existing.map(\.id))
            for c in sample where !ids.contains(c.id) { existing.append(c); seededCollectionIDs.append(c.id) }
            try saveCollections(existing, containerRoot)
        }

        // 3) Tags — merge, dedup by name (case-insensitive, matching the store).
        var seededTagIDs: [String] = []
        if let data = bundleData(bundleRoot, "tags.json"),
           let sample = try? dec.decode([Tag].self, from: data) {
            var existing = (try? loadTags(containerRoot)) ?? []
            var names = Set(existing.map { $0.name.lowercased() })
            for t in sample where !names.contains(t.name.lowercased()) {
                existing.append(t); seededTagIDs.append(t.id.uuidString); names.insert(t.name.lowercased())
            }
            try saveTags(existing, containerRoot)
        }

        // 4) Field definitions — merge, dedup by id.
        var seededDefIDs: [String] = []
        if let data = bundleData(bundleRoot, "field_definitions.json"),
           let sampleStore = try? dec.decode(FieldDefinitionStore.self, from: data) {
            var store = (try? loadFieldDefinitions(containerRoot)) ?? FieldDefinitionStore()
            let ids = Set(store.definitions.map(\.id))
            for d in sampleStore.definitions where !ids.contains(d.id) {
                store.definitions.append(d); seededDefIDs.append(d.id)
            }
            try saveFieldDefinitions(store, containerRoot)
        }

        // 5) Chats — merge, dedup by id (present only once pinned chats are baked).
        var seededChatIDs: [String] = []
        if let data = bundleData(bundleRoot, "chats.json"),
           let sample = try? dec.decode([Chat].self, from: data) {
            var existing = (try? loadChats(containerRoot)) ?? []
            let ids = Set(existing.map { $0.id })
            for c in sample where !ids.contains(c.id) { existing.append(c); seededChatIDs.append(c.id.uuidString) }
            try saveChats(existing, containerRoot)
        }

        // 6) Write the marker.
        let manifest = Manifest(
            version: manifestVersion, seededAt: now,
            collectionIDs: seededCollectionIDs, nodeIDs: seededNodeIDs,
            tagIDs: seededTagIDs, fieldDefinitionIDs: seededDefIDs, chatIDs: seededChatIDs)
        try JSONEncoder.airPad.encode(manifest)
            .write(to: containerRoot.appendingPathComponent(markerName), options: .atomic)
        return manifest
    }

    // MARK: - Remove

    /// Reads the marker and removes EXACTLY what was seeded. Node dirs are deleted
    /// only by their recorded id, so a user's own nodes (different ids) are never
    /// touched. Shared artifacts (tags / field defs / chats) are removed only when
    /// no SURVIVING node still references them — so a tag the user has since applied
    /// to their own note is kept. Returns the removed manifest, or nil if none.
    @discardableResult
    static func remove(containerRoot: URL) throws -> Manifest? {
        let fm = FileManager.default
        let markerURL = containerRoot.appendingPathComponent(markerName)
        guard let data = try? Data(contentsOf: markerURL),
              let manifest = try? JSONDecoder.airPad.decode(Manifest.self, from: data) else { return nil }

        // 1) Delete seeded node dirs — by recorded id ONLY.
        let containerNodes = containerRoot.appendingPathComponent("nodes")
        for id in manifest.nodeIDs {
            let dir = containerNodes.appendingPathComponent(id)
            if fm.fileExists(atPath: dir.path) { try? fm.removeItem(at: dir) }
        }

        // 2) Load SURVIVING nodes to guard shared artifacts.
        let survivors = (try? loadAllNodes(containerRoot)) ?? []
        let survivingTagNames = Set(survivors.flatMap { $0.tags.map { $0.lowercased() } })
        let survivingDefIDs = Set(survivors.flatMap { $0.items.compactMap { $0.field?.definitionID } })
        let survivingChatIDs = Set(survivors.flatMap { $0.items.flatMap { $0.chatSessionIDs ?? [] } })

        // 3) Seeded collections.
        if var collections = try? loadCollections(containerRoot) {
            let before = collections.count
            collections.removeAll { manifest.collectionIDs.contains($0.id) }
            if collections.count != before { try saveCollections(collections, containerRoot) }
        }
        // 4) Seeded tags — kept if a surviving node still uses them.
        if var tags = try? loadTags(containerRoot) {
            let seeded = Set(manifest.tagIDs)
            let before = tags.count
            tags.removeAll { seeded.contains($0.id.uuidString) && !survivingTagNames.contains($0.name.lowercased()) }
            if tags.count != before { try saveTags(tags, containerRoot) }
        }
        // 5) Seeded field definitions — kept if a surviving node references them.
        if var store = try? loadFieldDefinitions(containerRoot) {
            let seeded = Set(manifest.fieldDefinitionIDs)
            let before = store.definitions.count
            store.definitions.removeAll { seeded.contains($0.id) && !survivingDefIDs.contains($0.id) }
            if store.definitions.count != before { try saveFieldDefinitions(store, containerRoot) }
        }
        // 6) Seeded chats — kept if a surviving node references them.
        if var chats = try? loadChats(containerRoot) {
            let seeded = Set(manifest.chatIDs)
            let before = chats.count
            chats.removeAll { seeded.contains($0.id.uuidString) && !survivingChatIDs.contains($0.id.uuidString) }
            if chats.count != before { try saveChats(chats, containerRoot) }
        }

        // 7) Delete the marker.
        try? fm.removeItem(at: markerURL)
        return manifest
    }

    // MARK: - Local file helpers (mirror iCloudDriveService paths + formats exactly)

    private static func bundleData(_ root: URL, _ name: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(name))
    }
    private static func loadAllNodes(_ root: URL) throws -> [Node] {
        let dir = root.appendingPathComponent("nodes")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return try contents.compactMap { d in
            let f = d.appendingPathComponent("node.json")
            guard FileManager.default.fileExists(atPath: f.path) else { return nil }
            return try JSONDecoder.airPad.decode(Node.self, from: Data(contentsOf: f))
        }
    }
    private static func loadCollections(_ root: URL) throws -> [NodeCollection]? {
        let f = root.appendingPathComponent("collections.json")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try JSONDecoder.airPad.decode([NodeCollection].self, from: Data(contentsOf: f))
    }
    private static func saveCollections(_ c: [NodeCollection], _ root: URL) throws {
        try JSONEncoder.airPad.encode(c).write(to: root.appendingPathComponent("collections.json"), options: .atomic)
    }
    private static func loadTags(_ root: URL) throws -> [Tag]? {
        let f = root.appendingPathComponent("tags.json")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try JSONDecoder.airPad.decode([Tag].self, from: Data(contentsOf: f))
    }
    private static func saveTags(_ t: [Tag], _ root: URL) throws {
        try JSONEncoder.airPad.encode(t).write(to: root.appendingPathComponent("tags.json"), options: .atomic)
    }
    private static func loadFieldDefinitions(_ root: URL) throws -> FieldDefinitionStore? {
        let f = root.appendingPathComponent("field_definitions.json")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try JSONDecoder.airPad.decode(FieldDefinitionStore.self, from: Data(contentsOf: f))
    }
    private static func saveFieldDefinitions(_ s: FieldDefinitionStore, _ root: URL) throws {
        try JSONEncoder.airPad.encode(s).write(to: root.appendingPathComponent("field_definitions.json"), options: .atomic)
    }
    private static func loadChats(_ root: URL) throws -> [Chat]? {
        let f = root.appendingPathComponent("chats.json")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try JSONDecoder.airPad.decode([Chat].self, from: Data(contentsOf: f))
    }
    private static func saveChats(_ c: [Chat], _ root: URL) throws {
        try JSONEncoder.airPad.encode(c).write(to: root.appendingPathComponent("chats.json"), options: .atomic)
    }
}
