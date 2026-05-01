import SwiftUI
import SpriteKit

struct SpriteKitView: UIViewRepresentable {
    let scene: SKScene

    func makeUIView(context: Context) -> SKView {
        let view = SKView()
        scene.isPaused = false
        view.preferredFramesPerSecond = 120
        view.presentScene(scene)
        view.ignoresSiblingOrder = true
        view.isPaused = false
        view.backgroundColor = .clear
        view.allowsTransparency = true
        return view
    }

    func updateUIView(_ uiView: SKView, context: Context) {
        // Keep unpaused on every SwiftUI update
        uiView.isPaused = false
        uiView.scene?.isPaused = false
    }
}
