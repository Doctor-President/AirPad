import SwiftUI

/// Dashboard Stage 3 — scoped collection canvas (Canvas Chrome arc D1).
///
/// Rendered as a top-level surface via `AppRouter.entryMode =
/// .collectionCanvas(id:)` (Canvas Chrome arc D1c). Earlier D1 drafts
/// pushed this view onto the dashboard's NavigationStack, but the
/// resulting nested NavigationStack (dashboard's outer + CanvasView's
/// inner one for NodeDetailView pushes) tripped SwiftUI's missing-
/// destination placeholder. Routing through `AppRouter` keeps
/// CanvasChrome / CanvasView at the top of the view hierarchy, and back-
/// chevron returns to dashboard via the same router rather than a stack
/// pop.
///
/// The screen mounts `CanvasChrome(scope: .collection(id))` — graph /
/// list / menus operate on the collection's membership (see
/// `CorpusStore.nodes(in:)`, `visibleNodes(in:)`, `filterState(for:)`).
///
/// The floating "+" lives inside CanvasView / NodeListView (the surfaces
/// CanvasChrome switches between), so this wrapper just hosts the chrome
/// and bumps recency on appear. The "+" inside those views reads `scope`
/// to pin the in-app capture overlay to this collection.
struct CollectionView: View {

    let collectionID: String

    @Environment(CorpusStore.self) private var store

    var body: some View {
        CanvasChrome(scope: .collection(collectionID))
            .onAppear {
                store.markCollectionUsed(collectionID)
            }
    }
}

#Preview {
    CollectionView(collectionID: NodeCollection.sample()[2].id)
}
