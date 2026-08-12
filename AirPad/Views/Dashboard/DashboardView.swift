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
///      CanvasView/VerticalScrollView collided with the dashboard's outer one).
///   4. Persistent floating "+" bottom-right — routes to QuikCapture with
///      `.dashboard` origin so the exit pill returns here rather than
///      suspending the app (c4.6).
/// Routes pushed onto the Dashboard's stack. Recents and node details are
/// both children of the Dashboard hub: Recents → Dashboard is a native pop;
/// Recents → Detail stacks deeper on the same path.
enum DashboardRoute: Hashable {
    case recents
    case priority
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
    @State private var showCollectionReorder = false
    @State private var showSettings = false
    #if DEBUG
    /// Dark lava-lamp tuner (throwaway; delete with the panel once T's DARK values
    /// are baked into DashLavaDark.default).
    @State private var showDashLavaDarkTuner = false
    @State private var dashLavaDarkTunerOffset: CGSize = .zero
    #endif

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
                        quickReentrySection
                        collectionsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 120)
                }

                floatingPlusButton

                #if DEBUG
                dashLavaDarkTunerLayer
                #endif
            }
            .toolbar(.hidden, for: .navigationBar) // dashboard renders its own header
            .navigationDestination(for: DashboardRoute.self) { route in
                switch route {
                case .recents:
                    RecentsView(onOpenNode: { node in path.append(.node(node)) })
                case .priority:
                    PriorityView(onOpenNode: { node in path.append(.node(node)) })
                case .node(let node):
                    NodeDetailView(nodeID: node.id)
                case .chat:
                    ChatView()
                }
            }
            // In-detail link-following (backlinks, suggestion preview) from a
            // detail pushed on the dashboard stack STACKS here too, carrying the
            // optional entryID. See `NodeDetailRoute`. (Dashboard's own handoff
            // already appends, so it never had the swap defect — but backlinks
            // still need this destination registered to resolve.)
            .navigationDestination(for: NodeDetailRoute.self) { route in
                NodeDetailView(nodeID: route.nodeID, focusEntryID: route.entryID)
            }
            .sheet(item: $renameTarget) { collection in
                RenameCollectionSheet(collectionID: collection.id, currentName: collection.name)
            }
            .sheet(isPresented: $showCreateCollectionSheet) {
                CollectionCreationSheet { _ in }
            }
            .sheet(isPresented: $showCollectionReorder) {
                CollectionReorderSheet(collections: store.collections)
                    .environment(store)
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
            // Capture-mode "Done" now returns to origin via NodeDetailView's
            // `dismiss()` (pops the pushed capture detail back to whatever surface
            // summoned it — Recents/Dashboard included), so no forced path reset
            // lives here anymore. See NodeDetailView.finishCapture.
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
                .foregroundStyle(AppearancePalette.ink)
                .frame(height: 56)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer()
                headerPill
            }
        }
        .frame(height: 48)
    }

    /// #3 — the chat / inbox / settings icons grouped into ONE liquid-glass pill,
    /// reusing the STANDARD `chromeSurface(Capsule())` chrome treatment (the same
    /// Map/Card/List chrome glass), NOT the #2 peek-pill style. Icons use the
    /// adaptive `AppearancePalette.ink` (dark #FFFFFF byte-identical; light
    /// dark-ink so they read on the light glass over parchment).
    private var headerPill: some View {
        HStack(spacing: 2) {
            pillIcon("bubble.left.and.bubble.right.fill", size: 16) { router.showChatsList = true }
            inboxPillIcon
            pillIcon("gearshape.fill", size: 16) { showSettings = true }
        }
        .padding(.horizontal, 4)
        .chromeSurface(Capsule())
    }

    private func pillIcon(_ systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var inboxPillIcon: some View {
        let badgeCount = 0
        return Button(action: {}) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())

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
    /// Quick re-entry cluster — Priority (when non-empty) stacked over Recents in
    /// ONE grouped pane with a hairline between, the SAME treatment as the
    /// Collections pane (not two separate floating panes — T, 2026-07-30). When
    /// Priority is empty the pane is just Recents: no hairline, no gap, no empty
    /// container.
    private var quickReentrySection: some View {
        VStack(spacing: 0) {
            if !store.priorityNodes.isEmpty {
                priorityRow
                collectionsHairline
            }
            recentsRow
        }
        .dashboardPaneSurface()
    }

    /// Dashboard "Priority" row — mirrors `recentsRow`'s single-line pane rhythm
    /// (flag icon + label + trailing count + chevron). Navigates to `PriorityView`.
    private var priorityRow: some View {
        Button {
            path.append(.priority)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "flag.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .frame(width: 28)
                Text("Priority")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                Spacer()
                Text("\(store.priorityNodes.count)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.3))
            }
            .padding(.vertical, 23)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentsRow: some View {
        Button {
            path.append(.recents)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .frame(width: 28)
                Text("Recents")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.3))
            }
            // #3 fix-up — vertical padding raised so this single-line pane matches
            // a (two-line) Collections row's height/rhythm (measured parity, see
            // report); horizontal 18 matches a Collections row's inset so the two
            // panes read as siblings. No subtitle added to fill the space.
            .padding(.vertical, 23)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Collections")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                // Collections reorder — drag-to-reorder trigger (only meaningful
                // with >1 user collection; Corpus/Journal are synthetic rows).
                if store.collections.count > 1 {
                    Button { showCollectionReorder = true } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reorder collections")
                }
            }

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
            // #3 fix-up — the SAME pane surface as the Today card
            // (`.thinMaterial` + white@0.12 rim, radius 22, no shadow; the lava
            // reads through it). Replaced the List-view row treatment (opaque
            // cream fill + heavy warm shadow + tight corners) that clashed here.
            .dashboardPaneSurface()
        }
    }

    /// Hairline between rows in `collectionsSection`. #3 — appearance-aware ink
    /// (dark #FFFFFF@0.08 byte-identical; light dark-ink so it reads on the
    /// translucent pane in both modes) — was `.white@0.08`, invisible in light.
    private var collectionsHairline: some View {
        Rectangle()
            .fill(AppearancePalette.ink.opacity(0.08))
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
                    // Capture mode: a fresh blank node opens in the note primitive
                    // (keyboard up) with the Librarian ducked. Reuses the existing
                    // pendingNodeNavigationID handoff to push the detail route.
                    Task {
                        guard let node = await store.createCaptureNode() else { return }
                        router.isCapturing = true
                        router.captureNodeID = node.id
                        router.captureDraftHasText = false
                        router.pendingNodeNavigationID = node.id
                    }
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

    #if DEBUG
    /// Dark lava tuner: drop-glyph trigger (top-left) + panel. Delete with
    /// DashLavaDarkTuningPanel once T's DARK values are baked.
    private var dashLavaDarkTunerLayer: some View {
        ZStack {
            VStack {
                HStack {
                    Button { showDashLavaDarkTuner.toggle() } label: {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 60)
            .padding(.leading, 10)

            if showDashLavaDarkTuner {
                VStack {
                    Spacer()
                    DashLavaDarkTuningPanel(isPresented: $showDashLavaDarkTuner,
                                            position: $dashLavaDarkTunerOffset)
                        .padding(.bottom, 80)
                }
            }
        }
    }
    #endif

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
                            .foregroundStyle(AppearancePalette.ink)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
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
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
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
            .foregroundStyle(AppearancePalette.ink.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Collections reorder — drag-to-reorder sheet for the Dashboard's user
/// collections. The `ddbf66f`/`GalleryReorderSheet` shape: a modal `List` in
/// permanent edit mode over a local working copy; each move persists the
/// resulting order by ID via `CorpusStore.setCollectionOrder` (order = array
/// position, no migration). Only user collections are passed in — Corpus /
/// Journal are synthetic Dashboard rows and aren't reorderable.
private struct CollectionReorderSheet: View {
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var working: [NodeCollection]

    init(collections: [NodeCollection]) {
        _working = State(initialValue: collections)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(working) { collection in
                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        Text(collection.name)
                            .font(.body)
                            .foregroundStyle(AppearancePalette.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Collections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Applies the List move to the local working copy (instant, smooth), then
    /// persists the resulting order by ID — one write per move.
    private func move(from source: IndexSet, to destination: Int) {
        working.move(fromOffsets: source, toOffset: destination)
        let orderedIDs = working.map(\.id)
        Task { await store.setCollectionOrder(orderedIDs) }
    }
}

#Preview {
    DashboardView()
}
