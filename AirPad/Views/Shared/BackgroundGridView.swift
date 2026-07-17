import SwiftUI
import SpriteKit
import UIKit

/// SwiftUI wrapper that hosts the same procedural grid shader used in
/// CorpusPhysicsScene, for screens without a camera (NodeListView, CoverFlowView,
/// VerticalScrollView, NodeGridView). Static uniforms (cameraPosition=(0,0),
/// cameraScale=1.0) so the grid sits fixed in screen space. The dot field is
/// STATIC — the translating value-noise (and its u_time dependence) was removed
/// in c17484a.
///
/// Matches the Map's tuned dot appearance: 0.5px dots on an 83pt period. Those
/// are the Map's baked literals verbatim, not a coincidence — both surfaces run
/// the shader at cameraScale 1.0 (the Map rests at xScale 1.0; it only leaves 1.0
/// via user pinch), and the shader makes screen dot-size scale-invariant and
/// screen-period = period/scale, so the same literals read the same here.
///
/// Dot color + opacity are per-mode (AppearancePalette), pushed from the SwiftUI
/// `colorScheme` through updateUIView — an SKView never receives SwiftUI's
/// environment, so the trait is read up here and pushed down. This fixes the
/// white-only dots (they were the makeShape default, unreadable on light ground).
struct BackgroundGridView: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> SKView {
        let view = SKView()
        view.backgroundColor = .clear
        view.allowsTransparency = true
        view.isOpaque = false
        // Static grid (noise stripped in c17484a — no per-frame content), so it
        // does not need 120fps. 10fps repaints resize + trait flip within ~100ms
        // (imperceptible, and inside the ~0.35s system appearance cross-fade)
        // while cutting idle GPU ~12×. Not paused: a permanently paused SKView
        // wouldn't render the resize/flip uniform pushes at all — the repaint on
        // those two events is exactly what must survive.
        view.preferredFramesPerSecond = 10

        let initialSize = CGSize(width: max(1, view.bounds.width),
                                 height: max(1, view.bounds.height))
        let scene = BackgroundGridScene(size: initialSize)
        scene.backgroundColor = .clear
        scene.scaleMode = .resizeFill
        scene.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        // Map's tuned dot geometry (0.5 / 83 — see the type doc for why the
        // literals transfer). dotOpacity here is only the makeShape seed;
        // pushAppearance immediately overrides it with the per-mode value.
        let grid = BackgroundGridNode.makeShape(
            viewportSize: initialSize,
            fillTexture: Self.whiteUVTexture,
            dotSizePx: 0.5, period: 83
        )
        scene.addChild(grid)
        scene.grid = grid
        pushAppearance(to: grid)   // initial push, so frame 1 isn't the white default

        view.presentScene(scene)
        return view
    }

    func updateUIView(_ uiView: SKView, context: Context) {
        // Re-push per-mode appearance on trait flip. BackgroundGridView reads
        // @Environment(\.colorScheme), so SwiftUI re-invokes updateUIView when
        // dark/light flips; the SKView itself never sees that environment. (Grid
        // resize stays automatic: .resizeFill -> didChangeSize -> resize.)
        if let grid = (uiView.scene as? BackgroundGridScene)?.grid {
            pushAppearance(to: grid)
        }
    }

    /// Push per-mode dot color + opacity via the SAME AppearancePalette tokens
    /// the Map uses (`mapGridDotRGB` + `mapGridDotOpacity`), so list/grid dots
    /// track the theme instead of the white-only makeShape default: dark = white
    /// @0.18, light = graphite #2E3A40 @0.47.
    private func pushAppearance(to grid: SKShapeNode) {
        let dark = colorScheme == .dark
        let dot = AppearancePalette.mapGridDotRGB(dark: dark)
        BackgroundGridNode.setDotAppearance(grid, r: dot.r, g: dot.g, b: dot.b,
                                            opacity: AppearancePalette.mapGridDotOpacity(dark: dark))
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
