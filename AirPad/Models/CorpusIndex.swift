import Foundation

// MARK: - Tag provenance (mirrors Node.TagSource)
// Defined in Node.swift — referenced here for clarity only.
// TagSource: user | model | promoted

// MARK: - Tag index entry

struct TagIndexEntry: Codable {
    let name: String
    var usageCount: Int
    var origin: TagSource
    var coOccurrence: [TagRelation]
    var semanticSimilarity: [TagRelation]
    /// Reserved for SB127 (conceptual tag similarity). Schema slot only in
    /// SB126 Stage 1; populated by a later track. Holding the slot now means
    /// adding labeled similarity later does not require a JSON migration.
    var similarityKind: String? = nil
    /// SB126 Stage 3 — deterministic lift-based similar tags for tags with
    /// `usage_count >= 5`. Cold-start tags (`usage_count < 5`) hold FM-derived
    /// entries from `computeTagSimilarity` until usage crosses the threshold,
    /// at which point lift takes over. Per-tag cap of 5; lift floor of 1.5
    /// and pair-count floor of 3 applied at compute time.
    var topSimilarTags: [TagSimilarity] = []

    enum CodingKeys: String, CodingKey {
        case name
        case usageCount = "usage_count"
        case origin
        case coOccurrence = "co_occurrence"
        case semanticSimilarity = "semantic_similarity"
        case similarityKind = "similarity_kind"
        case topSimilarTags = "top_similar_tags"
    }
}

extension TagIndexEntry {
    /// Backwards-compatible decoder. Pre-SB126-Stage-3 corpus_index.json files
    /// lack `top_similar_tags`; default to empty so the next refresh can
    /// populate via lift (or cold-start FM for usage_count < 5 tags).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        usageCount = try c.decode(Int.self, forKey: .usageCount)
        origin = try c.decode(TagSource.self, forKey: .origin)
        coOccurrence = try c.decode([TagRelation].self, forKey: .coOccurrence)
        semanticSimilarity = try c.decode([TagRelation].self, forKey: .semanticSimilarity)
        similarityKind = try c.decodeIfPresent(String.self, forKey: .similarityKind)
        topSimilarTags = try c.decodeIfPresent([TagSimilarity].self, forKey: .topSimilarTags) ?? []
    }
}

struct TagRelation: Codable {
    let tag: String
    /// For `semanticSimilarity` entries this carries a similarity score in [0, 1].
    /// For `co_occurrence` entries this carries an integer count cast to Double.
    let score: Double
}

/// SB126 Stage 3 — per-pair similarity entry. Populated deterministically via
/// lift for established tags; via FM cold-start for tags with usage_count < 5.
/// `similarityKind` is reserved for SB127 labeled similarity (always nil in v1).
struct TagSimilarity: Codable, Hashable {
    let tagID: String
    let lift: Double
    let similarityKind: String?

    enum CodingKeys: String, CodingKey {
        case tagID = "tag_id"
        case lift
        case similarityKind = "similarity_kind"
    }
}

// MARK: - Neighborhood registry entry

struct NeighborhoodIndexEntry: Codable {
    let id: String
    var name: String
    var memberCount: Int
    var dominantTags: [String]
    /// Sorted node IDs that belong to this neighborhood. Persisted so the next
    /// run's Louvain output can be Jaccard-matched against this set to keep
    /// cluster identity stable across launches (AT21 Cat A).
    var members: [String]
    var centroid: IndexPoint
    var cohesionScore: Double
    var hue: Double  // HSL hue value 0.0-360.0, assigned at neighborhood creation
    /// 1-2 sentence summary produced by the nameNeighborhood Call A
    /// characterize step. Carried forward across refreshes; regenerated only
    /// when the SB126 Stage 1 trigger rule fires.
    var description: String
    /// Sentence embedding of `description` via NLEmbedding. ~512 floats.
    /// Consumed by SB126 Stage 2's processNode prefilter.
    var descriptionEmbedding: [Float]
    /// 8 representative member node IDs (3 central, 3 seeded-random, 2 recent).
    /// Refreshed when the trigger rule fires; otherwise carried forward.
    var sampledMemberIDs: [String]
    /// SB126 Stage 2 — backoff counter for Call A nil returns. Increments each
    /// time `characterizeNeighborhood` returns nil for this cluster; resets to
    /// 0 on a successful Call A or when `dominantTags` shifts enough to retry.
    /// Once `>= 3` AND `descriptionEmbedding.isEmpty`, the trigger rule stops
    /// firing the chain for this cluster (Tech/Work-style permanently generic
    /// clusters that the FM keeps declining to characterize).
    var descriptionAttempts: Int

    enum CodingKeys: String, CodingKey {
        case id, name, hue, members, description
        case memberCount = "member_count"
        case dominantTags = "dominant_tags"
        case centroid
        case cohesionScore = "cohesion_score"
        case descriptionEmbedding = "description_embedding"
        case sampledMemberIDs = "sampled_member_ids"
        case descriptionAttempts = "description_attempts"
    }
}

extension NeighborhoodIndexEntry {
    /// Backwards-compatible decoder. Pre-AT21 entries have no `members` field;
    /// pre-SB126 Stage 1 entries lack `description`, `description_embedding`,
    /// and `sampled_member_ids`; pre-Stage-2 entries lack `description_attempts`.
    /// Each decodes to a default; the next refresh repopulates as needed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        memberCount = try c.decode(Int.self, forKey: .memberCount)
        dominantTags = try c.decode([String].self, forKey: .dominantTags)
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
        centroid = try c.decode(IndexPoint.self, forKey: .centroid)
        cohesionScore = try c.decode(Double.self, forKey: .cohesionScore)
        hue = try c.decode(Double.self, forKey: .hue)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        descriptionEmbedding = try c.decodeIfPresent([Float].self, forKey: .descriptionEmbedding) ?? []
        sampledMemberIDs = try c.decodeIfPresent([String].self, forKey: .sampledMemberIDs) ?? []
        descriptionAttempts = try c.decodeIfPresent(Int.self, forKey: .descriptionAttempts) ?? 0
    }
}

struct IndexPoint: Codable {
    let x: Double
    let y: Double
}

// MARK: - Corpus summary (Layer 3 — populated by AIService in Session C)

struct CorpusSummary: Codable {
    var nodeCount: Int
    var tagCount: Int
    var neighborhoodCount: Int
    var dominantThemes: [String]
    var recentDominantTags: [String]
    var anomalies: CorpusAnomalies
    var summaryText: String
    var generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case nodeCount = "node_count"
        case tagCount = "tag_count"
        case neighborhoodCount = "neighborhood_count"
        case dominantThemes = "dominant_themes"
        case recentDominantTags = "recent_dominant_tags"
        case anomalies
        case summaryText = "summary_text"
        case generatedAt = "generated_at"
    }
}

struct CorpusAnomalies: Codable {
    var staleTags: [String]       // tags not appearing in 30+ days
    var floaterNodeIDs: [String]  // nodes not fitting any neighborhood

    enum CodingKeys: String, CodingKey {
        case staleTags = "stale_tags"
        case floaterNodeIDs = "floater_node_ids"
    }
}

// MARK: - Root index

struct CorpusIndex: Codable {
    let version: Int
    var updatedAt: Date
    var tags: [String: TagIndexEntry]
    var neighborhoods: [String: NeighborhoodIndexEntry]
    var summary: CorpusSummary?

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case tags
        case neighborhoods
        case summary
    }

    static func empty() -> CorpusIndex {
        CorpusIndex(
            version: 1,
            updatedAt: Date(),
            tags: [:],
            neighborhoods: [:],
            summary: nil
        )
    }
}
