import Foundation

struct NodeItem: Codable, Identifiable, Equatable {
    let id: String
    /// Mutable as of Stage 4.2 so `migrateEntrySchemaV1ToV2` can convert
    /// `.image` and `.video` entries to the unified `.imageVideo` type in
    /// place. No other code path mutates `type` — the only legitimate write
    /// is the migration step.
    var type: NodeItemType
    let createdAt: Date

    // text
    var content: String?

    // image, audio, video
    var file: String?

    // image
    var description: String?

    // audio, video
    var transcript: String?
    var durationSeconds: Double?

    // link
    var url: String?
    var title: String?
    var preview: String?

    // Stage 3.1a — entry primitive. Four fields added additively so legacy
    // `node.json` files decode cleanly via `decodeIfPresent`. The per-node
    // `Node.entrySchemaVersion` bump and `migrateEntrySchemaIfNeeded` populate
    // these on first open under 3.1a; thereafter they are always present on
    // disk. The `NodeItem` → `NodeEntry` rename is deferred to commit (b)
    // alongside the EntryCard UI shift.

    /// Future seat for specialized types (e.g. "ingredients", "recipeSteps").
    /// Always nil in 3.1a; reserved so the schema doesn't need another
    /// migration when specialized types arrive.
    var specializedType: String?

    /// User-editable display name shown in the entry card's title row.
    /// Populated by migration from `type.defaultDisplayName` + sequential
    /// numbering scoped to the node. Optional in the schema so legacy JSON
    /// decodes; always non-nil after migration runs.
    var displayName: String?

    /// Collapsed/expanded state for the entry card. Defaults true (expanded)
    /// on migration and on new entries. Persists across app restarts so a
    /// user's deliberate collapse survives.
    var isExpanded: Bool?

    /// Last-edit timestamp. Optional in 3.1a (the legacy schema only had
    /// `createdAt`); migration backfills to `createdAt` for legacy items.
    /// Live edits in commit (b) onward will bump this.
    var updatedAt: Date?

    // AT19.3c — OG preview metadata for link entries. Five additive optional
    // fields populated by `OGMetadataService` after a successful
    // `LPMetadataProvider` fetch. Image stored as sidecar at
    // `nodes/<nodeID>/items/<id>.og.<ext>` to keep `node.json` small;
    // `ogImageFile` holds just the filename. Legacy link entries decode
    // cleanly via `decodeIfPresent` — no `entrySchemaVersion` bump.
    var ogTitle: String?
    var ogDescription: String?
    var ogSiteName: String?
    var ogImageFile: String?
    var ogFetchedAt: Date?

    // Stage 4.2 — ordered media list backing an `.imageVideo` entry. Populated
    // by `migrateEntrySchemaV1ToV2` for legacy `.image` / `.video` entries
    // (one-element array; `GalleryItem.id` matches `NodeItem.id` so the
    // existing sidecar path stays reachable without file moves) and by the
    // creation/append flows for new gallery entries. Nil on every non-
    // imageVideo entry; rendering reads off this field for `.imageVideo`
    // and ignores the legacy `file` / `description` / `transcript` /
    // `durationSeconds` fields (which remain populated on migrated entries
    // as a diagnostic breadcrumb but are no longer authoritative).
    var mediaItems: [GalleryItem]?

    // Stage 4.2 commit 4 — per-entry gallery view-mode persistence. Three-
    // state semantics:
    //   - nil: user has never chosen; renderer picks a count-based default
    //     (≤3 → carousel, ≥4 → bento). Single-item entries also leave this
    //     nil — they render via `SingleMediaBody`, which doesn't read
    //     `viewMode`.
    //   - .carousel / .bento: user (or the first single→multi transition)
    //     wrote a value. The renderer honors it verbatim regardless of
    //     count; incremental adds preserve the existing choice so the user's
    //     toggle is the only thing that changes it after first transition.
    // Additive optional, no entrySchemaVersion bump — `decodeIfPresent`
    // handles legacy `node.json` files cleanly.
    var viewMode: GalleryViewMode?

    enum CodingKeys: String, CodingKey {
        case id, type, content, file, description, transcript, url, title, preview
        case createdAt = "created_at"
        case durationSeconds = "duration_seconds"
        case specializedType = "specialized_type"
        case displayName = "display_name"
        case isExpanded = "is_expanded"
        case updatedAt = "updated_at"
        case ogTitle = "og_title"
        case ogDescription = "og_description"
        case ogSiteName = "og_site_name"
        case ogImageFile = "og_image_file"
        case ogFetchedAt = "og_fetched_at"
        case mediaItems = "media_items"
        case viewMode = "view_mode"
    }
}

/// Stage 4.2 commit 4 — gallery presentation mode for an `.imageVideo` entry
/// with ≥2 items. Persisted on `NodeItem.viewMode`. Raw values are
/// snake_case-stable for the JSON encoding.
enum GalleryViewMode: String, Codable, Equatable {
    /// Horizontal scrollable strip. Default for entries with ≤3 items at the
    /// moment they first become multi-item.
    case carousel
    /// Tiled grid with variable-size cells. Default for entries with ≥4
    /// items at the moment they first become multi-item.
    case bento
}

extension NodeItem {
    static func text(content: String) -> NodeItem {
        NodeItem(
            id: UUID().uuidString,
            type: .text,
            createdAt: Date(),
            content: content
        )
    }

    static func audio(itemID: String = UUID().uuidString, file: String, transcript: String, duration: Double) -> NodeItem {
        NodeItem(
            id: itemID,
            type: .audio,
            createdAt: Date(),
            file: file,
            transcript: transcript,
            durationSeconds: duration
        )
    }
}

/// Stage 4.2 — single media item inside an `.imageVideo` entry. Each item is
/// persisted as a sidecar at `nodes/<nodeID>/items/<GalleryItem.id>.<ext>`;
/// the file path computation uses `GalleryItem.id`, not the parent
/// `NodeItem.id`, so a single entry can hold multiple files without
/// collision. On migration from a v1 image/video entry, `GalleryItem.id` is
/// set equal to the parent `NodeItem.id` so the existing sidecar file at
/// `items/<entryID>.<ext>` stays reachable without renaming; items appended
/// to an entry post-4.2 get fresh UUIDs.
struct GalleryItem: Codable, Identifiable, Equatable {
    /// Image vs video. Per-item so a single entry can interleave both.
    enum MediaType: String, Codable, Equatable {
        case image
        case video
    }

    let id: String
    let mediaType: MediaType
    let file: String
    /// Width divided by height of the underlying asset. Nil until the
    /// renderer measures the loaded asset and persists back so that the
    /// bento layout can size tiles without first loading every image.
    var aspectRatio: Double?
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, file
        case mediaType = "media_type"
        case aspectRatio = "aspect_ratio"
        case capturedAt = "captured_at"
    }
}
