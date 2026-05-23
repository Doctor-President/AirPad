import SwiftUI

/// Dashboard C2 — stub scoped collection view.
///
/// Pushed onto the dashboard's NavigationStack when a user-collection row is
/// tapped. Renders the collection name as the title, a placeholder empty-state
/// body, and relies on the navigation stack's default back chevron for return.
///
/// Real membership (which nodes belong to this collection) lands in a separate
/// arc — see `ws-collections.md` (to be filed). Until then, every collection
/// view shows the same "no nodes yet" placeholder. The Corpus row deliberately
/// bypasses this view and routes to canvas instead (see `DashboardView.tap`).
struct CollectionView: View {

    let collection: NodeCollection

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "tray")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.white.opacity(0.35))
                Text("No nodes yet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Membership wiring lands in a later stage.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

#Preview {
    NavigationStack {
        CollectionView(collection: NodeCollection.sample()[2])
    }
}
