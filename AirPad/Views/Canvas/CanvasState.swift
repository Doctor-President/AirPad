import Foundation
import Observation

/// Observable bridge between the SpriteKit scene and the SwiftUI canvas layer.
/// The scene writes to this; CanvasView reads from it.
@Observable
@MainActor
final class CanvasState {
    /// ID of the node the user last tapped, or nil when nothing is selected.
    var selectedNodeID: String? = nil
}
