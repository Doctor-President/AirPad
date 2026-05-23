import Foundation

/// Dashboard C1 stub — a named grouping of nodes surfaced on the dashboard.
///
/// Named `NodeCollection` rather than `Collection` to avoid shadowing the
/// standard-library `Swift.Collection` protocol.
///
/// The Corpus collection is implicit (every node belongs to it) and is rendered
/// distinctly from user collections. Journal is a system collection seeded on
/// first launch (C2+); for C1 it lives in the sample dataset alongside Corpus.
///
/// `nodeCount` and `lastEntryAt` are surface values for the row label; in C2+
/// they will be derived from `CorpusStore.nodes` and per-collection membership
/// (whose storage shape is still open — `Node.collectionIDs` vs a separate
/// index). For C1 the values are hardcoded in `NodeCollection.sample`.
struct NodeCollection: Identifiable, Equatable {
    let id: String
    var name: String
    var nodeCount: Int
    var lastEntryAt: Date?
    var isCorpus: Bool
    var isJournal: Bool

    static let corpusID = "_corpus"
    static let journalID = "_journal"
}

extension NodeCollection {
    /// Hardcoded sample dataset for Dashboard C1. Replaced in C2+ by a derived
    /// list off `CorpusStore`.
    static func sample(now: Date = Date()) -> [NodeCollection] {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        let day: TimeInterval = 24 * hour
        return [
            NodeCollection(
                id: corpusID,
                name: "Corpus",
                nodeCount: 142,
                lastEntryAt: now.addingTimeInterval(-12 * minute),
                isCorpus: true,
                isJournal: false
            ),
            NodeCollection(
                id: journalID,
                name: "Journal",
                nodeCount: 8,
                lastEntryAt: now.addingTimeInterval(-3 * hour),
                isCorpus: false,
                isJournal: true
            ),
            NodeCollection(
                id: "field-notes",
                name: "Field Notes",
                nodeCount: 23,
                lastEntryAt: now.addingTimeInterval(-1 * day),
                isCorpus: false,
                isJournal: false
            ),
            NodeCollection(
                id: "reading",
                name: "Reading",
                nodeCount: 47,
                lastEntryAt: now.addingTimeInterval(-2 * day),
                isCorpus: false,
                isJournal: false
            ),
            NodeCollection(
                id: "studio",
                name: "Studio",
                nodeCount: 11,
                lastEntryAt: now.addingTimeInterval(-5 * day),
                isCorpus: false,
                isJournal: false
            ),
        ]
    }
}
