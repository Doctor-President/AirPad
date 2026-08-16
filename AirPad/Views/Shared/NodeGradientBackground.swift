import SwiftUI

/// Hero-gradient morph tuning. These are the knobs most likely to get
/// re-judged on eval, kept top-of-file for cheap nudging.
/// - `blobMorphSpeeds`: per-harmonic morph rates (rad/s). Slow churn,
///   not vibration — keep in `0.12…0.35` so the silhouette flows
///   instead of buzzing.
/// - `blobMorphAmps`: per-harmonic radius amplitudes (fraction of R).
///   Their sum × `undulation` = peak ± radius swing. Defaults sum to
///   0.29 so at `undulation: 1.0` the blob clearly stops reading as a
///   circle.
/// - `blobMorphKs`: lobe counts. Low integers give organic bumps;
///   higher numbers would read as noise/vibration.
private let blobMorphSpeeds: [Double] = [0.15, 0.22, 0.31]
private let blobMorphAmps: [CGFloat] = [0.14, 0.09, 0.06]
private let blobMorphKs: [Int] = [2, 3, 5]

/// Shared compositing recipe used by every node-surface visual: dark
/// base + three drifting tag-palette circles + a radial inner-glow
/// composited with `.blendMode(.overlay)`. The overlay blend is what
/// keeps overlapping circles vivid instead of muddying them to grey —
/// it preserves the centre (overlay against black is a no-op) and
/// brightens the rim (overlay against white screens the underlying).
/// No outer stroke rim here — that chrome lives on the consumer
/// (`NodeGradientBackground` adds it for cards; the hero omits it).
///
/// Used verbatim by `NodeGradientBackground` and `NodeDetailView.heroZone`
/// so the two surfaces are guaranteed identical by construction.
struct NodeGradientLayer: View {
    let node: Node

    /// Selects the blob COMPOSITION (see `blobSet`) — decoupled from `undulation` (2026-08-16).
    enum BlobSet { case card, hero }

    /// Multiplier on circle DIAMETER (not blur). `1.0` (the default)
    /// matches the card geometry — `NodeGradientBackground` consumers
    /// inherit it untouched. `NodeDetailView.heroZone` passes a larger
    /// value so palette colour reaches close to all edges of the wider
    /// band without regressing the card. Blur radius is held constant
    /// at 40pt regardless of scale — scaling blur with size washes the
    /// pools into mud and erases the chroma the card design depends on.
    /// Offsets are NOT scaled either — circles spread out more by
    /// virtue of being bigger.
    var circleScale: CGFloat = 1.0
    /// Multiplier on circle BLUR radius. `1.0` (default) leaves the
    /// 40pt base untouched — hero / card consumers render identically.
    /// Tile callers pass <1 so the blur shrinks with the smaller circles;
    /// the original "scaling blur washes pools into mud" reasoning is
    /// true at hero scale but inverts at tile scale, where leaving 40pt
    /// of blur on already-shrunken circles flattens chroma into wash.
    var blurScale: CGFloat = 1.0
    /// Multiplier on the ±80pt static offsets that spread the three
    /// circles across the canvas. `1.0` (default) keeps the card/hero
    /// composition unchanged; tiles pass <1 to pull the lobes inward so
    /// they read as a contained form, not edge-to-edge wash.
    var offsetScale: CGFloat = 1.0
    /// Dark-rim vignette opacity. `0` (default) skips the layer entirely —
    /// zero regression for hero / card. Tiles pass ~0.35–0.55 to darken
    /// the corners and give the gradient a defined center.
    var vignette: CGFloat = 0
    /// `radialGlow` inner/outer radius as a fraction of the view WIDTH (dark mode only).
    /// Defaults `0.15`/`0.72` are the shipped literals → byte-identical when unset. Exposed
    /// (2026-08-16, glow-parity) so the width-only glow can be dialed per surface, since a
    /// ~5:7 card and a ~16:5 band get very different coverage from identical width-basis code.
    /// ⚠️ Still WIDTH-basis — the basis change (width→aspect-aware) is a filed post-V1 follow-up.
    var glowStart: CGFloat = 0.15
    var glowEnd: CGFloat = 0.72
    /// Opacity of the fixed `radialGlow` circle (dark mode). `1` (default) = today. Lower it to
    /// fade the legacy radial out while dialing `bloom` up — the two are a crossfade from the
    /// hand-drawn circle to the imagery-derived glow (2026-08-16). 0 removes the radial entirely.
    var glowStrength: CGFloat = 1
    /// Imagery-derived bloom (dark mode). `0` (default) → no bloom → byte-identical. > 0 makes each
    /// colour blob emit a soft additive halo IN ITS OWN COLOUR (BlobField.metal), so the glow
    /// follows the imagery and can never miscenter the way the fixed `radialGlow` does.
    var bloom: CGFloat = 0
    /// Vertical shift (points) applied to the color blobs only — the
    /// dark base, radial glow, and vignette stay centered. `0` (default)
    /// renders byte-identical to today. Gradient-only tiles pass a
    /// negative value so the color form rides up into the hero zone,
    /// matching where a cover image would sit on a hero tile.
    var centerYOffset: CGFloat = 0
    /// Domain-warp AMPLITUDE for the SELECTED blob set (`blobSet`). PURE GEOMETRY — the card shader
    /// warps the sample point by fbm noise before measuring distance (never touches colour). `0`
    /// (default) = no warp (plain disc) → byte-identical. Higher = the boundary moves further.
    /// Paired with `warpScale` (wavelength); the two are INDEPENDENT (amount vs. size).
    /// ★ 2026-08-16 correction: an earlier note read this as "undulation shifts HUE (orange→
    /// magenta at 0.00→0.02)". That was a SYMPTOM of `undulation` doubling as the blob-SET
    /// selector — `undulation > 0` swapped the CARD set for the HERO set, and the two sets pool
    /// colour differently. It was NEVER the shader. Selection now lives in `blobSet`, so
    /// `undulation` is a clean geometry dial on whichever set is chosen.
    var undulation: CGFloat = 0
    /// Domain-warp noise WAVELENGTH as a multiple of blob radius (card path). Relative to radius, so
    /// the same value reads the same on a 60pt and a 200pt blob. Larger = fewer, flowing lobes;
    /// `2` (default) ≈ one undulation across the blob. Only matters when `undulation > 0`.
    var warpScale: CGFloat = 2

    /// Which blob COMPOSITION renders, decoupled from `undulation` (2026-08-16). `.card`
    /// (default) = the three static discs, now able to wobble via `undulation` (card-morph);
    /// `.hero` = the four morphing hero blobs. Every existing caller keeps `.card`; only the
    /// hero-look callers (QuikCapture) pass `.hero`.
    var blobSet: BlobSet = .card
    /// Drives `TimelineView(.animation)` when true. When false, the same
    /// layers render with `time = 0` — a still frame of the live gradient,
    /// not a different visual. On the GPU (static path) motion is ~free, so
    /// dense tiles now animate too (see `driftSpeedScale`).
    /// Default true keeps cards / carousel / detail callsites unchanged.
    var animated: Bool = true
    /// Rest anchor for the static color blobs. `.center` (default) is
    /// today's full-bleed look; `.bottom` pools the color at the card floor
    /// so a hero-image card's gradient sits beneath the photo instead of
    /// washing up into it. Static path only — the hero morph ignores it.
    var anchor: UnitPoint = .center
    /// Multiplier on the static blobs' drift frequency. `1.0` (default) is
    /// the original speed. Dense grid tiles pass <1 (~0.4) so small blobs
    /// read as slow ambient breathing, not shimmer, now that they animate.
    var driftSpeedScale: CGFloat = 1.0

    /// OPTIONAL blob-distribution override (hero-LEFT look-see only, DEBUG). `nil`
    /// (default) leaves EVERY existing caller on the untouched `cardBlobs()` path —
    /// carousel, grid, and detail hero render byte-identically. When set, the three
    /// static blobs are instead placed relative to a left COLUMN and distributed
    /// down its long (vertical) axis, so their colours meet and mix (the carousel
    /// reads well precisely because its blobs span a wide field and overlap). Only
    /// `NodeCardView`'s hero-left vertical gradient passes a non-nil value.
    struct BlobDistribution: Equatable {
        var columnFrac: CGFloat        // reference column width, as a fraction of layer width
        var blobScale: CGFloat         // radius = blobScale × (columnFrac × width)
        var verticalSpread: CGFloat    // centre gap down the column, fraction of layer height
        var horizontalOffset: CGFloat  // centre-of-mass X, fraction of the column width
        var overlap: CGFloat           // 0 = full spread … 1 = coincident (single wash)
    }
    var blobDistribution: BlobDistribution? = nil

    @State private var phase: Double = Double.random(in: 0...100)

    /// Effective appearance — the SAME mechanism the shipped map/chrome theming
    /// uses (`AppearancePalette.mapBackground(dark: colorScheme == .dark)`). Dark
    /// routes to the byte-identical Solar Flare recipe; light routes to the
    /// transmissive Cucumber Water path below.
    @Environment(\.colorScheme) private var colorScheme

    // Cucumber Water (light) — BAKED, T's device-verified values. PROMOTED to
    // `AppearancePalette` (cwParchmentHex / cwBaseLightness / cwPigmentStrength /
    // cwTransferMode + `.pigmentOnParchment()`) so the dashboard lava lamp (#3)
    // shares this exact light path. Read only via that modifier; the dark path
    // never touches it, so Solar Flare stays byte-identical.

    private static let circleColors: [(String, String, String)] = [
        ("9B6FE8", "F5C5A3", "E36B4E"),
        ("5B8FFF", "A78BFA", "F472B6"),
        ("34D399", "60A5FA", "A78BFA"),
        ("FB923C", "FBBF24", "E36B4E"),
        ("F472B6", "FB7185", "C084FC"),
        ("22D3EE", "34D399", "60A5FA"),
        ("A78BFA", "818CF8", "E36B4E"),
    ]

    private var paletteIndex: Int { Self.paletteSlot(for: node) }

    static func paletteSlot(for node: Node) -> Int {
        guard let tagName = node.primaryTag else { return 0 }
        switch tagName {
        case "pal0": return 0
        case "pal1": return 1
        case "pal2": return 2
        case "pal3": return 3
        case "pal4": return 4
        case "pal5": return 5
        case "pal6": return 6
        default: return abs(tagName.hashValue) % 7
        }
    }

    // MARK: - Luminance-aware ink

    private static func rgb(_ hex: String) -> (Double, Double, Double) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        return (Double((int >> 16) & 0xFF) / 255,
                Double((int >> 8) & 0xFF) / 255,
                Double(int & 0xFF) / 255)
    }

    /// Representative luminance (0…1) of the node's gradient — the mean relative
    /// luminance of its three blob colors, which pool where the bubble text sits.
    static func representativeLuminance(for node: Node) -> Double {
        let (a, b, c) = circleColors[paletteSlot(for: node) % circleColors.count]
        func lum(_ hex: String) -> Double {
            let (r, g, bl) = rgb(hex)
            return 0.2126 * r + 0.7152 * g + 0.0722 * bl
        }
        return (lum(a) + lum(b) + lum(c)) / 3
    }

    /// Ink that reads legibly over the node's bubble gradient (which, unlike the
    /// card face, has no darkening scrim): warm near-black on a light palette,
    /// warm off-white on a dark one. Pair with `legibleHalo` for a contrast
    /// outline so mid-luminance palettes read too.
    static func legibleInk(for node: Node) -> Color {
        legibleInk(forLuminance: representativeLuminance(for: node))
    }

    /// Contrast halo behind the ink — the OPPOSITE luminance, applied as a text
    /// shadow so the type separates from a mid-tone gradient where neither pure
    /// ink has strong contrast on its own (the bubble carries no scrim).
    static func legibleHalo(for node: Node) -> Color {
        legibleHalo(forLuminance: representativeLuminance(for: node))
    }

    /// Luminance-parameterized ink — the SAME rule + ink values as
    /// `legibleInk(for:)` / `AppearancePalette.legibleInk(onFillHex:)` (map orbs,
    /// tag pills, chat bubbles), but driven by ANY sampled luminance. Used by the
    /// scroll-collapsed band, which samples the blurred hero IMAGE under the title
    /// rather than the gradient palette — one rule, two luminance sources.
    /// `threshold` defaults to the shared 0.62 so existing callers stay
    /// byte-identical.
    static func legibleInk(forLuminance lum: Double, threshold: Double = 0.62) -> Color {
        lum > threshold
            ? Color(red: 0.08, green: 0.07, blue: 0.06)
            : Color(red: 1.0, green: 0.98, blue: 0.95)
    }

    static func legibleHalo(forLuminance lum: Double, threshold: Double = 0.62) -> Color {
        lum > threshold
            ? Color.white.opacity(0.55)     // dark ink → light halo
            : Color.black.opacity(0.60)     // light ink → dark halo
    }

    // MARK: - Diagonal node wash (single-hue territory shade)

    private static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Two stops of ONE shade for the focal bubble's subtle diagonal wash: a
    /// gentle lift and a darker anchor. The dark stop is CLAMPED below the
    /// mid-luminance dead zone (≤ 0.22) so there's always a genuinely dark region
    /// for the light type to read against — the text-contrast rule samples this
    /// darkest region, so legibility no longer depends on the base landing outside
    /// the muddy middle. Returned light → dark for a topLeading→bottomTrailing fill.
    static func washStops(baseHex: String) -> (light: Color, dark: Color) {
        let (r, g, b) = rgb(baseHex)
        // Light stop — a subtle lift of the same hue (kept modest so it stays a
        // wash, not a spotlight).
        let lf = 1.14
        let light = Color(red: min(1, r * lf), green: min(1, g * lf), blue: min(1, b * lf))
        // Dark stop — scale the hue down until it clears the dead zone.
        var f = 0.68
        var dr = r * f, dg = g * f, db = b * f
        var i = 0
        while luminance(dr, dg, db) > 0.22 && i < 14 {
            f *= 0.85; dr = r * f; dg = g * f; db = b * f; i += 1
        }
        return (light, Color(red: dr, green: dg, blue: db))
    }

    var body: some View {
        if colorScheme == .dark {
            darkBody
        } else {
            lightBody
        }
    }

    /// Solar Flare (dark) — the shipped recipe, byte-identical to main
    /// (`51ba4ae`): dark base + color blobs (source-over) + radial inner-glow
    /// (overlay) + optional vignette (multiply). Reads NONE of the Cucumber dials.
    private var darkBody: some View {
        ZStack {
            gradientFill
            // glowStrength fades the fixed radial (1 = today, 0 = gone) so it can crossfade
            // against the imagery `bloom`. opacity(1) is a no-op → byte-identical at the default.
            radialGlow.blendMode(.overlay).opacity(glowStrength)
            if vignette > 0 {
                vignetteLayer
            }
        }
    }

    /// Cucumber Water (light) — TRANSMISSIVE. Parchment base + the SAME color-blob
    /// field composited OVER it with the baked `.plusDarker` transfer blend at the
    /// baked pigment strength (Tom's device-verified values). The dark radial-glow
    /// and vignette are dropped — on cream they blow the rim out / dirty the
    /// corners; the parchment + ink layer carry the read instead.
    /// `compositingGroup` isolates the blend so it composites against the
    /// parchment, not the map ground behind the card.
    private var lightBody: some View {
        // #3 — converged onto the shared `.pigmentOnParchment()` recipe (its
        // defaults ARE the Cucumber Water bake: parchment #F4EFE3 × 0.98 +
        // `.plusDarker` at strength 1.0 + compositingGroup). The dashboard lava
        // lamp uses the same modifier — one light path, no divergence.
        pigmentField.pigmentOnParchment()
    }

    /// The color-pigment blobs ALONE (no base behind them) — the same GPU field
    /// the dark path uses, returned bare so `lightBody` can slot a blend mode
    /// between it and the parchment. Transparent between blobs (the shader emits
    /// premultiplied source-over), so the blend leaves bare paper untouched.
    @ViewBuilder
    private var pigmentField: some View {
        let colors = Self.circleColors[paletteIndex % Self.circleColors.count]
        let size: CGFloat = 180 * circleScale
        if let dist = blobDistribution {
            // Hero-LEFT: column-relative, vertically distributed blobs (measured).
            GeometryReader { g in
                BlobFieldView(cardBlobs: distributedBlobs(colors: colors, dist: dist, size: g.size),
                              animated: animated, anchor: .center)
            }
        } else if blobSet == .hero {
            BlobFieldView(heroBlobs: heroBlobs(colors: colors, size: size),
                          animated: animated)
        } else {
            BlobFieldView(cardBlobs: cardBlobs(colors: colors, size: size),
                          animated: animated,
                          anchor: anchor)
        }
    }

    private var gradientFill: some View {
        let colors = Self.circleColors[paletteIndex % Self.circleColors.count]
        let size: CGFloat = 180 * circleScale
        return Group {
            if blobSet == .hero {
                // HERO — the organic morph, now on the GPU (BlobField hero
                // style: per-pixel harmonic boundary + drift/buoyancy/breathe).
                // ws-render-perf PERF FIX 3, stage 3.
                heroFill(colors: colors, size: size)
            } else {
                // STATIC cards/tiles — the three blurred color circles now
                // run on the GPU via BlobField (ws-render-perf PERF FIX 3,
                // stage 2). This is the path that rendered many-at-once and
                // paid a per-frame CPU gaussian blur it couldn't cache while
                // animated.
                staticFill(colors: colors, size: size)
            }
        }
    }

    // Hero morph on the GPU. Dark base stays a SwiftUI layer; radialGlow
    // (overlay) + vignette composite over it in `body`, same as the card path.
    private func heroFill(colors: (String, String, String), size: CGFloat) -> some View {
        ZStack {
            Color(red: 0.027, green: 0.027, blue: 0.039)
            BlobFieldView(heroBlobs: heroBlobs(colors: colors, size: size),
                          animated: animated, bloom: bloom)
        }
    }

    // Static gradient on the GPU. The dark base stays a SwiftUI layer and the
    // radialGlow (overlay) + vignette (multiply) composite over it in `body`
    // exactly as before — only the expensive blurred circles moved to Metal,
    // so the overlay-blend vividness is unchanged by construction.
    @ViewBuilder
    private func staticFill(colors: (String, String, String), size: CGFloat) -> some View {
        ZStack {
            Color(red: 0.027, green: 0.027, blue: 0.039)
            if let dist = blobDistribution {
                GeometryReader { g in
                    BlobFieldView(cardBlobs: distributedBlobs(colors: colors, dist: dist, size: g.size),
                                  animated: animated, anchor: .center, bloom: bloom)
                }
            } else {
                BlobFieldView(cardBlobs: cardBlobs(colors: colors, size: size),
                              animated: animated,
                              anchor: anchor, bloom: bloom)
            }
        }
    }

    /// Hero-LEFT distribution (guarded, additive): three static blobs placed
    /// relative to a left COLUMN and stacked down its long axis so their colours
    /// overlap and mix. Reuses the SAME drift character and the SAME 40·blurScale
    /// falloff as `cardBlobs()` — only positions + radius change. Does not touch
    /// `cardBlobs()` and never adds a fourth blob.
    private func distributedBlobs(colors: (String, String, String),
                                  dist: BlobDistribution,
                                  size: CGSize) -> [BlobFieldView.CardBlob] {
        let colW = size.width * dist.columnFrac
        let radius = dist.blobScale * colW
        let centerX = dist.horizontalOffset * colW
        let gap = dist.verticalSpread * size.height * (1 - dist.overlap)
        let blurWidth: CGFloat = 40 * blurScale
        let ph = CGFloat(phase)
        let hexes = [colors.0, colors.1, colors.2]
        // Same per-blob drift frequencies / phase seeds as cardBlobs().
        let dFreq: [CGSize] = [.init(width: 0.30, height: 0.25),
                               .init(width: 0.35, height: 0.30),
                               .init(width: 0.40, height: 0.35)]
        let dPhase: [CGSize] = [.init(width: 1.3, height: 0.9),
                                .init(width: 1.7, height: 1.1),
                                .init(width: 2.1, height: 0.7)]
        return (0..<3).map { i -> BlobFieldView.CardBlob in
            let baseY: CGFloat = CGFloat(i - 1) * gap
            let offset = CGPoint(x: centerX - size.width / 2, y: baseY)
            let freq = CGSize(width: dFreq[i].width * driftSpeedScale,
                              height: dFreq[i].height * driftSpeedScale)
            let dph = CGSize(width: ph * dPhase[i].width, height: ph * dPhase[i].height)
            let sd: CGFloat = ph + CGFloat(i) * 1.7
            return BlobFieldView.CardBlob(
                baseOffset: offset,
                radius: radius,
                driftFreq: freq,
                driftPhase: dph,
                driftAmp: 30,
                blurWidth: blurWidth,
                color: Color(hexString: hexes[i]),
                peak: 1,
                // Same card-morph as cardBlobs() so the list (hero-left) warps too; undulation 0
                // → no-op → byte-identical to the pre-morph distributed blob.
                undulation: undulation,
                seed: sd,
                warpScale: warpScale
            )
        }
    }

    /// Map the three static circles to `BlobField` card blobs, preserving the
    /// original per-blob sin/cos drift, per-node `phase` seed, and every knob
    /// (`circleScale` via `size`, `blurScale`, `offsetScale`, `centerYOffset`).
    private func cardBlobs(colors: (String, String, String), size: CGFloat) -> [BlobFieldView.CardBlob] {
        let radius: CGFloat = size / 2          // size = 180 * circleScale
        let blurWidth: CGFloat = 40 * blurScale
        let spread: CGFloat = 80 * offsetScale
        let amp: CGFloat = 30
        let ph = CGFloat(phase)

        func blob(baseX: CGFloat, fx: CGFloat, fy: CGFloat,
                  px: CGFloat, py: CGFloat, sd: CGFloat, hex: String) -> BlobFieldView.CardBlob {
            BlobFieldView.CardBlob(
                baseOffset: CGPoint(x: baseX, y: centerYOffset),
                radius: radius,
                driftFreq: CGSize(width: fx * driftSpeedScale, height: fy * driftSpeedScale),
                driftPhase: CGSize(width: ph * px, height: ph * py),
                driftAmp: amp,
                blurWidth: blurWidth,
                color: Color(hexString: hex),
                peak: 1,
                // card-morph: the caller's `undulation` (amplitude) + `warpScale` (wavelength) drive
                // the fbm domain warp; `sd` de-syncs each disc. At undulation 0 the warp is a no-op
                // → byte-identical to the plain disc.
                undulation: undulation,
                seed: sd,
                warpScale: warpScale
            )
        }

        return [
            blob(baseX: -spread, fx: 0.30, fy: 0.25, px: 1.3, py: 0.9, sd: ph,       hex: colors.0),
            blob(baseX: 0,       fx: 0.35, fy: 0.30, px: 1.7, py: 1.1, sd: ph + 1.7, hex: colors.1),
            blob(baseX: spread,  fx: 0.40, fy: 0.35, px: 2.1, py: 0.7, sd: ph + 3.4, hex: colors.2),
        ]
    }

    /// Build the four hero blobs, reproducing the CPU `morphBlob` math: per-blob
    /// seed, drift/buoyancy/breathe frequencies, and the three morph harmonics
    /// (k/amp from the top-of-file tuning constants; speed = base + index*0.03).
    /// The wobble itself is evaluated per-pixel in the shader; here we just hand
    /// it the same numbers.
    private func heroBlobs(colors: (String, String, String), size: CGFloat) -> [BlobFieldView.HeroBlob] {
        let spread: CGFloat = 80 * offsetScale
        let blurWidth: CGFloat = 40 * blurScale
        let ks = blobMorphKs.map { CGFloat($0) }

        func hero(index: Int, baseX: CGFloat, color: Color) -> BlobFieldView.HeroBlob {
            let seedPhase = phase + Double(index) * 1.7
            let speeds = (0..<3).map { CGFloat(blobMorphSpeeds[$0] + Double(index) * 0.03) }
            return BlobFieldView.HeroBlob(
                baseOffset: CGPoint(x: baseX, y: centerYOffset),
                baseSize: size,
                driftFreq: CGSize(width: 0.30 + CGFloat(index) * 0.05,
                                  height: 0.25 + CGFloat(index) * 0.05),
                buoyancyFreq: 0.10 + CGFloat(index) * 0.02,
                breatheFreq: 0.20 + CGFloat(index) * 0.03,
                seedPhase: CGFloat(seedPhase),
                harmonicKs: ks,
                harmonicAmps: blobMorphAmps,
                harmonicSpeeds: speeds,
                undulation: undulation,
                blurWidth: blurWidth,
                color: color,
                peak: 1
            )
        }

        return [
            hero(index: 0, baseX: -spread, color: Color(hexString: colors.0)),
            hero(index: 1, baseX: 0, color: Color(hexString: colors.1)),
            hero(index: 2, baseX: spread, color: Color(hexString: colors.2)),
            // 4th blob — density only, hue blended from the outer two so it
            // doesn't introduce a new colour. Pull this line if the hero reads
            // too busy.
            hero(index: 3, baseX: -30 * offsetScale, color: blendHex(colors.0, colors.2)),
        ]
    }

    private var radialGlow: some View {
        GeometryReader { geo in
            RadialGradient(
                colors: [.black, Color.white.opacity(0.85)],
                center: .center,
                // WIDTH-basis (unchanged); `glowStart`/`glowEnd` default to 0.15/0.72 = today.
                startRadius: geo.size.width * glowStart,
                endRadius: geo.size.width * glowEnd
            )
        }
    }

    /// Dark-rim vignette. Sits above `radialGlow` and is multiplied into
    /// the composition so it darkens edges without paving over them — the
    /// palette colours stay legible, just contained. Only mounted when
    /// `vignette > 0`, so hero / card paths pay zero cost.
    private var vignetteLayer: some View {
        GeometryReader { geo in
            RadialGradient(
                colors: [.clear, .black.opacity(vignette)],
                center: .center,
                startRadius: geo.size.width * 0.20,
                endRadius:   geo.size.width * 0.70
            )
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}

/// Linear interpolation between two hex-string colours at `t ∈ [0,1]`.
/// Used once for the 4th hero blob so it doesn't introduce a new hue.
private func blendHex(_ a: String, _ b: String, t: CGFloat = 0.5) -> Color {
    func rgb(_ hex: String) -> (Double, Double, Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&v)
        return (Double((v >> 16) & 0xFF) / 255,
                Double((v >> 8) & 0xFF) / 255,
                Double(v & 0xFF) / 255)
    }
    let (ar, ag, ab) = rgb(a)
    let (br, bg, bb) = rgb(b)
    let tD = Double(t)
    return Color(
        red: ar + (br - ar) * tD,
        green: ag + (bg - ag) * tD,
        blue: ab + (bb - ab) * tD
    )
}

/// Card-surface variant: the shared `NodeGradientLayer` plus the white
/// outline rim that frames every list/canvas/overlay card. The rim is
/// also overlay-blended so it picks up the underlying palette colour at
/// the edges instead of looking pasted on.
///
/// The view fills its container; consumers control sizing via `.frame`
/// and corner shape via `.clipShape`. The stroke rim follows `cornerRadius`.
struct NodeGradientBackground: View {
    let node: Node
    var cornerRadius: CGFloat = 36

    var body: some View {
        ZStack {
            NodeGradientLayer(node: node)
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                .blendMode(.overlay)
        }
    }
}

// MARK: - Detail header-band gradient (baked scrim/blur; morph/glow baked in `GradientBake`)

/// Settled band chrome: the top scrim + the collapsed-band blur (T device-settled; baked literals).
/// The band's morph + glow values live in `GradientBake` (also baked, tuner deleted).
///
/// ⚠️ RECORDED: the card's `travelingScrim` does NOT transfer to a header. T's ruling: a bottom
/// fade on a short strip that bleeds off-screen reads as a HARD BAND, not depth (nowhere to
/// resolve). So `scrimBottom = 0` (no bottom scrim); the band keeps only a light top fade. Do NOT
/// re-add a bottom scrim thinking it was an oversight.
enum BandGradient {
    static let scrimTop: CGFloat = 0.13       // light top fade (the header analogue of the card scrim)
    static let scrimBottom: CGFloat = 0.0     // ships as NO bottom scrim — see the note above
    static let backdropBlur: CGFloat = 18     // collapsed band only
}

/// BAKED gradient values — T device-settled on TestFlight `202608161025` and pasted the final list
/// (2026-08-16); the dev tuner (`BandGradientTuning` + `BandGradientTuningPanel` + `GlobalGradientTuner`)
/// has been DELETED. SINGLE source of truth so the band's two sites (expanded/collapsed) and the
/// card's two sites (`NodeCardView` :217 carousel+canvas, :287 list) can't drift.
/// ⚠️ GRID TILE has no vignette here — grid vignette stays PER-DENSITY in the grid's own tuner
/// (`gradientVignette_2col` 0.62 / `_3col` 0.26), UNCHANGED. ⚠️ The COLLAPSED band forces vignette 0
/// regardless (see `BandGradientCollapsed`) — a `.multiply` vignette does not survive its opaque blur.
enum GradientBake {
    // BAND — morph (amplitude / scale-wavelength / circle-size)
    static let bandAmplitude: CGFloat = 1.00
    static let bandScale:     CGFloat = 1.35
    static let bandCircle:    CGFloat = 1.28
    // CARD — morph (carousel + canvas + list)
    static let cardAmplitude: CGFloat = 1.00
    static let cardScale:     CGFloat = 1.34
    // BAND — glow (dark)
    static let bandRadial:    CGFloat = 1.00
    static let bandBloom:     CGFloat = 0.00
    static let bandGlowStart: CGFloat = 0.07
    static let bandGlowEnd:   CGFloat = 1.00
    static let bandVignette:  CGFloat = 0.64   // EXPANDED band only; collapsed forces 0
    // CARD — glow (dark)
    static let cardRadial:    CGFloat = 1.00
    static let cardBloom:     CGFloat = 0.00
    static let cardGlowStart: CGFloat = 0.07
    static let cardGlowEnd:   CGFloat = 1.60
    static let cardVignette:  CGFloat = 0.00
    // GRID TILE — glow (dark). vignette stays on the grid's own per-density tuner.
    static let gridRadial:    CGFloat = 1.00
    static let gridBloom:     CGFloat = 0.02
    static let gridGlowStart: CGFloat = 0.22
    static let gridGlowEnd:   CGFloat = 1.60
}

/// The header-band top scrim — the analogue of the card's `travelingScrim`, with the band's own
/// (light) baked values (`BandGradient.scrimTop`/`scrimBottom`). Mirrors the card's scrimInk
/// (dark→black, light→clear) so the two surfaces read as the same app. ⚠️ NOT the card's
/// 0.42/0.52 stops: the band is a short, wide, status-bar-bleeding strip (T settled ~0.13 top,
/// 0 bottom — see the `BandGradient` note on why a bottom fade doesn't work here).
struct BandScrim: View {
    var top: CGFloat
    var bottom: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let ink: Color = scheme == .dark ? .black : .clear
        LinearGradient(
            stops: [
                .init(color: ink.opacity(Double(top)),    location: 0.0),
                .init(color: .clear,                       location: 0.20),
                .init(color: .clear,                       location: 0.80),
                .init(color: ink.opacity(Double(bottom)),  location: 1.0)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// The EXPANDED detail header band (`NodeDetailView` :1014 no-hero, :3013 hero-load-fail). ONE
/// definition so the two sites can't diverge (a hero-load failure MUST match a no-hero node).
/// Card blob set (undulation = card-morph irregularity, not a hero swap); NOT externally blurred.
struct BandGradientExpanded: View {
    let node: Node
    let totalHeight: CGFloat
    var body: some View {
        NodeGradientLayer(node: node, circleScale: GradientBake.bandCircle,
                          vignette: GradientBake.bandVignette, glowStart: GradientBake.bandGlowStart, glowEnd: GradientBake.bandGlowEnd,
                          glowStrength: GradientBake.bandRadial, bloom: GradientBake.bandBloom,
                          undulation: GradientBake.bandAmplitude, warpScale: GradientBake.bandScale)
            .frame(height: totalHeight)
            .overlay(BandScrim(top: BandGradient.scrimTop, bottom: BandGradient.scrimBottom))
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 30, bottomTrailingRadius: 30, style: .continuous))
    }
}

/// The COLLAPSED pinned-band backdrop (`NodeDetailView` :1118, :3144). Blurred identity wash;
/// NO scrim. Card blob set + the tuner's undulation/circleScale; blur from `BandGradient`.
struct BandGradientCollapsed: View {
    let node: Node
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        // ⚠️ vignette FORCED 0 here (regression fix 2026-08-16): the vignette layer's
        // `.blendMode(.multiply)` does NOT survive this band's `.blur(opaque: true).drawingGroup()`
        // — a non-zero band vignette (T settled 0.64) collapsed the whole pinned strip to solid
        // BLACK (device-observed, Sim-reproduced at 0.4 and 1.0; the EXPANDED band renders the same
        // vignette correctly because it has no opaque blur / drawingGroup). A vignette is pointless
        // on an 18pt-blurred identity wash anyway. The expanded band keeps `GradientBake.bandVignette`.
        NodeGradientLayer(node: node, circleScale: GradientBake.bandCircle,
                          vignette: 0, glowStart: GradientBake.bandGlowStart, glowEnd: GradientBake.bandGlowEnd,
                          glowStrength: GradientBake.bandRadial, bloom: GradientBake.bandBloom,
                          undulation: GradientBake.bandAmplitude, warpScale: GradientBake.bandScale, animated: false)
            .frame(width: width, height: height)
            .clipped()
            .blur(radius: BandGradient.backdropBlur, opaque: true)
            .drawingGroup()
    }
}

