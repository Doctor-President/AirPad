import SpriteKit
import UIKit

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
            move.timingMode = .easeInOut
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

    // Touch tracking
    private var activeTouches: [UITouch: CGPoint] = [:]    // screen-space positions
    private var tapStartInfo: (screenPoint: CGPoint, time: TimeInterval)?
    private var lastPinchDistance: CGFloat?

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
