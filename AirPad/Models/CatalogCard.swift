import Foundation

/// ws-card-catalog step 2a — per-node catalog sidecar (`nodes/<id>/card.json`).
///
/// One struct, two projections: the sidecar stores only card-OWNED data. Title,
/// tags, and folksonomy are NOT duplicated here — they project from `Node` at
/// render time. The embedded card text is GIST ONLY (D2/V4 finding: the gist
/// alone separates best; adding title/tags scaffolding compresses the space).
///
/// Derived + regenerable: like the block-embedding sidecar it lives inside the
/// node directory, so `deleteNode` (which removes the whole dir) auto-cleans it.
struct CatalogCard: Codable {
    /// Owning node. Not a duplicate of card data — the join key back to `Node`.
    let nodeID: String
    /// The embedded card text (gist-only). Source of the `embedding` vector.
    var gist: String
    /// Authorship of `gist`: `.model` when FM-authored, `.user` when edited.
    var gistSource: TagSource
    /// SHA256 of `extractNodeContent` output — the freshness key. When the node's
    /// content hash drifts from this, the card is stale and needs a re-embed.
    var contentHash: String
    /// Card-text format version. Bump when the projection that builds `gist`
    /// changes so stale cards can be found. Starts at 1.
    var cardTextVersion: Int
    /// Embedder/call-shape version. 0 = not embedded yet. Mirrors
    /// `CardEmbeddingService.currentEmbeddingVersion` when `embedding` is fresh.
    var embeddingVersion: Int
    /// 384-dim BGE-micro-v2 mean-pooled, L2-normalized vector. Nil until embedded.
    var embedding: [Float]?
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Reserved V2 (all optional + decodeIfPresent, nil today)
    //
    // These land in later steps (annotations, interpretive edges, contradiction
    // detection, thread membership, an interpretive embedding lens). Declared now
    // so the sidecar schema is forward-stable — legacy `card.json` decodes with
    // these absent (synthesized Codable treats optionals as decodeIfPresent).

    var annotations: [String]? = nil
    var edges: [CardEdge]? = nil
    var contradictionFlags: [String]? = nil
    var threadIDs: [String]? = nil
    var interpretiveEmbedding: [Float]? = nil

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case gist
        case gistSource = "gist_source"
        case contentHash = "content_hash"
        case cardTextVersion = "card_text_version"
        case embeddingVersion = "embedding_version"
        case embedding
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case annotations
        case edges
        case contradictionFlags = "contradiction_flags"
        case threadIDs = "thread_ids"
        case interpretiveEmbedding = "interpretive_embedding"
    }
}

/// ws-card-catalog step 2a — reserved V2 interpretive edge between cards. Not
/// written today; defined so `CatalogCard.edges` has a concrete element type.
struct CardEdge: Codable {
    let id: String
    let targetNodeID: String
    /// Free-form edge kind (e.g. "supports", "contradicts", "elaborates").
    var kind: String
    var note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case targetNodeID = "target_node_id"
        case kind
        case note
    }
}
