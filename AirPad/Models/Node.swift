import Foundation

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

    enum CodingKeys: String, CodingKey {
        case id, title, summary, tags, mood, provenance, threads, location, items, domain, source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isMeta = "is_meta"
        case domainConfirmed = "domain_confirmed"
        case needsAIProcessing = "needs_ai_processing"
        case needsReview = "needs_review"
        case journalDate = "journal_date"
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
        entrySchemaVersion: Int = 0
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
