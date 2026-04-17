import SwiftUI

// MARK: - List node (wrapper for sentinel/real items in the looping scroll)

private struct ListItem: Identifiable {
    let id: String        // "real-<nodeID>" | "sent-start-<nodeID>" | "sent-end-<nodeID>"
    let node: Node
    var isReal: Bool { id.hasPrefix("real-") }
    var realNodeID: String { String(id.dropFirst(id.hasPrefix("real-") ? 5 : id.hasPrefix("sent-start-") ? 11 : 10)) }
}

// MARK: - NodeListView

struct NodeListView: View {

    @Environment(CorpusStore.self) private var store
    @Namespace private var zoomNamespace
    @State private var navigationPath = NavigationPath()
    @State private var displayItems: [ListItem] = []
    @State private var scrolledID: String? = nil
    @State private var isJumping = false

    private let cardHeight: CGFloat = 168
    private let cardSpacing: CGFloat = 12
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            NavigationStack(path: $navigationPath) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    listContent(containerHeight: geo.size.height)
                }
                .navigationDestination(for: Node.self) { node in
                    NodeDetailView(nodeID: node.id)
                        .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
                }
            }
        }
        .onAppear {
            haptic.prepare()
            buildItems()
        }
        .onChange(of: store.filteredNodes) { _, _ in buildItems() }
        .onChange(of: store.filterState.sortOrder) { _, _ in buildItems() }
        .onChange(of: navigationPath) { _, new in store.isInDetailView = !new.isEmpty }
    }

    // MARK: - Scroll content

    private func listContent(containerHeight: CGFloat) -> some View {
        let margin = max(60, (containerHeight - cardHeight) / 2)
        let screenMidY = containerHeight / 2.0

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: cardSpacing) {
                    ForEach(displayItems) { item in
                        NodeCard(
                            node: item.node,
                            namespace: zoomNamespace,
                            screenMidY: screenMidY,
                            onTap: {
                                guard let real = store.nodes.first(where: { $0.id == item.realNodeID }) else { return }
                                navigationPath.append(real)
                            }
                        )
                        .frame(height: cardHeight)
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.vertical, margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledID)
            .onChange(of: scrolledID) { _, newID in
                guard let newID, !isJumping else { return }
                haptic.selectionChanged()
                handleLoopJump(to: newID, proxy: proxy)
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
        let nodes = store.filteredNodes
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
        guard let name = node.tags.first,
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
