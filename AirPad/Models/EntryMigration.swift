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
/// - 2 → 3: Stage 4.5 link gallery (`linkItems` array on `.link`
///   entries). Legacy `url` / `title` / `preview` / `og*` fields stay
///   populated for v1/v2 compatibility; rendering reads `linkItems`
///   when present.
/// - 3 → 4: Stage 4.6 document gallery (`documentItems` array on
///   `.document` entries). Legacy `file` / `description` fields stay
///   populated for v1/v2/v3 compatibility; rendering reads
///   `documentItems` when present. `LinkItem` snapshot fields
///   (`snapshotText`, `snapshotAt`, `snapshotWordCount`) are bundled
///   into this bump per the Phase 1 audit — every prior gallery
///   enrichment bumped on shape change, so this matches the project
///   contract even though the snapshot fields are themselves additive
///   optional. The migration step itself does no work on `LinkItem`s
///   (the new snapshot fields are nil for every pre-4.6 link until the
///   user invokes the Snapshot gesture).
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
    if node.entrySchemaVersion < 3 {
        migrateEntrySchemaV2ToV3(&node)
        didMigrate = true
    }
    if node.entrySchemaVersion < 4 {
        migrateEntrySchemaV3ToV4(&node)
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

// MARK: - v2 → v3 (Stage 4.5 link gallery)

/// Converts every `.link` entry with `url` populated into a one-element
/// `linkItems` array. The legacy `url` / `title` / `preview` / `og*` fields
/// stay populated on the migrated entry — vestigial post-migration but
/// harmless, useful as a diagnostic breadcrumb if `linkItems` is ever found
/// inconsistent, and required for any v1/v2 read path that hasn't been
/// updated to read from `linkItems` yet. Rendering reads `linkItems` when
/// present.
///
/// `LinkItem.id` is set equal to the parent `NodeItem.id` so the existing
/// OG-image sidecar at `nodes/<nodeID>/items/<entryID>.og.<ext>` stays
/// reachable via `LinkItem.imageFile` without renaming. The OG fields are
/// copied from the parent `NodeItem`'s OG-fetched fields directly — no
/// network re-fetch is needed even though `OGMetadataService` has no
/// explicit cache-lookup method, because the OG metadata was persisted
/// on the parent `NodeItem` by `LinkEntryBody`'s first-render fetch.
/// Entries that never completed an OG fetch carry nil OG fields into
/// `linkItems[0]`; the new `LinkGalleryTile` (commit 3) will trigger a
/// fetch on first render using the same staleness check
/// `LinkEntryBody.refetchIfStaleOrMissing` uses today.
///
/// A `.link` entry with a nil `url` (the in-progress URL-entry state
/// where the user opened a fresh link entry but hasn't committed a URL)
/// is left with `linkItems = nil`. The renderer's State A path in
/// `OGPreviewView` continues to drive URL entry; commit 2 routes the
/// first URL commit through a store method that creates `linkItems`
/// directly without going through this migration path again.
///
/// Other entry types (`text`, `audio`, `image`, `video`, `imageVideo`,
/// `document`) are untouched by this step. Note that pre-v2 entries are
/// already brought up to v2 by `migrateEntrySchemaV1ToV2` running first
/// in the chain, so by the time this step runs, all image/video entries
/// have type `.imageVideo` (not the legacy `.image` / `.video`).
private func migrateEntrySchemaV2ToV3(_ node: inout Node) {
    for i in node.items.indices {
        let item = node.items[i]
        guard item.type == .link else { continue }
        // Idempotency safety: if a previous pass already populated
        // linkItems (shouldn't be possible since entrySchemaVersion < 3
        // gates entry here, but be defensive), leave the entry alone.
        guard item.linkItems == nil else { continue }
        guard let url = item.url, !url.isEmpty else {
            // No URL committed yet — leave linkItems nil. The State A
            // path in OGPreviewView still drives URL entry; commit 2's
            // store method will create linkItems on first commit.
            continue
        }
        let linkItem = LinkItem(
            id: item.id,
            url: url,
            title: item.ogTitle,
            description: item.ogDescription,
            imageFile: item.ogImageFile,
            siteName: item.ogSiteName,
            faviconFile: nil,
            capturedAt: item.createdAt
        )
        node.items[i].linkItems = [linkItem]
    }
    node.entrySchemaVersion = 3
}

// MARK: - v3 → v4 (Stage 4.6 document gallery + link snapshot fields)

/// Converts every `.document` entry with `file` populated into a one-element
/// `documentItems` array. The legacy `file` / `description` fields stay
/// populated on the migrated entry — vestigial post-migration but harmless,
/// useful as a diagnostic breadcrumb if `documentItems` is ever found
/// inconsistent, and required for any v1/v2/v3 read path that hasn't been
/// updated to read from `documentItems` yet. Rendering reads
/// `documentItems` when present.
///
/// `DocumentItem.id` is set equal to the parent `NodeItem.id` so the
/// existing file sidecar at `nodes/<nodeID>/items/<entryID>.<ext>` stays
/// reachable via `DocumentItem.filePath` without renaming — same strategy
/// `migrateEntrySchemaV1ToV2` uses for `GalleryItem.id` and
/// `migrateEntrySchemaV2ToV3` uses for `LinkItem.id`.
///
/// `extractedText`, `thumbnailFile`, `documentTitle`, `pageCount`, and
/// `wordCount` are nil on migrated entries — extraction is async and
/// expensive (PDF page-1 render, HTML JS execution), so we don't run it
/// inside the migration. Commit 2 wires a backfill path that fires
/// `DocumentExtractionService` on first render of a `.document` tile
/// whose `extractedText` is nil, the same way Stage 4.5 backfills
/// missing OG metadata via `LinkEntryBody.refetchIfStaleOrMissing`.
///
/// A `.document` entry with a nil `file` (a malformed legacy shape or
/// a placeholder entry that never had a file attached) is left with
/// `documentItems = nil`. The renderer's empty-state fallback in
/// `DocumentEntryBody` handles those entries unchanged.
///
/// `LinkItem` snapshot fields (`snapshotText` / `snapshotAt` /
/// `snapshotWordCount`) are bundled into the v4 bump but require no
/// migration work — they're additive optional and nil for every
/// pre-4.6 link until the user invokes the Snapshot gesture. Bundling
/// them into v4 (rather than treating them as additive-without-bump)
/// matches the project contract: every prior gallery enrichment
/// (v1→v2 mediaItems, v2→v3 linkItems) bumped on shape change.
///
/// Other entry types (`text`, `audio`, `image`, `video`, `imageVideo`,
/// `link`) are untouched by this step. Note that pre-v2 entries are
/// already brought up to v2 by `migrateEntrySchemaV1ToV2` running
/// first in the chain, so by the time this step runs, all
/// image/video entries have type `.imageVideo` and `.document` is the
/// only file-bearing type left.
private func migrateEntrySchemaV3ToV4(_ node: inout Node) {
    for i in node.items.indices {
        let item = node.items[i]
        guard item.type == .document else { continue }
        // Idempotency safety: if a previous pass already populated
        // documentItems (shouldn't be possible since entrySchemaVersion
        // < 4 gates entry here, but be defensive), leave the entry alone.
        guard item.documentItems == nil else { continue }
        guard let file = item.file, !file.isEmpty else {
            // No file committed — leave documentItems nil. The renderer's
            // empty-state fallback handles those entries unchanged.
            continue
        }
        // Derive fileName + fileType from the legacy sidecar path. The
        // legacy `file` field for documents is the same UUID-named
        // sidecar shape used by every other media type, so the last
        // path component is the on-disk filename and the extension
        // after the final `.` is the file type. We don't have the
        // user-facing original filename (it was never stored
        // pre-4.6), so we fall back to the on-disk filename — the
        // user can rename the entry's displayName to give it a more
        // recognizable label.
        let onDiskName = (file as NSString).lastPathComponent
        let ext = (onDiskName as NSString).pathExtension.lowercased()
        let documentItem = DocumentItem(
            id: item.id,
            filePath: file,
            fileName: onDiskName,
            fileType: ext,
            documentTitle: nil,
            extractedText: nil,
            thumbnailFile: nil,
            pageCount: nil,
            wordCount: nil,
            capturedAt: item.createdAt
        )
        node.items[i].documentItems = [documentItem]
    }
    node.entrySchemaVersion = 4
}
