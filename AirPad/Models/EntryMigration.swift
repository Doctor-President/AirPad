import Foundation

/// Per-node lazy migration of the entry schema. Chains every versioned step:
/// a node decoded at version 0 (legacy) is brought up to the current version
/// in one call.
///
/// Returns `true` if any step actually ran (caller should persist), `false`
/// if the node was already at the current version (no-op). Idempotent:
/// running twice on the same node produces the same result as running once.
/// Lossless: each step only populates nil fields or transforms specific
/// legacy shapes — existing populated fields are never overwritten.
///
/// Per-node, lazy. Caller is `CorpusStore.ensureEntrySchema(forNodeID:)`,
/// invoked from `NodeDetailView.onAppear`. Nodes the user never opens stay
/// at their on-disk version until first open under this build — the corpus
/// is never bulk-walked at launch.
///
/// ## Versions
/// - 0 → 1: Stage 3.1a entry primitive (`displayName`, `isExpanded`,
///   `updatedAt`, `specializedType`).
/// - 1 → 2: Stage 4.2 unified image/video gallery (`mediaItems` array,
///   `.image` / `.video` entry types collapsed into `.imageVideo`).
@discardableResult
func migrateEntrySchemaIfNeeded(_ node: inout Node) -> Bool {
    var didMigrate = false
    if node.entrySchemaVersion < 1 {
        migrateEntrySchemaV0ToV1(&node)
        didMigrate = true
    }
    if node.entrySchemaVersion < 2 {
        migrateEntrySchemaV1ToV2(&node)
        didMigrate = true
    }
    return didMigrate
}

// MARK: - v0 → v1 (Stage 3.1a entry primitive)

/// Populates the four entry-primitive fields added in Stage 3.1a:
/// `displayName`, `isExpanded`, `updatedAt`, `specializedType`. Sequential
/// display names are scoped per-node, per-type (`Voice`, `Voice 2`, …);
/// gaps after deletion are accepted — stable identity over tidy sequences.
private func migrateEntrySchemaV0ToV1(_ node: inout Node) {
    var counters: [NodeItemType: Int] = [:]
    for i in node.items.indices {
        let t = node.items[i].type
        let n = (counters[t] ?? 0) + 1
        counters[t] = n

        // Only populate fields that are absent. A user who renamed an item
        // under a hypothetical earlier 3.1a build (or any future scenario
        // where displayName arrives populated) is respected.
        if node.items[i].displayName == nil {
            let base = t.defaultDisplayName
            node.items[i].displayName = (n == 1) ? base : "\(base) \(n)"
        }
        if node.items[i].isExpanded == nil {
            node.items[i].isExpanded = true
        }
        if node.items[i].updatedAt == nil {
            // Legacy items have no `updatedAt`; fall back to `createdAt`
            // so the field is always populated post-migration.
            node.items[i].updatedAt = node.items[i].createdAt
        }
        // `specializedType` stays nil — no specialized types in 3.1a.
    }

    node.entrySchemaVersion = 1
}

// MARK: - v1 → v2 (Stage 4.2 unified image/video gallery)

/// Converts every `.image` and `.video` entry into a unified `.imageVideo`
/// entry whose `mediaItems` is a one-element array carrying the original
/// file reference.
///
/// `GalleryItem.id` is set equal to the parent `NodeItem.id` so the existing
/// sidecar path `nodes/<nodeID>/items/<itemID>.<ext>` stays reachable
/// without file moves. `capturedAt` is filled from the entry's `createdAt`;
/// `aspectRatio` stays nil and is populated by the renderer on first load.
///
/// Legacy `file` / `description` / `transcript` / `durationSeconds` stay
/// populated on the migrated entry — vestigial post-migration but harmless,
/// useful as a diagnostic breadcrumb if `mediaItems` is ever found
/// inconsistent. Rendering reads `mediaItems`, not `file`.
///
/// A `.image` or `.video` entry with a nil `file` (a malformed legacy
/// shape) is still converted: `type` becomes `.imageVideo` with an empty
/// `mediaItems` array. The renderer's empty-state path handles the rest per
/// 3.1a's empty-entries-persist rule.
///
/// Other entry types (`text`, `audio`, `link`, `document`) are untouched
/// by this step.
private func migrateEntrySchemaV1ToV2(_ node: inout Node) {
    for i in node.items.indices {
        let item = node.items[i]
        switch item.type {
        case .image, .video:
            // Idempotency safety: if a previous pass already populated
            // mediaItems (shouldn't be possible since type=.image/.video
            // implies pre-v2, but be defensive), leave the entry alone.
            guard item.mediaItems == nil else { continue }
            let mediaType: GalleryItem.MediaType = (item.type == .image) ? .image : .video
            if let file = item.file {
                let galleryItem = GalleryItem(
                    id: item.id,
                    mediaType: mediaType,
                    file: file,
                    aspectRatio: nil,
                    capturedAt: item.createdAt
                )
                node.items[i].mediaItems = [galleryItem]
            } else {
                node.items[i].mediaItems = []
            }
            node.items[i].type = .imageVideo
        case .text, .audio, .link, .document, .imageVideo:
            // Untouched by this step. `.imageVideo` only appears if a
            // future schema step lands on top of an already-migrated node;
            // skipping here is safe.
            continue
        }
    }
    node.entrySchemaVersion = 2
}
