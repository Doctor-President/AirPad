import Foundation

/// Dashboard collection — a named grouping of nodes surfaced on the dashboard.
///
/// Named `NodeCollection` rather than `Collection` to avoid shadowing the
/// standard-library `Swift.Collection` protocol.
///
/// **Persistence vs display.** Only `id` and `name` are encoded to JSON.
/// `nodeCount` and `lastEntryAt` are derived at render time by the Dashboard
/// from `CorpusStore.nodes` filtered by membership (`Node.collectionIDs`); they
/// reset to defaults on decode and never round-trip through disk.
///
/// **Corpus and Journal are virtual.** Both are computed from the reserved IDs
/// `_corpus` and `_journal`. Neither is persisted in the user-collections list;
/// the dashboard prepends them as virtual rows at render time. `isCorpus` /
/// `isJournal` are computed from the id so callers never need to keep flags in
/// sync.
struct NodeCollection: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var nodeCount: Int
    var lastEntryAt: Date?

    static let corpusID = "_corpus"
    static let journalID = "_journal"

    var isCorpus: Bool { id == Self.corpusID }
    var isJournal: Bool { id == Self.journalID }
    var isSystem: Bool { isCorpus || isJournal }

    init(id: String, name: String, nodeCount: Int = 0, lastEntryAt: Date? = nil) {
        self.id = id
        self.name = name
        self.nodeCount = nodeCount
        self.lastEntryAt = lastEntryAt
    }

    enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.nodeCount = 0
        self.lastEntryAt = nil
    }
}

extension NodeCollection {
    /// Stage 4 c4.4 — translates a pill-rail selection into the Node fields
    /// that get stamped on capture. Journal writes a start-of-day
    /// `journalDate` (the membership rule the dashboard uses); user
    /// collections go into `collectionIDs`; nil leaves the node loose
    /// (Corpus-only). Centralized so every capture surface stays in sync.
    struct CaptureStamp {
        let collectionIDs: [String]
        let journalDate: Date?
    }

    static func captureStamp(forCollectionID id: String?) -> CaptureStamp {
        guard let id else {
            return CaptureStamp(collectionIDs: [], journalDate: nil)
        }
        if id == journalID {
            return CaptureStamp(
                collectionIDs: [],
                journalDate: Calendar.current.startOfDay(for: Date())
            )
        }
        return CaptureStamp(collectionIDs: [id], journalDate: nil)
    }

    /// SwiftUI-preview helper only. Production dashboard derives rows from
    /// `CorpusStore.collections` plus virtual Corpus/Journal entries.
    static func sample(now: Date = Date()) -> [NodeCollection] {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        let day: TimeInterval = 24 * hour
        return [
            NodeCollection(
                id: corpusID,
                name: "Corpus",
                nodeCount: 142,
                lastEntryAt: now.addingTimeInterval(-12 * minute)
            ),
            NodeCollection(
                id: journalID,
                name: "Journal",
                nodeCount: 8,
                lastEntryAt: now.addingTimeInterval(-3 * hour)
            ),
            NodeCollection(
                id: "field-notes",
                name: "Field Notes",
                nodeCount: 23,
                lastEntryAt: now.addingTimeInterval(-1 * day)
            ),
            NodeCollection(
                id: "reading",
                name: "Reading",
                nodeCount: 47,
                lastEntryAt: now.addingTimeInterval(-2 * day)
            ),
            NodeCollection(
                id: "studio",
                name: "Studio",
                nodeCount: 11,
                lastEntryAt: now.addingTimeInterval(-5 * day)
            ),
        ]
    }
}
