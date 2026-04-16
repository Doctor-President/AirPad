import SwiftUI

// MARK: - Node list view

/// Drum-roll scroll list mode. Magnetic snap to center, perspective scaling, haptics.
struct NodeListView: View {

    let namespace: Namespace.ID
    let onSelectNode: (Node) -> Void

    @Environment(CorpusStore.self) private var store
    @State private var centeredNodeID: String? = nil

    private var items: [Node] { store.filteredNodes }

    // Sentinel-padded list for the loop illusion.
    // We duplicate a small prefix+suffix so the scroll feels continuous.
    private static let sentinelCount = 3

    private var loopedItems: [LoopItem] {
        guard !items.isEmpty else { return [] }
        let head = items.suffix(Self.sentinelCount).map { LoopItem(node: $0, role: .headSentinel) }
        let body = items.map { LoopItem(node: $0, role: .body) }
        let tail = items.prefix(Self.sentinelCount).map { LoopItem(node: $0, role: .tailSentinel) }
        return head + body + tail
    }

    var body: some View {
        if items.isEmpty {
            emptyPlaceholder
        } else {
            LoopingScrollView(
                items: loopedItems,
                realCount: items.count,
                namespace: namespace,
                onCentered: { id in centeredNodeID = id },
                onSelectNode: onSelectNode
            )
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Text("No ideas match this filter.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - Loop item

private struct LoopItem: Identifiable {
    enum Role { case headSentinel, body, tailSentinel }
    let node: Node
    let role: Role
    var id: String { "\(role)-\(node.id)" }
}

// MARK: - Looping scroll view

private struct LoopingScrollView: View {

    let items: [LoopItem]
    let realCount: Int
    let namespace: Namespace.ID
    let onCentered: (String) -> Void
    let onSelectNode: (Node) -> Void

    @Environment(CorpusStore.self) private var store
    @State private var scrollPosition: String? = nil
    @State private var feedbackGenerator = UISelectionFeedbackGenerator()
    @State private var lastCenteredID: String? = nil

    // Stretch effect driven by scroll velocity
    @State private var stretchAmount: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    NodeCard(
                        node: item.node,
                        namespace: namespace,
                        isCentered: scrollPosition == item.id,
                        stretchAmount: stretchAmount,
                        onTap: { onSelectNode(item.node) }
                    )
                    .id(item.id)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 24)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $scrollPosition)
        .background(Color.black)
        .onAppear {
            feedbackGenerator.prepare()
            // Jump to first real item (after sentinels)
            if items.count > NodeListView.sentinelCount {
                scrollPosition = items[NodeListView.sentinelCount].id
            }
        }
        .onChange(of: scrollPosition) { _, newID in
            guard let newID else { return }
            handleCenterChange(to: newID)
        }
    }

    private func handleCenterChange(to id: String) {
        guard id != lastCenteredID else { return }
        lastCenteredID = id
        feedbackGenerator.selectionChanged()
        feedbackGenerator.prepare()

        if let item = items.first(where: { $0.id == id }) {
            onCentered(item.node.id)

            // Loop: if we land on a sentinel, silently jump to the real counterpart
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if item.role == .tailSentinel {
                    // Jumped past end — jump to real item at same offset
                    if let realIdx = items.firstIndex(where: {
                        $0.role == .body && $0.node.id == item.node.id
                    }) {
                        scrollPosition = items[realIdx].id
                    }
                } else if item.role == .headSentinel {
                    if let realIdx = items.lastIndex(where: {
                        $0.role == .body && $0.node.id == item.node.id
                    }) {
                        scrollPosition = items[realIdx].id
                    }
                }
            }
        }
    }
}

// MARK: - Node card

private struct NodeCard: View {

    let node: Node
    let namespace: Namespace.ID
    let isCentered: Bool
    let stretchAmount: CGFloat
    let onTap: () -> Void

    @Environment(CorpusStore.self) private var store

    private var primaryTagColor: Color {
        guard let tagName = node.tags.first,
              let tag = store.tags.first(where: { $0.name == tagName })
        else { return Color(hex: Tag.neutralColorHex) ?? .gray }
        return Color(hex: tag.colorHex) ?? .gray
    }

    // Thematic sort: color clusters shift together
    private var accentColor: Color { primaryTagColor }

    private var scale: CGFloat { isCentered ? 1.0 : 0.92 }
    private var opacity: Double { isCentered ? 1.0 : 0.72 }

    var body: some View {
        HStack(spacing: 0) {
            // Left color accent strip
            Rectangle()
                .fill(accentColor)
                .frame(width: 4)
                .clipShape(
                    .rect(topLeadingRadius: 16, bottomLeadingRadius: 16)
                )

            VStack(alignment: .leading, spacing: 8) {
                // Title
                Text(node.title.isEmpty ? "Untitled" : node.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                // Summary
                if !node.summary.isEmpty {
                    Text(node.summary)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    // Item type icons
                    ItemIconRow(items: node.items)
                    Spacer()
                    // Relative timestamp
                    RelativeTimestamp(date: node.createdAt)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accentColor.opacity(isCentered ? 0.4 : 0.12), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .scaleEffect(x: 1.0, y: scale + stretchAmount, anchor: .center)
        .opacity(opacity)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isCentered)
        .matchedTransitionSource(id: node.id, in: namespace)
        .onTapGesture { onTap() }
    }
}

// MARK: - Item icon row

private struct ItemIconRow: View {
    let items: [NodeItem]

    private struct TypeCount {
        var text = 0, image = 0, audio = 0, video = 0, link = 0, document = 0
    }

    private var counts: TypeCount {
        var c = TypeCount()
        for item in items {
            switch item.type {
            case .text:     c.text     += 1
            case .image:    c.image    += 1
            case .audio:    c.audio    += 1
            case .video:    c.video    += 1
            case .link:     c.link     += 1
            case .document: c.document += 1
            }
        }
        return c
    }

    var body: some View {
        HStack(spacing: 8) {
            if counts.text     > 0 { icon("doc.text",   counts.text)     }
            if counts.image    > 0 { icon("photo",       counts.image)    }
            if counts.audio    > 0 { icon("mic",         counts.audio)    }
            if counts.video    > 0 { icon("video",       counts.video)    }
            if counts.link     > 0 { icon("link",        counts.link)     }
            if counts.document > 0 { icon("doc",         counts.document) }
        }
    }

    private func icon(_ name: String, _ count: Int) -> some View {
        Label("\(count)", systemImage: name)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
    }
}

// MARK: - Relative timestamp

private struct RelativeTimestamp: View {
    let date: Date

    private var label: String {
        let interval = Date().timeIntervalSince(date)
        switch interval {
        case ..<3600:
            let hours = max(1, Int(interval / 60))
            return "\(hours)m ago"
        case ..<86400:
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        case ..<172800:
            return "Yesterday"
        default:
            let days = Int(interval / 86400)
            return "\(days) days ago"
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.35))
    }
}
