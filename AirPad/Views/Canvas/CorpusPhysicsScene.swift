import SpriteKit
import UIKit

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

    /// Animate all existing sprites to new positions in a cascading wave.
    func rearrangeToPositions(_ positions: [String: CGPoint]) {
        let ids = Array(positions.keys)
        for (index, nodeID) in ids.enumerated() {
            guard let shape = nodeSprites[nodeID], let target = positions[nodeID] else { continue }
            shape.physicsBody?.velocity = .zero
            shape.physicsBody?.angularVelocity = 0

            let cascadeDelay = Double(index) / Double(max(ids.count, 1)) * 1.5
            let jitter = Double.random(in: 0...0.15)
            let move = SKAction.move(to: target, duration: 0.65)
            move.timingMode = .easeInEaseOut
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
        let cols = 9
        let rows = 14
        let spacingX: CGFloat = 68
        let spacingY: CGFloat = 68
        let originX = -CGFloat(cols - 1) * spacingX / 2
        let originY = -CGFloat(rows - 1) * spacingY / 2

        for row in 0..<rows {
            for col in 0..<cols {
                let jitterX = spacingX * CGFloat.random(in: -0.18...0.18)
                let jitterY = spacingY * CGFloat.random(in: -0.18...0.18)
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
        let dot = SKShapeNode(circleOfRadius: 2.2)
        dot.strokeColor = .clear
        if isDarkMode {
            // Solar Flare: luminous prismatic — warm spectrum
            let hue = CGFloat.random(in: 0.0...0.18)
            let sat = CGFloat.random(in: 0.65...0.90)
            dot.fillColor = UIColor(hue: hue, saturation: sat, brightness: 1.0,
                                    alpha: CGFloat.random(in: 0.50...0.75))
        } else {
            // Cucumber Water: barely-there iridescence — cool spectrum
            let hue = CGFloat.random(in: 0.12...0.65)
            let sat = CGFloat.random(in: 0.15...0.40)
            dot.fillColor = UIColor(hue: hue, saturation: sat, brightness: 0.55,
                                    alpha: CGFloat.random(in: 0.18...0.38))
        }
        return dot
    }

    private func animateDot(_ dot: SKShapeNode, origin: CGPoint) {
        // Scale oscillation — random period and phase
        let period = Double.random(in: 3.0...6.0)
        let phase  = Double.random(in: 0...period)
        let hi: CGFloat = CGFloat.random(in: 1.3...1.65)
        let lo: CGFloat = CGFloat.random(in: 0.55...0.80)
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

        let path = blobPath(for: node.id, radius: radius)
        let shape = makeBlobShape(path: path, fillColor: bubbleColor(for: node), isMeta: node.isMeta)
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

        if isNew {
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

        let newRadius = bubbleRadius(for: node)
        let oldRadius = bubbleBaseRadii[node.id] ?? newRadius

        shape.fillColor = bubbleColor(for: node).withAlphaComponent(node.isMeta ? 0.55 : 1.0)

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
        let n = 7
        var pts: [CGPoint] = []
        for i in 0..<n {
            let angle = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            let r = radius * CGFloat.random(in: 0.85...1.15)
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

    private func makeBlobShape(path: CGPath, fillColor: UIColor, isMeta: Bool = false) -> SKShapeNode {
        let shape = SKShapeNode(path: path)
        shape.fillColor = isMeta ? fillColor.withAlphaComponent(0.55) : fillColor
        shape.zPosition = 1
        if isMeta {
            shape.strokeColor = UIColor(red: 0.7, green: 0.5, blue: 1.0, alpha: 0.7)
            shape.lineWidth = 1.5
        } else {
            shape.strokeColor = UIColor.white.withAlphaComponent(0.12)
            shape.lineWidth = 1
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
        if let primaryTag = node.tags.first, let color = tagColors[primaryTag] {
            print("[AirPad][bubbleColor] ✓ node=\(node.id.prefix(6)) tag='\(primaryTag)' color=\(color)")
            return color
        }
        print("[AirPad][bubbleColor] GREY node=\(node.id.prefix(6)) nodeTags=\(node.tags) availableKeys=\(Array(tagColors.keys))")
        return UIColor(red: 0.556, green: 0.556, blue: 0.576, alpha: 1.0)
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
