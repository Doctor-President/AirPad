import Foundation
import CoreGraphics

enum TagSource: String, Codable {
    case user
    case model
    case promoted  // model-generated, explicitly accepted by user
}

/// Per-tag provenance carried on a Node. Modeled as a struct (not a bare
/// `TagSource`) so future SB128 fields like `attributeOrigin`,
/// `extractionSource`, and `confidence` can land alongside `source` without a
/// JSON migration. Today only `source` is populated.
struct TagOrigin: Codable {
    var source: TagSource

    init(source: TagSource) {
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case source
    }
}

/// SB139 Stage 1 cleanup — diagnostic detail for `fm_error` nodes. Captures
/// what `processSubstrate` actually saw so we can tune the textual
/// guardrail-vs-other-error classifier against observed strings instead of
/// strings inferred from the harness logs. Populated only when
/// `embeddingFailureReason == "fm_error"`; nil in every other state.
struct FMErrorDetail: Codable, Hashable {
    /// The Swift type / case path of the error, e.g.
    /// `"GenerationError.refusal"` or `"FoundationModels.LanguageModelSession.GenerationError"`.
    /// Tells us *what kind* of error this is.
    var errorType: String
    /// The Context.debugDescription if the error was a typed
    /// `LanguageModelSession.GenerationError` (parsed from the stringified
    /// error so we don't bet on case names that may not exist in this SDK).
    /// Tells us *what specifically* the error said.
    var debugDescription: String?

    enum CodingKeys: String, CodingKey {
        case errorType = "error_type"
        case debugDescription = "debug_description"
    }
}

extension TagOrigin {
    /// Backwards-compatible decoder. Accepts either the legacy bare-string form
    /// (`"Recipe": "user"`) or the typed-struct form (`{"source": "user"}`).
    /// Encoding always emits the struct form, so legacy node JSONs are
    /// rewritten in place on the next save.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let bare = try? single.decode(TagSource.self) {
            self.source = bare
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decode(TagSource.self, forKey: .source)
    }
}

/// #7 (hero-crop v2) — crop adjustment for a node's hero banner, stored as
/// NORMALIZED fractions of the rendered image so it survives any frame size or
/// aspect ratio. Supersedes the v1 `heroOffset` (absolute points, which didn't
/// translate across frames); v1 values do NOT migrate — a precise conversion
/// needs the image's rendered size (unavailable at decode) and the old points
/// were frame-specific, so an existing v1 hero recenters (see `Node`'s decode).
///
/// TYPED (schema-foresight) so future crop controls — `zoom` / `scale`, an
/// explicit `focalPoint`, or per-surface overrides — can be added as additive,
/// decode-tolerant fields with NO further migration.
/// #7 (BUG 24) — how the hero image sits inside its zone. `fill` (default) is
/// the shipped `scaledToFill` cover cropped by `offset`; `fullHeight` shows the
/// WHOLE image (`scaledToFit`) — the detail hero grows its zone to the image's
/// natural height (capped), the card / grid tiles letterbox it inside their
/// FIXED zone. NODE-owned per ws-templates (template owns the zone, node owns
/// the fit). Additive: the matte / blur-fill / letterbox variants can arrive
/// later as new cases with no migration.
enum HeroFit: String, Codable, Hashable {
    case fill
    case fullHeight
}

struct HeroCrop: Codable, Hashable {
    /// Pan offset as a FRACTION of the rendered image's width / height. `.zero`
    /// = the centered crop (default). Roughly ±0.5; clamped to the actual image
    /// overflow at render so it can never expose an edge. Only meaningful in
    /// `.fill` — `.fullHeight` shows the whole image, so there is no overflow to pan.
    var offset: CGPoint
    /// BUG 24 — fill (crop) vs fullHeight (whole image). Additive; legacy nodes
    /// (and any encode without this key) decode as `.fill`.
    var fit: HeroFit

    init(offset: CGPoint = .zero, fit: HeroFit = .fill) {
        self.offset = offset
        self.fit = fit
    }

    enum CodingKeys: String, CodingKey {
        case offset, fit
    }
}

extension HeroCrop {
    /// Decode-tolerant (codebase norm — see `Node` / `FilterState`): future
    /// additive fields decode as their defaults rather than throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        offset = try c.decodeIfPresent(CGPoint.self, forKey: .offset) ?? offset
        fit = try c.decodeIfPresent(HeroFit.self, forKey: .fit) ?? fit
    }

    // MARK: - Crop → points geometry (ONE source for every surface)
    //
    // The hero banner (detail), the card tile, and the grid tile all crop a
    // `scaledToFill` cover the same way; keeping the math here means the framing
    // can't drift between the surface you dial it on and the ones that show it.

    /// The clamped POINT offset to apply to a `scaledToFill` image of
    /// `imageAspect` (w/h) inside a `width`×`height` frame, given a NORMALIZED
    /// offset (fraction of the rendered image). `extraTranslation` (points) is
    /// added before clamping — the detail-view drag passes the live finger
    /// delta; display surfaces pass `.zero`. Clamped to the overflow so a pan
    /// can never expose an edge.
    static func clampedPointOffset(normalizedOffset: CGPoint,
                                   imageAspect aspect: CGFloat,
                                   width: CGFloat,
                                   height: CGFloat,
                                   extraTranslation: CGSize = .zero) -> CGPoint {
        let s = max(width / max(aspect, 0.01), height)   // fill scale (unit-height image)
        let scaledW = aspect * s
        let scaledH = s
        let overflowX = max(0, (scaledW - width) / 2)
        let overflowY = max(0, (scaledH - height) / 2)
        let px = normalizedOffset.x * scaledW + extraTranslation.width
        let py = normalizedOffset.y * scaledH + extraTranslation.height
        return CGPoint(x: min(max(px, -overflowX), overflowX),
                       y: min(max(py, -overflowY), overflowY))
    }

    /// Inverse of `clampedPointOffset`: convert a committed POINT offset back to
    /// a normalized fraction, for persisting a drag.
    static func normalize(pointOffset: CGPoint,
                          imageAspect aspect: CGFloat,
                          width: CGFloat,
                          height: CGFloat) -> CGPoint {
        let s = max(width / max(aspect, 0.01), height)
        let scaledW = aspect * s
        let scaledH = s
        return CGPoint(x: scaledW > 0 ? pointOffset.x / scaledW : 0,
                       y: scaledH > 0 ? pointOffset.y / scaledH : 0)
    }
}

/// Membership in the Dashboard "Priority" working set (`nil` on `Node` = not
/// prioritized). `order` is the explicit manual position (lower = higher in the
/// list) so the Collections-reorder idiom can reassign it; `addedAt` is the
/// fallback sort and a record of when the node was prioritized. Additive +
/// decode-tolerant, per `HeroCrop` — not a bare Bool, so ordering has somewhere
/// to live without a later schema change.
struct PriorityState: Codable, Hashable {
    var addedAt: Date
    var order: Int

    init(addedAt: Date = Date(), order: Int = 0) {
        self.addedAt = addedAt
        self.order = order
    }

    enum CodingKeys: String, CodingKey {
        case addedAt = "added_at"
        case order
    }
}

extension PriorityState {
    /// Decode-tolerant (codebase norm): additive fields decode as defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? addedAt
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? order
    }
}

struct Node: Codable, Identifiable, Hashable {
    let id: String
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var summary: String
    var tags: [String]
    var tagSources: [String: TagOrigin]
    var mood: String?
    var isMeta: Bool
    var provenance: [String]?
    var threads: [String]
    var location: NodeLocation?
    var items: [NodeItem]
    var domain: String?
    var domainConfirmed: Bool
    var needsAIProcessing: Bool
    /// Router flag: system isn't confident this belongs in corpus, user should confirm.
    var needsReview: Bool
    /// Dashboard Stage 2 — start-of-day marker for journal nodes. Non-nil
    /// indicates this is the journal node for that day; lookup key for the
    /// dashboard's "today's journal" find-or-create. Optional + decodeIfPresent
    /// in the custom decoder means existing nodes silently decode as `nil` —
    /// no schema-version bump required.
    var journalDate: Date?
    /// Durable identity for THE day's journal entry, distinct from Journal-
    /// *collection* membership (which is `journalDate` alone). Set true only when
    /// `findOrCreateTodayJournalNode` creates the day's entry; a note merely filed
    /// into the Journal collection has `journalDate` but `isJournalEntry == false`,
    /// so it no longer hijacks the "What's on your mind today" prompt. Additive,
    /// decode-tolerant (`?? false`) — same pattern as `foldIndex`/`titleSource`;
    /// no migration (no historical node has it; the next tap creates today's).
    var isJournalEntry: Bool
    /// Dashboard Stage 3 — IDs of user collections this node belongs to.
    /// Corpus is implicit (every node) and Journal is derived from
    /// `journalDate`, so neither appears in this array. Stored as a plain
    /// `[String]` for ergonomic call sites (no optional unwrap on read);
    /// `decodeIfPresent ?? []` on the decoder side means legacy nodes
    /// silently decode as empty — no schema-version bump required.
    var collectionIDs: [String]
    /// Backlinks v1 — user-asserted relational edges (see `NodeConnection`).
    /// Durable, bidirectional (both endpoint nodes carry the edge, sharing an
    /// `id`), independent of substrate similarity. **The system NEVER
    /// auto-writes this** — only explicit user actions (drawing a backlink,
    /// accepting a suggestion) mutate it. `decodeIfPresent ?? []` means legacy
    /// nodes decode as empty — no schema-version bump (mirrors `collectionIDs`).
    var connections: [NodeConnection]
    /// Import breadcrumb. Format: "import-<ISO8601 timestamp>". Nil for organically captured nodes.
    var source: String?
    /// SB126 Stage 2 — `NLEmbedding.sentenceEmbedding(for: .english)` of the
    /// node's content. Computed lazily during the corpus-aware `processNode`
    /// path; consumed by the deterministic neighborhood prefilter. Nil for
    /// nodes captured before Stage 2 or when content was unavailable.
    var contentEmbedding: [Float]?
    /// SB126 Stage 2 — neighborhood ID the FM judged most relevant during the
    /// corpus-aware tagging call. Stored for downstream consumption (a future
    /// SB may surface or auto-assign), not read in Stage 2 itself.
    var fmSuggestedNeighborhoodID: String?

    // MARK: - SB139 substrate (Stage 1)
    //
    // Parallel to the tag pipeline. The substrate's "summary" and "content
    // embedding" are NOT the same artifacts as the existing `summary` field
    // (tag pipeline) and `contentEmbedding` (NLEmbedding sentenceEmbedding).
    // These come from a dedicated substrate FM call and `NLContextualEmbedding`
    // respectively, named distinctly so the two embedding spaces stay
    // separable: NLEmbedding for SB137 isolate routing, NLContextualEmbedding
    // for SB139 substrate. Vectors are stored RAW; mean-centering is applied
    // at read time by `SubstrateService` against the cached corpus mean.

    /// FM-generated summary from the substrate prompt. Distinct from the
    /// tag-pipeline `summary` above; this one is purpose-built for embedding.
    /// Nil before substrate runs, on guardrail refusal, or for thin content.
    var substrateSummary: String?
    /// FM-generated free-form folksonomy tags. Joined comma-space before
    /// embedding. Empty/nil on guardrail refusal or thin content.
    var folksonomy: [String]?
    /// `NLContextualEmbedding(.english)` mean-pooled vector of `substrateSummary`.
    /// Stored raw; mean-center via `SubstrateService` before cosine.
    var summaryEmbedding: [Float]?
    /// Embedding of the comma-space folksonomy phrase. Stored raw.
    var folksonomyEmbedding: [Float]?
    /// Embedding of the node's extracted content. Used as the fallback channel
    /// when summary or folksonomy are missing (guardrail refusal). Stored raw.
    var contextualContentEmbedding: [Float]?
    /// Substrate embedder/call-shape version. 0 = substrate never processed
    /// this node. 1 = `NLContextualEmbedding(.english)` mean-pooled, summary +
    /// folksonomy via `processSubstrate`. Bump when the embedder or call
    /// shape changes so backfills can find stale vectors.
    var embeddingVersion: Int
    /// Nil on success. Populated when substrate processing reached a known
    /// dead end: `guardrail_refused`, `thin_content`, `fm_error` (FM call
    /// non-guardrail failure — content embedding may still be present),
    /// `embedder_error` (`NLContextualEmbedding` load failure — no vectors).
    var embeddingFailureReason: String?
    /// Diagnostic-only sidecar populated when `embeddingFailureReason ==
    /// "fm_error"`. Captures the raw error type and debug description so we
    /// can tune the guardrail-vs-other classifier against observed strings.
    /// Cleared on every other outcome (success, guardrail, thin, embedder).
    var fmErrorDetail: FMErrorDetail?

    // MARK: - SB139 Stage 4 substrate layout
    //
    // Coord and version land at 4a. Cluster identity (`substrateClusterID`,
    // membership stability, FM-derived label) lands at 4b. Canvas read-side
    // continues to use the tag-driven LayoutService until the 4c1 flag flip.

    /// SB139 Stage 4a — UMAP-projected 2D coordinate for the canvas substrate
    /// layout. Nil before the layout has been fit or for nodes captured after
    /// the last fit (project-through-saved-model fills these on next refresh
    /// cycle). Stored independently of the canvas read path; populated only
    /// when `FeatureFlags.substrateLayout` is on.
    var substrateCoord2D: SubstrateCoord2D?
    /// SB139 Stage 4a — UMAP fit version this coord was produced under. 0 =
    /// never projected. Bumps on every full re-fit. Matches the
    /// `UMAPFittedModel.fitVersion` that was active when the coord was
    /// computed so we can detect coords stale against the saved model.
    var substrateLayoutVersion: Int

    /// Stage 3.1a — entry-primitive schema version for `items`. 0 = legacy
    /// flat-item schema (pre-3.1a); 1 = items carry `displayName`,
    /// `isExpanded`, `updatedAt`, `specializedType`. Bumped by
    /// `migrateEntrySchemaIfNeeded` on first open under 3.1a. Per-node lazy
    /// migration; the corpus is never bulk-walked at launch.
    var entrySchemaVersion: Int

    /// Stored boundary within `items` separating card-visible entries
    /// (indices `0..<foldIndex`) from below-fold entries (`foldIndex..<count`).
    ///
    /// **`nil` = AUTO** (fold-auto-default): the card renders atomics, then
    /// payload in order, as many as fit (`NodeCardView.fitPayloads`). This is
    /// the app's authorship rule (decisions.md 2026-07-06): the system fills
    /// empty fields, never overwrites authored ones — an unauthored fold is an
    /// invitation, and the ••• "Show/Remove from card" action is what authors
    /// it. **Non-nil = user-authored**, honored exactly. Read through
    /// `effectiveFoldIndex` (nil → all payload eligible); index-shifting
    /// mutations preserve nil. Decode-tolerant (`decodeIfPresent`, foresight
    /// rule 2026-06-14); legacy `fold_index: 0` migrates to nil (see decode).
    var foldIndex: Int?

    /// Fold boundary resolved for READS: `nil` (AUTO) → `items.count`, so all
    /// payload is eligible and `NodeCardView.fitPayloads` shows as-many-as-fit;
    /// authored values pass through unchanged. Mutations that shift indices keep
    /// `foldIndex` itself optional (they don't materialize AUTO).
    var effectiveFoldIndex: Int { foldIndex ?? items.count }

    /// entry-system-and-fold Commit 6 — visibility flag for whether the
    /// node's `summary` renders on the card-view surface. Pure
    /// presentation: the FM pipeline never reads or writes it; only the
    /// user toggles via the detail-view `•••` menu. Default `true` so
    /// legacy nodes (and freshly captured ones) show the description on
    /// the card. The card-view surface (queue #10) is the consumer; the
    /// detail view always renders the summary regardless of this flag.
    /// Additive; legacy nodes decode as `true` via `?? true`, no
    /// schema-version bump — same precedent as `foldIndex ?? 0`.
    var descriptionOnCard: Bool

    /// entry-system-and-fold Commit 6 — authorship provenance for
    /// `summary`. Mirrors `primaryTag`'s user-beats-model logic: when
    /// `.user`, the FM pipeline must leave `summary` alone (including a
    /// deliberately empty value); when `nil` or `.model`, the FM may
    /// rewrite and stamp `.model`. User-driven edits in
    /// `NodeDetailView.saveIfChanged` stamp `.user`. Orthogonal to
    /// `descriptionOnCard` — text ownership and visibility are
    /// independent concerns. Legacy nodes decode as `nil` (FM eligible
    /// on next run); the first FM write stamps `.model`.
    var summarySource: TagSource?

    /// ws-card-catalog step 1 — authorship provenance for `title`, mirroring
    /// `summarySource` exactly. When `.user`, `processNodeWithAI` must leave the
    /// title alone; when `nil` (legacy / never-processed) or `.model`, the FM may
    /// rewrite and stamp `.model`. User-driven edits in
    /// `NodeDetailView.saveIfChanged` stamp `.user`. Legacy nodes decode as `nil`
    /// (FM eligible on next run); additive, no schema-version bump.
    var titleSource: TagSource?

    /// hero-image v1 — relative path (`items/<id>.<ext>`) of the image
    /// the user picked as this node's hero banner, or `nil` when the
    /// hero falls back to the morphing gradient. Same handle the rest
    /// of the storage layer uses; resolved through
    /// `service.resolveItemPath(nodeID:, relativePath:)`. Additive;
    /// legacy nodes decode as `nil` via `?? nil`, same precedent as
    /// `summarySource` — no schema-version bump.
    var coverImageRelativePath: String?

    /// #7 (hero-crop v2) — normalized crop adjustment for the hero banner
    /// (`nil` = centered default). See `HeroCrop`. Additive + decode-tolerant;
    /// no schema-version bump. Replaces the v1 `hero_offset` (absolute points):
    /// that key is no longer decoded, so an existing v1 hero recenters and the
    /// stale key is dropped on the next save — a deliberate reset, not a
    /// migration (v1 points can't be converted without the image + frame).
    var heroCrop: HeroCrop?

    /// OCR / analysis of a DIRECTLY-PICKED hero image — one with no corresponding
    /// gallery item (heroes set FROM a gallery item are OCR'd via that item's
    /// `GalleryItem.analysis`). Reuses the SAME `ImageAnalysis` struct as gallery
    /// items and is populated by the SAME reconciler. Optional + decode-tolerant,
    /// absent on existing nodes, no migration. See `directlyPickedHeroPath`.
    var heroAnalysis: ImageAnalysis?

    /// The hero's relative path IFF the hero is a directly-picked image with NO
    /// corresponding gallery item — the only case that needs its own OCR and its
    /// own search row. `nil` when there's no hero, or when the hero IS one of this
    /// node's gallery items (that image is already OCR'd via its
    /// `GalleryItem.analysis` and searchable through it, so a separate hero row
    /// would double-count). This single check DEDUPES at the source — the
    /// reconciler and Instant Search both consult it.
    var directlyPickedHeroPath: String? {
        guard let path = coverImageRelativePath else { return nil }
        let isGalleryFile = items.contains { item in
            (item.mediaItems ?? []).contains { $0.file == path }
        }
        return isGalleryFile ? nil : path
    }

    /// Dashboard "Priority" working set membership (`nil` = not prioritized).
    /// See `PriorityState`. Additive + decode-tolerant; no schema-version bump.
    var priority: PriorityState?

    /// THE LEVER — Stage 1. Model-authored proposals for this node's
    /// user-owned fields (title / summary / tags), recorded ALONGSIDE the
    /// existing write. One `Proposal` per kind at most (a regeneration
    /// replaces the prior of that kind). See `Proposal`. Model-authored
    /// derived output living on the node — the established pattern here
    /// (`substrateSummary`, `folksonomy`, the four `[Float]` embeddings) —
    /// not a sidecar. Additive + decode-tolerant; legacy nodes decode as
    /// `nil` (no `proposals` key), no schema-version bump — the `heroCrop` /
    /// `priority` pattern.
    var proposals: [Proposal]?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, tags, mood, provenance, threads, location, items, domain, source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isMeta = "is_meta"
        case domainConfirmed = "domain_confirmed"
        case needsAIProcessing = "needs_ai_processing"
        case needsReview = "needs_review"
        case journalDate = "journal_date"
        case isJournalEntry = "is_journal_entry"
        case collectionIDs = "collection_ids"
        case connections
        case tagSources = "tag_sources"
        case contentEmbedding = "content_embedding"
        case fmSuggestedNeighborhoodID = "fm_suggested_neighborhood_id"
        case substrateSummary = "substrate_summary"
        case folksonomy
        case summaryEmbedding = "summary_embedding"
        case folksonomyEmbedding = "folksonomy_embedding"
        case contextualContentEmbedding = "contextual_content_embedding"
        case embeddingVersion = "embedding_version"
        case embeddingFailureReason = "embedding_failure_reason"
        case fmErrorDetail = "fm_error_detail"
        case substrateCoord2D = "substrate_coord_2d"
        case substrateLayoutVersion = "substrate_layout_version"
        case entrySchemaVersion = "entry_schema_version"
        case foldIndex = "fold_index"
        case descriptionOnCard = "description_on_card"
        case summarySource = "summary_source"
        case titleSource = "title_source"
        case coverImageRelativePath = "cover_image_relative_path"
        case heroCrop = "hero_crop"
        case heroAnalysis = "hero_analysis"
        case priority
        case proposals
    }

    // ID-based equality so Hashable synthesis doesn't require all properties to be Hashable.
    static func == (lhs: Node, rhs: Node) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Explicit memberwise init with defaults for optional fields.
    init(
        id: String,
        createdAt: Date,
        updatedAt: Date,
        title: String,
        summary: String,
        tags: [String],
        tagSources: [String: TagOrigin] = [:],
        mood: String? = nil,
        isMeta: Bool = false,
        provenance: [String]? = nil,
        threads: [String] = [],
        location: NodeLocation? = nil,
        items: [NodeItem] = [],
        domain: String? = nil,
        domainConfirmed: Bool = false,
        needsAIProcessing: Bool = false,
        needsReview: Bool = false,
        journalDate: Date? = nil,
        isJournalEntry: Bool = false,
        collectionIDs: [String] = [],
        connections: [NodeConnection] = [],
        source: String? = nil,
        contentEmbedding: [Float]? = nil,
        fmSuggestedNeighborhoodID: String? = nil,
        substrateSummary: String? = nil,
        folksonomy: [String]? = nil,
        summaryEmbedding: [Float]? = nil,
        folksonomyEmbedding: [Float]? = nil,
        contextualContentEmbedding: [Float]? = nil,
        embeddingVersion: Int = 0,
        embeddingFailureReason: String? = nil,
        fmErrorDetail: FMErrorDetail? = nil,
        substrateCoord2D: SubstrateCoord2D? = nil,
        substrateLayoutVersion: Int = 0,
        entrySchemaVersion: Int = 0,
        foldIndex: Int? = nil,
        descriptionOnCard: Bool = true,
        summarySource: TagSource? = nil,
        titleSource: TagSource? = nil,
        coverImageRelativePath: String? = nil,
        heroCrop: HeroCrop? = nil,
        heroAnalysis: ImageAnalysis? = nil,
        priority: PriorityState? = nil,
        proposals: [Proposal]? = nil
    ) {
        self.id                          = id
        self.createdAt                   = createdAt
        self.updatedAt                   = updatedAt
        self.title                       = title
        self.summary                     = summary
        self.tags                        = tags
        self.tagSources                  = tagSources
        self.mood                        = mood
        self.isMeta                      = isMeta
        self.provenance                  = provenance
        self.threads                     = threads
        self.location                    = location
        self.items                       = items
        self.domain                      = domain
        self.domainConfirmed             = domainConfirmed
        self.needsAIProcessing           = needsAIProcessing
        self.needsReview                 = needsReview
        self.journalDate                 = journalDate
        self.isJournalEntry              = isJournalEntry
        self.collectionIDs               = collectionIDs
        self.connections                 = connections
        self.source                      = source
        self.contentEmbedding            = contentEmbedding
        self.fmSuggestedNeighborhoodID   = fmSuggestedNeighborhoodID
        self.substrateSummary            = substrateSummary
        self.folksonomy                  = folksonomy
        self.summaryEmbedding            = summaryEmbedding
        self.folksonomyEmbedding         = folksonomyEmbedding
        self.contextualContentEmbedding  = contextualContentEmbedding
        self.embeddingVersion            = embeddingVersion
        self.embeddingFailureReason      = embeddingFailureReason
        self.fmErrorDetail               = fmErrorDetail
        self.substrateCoord2D            = substrateCoord2D
        self.substrateLayoutVersion      = substrateLayoutVersion
        self.entrySchemaVersion          = entrySchemaVersion
        self.foldIndex                   = foldIndex
        self.descriptionOnCard           = descriptionOnCard
        self.summarySource               = summarySource
        self.titleSource                 = titleSource
        self.coverImageRelativePath      = coverImageRelativePath
        self.heroCrop                    = heroCrop
        self.heroAnalysis                = heroAnalysis
        self.priority                    = priority
        self.proposals                   = proposals
    }
}

// Decoder in extension so the explicit memberwise init above is the designated init.
extension Node {
    // Custom decoder for backward compatibility — new fields default gracefully.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                        = try c.decode(String.self,    forKey: .id)
        createdAt                 = try c.decode(Date.self,      forKey: .createdAt)
        updatedAt                 = try c.decode(Date.self,      forKey: .updatedAt)
        title                     = try c.decode(String.self,    forKey: .title)
        summary                   = try c.decode(String.self,    forKey: .summary)
        tags                      = try c.decode([String].self,  forKey: .tags)
        tagSources                = try c.decodeIfPresent([String: TagOrigin].self, forKey: .tagSources) ?? [:]
        mood                      = try c.decodeIfPresent(String.self,    forKey: .mood)
        isMeta                    = try c.decode(Bool.self,      forKey: .isMeta)
        provenance                = try c.decodeIfPresent([String].self,  forKey: .provenance)
        threads                   = try c.decode([String].self,  forKey: .threads)
        location                  = try c.decodeIfPresent(NodeLocation.self, forKey: .location)
        items                     = try c.decode([NodeItem].self, forKey: .items)
        domain                    = try c.decodeIfPresent(String.self,    forKey: .domain)
        domainConfirmed           = try c.decodeIfPresent(Bool.self,      forKey: .domainConfirmed) ?? false
        needsAIProcessing         = try c.decodeIfPresent(Bool.self,      forKey: .needsAIProcessing) ?? false
        needsReview               = try c.decodeIfPresent(Bool.self,      forKey: .needsReview) ?? false
        journalDate               = try c.decodeIfPresent(Date.self,      forKey: .journalDate)
        isJournalEntry            = try c.decodeIfPresent(Bool.self,      forKey: .isJournalEntry) ?? false
        collectionIDs             = try c.decodeIfPresent([String].self,  forKey: .collectionIDs) ?? []
        connections               = try c.decodeIfPresent([NodeConnection].self, forKey: .connections) ?? []
        source                    = try c.decodeIfPresent(String.self,    forKey: .source)
        contentEmbedding          = try c.decodeIfPresent([Float].self,   forKey: .contentEmbedding)
        fmSuggestedNeighborhoodID = try c.decodeIfPresent(String.self,    forKey: .fmSuggestedNeighborhoodID)
        substrateSummary           = try c.decodeIfPresent(String.self,   forKey: .substrateSummary)
        folksonomy                 = try c.decodeIfPresent([String].self, forKey: .folksonomy)
        summaryEmbedding           = try c.decodeIfPresent([Float].self,  forKey: .summaryEmbedding)
        folksonomyEmbedding        = try c.decodeIfPresent([Float].self,  forKey: .folksonomyEmbedding)
        contextualContentEmbedding = try c.decodeIfPresent([Float].self,  forKey: .contextualContentEmbedding)
        embeddingVersion           = try c.decodeIfPresent(Int.self,      forKey: .embeddingVersion) ?? 0
        embeddingFailureReason     = try c.decodeIfPresent(String.self,   forKey: .embeddingFailureReason)
        fmErrorDetail              = try c.decodeIfPresent(FMErrorDetail.self, forKey: .fmErrorDetail)
        substrateCoord2D           = try c.decodeIfPresent(SubstrateCoord2D.self, forKey: .substrateCoord2D)
        substrateLayoutVersion     = try c.decodeIfPresent(Int.self,      forKey: .substrateLayoutVersion) ?? 0
        entrySchemaVersion         = try c.decodeIfPresent(Int.self,      forKey: .entrySchemaVersion) ?? 0
        // fold-auto-default — migrate legacy `fold_index: 0` (and absent) to
        // nil = AUTO. A stored 0 meant "authored empty" under the old scheme,
        // which now reads as sparse. T's call (pre-V1, one user): treat ALL 0s
        // as nil; don't build the untouched-vs-deliberately-cleared distinction
        // (0 is also reachable via "Remove from card" on an atomic-less node,
        // so the two are indistinguishable on disk anyway).
        let rawFoldIndex           = try c.decodeIfPresent(Int.self,      forKey: .foldIndex)
        foldIndex                  = (rawFoldIndex == 0) ? nil : rawFoldIndex
        descriptionOnCard          = try c.decodeIfPresent(Bool.self,     forKey: .descriptionOnCard) ?? true
        summarySource              = try c.decodeIfPresent(TagSource.self, forKey: .summarySource)
        titleSource                = try c.decodeIfPresent(TagSource.self, forKey: .titleSource)
        coverImageRelativePath     = try c.decodeIfPresent(String.self,   forKey: .coverImageRelativePath) ?? nil
        heroCrop                   = try c.decodeIfPresent(HeroCrop.self,  forKey: .heroCrop)
        heroAnalysis               = try c.decodeIfPresent(ImageAnalysis.self, forKey: .heroAnalysis) ?? nil
        priority                   = try c.decodeIfPresent(PriorityState.self, forKey: .priority)
        proposals                  = try c.decodeIfPresent([Proposal].self, forKey: .proposals)
    }
}

extension Node {
    /// Source of truth for color identity across all surfaces (canvas, list card,
    /// detail view, focal overlay). User-assigned tags beat FM-assigned tags so the
    /// node's identity follows the user's intent when the model and user disagree.
    var primaryTag: String? {
        if let userTag = tags.first(where: { tagSources[$0]?.source == .user }) {
            return userTag
        }
        return tags.first
    }
}

struct NodeLocation: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}
