import SwiftUI

/// Dashboard Stage 3 — scoped collection canvas (Canvas Chrome arc D1).
///
/// Pushed onto the dashboard's `NavigationStack` when a Journal or user-
/// collection row is tapped. (The Corpus row routes to canvas instead — see
/// `DashboardView.tap`.) D1 swapped the previous custom scroll-list for the
/// full `CanvasChrome` surface, scoped to `.collection(id)` so the canvas
/// graph/list/menus all operate on this collection's membership instead of
/// the whole corpus. Membership resolution + per-scope filter state live in
/// `CorpusStore` (see `nodes(in:)`, `visibleNodes(in:)`, `filterState(for:)`).
///
/// The nav bar is hidden so the chrome's top row owns the header surface;
/// the collection name will surface in chrome top row in D2.
///
/// Floating "+" stays outside the chrome and routes to QuikCapture with
/// `forcedCollectionID = collection.id` so captures land in this collection
/// without the pill rail needing to be touched (c4.7). `markCollectionUsed`
/// on appear bumps recency so the pill rail's ordering reflects collections
/// the user actually visits.
struct CollectionView: View {

    let collection: NodeCollection

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack {
            CanvasChrome(scope: .collection(collection.id))
            floatingPlusButton
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            store.markCollectionUsed(collection.id)
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
                        forcedCollectionID: collection.id,
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
    NavigationStack {
        CollectionView(collection: NodeCollection.sample()[2])
    }
}
