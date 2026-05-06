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
    /// Import breadcrumb. Format: "import-<ISO8601 timestamp>". Nil for organically captured nodes.
    var source: String?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, tags, mood, provenance, threads, location, items, domain, source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isMeta = "is_meta"
        case domainConfirmed = "domain_confirmed"
        case needsAIProcessing = "needs_ai_processing"
        case needsReview = "needs_review"
        case tagSources = "tag_sources"
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
        source: String? = nil
    ) {
        self.id                = id
        self.createdAt         = createdAt
        self.updatedAt         = updatedAt
        self.title             = title
        self.summary           = summary
        self.tags              = tags
        self.tagSources        = tagSources
        self.mood              = mood
        self.isMeta            = isMeta
        self.provenance        = provenance
        self.threads           = threads
        self.location          = location
        self.items             = items
        self.domain            = domain
        self.domainConfirmed   = domainConfirmed
        self.needsAIProcessing = needsAIProcessing
        self.needsReview       = needsReview
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
        tagSources        = try c.decodeIfPresent([String: TagOrigin].self, forKey: .tagSources) ?? [:]
        mood              = try c.decodeIfPresent(String.self,    forKey: .mood)
        isMeta            = try c.decode(Bool.self,      forKey: .isMeta)
        provenance        = try c.decodeIfPresent([String].self,  forKey: .provenance)
        threads           = try c.decode([String].self,  forKey: .threads)
        location          = try c.decodeIfPresent(NodeLocation.self, forKey: .location)
        items             = try c.decode([NodeItem].self, forKey: .items)
        domain            = try c.decodeIfPresent(String.self,    forKey: .domain)
        domainConfirmed   = try c.decodeIfPresent(Bool.self,      forKey: .domainConfirmed) ?? false
        needsAIProcessing = try c.decodeIfPresent(Bool.self,      forKey: .needsAIProcessing) ?? false
        needsReview       = try c.decodeIfPresent(Bool.self,      forKey: .needsReview) ?? false
        source            = try c.decodeIfPresent(String.self,    forKey: .source)
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
