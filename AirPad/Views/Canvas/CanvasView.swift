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
    /// Frozen tag-anchored territory formation. Computed ONLY on deliberate
    /// triggers (appear, anchor/weight/tint change, Analyze/idle) and reused by
    /// the reactive `syncScene` — so capture/cancel never re-territorialize.
    /// Territory identity is a corpus-clock event; the `nodes` observer is the
    /// interaction clock (decisions.md 2026-07-06 — "the map is a place").
    @State private var territory: FrozenTerritory? = nil
    @State private var navigationPath = NavigationPath()
    /// Node ID currently sitting at the top of the navigation stack
    /// after a router-driven push. Used to dedupe rapid multi-taps on
    /// the same Librarian match (which otherwise stack identical
    /// detail views). Set on every append from the pendingNavigationID
    /// handlers below; cleared when the path returns to root.
    @State private var currentDetailNodeID: String? = nil
    @State private var localTagSuggestions: TagSuggestionContext? = nil
    @State private var isDismissing = false
    /// Swipe-down-to-dismiss follow-finger offset for the presented card (0 = at rest).
    @State private var cardDragY: CGFloat = 0

    /// SB139 Stage 4c2 commit E — cluster identity being renamed by the
    /// user via long-press → "Rename" on a cluster label badge. Drives
    /// the rename alert + text-field binding.
    @State private var clusterBeingRenamedID: UUID? = nil
    @State private var clusterRenameDraft: String = ""

    @Namespace private var zoomNamespace

    // Tag-anchored Map — signal weights (the "gravity" strengths). Tunable dials;
    // T calibrates on device, bake later. The permeability dial binds `language`.
    @AppStorage("map.weight.collection") private var wCollection: Double = 1.0
    @AppStorage("map.weight.anchor") private var wAnchor: Double = 0.6
    @AppStorage("map.weight.language") private var wLanguage: Double = 0.3
    @AppStorage("map.weight.backlink") private var wBacklink: Double = 0.4
    @AppStorage("map.tintByRecency") private var tintByRecency: Bool = true

    /// SKView HUD (draw-call count / fps / nodes) for node-perf spikes. DEBUG only;
    /// empty in Release.
    private var mapDebugOptions: SpriteView.DebugOptions {
        #if DEBUG
        return [.showsFPS, .showsDrawCount, .showsNodeCount]
        #else
        return []
        #endif
    }

    // ws-dark-light-mode — Map background flips with the interface style:
    // #111115 dark / #F4EFE3 light (the detail-view ground). Baked (Map tuner
    // gone); colorScheme drives the live SwiftUI recompute on appearance flip.
    @Environment(\.colorScheme) private var mapColorScheme
    private var mapWeights: TagTerritoryLayout.SignalWeights {
        .init(collection: wCollection, anchor: wAnchor, language: wLanguage, backlink: wBacklink)
    }

    /// Commit 3 — Map is a SpriteKit surface, not a SwiftUI cell, so it can't
    /// diff per-cell. `.onChange(of: store.nodes)` is gated by `Node.==` (id-only)
    /// and never fires on a title/summary/color edit, so an enriched node's sprite
    /// stays stale until a structural resync. This signature captures EXACTLY the
    /// fields `updateNodeSprite` / `bubbleColor` render — id, title, fallback
    /// content, isMeta, tags — so an onChange on it re-runs `syncScene` (which
    /// reuses the frozen territory cache and re-rasterizes only changed sprites)
    /// on precisely those changes and nothing else.
    private var spriteDisplaySignature: [String] {
        store.visibleNodes(in: scope).map { n in
            "\(n.id)\u{01}\(n.title)\u{01}\(n.isMeta ? 1 : 0)\u{01}\(n.tags.joined(separator: ","))\u{01}\(n.items.first?.content ?? "")"
        }
    }

    /// Per-node territory tint — a within-family gradient anchored on the
    /// territory's palette hex, varied by recency (or a stable hash when off).
    /// Label pills keep the flat family anchor.
    private func mapTerritoryColors(_ layout: TagTerritoryLayout.Layout, nodes: [Node]) -> [String: UIColor] {
        let keyColor = territoryColorMap(layout.territories)
        let dates = nodes.map { $0.updatedAt.timeIntervalSince1970 }
        let minD = dates.min() ?? 0
        let span = max(1, (dates.max() ?? 1) - minD)
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: UIColor] = [:]
        for (nodeID, key) in layout.nodeTerritory {
            guard let base = keyColor[key] else { continue }
            let t: Double
            if tintByRecency, let node = byID[nodeID] {
                t = (node.updatedAt.timeIntervalSince1970 - minD) / span
            } else {
                t = Double(abs(nodeID.hashValue) % 100) / 100
            }
            out[nodeID] = familyTint(base, t)
        }
        return out
    }

    /// A frozen territory formation — the deliberate-clock output that reactive
    /// syncs reuse. `colors` is captured at formation time so existing nodes'
    /// tints are byte-identical across a capture/cancel (recency span can't shift
    /// them). `layout` carries frozen positions, membership, centers, centroids.
    private struct FrozenTerritory {
        let layout: TagTerritoryLayout.Layout
        let colors: [String: UIColor]
    }

    /// Deliberately (re)form territories and cache the result. The ONLY place
    /// `TagTerritoryLayout.layout` runs — never on the `nodes` observer. Clears
    /// the cache when the corpus/config has no territories. Logs so console and
    /// on-screen behavior can be reconciled (the old `[Layout]` line was blind
    /// to this path).
    private func formTerritories(nodes: [Node], trigger: String) {
        guard !store.canvasAnchorTags.isEmpty || hasUserCollections else {
            territory = nil
            print("[Territory] No territories (no anchors / user collections) — trigger: \(trigger)")
            return
        }
        let layout = TagTerritoryLayout.layout(
            nodes: nodes, anchors: store.canvasAnchorTags,
            collections: store.collections, weights: mapWeights, radii: mapLayoutRadii(for: nodes)
        )
        territory = FrozenTerritory(layout: layout, colors: mapTerritoryColors(layout, nodes: nodes))
        print("[Territory] Forming \(layout.territories.count) territories — trigger: \(trigger)")
    }

    /// Re-derive Map positions + tint live (weight or tint-toggle change — a
    /// DELIBERATE map action, so it re-forms the frozen cache).
    private func reblendMap() {
        guard !store.canvasAnchorTags.isEmpty || hasUserCollections else { return }
        let nodes = store.visibleNodes(in: scope)
        formTerritories(nodes: nodes, trigger: "reblend")
        guard let frozen = territory else { return }
        scene.rearrangeToPositions(frozen.layout.positions.mapValues { CGPoint(x: $0.x, y: -$0.y) })
        scene.applyTerritoryColors(frozen.colors)
    }

    /// Shift a base color within its hue family — brightness (+ a touch of
    /// saturation) by `t` (0 dimmer/older → 1 brighter/newer). Hue is anchored.
    private func familyTint(_ base: UIColor, _ t: Double) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard base.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return base }
        let nb = min(1.0, max(0.40, b * CGFloat(0.78 + 0.44 * t)))
        let ns = min(1.0, max(0.0, s * CGFloat(1.05 - 0.15 * t)))
        return UIColor(hue: h, saturation: ns, brightness: nb, alpha: a)
    }

    @State private var scene: CorpusPhysicsScene = {
        let s = CorpusPhysicsScene(size: CGSize(width: 393, height: 852))
        s.scaleMode = .resizeFill
        s.backgroundColor = .clear
        return s
    }()

    // MARK: - Body

    var body: some View {
        canvasWithLateObservers
            // Live theme flip → push the authoritative colorScheme into the scene
            // (the orb-desync fix). Placed on `body` — a light chunk — so the
            // observer chains stay within the type-checker's budget.
            .onChange(of: mapColorScheme) { _, newScheme in
                scene.appearanceIsLight = (newScheme == .light)
            }
    }

    // Body observers are split across two computed properties purely to keep
    // each modifier chain within the Swift type-checker's budget (same reason
    // `canvasStack` is extracted). Order is preserved; behavior is unchanged.
    private var canvasWithEarlyObservers: some View {
        NavigationStack(path: $navigationPath) {
            canvasStack
        }
        .onAppear {
            // Push the authoritative light/dark into the scene so the orbs stop
            // reading it through a nil-prone `view?.traitCollection` (dropped
            // transmission on Analyze re-formation). Same signal as AppearancePalette.
            scene.appearanceIsLight = (mapColorScheme == .light)
            scene.canvasState = canvasState
            scene.selection = selection
            store.canvasState = canvasState
            store.detailViewDepth = navigationPath.count
            previousNodeIDs = Set(store.filteredNodes(in: scope).map { $0.id })
            // .onAppear RENDERS — it must never re-derive territories. A
            // view-lifecycle event (e.g. returning from the capture sheet, which
            // re-presents the canvas underneath) would otherwise rebuild every
            // territory from zero — the cancel shift. syncScene forms ONCE on cold
            // start (territory == nil); a valid cache is only rendered. Deliberate
            // re-formation is Analyze/idle/anchor/weights/batch — not appear.
            syncScene(nodes: store.visibleNodes(in: scope))
            scene.refreshSelectionOutlines()
            kickOffSubstrateAutoFitIfNeeded()
            kickOffClusterLabelingIfNeeded()
        }
        .onChange(of: store.territoryFormationRequest) { _, _ in
            // DELIBERATE re-formation — Analyze button / idle fallback bumped the
            // signal (runCorpusAnalysis). This is the only reactive path allowed
            // to re-territorialize; capture/cancel reuse the frozen formation.
            formTerritories(nodes: store.visibleNodes(in: scope), trigger: "analyze")
            syncScene(nodes: store.visibleNodes(in: scope))
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
        .onChange(of: spriteDisplaySignature) { _, _ in
            // Commit 3 — a sprite's rendered fields (title/summary/color) changed
            // (e.g. enrichment wrote a title) but `Node.==` hid it from the nodes
            // observer above. Re-sync so `updateNodeSprite` re-rasterizes the
            // changed sprite. Reuses the frozen territory cache — no reshuffle.
            syncScene(nodes: store.visibleNodes(in: scope))
        }
        .onChange(of: SubstrateLayoutService.shared.generation) { _, _ in
            // SB139 Stage 4c1 — fit/load/clear in the substrate service bumps
            // `generation`. Re-sync so substrate-derived positions replace
            // legacy ones (or vice versa on clear).
            syncScene(nodes: store.visibleNodes(in: scope))
            // SB139 Stage 4c2 commit D — kick off FM label generation for any
            // persistent clusters whose registry identity has no label yet.
            // Gated by `labelMissingClusters` on identity.label == nil so a
            // re-fit on the same membership is a no-op. Summary closure
            // resolves through the live store so a node summary updated
            // between fits is reflected in the prompt.
            kickOffClusterLabelingIfNeeded()
        }
        .onChange(of: store.filteredNodes) { old, filtered in
            // Re-sync when filter state changes (tag filter, type filter, etc.)
            print("[Canvas] onChange(filteredNodes): \(old.count)→\(filtered.count), visibleNodes=\(store.visibleNodes(in: scope).count)")
            syncScene(nodes: store.visibleNodes(in: scope))
        }
        .onChange(of: store.tags) { _, _ in
            syncScene(nodes: store.visibleNodes(in: scope))
        }
    }

    private var canvasWithLateObservers: some View {
        canvasWithEarlyObservers
        // Tag-anchored Map — migration. When the anchor SET changes (designate /
        // demote), animate existing sprites to their new territory homes (or
        // back to the canonical layout when the last anchor is demoted). `syncScene`
        // above already refreshed `positionMap` for new sprites; this moves the
        // ones already on screen so nothing teleports.
        .onChange(of: store.tags.filter(\.isCanvasAnchor).map(\.id.uuidString).sorted()) { _, _ in
            // Designating/demoting an anchor is a DELIBERATE map action → re-form.
            let nodes = store.visibleNodes(in: scope)
            if store.canvasAnchorTags.isEmpty && !hasUserCollections {
                // No territories left → animate back to the canonical layout and
                // clear the tint + frozen cache.
                territory = nil
                let sk = store.canvasLayout.positions.mapValues { CGPoint(x: $0.x, y: -$0.y) }
                scene.rearrangeToPositions(sk)
                scene.applyTerritoryColors([:])
            } else {
                formTerritories(nodes: nodes, trigger: "anchor-change")
                if let frozen = territory {
                    // SwiftUI-space → SpriteKit (y-up).
                    scene.rearrangeToPositions(frozen.layout.positions.mapValues { CGPoint(x: $0.x, y: -$0.y) })
                    scene.applyTerritoryColors(frozen.colors)
                }
            }
        }
        // Tag-anchored Map — re-blend live as the gravity weights (and tint
        // toggle) are dialed.
        .onChange(of: [wCollection, wAnchor, wLanguage, wBacklink]) { _, _ in
            reblendMap()
        }
        .onChange(of: tintByRecency) { _, _ in reblendMap() }
        .onChange(of: store.filterState.sortOrder) { _, newOrder in
            rearrangeForSortOrder(newOrder, nodes: store.visibleNodes(in: scope))
        }
        .onChange(of: store.canvasNeedsSync) { _, _ in
            // Fired by batchImportText after canvasLayout is updated with all new positions.
            // Belt-and-suspenders: ensures the scene reflects the final store state even if
            // the per-node onChange chain was coalesced or ran before canvasLayout was ready.
            // Batch import is a DELIBERATE bulk placement → re-form territories so the
            // imported nodes land in geography (single-node drift can't cover a bulk add).
            previousNodeIDs = Set(store.nodes(in: scope).map { $0.id })
            print("[Canvas] canvasNeedsSync: forcing full resync — visibleNodes=\(store.visibleNodes(in: scope).count) layoutPositions=\(store.canvasLayout.positions.count) sprites=\(scene.spriteCount)")
            formTerritories(nodes: store.visibleNodes(in: scope), trigger: "batch-resync")
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
            if nodeID != currentDetailNodeID {
                navigationPath.append(node)
                currentDetailNodeID = nodeID
            }
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
            .alert("Rename cluster", isPresented: Binding(
                get: { clusterBeingRenamedID != nil },
                set: { if !$0 { clusterBeingRenamedID = nil } }
            )) {
                TextField("Label", text: $clusterRenameDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                Button("Cancel", role: .cancel) {
                    clusterBeingRenamedID = nil
                    clusterRenameDraft = ""
                }
                Button("Save") {
                    commitClusterRename()
                }
            } message: {
                Text("Up to 32 characters. The FM label service will not overwrite a manual rename — use Clear label to re-open it.")
            }
            .onChange(of: store.pendingTagSuggestions) { _, new in
                if let new, localTagSuggestions == nil { localTagSuggestions = new }
            }
            .onChange(of: router.pendingNodeNavigationID) { _, newValue in
                guard let id = newValue,
                      let node = store.nodes.first(where: { $0.id == id })
                else { return }
                if id != currentDetailNodeID {
                    // Atomic wholesale assignment — single state mutation, so
                    // there's no transient depth-0 frame between removeLast and
                    // append (which let chrome bleed and let rapid taps stack).
                    // Rapid-fire taps converge to last-write-wins at depth=1.
                    navigationPath = NavigationPath([node])
                    currentDetailNodeID = id
                }
                router.pendingNodeNavigationID = nil
            }
            // #3 — shared focus signal: Map flies the camera to the node's orb
            // in place (no view-mode switch, no Detail push).
            .onChange(of: router.pendingFocusNodeID) { _, id in
                guard let id else { return }
                scene.focusNode(id)
                router.pendingFocusNodeID = nil
            }
            .onChange(of: navigationPath.count) { _, newCount in
                // Authoritative depth signal. `navigationPath` only ever
                // contains Node values (the sole `.navigationDestination
                // (for: Node.self)`), so `count` is the detail depth.
                // ContentView's `isInDetailView` handler reads this for
                // first-enter/last-exit panel choreography.
                store.detailViewDepth = newCount
                // Back-out → root: clear so a subsequent tap on the
                // same node pushes a fresh detail view.
                if newCount == 0 { currentDetailNodeID = nil }
            }
    }

    private var canvasZStack: some View {
        ZStack(alignment: .bottomTrailing) {
            AppearancePalette.mapBackground(dark: mapColorScheme == .dark)
                .ignoresSafeArea()

            SpriteView(
                scene: scene,
                preferredFramesPerSecond: 120,
                options: [.allowsTransparency, .ignoresSiblingOrder],
                debugOptions: mapDebugOptions
            )
            .ignoresSafeArea()
            .blur(radius: (canvasState.isZoomed || isDismissing) ? 8 : 0)
            .animation(.easeInOut(duration: 0.25), value: canvasState.isZoomed)

            if store.nodes(in: scope).isEmpty {
                EmptyStateOverlay()
                    .transition(.opacity)
            }

            clusterLabelOverlay
            territoryLabelOverlay
            focalEngagementOverlay
            nodeSummaryLayer
            drillDownBackButton

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
                        // Light-mode convergence — adaptive ink (dark `#FFFFFF`,
                        // light `#232A2E`) on the already-adaptive `.ultraThinMaterial`
                        // drill-down pill; was hardcoded `.white` (illegible on the
                        // cream map in light).
                        .foregroundStyle(AppearancePalette.ink)
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

    /// Open the rename alert for `pid`, seeding the draft from the
    /// current label so the user can edit in place. Kept available for
    /// when rename gets a real surface (long-press on cluster dot,
    /// settings list); not currently called now that the SwiftUI label
    /// overlay has been migrated into the SpriteKit scene.
    private func beginRenamingCluster(_ pid: UUID) {
        clusterRenameDraft = SubstrateClusterRegistry.shared.label(for: pid) ?? ""
        clusterBeingRenamedID = pid
    }

    /// Commit the rename draft. Trims whitespace, drops empty input
    /// (treat as cancel), caps at 32 chars to keep the badge tidy.
    /// Stamps `.user` source so the FM label service will not overwrite
    /// it on subsequent passes; a separate "Clear label" gesture
    /// re-opens the identity to `.fm` regeneration.
    private func commitClusterRename() {
        defer {
            clusterBeingRenamedID = nil
            clusterRenameDraft = ""
        }
        guard let pid = clusterBeingRenamedID else { return }
        let trimmed = clusterRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let capped = String(trimmed.prefix(32))
        SubstrateClusterRegistry.shared.setLabel(persistentID: pid, label: capped, source: .user)
    }

    /// Tag-colored gradient that tracks the focal node during honeycomb engagement.
    /// SpriteKit owns the geometry (position, scale via lens); CanvasState bridges
    /// position and diameter here continuously, including through preCollapse and
    /// disengaging via `disengagingFocalNodeID` so the overlay shrinks with the
    /// sprite as it eases back into the corpus instead of cutting at full size.
    /// Hidden during zoom — `nodeSummaryLayer` morphs in with the same gradient
    /// and takes over.
    /// Title/summary text renders HERE (the SpriteKit sprite + its child
    /// titleLabel are alpha-0 during engagement, and `swapToFocalTexture` no
    /// longer rasterizes focal text). The type is drawn at the FINAL focal size
    /// (`focalNodeFinalDiameter`) so it doesn't reflow as the node grows, with a
    /// single opacity crossfade in on engage / out on release.
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
                // Final (settled) focal size — the title renders at THIS size and
                // just crossfades, so it doesn't reflow/scale as the node grows in.
                let finalDiameter = canvasState.focalNodeFinalDiameter > 0
                    ? canvasState.focalNodeFinalDiameter : diameter
                let displayTitle = node.title.isEmpty ? (node.items.first?.content ?? "") : node.title

                // MORPH-TO-CARD — one clock (focalMorph): the focal grows as a
                // bubble, then morphs into the node's actual Card View face in
                // place. Frame + corner interpolate circle → 5:7 card; the bubble
                // crossfades out as the card fades in. Release runs it back.
                let m = canvasState.focalMorph
                // This overlay is now a COMMITTED card (tap-driven cardedNodeID),
                // not a transient graze — so it catches taps (card→detail + X) once
                // mostly morphed. During the dismiss fade cardedNodeID is nil → the
                // card stops catching taps and empty taps pass through to the scene.
                let isCarded = (canvasState.cardedNodeID == id)
                let cardH = finalDiameter * 1.4          // 5:7 portrait
                let w = diameter + (finalDiameter - diameter) * m
                let h = diameter + (cardH - diameter) * m
                let cardCorner: CGFloat = 30             // mirrors NodeCardView.cornerRadius
                let corner = (diameter / 2) + (cardCorner - diameter / 2) * m

                ZStack {
                    // BUBBLE — gradient + centered title, clipped to the morphing
                    // shape, crossfading out as the card comes in. Title opacity is
                    // slaved to scale progress (one clock) so a fast graze never
                    // lets it linger; it also hands off to the card's own title.
                    ZStack {
                        // Node wash (option 3) — a subtle DIAGONAL two-stop gradient
                        // of the node's own territory shade (one hue, light → dark),
                        // topLeading → bottomTrailing. The dark stop is clamped out
                        // of the mid-luminance dead zone, so there's always a dark
                        // region under the text.
                        let (washLight, washDark) = NodeGradientLayer.washStops(
                            baseHex: canvasState.focalNodeShadeHex ?? "#5B8FFF")
                        LinearGradient(colors: [washLight, washDark],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)

                        // The wash guarantees a dark region under the text, so the
                        // contrast rule resolves to light ink + a dark halo (the
                        // halo also carries the type across the lighter diagonal end).
                        let ink = Color(red: 1.0, green: 0.98, blue: 0.95)
                        let halo = Color.black.opacity(0.6)
                        VStack(spacing: finalDiameter * 0.025) {
                            Text(displayTitle)
                                .font(.custom("SourceSerif4-Bold", size: finalDiameter * 0.085))
                                .foregroundStyle(ink)
                                .shadow(color: halo, radius: 3)
                                .shadow(color: halo, radius: 1)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            if !node.summary.isEmpty {
                                Text(node.summary)
                                    .font(.custom("SourceSerif4-Regular", size: finalDiameter * 0.05))
                                    .foregroundStyle(ink)
                                    .shadow(color: halo, radius: 3)
                                    .shadow(color: halo, radius: 1)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(4)
                            }
                        }
                        .frame(width: finalDiameter * 0.7)
                        .opacity(canvasState.focalScaleProgress)
                    }
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                    .opacity(1 - m)
                    .allowsHitTesting(false)   // bubble never eats taps

                    // CARD — the node's real face (same type voice), fading in as
                    // the bubble morphs. Built only while morphing (m>0), so a fast
                    // graze that never settles never instantiates the card.
                    if m > 0.001 {
                        // Swipe-down-to-dismiss: follow-finger offset + fade/scale.
                        let dismissDistance: CGFloat = 240
                        let dragFrac = min(cardDragY / dismissDistance, 1)
                        ZStack(alignment: .topTrailing) {
                            NodeCardView(nodeID: id, fallbackNode: node, animateEntry: false)
                                .frame(width: w, height: h)
                                // CARD → DETAIL: tapping the presented card pushes
                                // NodeDetailView (reuses the working pendingNavigation
                                // path) and clears the card.
                                .contentShape(RoundedRectangle(cornerRadius: cardCorner))
                                .onTapGesture {
                                    MapHaptics.detail()   // the set's arrival tick
                                    canvasState.pendingNavigationNodeID = id  // → NodeDetailView (verified route)
                                    canvasState.cardedNodeID = nil
                                }
                            // DISMISS X (upper-right) → back to browse.
                            if isCarded && m > 0.5 {
                                Button {
                                    canvasState.cardedNodeID = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 26))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.35))
                                        .padding(10)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .transition(.opacity)
                            }
                        }
                        .frame(width: w, height: h)
                        .scaleEffect(1 - dragFrac * 0.12)
                        .offset(y: cardDragY)
                        .opacity(m * (1 - dragFrac * 0.6))
                        // Only the committed, mostly-morphed card is interactive; a
                        // transient/fading overlay lets taps reach the scene beneath.
                        .allowsHitTesting(isCarded && m > 0.5)
                        // SWIPE DOWN — follow-finger, threshold/flick-commit else spring
                        // back. DOWN-ONLY (damp up + lateral) so it never fights the
                        // canvas pan/pinch below. A third dismiss path beside X + tap-away.
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    cardDragY = max(0, value.translation.height)
                                }
                                .onEnded { value in
                                    let dy = max(0, value.translation.height)
                                    let flick = value.predictedEndTranslation.height > 360
                                    if isCarded && (dy > 120 || flick) {
                                        MapHaptics.release()   // soft "let go"
                                        withAnimation(.easeOut(duration: 0.22)) { cardDragY = dismissDistance * 1.6 }
                                        canvasState.cardedNodeID = nil
                                    } else {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { cardDragY = 0 }
                                    }
                                }
                        )
                    }
                }
                .position(canvasState.focalNodeScreenPosition)
                .opacity(isFading ? 0 : 1)
                .ignoresSafeArea()
                // Single crossfade in/out — no scale/bounce.
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isFading)
        // Reset the swipe offset when a NEW card commits/hops (not on dismiss — a
        // swipe-commit sets cardedNodeID nil and needs its slide-out animation intact).
        .onChange(of: canvasState.cardedNodeID) { _, newID in
            if newID != nil { cardDragY = 0 }
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

    /// Per-cluster "background context" labels — frosted `.ultraThinMaterial`
    /// pills with serif type, positioned at each bag's screen-space
    /// centroid (bridged from CorpusPhysicsScene via
    /// `canvasState.clusterCentroidScreenPositions`).
    ///
    /// Why SwiftUI instead of SK: `.ultraThinMaterial` is not raw-SK
    /// reproducible without a custom render pass, and that's the visual
    /// the user wants. Tradeoffs (flagged in `syncClusterCentroidsToCanvasState`):
    /// labels render above strands too (SwiftUI overlay can't sit
    /// between SK z-bands) and read centroids 1 frame stale on fast pan.
    ///
    /// Declutter: greedy, largest-bag-first; ties broken by uuidString
    /// for determinism. A candidate is skipped if its bbox intersects
    /// an already-placed candidate's bbox (+ small halo). Off-screen
    /// candidates are dropped so they don't suppress on-screen
    /// neighbors.
    ///
    /// `TimelineView(.animation)` forces a SwiftUI re-render every
    /// frame so the overlay reads the latest centroid write from the
    /// SK update tick instead of waiting on an @Observable propagation
    /// scheduled for next runloop hop.
    @ViewBuilder
    private var clusterLabelOverlay: some View {
        TimelineView(.animation) { _ in
            ClusterLabelLayer(
                positions: canvasState.clusterCentroidScreenPositions,
                memberCounts: bagMemberCounts()
            )
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Tag-anchored Map — territory name pills as real `.ultraThinMaterial`
    /// glass above the SpriteKitView (same overlay pattern + rationale as the
    /// cluster labels). Positions are bridged screen-space centroids, refreshed
    /// every frame via `TimelineView(.animation)`.
    @ViewBuilder
    private var territoryLabelOverlay: some View {
        TimelineView(.animation) { _ in
            TerritoryLabelLayer(labels: canvasState.territoryLabels)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Pulls per-persistent-cluster member counts off the live bag
    /// layout for declutter prioritization. Empty when no fit is
    /// loaded; the overlay handles that as "no labels to draw".
    private func bagMemberCounts() -> [UUID: Int] {
        guard let bags = SubstrateLayoutService.shared.bagLayout?.bags else { return [:] }
        var out: [UUID: Int] = [:]
        out.reserveCapacity(bags.count)
        for bag in bags { out[bag.persistentClusterID] = bag.memberCount }
        return out
    }

    private func rearrangeForSortOrder(_ order: SortOrder, nodes: [Node]) {
        guard !nodes.isEmpty else { return }
        var positions: [String: CGPoint] = [:]

        switch order {
        case .recency, .alphabetical:
            // Spiral outward from center — index 0 (most recent / first in
            // sort order) near center. Alphabetical sort is a list/grid
            // concern with no spatial meaning in the System Graph; route it
            // through the same neutral spiral as `.recency` so the graph
            // surfaces a default arrangement without lying about ordering.
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

    /// True when there's at least one user (non-system) collection — collections
    /// are gravity territories, so the Map activates for them even without anchors.
    private var hasUserCollections: Bool {
        store.collections.contains {
            !$0.isCorpus && !$0.isJournal && $0.id != NodeCollection.librarianSessionsID
        }
    }

    /// Territory key → designed palette color, assigned by the engine's territory
    /// order. Single source so tint + labels + migration agree.
    private func territoryColorMap(_ territories: [TagTerritoryLayout.Territory]) -> [String: UIColor] {
        var m: [String: UIColor] = [:]
        let palette = CorpusPhysicsScene.territoryPalette
        for (i, t) in territories.enumerated() {
            m[t.key] = palette[i % palette.count]
        }
        return m
    }

    /// Map layout radii — mirror the substrate path's documented fallback chain
    /// (`store.nodeRadii[id]` → `min(30 + 4×(items−1), 60)`, then `× 1.15 + 0.5`
    /// visual inflation) so TagTerritoryLayout is never blind to big nodes' real
    /// extent. `store.nodeRadii` is NOT persisted — on a fresh launch it starts
    /// empty and only fills after capture/import, so passing it raw left big
    /// nodes (Project: AirPad) packed as default-radius and overlapping at rest.
    /// THE EMPTY-nodeRadii-ON-LAUNCH TRAP — 2nd occurrence (1st was substrate 4c1.3).
    private func mapLayoutRadii(for nodes: [Node]) -> [String: CGFloat] {
        var out: [String: CGFloat] = [:]
        out.reserveCapacity(nodes.count)
        for node in nodes {
            let geometric: CGFloat
            if let r = store.nodeRadii[node.id] {
                geometric = r
            } else {
                let extra = CGFloat(max(0, node.items.count - 1)) * 4.0
                geometric = min(30.0 + extra, 60.0)
            }
            // ×OrbTuning.sizeScale (default 1.0) so the layout spaces grown orbs
            // proportionally — same scale the scene applies to the visual radius,
            // keeping spacing coupled to size. Layout math unchanged; only its input.
            out[node.id] = (geometric * 1.15 + 0.5) * CorpusPhysicsScene.OrbTuning.sizeScale
        }
        return out
    }

    /// Territory key → palette HEX (same index assignment as `territoryColorMap`,
    /// so the pill stroke and node tint always pair). Hex literal for the label
    /// overlay, per the colorblind house rule.
    private func territoryHexMap(_ territories: [TagTerritoryLayout.Territory]) -> [String: String] {
        var m: [String: String] = [:]
        let hex = CorpusPhysicsScene.territoryPaletteHex
        for (i, t) in territories.enumerated() {
            m[t.key] = hex[i % hex.count]
        }
        return m
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
        var territoryColors: [String: UIColor] = [:]
        var territoryLabels: [CorpusPhysicsScene.TerritoryLabel] = []
        if let drilledClusterID = canvasState.drilledInto,
           store.uberNodeCache?.clusters.first(where: { $0.id == drilledClusterID }) != nil,
           let centerPos = expandingFrom {
            // Radial layout around Über-node position
            layoutPositions = computeRadialLayout(nodes: nodes, center: centerPos)
        } else if !store.canvasAnchorTags.isEmpty || hasUserCollections {
            // Tag-anchored Map (gravity model). REUSE the frozen formation —
            // never re-derive here (this runs on the interaction clock). A
            // newly captured node DRIFTS into the frozen geography at its
            // best-fit centroid; every existing node keeps its frozen position,
            // tint, and territory. Re-formation happens only on deliberate
            // triggers (see `formTerritories`).
            if territory == nil {
                formTerritories(nodes: nodes, trigger: "cold-start")
            }
            if let frozen = territory {
                let layout = frozen.layout
                var positions = layout.positions
                var colors = frozen.colors
                var membersByKey: [String: [String]] = [:]
                for (nodeID, key) in layout.nodeTerritory {
                    membersByKey[key, default: []].append(nodeID)
                }
                // Drift the newly captured node into the frozen formation.
                if let newNodeID, positions[newNodeID] == nil,
                   let newNode = nodes.first(where: { $0.id == newNodeID }) {
                    let placement = TagTerritoryLayout.driftPlacement(
                        for: newNode, anchors: store.canvasAnchorTags,
                        collections: store.collections, weights: mapWeights, in: layout
                    )
                    positions[newNodeID] = placement.position
                    if let key = placement.key {
                        membersByKey[key, default: []].append(newNodeID)
                        if let base = territoryColorMap(layout.territories)[key] {
                            colors[newNodeID] = familyTint(base, Double(abs(newNodeID.hashValue) % 100) / 100)
                        }
                    }
                }
                layoutPositions = positions
                territoryColors = colors
                let keyHex = territoryHexMap(layout.territories)   // flat family anchor — label pill stroke
                territoryLabels = layout.territories.compactMap { t in
                    guard let members = membersByKey[t.key], !members.isEmpty else { return nil }
                    return CorpusPhysicsScene.TerritoryLabel(
                        key: t.key,
                        name: t.name,
                        colorHex: keyHex[t.key] ?? "#BBBBBB",
                        memberIDs: members
                    )
                }
            } else {
                // No territories in this corpus/config — canonical positions.
                layoutPositions = store.canvasLayout.positions
            }
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
            // them. `CorpusPhysicsScene` renders nodes as circles with a
            // 1 pt centered stroke (the per-frame blob deformation was
            // retired — Level 1), so the rendered extent exceeds the
            // geometric radius by ~0.5 pt of stroke. PBD's collision model
            // is a circle of the
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
                    // ×OrbTuning.sizeScale — mirror mapLayoutRadii so the substrate
                    // relaxation re-spaces grown orbs too (same scale as the visual).
                    visualRadii[id] = (geometric * 1.15 + 0.5) * CorpusPhysicsScene.OrbTuning.sizeScale
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
            nodeRadii: store.nodeRadii,
            territoryColors: territoryColors
        )
        // Tag-anchored Map — territory name labels (empty in non-Map modes,
        // which clears any previously drawn labels).
        scene.setTerritoryLabels(territoryLabels)
        scene.refreshSelectionOutlines()
        print("[Canvas] syncScene: \(scene.spriteCount) sprites after, \(uberClusters.count) Über-nodes")
    }

    /// SB139 Stage 4c2 commit D — FM cluster-label generation trigger.
    /// Builds the persistent-ID-by-node-ID lookup from the substrate
    /// service and a `summaryProvider` closure that resolves through the
    /// live `store.nodes` (substrate summary preferred, falls back to the
    /// pipeline summary, then title). Bails when no fit is loaded or
    /// clustering hasn't run.
    ///
    /// `labelMissingClusters` is itself idempotent (gates on
    /// identity.label == nil) so calling on every generation change is
    /// safe — a re-fit on the same membership produces a no-op pass.
    private func kickOffClusterLabelingIfNeeded() {
        guard FeatureFlags.substrateLayout else { return }
        let service = SubstrateLayoutService.shared
        guard let model = service.fittedModel,
              let pids = service.persistentClusterIDs,
              model.trainingPoints.count == pids.count else { return }

        var persistentIDByNodeID: [String: UUID] = [:]
        persistentIDByNodeID.reserveCapacity(pids.count)
        // Build the embedding snapshot in the same pass — the labeler's
        // coherence gate reads it to decide whether to ask FM at all.
        // Same vectors HDBSCAN cut on, so coherence aligns with the
        // boundary that defined the cluster.
        var embeddingByNodeID: [String: [Float]] = [:]
        embeddingByNodeID.reserveCapacity(pids.count)
        for (i, point) in model.trainingPoints.enumerated() {
            if let pid = pids[i] {
                persistentIDByNodeID[point.nodeID] = pid
                embeddingByNodeID[point.nodeID] = point.inputVector
            }
        }
        guard !persistentIDByNodeID.isEmpty else { return }

        // Capture snapshot maps so the async task doesn't reach into
        // the live store off-MainActor.
        let nodesByID = Dictionary(uniqueKeysWithValues: store.nodes.map { ($0.id, $0) })
        Task { @MainActor in
            await SubstrateClusterLabelService.shared.labelMissingClusters(
                persistentIDByNodeID: persistentIDByNodeID,
                summaryProvider: { nodeID in
                    guard let node = nodesByID[nodeID] else { return nil }
                    if let s = node.substrateSummary, !s.isEmpty { return s }
                    if !node.summary.isEmpty { return node.summary }
                    return node.title.isEmpty ? nil : node.title
                },
                embeddingProvider: { nodeID in
                    embeddingByNodeID[nodeID]
                },
                tagsProvider: { nodeID in
                    nodesByID[nodeID]?.tags ?? []
                }
            )
        }
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
                // Light-mode convergence — adaptive ink. The focal bubble's
                // luminance follows the APP MODE (light → pigment-on-parchment,
                // dark → Solar Flare), so the mode-tracking `AppearancePalette.ink`
                // (dark `#FFFFFF` — byte-identical to the old flat `.white`; light
                // `#232A2E`) is the correct token — NOT the palette-keyed
                // `legibleInk`, which would return cream ink on a light bubble for
                // dark-palette nodes. Opacity ratios (1.0 / 0.85 / 0.65) preserved.
                VStack(alignment: .leading, spacing: 12) {
                    // Title
                    Text(node.title.isEmpty ? (node.items.first?.content ?? "Untitled") : node.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Summary
                    if !node.summary.isEmpty {
                        Text(node.summary)
                            .font(.system(size: 16))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.85))
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
                            .foregroundStyle(AppearancePalette.ink.opacity(0.65))
                        + Text(" ago")
                            .font(.caption)
                            .foregroundStyle(AppearancePalette.ink.opacity(0.65))
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
                            // On frosted `.ultraThinMaterial` (adaptive), so adaptive
                            // ink — not the node-face `legibleInk` used for the text.
                            .foregroundStyle(AppearancePalette.ink.opacity(0.6))
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
            // Stage 4.8 — Rating is a typed atomic and doesn't slot
            // into the legacy six-bucket count chip row; skipped here.
            // If the canvas grows a typed-entry chip later it can read
            // off `.rating` directly.
            case .rating:   break
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
            // Light-mode convergence — adaptive ink (was hardcoded `.white`).
            .foregroundStyle(AppearancePalette.ink.opacity(0.55))
    }
}

// MARK: - Cluster label layer

/// Per-cluster frosted pill labels rendered on top of the SpriteKitView.
///
/// Reads positions written by `CorpusPhysicsScene.syncClusterCentroidsToCanvasState`
/// and label text from `SubstrateClusterRegistry.shared` (re-reads
/// reactively because the registry is `@Observable`). Pills use
/// `.ultraThinMaterial` for the frosted backdrop blur, serif type at
/// fixed pixel size — they do not scale with canvas zoom because they
/// live in SwiftUI, not in the SK scene transform.
///
/// Declutter uses approximate pill widths computed from the rendered
/// string. Exact rendering still happens in `LabelPill` so on-screen
/// fidelity is preserved; the approximation only affects which
/// overlapping pair gets suppressed.
private struct ClusterLabelLayer: View {
    let positions: [UUID: CGPoint]
    let memberCounts: [UUID: Int]

    private static let fontSize: CGFloat = 13
    private static let hPad: CGFloat = 12
    private static let vPad: CGFloat = 6
    private static let minHeight: CGFloat = 26
    private static let approxGlyphWidth: CGFloat = 6.5  // serif 13pt empirical
    private static let halo: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let visibleIDs = declutter(in: bounds)
            ZStack(alignment: .topLeading) {
                ForEach(visibleIDs, id: \.self) { pid in
                    if let pt = positions[pid],
                       let label = SubstrateClusterRegistry.shared.label(for: pid),
                       !label.isEmpty {
                        LabelPill(text: label)
                            .position(pt)
                    }
                }
            }
        }
    }

    /// Greedy member-count-first placement with bbox intersection check.
    /// Off-screen candidates are dropped so they can't suppress
    /// on-screen neighbors. Ties broken by uuidString for determinism.
    private func declutter(in bounds: CGRect) -> [UUID] {
        struct Candidate {
            let pid: UUID
            let box: CGRect
            let priority: Int
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(positions.count)
        for (pid, pt) in positions {
            guard let label = SubstrateClusterRegistry.shared.label(for: pid),
                  !label.isEmpty else { continue }
            let textW = CGFloat(label.count) * Self.approxGlyphWidth
            let w = textW + Self.hPad * 2
            let h = max(Self.fontSize + Self.vPad * 2, Self.minHeight)
            let box = CGRect(x: pt.x - w / 2, y: pt.y - h / 2, width: w, height: h)
                .insetBy(dx: -Self.halo, dy: -Self.halo)
            if !box.intersects(bounds) { continue }
            candidates.append(Candidate(
                pid: pid,
                box: box,
                priority: memberCounts[pid] ?? 0
            ))
        }
        candidates.sort { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.pid.uuidString < b.pid.uuidString
        }
        var placed: [CGRect] = []
        placed.reserveCapacity(candidates.count)
        var visible: [UUID] = []
        visible.reserveCapacity(candidates.count)
        for c in candidates {
            if placed.contains(where: { $0.intersects(c.box) }) { continue }
            placed.append(c.box)
            visible.append(c.pid)
        }
        return visible
    }
}

private struct LabelPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .serif))
            // Light-mode convergence — adaptive ink on the already-adaptive
            // `.ultraThinMaterial` pill (was hardcoded `.white`, illegible on the
            // cream map in light). The white rim (below) is a frosted-glass
            // highlight, correct in both modes — left as-is.
            .foregroundStyle(AppearancePalette.ink.opacity(0.95))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 26)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5)
            )
    }
}

/// Tag-anchored Map — territory name pills, screen-positioned from bridged
/// centroids. Real `.ultraThinMaterial` glass; Source Serif 4; palette stroke.
private struct TerritoryLabelLayer: View {
    let labels: [CanvasState.TerritoryLabelInfo]

    private static let fontSize: CGFloat = 15
    private static let hPad: CGFloat = 14
    private static let vPad: CGFloat = 7
    private static let minHeight: CGFloat = 30
    private static let approxGlyphWidth: CGFloat = 10.5  // Source Serif 4 15pt uppercase + tracking, empirical
    private static let halo: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let visible = declutter(in: bounds)
            ZStack(alignment: .topLeading) {
                ForEach(visible) { label in
                    TerritoryLabelPill(text: label.name, colorHex: label.colorHex)
                        .position(label.screenPosition)
                        // Region-label zoom fade (computed in-scene, shared curve).
                        .opacity(label.lodAlpha)
                }
            }
        }
    }

    /// Greedy declutter in layout order (the engine already emits larger
    /// continents first). Off-screen candidates are dropped; a candidate whose
    /// padded bbox hits an already-placed one is skipped.
    private func declutter(in bounds: CGRect) -> [CanvasState.TerritoryLabelInfo] {
        var placed: [CGRect] = []
        var visible: [CanvasState.TerritoryLabelInfo] = []
        for label in labels {
            let textW = CGFloat(label.name.count) * Self.approxGlyphWidth
            let w = textW + Self.hPad * 2
            let h = max(Self.fontSize + Self.vPad * 2, Self.minHeight)
            let box = CGRect(x: label.screenPosition.x - w / 2,
                             y: label.screenPosition.y - h / 2,
                             width: w, height: h)
                .insetBy(dx: -Self.halo, dy: -Self.halo)
            if !box.intersects(bounds) { continue }
            if placed.contains(where: { $0.intersects(box) }) { continue }
            placed.append(box)
            visible.append(label)
        }
        return visible
    }
}

private struct TerritoryLabelPill: View {
    let text: String
    let colorHex: String
    /// Same theme accessor the rest of the canvas chrome uses. Dark keeps the
    /// shipped white; light darkens the text to the detail-view ink so it reads
    /// on cream (this pill was missed by the canvas white-sweep).
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text.uppercased())
            .font(.custom("SourceSerif4-Bold", size: 15))
            .tracking(1.5)
            // Dark (Solar Flare): byte-identical white@0.95. Light (Cucumber
            // Water): AppearancePalette.ink — the same token the detail view uses.
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.95) : AppearancePalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color(hexString: colorHex).opacity(0.95), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

