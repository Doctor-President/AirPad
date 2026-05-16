import Foundation

struct NodeItem: Codable, Identifiable, Equatable {
    let id: String
    let type: NodeItemType
    let createdAt: Date

    // text
    var content: String?

    // image, audio, video
    var file: String?

    // image
    var description: String?

    // audio, video
    var transcript: String?
    var durationSeconds: Double?

    // link
    var url: String?
    var title: String?
    var preview: String?

    // Stage 3.1a — entry primitive. Four fields added additively so legacy
    // `node.json` files decode cleanly via `decodeIfPresent`. The per-node
    // `Node.entrySchemaVersion` bump and `migrateEntrySchemaIfNeeded` populate
    // these on first open under 3.1a; thereafter they are always present on
    // disk. The `NodeItem` → `NodeEntry` rename is deferred to commit (b)
    // alongside the EntryCard UI shift.

    /// Future seat for specialized types (e.g. "ingredients", "recipeSteps").
    /// Always nil in 3.1a; reserved so the schema doesn't need another
    /// migration when specialized types arrive.
    var specializedType: String?

    /// User-editable display name shown in the entry card's title row.
    /// Populated by migration from `type.defaultDisplayName` + sequential
    /// numbering scoped to the node. Optional in the schema so legacy JSON
    /// decodes; always non-nil after migration runs.
    var displayName: String?

    /// Collapsed/expanded state for the entry card. Defaults true (expanded)
    /// on migration and on new entries. Persists across app restarts so a
    /// user's deliberate collapse survives.
    var isExpanded: Bool?

    /// Last-edit timestamp. Optional in 3.1a (the legacy schema only had
    /// `createdAt`); migration backfills to `createdAt` for legacy items.
    /// Live edits in commit (b) onward will bump this.
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, type, content, file, description, transcript, url, title, preview
        case createdAt = "created_at"
        case durationSeconds = "duration_seconds"
        case specializedType = "specialized_type"
        case displayName = "display_name"
        case isExpanded = "is_expanded"
        case updatedAt = "updated_at"
    }
}

extension NodeItem {
    static func text(content: String) -> NodeItem {
        NodeItem(
            id: UUID().uuidString,
            type: .text,
            createdAt: Date(),
            content: content
        )
    }

    static func audio(itemID: String = UUID().uuidString, file: String, transcript: String, duration: Double) -> NodeItem {
        NodeItem(
            id: itemID,
            type: .audio,
            createdAt: Date(),
            file: file,
            transcript: transcript,
            durationSeconds: duration
        )
    }
}
