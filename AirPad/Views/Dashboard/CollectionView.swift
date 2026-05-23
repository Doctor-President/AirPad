import SwiftUI

/// Dashboard Stage 3 — scoped collection view.
///
/// Pushed onto the dashboard's `NavigationStack` when a Journal or user-
/// collection row is tapped. (The Corpus row routes to canvas instead — see
/// `DashboardView.tap`.) Lists member nodes; tapping a row pushes
/// `NodeDetailView` via the parent stack's `navigationDestination(for:
/// Node.self)`. An empty state stands in when no members exist yet — true for
/// freshly-seeded user collections until C4 wires assignment UI.
///
/// Membership rules:
///   • Journal: nodes with `journalDate != nil`, sorted by `journalDate` desc.
///   • User collection: nodes whose `collectionIDs` contains `collection.id`,
///     sorted by `createdAt` desc.
struct CollectionView: View {

    let collection: NodeCollection

    @Environment(CorpusStore.self) private var store

    private var members: [Node] {
        if collection.isJournal {
            return store.nodes
                .filter { $0.journalDate != nil }
                .sorted { ($0.journalDate ?? .distantPast) > ($1.journalDate ?? .distantPast) }
        }
        return store.nodes
            .filter { $0.collectionIDs.contains(collection.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if members.isEmpty {
                emptyState
            } else {
                memberList
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    // MARK: - Member list

    private var memberList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(members) { node in
                    NavigationLink(value: node) {
                        NodeRow(node: node, isJournal: collection.isJournal)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
            Text("No nodes yet")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(collection.isJournal
                ? "Start a journal entry from the dashboard's Today card."
                : "Assignment lands in a later stage.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

// MARK: - Node row

/// Minimal node row matching the dashboard's CollectionRow visual language.
/// Deliberately not a `NodeCardView` — that one is the legacy list view's
/// gradient card and pulls in animation + palette layers we don't want here.
private struct NodeRow: View {
    let node: Node
    let isJournal: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.07))
        )
    }

    private var titleText: String {
        if !node.title.isEmpty { return node.title }
        if let first = node.items.first?.content, !first.isEmpty { return first }
        return "Untitled"
    }

    private var subtitleText: String {
        if isJournal, let d = node.journalDate {
            let f = DateFormatter()
            f.dateFormat = "EEEE, MMMM d"
            return f.string(from: d)
        }
        return node.relativeTimestamp
    }
}

#Preview {
    NavigationStack {
        CollectionView(collection: NodeCollection.sample()[2])
    }
}
