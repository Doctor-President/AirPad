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
    private let topInset: CGFloat = 110
    private let bottomInset: CGFloat = 120
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
    private static var tileSheen: some View {
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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottomTrailing) {
                AppearancePalette.mapBackground(dark: colorScheme == .dark).ignoresSafeArea()
                BackgroundGridView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                gridContent

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
                                animateGradient: true,
                                columnCount: columnCount
                            )
                            // Commit 3 — skip re-rendering tiles whose rendered
                            // fields didn't change (NodeTileView.==), so a single
                            // node's enrichment re-renders only its tile.
                            .equatable()
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
                                    navigationPath.append(node)
                                }
                            }
                            // #3 — shared focus glow (matches the tile's 14pt clip).
                            .focusHighlight(nodeID: node.id, cornerRadius: 14)
                        }
                    }
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

private struct NodeTileView: View, Equatable {
    let node: Node
    let isSelecting: Bool
    let isPicked: Bool
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let animateGradient: Bool
    let columnCount: Int

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
        l.node.id == r.node.id &&
        l.node.title == r.node.title &&
        l.node.summary == r.node.summary &&
        l.node.tags == r.node.tags &&
        l.node.items == r.node.items &&
        l.node.coverImageRelativePath == r.node.coverImageRelativePath &&
        l.node.descriptionOnCard == r.node.descriptionOnCard &&
        l.node.updatedAt == r.node.updatedAt
    }

    var body: some View {
        NodeGridTile(
            node: node,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            animateGradient: animateGradient,
            columnCount: columnCount
        )
        .frame(width: cellWidth, height: cellHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // BUG 10 — shared selection treatment (checkmark + Klein outline),
        // replacing the low-contrast white stroke that didn't read on parchment.
        .selectionHighlight(isSelecting: isSelecting, isPicked: isPicked, cornerRadius: 14)
    }
}
