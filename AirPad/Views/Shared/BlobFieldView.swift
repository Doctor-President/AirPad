import SwiftUI
import UIKit

/// GPU-computed animated blob field — the one primitive behind the lava lamp
/// (Stage 1) and the static card gradient (Stage 2). Backed by
/// `BlobField.metal`, driven as a SwiftUI `.colorEffect`: N blobs are computed
/// analytically in the fragment shader, so there is no CPU `Canvas`
/// rasterization and no Core Animation `.blur()` pass. The shader's falloff
/// ramp replaces `.blur(radius:)`.
///
/// Two typed entry points feed one shader:
/// - `init(parameters:)` — the LAVA style: wide ambient blobs, additive, in
///   normalized (fraction-of-view) space. Used by `DashboardLavaLamp`.
/// - `init(cardBlobs:animated:)` — the CARD style: opaque discs with a blurred
///   rim, composited source-over in absolute points. Used by the static
///   `NodeGradientLayer` path.
struct BlobFieldView: View {

    private enum Style {
        case lava, card, hero
        /// Uniform value passed to the shader's `style` argument.
        var shaderValue: Float {
            switch self {
            case .lava: return 0
            case .card: return 1
            case .hero: return 2
            }
        }
    }

    // MARK: Lava style (Stage 1)

    /// One lava blob. `origin`/`radius` are fractions of the view size so the
    /// field scales with whatever surface hosts it.
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

    // MARK: Card style (Stage 2)

    /// One card blob — an opaque disc with a blurred rim, positioned in
    /// absolute points relative to the view center. Reproduces a
    /// `Circle().fill().blur()` from the static `NodeGradientLayer` path.
    struct CardBlob {
        /// Rest offset from the view center, in points. `y` folds in the
        /// consumer's `centerYOffset`.
        var baseOffset: CGPoint
        /// Disc radius in points (half the circle diameter).
        var radius: CGFloat
        /// Drift frequency per axis (x uses sin, y uses cos).
        var driftFreq: CGSize
        /// Drift phase per axis — already `phase * seed`, so no two blobs (or
        /// nodes) move in lockstep.
        var driftPhase: CGSize
        /// Drift amplitude in points.
        var driftAmp: CGFloat
        /// Falloff ramp half-width in points — the shader's answer to
        /// `.blur(radius:)`. Larger = softer rim.
        var blurWidth: CGFloat
        var color: Color
        /// Peak opacity at the disc core (1 = opaque fill).
        var peak: CGFloat
        /// Card-morph (2026-08-16): domain-warp amount. 0 (default) → a plain disc,
        /// byte-identical to the pre-card-morph path. > 0 warps the boundary in position space
        /// with 2-octave fbm noise (BlobField.metal) → an irregular, non-repeating organic edge
        /// that keeps the card's colour.
        var undulation: CGFloat = 0
        /// Per-blob noise offset so blobs don't warp in lockstep (only matters when undulation > 0).
        var seed: CGFloat = 0
        /// Warp noise wavelength as a MULTIPLE of blob radius (relative, so it reads the same on
        /// any blob size). Larger = longer wavelength = fewer, flowing lobes. Only matters when
        /// undulation > 0; default `2` ≈ one undulation across the blob.
        var warpScale: CGFloat = 2
    }

    // MARK: Hero style (Stage 3)

    /// One morphing hero blob — a source-over blurred blob (like `CardBlob`)
    /// whose boundary radius wobbles per angle via a harmonic sum, plus drift,
    /// buoyancy, and breathing. Reproduces the CPU `BlobShape` morph on the GPU.
    struct HeroBlob {
        /// Rest offset from view center, points (`y` folds `centerYOffset`).
        var baseOffset: CGPoint
        /// Blob diameter in points before breathing (`180 * circleScale`).
        var baseSize: CGFloat
        /// Drift frequency per axis (x = sin, y = cos).
        var driftFreq: CGSize
        /// Slow vertical swell frequency.
        var buoyancyFreq: CGFloat
        /// Size-pulse frequency.
        var breatheFreq: CGFloat
        /// Per-blob seed; harmonic and drift phases derive from it.
        var seedPhase: CGFloat
        /// The three morph harmonics: lobe counts, amplitudes (fraction of R),
        /// and rates (rad/s, already `base + index*0.03`). Each array is count 3.
        var harmonicKs: [CGFloat]
        var harmonicAmps: [CGFloat]
        var harmonicSpeeds: [CGFloat]
        /// Morph amount. Sum(amps) × undulation = peak radius swing.
        var undulation: CGFloat
        /// Falloff ramp half-width in points (the blur).
        var blurWidth: CGFloat
        var color: Color
        /// Peak opacity at the blob core (1 = opaque fill).
        var peak: CGFloat
    }

    // MARK: Stored config

    private let style: Style
    private let packed: [Float]
    private let sharedField: Bool
    private let animated: Bool
    private let frameInterval: Double
    /// Card rest reference as a fraction of view size (card style only).
    private let anchor: UnitPoint
    /// #3 — slight-irregularity domain warp. 0 = off; node cards / hero / dark
    /// lava all pass 0 → byte-identical. Only the dashboard LIGHT field dials it.
    private let noiseAmount: Float
    private let noiseScale: Float
    /// Imagery-derived bloom amount (card + hero styles). 0 (default) → no bloom →
    /// byte-identical. > 0 adds each blob's own soft additive colour halo (BlobField.metal).
    private let bloom: Float

    init(parameters: Parameters) {
        self.style = .lava
        self.packed = Self.packLava(parameters.blobs)
        self.sharedField = parameters.sharedField
        self.animated = true
        self.frameInterval = parameters.frameInterval
        self.anchor = .center   // unused by the lava path
        self.noiseAmount = 0
        self.noiseScale = 0
        self.bloom = 0
    }

    /// - Parameter animated: `false` renders a single still frame (time = 0)
    ///   with no per-frame redraw — the GPU equivalent of the old frozen +
    ///   `.drawingGroup()` tile path. Per-blob phase still varies the frame.
    /// - Parameter anchor: rest reference for the blobs. `.center` (default)
    ///   matches today; `.bottom` pools the color at the card floor (used on
    ///   hero-image cards so the gradient doesn't bleed up into the photo).
    init(cardBlobs: [CardBlob],
         animated: Bool,
         anchor: UnitPoint = .center,
         sharedField: Bool = false,
         frameInterval: Double = 1.0 / 30.0,
         noiseAmount: CGFloat = 0,
         noiseScale: CGFloat = 0,
         bloom: CGFloat = 0) {
        self.style = .card
        self.packed = Self.packCard(cardBlobs)
        self.sharedField = sharedField
        self.animated = animated
        self.frameInterval = frameInterval
        self.anchor = anchor
        self.noiseAmount = Float(noiseAmount)
        self.noiseScale = Float(noiseScale)
        self.bloom = Float(bloom)
    }

    init(heroBlobs: [HeroBlob],
         animated: Bool,
         sharedField: Bool = false,
         frameInterval: Double = 1.0 / 30.0,
         bloom: CGFloat = 0) {
        self.style = .hero
        self.packed = Self.packHero(heroBlobs)
        self.sharedField = sharedField
        self.animated = animated
        self.frameInterval = frameInterval
        self.anchor = .center   // unused by the hero path
        self.noiseAmount = 0
        self.noiseScale = 0
        self.bloom = Float(bloom)
    }

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            if animated {
                TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
                    // Wrap time to keep Float precision usable across the app's
                    // multi-hundred-million-second reference clock (per brief).
                    let t = Float(timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1000.0))
                    canvas(size: geo.size, origin: origin, time: t)
                }
            } else {
                // Still frame: time pinned to 0, no TimelineView driving
                // redraws. CA caches the rendered layer and scrolls it as flat
                // pixels — cheap, like the old `.drawingGroup()`.
                canvas(size: geo.size, origin: origin, time: 0)
            }
        }
    }

    private func canvas(size: CGSize, origin: CGPoint, time: Float) -> some View {
        Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.blobField(
                    .float(time),
                    .float2(Float(size.width), Float(size.height)),
                    .float2(Float(origin.x), Float(origin.y)),
                    .float(sharedField ? 1 : 0),
                    .float(style.shaderValue),
                    .float2(Float(anchor.x), Float(anchor.y)),
                    .float(noiseAmount),
                    .float(noiseScale),
                    .float(bloom),
                    .floatArray(packed)
                )
            )
    }

    // MARK: Packing — order must match the layouts in BlobField.metal

    /// LAVA layout, stride 10.
    private static func packLava(_ blobs: [Blob]) -> [Float] {
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

    /// CARD layout, stride 16.
    private static func packCard(_ blobs: [CardBlob]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(blobs.count * 16)
        for blob in blobs {
            let (r, g, b) = rgb(blob.color)
            out.append(Float(blob.baseOffset.x))
            out.append(Float(blob.baseOffset.y))
            out.append(Float(blob.radius))
            out.append(Float(blob.driftFreq.width))
            out.append(Float(blob.driftFreq.height))
            out.append(Float(blob.driftPhase.width))
            out.append(Float(blob.driftPhase.height))
            out.append(Float(blob.driftAmp))
            out.append(Float(blob.blurWidth))
            out.append(Float(blob.peak))
            out.append(r)
            out.append(g)
            out.append(b)
            out.append(Float(blob.undulation))
            out.append(Float(blob.seed))
            out.append(Float(blob.warpScale))
        }
        return out
    }

    /// HERO layout, stride 23.
    private static func packHero(_ blobs: [HeroBlob]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(blobs.count * 23)
        for blob in blobs {
            let (r, g, b) = rgb(blob.color)
            out.append(Float(blob.baseOffset.x))
            out.append(Float(blob.baseOffset.y))
            out.append(Float(blob.baseSize))
            out.append(Float(blob.driftFreq.width))
            out.append(Float(blob.driftFreq.height))
            out.append(Float(blob.buoyancyFreq))
            out.append(Float(blob.breatheFreq))
            out.append(Float(blob.seedPhase))
            // Three harmonics: k0..2, amp0..2, speed0..2.
            out.append(Float(blob.harmonicKs[0]))
            out.append(Float(blob.harmonicKs[1]))
            out.append(Float(blob.harmonicKs[2]))
            out.append(Float(blob.harmonicAmps[0]))
            out.append(Float(blob.harmonicAmps[1]))
            out.append(Float(blob.harmonicAmps[2]))
            out.append(Float(blob.harmonicSpeeds[0]))
            out.append(Float(blob.harmonicSpeeds[1]))
            out.append(Float(blob.harmonicSpeeds[2]))
            out.append(Float(blob.undulation))
            out.append(Float(blob.blurWidth))
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
