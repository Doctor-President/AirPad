import SpriteKit
import UIKit
import CoreImage

/// The SpriteKit physics canvas that renders nodes as floating blobs on a living dot-field substrate.
/// Owned by CanvasView; communicates selection events back via CanvasState.
final class CorpusPhysicsScene: SKScene {

    // MARK: - Public interface

    var canvasState: CanvasState?

    var spriteCount: Int { nodeSprites.count }

    /// True = Solar Flare (dark); false = Cucumber Water (light).
    var isDarkMode: Bool = true {
        didSet { if oldValue != isDarkMode { rebuildDotField() } }
    }

    /// Animate all existing sprites to new positions in a spring-settling cascade wave.
    func rearrangeToPositions(_ positions: [String: CGPoint]) {
        let ids = Array(positions.keys)
        for (index, nodeID) in ids.enumerated() {
            guard let shape = nodeSprites[nodeID], let target = positions[nodeID] else { continue }
            shape.physicsBody?.velocity = .zero
            shape.physicsBody?.angularVelocity = 0

            let cascadeDelay = Double(index) / Double(max(ids.count, 1)) * 1.5
            let jitter = Double.random(in: 0...0.2)
            let duration = 1.8 + Double.random(in: 0...0.4)
            let move = SKAction.move(to: target, duration: duration)
            // Damped spring: f(t) = 1 - exp(-8t)·cos(12t) — overshoots ~12%, settles by t=1
            move.timingFunction = { t in
                let ft = 1.0 - exp(-8.0 * Double(t)) * cos(12.0 * Double(t))
                return Float(ft)
            }
            shape.run(.sequence([.wait(forDuration: cascadeDelay + jitter), move]),
                      withKey: "rearrange")
        }
    }

    /// Call whenever CorpusStore.nodes or tags change.
    func syncNodes(
        _ nodes: [Node],
        layoutPositions: [String: CanvasPosition],
        tagColors: [String: UIColor] = [:],
        newNodeID: String? = nil
    ) {
        print("[AirPad][syncNodes] nodes=\(nodes.count) tagColors=\(tagColors.count) keys=\(Array(tagColors.keys))")
        self.tagColors = tagColors
        positionMap = layoutPositions

        let incomingIDs = Set(nodes.map { $0.id })
        let existingIDs = Set(nodeSprites.keys)

        for id in existingIDs.subtracting(incomingIDs) {
            nodeSprites[id]?.removeFromParent()
            nodeSprites.removeValue(forKey: id)
            blobPaths.removeValue(forKey: id)
            bubbleBaseRadii.removeValue(forKey: id)
            glowSprites[id]?.removeFromParent()
            glowSprites.removeValue(forKey: id)
        }

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

    // Blob geometry
    private var blobPaths: [String: CGPath] = [:]
    private var bubbleBaseRadii: [String: CGFloat] = [:]

    // Per-node base hue for prismatic glow (untagged/neutral nodes)
    private var nodeDefaultHues: [String: CGFloat] = [:]

    // Edge glow nodes — siblings of main sprites, synced in update()
    private var glowSprites: [String: SKEffectNode] = [:]

    // Dot field
    private var dotFieldLayer = SKNode()

    // Touch tracking
    private var activeTouches: [UITouch: CGPoint] = [:]
    private var tapStartInfo: (screenPoint: CGPoint, time: TimeInterval)?
    private var lastPinchDistance: CGFloat?

    // Update loop state
    private var lastLabelScale: CGFloat = -1
    private var ambientDriftTimer: TimeInterval = 0

    // MARK: - Scene lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        physicsWorld.gravity = .zero
        physicsWorld.speed = 1.0

        addChild(cameraNode)
        camera = cameraNode

        let boundary = CGRect(x: -1500, y: -1500, width: 3000, height: 3000)
        physicsBody = SKPhysicsBody(edgeLoopFrom: boundary)

        view.isMultipleTouchEnabled = true

        setupDotField()
    }

    // MARK: - Dot field substrate

    private func setupDotField() {
        dotFieldLayer.zPosition = -5
        addChild(dotFieldLayer)
        buildDotField()
    }

    private func rebuildDotField() {
        dotFieldLayer.removeAllChildren()
        buildDotField()
    }

    private func buildDotField() {
        // Moleskine dot journal aesthetic: tiny, dense, barely-perceptible grid
        let cols = 24
        let rows = 46
        let spacingX: CGFloat = 20
        let spacingY: CGFloat = 20
        let originX = -CGFloat(cols - 1) * spacingX / 2
        let originY = -CGFloat(rows - 1) * spacingY / 2

        for row in 0..<rows {
            for col in 0..<cols {
                let jitterX = spacingX * CGFloat.random(in: -0.15...0.15)
                let jitterY = spacingY * CGFloat.random(in: -0.15...0.15)
                let position = CGPoint(
                    x: originX + CGFloat(col) * spacingX + jitterX,
                    y: originY + CGFloat(row) * spacingY + jitterY
                )
                let dot = makeDotNode()
                dot.position = position
                animateDot(dot, origin: position)
                dotFieldLayer.addChild(dot)
            }
        }
    }

    private func makeDotNode() -> SKShapeNode {
        let radius = CGFloat.random(in: 1.5...2.0)
        let dot = SKShapeNode(circleOfRadius: radius)
        dot.strokeColor = .clear
        if isDarkMode {
            // Solar Flare: warm prismatic — muted at small size
            let hue = CGFloat.random(in: 0.0...0.20)
            let sat = CGFloat.random(in: 0.55...0.80)
            dot.fillColor = UIColor(hue: hue, saturation: sat, brightness: 1.0,
                                    alpha: CGFloat.random(in: 0.30...0.55))
        } else {
            // Cucumber Water: barely-there iridescent — cool spectrum
            let hue = CGFloat.random(in: 0.12...0.65)
            let sat = CGFloat.random(in: 0.12...0.35)
            dot.fillColor = UIColor(hue: hue, saturation: sat, brightness: 0.45,
                                    alpha: CGFloat.random(in: 0.10...0.22))
        }
        return dot
    }

    private func animateDot(_ dot: SKShapeNode, origin: CGPoint) {
        // Subtle scale oscillation ±8% — Moleskine dots breathe, not pulse
        let period = Double.random(in: 4.0...8.0)
        let phase  = Double.random(in: 0...period)
        let hi: CGFloat = CGFloat.random(in: 1.05...1.08)
        let lo: CGFloat = CGFloat.random(in: 0.92...0.95)
        let up = SKAction.scale(to: hi, duration: period / 2)
        up.timingMode = .easeInEaseOut
        let down = SKAction.scale(to: lo, duration: period / 2)
        down.timingMode = .easeInEaseOut
        dot.run(.sequence([.wait(forDuration: phase), SKAction.repeatForever(.sequence([up, down]))]))

        // Positional drift — wander away from origin, never return to exactly same spot
        startDotDrift(dot, anchor: origin)
    }

    private func startDotDrift(_ dot: SKShapeNode, anchor: CGPoint) {
        let duration = Double.random(in: 10...20)
        let amp: CGFloat = 20
        let target = CGPoint(
            x: anchor.x + CGFloat.random(in: -amp...amp),
            y: anchor.y + CGFloat.random(in: -amp...amp)
        )
        let move = SKAction.move(to: target, duration: duration)
        move.timingMode = .easeInEaseOut
        dot.run(move) { [weak self, weak dot] in
            guard let self, let dot else { return }
            self.startDotDrift(dot, anchor: dot.position)
        }
    }

    // MARK: - Node sprites

    private func addNodeSprite(_ node: Node, isNew: Bool) {
        let radius = bubbleRadius(for: node)
        bubbleBaseRadii[node.id] = radius

        // Ensure a stable hue exists before calling bubbleColor (which reads nodeDefaultHues)
        if nodeDefaultHues[node.id] == nil {
            nodeDefaultHues[node.id] = randomPrismaticHue()
        }
        let path = blobPath(for: node.id, radius: radius)
        let shape = makeBlobShape(path: path, fillColor: bubbleColor(for: node), isMeta: node.isMeta, radius: radius)
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

        let finalPosition = storedPosition(for: node.id)
        shape.position = finalPosition

        addBreathe(shape)

        // Start prismatic cycle for untagged or neutral-colored nodes
        if let hue = nodeDefaultHues[node.id], !hasTagColor(node) {
            addPrismaticGlow(shape, baseHue: hue)
        }

        if isNew {
            shape.position = CGPoint(x: finalPosition.x, y: finalPosition.y + 60)
            addChild(shape)
            nodeSprites[node.id] = shape
            if isDarkMode { addGlowNode(for: node.id, path: path, radius: radius) }

            let drop = SKAction.move(to: finalPosition, duration: 0.45)
            drop.timingMode = .easeOut
            shape.run(drop)

            playRipple(at: finalPosition, radius: radius)
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            let dx = CGFloat.random(in: -20...20)
            let dy = CGFloat.random(in: -20...20)
            shape.physicsBody?.applyImpulse(CGVector(dx: dx, dy: dy))
        } else {
            addChild(shape)
            nodeSprites[node.id] = shape
            if isDarkMode { addGlowNode(for: node.id, path: path, radius: radius) }
        }
    }

    private func updateNodeSprite(_ node: Node) {
        guard let shape = nodeSprites[node.id] else { return }

        let newRadius = bubbleRadius(for: node)
        let oldRadius = bubbleBaseRadii[node.id] ?? newRadius

        if hasTagColor(node) {
            // Node now has a real tag color — stop prismatic cycle and use it
            shape.removeAction(forKey: "prismCycle")
            shape.fillColor = bubbleColor(for: node).withAlphaComponent(node.isMeta ? 0.55 : 1.0)
        } else {
            // Still untagged/neutral — ensure prism cycle running
            if nodeDefaultHues[node.id] == nil { nodeDefaultHues[node.id] = randomPrismaticHue() }
            if shape.action(forKey: "prismCycle") == nil, let hue = nodeDefaultHues[node.id] {
                addPrismaticGlow(shape, baseHue: hue)
            }
        }

        // Rebuild blob path if size changed meaningfully
        if abs(newRadius - oldRadius) > 2.0 {
            bubbleBaseRadii[node.id] = newRadius
            blobPaths.removeValue(forKey: node.id)
            shape.path = blobPath(for: node.id, radius: newRadius)
            let body = SKPhysicsBody(circleOfRadius: newRadius)
            body.linearDamping = 0.6
            body.angularDamping = 0.8
            body.friction = 0.1
            body.restitution = 0.25
            body.mass = CGFloat(max(0.5, Float(newRadius / 30)))
            shape.physicsBody = body
            if let lbl = shape.children.compactMap({ $0 as? SKLabelNode }).first(where: { $0.position.y < 0 }) {
                lbl.position = CGPoint(x: 0, y: -(newRadius + 6))
            }
        }

        if let titleLabel = shape.children.compactMap({ $0 as? SKLabelNode }).first(where: { $0.position.y < 0 }) {
            titleLabel.text = node.title
        }
    }

    // MARK: - Blob path generation

    private func blobPath(for nodeID: String, radius: CGFloat) -> CGPath {
        if let cached = blobPaths[nodeID] { return cached }
        let path = generateBlobPath(radius: radius)
        blobPaths[nodeID] = path
        return path
    }

    private func generateBlobPath(radius: CGFloat) -> CGPath {
        let n = 8
        var pts: [CGPoint] = []
        for i in 0..<n {
            let angle = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            let r = radius * CGFloat.random(in: 0.67...1.33)
            pts.append(CGPoint(x: cos(angle) * r, y: sin(angle) * r))
        }

        let path = CGMutablePath()
        let last = pts[n - 1]
        let first = pts[0]
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for i in 0..<n {
            let cur  = pts[i]
            let next = pts[(i + 1) % n]
            path.addQuadCurve(
                to: CGPoint(x: (cur.x + next.x) / 2, y: (cur.y + next.y) / 2),
                control: cur
            )
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Breathing animation

    private func addBreathe(_ shape: SKShapeNode) {
        let phaseDelay = Double.random(in: 0...4.0)
        let hi: CGFloat = 1.035
        let lo: CGFloat = 0.966
        let breatheIn = SKAction.scale(to: hi, duration: 2.2)
        breatheIn.timingMode = .easeInEaseOut
        let breatheOut = SKAction.scale(to: lo, duration: 2.2)
        breatheOut.timingMode = .easeInEaseOut
        shape.run(
            .sequence([.wait(forDuration: phaseDelay), SKAction.repeatForever(.sequence([breatheIn, breatheOut]))]),
            withKey: "breathe"
        )
    }

    // MARK: - Shape factory

    private func makeBlobShape(path: CGPath, fillColor: UIColor, isMeta: Bool = false, radius: CGFloat = 0) -> SKShapeNode {
        let shape = SKShapeNode(path: path)
        shape.zPosition = 1
        if isMeta {
            shape.strokeColor = UIColor(red: 0.7, green: 0.5, blue: 1.0, alpha: 0.7)
            shape.lineWidth = 1.5
        } else {
            shape.strokeColor = UIColor.white.withAlphaComponent(0.08)
            shape.lineWidth = 0.5
        }
        if isDarkMode {
            // fillTexture must be non-nil before assigning fillShader so the GPU
            // emits valid v_tex_coord UV (0→1) instead of undefined zeros.
            shape.fillTexture = whiteUVTexture
            shape.fillColor = isMeta ? fillColor.withAlphaComponent(0.55) : fillColor
            shape.fillShader = nodeFillShader

            // Inner edge glow — 92% scale blob in screen blend, warm cream colour
            var innerTransform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            if let innerPath = path.copy(using: &innerTransform) {
                let innerGlow = SKShapeNode(path: innerPath)
                // #FFE8D5 — warm cream matching the token highlight colour
                innerGlow.fillColor = UIColor(red: 1.0, green: 0.910, blue: 0.835, alpha: 0.55)
                innerGlow.strokeColor = .clear
                innerGlow.blendMode = .screen
                innerGlow.zPosition = 2
                shape.addChild(innerGlow)
            }
        } else {
            shape.fillColor = isMeta ? fillColor.withAlphaComponent(0.55) : fillColor
        }
        return shape
    }

    // MARK: - Solar Flare gradient fill shader

    // A shared 128×128 all-white texture. Setting fillTexture on an SKShapeNode
    // forces the GPU to emit proper 0→1 UV coordinates into v_tex_coord for every
    // fragment. Without a fillTexture, v_tex_coord is undefined (effectively zero
    // everywhere), which makes the shader produce a uniform colour instead of a gradient.
    private lazy var whiteUVTexture: SKTexture = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128))
        let img = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: 128, height: 128)))
        }
        return SKTexture(image: img)
    }()

    // 4-corner palette gradient matching Claude Design tokens.
    // v_tex_coord: (0,0) = bottom-left, (1,1) = top-right (SpriteKit y-up).
    // Corner assignments:   top-left → purple, top-right → ember,
    //                       bottom-left → magenta, bottom-right → coral.
    // Centre is darkened; a warm highlight sheen sits slightly above mid.
    // base.a is preserved so meta-node alpha (0.55) still applies.
    private func makeNodeFillShader() -> SKShader {
        let src = """
        void main() {
            vec4 base = SKDefaultShading();
            vec2 uv = v_tex_coord;

            // Gradient palette — Solar Flare token colours
            vec4 purple   = vec4(0.478, 0.322, 1.000, 1.0);  // #7A52FF top-left
            vec4 coral    = vec4(0.890, 0.420, 0.306, 1.0);  // #E36B4E bottom-right
            vec4 ember    = vec4(0.769, 0.235, 0.165, 1.0);  // #C43C2A top-right
            vec4 magenta  = vec4(0.722, 0.341, 0.831, 1.0);  // #B857D4 bottom-left
            vec4 hilight  = vec4(1.000, 0.843, 0.761, 1.0);  // #FFD7C2 sheen

            // Bilinear corner weights
            float tl = (1.0 - uv.x) * uv.y;        // top-left
            float br = uv.x * (1.0 - uv.y);         // bottom-right
            float tr = uv.x * uv.y;                 // top-right
            float bl = (1.0 - uv.x) * (1.0 - uv.y);// bottom-left

            vec4 col = purple * tl + coral * br + ember * tr + magenta * bl;

            // Centre darkening — light comes from the perimeter
            float dist = distance(uv, vec2(0.5));
            col = mix(col * 0.62, col, smoothstep(0.0, 0.5, dist));

            // Warm highlight sheen — slightly above centre
            float sheen = exp(-distance(uv, vec2(0.5, 0.62)) * 8.0);
            col += hilight * sheen * 0.45;

            gl_FragColor = vec4(clamp(col.rgb, 0.0, 1.0), base.a);
        }
        """
        return SKShader(source: src)
    }

    // Shared shader instance — create once, reuse across all nodes.
    private lazy var nodeFillShader: SKShader = makeNodeFillShader()

    // MARK: - Solar Flare edge glow

    private func addGlowNode(for nodeID: String, path: CGPath, radius: CGFloat) {
        let effect = SKEffectNode()
        effect.shouldRasterize = true
        // blurNodeHalo = 36px per token spec
        effect.filter = CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": 36 as NSNumber])

        let glowBlob = SKShapeNode(path: path)
        glowBlob.fillColor = UIColor.white.withAlphaComponent(0.20)
        glowBlob.strokeColor = .clear
        glowBlob.setScale(1.22)
        effect.addChild(glowBlob)

        effect.zPosition = 0.8
        addChild(effect)
        glowSprites[nodeID] = effect
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

    // MARK: - Per-frame update

    override func update(_ currentTime: TimeInterval) {
        // Zoom-aware label visibility — only recalculate when scale changes meaningfully
        let scale = cameraNode.xScale
        if abs(scale - lastLabelScale) > 0.06 {
            lastLabelScale = scale
            updateLabelVisibility(cameraScale: scale)
        }

        // Sync edge-glow positions to their blob sprites (Solar Flare only)
        if isDarkMode {
            for (id, shape) in nodeSprites {
                glowSprites[id]?.position = shape.position
            }
        }

        // Ambient drift — gentle impulses every few seconds
        if currentTime - ambientDriftTimer > 4.0 {
            ambientDriftTimer = currentTime
            for (_, shape) in nodeSprites {
                let dx = CGFloat.random(in: -3.5...3.5)
                let dy = CGFloat.random(in: -3.5...3.5)
                shape.physicsBody?.applyImpulse(CGVector(dx: dx, dy: dy))
            }
        }
    }

    private func updateLabelVisibility(cameraScale: CGFloat) {
        let show = cameraScale < 2.5
        for (_, shape) in nodeSprites {
            for child in shape.children {
                guard let lbl = child as? SKLabelNode, lbl.position.y < 0 else { continue }
                lbl.alpha = show ? 0.65 : 0.0
            }
        }
    }

    // MARK: - Helpers

    private func bubbleRadius(for node: Node) -> CGFloat {
        let extra = CGFloat(max(0, node.items.count - 1)) * 4.0
        return min(30.0 + extra, 60.0)
    }

    private func bubbleColor(for node: Node) -> UIColor {
        if let primaryTag = node.tags.first,
           let color = tagColors[primaryTag],
           !isNeutralGrey(color) {
            print("[AirPad][bubbleColor] ✓ node=\(node.id.prefix(6)) tag='\(primaryTag)' color=\(color)")
            return color
        }
        // Untagged or neutral-tagged: prismatic glow using per-node stored hue
        let hue = nodeDefaultHues[node.id, default: randomPrismaticHue()]
        print("[AirPad][bubbleColor] PRISMATIC node=\(node.id.prefix(6)) hue=\(String(format:"%.2f",hue)) nodeTags=\(node.tags) availableKeys=\(Array(tagColors.keys))")
        return UIColor(hue: hue, saturation: 0.58, brightness: 0.78, alpha: 0.80)
    }

    private func isNeutralGrey(_ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        return abs(r - g) < 0.04 && abs(g - b) < 0.04 && b > 0.45 && b < 0.70
    }

    private func hasTagColor(_ node: Node) -> Bool {
        guard let primaryTag = node.tags.first, let color = tagColors[primaryTag] else { return false }
        return !isNeutralGrey(color)
    }

    private func randomPrismaticHue() -> CGFloat { CGFloat.random(in: 0...1) }

    private func addPrismaticGlow(_ shape: SKShapeNode, baseHue: CGFloat) {
        let period = Double.random(in: 9.0...14.0)
        let cycle = SKAction.customAction(withDuration: period) { node, elapsed in
            guard let s = node as? SKShapeNode else { return }
            let t = elapsed / CGFloat(period)
            let hue = (baseHue + t * 0.15).truncatingRemainder(dividingBy: 1.0)
            s.fillColor = UIColor(hue: hue, saturation: 0.58, brightness: 0.78, alpha: 0.80)
        }
        shape.run(SKAction.repeatForever(cycle), withKey: "prismCycle")
    }

    private func storedPosition(for nodeID: String) -> CGPoint {
        if let pos = positionMap[nodeID] {
            return CGPoint(x: pos.x, y: -pos.y)
        }
        return CGPoint(x: CGFloat.random(in: -60...60), y: CGFloat.random(in: -60...60))
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }
        for touch in touches { activeTouches[touch] = touch.location(in: view) }
        if activeTouches.count == 1, let touch = touches.first {
            tapStartInfo = (screenPoint: touch.location(in: view), time: CACurrentMediaTime())
        }
        if activeTouches.count >= 2 {
            let pts = Array(activeTouches.values)
            lastPinchDistance = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
            tapStartInfo = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view else { return }
        let touchCount = activeTouches.count

        if touchCount == 1, let touch = touches.first {
            let prev    = activeTouches[touch] ?? touch.location(in: view)
            let current = touch.location(in: view)
            activeTouches[touch] = current

            cameraNode.position.x -= (current.x - prev.x) * cameraNode.xScale
            cameraNode.position.y += (current.y - prev.y) * cameraNode.yScale

            if let info = tapStartInfo {
                let moved = hypot(current.x - info.screenPoint.x, current.y - info.screenPoint.y)
                if moved > 8 { tapStartInfo = nil }
            }
        } else if touchCount >= 2 {
            let prevDist = lastPinchDistance
            for touch in touches { activeTouches[touch] = touch.location(in: view) }
            let pts = Array(activeTouches.values)
            let dist = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
            if let prev = prevDist, prev > 0 {
                let factor   = prev / dist
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
            if activeTouches.isEmpty { lastPinchDistance = nil; tapStartInfo = nil }
        }

        guard activeTouches.count == 1,
              let touch = touches.first,
              let info  = tapStartInfo else { return }

        let endPoint = touch.location(in: view)
        let duration = CACurrentMediaTime() - info.time
        let dist     = hypot(endPoint.x - info.screenPoint.x, endPoint.y - info.screenPoint.y)
        guard duration < 0.3, dist < 14 else { return }

        let scenePoint = convertPoint(fromView: endPoint)
        if let shape = nodeSprites.values.first(where: { $0.contains(scenePoint) }),
           let name  = shape.name,
           name.hasPrefix("node:") {
            let nodeID = String(name.dropFirst(5))
            DispatchQueue.main.async { [weak self] in self?.canvasState?.selectedNodeID = nodeID }
        } else {
            DispatchQueue.main.async { [weak self] in self?.canvasState?.selectedNodeID = nil }
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
