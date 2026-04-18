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

    @State private var scrollToFirstAfterSort = false
    @State private var fanExpanded = false
    @State private var captureMode: ListCaptureMode? = nil
    @State private var captureTargetNodeID: String? = nil
    @State private var showingNodePicker = false

    private let cardHeight: CGFloat = 168
    private let cardSpacing: CGFloat = 12
    private let haptic = UISelectionFeedbackGenerator()

    enum ListCaptureMode: String, Identifiable {
        case voice, text, camera
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geo in
            NavigationStack(path: $navigationPath) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    listContent(containerHeight: geo.size.height)
                    ActionButtonFan(
                        isExpanded: $fanExpanded,
                        isEmpty: store.nodes.isEmpty,
                        onVoice:       { captureMode = .voice },
                        onCamera:      { captureMode = .camera },
                        onText:        { captureMode = .text },
                        onNodePicker:  { showingNodePicker = true },
                        onAddToRecent: { captureTargetNodeID = store.nodes.first?.id }
                    )
                }
                .navigationDestination(for: Node.self) { node in
                    NodeDetailView(nodeID: node.id)
                        .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
                }
                .sheet(item: $captureMode) { mode in
                    switch mode {
                    case .voice:  VoiceCaptureSheet(targetNodeID: captureTargetNodeID)
                    case .text:   TextCaptureSheet(targetNodeID: captureTargetNodeID)
                    case .camera: CameraCaptureView(targetNodeID: captureTargetNodeID)
                    }
                }
                .sheet(isPresented: $showingNodePicker) {
                    NodePickerSheet(selectedNodeID: $captureTargetNodeID)
                }
                .onChange(of: captureMode) { _, mode in
                    if mode != nil { fanExpanded = false }
                    if mode == nil { captureTargetNodeID = nil }
                }
            }
        }
        .onAppear {
            haptic.prepare()
            buildItems()
        }
        .onChange(of: store.filteredNodes) { _, _ in buildItems() }
        .onChange(of: store.filterState.sortOrder) { _, _ in
            buildItems()
            scrollToFirstAfterSort = true
        }
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
                            isSelected: scrolledID == item.id,
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
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(CorpusStore.self) private var store

    var body: some View {
        ZStack {
            // Luminous glow border — only for the centered/selected card
            if isSelected {
                RoundedRectangle(cornerRadius: 20)
                    .fill(primaryTagColor.opacity(0.30))
                    .blur(radius: 12)
                    .padding(-10)
            }

            // Card face
            ZStack(alignment: .trailing) {
                // Gradient fill — tag color bleeding into warm amber/sienna
                RoundedRectangle(cornerRadius: 20)
                    .fill(cardGradient)

                // Inner perimeter light (silk-like bloom from edges)
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Photo thumbnail — bleeds into trailing edge when image items present
                if let thumbnailImage = firstThumbnail {
                    HStack {
                        Spacer()
                        Image(uiImage: thumbnailImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 88, height: 168)
                            .clipped()
                            .overlay(
                                LinearGradient(
                                    colors: [primaryTagColor, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 56)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            )
                            .clipShape(
                                .rect(
                                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 20, topTrailingRadius: 20
                                )
                            )
                    }
                }

                // Text content
                VStack(alignment: .leading, spacing: 8) {
                    Text(node.title.isEmpty ? "Untitled" : node.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(node.summary.isEmpty ? "—" : node.summary)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    HStack(spacing: 0) {
                        NodeCardItemCounts(items: node.items)
                        Spacer()
                        if node.needsAIProcessing {
                            HStack(spacing: 4) {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                                Text("Needs review")
                                    .font(.caption)
                                    .foregroundStyle(Color.orange)
                            }
                        } else {
                            Text(relativeTimestamp(node.createdAt))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.38))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .padding(.trailing, firstThumbnail != nil ? 80 : 0)
            }
        }
        .matchedTransitionSource(id: node.id, in: namespace)
        .onTapGesture { onTap() }
        // Scale + opacity: selected card full brightness, others dimmed
        .visualEffect { content, proxy in
            let frame = proxy.frame(in: .global)
            let distance = abs(frame.midY - screenMidY)
            let t = min(distance / 420, 1.0)
            let opacity = t < 0.12 ? 1.0 : (1.0 - min((t - 0.12) / 0.35, 1.0) * 0.35)
            return content
                .scaleEffect(1.0 - t * 0.07, anchor: .center)
                .opacity(opacity)
        }
    }

    // MARK: - Gradient

    private var cardGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: primaryTagColor, location: 0),
                .init(color: warmAccentColor, location: 0.55),
                .init(color: darkShadowColor, location: 1)
            ],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    private var primaryTagColor: Color {
        guard let name = node.tags.first,
              let tag = store.tags.first(where: { $0.name == name })
        else { return Color(hue: 0.72, saturation: 0.55, brightness: 0.70) }
        return Color(hex: tag.colorHex) ?? Color(hue: 0.72, saturation: 0.55, brightness: 0.70)
    }

    // Warm amber/peach secondary — always toward orange-red regardless of tag
    private var warmAccentColor: Color {
        guard let name = node.tags.first,
              let tag = store.tags.first(where: { $0.name == name }),
              let base = UIColor(hex: tag.colorHex)
        else { return Color(hue: 0.05, saturation: 0.75, brightness: 0.80) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let warmH = h * 0.25 + 0.04
        return Color(UIColor(hue: warmH, saturation: min(s * 1.15, 1), brightness: min(b * 1.15, 1), alpha: a))
    }

    // Dark maroon edge shadow
    private var darkShadowColor: Color {
        Color(red: 0.12, green: 0.02, blue: 0.06)
    }

    // MARK: - Thumbnail

    private var firstThumbnail: UIImage? {
        guard let item = node.items.first(where: { $0.type == .image }),
              let file = item.file,
              let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return UIImage(contentsOfFile: docsURL.appendingPathComponent(file).path)
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
