import SwiftUI
import UIKit

/// Full canvas surface — body switcher (5 view modes) + overlay chrome
/// (top row, selection header, batch bar, banners) + chrome-driven sheets
/// + the C2 slide-out menu. Extracted from `ContentView` in B1; the top-row
/// cluster collapsed to a single ellipsis trigger in C3 (this commit).
///
/// Scope-aware pieces:
///   - body switcher passes `scope` into `CanvasView` / `VerticalScrollView`
///   - `ChromeBar`'s select segment enters selection on this scope
///   - view-mode / filter reads + writes use `store.filterState(for: scope)`
///     and `setFilterState(_, for: scope)`; `FilterPanelView` mirrors
/// Scope-fixed pieces (intentional — global tools):
///   - Back chevron unconditionally returns to dashboard via the router.
///     Both corpus and collection canvases route in via `AppRouter.entryMode`
///     (D1c — was a NavigationStack push pre-D1c, but the inner stack in
///     CanvasView/VerticalScrollView collided with the dashboard's outer stack).
///   - Settings and Quarantine rows operate on global state regardless of
///     scope. Collection canvases share the same settings/quarantine surfaces.
struct CanvasChrome: View {

    var scope: CanvasScope = .corpus

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(QuarantineStore.self) private var quarantineStore
    @Environment(SelectionService.self) private var selection
    /// Card View presentation dispatch (default branch): count == 1 → Cover
    /// Flow carousel; 4 → VerticalScrollView; 2 or 3 → NodeGridView. Same key
    /// the grid + density pill read, so the pill swaps the body live.
    @AppStorage("gridColumnCount") private var gridColumnCount: Int = 2
    @State private var showFilterPanel = false
    @State private var showSettings = false
    @State private var showQuarantineReview = false
    @State private var showSlideOutMenu = false
    @State private var showEditMap = false
    @State private var showBatchDeleteConfirmation = false
    @State private var showBatchAddTagSheet = false

    #if DEBUG
    /// DEBUG-only — Solar Flare material spike tuner. Mounted here in
    /// CanvasChrome (not inside CanvasView/NodeGridView/etc.) so the
    /// ☀︎ trigger is reachable across every body mode (graph, grid,
    /// carousel, vertical scroll). NOT inside the Librarian panel surface —
    /// the FloatingPanel eats touches inside its own bounds (the
    /// repeated past mistake). Self-deletes once the sf.* values are
    /// baked into SolarFlareMaterial as literals.
    @State private var showSolarFlareTuningPanel = false
    /// Drag offset for the floating widget. Owned here so position
    /// survives close/re-open within a session — same pattern as
    /// NodeGridView's tile tuning panel.
    @State private var solarFlareTuningPanelOffset: CGSize = .zero

    #endif

    private var filterState: FilterState {
        store.filterState(for: scope)
    }

    /// Dot indicator on the ellipsis trigger when something inside the
    /// menu has live state — active filters or quarantined entries. The
    /// menu rows themselves carry the specific counts; the trigger just
    /// nudges the user to look inside.
    private var menuHasAttention: Bool {
        filterState.activeFilterCount > 0 || quarantineStore.entries.count > 0
    }

    /// Persistent capture "+" for the chrome layer. Creates a fresh blank
    /// capture node (rich note surface — the four entry-type circles live
    /// inside it) and hands navigation to the active body's NavigationStack
    /// via `router.pendingNodeNavigationID`, exactly as the Dashboard "+"
    /// does. Replaces the four per-body triggers that routed to the retired
    /// `CaptureOverlayView`.
    private var captureTriggerButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
                // ws-dark-light-mode item 2 — capture "+". Dark byte-identical
                // (onInk #000000 glyph on ink #FFFFFF circle == the old
                // .black-on-.white); light = a cream glyph cut out of a dark
                // ink circle so it reads on cream. T art-directs (surface 6).
                .foregroundStyle(AppearancePalette.onInk)
                .frame(width: 60, height: 60)
                .background(AppearancePalette.ink)
                .clipShape(Circle())
                .shadow(color: AppearancePalette.panelShadow, radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        ZStack {
            // Main content — switches between graph, List, and Card View. Each
            // owns its own NavigationStack; the floating "+" trigger lives
            // inside them so navigation handoff from the in-app capture
            // overlay can push onto the local path.
            Group {
                switch filterState.viewMode {
                case .systemGraph:
                    CanvasView(scope: scope)
                case .list:
                    NodeListView(scope: scope)
                default:
                    // Card View. The density pill drives the presentation via
                    // the shared `gridColumnCount` key so it swaps the body
                    // live: 1 = Cover Flow 3D carousel; 4 = vertical-scroll
                    // full cards; 2/3 = uniform-tile grid.
                    switch gridColumnCount {
                    case 1:
                        CoverFlowView(scope: scope)
                    case 4:
                        VerticalScrollView(scope: scope)
                    default:
                        NodeGridView(scope: scope)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: filterState.viewMode)

            // Overlays that live above the canvas but behind the fan — these all
            // blur uniformly when the fan is expanded so the focal effect is
            // consistent across the full screen, not just the canvas area.
            ZStack {
                if store.iCloudUnavailable {
                    VStack {
                        iCloudUnavailableBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.top, 8)
                        Spacer()
                    }
                }

                // C4 — top-center "thinking" pill. Sits alongside the topRow
                // (back chevron / select / ellipsis), in the same blur scope
                // so the fan expansion treats it as chrome. Hidden in
                // selection mode and inside detail views so the surface stays
                // calm during focused interactions.
                if !store.isInDetailView && !selection.isActive && store.isAnyModelProcessing {
                    VStack {
                        ModelProcessingIndicator()
                            .padding(.top, 22)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        Spacer()
                    }
                }

                if !store.isInDetailView {
                    VStack(spacing: 0) {
                        if selection.isActive {
                            SelectionHeader(count: selection.count) {
                                selection.exit()
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        } else {
                            // ZStack (not HStack + Spacers) so the view pill is
                            // TRUE-centered on screen regardless of the leading
                            // back button vs. the wider trailing ChromeBar —
                            // two Spacers would bias it toward the narrower side.
                            ZStack {
                                // Top-center view pill — the single view-mode
                                // switcher, persistent across every canvas mode.
                                ViewPill(scope: scope, onEditMap: { showEditMap = true })

                                HStack(alignment: .center, spacing: 8) {
                                    DashboardBackButton {
                                        router.entryMode = .dashboard
                                    }
                                    Spacer()
                                    ChromeBar(
                                        menuHasAttention: menuHasAttention,
                                        onSelect: { selection.enter(scope: scope) },
                                        onMenu: { showSlideOutMenu = true }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        }
                        Spacer()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
                }

                // Density pill as a bottom-centered floater. Rides the same
                // visibility signal as NodeGridView's "+" capture trigger so
                // the two share a lifecycle: both hide when the Librarian is
                // raised above peek, neither appears in detail view or while
                // selection is active. Body-switcher gate still applies — the
                // pill only makes sense in the default branch (grid / cover flow).
                if !store.isInDetailView
                    && !selection.isActive
                    && router.librarianAtPeek
                    && filterState.viewMode != .systemGraph
                    && filterState.viewMode != .list {
                    VStack {
                        Spacer()
                        ZStack {
                            HStack {
                                SortMenu(scope: scope)
                                Spacer()
                            }
                            DensityPill()
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, LibrarianPanelLayout.peekDetentHeight + 12)
                    }
                }

                // Persistent capture "+" — ONE button in the chrome layer
                // above the body switcher, so every view mode (all four Card
                // presentations, List, and the graph canvas) shows an
                // identical capture affordance. Replaces the four per-body
                // copies that had drifted (missing entirely from the carousel;
                // a hardcoded bottom inset in vertical scroll). Bottom-trailing,
                // clearing the peek pill. Shares the density/pill visibility
                // gate — hidden in detail view, during selection, or when the
                // Librarian rises above peek.
                if !store.isInDetailView
                    && !selection.isActive
                    && router.librarianAtPeek {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            captureTriggerButton
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, LibrarianPanelLayout.peekOverlayClearance)
                    }
                }

                if selection.isActive && !selection.isEmpty && !store.isInDetailView {
                    VStack {
                        Spacer()
                        BatchActionBar(
                            count: selection.count,
                            scope: scope,
                            tags: store.tags,
                            collections: store.collections,
                            collectionLastUsedAt: store.collectionLastUsedAt,
                            onDelete: { showBatchDeleteConfirmation = true },
                            onPickExistingTag: { tagName in
                                let ids = selection.selected
                                Task {
                                    await store.addTag(tagName, toNodes: ids)
                                    await MainActor.run { selection.exit() }
                                }
                            },
                            onAddNewTag: { showBatchAddTagSheet = true },
                            onAddToCollection: { collectionID in
                                let ids = selection.selected
                                Task {
                                    await store.addNodes(ids: ids, toCollection: collectionID)
                                    await MainActor.run { selection.exit() }
                                }
                            },
                            onRemoveFromCurrentCollection: {
                                guard case .collection(let currentID) = scope else { return }
                                let ids = selection.selected
                                Task {
                                    await store.removeNodes(ids: ids, fromCollection: currentID)
                                    await MainActor.run { selection.exit() }
                                }
                            },
                            onMoveToCollection: { targetID in
                                guard case .collection(let currentID) = scope else { return }
                                let ids = selection.selected
                                Task {
                                    await store.moveNodes(ids: ids, from: currentID, to: targetID)
                                    await MainActor.run { selection.exit() }
                                }
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, LibrarianPanelLayout.peekDetentHeight + 12)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let progress = store.importBatchProgress {
                    VStack {
                        Spacer()
                        ImportProgressBanner(current: progress.current, total: progress.total)
                            .padding(.bottom, 108)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .animation(.spring(response: 0.35), value: store.importBatchProgress != nil)
                }

            }

            // Slide-out menu sits outside any blur scope so it stays sharp.
            CanvasSlideOutMenu(
                isPresented: $showSlideOutMenu,
                currentMode: filterState.viewMode,
                filterActiveCount: filterState.activeFilterCount,
                quarantineCount: quarantineStore.entries.count,
                onSelectMode: { mode in
                    var s = filterState
                    s.viewMode = mode
                    store.setFilterState(s, for: scope)
                },
                onAnalyze: { Task { store.runCorpusAnalysis(trigger: .manual) } },
                onFilter: { showFilterPanel = true },
                onSettings: { showSettings = true },
                onQuarantineReview: { showQuarantineReview = true }
            )

            #if DEBUG
            // Top-most dev layer — placed AFTER CanvasSlideOutMenu so it
            // renders above every other CanvasChrome overlay (including
            // the menu, batch bar, banners). Both pieces are zero-cost
            // when the spike is removed; just delete this block + the
            // two #if DEBUG @State props above.
            solarFlareTuningTrigger
            if showSolarFlareTuningPanel {
                floatingSolarFlareTuningPanel
            }
            #endif
        }
        // #3 — clear the persistent focus highlight on the user's next touch
        // anywhere. Installed once on the window; observes touches without
        // consuming them (see FocusDismissTouchProbe).
        .background(
            FocusDismissTouchProbe { router.clearFocusHighlight() }
                .frame(width: 0, height: 0)
        )
        .animation(.spring(response: 0.35), value: store.iCloudUnavailable)
        .sheet(isPresented: $showFilterPanel) {
            FilterPanelView(scope: scope)
        }
        .sheet(isPresented: $showEditMap) {
            EditMapSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showQuarantineReview) {
            QuarantineReviewSheet()
        }
        .sheet(isPresented: $showBatchAddTagSheet) {
            TagEditorSheet(existing: nil) { createdName in
                let ids = selection.selected
                Task {
                    await store.addTag(createdName, toNodes: ids)
                    await MainActor.run { selection.exit() }
                }
            }
        }
        .confirmationDialog(
            "Delete \(selection.count) \(selection.count == 1 ? "item" : "items")?",
            isPresented: $showBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let ids = selection.selected
                Task {
                    await store.deleteNodes(ids: ids)
                    await MainActor.run {
                        selection.exit()
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
        }
    }

    #if DEBUG
    // MARK: - Solar Flare tuning (DEBUG)

    /// Tiny ☀︎ in the top-leading corner, below the back button (top: 12)
    /// and below NodeGridView's tile-tuning ⚙ (top: 60). Faint so it
    /// doesn't distract in normal use; tap shows/hides the floating
    /// Solar Flare tuner. Always-on visibility (no detail / selection
    /// gates) — the spike is meant to be reachable from any state.
    private var solarFlareTuningTrigger: some View {
        VStack {
            HStack {
                Button {
                    showSolarFlareTuningPanel.toggle()
                } label: {
                    Image(systemName: "sun.max")
                        .font(.system(size: 13, weight: .medium))
                        // ws-dark-light-mode item 2 — DEBUG trigger stays reachable
                        // on cream so T can open the tuner in light mode. ink @0.45
                        // (dark #FFFFFF == the old .white@0.45).
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Spacer()
        }
        .padding(.top, 100)
        .padding(.leading, 10)
    }

    /// Floating Solar Flare tuner. Default-positioned just above the
    /// panel's expanded chrome so it doesn't collide with the morphing
    /// field when T is dialing values from peek. Position is parent-
    /// owned (`solarFlareTuningPanelOffset`) so the widget survives
    /// close/re-open within a session.
    private var floatingSolarFlareTuningPanel: some View {
        VStack {
            Spacer()
            SolarFlareTuningPanel(
                isPresented: $showSolarFlareTuningPanel,
                position: $solarFlareTuningPanelOffset
            )
            .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    // MARK: - Dark-mode orb POP tuning (DEBUG)

    #endif
}

// MARK: - Dashboard back button

private struct DashboardBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                // ws-dark-light-mode item 2 — dark #FFFFFF == .white (identical);
                // light = ink blue-black so it reads on the adaptive chromeSurface.
                .foregroundStyle(AppearancePalette.ink)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .chromeSurface(Circle())
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Chrome bar (Select / Menu)

/// Icon segments inside one Capsule with a shared chrome surface
/// (Liquid Glass on iOS 26+, `.thinMaterial` fallback below). Height matches
/// the standalone back-button circle (48) so the row aligns. The former
/// leading "Recents" (history) segment was retired — recency now lives in
/// List view's default sort, reached via the top-center view pill.
private struct ChromeBar: View {
    let menuHasAttention: Bool
    let onSelect: () -> Void
    let onMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(icon: "checkmark.circle", weightSize: 18, action: onSelect)
            segment(icon: "line.3.horizontal.decrease", weightSize: 18, action: onMenu)
                .overlay(alignment: .topTrailing) {
                    if menuHasAttention {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .chromeSurface(Capsule())
    }

    private func segment(icon: String, weightSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: weightSize, weight: .semibold))
                // ws-dark-light-mode item 2 — ink (dark #FFFFFF == .white).
                .foregroundStyle(AppearancePalette.ink)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View pill (top-center)

/// Top-center view pill — the single view-mode switcher for the whole
/// canvas chrome. Shows the current view's NAME (Card / List / Map) and
/// taps open an inline `Picker` flyout (checkmark on the current mode).
/// Lives in the persistent chrome layer above the body switcher, so it
/// rides EVERY view mode — the user hops graph→list→card from anywhere.
/// Replaces both the retired Dashboard Recents button and the earlier
/// bottom trailing-slot toggle (which clashed with the capture "+").
///
/// The right-edge slide-out menu keeps its own View rows too (intentional
/// redundancy per the unification brief); this is the fast path.
///
/// Destinations map short pill names onto `ViewMode`: "Card" → `.grid`
/// (Card View's presentation family), "List" → `.list`, "Map" →
/// `.systemGraph` (the graph canvas). The two "coming soon" stubs
/// (`.userGraph`, `.timeline`) are intentionally absent — the pill offers
/// only the live primaries; the slide-out menu still lists the stubs.
private struct ViewPill: View {
    @Environment(CorpusStore.self) private var store
    let scope: CanvasScope
    /// Tag-anchored Map — opens the anchor-designation settings. Shown in the
    /// flyout only when Map is the active view.
    var onEditMap: () -> Void = {}

    private static let destinations: [(mode: ViewMode, label: String, icon: String)] = [
        (.grid,        "Card", "square.grid.2x2"),
        (.list,        "List", "list.bullet"),
        (.systemGraph, "Map",  "circle.hexagongrid.fill"),
    ]

    private var current: ViewMode { store.filterState(for: scope).viewMode }

    /// Card View spans several `viewMode`s that all route to the `.grid`
    /// destination, so fall back to the first entry (Card) when the live
    /// mode isn't one of the three pill primaries.
    private var currentDest: (mode: ViewMode, label: String, icon: String) {
        Self.destinations.first { $0.mode == current } ?? Self.destinations[0]
    }

    private var modeBinding: Binding<ViewMode> {
        Binding(
            get: { current },
            set: { newValue in
                guard newValue != current else { return }
                var s = store.filterState(for: scope)
                s.viewMode = newValue
                store.setFilterState(s, for: scope)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        )
    }

    var body: some View {
        Menu {
            Picker("View", selection: modeBinding) {
                ForEach(Self.destinations, id: \.mode) { dest in
                    Label(dest.label, systemImage: dest.icon).tag(dest.mode)
                }
            }
            // Map settings — anchor designation. Only meaningful on the Map.
            if current == .systemGraph {
                Divider()
                Button("Edit Map…", systemImage: "slider.horizontal.3", action: onEditMap)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: currentDest.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(currentDest.label)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.6)
            }
            // ws-dark-light-mode item 2 — the "Map"/view pill. ink (dark #FFFFFF == .white).
            .foregroundStyle(AppearancePalette.ink)
            .frame(height: 36)
            .padding(.horizontal, 14)
            .contentShape(Capsule())
            .chromeSurface(Capsule())
            .clipShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

// MARK: - Sort menu

/// Bottom-row sort control. Glassed circular trigger displays the active
/// sort's icon; tapping opens an inline Picker (renders with checkmark
/// on the current selection inside a Menu). Reads/writes the active
/// scope's `FilterState.sortOrder` via the store, mirroring the pattern
/// `FilterPanelView.mutate` uses so the side-panel sort and this menu
/// stay in lockstep. Visibility is gated by the caller (same lifecycle
/// as DensityPill — rides the "+" trigger / Librarian-peek signal).
private struct SortMenu: View {
    @Environment(CorpusStore.self) private var store
    let scope: CanvasScope

    private var state: FilterState { store.filterState(for: scope) }

    private var sortBinding: Binding<SortOrder> {
        Binding(
            get: { state.sortOrder },
            set: { newValue in
                var s = state
                s.sortOrder = newValue
                store.setFilterState(s, for: scope)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        )
    }

    var body: some View {
        Menu {
            Picker("Sort", selection: sortBinding) {
                ForEach(SortOrder.menuOrder, id: \.self) { order in
                    Label(order.displayName, systemImage: order.icon).tag(order)
                }
            }
        } label: {
            Image(systemName: state.sortOrder.icon)
                .font(.system(size: 15, weight: .semibold))
                // ws-dark-light-mode item 2 — sort trigger. ink (dark #FFFFFF == .white).
                .foregroundStyle(AppearancePalette.ink)
                .frame(height: 40)
                .padding(.horizontal, 14)
                .contentShape(Capsule())
                .chromeSurface(Capsule())
                .clipShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

// MARK: - Density pill

/// Bottom-anchored segmented Card View presentation control. Four SF Symbol
/// segments — tall card (Cover Flow carousel), 2x2 grid, 3x3 grid, and
/// vertical scroll (full-card stack) — driving the same
/// `@AppStorage("gridColumnCount")` the body switcher and NodeGridView
/// read (value 4 = vertical scroll routes to VerticalScrollView, never to
/// NodeGridView). Replaces the retired MagnifyGesture so a single canonical
/// control runs the default arm. Visibility is gated by the caller
/// (rides the "+" capture trigger's signal so it hides when the
/// Librarian rises above peek). Segments are sized for thumb tapping.
private struct DensityPill: View {
    @AppStorage("gridColumnCount") private var columnCount: Int = 2

    var body: some View {
        HStack(spacing: 0) {
            segment(value: 1, symbol: "rectangle.portrait")
            segment(value: 2, symbol: "square.grid.2x2")
            segment(value: 3, symbol: "square.grid.3x3")
            segment(value: 4, symbol: "rectangle.grid.1x2")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .chromeSurface(Capsule())
    }

    private func segment(value: Int, symbol: String) -> some View {
        Button {
            if columnCount != value {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                columnCount = value
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(columnCount == value ? AppearancePalette.ink : AppearancePalette.ink.opacity(0.55))
                .frame(width: 52, height: 40)
                .contentShape(Rectangle())
                .background {
                    if columnCount == value {
                        Capsule().fill(AppearancePalette.ink.opacity(0.15))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter panel

struct FilterPanelView: View {
    var scope: CanvasScope = .corpus

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var state: FilterState { store.filterState(for: scope) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    filterSection("Sort") {
                        HStack(spacing: 8) {
                            filterPill("Recent",       isActive: state.sortOrder == .recency)      { mutate { $0.sortOrder = .recency } }
                            filterPill("Alphabetical", isActive: state.sortOrder == .alphabetical) { mutate { $0.sortOrder = .alphabetical } }
                        }
                    }

                    filterSection("Type") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ItemTypeFilter.allCases, id: \.self) { type in
                                    filterPill(
                                        type.displayName,
                                        icon: type.icon,
                                        isActive: state.itemType == type
                                    ) { mutate { $0.itemType = type } }
                                }
                            }
                        }
                    }

                    // #9 — recency window (enum pills, mirrors "Type").
                    filterSection("When") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(RecencyFilter.allCases, id: \.self) { window in
                                    filterPill(
                                        window.displayName,
                                        icon: window.icon,
                                        isActive: state.recency == window
                                    ) { mutate { $0.recency = window } }
                                }
                            }
                        }
                    }

                    if !store.tags.isEmpty {
                        filterSection("Tag") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    filterPill("All", isActive: state.tagName == nil) {
                                        mutate { $0.tagName = nil }
                                    }
                                    ForEach(store.tags) { tag in
                                        filterPill(
                                            tag.name,
                                            color: Color(hex: tag.colorHex),
                                            isActive: state.tagName == tag.name
                                        ) { mutate { $0.tagName = tag.name } }
                                    }
                                }
                            }
                        }
                    }

                    // #9 — collection membership (mirrors the "Tag" section
                    // exactly: an "All" pill plus one pill per collection,
                    // single-select).
                    if !store.collections.isEmpty {
                        filterSection("Collection") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    filterPill("All", isActive: state.collectionID == nil) {
                                        mutate { $0.collectionID = nil }
                                    }
                                    ForEach(store.collections, id: \.id) { collection in
                                        filterPill(
                                            collection.name,
                                            isActive: state.collectionID == collection.id
                                        ) { mutate { $0.collectionID = collection.id } }
                                    }
                                }
                            }
                        }
                    }

                    filterSection("Threads") {
                        HStack(spacing: 8) {
                            ForEach(ThreadStatusFilter.allCases, id: \.self) { status in
                                filterPill(status.displayName, isActive: state.threadStatus == status) {
                                    mutate { $0.threadStatus = status }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
                if state.activeFilterCount > 0 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Clear all") { mutate {
                            $0.sortOrder = .recency
                            $0.itemType = .all
                            $0.tagName = nil
                            $0.threadStatus = .all
                            $0.recency = .all
                            $0.collectionID = nil
                        }}
                        .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.black)
    }

    private func mutate(_ block: (inout FilterState) -> Void) {
        var s = state
        block(&s)
        store.setFilterState(s, for: scope)
    }

    @ViewBuilder
    private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
            content()
        }
    }

    private func filterPill(
        _ label: String,
        icon: String? = nil,
        color: Color? = nil,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(label)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? .black : .white.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isActive ? (color ?? .white) : Color.white.opacity(0.09))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Import progress banner

private struct ImportProgressBanner: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(AppearancePalette.ink)
                .scaleEffect(0.75)
            Text("Importing \(total) ideas… (\(current)/\(total) processed)")
                .font(.caption.weight(.medium))
                .foregroundStyle(AppearancePalette.ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

// MARK: - iCloud banner

private struct iCloudUnavailableBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.caption)
            Text("iCloud unavailable — saving locally")
                .font(.caption)
        }
        .foregroundStyle(AppearancePalette.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}

// MARK: - Selection mode controls

private struct SelectionHeader: View {
    let count: Int
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(count == 0 ? "Select items" : "\(count) selected")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(AppearancePalette.bgElevated)
                .clipShape(Capsule())
            Spacer()
            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppearancePalette.bgElevated)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct BatchActionBar: View {
    let count: Int
    let scope: CanvasScope
    let tags: [Tag]
    let collections: [NodeCollection]
    let collectionLastUsedAt: [String: Date]
    let onDelete: () -> Void
    let onPickExistingTag: (String) -> Void
    let onAddNewTag: () -> Void
    let onAddToCollection: (String) -> Void
    let onRemoveFromCurrentCollection: () -> Void
    let onMoveToCollection: (String) -> Void

    private var isCollectionScope: Bool {
        if case .collection = scope { return true } else { return false }
    }

    /// Excluded from Add/Move pickers so the user can't pick the collection
    /// they're already in. Nil at corpus scope — picker shows everything.
    private var currentCollectionID: String? {
        if case .collection(let id) = scope { return id } else { return nil }
    }

    var body: some View {
        HStack(spacing: 12) {
            TagPickerButton(
                tags: tags,
                excludeNames: [],
                onPickExisting: onPickExistingTag,
                onAddNew: onAddNewTag
            ) {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Tag")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(AppearancePalette.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(AppearancePalette.bgElevated)
                .clipShape(Capsule())
            }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1.0)

            Menu {
                if isCollectionScope {
                    Menu {
                        CollectionPickerMenuContent(
                            collections: collections,
                            collectionLastUsedAt: collectionLastUsedAt,
                            excludeIDs: currentCollectionID.map { Set([$0]) } ?? [],
                            onPick: onAddToCollection
                        )
                    } label: {
                        Label("Add to…", systemImage: "plus")
                    }
                    Button {
                        onRemoveFromCurrentCollection()
                    } label: {
                        Label("Remove from current", systemImage: "minus")
                    }
                    Menu {
                        CollectionPickerMenuContent(
                            collections: collections,
                            collectionLastUsedAt: collectionLastUsedAt,
                            excludeIDs: currentCollectionID.map { Set([$0]) } ?? [],
                            onPick: onMoveToCollection
                        )
                    } label: {
                        Label("Move to…", systemImage: "arrow.right")
                    }
                } else {
                    CollectionPickerMenuContent(
                        collections: collections,
                        collectionLastUsedAt: collectionLastUsedAt,
                        excludeIDs: [],
                        onPick: onAddToCollection
                    )
                }
            } label: {
                Text("Organize")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(AppearancePalette.bgElevated)
                    .clipShape(Capsule())
            }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1.0)

            Button(action: onDelete) {
                Text("Delete")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.85))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1.0)
        }
    }
}

// MARK: - Chrome surface (Liquid Glass on 26+, .thinMaterial below)
// Internal (was private) so the dashboard upper-chrome pill (#3 follow-up) reuses
// the SAME standard chrome glass as the Map/Card/List chrome — not a second impl.

extension View {
    @ViewBuilder
    func chromeSurface<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.thinMaterial, in: shape)
        }
    }
}

// MARK: - #3 focus request (shared plumbing)
// The move handler + the glow live here beside `chromeSurface` because, like
// it, they are ONE treatment every canvas surface (Map / List / Grid /
// CoverFlow / vertical Card stack) reuses — the modifier owns the tricky parts
// so no surface re-implements them (and drifts, the BUG-10 failure mode).

/// The shared #3 focus-request handler. Each surface applies
/// `.onFocusRequest { id in … }` with its own move action (fly the camera /
/// scroll to the row). This modifier owns the parts identical across all of
/// them:
///   - observe `router.focusRequest?.token` so a repeat request for the SAME
///     node still fires (the token advances even when the nodeID repeats);
///   - ALSO run on `.onAppear`, so a surface that MOUNTS with an unhandled
///     request still lands it (capture-return sets the request before the
///     origin view re-appears; `.onChange` never fires for a value set before
///     mount — the exact silent miss this replaces);
///   - dedupe via a per-surface `lastHandledToken` so re-appearing after
///     already handling the current token does nothing;
///   - defer the move ONE runloop so a panel resize riding along with the
///     request (Librarian raiseToPeek) has applied its layout before a
///     `scrollTo` computes offsets — otherwise the scroll mis-lands.
private struct FocusRequestHandler: ViewModifier {
    @Environment(AppRouter.self) private var router
    let perform: (String) -> Void
    @State private var lastHandledToken = 0

    func body(content: Content) -> some View {
        content
            .onChange(of: router.focusRequest?.token) { _, _ in handle() }
            .onAppear { handle() }
    }

    private func handle() {
        guard let request = router.focusRequest,
              request.token != lastHandledToken else { return }
        lastHandledToken = request.token
        let nodeID = request.nodeID
        // One-runloop defer — see the doc comment (panel resize must land first).
        DispatchQueue.main.async { perform(nodeID) }
    }
}

extension View {
    /// Handle the shared #3 focus request with a per-surface move action.
    /// `perform` receives the node id to move the viewport to.
    func onFocusRequest(_ perform: @escaping (String) -> Void) -> some View {
        modifier(FocusRequestHandler(perform: perform))
    }
}

/// The shared focus HIGHLIGHT — a PERSISTENT Klein-blue → electric-cyan
/// gradient outline over the focused node's card/tile on the scrolling
/// surfaces (Grid, CoverFlow, vertical Card stack). List uses a full-strip fill
/// and Map a cyan orb ring (`CorpusPhysicsScene.applyFocusOutline`) instead —
/// same identity, per-surface treatment. Bound declaratively to
/// `router.focusedHighlightNodeID`, so it fades IN when this node becomes the
/// focus target and fades OUT when the user's next touch clears it (T: "persist
/// until the user's next touch"). A landed focus glows, a dropped one shows
/// nothing — still the diagnostic. Sensible defaults; T dials on device.
private struct FocusHighlight: ViewModifier {
    @Environment(AppRouter.self) private var router
    let nodeID: String
    var cornerRadius: CGFloat = 20
    private var isHighlighted: Bool { router.focusedHighlightNodeID == nodeID }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color(hexString: "1B59C2"), Color(hexString: "00BFFF")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .shadow(color: Color(hexString: "00BFFF").opacity(isHighlighted ? 0.7 : 0), radius: 10)
                    .opacity(isHighlighted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.25), value: isHighlighted)
    }
}

extension View {
    /// Draw the shared #3 focus glow on this node's cell while it is the focus
    /// target. `cornerRadius` should match the cell's own rounding.
    func focusHighlight(nodeID: String, cornerRadius: CGFloat) -> some View {
        modifier(FocusHighlight(nodeID: nodeID, cornerRadius: cornerRadius))
    }
}

/// Process-lifetime, window-level, non-consuming touch observer that clears the
/// persistent focus highlight on the user's next touch anywhere (T: "persist
/// until the user's next touch"). A 0-duration long-press fires on touch-DOWN;
/// `cancelsTouchesInView = false` + a simultaneous-recognition delegate mean it
/// only OBSERVES — it never steals a tap, a scroll, or a map pan. The creating
/// tap is safe: search / capture set the highlight on touch-UP, so this
/// recogniser's touch-DOWN for that same tap sees no highlight yet, and only a
/// SUBSEQUENT touch clears.
///
/// A SINGLETON (not a per-view coordinator) so exactly ONE recogniser is ever
/// installed per window — a per-mount coordinator would accumulate recognisers
/// as CanvasChrome remounts, since the window outlives each mount. Its `onTouch`
/// is refreshed each body eval to the current closure (which captures the stable
/// AppRouter singleton), and it lives for the process, so target lifetime is
/// never in question.
final class FocusDismissTouchMonitor: NSObject, UIGestureRecognizerDelegate {
    static let shared = FocusDismissTouchMonitor()
    var onTouch: (() -> Void)?
    private weak var installedWindow: UIWindow?

    func install(on window: UIWindow?) {
        guard let window, window !== installedWindow else { return }
        installedWindow = window
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(fire(_:)))
        recognizer.minimumPressDuration = 0
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
    }

    @objc private func fire(_ recognizer: UIGestureRecognizer) {
        if recognizer.state == .began { onTouch?() }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Zero-size bridge that hands the current window to `FocusDismissTouchMonitor`
/// and keeps its `onTouch` closure current. Mounted once in `CanvasChrome`.
struct FocusDismissTouchProbe: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = { window in
            FocusDismissTouchMonitor.shared.install(on: window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        FocusDismissTouchMonitor.shared.onTouch = onTouch
    }

    final class ProbeView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }
}

// MARK: - BUG 10: batch selection (ONE shared treatment)
// The SIBLING of the #3 focus highlight above — same shape (persistent state →
// a visual treatment) and the same Klein Blue identity, so the two can't drift.
// Where they MUST NOT share: focus is a GLOBAL, SINGLE-node glow off
// `AppRouter.focusedHighlightNodeID`, cleared on the next touch; selection is a
// PER-SCOPE, MULTI-node mode off `SelectionService`, entered/exited explicitly.
// Different state, different lifecycle — kept separate on purpose. The one
// visual overlap (both can outline a card in blue) is disambiguated by the
// CHECKMARK, which only selection draws.

/// The shared selection checkmark badge. CHECKMARK PRIMARY: a SHAPE affordance
/// that reads regardless of hue — T is colourblind, so a colour-only selection
/// state is exactly the wrong pattern — and it matches the Photos convention.
/// Picked → Klein-blue disc + white check; unpicked → an empty ring. Carries a
/// dark scrim disc + shadow so BOTH states stay legible over every backdrop
/// (bright photo thumbnails, gradient blobs, parchment) in either appearance.
struct SelectionCheckBadge: View {
    let isPicked: Bool
    var body: some View {
        ZStack {
            Circle()
                .fill(isPicked ? Color(hexString: "1B59C2") : Color.black.opacity(0.22))
                .frame(width: 26, height: 26)
            Circle()
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
                .frame(width: 26, height: 26)
            if isPicked {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

/// The ONE selection treatment applied to every card surface (Grid, List, Cover
/// Flow, vertical Card stack) so the affordance can't drift per-view (BUG 10 —
/// the disease was four call sites each inventing their own or none). Checkmark
/// primary (above); a Klein Blue `#1B59C2` OUTLINE (a hex literal T can verify
/// with a picker) is the raised-contrast secondary cue, shown on the picked
/// cell. `isSelecting` / `isPicked` are passed in — unlike focus's global state,
/// selection is per-scope, so the call site (which knows its scope) computes them.
private struct SelectionHighlight: ViewModifier {
    let isSelecting: Bool
    let isPicked: Bool
    var cornerRadius: CGFloat = 20
    var badgeAlignment: Alignment = .topTrailing
    /// The card surfaces draw the Klein outline; List sets this false because it
    /// carries its own whole-strip fill (an inset rounded outline doesn't hug a
    /// full-width row band — T's note). The checkmark stays either way.
    var outline: Bool = true

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(hexString: "1B59C2"),
                                  lineWidth: outline && isSelecting && isPicked ? 3 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: badgeAlignment) {
                if isSelecting {
                    SelectionCheckBadge(isPicked: isPicked)
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isSelecting)
            .animation(.easeInOut(duration: 0.18), value: isPicked)
    }
}

extension View {
    /// Apply the shared BUG-10 selection treatment (checkmark primary + Klein
    /// Blue outline secondary). `cornerRadius` should match the cell's rounding;
    /// `badgeAlignment` places the checkmark (corner for cards, trailing for rows).
    func selectionHighlight(isSelecting: Bool, isPicked: Bool,
                            cornerRadius: CGFloat,
                            badgeAlignment: Alignment = .topTrailing,
                            outline: Bool = true) -> some View {
        modifier(SelectionHighlight(isSelecting: isSelecting, isPicked: isPicked,
                                    cornerRadius: cornerRadius, badgeAlignment: badgeAlignment,
                                    outline: outline))
    }
}
