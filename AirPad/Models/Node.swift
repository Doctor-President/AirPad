import Foundation

struct Node: Codable, Identifiable, Equatable {
    let id: String
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var summary: String
    var tags: [String]
    var mood: String?
    var isMeta: Bool
    var provenance: [String]?
    var threads: [String]
    var location: NodeLocation?
    var items: [NodeItem]
    var domain: String?
    var domainConfirmed: Bool
    var needsAIProcessing: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, summary, tags, mood, provenance, threads, location, items, domain
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isMeta = "is_meta"
        case domainConfirmed = "domain_confirmed"
        case needsAIProcessing = "needs_ai_processing"
    }
}

// Decoder in extension so Swift still synthesizes the memberwise init for the struct.
extension Node {
    // Custom decoder for backward compatibility — new fields default gracefully.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = try c.decode(String.self,    forKey: .id)
        createdAt         = try c.decode(Date.self,      forKey: .createdAt)
        updatedAt         = try c.decode(Date.self,      forKey: .updatedAt)
        title             = try c.decode(String.self,    forKey: .title)
        summary           = try c.decode(String.self,    forKey: .summary)
        tags              = try c.decode([String].self,  forKey: .tags)
        mood              = try c.decodeIfPresent(String.self,    forKey: .mood)
        isMeta            = try c.decode(Bool.self,      forKey: .isMeta)
        provenance        = try c.decodeIfPresent([String].self,  forKey: .provenance)
        threads           = try c.decode([String].self,  forKey: .threads)
        location          = try c.decodeIfPresent(NodeLocation.self, forKey: .location)
        items             = try c.decode([NodeItem].self, forKey: .items)
        domain            = try c.decodeIfPresent(String.self,    forKey: .domain)
        domainConfirmed   = try c.decodeIfPresent(Bool.self,      forKey: .domainConfirmed) ?? false
        // Existing nodes were processed before this field existed — default false.
        // Share extension nodes are saved with true explicitly.
        needsAIProcessing = try c.decodeIfPresent(Bool.self,      forKey: .needsAIProcessing) ?? false
    }
}

struct NodeLocation: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}
