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
    /// Brief BF — bucket headers + empty state follow the app-wide Font; the sort icon stays SF.
    @Environment(\.appBodyFont) private var appFont

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
        let _ = Perf.body(Self.self)   // perf recorder (P6): counts this rebuild
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottom) {
                AppearancePalette.libraryBackground(dark: colorScheme == .dark).ignoresSafeArea()
                BackgroundGridView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if nodes.isEmpty {
                    emptyState
                } else if RunningOnMac.isMac && !perfAB("noisolate") {
                    // E fix-up 5 (L1) — not re-run by the stack's path; the key is every value of this view the rows read.
                    PathIsolated(key: [scope, sortKey, keyIndex, colorScheme, appFont] as [AnyHashable]) { macList }.equatable()
                } else if RunningOnMac.isMac {
                    macList   // Mac batch D4 — the desktop list (T asked for it)
                } else {
                    bucketList
                }

                // Local sort toggle, pinned above the Librarian peek. Rides
                // the same visibility signal as the sibling bodies (hidden in
                // detail, during selection, or when the Librarian rises above
                // peek). The capture "+" is no longer per-body — it lives once
                // in the persistent chrome layer (CanvasChrome).
                if !RunningOnMac.isMac && !store.isInDetailView && !selection.isActive && router.librarianAtPeek {
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
            .navigationHistory($navigationPath)   // Mac batch C1 — Go › Back / Forward
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
        .macInstantNavigation(navigationPath.count)   // E fix-up 6 (M7)
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
                                // live-16 — decode its hero + first gallery photos now; an uncached hero holds the push ≤ 300 ms.
                                store.openAfterPrewarm(node) { navigationPath.append(node) }
                            }
                        } label: {
                            RecentNodeRow(node: node, timestamp: node.updatedAt,
                                          ink: AppearancePalette.ink, appFont: appFont)
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
                        .accessibilityIdentifier("listRow-\(node.id)")   // A3 — one row per entry, findable by id
                        .pointerHover(cornerRadius: 8)   // Mac batch C5
                        .entryContextMenu(node)
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
                                    // §4 background pass (T 2026-10-02): KEEP the row panel (the
                                    // "removed" option was a Companion default, not T's pick) — now over
                                    // the quieter dots + dark gradient. Dark = frosted material; light =
                                    // warm elevated fill + lift.
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
                            .font(appFont.font(size: 12, weight: .semibold, relativeTo: .caption1))
                            .groundInk(0.5)
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .onCustomGround()   // 1.1-B — sits on the background
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

    // MARK: - Mac batch D4 — the desktop list

    /// Every entry in the order picked: "N entries · Sorted by last edited" (a menu), then one row each — a small hero
    /// thumbnail, the title, one line of summary, the collection (dot + name) once the content is ≥ 720 pt wide, and the
    /// age. Hover wash, right-click menu, ↑ / ↓ to move and ↩ to open.
    /// D fix-up B6 — from 720 pt (was 820): the default 1,350 pt window with the sidebar and the Librarian open leaves
    /// the List 736 pt, so the column never showed there; the title and summary still get ~400 pt.
    /// Batch E — 660 pt: the Librarian's 370 pt default leaves rows 694 pt at 1,350; the title and summary keep ~410 pt.
    static let macCollectionColumnMinWidth: CGFloat = 660

    private var macList: some View {
        let rows = sections.flatMap(\.nodes)
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    // E fix-up 4 (K3) — the header, then ONE lazy stack of rows (was a lazy stack nested in another:
                    // List scrolling ran at ~17 fps on 265 entries, the bench's base). The rows' hover and right-click
                    // menu are the list's, not 265 responders: SwiftUI hit-tested every row's hover / context-menu
                    // responder on each scroll event (a third of the main thread while scrolling).
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text("\(rows.count) \(rows.count == 1 ? "entry" : "entries") ·")
                            Menu {
                                Picker("Sort", selection: $sortKey) {
                                    Text("Last edited").tag(ListSort.newest)
                                    Text("Oldest first").tag(ListSort.oldest)
                                    Text("Title, A – Z").tag(ListSort.alphabetical)
                                }
                                .pickerStyle(.inline)
                            } label: {
                                HStack(spacing: 3) {
                                    Text(sortLabel)
                                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                }
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                        .font(appFont.font(size: 13, weight: .medium))
                        .groundInk(0.55)
                        .padding(.horizontal, 30)
                        .padding(.top, 18)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("macListHeader")
                        // D fix-up F1 — the rows sit on the app's panel, as the iPhone's rows do (dark: the frosted
                        // material; light: the warm elevated fill + its lift), not as bare text on the dot grid.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, node in
                                MacListRow(node: node, showCollection: geo.size.width - 32 >= Self.macCollectionColumnMinWidth,
                                           keyboardFocused: keyIndex == index, hover: macHover,
                                           appFont: appFont) { open(node) }
                                    .equatable()
                                    .id(node.id)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("macListRows")) } action: {
                                        macHover.frames[node.id] = $0
                                    }
                                    .accessibilityIdentifier("listRow-\(node.id)")
                            }
                        }
                        .padding(.vertical, 6)
                        .coordinateSpace(.named("macListRows"))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { macHover.listGlobal = $0 }
                        .onContinuousHover(coordinateSpace: .global) { phase in
                            switch phase {
                            case .active(let g): macHover.pointer(global: g)
                            case .ended: macHover.pointer(global: nil)
                            }
                        }
                        .contextMenu { MacListRowMenu(hover: macHover, rows: rows) }
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(colorScheme == .dark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(AppearancePalette.bgElevated))
                            .shadow(color: AppearancePalette.listRowLift, radius: 26, x: 0, y: 11))
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("macListPanel")
                    }
                    .padding(.bottom, 24)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { moveKey(+1, rows, proxy); return .handled }
                .onKeyPress(.upArrow) { moveKey(-1, rows, proxy); return .handled }
                .onKeyPress(.return) {
                    if let i = keyIndex, rows.indices.contains(i) { open(rows[i]) }
                    return .handled
                }
                .onFocusRequest { id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        // D fix-up F4 — View › Sort List By.
        .onChange(of: router.commandRequest) { _, request in
            switch request?.command {
            case .sortEdited?: sortKey = .newest
            case .sortOldest?: sortKey = .oldest
            case .sortTitle?: sortKey = .alphabetical
            default: break
            }
        }
    }

    @State private var keyIndex: Int?
    /// K3 — the row under the pointer (one tracker for the list; the rows' frames aren't observed).
    @State private var macHover = MacListHover()


    private var sortLabel: String {
        switch sortKey {
        case .newest: return "Sorted by last edited"
        case .oldest: return "Oldest first"
        case .alphabetical: return "Sorted by title"
        }
    }

    private func moveKey(_ step: Int, _ rows: [Node], _ proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let next = min(max((keyIndex ?? (step > 0 ? -1 : rows.count)) + step, 0), rows.count - 1)
        keyIndex = next
        proxy.scrollTo(rows[next].id)
    }

    private func open(_ node: Node) {
        if selection.isActive { selection.toggle(node.id); return }
        store.openAfterPrewarm(node) { macNavigate { navigationPath.append(node) } }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Nothing here yet")
                .font(appFont.font(size: 17, weight: .semibold))
                .groundInk(0.5)
            Text("Capture something to get started.")
                .font(appFont.font(size: 14))
                .groundInk(0.3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onCustomGround()   // 1.1-B — sits on the background
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

/// E fix-up 4 (K3) — which row the pointer is over: one continuous-hover tracker for the whole list, against the rows'
/// frames in the list's space (reported once per layout, not observed), instead of one hover responder per row.
/// The list's right-click menu: the entry menu for the row under the pointer (nothing elsewhere in the list).
private struct MacListRowMenu: View {
    let hover: MacListHover
    let rows: [Node]
    @Environment(AppRouter.self) private var router
    var body: some View {
        if let id = hover.id, let node = rows.first(where: { $0.id == id }) {
            EntryContextMenu.items(nodeID: node.id, isPrivate: node.isPrivate, router: router)
        }
    }
}

@Observable final class MacListHover {
    var id: String?
    @ObservationIgnored var frames: [String: CGRect] = [:]
    @ObservationIgnored var listGlobal: CGRect = .zero
    @ObservationIgnored private var lastPointer: CGPoint?
    /// Only a pointer that MOVED re-picks the row: while the list scrolls under a still pointer, hover fires every frame
    /// (the content moved), and re-picking then re-drew rows each frame (List scrolling ran at ~10–16 fps); the wash
    /// goes until the pointer moves again.
    /// The row under the last pointer position whether or not it moved since (Recents' right-click menu: after a
    /// scroll under a still pointer `id` is nil by design, and a right-click does not move the pointer).
    @ObservationIgnored private var lastSeen: CGPoint?
    var idForMenu: String? {
        if let id { return id }
        guard let g = lastSeen else { return nil }
        let p = CGPoint(x: g.x - listGlobal.minX, y: g.y - listGlobal.minY)
        return frames.first { $0.value.contains(p) }?.key
    }
    func pointer(global g: CGPoint?) {
        lastSeen = g
        guard let g else { lastPointer = nil; if id != nil { id = nil }; return }
        if let l = lastPointer, abs(l.x - g.x) < 0.5, abs(l.y - g.y) < 0.5 { if id != nil { id = nil }; return }
        lastPointer = g
        let p = CGPoint(x: g.x - listGlobal.minX, y: g.y - listGlobal.minY)
        let hit = frames.first { $0.value.contains(p) }?.key
        if hit != id { id = hit }
    }
}

/// Mac batch D4 — one row of the desktop list.
/// E fix-up 3 (H1) — Equatable on what it draws (not the open action, a new closure every pass), so a width change (the
/// Librarian or sidebar opening, animated) re-lays the rows out without re-running each row's body every frame.
private struct MacListRow: View, Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.node == b.node && a.showCollection == b.showCollection && a.keyboardFocused == b.keyboardFocused && a.hover === b.hover
            && a.appFont == b.appFont
    }
    let node: Node
    let showCollection: Bool
    let keyboardFocused: Bool
    /// K3 — the list's hover tracker (read in the body: only rows on screen re-draw when the hovered row changes).
    let hover: MacListHover
    let appFont: EntryBodyFont
    let action: () -> Void
    @Environment(CorpusStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var thumb: UIImage?
    /// E fix-up 5 (L6) — no hero: a still of the entry's own gradient (`ListGradientThumbs`).
    @State private var gradientThumb: UIImage?

    var body: some View {
        let _ = Perf.body(Self.self)   // perf recorder (P6): counts this rebuild
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppearancePalette.ink.opacity(0.07))
                    if let thumb = shownThumb { Image(uiImage: thumb).resizable().scaledToFill() }
                    else if let gradientThumb = shownGradientThumb { Image(uiImage: gradientThumb).resizable().scaledToFill() }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title.isEmpty ? "Untitled" : node.title)
                        .font(appFont.font(size: 14, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.95))
                        .lineLimit(1)
                    if !node.summary.isEmpty {
                        Text(MarkdownPlain.label(node.summary))
                            .font(appFont.font(size: 12.5))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showCollection {
                    // D fix-up B6 — the column keeps its width on every row (an unfiled entry leaves it blank), and a
                    // journal entry names the Journal: only user collections showed, so a run of journal entries had none.
                    HStack(spacing: 6) {
                        if let c = collection {
                            if !CollectionColors.retired {   // sweep 1 · N16: the name alone
                                Circle().fill(CollectionDot.color(c.id, light: scheme == .light, chosen: store.collectionColorHex(c.id))).frame(width: 8, height: 8)
                            }
                            Text(c.name).font(appFont.font(size: 12.5)).foregroundStyle(AppearancePalette.ink.opacity(0.7)).lineLimit(1)
                        }
                    }
                    .frame(width: 150, alignment: .leading)
                    .accessibilityIdentifier("listCollection")
                }
                Text(Self.age(node.updatedAt))
                    .font(appFont.font(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AppearancePalette.ink.opacity(keyboardFocused ? 0.11 : (hover.id == node.id ? 0.05 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .task(id: node.coverImageRelativePath) {
            if Self.syncThumbs, thumb == nil, let c = cachedCover { kept.cover = c; return }   // already drawn from the cache
            guard let url = await store.coverImageURL(for: node), let key = DisplayImageCache.coverKey(node) else { return }
            thumb = await DisplayImageCache.shared.load(path: key, url: url, pixels: Int(40 * DisplaySize.scale))
        }
        .task(id: node.coverImageRelativePath == nil ? ListGradientThumbs.key(node, dark: scheme == .dark) : "") {
            guard node.coverImageRelativePath == nil else { if gradientThumb != nil { gradientThumb = nil }; return }
            if Self.syncThumbs, gradientThumb == nil, let g = cachedGradient { kept.gradient = g; return }   // already drawn
            gradientThumb = ListGradientThumbs.shared.cached(node, dark: scheme == .dark)
            if gradientThumb == nil { gradientThumb = await ListGradientThumbs.shared.image(node, dark: scheme == .dark) }
        }
    }

    /// Sweep 1 · 1.4 (sheet C) — a row whose thumbnail is already decoded (the cover in `DisplayImageCache`, the gradient
    /// still in `ListGradientThumbs`' memory) draws it in its FIRST pass. It waited for its `.task` to copy it into
    /// state, so every such row was built twice on a switch to List, and the thumbnails landed a frame after the rows.
    /// In-memory lookups only (no I/O); `kept` holds what was drawn so a later cache trim can't blank it (not state: no
    /// second pass). `-MacPerfAB oldlistthumbs` (bench) = as before.
    private static var syncThumbs: Bool { !perfAB("oldlistthumbs") }
    @State private var kept = KeptThumbs()
    private final class KeptThumbs { var cover: UIImage?; var gradient: UIImage? }
    private var cachedCover: UIImage? {
        DisplayImageCache.coverKey(node).flatMap { DisplayImageCache.shared.image(path: $0, atLeast: Int(40 * DisplaySize.scale)) }
    }
    private var cachedGradient: UIImage? { ListGradientThumbs.shared.cached(node, dark: scheme == .dark) }
    private var shownThumb: UIImage? { thumb ?? (Self.syncThumbs ? (cachedCover ?? kept.cover) : nil) }
    private var shownGradientThumb: UIImage? {
        guard node.coverImageRelativePath == nil else { return gradientThumb }
        return gradientThumb ?? (Self.syncThumbs ? (cachedGradient ?? kept.gradient) : nil)
    }

    private var collection: NodeCollection? {
        if let c = store.collections.first(where: { !$0.isSystem && node.collectionIDs.contains($0.id) }) { return c }
        guard node.journalDate != nil || node.collectionIDs.contains(NodeCollection.journalID) else { return nil }
        return store.collections.first { $0.isJournal } ?? NodeCollection(id: NodeCollection.journalID, name: "Journal", nodeCount: 0)
    }

    /// "now", "5 min", "3 h", "2 d", "6 wk", then the date.
    static func age(_ date: Date) -> String {
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86_400 { return "\(Int(s / 3600)) h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400)) d" }
        if s < 60 * 86_400 { return "\(Int(s / (7 * 86_400))) wk" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// E fix-up 5 (L6) — T: rows without a hero showed a blank square ("we could do gradients sure"). The row shows a STILL
/// of the entry's own gradient — the colours and composition its card shows (the card's `NodeGradientLayer` values),
/// frozen at time 0, never animated in the List. Rendered once per entry and look, kept in memory and on disk
/// (Caches/ListGradientThumbs); the key holds what the gradient is made from (the entry's id, its primary tag, light /
/// dark), so a change there renders a new one. Rendering yields first, so a row draws its placeholder before it.
@MainActor final class ListGradientThumbs {
    static let shared = ListGradientThumbs()
    /// Bump when the card's gradient values change (the stills on disk are then re-rendered).
    static let version = 2
    /// A card's proportions (5:7) at a typical card width; the row shows its centre, scaled to fill.
    static let renderSize = CGSize(width: 200, height: 280)
    private let memory = NSCache<NSString, UIImage>()
    private let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ListGradientThumbs", isDirectory: true)

    static func key(_ node: Node, dark: Bool) -> String {
        "v\(version)-\(node.id)-\(NodeGradientLayer.stableHash(node.primaryTag ?? ""))-\(dark ? "d" : "l")"
    }

    func cached(_ node: Node, dark: Bool) -> UIImage? { memory.object(forKey: Self.key(node, dark: dark) as NSString) }

    func image(_ node: Node, dark: Bool) async -> UIImage? {
        let key = Self.key(node, dark: dark)
        if let i = memory.object(forKey: key as NSString) { return i }
        let file = dir.appendingPathComponent(key + ".png")
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: file) }.value
        if let data, let i = UIImage(data: data) { memory.setObject(i, forKey: key as NSString); return i }
        await Task.yield()
        if let i = memory.object(forKey: key as NSString) { return i }
        let renderer = ImageRenderer(content: Self.still(node)
            .frame(width: Self.renderSize.width, height: Self.renderSize.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 0.6 * DisplaySize.scale / 2   // the row's 40 pt square ≈ the render's centre 120 pt
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { return nil }
        memory.setObject(image, forKey: key as NSString)
        let dir = self.dir
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: file, options: .atomic)
        }
        return image
    }

    /// The card's gradient (NodeCardView, a card without a hero), centred, at time 0, without the glass ribs.
    private static func still(_ node: Node) -> some View {
        NodeGradientLayer(node: node,
                          vignette: GradientBake.cardVignette,
                          glowStart: GradientBake.cardGlowStart,
                          glowEnd: GradientBake.cardGlowEnd,
                          glowStrength: GradientBake.cardRadial,
                          bloom: GradientBake.cardBloom,
                          undulation: GradientBake.cardAmplitude,
                          warpScale: GradientBake.cardScale,
                          animated: false,
                          anchor: .center,
                          blobExpr: 1,
                          glassSurface: nil,   // no fluted ribs: at 40 pt they read as stripes, not glass
                          showsBlobs: true)
    }
}
