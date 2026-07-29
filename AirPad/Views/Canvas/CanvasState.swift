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

    /// Screen-space diameter the focal node settles at (the lens' full focal
    /// size, constant per screen width). The overlay renders the focal TITLE at
    /// this size so the type doesn't reflow as the node grows in.
    var focalNodeFinalDiameter: CGFloat = 0

    /// How far the focal has grown, 0 (resting) → 1 (full focal size). The ONE
    /// CLOCK for focal presentation: the overlay text opacity is slaved to it,
    /// so a fast graze (focal never fully grows) never lets text linger, and on
    /// release it fades in lockstep with the shrink.
    var focalScaleProgress: CGFloat = 0

    /// Hex of the focal node's rendered shade (territory tint in Map mode, else
    /// its base fill). The focal bubble builds its subtle DIAGONAL two-stop wash
    /// from this — one hue, light→dark, clamped out of the mid-luminance dead zone.
    var focalNodeShadeHex: String? = nil

    /// Bubble→card morph amount, 0 (bubble) → 1 (full card face), eased off the
    /// tail of `focalScaleProgress`: the focal grows as a bubble, then morphs
    /// into the node's actual Card View face once mostly grown. Release runs it
    /// back to 0 (card → bubble). Drives both the overlay morph and the
    /// solidity-law card footprint.
    var focalMorph: CGFloat = 0

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

    /// ID of the node whose CARD is presented — set by a clean COMMITTING tap on
    /// an orb, cleared by tapping empty or the card's X. Drives the focal card
    /// overlay: the scene reads it each frame and eases the bubble→card morph
    /// (`focalScaleProgress`/`focalMorph`). Browse (graze) never sets it — only a
    /// tap does. Tapping another orb while carded reassigns it (neighbor-hop).
    var cardedNodeID: String? = nil

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

    /// Tag-anchored Map — resolved territory name labels in **screen-space**,
    /// written each scene tick by `syncTerritoryLabelsToCanvasState`. The
    /// SwiftUI `territoryLabelOverlay` renders these as real
    /// `.ultraThinMaterial` glass pills (Source Serif 4) above the SpriteKitView
    /// — same overlay pattern as the cluster labels, for the same reason (SK
    /// can't reproduce the system blur). Empty in every non-Map mode.
    var territoryLabels: [TerritoryLabelInfo] = []

    /// One territory name pill: its name, palette stroke color (hex literal, per
    /// the colorblind house rule), and screen-space center.
    struct TerritoryLabelInfo: Identifiable, Equatable {
        let key: String
        let name: String
        let colorHex: String
        let screenPosition: CGPoint
        /// Region-label zoom fade [0,1], computed in the scene from `cameraScale`
        /// via the SAME `smoothstepClamp` curve the per-orb label LOD uses — so
        /// region labels are the macro complement of node labels (full at rest /
        /// zoomed out, fading as you zoom in and node labels take over). Carried
        /// here (already bridged per-frame) so the pill needs no separate
        /// cameraScale reader. Defaults to 1 for any producer that omits it.
        var lodAlpha: CGFloat = 1
        /// Material (capsule fill + stroke + shadow) fade, SEPARATE from the text
        /// `lodAlpha`. As the pill nears its floor the MATERIAL drops to 0 while the
        /// text persists faintly — the fill is what obscures a node title; faint
        /// text alone is near-harmless (T, ws-map-labels 2026-07-29). Both computed
        /// in-scene on the shared curve; the pill applies `lodAlpha` to its text and
        /// `materialAlpha` to its capsule/stroke/shadow. Defaults to 1.
        var materialAlpha: CGFloat = 1
        var id: String { key }
    }
}
