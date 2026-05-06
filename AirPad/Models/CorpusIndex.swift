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

    enum CodingKeys: String, CodingKey {
        case name
        case usageCount = "usage_count"
        case origin
        case coOccurrence = "co_occurrence"
        case semanticSimilarity = "semantic_similarity"
        case similarityKind = "similarity_kind"
    }
}

struct TagRelation: Codable {
    let tag: String
    /// For `semanticSimilarity` entries this carries a similarity score in [0, 1].
    /// For `co_occurrence` entries this carries an integer count cast to Double.
    let score: Double
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

    enum CodingKeys: String, CodingKey {
        case id, name, hue, members, description
        case memberCount = "member_count"
        case dominantTags = "dominant_tags"
        case centroid
        case cohesionScore = "cohesion_score"
        case descriptionEmbedding = "description_embedding"
        case sampledMemberIDs = "sampled_member_ids"
    }
}

extension NeighborhoodIndexEntry {
    /// Backwards-compatible decoder. Pre-AT21 entries have no `members` field;
    /// pre-SB126 Stage 1 entries lack `description`, `description_embedding`,
    /// and `sampled_member_ids`. Each decodes to an empty default; the next
    /// refresh that meets the trigger rule populates the three derived fields.
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
