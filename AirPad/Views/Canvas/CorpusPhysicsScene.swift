import SpriteKit
import UIKit
import simd

// MARK: - Hex Coordinate System (SB80a)

/// Axial hex coordinate (pointy-top orientation)
struct HexCoord: Hashable {
    let q: Int
    let r: Int
}

/// Convert axial hex coordinate to world position
func hexToWorld(_ coord: HexCoord, cellSize: CGFloat) -> CGPoint {
    let x = cellSize * sqrt(3.0) * (CGFloat(coord.q) + CGFloat(coord.r) / 2.0)
    let y = cellSize * 1.5 * CGFloat(coord.r)
    return CGPoint(x: x, y: y)
}

/// Manhattan distance between two hex coordinates
func hexDistance(_ a: HexCoord, _ b: HexCoord) -> Int {
    let dq = a.q - b.q
    let dr = a.r - b.r
    return (abs(dq) + abs(dr) + abs(dq + dr)) / 2
}

/// The SpriteKit physics canvas that renders nodes as floating bubbles.
/// Owned by CanvasView; communicates selection events back via CanvasState.
final class CorpusPhysicsScene: SKScene {

    // MARK: - Public interface

    /// Set by CanvasView so the scene can report tap events.
    var canvasState: CanvasState?

    var spriteCount: Int { nodeSprites.count }

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

    /// Toggle hex layout debug visualization (SB80a-fix5)
    func toggleHexDebugMode() {
        debugShowHexLayout.toggle()

        if debugShowHexLayout {
            // Snapshot current sprite state BEFORE applying hex transformations
            preHexSnapshot.removeAll()
            for (nodeID, sprite) in nodeSprites {
                preHexSnapshot[nodeID] = (
                    position: sprite.position,
                    scale: sprite.xScale
                )
            }

            print("[Hex Debug] Enabled — snapshotted \(preHexSnapshot.count) sprites, applying hex layout")

            for (nodeID, sprite) in nodeSprites {
                sprite.physicsBody?.isDynamic = false

                // Position: hex coord → world space
                if let hexCoord = nodeHexCoords[nodeID] {
                    sprite.position = hexToWorld(hexCoord, cellSize: hexCellSize)
                }

                // Size: uniform baseline (fixed world-space)
                if let intrinsicRadius = nodeIntrinsicRadii[nodeID], intrinsicRadius > 0 {
                    sprite.setScale(hexBaselineRadius / intrinsicRadius)
                }
            }
        } else {
            print("[Hex Debug] Disabled — restoring \(preHexSnapshot.count) sprites from snapshot")

            for (nodeID, sprite) in nodeSprites {
                sprite.physicsBody?.isDynamic = true

                if let snapshot = preHexSnapshot[nodeID] {
                    sprite.position = snapshot.position
                    sprite.setScale(snapshot.scale)
                } else {
                    // Fallback if snapshot missing (e.g., sprite added during hex mode)
                    if let pos = positionMap[nodeID] {
                        sprite.position = CGPoint(x: pos.x, y: -pos.y)
                    }
                    sprite.setScale(nodeRestingScales[nodeID] ?? 1.0)
                }
            }

            preHexSnapshot.removeAll()
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
        nodeRadii: [String: CGFloat] = [:]
    ) {
        self.tagColors = tagColors
        positionMap = layoutPositions
        self.neighborhoodCache = neighborhoodCache
        self.nodeRadii = nodeRadii
        self.currentNodes = nodes  // Cache for relatedness computation

        // Reset label tier to force re-evaluation on next update() frame
        currentLabelTier = -1

        // Recompute hex layout when neighborhood structure changes (SB80a)
        if neighborhoodCache != nil {
            computeNeighborhoodHexLayout()
        }

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
    }

    // MARK: - Private state

    private var cameraNode = SKCameraNode()
    private var nodeSprites: [String: SKShapeNode] = [:]
    var uberNodeSprites: [String: SKShapeNode] = [:]  // Accessed by CanvasView for drill-down
    private var positionMap: [String: CanvasPosition] = [:]

    private var tagColors: [String: UIColor] = [:]
    private var neighborhoodCache: NeighborhoodCache? = nil
    private var nodeRadii: [String: CGFloat] = [:]

    // MARK: - Hex grid state (SB80a-fix6: world-space, single coordinate system)

    private var nodeHexCoords: [String: HexCoord] = [:]

    /// Fixed world-space cell size for the hex grid. Matches the natural
    /// nearest-neighbor density of the algorithmic resting layout.
    private let hexCellSize: CGFloat = 60.0

    /// Fixed world-space radius for nodes in hex view. Sized to fit
    /// comfortably within hexCellSize spacing.
    private let hexBaselineRadius: CGFloat = 22.0  // ~37% of cell size

    private var debugShowHexLayout: Bool = false  // Toggle for debug visualization

    /// Snapshot of sprite state captured before hex debug mode is entered.
    /// Used to cleanly restore on exit. Cleared on exit.
    private var preHexSnapshot: [String: (position: CGPoint, scale: CGFloat)] = [:]

    // Strand layer state
    private var focalNodeID: String? = nil
    private var strandLayer: SKNode? = nil
    private let relatednessService = RelatednessService()
    private var currentNodes: [Node] = []  // Cached for relatedness computation

    // Zoom state
    private var originalCameraPosition: CGPoint = .zero
    private var originalCameraScale: CGFloat = 1.0
    private var zoomedNodeID: String? = nil
    private var savedPhysicsBody: SKPhysicsBody? = nil
    private var savedZPosition: CGFloat = 0

    // Label tier state (for zoom-aware visibility)
    private var currentLabelTier: Int = -1

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

    // Honeycomb gesture state machine.
    // Note: grace period lives on `engagementState` only (single source of truth).
    private enum GestureState {
        case idle
        case tapCandidate(initialPosition: CGPoint, startTime: TimeInterval)
        case honeycomb(initialPosition: CGPoint, lastPanPosition: CGPoint)
    }

    private var gestureState: GestureState = .idle
    private let dragThreshold: CGFloat = 10.0
    private let holdThreshold: TimeInterval = 0.7
    private let gracePeriodDuration: TimeInterval = 2.0  // SB80b-fix2: bumped from 1.5
    private let panMultiplier: CGFloat = 1.5
    private let focalZPosition: CGFloat = 1000

    private var currentFocalNodeID: String? = nil
    private var holdTimerStart: TimeInterval? = nil
    private var holdCompleted: Bool = false
    private var driftedRelatedIDs: [String: CGPoint] = [:]
    private var gracePromptLabel: SKLabelNode? = nil
    private var savedFocalZPositions: [String: CGFloat] = [:]

    // Engagement state (SB80b: hex grid + scale lens)
    private enum EngagementState {
        case idle
        case engaging(focal: String)
        case engaged(focal: String)
        case gracePeriod(focal: String, expiresAt: TimeInterval)
        case disengaging
    }

    private var engagementState: EngagementState = .idle

    /// Canonical resting fingerprint — target positions from the algorithmic layout.
    /// Captured at sprite creation, on layout recompute, and persists across engagement cycles.
    /// Never captured per-drag, never cleared on disengage.
    private var nodeRestingPositions: [String: CGPoint] = [:]

    /// Canonical resting fingerprint — target xScale (layout radius / intrinsic radius).
    private var nodeRestingScales: [String: CGFloat] = [:]

    /// Intrinsic (unscaled) sprite radius, captured once at creation. Pure value, never frame-derived.
    private var nodeIntrinsicRadii: [String: CGFloat] = [:]

    private var driftExcludedIDs: Set<String> = []

    // Screen-space scale lens (SB80b-fix2)
    private let focalScreenFraction: CGFloat = 0.60       // focal diameter = 60% of screen width
    private let baselineScreenFraction: CGFloat = 0.09    // baseline diameter = 9% of screen width
    private let scaleSigmoidSteepness: CGFloat = 3.0      // steeper = sharper focal-to-neighbor drop
    private let scaleSigmoidMidpoint: CGFloat = 0.7       // hex distance at which curve is at midpoint

    // Radial position compression
    private let positionCompressionStrength: CGFloat = 0.55  // 0 = no compression, 1 = all nodes at focal
    private let positionCompressionFalloff: CGFloat = 3.0    // hex distance at which compression effect halves
    private let neighborBreathingGap: CGFloat = 8.0          // world-space gap between focal edge and neighbor edge

    // Lerp factors (preserved from SB80b)
    private let engagementLerp: CGFloat = 0.30
    private let steadyStateLerp: CGFloat = 0.20
    private let cameraFollowLerp: CGFloat = 0.10

    // Convergence tolerances (preserved)
    private let positionMatchTolerance: CGFloat = 2.0
    private let scaleMatchTolerance: CGFloat = 0.05

    private let hysteresisThreshold: CGFloat = 20.0

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

    // MARK: - Blob displacement state

    /// Displacement amplitude (0 = perfect circle, 1 = full deformation)
    private var displacementAmplitude: Float = 0.15
    /// Displacement speed multiplier (affects breath rate)
    private var displacementSpeed: Float = 1.0
    /// Canvas-wide noise frequency (lower = slower ambient waves)
    private var canvasNoiseFrequency: Float = 0.5
    /// Per-node deformation intensity (0-1)
    private var nodeDeformIntensity: Float = 1.0
    /// Per-node phase offsets (randomized on init so nodes breathe differently)
    private var nodePhaseOffsets: [String: Float] = [:]

    // MARK: - Scene lifecycle

    override func didMove(to view: SKView) {
        self.isPaused = false
        backgroundColor = .clear
        physicsWorld.gravity = .zero
        physicsWorld.speed = 1.0

        // Camera
        addChild(cameraNode)
        camera = cameraNode

        // Large boundary so nodes don't escape to infinity
        let boundary = CGRect(x: -1500, y: -1500, width: 3000, height: 3000)
        physicsBody = SKPhysicsBody(edgeLoopFrom: boundary)

        view.isMultipleTouchEnabled = true

        // Strand layer (below sprites)
        strandLayer = SKNode()
        strandLayer?.zPosition = -1
        addChild(strandLayer!)

        // Start shader animation clock
        shaderStartTime = CACurrentMediaTime()
        lastUpdateTime = shaderStartTime
    }

    override func update(_ currentTime: TimeInterval) {
        if isPaused { return }
        let elapsed = currentTime - shaderStartTime
        nodeFillShader.uniforms.first(where: { $0.name == "u_time" })?.floatValue = Float(elapsed)

        // Über-node shader updates disabled (sprites not rendered)
        // for (_, shape) in uberNodeSprites {
        //     shape.fillShader?.uniforms.first(where: { $0.name == "u_time" })?.floatValue = Float(elapsed)
        // }

        // SB80a-fix6: Debug hex layout visualization (per-frame, world-space)
        if debugShowHexLayout {
            for (nodeID, sprite) in nodeSprites {
                sprite.physicsBody?.isDynamic = false

                // Position: hex coord → world space (fixed cell size)
                if let hexCoord = nodeHexCoords[nodeID] {
                    sprite.position = hexToWorld(hexCoord, cellSize: hexCellSize)
                }

                // Size: uniform baseline (fixed world-space) — pure math, no frame reads.
                if let intrinsicRadius = nodeIntrinsicRadii[nodeID], intrinsicRadius > 0 {
                    sprite.setScale(hexBaselineRadius / intrinsicRadius)
                }
            }
            return  // Skip normal update logic
        }

        let scale = cameraNode.xScale
        let tier: Int = scale > 1.5 ? 0 : scale >= 0.8 ? 1 : 2

        currentLabelTier = tier
        applyLabelTier(tier)

        // Update newcomer halos
        if enableNewcomerHalo {
            updateNewcomerHalos(currentTime: currentTime)
        }

        // Update strand paths if focal node is set
        if let focalID = focalNodeID, let focalSprite = nodeSprites[focalID] {
            for strand in strandLayer?.children ?? [] {
                guard let line = strand as? SKShapeNode,
                      let relatedID = line.userData?["relatedID"] as? String,
                      let relatedSprite = nodeSprites[relatedID] else { continue }
                let path = CGMutablePath()
                path.move(to: focalSprite.position)
                path.addLine(to: relatedSprite.position)
                line.path = path
            }
        }

        // Honeycomb gesture state updates
        switch gestureState {
        case .honeycomb(_, _):
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

                if let newFocalID = newFocalID, let newSprite = nodeSprites[newFocalID] {
                    // Save original zPosition before lifting
                    savedFocalZPositions[newFocalID] = newSprite.zPosition
                    newSprite.zPosition = focalZPosition

                    print("[Honeycomb] Focal: \(oldFocalID ?? "nil") → \(newFocalID)")

                    // Update engagement state to new focal (scale field will redistribute, positions stay rigid)
                    if case .engaged = engagementState {
                        engagementState = .engaged(focal: newFocalID)
                    } else if case .engaging = engagementState {
                        engagementState = .engaging(focal: newFocalID)
                    }

                    // Reset hold timer and completion flag
                    holdTimerStart = currentTime
                    holdCompleted = false

                    // Clear strands if any
                    clearStrands()

                    // Unwind drift if any
                    unwindDrift()
                }
            } else if let focalID = currentFocalNodeID, let startTime = holdTimerStart {
                // Same focal - check hold threshold
                if currentTime - startTime >= holdThreshold {
                    // Hold threshold reached
                    print("[Honeycomb] Hold threshold reached for \(focalID) — rendering strands + drift")

                    // Render strands
                    setFocalNode(focalID)

                    // Start drift
                    if let focalSprite = nodeSprites[focalID] {
                        let related = relatednessService.topRelated(
                            forNodeID: focalID,
                            in: currentNodes,
                            limit: 5
                        )
                        let relatedIDs = related.map { $0.0 }
                        startDrift(towardFocalID: focalID, relatedIDs: relatedIDs)
                    }

                    // Mark hold as completed
                    holdCompleted = true

                    // Reset timer to prevent re-triggering
                    holdTimerStart = nil
                }
            }

        default:
            break
        }

        // Engagement state machine: runs independently every frame (SB80b-fix2)
        switch engagementState {
        case .engaging(let focalID), .engaged(let focalID):
            guard let focalCoord = nodeHexCoords[focalID],
                  let view = view else { break }

            // Determine lerp factor based on state
            let lerpFactor: CGFloat
            if case .engaging = engagementState {
                lerpFactor = engagementLerp
            } else {
                lerpFactor = steadyStateLerp
            }

            // Track convergence for state transition
            var allPositionsConverged = true
            var allScalesConverged = true

            let screenWidth = view.bounds.width
            let cameraScale = cameraNode.xScale

            // Apply hex grid positions + screen-space scale lens + radial compression
            for (nodeID, sprite) in nodeSprites {
                guard !driftExcludedIDs.contains(nodeID),
                      let nodeCoord = nodeHexCoords[nodeID],
                      let intrinsicRadius = nodeIntrinsicRadii[nodeID],
                      intrinsicRadius > 0 else { continue }

                // Target position: compressed hex position (radial pull toward focal)
                let targetPos = compressedHexPosition(nodeCoord: nodeCoord, focalCoord: focalCoord)

                // Target scale: screen-space sigmoid → world-space, divided by stable intrinsic.
                // No frame-derived reads — `intrinsicRadius` is captured at sprite creation
                // and never updated, so positive feedback (lerp → frame.width → larger target)
                // cannot accumulate.
                let hexDist = hexDistance(focalCoord, nodeCoord)
                let targetScreenDiameter = screenWidth * screenFractionForHexDistance(hexDist)
                let targetWorldRadius = (targetScreenDiameter / 2.0) * cameraScale
                let targetScale = targetWorldRadius / intrinsicRadius

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

            // Camera follow (engaged state only, not during engaging)
            if case .engaged = engagementState {
                let focalWorldPos = compressedHexPosition(nodeCoord: focalCoord, focalCoord: focalCoord)
                let camDx = focalWorldPos.x - cameraNode.position.x
                let camDy = focalWorldPos.y - cameraNode.position.y
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
            // During grace: hex grid stays frozen at engaged target state.
            // engagementState owns grace expiry — gestureState no longer mirrors this.
            if currentTime >= expiresAt {
                print("[Honeycomb] State: gracePeriod → disengaging")

                clearStrands()
                unwindDrift()

                if let focalSprite = nodeSprites[focalID] {
                    if let savedZ = savedFocalZPositions[focalID] {
                        focalSprite.zPosition = savedZ
                        savedFocalZPositions.removeValue(forKey: focalID)
                    }
                }

                if let prompt = gracePromptLabel {
                    let fadeOut = SKAction.fadeOut(withDuration: 0.2)
                    let remove = SKAction.removeFromParent()
                    prompt.run(.sequence([fadeOut, remove]))
                    gracePromptLabel = nil
                }

                engagementState = .disengaging
                currentFocalNodeID = nil
                holdCompleted = false
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
                driftExcludedIDs.removeAll()
                print("[Honeycomb] State: disengaging → idle")
            }

        case .idle:
            break
        }

        // Resting state: continuous physics disabled (forces governed by algorithmic layout)
        // applyNeighborhoodForces and checkConvergence removed
        lastUpdateTime = currentTime
    }

    /// Sigmoid scale falloff: focal large, smooth taper, asymptotic to baseline.
    /// `d` is hex distance from focal (0 = focal itself).
    /// Returns: target screen-space diameter as fraction of screen width.
    private func screenFractionForHexDistance(_ d: Int) -> CGFloat {
        let x = CGFloat(d)
        // Logistic sigmoid: 1 at x=0, smoothly transitions to 0 as x grows past midpoint
        let sigmoid = 1.0 / (1.0 + exp(scaleSigmoidSteepness * (x - scaleSigmoidMidpoint)))
        // Map sigmoid output to range [baselineScreenFraction, focalScreenFraction]
        return baselineScreenFraction + (focalScreenFraction - baselineScreenFraction) * sigmoid
    }

    /// Rendered world-space radius for a node at hex distance `d` from focal.
    /// Mirrors the screen-space scale lens used in the engagement render block.
    private func renderedWorldRadius(forHexDistance d: Int) -> CGFloat {
        guard let view = view else { return 0 }
        let screenDiameter = view.bounds.width * screenFractionForHexDistance(d)
        return (screenDiameter / 2.0) * cameraNode.xScale
    }

    /// Monotonic minimum world-space spacing from focal center to a node at hex distance `d`.
    /// Walks outward ring by ring so spacing(d) is always strictly greater than spacing(d-1) —
    /// prevents ring inversion when the sigmoid lens makes outer rings smaller than inner rings.
    private func minimumSpacingFromFocal(forHexDistance d: Int) -> CGFloat {
        guard d > 0 else { return 0 }
        var spacing: CGFloat = 0
        for k in 1...d {
            let innerRadius = renderedWorldRadius(forHexDistance: k - 1)
            let outerRadius = renderedWorldRadius(forHexDistance: k)
            spacing += innerRadius + outerRadius + neighborBreathingGap
        }
        return spacing
    }

    /// Compute compressed render position for a node.
    /// Hex coordinate is unchanged; this is purely visual.
    private func compressedHexPosition(
        nodeCoord: HexCoord,
        focalCoord: HexCoord
    ) -> CGPoint {
        let rawHexPos = hexToWorld(nodeCoord, cellSize: hexCellSize)
        let focalHexPos = hexToWorld(focalCoord, cellSize: hexCellSize)
        let d = hexDistance(focalCoord, nodeCoord)

        if d == 0 { return focalHexPos }  // focal stays at its hex position

        // Vector from focal to node in raw hex space
        let dx = rawHexPos.x - focalHexPos.x
        let dy = rawHexPos.y - focalHexPos.y
        let rawDistance = hypot(dx, dy)

        // Percentage compression: stronger near focal, weaker far away.
        let compressionFactor = positionCompressionStrength * exp(-CGFloat(d - 1) / positionCompressionFalloff)
        let percentageCompressedDistance = rawDistance * (1.0 - compressionFactor)

        // Minimum spacing based on rendered sizes — guarantees no overlap regardless
        // of how aggressive the percentage compression is.
        let minimumSpacing = minimumSpacingFromFocal(forHexDistance: d)

        let finalDistance = max(percentageCompressedDistance, minimumSpacing)

        // Place node along the original angle from focal so hex angular structure is preserved.
        let angle = atan2(dy, dx)
        return CGPoint(
            x: focalHexPos.x + cos(angle) * finalDistance,
            y: focalHexPos.y + sin(angle) * finalDistance
        )
    }

    private func applyLabelTier(_ tier: Int) {
        for (_, shape) in nodeSprites {
            guard let label = shape.children.first(where: { $0.name == "titleLabel" }) as? SKLabelNode,
                  let fullTitle = label.userData?["fullTitle"] as? String else {
                continue
            }

            // Check for forced tier from hover-browse
            let effectiveTier: Int
            if let forcedTier = shape.userData?["forceLabelTier"] as? Int {
                effectiveTier = forcedTier
            } else {
                effectiveTier = tier
            }

            switch effectiveTier {
            case 0:
                // Tier 0: Hidden
                label.isHidden = true
            case 1:
                // Tier 1: 2 words
                label.isHidden = false
                let words = fullTitle.split(separator: " ")
                let newText = words.prefix(2).joined(separator: " ")
                if label.text != newText { label.text = newText }
            case 2:
                // Tier 2: 3 words
                label.isHidden = false
                let words = fullTitle.split(separator: " ")
                let newText = words.prefix(3).joined(separator: " ")
                if label.text != newText { label.text = newText }
            default:
                break
            }
        }
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

    // MARK: - Blob displacement debug controls

    func setDisplacementAmplitude(_ amplitude: Float) {
        displacementAmplitude = amplitude
    }

    func setDisplacementSpeed(_ speed: Float) {
        displacementSpeed = speed
    }

    func setCanvasNoiseFrequency(_ frequency: Float) {
        canvasNoiseFrequency = frequency
    }

    func setNodeDeformIntensity(_ intensity: Float) {
        nodeDeformIntensity = intensity
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

    // MARK: - Strand layer

    /// Set the focal node and render strands to its top-related nodes.
    /// Pass nil to clear the focal node and fade out all strands.
    func setFocalNode(_ nodeID: String?) {
        // Clear focal if nil
        guard let nodeID = nodeID else {
            focalNodeID = nil
            clearStrands()
            print("[Strand] Focal cleared")
            return
        }

        // No-op if same node
        guard nodeID != focalNodeID else { return }

        // Set new focal
        focalNodeID = nodeID
        renderStrands(forFocalID: nodeID)
    }

    private func renderStrands(forFocalID focalID: String) {
        // Clear existing strands first (fast removal, no animation)
        strandLayer?.removeAllChildren()

        // Find focal sprite
        guard let focalSprite = nodeSprites[focalID] else {
            print("[Strand] Focal node \(focalID) not found in sprites")
            return
        }

        // Query related nodes
        let related = relatednessService.topRelated(
            forNodeID: focalID,
            in: currentNodes,
            limit: 5
        )

        guard !related.isEmpty else {
            print("[Strand] Focal set to node \(focalID) — 0 related nodes found")
            return
        }

        print("[Strand] Focal set to node \(focalID) — \(related.count) related nodes found")

        // Render strands
        for (relatedID, _) in related {
            guard let relatedSprite = nodeSprites[relatedID] else { continue }

            // Create line from focal to related
            let path = CGMutablePath()
            path.move(to: focalSprite.position)
            path.addLine(to: relatedSprite.position)

            let line = SKShapeNode(path: path)
            line.strokeColor = UIColor.white.withAlphaComponent(0.0)  // Start transparent
            line.lineWidth = 1.0
            line.zPosition = -1

            // Store related ID in userData for path updates
            line.userData = NSMutableDictionary()
            line.userData?["relatedID"] = relatedID

            strandLayer?.addChild(line)

            // Fade in to 0.3 opacity
            let fadeIn = SKAction.fadeAlpha(to: 0.3, duration: 0.4)
            fadeIn.timingMode = .easeOut
            line.run(fadeIn)
        }

        print("[Strand] Rendered \(related.count) strands (fade-in 0.4s)")
    }

    private func clearStrands() {
        guard let strandLayer = strandLayer else { return }

        let childCount = strandLayer.children.count
        guard childCount > 0 else { return }

        print("[Strand] Cleared \(childCount) strands (fade-out 0.3s)")

        // Fade out each strand
        for child in strandLayer.children {
            let fadeOut = SKAction.fadeOut(withDuration: 0.3)
            fadeOut.timingMode = .easeIn
            let remove = SKAction.removeFromParent()
            child.run(.sequence([fadeOut, remove]))
        }
    }

    // MARK: - Honeycomb helpers

    /// Find the node sprite nearest to the camera center with hysteresis.
    private func findNearestNodeToCamera() -> String? {
        let cameraCenter = cameraNode.position
        var nearestID: String? = nil
        var nearestDistance: CGFloat = .infinity

        for (nodeID, sprite) in nodeSprites {
            let dx = sprite.position.x - cameraCenter.x
            let dy = sprite.position.y - cameraCenter.y
            let distance = sqrt(dx * dx + dy * dy)

            if distance < nearestDistance {
                nearestDistance = distance
                nearestID = nodeID
            }
        }

        // Apply hysteresis if there's a current focal
        if let currentID = currentFocalNodeID,
           let currentSprite = nodeSprites[currentID] {
            let currentDx = currentSprite.position.x - cameraCenter.x
            let currentDy = currentSprite.position.y - cameraCenter.y
            let currentDistance = sqrt(currentDx * currentDx + currentDy * currentDy)

            if let candidate = nearestID,
               candidate != currentID,
               nearestDistance < currentDistance - hysteresisThreshold {
                // New candidate is at least 20pt closer — switch
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

    /// Start drift animation: move related nodes 8% toward focal.
    private func startDrift(towardFocalID focalID: String, relatedIDs: [String]) {
        guard let focalSprite = nodeSprites[focalID] else { return }

        // Exclude drifting nodes from displacement loop
        driftExcludedIDs = Set(relatedIDs)

        for relatedID in relatedIDs {
            guard let relatedSprite = nodeSprites[relatedID] else { continue }

            // Store original position
            driftedRelatedIDs[relatedID] = relatedSprite.position

            // Compute 8% of vector toward focal
            let dx = focalSprite.position.x - relatedSprite.position.x
            let dy = focalSprite.position.y - relatedSprite.position.y
            let driftDx = dx * 0.08
            let driftDy = dy * 0.08

            // Animate
            let move = SKAction.moveBy(x: driftDx, y: driftDy, duration: 0.5)
            move.timingMode = .easeOut
            relatedSprite.run(move, withKey: "honeycombDrift")
        }
    }

    /// Unwind drift animation: return drifted nodes to original positions.
    private func unwindDrift() {
        guard !driftedRelatedIDs.isEmpty else { return }

        for (relatedID, originalPosition) in driftedRelatedIDs {
            guard let relatedSprite = nodeSprites[relatedID] else { continue }

            let move = SKAction.move(to: originalPosition, duration: 0.4)
            move.timingMode = .easeIn
            relatedSprite.run(move, withKey: "honeycombDrift")
        }

        driftedRelatedIDs.removeAll()
        driftExcludedIDs.removeAll()
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
        let labelNode = makeTitleLabel(text: displayText, radius: radius)
        shape.addChild(labelNode)

        // Apply current label tier immediately on add
        if currentLabelTier == 0 {
            labelNode.isHidden = true
        } else {
            labelNode.isHidden = false
            if let fullTitle = labelNode.userData?["fullTitle"] as? String {
                let words = fullTitle.split(separator: " ")
                labelNode.text = words.prefix(currentLabelTier == 1 ? 2 : 3).joined(separator: " ")
            }
        }

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
        shape.fillColor = bubbleColor(for: node).withAlphaComponent(node.isMeta ? 0.55 : 1.0)

        // Update cached neighborhoodID
        if shape.userData == nil {
            shape.userData = NSMutableDictionary()
        }
        shape.userData?["neighborhoodID"] = neighborhoodCache?.neighborhoodID(forNodeID: node.id)

        // Title label update
        if let label = shape.children.first(where: { $0.name == "titleLabel" }) as? SKLabelNode {
            let displayText = node.title.isEmpty ? (node.items.first?.content ?? "") : node.title
            label.text = displayText
            label.userData = ["fullTitle": displayText]
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
    private func addNewcomerHalo(to sprite: SKShapeNode, radius: CGFloat) {
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
        let titleLabel = SKLabelNode(text: cluster.title)
        titleLabel.fontSize = 11
        titleLabel.fontName = "HelveticaNeue-Medium"
        titleLabel.fontColor = UIColor.white.withAlphaComponent(0.85)
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
        // startUberNodeBreathing(for: shape, clusterID: cluster.id, radius: radius)
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

    /// Start slower breathing animation for Über-node (1.5× duration of regular nodes).
    private func startUberNodeBreathing(for shape: SKShapeNode, clusterID: String, radius: CGFloat) {
        let morphDuration = TimeInterval.random(in: 3.0...4.5)  // Slower than regular (2-3s)

        let morphAction = SKAction.customAction(withDuration: morphDuration) { [weak self, weak shape] node, elapsed in
            guard let self = self, let shape = shape else { return }
            let currentTime = CACurrentMediaTime() - self.shaderStartTime
            let newPath = self.makeDeformedBlobPath(radius: radius, nodeID: clusterID, time: currentTime)
            shape.path = newPath
        }
        morphAction.timingMode = .easeInEaseOut

        let wait = SKAction.wait(forDuration: 0.1)
        let sequence = SKAction.sequence([morphAction, wait])
        let forever = SKAction.repeatForever(sequence)

        shape.run(forever, withKey: "blobBreathing")
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

    // MARK: - Blob displacement helpers

    /// Simple 2D Perlin-style noise (returns -1...1)
    private func noise2D(x: Float, y: Float, seed: Float = 0) -> Float {
        let ix = floor(x)
        let iy = floor(y)
        let fx = x - ix
        let fy = y - iy

        // Smoothstep interpolation
        let u = fx * fx * (3 - 2 * fx)
        let v = fy * fy * (3 - 2 * fy)

        // Hash-based pseudo-random gradients
        func hash(_ x: Float, _ y: Float, _ s: Float) -> Float {
            let h = sin(x * 127.1 + y * 311.7 + s * 217.3) * 43758.5453
            return h - floor(h) - 0.5  // range -0.5...0.5
        }

        let a = hash(ix, iy, seed)
        let b = hash(ix + 1, iy, seed)
        let c = hash(ix, iy + 1, seed)
        let d = hash(ix + 1, iy + 1, seed)

        return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v
    }

    /// Generate an organic blob path with smooth Catmull-Rom style curves
    private func makeDeformedBlobPath(
        radius: CGFloat,
        nodeID: String,
        time: TimeInterval
    ) -> CGPath {
        let numPoints = 16  // More points = smoother perimeter
        let angleStep = 2 * CGFloat.pi / CGFloat(numPoints)

        // Get or create phase offset for this node
        if nodePhaseOffsets[nodeID] == nil {
            nodePhaseOffsets[nodeID] = Float.random(in: 0...100)
        }
        let phaseOffset = nodePhaseOffsets[nodeID] ?? 0

        // Canvas-wide noise (slow ambient breathing)
        let canvasTime = Float(time) * canvasNoiseFrequency * displacementSpeed * 0.2
        let canvasNoiseVal = noise2D(x: canvasTime, y: phaseOffset * 0.1)

        // First pass: calculate all deformed points with noise-based radius variation
        var points: [CGPoint] = []
        for i in 0..<numPoints {
            let baseAngle = angleStep * CGFloat(i)

            // Per-node high-frequency deformation
            let nodeTime = Float(time) * displacementSpeed + phaseOffset
            let noiseX = cos(Float(baseAngle)) + nodeTime * 0.5
            let noiseY = sin(Float(baseAngle)) + nodeTime * 0.5
            let nodeNoiseVal = noise2D(x: noiseX, y: noiseY, seed: phaseOffset)

            // Combine: canvas ambient + per-node deformation
            let combinedNoise = canvasNoiseVal * 0.3 + nodeNoiseVal * 0.7 * nodeDeformIntensity
            let displacement = CGFloat(combinedNoise) * CGFloat(displacementAmplitude)

            let deformedRadius = radius * (1.0 + displacement)
            let x = cos(baseAngle) * deformedRadius
            let y = sin(baseAngle) * deformedRadius
            points.append(CGPoint(x: x, y: y))
        }

        // Second pass: create ultra-smooth Catmull-Rom style cubic bezier path
        // Control point handle length = 0.4× chord distance for river-worn stone smoothness
        let bezier = UIBezierPath()
        bezier.move(to: points[0])

        for i in 0..<numPoints {
            let current = points[i]
            let next = points[(i + 1) % numPoints]
            let prev = points[(i - 1 + numPoints) % numPoints]
            let afterNext = points[(i + 2) % numPoints]

            // Chord distance from current to next
            let dx = next.x - current.x
            let dy = next.y - current.y
            let chordDistance = sqrt(dx * dx + dy * dy)
            let handleLength = chordDistance * 0.4

            // Tangent vector at current (normalized direction from prev to next)
            let tangentX = next.x - prev.x
            let tangentY = next.y - prev.y
            let tangentLength = sqrt(tangentX * tangentX + tangentY * tangentY)
            let normTangentX = tangentLength > 0 ? tangentX / tangentLength : 0
            let normTangentY = tangentLength > 0 ? tangentY / tangentLength : 0

            // Control point 1: extends from current along tangent
            let cp1 = CGPoint(
                x: current.x + normTangentX * handleLength,
                y: current.y + normTangentY * handleLength
            )

            // Tangent vector at next (normalized direction from current to afterNext)
            let tangentNextX = afterNext.x - current.x
            let tangentNextY = afterNext.y - current.y
            let tangentNextLength = sqrt(tangentNextX * tangentNextX + tangentNextY * tangentNextY)
            let normTangentNextX = tangentNextLength > 0 ? tangentNextX / tangentNextLength : 0
            let normTangentNextY = tangentNextLength > 0 ? tangentNextY / tangentNextLength : 0

            // Control point 2: extends from next backward along its tangent
            let cp2 = CGPoint(
                x: next.x - normTangentNextX * handleLength,
                y: next.y - normTangentNextY * handleLength
            )

            bezier.addCurve(to: next, controlPoint1: cp1, controlPoint2: cp2)
        }

        bezier.close()
        return bezier.cgPath
    }

    /// Start breathing animation for a node shape
    private func startBlobBreathing(for shape: SKShapeNode, nodeID: String, radius: CGFloat) {
        // Über-nodes breathe slower than regular nodes
        let isUberNode = shape.name?.hasPrefix("uber:") ?? false
        let morphDuration = isUberNode
            ? TimeInterval.random(in: 3.5...5.0)
            : TimeInterval.random(in: 2.0...3.0)

        let morphAction = SKAction.customAction(withDuration: morphDuration) { [weak self, weak shape] node, elapsed in
            guard let self = self, let shape = shape else { return }
            // Continuously regenerate path with advancing time for smooth organic motion
            let currentTime = CACurrentMediaTime() - self.shaderStartTime
            let newPath = self.makeDeformedBlobPath(radius: radius, nodeID: nodeID, time: currentTime)
            shape.path = newPath
        }
        morphAction.timingMode = .easeInEaseOut

        let wait = SKAction.wait(forDuration: 0.1)  // Brief pause between updates
        let sequence = SKAction.sequence([morphAction, wait])
        let forever = SKAction.repeatForever(sequence)

        shape.run(forever, withKey: "blobBreathing")
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
        var neighborhoodGroups: [String: [SKShapeNode]] = [:]
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

    // MARK: - Hex Grid Layout (SB80a-fix4: global grid, nearest-cell snap)

    /// Compute hex coordinates for all nodes on a global grid covering the canvas
    private func computeNeighborhoodHexLayout() {
        nodeHexCoords.removeAll()

        // Collect all resting positions
        var restingPositions: [String: CGPoint] = [:]
        for (nodeID, sprite) in nodeSprites {
            restingPositions[nodeID] = sprite.position
        }

        guard !restingPositions.isEmpty else { return }

        // Step 1: Compute bounding box
        let positions = Array(restingPositions.values)
        let minX = positions.map { $0.x }.min()!
        let maxX = positions.map { $0.x }.max()!
        let minY = positions.map { $0.y }.min()!
        let maxY = positions.map { $0.y }.max()!

        // Add padding (one cell radius)
        let padding: CGFloat = 60.0  // Approximate cell radius
        let bbox = CGRect(
            x: minX - padding,
            y: minY - padding,
            width: (maxX - minX) + 2 * padding,
            height: (maxY - minY) + 2 * padding
        )

        // Step 2: Generate hex cell centers covering bounding box
        // Use the shared world-space cell size for layout and rendering
        let unitSpacing = hexCellSize
        var hexCells: [HexCoord] = []
        var hexCellCenters: [HexCoord: CGPoint] = [:]

        // Generate hex coords that cover the bounding box
        let qMin = Int(floor(bbox.minX / (unitSpacing * sqrt(3.0)))) - 2
        let qMax = Int(ceil(bbox.maxX / (unitSpacing * sqrt(3.0)))) + 2
        let rMin = Int(floor(bbox.minY / (unitSpacing * 1.5))) - 2
        let rMax = Int(ceil(bbox.maxY / (unitSpacing * 1.5))) + 2

        for q in qMin...qMax {
            for r in rMin...rMax {
                let coord = HexCoord(q: q, r: r)
                let center = hexToWorld(coord, cellSize: unitSpacing)
                if bbox.contains(center) || bbox.insetBy(dx: -padding, dy: -padding).contains(center) {
                    hexCells.append(coord)
                    hexCellCenters[coord] = center
                }
            }
        }

        // Step 3: Sort nodes by distance from canvas centroid (center-out assignment)
        let canvasCentroid = CGPoint(
            x: (minX + maxX) / 2,
            y: (minY + maxY) / 2
        )

        let sortedNodes = restingPositions.sorted { lhs, rhs in
            let dist1 = hypot(lhs.value.x - canvasCentroid.x, lhs.value.y - canvasCentroid.y)
            let dist2 = hypot(rhs.value.x - canvasCentroid.x, rhs.value.y - canvasCentroid.y)
            return dist1 < dist2
        }

        // Step 4: Greedy nearest-cell assignment
        var claimedCells = Set<HexCoord>()
        for (nodeID, restingPos) in sortedNodes {
            // Find nearest unclaimed hex cell
            var nearestCell: HexCoord?
            var nearestDist: CGFloat = .infinity

            for coord in hexCells where !claimedCells.contains(coord) {
                let cellCenter = hexCellCenters[coord]!
                let dist = hypot(cellCenter.x - restingPos.x, cellCenter.y - restingPos.y)
                if dist < nearestDist {
                    nearestDist = dist
                    nearestCell = coord
                }
            }

            if let cell = nearestCell {
                nodeHexCoords[nodeID] = cell
                claimedCells.insert(cell)
            }
        }

        print("[Hex] Assigned \(nodeHexCoords.count) nodes to global hex grid (\(hexCells.count) cells generated)")
    }

    /// Generate hex coordinate in spiral order from origin (index 0 = (0,0), then spiral outward)
    private func spiralHexCoord(index: Int) -> HexCoord {
        if index == 0 {
            return HexCoord(q: 0, r: 0)
        }

        // Determine which ring (1, 2, 3, ...) this index falls into
        var ring = 1
        var cellsBeforeRing = 1  // center
        while cellsBeforeRing + (ring * 6) < index + 1 {
            cellsBeforeRing += ring * 6
            ring += 1
        }

        // Index within this ring
        let indexInRing = index - cellsBeforeRing

        // Hex directions (counter-clockwise from East)
        let directions: [(Int, Int)] = [
            (1, 0),    // E
            (0, 1),    // NE
            (-1, 1),   // NW
            (-1, 0),   // W
            (0, -1),   // SW
            (1, -1)    // SE
        ]

        // Start at (ring, 0) - the eastmost point of this ring
        var q = ring
        var r = 0

        // Walk around the ring
        var stepsRemaining = indexInRing
        for (dq, dr) in directions {
            let stepsInThisDirection = min(ring, stepsRemaining)
            q += dq * stepsInThisDirection
            r += dr * stepsInThisDirection
            stepsRemaining -= stepsInThisDirection
            if stepsRemaining == 0 {
                break
            }
        }

        return HexCoord(q: q, r: r)
    }

    // MARK: - Helpers

    private func makeShape(
        radius: CGFloat,
        fillColor: UIColor,
        isMeta: Bool = false,
        nodeID: String
    ) -> SKShapeNode {
        // Start with deformed blob path
        let initialPath = makeDeformedBlobPath(
            radius: radius,
            nodeID: nodeID,
            time: CACurrentMediaTime() - shaderStartTime
        )

        let shape = SKShapeNode(path: initialPath)
        shape.fillColor = isMeta ? fillColor.withAlphaComponent(0.55) : fillColor
        shape.zPosition = 1

        if isMeta {
            shape.strokeColor = UIColor(red: 0.7, green: 0.5, blue: 1.0, alpha: 0.7)  // soft purple
            shape.lineWidth = 1.5
        } else {
            shape.strokeColor = UIColor.white.withAlphaComponent(0.12)
            shape.lineWidth = 1
            // Gradient fill shader — requires a non-nil fillTexture so v_tex_coord is valid
            shape.fillTexture = whiteUVTexture
            shape.fillShader = nodeFillShader

            // Start organic breathing animation
            startBlobBreathing(for: shape, nodeID: nodeID, radius: radius)
        }
        return shape
    }

    /// Create Über-node shape with GLSL gradient shader using child colors.
    private func makeUberNodeShape(
        radius: CGFloat,
        colors: [UIColor],
        clusterID: String
    ) -> SKShapeNode {
        // Start with deformed blob path
        let initialPath = makeDeformedBlobPath(
            radius: radius,
            nodeID: clusterID,
            time: CACurrentMediaTime() - shaderStartTime
        )

        let shape = SKShapeNode(path: initialPath)

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

    private func makeTitleLabel(text: String, radius: CGFloat) -> SKLabelNode {
        let label = SKLabelNode(text: text)
        label.fontSize = 48  // High-res rasterization
        label.xScale = 10.0 / 48.0  // Scale down to 10pt visual size
        label.yScale = 10.0 / 48.0
        label.fontName = "HelveticaNeue"
        label.fontColor = UIColor.white.withAlphaComponent(0.65)
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = .zero
        label.preferredMaxLayoutWidth = radius * 6.72  // pre-scale local coordinates: visible width = radius * 1.4, divided by xScale (10/48)
        label.numberOfLines = 2
        label.zPosition = 2
        label.name = "titleLabel"
        label.userData = ["fullTitle": text]
        return label
    }

    private func bubbleRadius(for node: Node) -> CGFloat {
        // Base diameter 60pt (radius 30), +8pt diameter per additional item, max diameter 120pt
        let extra = CGFloat(max(0, node.items.count - 1)) * 4.0  // +4pt radius per item
        return min(30.0 + extra, 60.0)
    }

    private func bubbleColor(for node: Node) -> UIColor {
        if let primaryTag = node.tags.first, let color = tagColors[primaryTag] {
            return color
        }
        return UIColor(red: 0.556, green: 0.556, blue: 0.576, alpha: 1.0)  // #8E8E93 neutral
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

                // Permissive sprite-walk: any node hit opens its detail view.
                if let shape = nodeSprites.values.first(where: { $0.contains(scenePoint) }),
                   let name = shape.name,
                   name.hasPrefix("node:") {
                    let tappedNodeID = String(name.dropFirst(5))
                    print("[Honeycomb] Grace tap on node \(tappedNodeID)")

                    DispatchQueue.main.async { [weak self] in
                        self?.canvasState?.pendingNavigationNodeID = tappedNodeID
                    }

                    // Stay in .gracePeriod with a fresh expiry. Detail view will dismiss
                    // and the canvas remains engaged with a full grace window.
                    let newExpiresAt = CACurrentMediaTime() + gracePeriodDuration
                    engagementState = .gracePeriod(focal: focalID, expiresAt: newExpiresAt)
                    return
                }

                // Empty-space tap during grace: fall through to tapCandidate so a follow-up
                // drag can trigger the drag-during-grace re-engagement path.
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
                    // Pick focal: if engagement is mid-grace, preserve the grace focal so
                    // a drag-during-grace seamlessly continues the same engagement. Otherwise
                    // pick the nearest node to camera.
                    let focalID: String
                    let priorState: String
                    if case .gracePeriod(let graceFocal, _) = engagementState {
                        focalID = graceFocal
                        priorState = "gracePeriod"
                        if let prompt = gracePromptLabel {
                            let fadeOut = SKAction.fadeOut(withDuration: 0.1)
                            let remove = SKAction.removeFromParent()
                            prompt.run(.sequence([fadeOut, remove]))
                            gracePromptLabel = nil
                        }
                    } else {
                        focalID = findNearestNodeToCamera() ?? ""
                        priorState = "idle"
                    }

                    // Transition to honeycomb mode
                    gestureState = .honeycomb(
                        initialPosition: initialPosition,
                        lastPanPosition: current
                    )
                    holdTimerStart = CACurrentMediaTime()
                    holdCompleted = false

                    // No per-drag capture — `nodeRestingPositions` / `nodeRestingScales`
                    // are populated from the layout in `captureRestingState()`.
                    engagementState = .engaging(focal: focalID)

                    print("[Honeycomb] State: \(priorState) → engaging(focal: \(focalID))")
                }

            case .honeycomb(let initialPosition, let lastPanPosition):
                // Apply pan to camera
                let panDx = (current.x - lastPanPosition.x) * panMultiplier
                let panDy = (current.y - lastPanPosition.y) * panMultiplier

                // Update camera position (inverted: drag right = pan left in scene)
                cameraNode.position.x -= panDx * cameraNode.xScale
                cameraNode.position.y += panDy * cameraNode.xScale  // y-inverted in SpriteKit

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
            if let focalID = currentFocalNodeID {
                print("[Honeycomb] Grace period entered for \(focalID)")

                // Enter grace period — owned by engagementState only. gestureState returns
                // to idle so the next touchesBegan starts a fresh tap candidate.
                let expiresAt = CACurrentMediaTime() + gracePeriodDuration
                engagementState = .gracePeriod(focal: focalID, expiresAt: expiresAt)
                gestureState = .idle

                // Create prompt label near focal sprite
                if let focalSprite = nodeSprites[focalID] {
                    let prompt = SKLabelNode(text: "Tap for more detail")
                    prompt.fontSize = 14
                    prompt.fontName = "HelveticaNeue-Medium"
                    prompt.fontColor = UIColor.white.withAlphaComponent(0.0)
                    prompt.verticalAlignmentMode = .center
                    prompt.horizontalAlignmentMode = .center
                    prompt.position = CGPoint(
                        x: focalSprite.position.x,
                        y: focalSprite.position.y - 60
                    )
                    prompt.zPosition = 100
                    addChild(prompt)
                    gracePromptLabel = prompt

                    // Fade in
                    let fadeIn = SKAction.fadeAlpha(to: 0.9, duration: 0.2)
                    prompt.run(fadeIn)
                }
            } else {
                // No focal tracked - return to idle
                print("[Honeycomb] State: engaged → disengaging")
                engagementState = .disengaging
                gestureState = .idle
                currentFocalNodeID = nil
                holdCompleted = false
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

            // Single-tap on node: open NodeDetailView
            DispatchQueue.main.async { [weak self] in
                self?.canvasState?.selectedNodeID = nodeID
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

        // Clean up honeycomb state
        if case .honeycomb(_, _) = gestureState {
            // Transition to disengaging
            engagementState = .disengaging

            clearStrands()
            unwindDrift()
            if let focalID = currentFocalNodeID, let focalSprite = nodeSprites[focalID] {
                let scaleDown = SKAction.scale(to: 1.0, duration: 0.3)
                scaleDown.timingMode = .easeOut
                focalSprite.run(scaleDown)

                // Restore original zPosition
                if let savedZ = savedFocalZPositions[focalID] {
                    focalSprite.zPosition = savedZ
                    savedFocalZPositions.removeValue(forKey: focalID)
                }
            }
            currentFocalNodeID = nil
        }
        gestureState = .idle
        holdCompleted = false
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
