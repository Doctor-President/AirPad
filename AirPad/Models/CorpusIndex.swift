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

    enum CodingKeys: String, CodingKey {
        case name
        case usageCount = "usage_count"
        case origin
        case coOccurrence = "co_occurrence"
        case semanticSimilarity = "semantic_similarity"
    }
}

struct TagRelation: Codable {
    let tag: String
    let score: Double
}

// MARK: - Neighborhood registry entry

struct NeighborhoodIndexEntry: Codable {
    let id: String
    var name: String
    var memberCount: Int
    var dominantTags: [String]
    var centroid: IndexPoint
    var cohesionScore: Double
    var hue: Double  // HSL hue value 0.0-360.0, assigned at neighborhood creation

    enum CodingKeys: String, CodingKey {
        case id, name, hue
        case memberCount = "member_count"
        case dominantTags = "dominant_tags"
        case centroid
        case cohesionScore = "cohesion_score"
    }
}

struct IndexPoint: Codable {
    let x: Double
    let y: Double
}

// MARK: - Node relatedness entry

struct NodeRelatednessEntry: Codable {
    let nodeID: String
    var related: [NodeRelation]
    var computedAt: Date

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case related
        case computedAt = "computed_at"
    }
}

struct NodeRelation: Codable {
    let nodeID: String
    let score: Double

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case score
    }
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
    var relatedness: [String: NodeRelatednessEntry]
    var summary: CorpusSummary?

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case tags
        case neighborhoods
        case relatedness
        case summary
    }

    static func empty() -> CorpusIndex {
        CorpusIndex(
            version: 1,
            updatedAt: Date(),
            tags: [:],
            neighborhoods: [:],
            relatedness: [:],
            summary: nil
        )
    }
}
