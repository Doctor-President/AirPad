import SpriteKit
import UIKit
import simd

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
    private var nodeSprites: [String: SKShapeNode] = [:]
    var uberNodeSprites: [String: SKShapeNode] = [:]  // Accessed by CanvasView for drill-down
    private var positionMap: [String: CanvasPosition] = [:]

    private var tagColors: [String: UIColor] = [:]
    private var neighborhoodCache: NeighborhoodCache? = nil
    private var nodeRadii: [String: CGFloat] = [:]

    // Strand layer state
    private var focalNodeID: String? = nil
    private var strandLayer: SKNode? = nil
    private let relatednessService = RelatednessService()
    private var currentNodes: [Node] = []  // Cached for relatedness computation

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
    private let holdThreshold: TimeInterval = 0.7
    private let gracePeriodDuration: TimeInterval = 1.0  // SB94: halved — was 2.0
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
    private var holdTimerStart: TimeInterval? = nil
    private var holdCompleted: Bool = false
    private var driftedRelatedIDs: [String: CGPoint] = [:]
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

    private var driftExcludedIDs: Set<String> = []

    // Screen-space scale lens (SB80b-fix2 — sigmoid math preserved; input is now
    // euclidean distance from focal normalized by `characteristicSpacing`)
    private let focalScreenFraction: CGFloat = 0.60       // focal diameter = 60% of screen width
    private let baselineScreenFraction: CGFloat = 0.09    // baseline diameter = 9% of screen width
    private let scaleSigmoidSteepness: CGFloat = 3.0      // SB85 baseline
    private let scaleSigmoidMidpoint: CGFloat = 0.7       // SB85 baseline

    // Radial position compression
    private let positionCompressionStrength: CGFloat = 0.55  // 0 = no compression, 1 = all nodes at focal
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

    private let hysteresisThreshold: CGFloat = 20.0

    // SB92: Track per-focal-switch lerp ramp window
    private var focalSwitchTimestamp: TimeInterval? = nil
    private let focalSwitchSlowLerpDuration: TimeInterval = 0.15

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

        // Background grid (AT18.1.9): single procedural-shader SKShapeNode
        // parented to the camera so its screen position is fixed. Shader
        // reconstructs world coordinates from camera uniforms; pan and zoom
        // are entirely handled by the shader's coordinate math.
        let viewportSize = view.bounds.size
        let grid = BackgroundGridNode.makeShape(viewportSize: viewportSize, fillTexture: whiteUVTexture)
        cameraNode.addChild(grid)
        gridNode = grid

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

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if let grid = gridNode {
            BackgroundGridNode.resize(grid, to: size)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        if isPaused { return }

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
        }


        // Über-node shader updates disabled (sprites not rendered)
        // for (_, shape) in uberNodeSprites {
        //     shape.fillShader?.uniforms.first(where: { $0.name == "u_time" })?.floatValue = Float(elapsed)
        // }

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
            guard let focalRestingPos = nodeRestingPositions[focalID],
                  let view = view else { break }

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
                guard !driftExcludedIDs.contains(nodeID),
                      let restingPos = nodeRestingPositions[nodeID],
                      let intrinsicRadius = nodeIntrinsicRadii[nodeID],
                      intrinsicRadius > 0 else { continue }

                // Target position: fingerprint resting position pushed radially outward
                // from focal to make room for the focal's enlarged size.
                let targetPos = applyRadialCompression(
                    nodePos: restingPos,
                    focalPos: focalRestingPos,
                    strength: positionCompressionStrength,
                    falloff: positionCompressionFalloff
                )

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

            // Phase 1.5 — SB92: Bounded-band relaxation
            // Resolve overlaps in the band near focal. Far periphery is excluded
            // because compression falloff has died out and overlaps are rare.
            var relaxationSet: [String] = [focalID]
            for nodeID in nodeSprites.keys where nodeID != focalID {
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

            // Phase 3: Lerp toward targets and check convergence
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

                clearStrands()
                unwindDrift()

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
                holdCompleted = false
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
                driftExcludedIDs.removeAll()
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

        // Resting state: continuous physics disabled (forces governed by algorithmic layout)
        // applyNeighborhoodForces and checkConvergence removed
        lastUpdateTime = currentTime
    }

    /// Tracks last focal-id pushed to CanvasState so we can detect transitions to
    /// nil and dispatch a single clear instead of polling canvasState off-isolation.
    private var lastSyncedFocalID: String? = nil

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
            }
            lastSyncedFocalID = trackedID
        } else if lastSyncedFocalID != nil {
            MainActor.assumeIsolated {
                canvasState?.currentFocalNodeID = nil
                canvasState?.disengagingFocalNodeID = nil
            }
            lastSyncedFocalID = nil
        }
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
        let labelSprite = makeTitleSprite(text: displayText, radius: radius)
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
        shape.fillColor = bubbleColor(for: node).withAlphaComponent(node.isMeta ? 0.55 : 1.0)

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
            // Unfocused nodes render flat tag color — gradient shader is applied on
            // engagement via setFocalShader(to:) and cleared on disengagement.

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
        renderScale: CGFloat
    ) -> SKTexture {
        let textWidth = side  // padding inside the square
        let textColor = UIColor.white.withAlphaComponent(0.85)

        // Title label
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = titleFont
        titleLabel.textColor = textColor
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .center
        let titleMaxHeight = titleFont.lineHeight * 2 + 4
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
            s.text = summary
            s.font = summaryFont
            s.textColor = textColor
            s.numberOfLines = 4
            s.lineBreakMode = .byTruncatingTail
            s.textAlignment = .center
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

    private func makeTitleSprite(text: String, radius: CGFloat) -> SKSpriteNode {
        // Rasterize at displayed dimensions (full visual size); sprite is sized in
        // intrinsic coords so parent scaling stays consistent.
        let displayedCanvasSide: CGFloat = 84
        let displayedTitleFontSize: CGFloat = 14
        let titleFont = UIFont(name: "HelveticaNeue", size: displayedTitleFontSize) ?? UIFont.systemFont(ofSize: displayedTitleFontSize)
        let texture = rasterizeSquareText(
            title: text,
            summary: nil,
            side: displayedCanvasSide,
            titleFont: titleFont,
            summaryFont: titleFont,
            renderScale: 6.0
        )
        let sprite = SKSpriteNode(texture: texture)
        sprite.position = .zero
        sprite.zPosition = 2
        sprite.name = "titleLabel"
        sprite.userData = ["fullTitle": text, "isFocal": false]
        sprite.size = CGSize(width: radius * 1.4, height: radius * 1.4)
        return sprite
    }

    private func swapToFocalTexture(nodeID: String) {
        guard let shape = nodeSprites[nodeID],
              let sprite = shape.children.first(where: { $0.name == "titleLabel" }) as? SKSpriteNode,
              let fullTitle = sprite.userData?["fullTitle"] as? String,
              let isFocal = sprite.userData?["isFocal"] as? Bool,
              !isFocal,
              let node = currentNodes.first(where: { $0.id == nodeID }),
              let radius = nodeIntrinsicRadii[nodeID],
              let view = self.view
        else { return }

        // Rasterize at displayed dimensions (full visual size) so glyphs render at their
        // actual on-screen point size. Sprite is sized in intrinsic coords so parent xScale
        // still drives the engagement scaling — it just lands at 1:1 with the bitmap.
        let displayedDiameter = focalScreenFraction * view.bounds.width
        let displayedSquareSide = displayedDiameter * 0.7
        let displayedTitleFontSize = displayedDiameter * 0.085
        let displayedSummaryFontSize = displayedDiameter * 0.05

        let titleFont = UIFont(name: "HelveticaNeue-Bold", size: displayedTitleFontSize) ?? UIFont.boldSystemFont(ofSize: displayedTitleFontSize)
        let summaryFont = UIFont(name: "HelveticaNeue", size: displayedSummaryFontSize) ?? UIFont.systemFont(ofSize: displayedSummaryFontSize)

        let texture = rasterizeSquareText(
            title: fullTitle,
            summary: node.summary,
            side: displayedSquareSide,
            titleFont: titleFont,
            summaryFont: summaryFont,
            renderScale: 6.0
        )
        sprite.texture = texture
        print("[FocalDebug] textureFiltering=\(texture.filteringMode.rawValue) spriteBlend=\(sprite.blendMode.rawValue) parentBlend=\(shape.blendMode.rawValue) parentHasShader=\(shape.fillShader != nil)")
        sprite.size = CGSize(width: radius * 1.4, height: radius * 1.4)
        sprite.userData?["isFocal"] = true

        print("[FocalText] swap radius=\(radius) intrinsicSide=\(radius * 1.4) displayedSide=\(displayedSquareSide) titleFontSize=\(displayedTitleFontSize) texture=\(texture.size())")
    }

    private func swapToNonFocalTexture(nodeID: String) {
        guard let shape = nodeSprites[nodeID],
              let sprite = shape.children.first(where: { $0.name == "titleLabel" }) as? SKSpriteNode,
              let fullTitle = sprite.userData?["fullTitle"] as? String,
              let isFocal = sprite.userData?["isFocal"] as? Bool,
              isFocal,
              let radius = nodeIntrinsicRadii[nodeID]
        else { return }

        let displayedCanvasSide: CGFloat = 84
        let displayedTitleFontSize: CGFloat = 14
        let titleFont = UIFont(name: "HelveticaNeue", size: displayedTitleFontSize) ?? UIFont.systemFont(ofSize: displayedTitleFontSize)

        let texture = rasterizeSquareText(
            title: fullTitle,
            summary: nil,
            side: displayedCanvasSide,
            titleFont: titleFont,
            summaryFont: titleFont,
            renderScale: 6.0
        )
        sprite.texture = texture
        sprite.size = CGSize(width: radius * 1.4, height: radius * 1.4)
        sprite.userData?["isFocal"] = false
    }

    private func bubbleRadius(for node: Node) -> CGFloat {
        // Base diameter 60pt (radius 30), +8pt diameter per additional item, max diameter 120pt
        let extra = CGFloat(max(0, node.items.count - 1)) * 4.0  // +4pt radius per item
        return min(30.0 + extra, 60.0)
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
        if let oldID = focalShaderID, oldID != nodeID,
           let oldShape = nodeSprites[oldID] {
            oldShape.fillShader = nil
            oldShape.fillTexture = nil
            oldShape.alpha = 1
        }
        if let newID = nodeID, newID != focalShaderID,
           let newShape = nodeSprites[newID] {
            newShape.fillShader = nil
            newShape.fillTexture = nil
            newShape.alpha = 0
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
                        engagementState = .engaged(focal: graceFocal)
                        focalChangeHaptic.prepare()  // SB96
                        print("[Honeycomb] State: gracePeriod → engaged (drag resume)")
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
                    holdTimerStart = CACurrentMediaTime()
                    holdCompleted = false

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
            if momentumEligible, let first = panSamples.first, let last = panSamples.last {
                let dt = last.time - first.time
                if dt > 0 {
                    let vxPerSec = (last.position.x - first.position.x) / CGFloat(dt)
                    let vyPerSec = (last.position.y - first.position.y) / CGFloat(dt)
                    let vxPerFrame = vxPerSec / 60.0
                    let vyPerFrame = vyPerSec / 60.0
                    if hypot(vxPerFrame, vyPerFrame) >= coastLaunchThreshold {
                        coastVelocity = CGPoint(x: vxPerFrame, y: vyPerFrame)
                    }
                }
            }
            panSamples.removeAll()
            momentumEligible = false

            if let focalID = currentFocalNodeID {
                print("[Honeycomb] Grace period entered for \(focalID)")

                // Enter grace period — owned by engagementState only. gestureState returns
                // to idle so the next touchesBegan starts a fresh tap candidate.
                let expiresAt = CACurrentMediaTime() + gracePeriodDuration
                engagementState = .gracePeriod(focal: focalID, expiresAt: expiresAt)
                gestureState = .idle
            } else {
                // No focal tracked - return to idle
                print("[Honeycomb] State: engaged → disengaging")
                engagementState = .disengaging
                gestureState = .idle
                currentFocalNodeID = nil
                setFocalShader(to: nil)
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
                lingerFocalNodeID = focalID
            }
            currentFocalNodeID = nil
            setFocalShader(to: nil)
            preCollapseStartScales.removeAll()  // SB94
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
