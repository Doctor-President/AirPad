import SpriteKit
import UIKit
import simd

/// Node-title typeface. **BAKED to `.fraunces`** (T's device-final, Type arc end) —
/// `mapLabelFont` resolves it to Fraunces72pt-Bold. The audition/tuner is gone; the
/// enum + `mapLabelFont` switch stay so the choice is one-liner-revivable. All faces
/// are OFL/on-device. NOTE: only the Fraunces *72pt* (display) optical cut is bundled
/// — the static instance can't dial `opsz` to the soft TEXT axis; if the 72pt reads
/// too sharp at tiny sizes, bundle the Fraunces TEXT-optical cut. `.lora` stays
/// bundled but dormant; `.sourceSerif`/`.sfSemibold`/`.charter` are system/already-bundled.
enum MapLabelFont: String, CaseIterable {
    case sfSemibold
    case sourceSerif
    case fraunces
    case lora
    case charter
}

/// Curated haptic ESCALATIONS for the browse→commit→detail→release loop. Weight
/// tracks commitment: graze tick (lightest) → tap-orb→card (firmer grab) → card→
/// detail (heaviest, arrival) → swipe-release (soft, "let go"). The `active` set
/// (A/B/C) selects the whole coherent set as one RELATIONSHIP, not individual
/// generators — baked to C ("Gentle"), T's device-final pick. Called from both the
/// scene (graze/commit) and the SwiftUI card overlay (detail/release). Generators
/// cached + reused (main-thread only).
enum MapHaptics {
    static let active: Int = 2   // BAKED: set C "Gentle" (T's device-final pick). 0=A 1=B 2=C
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// The set's graze generator (varies by set: A/B .light, C .soft).
    private static var grazeGen: UIImpactFeedbackGenerator { active == 2 ? soft : light }
    static func prepareGraze() { grazeGen.prepare() }
    /// Graze tick — intensity is already × envelope × centrality × the amount slider.
    static func graze(intensity: CGFloat) { let g = grazeGen; g.impactOccurred(intensity: intensity); g.prepare() }

    /// tap-orb → card (firmer grab).
    static func commit() {
        switch active {
        case 1:  selection.selectionChanged(); selection.prepare()   // B: selection click
        case 2:  light.impactOccurred()                              // C: gentle
        default: medium.impactOccurred()                             // A: medium
        }
    }
    /// card → detail (heaviest, the arrival).
    static func detail() {
        switch active {
        case 1:  notification.notificationOccurred(.success)         // B: success notif
        case 2:  medium.impactOccurred()                             // C
        default: rigid.impactOccurred()                              // A: rigid
        }
    }
    /// swipe-release dismiss — soft "let go" in every set.
    static func release() { soft.impactOccurred(intensity: 0.7) }
}

/// The SpriteKit physics canvas that renders nodes as floating bubbles.
/// Owned by CanvasView; communicates selection events back via CanvasState.
final class CorpusPhysicsScene: SKScene {

    // MARK: - Public interface

    /// Set by CanvasView so the scene can report tap events.
    var canvasState: CanvasState?

    /// Set by CanvasView. When non-nil and `isActive`, taps toggle selection
    /// instead of opening the detail view.
    var selection: SelectionService?

    var spriteCount: Int { nodeSprites.count }

    /// White-flash fix (queue.md:879): fired once, the first time the scene has
    /// begun rendering (first `update`), so CanvasView reveals the map only after
    /// the SpriteView host has real content — its opaque mount-backing (the
    /// gray/white flash on entering the Map) never shows. Re-armed on every
    /// `didMove`. Assigning this AFTER the first render already happened fires it
    /// immediately (guards the set-after-render race that would otherwise leave
    /// the map hidden forever).
    var onFirstRender: (() -> Void)? {
        didSet { if hasRenderedFirstFrame { onFirstRender?() } }
    }
    private var hasRenderedFirstFrame = false

    /// Apply or remove the white outline child for a single node sprite.
    /// Mirrors the `addNewcomerHalo` pattern — the outline lives as a named
    /// child node so it tracks sprite motion automatically.
    func applySelectionOutline(nodeID: String, isSelected: Bool) {
        guard let sprite = nodeSprites[nodeID] else { return }
        if let existing = sprite.children.first(where: { $0.name == "selectionOutline" }) {
            existing.removeFromParent()
        }
        guard isSelected else { return }
        let radius = (sprite.userData?["radius"] as? CGFloat) ?? 30
        let outline = SKShapeNode(circleOfRadius: radius + 6)
        // BUG 10 — unified selection outline colour: Klein Blue #1B59C2, raised
        // contrast over the old white. Distinct from the focus ring's cyan #00BFFF
        // (the two never coexist — entering selection is a touch that clears focus).
        outline.strokeColor = UIColor(red: 0x1B / 255.0, green: 0x59 / 255.0, blue: 0xC2 / 255.0, alpha: 1)
        outline.fillColor = .clear
        outline.lineWidth = 3
        outline.zPosition = 1.0
        outline.name = "selectionOutline"
        sprite.addChild(outline)
    }

    /// Reconcile outlines against the current selection set. Called by
    /// CanvasView whenever `selection.selected` or `isActive` changes.
    func refreshSelectionOutlines() {
        let active = selection?.isActive ?? false
        let picked = selection?.selected ?? []
        for (id, sprite) in nodeSprites {
            let want = active && picked.contains(id)
            let existing = sprite.children.first(where: { $0.name == "selectionOutline" })
            if want, existing == nil {
                applySelectionOutline(nodeID: id, isSelected: true)
            } else if !want, existing != nil {
                existing?.removeFromParent()
            }
        }
    }

    /// #3 focus highlight on Map — the same primitive as the batch-select ring
    /// (`applySelectionOutline`) that T asked us to leverage, but in the focus
    /// colour (electric cyan `#00BFFF`) and slightly wider, so a focused orb
    /// reads as "focused" not "selected". Single-focus: any prior focus ring is
    /// removed first. `nil` clears it. Persists (a named child tracks the orb)
    /// until CanvasView clears it on the user's next touch — same
    /// `focusedHighlightNodeID` semantics as the card/tile glow.
    func applyFocusOutline(nodeID: String?) {
        for (_, sprite) in nodeSprites {
            sprite.children.first(where: { $0.name == "focusOutline" })?.removeFromParent()
        }
        guard let nodeID, let sprite = nodeSprites[nodeID] else { return }
        let radius = (sprite.userData?["radius"] as? CGFloat) ?? 30
        let outline = SKShapeNode(circleOfRadius: radius + 6)
        outline.strokeColor = UIColor(red: 0x00 / 255.0, green: 0xBF / 255.0, blue: 0xFF / 255.0, alpha: 1)
        outline.fillColor = .clear
        outline.lineWidth = 4
        outline.zPosition = 1.0
        outline.name = "focusOutline"
        sprite.addChild(outline)
    }

    /// Animate all existing sprites to new positions (view-only rearrangement; does not
    /// mutate canvasLayout). Positions use SpriteKit convention (y-up from center).
    func rearrangeToPositions(_ positions: [String: CGPoint]) {
        for (nodeID, target) in positions {
            guard let shape = nodeSprites[nodeID] else { continue }
            shape.physicsBody?.velocity = .zero
            shape.physicsBody?.angularVelocity = 0
            let move = SKAction.move(to: target, duration: 0.55)
            move.timingMode = .easeInEaseOut
            shape.run(move, withKey: "rearrange")
        }
    }

    /// Center camera on a node and scale it up for detail preview
    func centerAndZoomNode(_ nodeID: String) {
        guard let shape = nodeSprites[nodeID],
              let view = self.view else { return }

        // Save original state
        originalCameraPosition = cameraNode.position
        originalCameraScale = cameraNode.xScale
        zoomedNodeID = nodeID

        // Save physics body and remove it (node becomes static while zoomed)
        savedPhysicsBody = shape.physicsBody
        shape.physicsBody = nil

        // Save zPosition and bring node to front
        savedZPosition = shape.zPosition
        shape.zPosition = 1000

        // Animate camera to center on node
        let cameraMove = SKAction.move(to: shape.position, duration: 0.38)
        cameraMove.timingMode = .easeInEaseOut

        // Calculate dynamic scale to match card height
        let currentNodeWidth = shape.frame.width
        let screenWidth = view.bounds.width
        let targetWidth = (screenWidth - 80) * 0.75
        let scaleMultiplier = targetWidth / currentNodeWidth

        let nodeScale = SKAction.scale(to: scaleMultiplier, duration: 0.38)
        nodeScale.timingMode = .easeInEaseOut

        let nodeFade = SKAction.fadeAlpha(to: 0, duration: 0.38)
        nodeFade.timingMode = .easeInEaseOut

        cameraNode.run(cameraMove)
        shape.run(.group([nodeScale, nodeFade]), withKey: "zoom")

        // Update canvas state for overlay positioning
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.canvasState?.isZoomed = true
            // Center of screen in view coordinates
            self.canvasState?.zoomedNodeScreenPosition = CGPoint(
                x: view.bounds.midX,
                y: view.bounds.midY
            )
        }
    }

    /// #3 (search-navigates-by-view) — fly the camera to a node's orb WITHOUT
    /// the detail-preview treatment `centerAndZoomNode` does: no node scale-up,
    /// no fade-to-α0, no overlay, no physics removal. This is the Map consumer
    /// of the shared focus request (`requestFocus`) — "show me where it lives, in
    /// the view I'm already in." Same 0.38s ease as the grid scroll so the four
    /// views feel consistent. A scale-pulse emphasis is deliberately omitted:
    /// `applyOrbScales` rewrites each orb's scale every frame, so a hardcoded
    /// pulse would be stomped — emphasis, if wanted, belongs in that system.
    func focusNode(_ nodeID: String) {
        guard let shape = nodeSprites[nodeID] else { return }
        let move = SKAction.move(to: shape.position, duration: 0.38)
        move.timingMode = .easeInEaseOut
        cameraNode.run(move, withKey: "focus")
    }

    /// Reset camera and node scale to original state
    func resetZoom() {
        guard let nodeID = zoomedNodeID,
              let shape = nodeSprites[nodeID] else {
            // If no zoomed node, just update state
            DispatchQueue.main.async { [weak self] in
                self?.canvasState?.isZoomed = false
            }
            // Delay clearing selectedNodeID to allow dismiss animation to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.canvasState?.selectedNodeID = nil
            }
            savedPhysicsBody = nil
            savedZPosition = 0
            return
        }

        // Animate camera back
        let cameraMove = SKAction.move(to: originalCameraPosition, duration: 0.38)
        cameraMove.timingMode = .easeInEaseOut

        // Scale node back to normal and fade back in
        let nodeScale = SKAction.scale(to: 1.0, duration: 0.38)
        nodeScale.timingMode = .easeInEaseOut

        let nodeFade = SKAction.fadeAlpha(to: 1, duration: 0.38)
        nodeFade.timingMode = .easeInEaseOut

        // Restore physics body and zPosition after animation completes
        let restorePhysics = SKAction.run { [weak self, weak shape] in
            guard let self = self, let shape = shape else { return }
            shape.physicsBody = self.savedPhysicsBody
            shape.zPosition = self.savedZPosition
            self.savedPhysicsBody = nil
        }

        cameraNode.run(cameraMove)
        shape.run(.sequence([.group([nodeScale, nodeFade]), restorePhysics]), withKey: "zoom")

        zoomedNodeID = nil

        // Update canvas state: set isZoomed false immediately for dismiss animation trigger
        DispatchQueue.main.async { [weak self] in
            self?.canvasState?.isZoomed = false
        }

        // Delay clearing selectedNodeID to allow dismiss animation to complete (0.53s + buffer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.canvasState?.selectedNodeID = nil
        }
    }

    /// Call whenever CorpusStore.nodes or tags change.
    /// tagColors: map of tag name → UIColor for bubble coloring.
    /// expandingFrom: spawn point for drill-down expansion animation.
    /// neighborhoodCache: neighborhood assignments for cohesion forces.
    /// nodeRadii: computed radii for each node (from LayoutService)
    func syncNodes(
        _ nodes: [Node],
        layoutPositions: [String: CanvasPosition],
        tagColors: [String: UIColor] = [:],
        newNodeID: String? = nil,
        uberNodeClusters: [UberNodeCluster] = [],
        expandingFrom: CGPoint? = nil,
        neighborhoodCache: NeighborhoodCache? = nil,
        nodeRadii: [String: CGFloat] = [:],
        territoryColors: [String: UIColor] = [:],
        territorySlots: [String: Int] = [:]
    ) {
        self.tagColors = tagColors
        self.territoryColors = territoryColors
        self.territorySlots = territorySlots
        positionMap = layoutPositions
        self.neighborhoodCache = neighborhoodCache
        self.nodeRadii = nodeRadii
        self.currentNodes = nodes  // Cache for relatedness computation

        // Sync regular nodes
        let incomingNodeIDs = Set(nodes.map { $0.id })
        let existingNodeIDs = Set(nodeSprites.keys)

        // Resting state: physics wake removed (continuous forces disabled)
        let hasNewNodes = !incomingNodeIDs.subtracting(existingNodeIDs).isEmpty
        if hasNewNodes && nodeSprites.isEmpty {
            print("[Layout] Initial sync for \(nodes.count) nodes")
        }

        // Remove deleted nodes
        for id in existingNodeIDs.subtracting(incomingNodeIDs) {
            nodeSprites[id]?.removeFromParent()
            nodeSprites.removeValue(forKey: id)
            nodeIntrinsicRadii.removeValue(forKey: id)
            nodeRestingPositions.removeValue(forKey: id)
            nodeRestingScales.removeValue(forKey: id)
            nodeOnScreenDiameter.removeValue(forKey: id)   // grid-warp caches
            nodeTitleLodFade.removeValue(forKey: id)
        }

        // Add or update regular nodes
        let newlyAddedIDs = incomingNodeIDs.subtracting(existingNodeIDs)
        for (index, node) in nodes.enumerated() {
            if nodeSprites[node.id] == nil {
                let isNew = node.id == newNodeID
                let spawnPoint = expandingFrom != nil && newlyAddedIDs.contains(node.id) ? expandingFrom : nil
                let stagger = expandingFrom != nil ? TimeInterval(index) * 0.03 : 0
                addNodeSprite(node, isNew: isNew, spawnPoint: spawnPoint, stagger: stagger)
            } else {
                updateNodeSprite(node)
                // Animate to new position if changed
                animateSpriteIfNeeded(nodeID: node.id)
            }
        }

        // Sync Über-nodes
        let incomingUberIDs = Set(uberNodeClusters.map { $0.id })
        let existingUberIDs = Set(uberNodeSprites.keys)

        // Remove deleted Über-nodes
        for id in existingUberIDs.subtracting(incomingUberIDs) {
            uberNodeSprites[id]?.removeFromParent()
            uberNodeSprites.removeValue(forKey: id)
        }

        // Add or update Über-nodes
        for cluster in uberNodeClusters {
            if uberNodeSprites[cluster.id] == nil {
                addUberNodeSprite(cluster, childNodes: nodes)
            } else {
                updateUberNodeSprite(cluster, childNodes: nodes)
            }
        }

        // Canonical resting state: capture target positions and scales from the layout.
        // Reads `positionMap` / `nodeRadii` (the layout's target outputs), not mid-animation
        // sprite state — so engagements during a layout transition still resolve to the
        // correct fingerprint when they disengage.
        captureRestingState()
    }

    /// Populate `nodeRestingPositions` / `nodeRestingScales` from the current layout's
    /// target outputs. Called at the end of every `syncNodes` (initial sync and recompute).
    /// Never call from gesture paths.
    private func captureRestingState() {
        for nodeID in nodeSprites.keys {
            nodeRestingPositions[nodeID] = storedPosition(for: nodeID)
            if let intrinsic = nodeIntrinsicRadii[nodeID], intrinsic > 0 {
                let target = nodeRadii[nodeID] ?? intrinsic
                nodeRestingScales[nodeID] = target / intrinsic
            }
        }
        cachedMeanRestingRadius = nil   // grid-warp mass reference re-derives from the new layout
    }

    // MARK: - Lens (a): global zoom-ramp on idle orb scale + label LOD

    /// Last `cameraNode.xScale` the idle ramp was applied at. `-1` forces a
    /// re-apply on the next idle frame (used on entering idle + on a DEBUG dial).
    private var lastRampCameraScale: CGFloat = -1

    /// Global zoom → idle-scale multiplier ∈ [minShrink, 1.0]. `cameraNode.xScale`
    /// is 1.0 at rest and LARGER when zoomed OUT (SpriteKit camera). Zoomed in
    /// (≤ zoomIn) → 1.0 (orbs at the `OrbTuning.sizeScale` max); zoomed out
    /// (≥ zoomOut) → minShrink (airy); smoothstep between. Pure scalar of zoom.
    private func zoomRampScale(_ cameraScale: CGFloat) -> CGFloat {
        let zin = LensTuning.zoomIn, zout = LensTuning.zoomOut
        if cameraScale <= zin { return 1.0 }
        if cameraScale >= zout { return LensTuning.minShrink }
        let t = (cameraScale - zin) / max(zout - zin, 0.0001)
        let smooth = t * t * (3 - 2 * t)                      // smoothstep 0→1
        return 1.0 + (LensTuning.minShrink - 1.0) * smooth    // lerp 1.0 → minShrink
    }

    /// Clamped smoothstep, for the label LOD fade band.
    private func smoothstepClamp(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - e0) / max(e1 - e0, 0.0001), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Global `u_corner_radius` for the current zoom, on the SAME band as the scale
    /// ramp: zoomed in (≤ zoomIn) → cornerMin (rounded-square text box); zoomed out
    /// (≥ zoomOut) → 0.5 (circle, shape-reading); smoothstep between. Set once per
    /// frame on the shared shader → all orbs morph together, still one batch.
    private func cornerRadiusForZoom(_ cameraScale: CGFloat) -> CGFloat {
        let zin = LensTuning.zoomIn, zout = LensTuning.zoomOut
        let cmin = LensTuning.cornerMin
        if cameraScale <= zin { return cmin }
        if cameraScale >= zout { return 0.5 }
        let t = (cameraScale - zin) / max(zout - zin, 0.0001)
        let smooth = t * t * (3 - 2 * t)
        return cmin + (0.5 - cmin) * smooth
    }

    /// Gentle center-magnify: `1 + amplitude·envelope` at the viewport center,
    /// smoothstep falloff to `1.0` by `radius` (screen-pt band width). `dist` is
    /// scene-space; `/cameraScale` makes the band a consistent SCREEN size. The
    /// `envelope` (0→1, the zoom bloom) scales the bump so on/off is gradual.
    /// Normalized centrality: 1 dead-center → 0 at/beyond the falloff radius (screen).
    private func annulusFalloff(_ dist: CGFloat, cameraScale: CGFloat) -> CGFloat {
        let screenDist = dist / max(cameraScale, 0.0001)
        let t = min(screenDist / max(AnnulusTuning.radius, 1), 1)   // 0 center → 1 edge
        return 1 - (t * t * (3 - 2 * t))                            // 1 center → 0 edge
    }
    private func annulusAmplify(_ dist: CGFloat, cameraScale: CGFloat, envelope: CGFloat) -> CGFloat {
        1 + AnnulusTuning.amplitude * annulusFalloff(dist, cameraScale: cameraScale) * envelope
    }

    /// PER-FRAME orb scale + label LOD. `scale = restingScale × zoomRamp × annulus
    /// Amplify(dist to viewport center)`, magnifying nodes near SCREEN CENTER as the
    /// zoom BLOOM envelope (0→1 across onset…fullZoom) opens — no hard on/off
    /// lurch. Off (envelope 0) → early-out on unchanged zoom. NEVER moves a node.
    private func applyOrbScales() {
        let cameraScale = cameraNode.xScale
        let ramp = zoomRampScale(cameraScale)
        let envelope = AnnulusTuning.envelope(cameraScale)
        let annulusOn = envelope > 0.001
        // Annulus ON → re-run every frame (camera.position pans → magnify center
        // shifts). OFF → only when the zoom actually changed (cheap idle path).
        if !annulusOn && abs(cameraScale - lastRampCameraScale) < 0.0005 { return }
        lastRampCameraScale = cameraScale
        let camPos = cameraNode.position
        let lod = LensTuning.labelLOD
        let fadeHi = lod * 1.5
        for (nodeID, sprite) in nodeSprites {
            let resting = nodeRestingScales[nodeID] ?? 1.0
            var scale = resting * ramp
            if annulusOn {
                // Amplify off the node's HOME distance (not its displaced sprite
                // position) so scale and the relaxation don't feed back on each other.
                let home = nodeRestingPositions[nodeID] ?? sprite.position
                let dx = home.x - camPos.x
                let dy = home.y - camPos.y
                // Double-bump damp: as the committing node's card inflates, fade its
                // annulus contribution so it doesn't amplify THEN morph (two bumps).
                var env = envelope
                if nodeID == activeCardID { env *= 1 - smoothstepClamp(0.3, 0.6, cardProgress) }
                scale *= annulusAmplify(hypot(dx, dy), cameraScale: cameraScale, envelope: env)
            }
            sprite.setScale(scale)
            guard let intrinsic = nodeIntrinsicRadii[nodeID] else { continue }
            // On-screen diameter (pt) = worldDiameter · spriteScale / cameraScale.
            let worldToScreen = scale / max(cameraScale, 0.0001)
            let onScreen = (intrinsic * 2) * worldToScreen
            // Orb edge crispness: drive the SDF feather to a screen-constant width so
            // zooming in doesn't blow the 1px edge into a soft blur (see updateOrbEdgeAA).
            updateOrbEdgeAA(sprite, onScreen: onScreen)

            // Title LOD fade — computed for EVERY orb (title-bearing or not, so the guard below can't
            // starve the grid-warp cache) and HOISTED above the title guard. Same value drives the
            // title alpha; the grid warp reads it so an orb's pinch fades in with its title (below).
            let lodFade = smoothstepClamp(lod, fadeHi, onScreen)
            // ONE derivation of on-screen size + title fade, cached here for the grid warp, which
            // MUST NOT recompute them (two copies of `intrinsic × xScale / cs` would drift).
            nodeOnScreenDiameter[nodeID] = onScreen   // pt
            nodeTitleLodFade[nodeID] = lodFade

            guard let title = sprite.children.first(where: { $0.name == "titleLabel" }) else { continue }
            title.alpha = lodFade   // culls the container cleanly at 0
            // MSDF glyph labels: the custom shader ignores SKNode.alpha, so push the LOD
            // fade to the glyphs as a_lod_alpha (with scale-aware smoothing, one pass).
            // Across the WHOLE band (not gated at alpha > 0) so the fade-IN from zero is
            // smooth — the loop already runs only on zoom-change / annulus, so it's cheap.
            if MSDFLabel.isGlyphContainer(title) {
                MSDFLabel.applyLOD(container: title, lodAlpha: lodFade,
                                   worldToScreenPt: worldToScreen, contentScale: glyphContentScale)
            }
        }
    }

    /// Cached `view.contentScaleFactor` for MSDF smoothing (device px per point).
    private var glyphContentScale: CGFloat { view?.contentScaleFactor ?? 3.0 }

    // Orb edge feather (a_geom.y) clamps — screen-constant AA, tunable.
    private static let orbEdgeMinAA: Float = 0.0003   // floor: avoid a razor-hard / aliased edge
    private static let orbEdgeMaxAA: Float = 0.06     // ceiling: avoid a fuzzy blob when tiny on screen

    /// Drive the orb SDF edge feather (`a_geom.y`) per frame to a SCREEN-CONSTANT width,
    /// like the MSDF `u_px_range`. It's a UV fraction set ONCE at creation (1px at BASE
    /// size), so it scales with the sprite → zooming in blows the feather into a soft
    /// blur. Re-derive it from the on-screen size each frame:
    ///   aa = clamp(contentScaleFactor / onScreenPx, minAA, maxAA),  onScreenPx = onScreen · csf
    /// → a big zoomed orb gets a tiny UV feather (crisp ~1px edge); a small orb gets a
    /// larger UV feather (still ~1px on screen). `a_geom.x` (stroke width) is PRESERVED —
    /// it's the orb's visual weight, not the softness. Called only in `applyOrbScales`,
    /// which already runs per-frame ONLY when the zoom changed (or the annulus is on).
    private func updateOrbEdgeAA(_ sprite: SKNode, onScreen: CGFloat) {
        guard let geom = sprite.value(forAttributeNamed: "a_geom")?.vectorFloat2Value else { return }
        let csf = glyphContentScale
        let onScreenPx = max(onScreen * csf, 0.5)
        let aa = min(Self.orbEdgeMaxAA, max(Self.orbEdgeMinAA, Float(csf / onScreenPx)))
        sprite.setValue(SKAttributeValue(vectorFloat2: vector_float2(geom.x, aa)), forAttribute: "a_geom")
    }

    /// TRANSIENT push-apart for the amplified band. Enlarged nodes (restingScale ×
    /// zoomRamp × annulusAmplify) shove each other apart to keep the breathing gap,
    /// as a per-frame OFFSET from restingPos — the base layout is never mutated.
    /// The PBD is recomputed FROM restingPos each frame (a pure function of the
    /// camera, no feedback), then the sprite damped-lerps toward it (anti-jitter).
    /// When a node's amplification fades (leaves the band) its target → restingPos,
    /// so it settles home. Envelope 0 (above onset) → everything lerps home.
    private func applyBandRelaxation() {
        let cameraScale = cameraNode.xScale
        let envelope = AnnulusTuning.envelope(cameraScale)
        let lerp = AnnulusTuning.relaxLerp
        // Damped move of a sprite toward `target`; skips sub-pixel noise.
        func ease(_ id: String, _ target: CGPoint) {
            guard let sprite = nodeSprites[id] else { return }
            let dx = target.x - sprite.position.x, dy = target.y - sprite.position.y
            if abs(dx) < 0.05 && abs(dy) < 0.05 { return }
            sprite.position = CGPoint(x: sprite.position.x + dx * lerp, y: sprite.position.y + dy * lerp)
        }

        guard envelope > 0.001 else {
            // Envelope closed → relax every displaced node back home; drop the haptic key.
            for (id, _) in nodeSprites { if let h = nodeRestingPositions[id] { ease(id, h) } }
            annulusNearestID = nil
            return
        }

        let ramp = zoomRampScale(cameraScale)
        let camPos = cameraNode.position
        // Band = nodes meaningfully amplified (by their HOME distance to center),
        // CAPPED to the `maxBand` closest to center (the ones that actually overlap)
        // so the per-frame PBD stays O(maxBand²·passes) at any corpus size. Also track
        // the nearest-to-center node (most amplified) for the haptic tick.
        var band: [(id: String, dist: CGFloat, r: CGFloat, home: CGPoint)] = []
        var nearestID: String? = nil
        var nearestDist: CGFloat = .infinity
        for (id, _) in nodeSprites {
            guard let home = nodeRestingPositions[id], let intrinsic = nodeIntrinsicRadii[id] else { continue }
            let dist = hypot(home.x - camPos.x, home.y - camPos.y)
            if dist < nearestDist { nearestDist = dist; nearestID = id }
            let amp = annulusAmplify(dist, cameraScale: cameraScale, envelope: envelope)
            if amp > 1.02 {
                band.append((id, dist, intrinsic * (nodeRestingScales[id] ?? 1) * ramp * amp, home))
            }
        }
        let nearestCentrality = nearestID != nil ? annulusFalloff(nearestDist, cameraScale: cameraScale) : 0
        fireAnnulusHaptic(nearestID, envelope: envelope, centrality: nearestCentrality)
        if band.count > AnnulusTuning.maxBand {
            band.sort { $0.dist < $1.dist }
            band.removeLast(band.count - AnnulusTuning.maxBand)
        }
        var ids: [String] = []
        var rad: [String: CGFloat] = [:]
        var pos: [String: CGPoint] = [:]
        for e in band { ids.append(e.id); rad[e.id] = e.r; pos[e.id] = e.home }
        // Pairwise PBD push-apart from resting homes (transient, recomputed each frame).
        // ★ item 2: orbs OVERLAP because the physics bodies are STATIC (isDynamic=false → no collision
        // resolution at all); separation is ONLY this PBD, and its gap was fixed. Dialing it wider
        // pushes amplified orbs apart (the real lever — a body-radius sync would do nothing here).
        let gap = AnnulusTuning.breathingGap
        for _ in 0..<max(0, AnnulusTuning.relaxPasses) {
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let a = ids[i], b = ids[j]
                    var pa = pos[a]!, pb = pos[b]!
                    let dx = pb.x - pa.x, dy = pb.y - pa.y
                    let dist = hypot(dx, dy)
                    let minDist = rad[a]! + rad[b]! + gap
                    if dist > 0.001 && dist < minDist {
                        let push = (minDist - dist) * 0.5
                        let nx = dx / dist, ny = dy / dist
                        pa.x -= nx * push; pa.y -= ny * push
                        pb.x += nx * push; pb.y += ny * push
                        pos[a] = pa; pos[b] = pb
                    }
                }
            }
        }
        // Ease band nodes toward the ENVELOPE-scaled relaxed offset (so push-apart
        // blooms in with the magnify); everyone else eases home.
        let bandSet = Set(ids)
        for (id, _) in nodeSprites {
            if bandSet.contains(id), let home = nodeRestingPositions[id] {
                let r = pos[id]!
                ease(id, CGPoint(x: home.x + (r.x - home.x) * envelope,
                                 y: home.y + (r.y - home.y) * envelope))
            } else if let h = nodeRestingPositions[id] { ease(id, h) }
        }
    }

    /// Browse tick: fire a heavy impact — scaled by `hapticIntensity × envelope`
    /// (so it's SILENT when the annulus is off and blooms in with the magnification,
    /// killing the zoomed-out phantom ticks) — when the most-amplified node (nearest
    /// to viewport center) CHANGES. Centrality toggle ON also × the node's centrality
    /// (firmer dead-center). Clamped to [minAudible, 1] when it fires; throttled.
    private func fireAnnulusHaptic(_ nearestID: String?, envelope: CGFloat, centrality: CGFloat) {
        guard AnnulusTuning.hapticOn, let nearestID, nearestID != annulusNearestID else {
            if let nearestID { annulusNearestID = nearestID }
            return
        }
        annulusNearestID = nearestID
        let now = CACurrentMediaTime()
        guard now - lastAnnulusHapticTime > annulusHapticThrottle else { return }
        var intensity = AnnulusTuning.hapticIntensity * envelope
        if AnnulusTuning.hapticCentrality { intensity *= centrality }
        intensity = min(1, max(AnnulusTuning.hapticMinAudible, intensity))
        MapHaptics.graze(intensity: intensity)   // set's graze style × the computed intensity
        lastAnnulusHapticTime = now
    }

    // MARK: - Private state

    private var cameraNode = SKCameraNode()
    // SKNode (not SKShapeNode) — unfocused orbs are SKSpriteNodes (shared-shader
    // substrate). Holds ONLY makeShape orbs; über nodes live in `uberNodeSprites`.
    private var nodeSprites: [String: SKNode] = [:]
    var uberNodeSprites: [String: SKShapeNode] = [:]  // Accessed by CanvasView for drill-down
    private var positionMap: [String: CanvasPosition] = [:]

    private var tagColors: [String: UIColor] = [:]
    /// Tag-anchored Map — per-node territory tint (nodeID → its territory tag's
    /// color). Empty in every other mode. Takes precedence in `bubbleColor`.
    private var territoryColors: [String: UIColor] = [:]
    /// Tag-anchored Map — per-node TERRITORY INDEX (nodeID → its territory's order in the layout).
    /// Lets `bubbleColor` re-resolve the tint live from a `RegionPalette` FAMILY (commit 2) instead
    /// of the frozen `territoryColors` snapshot. Empty in other modes / when Current family is active.
    private var territorySlots: [String: Int] = [:]

    /// Re-tint the sprites already on screen for a live designate/demote — new
    /// sprites already read this via `bubbleColor`. Passing `[:]` restores each
    /// node's original (substrate/neighborhood) color.
    func applyTerritoryColors(_ colors: [String: UIColor]) {
        territoryColors = colors
        // Re-tint through the unfocused-orb styler so the light-mode fill dilution
        // + hue wash stay in sync with the new fill. DARK is byte-identical — the
        // styler reproduces the shipped opaque fill + white@0.12 stroke + black wash.
        restyleUnfocusedOrbs()
    }

    /// Designed, distinct territory palette (colorblind-considered qualitative set; hex literals so
    /// it's verifiable per house rule). Assigned to territories by anchor order; the label pill
    /// stroke and member tint share the same entry so colour + name always pair.
    ///
    /// ★ PER APPEARANCE since the 2026-09-15 palette bake — slot i is the same HUE in both, at a
    /// different lightness. `RegionPalette` owns the literals; this is the scene-side accessor.
    static func territoryPaletteHex(isLight: Bool) -> [String] { RegionPalette.currentHex(isLight: isLight) }
    static func territoryPalette(isLight: Bool) -> [UIColor] {
        (isLight ? cachedTerritoryPaletteLight : cachedTerritoryPaletteDark)
    }
    private static let cachedTerritoryPaletteDark: [UIColor] =
        RegionPalette.currentHexDark.map { UIColor(hex: $0) ?? .gray }
    private static let cachedTerritoryPaletteLight: [UIColor] =
        RegionPalette.currentHexLight.map { UIColor(hex: $0) ?? .gray }

    /// A territory name label. Position is NOT stored — it's re-derived each
    /// frame from members' live sprite positions and bridged to the SwiftUI
    /// overlay (`territoryLabelScreenInfo` → `canvasState.territoryLabels`), so
    /// the pill can render as real `.ultraThinMaterial` glass above the SK view.
    struct TerritoryLabel {
        /// Unique territory key ("col:<id>" / "tag:<name>"). Distinct from `name`
        /// so two same-named territories (e.g. a collection and a tag both named
        /// "AirPad") get distinct Identifiable ids downstream.
        let key: String
        let name: String
        let colorHex: String
        let memberIDs: [String]
    }

    /// Store the Map's territory label metadata. The pills themselves are NOT
    /// drawn in-scene (SK can't reproduce `.ultraThinMaterial`); each frame
    /// `syncTerritoryLabelsToCanvasState` projects member centroids to screen
    /// space for the SwiftUI overlay. Passing `[]` clears the overlay.
    func setTerritoryLabels(_ labels: [TerritoryLabel]) {
        territoryLabelData = labels
        // C4: a rebuild / mode switch must not resurrect stale fade or incumbency.
        regionLabelDeclutterAlpha.removeAll()
        regionLabelPlacedLastFrame.removeAll()
    }

    /// Condensed system label font (SF Compact / condensed width) for the tiny
    /// RESTING node labels only — a serif reads muddy at 8–14pt on a wobbling
    /// blob, whereas condensed sans stays crisp and packs more glyphs per line.
    /// Serif (Source Serif 4) stays everywhere identity-bearing: focal bubble,
    /// card face, territory pills, über titles.
    static func condensedLabelFont(size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .semibold, width: .condensed)
    }

    /// Resting-label font — baked to non-condensed SF semibold (`.sans`), T's
    /// device-verified pick from the Map tuner (reverses the old SF Condensed
    /// default). The tuner's condensed / serif options are gone with it.
    static func mapLabelFont(size: CGFloat) -> UIFont {
        // Type arc #2 — the title typeface is auditionable (DEBUG picker; Release
        // baked). Same call site for fit + render, so metrics stay consistent. The
        // bundled/system faces fall back to the SourceSerif4 voice-unifier if a load
        // fails (which would show up as a face reading identical to `.sourceSerif`).
        // NB the orb-title FONT is selected at the MSDF-atlas level (see makeTitleSprite), since
        // titles render from a baked atlas — this UIFont only supplies pointSize for the tier fit.
        switch TypeTuning.fontChoice {
        case .sfSemibold:
            return UIFont.systemFont(ofSize: size, weight: .semibold)
        case .sourceSerif:
            return serifFont(size: size, weight: .bold)               // SourceSerif4-Bold
        case .fraunces:
            return UIFont(name: "Fraunces72pt-Bold", size: size) ?? serifFont(size: size, weight: .bold)
        case .lora:
            return UIFont(name: "Lora-Bold", size: size) ?? serifFont(size: size, weight: .bold)
        case .charter:
            return UIFont(name: "Charter-Bold", size: size) ?? serifFont(size: size, weight: .bold)
        }
    }

    /// Source Serif 4 — the app's editorial serif (note editor default, SB121).
    /// The Map's focal + identity text speak it so the type voice is one. Falls
    /// back to the system serif, then Georgia, if the bundled face fails to load.
    static func serifFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let isBold = weight.rawValue >= UIFont.Weight.semibold.rawValue
        if let f = UIFont(name: isBold ? "SourceSerif4-Bold" : "SourceSerif4-Regular", size: size) {
            return f
        }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: d, size: size)
        }
        return UIFont(name: isBold ? "Georgia-Bold" : "Georgia", size: size) ?? base
    }

    /// Type arc #2 — insert U+00AD soft hyphens at the current locale's hyphenation
    /// points, PER WORD. UILabel breaks at these under `.byWordWrapping` and renders a
    /// VISIBLE hyphen, reliably and EVEN when the text is later uppercased — iOS's
    /// automatic `hyphenationFactor` is skipped for all-caps runs and is finicky under
    /// `.byCharWrapping`; explicit soft hyphens are always honored. Each whitespace
    /// token is hyphenated independently: `CFStringGetHyphenationLocationBeforeIndex`
    /// walks backward and STOPS at the first space, so a whole-title call only breaks
    /// the last word — split first. Computed on the given (original-case) string so
    /// the dictionary recognizes the words; the caller uppercases afterward (U+00AD is
    /// case-neutral). Returns the input unchanged if hyphenation is unavailable (e.g.
    /// the Simulator, which lacks the dictionary) or no word has break points.
    static func softHyphenated(_ s: String) -> String {
        guard let locale = CFLocaleCopyCurrent() as CFLocale?,
              CFStringIsHyphenationAvailableForLocale(locale) else { return s }
        return s.split(separator: " ", omittingEmptySubsequences: true)
            .map { softHyphenatedWord(String($0), locale) }
            .joined(separator: " ")
    }

    /// Soft-hyphenate ONE word (no spaces). Indices are UTF-16; node titles are
    /// effectively ASCII so the Character-array insert lines up (a rare mismatch is
    /// cosmetic, never a crash).
    private static func softHyphenatedWord(_ w: String, _ locale: CFLocale) -> String {
        guard w.count > 4 else { return w }
        let cf = w as CFString
        let len = CFStringGetLength(cf)
        var locs: [Int] = []
        var probe = len
        while probe > 1 {
            let loc = CFStringGetHyphenationLocationBeforeIndex(cf, probe, CFRange(location: 0, length: len), 0, locale, nil)
            guard loc != kCFNotFound, loc > 0, loc < len else { break }
            locs.append(loc)
            probe = loc
        }
        guard !locs.isEmpty else { return w }
        var chars = Array(w)
        for loc in locs.sorted(by: >) where loc <= chars.count {
            chars.insert("\u{00AD}", at: loc)
        }
        return String(chars)
    }

    private var territoryLabelData: [TerritoryLabel] = []
    /// True after we last wrote an empty territory-label set, so we clear the
    /// overlay once instead of every idle frame.
    private var lastTerritoryLabelsEmpty = true

    // ── REGION-LABEL DECLUTTER / EDGE FADE (SHIPPING — runs in Release) ──────────────────────────
    // Moved out of the SwiftUI layer so ONE place decides visibility, on LIVE positions (the layer
    // had a frame-stale copy), and so the decision has per-frame state to EASE against — fixing the
    // two pop causes: the hard screen-edge cull and the greedy overlap drop with no fade.
    //
    /// Per-key eased declutter/edge alpha [0,1], toward (placed ? edgeAlpha : 0). A new key starts at
    /// 0 so it fades IN rather than popping. Pruned to live keys each frame; cleared in
    /// `setTerritoryLabels` so a map rebuild / mode switch can't resurrect stale alphas.
    private var regionLabelDeclutterAlpha: [String: CGFloat] = [:]
    /// Keys that WON a slot last frame — incumbents. They get first refusal this frame with the
    /// smaller `haloKeep`, so a pair straddling the overlap threshold stops oscillating.
    private var regionLabelPlacedLastFrame: Set<String> = []

    // ── REGION-LABEL declutter — **T device-final 2026-09-14**, see
    // Ops/reference/tuner-state-accepted.md (`region-labels: fadeDur / edgeMargin / hysteresisGap`).
    // These replace the provisional 0.45 / 120 / 6 the arc shipped while the dials were live.

    /// Fade duration (s) for the region-label declutter ease.
    private var regionLabelFadeDuration: TimeInterval { 0.720 }
    /// Edge-fade margin M (points past the real bounds over which a leaving label fades out).
    private var regionLabelEdgeMargin: CGFloat { 200.000 }
    /// Hysteresis gap (points) = the EXTRA inset a newcomer must clear beyond an incumbent:
    /// `haloKeep` is fixed at the shared metric halo and `haloPlace = haloKeep + gap`.
    /// (Originally the gap shrank `haloKeep` toward 0 with `haloPlace` fixed at 6, so the 0–40 dial
    /// SATURATED at 6 — every value above it behaved identically and recorded nothing. Widening
    /// outward instead keeps gap=0 exactly equal to no-hysteresis and makes the full range live.)
    private var regionLabelHysteresisGap: CGFloat { 26.462 }

    /// Distance from `box` to `rect`: 0 while they intersect, growing as `box` moves outside.
    private func rectGap(from box: CGRect, to rect: CGRect) -> CGFloat {
        let dx = max(0, max(rect.minX - box.maxX, box.minX - rect.maxX))
        let dy = max(0, max(rect.minY - box.maxY, box.minY - rect.maxY))
        return hypot(dx, dy)
    }

    private var neighborhoodCache: NeighborhoodCache? = nil
    private var nodeRadii: [String: CGFloat] = [:]

    /// Cached corpus snapshot. Source for strand neighbor lookup and other
    /// per-node consumers that need the live `Node` value (not just sprite).
    private var currentNodes: [Node] = []

    // Background grid (AT18.1.9: procedural adaptive shader).
    // Single SKShapeNode parented to cameraNode; shader reconstructs world
    // coordinates from camera position + scale uniforms each frame.
    private var gridNode: SKShapeNode?

    // Zoom state
    private var originalCameraPosition: CGPoint = .zero
    private var originalCameraScale: CGFloat = 1.0
    private var zoomedNodeID: String? = nil
    private var savedPhysicsBody: SKPhysicsBody? = nil
    private var savedZPosition: CGFloat = 0

    // MARK: - Shared shader resources (lazy; created once, reused across all nodes)

    /// 128×128 all-white texture — required so v_tex_coord carries valid 0→1 UV data
    /// on SKShapeNode.fillShader (without fillTexture, v_tex_coord is always (0,0)).
    private lazy var whiteUVTexture: SKTexture = {
        let size = CGSize(width: 128, height: 128)
        UIGraphicsBeginImageContext(size)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return SKTexture(image: img)
    }()

    // (nodeWashTexture / nodeWashLightTexture deleted — the diagonal wash is now a
    //  shader term in orbSpriteShader (a_wash + u_wash_is_light), so it shares the
    //  rounded-box SDF and morphs with the fill instead of being a circular child.)

    /// Gradient shader matching blob.jsx lines 45-50, with inner glow layer
    private lazy var nodeFillShader: SKShader = {
        let src = """
        void main() {
            // Token colors from tokens.jsx
            vec3 purple    = vec3(0.478, 0.322, 1.000);  // #7A52FF
            vec3 coral     = vec3(0.890, 0.420, 0.306);  // #E36B4E
            vec3 ember     = vec3(0.769, 0.235, 0.165);  // #C43C2A
            vec3 magenta   = vec3(0.722, 0.341, 0.831);  // #B857D4
            vec3 highlight = vec3(1.000, 0.843, 0.761);  // #FFD7C2
            vec3 indigo    = vec3(0.231, 0.165, 0.722);  // #3B2AB8

            // UV: (0,0)=bottom-left in SpriteKit, but CSS uses top-left
            // So flip Y: css_y = 1.0 - gl_y
            vec2 uv = v_tex_coord;
            vec2 cssUV = vec2(uv.x, 1.0 - uv.y);

            // Base: linear-gradient(135deg, indigo, ember)
            // 135deg = bottom-left to top-right diagonal
            float diag = (cssUV.x + cssUV.y) * 0.5;
            vec3 base = mix(indigo, ember, diag);

            // Layer 1: radial-gradient(ellipse 70% 60% at 22% 30%, purple 0%, transparent 55%)
            vec2 p1 = (cssUV - vec2(0.22, 0.30)) / vec2(0.70, 0.60);
            float d1 = length(p1);
            float a1 = smoothstep(0.55, 0.0, d1);

            // Layer 2: radial-gradient(ellipse 55% 55% at 78% 28%, coral 0%, transparent 60%)
            vec2 p2 = (cssUV - vec2(0.78, 0.28)) / vec2(0.55, 0.55);
            float d2 = length(p2);
            float a2 = smoothstep(0.60, 0.0, d2);

            // Layer 3: radial-gradient(ellipse 65% 65% at 72% 78%, ember 0%, transparent 65%)
            vec2 p3 = (cssUV - vec2(0.72, 0.78)) / vec2(0.65, 0.65);
            float d3 = length(p3);
            float a3 = smoothstep(0.65, 0.0, d3);

            // Layer 4: radial-gradient(ellipse 50% 60% at 28% 80%, magenta 0%, transparent 65%)
            vec2 p4 = (cssUV - vec2(0.28, 0.80)) / vec2(0.50, 0.60);
            float d4 = length(p4);
            float a4 = smoothstep(0.65, 0.0, d4);

            // Layer 5: radial-gradient(circle at 55% 45%, highlight 0%, transparent 18%)
            vec2 p5 = cssUV - vec2(0.55, 0.45);
            float d5 = length(p5);
            float a5 = smoothstep(0.18, 0.0, d5);

            // Composite layers (CSS default: over blending, back-to-front)
            vec3 color = base;
            color = mix(color, purple,    a1);
            color = mix(color, coral,     a2);
            color = mix(color, ember,     a3);
            color = mix(color, magenta,   a4);
            color = mix(color, highlight, a5 * 0.2);

            // Inner glow: SDF distance-from-boundary falloff
            // Circle in UV space: centered at (0.5, 0.5), radius 0.5
            vec2 center = vec2(0.5, 0.5);
            float circleRadius = 0.5;
            float distFromCenter = length(cssUV - center);
            // Distance inward from boundary (positive inside circle, near boundary)
            float distFromBoundary = circleRadius - distFromCenter;

            // Normalize by glow reach (in UV space: reach_px / node_diameter_px)
            // Default reach: 12px, typical node diameter ~60-120px → ~0.1-0.2 in UV
            float reachNormalized = u_glow_reach / 60.0;  // assuming 60px base diameter
            float normalizedDist = distFromBoundary / reachNormalized;

            // Exponential falloff: glow = exp(-dist * falloff) when dist > 0
            float glowFalloff = u_glow_falloff;
            float glowStrength = 0.0;
            if (normalizedDist > 0.0 && normalizedDist < 1.0) {
                glowStrength = exp(-normalizedDist * glowFalloff) * u_glow_intensity;
            }

            // Glow color: near-white with warm bias, tinted by u_glow_tint
            vec3 glowBaseColor = vec3(1.0, 0.98, 0.94);  // warm white
            vec3 glowColor = mix(glowBaseColor, u_glow_tint, 0.3);

            // Layer glow on top using additive blending
            color = color + glowColor * glowStrength;

            // Chromatic aberration: boundary-based RGB channel shift
            vec2 aberrationDir = normalize(cssUV - center);
            float aberrationMag = smoothstep(0.1, 0.0, distFromBoundary) * u_aberration_scale;
            color.rg += aberrationDir * aberrationMag; color.b -= length(aberrationDir) * aberrationMag * 0.5;

            gl_FragColor = vec4(color, 1.0);
        }
        """
        let shader = SKShader(source: src)

        // Set default glow and chromatic aberration parameters
        shader.uniforms = [
            SKUniform(name: "u_glow_reach", float: 12.0),
            SKUniform(name: "u_glow_intensity", float: 0.5),
            SKUniform(name: "u_glow_falloff", float: 3.0),
            SKUniform(name: "u_glow_tint", vectorFloat3: vector_float3(1.0, 0.95, 0.9)),
            SKUniform(name: "u_aberration_scale", float: 0.008),
            SKUniform(name: "u_aberration_velocity_mult", float: 2.0),
            SKUniform(name: "u_aberration_decay", float: 1.0),
            SKUniform(name: "u_aberration_max", float: 0.02)
        ]

        return shader
    }()

    /// Create Über-node gradient shader with 3 drifting color blobs (per-instance).
    private func makeUberNodeShader(colors: [UIColor]) -> SKShader {
        let src = """
        void main() {
            vec2 uv = v_tex_coord;
            vec2 cssUV = vec2(uv.x, 1.0 - uv.y);
            vec2 center = vec2(0.5, 0.5);

            // Dark base color
            vec3 base = vec3(0.03, 0.03, 0.04);

            // 3 drifting Gaussian-falloff color blobs
            // Blob 1: top-left drift
            vec2 offset1 = vec2(
                0.3 + sin(u_time * 0.3 + u_phase_1) * 0.2,
                0.3 + cos(u_time * 0.25 + u_phase_1 * 0.9) * 0.2
            );
            float d1 = length(cssUV - offset1);
            float strength1 = exp(-d1 * d1 / 0.15);

            // Blob 2: center drift
            vec2 offset2 = vec2(
                0.5 + sin(u_time * 0.35 + u_phase_2) * 0.15,
                0.5 + cos(u_time * 0.3 + u_phase_2 * 1.1) * 0.15
            );
            float d2 = length(cssUV - offset2);
            float strength2 = exp(-d2 * d2 / 0.18);

            // Blob 3: bottom-right drift
            vec2 offset3 = vec2(
                0.7 + sin(u_time * 0.4 + u_phase_3) * 0.2,
                0.7 + cos(u_time * 0.35 + u_phase_3 * 0.7) * 0.2
            );
            float d3 = length(cssUV - offset3);
            float strength3 = exp(-d3 * d3 / 0.16);

            // Sum blobs
            vec3 color = base;
            color += u_color_1 * strength1;
            color += u_color_2 * strength2;
            color += u_color_3 * strength3;

            gl_FragColor = vec4(color, 1.0);
        }
        """

        let shader = SKShader(source: src)

        // Convert UIColors to vec3
        func colorToVec3(_ color: UIColor) -> vector_float3 {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return vector_float3(Float(r), Float(g), Float(b))
        }

        let color1 = colors.count > 0 ? colorToVec3(colors[0]) : vector_float3(0.5, 0.5, 0.5)
        let color2 = colors.count > 1 ? colorToVec3(colors[1]) : vector_float3(0.5, 0.5, 0.5)
        let color3 = colors.count > 2 ? colorToVec3(colors[2]) : vector_float3(0.5, 0.5, 0.5)

        shader.uniforms = [
            SKUniform(name: "u_time", float: 0.0),
            SKUniform(name: "u_color_1", vectorFloat3: color1),
            SKUniform(name: "u_color_2", vectorFloat3: color2),
            SKUniform(name: "u_color_3", vectorFloat3: color3),
            SKUniform(name: "u_phase_1", float: Float.random(in: 0...100)),
            SKUniform(name: "u_phase_2", float: Float.random(in: 0...100)),
            SKUniform(name: "u_phase_3", float: Float.random(in: 0...100))
        ]

        return shader
    }

    // Touch tracking
    private var activeTouches: [UITouch: CGPoint] = [:]    // screen-space positions
    private var tapStartInfo: (screenPoint: CGPoint, time: TimeInterval)?
    private var lastPinchDistance: CGFloat?
    private var lastTapTime: TimeInterval = 0
    private var lastTapLocation: CGPoint = .zero

    // Honeycomb gesture state machine. Browse ≠ commit: no grace sub-machine —
    // a drag is browse (honeycomb), a clean lift is a tap (commit → card).
    private enum GestureState {
        case idle
        case tapCandidate(initialPosition: CGPoint, startTime: TimeInterval)
        case honeycomb(initialPosition: CGPoint, lastPanPosition: CGPoint)
    }

    private var gestureState: GestureState = .idle
    private let dragThreshold: CGFloat = 10.0
    private let panMultiplier: CGFloat = 1.5

    // SB83c: Momentum scrolling on pan release.
    // Samples are screen-space touch positions; velocity is screen px/frame.
    // Coast applies the same `* panMultiplier * cameraNode.xScale` math as touchesMoved (SB83a).
    private var panSamples: [(time: TimeInterval, position: CGPoint)] = []
    private let panSampleWindow: TimeInterval = 0.1
    private var coastVelocity: CGPoint = .zero
    private let coastFriction: CGFloat = 0.95
    private let coastStopThreshold: CGFloat = 0.5
    private let coastLaunchThreshold: CGFloat = 2.0
    // SB83d: True for any tapCandidate → honeycomb transition (idle navigation OR grace-exit pan).
    private var momentumEligible: Bool = false

    // MARK: - Tap-driven card presentation (browse ≠ commit)
    /// The card currently being PRESENTED. Tracks `canvasState.cardedNodeID` and
    /// lingers through the dismiss/hop morph so the overlay follows the orb.
    private var activeCardID: String? = nil
    /// Card morph clock (0 = no card, 1 = full card), eased toward the target each
    /// frame in `updateCardPresentation`. Drives `focalScaleProgress`/`focalMorph`.
    private var cardProgress: CGFloat = 0
    /// Per-frame lerp for the card morph (tap → grow / dismiss) — BAKED 0.10
    /// (T's device-final graceful inflate).
    private let cardMorphLerp: CGFloat = 0.10
    /// Orb→card cross-fade band: the tapped orb holds full alpha until `Start`,
    /// then fades to 0 by `End` as the SwiftUI card face fades IN — so the orb
    /// INFLATES into the card (no instant pop).
    private let cardFadeStart: CGFloat = 0.15
    private let cardFadeEnd: CGFloat = 0.70
    /// On a node CHANGE, cardProgress dips to this so the morph visibly re-lerps
    /// from the new orb — neighbor-hop / re-tap inflates like a first tap (no pop).
    private let cardHopDip: CGFloat = 0.15
    /// Camera recenter-on-commit (pan only): glide `cameraNode.position` from the
    /// snapshot at commit to the tapped node's home on the SAME cardProgress clock.
    private var cardCamStart: CGPoint? = nil
    private var cardCamTarget: CGPoint? = nil

    // Annulus browse tick — fires via MapHaptics (the set's graze style); throttled
    // so fast pans don't machine-gun it.
    private var annulusNearestID: String? = nil
    private var lastAnnulusHapticTime: TimeInterval = 0
    private let annulusHapticThrottle: TimeInterval = 0.05

    /// Last appearance applied to the unfocused orbs, so `update` re-themes them
    /// only when the trait actually flips (light ↔ dark), not every frame. nil
    /// until the first tick (which forces an initial apply once the SKView trait
    /// is available; a no-op if no sprites exist yet — `makeShape` themes those).
    private var lastAppearanceIsLight: Bool? = nil
    /// The most recent graze focal node, kept around through
    /// disengaging so syncFocalToCanvasState can continue bridging its
    /// shrinking position and diameter to the SwiftUI gradient overlay while
    /// the overlay's opacity fades to 0. Cleared at disengaging → idle.
    /// Node currently rendering with the gradient shader (focal render state).
    /// Mutated only via `setFocalShader(to:)`.
    private var focalShaderID: String? = nil

    /// Strand ring-target positions in the undistorted (substrate-resting)
    /// frame, keyed by neighbor nodeID. Populated on engaged-state entry +
    /// focal switch; cleared on honeycomb teardown. Bypasses
    /// the engaged-branch radial-compression target for any node in the dict.
    private var strandTargets: [String: CGPoint] = [:]

    /// Focal whose strand targets are currently in `strandTargets`. Used to
    /// detect focal-switch within engaged state and recompute the ring. nil
    /// when no ring is active (idle / disengaging).
    private var lastStrandFocalID: String? = nil

    /// IDs of sprites currently faded to `StrandService.dimAlpha` via SKAction.
    /// Used so `clearStrandDimming` knows exactly which sprites to fade back —
    /// avoids touching the focal or strand neighbors (which were never dimmed).
    /// SKAction-based on purpose: per-frame alpha writes here race with
    /// `setFocalShader`'s instant `alpha = 0` on the focal and let the focal's
    /// solid fill leak through behind the SwiftUI gradient overlay.
    private var dimmedSpriteIDs: Set<String> = []

    /// SKAction key for strand dim/restore fades. Re-running the action with
    /// the same key cancels any in-flight fade on that sprite — critical for
    /// mid-engagement focal switches where the dim set changes.
    private static let strandDimActionKey = "strandDim"
    private static let strandDimDuration: TimeInterval = 0.2

    /// Saved zPositions for strand neighbors before they were lifted above the
    /// dimmed corpus. Restored on disengage. Strands sit between corpus
    /// (zPosition = 1) and focal (zPosition = focalZPosition = 1000) so the
    /// ring is never occluded by a dimmed sibling.
    private var savedStrandZPositions: [String: CGFloat] = [:]
    private static let strandZPosition: CGFloat = 500

    /// Canonical resting fingerprint — target positions from the algorithmic layout.
    /// Captured at sprite creation, on layout recompute, and persists across engagement cycles.
    /// Never captured per-drag, never cleared on disengage.
    private var nodeRestingPositions: [String: CGPoint] = [:]

    /// Canonical resting fingerprint — target xScale (layout radius / intrinsic radius).
    private var nodeRestingScales: [String: CGFloat] = [:]

    /// Intrinsic (unscaled) sprite radius, captured once at creation. Pure value, never frame-derived.
    private var nodeIntrinsicRadii: [String: CGFloat] = [:]

    /// Focal diameter as a fraction of screen width — LIVE, but for the tap→card morph
    /// (`focalNodeFinalDiameter` / the card-commit glide), not the retired browse lens.
    private let focalScreenFraction: CGFloat = 0.60

    // (The GRAZE-ERA constants that lived here — baselineScreenFraction, positionCompressionFalloff,
    // neighborBreathingGap, engagementLerp, steadyStateLerp, relaxationBand/Passes/BreathingGap,
    // position/scaleMatchTolerance, and characteristicSpacing with its O(n²) median pass — were
    // DELETED 2026-09-15. Each had a declaration and NO reader: they belonged to the focal-lens
    // model that the viewport-centred ANNULUS replaced (`applyOrbScales` / `annulusAmplify` /
    // `applyBandRelaxation` over `AnnulusTuning`). Unused `private let`s draw no compiler warning,
    // which is why a dozen of them sat here looking like tuning.)

    // Shader animation state
    private var shaderStartTime: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Neighborhood cohesion state

    /// Track velocity for convergence detection
    private var velocityHistory: [CGFloat] = []
    private var physicsIsSleeping = false
    private let convergenceThreshold: CGFloat = 0.5  // pt/sec
    private let convergenceFrames = 30

    // MARK: - Newcomer halo state

    private var enableNewcomerHalo: Bool = true
    private let haloFadeDuration: TimeInterval = 300  // 5 minutes

    // MARK: - Scene lifecycle

    override func didMove(to view: SKView) {
        self.isPaused = false
        // White-flash fix: a re-presented scene must re-signal its first frame so
        // CanvasView re-hides then reveals (each mount has the backing gap).
        hasRenderedFirstFrame = false
        backgroundColor = .clear
        physicsWorld.gravity = .zero
        physicsWorld.speed = 1.0

        // Camera
        addChild(cameraNode)
        camera = cameraNode

        // Background grid (AT18.1.9): single procedural-shader SKShapeNode
        // parented to the camera so its screen position is fixed. Shader
        // reconstructs world coordinates from camera uniforms; pan and zoom
        // are entirely handled by the shader's coordinate math.
        let viewportSize = view.bounds.size
        // Map dot geometry, baked (bake-and-delete of the Map tuner): 0.5px dots
        // on an 83pt period. dotOpacity here is the dark seed (0.18) — the
        // per-frame block below drives the real per-mode value (0.18 dark ·
        // 0.47 light) + dot color from the view's trait.
        let grid = BackgroundGridNode.makeShape(viewportSize: viewportSize, fillTexture: whiteUVTexture,
                                                dotSizePx: 0.5, dotOpacity: 0.18, period: 83)
        cameraNode.addChild(grid)
        gridNode = grid

        // Large boundary so nodes don't escape to infinity
        let boundary = CGRect(x: -1500, y: -1500, width: 3000, height: 3000)
        physicsBody = SKPhysicsBody(edgeLoopFrom: boundary)

        view.isMultipleTouchEnabled = true

        // Start shader animation clock
        shaderStartTime = CACurrentMediaTime()
        lastUpdateTime = shaderStartTime

        // (The `-SPRMeasure` / `-SPRBand` synthetic-corpus harnesses were deleted at the
        // 2026-09-14 bake — they existed to dial the now-baked warp/band spikes and were
        // wired to the deleted tuner.)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if let grid = gridNode {
            BackgroundGridNode.resize(grid, to: size)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        if isPaused { return }

        // White-flash fix (queue.md:879): first non-paused frame → tell CanvasView
        // to reveal the map (orbs + labels) now that the host has real content.
        if !hasRenderedFirstFrame {
            hasRenderedFirstFrame = true
            onFirstRender?()
        }

        updateGridWarp()      // grid warp — SHIPS (baked 2026-09-14)

        // SB83c: Coast camera with friction. Same pan math as SB83a (`* cameraNode.xScale`).
        if coastVelocity != .zero {
            let panDx = coastVelocity.x * panMultiplier
            let panDy = coastVelocity.y * panMultiplier
            cameraNode.position.x -= panDx * cameraNode.xScale
            cameraNode.position.y += panDy * cameraNode.xScale
            coastVelocity.x *= coastFriction
            coastVelocity.y *= coastFriction
            if hypot(coastVelocity.x, coastVelocity.y) < coastStopThreshold {
                coastVelocity = .zero
            }
        }

        let elapsed = currentTime - shaderStartTime
        nodeFillShader.uniforms.first(where: { $0.name == "u_time" })?.floatValue = Float(elapsed)

        // Morph RETIRED to dormant: u_corner_radius stays at its 0.5 default (=
        // permanent circle). The per-frame cornerRadiusForZoom drive is gone; the
        // sdRoundBox + uniform machinery is preserved inert for possible revival.
        // Wash composite mode (global): light screen-deepen vs dark darken.
        orbSpriteShader.uniforms.first(where: { $0.name == "u_wash_is_light" })?
            .floatValue = currentIsLight ? 1.0 : 0.0

        // AT18.1.9: push camera state into the grid shader. The grid shape is
        // camera-parented (fixed screen position); the shader handles pan and
        // zoom by reconstructing world coordinates from these uniforms.
        if let grid = gridNode {
            BackgroundGridNode.update(grid,
                                      cameraPosition: cameraNode.position,
                                      cameraScale: cameraNode.xScale)
            // ws-dark-light-mode — push the per-theme dot color + opacity. Dark:
            // white dots @0.18. Light: a cool graphite @0.47 so the dots read on
            // cream. Resolved from the view's trait so it tracks the same
            // appearance the SwiftUI canvas background flips on. (Dot geometry is
            // baked at construction; the tuner is gone.)
            let dotDark = view?.traitCollection.userInterfaceStyle != .light
            let dot = AppearancePalette.mapGridDotRGB(dark: dotDark)
            BackgroundGridNode.setDotAppearance(grid, r: dot.r, g: dot.g, b: dot.b,
                                                opacity: AppearancePalette.mapGridDotOpacity(dark: dotDark))
        }

        // Re-theme unfocused orbs when the appearance flips (light ↔ dark). Fires
        // only on an actual trait change (guarded by lastAppearanceIsLight), not
        // per frame — the DEBUG dial path re-themes separately via CanvasView.
        let orbIsLight = view?.traitCollection.userInterfaceStyle == .light
        if orbIsLight != lastAppearanceIsLight {
            lastAppearanceIsLight = orbIsLight
            restyleUnfocusedOrbs()
        }


        // Über-node shader updates disabled (sprites not rendered)
        // for (_, shape) in uberNodeSprites {
        //     shape.fillShader?.uniforms.first(where: { $0.name == "u_time" })?.floatValue = Float(elapsed)
        // }

        // Update newcomer halos
        if enableNewcomerHalo {
            updateNewcomerHalos(currentTime: currentTime)
        }

        // Per-frame orb scale (zoom ramp × viewport annulus), then the transient
        // pairwise push-apart so enlarged band nodes don't overlap. The engagement
        // machine is retired; displacement is per-frame off restingPos (never mutates
        // the base layout), so nodes settle home as they leave the band.
        applyOrbScales()
        applyBandRelaxation()

        updateCardPresentation()   // tap-driven card morph → SwiftUI overlay
        syncClusterCentroidsToCanvasState()
        syncTerritoryLabelsToCanvasState(currentTime: currentTime)

        // Resting state: continuous physics disabled (forces governed by algorithmic layout)
        // applyNeighborhoodForces and checkConvergence removed
        lastUpdateTime = currentTime
    }

    /// Tracks last focal-id pushed to CanvasState so we can detect transitions to
    /// nil and dispatch a single clear instead of polling canvasState off-isolation.
    private var lastSyncedFocalID: String? = nil

    /// SB139 Stage 4c2 commit D — cached nodeID → persistent cluster UUID
    /// lookup. Rebuilt only when the substrate service's `generation`
    /// counter advances (fit/load/clear/runClustering); per-frame the
    /// centroid pass walks this map without touching the service.
    private var nodeIDToPersistentClusterID: [String: UUID] = [:]

    /// Generation snapshot for `nodeIDToPersistentClusterID`. Sentinel
    /// `-1` forces the first build on first frame.
    private var lastSeenSubstrateGeneration: Int = -1

    /// Tracks which persistent-cluster pids we wrote to
    /// `canvasState.clusterCentroidScreenPositions` last frame, so we can
    /// remove entries whose cluster has dropped out of the live fit
    /// without churning the whole dictionary on every tick.
    private var lastWrittenCentroidPids: Set<UUID> = []

    /// Bridges the engaged focal node's screen-space center and diameter to
    /// CanvasState every frame so the SwiftUI gradient overlay can track it as the
    /// user drags. Runs from `update(_:)`, which SpriteKit invokes on the main
    /// thread; the dispatch is for @MainActor isolation only.
    /// Update the tap-driven card morph, then bridge it to the SwiftUI overlay.
    /// Browse never drives this — only `canvasState.cardedNodeID` does. Tap →
    /// `cardedNodeID` set → the orb INFLATES into the card (its alpha cross-fades to
    /// the SwiftUI card face mid-morph). Tap-empty / X clears it → shrink. Tapping
    /// another orb reassigns it → the card hops (progress stays up → no teardown).
    private func updateCardPresentation() {
        let carded = canvasState?.cardedNodeID
        if carded != activeCardID {
            if let prev = activeCardID, let s = nodeSprites[prev] { s.alpha = 1 }
            // COMMIT / NEIGHBOR-HOP: dip the morph so it visibly re-lerps from the new
            // orb (every commit inflates the same way — no full-progress re-point pop),
            // and snapshot the camera glide toward the new node (pan only). DISMISS
            // (carded == nil) leaves cardProgress + camera alone.
            if let id = carded {
                cardProgress = min(cardProgress, cardHopDip)
                cardCamStart = cameraNode.position
                cardCamTarget = nodeRestingPositions[id] ?? nodeSprites[id]?.position
                coastVelocity = .zero   // cancel any pan-coast momentum in flight
            } else {
                cardCamStart = nil; cardCamTarget = nil
            }
            activeCardID = carded
        }
        let target: CGFloat = (carded != nil) ? 1 : 0
        cardProgress += (target - cardProgress) * cardMorphLerp
        if target == 0 && cardProgress < 0.01 {
            cardProgress = 0
            if let prev = activeCardID, let s = nodeSprites[prev] { s.alpha = 1 }
            activeCardID = nil
        }
        // MORPH-INFLATE: fade the tapped orb out as the card face fades IN.
        if let id = activeCardID, let sprite = nodeSprites[id] {
            sprite.alpha = 1 - smoothstepClamp(cardFadeStart, cardFadeEnd, cardProgress)
        }
        // RECENTER on the SAME clock as the morph (pan only — never touch xScale).
        // The annulus (centered on camera.position) follows the glide, so the node
        // amplifies as it reaches center, then the card takes over.
        if let start = cardCamStart, let dest = cardCamTarget, activeCardID != nil {
            let e = cardProgress * cardProgress * (3 - 2 * cardProgress)   // smoothstep
            cameraNode.position = CGPoint(x: start.x + (dest.x - start.x) * e,
                                          y: start.y + (dest.y - start.y) * e)
        }
        syncFocalToCanvasState()
    }

    /// Bridge the presented card (`activeCardID` + `cardProgress`) to the SwiftUI
    /// overlay each frame. Card-driven now (was graze-driven): `currentFocalNodeID`
    /// stays a scene-internal ANNULUS CENTER and no longer reaches CanvasState here.
    private func syncFocalToCanvasState() {
        guard let view = self.view else { return }
        let isActive = canvasState?.cardedNodeID != nil
        let trackedID = activeCardID

        if let trackedID, let sprite = nodeSprites[trackedID] {
            let centerScene = sprite.position
            let centerView = view.convert(centerScene, from: self)
            let radiusScene = (nodeIntrinsicRadii[trackedID] ?? 30) * sprite.xScale
            let edgeView = view.convert(
                CGPoint(x: centerScene.x + radiusScene, y: centerScene.y),
                from: self
            )
            let diameterView = abs(edgeView.x - centerView.x) * 2
            // Write synchronously so the SwiftUI overlay commits in the same
            // CATransaction as the SpriteKit render. Dispatching async here
            // adds a runloop hop, leaving the overlay one frame behind the
            // surrounding sprites and producing visible jitter when the
            // camera is moving (it follows focal during engagement).
            // SpriteKit calls update(_:) on the main thread, so assumeIsolated
            // is sound — the dispatch was only here for @MainActor isolation.
            MainActor.assumeIsolated {
                canvasState?.currentFocalNodeID = isActive ? trackedID : nil
                canvasState?.disengagingFocalNodeID = isActive ? nil : trackedID
                canvasState?.focalNodeScreenPosition = centerView
                canvasState?.focalNodeDiameter = diameterView
                canvasState?.focalNodeFinalDiameter = view.bounds.width * focalScreenFraction
                canvasState?.focalScaleProgress = cardProgress
                canvasState?.focalMorph = morphAmount(cardProgress)
                if let focalNode = currentNodes.first(where: { $0.id == trackedID }) {
                    canvasState?.focalNodeShadeHex = hexString(bubbleColor(for: focalNode))
                }
            }
            lastSyncedFocalID = trackedID
        } else if lastSyncedFocalID != nil {
            MainActor.assumeIsolated {
                canvasState?.currentFocalNodeID = nil
                canvasState?.disengagingFocalNodeID = nil
                canvasState?.focalScaleProgress = 0
                canvasState?.focalMorph = 0
            }
            lastSyncedFocalID = nil
        }
    }

    /// `#RRGGBB` for a UIColor (sRGB). Used to bridge the focal node's rendered
    /// shade to the SwiftUI bubble wash.
    private func hexString(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int((max(0, min(1, r)) * 255).rounded()),
                      Int((max(0, min(1, g)) * 255).rounded()),
                      Int((max(0, min(1, b)) * 255).rounded()))
    }

    /// Fraction of the focal's growth held before it starts morphing to a card.
    private let morphStartProgress: CGFloat = 0.6

    /// MORPH-TO-CARD easing: the focal holds as a bubble until it's mostly grown
    /// (`morphStartProgress`), then eases into the card face over the top of the
    /// grow. Shared clock = `focalScaleProgress`, so it also runs backward on
    /// release (card → bubble → shrink).
    private func morphAmount(_ p: CGFloat) -> CGFloat {
        guard p > morphStartProgress else { return 0 }
        let x = min(1, (p - morphStartProgress) / (1 - morphStartProgress))
        return x * x * (3 - 2 * x)   // smoothstep
    }

    /// The ONE CLOCK for focal presentation: how far `nodeID` has grown between
    /// its resting scale and full focal scale, clamped 0…1. Slaves the overlay
    /// text opacity (and, later, the morph) to the actual sprite scale, so a
    /// fast graze that never fully grows never lets text linger, and release
    /// fades it in lockstep with the shrink.
    private func focalScaleProgress(for nodeID: String, isActive: Bool) -> CGFloat {
        guard let sprite = nodeSprites[nodeID], let view = self.view else {
            return isActive ? 1 : 0
        }
        let intrinsic = max(nodeIntrinsicRadii[nodeID] ?? 30, 0.001)
        let restingScale = nodeRestingScales[nodeID] ?? 1.0
        let fullFocalWorldRadius = (view.bounds.width * focalScreenFraction / 2) * cameraNode.xScale
        let fullFocalScale = fullFocalWorldRadius / intrinsic
        let denom = fullFocalScale - restingScale
        guard denom > 0.0001 else { return isActive ? 1 : 0 }
        return min(1, max(0, (sprite.xScale - restingScale) / denom))
    }

    /// SB139 ws-canvas-visual-model — bridge bag centroids to
    /// `canvasState.clusterCentroidScreenPositions` each frame so the
    /// SwiftUI `clusterLabelOverlay` can render frosted `.ultraThinMaterial`
    /// pills at constant pixel size on top of the SpriteKitView.
    ///
    /// Pipeline each frame:
    /// 1. Refresh `nodeIDToPersistentClusterID` if the substrate service
    ///    generation has advanced (cheap cached lookup otherwise).
    /// 2. Walk member sprites to accumulate per-cluster centroids in
    ///    world coords.
    /// 3. Convert each centroid to view (screen) coords via
    ///    `view.convert(_:from: self)` so SwiftUI can position without
    ///    knowing the SK camera transform.
    /// 4. Write to canvasState; remove entries for pids that dropped out
    ///    of the live fit since the last frame.
    ///
    /// Declutter, declutter-priority (member count), and label text
    /// lookup all happen in the SwiftUI overlay — `clusterLabelOverlay`
    /// in CanvasView. Reading the registry there keeps the live
    /// observable trigger flowing (rename + clear hit the registry and
    /// the SwiftUI side picks it up via @Observable).
    ///
    /// Tradeoffs vs an all-SK render path (the prior attempt):
    /// - SwiftUI overlay sits above SpriteKitView, so labels render
    ///   above strands (SK z=500) too — partial z-order regression vs
    ///   the requested middle-band placement (above dots, below focal +
    ///   strands). Required because `.ultraThinMaterial` is not raw-SK
    ///   reproducible.
    /// - SwiftUI's render pass runs before the embedded SKView's pass
    ///   in the display cycle, so during fast pan/zoom the overlay
    ///   reads a 1-frame-stale centroid — visible as a brief trail.
    ///
    /// Centroid scan is sub-ms even at ~200 sprites.
    private func syncClusterCentroidsToCanvasState() {
        guard let view = self.view else { return }
        // SpriteKit invokes update(_:) on the main thread, so the
        // @MainActor singletons + canvasState are safe under assumeIsolated.
        MainActor.assumeIsolated {
            let service = SubstrateLayoutService.shared
            let currentGeneration = service.generation
            if currentGeneration != lastSeenSubstrateGeneration {
                lastSeenSubstrateGeneration = currentGeneration
                rebuildNodeIDToPersistentClusterIDMap(from: service)
            }

            guard !nodeIDToPersistentClusterID.isEmpty else {
                if !lastWrittenCentroidPids.isEmpty {
                    canvasState?.clusterCentroidScreenPositions = [:]
                    lastWrittenCentroidPids.removeAll()
                }
                return
            }

            // Accumulate sprite positions per persistent cluster UUID.
            var sums: [UUID: CGPoint] = [:]
            var counts: [UUID: Int] = [:]
            for (nodeID, pid) in nodeIDToPersistentClusterID {
                guard let sprite = nodeSprites[nodeID] else { continue }
                let p = sprite.position
                let prior = sums[pid] ?? .zero
                sums[pid] = CGPoint(x: prior.x + p.x, y: prior.y + p.y)
                counts[pid, default: 0] += 1
            }

            var screenPositions: [UUID: CGPoint] = [:]
            screenPositions.reserveCapacity(sums.count)
            var activePids = Set<UUID>()
            activePids.reserveCapacity(sums.count)
            for (pid, sum) in sums {
                let count = CGFloat(counts[pid] ?? 1)
                let worldCentroid = CGPoint(x: sum.x / count, y: sum.y / count)
                let viewCentroid = view.convert(worldCentroid, from: self)
                screenPositions[pid] = viewCentroid
                activePids.insert(pid)
            }

            canvasState?.clusterCentroidScreenPositions = screenPositions
            lastWrittenCentroidPids = activePids
        }
    }

    /// Tag-anchored Map — bridge each territory label's screen-space centroid to
    /// `canvasState.territoryLabels` every frame so the SwiftUI overlay can draw
    /// real `.ultraThinMaterial` glass pills above the SpriteKitView. Centroid is
    /// the mean of the territory members' LIVE sprite positions (so the pill
    /// rides with its nodes through pan/zoom/engagement), projected via
    /// `view.convert(_:from:)`. Empty data clears the overlay once.
    private func syncTerritoryLabelsToCanvasState(currentTime: TimeInterval) {
        guard let view = self.view else { return }
        // Local type (function body, not the closure) so it's capturable below.
        struct RegionCandidate {
            let key: String
            let name: String
            let colorHex: String
            let screen: CGPoint
            let box: CGRect
        }
        MainActor.assumeIsolated {
            guard !territoryLabelData.isEmpty else {
                if !lastTerritoryLabelsEmpty {
                    canvasState?.territoryLabels = []
                    lastTerritoryLabelsEmpty = true
                }
                // C4: an empty set clears the fade + incumbency state too.
                regionLabelDeclutterAlpha.removeAll()
                regionLabelPlacedLastFrame.removeAll()
                return
            }
            lastTerritoryLabelsEmpty = false

            // Region-label zoom fade — macro complement of the per-orb title LOD, at
            // T's device-dialed + accepted literals (ws-map-labels 2026-07-29; baked in
            // RegionLabelTuning, tuner deleted). xScale small = zoomed IN → floored;
            // large = zoomed OUT → full; smoothstep across the (end, start) band. Text
            // lands on a LOW FLOOR (region name stays faintly present); as the pill
            // nears the floor its MATERIAL drops out (below) leaving only faint text.
            // One value per frame (cameraScale is global) → no per-label cost.
            // (The engagement-coupled driver from f525711 was removed at bake — inert at
            // the accepted literals; see the RegionLabelTuning note in CanvasView.)
            let regionScale = cameraNode.xScale
            let regionRaw = smoothstepClamp(RegionLabelTuning.fadeBandEnd,
                                            RegionLabelTuning.fadeBandStart, regionScale)
            let regionFloor = RegionLabelTuning.alphaFloor
            let regionLodAlpha = regionFloor + (1 - regionFloor) * regionRaw
            let regionMatDrop = RegionLabelTuning.materialDropThreshold
            let regionMaterialAlpha = smoothstepClamp(regionMatDrop,
                                                      min(regionMatDrop + 0.2, 1.0), regionRaw)
            // ── PASS 0 — project each label's LIVE centroid to screen and compute its RAW pill box.
            // Stable order = territoryLabelData order (set once via setTerritoryLabels, never rebuilt
            // per frame) → incumbency is meaningful downstream.
            // Labels with no live members are skipped, exactly as before.
            var candidates: [RegionCandidate] = []
            candidates.reserveCapacity(territoryLabelData.count)
            for label in territoryLabelData {
                var sum = CGPoint.zero
                var n: CGFloat = 0
                for id in label.memberIDs {
                    guard let sprite = nodeSprites[id] else { continue }
                    sum.x += sprite.position.x
                    sum.y += sprite.position.y
                    n += 1
                }
                guard n > 0 else { continue }
                let world = CGPoint(x: sum.x / n, y: sum.y / n)
                // The label sits ON its members' live centroid, projected once. (The DEBUG
                // repel-from-orbs + tether solver that used to displace this was REMOVED 2026-09-13:
                // it kept a PERSISTENT screen-space position and eased toward the target by a damped
                // step, so every pan left the label trailing its orbs for several frames — that was
                // the "swim". Its on-orb-collision job is now done by the zoom fade: labels vanish
                // before orbs are big enough to sit under them. See ws-ios-polish.)
                let screen = view.convert(world, from: self)
                candidates.append(RegionCandidate(
                    key: label.key, name: label.name, colorHex: label.colorHex,
                    screen: screen,
                    box: RegionLabelPillMetrics.box(charCount: label.name.count, center: screen)))
            }

            // ── DECLUTTER (moved from SwiftUI; runs AFTER the sep solver, on LIVE boxes) ──
            // C1 edge fade replaces the old hard `intersects(bounds)` cull; C2 is a two-pass
            // hysteresis overlap so a threshold-straddling pair stops fluttering.
            let viewBounds = view.bounds
            let M = regionLabelEdgeMargin
            let expanded = viewBounds.insetBy(dx: -M, dy: -M)
            // The gap widens haloPlace OUTWARD from the fixed keep inset (it used to shrink haloKeep
            // toward 0, which saturated the whole dial at halo=6 — see the note on the property).
            let haloKeep = RegionLabelPillMetrics.halo
            let haloPlace = haloKeep + max(0, regionLabelHysteresisGap)

            var placedBoxes: [CGRect] = []
            placedBoxes.reserveCapacity(candidates.count)
            var placedKeys = Set<String>()
            placedKeys.reserveCapacity(candidates.count)
            // Claim a slot if, padded by the applicable halo, the box clears everything already
            // claimed. Beyond the edge-fade margin it's never a candidate (target alpha 0). The
            // claimed box is stored padded by its OWN halo, so incumbent↔incumbent clearance is
            // 2·haloKeep while a newcomer must clear haloKeep+gap → keeping is cheaper than winning.
            func tryPlace(_ c: RegionCandidate, halo: CGFloat) {
                guard c.box.intersects(expanded) else { return }
                let padded = c.box.insetBy(dx: -halo, dy: -halo)
                if placedBoxes.contains(where: { $0.intersects(padded) }) { return }
                placedBoxes.append(padded)
                placedKeys.insert(c.key)
            }
            // Pass 1: incumbents (placed last frame) first, in stable order, with the smaller haloKeep.
            for c in candidates where regionLabelPlacedLastFrame.contains(c.key) {
                tryPlace(c, halo: haloKeep)
            }
            // Pass 2: everyone else, in stable order, with the larger haloPlace, against pass-1's claims.
            for c in candidates where !regionLabelPlacedLastFrame.contains(c.key) {
                tryPlace(c, halo: haloPlace)
            }

            // ── C3 EASE + C1 edge alpha + C5 emit. dt = the scene's frame delta: lastUpdateTime is
            // written at the END of update(), so here it still holds the previous frame's time.
            // Clamped so a stale first frame can't produce a giant step.
            let dt = min(max(currentTime - lastUpdateTime, 0), 0.1)
            let fadeStep = CGFloat(dt / max(regionLabelFadeDuration, 0.001))   // full 0→1 fade in `duration` s
            var out: [CanvasState.TerritoryLabelInfo] = []
            out.reserveCapacity(candidates.count)
            for c in candidates {
                let placed = placedKeys.contains(c.key)
                let d = rectGap(from: c.box, to: viewBounds)      // 0 on screen, → M as the box leaves
                let edgeAlpha = 1 - smoothstepClamp(0, M, d)
                let target: CGFloat = placed ? edgeAlpha : 0
                var a = regionLabelDeclutterAlpha[c.key] ?? 0     // new key → fade IN from 0, never pop
                if target > a { a = min(target, a + fadeStep) }
                else if target < a { a = max(target, a - fadeStep) }
                regionLabelDeclutterAlpha[c.key] = a
                // C5: omit from the bridged array only ONCE the ease actually reached ~0 — never as a
                // shortcut for target==0, or a fading-out label would vanish instead of being seen out.
                guard a > 0.001 else { continue }
                out.append(CanvasState.TerritoryLabelInfo(
                    key: c.key,
                    name: c.name,
                    colorHex: c.colorHex,
                    screenPosition: c.screen,
                    lodAlpha: regionLodAlpha,
                    materialAlpha: regionMaterialAlpha,
                    declutterAlpha: a
                ))
            }
            // C4: prune keys no longer in territoryLabelData (setTerritoryLabels also clears on
            // rebuild; this keeps the dict size == live label count — the verify step checks it).
            let liveKeys = Set(territoryLabelData.map { $0.key })
            regionLabelDeclutterAlpha = regionLabelDeclutterAlpha.filter { liveKeys.contains($0.key) }
            regionLabelPlacedLastFrame = placedKeys
            canvasState?.territoryLabels = out
        }
    }

    /// Rebuilds the nodeID → persistent-cluster-UUID lookup from the
    /// substrate service's current fitted model + persistent ID array.
    /// Empties the lookup when no model is loaded, when clustering hasn't
    /// run, or when the two arrays are unaligned (defensive — the service
    /// guarantees alignment but we're index-matching so a mismatch should
    /// degrade to "no labels" rather than crash).
    ///
    /// Caller responsibility: invoke only from a MainActor-isolated
    /// context — `service`'s fittedModel / persistentClusterIDs reads
    /// require it.
    private func rebuildNodeIDToPersistentClusterIDMap(from service: SubstrateLayoutService) {
        guard let model = service.fittedModel,
              let pids = service.persistentClusterIDs,
              model.trainingPoints.count == pids.count else {
            nodeIDToPersistentClusterID = [:]
            return
        }
        var out: [String: UUID] = [:]
        out.reserveCapacity(pids.count)
        for (i, point) in model.trainingPoints.enumerated() {
            if let pid = pids[i] {
                out[point.nodeID] = pid
            }
        }
        nodeIDToPersistentClusterID = out
    }



    // MARK: - Strand ring targets  ·  ⚠️ DORMANT (retired 2026-07-06)
    //
    // Strands are RETIRED from engagement. `recomputeStrandTargets` is neutered
    // to always clear `strandTargets` (and undo any dim / z-lift), so every
    // downstream `strandTargets`-guarded path (Phase 1 ring override, Phase 1.1
    // scale override, Phase 1.5 inclusion, dimming) is inert. The successor is
    // TETHERS-ON-TAP. The mechanism below (ringSlots, dimming, z-lift, radius)
    // is preserved DORMANT for reference / possible revival — reversible by
    // restoring `recomputeStrandTargets`'s original body (see git history).

    /// Default ring-radius multiplier applied to focal's steady-state world
    /// radius. Tunable from inspect view via `strand.ringRadiusMultiplier`.
    private static let defaultStrandRingRadiusMultiplier: CGFloat = 1.6

    private var strandRingRadiusMultiplier: CGFloat {
        let v = UserDefaults.standard.double(forKey: StrandService.ringRadiusMultiplierKey)
        return v > 0 ? CGFloat(v) : Self.defaultStrandRingRadiusMultiplier
    }

    /// World-space ring radius around `focalID`. Targets the focal's
    /// **steady-state** rendered radius (post-sigmoid) × multiplier — using
    /// the live sprite frame would chase a moving target during the
    /// engaging→engaged lerp and produce a ring that drifts outward as the
    /// focal scales up. Mirrors the sigmoid target math used by the engaged
    /// target loop so geometry stays consistent.
    private func strandRingRadius(focalID: String, screenWidth: CGFloat) -> CGFloat {
        let cameraScale = cameraNode.xScale
        let steadyStateFocalWorldRadius = focalScreenFraction * screenWidth * cameraScale / 2
        return steadyStateFocalWorldRadius * strandRingRadiusMultiplier
    }

    /// Compute strand-ring target positions for the given focal and store
    /// them in `strandTargets`. Flag-off or no-qualifying-neighbors clears
    /// the dict (a sparse or empty ring is valid output). Called from the
    /// engaged-state branch when focal changes — single source of trigger.
    private func recomputeStrandTargets(focalID: String, screenWidth: CGFloat) {
        // DORMANT — strands retired (see section banner). No ring is ever built:
        // clear targets and undo any lingering dim / z-lift so engagement runs
        // with the crowd solid and undimmed. Successor: tethers-on-tap.
        strandTargets.removeAll()
        clearStrandDimming()
        restoreStrandZPositions()
    }

    /// Saves the current zPosition of each strand neighbor, then lifts them to
    /// `strandZPosition` so they render above any dimmed corpus sibling that
    /// happens to land near the ring. Focal still sits above strands.
    /// Idempotent — re-running after a focal switch restores the previous
    /// strands first and then lifts the new set.
    private func liftStrandZPositions() {
        // Restore zPositions for sprites that are no longer strands.
        let currentStrandIDs = Set(strandTargets.keys)
        for (id, z) in savedStrandZPositions where !currentStrandIDs.contains(id) {
            if let sprite = nodeSprites[id] { sprite.zPosition = z }
            savedStrandZPositions.removeValue(forKey: id)
        }
        // Lift current strands (only if not already lifted).
        for id in currentStrandIDs {
            guard let sprite = nodeSprites[id] else { continue }
            if savedStrandZPositions[id] == nil {
                savedStrandZPositions[id] = sprite.zPosition
            }
            sprite.zPosition = Self.strandZPosition
        }
    }

    /// Restores every lifted strand sprite to its pre-engagement zPosition.
    private func restoreStrandZPositions() {
        for (id, z) in savedStrandZPositions {
            if let sprite = nodeSprites[id] { sprite.zPosition = z }
        }
        savedStrandZPositions.removeAll()
    }

    /// Fades every non-focal, non-strand sprite to `StrandService.dimAlpha` via
    /// SKAction so the ring stands out. Double-guarded against the focal: both
    /// the engagement-state focal (`focalID` arg) and `focalShaderID` are
    /// excluded, in case they momentarily disagree mid-transition. No-op when
    /// `strandTargets` is empty (sparse-ring or flag-off).
    private func applyStrandDimming(focalID: String) {
        guard !strandTargets.isEmpty else {
            clearStrandDimming()
            restoreStrandZPositions()
            return
        }
        let dimAlpha = StrandService.dimAlpha
        let duration = Self.strandDimDuration
        let key = Self.strandDimActionKey

        var newDimmed: Set<String> = []
        for (nodeID, sprite) in nodeSprites {
            if nodeID == focalID { continue }
            if nodeID == focalShaderID { continue }
            if strandTargets[nodeID] != nil { continue }
            newDimmed.insert(nodeID)
            sprite.removeAction(forKey: key)
            sprite.run(SKAction.fadeAlpha(to: dimAlpha, duration: duration), withKey: key)
        }

        // Restore any sprite that was previously dimmed but is no longer in the
        // dim set (e.g., became a strand neighbor after a focal switch).
        for staleID in dimmedSpriteIDs.subtracting(newDimmed) {
            guard let sprite = nodeSprites[staleID] else { continue }
            sprite.removeAction(forKey: key)
            sprite.run(SKAction.fadeAlpha(to: 1.0, duration: duration), withKey: key)
        }

        dimmedSpriteIDs = newDimmed
    }

    /// Fades every dimmed sprite back to full opacity. Called at engagement
    /// teardown (disengage / touch-cancelled).
    private func clearStrandDimming() {
        guard !dimmedSpriteIDs.isEmpty else { return }
        let duration = Self.strandDimDuration
        let key = Self.strandDimActionKey
        for nodeID in dimmedSpriteIDs {
            guard let sprite = nodeSprites[nodeID] else { continue }
            sprite.removeAction(forKey: key)
            sprite.run(SKAction.fadeAlpha(to: 1.0, duration: duration), withKey: key)
        }
        dimmedSpriteIDs.removeAll()
    }

    // MARK: - Debug controls (called from external UI)

    func setShaderRotationSpeed(_ speed: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_rotation_speed" })?.floatValue = speed
    }

    func setShaderColorIntensity(_ intensity: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_color_intensity" })?.floatValue = intensity
    }

    func setShaderCenterOffset(_ offset: CGPoint) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_center_offset" })?.vectorFloat2Value = vector_float2(Float(offset.x), Float(offset.y))
    }

    // MARK: - Inner glow debug controls

    func setGlowReach(_ reach: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_glow_reach" })?.floatValue = reach
    }

    func setGlowIntensity(_ intensity: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_glow_intensity" })?.floatValue = intensity
    }

    func setGlowFalloff(_ falloff: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_glow_falloff" })?.floatValue = falloff
    }

    func setGlowTint(_ tint: vector_float3) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_glow_tint" })?.vectorFloat3Value = tint
    }

    // MARK: - Chromatic aberration debug controls

    func setChromaticAberrationScale(_ scale: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_aberration_scale" })?.floatValue = scale
    }

    func setChromaticAberrationVelocityMult(_ mult: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_aberration_velocity_mult" })?.floatValue = mult
    }

    func setChromaticAberrationDecay(_ decay: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_aberration_decay" })?.floatValue = decay
    }

    func setChromaticAberrationMax(_ max: Float) {
        nodeFillShader.uniforms.first(where: { $0.name == "u_aberration_max" })?.floatValue = max
    }

    // MARK: - Honeycomb helpers


    // MARK: - Node sprites

    private func addNodeSprite(_ node: Node, isNew: Bool, spawnPoint: CGPoint? = nil, stagger: TimeInterval = 0) {
        // Use computed radius from LayoutService, fallback to old formula if not available
        let radius = nodeRadii[node.id] ?? bubbleRadius(for: node)
        nodeIntrinsicRadii[node.id] = radius
        let shape = makeShape(
            radius: radius,
            fillColor: bubbleColor(for: node),
            isMeta: node.isMeta,
            nodeID: node.id
        )
        shape.name = "node:\(node.id)"

        // Cache neighborhoodID and radius
        shape.userData = NSMutableDictionary()
        shape.userData?["neighborhoodID"] = neighborhoodCache?.neighborhoodID(forNodeID: node.id)
        shape.userData?["radius"] = radius

        let displayText = node.title.isEmpty ? (node.items.first?.content ?? "") : node.title
        let labelSprite = makeTitleSprite(text: displayText, radius: radius, fillColor: bubbleColor(for: node))
        shape.addChild(labelSprite)

        if node.isMeta {
            let spark = SKLabelNode(text: "✦")
            spark.fontSize = 10
            spark.fontColor = UIColor.white.withAlphaComponent(0.6)
            spark.verticalAlignmentMode = .center
            spark.horizontalAlignmentMode = .center
            spark.position = .zero
            spark.zPosition = 3
            shape.addChild(spark)
        }

        shape.physicsBody = Self.configuredOrbBody(radius: radius)

        // Position: stored layout or random near center
        let finalPosition = storedPosition(for: node.id)

        if let spawn = spawnPoint {
            // Drill-down expansion: spawn at Über-node position, animate to radial layout
            shape.position = spawn
            addChild(shape)
            nodeSprites[node.id] = shape

            let move = SKAction.move(to: finalPosition, duration: 0.35)
            move.timingMode = .easeOut
            let wait = SKAction.wait(forDuration: stagger)
            shape.run(.sequence([wait, move]))
        } else if isNew {
            // Drop-in from above, then ripple + haptic
            shape.position = CGPoint(x: finalPosition.x, y: finalPosition.y + 60)
            addChild(shape)
            nodeSprites[node.id] = shape

            let drop = SKAction.move(to: finalPosition, duration: 0.45)
            drop.timingMode = .easeOut
            shape.run(drop)

            playRipple(at: finalPosition, radius: radius)
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }

            // Gentle random drift impulse
            let dx = CGFloat.random(in: -20...20)
            let dy = CGFloat.random(in: -20...20)
            shape.physicsBody?.applyImpulse(CGVector(dx: dx, dy: dy))
        } else {
            shape.position = finalPosition
            addChild(shape)
            nodeSprites[node.id] = shape
        }

        // Add newcomer halo for new nodes
        if isNew && enableNewcomerHalo {
            addNewcomerHalo(to: shape, radius: radius)
        }
    }

    private func updateNodeSprite(_ node: Node) {
        guard let shape = nodeSprites[node.id] else { return }
        // Re-color the sprite orb's fill attribute (opaque re-color — no light
        // dilution here, matching the prior behavior).
        let fill = bubbleColor(for: node).withAlphaComponent(node.isMeta ? 0.55 : 1.0)
        if let s = shape as? SKSpriteNode {
            s.setValue(SKAttributeValue(vectorFloat4: Self.rgbaVec(fill)), forAttribute: "a_node_color")
        }

        // Update cached neighborhoodID
        if shape.userData == nil {
            shape.userData = NSMutableDictionary()
        }
        shape.userData?["neighborhoodID"] = neighborhoodCache?.neighborhoodID(forNodeID: node.id)

        // Title label update — rebuild the glyph container if the title changed, so the
        // edited title re-wraps in glyph-space.
        if let titleNode = shape.children.first(where: { $0.name == "titleLabel" }),
           let oldTitle = titleNode.userData?["fullTitle"] as? String {
            let displayText = node.title.isEmpty ? (node.items.first?.content ?? "") : node.title
            if oldTitle != displayText {
                titleNode.removeFromParent()
                let radius = nodeIntrinsicRadii[node.id] ?? bubbleRadius(for: node)
                shape.addChild(makeTitleSprite(text: displayText, radius: radius,
                                               fillColor: bubbleColor(for: node)))
            }
        }
    }

    /// Animate sprite to target position and radius if they have changed.
    private func animateSpriteIfNeeded(nodeID: String) {
        guard let sprite = nodeSprites[nodeID] else { return }
        let targetPosition = storedPosition(for: nodeID)

        // Check if position has changed (within tolerance)
        let dx = sprite.position.x - targetPosition.x
        let dy = sprite.position.y - targetPosition.y
        let distance = sqrt(dx * dx + dy * dy)
        let positionChanged = distance > 5  // 5pt tolerance

        // Check if radius has changed
        var radiusChanged = false
        var newRadius: CGFloat = 30  // default
        if let radius = nodeRadii[nodeID] {
            newRadius = radius
            if let oldRadius = sprite.userData?["radius"] as? CGFloat {
                radiusChanged = abs(radius - oldRadius) > 0.5
            } else {
                radiusChanged = true  // First time setting radius
            }
        }

        guard positionChanged || radiusChanged else { return }

        // Animate position if changed
        if positionChanged {
            let move = SKAction.move(to: targetPosition, duration: 1.5)
            move.timingMode = .easeOut
            sprite.run(move, withKey: "algorithmicLayout")
        }

        // Animate radius if changed
        if radiusChanged {
            let oldRadius = (sprite.userData?["radius"] as? CGFloat) ?? 30.0
            let scaleRatio = newRadius / oldRadius

            let scaleAction = SKAction.scale(to: scaleRatio, duration: 1.5)
            scaleAction.timingMode = .easeOut
            sprite.run(scaleAction, withKey: "scaleAnimation")

            // Update physics body to match new radius
            sprite.physicsBody = SKPhysicsBody(circleOfRadius: newRadius)
            sprite.physicsBody?.linearDamping = 0.6
            sprite.physicsBody?.angularDamping = 0.8
            sprite.physicsBody?.friction = 0.1
            sprite.physicsBody?.restitution = 0.25
            sprite.physicsBody?.mass = CGFloat(max(0.5, Float(newRadius / 30)))
            sprite.physicsBody?.allowsRotation = false
            sprite.physicsBody?.isDynamic = false

            // Cache new radius
            if sprite.userData == nil {
                sprite.userData = NSMutableDictionary()
            }
            sprite.userData?["radius"] = newRadius
        }
    }

    /// Add newcomer halo to a sprite.
    private func addNewcomerHalo(to sprite: SKNode, radius: CGFloat) {
        let haloRadius = radius + 12
        let halo = SKShapeNode(circleOfRadius: haloRadius)
        halo.strokeColor = UIColor.white.withAlphaComponent(0.5)
        halo.fillColor = .clear
        halo.lineWidth = 2
        halo.zPosition = -0.5
        halo.name = "newcomerHalo"

        // Store creation timestamp
        if sprite.userData == nil {
            sprite.userData = NSMutableDictionary()
        }
        sprite.userData?["haloCreatedAt"] = CACurrentMediaTime()

        sprite.addChild(halo)
        print("[Halo] Newcomer halo spawned for node \(sprite.name ?? "unknown")")
    }

    /// Update newcomer halo opacity based on elapsed time.
    private func updateNewcomerHalos(currentTime: TimeInterval) {
        for (_, sprite) in nodeSprites {
            guard let halo = sprite.children.first(where: { $0.name == "newcomerHalo" }) as? SKShapeNode,
                  let createdAt = sprite.userData?["haloCreatedAt"] as? TimeInterval else {
                continue
            }

            let elapsed = currentTime - createdAt
            let progress = min(elapsed / haloFadeDuration, 1.0)

            if progress >= 1.0 {
                // Halo expired — remove it
                halo.removeFromParent()
                sprite.userData?["haloCreatedAt"] = nil
                print("[Halo] Newcomer halo expired for node \(sprite.name ?? "unknown")")
            } else {
                // Decay opacity from 0.5 to 0.0
                let opacity = 0.5 * (1.0 - progress)
                halo.strokeColor = UIColor.white.withAlphaComponent(opacity)
            }
        }
    }

    // MARK: - Über-node sprites

    /// Drill into an Über-node: remove it and spread child nodes outward.
    private func drillIntoUberNode(clusterID: String) {
        guard let uberShape = uberNodeSprites[clusterID],
              let name = uberShape.name,
              name.hasPrefix("uber:") else { return }

        // Find the cluster to get child node IDs
        // We need access to the cluster data - store it in userData
        guard let childNodeIDs = uberShape.userData?["childNodeIDs"] as? [String] else { return }

        let uberPosition = uberShape.position

        // Remove Über-node sprite with fade-out animation
        let fadeOut = SKAction.fadeAlpha(to: 0, duration: 0.25)
        let remove = SKAction.removeFromParent()
        uberShape.run(.sequence([fadeOut, remove]))
        uberNodeSprites.removeValue(forKey: clusterID)

        // Spread child nodes outward from Über-node position
        for childID in childNodeIDs {
            guard let childShape = nodeSprites[childID] else { continue }

            // Calculate direction from Über-node to child
            let dx = childShape.position.x - uberPosition.x
            let dy = childShape.position.y - uberPosition.y
            let distance = hypot(dx, dy)

            // Normalize and apply outward impulse
            if distance > 0 {
                let impulseStrength: CGFloat = 80
                let impulseDx = (dx / distance) * impulseStrength
                let impulseDy = (dy / distance) * impulseStrength
                childShape.physicsBody?.applyImpulse(CGVector(dx: impulseDx, dy: impulseDy))
            } else {
                // If child is exactly at Über-node position, push in random direction
                let randomAngle = CGFloat.random(in: 0...(2 * .pi))
                let impulseStrength: CGFloat = 80
                childShape.physicsBody?.applyImpulse(CGVector(
                    dx: cos(randomAngle) * impulseStrength,
                    dy: sin(randomAngle) * impulseStrength
                ))
            }
        }

        // Play expansion ripple at Über-node position
        playRipple(at: uberPosition, radius: uberShape.frame.width / 2)

        // Haptic feedback
        DispatchQueue.main.async {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func addUberNodeSprite(_ cluster: UberNodeCluster, childNodes: [Node]) {
        let childCount = cluster.childNodeIDs.count
        let radius = uberNodeRadius(for: childCount)
        let colors = sampleChildColors(cluster: cluster, childNodes: childNodes)

        let shape = makeUberNodeShape(
            radius: radius,
            colors: colors,
            clusterID: cluster.id
        )
        shape.name = "uber:\(cluster.id)"
        shape.userData = ["childNodeIDs": cluster.childNodeIDs]

        // Title label (cluster title, e.g., "Work (12)")
        let titleLabel = SKLabelNode()
        titleLabel.attributedText = NSAttributedString(
            string: cluster.title,
            attributes: [
                .font: CorpusPhysicsScene.serifFont(size: 11, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
        )
        titleLabel.verticalAlignmentMode = .center
        titleLabel.horizontalAlignmentMode = .center
        titleLabel.position = .zero
        titleLabel.zPosition = 2
        titleLabel.name = "titleLabel"
        titleLabel.userData = ["fullTitle": cluster.title]
        shape.addChild(titleLabel)

        // Physics body (heavier than regular nodes)
        let body = SKPhysicsBody(circleOfRadius: radius)
        body.linearDamping = 0.7  // Slightly higher damping (slower drift)
        body.angularDamping = 0.8
        body.friction = 0.1
        body.restitution = 0.25
        body.mass = CGFloat(max(1.0, Float(radius / 20)))  // Heavier
        body.allowsRotation = false
        body.isDynamic = false  // Resting state: no continuous physics
        shape.physicsBody = body

        // Position: random near center (no stored layout for Über-nodes yet)
        let finalPosition = CGPoint(
            x: CGFloat.random(in: -80...80),
            y: CGFloat.random(in: -80...80)
        )
        shape.position = finalPosition

        // Disable cluster bubble rendering (keep data structure for honeycomb)
        // addChild(shape)
        uberNodeSprites[cluster.id] = shape

        // Slower breathing animation (disabled since sprite not added to scene)
    }

    private func updateUberNodeSprite(_ cluster: UberNodeCluster, childNodes: [Node]) {
        guard let shape = uberNodeSprites[cluster.id] else { return }
        // Update title if cluster membership changed
        if let label = shape.children.first(where: { $0.name == "titleLabel" }) as? SKLabelNode {
            label.text = cluster.title
            label.userData = ["fullTitle": cluster.title]
        }
    }

    /// Calculate Über-node radius based on child count.
    /// Base radius 40pt, +2pt per child, max 80pt.
    private func uberNodeRadius(for childCount: Int) -> CGFloat {
        let extra = CGFloat(max(0, childCount - 2)) * 2.0
        return min(40.0 + extra, 80.0)
    }

    /// Sample top 3 dominant colors from child nodes' primary tags.
    private func sampleChildColors(cluster: UberNodeCluster, childNodes: [Node]) -> [UIColor] {
        let children = childNodes.filter { cluster.childNodeIDs.contains($0.id) }
        var colorCounts: [UIColor: Int] = [:]

        for child in children {
            if let tag = child.tags.first, let color = tagColors[tag] {
                colorCounts[color, default: 0] += 1
            }
        }

        // Sort by frequency, take top 3
        let topColors = colorCounts.sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }

        // Fallback to neutral if no colors found
        if topColors.isEmpty {
            return [UIColor(red: 0.556, green: 0.556, blue: 0.576, alpha: 1.0)]
        }

        return Array(topColors)
    }

    // MARK: - Landing ripple

    private func playRipple(at position: CGPoint, radius: CGFloat) {
        let ripple = SKShapeNode(circleOfRadius: 1)
        ripple.position = position
        ripple.strokeColor = UIColor.white.withAlphaComponent(0.45)
        ripple.fillColor = .clear
        ripple.lineWidth = 2
        ripple.zPosition = -1
        addChild(ripple)

        let expand = SKAction.customAction(withDuration: 0.55) { node, elapsed in
            guard let shape = node as? SKShapeNode else { return }
            let progress = min(elapsed / 0.55, 1.0)
            let r = (radius + 50) * progress
            shape.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
            shape.alpha = 1 - progress
        }
        ripple.run(.sequence([expand, .removeFromParent()]))
    }

    // MARK: - Neighborhood cohesion physics

    private func applyNeighborhoodForces(deltaTime: TimeInterval) {
        let dt = CGFloat(deltaTime)

        // Force parameters (tunable)
        let centrAttractionStrength: CGFloat = 0.02
        let maxCentroidImpulse: CGFloat = 5.0
        let repulsionStrength: CGFloat = 50.0
        let repulsionThreshold: CGFloat = 200.0
        let maxRepulsionImpulse: CGFloat = 3.0

        // Group nodes by neighborhoodID to calculate centroids
        var neighborhoodGroups: [String: [SKNode]] = [:]
        for (_, sprite) in nodeSprites {
            guard let _neighborhoodID = sprite.userData?["neighborhoodID"] as? String else { continue }
            neighborhoodGroups[_neighborhoodID, default: []].append(sprite)
        }

        // Pass 1: Centroid attraction
        for (_, group) in neighborhoodGroups where group.count > 1 {
            for sprite in group {
                guard let body = sprite.physicsBody, body.isDynamic else { continue }

                // Calculate centroid of other nodes in this group
                var centroidX: CGFloat = 0
                var centroidY: CGFloat = 0
                var count = 0

                for other in group where other !== sprite {
                    centroidX += other.position.x
                    centroidY += other.position.y
                    count += 1
                }

                guard count > 0 else { continue }
                centroidX /= CGFloat(count)
                centroidY /= CGFloat(count)

                // Vector toward centroid
                let dx = centroidX - sprite.position.x
                let dy = centroidY - sprite.position.y
                let distance = sqrt(dx * dx + dy * dy)

                if distance > 0 {
                    // Impulse proportional to distance, clamped
                    let rawMagnitude = distance * centrAttractionStrength
                    let magnitude = min(rawMagnitude, maxCentroidImpulse)
                    let impulse = CGVector(
                        dx: (dx / distance) * magnitude * dt,
                        dy: (dy / distance) * magnitude * dt
                    )
                    body.applyImpulse(impulse)
                }
            }
        }

        // Pass 2: Inter-neighborhood repulsion
        let sprites = Array(nodeSprites.values)
        for i in 0..<sprites.count {
            let sprite1 = sprites[i]
            guard let body1 = sprite1.physicsBody, body1.isDynamic else { continue }
            guard let _neighborhoodID1 = sprite1.userData?["neighborhoodID"] as? String else { continue }

            for j in (i+1)..<sprites.count {
                let sprite2 = sprites[j]
                guard let body2 = sprite2.physicsBody, body2.isDynamic else { continue }
                guard let _neighborhoodID2 = sprite2.userData?["neighborhoodID"] as? String else { continue }

                // Only repel if different neighborhoods
                guard _neighborhoodID1 != _neighborhoodID2 else { continue }

                let dx = sprite2.position.x - sprite1.position.x
                let dy = sprite2.position.y - sprite1.position.y
                let distance = sqrt(dx * dx + dy * dy)

                // Only repel if within threshold
                guard distance > 0 && distance < repulsionThreshold else { continue }

                // Inverse square law, clamped
                let rawMagnitude = repulsionStrength / (distance * distance)
                let magnitude = min(rawMagnitude, maxRepulsionImpulse)

                let impulse1 = CGVector(
                    dx: -(dx / distance) * magnitude * dt,
                    dy: -(dy / distance) * magnitude * dt
                )
                let impulse2 = CGVector(
                    dx: (dx / distance) * magnitude * dt,
                    dy: (dy / distance) * magnitude * dt
                )

                body1.applyImpulse(impulse1)
                body2.applyImpulse(impulse2)
            }
        }
    }

    private func checkConvergence() {
        // Calculate mean velocity magnitude
        var totalVelocity: CGFloat = 0
        var count = 0

        for (_, sprite) in nodeSprites {
            guard let body = sprite.physicsBody, body.isDynamic else { continue }
            let vel = body.velocity
            let magnitude = sqrt(vel.dx * vel.dx + vel.dy * vel.dy)
            totalVelocity += magnitude
            count += 1
        }

        guard count > 0 else { return }
        let meanVelocity = totalVelocity / CGFloat(count)

        // Track history
        velocityHistory.append(meanVelocity)
        if velocityHistory.count > convergenceFrames {
            velocityHistory.removeFirst()
        }

        // Check if converged (all recent frames below threshold)
        if velocityHistory.count == convergenceFrames {
            let allBelowThreshold = velocityHistory.allSatisfy { $0 < convergenceThreshold }
            if allBelowThreshold && !physicsIsSleeping {
                sleepPhysics()
            }
        }
    }

    private func sleepPhysics() {
        physicsIsSleeping = true
        let elapsedTime = velocityHistory.count > 0 ? Double(velocityHistory.count) / 60.0 : 0
        print("[Neighborhood] Converged in \(String(format: "%.1f", elapsedTime))s, sleeping")

        // Set all non-interacting nodes to static
        for (_, sprite) in nodeSprites {
            guard let body = sprite.physicsBody else { continue }
            // Skip if node is currently being manipulated (zoomedNode, etc.)
            if sprite.name == "node:\(zoomedNodeID ?? "")" {
                continue
            }
            body.isDynamic = false
        }
    }

    private func wakePhysics(reason: String) {
        guard physicsIsSleeping else { return }
        physicsIsSleeping = false
        velocityHistory.removeAll()
        print("[Neighborhood] Woken by \(reason)")

        // Set all nodes back to dynamic
        for (_, sprite) in nodeSprites {
            sprite.physicsBody?.isDynamic = true
        }
    }

    // MARK: - Unfocused-orb appearance (Solar Flare dark / Cucumber Water light)

    // (`lightInk` — the light-mode orb STROKE ink — was deleted at the 2026-09-14 bake: T dialled
    // `stroke=0.000` in light, so light-mode orbs carry no stroke at all.)

    /// Authoritative light/dark — PUSHED from SwiftUI's `@Environment(\.colorScheme)`
    /// by CanvasView (the same signal that drives AppearancePalette; never nil).
    /// Was read as `view?.traitCollection.userInterfaceStyle == .light`, but `view?`
    /// resolves nil during a re-formation re-render (Analyze / idle) → false → orbs
    /// took the DARK branch and lost transmission. A pushed bool can't be nil.
    /// Restyles on an actual flip so live theme changes still take.
    var appearanceIsLight: Bool = true {
        didSet {
            if oldValue != appearanceIsLight {
                restyleUnfocusedOrbs()
                restyleLabels()   // dark label ink depends on the sat/val boost → re-flip on theme change
            }
        }
    }
    private var currentIsLight: Bool { appearanceIsLight }

    // Baked Cucumber Water (light) unfocused-orb wash — Tom's device-locked
    // values (the DEBUG tuner is retired). Single source in both configs; dark
    // reads none of these, so Solar Flare stays byte-identical.
    // (`cwPigment` 0.60 and `cwStrokeInk` 0.35 were deleted at the 2026-09-14 bake — T's
    // `fill=1.000` makes the light fill SOLID and `stroke=0.000` removes the light stroke.)
    private static let cwWashStrength: CGFloat = 0.10     // diagonal hue-wash peak (light, screen)
    private static let cwWashDark: CGFloat = 0.38         // diagonal black-wash peak (dark, darken)

    /// A deeper, slightly richer shade of the node's OWN hue — the pigment the
    /// light wash pools into (instead of black): same hue, lower brightness,
    /// nudged saturation.
    private func washHueShade(_ base: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard base.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return base }
        return UIColor(hue: h,
                       saturation: min(1.0, s * 1.15),
                       brightness: max(0.0, b * 0.55),
                       alpha: 1.0)
    }

    /// Apply the unfocused-orb treatment to `shape` for `baseFill`. Fill / stroke /
    /// wash all ride per-node attributes on the shared shader (the wash is a shader
    /// term now, not a child sprite).
    /// - DARK (Solar Flare): opaque fill (meta `0.55`) + black diagonal darken
    ///   (peak 0.38) + white@0.12 stroke — byte-identical to the shipped look.
    /// - LIGHT (Cucumber Water): SOLID fill (T's `fill=1.000`, 2026-09-14 — the old
    ///   `cwPigment` dilution let the dot grid show through); the wash screen-deepens
    ///   the node's OWN hue (`washHueShade`, peak `cwWashStrength`); NO stroke
    ///   (`stroke=0.000`). Never touches `shape.alpha`, so focal/dimmed state
    ///   (set by `setFocalShader`) is preserved.
    private func styleUnfocusedOrb(_ node: SKNode,
                                   baseFill: UIColor,
                                   isMeta: Bool,
                                   isLight: Bool) {
        // Fill/stroke → per-node attributes on the shared-shader sprite orb.
        // ★ T device-final 2026-09-14 (Ops/reference/tuner-state-accepted.md): `orb: fill=1.000`
        // BOTH appearances, `stroke=1.000` dark / `0.000` light.
        //   • fill 1.000 is SET, not multiplied — a SOLID fill even in light. It retires the
        //     `cwPigment` (0.60) dilution, which let the dot grid show through the orb.
        //   • stroke 0.000 in light removes EVERY light-mode stroke (the near-invisible ink rim and
        //     the meta purple rim alike — the dial multiplied whatever stroke was computed).
        let metaAlpha: CGFloat = isMeta ? 0.55 : 1.0
        let fillAlpha = metaAlpha
        var stroke: UIColor = isMeta
            ? UIColor(red: 0.7, green: 0.5, blue: 1.0, alpha: 0.7)  // soft purple (dark only now)
            : UIColor.white.withAlphaComponent(0.12)
        if isLight { stroke = stroke.withAlphaComponent(0) }
        let fill = baseFill.withAlphaComponent(fillAlpha)
        let lineWidth: CGFloat = isMeta ? 1.5 : 1.0

        // Diagonal wash, now a shader term (was a circular child sprite): light
        // deepens the node's OWN hue (screen, peak 0.10); dark darkens toward black
        // (peak 0.38). Shipped values preserved; u_wash_is_light (set per-frame in
        // `update`) selects the composite. Shared with the fill's rounded-box SDF, so
        // it morphs as one shape — no circle-in-square.
        let washColor: UIColor = isLight ? washHueShade(baseFill) : .black
        let washStrength: CGFloat = isLight ? Self.cwWashStrength : Self.cwWashDark

        if let sprite = node as? SKSpriteNode {
            setOrbSpriteAttributes(sprite, fill: fill, stroke: stroke,
                                   lineWidth: lineWidth, radius: sprite.size.width / 2,
                                   wash: washColor, washStrength: washStrength)
        }
    }

    /// Re-apply the unfocused-orb treatment to every on-screen orb — called on
    /// appearance flip (from `update`, when the trait changes). Resolves the trait
    /// ONCE, then loops. Focal nodes are safe to include — `styleUnfocusedOrb`
    /// leaves `shape.alpha` (0 while focal) untouched, so they stay hidden and pick
    /// up the current theme on disengagement.
    func restyleUnfocusedOrbs() {
        let isLight = currentIsLight
        let byID = Dictionary(currentNodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, shape) in nodeSprites {
            guard let node = byID[id] else { continue }
            styleUnfocusedOrb(shape, baseFill: bubbleColor(for: node), isMeta: node.isMeta,
                              isLight: isLight)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // GRID WARP — SHIPS (baked 2026-09-14). Everything below is Release code: the orbs pinch the dot
    // grid like balls on a taut fabric, eased in per orb with its title. The tuner that dialled it is
    // gone; these are T's device-final values.
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// Grid-warp values — **T device-final 2026-09-14, see Ops/reference/tuner-state-accepted.md**.
    /// Reach is in ORB RADII and depth is a FRACTION OF AN ORB RADIUS (both converted to px per frame
    /// from each orb's actual on-screen size), so the look holds at every zoom by construction.
    /// Per-appearance where T dialled them apart; `reach`/`depth`/`massLaw` converged on one value.
    enum GridWarpTuning {
        static let reachOrbRadii: Double = 6.000     // both appearances (top of the dialled range; T called it final)
        static let depthOrbRadii: Double = 0.600     // both appearances
        static let massLaw: Double = 2.177           // both appearances (exponent: displacement ∝ r^law)
        static let sign: Double = 1                  // +1 = converge (mass dimple)
        /// Mass influence — how strongly an orb's own size drives its dent. 0 = every orb equal.
        static func massInfluence(isLight: Bool) -> Double { isLight ? 0.647 : 0.636 }
        /// Mode-C dot shrink near mass (a depression recedes from the viewer).
        static func dotShrink(isLight: Bool) -> Double { isLight ? 0.540 : 1.000 }
    }

    private var lastWarpMode = 0

    /// Cached corpus-wide resting-radius references (the grid-warp mass normalisers). Invalidated by
    /// `captureRestingState`; the count/exponent checks are a second line of defence.
    private var cachedMeanRestingRadius: (count: Int, exponent: Double, linear: Double, mass: Double)?
    /// Grid-warp reads on-screen size + title-LOD fade from these, populated by applyOrbScales (the
    /// ONE place on-screen size is derived). Never recomputed in updateGridWarp — two copies drift.
    private var nodeOnScreenDiameter: [String: CGFloat] = [:]   // pt, per node (applyOrbScales)
    private var nodeTitleLodFade: [String: CGFloat] = [:]       // per node, = title.alpha (LOD fade)


    // MARK: - Grid warp (feeds BackgroundGridNode)

    /// Per frame: push the warp state into the grid shader. Mode is hardwired to RELOCATE C (T's
    /// ruling): the field moves each dot's CENTRE and draws a round dot around it, so dots can't
    /// smear, and they shrink near mass. The CPU builds a low-res displacement field once per frame.
    func updateGridWarp() {
        guard let grid = gridNode, let view = view else { return }
        let isLight = currentIsLight
        let mode: Float = 3                                   // Relocate C — the only mode that ships
        let cameraScale = cameraNode.xScale, camPos = cameraNode.position
        let viewW = Double(view.bounds.width), viewH = Double(view.bounds.height)
        let cs = Double(cameraScale)

        // ── ORB-UNIT BASIS (2026-09-14) ───────────────────────────────────────────────────────────
        // Reach and depth are dialled in ORB UNITS, converted to px per frame from each orb's ACTUAL
        // on-screen size. The old pixel values were anchored at cs = 1, so the look held at exactly one
        // zoom; three compensator dials (zoomWiden/zoomTighten/massReach) tried to patch that and each
        // was inert on one side of cs = 1. In orb units "distortion scales with the orb" is true BY
        // CONSTRUCTION at every zoom. Everything the shader consumes is still PIXELS: u_viewport_size
        // and the screenDist rank key live in the same point space applyOrbScales measures in, so there
        // is NO unit conversion — reach (orb-radii × on-screen radius) is already px.
        let ramp = max(Double(zoomRampScale(cameraScale)), 0.0001)
        let influence = min(1, max(0, GridWarpTuning.massInfluence(isLight: isLight)))
        let exponent = max(0.1, GridWarpTuning.massLaw)
        let massCeil = Double(BackgroundGridNode.warpMassCeiling)
        let massRange = BackgroundGridNode.warpMassRange(influence: influence)
        let refs = massReferenceRadii(exponent: exponent)
        // Corpus-average orb's on-screen RADIUS (px). refs.linear is a resting world radius (it already
        // folds in restingScale), so a resting orb draws at refs.linear × ramp / cs — the same formula
        // applyOrbScales uses per orb (onScreen ÷ 2), for the mean. This is the encode base.
        let refScreen = refs.linear * ramp / cs
        let reachUnits = GridWarpTuning.reachOrbRadii             // ORB RADII
        // DEFENSIVE CEILING on a single orb's reach. `buildWarpField` early-exits per texel with
        // `dist > o.reach`, which is what keeps its cost bounded; reach in ORB UNITS grows with the
        // orb's on-screen size, so zoomed close enough one orb's ring can cover the whole viewport
        // and that early-exit stops firing — every texel then sums every orb. A ring wider than half
        // the screen diagonal adds nothing visible, so capping there restores the exit without
        // touching the look. INERT at normal zooms (see the byte-identical check in the report).
        let reachCeiling = 0.5 * (viewW * viewW + viewH * viewH).squareRoot()
        let depth = GridWarpTuning.depthOrbRadii                  // fraction of an orb radius
        let strengthEff = depth * refScreen                      // px — global displacement depth; per-orb
                                                                 //      depth-dependence rides mass, as before

        // ── MASS (unchanged) — an orb dents in proportion to its AMPLIFIED radius. Zoom-invariant via
        // ÷ ramp; frame-invariant references so an orb's mass can't change because another orb moved.
        var scored: [(key: Double, sx: Double, sy: Double, mass: Double, reach: Double, fade: Double)] = []
        scored.reserveCapacity(nodeSprites.count)
        var titlesVisible = 0
        for (id, sprite) in nodeSprites {
            // ONE derivation of on-screen size: read what applyOrbScales already measured (DIAMETER,
            // pt) from the cache — never recompute intrinsic × xScale / cs here (the two would drift).
            // A node not yet measured this launch is simply skipped for this frame.
            guard let onScreen = nodeOnScreenDiameter[id] else { continue }
            let orbScreen = Double(onScreen) / 2                 // on-screen RADIUS, px
            // EASE-IN is PER ORB, tied to TITLE VISIBILITY: fade = the exact lodFade applyOrbScales
            // assigned to this orb's title (LensTuning.labelLOD … labelLOD×1.5 band — referenced, not
            // copied). An orb's pinch and its title appear together by construction. Fully zoomed out
            // every fade is 0 → every packed weight is 0 → the grid is exactly undistorted.
            let fade = Double(nodeTitleLodFade[id] ?? 0)
            if fade > 0 { titlesVisible += 1 }
            let p = sprite.position
            let sx = 0.5 + Double((p.x - camPos.x) / cameraScale) / viewW
            let sy = 0.5 + Double((p.y - camPos.y) / cameraScale) / viewH
            let rWorld = Double((nodeIntrinsicRadii[id] ?? 30) * sprite.xScale) / ramp
            // MASS LAW: displacement ∝ r^exponent, mixed against 1.0 by the influence dial (0 = uniform).
            let mass = min(massCeil, (1 - influence) + influence * pow(rWorld / refs.mass, exponent))
            // REACH in orb radii → px off THIS orb's live on-screen radius (annulus included). Wider for
            // a bigger orb by construction — this is what the retired warpMassReach dial approximated.
            let reach = min(reachUnits * orbScreen, reachCeiling)
            // RANK by the influence circle's distance from centre so a far-reaching big orb isn't
            // evicted from the 48-set by a nearer small one.
            let screenDist = Double(hypot(p.x - camPos.x, p.y - camPos.y)) / cs
            scored.append((screenDist - reach, sx, sy, mass, reach, fade))
        }
        scored.sort { $0.key < $1.key }
        let n = BackgroundGridNode.maxWarpOrbs
        // MEMBERSHIP WEIGHT: fade each orb's contribution to 0 over the last ~25% of the nearest-48 set
        // so an orb crossing the set boundary does so at ~0 weight → no pop.
        func membership(_ i: Int) -> Double { 1 - smoothstepD(0.75, 1.0, Double(i) / Double(n)) }
        var packed: [(sx: Double, sy: Double, w: Double, reach: Double)] = []
        packed.reserveCapacity(n)
        var maxW = 0.0
        for (i, e) in scored.prefix(n).enumerated() {
            // PER-ORB EASE folds into the weight: w = membership × mass × title-fade.
            let w = membership(i) * e.mass * e.fade
            maxW = max(maxW, w)
            packed.append((e.sx, e.sy, w, e.reach))
        }

        // OFF when the warp would contribute nothing — depth 0, OR fully zoomed out (no title visible →
        // every weight 0). Push the exact mode-0 path → byte-identical to an unwarped grid. This is what
        // delivers "fully zoomed out = undistorted" by construction.
        guard depth > 0.0001, maxW > 0.002 else {
            if lastWarpMode != 0 {
                BackgroundGridNode.setWarp(grid, mode: 0, strength: 0, sign: 1,
                                           shrink: 0, massRange: 1, field: nil)
                lastWarpMode = 0
            }
            return
        }
        lastWarpMode = Int(mode)

        // Mode C consumes the field exclusively (the per-orb orb-data texture went with mode A).
        // Falloff baked 1.0; the field carries the per-orb title fade via w, so the dot shrink
        // (∝ field magnitude) eases in per orb too.
        let field = buildWarpField(orbs: packed, falloff: 1.0, massRange: massRange, viewW: viewW, viewH: viewH)
        BackgroundGridNode.setWarp(grid, mode: mode, strength: Float(strengthEff),
                                   sign: Float(GridWarpTuning.sign),
                                   shrink: Float(GridWarpTuning.dotShrink(isLight: isLight)),
                                   massRange: Float(massRange), field: field)
    }

    /// The two corpus-wide reference radii the grid-warp mass normalises against (world units).
    ///
    /// `linear` = the plain mean resting radius, used for the REACH widening (which must not move
    /// when the mass law changes). `mass` = the power mean `(mean rᵉ)^(1/e)`, chosen so that the
    /// MEAN MASS over the resting corpus is exactly 1 whatever the exponent — switching the law
    /// between linear and area then redistributes weight between big and small orbs WITHOUT
    /// changing the overall gain, so T's already-dialled Strength keeps its meaning and the A/B
    /// compares one thing at a time.
    ///
    /// Cached on (node count, exponent) and invalidated from `captureRestingState`. It must NOT
    /// vary per frame, or an orb's mass would change because another orb moved — which is the
    /// invisible driver this whole change exists to remove.
    private func massReferenceRadii(exponent: Double) -> (linear: Double, mass: Double) {
        if let c = cachedMeanRestingRadius, c.count == nodeSprites.count, c.exponent == exponent {
            return (c.linear, c.mass)
        }
        var sum = 0.0, sumPow = 0.0
        for id in nodeSprites.keys {
            let r = Double(nodeRadii[id] ?? nodeIntrinsicRadii[id] ?? 30)
            sum += r; sumPow += pow(r, exponent)
        }
        let n = Double(max(nodeSprites.count, 1))
        let linear = nodeSprites.isEmpty ? 30 : max(1, sum / n)
        let mass = nodeSprites.isEmpty ? 30 : max(1, pow(sumPow / n, 1 / exponent))
        cachedMeanRestingRadius = (nodeSprites.count, exponent, linear, mass)
        return (linear, mass)
    }

    /// B — CPU-build a low-res signed AWAY-pull field (rg = 0.5-biased). Same sign as A (converge).
    /// Cost O(texels × orbs), done ONCE/frame → the grid's per-fragment cost is constant at any count.
    /// `orbs.w` already carries membership × mass and `orbs.reach` is that orb's own mass-widened
    /// reach, so B and C agree with A. This is the ONLY consumer for modes B/C, and it works in full
    /// Double precision — the 8-bit squeeze happens once, at the encode below.
    private func buildWarpField(orbs: [(sx: Double, sy: Double, w: Double, reach: Double)],
                                falloff: Double, massRange: Double, viewW: Double, viewH: Double) -> SKTexture {
        let fw = 40, fh = 80
        var bytes = [UInt8](repeating: 128, count: fw * fh * 4)   // 128 = 0.5 = no pull
        let invRange = 1 / max(massRange, 0.001)
        for j in 0..<fh {
            let fy = (Double(j) + 0.5) / Double(fh)
            let fragPy = (fy - 0.5) * viewH
            for i in 0..<fw {
                let fx = (Double(i) + 0.5) / Double(fw)
                let fragPx = (fx - 0.5) * viewW
                var px = 0.0, py = 0.0
                for o in orbs where o.w > 0.001 {
                    let dx = fragPx - (o.sx - 0.5) * viewW      // FRAGMENT - orb, in PIXELS = AWAY (matches A)
                    let dy = fragPy - (o.sy - 0.5) * viewH
                    let dist = (dx * dx + dy * dy).squareRoot()  // real px, isotropic
                    if dist > o.reach || dist < 1e-3 { continue }
                    let f = pow(max(0, 1 - dist / o.reach), 1 + falloff * 4)
                    px += (dx / dist) * f * o.w; py += (dy / dist) * f * o.w
                }
                // Encode against the same full-scale the shader decodes with. At influence 0 the
                // range is 1 and this is the pre-mass encoding byte-for-byte; at influence 1 it is
                // the mass ceiling, which is what stops a heavy orb's dimple CLIPPING flat at its
                // core (the pre-mass field already saturated at 1.0 directly under an orb).
                let ex = min(1, max(-1, px * invRange)), ey = min(1, max(-1, py * invRange))
                let b = (j * fw + i) * 4
                bytes[b] = UInt8((0.5 + ex * 0.5) * 255)
                bytes[b + 1] = UInt8((0.5 + ey * 0.5) * 255)
            }
        }
        let tex = SKTexture(data: Data(bytes), size: CGSize(width: fw, height: fh))
        tex.filteringMode = .linear
        return tex
    }

    /// Double smoothstep (the shader has one; the scene didn't).
    private func smoothstepD(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / max(e1 - e0, 1e-6))); return t * t * (3 - 2 * t)
    }

    // (The per-orb DROP SHADOW spike was DELETED at the bake, 2026-09-14 — T ruled it out: the
    // grid warp's dot shrink does the figure-ground job the shadow existed for.)

    /// Recolor every resting (non-focal) glyph label on APPEARANCE FLIP — the DARK ink
    /// depends on the sat/val boost, so light↔dark must re-flip. Glyph labels recolor in
    /// place (set `a_glyph_color`; no re-raster) — a one-time burst on flip.
    func restyleLabels() {
        for (nodeID, shape) in nodeSprites {
            guard let titleNode = shape.children.first(where: { $0.name == "titleLabel" }),
                  (titleNode.userData?["isFocal"] as? Bool) != true
            else { continue }
            let fillColor = currentNodes.first(where: { $0.id == nodeID }).map { bubbleColor(for: $0) } ?? .gray
            let inkFill = currentIsLight ? fillColor : applyDarkOrbBoost(fillColor)
            MSDFLabel.recolor(container: titleNode, color: legibleInk(over: inkFill).ink)
        }
    }

    // MARK: - Sprite orb substrate (the sole unfocused-orb render path)

    /// ONE shared SKShader for every unfocused orb (created once, reused; NOT
    /// per-instance — that's the über anti-pattern that breaks batching). Renders
    /// an anti-aliased filled-circle SDF + inner stroke ring, colored PER NODE via
    /// SKAttributes (a_node_color / a_stroke_color / a_geom). Shared shader + shared
    /// texture + per-node attributes + `.ignoresSiblingOrder` collapse the orb fills
    /// to a handful of draws (sim-measured 2804→5; device-verified identical).
    private lazy var orbSpriteShader: SKShader = {
        let src = """
        // Lens: circle → rounded-square morph via one uniform. sdRoundBox is a true
        // signed distance (0 at edge, negative inside); `+ 0.5` shifts it so the
        // edge lands at d = R = 0.5, identical to the old `length(p)` when
        // u_corner_radius == 0.5 (that IS a circle). So the fill/stroke smoothstep
        // on d is UNCHANGED and the stroke ring (an inset of the same field)
        // follows the shape automatically. u_corner_radius is a global uniform →
        // one value for every orb → still batches.
        float sdRoundBox(vec2 p, vec2 b, float r) {
            vec2 q = abs(p) - b + r;
            return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
        }
        // HSV helpers for the DARK dimensionality block (hue-preserving sat/val +
        // tinted rim/glow). Standard GLSL (Hocevar). The LIGHT path never calls these.
        vec3 rgb2hsv(vec3 c) {
            vec4 K = vec4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
            vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
            vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
            float dv = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return vec3(abs(q.z + (q.w - q.y) / (6.0 * dv + e)), dv / (q.x + e), q.x);
        }
        vec3 hsv2rgb(vec3 c) {
            vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
            vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
        }
        void main() {
            vec2 p = v_tex_coord - vec2(0.5);
            float d = sdRoundBox(p, vec2(0.5), u_corner_radius) + 0.5;
            float R = 0.5;
            float aa = a_geom.y;          // ~1px feather (uv)
            float sw = a_geom.x;          // stroke width (uv)
            float disc = 1.0 - smoothstep(R - aa, R, d);
            float ring = clamp(smoothstep(R - sw - aa, R - sw, d) - smoothstep(R - aa, R, d), 0.0, 1.0);
            vec4 fillC = a_node_color;
            vec4 strokeC = a_stroke_color;

            // Diagonal hue-wash, folded IN so it shares this SDF and morphs as ONE
            // shape (was a separate circular child sprite → circle-in-square). Ramp:
            // clear at top-leading (v_tex_coord 0,1) → deep at bottom-trailing (1,0),
            // matching the retired nodeWashTexture direction. Applied to the fill →
            // gated by `disc` → follows the rounded-box corners. a_wash.rgb = pigment
            // (light: hue shade; dark: black), a_wash.a = peak strength; u_wash_is_light
            // picks screen-deepen (Cucumber Water) vs darken (Solar Flare).
            float washT = clamp((v_tex_coord.x - v_tex_coord.y + 1.0) * 0.5, 0.0, 1.0);
            float wS = a_wash.a * washT;
            vec3 fillRGB = fillC.rgb;
            if (u_wash_is_light > 0.5) {
                // LIGHT (Cucumber Water) — UNCHANGED. Byte-identical: no new term touches this branch.
                vec3 screenTerm = 1.0 - (1.0 - fillRGB) * (1.0 - a_wash.rgb);
                fillRGB = mix(fillRGB, screenTerm, wS);
            } else {
                // DARK — emissive dimensionality register (the substrate's first
                // effect). Replaces the flat diagonal darken with a lit-ball look
                // while PRESERVING the cluster hue. All levers are global uniforms +
                // per-pixel math → one value for every orb → still one batch.
                // Composite: fill → sat/val → sphere-shade → +rim → +specular → +glow.
                vec3 hsv = rgb2hsv(fillRGB);
                hsv.y = clamp(hsv.y * u_dark_sat, 0.0, 1.0);   // 1. saturation (drab-killer, hue kept)
                hsv.z = clamp(hsv.z * u_dark_val, 0.0, 1.0);   //    + brightness
                vec3 col = hsv2rgb(hsv);

                vec2 ldir = normalize(u_light_dir);
                float shade = dot(normalize(p + vec2(1e-4)), ldir);          // 3. sphere-shade (-1..1, volume)
                col *= (1.0 + u_dark_sphere * shade);

                float rim = smoothstep(R - u_rim_width, R, d);               // 2. rim-light (lit edge)
                vec3 rimCol = hsv2rgb(vec3(hsv.x, hsv.y * 0.5, min(1.0, hsv.z + 0.4)));
                col += u_dark_rim * rim * rimCol;

                vec2 specP = ldir * (R * 0.55);                             // 4. specular catch-light
                float spec = smoothstep(u_spec_size, 0.0, distance(p, specP));
                col += u_dark_spec * spec;

                float glowFall = 1.0 - smoothstep(0.0, R, length(p));        // 5. inner glow / emissive bloom
                vec3 glowCol = hsv2rgb(vec3(hsv.x, hsv.y, 1.0));
                col += u_dark_glow * glowFall * glowCol;

                fillRGB = clamp(col, 0.0, 1.0);
            }

            float fa = disc * fillC.a;
            float sa = ring * strokeC.a;
            float outA = sa + fa * (1.0 - sa);
            vec3 outRGB = strokeC.rgb * sa + fillRGB * fa * (1.0 - sa);  // premultiplied, stroke over washed fill
            gl_FragColor = vec4(outRGB, outA);
        }
        """
        let shader = SKShader(source: src)
        shader.attributes = [
            SKAttribute(name: "a_node_color", type: .vectorFloat4),
            SKAttribute(name: "a_stroke_color", type: .vectorFloat4),
            SKAttribute(name: "a_geom", type: .vectorFloat2),
            SKAttribute(name: "a_wash", type: .vectorFloat4)    // rgb = wash pigment, a = peak strength
        ]
        // u_corner_radius: 0.5 = circle. Held at 0.5 — the morph to rounded square
        // (cornerMin) is retired to dormant; the uniform + sdRoundBox stay inert for
        // revival. u_wash_is_light: 1 = light screen-deepen, 0 = dark darken.
        // Both global → the orb sprites still collapse to one batch.
        shader.uniforms = [
            SKUniform(name: "u_corner_radius", float: 0.5),
            SKUniform(name: "u_wash_is_light", float: 1.0),
            // Dark-mode dimensionality levers (global → one batch). Set once here from
            // the BAKED DarkOrbTuning literals (the tuner + live re-push were deleted).
            SKUniform(name: "u_dark_sat", float: Float(DarkOrbTuning.sat)),
            SKUniform(name: "u_dark_val", float: Float(DarkOrbTuning.val)),
            SKUniform(name: "u_dark_rim", float: Float(DarkOrbTuning.rim)),
            SKUniform(name: "u_rim_width", float: Float(DarkOrbTuning.rimWidth)),
            SKUniform(name: "u_dark_sphere", float: Float(DarkOrbTuning.sphere)),
            SKUniform(name: "u_light_dir", vectorFloat2: vector_float2(Float(DarkOrbTuning.lightDirX), Float(DarkOrbTuning.lightDirY))),
            SKUniform(name: "u_dark_spec", float: Float(DarkOrbTuning.spec)),
            SKUniform(name: "u_spec_size", float: Float(DarkOrbTuning.specSize)),
            SKUniform(name: "u_dark_glow", float: Float(DarkOrbTuning.glow))
        ]
        return shader
    }()

    private static func rgbaVec(_ c: UIColor) -> vector_float4 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return vector_float4(Float(r), Float(g), Float(b), Float(a))
    }

    /// Push per-node fill/stroke into the shared sprite shader via attributes.
    /// `sw`/`aa` are in uv (sprite spans size=2·radius → 1px = 1/(2·radius) uv).
    private func setOrbSpriteAttributes(_ sprite: SKSpriteNode, fill: UIColor,
                                        stroke: UIColor, lineWidth: CGFloat, radius: CGFloat,
                                        wash: UIColor, washStrength: CGFloat) {
        sprite.setValue(SKAttributeValue(vectorFloat4: Self.rgbaVec(fill)), forAttribute: "a_node_color")
        sprite.setValue(SKAttributeValue(vectorFloat4: Self.rgbaVec(stroke)), forAttribute: "a_stroke_color")
        let denom = Float(max(1, radius * 2))
        sprite.setValue(SKAttributeValue(vectorFloat2: vector_float2(Float(lineWidth) / denom, 1.0 / denom)),
                        forAttribute: "a_geom")
        let w = Self.rgbaVec(wash)   // straight rgb; alpha overridden by the wash peak strength
        sprite.setValue(SKAttributeValue(vectorFloat4: vector_float4(w.x, w.y, w.z, Float(washStrength))),
                        forAttribute: "a_wash")
    }



    // MARK: - Helpers

    /// The unfocused orb — ONE SKSpriteNode running the shared SDF `orbSpriteShader`
    /// (rounded-box fill + inner stroke ring + diagonal hue-wash, all per-node via
    /// SKAttributes). One sprite, one shape — the wash is shader-internal now, so it
    /// morphs with the fill. SOLE orb render path (promoted from the SKShapeNode
    /// spike). Über keeps its own `makeUberNodeShape`. Physics/label/name attached
    /// by `addNodeSprite`.
    private func makeShape(
        radius: CGFloat,
        fillColor: UIColor,
        isMeta: Bool = false,
        nodeID: String
    ) -> SKNode {
        let sprite = SKSpriteNode(texture: whiteUVTexture)  // texture → valid v_tex_coord
        sprite.size = CGSize(width: radius * 2, height: radius * 2)
        sprite.zPosition = 1
        sprite.shader = orbSpriteShader

        // Fill/stroke/wash appearance (dark Solar Flare vs light Cucumber Water),
        // re-applied on appearance flip via restyleUnfocusedOrbs().
        styleUnfocusedOrb(sprite, baseFill: fillColor, isMeta: isMeta,
                          isLight: currentIsLight)
        return sprite
    }

    /// Create Über-node shape with GLSL gradient shader using child colors.
    private func makeUberNodeShape(
        radius: CGFloat,
        colors: [UIColor],
        clusterID: String
    ) -> SKShapeNode {
        // ws-map — deformation retired (Level 1); nodes are circles.
        let shape = SKShapeNode(circleOfRadius: radius)

        // Apply per-instance shader with child node colors
        shape.fillTexture = whiteUVTexture
        shape.fillShader = makeUberNodeShader(colors: colors)
        shape.strokeColor = UIColor.white.withAlphaComponent(0.2)
        shape.lineWidth = 1.5
        shape.zPosition = 1

        return shape
    }

    /// Blend two UIColors with the given ratio (0.0 = all color1, 1.0 = all color2).
    private func blendColors(_ color1: UIColor, _ color2: UIColor, ratio: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

        color1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        return UIColor(
            red: r1 * (1 - ratio) + r2 * ratio,
            green: g1 * (1 - ratio) + g2 * ratio,
            blue: b1 * (1 - ratio) + b2 * ratio,
            alpha: a1 * (1 - ratio) + a2 * ratio
        )
    }

    /// Ink + halo that read legibly over a given fill: warm near-black on a light
    /// fill, warm off-white on a dark one, each paired with an opposite-luminance
    /// halo so the type separates on mid-tones too. Mirrors the focal bubble's
    /// SwiftUI rule (`NodeGradientLayer.legibleInk`), in UIKit for the sprite path.
    private func legibleInk(over fill: UIColor) -> (ink: UIColor, halo: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        fill.getRed(&r, green: &g, blue: &b, alpha: &a)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if lum > 0.6 {
            return (UIColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1.0),
                    UIColor(white: 1.0, alpha: 0.6))     // dark ink, light halo
        } else {
            return (UIColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1.0),
                    UIColor(white: 0.0, alpha: 0.6))     // light ink, dark halo
        }
    }

    /// Replicate `orbSpriteShader`'s DARK sat/val boost EXACTLY (rgb→hsv,
    /// s ×= dark_sat, v ×= dark_val, clamp [0,1], hsv→rgb), reading the SAME
    /// `DarkOrbTuning` the shader uses so the label-ink decision can't drift from the
    /// rendered orb. `legibleInk` then evaluates its `lum > 0.6` threshold on the
    /// ACTUAL rendered tone → bright boosted orbs consistently get dark ink. The
    /// rim/sphere/spec/glow levers are localized highlights, not the base tone, so
    /// they don't enter the ink decision. Dark mode only.
    private func applyDarkOrbBoost(_ c: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &v, alpha: &a) else { return c }
        s = min(1.0, s * DarkOrbTuning.sat)
        v = min(1.0, v * DarkOrbTuning.val)
        return UIColor(hue: h, saturation: s, brightness: v, alpha: a)
    }

    /// Node-label size tiers — BAKED from T's device-final values (2026-07-21
    /// end-of-loop bake). Tier font sizes = box × fraction, clamped to [floor, cap].
    /// Plain literals, ZERO UserDefaults → Debug == Release.
    enum LabelTuning {
        static let largeFrac: CGFloat = 0.195
        static let medFrac:   CGFloat = 0.135
        static let smallFrac: CGFloat = 0.125
        static let floor:     CGFloat = 5
        static let maxLines:  Int = 3
        static let cap: CGFloat = 28   // absolute point ceiling

        /// The 3 tier point sizes for a `box`-wide label, largest → smallest.
        static func tierSizes(box: CGFloat) -> [CGFloat] {
            [largeFrac, medFrac, smallFrac].map { min(cap, max(floor, box * $0)) }
        }
    }

    /// Node-title typography — BAKED to T's device-final values (Type arc end,
    /// 2026-07-21). Plain literals, ZERO UserDefaults → Debug == Release; the DEBUG
    /// type tuner is gone. `resolveTitle` (clean-fit + whole-title hyphenation) and
    /// `softHyphenated` stay — the hyphenation LOGIC is retained; only the dials are
    /// frozen. Fraunces + all-caps + hyphenation on + no tracking.
    enum TypeTuning {
        static let allCaps: Bool = true
        static let hyphenation: Bool = true
        static let tracking: CGFloat = 0.0
        static let fontChoice: MapLabelFont = .fraunces
    }

    /// Dark-mode orb POP — the substrate's first EFFECT: dimensionality levers fed to
    /// `orbSpriteShader`'s dark branch as GLOBAL uniforms (one value per orb → one
    /// batch). Light (Cucumber Water) is untouched. BAKED to T's device-final dialed
    /// mix (2026-07-21): the RESTRAINED register — vivid sat/val + a light rim, NO
    /// sphere-shade / specular / glow. Literals, zero UserDefaults → Debug == Release
    /// (the DEBUG dark-orb tuner panel + `dark.*` keys were baked-and-deleted). Pushed
    /// once into the shader's `uniforms` at `orbSpriteShader` init.
    enum DarkOrbTuning {
        // ★ T device-final 2026-09-14 (`orb: darkSat/darkVal/darkRim`, DARK-ONLY) —
        // see Ops/reference/tuner-state-accepted.md. Was 2.00 / 1.25 / 0.20 pre-bake.
        static let sat: CGFloat = 3.000       // saturation ×
        static let val: CGFloat = 1.952       // brightness ×
        static let rim: CGFloat = 0.000       // rim-light strength (dialled off)
        static let rimWidth: CGFloat = 0.17   // rim band width (uv)
        static let sphere: CGFloat = 0.00     // sphere-shade intensity (off)
        static let lightDirX: CGFloat = -1.0  // light direction x
        static let lightDirY: CGFloat = -1.0  // light direction y
        static let spec: CGFloat = 0.00       // specular strength (off)
        static let specSize: CGFloat = 0.18   // specular radius (uv)
        static let glow: CGFloat = 0.00       // inner glow (off)
    }

    /// Orb-size multiplier — BAKED 1.00 (T's device-final). Applied to the whole
    /// `bubbleRadius`; radius drives sprite + label box + physics body + CanvasView's
    /// layout-radii. Literal, zero UserDefaults → Debug == Release.
    enum OrbTuning {
        static let sizeScale: CGFloat = 1.0
    }

    /// Lens (a) — global zoom-ramp — BAKED (T's device-final, 2026-07-21). Shrinks
    /// IDLE orbs from the max as the camera zooms OUT; culls titles below labelLOD.
    /// `cornerMin` baked 0.50 = permanent CIRCLE — the morph is DORMANT (its
    /// sdRoundBox + u_corner_radius machinery is preserved inert in orbSpriteShader).
    /// `labelBoxFactor` 1.4 = circle-inscribed. Literals, zero UD → Debug == Release.
    enum LensTuning {
        static let zoomIn: CGFloat = 0.55
        static let zoomOut: CGFloat = 2.45
        static let minShrink: CGFloat = 0.79
        static let labelLOD: CGFloat = 33
        static let cornerMin: CGFloat = 0.50   // permanent circle (morph retired to dormant)
        static let labelBoxFactor: CGFloat = 1.4
    }

    /// Viewport-centered continuous-annulus — BAKED (T's device-final). `amplitude` =
    /// center bump; `onset`/`rampWidth` = the bloom envelope; `radius` = falloff band;
    /// the pairwise push-apart keeps enlarged band nodes apart. Literals, zero UD.
    enum AnnulusTuning {
        static let amplitude: CGFloat = 1.20
        static let onset: CGFloat = 3.00
        static let rampWidth: CGFloat = 1.50
        static let radius: CGFloat = 300
        static let breathingGap: CGFloat = 8.923   // T device-final 2026-09-14 (`separation: orbGap`),
                                                  // see Ops/reference/tuner-state-accepted.md (was 30)
        static let relaxPasses: Int = 8
        static let relaxLerp: CGFloat = 0.22       // damped approach to the relaxed target
        static let hapticOn: Bool = true
        static let hapticIntensity: CGFloat = 0.60
        static let hapticCentrality: Bool = false
        static let hapticMinAudible: CGFloat = 0.10   // floor when a tick fires (never round to nothing)
        static let maxBand: Int = 56                  // PERF CAP: N most-central nodes relax (O(N²·passes))

        /// Full-bloom cameraScale (more zoomed in than onset), derived from the ramp.
        static var fullZoom: CGFloat { onset - rampWidth }

        /// Bloom-in envelope 0→1 as the camera zooms IN across [onset … fullZoom].
        /// One envelope drives BOTH amplify + relaxation. 0 at onset, 1 at fullZoom.
        static func envelope(_ cameraScale: CGFloat) -> CGFloat {
            let on = onset, full = fullZoom
            if cameraScale >= on { return 0 }
            if cameraScale <= full { return 1 }
            let t = (on - cameraScale) / max(on - full, 0.0001)
            return t * t * (3 - 2 * t)   // smoothstep
        }
    }

    // MARK: - Glyph-space line layout (Phase 2) — the MSDF port of resolveTitle

    /// How a segment attaches to the previous one ON THE SAME LINE. A break before a
    /// `.hyphen` segment (a soft-hyphen point, mid-word) leaves a VISIBLE "-"; a break
    /// before `.space` drops cleanly with no mark.
    private enum GlyphJoin { case start, space, hyphen }

    /// Glyph-space port of `resolveTitle`'s PASS 1/2/3 — SAME tier set / maxLines /
    /// softHyphenated dictionary / all-caps — but measured with `measure` (atlas
    /// advances) and producing EXPLICIT lines, so one metric system drives both fit and
    /// render. The raster path keeps `resolveTitle`'s UIKit measurer until Phase 3.
    private func resolveTitleLines(_ rawText: String, box: CGFloat,
                                   measure: (String, UIFont) -> CGFloat) -> (font: UIFont, lines: [String]) {
        let maxLines = LabelTuning.maxLines
        let tiers = LabelTuning.tierSizes(box: box)
        let capsText = TypeTuning.allCaps ? rawText.uppercased() : rawText

        // PASS 1 — clean WORD-WRAP across tiers (largest first). Each word must fit the
        // box alone (no char-break) and wrap within maxLines by word boundaries. No hyphens.
        for size in tiers {
            let f = CorpusPhysicsScene.mapLabelFont(size: size)
            let segs = capsText.split(separator: " ", omittingEmptySubsequences: true)
                .enumerated().map { ($0 == 0 ? GlyphJoin.start : .space, String($1)) }
            if let lines = Self.wrapSegments(segs, f, box: box, maxLines: maxLines, measure: measure) {
                return (f, lines)
            }
        }

        // PASS 2 — soft-hyphenate the whole title (original case for the dict), uppercase,
        // wrap allowing hyphen breaks (a VISIBLE "-"). First tier that fits within maxLines.
        // The Simulator lacks the hyphenation dictionary → softHyphenated is a no-op there,
        // so this pass finds nothing in-sim and PASS 3 handles it (device renders the hyphens).
        if TypeTuning.hyphenation {
            let hyBase = CorpusPhysicsScene.softHyphenated(rawText)
            if hyBase != rawText {
                let hyText = TypeTuning.allCaps ? hyBase.uppercased() : hyBase
                let segs = Self.hyphenSegments(hyText)
                for size in tiers {
                    let f = CorpusPhysicsScene.mapLabelFont(size: size)
                    if let lines = Self.wrapSegments(segs, f, box: box, maxLines: maxLines, measure: measure) {
                        return (f, lines)
                    }
                }
            }
        }

        // PASS 3 — floor tier. Single word → char-wrap (show every letter). Multiple words
        // → greedy word-wrap, drop the overflow, mark the last line with "..." (the atlas
        // has no U+2026 ellipsis glyph). Mirrors resolveTitle's last resort.
        let floorFont = CorpusPhysicsScene.mapLabelFont(size: tiers.last ?? LabelTuning.floor)
        let words = capsText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if words.count <= 1 {
            return (floorFont, Self.charWrap(capsText, floorFont, box: box, maxLines: maxLines, measure: measure))
        }
        return (floorFont, Self.dropWithEllipsis(words, floorFont, box: box, maxLines: maxLines, measure: measure))
    }

    /// Greedy line wrapper over pre-tokenised `(join, segment)`s. `.space` break → new
    /// line, no mark; `.hyphen` break (mid-word) → a VISIBLE "-" ends the broken line.
    /// Returns nil if a segment can't fit the box alone or the wrap needs > maxLines.
    private static func wrapSegments(_ segs: [(GlyphJoin, String)], _ f: UIFont, box: CGFloat,
                                     maxLines: Int, measure: (String, UIFont) -> CGFloat) -> [String]? {
        var lines: [String] = []
        var cur = ""
        for (join, seg) in segs {
            if cur.isEmpty {
                if measure(seg, f) > box + 0.5 { return nil }
                cur = seg
                continue
            }
            let glue = (join == .space) ? " " : ""
            let trial = cur + glue + seg
            if measure(trial, f) <= box + 0.5 {
                cur = trial
            } else {
                lines.append(join == .hyphen ? cur + "-" : cur)
                if lines.count >= maxLines { return nil }
                if measure(seg, f) > box + 0.5 { return nil }
                cur = seg
            }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.count <= maxLines ? lines : nil
    }

    /// Segment a soft-hyphenated (U+00AD) title: words split on spaces (`.space` join),
    /// syllables split on the soft hyphens (`.hyphen` join).
    private static func hyphenSegments(_ text: String) -> [(GlyphJoin, String)] {
        var segs: [(GlyphJoin, String)] = []
        for (wi, word) in text.split(separator: " ", omittingEmptySubsequences: true).enumerated() {
            for (si, syl) in word.split(separator: "\u{00AD}", omittingEmptySubsequences: true).enumerated() {
                let join: GlyphJoin = (wi == 0 && si == 0) ? .start : (si == 0 ? .space : .hyphen)
                segs.append((join, String(syl)))
            }
        }
        return segs
    }

    /// Char-wrap a single over-long word (raster's `.byCharWrapping`): pack characters
    /// per line, no hyphen, capped at maxLines.
    private static func charWrap(_ text: String, _ f: UIFont, box: CGFloat, maxLines: Int,
                                 measure: (String, UIFont) -> CGFloat) -> [String] {
        var lines: [String] = []
        var cur = ""
        for ch in text {
            let trial = cur + String(ch)
            if cur.isEmpty || measure(trial, f) <= box + 0.5 { cur = trial }
            else { lines.append(cur); cur = String(ch); if lines.count >= maxLines { return lines } }
        }
        if !cur.isEmpty, lines.count < maxLines { lines.append(cur) }
        return lines
    }

    /// Greedy word-wrap at the floor tier; drop the overflow and mark the last kept line
    /// with "..." (no U+2026 in the atlas). Best-effort — the rare PASS-3 multi-word case.
    private static func dropWithEllipsis(_ words: [String], _ f: UIFont, box: CGFloat, maxLines: Int,
                                         measure: (String, UIFont) -> CGFloat) -> [String] {
        var lines: [String] = []
        var cur = ""
        var i = 0
        while i < words.count {
            let w = words[i]
            let trial = cur.isEmpty ? w : cur + " " + w
            if cur.isEmpty || measure(trial, f) <= box + 0.5 { cur = trial; i += 1 }
            else if lines.count + 1 == maxLines { break }   // last line reached; rest overflow
            else { lines.append(cur); cur = "" }
        }
        if i < words.count {   // words were dropped → ellipsize the last line
            while cur.contains(" "), measure(cur + "...", f) > box + 0.5 {
                cur = String(cur[..<cur.range(of: " ", options: .backwards)!.lowerBound])
            }
            lines.append(cur.isEmpty ? "..." : cur + "...")
        } else if !cur.isEmpty {
            lines.append(cur)
        }
        return Array(lines.prefix(maxLines))
    }

    private func makeTitleSprite(text: String, radius: CGFloat, fillColor: UIColor) -> SKNode {
        // MSDF glyph label — the SOLE label path (raster retired in Phase 3). The wrap /
        // tier / hyphenation is resolved in glyph-space (resolveTitleLines, measured with
        // atlas advances → one metric system for fit + render); ink matches the orb
        // (legibleInk over the dark-boosted fill). Returns a container child of the orb
        // named "titleLabel", z 2 — resolution-independent (crisp at any zoom) + batched.
        let side = radius * LensTuning.labelBoxFactor
        // Orb-title FONT — Space Grotesk Bold (T device-final 2026-09-14). MSDF renders + measures
        // from the SAME atlas, so the face and its metrics must not diverge (see MSDFFont.orbTitle).
        let font = MSDFFont.orbTitle
        let (glyphFont, lines) = resolveTitleLines(text, box: side) { s, f in
            MSDFLabel.textWidth(s, pointSize: f.pointSize, font: font)
        }
        let inkFill = currentIsLight ? fillColor : applyDarkOrbBoost(fillColor)
        // Title ink: T device-final 2026-09-14 is `titleColour=(auto)` + `titleOpacity=1.000`,
        // i.e. the legible-ink rule with no override — so the auto value IS the shipped value.
        let titleColor = legibleInk(over: inkFill).ink
        return MSDFLabel.makeContainer(lines: lines, pointSize: glyphFont.pointSize,
                                       color: titleColor, fullTitle: text, font: font)
    }

    /// The resting orb physics body for a given radius — extracted so a rebuild
    /// produces an IDENTICAL body (SKPhysicsBody radius is immutable, so a fresh
    /// radius means a fresh body). Static: mass derives only from radius.
    /// `isDynamic = false` — resting layout is algorithmic, not physics-settled;
    /// the body is kept coupled for hit-testing + future use.
    private static func configuredOrbBody(radius: CGFloat) -> SKPhysicsBody {
        let body = SKPhysicsBody(circleOfRadius: radius)
        body.linearDamping = 0.6
        body.angularDamping = 0.8
        body.friction = 0.1
        body.restitution = 0.25
        body.mass = CGFloat(max(0.5, Float(radius / 30)))
        body.allowsRotation = false
        body.isDynamic = false
        return body
    }

    private func bubbleRadius(for node: Node) -> CGFloat {
        // Base diameter 60pt (radius 30), +8pt diameter per additional item (radius
        // +4), max diameter 120pt (radius 60). Shipped values, baked (Map tuner gone).
        // `OrbTuning.sizeScale` (default 1.0) multiplies base + extra + cap uniformly
        // so every orb grows proportionally; min(a,b)·s == min(a·s, b·s) for s>0.
        let extra = CGFloat(max(0, node.items.count - 1)) * 4
        return min(30 + extra, 60) * OrbTuning.sizeScale
    }

    /// Hides the focal node's SpriteKit sprite so the SwiftUI gradient overlay in
    /// CanvasView owns the visual entirely. Pixel-perfect alignment between the two
    /// layers is impractical because the lens system continuously animates the
    /// SpriteKit node's scale; getting it out of the way is cleaner. Direct alpha
    /// assignment (not SKAction) so the transition is instant.
    /// Note: the sprite's "titleLabel" child inherits the parent alpha, so the
    /// SpriteKit-rendered title is hidden too. The SwiftUI overlay does not yet
    /// render the title — that's tracked separately.
    private func setFocalShader(to nodeID: String?) {
        // Cancel any in-flight strand-dim fade on either sprite — otherwise an
        // active `SKAction.fadeAlpha` keeps interpolating each frame toward the
        // dim target and clobbers the instant alpha assignment below, letting
        // the focal's solid fill bleed through behind the SwiftUI gradient.
        // Orbs are SKSpriteNodes with the shared orb shader — focal-hide is just
        // alpha=0 (keep the shader; don't clear it). Focal visual is the SwiftUI
        // overlay. (über is a separate dict, unaffected.)
        if let oldID = focalShaderID, oldID != nodeID,
           let oldShape = nodeSprites[oldID] {
            oldShape.removeAction(forKey: Self.strandDimActionKey)
            oldShape.alpha = 1
            dimmedSpriteIDs.remove(oldID)
        }
        if let newID = nodeID, newID != focalShaderID,
           let newShape = nodeSprites[newID] {
            newShape.removeAction(forKey: Self.strandDimActionKey)
            newShape.alpha = 0
            dimmedSpriteIDs.remove(newID)
        }
        focalShaderID = nodeID
    }

    // SB135 Stage 1a — per-neighborhood palette (PLACEHOLDER).
    // When the colorblind-tested set lands, replace this array — no other
    // rendering changes required. Six slots; collisions across neighborhoods
    // are accepted at this palette size.
    private static let neighborhoodPalette: [UIColor] = [
        UIColor(red: 0x1B/255.0, green: 0x59/255.0, blue: 0xC2/255.0, alpha: 1.0),  // #1B59C2 Klein Blue
        UIColor(red: 0xE8/255.0, green: 0x82/255.0, blue: 0x0A/255.0, alpha: 1.0),  // #E8820A Mango
        UIColor(red: 0x00/255.0, green: 0xBF/255.0, blue: 0xFF/255.0, alpha: 1.0),  // #00BFFF Electric Cyan
        UIColor(red: 0x7B/255.0, green: 0x68/255.0, blue: 0xEE/255.0, alpha: 1.0),  // #7B68EE Slate Blue
        UIColor(red: 0x20/255.0, green: 0xB2/255.0, blue: 0xAA/255.0, alpha: 1.0),  // #20B2AA Sea Green
        UIColor(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x6B/255.0, alpha: 1.0),  // #FF6B6B Coral
    ]

    // SB135 Stage 1a — reserved low-saturation neutral for unattached nodes
    // (neighborhoodID nil). Three candidates declared; T picks on-device by
    // changing the active default below.
    private static let unattachedNeutralCool = UIColor(red: 0xA8/255.0, green: 0xB0/255.0, blue: 0xBC/255.0, alpha: 1.0)  // desaturated slate
    private static let unattachedNeutralWarm = UIColor(red: 0xB5/255.0, green: 0xAD/255.0, blue: 0xA0/255.0, alpha: 1.0)  // desaturated taupe
    private static let unattachedNeutralPure = UIColor(red: 0xA8/255.0, green: 0xA8/255.0, blue: 0xAC/255.0, alpha: 1.0)  // pure neutral grey
    private static let unattachedNeutral = unattachedNeutralCool  // T picks on-device

    /// DJB2 stable hash. Swift's `String.hashValue` randomizes per launch, so we
    /// use a deterministic hash to keep neighborhoodID → palette slot consistent
    /// across sessions.
    private func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in s.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return hash
    }

    /// SB135 Stage 1a — non-focal idea-node fill routes through neighborhoodID
    /// against the placeholder palette. Tag identity is no longer a canvas
    /// color channel for non-focal nodes; tags remain a vocabulary in detail
    /// view, list mode, and swatch picker. The focal node's tag-driven gradient
    /// is preserved via `NodeGradientBackground` (SwiftUI overlay) — that path
    /// is unchanged.
    ///
    /// Über-nodes are not routed here — they have their own path via
    /// `makeUberNodeShape` + `sampleChildColors`, which still reads `tagColors`.
    private func bubbleColor(for node: Node) -> UIColor {
        // Tag-anchored Map — territory tint takes precedence when the node sits
        // in a designated-anchor territory (paired with the on-canvas label for
        // colorblind-safe reading).
        if let territory = territoryColors[node.id] { return territory }
        // SB139 Stage 4c1.1 — substrate-as-baseline color path. When the flag
        // is on and the substrate has computed an HSB for this node, render
        // it. Otherwise fall through to the legacy neighborhood palette so
        // non-rankable / meta / pre-fit corpora keep their tag-driven colors.
        if #available(iOS 17.0, *),
           FeatureFlags.substrateLayout,
           let hsb = SubstrateLayoutService.shared.colorHSB?[node.id] {
            return UIColor(
                hue: CGFloat(hsb.hue),
                saturation: CGFloat(hsb.saturation),
                brightness: CGFloat(hsb.brightness),
                alpha: 1.0
            )
        }
        guard let neighborhoodID = neighborhoodCache?.neighborhoodID(forNodeID: node.id) else {
            return Self.unattachedNeutral
        }
        let palette = Self.neighborhoodPalette
        let index = Int(stableHash(neighborhoodID) % UInt64(palette.count))
        return palette[index]
    }

    private func storedPosition(for nodeID: String) -> CGPoint {
        if let pos = positionMap[nodeID] {
            // canvas_layout uses SwiftUI convention (y-down from center).
            // SpriteKit uses y-up from center. Flip Y.
            return CGPoint(x: pos.x, y: -pos.y)
        }
        return CGPoint(
            x: CGFloat.random(in: -60...60),
            y: CGFloat.random(in: -60...60)
        )
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }

        // SB83c: Touch-down kills momentum unconditionally — every touch, no exceptions.
        coastVelocity = .zero
        panSamples.removeAll()
        momentumEligible = false

        // Resting state: no physics wake needed (continuous forces disabled)

        for touch in touches {
            activeTouches[touch] = touch.location(in: view)
        }

        if activeTouches.count == 1, let touch = touches.first {
            let screenPoint = touch.location(in: view)
            tapStartInfo = (screenPoint: screenPoint, time: CACurrentMediaTime())

            // Browse ≠ commit: no grace sub-machine. Every touch-down just starts a
            // tap candidate; a drag promotes to honeycomb (browse), a clean lift
            // taps (commit → card). The card itself is a SwiftUI overlay.
            gestureState = .tapCandidate(
                initialPosition: screenPoint,
                startTime: CACurrentMediaTime()
            )
        }

        if activeTouches.count >= 2 {
            let pts = Array(activeTouches.values)
            lastPinchDistance = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
            tapStartInfo = nil  // cancel tap if two fingers
            gestureState = .idle  // cancel honeycomb
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }

        let touchCount = activeTouches.count

        if touchCount == 1, let touch = touches.first {
            let current = touch.location(in: view)
            activeTouches[touch] = current

            // Honeycomb gesture state machine
            switch gestureState {
            case .tapCandidate(let initialPosition, _):
                // Check if drag threshold exceeded
                let dx = current.x - initialPosition.x
                let dy = current.y - initialPosition.y
                let distance = sqrt(dx * dx + dy * dy)

                if distance > dragThreshold {
                    // Browse = PAN only now (the engagement machine is retired; the
                    // annulus magnifies off camera.position every frame). RE-GRAZE
                    // DISMISS: starting a pan clears any open card.
                    if canvasState?.cardedNodeID != nil {
                        DispatchQueue.main.async { [weak self] in self?.canvasState?.cardedNodeID = nil }
                    }

                    // Transition to pan (honeycomb) mode
                    gestureState = .honeycomb(
                        initialPosition: initialPosition,
                        lastPanPosition: current
                    )
                    momentumEligible = true   // pan → coast-eligible
                    MapHaptics.prepareGraze()   // warm the browse-tick generator
                }

            case .honeycomb(let initialPosition, let lastPanPosition):
                // Apply pan to camera
                let panDx = (current.x - lastPanPosition.x) * panMultiplier
                let panDy = (current.y - lastPanPosition.y) * panMultiplier

                // Update camera position (inverted: drag right = pan left in scene)
                cameraNode.position.x -= panDx * cameraNode.xScale
                cameraNode.position.y += panDy * cameraNode.xScale  // y-inverted in SpriteKit

                // SB83c: Sample touch position into the 100ms ring buffer for velocity calc on release.
                let sampleTime = CACurrentMediaTime()
                panSamples.append((time: sampleTime, position: current))
                let cutoff = sampleTime - panSampleWindow
                panSamples.removeAll(where: { $0.time < cutoff })

                // Update state with new pan position
                gestureState = .honeycomb(
                    initialPosition: initialPosition,
                    lastPanPosition: current
                )

            default:
                break
            }

        } else if touchCount >= 2 {
            // Pinch: use stored previous distance, then update positions.
            let prevPinchDist = lastPinchDistance
            for touch in touches {
                activeTouches[touch] = touch.location(in: view)
            }
            let pts = Array(activeTouches.values)
            let dist = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
            if let prev = prevPinchDist, prev > 0 {
                // prevDist / currDist > 1 when pinching in → scale up camera (zoom out)
                let factor = prev / dist
                let newScale = (cameraNode.xScale * factor).clamped(to: 0.25...4.0)
                cameraNode.setScale(newScale)
                applyOrbScales()   // annulus + zoom ramp live with the pinch
            }
            lastPinchDistance = dist
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }

        defer {
            for touch in touches { activeTouches.removeValue(forKey: touch) }
            if activeTouches.isEmpty {
                lastPinchDistance = nil
                tapStartInfo = nil
            }
        }

        // Pan lift: launch momentum/coast from the windowed velocity, then idle.
        // Nothing to disengage — the annulus is persistent (per-frame off
        // camera.position), so nothing snaps back.
        if case .honeycomb(_, _) = gestureState {
            if let first = panSamples.first, let last = panSamples.last, momentumEligible {
                let dt = last.time - first.time
                if dt > 0 {
                    let vxPerFrame = ((last.position.x - first.position.x) / CGFloat(dt)) / 60.0
                    let vyPerFrame = ((last.position.y - first.position.y) / CGFloat(dt)) / 60.0
                    if hypot(vxPerFrame, vyPerFrame) >= coastLaunchThreshold {
                        coastVelocity = CGPoint(x: vxPerFrame, y: vyPerFrame)
                    }
                }
            }
            panSamples.removeAll()
            momentumEligible = false
            gestureState = .idle
            return
        }

        // Only evaluate tap if this is the last touch lifting
        guard activeTouches.count == 1,
              let touch = touches.first,
              let info = tapStartInfo else { return }

        let endPoint = touch.location(in: view)
        let duration = CACurrentMediaTime() - info.time
        let dist = hypot(endPoint.x - info.screenPoint.x, endPoint.y - info.screenPoint.y)

        guard duration < 0.3, dist < 14 else { return }

        // Convert screen point to scene coordinates (accounts for camera position + scale)
        let scenePoint = convertPoint(fromView: endPoint)

        // Check for double-tap (within 0.3s of last tap, within 30pt radius)
        let currentTime = CACurrentMediaTime()
        let timeSinceLastTap = currentTime - lastTapTime
        let distFromLastTap = hypot(scenePoint.x - lastTapLocation.x, scenePoint.y - lastTapLocation.y)
        let isDoubleTap = timeSinceLastTap < 0.3 && distFromLastTap < 30

        // Update last tap tracking
        lastTapTime = currentTime
        lastTapLocation = scenePoint

        if let shape = nodeSprites.values.first(where: { $0.contains(scenePoint) }),
                  let name = shape.name,
                  name.hasPrefix("node:") {
            let nodeID = String(name.dropFirst(5))

            // Selection mode: tap toggles, does not commit a card.
            if selection?.isActive == true {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.selection?.toggle(nodeID)
                    let nowPicked = self.selection?.isSelected(nodeID) ?? false
                    self.applySelectionOutline(nodeID: nodeID, isSelected: nowPicked)
                }
                return
            }

            // COMMIT: a clean tap on an orb morphs its CARD up. Reassigning while a
            // card is already up is a free NEIGHBOR-HOP (the morph re-points to the
            // new orb — no teardown). Card→detail + X + swipe live in the SwiftUI overlay.
            MapHaptics.commit()   // the set's "firmer grab" tick
            DispatchQueue.main.async { [weak self] in
                self?.canvasState?.cardedNodeID = nodeID
            }

        } else {
            // Tap on empty canvas
            if isDoubleTap && canvasState?.drilledInto != nil {
                // Double-tap on empty space while drilled in: exit drill-down (preserved)
                DispatchQueue.main.async { [weak self] in
                    self?.canvasState?.drilledInto = nil
                }
            } else if zoomedNodeID != nil {
                // Single tap: reset zoom (preserved for legacy zoom states)
                resetZoom()
            } else {
                // DISMISS: tap empty → clear the card (and any open detail selection).
                DispatchQueue.main.async { [weak self] in
                    self?.canvasState?.cardedNodeID = nil
                    self?.canvasState?.selectedNodeID = nil
                }
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches.removeValue(forKey: touch) }
        lastPinchDistance = nil
        tapStartInfo = nil
        gestureState = .idle   // nothing to disengage — the annulus is per-frame
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

