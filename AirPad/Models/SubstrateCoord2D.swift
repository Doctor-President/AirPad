import Foundation

/// SB139 Stage 4a — 2D position in the substrate-derived canvas layout.
/// Stored on each Node (`substrateCoord2D`) and inside the persisted
/// `UMAPFittedModel.embeddings2D`. Codable as `{"x": …, "y": …}` JSON.
///
/// Chosen over `SIMD2<Float>` for Codable simplicity. The canvas read side
/// converts to `CGPoint` at the LayoutService boundary in 4c1.
///
/// Lives in `Models/` (not `Services/UMAP/`) because it's a Node property
/// type, not a UMAP internal — UMAP just happens to produce values for it.
/// Target membership: AirPad + AirPadShare (Node carries the field; the
/// share extension encodes Node into the App Group inbox).
struct SubstrateCoord2D: Codable, Hashable {
    var x: Float
    var y: Float

    init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}
