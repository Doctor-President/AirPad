import SwiftUI
import SpriteKit

struct SpriteKitView: UIViewRepresentable {
    let scene: SKScene

    func makeUIView(context: Context) -> SKView {
        let view = SKView()
        scene.isPaused = false
        view.presentScene(scene)
        view.ignoresSiblingOrder = true
        view.isPaused = false
        view.backgroundColor = UIColor(red: 0.027, green: 0.027, blue: 0.039, alpha: 1.0)
        return view
    }

    func updateUIView(_ uiView: SKView, context: Context) {
        // Keep unpaused on every SwiftUI update
        uiView.isPaused = false
        uiView.scene?.isPaused = false
    }
}
