import SwiftUI
import SpriteKit

/// The real canvas view for Session 2+. Wraps a SpriteKit physics scene with SwiftUI overlays.
struct CanvasView: View {

    @Environment(CorpusStore.self) private var store
    @Environment(SelectionService.self) private var selection
    @Environment(AppRouter.self) private var router
    @State private var canvasState = CanvasState()
    /// What slice of the corpus this canvas renders. Defaults to `.corpus`
    /// so the existing ContentView call site (the only one in A1) keeps its
    /// behavior unchanged. Collection canvases pass `.collection(id)` once
    /// commit D1 wires them up.
    var scope: CanvasScope = .corpus
    @State private var previousNodeIDs: Set<String> = []
    @State private var navigationPath = NavigationPath()
    @State private var localTagSuggestions: TagSuggestionContext? = nil
    @State private var isDismissing = false

    @Namespace private var zoomNamespace

    @State private var scene: CorpusPhysicsScene = {
        let s = CorpusPhysicsScene(size: CGSize(width: 393, height: 852))
        s.scaleMode = .resizeFill
        s.backgroundColor = .clear
        return s
    }()

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navigationPath) {
            canvasStack
        }
        .onAppear {
            scene.canvasState = canvasState
            scene.selection = selection
            store.canvasState = canvasState
            previousNodeIDs = Set(store.filteredNodes(in: scope).map { $0.id })
            syncScene(nodes: store.visibleNodes(in: scope))
            scene.refreshSelectionOutlines()
            kickOffSubstrateAutoFitIfNeeded()
        }
        .onChange(of: store.nodes) { old, newNodes in
            // Observe the broad signal (raw nodes) so collection scopes still
            // pick up membership changes that don't visibly add/remove from
            // the scope. Compare scoped IDs so `addedID` correctly fires the
            // drop-in animation only for nodes that landed in this canvas.
            let scopedNew = store.nodes(in: scope)
            let newIDs = Set(scopedNew.map { $0.id })
            let addedID = newIDs.subtracting(previousNodeIDs).first
            previousNodeIDs = newIDs
            print("[Canvas] onChange(nodes): \(old.count)→\(newNodes.count), addedID=\(addedID ?? "nil"), visibleNodes=\(store.visibleNodes(in: scope).count), layoutPositions=\(store.canvasLayout.positions.count)")
            syncScene(nodes: store.visibleNodes(in: scope), newNodeID: addedID)
            kickOffSubstrateAutoFitIfNeeded()
        }
        .onChange(of: SubstrateLayoutService.shared.generation) { _, _ in
            // SB139 Stage 4c1 — fit/load/clear in the substrate service bumps
            // `generation`. Re-sync so substrate-derived positions replace
            // legacy ones (or vice versa on clear).
            syncScene(nodes: store.visibleNodes(in: scope))
        }
        .onChange(of: store.filteredNodes) { old, filtered in
            // Re-sync when filter state changes (tag filter, type filter, etc.)
            print("[Canvas] onChange(filteredNodes): \(old.count)→\(filtered.count), visibleNodes=\(store.visibleNodes(in: scope).count)")
            syncScene(nodes: store.visibleNodes(in: scope))
        }
        .onChange(of: store.tags) { _, _ in
            syncScene(nodes: store.visibleNodes(in: scope))
        }
        .onChange(of: store.filterState.sortOrder) { _, newOrder in
            rearrangeForSortOrder(newOrder, nodes: store.visibleNodes(in: scope))
        }
        .onChange(of: store.canvasNeedsSync) { _, _ in
            // Fired by batchImportText after canvasLayout is updated with all new positions.
            // Belt-and-suspenders: ensures the scene reflects the final store state even if
            // the per-node onChange chain was coalesced or ran before canvasLayout was ready.
            previousNodeIDs = Set(store.nodes(in: scope).map { $0.id })
            print("[Canvas] canvasNeedsSync: forcing full resync — visibleNodes=\(store.visibleNodes(in: scope).count) layoutPositions=\(store.canvasLayout.positions.count) sprites=\(scene.spriteCount)")
            syncScene(nodes: store.visibleNodes(in: scope))
            print("[Canvas] canvasNeedsSync: after syncScene sprites=\(scene.spriteCount)")
        }
        .onChange(of: canvasState.drilledInto) { oldValue, newValue in
            // Drill-down state changed — resync to show only child nodes or full canvas
            print("[Canvas] onChange(drilledInto): \(newValue ?? "nil"), visibleNodes=\(store.visibleNodes(in: scope).count)")

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

            syncScene(nodes: store.visibleNodes(in: scope), expandingFrom: expandingFrom)
        }
        .onChange(of: canvasState.pendingNavigationNodeID) { _, nodeID in
            guard let nodeID, let node = store.nodes.first(where: { $0.id == nodeID }) else { return }
            navigationPath.append(node)
            canvasState.pendingNavigationNodeID = nil
        }
        .onChange(of: selection.isActive) { _, _ in
            scene.refreshSelectionOutlines()
        }
        .onChange(of: selection.selected) { _, _ in
            scene.refreshSelectionOutlines()
        }
    }

    // MARK: - Canvas stack (extracted to keep body type-checkable)

    private var canvasStack: some View {
        canvasZStack
            .animation(.spring(response: 0.28), value: store.nodes(in: scope).isEmpty)
            .animation(.spring(response: 0.28), value: canvasState.selectedNodeID)
            .navigationDestination(for: Node.self) { node in
                NodeDetailView(nodeID: node.id)
                    .navigationTransition(.zoom(sourceID: node.id, in: zoomNamespace))
            }
            .sheet(item: $localTagSuggestions) { context in
                tagCreationSheet(context: context)
            }
            .onChange(of: store.pendingTagSuggestions) { _, new in
                if let new, localTagSuggestions == nil { localTagSuggestions = new }
            }
            .onChange(of: router.pendingNodeNavigationID) { _, newValue in
                guard let id = newValue,
                      let node = store.nodes.first(where: { $0.id == id })
                else { return }
                navigationPath.append(node)
                router.pendingNodeNavigationID = nil
            }
    }

    private var canvasZStack: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(red: 0.027, green: 0.027, blue: 0.039)
                .ignoresSafeArea()

            SpriteKitView(scene: scene)
                .ignoresSafeArea()
                .blur(radius: (canvasState.isZoomed || isDismissing) ? 8 : 0)
                .animation(.easeInOut(duration: 0.25), value: canvasState.isZoomed)

            if store.nodes(in: scope).isEmpty {
                EmptyStateOverlay()
                    .transition(.opacity)
            }

            focalEngagementOverlay
            nodeSummaryLayer
            drillDownBackButton

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
    }

    /// "+" capture trigger — sits above the LibrarianSurface in the
    /// bottom-anchored VStack so it rides up with the morphing surface
    /// rather than overlapping it. Tap presents the in-app capture overlay
    /// (mounted at ContentView); navigation handoff arrives via
    /// `router.pendingNodeNavigationID` and is pushed onto our own
    /// `navigationPath` (see `canvasStack`).
    private var captureTriggerButton: some View {
        Button {
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

    private func tagCreationSheet(context: TagSuggestionContext) -> some View {
        TagCreationSheet(context: context)
            .onDisappear {
                store.pendingTagSuggestions = nil
                localTagSuggestions = nil
            }
    }

    /// Tag-colored gradient that tracks the focal node during honeycomb engagement.
    /// SpriteKit owns the geometry (position, scale via lens); CanvasState bridges
    /// position and diameter here continuously, including through preCollapse and
    /// disengaging via `disengagingFocalNodeID` so the overlay shrinks with the
    /// sprite as it eases back into the corpus instead of cutting at full size.
    /// Hidden during zoom — `nodeSummaryLayer` morphs in with the same gradient
    /// and takes over.
    /// Title/summary text rendered here too, since the SpriteKit sprite (and its
    /// child titleLabel) is hidden via alpha=0 during engagement. Font sizes mirror
    /// swapToFocalTexture in CorpusPhysicsScene so the visual matches.
    @ViewBuilder
    private var focalEngagementOverlay: some View {
        let isFading = canvasState.currentFocalNodeID == nil
        let trackedID = canvasState.currentFocalNodeID ?? canvasState.disengagingFocalNodeID

        ZStack {
            if let id = trackedID,
               !canvasState.isZoomed,
               !isDismissing,
               canvasState.focalNodeDiameter > 0,
               let node = store.nodes.first(where: { $0.id == id }) {
                let diameter = canvasState.focalNodeDiameter
                let displayTitle = node.title.isEmpty ? (node.items.first?.content ?? "") : node.title

                ZStack {
                    NodeGradientBackground(node: node, cornerRadius: diameter / 2)

                    VStack(spacing: diameter * 0.025) {
                        Text(displayTitle)
                            .font(.system(size: diameter * 0.085, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        if !node.summary.isEmpty {
                            Text(node.summary)
                                .font(.system(size: diameter * 0.05))
                                .foregroundStyle(.white.opacity(0.85))
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                        }
                    }
                    .frame(width: diameter * 0.7)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .position(canvasState.focalNodeScreenPosition)
                .opacity(isFading ? 0 : 1)
                .allowsHitTesting(false)
                .ignoresSafeArea()
                .transition(.scale(scale: 0.7, anchor: .center).combined(with: .opacity))
            }
        }
        .animation(.bouncy(duration: 0.35, extraBounce: 0.2), value: isFading)
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
            store.tags.compactMap { tag -> (String, UIColor)? in
                guard let color = UIColor(hex: tag.colorHex) else { return nil }
                return (tag.name, color)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Compute layout: radial when drilled in, substrate when flag on +
        // fitted, canonical otherwise.
        let layoutPositions: [String: CanvasPosition]
        if let drilledClusterID = canvasState.drilledInto,
           store.uberNodeCache?.clusters.first(where: { $0.id == drilledClusterID }) != nil,
           let centerPos = expandingFrom {
            // Radial layout around Über-node position
            layoutPositions = computeRadialLayout(nodes: nodes, center: centerPos)
        } else if FeatureFlags.substrateLayout,
                  let placements = SubstrateLayoutService.shared.canvasPlacements() {
            // SB139 Stage 4c1 — substrate-as-baseline. Below the auto-fit
            // threshold or before a model lands, `canvasPlacements()`
            // returns nil and the canonical legacy path runs silently.
            let truth = SubstrateCanvasLayoutAdapter.map(placements)
            // SB139 Stage 4c1.3 — one-shot tethered relaxation resolves
            // visual overlap. Truth coords stay first-class on the service;
            // the canvas reads display positions when the flag is on and
            // falls back to truth when off.
            //
            // Radii are inflated from geometric → visual before PBD sees
            // them. `CorpusPhysicsScene` renders nodes as deformed blob
            // paths (16-point perimeter at `radius × (1 + displacement)`,
            // `displacementAmplitude = 0.15`) with a 1 pt centered stroke,
            // so the rendered extent exceeds the geometric radius by up
            // to 15% + ~0.5 pt. PBD's collision model is a circle of the
            // radius it's given; feeding visual radii lets `minGap` keep
            // its honest meaning ("breathing room between visible edges").
            //
            // The source of truth for geometric radius mirrors the scene's
            // fallback chain at `CorpusPhysicsScene.addNodeSprite` line
            // ~1500: prefer `store.nodeRadii` when populated (legacy layout
            // pass ran), otherwise compute from item count via the same
            // formula `bubbleRadius` uses (30 + 4×extras, capped at 60).
            // `store.nodeRadii` is not persisted — on a fresh launch it
            // starts empty and only fills after capture/import/neighborhood
            // events. Relying on it directly leaves PBD blind to large
            // nodes' real extent for an entire session, which produced the
            // cross-color overlap pattern in the 4c1.3 first-light test.
            // Non-substrate stragglers (meta, non-rankable, unembedded) have
            // no UMAP coord and would otherwise drop into the scene at their
            // tag-driven `store.canvasLayout.positions` coord untouched —
            // mixed into the substrate scene unrelaxed, they visibly overlap
            // substrate-fit nodes (the cross-color overlap T saw in the 4c1.3
            // first-light test: green/red/teal "neighborhood palette" nodes
            // sitting inside the blue/orange "substrate HSB" cluster cores).
            //
            // Fix: include every displayed node in PBD. Substrate-fit nodes
            // tether to their substrate truth; non-fit nodes tether to their
            // tag-driven position. Projection resolves cross-class collisions
            // uniformly. Caller owns input assembly; service just caches the
            // result and short-circuits on input-fingerprint match.
            let mergedTruth: [String: CanvasPosition] = {
                var m = store.canvasLayout.positions
                for (id, pos) in truth.positions { m[id] = pos }
                return m
            }()
            let substratePositions: [String: CanvasPosition]
            if FeatureFlags.substrateRelaxation {
                let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
                var visualRadii: [String: CGFloat] = [:]
                visualRadii.reserveCapacity(mergedTruth.count)
                for id in mergedTruth.keys {
                    let geometric: CGFloat
                    if let r = store.nodeRadii[id] {
                        geometric = r
                    } else if let node = nodesByID[id] {
                        let extra = CGFloat(max(0, node.items.count - 1)) * 4.0
                        geometric = min(30.0 + extra, 60.0)
                    } else {
                        geometric = 24
                    }
                    visualRadii[id] = geometric * 1.15 + 0.5
                }
                SubstrateLayoutService.shared.ensureRelaxation(
                    truthPositions: mergedTruth,
                    nodeRadii: visualRadii
                )
                substratePositions = SubstrateLayoutService.shared.displayCanvasPositions
                    ?? mergedTruth
            } else {
                substratePositions = mergedTruth
            }
            layoutPositions = substratePositions
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
            expandingFrom: expandingFrom,
            neighborhoodCache: store.neighborhoodCache,
            nodeRadii: store.nodeRadii
        )
        scene.refreshSelectionOutlines()
        print("[Canvas] syncScene: \(scene.spriteCount) sprites after, \(uberClusters.count) Über-nodes")
    }

    /// SB139 Stage 4c1 — substrate-as-baseline auto-fit trigger. Cheap to
    /// call multiple times: the service early-returns if a model is already
    /// loaded or the rankable count is below `autoFitMinNodeCount`. Called
    /// on canvas appear and whenever `store.nodes` changes so corpus growth
    /// past the threshold triggers the first fit.
    private func kickOffSubstrateAutoFitIfNeeded() {
        guard FeatureFlags.substrateLayout else { return }
        guard SubstrateLayoutService.shared.fittedModel == nil else { return }
        let snapshot = store.nodes
        Task { @MainActor in
            do {
                try await SubstrateLayoutService.shared.ensureFittedIfPossible(allNodes: snapshot, store: store)
            } catch {
                print("[Canvas] Substrate auto-fit error: \(error)")
            }
        }
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
            NodeGradientBackground(
                node: node,
                cornerRadius: isExpanded ? 32 : initialDiameter / 2
            )
            .frame(
                width: isExpanded ? finalWidth : initialDiameter,
                height: isExpanded ? finalHeight : initialDiameter
            )
            .clipShape(RoundedRectangle(cornerRadius: isExpanded ? 32 : initialDiameter / 2))
            .opacity(isExpanded ? 1.0 : 0.0)

            // Text content: fades in after morph completes
            if showText {
                VStack(alignment: .leading, spacing: 12) {
                    // Title
                    Text(node.title.isEmpty ? (node.items.first?.content ?? "Untitled") : node.title)
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
            case .imageVideo: i += 1
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

