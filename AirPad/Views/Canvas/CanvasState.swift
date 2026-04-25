import Foundation
import Observation
import CoreGraphics

/// Observable bridge between the SpriteKit scene and the SwiftUI canvas layer.
/// The scene writes to this; CanvasView reads from it.
@Observable
@MainActor
final class CanvasState {
    /// ID of the node the user last tapped, or nil when nothing is selected.
    var selectedNodeID: String? = nil

    /// Whether a node is currently zoomed (centered and scaled up).
    var isZoomed: Bool = false

    /// Screen position of the zoomed node (for overlay positioning).
    var zoomedNodeScreenPosition: CGPoint = .zero

    /// Screen diameter of the zoomed node (for overlay sizing).
    var zoomedNodeDiameter: CGFloat = 0

    /// ID of the Über-node the user has drilled into, or nil when viewing the full canvas.
    var drilledInto: String? = nil
}
