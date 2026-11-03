import Foundation

/// 1.1-C (C1) — what the app and the share extension share through the App Group (`group.com.doctorpresident.airpad`).
/// The extension can't open the Library (it lives in iCloud), so the app leaves it a small index of entry names to pick
/// "Existing entry" from, and two settings. The extension never writes the Library: it stages inbox records the app
/// applies (`node.json` = a new entry, `append.json` = items for an existing one).
enum ShareShared {
    static let appGroupID = "group.com.doctorpresident.airpad"
    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) }

    /// Settings → Share sheet → "Quick save": the share icon saves at once ("Saved!"), the 1.0 behaviour. Off by default.
    static let quickSaveKey = "share.quickSave"
    /// A mirror of Settings → Require Face ID (`AppLock.enabledKey` lives in the app's own defaults).
    static let requireFaceIDKey = "share.requireFaceID"

    static var quickSave: Bool {
        get { defaults?.bool(forKey: quickSaveKey) ?? false }
        set { defaults?.set(newValue, forKey: quickSaveKey) }
    }
    static var requireFaceID: Bool {
        get { defaults?.bool(forKey: requireFaceIDKey) ?? false }
        set { defaults?.set(newValue, forKey: requireFaceIDKey) }
    }

    static var indexURL: URL? { container?.appendingPathComponent("AirPad/share-index.json") }
}

/// The entry list the share sheet's "Existing entry" picks from: the user's own entries (not the Sample Library),
/// newest first, names only. Private entries carry their flag; the sheet leaves them out unless unlocked.
struct ShareIndex: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let updatedAt: Date
        let isPrivate: Bool
    }
    var entries: [Entry]

    static let limit = 2000

    static func load() -> ShareIndex? {
        guard let url = ShareShared.indexURL, let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(ShareIndex.self, from: data)
    }

    func save() {
        guard let url = ShareShared.indexURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(self) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The list as the sheet shows it: private entries only when unlocked; `query` matches words in the name.
    func visible(query: String, showPrivate: Bool) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { (showPrivate || !$0.isPrivate) && (q.isEmpty || $0.title.lowercased().contains(q)) }
    }
}

/// An inbox record that adds items to an existing entry (`inbox/<id>/append.json` + `items/`).
struct ShareAppendRecord: Codable {
    static let fileName = "append.json"
    let target: String
    let items: [NodeItem]
}
