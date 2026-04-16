import SwiftUI
import SpriteKit

/// Top-level view host. Owns the NavigationStack for zoom transitions.
/// Shows either the SpriteKit graph canvas or the drum-roll list — toggled by the user.
struct CanvasView: View {

    @Environment(CorpusStore.self) private var store

    @State private var canvasState = CanvasState()
    @State private var fanExpanded = false
    @State private var captureMode: CaptureMode? = nil
    @State private var captureTargetNodeID: String? = nil
    @State private var showingNodePicker = false
    @State private var previousNodeIDs: Set<String> = []
    @State private var navigationPath = NavigationPath()
    @State private var localTagSuggestions: TagSuggestionContext? = nil
    @State private var showingFilter = false

    @Namespace private var zoomNamespace

    @State private var scene = CorpusPhysicsScene()

    // MARK: - Capture mode

    enum CaptureMode: String, Identifiable {
        case voice, text, camera
        var id: String { rawValue }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()

                // ─── Graph mode ───────────────────────────────────────────────
                if store.viewMode == .graph {
                    // Empty state (behind SpriteKit)
                    if store.nodes.isEmpty {
                        GraphPaperEmptyView()
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }

                    // Physics canvas
                    SpriteView(scene: scene, options: [.allowsTransparency])
                        .ignoresSafeArea()
                        .transition(.opacity)

                    // Node summary overlay — tap-to-select
                    if let id = canvasState.selectedNodeID,
                       let node = store.nodes.first(where: { $0.id == id }) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { canvasState.selectedNodeID = nil }
                            .ignoresSafeArea()

                        NodeSummaryOverlay(
                            node: node,
                            namespace: zoomNamespace,
                            onEnterDetail: { navigationPath.append(node) },
                            onDismiss:     { canvasState.selectedNodeID = nil }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // ─── List mode ────────────────────────────────────────────────
                if store.viewMode == .list {
                    NodeListView(
                        namespace: zoomNamespace,
                        onSelectNode: { node in
                            navigationPath.append(node)
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .transition(.opacity)
                }

                // ─── Persistent overlays ─────────────────────────────────────

                // Capture target indicator (graph mode only)
                if store.viewMode == .graph,
                   let targetID = captureTargetNodeID,
                   let targetNode = store.nodes.first(where: { $0.id == targetID }) {
                    VStack {
                        HStack {
                            Label("Adding to: \(targetNode.title)", systemImage: "arrow.up.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .padding(.top, 8)
                                .onTapGesture { captureTargetNodeID = nil }
                            Spacer()
                        }
                        .padding(.leading, 16)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Capture fan — same in both graph and list modes
                ActionButtonFan(
                    isExpanded: $fanExpanded,
                    onVoice:       { captureMode = .voice },
                    onCamera:      { captureMode = .camera },
                    onText:        { captureMode = .text },
                    onNodePicker:  { showingNodePicker = true },
                    onAddToRecent: { captureTargetNodeID = store.nodes.first?.id }
                )
            }
            .animation(.easeInOut(duration: 0.25), value: store.viewMode)
            .animation(.spring(response: 0.28), value: store.nodes.isEmpty)
            .animation(.spring(response: 0.28), value: canvasState.selectedNodeID)
            .animation(.spring(response: 0.28), value: captureTargetNodeID)
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
            .sheet(item: $localTagSuggestions) { context in
                TagCreationSheet(context: context)
                    .onDisappear {
                        store.pendingTagSuggestions = nil
                        localTagSuggestions = nil
                    }
            }
            .sheet(isPresented: $showingFilter) {
                FilterPanel()
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.black)
            }
            .onChange(of: store.pendingTagSuggestions) { _, new in
                if let new, localTagSuggestions == nil {
                    localTagSuggestions = new
                }
            }
            .onChange(of: captureMode) { _, mode in
                if mode != nil { fanExpanded = false }
                if mode == nil { captureTargetNodeID = nil }
            }
        }
        // Overlay is on the NavigationStack (outside it), not on the ZStack inside it.
        // This matters: the UIHostingController renders the NavigationStack as a UINavigationController
        // subview, then adds the overlay as a SIBLING view after it in the UIKit hierarchy.
        // That guarantees the overlay is above SpriteKit's CAMetalLayer, which is deep inside the
        // UINavigationController's content view. An overlay on the ZStack inside the nav stack
        // is still within the same UIView tree as the Metal layer and loses the z-ordering battle.
        // Guard with navigationPath.isEmpty so it hides correctly during push transitions.
        .overlay(alignment: .top) {
            if navigationPath.isEmpty {
                HStack {
                    Button {
                        showingFilter = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.75))
                            if store.filterState.isActive {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                    .padding(.leading, 20)

                    Spacer()

                    ViewTogglePill()

                    Spacer()

                    Color.clear
                        .frame(width: 36, height: 36)
                        .padding(.trailing, 20)
                }
                .padding(.top, 12)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .onAppear {
            scene.scaleMode = .resizeFill
            scene.backgroundColor = .clear
            scene.canvasState = canvasState
            previousNodeIDs = Set(store.nodes.map { $0.id })
            syncScene(nodes: store.nodes)
        }
        .onChange(of: store.nodes) { _, newNodes in
            let newIDs = Set(newNodes.map { $0.id })
            let addedID = newIDs.subtracting(previousNodeIDs).first
            previousNodeIDs = newIDs
            syncScene(nodes: newNodes, newNodeID: addedID)
        }
        .onChange(of: store.tags) { _, _ in
            syncScene(nodes: store.nodes)
        }
    }

    private func syncScene(nodes: [Node], newNodeID: String? = nil) {
        let tagColorMap = Dictionary(
            uniqueKeysWithValues: store.tags.compactMap { tag -> (String, UIColor)? in
                guard let color = UIColor(hex: tag.colorHex) else { return nil }
                return (tag.name, color)
            }
        )
        scene.syncNodes(
            nodes,
            layoutPositions: store.canvasLayout.positions,
            tagColors: tagColorMap,
            newNodeID: newNodeID
        )
    }
}

// MARK: - View toggle pill

private struct ViewTogglePill: View {
    @Environment(CorpusStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            toggleSegment(label: "Graph", icon: "circle.hexagongrid", mode: .graph)
            toggleSegment(label: "List",  icon: "list.bullet",        mode: .list)
        }
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    private func toggleSegment(label: String, icon: String, mode: ViewMode) -> some View {
        let selected = store.viewMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                store.viewMode = mode
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(selected ? Color.white : Color.clear)
            .clipShape(Capsule())
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        }
    }
}

// MARK: - Filter panel

private struct FilterPanel: View {
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {

                    // Sort order
                    filterSection("Sort") {
                        HStack(spacing: 10) {
                            ForEach([SortOrder.recency, .thematic], id: \.self) { order in
                                pillToggle(
                                    label: order == .recency ? "Recent" : "Thematic",
                                    selected: store.filterState.sortOrder == order
                                ) {
                                    store.filterState.sortOrder = order
                                }
                            }
                        }
                    }

                    // Media type
                    filterSection("Type") {
                        FlowPills(spacing: 10) {
                            ForEach(MediaTypeFilter.allCases, id: \.self) { type in
                                pillToggle(
                                    label: type.displayName,
                                    selected: store.filterState.mediaType == type
                                ) {
                                    store.filterState.mediaType = type
                                }
                            }
                        }
                    }

                    // Tag filter
                    if !store.tags.isEmpty {
                        filterSection("Tag") {
                            FlowPills(spacing: 10) {
                                // "All" pill
                                pillToggle(label: "All", selected: store.filterState.tagName == nil) {
                                    store.filterState.tagName = nil
                                }
                                ForEach(store.tags) { tag in
                                    pillToggle(
                                        label: tag.name,
                                        color: Color(hex: tag.colorHex),
                                        selected: store.filterState.tagName == tag.name
                                    ) {
                                        store.filterState.tagName = tag.name
                                    }
                                }
                            }
                        }
                    }

                    // Thread status
                    filterSection("Threads") {
                        HStack(spacing: 10) {
                            ForEach([ThreadFilter.all, .threadsOnly, .pulledOnly], id: \.self) { f in
                                pillToggle(label: f.displayName, selected: store.filterState.threadFilter == f) {
                                    store.filterState.threadFilter = f
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Color.black.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        store.filterState = FilterState()
                    }
                    .foregroundStyle(store.filterState.isActive ? .red : .white.opacity(0.35))
                    .disabled(!store.filterState.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(0.8)
            content()
        }
    }

    private func pillToggle(label: String, color: Color? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Color.white : Color.white.opacity(0.08))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(selected ? 0 : 0.12), lineWidth: 0.5))
        }
    }
}

// MARK: - Flow pills layout

private struct FlowPills<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Wrap using a custom flow layout
        _FlowLayout(spacing: spacing, content: content)
    }
}

private struct _FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        // SwiftUI Layout is iOS 16+, which we have.
        // Use a simple wrapping HStack via a custom Layout.
        CustomFlowLayout(spacing: spacing) { content() }
    }
}

private struct CustomFlowLayout<Content: View>: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Display name extensions

private extension MediaTypeFilter {
    var displayName: String {
        switch self {
        case .all:      return "All"
        case .voice:    return "Voice"
        case .photo:    return "Photo"
        case .video:    return "Video"
        case .text:     return "Text"
        case .link:     return "Link"
        case .document: return "Document"
        }
    }
}

private extension ThreadFilter {
    var displayName: String {
        switch self {
        case .all:         return "All"
        case .threadsOnly: return "Threads"
        case .pulledOnly:  return "Pulled"
        }
    }
}

// MARK: - Node summary overlay

private struct NodeSummaryOverlay: View {
    let node: Node
    let namespace: Namespace.ID
    let onEnterDetail: () -> Void
    let onDismiss: () -> Void

    @Environment(CorpusStore.self) private var store

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text(node.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if !node.summary.isEmpty {
                    Text(node.summary)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }

                // Tags
                if !node.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(node.tags, id: \.self) { name in
                                let color = tagColor(for: name)
                                Text(name)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(color.opacity(0.3))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                HStack(spacing: 14) {
                    ItemCountsRow(items: node.items)
                    Spacer()
                    Text(node.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.40))
                    + Text(" ago")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
            .matchedTransitionSource(id: node.id, in: namespace)
            .onTapGesture { onEnterDetail() }
        }
    }

    private func tagColor(for name: String) -> Color {
        if let tag = store.tags.first(where: { $0.name == name }) {
            return Color(hex: tag.colorHex) ?? .gray
        }
        return .gray
    }
}

// MARK: - Item counts row

private struct ItemCountsRow: View {
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
        HStack(spacing: 10) {
            if counts.text     > 0 { chip("pencil",    counts.text)     }
            if counts.image    > 0 { chip("photo",     counts.image)    }
            if counts.audio    > 0 { chip("mic",       counts.audio)    }
            if counts.video    > 0 { chip("video",     counts.video)    }
            if counts.link     > 0 { chip("link",      counts.link)     }
            if counts.document > 0 { chip("doc",       counts.document) }
        }
    }

    private func chip(_ icon: String, _ count: Int) -> some View {
        Label("\(count)", systemImage: icon)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.55))
    }
}

// MARK: - Node picker sheet

private struct NodePickerSheet: View {
    @Binding var selectedNodeID: String?
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.nodes.prefix(20)) { node in
                    Button {
                        selectedNodeID = node.id
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(nodeColor(node))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(node.createdAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))
                                + Text(" ago")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                            Spacer()
                            if selectedNodeID == node.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Add to Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("New Node") {
                        selectedNodeID = nil
                        dismiss()
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.black)
    }

    private func nodeColor(_ node: Node) -> Color {
        guard let tag = node.tags.first,
              let storeTag = store.tags.first(where: { $0.name == tag })
        else { return .gray }
        return Color(hex: storeTag.colorHex) ?? .gray
    }
}
