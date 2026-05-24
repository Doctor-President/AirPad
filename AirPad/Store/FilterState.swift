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

    fileprivate static let legacyUDKey = "com.airpad.filterState"

    /// Legacy single-global loader. Kept for the one-time migration path
    /// in `FilterStates.load`; new persistence runs through `FilterStates`
    /// (per-scope dict) — see A2 of the Canvas Chrome arc.
    static func load() -> FilterState {
        guard let data = UserDefaults.standard.data(forKey: legacyUDKey),
              let state = try? JSONDecoder().decode(FilterState.self, from: data)
        else { return FilterState() }
        return state
    }
}

// MARK: - Per-scope persistence (Canvas Chrome arc, A2)

/// Storage for per-scope `FilterState`, keyed by `CanvasScope.key`. Each
/// canvas surface (corpus + every collection canvas) has its own persisted
/// view-mode / sort / filter state — confirmed during A2 scoping as a real
/// user preference. Persisted as a single JSON dict under one UserDefaults
/// key so save is O(1) regardless of how many collections exist.
enum FilterStates {
    fileprivate static let udKey = "com.airpad.filterStates"

    static func load() -> [String: FilterState] {
        if let data = UserDefaults.standard.data(forKey: udKey),
           let dict = try? JSONDecoder().decode([String: FilterState].self, from: data) {
            return dict
        }
        // First launch after A2: migrate the legacy single-global value into
        // the corpus-scope slot so users keep their existing preferences. The
        // legacy key is left in UserDefaults — harmless and a safety net if
        // we ever need to roll back.
        let legacy = FilterState.load()
        return [NodeCollection.corpusID: legacy]
    }

    static func save(_ states: [String: FilterState]) {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
    }
}
