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
    func syncNodes(
        _ nodes: [Node],
        layoutPositions: [String: CanvasPosition],
        tagColors: [String: UIColor] = [:],
        newNodeID: String? = nil,
        uberNodeClusters: [UberNodeCluster] = [],
        expandingFrom: CGPoint? = nil
    ) {
        self.tagColors = tagColors
        positionMap = layoutPositions

        // Reset label tier to force re-evaluation on next update() frame
        currentLabelTier = -1

        // Sync regular nodes
        let incomingNodeIDs = Set(nodes.map { $0.id })
        let existingNodeIDs = Set(nodeSprites.keys)

        // Remove deleted nodes
        for id in existingNodeIDs.subtracting(incomingNodeIDs) {
            nodeSprites[id]?.removeFromParent()
            nodeSprites.removeValue(forKey: id)
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
    }

    // MARK: - Private state

    private var cameraNode = SKCameraNode()
    private var nodeSprites: [String: SKShapeNode] = [:]
    var uberNodeSprites: [String: SKShapeNode] = [:]  // Accessed by CanvasView for drill-down
    private var positionMap: [String: CanvasPosition] = [:]

    private var tagColors: [String: UIColor] = [:]

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

    // Hover-browse state
    private weak var hoveredNode: SKShapeNode?
    private var snapBackPositions: [SKShapeNode: CGPoint] = [:]

    // Shader animation state
    private var shaderStartTime: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0

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

        // Start shader animation clock
        shaderStartTime = CACurrentMediaTime()
        lastUpdateTime = shaderStartTime
    }

    override func update(_ currentTime: TimeInterval) {
        if isPaused { return }
        let elapsed = currentTime - shaderStartTime
        nodeFillShader.uniforms.first(where: { $0.name == "u_time" })?.floatValue = Float(elapsed)

        // Update u_time for each Über-node shader
        for (_, shape) in uberNodeSprites {
            shape.fillShader?.uniforms.first(where: { $0.name == "u_time" })?.floatValue = Float(elapsed)
        }

        let scale = cameraNode.xScale
        let tier: Int = scale > 1.5 ? 0 : scale >= 0.8 ? 1 : 2

        currentLabelTier = tier
        applyLabelTier(tier)
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

    // MARK: - Node sprites

    private func addNodeSprite(_ node: Node, isNew: Bool, spawnPoint: CGPoint? = nil, stagger: TimeInterval = 0) {
        let radius = bubbleRadius(for: node)
        let shape = makeShape(
            radius: radius,
            fillColor: bubbleColor(for: node),
            isMeta: node.isMeta,
            nodeID: node.id
        )
        shape.name = "node:\(node.id)"

        let labelNode = makeTitleLabel(text: node.title, radius: radius)
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
    }

    private func updateNodeSprite(_ node: Node) {
        guard let shape = nodeSprites[node.id] else { return }
        shape.fillColor = bubbleColor(for: node).withAlphaComponent(node.isMeta ? 0.55 : 1.0)
        // Title label update
        if let label = shape.children.first(where: { $0.name == "titleLabel" }) as? SKLabelNode {
            label.text = node.title
            label.userData = ["fullTitle": node.title]
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
        shape.physicsBody = body

        // Position: random near center (no stored layout for Über-nodes yet)
        let finalPosition = CGPoint(
            x: CGFloat.random(in: -80...80),
            y: CGFloat.random(in: -80...80)
        )
        shape.position = finalPosition

        addChild(shape)
        uberNodeSprites[cluster.id] = shape

        // Slower breathing animation
        startUberNodeBreathing(for: shape, clusterID: cluster.id, radius: radius)
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
        for touch in touches {
            activeTouches[touch] = touch.location(in: view)
        }
        if activeTouches.count == 1, let touch = touches.first {
            tapStartInfo = (screenPoint: touch.location(in: view), time: CACurrentMediaTime())
        }
        if activeTouches.count >= 2 {
            let pts = Array(activeTouches.values)
            lastPinchDistance = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
            tapStartInfo = nil  // cancel tap if two fingers
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }

        let touchCount = activeTouches.count

        if touchCount == 1, let touch = touches.first {
            let current = touch.location(in: view)
            activeTouches[touch] = current

            // Hover-browse mode: hit-test for node under touch
            let touchLocation = touch.location(in: self)
            if let body = physicsWorld.body(at: touchLocation),
               let node = body.node as? SKShapeNode {
                // Found a node under touch
                if node != hoveredNode {
                    // Reset previous hovered node
                    if let prevNode = hoveredNode {
                        let scaleDown = SKAction.scale(to: 1.0, duration: 0.2)
                        scaleDown.timingMode = .easeInEaseOut
                        prevNode.run(scaleDown)
                        // Re-enable physics
                        prevNode.physicsBody?.isDynamic = true
                        prevNode.userData?["forceLabelTier"] = nil

                        // Snap back displaced neighbors
                        for (neighbor, storedPosition) in snapBackPositions {
                            neighbor.physicsBody?.isDynamic = false
                            let moveBack = SKAction.move(to: storedPosition, duration: 0.3)
                            moveBack.timingMode = .easeOut
                            neighbor.run(moveBack) {
                                neighbor.physicsBody?.isDynamic = true
                            }
                        }
                        snapBackPositions.removeAll()
                    }

                    // Freeze physics (node becomes static while hovered)
                    node.physicsBody?.isDynamic = false

                    // Scale up new node with easing
                    let scaleUp = SKAction.scale(to: 3.0, duration: 0.2)
                    scaleUp.timingMode = .easeInEaseOut
                    node.run(scaleUp)

                    // Set force label tier
                    if node.userData == nil {
                        node.userData = NSMutableDictionary()
                    }
                    node.userData?["forceLabelTier"] = 2

                    // Haptic feedback
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()

                    // Update reference
                    hoveredNode = node

                    // One-shot neighbor position snapshotting at hover entry
                    let threshold = 350 / cameraNode.xScale
                    for (_, neighborShape) in nodeSprites {
                        // Skip the hovered node itself
                        if neighborShape === node { continue }

                        // Check distance
                        let dx = neighborShape.position.x - node.position.x
                        let dy = neighborShape.position.y - node.position.y
                        let distance = sqrt(dx * dx + dy * dy)

                        if distance <= threshold {
                            snapBackPositions[neighborShape] = neighborShape.position
                            print("[HoverBrowse] Snapshotted neighbor at distance \(distance)")
                        }
                    }
                }
            } else {
                // No node under touch, reset any hovered node
                if let prevNode = hoveredNode {
                    let scaleDown = SKAction.scale(to: 1.0, duration: 0.2)
                    scaleDown.timingMode = .easeInEaseOut
                    prevNode.run(scaleDown)
                    // Re-enable physics
                    prevNode.physicsBody?.isDynamic = true
                    prevNode.userData?["forceLabelTier"] = nil
                    hoveredNode = nil

                    // Snap back displaced neighbors
                    for (neighbor, storedPosition) in snapBackPositions {
                        neighbor.physicsBody?.isDynamic = false
                        let moveBack = SKAction.move(to: storedPosition, duration: 0.3)
                        moveBack.timingMode = .easeOut
                        neighbor.run(moveBack) {
                            neighbor.physicsBody?.isDynamic = true
                        }
                    }
                    snapBackPositions.removeAll()
                }
            }

            // Cancel pending tap if finger moved beyond threshold
            if let info = tapStartInfo {
                let moved = hypot(current.x - info.screenPoint.x, current.y - info.screenPoint.y)
                if moved > 8 { tapStartInfo = nil }
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

                // Clean up hover-browse state
                if let node = hoveredNode {
                    let scaleDown = SKAction.scale(to: 1.0, duration: 0.2)
                    scaleDown.timingMode = .easeInEaseOut
                    node.run(scaleDown)
                    // Re-enable physics
                    node.physicsBody?.isDynamic = true
                    node.userData?["forceLabelTier"] = nil
                    hoveredNode = nil

                    // Snap back displaced neighbors
                    for (neighbor, storedPosition) in snapBackPositions {
                        neighbor.physicsBody?.isDynamic = false
                        let moveBack = SKAction.move(to: storedPosition, duration: 0.3)
                        moveBack.timingMode = .easeOut
                        neighbor.run(moveBack) {
                            neighbor.physicsBody?.isDynamic = true
                        }
                    }
                    snapBackPositions.removeAll()
                }
            }
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

        // Check for Über-node tap first
        if let shape = uberNodeSprites.values.first(where: { $0.contains(scenePoint) }),
           let name = shape.name,
           name.hasPrefix("uber:") {
            let clusterID = String(name.dropFirst(5))

            if isDoubleTap {
                // Double-tap: drill into Über-node
                DispatchQueue.main.async { [weak self] in
                    self?.canvasState?.drilledInto = clusterID
                }
            } else {
                // Single tap: center and zoom (universal behavior)
                if zoomedNodeID == nil {
                    centerAndZoomNode(clusterID)
                    DispatchQueue.main.async { [weak self] in
                        self?.canvasState?.selectedNodeID = clusterID
                    }
                }
            }
        } else if let shape = nodeSprites.values.first(where: { $0.contains(scenePoint) }),
                  let name = shape.name,
                  name.hasPrefix("node:") {
            let nodeID = String(name.dropFirst(5))

            // If already zoomed, tapping the zoomed node does nothing
            // (tap outside will dismiss via the else branch)
            if zoomedNodeID == nil {
                // Zoom in on this node
                centerAndZoomNode(nodeID)
                DispatchQueue.main.async { [weak self] in
                    self?.canvasState?.selectedNodeID = nodeID
                }
            }
        } else {
            // Tap on empty space
            if isDoubleTap && canvasState?.drilledInto != nil {
                // Double-tap on empty space while drilled in: exit drill-down
                DispatchQueue.main.async { [weak self] in
                    self?.canvasState?.drilledInto = nil
                }
            } else if zoomedNodeID != nil {
                // Single tap: reset zoom
                resetZoom()
            } else {
                // Single tap: deselect
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

        // Clean up hover-browse state
        if let node = hoveredNode {
            let scaleDown = SKAction.scale(to: 1.0, duration: 0.2)
            scaleDown.timingMode = .easeInEaseOut
            node.run(scaleDown)
            // Re-enable physics
            node.physicsBody?.isDynamic = true
            node.userData?["forceLabelTier"] = nil
            hoveredNode = nil

            // Snap back displaced neighbors
            for (neighbor, storedPosition) in snapBackPositions {
                neighbor.physicsBody?.isDynamic = false
                let moveBack = SKAction.move(to: storedPosition, duration: 0.3)
                moveBack.timingMode = .easeOut
                neighbor.run(moveBack) {
                    neighbor.physicsBody?.isDynamic = true
                }
            }
            snapBackPositions.removeAll()
        }
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
