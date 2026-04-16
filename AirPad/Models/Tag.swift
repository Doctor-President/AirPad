import Foundation

struct Tag: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colorHex: String    // e.g. "#FF6B35"
    var createdAt: Date
    var useCount: Int

    static let neutralColorHex = "#8E8E93"
}

// Context passed to TagCreationSheet when AI suggests tags not yet in vocabulary.
struct TagSuggestionContext: Identifiable {
    let id = UUID()
    let nodeID: String
    let newTagNames: [String]       // AI-suggested names that don't exist yet — need color assignment
    let existingTagNames: [String]  // AI-suggested names already in vocabulary — applied immediately
}
