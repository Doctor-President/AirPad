import SwiftUI
import SpriteKit

/// The real canvas view for Session 2+. Wraps a SpriteKit physics scene with SwiftUI overlays.
struct CanvasView: View {

    @Environment(CorpusStore.self) private var store
    @State private var canvasState = CanvasState()
    @State private var fanExpanded = false
    @State private var captureMode: CaptureMode? = nil
    @State private var captureTargetNodeID: String? = nil  // nil = create new node
    @State private var showingNodePicker = false
    @State private var previousNodeIDs: Set<String> = []
    @State private var navigationPath = NavigationPath()
    @State private var localTagSuggestions: TagSuggestionContext? = nil

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

                // Empty state (behind the SpriteKit layer)
                if store.nodes.isEmpty {
                    GraphPaperEmptyView()
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Physics canvas
                SpriteView(scene: scene, options: [.allowsTransparency])
                    .ignoresSafeArea()

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
                        onEnterDetail: {
                            navigationPath.append(node)
                        },
                        onDismiss: {
                            canvasState.selectedNodeID = nil
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Capture target indicator
                if let targetID = captureTargetNodeID,
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

                // Capture fan
                ActionButtonFan(
                    isExpanded: $fanExpanded,
                    onVoice:       { captureMode = .voice },
                    onCamera:      { captureMode = .camera },
                    onText:        { captureMode = .text },
                    onNodePicker:  { showingNodePicker = true },
                    onAddToRecent: { captureTargetNodeID = store.nodes.first?.id }
                )
            }
            .animation(.spring(response: 0.28), value: store.nodes.isEmpty)
            .animation(.spring(response: 0.28), value: canvasState.selectedNodeID)
            .animation(.spring(response: 0.28), value: captureTargetNodeID)
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
                    .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
            }
            // Capture sheet — passes target node ID into the capture view
            .sheet(item: $captureMode) { mode in
                switch mode {
                case .voice:  VoiceCaptureSheet(targetNodeID: captureTargetNodeID)
                case .text:   TextCaptureSheet(targetNodeID: captureTargetNodeID)
                case .camera: CameraCaptureView(targetNodeID: captureTargetNodeID)
                }
            }
            // Node picker sheet
            .sheet(isPresented: $showingNodePicker) {
                NodePickerSheet(selectedNodeID: $captureTargetNodeID)
            }
            // Tag creation sheet — presented when AI surfaces new tag suggestions
            .sheet(item: $localTagSuggestions) { context in
                TagCreationSheet(context: context)
                    .onDisappear {
                        store.pendingTagSuggestions = nil
                        localTagSuggestions = nil
                    }
            }
            .onChange(of: store.pendingTagSuggestions) { _, new in
                if let new, localTagSuggestions == nil {
                    localTagSuggestions = new
                }
            }
            .onChange(of: captureMode) { _, mode in
                if mode != nil { fanExpanded = false }
                // Clear target after capture sheet dismisses
                if mode == nil { captureTargetNodeID = nil }
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
