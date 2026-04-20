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

    /// Call whenever CorpusStore.nodes or tags change.
    /// tagColors: map of tag name → UIColor for bubble coloring.
    func syncNodes(
        _ nodes: [Node],
        layoutPositions: [String: CanvasPosition],
        tagColors: [String: UIColor] = [:],
        newNodeID: String? = nil
    ) {
        self.tagColors = tagColors
        positionMap = layoutPositions

        let incomingIDs = Set(nodes.map { $0.id })
        let existingIDs = Set(nodeSprites.keys)

        // Remove deleted nodes
        for id in existingIDs.subtracting(incomingIDs) {
            nodeSprites[id]?.removeFromParent()
            nodeSprites.removeValue(forKey: id)
        }

        // Add or update
        for node in nodes {
            if nodeSprites[node.id] == nil {
                addNodeSprite(node, isNew: node.id == newNodeID)
            } else {
                updateNodeSprite(node)
            }
        }
    }

    // MARK: - Private state

    private var cameraNode = SKCameraNode()
    private var nodeSprites: [String: SKShapeNode] = [:]
    private var positionMap: [String: CanvasPosition] = [:]

    private var tagColors: [String: UIColor] = [:]

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
            color = mix(color, highlight, a5);

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

            gl_FragColor = vec4(color, 1.0);
        }
        """
        let shader = SKShader(source: src)

        // Set default glow parameters
        shader.uniforms = [
            SKUniform(name: "u_glow_reach", float: 12.0),
            SKUniform(name: "u_glow_intensity", float: 0.5),
            SKUniform(name: "u_glow_falloff", float: 3.0),
            SKUniform(name: "u_glow_tint", vectorFloat3: vector_float3(1.0, 0.95, 0.9))
        ]

        print("[Shader] Gradient + inner glow shader created")
        return shader
    }()

    // Touch tracking
    private var activeTouches: [UITouch: CGPoint] = [:]    // screen-space positions
    private var tapStartInfo: (screenPoint: CGPoint, time: TimeInterval)?
    private var lastPinchDistance: CGFloat?

    // Shader animation state
    private var shaderStartTime: TimeInterval = 0
    private var lastUpdateTime: TimeInterval = 0

    // MARK: - Scene lifecycle

    override func didMove(to view: SKView) {
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
        // Update shader u_time uniform for gradient sweep animation
        let elapsed = currentTime - shaderStartTime
        nodeFillShader.uniforms.first(where: { $0.name == "u_time" })?.floatValue = Float(elapsed)
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

    // MARK: - Node sprites

    private func addNodeSprite(_ node: Node, isNew: Bool) {
        let radius = bubbleRadius(for: node)
        let shape = makeShape(radius: radius, fillColor: bubbleColor(for: node), isMeta: node.isMeta)
        shape.name = "node:\(node.id)"

        let label = makeTitleLabel(text: node.title, offsetY: -(radius + 6))
        shape.addChild(label)

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
        shape.physicsBody = body

        // Position: stored layout or random near center
        let finalPosition = storedPosition(for: node.id)
        shape.position = finalPosition

        if isNew {
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
            addChild(shape)
            nodeSprites[node.id] = shape
        }
    }

    private func updateNodeSprite(_ node: Node) {
        guard let shape = nodeSprites[node.id] else { return }
        shape.fillColor = bubbleColor(for: node).withAlphaComponent(node.isMeta ? 0.55 : 1.0)
        // Title label update (first label child = the title)
        let labels = shape.children.compactMap { $0 as? SKLabelNode }
        if let titleLabel = labels.first(where: { $0.position.y < 0 }) {
            titleLabel.text = node.title
        }
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

    // MARK: - Helpers

    private func makeShape(radius: CGFloat, fillColor: UIColor, isMeta: Bool = false) -> SKShapeNode {
        let shape = SKShapeNode(circleOfRadius: radius)
        shape.fillColor = isMeta ? fillColor.withAlphaComponent(0.55) : fillColor
        shape.zPosition = 1

        if isMeta {
            // Dashed border: use a UIBezierPath with dash pattern converted to CGPath
            let bezier = UIBezierPath()
            bezier.addArc(withCenter: .zero, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            bezier.setLineDash([5, 4], count: 2, phase: 0)
            shape.path = bezier.cgPath
            shape.strokeColor = UIColor(red: 0.7, green: 0.5, blue: 1.0, alpha: 0.7)  // soft purple
            shape.lineWidth = 1.5
        } else {
            shape.strokeColor = UIColor.white.withAlphaComponent(0.12)
            shape.lineWidth = 1
            // Gradient fill shader — requires a non-nil fillTexture so v_tex_coord is valid
            shape.fillTexture = whiteUVTexture
            shape.fillShader = nodeFillShader
            print("[Shader] Applied to node - fillTexture: \(shape.fillTexture != nil), fillShader: \(shape.fillShader != nil), fillColor: \(shape.fillColor)")
        }
        return shape
    }

    private func makeTitleLabel(text: String, offsetY: CGFloat) -> SKLabelNode {
        let label = SKLabelNode(text: text)
        label.fontSize = 10
        label.fontName = "HelveticaNeue"
        label.fontColor = UIColor.white.withAlphaComponent(0.65)
        label.verticalAlignmentMode = .top
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: offsetY)
        label.preferredMaxLayoutWidth = 80
        label.numberOfLines = 1
        label.zPosition = 2
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
            // Read previous position BEFORE updating activeTouches — otherwise delta is always zero.
            let prev = activeTouches[touch] ?? touch.location(in: view)
            let current = touch.location(in: view)
            activeTouches[touch] = current

            let dx = current.x - prev.x
            let dy = current.y - prev.y
            cameraNode.position.x -= dx * cameraNode.xScale
            cameraNode.position.y += dy * cameraNode.yScale

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
        if let shape = nodeSprites.values.first(where: { $0.contains(scenePoint) }),
           let name = shape.name,
           name.hasPrefix("node:") {
            let nodeID = String(name.dropFirst(5))
            DispatchQueue.main.async { [weak self] in
                self?.canvasState?.selectedNodeID = nodeID
            }
        } else {
            // Tap on empty space — deselect
            DispatchQueue.main.async { [weak self] in
                self?.canvasState?.selectedNodeID = nil
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches.removeValue(forKey: touch) }
        lastPinchDistance = nil
        tapStartInfo = nil
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
