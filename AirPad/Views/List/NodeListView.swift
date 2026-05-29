import SwiftUI

// MARK: - List node (wrapper for sentinel/real items in the looping scroll)

private struct ListItem: Identifiable {
    let id: String        // "real-<nodeID>" | "sent-start-<nodeID>" | "sent-end-<nodeID>"
    let node: Node
    var isReal: Bool { id.hasPrefix("real-") }
    var realNodeID: String { String(id.dropFirst(id.hasPrefix("real-") ? 5 : id.hasPrefix("sent-start-") ? 11 : 9)) }
}

// MARK: - NodeListView

struct NodeListView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(AppRouter.self) private var router
    @Namespace private var zoomNamespace
    @State private var navigationPath = NavigationPath()
    @State private var displayItems: [ListItem] = []
    @State private var scrolledID: String? = nil
    @State private var isJumping = false

    @State private var scrollToFirstAfterSort = false
    /// What slice of the corpus this list renders. Defaults to `.corpus` so
    /// the existing ContentView call site keeps its behavior unchanged.
    /// Collection canvases pass `.collection(id)` once D1 wires them up.
    var scope: CanvasScope = .corpus
    @State private var centerIdx = 0

    private let cardHeight: CGFloat = 168
    private let cardSpacing: CGFloat = 12
    private let topBarHeight: CGFloat = 110  // Graph/List toggle bar + padding from ContentView
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let navHaptic = UIImpactFeedbackGenerator(style: .heavy)

    var body: some View {
        GeometryReader { geo in
            NavigationStack(path: $navigationPath) {
                ZStack(alignment: .bottomTrailing) {
                    Color.black.ignoresSafeArea()
                    BackgroundGridView()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    listContent(containerHeight: geo.size.height)
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 100)
                        .allowsHitTesting(false)

                        Spacer()

                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 100)
                        .allowsHitTesting(false)
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                    if !store.isInDetailView {
                        VStack(spacing: 12) {
                            Spacer()
                            if !selection.isActive {
                                HStack {
                                    Spacer()
                                    captureTriggerButton
                                }
                            }
                            LibrarianSurface(hostScope: scope)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: router.librarian.surfaceMode)
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
                    navigationPath.append(node)
                    router.pendingNodeNavigationID = nil
                }
            }
        }
        .onAppear {
            haptic.prepare()
            navHaptic.prepare()
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

    // MARK: - Capture trigger

    /// "+" capture trigger — sits above the LibrarianSurface in the
    /// bottom-anchored VStack so it rides up with the morphing surface
    /// rather than overlapping it. Tap presents the in-app capture overlay
    /// (mounted at ContentView); navigation handoff arrives via
    /// `router.pendingNodeNavigationID` and is pushed onto our own
    /// `navigationPath`.
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

    // MARK: - Scroll content

    private func listContent(containerHeight: CGFloat) -> some View {
        let margin = max(60, (containerHeight - cardHeight) / 2)
        let screenMidY = containerHeight / 2.0

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: cardSpacing) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        let dist = abs(index - centerIdx)

                        NodeCardView(
                            node: item.node,
                            selected: index == centerIdx,
                            dist: dist,
                            isSelecting: selection.isActive,
                            isPicked: selection.isSelected(item.realNodeID)
                        )
                        .frame(height: cardHeight)
                        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: dist)
                        .animation(.easeInOut(duration: 0.18), value: selection.isActive)
                        .id(item.id)
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
                        .matchedTransitionSource(id: item.node.id, in: zoomNamespace)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let real = store.nodes.first(where: { $0.id == item.realNodeID }) else { return }
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
                guard let newID, !isJumping else { return }
                if let index = displayItems.firstIndex(where: { $0.id == newID }) {
                    centerIdx = index
                }
                haptic.impactOccurred()
                handleLoopJump(to: newID, proxy: proxy)
            }
            .onChange(of: scrollToFirstAfterSort) { _, flag in
                guard flag, let firstID = displayItems.first(where: { $0.isReal })?.id else { return }
                scrollToFirstAfterSort = false
                withAnimation(.spring(response: 0.4)) {
                    proxy.scrollTo(firstID, anchor: .center)
                }
            }
        }
    }

    // MARK: - Infinite loop handling

    private func handleLoopJump(to id: String, proxy: ScrollViewProxy) {
        guard id.hasPrefix("sent-") else { return }
        let realNodeID = id.hasPrefix("sent-start-")
            ? String(id.dropFirst(11))
            : String(id.dropFirst(10))
        guard let target = displayItems.first(where: { $0.id == "real-\(realNodeID)" }) else { return }
        isJumping = true
        proxy.scrollTo(target.id, anchor: .center)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isJumping = false }
    }

    // MARK: - Build display items

    private func buildItems() {
        let nodes = store.filteredNodes(in: scope)
        guard !nodes.isEmpty else { displayItems = []; return }

        let sentCount = min(3, nodes.count)
        var result: [ListItem] = []

        for node in nodes.suffix(sentCount) {
            result.append(ListItem(id: "sent-start-\(node.id)", node: node))
        }
        for node in nodes {
            result.append(ListItem(id: "real-\(node.id)", node: node))
        }
        for node in nodes.prefix(sentCount) {
            result.append(ListItem(id: "sent-end-\(node.id)", node: node))
        }
        displayItems = result
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
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(node.summary.isEmpty ? "—" : node.summary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)

                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    NodeCardItemCounts(items: node.items)
                    Spacer()
                    Text(relativeTimestamp(node.createdAt))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.38))
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
            .foregroundStyle(.white.opacity(0.48))
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
