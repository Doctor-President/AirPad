import Foundation

/// What slice of the corpus a canvas surface is rendering.
///
/// Introduced in the Canvas Chrome + Collection Canvas arc (A1) so a single
/// `CanvasView` / `NodeListView` can render either the full corpus or the
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
}
