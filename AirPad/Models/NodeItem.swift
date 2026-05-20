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

    // Stage 4.5 — ordered link list backing a `.link` entry. Populated by
    // `migrateEntrySchemaV2ToV3` for legacy single-link entries (one-element
    // array; `LinkItem.id` matches the parent `NodeItem.id` on migration so
    // the existing OG-image sidecar stays reachable without file moves) and
    // by the append flow shipping in commit 2 for multi-link entries. The
    // legacy `url` / `title` / `preview` / `og*` fields stay populated as a
    // diagnostic breadcrumb and for v1/v2 read-side compatibility. Nil on
    // every non-link entry; nil on `.link` entries that have never had a
    // URL committed (the State A TextField path in `OGPreviewView`
    // continues to drive URL entry, and commit 2 will route the first URL
    // commit through a store method that lifts the URL into `linkItems`
    // directly). Rendering reads off this field when present and falls
    // back to the legacy `url` field otherwise.
    var linkItems: [LinkItem]?

    // Stage 4.5 — per-entry link-gallery view-mode persistence. Mirrors
    // `viewMode` for the media gallery (`.imageVideo`), but with its own
    // enum (`LinkViewMode = carousel | grid`) because the link gallery
    // replaces bento with a uniform 2-column grid. Three-state semantics:
    //   - nil: user has never chosen; renderer picks a count-based default
    //     (≤3 → carousel, ≥4 → grid) at the first transition with ≥2
    //     items. Single-link entries leave this nil — they render via
    //     `LinkEntryBody`, which doesn't read `linkViewMode`.
    //   - .carousel / .grid: user (or the first single→multi transition)
    //     wrote a value. The renderer honors it verbatim regardless of
    //     count; incremental adds preserve the existing choice so the
    //     user's toggle is the only thing that changes it after first
    //     transition.
    // Additive optional, no entrySchemaVersion bump on its own — the v3
    // bump is driven by `linkItems`; `linkViewMode` rides along as nil for
    // migrated entries (count is at most 1 post-migration so the count-
    // based fallback covers them).
    var linkViewMode: LinkViewMode?

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
        case linkItems = "link_items"
        case linkViewMode = "link_view_mode"
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

/// Stage 4.5 — single link inside a `.link` entry. Each item carries the
/// canonical URL plus the OG-fetched fields. Unlike `GalleryItem`, links
/// have no sidecar file as their primary asset (the URL is the asset); the
/// OG-fetched image is stored as a sidecar at
/// `nodes/<nodeID>/items/<LinkItem.id>.og.<ext>`, with `imageFile` holding
/// just the filename. The OG fields are optional because OG fetch is async
/// and may not have completed by the time the item is persisted — the
/// renderer falls back to bare-URL display while fields are nil.
///
/// On migration from a v2 single-link entry, `LinkItem.id` is set equal
/// to the parent `NodeItem.id` so the existing OG-image sidecar at
/// `items/<entryID>.og.<ext>` stays reachable without file moves — same
/// strategy `migrateEntrySchemaV1ToV2` uses for `GalleryItem.id`. Items
/// appended post-4.5 get fresh UUIDs.
struct LinkItem: Codable, Identifiable, Equatable {
    let id: String
    /// Canonical URL string. Stored as `String` (not `URL`) to match the
    /// legacy `NodeItem.url` shape and survive any edge URLs that
    /// `URL(string:)` would reject but the user nonetheless wants to keep.
    let url: String
    /// OG-fetched fields. Nil until `OGMetadataService.fetch` completes;
    /// remain nil indefinitely if the fetch fails or the page has no OG
    /// tags. `LinkGalleryTile` falls back to bare-URL display when nil.
    var title: String?
    var description: String?
    /// Filename (not URL) of the OG image sidecar at
    /// `nodes/<nodeID>/items/<LinkItem.id>.og.<ext>`. Mirrors
    /// `NodeItem.ogImageFile` conventions so the existing
    /// `iCloudDriveService.saveItemFile` path can write it without
    /// changes.
    var imageFile: String?
    var siteName: String?
    /// Stage 4.5 commit 4 — filename (not URL) of the favicon sidecar at
    /// `nodes/<nodeID>/items/<LinkItem.id>.favicon.<ext>`. Captured by
    /// the favicon scraper in `OGMetadataService` and rendered as a
    /// smaller, centered, tinted-bg fallback in `LinkGalleryTile` when
    /// `imageFile` is nil. Independent of `imageFile` — both can be
    /// populated, in which case `imageFile` wins the tile's image slot
    /// and the favicon stays on disk as a no-op until a future surface
    /// (e.g. tile menu, OG inspector) reads it.
    var faviconFile: String?
    /// Timestamp the item was added to the entry. For migrated entries,
    /// copied from the parent `NodeItem.createdAt` so the original capture
    /// moment is preserved. For appended items, the moment of append.
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, url, title, description
        case imageFile = "image_file"
        case siteName = "site_name"
        case faviconFile = "favicon_file"
        case capturedAt = "captured_at"
    }
}

/// Stage 4.5 — link-gallery presentation mode for a `.link` entry with ≥2
/// items. Persisted on `NodeItem.linkViewMode`. Raw values are
/// snake_case-stable for the JSON encoding. Distinct from
/// `GalleryViewMode` (the media gallery's enum) because the link gallery
/// replaces bento with a uniform 2-column grid — OG cards are roughly
/// uniform in shape so the aspect-aware bento packer doesn't earn its
/// keep here.
enum LinkViewMode: String, Codable, Equatable {
    /// Horizontal scrollable strip. Default for entries with ≤3 items at
    /// the moment they first become multi-link.
    case carousel
    /// 2-column rectangular grid, deterministic left-to-right top-to-
    /// bottom order. Default for entries with ≥4 items at the moment they
    /// first become multi-link.
    case grid
}
