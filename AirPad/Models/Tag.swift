import Foundation

struct Tag: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colorHex: String    // e.g. "#FF6B35"
    var createdAt: Date
    var useCount: Int
    /// Tag-anchored Map v1 — user designation promoting this corpus tag to a
    /// spatial territory on the canvas (≤12 active; see
    /// `CorpusStore.maxCanvasAnchors`). The system NEVER designates anchors —
    /// only the user. Additive + migration-safe: legacy tags (no key) decode
    /// as `false` via the custom decoder below.
    var isCanvasAnchor: Bool = false

    static let neutralColorHex = "#8E8E93"

    init(id: UUID, name: String, colorHex: String, createdAt: Date,
         useCount: Int, isCanvasAnchor: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.useCount = useCount
        self.isCanvasAnchor = isCanvasAnchor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        useCount = try c.decode(Int.self, forKey: .useCount)
        isCanvasAnchor = try c.decodeIfPresent(Bool.self, forKey: .isCanvasAnchor) ?? false
    }
}

// Context passed to TagCreationSheet when AI suggests tags not yet in vocabulary.
struct TagSuggestionContext: Identifiable, Equatable {
    let id = UUID()
    let nodeID: String
    let newTagNames: [String]       // AI-suggested names that don't exist yet — need color assignment
    let existingTagNames: [String]  // AI-suggested names already in vocabulary — applied immediately
}
