import SwiftUI

/// True List View — a compact, sectioned scanning surface for the nodes of
/// the CURRENT context (corpus or collection), not a global recents.
///
/// Reuses `RecentNodeRow` (the shared Recents / History band: tag-color dot ·
/// title · relative timestamp) grouped into time buckets (Today / Previous 7
/// Days / Previous 30 Days / month labels) for the chronological sorts, or a
/// flat A–Z list for alphabetical. The row component is lifted as-is; the
/// bucketing is copied+adapted from `RecentsView` (which is hardwired to
/// `store.nodes` + its own sort key) so this surface can own its scope + sort
/// without entangling the dashboard's landing list.
///
/// A body inside `CanvasChrome` (the view menu's "List" row): owns its own
/// `NavigationStack` for detail pushes + router nav handoff, mirroring
/// `NodeGridView` / `VerticalScrollView`. Sort is a local three-way toggle
/// (Newest / Oldest / A–Z) via a Menu affordance modeled on `RecentsView`'s.
struct NodeListView: View {

    /// What slice of the corpus this view renders. Defaults to `.corpus` so
    /// the CanvasChrome corpus call site keeps its behavior; collection
    /// canvases pass `.collection(id)`.
    var scope: CanvasScope = .corpus

    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    @State private var navigationPath = NavigationPath()
    /// Node ID at the top of the nav stack after a router-driven push —
    /// dedupes rapid multi-taps on the same Librarian match. Mirrors the
    /// sibling bodies.
    @State private var currentDetailNodeID: String? = nil
    @State private var sortKey: ListSort = .newest

    private let navHaptic = UIImpactFeedbackGenerator(style: .heavy)

    enum ListSort: Hashable { case newest, oldest, alphabetical }

    private var nodes: [Node] { store.filteredNodes(in: scope) }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottom) {
                AppearancePalette.mapBackground(dark: colorScheme == .dark).ignoresSafeArea()
                BackgroundGridView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if nodes.isEmpty {
                    emptyState
                } else {
                    bucketList
                }

                // Local sort toggle, pinned above the Librarian peek. Rides
                // the same visibility signal as the sibling bodies (hidden in
                // detail, during selection, or when the Librarian rises above
                // peek). The capture "+" is no longer per-body — it lives once
                // in the persistent chrome layer (CanvasChrome).
                if !store.isInDetailView && !selection.isActive && router.librarianAtPeek {
                    HStack {
                        sortControl
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, LibrarianPanelLayout.peekDetentHeight + 12)
                }
            }
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
            }
            // In-detail link-following (backlinks, suggestion preview) STACKS
            // here so back returns to the originating detail. See `NodeDetailRoute`.
            .navigationDestination(for: NodeDetailRoute.self) { route in
                NodeDetailView(nodeID: route.nodeID, focusEntryID: route.entryID)
            }
            // §3 — Librarian search ROW tap pops the detail so the focus lands
            // on the visible surface (no-op at root).
            .onChange(of: router.dismissDetailRequest) { _, _ in
                navigationPath = NavigationPath()
            }
            .onChange(of: router.pendingNodeNavigationID) { _, newValue in
                guard let id = newValue,
                      let node = store.nodes.first(where: { $0.id == id })
                else { return }
                if id != currentDetailNodeID {
                    navigationPath = NavigationPath([node])
                    currentDetailNodeID = id
                }
                router.pendingNodeNavigationID = nil
            }
            .onChange(of: navigationPath.count) { _, newCount in
                store.detailViewDepth = newCount
                if newCount == 0 { currentDetailNodeID = nil }
            }
        }
        .onAppear {
            navHaptic.prepare()
            store.detailViewDepth = navigationPath.count
        }
    }

    // MARK: - Bucketed list

    private var bucketList: some View {
        // #3 — ScrollViewReader so the shared focus signal can scroll to a row.
        ScrollViewReader { proxy in
        List {
            ForEach(sections, id: \.id) { section in
                Section {
                    ForEach(section.nodes) { node in
                        Button {
                            // BUG 10 — THE functional fix: in selection mode the
                            // row tap TOGGLES selection instead of pushing Detail.
                            // Without this branch, batch Tag/Organize/Delete were
                            // unreachable from List (tap always routed to Detail).
                            if selection.isActive {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                selection.toggle(node.id)
                            } else {
                                navHaptic.impactOccurred()
                                navigationPath.append(node)
                            }
                        } label: {
                            RecentNodeRow(node: node, timestamp: node.updatedAt,
                                          ink: AppearancePalette.ink)
                                .equatable()
                                // BUG 10 — shared selection CHECKMARK (trailing;
                                // the row's leading slot has the type dot). Outline
                                // suppressed — List carries a whole-strip fill in
                                // its listRowBackground instead (an inset outline
                                // doesn't hug a full-width row band — T's note).
                                .selectionHighlight(isSelecting: selection.isActive,
                                                    isPicked: selection.isSelected(node.id),
                                                    cornerRadius: 12,
                                                    badgeAlignment: .trailing,
                                                    outline: false)
                        }
                        // #13 (T-dialed) — LIGHT: a warm ELEVATED fill
                        // (`bgElevated`, the note-panel lift tone) + a heavy warm
                        // drop shadow, so each row band lifts off the hobonichi
                        // parchment. The first pass kept the frosted
                        // `.ultraThinMaterial` + a soft grid-card shadow and read
                        // as NO separation on parchment (T device-verified) — the
                        // material sits too close to the parchment tone. The warm
                        // opaque fill hides the grid dots UNDER each band (they
                        // still show in the gaps); T chose that trade for the
                        // clean lift. DARK: unchanged — the frosted material with
                        // `listRowLift` resolving `.clear`, BYTE-IDENTICAL to the
                        // pre-#13 rows (dark had no shadow and no elevated fill).
                        // #3 focus highlight (List) — the FOCUSED row's WHOLE
                        // STRIP fills with the Klein→cyan focus gradient rather
                        // than an outline (T: the outline didn't hug the row —
                        // make the strip blue). Persists until the next touch.
                        .listRowBackground(
                            Group {
                                if selection.isSelected(node.id) {
                                    // BUG 10 — SELECTED row: whole-strip Klein fill
                                    // (T asked for the focus-highlight treatment,
                                    // not the inset outline). Solid Klein `#1B59C2`
                                    // distinguishes it from focus's Klein→cyan
                                    // gradient; the trailing checkmark is definitive.
                                    Rectangle().fill(Color(hexString: "1B59C2"))
                                } else if router.focusedHighlightNodeID == node.id {
                                    LinearGradient(
                                        colors: [Color(hexString: "1B59C2"), Color(hexString: "00BFFF")],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                } else {
                                    Rectangle()
                                        .fill(colorScheme == .dark
                                              ? AnyShapeStyle(.ultraThinMaterial)
                                              : AnyShapeStyle(AppearancePalette.bgElevated))
                                        .shadow(color: AppearancePalette.listRowLift, radius: 26, x: 0, y: 11)
                                }
                            }
                            .animation(.easeInOut(duration: 0.25), value: selection.isSelected(node.id))
                            .animation(.easeInOut(duration: 0.25), value: router.focusedHighlightNodeID == node.id)
                        )
                    }
                } header: {
                    if let label = section.label {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                            .textCase(.uppercase)
                            .tracking(0.8)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Clear the CanvasChrome top row (back / ChromeBar overlay) and the
        // bottom sort+capture floaters + Librarian peek.
        .contentMargins(.top, 96, for: .scrollContent)
        .contentMargins(.bottom, LibrarianPanelLayout.peekDetentHeight + 72, for: .scrollContent)
        // #3 — shared focus signal: scroll the list so the focused row lands
        // CENTERED (was .top — it snapped under the top chrome bar).
        .onFocusRequest { id in
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Nothing here yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            Text("Capture something to get started.")
                .font(.system(size: 14))
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sort control

    private var sortControl: some View {
        Menu {
            Picker("Sort", selection: $sortKey) {
                Label("Newest", systemImage: "arrow.down").tag(ListSort.newest)
                Label("Oldest", systemImage: "arrow.up").tag(ListSort.oldest)
                Label("A – Z", systemImage: "textformat.abc").tag(ListSort.alphabetical)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .onChange(of: sortKey) { _, _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }


    // MARK: - Sectioning
    // Copied+adapted from RecentsView.buckets: same Today / Previous 7 Days /
    // Previous 30 Days / month labels, but sourced from the scoped `nodes`
    // and driven by the local three-way sort. Alphabetical collapses to a
    // single unlabeled section (A–Z jump index is a separate brief).

    private struct ListSection: Identifiable {
        let id: String
        let label: String?
        let nodes: [Node]
    }

    private var sections: [ListSection] {
        switch sortKey {
        case .alphabetical:
            let sorted = nodes.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return [ListSection(id: "az", label: nil, nodes: sorted)]

        case .newest, .oldest:
            let newestFirst = timeBuckets()
            guard sortKey == .oldest else { return newestFirst }
            // Oldest-first: reverse the section order and each section's rows,
            // keeping the same date-range labels.
            return newestFirst
                .reversed()
                .map { ListSection(id: $0.id, label: $0.label, nodes: $0.nodes.reversed()) }
        }
    }

    /// Newest-first time buckets over the scoped nodes, keyed on `updatedAt`.
    private func timeBuckets() -> [ListSection] {
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        guard let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
              let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday)
        else { return [] }
        let currentYear = calendar.component(.year, from: now)

        let sorted = nodes.sorted { $0.updatedAt > $1.updatedAt }

        var today: [Node] = []
        var prev7: [Node] = []
        var prev30: [Node] = []
        var monthOrder: [String] = []
        var monthGroups: [String: [Node]] = [:]

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "LLLL"
        let monthYearFormatter = DateFormatter()
        monthYearFormatter.dateFormat = "LLLL yyyy"

        for node in sorted {
            let d = node.updatedAt
            if d >= startOfToday {
                today.append(node)
            } else if d >= sevenDaysAgo {
                prev7.append(node)
            } else if d >= thirtyDaysAgo {
                prev30.append(node)
            } else {
                let year = calendar.component(.year, from: d)
                let label = year == currentYear
                    ? monthFormatter.string(from: d)
                    : monthYearFormatter.string(from: d)
                if monthGroups[label] == nil {
                    monthOrder.append(label)
                    monthGroups[label] = []
                }
                monthGroups[label]?.append(node)
            }
        }

        var result: [ListSection] = []
        if !today.isEmpty { result.append(ListSection(id: "today", label: "Today", nodes: today)) }
        if !prev7.isEmpty { result.append(ListSection(id: "prev7", label: "Previous 7 Days", nodes: prev7)) }
        if !prev30.isEmpty { result.append(ListSection(id: "prev30", label: "Previous 30 Days", nodes: prev30)) }
        for label in monthOrder {
            if let nodes = monthGroups[label] {
                result.append(ListSection(id: "month-\(label)", label: label, nodes: nodes))
            }
        }
        return result
    }
}
