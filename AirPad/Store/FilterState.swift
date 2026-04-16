import Foundation

enum ViewMode: String, Codable {
    case graph, list
}

enum SortOrder: String, Codable {
    case recency, thematic
}

enum ItemTypeFilter: String, Codable, CaseIterable {
    case all, voice, photo, video, text, link, document

    var displayName: String {
        switch self {
        case .all:      return "All"
        case .voice:    return "Voice"
        case .photo:    return "Photo"
        case .video:    return "Video"
        case .text:     return "Text"
        case .link:     return "Link"
        case .document: return "Document"
        }
    }

    var icon: String {
        switch self {
        case .all:      return "square.grid.2x2"
        case .voice:    return "mic"
        case .photo:    return "photo"
        case .video:    return "video"
        case .text:     return "doc.text"
        case .link:     return "link"
        case .document: return "doc"
        }
    }
}

enum ThreadStatusFilter: String, Codable, CaseIterable {
    case all, threadsOnly, pulledOnly

    var displayName: String {
        switch self {
        case .all:         return "All"
        case .threadsOnly: return "Threads"
        case .pulledOnly:  return "Pulled"
        }
    }
}

struct FilterState: Codable {
    var viewMode: ViewMode = .graph
    var sortOrder: SortOrder = .recency
    var itemType: ItemTypeFilter = .all
    var tagName: String? = nil
    var threadStatus: ThreadStatusFilter = .all

    var activeFilterCount: Int {
        var n = 0
        if sortOrder != .recency        { n += 1 }
        if itemType != .all             { n += 1 }
        if tagName != nil               { n += 1 }
        if threadStatus != .all         { n += 1 }
        return n
    }

    private static let udKey = "com.airpad.filterState"

    static func load() -> FilterState {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let state = try? JSONDecoder().decode(FilterState.self, from: data)
        else { return FilterState() }
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: FilterState.udKey)
        }
    }
}
