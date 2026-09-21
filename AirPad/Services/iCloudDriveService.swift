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
        #if DEBUG
        // Device-safety for the Stage 5.1 -FieldFixtureNode visual check: root
        // at a THROWAWAY local scratch dir so the twelve-kind fixture (and any
        // derived write a background pass makes over it — saveNode, saveCard,
        // saveCorpusIndex, …) can NEVER reach the real iCloud corpus. Every I/O
        // in this actor flows through `requireRoot()`, so redirecting the root
        // is a single, total isolation point; the real container is not even
        // resolved in this mode. See `CorpusStore.load`'s injection.
        if ProcessInfo.processInfo.arguments.contains("-FieldFixtureNode"),
           trySetupFieldFixtureScratch() {
            return
        }
        // Brief N §2 — demo the sample-library seed against a THROWAWAY scratch
        // container that NEVER touches the real iCloud corpus. The scratch starts
        // empty, so the normal seed path in `CorpusStore.load()` fires and the app
        // runs against the seeded sample. It PERSISTS across relaunch (so the
        // marker / Remove / no-re-seed cycle is real); delete the app to reset.
        if ProcessInfo.processInfo.arguments.contains("-SampleSeedDemo"),
           trySetupSampleDemoScratch() {
            return
        }
        // Brief Y Part D — `-CorpusFixture <path>`: root at a COPY of the directory
        // at <path> (a read-only clone of T's real corpus). Every write lands in a
        // throwaway scratch, NEVER back to <path> and NEVER to iCloud — so CC can run
        // retrieval / Map / Dashboard checks against real data on the Mac. The value
        // is read from the argument domain (`-CorpusFixture /abs/path`).
        if let fixture = UserDefaults.standard.string(forKey: "CorpusFixture"),
           !fixture.trimmingCharacters(in: .whitespaces).isEmpty,
           trySetupCorpusFixture(source: fixture) {
            return
        }
        #endif
        if await trySetupICloud() { return }
        trySetupLocalFallback()
    }

    #if DEBUG
    /// Brief Y Part D — root at a COPY of `source` (a real-corpus clone). Copied into
    /// a scratch ONCE (reused across launches so a large corpus isn't re-copied each
    /// time); to refresh, delete the scratch. Writes land only in the scratch — the
    /// source clone and iCloud are never touched. `usingLocalFallback=false` so no
    /// banner clouds the fixture (it's a faithful stand-in for the real container).
    private func trySetupCorpusFixture(source: String) -> Bool {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let root = caches.appendingPathComponent("AirPadCorpusFixtureScratch")
        let src = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: src.appendingPathComponent("nodes").path) else {
            print("[CorpusFixture] source has no nodes/ dir: \(src.path)")
            return false
        }
        do {
            if !fm.fileExists(atPath: root.path) {
                try fm.copyItem(at: src, to: root)
            }
            try fm.createDirectory(at: root.appendingPathComponent("nodes"), withIntermediateDirectories: true)
            rootURL = root
            isAvailable = true
            usingLocalFallback = false
            print("[CorpusFixture] rooted at scratch copy of \(src.path)")
            return true
        } catch {
            print("[CorpusFixture] setup error: \(error)")
            return false
        }
    }

    private func trySetupFieldFixtureScratch() -> Bool {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let root = caches.appendingPathComponent("AirPadFieldFixtureScratch")
        do {
            // Start clean each launch so the injected fixture is the ONLY node
            // and never accumulates / duplicates against a prior scratch run.
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("nodes"),
                withIntermediateDirectories: true
            )
            rootURL = root
            isAvailable = true
            usingLocalFallback = true
            return true
        } catch {
            return false
        }
    }

    /// Brief N §2 — throwaway scratch container for `-SampleSeedDemo`. ★ WIPED CLEAN on EVERY
    /// launch (2026-09-18 fix), like the field-fixture scratch: it is a preview of the CURRENT
    /// bundle, so it must always start empty and re-seed. The earlier persist-across-launch design
    /// let a stale marker + old placeholder seed survive a bundle update, so the seeder correctly
    /// refused to re-seed and the demo showed old content. Wiping every launch removes the trap —
    /// each `-SampleSeedDemo` run seeds the bundle as shipped. (Trade-off: the marker → Remove →
    /// no-re-seed cycle is no longer demoable HERE; test that on a real fresh Simulator install.)
    /// Never touches iCloud.
    private func trySetupSampleDemoScratch() -> Bool {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return false }
        let root = caches.appendingPathComponent("AirPadSampleDemoScratch")
        do {
            // Start clean each launch so the demo always reflects the current bundle — never a
            // stale prior seed whose marker would block re-seeding.
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("nodes"),
                withIntermediateDirectories: true
            )
            rootURL = root
            isAvailable = true
            // Report NOT-fallback so `-SampleSeedDemo` is a faithful first-run PREVIEW: the
            // "iCloud unavailable — saving locally" banner is driven by `usingLocalFallback`, and a
            // real first-run user WITH iCloud never sees it (trySetupICloud sets it false). The scratch
            // is local, but flagging it would show a banner a real iCloud user won't. Cosmetic only —
            // `usingLocalFallback`/`iCloudUnavailable` gate nothing but that banner + a debug print.
            usingLocalFallback = false
            return true
        } catch {
            return false
        }
    }
    #endif

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

    /// The resolved container root (nil before `setup()`). Exposed for
    /// `SampleLibrarySeeder`, which operates on explicit URLs so it stays testable.
    func containerRootURL() -> URL? { rootURL }

    /// Brief V — classify the resolved storage root for the one-line launch
    /// diagnostic. `scratch`/`field-scratch` are the DEBUG throwaway roots (only
    /// reached via `-SampleSeedDemo` / `-FieldFixtureNode`); `icloud` is the real
    /// ubiquity container; `local` is the no-iCloud fallback. Reading `scratch`
    /// here on a device is the fingerprint of a launch that carried the demo arg.
    func storageDiagnostic() -> (kind: String, path: String, fallback: Bool) {
        guard let root = rootURL else { return ("none", "-", usingLocalFallback) }
        let path = root.path
        let kind: String
        if path.contains("AirPadSampleDemoScratch") { kind = "scratch" }
        else if path.contains("AirPadCorpusFixtureScratch") { kind = "corpus-fixture" }
        else if path.contains("AirPadFieldFixtureScratch") { kind = "field-scratch" }
        else if path.contains("Mobile Documents") || path.contains("com~apple~CloudDocs") { kind = "icloud" }
        else if usingLocalFallback { kind = "local" }
        else { kind = "unknown" }
        return (kind, path, usingLocalFallback)
    }

    // MARK: - Nodes

    func saveNode(_ node: Node) throws {
        let root = try requireRoot()
        let nodeDir = root.appendingPathComponent("nodes/\(node.id)")
        try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        let data = try JSONEncoder.airPad.encode(node)
        try data.write(to: nodeDir.appendingPathComponent("node.json"), options: .atomic)
    }

    func deleteNode(id: String) throws {
        let root = try requireRoot()
        let nodeDir = root.appendingPathComponent("nodes/\(id)")
        if FileManager.default.fileExists(atPath: nodeDir.path) {
            try FileManager.default.removeItem(at: nodeDir)
        }
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

    // MARK: - Block embedding sidecar

    /// Per-node block-embedding sidecar at `nodes/<nodeID>/blocks.json`.
    /// Derived data — regenerable from node text via `BlockChunker`. Lives
    /// inside the node's own directory so `deleteNode` (which removes the
    /// whole directory) auto-cleans it; no symmetric delete method is
    /// needed.
    func saveBlockIndex(_ index: NodeBlockIndex, forNodeID nodeID: String) throws {
        let root = try requireRoot()
        let nodeDir = root.appendingPathComponent("nodes/\(nodeID)")
        try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        let data = try JSONEncoder.airPad.encode(index)
        try data.write(to: nodeDir.appendingPathComponent("blocks.json"), options: .atomic)
    }

    /// Returns nil when the sidecar is absent — callers treat that as
    /// "never built" and trigger a fresh chunk + embed pass. Mirrors
    /// `loadCollections` rather than `loadTags`: missing-file is a
    /// meaningful signal here, not an empty list.
    func loadBlockIndex(forNodeID nodeID: String) throws -> NodeBlockIndex? {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("nodes/\(nodeID)/blocks.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.airPad.decode(NodeBlockIndex.self, from: data)
    }

    // MARK: - Catalog card sidecar

    /// ws-card-catalog step 2a — per-node catalog-card sidecar at
    /// `nodes/<nodeID>/card.json`. Derived data (regenerable from node content).
    /// Lives inside the node's directory so `deleteNode` (which removes the whole
    /// directory) auto-cleans it; no symmetric delete method is needed. Mirrors
    /// `saveBlockIndex` exactly.
    func saveCard(_ card: CatalogCard, forNodeID nodeID: String) throws {
        let root = try requireRoot()
        let nodeDir = root.appendingPathComponent("nodes/\(nodeID)")
        try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        let data = try JSONEncoder.airPad.encode(card)
        try data.write(to: nodeDir.appendingPathComponent("card.json"), options: .atomic)
    }

    /// Returns nil when the sidecar is absent — callers treat that as "no card
    /// yet". Mirrors `loadBlockIndex`.
    func loadCard(forNodeID nodeID: String) throws -> CatalogCard? {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("nodes/\(nodeID)/card.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.airPad.decode(CatalogCard.self, from: data)
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

    /// Stage 3.1b — deletes the media file for an entry. Symmetric to
    /// `saveItemFile`. Returns `true` if a file was found and removed,
    /// `false` if no file existed at the expected path (already gone, never
    /// created, or corrupted state). Only throws on actual filesystem errors
    /// (permissions, disk full, root unavailable) — missing-file is a
    /// recoverable no-op so `CorpusStore.deleteEntry` can still remove the
    /// orphaned entry from `node.items`.
    @discardableResult
    func deleteItemFile(nodeID: String, itemID: String, fileExtension: String) throws -> Bool {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("nodes/\(nodeID)/items/\(itemID).\(fileExtension)")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        try FileManager.default.removeItem(at: fileURL)
        return true
    }

    /// Test-only sibling check used by `EntryDeletionDiagnostic` to assert
    /// the file is gone from disk after a delete cycle. Lives here (not in
    /// the diagnostic) so the diagnostic doesn't have to know how the actor
    /// composes its root URL — single source of truth for item-path resolution.
    func itemFileExists(nodeID: String, itemID: String, fileExtension: String) -> Bool {
        guard let root = rootURL else { return false }
        let fileURL = root.appendingPathComponent("nodes/\(nodeID)/items/\(itemID).\(fileExtension)")
        return FileManager.default.fileExists(atPath: fileURL.path)
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

    // MARK: - Collections (Dashboard Stage 3)

    func saveCollections(_ collections: [NodeCollection]) throws {
        let root = try requireRoot()
        let data = try JSONEncoder.airPad.encode(collections)
        try data.write(to: root.appendingPathComponent("collections.json"), options: .atomic)
    }

    /// Returns nil when the file is absent (first launch). Returns an empty
    /// array when the user has explicitly deleted all their collections.
    /// CorpusStore relies on this distinction to seed defaults exactly once.
    func loadCollections() throws -> [NodeCollection]? {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("collections.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.airPad.decode([NodeCollection].self, from: data)
    }

    // MARK: - Field definitions (Stage 5.1 — atomic fields)

    /// Write half of the corpus-level field-definition store, at
    /// `<root>/field_definitions.json`. Mirrors `saveCollections` — a single
    /// top-level file beside `nodes/`, one atomic write per change. (No caller
    /// in Stage 1: field creation is a later stage. The symmetric pair lives
    /// here so the I/O layer is complete, matching every other store object.)
    func saveFieldDefinitions(_ store: FieldDefinitionStore) throws {
        let root = try requireRoot()
        let data = try JSONEncoder.airPad.encode(store)
        try data.write(to: root.appendingPathComponent("field_definitions.json"), options: .atomic)
    }

    /// Returns nil when the file is absent — the normal first-run state (a
    /// corpus with no field definitions yet). CorpusStore treats nil as an
    /// empty definition set and does NOT seed or write anything (unlike
    /// collections/tags, there are no default fields to seed). Mirrors
    /// `loadCollections`.
    func loadFieldDefinitions() throws -> FieldDefinitionStore? {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("field_definitions.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.airPad.decode(FieldDefinitionStore.self, from: data)
    }

    // MARK: - Chats (clean Chat lane)

    /// Single-file blob at `<root>/chats.json`. Mirrors `collections.json`
    /// / `tags.json` rather than the per-node directory pattern — chats
    /// are small JSON records with no sidecars, and a single file means
    /// one atomic write per upsert. Lives at the same iCloud Drive root
    /// as the corpus so chats sync alongside the user's nodes.
    func saveChats(_ chats: [Chat]) throws {
        let root = try requireRoot()
        let data = try JSONEncoder.airPad.encode(chats)
        try data.write(to: root.appendingPathComponent("chats.json"), options: .atomic)
    }

    /// nil when the file is absent (first launch / pre-chat install).
    /// Empty array when the user has deleted every chat — distinct
    /// signal so `ChatStore` doesn't try to seed anything on top of an
    /// intentionally-empty state.
    func loadChats() throws -> [Chat]? {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("chats.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.airPad.decode([Chat].self, from: data)
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

    // MARK: - Territory layout (tag-anchored Map geography)

    /// Persist the Map's derived card-basis geography so a relaunch RESTORES it
    /// instead of re-deriving + animating it (the map-relayout fix). Separate file
    /// from `canvas_layout.json`: that one is the CANONICAL (non-territory) layout,
    /// written by capture/import/neighborhood/recompute — the territory geography
    /// must never collide with it.
    /// Brief Z Z2 — `territory_layout.json` is now a PER-SCOPE dict
    /// (`CanvasScope.key` → snapshot), so the user map and sample map persist
    /// independently.
    func saveTerritoryLayouts(_ layouts: [String: TerritoryLayoutSnapshot]) throws {
        let root = try requireRoot()
        let data = try JSONEncoder.airPad.encode(layouts)
        try data.write(to: root.appendingPathComponent("territory_layout.json"), options: .atomic)
    }

    /// Loads the per-scope dict. **Migration:** a pre-Z2 file holds a SINGLE
    /// snapshot object — decode that and wrap it under the `_corpus` key (the user
    /// room), so an existing map restores on the first Z2 launch instead of re-forming.
    func loadTerritoryLayouts() throws -> [String: TerritoryLayoutSnapshot]? {
        let root = try requireRoot()
        let fileURL = root.appendingPathComponent("territory_layout.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        if let dict = try? JSONDecoder.airPad.decode([String: TerritoryLayoutSnapshot].self, from: data) {
            return dict
        }
        if let single = try? JSONDecoder.airPad.decode(TerritoryLayoutSnapshot.self, from: data) {
            return [NodeCollection.corpusID: single]   // pre-Z2 → the user room
        }
        return nil
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

    /// SB137 Stage A — write the routing diagnostics sidecar so the cosine
    /// distribution can be AirDropped back for offline threshold tuning.
    /// Overwritten on every neighborhood refresh.
    func saveRoutingDiagnostics(_ diagnostics: RoutingDiagnostics) throws {
        let root = try requireRoot()
        let data = try JSONEncoder.airPad.encode(diagnostics)
        try data.write(
            to: root.appendingPathComponent("corpus_routing_diagnostics.json"),
            options: .atomic
        )
    }

    /// SB137 Stage A — copy the live `corpus_index.json` to
    /// `corpus_index.pre-stageA.json` so a manual revert is possible if the
    /// post-upgrade rebuild produces something obviously broken. Idempotent in
    /// the sense that the backup is overwritten on every call (so a second
    /// upgrade attempt doesn't lose the original); the caller guards by
    /// detecting the v1 → v2 schema transition exactly once.
    func backupCorpusIndexForStageAUpgrade() throws {
        let root = try requireRoot()
        let src = root.appendingPathComponent("corpus_index.json")
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let dst = root.appendingPathComponent("corpus_index.pre-stageA.json")
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
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
