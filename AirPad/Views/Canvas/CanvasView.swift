import SwiftUI
import SpriteKit
import CoreHaptics

/// The real canvas view for Session 2+. Wraps a SpriteKit physics scene with SwiftUI overlays.
struct CanvasView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var canvasState = CanvasState()
    @State private var fanExpanded = false
    @State private var captureMode: CaptureMode? = nil
    @State private var captureTargetNodeID: String? = nil
    @State private var showingNodePicker = false
    @State private var previousNodeIDs: Set<String> = []
    @State private var navigationPath = NavigationPath()
    @State private var localTagSuggestions: TagSuggestionContext? = nil
    @State private var hapticEngine: CHHapticEngine?

    @Namespace private var zoomNamespace

    @State private var scene = CorpusPhysicsScene()

    // MARK: - Capture mode

    enum CaptureMode: String, Identifiable {
        case voice, text, camera
        var id: String { rawValue }
    }

    // MARK: - Body

    var body: some View {
        observedStack
            .onChange(of: store.filteredNodes) { _, filtered in
                syncScene(nodes: filtered)
            }
            .onChange(of: store.tags) { _, _ in
                syncScene(nodes: store.filteredNodes)
            }
            .onChange(of: store.filterState.canvasViewMode) { _, newMode in
                rearrangeForMode(newMode, nodes: store.filteredNodes)
                playModeTransitionHaptic()
            }
            .onChange(of: store.canvasNeedsSync) { _, _ in
                previousNodeIDs = Set(store.nodes.map { $0.id })
                syncScene(nodes: store.filteredNodes)
            }
            .onReceive(NotificationCenter.default.publisher(for: .airPadActionButtonPressed)) { _ in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
                    fanExpanded = true
                }
            }
    }

    private var observedStack: some View {
        NavigationStack(path: $navigationPath) {
            canvasStack
        }
        .onAppear {
            scene.scaleMode = .resizeFill
            scene.backgroundColor = .clear
            scene.canvasState = canvasState
            scene.isDarkMode = colorScheme == .dark
            previousNodeIDs = Set(store.filteredNodes.map { $0.id })
            syncScene(nodes: store.filteredNodes)
            prepareHaptics()
            rearrangeForMode(store.filterState.canvasViewMode, nodes: store.filteredNodes)
        }
        .onChange(of: colorScheme) { _, new in
            scene.isDarkMode = new == .dark
        }
        .onChange(of: store.nodes) { _, newNodes in
            let newIDs: Set<String> = Set(newNodes.map { $0.id })
            let addedID: String? = newIDs.subtracting(previousNodeIDs).first
            previousNodeIDs = newIDs
            syncScene(nodes: store.filteredNodes, newNodeID: addedID)
        }
    }

    // MARK: - Canvas stack

    private var canvasStack: some View {
        canvasStackWithSheets
            .onChange(of: store.pendingTagSuggestions) { _, new in
                if let new, localTagSuggestions == nil { localTagSuggestions = new }
            }
            .onChange(of: captureMode) { _, mode in
                if mode != nil { fanExpanded = false }
                if mode == nil { captureTargetNodeID = nil }
            }
    }

    private var canvasStackWithSheets: some View {
        canvasStackAnimated
            .sheet(item: $captureMode, content: captureModeSheet)
            .sheet(isPresented: $showingNodePicker) {
                NodePickerSheet(selectedNodeID: $captureTargetNodeID)
            }
            .sheet(item: $localTagSuggestions) { context in
                tagCreationSheet(context: context)
            }
    }

    private var canvasStackAnimated: some View {
        canvasZStack
            .animation(.spring(response: 0.28), value: store.nodes.isEmpty)
            .animation(.spring(response: 0.28), value: canvasState.selectedNodeID)
            .animation(.spring(response: 0.28), value: captureTargetNodeID)
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
                    .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
            }
    }

    private var canvasZStack: some View {
        ZStack {
            // Background: void black (Solar Flare) or warm white (Cucumber Water)
            canvasBackground.ignoresSafeArea()
            SpriteView(scene: scene, options: [.allowsTransparency])
                .ignoresSafeArea()
            nodeSummaryLayer
            captureTargetBanner
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

    private var canvasBackground: Color {
        colorScheme == .dark ? .black : Color(red: 0.98, green: 0.97, blue: 0.955)
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

    // MARK: - Mode layout

    private func rearrangeForMode(_ mode: CanvasViewMode, nodes: [Node]) {
        guard !nodes.isEmpty else { return }
        var positions: [String: CGPoint] = [:]

        switch mode {

        case .temporal:
            let sorted = nodes.sorted { $0.createdAt > $1.createdAt }
            let goldenAngle = 2.399963229728653
            for (i, node) in sorted.enumerated() {
                let angle  = Double(i) * goldenAngle
                let radius = 40.0 + sqrt(Double(i)) * 38.0
                positions[node.id] = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }

        case .thematic:
            positions = thematicLayout(nodes: nodes, groupKey: { $0.tags.first ?? "" })

        case .semantic:
            // No embeddings yet — fall back to thematic
            positions = thematicLayout(nodes: nodes, groupKey: { $0.tags.first ?? "" })

        case .domain:
            positions = thematicLayout(nodes: nodes, groupKey: { $0.domain ?? "Unknown" })

        case .density:
            let sorted = nodes.sorted { $0.items.count > $1.items.count }
            let goldenAngle = 2.399963229728653
            for (i, node) in sorted.enumerated() {
                let angle  = Double(i) * goldenAngle
                let radius = 20.0 + sqrt(Double(i)) * 42.0
                positions[node.id] = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }

        case .tension:
            // Thematic base with random displacement (proxy until embeddings available)
            var base = thematicLayout(nodes: nodes, groupKey: { $0.tags.first ?? "" })
            for (id, pt) in base {
                let tensionMag = Double.random(in: 0...45)
                let tensionDir = Double.random(in: 0...2 * .pi)
                base[id] = CGPoint(
                    x: pt.x + CGFloat(cos(tensionDir) * tensionMag),
                    y: pt.y + CGFloat(sin(tensionDir) * tensionMag)
                )
            }
            positions = base
        }

        scene.rearrangeToPositions(positions)
    }

    private func thematicLayout(nodes: [Node], groupKey: (Node) -> String) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        let groups      = Dictionary(grouping: nodes, by: groupKey)
        let keys        = groups.keys.sorted()
        let groupCount  = keys.count
        let groupRadius = groupCount > 1 ? max(160.0, Double(groupCount) * 55.0) : 0.0

        for (gi, key) in keys.enumerated() {
            let groupAngle = groupCount > 1
                ? Double(gi) / Double(groupCount) * 2 * .pi
                : 0.0
            let cx = cos(groupAngle) * groupRadius
            let cy = sin(groupAngle) * groupRadius
            let members     = groups[key] ?? []
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
        return positions
    }

    // MARK: - CoreHaptics

    private func prepareHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        hapticEngine = try? CHHapticEngine()
        try? hapticEngine?.start()
    }

    private func playModeTransitionHaptic() {
        guard let engine = hapticEngine else { return }

        var events: [CHHapticEvent] = []
        // Initial firm thud
        events.append(CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.88),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.70)
            ],
            relativeTime: 0
        ))
        // Decaying pulse train — intensity and sharpness fall, interval grows
        for i in 1...5 {
            let intensity  = Float(0.88 * pow(0.58, Double(i)))
            let sharpness  = Float(max(0.1, 0.5 - Double(i) * 0.07))
            let relTime    = 0.13 * pow(1.45, Double(i))
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: relTime
            ))
        }

        guard let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player  = try? engine.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    // MARK: - Scene sync

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
