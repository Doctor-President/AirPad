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
/// Routes pushed onto the Dashboard's stack. Recents and node details are
/// both children of the Dashboard hub: Recents → Dashboard is a native pop;
/// Recents → Detail stacks deeper on the same path.
enum DashboardRoute: Hashable {
    case recents
    case node(Node)
    /// Passage-free FM chat surface (`ChatView`). Pushed via the header
    /// chat icon. Detail-depth math (`detailDepth(in:)`) deliberately
    /// excludes this case so the Librarian panel doesn't duck while the
    /// chat lane is open.
    case chat
}

struct DashboardView: View {

    /// Seeds the initial stack. `.recents` lands the app on Recents with the
    /// hub one pop beneath (cold-launch landing); nil opens the hub directly
    /// (returning from a canvas). Only read at creation — afterwards `path`
    /// is the source of truth.
    let initialRoute: DashboardRoute?

    init(initialRoute: DashboardRoute? = nil) {
        self.initialRoute = initialRoute
        _path = State(initialValue: initialRoute.map { [$0] } ?? [])
    }

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store

    @State private var path: [DashboardRoute]
    @State private var renameTarget: NodeCollection?
    @State private var deleteTarget: NodeCollection?
    @State private var showCreateCollectionSheet = false
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
                DashboardLavaLamp()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                            .padding(.top, 6)
                        todaySection
                        recentsRow
                        collectionsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
                }

                floatingPlusButton
            }
            .toolbar(.hidden, for: .navigationBar) // dashboard renders its own header
            .navigationDestination(for: DashboardRoute.self) { route in
                switch route {
                case .recents:
                    RecentsView(onOpenNode: { node in path.append(.node(node)) })
                case .node(let node):
                    NodeDetailView(nodeID: node.id)
                case .chat:
                    ChatView()
                }
            }
            .sheet(item: $renameTarget) { collection in
                RenameCollectionSheet(collectionID: collection.id, currentName: collection.name)
            }
            .sheet(isPresented: $showCreateCollectionSheet) {
                CollectionCreationSheet { _ in }
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
                path.append(.node(node))
                router.pendingNodeNavigationID = nil
            }
            // Authoritative depth signal. `path` is [DashboardRoute] mixing
            // the pushed `.recents` landing with node details, so raw
            // `path.count` would over-count — `detailDepth(in:)` counts only
            // `.node` entries. ContentView's `isInDetailView` handler reads
            // this for first-enter / last-exit panel choreography.
            .onChange(of: path) { _, newPath in
                store.detailViewDepth = detailDepth(in: newPath)
            }
            .onAppear { store.detailViewDepth = detailDepth(in: path) }
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

    /// Detail depth = node screens on the path. `.recents` also rides this
    /// stack but isn't a detail, so it's excluded — keeps `isInDetailView`
    /// (Librarian panel raise/duck) correct when Recents is on top.
    private func detailDepth(in routes: [DashboardRoute]) -> Int {
        routes.filter { if case .node = $0 { return true } else { return false } }.count
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
                headerIconButton(systemName: "bubble.left.and.bubble.right.fill") {
                    path.append(.chat)
                }
                inboxButton
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
            onRecentTap: { node in path.append(.node(node)) }
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
                path.append(.node(node))
            }
        }
    }

    // MARK: - Recents row

    /// Sits between Today and the Collections eyebrow. Distinct treatment
    /// from `CollectionRow` (no `.thinMaterial` card, no subtitle) so it
    /// reads as a sibling navigation row to the Collections list, not as
    /// one of the collections.
    private var recentsRow: some View {
        Button {
            path.append(.recents)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28)
                Text("Recents")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Collections")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.8)

            VStack(spacing: 0) {
                ForEach(displayedCollections) { collection in
                    CollectionRow(
                        collection: collection,
                        onTap: { tap(collection) },
                        onRename: canManage(collection) ? { renameTarget = collection } : nil,
                        onDelete: canDelete(collection) ? { deleteTarget = collection } : nil
                    )
                    // Hairline after every collection row. The final
                    // collection row sits above NewCollectionButton (not
                    // the section end), so a divider here is correct;
                    // NewCollectionButton itself is the last element and
                    // gets no trailing line.
                    collectionsHairline
                }
                NewCollectionButton { showCreateCollectionSheet = true }
            }
        }
    }

    /// Hairline used between rows in `collectionsSection` since the cards
    /// were stripped in commit 2 of the recents-landing brief.
    private var collectionsHairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
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
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
/// a `CollectionRow` (lower-opacity label) so it reads as auxiliary. Flat
/// to match the hairline-divided collection rows above it.
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DashboardView()
}
