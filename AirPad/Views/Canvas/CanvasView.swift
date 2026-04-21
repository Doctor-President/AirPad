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
    @State private var showGlowDebugPanel = true  // visible by default for testing

    // MARK: - Capture mode

    enum CaptureMode: String, Identifiable {
        case voice, text, camera
        var id: String { rawValue }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            canvasStack
        }
        .onAppear {
            scene.scaleMode = .resizeFill
            scene.backgroundColor = .clear
            scene.canvasState = canvasState
            previousNodeIDs = Set(store.filteredNodes.map { $0.id })
            syncScene(nodes: store.filteredNodes)

            // Inject test nodes for visual development
            if showGlowDebugPanel && store.nodes.isEmpty {
                injectTestNodes()
            }
        }
        .onChange(of: store.nodes) { old, newNodes in
            // Track additions against the raw node list so newly captured nodes
            // get the drop-in animation even if filteredNodes would include them.
            let newIDs = Set(newNodes.map { $0.id })
            let addedID = newIDs.subtracting(previousNodeIDs).first
            previousNodeIDs = newIDs
            print("[Canvas] onChange(nodes): \(old.count)→\(newNodes.count), addedID=\(addedID ?? "nil"), filteredNodes=\(store.filteredNodes.count), layoutPositions=\(store.canvasLayout.positions.count)")
            syncScene(nodes: store.filteredNodes, newNodeID: addedID)
        }
        .onChange(of: store.filteredNodes) { old, filtered in
            // Re-sync when filter state changes (tag filter, type filter, etc.)
            print("[Canvas] onChange(filteredNodes): \(old.count)→\(filtered.count)")
            syncScene(nodes: filtered)
        }
        .onChange(of: store.tags) { _, _ in
            syncScene(nodes: store.filteredNodes)
        }
        .onChange(of: store.filterState.sortOrder) { _, newOrder in
            rearrangeForSortOrder(newOrder, nodes: store.filteredNodes)
        }
        .onChange(of: store.canvasNeedsSync) { _, _ in
            // Fired by batchImportText after canvasLayout is updated with all new positions.
            // Belt-and-suspenders: ensures the scene reflects the final store state even if
            // the per-node onChange chain was coalesced or ran before canvasLayout was ready.
            previousNodeIDs = Set(store.nodes.map { $0.id })
            print("[Canvas] canvasNeedsSync: forcing full resync — filteredNodes=\(store.filteredNodes.count) layoutPositions=\(store.canvasLayout.positions.count) sprites=\(scene.spriteCount)")
            syncScene(nodes: store.filteredNodes)
            print("[Canvas] canvasNeedsSync: after syncScene sprites=\(scene.spriteCount)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .airPadActionButtonPressed)) { _ in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
                fanExpanded = true
            }
        }
    }

    // MARK: - Canvas stack (extracted to keep body type-checkable)

    private var canvasStack: some View {
        canvasZStack
            .animation(.spring(response: 0.28), value: store.nodes.isEmpty)
            .animation(.spring(response: 0.28), value: canvasState.selectedNodeID)
            .animation(.spring(response: 0.28), value: captureTargetNodeID)
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
                    .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
            }
            .sheet(item: $captureMode, content: captureModeSheet)
            .sheet(isPresented: $showingNodePicker) {
                NodePickerSheet(selectedNodeID: $captureTargetNodeID)
            }
            .sheet(item: $localTagSuggestions) { context in
                tagCreationSheet(context: context)
            }
            .onChange(of: store.pendingTagSuggestions) { _, new in
                if let new, localTagSuggestions == nil { localTagSuggestions = new }
            }
            .onChange(of: captureMode) { _, mode in
                if mode != nil { fanExpanded = false }
                if mode == nil { captureTargetNodeID = nil }
            }
    }

    private var canvasZStack: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.ignoresSafeArea()
            if store.nodes.isEmpty {
                GraphPaperEmptyView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            SpriteView(scene: scene, options: [.allowsTransparency])
                .ignoresSafeArea()
            nodeSummaryLayer
            captureTargetBanner
            glowDebugPanelLayer
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
    }

    @ViewBuilder
    private var glowDebugPanelLayer: some View {
        if showGlowDebugPanel {
            VStack {
                Spacer()
                HStack {
                    GlowDebugPanel(
                        isVisible: $showGlowDebugPanel,
                        onGlowReachChange: { scene.setGlowReach($0) },
                        onGlowIntensityChange: { scene.setGlowIntensity($0) },
                        onGlowFalloffChange: { scene.setGlowFalloff($0) },
                        onGlowTintChange: { scene.setGlowTint($0) },
                        onDisplacementAmplitudeChange: { scene.setDisplacementAmplitude($0) },
                        onDisplacementSpeedChange: { scene.setDisplacementSpeed($0) },
                        onCanvasNoiseFrequencyChange: { scene.setCanvasNoiseFrequency($0) },
                        onNodeDeformIntensityChange: { scene.setNodeDeformIntensity($0) },
                        onChromaticAberrationScaleChange: { scene.setChromaticAberrationScale($0) },
                        onChromaticAberrationVelocityMultChange: { scene.setChromaticAberrationVelocityMult($0) },
                        onChromaticAberrationDecayChange: { scene.setChromaticAberrationDecay($0) },
                        onChromaticAberrationMaxChange: { scene.setChromaticAberrationMax($0) }
                    )
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
                    Spacer()
                }
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func captureModeSheet(_ mode: CaptureMode) -> some View {
        switch mode {
        case .voice:  VoiceCaptureSheet(targetNodeID: captureTargetNodeID)
        case .text:   TextCaptureSheet(targetNodeID: captureTargetNodeID)
        case .camera: CameraCaptureView(targetNodeID: captureTargetNodeID)
        }
    }

    private func tagCreationSheet(context: TagSuggestionContext) -> some View {
        TagCreationSheet(context: context)
            .onDisappear {
                store.pendingTagSuggestions = nil
                localTagSuggestions = nil
            }
    }

    @ViewBuilder
    private var nodeSummaryLayer: some View {
        if let id = canvasState.selectedNodeID,
           let node = store.nodes.first(where: { $0.id == id }) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { canvasState.selectedNodeID = nil }
                .ignoresSafeArea()
            NodeSummaryOverlay(
                node: node, namespace: zoomNamespace,
                onEnterDetail: { navigationPath.append(node) },
                onDismiss: { canvasState.selectedNodeID = nil }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var captureTargetBanner: some View {
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
    }

    private func rearrangeForSortOrder(_ order: SortOrder, nodes: [Node]) {
        guard !nodes.isEmpty else { return }
        var positions: [String: CGPoint] = [:]

        switch order {
        case .recency:
            // Spiral outward from center — index 0 (most recent) near center.
            let goldenAngle = 2.399963229728653  // radians ≈ 137.5°
            for (index, node) in nodes.enumerated() {
                let angle = Double(index) * goldenAngle
                let radius = 40.0 + sqrt(Double(index)) * 38.0
                positions[node.id] = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }

        case .thematic:
            // Group by primary tag; arrange group centers in a ring, nodes within each group
            // in a smaller circle around the group center.
            let groups = Dictionary(grouping: nodes) { $0.tags.first ?? "" }
            let tagKeys = groups.keys.sorted()
            let groupCount = tagKeys.count
            let groupRadius = groupCount > 1 ? max(160.0, Double(groupCount) * 55.0) : 0.0
            for (gi, tag) in tagKeys.enumerated() {
                let groupAngle = groupCount > 1
                    ? Double(gi) / Double(groupCount) * 2 * .pi
                    : 0.0
                let cx = cos(groupAngle) * groupRadius
                let cy = sin(groupAngle) * groupRadius
                let members = groups[tag] ?? []
                let innerRadius = max(35.0, Double(members.count) * 12.0)
                for (ni, node) in members.enumerated() {
                    let nodeAngle = members.count > 1
                        ? Double(ni) / Double(members.count) * 2 * .pi
                        : 0.0
                    positions[node.id] = CGPoint(
                        x: cx + cos(nodeAngle) * innerRadius,
                        y: cy + sin(nodeAngle) * innerRadius
                    )
                }
            }
        }

        scene.rearrangeToPositions(positions)
    }

    private func syncScene(nodes: [Node], newNodeID: String? = nil) {
        print("[Canvas] syncScene: \(nodes.count) nodes, \(store.canvasLayout.positions.count) positions, \(scene.spriteCount) sprites before")
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
        print("[Canvas] syncScene: \(scene.spriteCount) sprites after")
    }

    // MARK: - Test node injection

    func injectTestNodes() {
        Task {
            // Create test tags cycling through palette indices 0-6
            let testTags = [
                Tag(id: UUID(), name: "pal0", colorHex: "#2D0A5E", createdAt: Date(), useCount: 0),
                Tag(id: UUID(), name: "pal1", colorHex: "#041E2A", createdAt: Date(), useCount: 0),
                Tag(id: UUID(), name: "pal2", colorHex: "#071A0A", createdAt: Date(), useCount: 0),
                Tag(id: UUID(), name: "pal3", colorHex: "#0A0520", createdAt: Date(), useCount: 0),
                Tag(id: UUID(), name: "pal4", colorHex: "#0A1020", createdAt: Date(), useCount: 0),
                Tag(id: UUID(), name: "pal5", colorHex: "#041A1A", createdAt: Date(), useCount: 0),
                Tag(id: UUID(), name: "pal6", colorHex: "#030A1A", createdAt: Date(), useCount: 0),
            ]

            // Add tags if they don't exist
            for tag in testTags {
                if !store.tags.contains(where: { $0.name == tag.name }) {
                    await store.addTag(tag)
                }
            }

            let testNodes = [
                Node(
                    id: "test-\(UUID().uuidString)",
                    createdAt: Date(),
                    updatedAt: Date(),
                    title: "Optimistic Adventures",
                    summary: "A journey through whimsical landscapes and curious encounters",
                    tags: ["pal0"],
                    items: []
                ),
                Node(
                    id: "test-\(UUID().uuidString)",
                    createdAt: Date().addingTimeInterval(-3600),
                    updatedAt: Date(),
                    title: "Emergence in Darkness",
                    summary: "A group of individuals track themselves in a dark, empty void",
                    tags: ["pal1"],
                    items: []
                ),
                Node(
                    id: "test-\(UUID().uuidString)",
                    createdAt: Date().addingTimeInterval(-7200),
                    updatedAt: Date(),
                    title: "Dog days of summer",
                    summary: "A summer adventure with friends and family",
                    tags: ["pal2"],
                    items: []
                ),
                Node(
                    id: "test-\(UUID().uuidString)",
                    createdAt: Date().addingTimeInterval(-10800),
                    updatedAt: Date(),
                    title: "God Macro Level Story",
                    summary: "A story pretext is a god macro level (Biblical apocalypse)",
                    tags: ["pal3"],
                    items: []
                ),
                Node(
                    id: "test-\(UUID().uuidString)",
                    createdAt: Date().addingTimeInterval(-14400),
                    updatedAt: Date(),
                    title: "Whole List",
                    summary: "Collecting all the pieces together",
                    tags: ["pal4"],
                    items: []
                ),
                Node(
                    id: "test-\(UUID().uuidString)",
                    createdAt: Date().addingTimeInterval(-18000),
                    updatedAt: Date(),
                    title: "Midnight Chronicles",
                    summary: "Tales from the edge of twilight",
                    tags: ["pal5"],
                    items: []
                ),
                Node(
                    id: "test-\(UUID().uuidString)",
                    createdAt: Date().addingTimeInterval(-21600),
                    updatedAt: Date(),
                    title: "Ocean Depths",
                    summary: "Exploring the mysteries beneath the waves",
                    tags: ["pal6"],
                    items: []
                )
            ]

            for (index, node) in testNodes.enumerated() {
                let angle = Double(index) * (2 * .pi / Double(testNodes.count))
                let radius = 250.0  // Wide spacing to prevent overlap
                let position = CGPoint(
                    x: cos(angle) * radius,
                    y: sin(angle) * radius
                )
                await store.addNode(node, position: position)
            }
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

