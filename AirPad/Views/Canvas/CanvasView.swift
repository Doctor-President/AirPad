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
    @State private var isDismissing = false

    @Namespace private var zoomNamespace

    @State private var scene: CorpusPhysicsScene = {
        let s = CorpusPhysicsScene(size: CGSize(width: 393, height: 852))
        s.scaleMode = .resizeFill
        s.backgroundColor = UIColor(red: 0.027, green: 0.027, blue: 0.039, alpha: 1.0)
        return s
    }()
    @State private var showGlowDebugPanel = false

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
            scene.canvasState = canvasState
            store.canvasState = canvasState
            previousNodeIDs = Set(store.filteredNodes.map { $0.id })
            syncScene(nodes: store.visibleNodes)

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
            print("[Canvas] onChange(nodes): \(old.count)→\(newNodes.count), addedID=\(addedID ?? "nil"), visibleNodes=\(store.visibleNodes.count), layoutPositions=\(store.canvasLayout.positions.count)")
            syncScene(nodes: store.visibleNodes, newNodeID: addedID)
        }
        .onChange(of: store.filteredNodes) { old, filtered in
            // Re-sync when filter state changes (tag filter, type filter, etc.)
            print("[Canvas] onChange(filteredNodes): \(old.count)→\(filtered.count), visibleNodes=\(store.visibleNodes.count)")
            syncScene(nodes: store.visibleNodes)
        }
        .onChange(of: store.tags) { _, _ in
            syncScene(nodes: store.visibleNodes)
        }
        .onChange(of: store.filterState.sortOrder) { _, newOrder in
            rearrangeForSortOrder(newOrder, nodes: store.visibleNodes)
        }
        .onChange(of: store.canvasNeedsSync) { _, _ in
            // Fired by batchImportText after canvasLayout is updated with all new positions.
            // Belt-and-suspenders: ensures the scene reflects the final store state even if
            // the per-node onChange chain was coalesced or ran before canvasLayout was ready.
            previousNodeIDs = Set(store.nodes.map { $0.id })
            print("[Canvas] canvasNeedsSync: forcing full resync — visibleNodes=\(store.visibleNodes.count) layoutPositions=\(store.canvasLayout.positions.count) sprites=\(scene.spriteCount)")
            syncScene(nodes: store.visibleNodes)
            print("[Canvas] canvasNeedsSync: after syncScene sprites=\(scene.spriteCount)")
        }
        .onChange(of: canvasState.drilledInto) { oldValue, newValue in
            // Drill-down state changed — resync to show only child nodes or full canvas
            print("[Canvas] onChange(drilledInto): \(newValue ?? "nil"), visibleNodes=\(store.visibleNodes.count)")

            // Find Über-node position for expansion animation
            let expandingFrom: CGPoint?
            if let drilledClusterID = newValue,
               let uberSprite = scene.uberNodeSprites[drilledClusterID] {
                expandingFrom = uberSprite.position
                // Freeze physics during transition
                scene.physicsWorld.speed = 0
                // Restore after 0.5s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    scene.physicsWorld.speed = 1.0
                }
            } else {
                expandingFrom = nil
            }

            syncScene(nodes: store.visibleNodes, expandingFrom: expandingFrom)
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
            if store.nodes.isEmpty {
                GraphPaperEmptyView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            SpriteKitView(scene: scene)
                .ignoresSafeArea()
                .blur(radius: (canvasState.isZoomed || isDismissing) ? 8 : 0)
                .animation(.easeInOut(duration: 0.25), value: canvasState.isZoomed)
            nodeSummaryLayer
            captureTargetBanner
            drillDownBackButton
            glowDebugPanelLayer
            debugPanelToggleButton
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
                HStack {
                    Spacer()
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
                    .padding(.trailing, 16)
                    .padding(.top, 150)
                }
                Spacer()
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var debugPanelToggleButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        showGlowDebugPanel.toggle()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .padding(.trailing, 16)
                .padding(.top, 120)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var drillDownBackButton: some View {
        if let drilledClusterID = canvasState.drilledInto,
           let cluster = store.uberNodeCache?.clusters.first(where: { $0.id == drilledClusterID }) {
            VStack {
                HStack {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            canvasState.drilledInto = nil
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text(cluster.title)
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    .padding(.leading, 16)
                    .padding(.top, 60)
                    Spacer()
                }
                Spacer()
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
        if (canvasState.isZoomed || isDismissing),
           let id = canvasState.selectedNodeID,
           let node = store.nodes.first(where: { $0.id == id }) {
            // Full-screen tap target for dismiss
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { scene.resetZoom() }
                .ignoresSafeArea()

            // Detail content overlay positioned at screen center
            NodeDetailOverlay(
                node: node,
                canvasState: canvasState,
                isDismissing: $isDismissing,
                navigationPath: $navigationPath,
                scene: scene
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .transition(.opacity)
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

    private func syncScene(nodes: [Node], newNodeID: String? = nil, expandingFrom: CGPoint? = nil) {
        print("[Canvas] syncScene: \(nodes.count) nodes, expandingFrom=\(expandingFrom != nil), sprites before=\(scene.spriteCount)")

        let tagColorMap = Dictionary(
            uniqueKeysWithValues: store.tags.compactMap { tag -> (String, UIColor)? in
                guard let color = UIColor(hex: tag.colorHex) else { return nil }
                return (tag.name, color)
            }
        )

        // Compute layout: radial when drilled in, canonical otherwise
        let layoutPositions: [String: CanvasPosition]
        if let drilledClusterID = canvasState.drilledInto,
           let cluster = store.uberNodeCache?.clusters.first(where: { $0.id == drilledClusterID }),
           let centerPos = expandingFrom {
            // Radial layout around Über-node position
            layoutPositions = computeRadialLayout(nodes: nodes, center: centerPos)
        } else {
            layoutPositions = store.canvasLayout.positions
        }

        let uberClusters = canvasState.drilledInto == nil ? (store.uberNodeCache?.clusters ?? []) : []

        scene.syncNodes(
            nodes,
            layoutPositions: layoutPositions,
            tagColors: tagColorMap,
            newNodeID: newNodeID,
            uberNodeClusters: uberClusters,
            expandingFrom: expandingFrom
        )
        print("[Canvas] syncScene: \(scene.spriteCount) sprites after, \(uberClusters.count) Über-nodes")
    }

    /// Compute radial layout for drilled-in child nodes around center point.
    private func computeRadialLayout(nodes: [Node], center: CGPoint) -> [String: CanvasPosition] {
        var positions: [String: CanvasPosition] = [:]
        let count = nodes.count
        let baseRadius: Double = 120.0

        for (index, node) in nodes.enumerated() {
            let angle = (Double(index) / Double(max(count, 1))) * 2 * .pi
            let x = center.x + cos(angle) * baseRadius
            let y = center.y + sin(angle) * baseRadius
            positions[node.id] = CanvasPosition(x: x, y: -y)  // Flip Y for SpriteKit
        }

        return positions
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

// MARK: - Node detail overlay (animated gradient card, morphs from circle)

private struct NodeDetailOverlay: View {
    let node: Node
    @Bindable var canvasState: CanvasState
    @Binding var isDismissing: Bool
    @Binding var navigationPath: NavigationPath
    let scene: CorpusPhysicsScene

    @Environment(CorpusStore.self) private var store
    @State private var isExpanded = false
    @State private var showText = false
    @State private var phase: Double = 0

    // Same circleColors table as NodeCardView
    private let circleColors: [(String, String, String)] = [
        ("9B6FE8", "F5C5A3", "E36B4E"),
        ("5B8FFF", "A78BFA", "F472B6"),
        ("34D399", "60A5FA", "A78BFA"),
        ("FB923C", "FBBF24", "E36B4E"),
        ("F472B6", "FB7185", "C084FC"),
        ("22D3EE", "34D399", "60A5FA"),
        ("A78BFA", "818CF8", "E36B4E"),
    ]

    // Derive palette index from node's primary tag (same logic as paletteIndexForNode)
    private var paletteIndex: Int {
        guard let tagName = node.tags.first else { return 0 }
        switch tagName {
        case "pal0": return 0
        case "pal1": return 1
        case "pal2": return 2
        case "pal3": return 3
        case "pal4": return 4
        case "pal5": return 5
        case "pal6": return 6
        default:
            return abs(tagName.hashValue) % 7
        }
    }

    // Calculate initial node diameter based on item count (matches bubbleRadius logic)
    private var initialDiameter: CGFloat {
        let radius = {
            let extra = CGFloat(max(0, node.items.count - 1)) * 4.0
            return min(30.0 + extra, 60.0)
        }()
        return radius * 2
    }

    // Overlay dimensions: screen width minus 80pt (40pt padding each side)
    private var finalWidth: CGFloat {
        UIScreen.main.bounds.width - 80
    }

    private var finalHeight: CGFloat {
        finalWidth * 0.75  // More content room than previous 0.6
    }

    var body: some View {
        ZStack {
            // Animated gradient fill (replicated from NodeCardView)
            gradientFill
                .frame(
                    width: isExpanded ? finalWidth : initialDiameter,
                    height: isExpanded ? finalHeight : initialDiameter
                )
                .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 32 : initialDiameter / 2))
                .opacity(isExpanded ? 1.0 : 0.0)

            // Inner glow overlay (animates with shape)
            innerGlow(cornerRadius: isExpanded ? 32 : initialDiameter / 2)
                .frame(
                    width: isExpanded ? finalWidth : initialDiameter,
                    height: isExpanded ? finalHeight : initialDiameter
                )
                .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 32 : initialDiameter / 2))
                .blendMode(.overlay)
                .opacity(isExpanded ? 1.0 : 0.0)

            // Text content: fades in after morph completes
            if showText {
                VStack(alignment: .leading, spacing: 12) {
                    // Title
                    Text(node.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Summary
                    if !node.summary.isEmpty {
                        Text(node.summary)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer()

                    // Item counts and timestamp
                    HStack(spacing: 16) {
                        ItemCountsRow(items: node.items)

                        Text(node.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                        + Text(" ago")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(width: finalWidth, height: finalHeight)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }

            // X dismiss button (fades in with text)
            if showText {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                    Button {
                        scene.resetZoom()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
                .frame(width: finalWidth, height: finalHeight)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .drawingGroup()
        .onTapGesture {
            // Tap card to navigate to NodeDetailView
            navigationPath.append(node)
            scene.resetZoom()
        }
        .onAppear {
            // Randomize phase for animation uniqueness
            phase = Double.random(in: 0...100)

            // Phase 1: Morph shape from circle to rounded rect (0.25s)
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded = true
            }

            // Phase 2: Fade in text after morph completes (0.25s delay, 0.1s duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeInOut(duration: 0.1)) {
                    showText = true
                }
            }
        }
        .onChange(of: canvasState.isZoomed) { wasZoomed, isZoomed in
            // Detect dismiss trigger (zoom → not zoomed)
            if wasZoomed && !isZoomed {
                // Keep overlay visible during dismiss animation
                isDismissing = true

                // Phase 1: Fade out text (0.1s)
                withAnimation(.easeInOut(duration: 0.1)) {
                    showText = false
                }

                // Phase 2: Collapse shape back to circle after text fades (0.1s delay, 0.25s duration)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded = false
                    }
                }

                // Phase 3: Remove overlay after full animation sequence (0.35s total)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isDismissing = false
                }
            }
        }
        .onDisappear {
            // Reset state for next appearance
            isExpanded = false
            showText = false
        }
    }

    // GRADIENT FILL (replicated from NodeCardView exactly)
    private var gradientFill: some View {
        let colors = circleColors[paletteIndex % circleColors.count]
        return TimelineView(.animation) { timeline in
            ZStack {
                Color(red: 0.027, green: 0.027, blue: 0.039)
                let time = timeline.date.timeIntervalSinceReferenceDate
                Circle()
                    .fill(Color(hexString: colors.0))
                    .frame(width: 180, height: 180)
                    .blur(radius: 40)
                    .offset(x: -80 + sin(time * 0.3 + phase * 1.3) * 30,
                            y: cos(time * 0.25 + phase * 0.9) * 30)
                Circle()
                    .fill(Color(hexString: colors.1))
                    .frame(width: 180, height: 180)
                    .blur(radius: 40)
                    .offset(x: sin(time * 0.35 + phase * 1.7) * 30,
                            y: cos(time * 0.3 + phase * 1.1) * 30)
                Circle()
                    .fill(Color(hexString: colors.2))
                    .frame(width: 180, height: 180)
                    .blur(radius: 40)
                    .offset(x: 80 + sin(time * 0.4 + phase * 2.1) * 30,
                            y: cos(time * 0.35 + phase * 0.7) * 30)
            }
        }
    }

    // INNER GLOW (replicated from NodeCardView)
    private func innerGlow(cornerRadius: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack {
                RadialGradient(
                    colors: [.black, Color.white.opacity(0.85)],
                    center: .center,
                    startRadius: geo.size.width * 0.15,
                    endRadius: geo.size.width * 0.72
                )
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
            }
        }
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

