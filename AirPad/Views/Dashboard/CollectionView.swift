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
/// Floating "+" stays outside the chrome and routes to QuikCapture with
/// `forcedCollectionID = id` so captures land in this collection without
/// the pill rail needing to be touched (c4.7). `markCollectionUsed` on
/// appear bumps recency so the pill rail's ordering reflects collections
/// the user actually visits.
struct CollectionView: View {

    let collectionID: String

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack {
            CanvasChrome(scope: .collection(collectionID))
            floatingPlusButton
        }
        .onAppear {
            store.markCollectionUsed(collectionID)
        }
    }

    // MARK: - Floating "+"

    private var floatingPlusButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    router.entryMode = .quikCapture(
                        forcedCollectionID: collectionID,
                        origin: .dashboard
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 60, height: 60)
                        .background(Color.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
                .padding(.bottom, 28)
            }
        }
    }
}

#Preview {
    CollectionView(collectionID: NodeCollection.sample()[2].id)
}
