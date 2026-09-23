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

/// Brief AJ4 / build K — the PURE core of a room-scoped tag edit. "Tags follow the
/// room, SEALED" (T, 2026-09-23): an edit in the USER room touches ONLY the user's
/// entries; a Sample Library entry is never modified. Kept pure (no store, no I/O) so
/// `CorpusStore` and the `-TagCrudDiag` self-test share ONE decision path — and so the
/// test can exercise it on a FIXTURE CLONE without any risk to a real container.
enum TagRoomEdit {
    /// Remove `name` from every USER entry (sample entries untouched). `keepVocabulary`
    /// is true when a SAMPLE entry still carries the name (the Tag object must stay for
    /// the sample); false → the caller removes the Tag + dissolves its territory.
    static func delete(tagName name: String, from nodes: [Node], sampleIDs: Set<String>)
        -> (nodes: [Node], changedUserIDs: [String], keepVocabulary: Bool) {
        var out = nodes
        var changed: [String] = []
        for i in out.indices where !sampleIDs.contains(out[i].id) && out[i].tags.contains(name) {
            out[i].tags.removeAll { $0 == name }
            out[i].tagSources[name] = nil
            changed.append(out[i].id)
        }
        let keepVocabulary = out.contains { sampleIDs.contains($0.id) && $0.tags.contains(name) }
        return (out, changed, keepVocabulary)
    }

    /// Re-tag every USER entry `old` → `new` (sample entries untouched). `shared` is
    /// true when a SAMPLE entry still carries `old` → the caller SPLITS (new Tag for the
    /// user, old Tag kept for the sample); false → the caller renames the Tag in place.
    static func rename(old: String, to new: String, in nodes: [Node], sampleIDs: Set<String>)
        -> (nodes: [Node], changedUserIDs: [String], shared: Bool) {
        var out = nodes
        var changed: [String] = []
        for i in out.indices where !sampleIDs.contains(out[i].id) && out[i].tags.contains(old) {
            out[i].tags = out[i].tags.map { $0 == old ? new : $0 }
            if let s = out[i].tagSources[old] { out[i].tagSources[new] = s; out[i].tagSources[old] = nil }
            changed.append(out[i].id)
        }
        let shared = out.contains { sampleIDs.contains($0.id) && $0.tags.contains(old) }
        return (out, changed, shared)
    }
}

// Context passed to TagCreationSheet when AI suggests tags not yet in vocabulary.
struct TagSuggestionContext: Identifiable, Equatable {
    let id = UUID()
    let nodeID: String
    let newTagNames: [String]       // AI-suggested names that don't exist yet — need color assignment
    let existingTagNames: [String]  // AI-suggested names already in vocabulary — applied immediately
}
