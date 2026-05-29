import SwiftUI

/// Dashboard — app root.
///
/// Layout (top → bottom):
///   1. Header — AirPad wordmark centered, right-aligned Inbox + Recents +
///      Settings icons. Inbox badge stub = 0 (hidden when zero).
///   2. Today section — `TodayCardView`. Journal prompt opens today's journal
///      node via `CorpusStore.findOrCreateTodayJournalNode`.
///   3. Collections section — Corpus row pinned first (visually distinct:
///      larger text, more vertical padding) and routes to canvas via entry-
///      mode flip. User-collection rows + Journal route to a scoped canvas
///      via `router.entryMode = .collectionCanvas(id:)` (Canvas Chrome arc
///      D1c — was a NavigationStack push pre-D1c, but the inner stack in
///      CanvasView/NodeListView collided with the dashboard's outer one).
///   4. Persistent floating "+" bottom-right — routes to QuikCapture with
///      `.dashboard` origin so the exit pill returns here rather than
///      suspending the app (c4.6).
struct DashboardView: View {

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store

    @State private var path = NavigationPath()
    @State private var renameTarget: NodeCollection?
    @State private var deleteTarget: NodeCollection?
    @State private var showCreateCollectionSheet = false
    @State private var showRecents = false
    @State private var showSettings = false

    /// Dashboard Stage 3 — rows are derived at render time from
    /// `CorpusStore`. Virtual Corpus + Journal rows are prepended to the
    /// persisted user collections; counts and `lastEntryAt` are computed
    /// from `Node.collectionIDs` membership (and `Node.journalDate` for the
    /// Journal row) so they stay honest as nodes are added or moved.
    private var displayedCollections: [NodeCollection] {
        let corpus = NodeCollection(
            id: NodeCollection.corpusID,
            name: "Corpus",
            nodeCount: store.nodes.count,
            lastEntryAt: store.nodes.map(\.createdAt).max()
        )
        let journalNodes = store.nodes.filter { $0.journalDate != nil }
        let journal = NodeCollection(
            id: NodeCollection.journalID,
            name: "Journal",
            nodeCount: journalNodes.count,
            lastEntryAt: journalNodes.compactMap(\.journalDate).max()
        )
        let userRows: [NodeCollection] = store.collections.map { collection in
            let members = store.nodes.filter { $0.collectionIDs.contains(collection.id) }
            var row = collection
            row.nodeCount = members.count
            row.lastEntryAt = members.map(\.createdAt).max()
            return row
        }
        return [corpus, journal] + userRows
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                            .padding(.top, 6)
                        todaySection
                        collectionsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
                }

                floatingPlusButton
            }
            .toolbar(.hidden, for: .navigationBar) // dashboard renders its own header
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
            }
            .sheet(item: $renameTarget) { collection in
                RenameCollectionSheet(collectionID: collection.id, currentName: collection.name)
            }
            .sheet(isPresented: $showCreateCollectionSheet) {
                CollectionCreationSheet { _ in }
            }
            .sheet(isPresented: $showRecents) {
                HistoryPanel(onSelect: { node in path.append(node) })
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            // In-app capture overlay handoff. The overlay (mounted at
            // ContentView) writes the picked / newly-captured node ID into
            // `router.pendingNodeNavigationID`; here we resolve it against
            // the store and push onto the dashboard's own NavigationStack.
            // Clear the field after handling so it fires exactly once.
            .onChange(of: router.pendingNodeNavigationID) { _, newValue in
                guard let id = newValue,
                      let node = store.nodes.first(where: { $0.id == id })
                else { return }
                path.append(node)
                router.pendingNodeNavigationID = nil
            }
            .confirmationDialog(
                deleteTarget.map { "Delete \"\($0.name)\"?" } ?? "Delete collection?",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { collection in
                Button("Delete", role: .destructive) {
                    Task { await store.deleteCollection(id: collection.id) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { _ in
                Text("Nodes will remain in your corpus.")
            }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Image("AirPadLogo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(height: 56)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 10) {
                Spacer()
                inboxButton
                headerIconButton(systemName: "clock.arrow.circlepath") { showRecents = true }
                headerIconButton(systemName: "gearshape.fill") { showSettings = true }
            }
        }
        .frame(height: 48)
    }

    private var inboxButton: some View {
        let badgeCount = 0
        return Button(action: {}) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color(white: 0.14))
                    .clipShape(Circle())

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, 3)
                        .background(Color.blue)
                        .clipShape(Capsule())
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func headerIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color(white: 0.14))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Today

    private var todaySection: some View {
        TodayCardView(
            recentNodes: recentNodes,
            onJournalPromptTap: openTodayJournal,
            onRecentTap: { node in path.append(node) }
        )
    }

    private var recentNodes: [Node] {
        store.nodes
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(3)
            .map { $0 }
    }

    private func openTodayJournal() {
        Task {
            if let node = await store.findOrCreateTodayJournalNode() {
                path.append(node)
            }
        }
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Collections")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.8)

            VStack(spacing: 8) {
                ForEach(displayedCollections) { collection in
                    CollectionRow(
                        collection: collection,
                        onTap: { tap(collection) },
                        onRename: canManage(collection) ? { renameTarget = collection } : nil,
                        onDelete: canDelete(collection) ? { deleteTarget = collection } : nil
                    )
                }
                NewCollectionButton { showCreateCollectionSheet = true }
            }
        }
    }

    // MARK: - Row taps

    /// Corpus row routes to the existing canvas (no scoping — Corpus is the
    /// "everything" view). User-collection rows + Journal route to a scoped
    /// canvas surface via `router.entryMode = .collectionCanvas(id:)` —
    /// nested NavigationStacks broke the push-based variant (D1c).
    private func tap(_ collection: NodeCollection) {
        if collection.isCorpus {
            router.entryMode = .canvas
        } else {
            router.entryMode = .collectionCanvas(id: collection.id)
        }
    }

    /// Rows that expose the ellipsis menu. Corpus and Journal are system
    /// surfaces — Corpus has no user-editable name; Journal rename is
    /// deferred (the "Journal" label is hardcoded across capture + dashboard
    /// + chrome surfaces, so renaming it is its own arc).
    private func canManage(_ collection: NodeCollection) -> Bool {
        !collection.isSystem
    }

    /// Rows that expose the Delete entry inside the ellipsis menu. Same as
    /// `canManage` today since Journal has no ellipsis at all — kept as a
    /// distinct predicate so the row code doesn't need to relearn the
    /// reasoning if Journal gains rename later.
    private func canDelete(_ collection: NodeCollection) -> Bool {
        !collection.isSystem
    }

    // MARK: - Floating "+"

    private var floatingPlusButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    router.captureOverlay = CaptureOverlayContext(scope: .corpus)
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

// MARK: - Collection row

private struct CollectionRow: View {
    let collection: NodeCollection
    let onTap: () -> Void
    /// Nil → no ellipsis menu on this row (Corpus, Journal).
    let onRename: (() -> Void)?
    /// Nil → Delete entry hidden inside the ellipsis menu. Only meaningful
    /// when `onRename` is also non-nil (the menu itself is gated on rename).
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onTap) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(collection.name)
                            .font(nameFont)
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onRename {
                Menu {
                    Button {
                        onRename()
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if let onDelete {
                        Button(role: .destructive) {
                            onDelete()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: collection.isCorpus ? 0.10 : 0.07))
        )
    }

    private var nameFont: Font {
        collection.isCorpus
            ? .system(size: 20, weight: .semibold)
            : .system(size: 16, weight: .semibold)
    }

    private var verticalPadding: CGFloat {
        collection.isCorpus ? 20 : 14
    }

    private var subtitle: String {
        let count = "\(collection.nodeCount) " + (collection.nodeCount == 1 ? "node" : "nodes")
        guard let last = collection.lastEntryAt else { return count }
        return count + " · " + relativeTime(last)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - New Collection button

/// Bottom-of-list affordance to create a new user collection. Quieter than
/// a `CollectionRow` so it reads as auxiliary — a thin stroke instead of a
/// solid fill, centered "+ New Collection" label. Same outer shape and
/// vertical rhythm as user-collection rows so the section stays aligned.
private struct NewCollectionButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text("New Collection")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DashboardView()
}
