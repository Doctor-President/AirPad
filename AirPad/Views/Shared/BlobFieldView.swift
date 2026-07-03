import SwiftUI
import UIKit

/// GPU-computed animated blob field — the one primitive behind the lava lamp,
/// and (later stages) the card + hero gradients. Backed by `BlobField.metal`,
/// driven as a SwiftUI `.colorEffect`: N soft radial blobs are computed
/// analytically in the fragment shader, so there is no CPU `Canvas`
/// rasterization and no Core Animation `.blur()` pass. The shader's falloff
/// ramp replaces `.blur(radius:)`.
///
/// Every consumer passes its own `Parameters` — blob count, colors, sizes,
/// softness, drift, and the `sharedField` switch — so cards get small tight
/// fast blobs, the hero gets big slow ones, the lava lamp gets four wide
/// ambient ones. Same engine, different dials.
struct BlobFieldView: View {

    /// One radial blob. `origin`/`radius` are fractions of the view size so
    /// the field scales with whatever surface hosts it.
    struct Blob {
        /// Rest position as a fraction of view size (0...1). The blob drifts
        /// ±0.28 around this via sin/cos.
        var origin: CGPoint
        /// Radius as a fraction of `min(width, height)`.
        var radius: CGFloat
        /// Drift speed on each axis (x uses sin, y uses cos).
        var speed: CGSize
        /// Phase offset so blobs don't move in lockstep.
        var phase: CGFloat
        var color: Color
        /// Peak opacity at the blob center.
        var peak: CGFloat
    }

    struct Parameters {
        var blobs: [Blob]
        /// false → field sampled in the view's own local space (safe default,
        /// matches today's look). true → sampled in global/world space so
        /// sibling surfaces read different slices of one continuous field.
        var sharedField: Bool = false
        /// Animation cadence. 30fps matches the original lava lamp.
        var frameInterval: Double = 1.0 / 30.0
    }

    let parameters: Parameters

    private let packed: [Float]

    init(parameters: Parameters) {
        self.parameters = parameters
        self.packed = Self.pack(parameters.blobs)
    }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            TimelineView(.animation(minimumInterval: parameters.frameInterval)) { timeline in
                // Wrap time to keep Float precision usable across the app's
                // multi-hundred-million-second reference clock (per brief).
                let t = Float(timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1000.0))
                Rectangle()
                    .fill(.black)
                    .colorEffect(
                        ShaderLibrary.blobField(
                            .float(t),
                            .float2(Float(geo.size.width), Float(geo.size.height)),
                            .float2(Float(origin.x), Float(origin.y)),
                            .float(parameters.sharedField ? 1 : 0),
                            .floatArray(packed)
                        )
                    )
            }
        }
    }

    /// Flatten blobs into the `device const float *` layout the shader reads.
    /// Order must match `BLOB_STRIDE`/layout in BlobField.metal.
    private static func pack(_ blobs: [Blob]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(blobs.count * 10)
        for blob in blobs {
            let (r, g, b) = rgb(blob.color)
            out.append(Float(blob.origin.x))
            out.append(Float(blob.origin.y))
            out.append(Float(blob.radius))
            out.append(Float(blob.speed.width))
            out.append(Float(blob.speed.height))
            out.append(Float(blob.phase))
            out.append(Float(blob.peak))
            out.append(r)
            out.append(g)
            out.append(b)
        }
        return out
    }

    private static func rgb(_ color: Color) -> (Float, Float, Float) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Float(r), Float(g), Float(b))
    }
}
