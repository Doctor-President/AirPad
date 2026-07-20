import SpriteKit
import UIKit
import simd

#if DEBUG
extension Notification.Name {
    /// Posted by the DEBUG `MapLabelTuningPanel` on every slider change; the
    /// scene observes it (added in `didMove`) and calls `restyleLabels()` so the
    /// node-label tier dial updates live on device. DEBUG-only.
    static let mapLabelTuningChanged = Notification.Name("map.label.tuningChanged")
}
#endif

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
        outline.strokeColor = .white
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
        territoryColors: [String: UIColor] = [:]
    ) {
        self.tagColors = tagColors
        self.territoryColors = territoryColors
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
        computeCharacteristicSpacing()
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

    /// Designed, distinct territory palette (colorblind-considered qualitative
    /// set; hex literals so it's verifiable per house rule). Assigned to
    /// territories by anchor order; the label pill stroke and member tint share
    /// the same entry so colour + name always pair.
    static let territoryPaletteHex: [String] = [
        "#4477AA", "#EE6677", "#228833", "#CCBB44", "#66CCEE", "#AA3377",
        "#EE7733", "#0099BB", "#DDCC77", "#882255", "#44AA99", "#BBBBBB"
    ]
    static let territoryPalette: [UIColor] = territoryPaletteHex.map { UIColor(hex: $0) ?? .gray }

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
        UIFont.systemFont(ofSize: size, weight: .semibold)
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

    private var territoryLabelData: [TerritoryLabel] = []
    /// True after we last wrote an empty territory-label set, so we clear the
    /// overlay once instead of every idle frame.
    private var lastTerritoryLabelsEmpty = true

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

    /// Shared diagonal wash — a circle-masked ramp from clear (top-leading) to
    /// translucent black (bottom-trailing), used as a child sprite over every
    /// node so each carries a subtle DIAGONAL gradient of its own shade (light →
    /// darker of the same hue). One texture for all nodes; circle mask keeps it
    /// inside the blob so no square corners spill. GPU-cheap (one texture sample).
    private lazy var nodeWashTexture: SKTexture = {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            c.addEllipse(in: CGRect(origin: .zero, size: size))
            c.clip()
            let colors = [UIColor.black.withAlphaComponent(0).cgColor,
                          UIColor.black.withAlphaComponent(0.38).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return }
            // Top-leading (clear) → bottom-trailing (dark). UIKit y-down, so start
            // top-left, end bottom-right = the requested diagonal.
            c.drawLinearGradient(grad,
                                 start: .zero,
                                 end: CGPoint(x: size.width, y: size.height),
                                 options: [])
        }
        return SKTexture(image: img)
    }()

    /// Light-mode ("Cucumber Water") wash ramp — the same circle-masked diagonal
    /// as `nodeWashTexture` but a FULL 0→1 alpha ramp. The per-node hue is applied
    /// via the wash sprite's `colorBlendFactor`/`color` (so only the alpha SHAPE
    /// matters here), and the wash-strength dial scales the sprite alpha over it —
    /// giving real depth range instead of the dark texture's fixed 0.38 ceiling.
    private lazy var nodeWashLightTexture: SKTexture = {
        let size = CGSize(width: 128, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            c.addEllipse(in: CGRect(origin: .zero, size: size))
            c.clip()
            let colors = [UIColor.black.withAlphaComponent(0).cgColor,
                          UIColor.black.withAlphaComponent(1.0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return }
            c.drawLinearGradient(grad,
                                 start: .zero,
                                 end: CGPoint(x: size.width, y: size.height),
                                 options: [])
        }
        return SKTexture(image: img)
    }()

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

    // SB83b: Grace-period double-tap tracking (single tap arms, second tap within window opens detail)
    private let doubleTapWindow: TimeInterval = 0.35
    private var lastGraceTapTime: TimeInterval = 0
    private var lastGraceTapNodeID: String? = nil

    // SB95.1: Set when a touch-down during grace lands on a node. Allows the touch to be
    // treated as a tap candidate (so a follow-up drag can resume engagement) while still
    // suppressing the default tap-on-node handler in touchesEnded so the grace-tap
    // double-tap-to-drill pattern stays intact.
    private var graceTapOnNodeSuppressLift: Bool = false

    // Honeycomb gesture state machine.
    // Note: grace period lives on `engagementState` only (single source of truth).
    private enum GestureState {
        case idle
        case tapCandidate(initialPosition: CGPoint, startTime: TimeInterval)
        case honeycomb(initialPosition: CGPoint, lastPanPosition: CGPoint)
    }

    private var gestureState: GestureState = .idle
    private let dragThreshold: CGFloat = 10.0
    // honeycomb-grazing-friction: shortened 1.0 → 0.5. Long enough to absorb
    // an accidental micro-lift, short enough that a deliberate release no
    // longer feels like quicksand.
    private let gracePeriodDuration: TimeInterval = 0.5
    // honeycomb-grazing-friction: if windowed finger speed at lift meets this
    // (screen px/sec), the lift was a graze-through, not a settle — skip grace
    // and disengage immediately. Tunable from device without a rebuild.
    private let decisiveGrazeVelocity: CGFloat = 600.0
    // honeycomb-grazing-friction: during gracePeriod, if a fresh touch-down
    // translates this far (screen pt) before settling into honeycomb, the user
    // is moving toward a different node — switch focal to the touch's nearest
    // node instead of resuming the lingering one. Below threshold = small
    // recovery move; resume old focal as before. Tunable from device.
    private let decisiveGrazeTranslation: CGFloat = 60.0
    private let panMultiplier: CGFloat = 1.5
    private let focalZPosition: CGFloat = 1000

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

    private var currentFocalNodeID: String? = nil

    /// Last appearance applied to the unfocused orbs, so `update` re-themes them
    /// only when the trait actually flips (light ↔ dark), not every frame. nil
    /// until the first tick (which forces an initial apply once the SKView trait
    /// is available; a no-op if no sprites exist yet — `makeShape` themes those).
    private var lastAppearanceIsLight: Bool? = nil
    /// The most recent focal node, kept around through preCollapse and
    /// disengaging so syncFocalToCanvasState can continue bridging its
    /// shrinking position and diameter to the SwiftUI gradient overlay while
    /// the overlay's opacity fades to 0. Cleared at disengaging → idle.
    private var lingerFocalNodeID: String? = nil
    /// Node currently rendering with the gradient shader (focal render state).
    /// Mutated only via `setFocalShader(to:)`.
    private var focalShaderID: String? = nil
    // SB96: Selection haptic for focal changes during engagement
    private let focalChangeHaptic = UISelectionFeedbackGenerator()
    private let navHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private var savedFocalZPositions: [String: CGFloat] = [:]

    // Engagement state (SB80b: hex grid + scale lens)
    private enum EngagementState {
        case idle
        case engaging(focal: String)
        case engaged(focal: String)
        case gracePeriod(focal: String, expiresAt: TimeInterval)
        case preCollapse(focal: String, startTime: TimeInterval)  // SB94: new
        case disengaging
    }

    private var engagementState: EngagementState = .idle

    /// Strand ring-target positions in the undistorted (substrate-resting)
    /// frame, keyed by neighbor nodeID. Populated on engaged-state entry +
    /// focal switch; cleared on `preCollapse` / honeycomb teardown. Bypasses
    /// the engaged-branch radial-compression target for any node in the dict.
    private var strandTargets: [String: CGPoint] = [:]

    /// Focal whose strand targets are currently in `strandTargets`. Used to
    /// detect focal-switch within engaged state and recompute the ring. nil
    /// when no ring is active (idle / preCollapse / disengaging).
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

    /// SB83g: True only during active engagement states. Focal-tracking during pan/disengage
    /// would otherwise mutate `currentFocalNodeID` and cause spurious grace entry on lift.
    private var isInActiveEngagement: Bool {
        switch engagementState {
        case .engaging, .engaged, .gracePeriod, .preCollapse: return true
        case .idle, .disengaging: return false
        }
    }

    /// Canonical resting fingerprint — target positions from the algorithmic layout.
    /// Captured at sprite creation, on layout recompute, and persists across engagement cycles.
    /// Never captured per-drag, never cleared on disengage.
    private var nodeRestingPositions: [String: CGPoint] = [:]

    /// Canonical resting fingerprint — target xScale (layout radius / intrinsic radius).
    private var nodeRestingScales: [String: CGFloat] = [:]

    /// Intrinsic (unscaled) sprite radius, captured once at creation. Pure value, never frame-derived.
    private var nodeIntrinsicRadii: [String: CGFloat] = [:]

    /// Median nearest-neighbor distance among fingerprint resting positions.
    /// Used to normalize euclidean distance for the sigmoid lens and radial compression
    /// so the lens behaves consistently across layouts of different densities.
    private var characteristicSpacing: CGFloat = 60.0

    // Screen-space scale lens (SB80b-fix2 — sigmoid math preserved; input is now
    // euclidean distance from focal normalized by `characteristicSpacing`)
    private let focalScreenFraction: CGFloat = 0.60       // focal diameter = 60% of screen width
    private let baselineScreenFraction: CGFloat = 0.09    // baseline diameter = 9% of screen width
    // Graze tuning dials — baked defaults, live-overridable from the Tuning
    // group (UserDefaults keys below). Cached here and refreshed once per frame
    // (`refreshGrazeTuning`) so the per-node lens reads a stored value, not
    // UserDefaults, on the hot path.
    private var scaleSigmoidSteepness: CGFloat = 3.0      // SB85 baseline
    private var scaleSigmoidMidpoint: CGFloat = 0.7       // SB85 baseline

    // Radial position compression
    private var positionCompressionStrength: CGFloat = 0.55  // 0 = no compression, 1 = all nodes at focal
    private let positionCompressionFalloff: CGFloat = 3.0    // normalized distance at which compression effect halves
    private let neighborBreathingGap: CGFloat = 8.0          // world-space gap between focal edge and neighbor edge

    // Lerp factors (preserved from SB80b)
    private let engagementLerp: CGFloat = 0.12
    private let steadyStateLerp: CGFloat = 0.20
    private let cameraFollowLerp: CGFloat = 0.10

    // SB92: Bounded-band relaxation for dense-region overlap cleanup
    private let relaxationBandWorldRadius: CGFloat = 480.0     // SB94: wider band at zoom-out — was 320
    private let relaxationPasses: Int = 8                       // SB94: more headroom for convergence — was 5
    private let relaxationBreathingGap: CGFloat = 6.0           // World-space baseline (made scale-aware below)

    // SB94: Pre-collapse phase — focal/amplified nodes relax slightly before full disengagement
    private let preCollapseDuration: TimeInterval = 0.18
    private let preCollapseScaleFactor: CGFloat = 0.92  // 8% scale-down
    private let preCollapseAmplifiedThreshold: CGFloat = 1.2  // Only nodes currently scaled > 1.2× resting participate
    // SB94: Starting scales for nodes participating in pre-collapse, captured at gracePeriod→preCollapse transition
    private var preCollapseStartScales: [String: CGFloat] = [:]

    // Convergence tolerances (preserved)
    private let positionMatchTolerance: CGFloat = 2.0
    private let scaleMatchTolerance: CGFloat = 0.05

    private var hysteresisThreshold: CGFloat = 20.0

    // SB92: Track per-focal-switch lerp ramp window
    private var focalSwitchTimestamp: TimeInterval? = nil
    private var focalSwitchSlowLerpDuration: TimeInterval = 0.15

    /// UserDefaults keys for the Graze tuning dials (shared with the SwiftUI
    /// Tuning group's `@AppStorage`). Baked defaults live on the properties
    /// above; a key is only read when the user has set it.
    private enum GrazeTuningKey {
        static let hysteresis = "graze.hysteresis"
        static let sigmoidSteepness = "graze.sigmoidSteepness"
        static let sigmoidMidpoint = "graze.sigmoidMidpoint"
        static let compression = "graze.compression"
        static let switchLerpDuration = "graze.switchLerpDuration"
    }

    /// Pull the live dial values into the cached properties. Called once per
    /// frame from `update` — cheap (5 UserDefaults reads), and keeps the
    /// per-node lens off UserDefaults. Absent key → keep the baked default.
    private func refreshGrazeTuning() {
        let d = UserDefaults.standard
        func tuned(_ key: String, _ fallback: CGFloat) -> CGFloat {
            d.object(forKey: key) == nil ? fallback : CGFloat(d.double(forKey: key))
        }
        hysteresisThreshold = tuned(GrazeTuningKey.hysteresis, 20.0)
        scaleSigmoidSteepness = tuned(GrazeTuningKey.sigmoidSteepness, 3.0)
        scaleSigmoidMidpoint = tuned(GrazeTuningKey.sigmoidMidpoint, 0.7)
        positionCompressionStrength = tuned(GrazeTuningKey.compression, 0.55)
        focalSwitchSlowLerpDuration = TimeInterval(tuned(GrazeTuningKey.switchLerpDuration, 0.15))
    }

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

        #if DEBUG
        // Device-pass node-label tier dial: re-raster every resting label when
        // the floating tuner writes new map.label.* values (mechanism-only in
        // Release; this observer + restyleLabels are DEBUG). De-dup the observer
        // in case didMove ever re-fires on the persistent scene.
        NotificationCenter.default.removeObserver(self, name: .mapLabelTuningChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLabelTuningChanged),
            name: .mapLabelTuningChanged, object: nil)
        #endif

        // Start shader animation clock
        shaderStartTime = CACurrentMediaTime()
        lastUpdateTime = shaderStartTime

        #if DEBUG
        // Synthetic-corpus batching measurement (SPRMeasure launch arg). Runs only
        // in the dedicated SPRMeasureView host, never the normal app.
        if UserDefaults.standard.bool(forKey: "SPRMeasure") {
            runSPRMeasure()
        }
        #endif
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if let grid = gridNode {
            BackgroundGridNode.resize(grid, to: size)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        if isPaused { return }

        #if DEBUG
        sprTickFPS(currentTime)
        #endif

        refreshGrazeTuning()  // pull live Graze dials into cached properties

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

        // Honeycomb gesture state updates
        switch gestureState {
        case .honeycomb(_, _) where isInActiveEngagement:
            // SB83g: Only track focal during active engagement. Pan/disengage gestures
            // must not mutate currentFocalNodeID — that would cause spurious grace on lift.
            // Track focal node (nearest to camera center) with hysteresis
            let newFocalID = findNearestNodeToCamera()
            if newFocalID != currentFocalNodeID {
                // Focal changed - capture old focal before updating
                let oldFocalID = currentFocalNodeID

                if let oldFocalID = oldFocalID, let oldSprite = nodeSprites[oldFocalID] {
                    // Restore original zPosition
                    if let savedZ = savedFocalZPositions[oldFocalID] {
                        oldSprite.zPosition = savedZ
                        savedFocalZPositions.removeValue(forKey: oldFocalID)
                    }
                }

                currentFocalNodeID = newFocalID
                setFocalShader(to: newFocalID)

                if let newFocalID = newFocalID, let newSprite = nodeSprites[newFocalID] {
                    // Save original zPosition before lifting
                    savedFocalZPositions[newFocalID] = newSprite.zPosition
                    newSprite.zPosition = focalZPosition

                    print("[Honeycomb] Focal: \(oldFocalID ?? "nil") → \(newFocalID)")
                    focalChangeHaptic.selectionChanged()  // SB96
                    focalChangeHaptic.prepare()             // SB96: re-prepare for next tick

                    // SB97.1: Swap textures — old focal back to non-focal, new focal to focal
                    if let oldFocalID = oldFocalID {
                        swapToNonFocalTexture(nodeID: oldFocalID)
                    }
                    swapToFocalTexture(nodeID: newFocalID)

                    // SB92: Mark focal-switch timestamp for lerp ramp
                    focalSwitchTimestamp = currentTime

                    // Update engagement state to new focal. Strand targets
                    // recompute when the engagement state machine sees the
                    // focal switch in its own branch — kept off this gesture
                    // path so the recompute trigger has a single source.
                    if case .engaged = engagementState {
                        engagementState = .engaged(focal: newFocalID)
                    } else if case .engaging = engagementState {
                        engagementState = .engaging(focal: newFocalID)
                    }
                }
            }

        default:
            break
        }

        // Engagement state machine: runs independently every frame (SB80b-fix2)
        switch engagementState {
        case .engaging(let focalID), .engaged(let focalID):
            guard let focalRestingPos = nodeRestingPositions[focalID],
                  let view = view else { break }

            // Strand targets: recompute on initial entry and on focal switch.
            // Single trigger point covers idle→engaging, engaging→engaged
            // (focalID is preserved across that transition), and mid-engagement
            // focal switches that reassign engagementState directly. Flag-off
            // is handled inside recomputeStrandTargets — clearing the dict.
            if focalID != lastStrandFocalID {
                recomputeStrandTargets(focalID: focalID, screenWidth: view.bounds.width)
                lastStrandFocalID = focalID
            }

            // Determine lerp factor based on state
            let lerpFactor: CGFloat
            if case .engaging = engagementState {
                lerpFactor = engagementLerp
            } else {
                if let switchTime = focalSwitchTimestamp,
                   currentTime - switchTime < focalSwitchSlowLerpDuration {
                    // SB92: Slow lerp briefly after a focal switch
                    lerpFactor = engagementLerp
                } else {
                    lerpFactor = steadyStateLerp
                }
            }

            // Track convergence for state transition
            var allPositionsConverged = true
            var allScalesConverged = true

            let screenWidth = view.bounds.width
            let cameraScale = cameraNode.xScale

            // Phase 1: Compute continuous-function targets for all nodes
            var targetPositions: [String: CGPoint] = [:]
            var targetScales: [String: CGFloat] = [:]

            for (nodeID, _) in nodeSprites {
                guard let restingPos = nodeRestingPositions[nodeID],
                      let intrinsicRadius = nodeIntrinsicRadii[nodeID],
                      intrinsicRadius > 0 else { continue }

                // Target position: fingerprint resting position pushed radially outward
                // from focal to make room for the focal's enlarged size.
                // Strand-ring members override with an undistorted ring slot —
                // strands sit outside the lens. PBD relaxation below resolves
                // any non-overlap against the override target.
                let targetPos: CGPoint
                if let ringTarget = strandTargets[nodeID] {
                    targetPos = ringTarget
                } else {
                    targetPos = applyRadialCompression(
                        nodePos: restingPos,
                        focalPos: focalRestingPos,
                        strength: positionCompressionStrength,
                        falloff: positionCompressionFalloff
                    )
                }

                // Target scale: screen-space sigmoid → world-space, divided by stable intrinsic.
                // `intrinsicRadius` is captured at sprite creation and never updated, so
                // positive feedback (lerp → frame.width → larger target) cannot accumulate.
                let dxWorld = restingPos.x - focalRestingPos.x
                let dyWorld = restingPos.y - focalRestingPos.y
                let worldDist = hypot(dxWorld, dyWorld)
                // SB93: Multiply by cameraScale so the amplified zone covers a consistent
                // screen-space radius around focal at any camera zoom level.
                let normalizedDist = (worldDist * cameraScale) / characteristicSpacing
                let targetScreenFraction = screenFractionForNormalizedDistance(normalizedDist)

                let targetScale: CGFloat
                // SB93: If the sigmoid has plateaued at baseline, use intrinsic scale (1.0)
                // so the outer field shrinks/grows naturally with the camera.
                // The 0.005 epsilon catches anything within ~10% of the baseline screen-fraction.
                let baselineEpsilon: CGFloat = 0.005
                if targetScreenFraction <= baselineScreenFraction + baselineEpsilon {
                    targetScale = 1.0
                } else {
                    let targetScreenDiameter = targetScreenFraction * screenWidth
                    let targetWorldRadius = (targetScreenDiameter / 2.0) * cameraScale
                    targetScale = targetWorldRadius / intrinsicRadius
                }

                targetPositions[nodeID] = targetPos
                targetScales[nodeID] = targetScale
            }

            // Phase 1.1 — Strand scale override. Strand members render at a
            // fraction of the focal's screen-space scale, so they read as
            // elevated against the dimmed corpus and stay sized consistently
            // across zoom levels (the focal already uses screen-space sigmoid
            // scaling, so multiplying its scale carries that property through).
            // Relative intrinsic sizing among strands is preserved — applying
            // the same scale multiplier to different intrinsic radii produces
            // proportionally different world sizes. Floored at resting scale
            // so a strand is never smaller than its plain corpus form.
            if !strandTargets.isEmpty, let focalScale = targetScales[focalID] {
                let strandMultiplier = StrandService.focalScaleMultiplier
                for strandID in strandTargets.keys {
                    guard targetScales[strandID] != nil else { continue }
                    let restingScale = nodeRestingScales[strandID] ?? 1.0
                    targetScales[strandID] = max(restingScale, strandMultiplier * focalScale)
                }
            }

            // Phase 1.5 — SB92: Bounded-band relaxation
            // Resolve overlaps in the band near focal. Far periphery is excluded
            // because compression falloff has died out and overlaps are rare.
            var relaxationSet: [String] = [focalID]
            for nodeID in nodeSprites.keys where nodeID != focalID {
                // SOLIDITY LAW: every body near focal is physical — strand-ring
                // members included — so radius-aware repulsion resolves any
                // overlap between a ring slot and a lens-compressed neighbor.
                // The ring target stays the attractor (reset each frame in
                // Phase 1); PBD only nudges on a real overlap, then it returns.
                if strandTargets[nodeID] != nil {
                    relaxationSet.append(nodeID)
                    continue
                }
                guard let restingPos = nodeRestingPositions[nodeID] else { continue }
                let dx = restingPos.x - focalRestingPos.x
                let dy = restingPos.y - focalRestingPos.y
                let worldDist = hypot(dx, dy)
                // SB93: Scale-aware relaxation band — covers a consistent screen-space region
                // regardless of camera zoom. At zoom-out, expands in world-space to match the
                // larger world-area visible on screen near focal; at zoom-in, contracts.
                let effectiveRelaxationBand = relaxationBandWorldRadius / max(cameraScale, 0.1)
                if worldDist < effectiveRelaxationBand {
                    relaxationSet.append(nodeID)
                }
            }

            // MORPH-TO-CARD solidity: once the focal morphs toward its card face,
            // its collision footprint becomes the card's 5:7 rounded rect (taller
            // than wide), so the crowd yields to the card's REAL shape instead of a
            // circle. 0 while it's still a bubble → the circle path below runs.
            let focalMorph = morphAmount(focalScaleProgress(for: focalID, isActive: true))
            let cardAspect: CGFloat = 1.4   // 5:7 portrait (height / width)

            for _ in 0..<relaxationPasses {
                var anyOverlap = false
                for i in 0..<relaxationSet.count {
                    let idA = relaxationSet[i]
                    guard let posA = targetPositions[idA],
                          let scaleA = targetScales[idA],
                          let intrinsicA = nodeIntrinsicRadii[idA] else { continue }
                    let radA = intrinsicA * scaleA

                    for j in (i + 1)..<relaxationSet.count {
                        let idB = relaxationSet[j]
                        guard let posB = targetPositions[idB],
                              let scaleB = targetScales[idB],
                              let intrinsicB = nodeIntrinsicRadii[idB] else { continue }
                        let radB = intrinsicB * scaleB

                        let aIsFocal = (idA == focalID)
                        let bIsFocal = (idB == focalID)

                        // SB94: Scale-aware breathing gap. Constant world-space gap shrinks to invisibility at zoom-out
                        // (6pt world × 0.25 cameraScale = 1.5pt screen). Divide by cameraScale so screen-space gap stays consistent.
                        let effectiveBreathingGap = relaxationBreathingGap / max(cameraScale, 0.1)

                        if (aIsFocal || bIsFocal) && focalMorph > 0.01 {
                            // Card AABB footprint — focal stays put; the other node
                            // yields out along its least-penetration axis.
                            let focalPos = aIsFocal ? posA : posB
                            let otherID  = aIsFocal ? idB : idA
                            let otherPos = aIsFocal ? posB : posA
                            let focalR   = aIsFocal ? radA : radB
                            let otherR   = aIsFocal ? radB : radA
                            let halfW = focalR + otherR + effectiveBreathingGap
                            let halfH = focalR * (1 + (cardAspect - 1) * focalMorph) + otherR + effectiveBreathingGap
                            let ddx = otherPos.x - focalPos.x
                            let ddy = otherPos.y - focalPos.y
                            let ox = halfW - abs(ddx)
                            let oy = halfH - abs(ddy)
                            if ox > 0 && oy > 0 {
                                anyOverlap = true
                                if ox <= oy {
                                    let s: CGFloat = ddx >= 0 ? 1 : -1
                                    targetPositions[otherID] = CGPoint(x: otherPos.x + s * ox, y: otherPos.y)
                                } else {
                                    let s: CGFloat = ddy >= 0 ? 1 : -1
                                    targetPositions[otherID] = CGPoint(x: otherPos.x, y: otherPos.y + s * oy)
                                }
                            }
                            continue
                        }

                        let required = radA + radB + effectiveBreathingGap
                        let dx = posB.x - posA.x
                        let dy = posB.y - posA.y
                        let actual = hypot(dx, dy)

                        if actual < required {
                            anyOverlap = true
                            let deficit = required - actual
                            let dirX: CGFloat
                            let dirY: CGFloat
                            if actual < 0.001 {
                                dirX = 1.0
                                dirY = 0.0
                            } else {
                                dirX = dx / actual
                                dirY = dy / actual
                            }

                            if aIsFocal {
                                targetPositions[idB] = CGPoint(
                                    x: posB.x + dirX * deficit,
                                    y: posB.y + dirY * deficit
                                )
                            } else if bIsFocal {
                                targetPositions[idA] = CGPoint(
                                    x: posA.x - dirX * deficit,
                                    y: posA.y - dirY * deficit
                                )
                            } else {
                                let half = deficit / 2.0
                                targetPositions[idA] = CGPoint(
                                    x: posA.x - dirX * half,
                                    y: posA.y - dirY * half
                                )
                                targetPositions[idB] = CGPoint(
                                    x: posB.x + dirX * half,
                                    y: posB.y + dirY * half
                                )
                            }
                        }
                    }
                }
                if !anyOverlap { break }
            }

            // Phase 3: Lerp toward targets and check convergence.
            // Alpha is no longer touched here — strand dimming runs via SKAction
            // at state transitions (see `applyStrandDimming` / `clearStrandDimming`).
            // Per-frame alpha writes here raced with `setFocalShader` and let the
            // focal's solid fill leak through behind the SwiftUI gradient overlay.
            for (nodeID, sprite) in nodeSprites {
                guard let targetPos = targetPositions[nodeID],
                      let targetScale = targetScales[nodeID] else { continue }

                // Lerp position
                let currentPos = sprite.position
                let dx = targetPos.x - currentPos.x
                let dy = targetPos.y - currentPos.y
                let lerpedPos = CGPoint(
                    x: currentPos.x + dx * lerpFactor,
                    y: currentPos.y + dy * lerpFactor
                )
                sprite.position = lerpedPos

                // Check position convergence
                if hypot(dx, dy) > positionMatchTolerance {
                    allPositionsConverged = false
                }

                // Lerp scale
                let currentScale = sprite.xScale
                let scaleDiff = targetScale - currentScale
                let lerpedScale = currentScale + scaleDiff * lerpFactor
                sprite.setScale(lerpedScale)

                // Check scale convergence
                if abs(scaleDiff) > scaleMatchTolerance {
                    allScalesConverged = false
                }

            }

            // Camera follow (engaged state only, not during engaging).
            // Focal stays at its own resting position — applyRadialCompression is a no-op
            // when nodePos == focalPos, so the focal's target equals its fingerprint pos.
            if case .engaged = engagementState {
                let camDx = focalRestingPos.x - cameraNode.position.x
                let camDy = focalRestingPos.y - cameraNode.position.y
                cameraNode.position = CGPoint(
                    x: cameraNode.position.x + camDx * cameraFollowLerp,
                    y: cameraNode.position.y + camDy * cameraFollowLerp
                )
            }

            // State transition: engaging → engaged
            if case .engaging = engagementState, allPositionsConverged && allScalesConverged {
                engagementState = .engaged(focal: focalID)
                print("[Honeycomb] State: engaging → engaged")
            }

        case .gracePeriod(let focalID, let expiresAt):
            // During grace: lens stays frozen at engaged target state.
            // engagementState owns grace expiry — gestureState no longer mirrors this.
            if currentTime >= expiresAt {
                print("[Honeycomb] State: gracePeriod → preCollapse")

                if let focalSprite = nodeSprites[focalID] {
                    if let savedZ = savedFocalZPositions[focalID] {
                        focalSprite.zPosition = savedZ
                        savedFocalZPositions.removeValue(forKey: focalID)
                    }
                }

                // SB94: Capture starting scales for amplified nodes only — these are the ones that will pre-collapse
                preCollapseStartScales.removeAll()
                for (nodeID, sprite) in nodeSprites {
                    guard let restingScale = nodeRestingScales[nodeID] else { continue }
                    let currentScale = sprite.xScale
                    let amplifiedRatio = currentScale / max(restingScale, 0.001)
                    if amplifiedRatio > preCollapseAmplifiedThreshold {
                        preCollapseStartScales[nodeID] = currentScale
                    }
                }

                engagementState = .preCollapse(focal: focalID, startTime: currentTime)
                lingerFocalNodeID = focalID
                currentFocalNodeID = nil
                setFocalShader(to: nil)
                strandTargets.removeAll()
                lastStrandFocalID = nil
                clearStrandDimming()
                restoreStrandZPositions()
            }

        case .preCollapse(_, let startTime):
            let elapsed = currentTime - startTime
            let progress = min(elapsed / preCollapseDuration, 1.0)
            let easedProgress = progress * progress * (3 - 2 * progress)  // smoothstep

            for (nodeID, sprite) in nodeSprites {
                guard let startingScale = preCollapseStartScales[nodeID] else { continue }
                let targetScale = startingScale * preCollapseScaleFactor
                let currentTargetScale = startingScale + (targetScale - startingScale) * easedProgress
                sprite.setScale(currentTargetScale)
            }

            if progress >= 1.0 {
                print("[Honeycomb] State: preCollapse → disengaging")
                engagementState = .disengaging
            }

        case .disengaging:
            var allPositionsConverged = true
            var allScalesConverged = true

            for (nodeID, sprite) in nodeSprites {
                guard let targetPos = nodeRestingPositions[nodeID],
                      let targetScale = nodeRestingScales[nodeID] else { continue }

                // Lerp toward canonical resting state (the layout's target fingerprint).
                let currentPos = sprite.position
                let dx = targetPos.x - currentPos.x
                let dy = targetPos.y - currentPos.y
                let lerpedPos = CGPoint(
                    x: currentPos.x + dx * engagementLerp,
                    y: currentPos.y + dy * engagementLerp
                )
                sprite.position = lerpedPos

                if hypot(dx, dy) > positionMatchTolerance {
                    allPositionsConverged = false
                }

                let currentScale = sprite.xScale
                let scaleDiff = targetScale - currentScale
                let lerpedScale = currentScale + scaleDiff * engagementLerp
                sprite.setScale(lerpedScale)

                if abs(scaleDiff) > scaleMatchTolerance {
                    allScalesConverged = false
                }

            }

            // State transition: disengaging → idle.
            // Do NOT clear nodeRestingPositions / nodeRestingScales — those are canonical
            // and persist across engagement cycles. Clearing them caused the next disengage
            // to skip every node and instantly transition without animating.
            if allPositionsConverged && allScalesConverged {
                engagementState = .idle
                focalSwitchTimestamp = nil  // SB92: Clean up focal-switch tracking
                preCollapseStartScales.removeAll()  // SB94: clean up
                lingerFocalNodeID = nil

                // SB97.1: Restore non-focal texture on any node still in focal state
                for (nodeID, shape) in nodeSprites {
                    if let sprite = shape.children.first(where: { $0.name == "titleLabel" }) as? SKSpriteNode,
                       let isFocal = sprite.userData?["isFocal"] as? Bool,
                       isFocal {
                        swapToNonFocalTexture(nodeID: nodeID)
                    }
                }

                print("[Honeycomb] State: disengaging → idle")
            }

        case .idle:
            break
        }

        syncFocalToCanvasState()
        syncClusterCentroidsToCanvasState()
        syncTerritoryLabelsToCanvasState()

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
    private func syncFocalToCanvasState() {
        guard let view = self.view else { return }
        // Prefer the active focal id; fall back to the lingering one so the
        // SwiftUI overlay can keep tracking the sprite as it shrinks back.
        let isActive = currentFocalNodeID != nil
        let trackedID = currentFocalNodeID ?? lingerFocalNodeID

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
                let progress = focalScaleProgress(for: trackedID, isActive: isActive)
                canvasState?.focalScaleProgress = progress
                canvasState?.focalMorph = morphAmount(progress)
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
    private func syncTerritoryLabelsToCanvasState() {
        guard let view = self.view else { return }
        MainActor.assumeIsolated {
            guard !territoryLabelData.isEmpty else {
                if !lastTerritoryLabelsEmpty {
                    canvasState?.territoryLabels = []
                    lastTerritoryLabelsEmpty = true
                }
                return
            }
            lastTerritoryLabelsEmpty = false

            var out: [CanvasState.TerritoryLabelInfo] = []
            out.reserveCapacity(territoryLabelData.count)
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
                let screen = view.convert(world, from: self)
                out.append(CanvasState.TerritoryLabelInfo(
                    key: label.key,
                    name: label.name,
                    colorHex: label.colorHex,
                    screenPosition: screen
                ))
            }
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

    /// Sigmoid scale falloff: focal large, smooth taper, asymptotic to baseline.
    /// Input is euclidean distance from focal divided by `characteristicSpacing`.
    /// Returns: target screen-space diameter as fraction of screen width.
    private func screenFractionForNormalizedDistance(_ x: CGFloat) -> CGFloat {
        // Logistic sigmoid: 1 at x=0, smoothly transitions to 0 as x grows past midpoint
        let sigmoid = 1.0 / (1.0 + exp(scaleSigmoidSteepness * (x - scaleSigmoidMidpoint)))
        // Map sigmoid output to range [baselineScreenFraction, focalScreenFraction]
        return baselineScreenFraction + (focalScreenFraction - baselineScreenFraction) * sigmoid
    }

    /// Push the node radially outward from focal so the focal's enlarged size has
    /// breathing room. Compression is exponential in normalized distance — close
    /// neighbors get pushed most, distant nodes barely move.
    private func applyRadialCompression(
        nodePos: CGPoint,
        focalPos: CGPoint,
        strength: CGFloat,
        falloff: CGFloat
    ) -> CGPoint {
        let dxWorld = nodePos.x - focalPos.x
        let dyWorld = nodePos.y - focalPos.y
        let worldDist = hypot(dxWorld, dyWorld)
        guard worldDist > 0.001 else { return nodePos }

        let normalizedDist = worldDist / characteristicSpacing
        let compressionFactor = strength * exp(-normalizedDist / falloff)
        let pushWorldDist = characteristicSpacing * compressionFactor

        let dirX = dxWorld / worldDist
        let dirY = dyWorld / worldDist

        return CGPoint(
            x: nodePos.x + dirX * pushWorldDist,
            y: nodePos.y + dirY * pushWorldDist
        )
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
    /// teardown (preCollapse / disengage / touch-cancelled).
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

    /// Compute median nearest-neighbor distance across all fingerprint resting positions.
    /// Sets `characteristicSpacing` so the sigmoid lens and radial compression are
    /// scale-invariant across layouts. Falls back to 60.0 if too few nodes exist.
    private func computeCharacteristicSpacing() {
        let positions = Array(nodeRestingPositions.values)
        guard positions.count > 1 else {
            characteristicSpacing = 60.0
            return
        }

        var nearestDistances: [CGFloat] = []
        nearestDistances.reserveCapacity(positions.count)
        for i in 0..<positions.count {
            var nearest: CGFloat = .infinity
            for j in 0..<positions.count where j != i {
                let dx = positions[i].x - positions[j].x
                let dy = positions[i].y - positions[j].y
                let d = hypot(dx, dy)
                if d < nearest { nearest = d }
            }
            if nearest.isFinite { nearestDistances.append(nearest) }
        }

        guard !nearestDistances.isEmpty else {
            characteristicSpacing = 60.0
            return
        }

        nearestDistances.sort()
        let mid = nearestDistances.count / 2
        let median: CGFloat
        if nearestDistances.count % 2 == 0 {
            median = (nearestDistances[mid - 1] + nearestDistances[mid]) / 2
        } else {
            median = nearestDistances[mid]
        }
        characteristicSpacing = max(median, 1.0)
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

    /// Find the node nearest to the camera center with hysteresis.
    ///
    /// Ranks by each node's TRUE HOME (`nodeRestingPositions`), NOT its displaced
    /// sprite position. During engagement the parting crowd pushes neighbour
    /// sprites radially outward; ranking by displaced positions moved switch
    /// targets away from the finger, so focus jittered and drifted off the node
    /// under the user's thumb. Resting homes are stable, so the focus decision
    /// tracks where the finger actually is — the crowd parts without changing who
    /// the finger is over. (Falls back to the sprite position pre-layout.)
    private func findNearestNodeToCamera() -> String? {
        let cameraCenter = cameraNode.position

        func homeDistance(_ nodeID: String) -> CGFloat {
            let home = nodeRestingPositions[nodeID] ?? nodeSprites[nodeID]?.position ?? cameraCenter
            let dx = home.x - cameraCenter.x
            let dy = home.y - cameraCenter.y
            return sqrt(dx * dx + dy * dy)
        }

        var nearestID: String? = nil
        var nearestDistance: CGFloat = .infinity
        for (nodeID, _) in nodeSprites {
            let distance = homeDistance(nodeID)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestID = nodeID
            }
        }

        // Apply hysteresis if there's a current focal
        if let currentID = currentFocalNodeID, nodeSprites[currentID] != nil {
            let currentDistance = homeDistance(currentID)

            // SB92: Scale-aware hysteresis for consistent screen-space behavior across zoom
            let effectiveHysteresis = hysteresisThreshold / max(cameraNode.xScale, 0.1)

            if let candidate = nearestID,
               candidate != currentID,
               nearestDistance < currentDistance - effectiveHysteresis {
                // New candidate is closer by more than effective hysteresis — switch
                return candidate
            } else {
                // Stay with current focal
                return currentID
            }
        } else {
            // No current focal — take the nearest
            return nearestID
        }
    }

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

        let body = SKPhysicsBody(circleOfRadius: radius)
        body.linearDamping = 0.6
        body.angularDamping = 0.8
        body.friction = 0.1
        body.restitution = 0.25
        body.mass = CGFloat(max(0.5, Float(radius / 30)))
        body.allowsRotation = false
        body.isDynamic = false  // Resting state: no continuous physics
        shape.physicsBody = body

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

        // Title label update — re-rasterize texture if title changed
        if let sprite = shape.children.first(where: { $0.name == "titleLabel" }) as? SKSpriteNode,
           let oldTitle = sprite.userData?["fullTitle"] as? String {
            let displayText = node.title.isEmpty ? (node.items.first?.content ?? "") : node.title
            if oldTitle != displayText {
                sprite.userData?["fullTitle"] = displayText
                let isFocal = (sprite.userData?["isFocal"] as? Bool) ?? false
                if isFocal {
                    sprite.userData?["isFocal"] = false
                    swapToFocalTexture(nodeID: node.id)
                } else {
                    sprite.userData?["isFocal"] = true
                    swapToNonFocalTexture(nodeID: node.id)
                }
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

    /// Light-mode ink for the orb stroke — the shipped light `AppearancePalette.ink`
    /// (`#232A2E`) resolved to a concrete UIColor (the scene is not SwiftUI, so it
    /// can't read the trait-dynamic Color directly).
    private static let lightInk: UIColor =
        UIColor(AppearancePalette.ink).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))

    /// Authoritative light/dark — PUSHED from SwiftUI's `@Environment(\.colorScheme)`
    /// by CanvasView (the same signal that drives AppearancePalette; never nil).
    /// Was read as `view?.traitCollection.userInterfaceStyle == .light`, but `view?`
    /// resolves nil during a re-formation re-render (Analyze / idle) → false → orbs
    /// took the DARK branch and lost transmission. A pushed bool can't be nil.
    /// Restyles on an actual flip so live theme changes still take.
    var appearanceIsLight: Bool = true {
        didSet { if oldValue != appearanceIsLight { restyleUnfocusedOrbs() } }
    }
    private var currentIsLight: Bool { appearanceIsLight }

    // Baked Cucumber Water (light) unfocused-orb wash — Tom's device-locked
    // values (the DEBUG tuner is retired). Single source in both configs; dark
    // reads none of these, so Solar Flare stays byte-identical.
    private static let cwPigment: CGFloat = 0.60          // fill dilution (parchment through)
    private static let cwWashStrength: CGFloat = 0.10     // diagonal hue-wash sprite alpha
    private static let cwWashBlend: SKBlendMode = .screen // wash composite
    private static let cwStrokeInk: CGFloat = 0.35        // ink stroke alpha

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

    /// Apply the unfocused-orb treatment to `shape` for `baseFill`.
    /// - DARK (Solar Flare): opaque fill (meta `0.55`) + black diagonal wash
    ///   (`.alpha`) + white@0.12 stroke — byte-identical to the shipped look.
    /// - LIGHT (Cucumber Water): fill diluted to `tuning.pigment` so the parchment
    ///   map ground shows through (pigment thinned into paper); the wash sprite
    ///   pools a translucent shade of the node's OWN hue (via `colorBlendFactor`)
    ///   at the dialed blend/strength; the near-invisible white stroke → low-alpha
    ///   ink. Never touches `shape.alpha` or `fillShader`, so focal/dimmed state
    ///   (set by `setFocalShader`) is preserved.
    private func styleUnfocusedOrb(_ node: SKNode,
                                   baseFill: UIColor,
                                   isMeta: Bool,
                                   isLight: Bool) {
        // Fill/stroke → per-node attributes on the shared-shader sprite orb.
        let metaAlpha: CGFloat = isMeta ? 0.55 : 1.0
        let fillAlpha = isLight ? metaAlpha * Self.cwPigment : metaAlpha
        let fill = baseFill.withAlphaComponent(fillAlpha)
        // Meta keeps its soft-purple rim in both rooms (reads on cream); only the
        // near-invisible white@0.12 non-meta stroke flips to ink.
        let stroke: UIColor = isMeta
            ? UIColor(red: 0.7, green: 0.5, blue: 1.0, alpha: 0.7)  // soft purple
            : (isLight ? Self.lightInk.withAlphaComponent(Self.cwStrokeInk)
                       : UIColor.white.withAlphaComponent(0.12))
        let lineWidth: CGFloat = isMeta ? 1.5 : 1.0

        if let sprite = node as? SKSpriteNode {
            setOrbSpriteAttributes(sprite, fill: fill, stroke: stroke,
                                   lineWidth: lineWidth, radius: sprite.size.width / 2)
        }

        // Diagonal wash child — deepen the node's own hue in light (screen 0.10);
        // black diagonal in dark (byte-identical Solar Flare).
        if let wash = node.childNode(withName: "wash") as? SKSpriteNode {
            if isLight {
                wash.texture = nodeWashLightTexture
                wash.colorBlendFactor = 1.0         // replace texture rgb with the hue shade
                wash.color = washHueShade(baseFill)
                wash.blendMode = Self.cwWashBlend
                wash.alpha = Self.cwWashStrength
            } else {
                // Solar Flare — the shipped wash: black diagonal, source-over, full.
                wash.texture = nodeWashTexture
                wash.colorBlendFactor = 0.0
                wash.color = .white                 // ignored at colorBlendFactor 0
                wash.blendMode = .alpha
                wash.alpha = 1.0
            }
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

    // MARK: - Sprite orb substrate (the sole unfocused-orb render path)

    /// ONE shared SKShader for every unfocused orb (created once, reused; NOT
    /// per-instance — that's the über anti-pattern that breaks batching). Renders
    /// an anti-aliased filled-circle SDF + inner stroke ring, colored PER NODE via
    /// SKAttributes (a_node_color / a_stroke_color / a_geom). Shared shader + shared
    /// texture + per-node attributes + `.ignoresSiblingOrder` collapse the orb fills
    /// to a handful of draws (sim-measured 2804→5; device-verified identical).
    private lazy var orbSpriteShader: SKShader = {
        let src = """
        void main() {
            vec2 p = v_tex_coord - vec2(0.5);
            float d = length(p);
            float R = 0.5;
            float aa = a_geom.y;          // ~1px feather (uv)
            float sw = a_geom.x;          // stroke width (uv)
            float disc = 1.0 - smoothstep(R - aa, R, d);
            float ring = clamp(smoothstep(R - sw - aa, R - sw, d) - smoothstep(R - aa, R, d), 0.0, 1.0);
            vec4 fillC = a_node_color;
            vec4 strokeC = a_stroke_color;
            float fa = disc * fillC.a;
            float sa = ring * strokeC.a;
            float outA = sa + fa * (1.0 - sa);
            vec3 outRGB = strokeC.rgb * sa + fillC.rgb * fa * (1.0 - sa);  // premultiplied, stroke over fill
            gl_FragColor = vec4(outRGB, outA);
        }
        """
        let shader = SKShader(source: src)
        shader.attributes = [
            SKAttribute(name: "a_node_color", type: .vectorFloat4),
            SKAttribute(name: "a_stroke_color", type: .vectorFloat4),
            SKAttribute(name: "a_geom", type: .vectorFloat2)
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
                                        stroke: UIColor, lineWidth: CGFloat, radius: CGFloat) {
        sprite.setValue(SKAttributeValue(vectorFloat4: Self.rgbaVec(fill)), forAttribute: "a_node_color")
        sprite.setValue(SKAttributeValue(vectorFloat4: Self.rgbaVec(stroke)), forAttribute: "a_stroke_color")
        let denom = Float(max(1, radius * 2))
        sprite.setValue(SKAttributeValue(vectorFloat2: vector_float2(Float(lineWidth) / denom, 1.0 / denom)),
                        forAttribute: "a_geom")
    }

    // MARK: - SPR measurement harness (DEBUG — synthetic corpus, Simulator-runnable)
    // Draw count is a CPU-side scene-graph fact (identical Sim vs device), so the
    // batching gate is settleable off-device. There's no public API for the GPU
    // draw count, so `draws` is read from the SKView HUD in a screenshot; nodes +
    // fps are logged. Reusable for any future node-perf spike.

    #if DEBUG
    private var sprLastUpdateTime: TimeInterval = 0
    private var sprSmoothedFPS: Double = 0

    /// Feed one frame delta into the smoothed fps (called from `update`).
    func sprTickFPS(_ currentTime: TimeInterval) {
        if sprLastUpdateTime > 0 {
            let dt = currentTime - sprLastUpdateTime
            if dt > 0 { sprSmoothedFPS = sprSmoothedFPS == 0 ? 1.0 / dt : sprSmoothedFPS * 0.9 + (1.0 / dt) * 0.1 }
        }
        sprLastUpdateTime = currentTime
    }

    /// Clearly-tagged counters line for CC to grep. `draws` is read from the HUD.
    func logSPRMeasure() {
        print(String(format: "[SPRMEASURE] nodes=%d fps=%.1f (draws: read from HUD in screenshot)",
                     nodeSprites.count, sprSmoothedFPS))
    }

    /// Data-independent synthetic corpus — `count` real orbs via `makeShape` (shared
    /// shader + wash child + z-order), each a DISTINCT hue (so per-node color
    /// delivery is eyeballable). Static (no physics) + inside the camera frame so
    /// nothing is culled. Reusable for future node-perf / EFFECT spikes.
    func injectSyntheticCorpus(count: Int) {
        cameraNode.position = .zero
        cameraNode.setScale(1.0)
        for (_, orb) in nodeSprites { orb.removeFromParent() }
        nodeSprites.removeAll()
        let hues: [CGFloat] = [0.0, 0.08, 0.16, 0.33, 0.5, 0.6, 0.75, 0.9]  // very distinct
        let halfW = (view?.bounds.width ?? 393) * 0.46
        let halfH = (view?.bounds.height ?? 852) * 0.46
        for i in 0..<count {
            let id = "synth-\(i)"
            let radius = CGFloat.random(in: 16...40)
            let color = UIColor(hue: hues[i % hues.count], saturation: 0.78, brightness: 0.92, alpha: 1)
            let orb = makeShape(radius: radius, fillColor: color, isMeta: false, nodeID: id)
            orb.name = "node:\(id)"
            orb.position = CGPoint(x: CGFloat.random(in: -halfW...halfW),
                                   y: CGFloat.random(in: -halfH...halfH))
            addChild(orb)
            nodeSprites[id] = orb
        }
    }

    /// Label-fit test spread — a 3×3 grid of TITLED orbs (short / long-multiword /
    /// single-long-word) at diameters 60/90/120, so mid-word truncation is
    /// eyeballable. Reached via `-SPRMeasure YES -SPRLabels YES`.
    func injectLabelTestSpread() {
        cameraNode.position = .zero
        cameraNode.setScale(1.0)
        for (_, orb) in nodeSprites { orb.removeFromParent() }
        nodeSprites.removeAll()
        let titles = ["Notes", "The Long Multi Word Title", "Geometric"]
        let radii: [CGFloat] = [30, 45, 60]   // diameters 60 / 90 / 120
        let colX: [CGFloat] = [-130, 0, 130]
        let rowY: [CGFloat] = [280, 0, -280]
        var i = 0
        for (r, radius) in radii.enumerated() {
            for (c, title) in titles.enumerated() {
                let id = "lbl-\(i)"; i += 1
                let fill = UIColor(hue: CGFloat(c) / 3.0, saturation: 0.45, brightness: 0.9, alpha: 1)
                let orb = makeShape(radius: radius, fillColor: fill, isMeta: false, nodeID: id)
                orb.name = "node:\(id)"
                orb.addChild(makeTitleSprite(text: title, radius: radius, fillColor: fill))
                orb.position = CGPoint(x: colX[c], y: rowY[r])
                addChild(orb)
                nodeSprites[id] = orb
            }
        }
    }

    /// `-SPRMeasure` entry (from `didMove`). Injects the synthetic corpus, then logs
    /// the READY marker after a few frames. `-SPRLight ON/OFF` forces the pushed
    /// `appearanceIsLight` for a controlled light/dark render (absent → sim trait).
    func runSPRMeasure() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            switch UserDefaults.standard.string(forKey: "SPRLight")?.uppercased() {
            case "ON":  self.appearanceIsLight = true
            case "OFF": self.appearanceIsLight = false
            default:    self.appearanceIsLight = (self.view?.traitCollection.userInterfaceStyle == .light)
            }
            if UserDefaults.standard.bool(forKey: "SPRLabels") {
                self.injectLabelTestSpread()
            } else {
                self.injectSyntheticCorpus(count: 700)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.logSPRMeasure()
                print("[SPRMEASURE] READY light=\(self.appearanceIsLight)")
            }
        }
    }
    #endif

    // MARK: - Helpers

    /// The unfocused orb — an SKSpriteNode running the shared SDF `orbSpriteShader`
    /// (filled circle + inner stroke ring, per-node color via SKAttributes) plus the
    /// diagonal wash child. This is the SOLE orb render path (promoted from the
    /// SKShapeNode spike). Über keeps its own `makeUberNodeShape` (SKShapeNode).
    /// Physics/label/name are attached by `addNodeSprite` (SKNode).
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

        // Diagonal wash child (z above the fill, below the title). Hidden
        // automatically when the parent goes alpha-0 focal.
        let wash = SKSpriteNode(texture: nodeWashTexture)
        wash.size = CGSize(width: radius * 2, height: radius * 2)
        wash.zPosition = 0.5
        wash.name = "wash"
        sprite.addChild(wash)

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

    /// AT17.3.4: Render title + summary into a square canvas, vertically centered.
    /// The texture is treated as an icon — same square dimensions regardless of text content.
    /// Long content truncates with ellipsis. The square is sized in the bubble's intrinsic
    /// coordinate space and scales with the parent shape.
    private func rasterizeSquareText(
        title: String,
        summary: String?,
        side: CGFloat,
        titleFont: UIFont,
        summaryFont: UIFont,
        renderScale: CGFloat,
        fillColor: UIColor,
        titleWrap: NSLineBreakMode = .byWordWrapping   // resolveTitle owns the fit; no mid-word cut
    ) -> SKTexture {
        let textWidth = side  // padding inside the square
        // Luminance-aware ink + soft halo, from the node's OWN fill — so the
        // resting title reads on a light node (dark ink) as well as a dark one
        // (light ink), and the halo separates it on mid-tones.
        // Ink-flip only — luminance-aware color, no baked halo (the NSShadow
        // muddied minified text). Clean minification comes from texture mipmaps.
        let (ink, _) = legibleInk(over: fillColor)
        func styled(_ text: String, _ font: UIFont, _ lineBreak: NSLineBreakMode) -> NSAttributedString {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = lineBreak
            return NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: para,
            ])
        }

        // Title label — wrap mode chosen by resolveTitle (word-boundary; the tier
        // loop already guaranteed the fit, so nothing is truncated mid-word here).
        let maxLines = LabelTuning.maxLines
        let titleLabel = UILabel()
        titleLabel.attributedText = styled(title, titleFont, titleWrap)
        titleLabel.numberOfLines = maxLines
        titleLabel.lineBreakMode = titleWrap
        let titleMaxHeight = titleFont.lineHeight * CGFloat(maxLines) + 4
        titleLabel.frame = CGRect(x: 0, y: 0, width: textWidth, height: titleMaxHeight)
        let titleFit = titleLabel.sizeThatFits(CGSize(width: textWidth, height: titleMaxHeight))
        let titleHeight = min(titleFit.height, titleMaxHeight)
        titleLabel.frame = CGRect(x: 0, y: 0, width: textWidth, height: titleHeight)

        // Summary label (optional)
        let spacing: CGFloat = side * 0.04
        var summaryLabel: UILabel? = nil
        var summaryHeight: CGFloat = 0
        if let summary, !summary.isEmpty {
            let s = UILabel()
            s.attributedText = styled(summary, summaryFont, .byTruncatingTail)
            s.numberOfLines = 4
            s.lineBreakMode = .byTruncatingTail
            let sMaxHeight = summaryFont.lineHeight * 4 + 4
            s.frame = CGRect(x: 0, y: 0, width: textWidth, height: sMaxHeight)
            let sFit = s.sizeThatFits(CGSize(width: textWidth, height: sMaxHeight))
            summaryHeight = min(sFit.height, sMaxHeight)
            s.frame = CGRect(x: 0, y: 0, width: textWidth, height: summaryHeight)
            summaryLabel = s
        }

        // Render into square canvas
        let canvasSize = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = renderScale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { ctx in
            let totalTextHeight = titleHeight + (summaryLabel != nil ? spacing + summaryHeight : 0)
            let yStart = (side - totalTextHeight) / 2.0
            let xStart = (side - textWidth) / 2.0

            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: xStart, y: yStart)
            titleLabel.layer.render(in: ctx.cgContext)
            ctx.cgContext.restoreGState()

            if let s = summaryLabel {
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: xStart, y: yStart + titleHeight + spacing)
                s.layer.render(in: ctx.cgContext)
                ctx.cgContext.restoreGState()
            }
        }

        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        texture.usesMipmaps = true   // clean minification when the sprite scales down
        return texture
    }

    // SB97.1: Rasterize title (and optional summary) into an SKTexture via UIKit.
    // SKLabelNode's text engine breaks mid-word at narrow widths; UILabel handles
    // word-wrap, shrink-to-fit, and subpixel positioning correctly.
    private func rasterizeText(
        title: String,
        summary: String?,
        bubbleDiameter: CGFloat,
        titleFont: UIFont,
        summaryFont: UIFont?,
        titleMaxLines: Int,
        summaryMaxLines: Int,
        renderScale: CGFloat
    ) -> SKTexture {
        let renderWidth = bubbleDiameter * 0.70
        let textColor = UIColor.white.withAlphaComponent(0.65)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = titleFont
        titleLabel.textColor = textColor
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.textAlignment = (summaryFont == nil) ? .center : .left
        let titleMaxHeight = titleFont.lineHeight * CGFloat(titleMaxLines) + 4
        titleLabel.frame = CGRect(x: 0, y: 0, width: renderWidth, height: titleMaxHeight)
        titleLabel.layoutIfNeeded()
        let titleFitSize = titleLabel.sizeThatFits(CGSize(width: renderWidth, height: titleMaxHeight))
        let titleHeight = min(titleFitSize.height, titleMaxHeight)
        titleLabel.frame = CGRect(x: 0, y: 0, width: renderWidth, height: titleHeight)
        titleLabel.layoutIfNeeded()

        let hasSummary = (summary?.isEmpty == false) && summaryFont != nil && summaryMaxLines > 0
        let spacing: CGFloat = 8
        var summaryLabel: UILabel? = nil
        var summaryHeight: CGFloat = 0
        if hasSummary, let sFont = summaryFont, let sText = summary {
            let s = UILabel()
            s.text = sText
            s.font = sFont
            s.textColor = textColor
            s.numberOfLines = summaryMaxLines
            s.lineBreakMode = .byTruncatingTail
            s.textAlignment = .left
            let sMaxHeight = sFont.lineHeight * CGFloat(summaryMaxLines) + 4
            s.frame = CGRect(x: 0, y: 0, width: renderWidth, height: sMaxHeight)
            s.layoutIfNeeded()
            let sFit = s.sizeThatFits(CGSize(width: renderWidth, height: sMaxHeight))
            summaryHeight = min(sFit.height, sMaxHeight)
            s.frame = CGRect(x: 0, y: 0, width: renderWidth, height: summaryHeight)
            s.layoutIfNeeded()
            summaryLabel = s
        }

        let totalHeight = titleHeight + (summaryLabel != nil ? spacing + summaryHeight : 0)
        let canvasSize = CGSize(width: renderWidth, height: max(totalHeight, 1))

        let format = UIGraphicsImageRendererFormat()
        // SB97.2: pixel density = renderScale × point size. Helper divides texture pixels
        // by renderScale to recover intrinsic point size in parent coord space.
        format.scale = renderScale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let image = renderer.image { ctx in
            titleLabel.frame = CGRect(x: 0, y: 0, width: renderWidth, height: titleHeight)
            titleLabel.layer.render(in: ctx.cgContext)
            if let s = summaryLabel {
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: 0, y: titleHeight + spacing)
                s.layer.render(in: ctx.cgContext)
                ctx.cgContext.restoreGState()
            }
        }

        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }

    /// SB97.2: Convert texture pixel dimensions back to the sprite's intrinsic visual size in the parent's coord space.
    /// The texture is rasterized at `bubbleDiameter * 1.4` width × renderScale multiplier of pixels.
    /// To display at intrinsic size, divide pixel size by renderScale.
    private func computeIntrinsicSpriteSize(
        texture: SKTexture,
        bubbleDiameter: CGFloat,
        renderScale: CGFloat
    ) -> CGSize {
        let textureSize = texture.size()
        return CGSize(
            width: textureSize.width / renderScale,
            height: textureSize.height / renderScale
        )
    }

    /// Node-label tier DIAL (taste — T tunes on device). Tier font sizes = box ×
    /// fraction, clamped to [floor, cap]. DEBUG reads UserDefaults (`map.label.*`,
    /// set by a device-pass panel); Release uses the baked defaults with ZERO
    /// UserDefaults access (the NodeCardView release-gate pattern). Sensible
    /// defaults; exact values are what T dials at the checkpoint.
    enum LabelTuning {
        static let defaultLargeFrac: CGFloat = 1.0 / 6.0
        static let defaultMedFrac:   CGFloat = 1.0 / 8.0
        static let defaultSmallFrac: CGFloat = 1.0 / 10.5
        static let defaultFloor:     CGFloat = 8
        static let defaultMaxLines:  Int = 2
        static let cap: CGFloat = 28   // absolute point ceiling

        #if DEBUG
        private static func frac(_ key: String, _ def: CGFloat) -> CGFloat {
            (UserDefaults.standard.object(forKey: key) as? Double).map { CGFloat($0) } ?? def
        }
        static var largeFrac: CGFloat { frac("map.label.largeFrac", defaultLargeFrac) }
        static var medFrac:   CGFloat { frac("map.label.medFrac", defaultMedFrac) }
        static var smallFrac: CGFloat { frac("map.label.smallFrac", defaultSmallFrac) }
        static var floor:     CGFloat { frac("map.label.floor", defaultFloor) }
        static var maxLines:  Int { (UserDefaults.standard.object(forKey: "map.label.maxLines") as? Int) ?? defaultMaxLines }
        #else
        static var largeFrac: CGFloat { defaultLargeFrac }
        static var medFrac:   CGFloat { defaultMedFrac }
        static var smallFrac: CGFloat { defaultSmallFrac }
        static var floor:     CGFloat { defaultFloor }
        static var maxLines:  Int { defaultMaxLines }
        #endif

        /// The 3 tier point sizes for a `box`-wide label, largest → smallest.
        static func tierSizes(box: CGFloat) -> [CGFloat] {
            [largeFrac, medFrac, smallFrac].map { min(cap, max(floor, box * $0)) }
        }
    }

    /// Resolve a node title into (font, renderText, wrapMode) with DISCRETE tiers
    /// and NO mid-word truncation. Tries the tier fonts LARGEST→smallest,
    /// word-wrapping the whole title into `box × maxLines`; returns the FIRST tier
    /// at which it fits with zero truncation (font steps DOWN rather than cutting).
    /// If even the smallest tier overflows: smallest tier + a WORD-boundary ellipsis
    /// (multi-word) or char-wrap of the whole word (single unbreakable word — every
    /// letter shown, no mid-word cut). Cache-safe: labels rasterize fresh per call.
    private func resolveTitle(_ text: String, box: CGFloat) -> (font: UIFont, text: String, wrap: NSLineBreakMode) {
        let maxLines = LabelTuning.maxLines
        let wordPara = NSMutableParagraphStyle()
        wordPara.lineBreakMode = .byWordWrapping
        func fits(_ s: String, _ f: UIFont) -> Bool {
            let b = (s as NSString).boundingRect(
                with: CGSize(width: box, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: f, .paragraphStyle: wordPara], context: nil)
            // width check catches a single word wider than the box (byWordWrapping
            // can't break it); height check catches multi-line overflow.
            return b.width <= box + 0.5 && b.height <= f.lineHeight * CGFloat(maxLines) + 1
        }
        let tiers = LabelTuning.tierSizes(box: box)
        for size in tiers {
            let f = CorpusPhysicsScene.mapLabelFont(size: size)
            if fits(text, f) { return (f, text, .byWordWrapping) }
        }
        // Overflow — render at the smallest tier.
        let f = CorpusPhysicsScene.mapLabelFont(size: tiers.last ?? LabelTuning.floor)
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        if words.count <= 1 {
            // Single (unbreakable) word — char-wrap the WHOLE word across lines.
            return (f, text, .byCharWrapping)
        }
        // Multi-word — drop trailing words until it fits, then append an ellipsis.
        var acc: [Substring] = []
        for w in words {
            if fits((acc + [w]).joined(separator: " ") + "…", f) { acc.append(w) } else { break }
        }
        if acc.isEmpty { return (f, String(words[0]), .byCharWrapping) }
        return (f, acc.joined(separator: " ") + "…", .byWordWrapping)
    }

    private func makeTitleSprite(text: String, radius: CGFloat, fillColor: UIColor) -> SKSpriteNode {
        // Rasterize in the node's ACTUAL display box (radius × 1.4), not a fixed
        // 84pt canvas scaled down — so the title lays out + renders at its real
        // on-screen size per node (1:1), instead of being wrapped for 84pt and
        // squished on small nodes.
        let side = radius * 1.4
        let (titleFont, renderTitle, titleWrap) = resolveTitle(text, box: side)
        let texture = rasterizeSquareText(
            title: renderTitle,
            summary: nil,
            side: side,
            titleFont: titleFont,
            summaryFont: titleFont,
            renderScale: 6.0,
            fillColor: fillColor,
            titleWrap: titleWrap
        )
        let sprite = SKSpriteNode(texture: texture)
        sprite.position = .zero
        sprite.zPosition = 2
        sprite.name = "titleLabel"
        sprite.userData = ["fullTitle": text, "isFocal": false]
        sprite.size = CGSize(width: side, height: side)
        return sprite
    }

    /// Focal text is NO LONGER rasterized into the sprite. The focal sprite is
    /// `alpha = 0` during engagement (see `setFocalShader`), so a scaled focal
    /// texture would never be seen — the title/summary render in the SwiftUI
    /// `focalEngagementOverlay` at final size instead. We only flag the sprite
    /// so its small non-focal texture is restored on release
    /// (`swapToNonFocalTexture`). The child keeps its non-focal texture, hidden
    /// by the parent's alpha throughout.
    private func swapToFocalTexture(nodeID: String) {
        guard let shape = nodeSprites[nodeID],
              let sprite = shape.children.first(where: { $0.name == "titleLabel" }) as? SKSpriteNode,
              let isFocal = sprite.userData?["isFocal"] as? Bool,
              !isFocal
        else { return }
        sprite.userData?["isFocal"] = true
    }

    private func swapToNonFocalTexture(nodeID: String) {
        guard let shape = nodeSprites[nodeID],
              let sprite = shape.children.first(where: { $0.name == "titleLabel" }) as? SKSpriteNode,
              let fullTitle = sprite.userData?["fullTitle"] as? String,
              let isFocal = sprite.userData?["isFocal"] as? Bool,
              isFocal,
              let radius = nodeIntrinsicRadii[nodeID]
        else { return }

        let side = radius * 1.4
        let (titleFont, renderTitle, titleWrap) = resolveTitle(fullTitle, box: side)

        let fillColor = currentNodes.first(where: { $0.id == nodeID }).map { bubbleColor(for: $0) } ?? .gray
        let texture = rasterizeSquareText(
            title: renderTitle,
            summary: nil,
            side: side,
            titleFont: titleFont,
            summaryFont: titleFont,
            renderScale: 6.0,
            fillColor: fillColor,
            titleWrap: titleWrap
        )
        sprite.texture = texture
        sprite.size = CGSize(width: side, height: side)
        sprite.userData?["isFocal"] = false
    }

    #if DEBUG
    @objc private func handleLabelTuningChanged() { restyleLabels() }

    /// Re-raster every resting node label from the CURRENT LabelTuning values so
    /// the device-pass tier dial (the floating `MapLabelTuningPanel`) shows live.
    /// Mirrors `swapToNonFocalTexture`'s raster path; skips focal sprites (they
    /// re-raster on release, which already reads the live tuning). DEBUG-only —
    /// nothing calls this in Release, where the baked defaults render once.
    func restyleLabels() {
        for (nodeID, shape) in nodeSprites {
            guard let sprite = shape.children.first(where: { $0.name == "titleLabel" }) as? SKSpriteNode,
                  (sprite.userData?["isFocal"] as? Bool) != true,
                  let fullTitle = sprite.userData?["fullTitle"] as? String,
                  let radius = nodeIntrinsicRadii[nodeID]
            else { continue }
            let side = radius * 1.4
            let (titleFont, renderTitle, titleWrap) = resolveTitle(fullTitle, box: side)
            let fillColor = currentNodes.first(where: { $0.id == nodeID }).map { bubbleColor(for: $0) } ?? .gray
            sprite.texture = rasterizeSquareText(
                title: renderTitle, summary: nil, side: side,
                titleFont: titleFont, summaryFont: titleFont,
                renderScale: 6.0, fillColor: fillColor, titleWrap: titleWrap)
            sprite.size = CGSize(width: side, height: side)
        }
    }
    #endif

    private func bubbleRadius(for node: Node) -> CGFloat {
        // Base diameter 60pt (radius 30), +8pt diameter per additional item (radius
        // +4), max diameter 120pt (radius 60). Shipped values, baked (Map tuner gone).
        let extra = CGFloat(max(0, node.items.count - 1)) * 4
        return min(30 + extra, 60)
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

            // Grace-period tap detection (touch-down for immediate response).
            // engagementState is the single source of truth for grace.
            if case .gracePeriod(let focalID, _) = engagementState {
                let scenePoint = convertPoint(fromView: screenPoint)

                // Permissive sprite-walk: any node hit registers a grace tap.
                if let shape = nodeSprites.values.first(where: { $0.contains(scenePoint) }),
                   let name = shape.name,
                   name.hasPrefix("node:") {
                    let tappedNodeID = String(name.dropFirst(5))
                    let now = CACurrentMediaTime()
                    let isDoubleTap = (tappedNodeID == lastGraceTapNodeID) &&
                                      (now - lastGraceTapTime < doubleTapWindow)

                    if isDoubleTap {
                        print("[Honeycomb] Grace double-tap on node \(tappedNodeID) → detail")
                        navHaptic.impactOccurred()
                        DispatchQueue.main.async { [weak self] in
                            self?.canvasState?.pendingNavigationNodeID = tappedNodeID
                        }
                        lastGraceTapNodeID = nil
                        lastGraceTapTime = 0
                        // Double-tap drilled in — no need to suppress lift handling, the
                        // navigation has already been queued.
                        graceTapOnNodeSuppressLift = false
                    } else {
                        print("[Honeycomb] Grace tap on node \(tappedNodeID) (awaiting second tap)")
                        lastGraceTapNodeID = tappedNodeID
                        lastGraceTapTime = now
                        // SB95.1: If the user lifts cleanly, suppress the default tap-on-node
                        // handler in touchesEnded so we don't fight the grace double-tap pattern.
                        graceTapOnNodeSuppressLift = true
                    }

                    // Stay in .gracePeriod with a fresh expiry so the second tap stays in window.
                    let newExpiresAt = now + gracePeriodDuration
                    engagementState = .gracePeriod(focal: focalID, expiresAt: newExpiresAt)

                    // SB95.1: Do NOT return early. Fall through to start a tapCandidate so that a
                    // follow-up drag during this grace window can promote to honeycomb and trigger
                    // the SB95 drag-resume path.
                } else {
                    // Empty-space tap during grace: fall through to tapCandidate so a follow-up
                    // drag can trigger the drag-during-grace re-engagement path.
                    graceTapOnNodeSuppressLift = false
                }
            } else {
                graceTapOnNodeSuppressLift = false
            }

            // Start tap candidate
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
                    // SB95.1: User is dragging — the touch is no longer a tap, so suppression no longer applies.
                    graceTapOnNodeSuppressLift = false
                    // SB95: Drag during grace RESUMES engagement instead of collapsing it.
                    // Lens scaffolding stays up, currentFocalNodeID is preserved, focal-tracking
                    // in update() takes over next frame. The user experiences continuous engagement
                    // across lift→re-touch→drag within the grace window.
                    //
                    // Otherwise (idle), engage the nearest node as the new focal.
                    if case .gracePeriod(let graceFocal, _) = engagementState {
                        // honeycomb-grazing-friction: a fresh touch + decisive
                        // drag during grace means the user is moving toward a
                        // different node, not recovering the same engagement.
                        // Switch focal to the touch-point's nearest node so the
                        // lingering focal releases as the new one engages.
                        var resumeFocalID = graceFocal
                        if distance > decisiveGrazeTranslation {
                            let scenePoint = self.convertPoint(fromView: current)
                            var bestID: String? = nil
                            var bestDistSq: CGFloat = .infinity
                            for (id, sprite) in nodeSprites {
                                let ndx = sprite.position.x - scenePoint.x
                                let ndy = sprite.position.y - scenePoint.y
                                let dSq = ndx * ndx + ndy * ndy
                                if dSq < bestDistSq {
                                    bestDistSq = dSq
                                    bestID = id
                                }
                            }
                            if let candidate = bestID { resumeFocalID = candidate }
                        }

                        if resumeFocalID != graceFocal,
                           let newSprite = nodeSprites[resumeFocalID] {
                            if let oldSprite = nodeSprites[graceFocal],
                               let savedZ = savedFocalZPositions[graceFocal] {
                                oldSprite.zPosition = savedZ
                                savedFocalZPositions.removeValue(forKey: graceFocal)
                            }
                            swapToNonFocalTexture(nodeID: graceFocal)

                            savedFocalZPositions[resumeFocalID] = newSprite.zPosition
                            newSprite.zPosition = focalZPosition
                            currentFocalNodeID = resumeFocalID
                            setFocalShader(to: resumeFocalID)
                            swapToFocalTexture(nodeID: resumeFocalID)
                            focalSwitchTimestamp = CACurrentMediaTime()
                            focalChangeHaptic.selectionChanged()
                            focalChangeHaptic.prepare()
                            print("[Honeycomb] Decisive grace move (dist=\(Int(distance))pt) — focal: \(graceFocal) → \(resumeFocalID)")
                        } else {
                            focalChangeHaptic.prepare()  // SB96
                            print("[Honeycomb] State: gracePeriod → engaged (drag resume)")
                        }
                        engagementState = .engaged(focal: resumeFocalID)
                    } else {
                        let focalID = findNearestNodeToCamera() ?? ""
                        engagementState = .engaging(focal: focalID)
                        focalChangeHaptic.prepare()  // SB96
                        print("[Honeycomb] State: idle → engaging(focal: \(focalID))")
                    }

                    // Transition to honeycomb mode
                    gestureState = .honeycomb(
                        initialPosition: initialPosition,
                        lastPanPosition: current
                    )

                    // SB83d: Any tapCandidate → honeycomb transition is pan-eligible
                    // (idle navigation OR grace-resume pan).
                    momentumEligible = true
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

        // Grace-period tap detection lives in touchesBegan (touch-down for immediate response).
        // Lifts during grace with no preceding drag are no-ops here.

        // Honeycomb: handle lift from honeycomb mode (SB80b-fix2: grace on every release)
        if case .honeycomb(_, _) = gestureState {
            // SB83d: Launch coast from windowed velocity. Eligibility is set at the
            // tapCandidate→honeycomb transition (always true for pan gestures).
            // honeycomb-grazing-friction: also compute lift speed (independent of
            // momentumEligible) to decide whether this lift was a decisive graze.
            var liftSpeedPerSec: CGFloat = 0
            if let first = panSamples.first, let last = panSamples.last {
                let dt = last.time - first.time
                if dt > 0 {
                    let vxPerSec = (last.position.x - first.position.x) / CGFloat(dt)
                    let vyPerSec = (last.position.y - first.position.y) / CGFloat(dt)
                    liftSpeedPerSec = hypot(vxPerSec, vyPerSec)
                    if momentumEligible {
                        let vxPerFrame = vxPerSec / 60.0
                        let vyPerFrame = vyPerSec / 60.0
                        if hypot(vxPerFrame, vyPerFrame) >= coastLaunchThreshold {
                            coastVelocity = CGPoint(x: vxPerFrame, y: vyPerFrame)
                        }
                    }
                }
            }
            panSamples.removeAll()
            momentumEligible = false

            let liftIsDecisiveGraze = liftSpeedPerSec >= decisiveGrazeVelocity

            if let focalID = currentFocalNodeID, !liftIsDecisiveGraze {
                print("[Honeycomb] Grace period entered for \(focalID)")

                // Enter grace period — owned by engagementState only. gestureState returns
                // to idle so the next touchesBegan starts a fresh tap candidate.
                let expiresAt = CACurrentMediaTime() + gracePeriodDuration
                engagementState = .gracePeriod(focal: focalID, expiresAt: expiresAt)
                gestureState = .idle
            } else {
                // honeycomb-grazing-friction: decisive-graze lift OR no focal —
                // disengage immediately. Movement at lift = unambiguous graze
                // signal; grace would only feel like the surface "holding on."
                if liftIsDecisiveGraze, let focalID = currentFocalNodeID {
                    print("[Honeycomb] Decisive graze lift (v=\(Int(liftSpeedPerSec)) px/s, focal=\(focalID)) → disengaging")
                } else {
                    print("[Honeycomb] State: engaged → disengaging")
                }
                engagementState = .disengaging
                gestureState = .idle
                currentFocalNodeID = nil
                setFocalShader(to: nil)
                strandTargets.removeAll()
                lastStrandFocalID = nil
                clearStrandDimming()
                restoreStrandZPositions()
            }
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

            // Selection mode: tap toggles, does not open detail.
            if selection?.isActive == true {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.selection?.toggle(nodeID)
                    let nowPicked = self.selection?.isSelected(nodeID) ?? false
                    self.applySelectionOutline(nodeID: nodeID, isSelected: nowPicked)
                }
                graceTapOnNodeSuppressLift = false
                return
            }

            // SB95.1: If this lift is the clean release of a grace-tap-on-node, the grace-tap
            // logic in touchesBegan already handled it (set lastGraceTapNodeID, refreshed expiry).
            // Suppress the default selectedNodeID side effect to avoid fighting the grace
            // double-tap-to-drill pattern.
            if graceTapOnNodeSuppressLift {
                graceTapOnNodeSuppressLift = false
            } else {
                // Single-tap on node: open NodeDetailView
                DispatchQueue.main.async { [weak self] in
                    self?.canvasState?.selectedNodeID = nodeID
                }
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
                // Single tap on empty: dismiss any open detail (preserved)
                DispatchQueue.main.async { [weak self] in
                    self?.canvasState?.selectedNodeID = nil
                }
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches.removeValue(forKey: touch) }
        lastPinchDistance = nil
        tapStartInfo = nil
        graceTapOnNodeSuppressLift = false

        // Clean up honeycomb state
        if case .honeycomb(_, _) = gestureState {
            // Transition to disengaging
            engagementState = .disengaging
            strandTargets.removeAll()
            lastStrandFocalID = nil
            clearStrandDimming()
            restoreStrandZPositions()

            if let focalID = currentFocalNodeID, let focalSprite = nodeSprites[focalID] {
                let scaleDown = SKAction.scale(to: 1.0, duration: 0.3)
                scaleDown.timingMode = .easeOut
                focalSprite.run(scaleDown)

                // Restore original zPosition
                if let savedZ = savedFocalZPositions[focalID] {
                    focalSprite.zPosition = savedZ
                    savedFocalZPositions.removeValue(forKey: focalID)
                }
                lingerFocalNodeID = focalID
            }
            currentFocalNodeID = nil
            setFocalShader(to: nil)
            preCollapseStartScales.removeAll()  // SB94
        }
        gestureState = .idle
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

