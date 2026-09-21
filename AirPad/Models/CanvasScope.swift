import Foundation

/// What slice of the corpus a canvas surface is rendering.
///
/// Introduced in the Canvas Chrome + Collection Canvas arc (A1) so a single
/// `CanvasView` / `VerticalScrollView` can render either the full corpus or the
/// members of a specific collection without forking the view tree. The
/// `CorpusStore` exposes scope-aware accessors (`nodes(in:)`,
/// `filteredNodes(in:)`, `visibleNodes(in:)`) that resolve membership.
///
/// `.corpus` returns the full node set (existing behavior).
/// `.collection(id)` returns scope-specific membership: the journal slice
/// when `id == NodeCollection.journalID`, otherwise user-collection
/// membership via `Node.collectionIDs`.
enum CanvasScope: Hashable, Sendable {
    case corpus
    case collection(String)
    /// Brief U — an arbitrary set of node ids (the seeded sample library's nodes).
    /// Renders through the same canvas pipeline as a collection but has no
    /// collection identity: it never marks a collection "used" (so a capture can't
    /// default into it) and carries no rename/delete chrome.
    case nodeIDs(Set<String>)
}

extension CanvasScope {
    /// Stable string key for dict-keying and persistence. Reuses the
    /// `NodeCollection` reserved IDs so per-scope storage (e.g. the per-
    /// scope `FilterState` dict added in A2) keys cleanly onto the same
    /// id space the rest of the app uses.
    var key: String {
        switch self {
        case .corpus:                 return NodeCollection.corpusID
        case .collection(let id):     return id
        case .nodeIDs:                return NodeCollection.sampleScopeID
        }
    }
}
