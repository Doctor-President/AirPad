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

    /// ID of the focal node during honeycomb engagement (set while the user is
    /// hold-and-drag interacting). Nil otherwise. Distinct from `selectedNodeID`,
    /// which is the tap target for full-zoom transitions.
    var currentFocalNodeID: String? = nil

    /// Screen-space center of the engaged focal node, updated each frame so the
    /// SwiftUI gradient overlay tracks the node as it moves under the user's drag.
    var focalNodeScreenPosition: CGPoint = .zero

    /// Screen-space diameter of the engaged focal node, accounting for SpriteKit
    /// scale + camera zoom so the SwiftUI overlay matches the canvas node visually.
    var focalNodeDiameter: CGFloat = 0

    /// ID of the previously-focal node while it shrinks back into the corpus
    /// during preCollapse and disengaging. Lets the SwiftUI overlay remain
    /// parented to the sprite as it animates back to its resting state, so the
    /// gradient fade follows the shrink instead of cutting at full size.
    /// `focalNodeScreenPosition` and `focalNodeDiameter` are kept up to date
    /// against this id while it's set; `currentFocalNodeID` is nil.
    var disengagingFocalNodeID: String? = nil

    /// ID of the Über-node the user has drilled into, or nil when viewing the full canvas.
    var drilledInto: String? = nil

    /// Node ID to push to detail view via navigationPath (set by grace tap).
    var pendingNavigationNodeID: String? = nil

    /// Per-persistent-cluster bag centroid in **screen-space points**,
    /// written each scene tick by `CorpusPhysicsScene.syncClusterCentroidsToCanvasState`.
    /// The SwiftUI `clusterLabelOverlay` reads this to position the
    /// frosted-pill labels. Screen-space because SwiftUI does not know
    /// about the SK camera transform; centroids written here have already
    /// been converted via `view.convert(_:from: scene)`.
    ///
    /// We keep this as the bridge (rather than rendering labels in SK)
    /// because `.ultraThinMaterial` blur is not reproducible in raw
    /// SpriteKit without a full custom render pass. Tradeoffs: the
    /// SwiftUI overlay sits above strands (SK z=500) too — partial
    /// z-order regression vs the all-SK approach — and SwiftUI's render
    /// pass typically runs before the embedded SKView's pass, so during
    /// fast pan/zoom the overlay reads a 1-frame-stale centroid.
    var clusterCentroidScreenPositions: [UUID: CGPoint] = [:]
}
