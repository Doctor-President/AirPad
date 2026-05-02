import SwiftUI
import SpriteKit
import UIKit

/// SwiftUI wrapper that hosts the same procedural grid shader used in
/// CorpusPhysicsScene, for screens without a camera (list, detail, etc.).
/// Static uniforms (cameraPosition=(0,0), cameraScale=1.0) so the grid sits
/// fixed in screen space; the screen-space noise still animates via u_time.
struct BackgroundGridView: UIViewRepresentable {

    func makeUIView(context: Context) -> SKView {
        let view = SKView()
        view.backgroundColor = .clear
        view.allowsTransparency = true
        view.isOpaque = false
        view.preferredFramesPerSecond = 120

        let initialSize = CGSize(width: max(1, view.bounds.width),
                                 height: max(1, view.bounds.height))
        let scene = BackgroundGridScene(size: initialSize)
        scene.backgroundColor = .clear
        scene.scaleMode = .resizeFill
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let grid = BackgroundGridNode.makeShape(
            viewportSize: initialSize,
            fillTexture: Self.whiteUVTexture
        )
        scene.addChild(grid)
        scene.grid = grid

        view.presentScene(scene)
        return view
    }

    func updateUIView(_ uiView: SKView, context: Context) {
        // SKScene .resizeFill -> didChangeSize -> grid resize, all automatic.
    }

    /// Shared 128x128 white texture for SKShapeNode.fillShader UV validity.
    private static let whiteUVTexture: SKTexture = {
        let size = CGSize(width: 128, height: 128)
        UIGraphicsBeginImageContext(size)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return SKTexture(image: img)
    }()
}

private final class BackgroundGridScene: SKScene {
    weak var grid: SKShapeNode?

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard let grid = grid else { return }
        BackgroundGridNode.resize(grid, to: size)
    }
}
