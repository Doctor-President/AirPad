import SwiftUI

// MARK: - NodeGridView
//
// Static, scroll-the-whole-corpus uniform-tile grid (Apple Photos /
// trading-card-binder model). Shell-only build 1 of the grid arc:
// scroll + tap-to-open + scroll-to-node seam. Density (2 vs 3 cols)
// is driven by the top-center DensityPill in CanvasChrome; the pinch
// gesture was retired so there's a single canonical control.
// No header, sort UI, search, graze, or snapshot cache here — those
// land in later passes. The carousel (VerticalScrollView) is parked, not
// deleted; CanvasChrome's else-branch points here instead.
//
// Mirrors VerticalScrollView's shell wiring verbatim so the R5
// `detailViewDepth` invariant + router-driven Librarian-nav handoff
// keep working unchanged across the swap.

struct NodeGridView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    /// Brief BF — passed into each `NodeTileView` so a live Font switch reaches the
    /// `.equatable()`-wrapped tiles (it's part of `NodeTileView.==`).
    @Environment(\.appBodyFont) private var appFont
    @Namespace private var zoomNamespace

    var scope: CanvasScope = .corpus

    @State private var navigationPath = NavigationPath()
    /// Mirrors VerticalScrollView's dedupe — Node ID currently sitting at
    /// the top of the navigation stack after a router-driven push.
    @State private var currentDetailNodeID: String? = nil

    @AppStorage("gridColumnCount") private var columnCount: Int = 2

    /// Owned by the grid so the scrubber can interrupt any in-flight scroll
    /// deceleration at scrub-start (see `StopperProbe` mounted below).
    @State private var momentumStopper = ScrollMomentumStopper()

    #if DEBUG
    /// DEBUG-only — toggled by the tiny ⚙ in the top-leading corner.
    /// v3: floating overlay widget instead of a sheet, so the grid stays
    /// scrollable behind it. Not compiled in release builds.
    @State private var showTileTuningPanel = false
    /// Drag offset for the floating widget. Owned by the parent so the
    /// widget's position survives close/re-open within a session.
    @State private var tuningPanelOffset: CGSize = .zero
    #endif

    private let tileSpacing: CGFloat = 10
    /// Mac D fix-up F3 — the card size on the Mac: a width the columns stay near (slider in the Cards header, ⌘+ / ⌘−,
    /// ⌘0 back to the default), remembered. Every card renders the iPhone's 2-column design scaled to it. Batch E4: the
    /// default is T's v3 pick, 210 (was 260); a size the user set stays theirs (the key holds it).
    static let macCardWidthDefault: Double = 210
    static let macCardWidthRange: ClosedRange<Double> = 160...440
    static let macCardWidthStep: Double = 40
    static let macCardWidthKey = "mac.cards.width.v1"
    /// The iPhone's 2-column card width (a 440 pt screen: (440 − 3 × 10) / 2), the size the card is designed at.
    static let macCardDesignWidth: CGFloat = 205
    @AppStorage(NodeGridView.macCardWidthKey) private var macCardWidth: Double = NodeGridView.macCardWidthDefault
    /// E fix-up 6 (M4) — the card under the pointer: one tracker for the grid (the List's K3 fix), not a hover and a
    /// right-click responder per card.
    @State private var macHover = MacListHover()
    @State private var macScroll = MacScrollState()
    private var topInset: CGFloat { RunningOnMac.isMac ? 6 : 110 }
    private var bottomInset: CGFloat { RunningOnMac.isMac ? 24 : 120 }
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let navHaptic = UIImpactFeedbackGenerator(style: .heavy)

    // R6 — raised-panel float cue on grid tiles: mirrors NodeCardView's
    // top-edge rim light + specular sheen, tuned separately for the smaller
    // 14pt-radius tile. Two faint intensities, dial on device — the gradient
    // art stays the hero. The tile owns no clip (NodeGridView clips at 14), so
    // the cue is applied here around that clip.
    private static let tileRimOpacity: Double = 0.24    // top-edge white rim light
    private static let tileSheenOpacity: Double = 0.14  // specular top sheen
    private static let tileRimWidth: CGFloat = 1.5       // rim hairline width

    /// Approx carousel-card width. The tile lift shadow scales DOWN from the
    /// carousel's radius-12 / y-4 by `cellW / this`, so a small tile gets a
    /// proportionally lighter shadow (a big card's shadow reads heavy on a
    /// small tile). Sets only the shadow's relative heft, not layout — a rough
    /// anchor is fine. The warm color is the shared `AppearancePalette.cardShadow`.
    private static let cardShadowReferenceWidth: CGFloat = 360

    /// Faint glassy highlight at the tile's top edge, fading out fast. Applied
    /// pre-clip so it's masked to the rounded tile shape.
    static var tileSheen: some View {   // internal: the live-23 card showcase renders the same tile
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(tileSheenOpacity),        location: 0.0),
                .init(color: Color.white.opacity(tileSheenOpacity * 0.35), location: 0.12),
                .init(color: Color.clear,                                  location: 0.40)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var nodes: [Node] { store.filteredNodes(in: scope) }

    /// Per-sort scrubber mode. >15 threshold skips the rail on tiny corpora;
    /// above it, both remaining sorts (recency, alphabetical) always vend a
    /// rail, so sort-switching never reflows the grid. `.thematic` is retired
    /// from the UI and normalized to `.recency` by `CorpusStore.filterState`
    /// on read — the branch here just satisfies switch exhaustiveness and
    /// is effectively unreachable.
    private var scrubberMode: ScrubMode? {
        guard nodes.count > 15 else { return nil }
        switch store.filterState(for: scope).sortOrder {
        case .alphabetical:
            let regions = AlphabetScrubber.alphabeticalRegions(for: nodes)
            return regions.isEmpty ? nil : .discrete(regions)
        case .recency:
            guard let timeline = AlphabetScrubber.recencyTimeline(for: nodes) else { return nil }
            return .continuous(timeline)
        case .thematic:
            return nil
        }
    }

    private var macIsolationKey: [AnyHashable] {
        var k: [AnyHashable] = [scope, colorScheme, appFont, columnCount, macCardWidth]
        #if DEBUG
        k.append(showTileTuningPanel)
        #endif
        return k
    }

    var body: some View {
        let _ = Perf.body(Self.self)   // perf recorder (P6): counts this rebuild
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottomTrailing) {
                AppearancePalette.libraryBackground(dark: colorScheme == .dark).ignoresSafeArea()
                BackgroundGridView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if RunningOnMac.isMac && !perfAB("noisolate") {
                    // E fix-up 5 (L1) — not re-run by the stack's path (opening / closing an entry); the key is every
                    // value of this view the cards read (the store, router and selection are tracked by the cards).
                    PathIsolated(key: macIsolationKey) {
                        VStack(spacing: 0) {
                            macCardsHeader
                            gridContent
                        }
                    }
                    .equatable()
                } else if RunningOnMac.isMac {
                    VStack(spacing: 0) {
                        macCardsHeader
                        gridContent
                    }
                } else {
                    gridContent
                }

                #if DEBUG
                tileTuningTrigger
                if showTileTuningPanel {
                    floatingTuningPanel
                }
                #endif
            }
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
                    .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
            }
            // In-detail link-following (backlinks, suggestion preview) STACKS
            // here so back returns to the originating detail. See `NodeDetailRoute`.
            .navigationDestination(for: NodeDetailRoute.self) { route in
                NodeDetailView(nodeID: route.nodeID, focusEntryID: route.entryID)
            }
            // §3 — search ROW tap pops the detail so the focus is visible.
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
            // Clamp any out-of-ladder values back into {1, 2, 3, 4}. This
            // host only ever runs at 2 or 3; 1 routes to CoverFlowView and 4
            // to VerticalScrollView at the CanvasChrome switch, so the clamp
            // leaves both alone so the density pill can swap to those bodies
            // without first bouncing through a re-clamp here.
            if columnCount != 1 && columnCount != 2 && columnCount != 3 && columnCount != 4 {
                columnCount = 2
            }
            haptic.prepare()
            navHaptic.prepare()
            store.detailViewDepth = navigationPath.count
        }
    }

    // MARK: - Grid content

    /// Mac D fix-up F3 — "N entries" and the card-size slider (small card · slider · large card), as in Photos / Finder.
    private var macCardsHeader: some View {
        HStack(spacing: 10) {
            Text("\(nodes.count) \(nodes.count == 1 ? "entry" : "entries")")
                .font(appFont.font(size: 13, weight: .medium))
                .groundInk(0.55)
            Spacer()
            Image(systemName: "rectangle.portrait").font(.system(size: 10, weight: .medium)).groundInk(0.5)
            Slider(value: $macCardWidth, in: Self.macCardWidthRange)
                .frame(width: 140)
                .tint(AppearancePalette.ink.opacity(0.6))
                .accessibilityLabel("Card size")
                .accessibilityIdentifier("cardsSizeSlider")
                .help("Card size (⌘+ / ⌘−)")
            Image(systemName: "rectangle.portrait").font(.system(size: 15, weight: .medium)).groundInk(0.5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .onChange(of: router.commandRequest) { _, request in
            // G3 — strictly Cards': only while the cards are the visible view (not under an open entry).
            let mode = store.filterState(for: scope).viewMode
            guard !store.isInDetailView, mode != .list, mode != .systemGraph else { return }
            switch request?.command {
            case .zoomIn?:  macCardWidth = macZoomedWidth(bigger: true)
            case .zoomOut?: macCardWidth = macZoomedWidth(bigger: false)
            case .zoomFit?: macCardWidth = Self.macCardWidthDefault
            default: break
            }
        }
    }

    /// Mac perf audit P0d (measured with real keys: of 16 presses, 5 changed nothing on screen) — ⌘+ / ⌘− used to move
    /// the wanted card width by 40 pt, but the grid shows whole columns, so a step that didn't cross into another
    /// column count changed nothing ("⌘+ sometimes doesn't register"). Now a press moves to the nearest width that
    /// gives one column fewer (bigger cards) or one more (smaller); at the last column count the range allows, nothing.
    /// `-MacPerfAB oldzoom` (bench) = the fixed 40 pt step.
    private func macZoomedWidth(bigger: Bool) -> Double {
        let range = Self.macCardWidthRange
        let avail = macGridWidth - tileSpacing - (scrubberMode != nil ? 30 : 0)
        guard avail > 0, !perfAB("oldzoom") else {
            return min(max(macCardWidth + (bigger ? 1 : -1) * Self.macCardWidthStep, range.lowerBound), range.upperBound)
        }
        func columns(_ w: Double) -> Int { max(1, Int((avail / (CGFloat(w) + tileSpacing)).rounded())) }
        let now = columns(macCardWidth), d = bigger ? 5.0 : -5.0
        var w = macCardWidth
        while range.contains(w + d) {
            w += d
            if columns(w) != now { return w }
        }
        return macCardWidth   // already at the largest / smallest the window allows
    }
    /// The grid's width, for `macZoomedWidth`: kept outside SwiftUI's state so noting it never re-evaluates anything.
    private var macGridWidth: CGFloat { macGridWidthBox.value }
    @State private var macGridWidthBox = WidthBox()
    private final class WidthBox { var value: CGFloat = 0 }
    private func macNoteGridWidth(_ w: CGFloat) { macGridWidthBox.value = w }

    private var gridContent: some View {
        // Width is measured ONCE here, above the ScrollView. cellW/cellH are
        // the single source of truth and get handed down to each tile.
        // The cell wrapper owns the 5:7 shape via .frame + .clipShape; the
        // tile content fills and is clipped — it never carries the ratio.
        GeometryReader { geo in
            // Reserve a right-edge gutter only when a rail is actually
            // present. Now that thematic is retired (normalized to recency
            // on read), the two remaining sorts both vend a rail above the
            // >15 node threshold — so within a given view the lane is either
            // always-on (large corpus) or always-off (small corpus), and
            // sort-switching never reflows the grid. ≤15 reclaims the lane.
            let railLane: CGFloat = scrubberMode != nil ? 30 : 0
            let _ = macNoteGridWidth(geo.size.width)
            // Mac D fix-up F3 — on the Mac as many columns as keep the cards nearest the chosen size.
            let columnCount = RunningOnMac.isMac
                ? max(1, Int(((geo.size.width - tileSpacing - railLane) / (CGFloat(macCardWidth) + tileSpacing)).rounded()))
                : self.columnCount
            let totalSpacing = tileSpacing * 2 + tileSpacing * CGFloat(columnCount - 1) + railLane
            let cellW = (geo.size.width - totalSpacing) / CGFloat(columnCount)
            let cellH = cellW * 7.0 / 5.0
            // Carousel-parity lift, scaled to the tile width (same for every
            // tile in a density) so grid cards separate from the parchment.
            let shadowScale = min(cellW / Self.cardShadowReferenceWidth, 1)
            let isDarkMode = colorScheme == .dark
            let tileShadowRadius = CardSurfaceResolved.shadowRadius(dark: isDarkMode)
            let tileShadowY = CardSurfaceResolved.shadowY(dark: isDarkMode)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(cellW), spacing: tileSpacing),
                            count: columnCount
                        ),
                        spacing: tileSpacing
                    ) {
                        ForEach(nodes) { node in
                            NodeTileView(
                                node: node,
                                isSelecting: selection.isActive,
                                isPicked: selection.isSelected(node.id),
                                cellWidth: cellW,
                                cellHeight: cellH,
                                animateGradient: !perfAB("cardstatic"),   // perf audit A/B
                                columnCount: RunningOnMac.isMac ? 2 : columnCount,   // F3 — the editorial card at every size
                                designWidth: RunningOnMac.isMac ? Self.macCardDesignWidth : nil,
                                appFont: appFont
                            )
                            // Commit 3 — skip re-rendering tiles whose rendered
                            // fields didn't change (NodeTileView.==), so a single
                            // node's enrichment re-renders only its tile.
                            .equatable()
                            // E fix-up 6 (M4) — on the Mac nothing inside a card takes the pointer (the card opens with
                            // the tap below, its menu is the grid's): SwiftUI then stops hit-testing every card's drawn
                            // views (the gradient's Metal view among them) on each hover event, which fires every frame
                            // while the grid scrolls under a still pointer (A/B, same session: 45 → 52 fps).
                            .allowsHitTesting(!RunningOnMac.isMac)
                            .frame(width: cellW, height: cellH)
                            // R6 — specular sheen over the tile content, masked
                            // to the tile shape by the clip that follows.
                            .overlay(Self.tileSheen)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            // Warm, appearance-adaptive lift — the SAME
                            // AppearancePalette.cardShadow the carousel uses,
                            // scaled down to the tile so it separates from the
                            // parchment without reading heavy. Cast by the
                            // clipped shape (drawn outside the clip).
                            .shadow(color: AppearancePalette.cardShadow,
                                    radius: tileShadowRadius * shadowScale,
                                    x: 0,
                                    y: tileShadowY * shadowScale)
                            // R6 — top-edge rim light on the rounded edge.
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(
                                        CardSurfaceResolved.rimGradient(dark: colorScheme == .dark),
                                        lineWidth: CardSurfaceResolved.rimWidth(dark: colorScheme == .dark)
                                    )
                                    .allowsHitTesting(false)
                            )
                            // Emboss — same builder as the carousel card.
                            .overlay(CardEmbossOverlay(cornerRadius: 14))
                            .matchedTransitionSource(id: node.id, in: zoomNamespace)
                            .id(node.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selection.isActive {
                                    haptic.impactOccurred()
                                    selection.toggle(node.id)
                                } else {
                                    navHaptic.impactOccurred()
                                    // live-16 — the tile showed the cover (cached → pushes at once); prewarm the gallery's first photos.
                                    store.openAfterPrewarm(node) { macNavigate { navigationPath.append(node) } }
                                }
                            }
                            // #3 — shared focus glow (matches the tile's 14pt clip).
                            .focusHighlight(nodeID: node.id, cornerRadius: 14)
                            .modifier(CardPointerResponders(node: node, hover: macHover))   // Mac batch C5 / E fix-up 6 M4
                            // A3 — one tile per entry, findable by id (the duplicate-entry check).
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("cardTile-\(node.id)")
                        }
                    }
                    .modifier(MacCardsGridResponders(hover: macHover, nodes: nodes))
                    .modifier(MacScrollHitGate(state: macScroll))
                    .modifier(CardsPlaceShowing())   // sweep 1 · 1.5 (sheet E)
                    .onChange(of: columnCount) { macHover.frames = [:] }
                    .onChange(of: cellW) { macHover.frames = [:] }
                    .padding(.leading, tileSpacing)
                    .padding(.trailing, tileSpacing + railLane)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)

                    // Plants a zero-size UIView inside the ScrollView so the
                    // momentum stopper can walk up to the host UIScrollView
                    // and cancel deceleration when a scrub begins.
                    StopperProbe(stopper: momentumStopper)
                        .frame(width: 0, height: 0)
                }
                .onScrollPhaseChange { _, phase in if RunningOnMac.isMac { macScroll.scrolling = phase != .idle } }   // E fix-up 6 (M4)
                // #3 — shared focus signal: scroll the grid to the focused tile.
                .onFocusRequest { id in
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .overlay { scrubberOverlay(proxy: proxy) }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: columnCount)
    }

    @ViewBuilder
    private func scrubberOverlay(proxy: ScrollViewProxy) -> some View {
        if let mode = scrubberMode {
            AlphabetScrubber(
                mode: mode,
                scrollTo: { id in
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                },
                onScrubBegin: { momentumStopper.stop() }
            )
        }
    }

    // MARK: - Tile tuning trigger (DEBUG)

    #if DEBUG
    /// Tiny ⚙ in the top-leading corner. Faint and small so it doesn't
    /// distract in normal use; tap shows/hides the floating tuning widget.
    private var tileTuningTrigger: some View {
        VStack {
            HStack {
                Button {
                    showTileTuningPanel.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
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
    }

    /// Floating tuning widget: bottom-center default, ~80pt above the safe
    /// area. The widget itself owns the drag offset (committed back into
    /// `tuningPanelOffset` on .onEnded), so position persists across
    /// close/re-open within a session.
    private var floatingTuningPanel: some View {
        VStack {
            Spacer()
            TileTuningPanel(
                isPresented: $showTileTuningPanel,
                position: $tuningPanelOffset
            )
            .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }
    #endif
}

// MARK: - NodeTileView
// Thin cell wrapper around NodeGridTile — the lightweight browse primitive.
// Renders the tile directly at cell size (no native-design / scaleEffect
// trick the full card needed); the cell owns shape via `.frame` + `.clipShape`.

/// E fix-up 6 (M4) — T: Cards scrolling slows "here and there" (the List is fine). Each card carried its own hover
/// and right-click responders, which SwiftUI hit-tests on every scroll event (fix-up 4 measured this on the List: a
/// third of the main thread). On the Mac the grid has one hover tracker and one right-click menu for the card under
/// the pointer (`MacListHover`, the List's); each card only reports its frame in the grid (once per layout, not per
/// scroll) and draws its wash from the tracker. iPhone / iPad: the per-card modifiers as before.
private struct CardPointerResponders: ViewModifier {
    let node: Node
    let hover: MacListHover
    func body(content: Content) -> some View {
        if RunningOnMac.isMac {
            content
                .overlay(CardHoverWash(hover: hover, id: node.id))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("macCardsGrid")) } action: { hover.frames[node.id] = $0 }
        } else {
            content
                .pointerHover(cornerRadius: 14)
                .entryContextMenu(node)
        }
    }
}

private struct CardHoverWash: View {
    let hover: MacListHover
    let id: String
    var body: some View {
        let on = hover.id == id || PointerHover<RoundedRectangle>.forced
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppearancePalette.ink.opacity(on ? 0.05 : 0))
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

private struct MacCardsGridResponders: ViewModifier {
    let hover: MacListHover
    let nodes: [Node]
    func body(content: Content) -> some View {
        if RunningOnMac.isMac {
            content
                .coordinateSpace(.named("macCardsGrid"))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hover.listGlobal = $0 }
                .onContinuousHover(coordinateSpace: .global) { phase in
                    switch phase {
                    case .active(let g): hover.pointer(global: g)
                    case .ended: hover.pointer(global: nil)
                    }
                }
                .contextMenu { MacCardMenu(hover: hover, nodes: nodes) }
        } else {
            content
        }
    }
}

/// E fix-up 6 (M4) — while the grid scrolls on the Mac its cards take no pointer events. Catalyst sends a hover event
/// every frame the content moves under a still pointer, and SwiftUI answers each with a hit-test that walks down
/// through the navigation container into every card's tap and shape responders (17 % of the main thread while
/// scrolling, after the cards' own views were taken out). The scroll view itself still scrolls; a click stops the
/// momentum as before; hit-testing returns at rest. Only this modifier re-evaluates when the phase flips, not the grid.
@Observable final class MacScrollState { var scrolling = false }

private struct MacScrollHitGate: ViewModifier {
    let state: MacScrollState
    func body(content: Content) -> some View {
        content.allowsHitTesting(!(RunningOnMac.isMac && state.scrolling && !perfAB("nogate")))   // perf audit A/B
    }
}

/// The grid's right-click menu: the entry menu for the card under the pointer (nothing between cards).
private struct MacCardMenu: View {
    let hover: MacListHover
    let nodes: [Node]
    @Environment(AppRouter.self) private var router
    var body: some View {
        if let id = hover.id, let node = nodes.first(where: { $0.id == id }) {
            EntryContextMenu.items(nodeID: node.id, isPrivate: node.isPrivate, router: router)
        }
    }
}

private struct NodeTileView: View, Equatable {
    let node: Node
    let isSelecting: Bool
    let isPicked: Bool
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let animateGradient: Bool
    let columnCount: Int
    /// Mac D fix-up F3 — see `NodeGridTile.designWidth`.
    var designWidth: CGFloat? = nil
    /// Brief BF — the app-wide content face. This wrapper is `.equatable()`, so a live Font
    /// switch is invisible to it unless the face is in `==`; the inner `NodeGridTile` reads
    /// the same face from `@Environment` and re-renders when this wrapper does.
    let appFont: EntryBodyFont
    /// Sweep 1 · 1.5 (sheet E) — on screen (any part of the card inside the scroll view's bounds).
    @State private var onScreen = false
    @Environment(\.cardsPlaceShowing) private var placeShowing

    // Commit 3 — targeted re-render. `Node.==` is id-only, so SwiftUI's default
    // diff hides title/summary/etc. edits and the tile renders stale until a
    // structural rebuild. Diff on EXACTLY the fields this tile renders (see
    // NodeGridTile body) plus its layout/selection inputs, so a single node's
    // display change re-renders ONLY its tile — no whole-array storm.
    static func == (l: NodeTileView, r: NodeTileView) -> Bool {
        l.isSelecting == r.isSelecting &&
        l.isPicked == r.isPicked &&
        l.cellWidth == r.cellWidth &&
        l.cellHeight == r.cellHeight &&
        l.animateGradient == r.animateGradient &&
        l.columnCount == r.columnCount &&
        l.designWidth == r.designWidth &&
        l.node.id == r.node.id &&
        l.node.title == r.node.title &&
        l.node.summary == r.node.summary &&
        l.node.tags == r.node.tags &&
        l.node.items == r.node.items &&
        l.node.coverImageRelativePath == r.node.coverImageRelativePath &&
        l.node.descriptionOnCard == r.node.descriptionOnCard &&
        l.node.updatedAt == r.node.updatedAt &&
        l.appFont == r.appFont
    }

    var body: some View {
        let _ = Perf.body(Self.self)   // perf recorder (P6): counts this rebuild
        NodeGridTile(
            node: node,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            animateGradient: animateGradient,
            columnCount: columnCount,
            designWidth: designWidth
        )
        .frame(width: cellWidth, height: cellHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // BUG 10 — shared selection treatment (checkmark + Klein outline),
        // replacing the low-contrast white stroke that didn't read on parchment.
        .selectionHighlight(isSelecting: isSelecting, isPicked: isPicked, cornerRadius: 14)
        .environment(\.blobFieldPaused, !(onScreen && placeShowing))
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
    }
}

/// Sweep 1 · 1.5 (sheet E) — Cards is the place the user sees: no entry open over it, the app active.
private struct CardsPlaceShowingKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var cardsPlaceShowing: Bool {
        get { self[CardsPlaceShowingKey.self] }
        set { self[CardsPlaceShowingKey.self] = newValue }
    }
}

/// Reads the open-entry flag and the scene phase HERE, so a push / pop doesn't re-run the grid's body (L1).
private struct CardsPlaceShowing: ViewModifier {
    @Environment(CorpusStore.self) private var store
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.environment(\.cardsPlaceShowing, !store.isInDetailView && phase == .active)
    }
}
