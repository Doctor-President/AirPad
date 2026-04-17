import Foundation

struct Node: Codable, Identifiable, Hashable {
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
    /// Import breadcrumb. Format: "import-<ISO8601 timestamp>". Nil for organically captured nodes.
    var source: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, tags, mood, provenance, threads, location, items, domain, source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isMeta = "is_meta"
        case domainConfirmed = "domain_confirmed"
        case needsAIProcessing = "needs_ai_processing"
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
        mood: String? = nil,
        isMeta: Bool = false,
        provenance: [String]? = nil,
        threads: [String] = [],
        location: NodeLocation? = nil,
        items: [NodeItem] = [],
        domain: String? = nil,
        domainConfirmed: Bool = false,
        needsAIProcessing: Bool = false,
        source: String? = nil
    ) {
        self.id                = id
        self.createdAt         = createdAt
        self.updatedAt         = updatedAt
        self.title             = title
        self.summary           = summary
        self.tags              = tags
        self.mood              = mood
        self.isMeta            = isMeta
        self.provenance        = provenance
        self.threads           = threads
        self.location          = location
        self.items             = items
        self.domain            = domain
        self.domainConfirmed   = domainConfirmed
        self.needsAIProcessing = needsAIProcessing
        self.source            = source
    }
}

// Decoder in extension so the explicit memberwise init above is the designated init.
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
        needsAIProcessing = try c.decodeIfPresent(Bool.self,      forKey: .needsAIProcessing) ?? false
        source            = try c.decodeIfPresent(String.self,    forKey: .source)
    }
}

struct NodeLocation: Codable, Equatable {
    let latitude: Double
    let longitude: Double
}
