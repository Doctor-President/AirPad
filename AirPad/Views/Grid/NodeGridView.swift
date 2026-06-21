import SwiftUI

// MARK: - NodeGridView
//
// Static, scroll-the-whole-corpus uniform-tile grid (Apple Photos /
// trading-card-binder model). Shell-only build 1 of the grid arc:
// scroll + pinch density step + tap-to-open + scroll-to-node seam.
// No header, sort UI, search, graze, or snapshot cache here — those
// land in later passes. The carousel (NodeListView) is parked, not
// deleted; CanvasChrome's else-branch points here instead.
//
// Mirrors NodeListView's shell wiring verbatim so the R5
// `detailViewDepth` invariant + router-driven Librarian-nav handoff
// keep working unchanged across the swap.

struct NodeGridView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(AppRouter.self) private var router
    @Namespace private var zoomNamespace

    var scope: CanvasScope = .corpus

    @State private var navigationPath = NavigationPath()
    /// Mirrors NodeListView's dedupe — Node ID currently sitting at
    /// the top of the navigation stack after a router-driven push.
    @State private var currentDetailNodeID: String? = nil

    @AppStorage("gridColumnCount") private var columnCount: Int = 2

    // 6-col was unbrowseable — tiles too small to read without grazing,
    // so it failed as a browse density. Ladder caps at 4.
    private let columnSteps: [Int] = [2, 3, 4]
    private let tileSpacing: CGFloat = 10
    private let topInset: CGFloat = 110
    private let bottomInset: CGFloat = 120
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let navHaptic = UIImpactFeedbackGenerator(style: .heavy)

    private var nodes: [Node] { store.filteredNodes(in: scope) }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottomTrailing) {
                Color.black.ignoresSafeArea()
                BackgroundGridView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                gridContent

                // Hide the "+" whenever the Librarian is raised above peek
                // (fix-pass v3 Item 2a) — same gating as NodeListView.
                if !store.isInDetailView && !selection.isActive && router.librarianAtPeek {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            captureTriggerButton
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 119)
                }
            }
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
                    .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
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
            let totalSpacing = tileSpacing * 2 + tileSpacing * CGFloat(columnCount - 1)
            let cellW = (geo.size.width - totalSpacing) / CGFloat(columnCount)
            let cellH = cellW * 7.0 / 5.0

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
                                isPicked: selection.isSelected(node.id),
                                cellWidth: cellW,
                                cellHeight: cellH,
                                animateGradient: columnCount == 2,
                                columnCount: columnCount
                            )
                            .frame(width: cellW, height: cellH)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
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
                        }
                    }
                    .padding(.horizontal, tileSpacing)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
                }
                .gesture(
                    MagnifyGesture().onEnded { value in
                        guard let i = columnSteps.firstIndex(of: columnCount) else {
                            columnCount = 2
                            return
                        }
                        // Spread (>1) = fewer/bigger; pinch (<1) = more/smaller.
                        if value.magnification > 1.2, i > 0 {
                            columnCount = columnSteps[i - 1]
                        } else if value.magnification < 0.8, i < columnSteps.count - 1 {
                            columnCount = columnSteps[i + 1]
                        }
                    }
                )
                .onChange(of: router.pendingGridScrollNodeID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    router.pendingGridScrollNodeID = nil
                }
            }
        }
    }

    // MARK: - Capture trigger

    private var captureTriggerButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            router.captureOverlay = CaptureOverlayContext(scope: scope)
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
    }
}

// MARK: - NodeTileView
// Thin cell wrapper around NodeGridTile — the lightweight browse primitive.
// Renders the tile directly at cell size (no native-design / scaleEffect
// trick the full card needed); the cell owns shape via `.frame` + `.clipShape`.

private struct NodeTileView: View {
    let node: Node
    let isPicked: Bool
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let animateGradient: Bool
    let columnCount: Int

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
        .overlay {
            if isPicked {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white, lineWidth: 3)
            }
        }
    }
}
