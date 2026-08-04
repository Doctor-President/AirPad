import SwiftUI

// MARK: - VerticalScrollView

/// Vertical-scroll presentation of Card View — full-bleed NodeCardView faces
/// stacked in a viewAligned vertical scroll (one card centered at a time). FINITE
/// by design: a sorted corpus has a first and a last, so the scroll opens at the
/// first node (natural top) and stops at the last — no wrap. Wrapping past the
/// oldest back into the newest destroyed the sense of position against the sort
/// (T, 2026-07-29), so the sentinel loop was removed. Reached from the density
/// pill's 4th segment (`gridColumnCount == 4`) alongside carousel / 2-col / dense grid.
struct VerticalScrollView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var zoomNamespace
    @State private var navigationPath = NavigationPath()
    /// Node ID currently sitting at the top of the navigation stack
    /// after a router-driven push. Dedupes rapid multi-taps on the
    /// same Librarian match (which otherwise stack identical detail
    /// views). Cleared when the path returns to root.
    @State private var currentDetailNodeID: String? = nil
    @State private var displayItems: [Node] = []
    @State private var scrolledID: String? = nil

    @State private var scrollToFirstAfterSort = false
    /// What slice of the corpus this view renders. Defaults to `.corpus` so
    /// the existing ContentView call site keeps its behavior unchanged.
    /// Collection canvases pass `.collection(id)` once D1 wires them up.
    var scope: CanvasScope = .corpus
    @State private var centerIdx = 0

    // 5:7 editorial card face. Card width = screen × 0.9 (from the existing
    // `.padding(.horizontal, width * 0.05)` below); height + inter-card gap are
    // CardTuning dials (keyed `.vertical`). Defaults reproduce the prior baked
    // values (height ratio 0.9·7/5 = 1.26 × screen width; spacing 6).
    @AppStorage(CardTuningKey.key(.vertical, .height))
    private var heightRatio: Double = CardTuningDefaults.value(.vertical, .height)
    @AppStorage(CardTuningKey.key(.vertical, .spacing))
    private var cardSpacingRaw: Double = CardTuningDefaults.value(.vertical, .spacing)

    private var cardHeight: CGFloat { UIScreen.main.bounds.width * CGFloat(heightRatio) }
    private var cardSpacing: CGFloat { CGFloat(cardSpacingRaw) }
    private let topBarHeight: CGFloat = 110  // top chrome row + padding from ContentView
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let navHaptic = UIImpactFeedbackGenerator(style: .heavy)

    #if DEBUG
    @State private var showCardTuning = false
    @State private var cardTuningOffset: CGSize = .zero
    #endif

    var body: some View {
        GeometryReader { geo in
            NavigationStack(path: $navigationPath) {
                ZStack(alignment: .bottomTrailing) {
                    AppearancePalette.mapBackground(dark: colorScheme == .dark).ignoresSafeArea()
                    BackgroundGridView()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    cardScrollContent(containerHeight: geo.size.height)

                    #if DEBUG
                    cardTuningTrigger
                    if showCardTuning {
                        floatingCardTuningPanel
                    }
                    #endif
                }
                .navigationDestination(for: Node.self) { node in
                    NodeDetailView(nodeID: node.id)
                        .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
                }
                // In-detail link-following (backlinks, suggestion preview) STACKS
                // here — a standard push (no zoom source), so back returns to the
                // originating detail. See `NodeDetailRoute`.
                .navigationDestination(for: NodeDetailRoute.self) { route in
                    NodeDetailView(nodeID: route.nodeID, focusEntryID: route.entryID)
                }
                // §3 — Librarian search ROW tap pops the detail so the focus
                // lands on the visible surface (no-op at root).
                .onChange(of: router.dismissDetailRequest) { _, _ in
                    navigationPath = NavigationPath()
                }
                .onChange(of: router.pendingNodeNavigationID) { _, newValue in
                    guard let id = newValue,
                          let node = store.nodes.first(where: { $0.id == id })
                    else { return }
                    if id != currentDetailNodeID {
                        // Atomic wholesale assignment — single state mutation, so
                        // there's no transient depth-0 frame between removeLast and
                        // append (which let chrome bleed and let rapid taps stack).
                        // Rapid-fire taps converge to last-write-wins at depth=1.
                        navigationPath = NavigationPath([node])
                        currentDetailNodeID = id
                    }
                    router.pendingNodeNavigationID = nil
                }
                .onChange(of: navigationPath.count) { _, newCount in
                    // Authoritative depth signal. `navigationPath` only
                    // ever contains Node values (the sole
                    // `.navigationDestination(for: Node.self)`), so
                    // `count` is the detail depth. ContentView's
                    // `isInDetailView` handler reads this for first-
                    // enter / last-exit panel choreography.
                    store.detailViewDepth = newCount
                    // Back-out → root: clear so a subsequent tap on the
                    // same node pushes a fresh detail view.
                    if newCount == 0 { currentDetailNodeID = nil }
                }
            }
        }
        .onAppear {
            haptic.prepare()
            navHaptic.prepare()
            store.detailViewDepth = navigationPath.count
            buildItems()
        }
        // Observe the broad filteredNodes signal — for collection scopes this
        // still fires whenever any filter input changes; `buildItems` reads
        // through the scoped accessor.
        .onChange(of: store.filteredNodes) { _, _ in buildItems() }
        .onChange(of: store.filterState.sortOrder) { _, _ in
            buildItems()
            scrollToFirstAfterSort = true
        }
    }

    // MARK: - Card tuning (DEBUG)

    #if DEBUG
    private var cardTuningTrigger: some View {
        VStack {
            HStack {
                Button {
                    showCardTuning.toggle()
                } label: {
                    Image(systemName: "textformat.size")
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

    private var floatingCardTuningPanel: some View {
        VStack {
            Spacer()
            CardTuningPanel(
                isPresented: $showCardTuning,
                position: $cardTuningOffset
            )
            .padding(.bottom, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }
    #endif

    // MARK: - Scroll content

    private func cardScrollContent(containerHeight: CGFloat) -> some View {
        let margin = max(60, (containerHeight - cardHeight) / 2)
        let screenMidY = containerHeight / 2.0

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: cardSpacing) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, node in
                        let dist = abs(index - centerIdx)
                        // R2 — pass the ID + a snapshot fallback. The card
                        // owns the live lookup (mirrors NodeDetailView), so
                        // in-place fold/entry edits re-render the card in
                        // place without waiting for the scroll to recycle.
                        NodeCardView(
                            nodeID: node.id,
                            fallbackNode: node,
                            presentation: .vertical
                        )
                        .frame(height: cardHeight)
                        // #3 — shared focus glow (matches NodeCardView's 30pt face).
                        .focusHighlight(nodeID: node.id, cornerRadius: 30)
                        // BUG 10 — shared selection treatment (checkmark + Klein outline).
                        .selectionHighlight(isSelecting: selection.isActive,
                                            isPicked: selection.isSelected(node.id),
                                            cornerRadius: 30)
                        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: dist)
                        .animation(.easeInOut(duration: 0.18), value: selection.isActive)
                        .id(node.id)
                        .visualEffect { content, proxy in
                            let frame = proxy.frame(in: .global)
                            let screenHeight = UIScreen.main.bounds.height
                            let screenMidY = screenHeight / 2.0

                            // Vignette effect — top and bottom chrome zones
                            let topZoneBottom: CGFloat = 175
                            let bottomZoneTop: CGFloat = screenHeight - 140
                            let transitionWidth: CGFloat = 240

                            let distanceFromTop = max(0, topZoneBottom - frame.minY)
                            let distanceFromBottom = max(0, frame.maxY - bottomZoneTop)

                            let tTop = min(distanceFromTop / transitionWidth, 1.0)
                            let tBottom = min(distanceFromBottom / transitionWidth, 1.0)
                            let t = max(tTop, tBottom)
                            let tEased = t * t * (3 - 2 * t)

                            let vignetteOpacity = max(1.0, 1.0 - (tEased * 1.4))

                            // Scale effect — same curve as before, driven by pixel distance from center
                            let distanceFromCenter = abs(frame.midY - screenMidY)
                            let scaleT = min(distanceFromCenter / 420, 1.0)
                            let scale = max(0.75, 1.0 - scaleT * 0.25)

                            return content
                                .opacity(vignetteOpacity)
                                .scaleEffect(scale, anchor: .center)
                        }
                        .matchedTransitionSource(id: node.id, in: zoomNamespace)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let real = store.nodes.first(where: { $0.id == node.id }) else { return }
                            if selection.isActive {
                                haptic.impactOccurred()
                                selection.toggle(real.id)
                            } else {
                                navHaptic.impactOccurred()
                                navigationPath.append(real)
                            }
                        }
                    }
                }
                .padding(.horizontal, UIScreen.main.bounds.width * 0.05)
                .scrollTargetLayout()
            }
            .contentMargins(.vertical, margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledID)
            .onChange(of: scrolledID) { _, newID in
                guard let newID else { return }
                if let index = displayItems.firstIndex(where: { $0.id == newID }) {
                    centerIdx = index
                }
                haptic.impactOccurred()
            }
            .onChange(of: scrollToFirstAfterSort) { _, flag in
                guard flag, let firstID = displayItems.first?.id else { return }
                scrollToFirstAfterSort = false
                withAnimation(.spring(response: 0.4)) {
                    proxy.scrollTo(firstID, anchor: .center)
                }
            }
            // #3 — shared focus signal: scroll the card stack to the focused node
            // in place (cards are keyed by node id).
            .onFocusRequest { id in
                guard displayItems.contains(where: { $0.id == id }) else { return }
                withAnimation(.spring(response: 0.4)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Build display items

    private func buildItems() {
        // Finite, sorted order: the display list IS the filtered corpus, in order.
        // No sentinels, no wrap — the scroll opens at the first node (natural top)
        // and ends at the last, so position always reads true against the sort.
        displayItems = store.filteredNodes(in: scope)
    }
}

// MARK: - NodeCard

private struct NodeCard: View {
    let node: Node
    let namespace: Namespace.ID
    let screenMidY: CGFloat
    let onTap: () -> Void

    @Environment(CorpusStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            // Left color accent strip
            Rectangle()
                .fill(primaryTagColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(node.title.isEmpty ? "Untitled" : node.title)
                    .font(.headline)
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1)

                Text(node.summary.isEmpty ? "—" : node.summary)
                    .font(.subheadline)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                    .lineLimit(2)

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    NodeCardItemCounts(items: node.items)
                    Spacer()
                    Text(relativeTimestamp(node.createdAt))
                        .font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.38))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(primaryTagColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(primaryTagColor.opacity(0.22), lineWidth: 1))
        .matchedTransitionSource(id: node.id, in: namespace)
        .onTapGesture { onTap() }
        // Perspective scale + opacity — fades/shrinks cards away from center.
        // screenMidY is passed as a CGFloat (Sendable) to avoid UIScreen.main in a Sendable closure.
        .visualEffect { content, proxy in
            let frame = proxy.frame(in: .global)
            let distance = abs(frame.midY - screenMidY)
            let t = min(distance / 420, 1.0)
            return content
                .scaleEffect(1.0 - t * 0.08, anchor: .center)
                .opacity(1.0 - t * 0.28)
        }
    }

    private var primaryTagColor: Color {
        guard let name = node.primaryTag,
              let tag = store.tags.first(where: { $0.name == name })
        else { return Color(hex: "#8E8E93") ?? .gray }
        return Color(hex: tag.colorHex) ?? .gray
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<3600:        return "\(max(1, Int(diff / 60)))m ago"
        case ..<86400:       return "\(Int(diff / 3600))h ago"
        case ..<604800:      return "\(Int(diff / 86400))d ago"
        default:             return "\(Int(diff / 604800))w ago"
        }
    }
}

// MARK: - Item count chips

private struct NodeCardItemCounts: View {
    let items: [NodeItem]

    private var counts: (text: Int, image: Int, audio: Int, video: Int, link: Int, document: Int) {
        var t = 0, i = 0, a = 0, v = 0, l = 0, d = 0
        for item in items {
            switch item.type {
            case .text:     t += 1
            case .image:    i += 1
            case .audio:    a += 1
            case .video:    v += 1
            case .link:     l += 1
            case .document: d += 1
            // Stage 4.2 — gallery entries are surfaced under the image
            // chip pre-design of a dedicated gallery chip; the chip count
            // reflects how many entries hold media, not how many media items
            // they hold. Adequate until 4.2.x or 4.3 revisits list chips.
            case .imageVideo: i += 1
            // Stage 4.8 / 5.1 — Rating and fields don't surface in the legacy
            // six-bucket chip row; skipped (no dedicated chip yet).
            case .rating, .field:   break
            // ws-chat-lane — pinned-chats entry gets no legacy six-bucket chip.
            case .chats:            break
            }
        }
        return (t, i, a, v, l, d)
    }

    var body: some View {
        HStack(spacing: 8) {
            if counts.audio    > 0 { chip("mic",       counts.audio)    }
            if counts.image    > 0 { chip("photo",     counts.image)    }
            if counts.video    > 0 { chip("video",     counts.video)    }
            if counts.text     > 0 { chip("doc.text",  counts.text)     }
            if counts.link     > 0 { chip("link",      counts.link)     }
            if counts.document > 0 { chip("doc",       counts.document) }
        }
    }

    private func chip(_ icon: String, _ count: Int) -> some View {
        Label("\(count)", systemImage: icon)
            .font(.caption)
            .foregroundStyle(AppearancePalette.ink.opacity(0.48))
    }
}

// MARK: - Node extension for relativeTimestamp

extension Node {
    var relativeTimestamp: String {
        let diff = Date().timeIntervalSince(createdAt)
        switch diff {
        case ..<3600:        return "\(max(1, Int(diff / 60)))m ago"
        case ..<86400:       return "\(Int(diff / 3600))h ago"
        case ..<604800:      return "\(Int(diff / 86400))d ago"
        default:             return "\(Int(diff / 604800))w ago"
        }
    }
}
