// SolarFlareTuning.swift
// Throwaway on-device material tuner for the Librarian panel. Six static
// layers + one optional drag-only glint, each independently @AppStorage-
// driven so T can dial the Solar Flare look live. Once the values are
// dialed, bake them into SolarFlareMaterial as literals and delete this
// file along with the tuner mount in CanvasView.
//
// PERFORMANCE CONTRACT (do not break when iterating):
//   - Every layer except L7 is static. No per-frame work.
//   - The noise tile is generated ONCE via ImageRenderer at first access
//     and cached on a static; subsequent renders are free.
//   - The glint (L7) is the ONLY animated layer, and it only animates
//     during isDragging. Gated on accessibilityReduceMotion.
//   - No animated blur. No repeatForever on anything blurred.
//
// Three things live here:
//   1. SolarFlareTuningKey / Defaults — @AppStorage keys + seed values.
//      Each layer has its own *On Bool so T can remove a layer entirely
//      from the stack (true absence, not a zeroed slider) for isolated
//      visual judgment.
//   2. SolarFlareMaterial — the layered material view. Replaces the
//      flat `.regularMaterial` in LibrarianSurface's morph ZStack.
//   3. SolarFlareTuningPanel (#if DEBUG) — TileTuningPanel-pattern
//      floating widget mounted in CanvasView, NOT in the panel surface
//      (the panel eats touches inside its own bounds — repeated past
//      mistake).

import SwiftUI
import UIKit

// MARK: - Keys

enum SolarFlareTuningKey {
    // Segmented choices
    static let materialBase        = "sf.materialBase"
    static let palette             = "sf.palette"
    static let noiseBlend          = "sf.noiseBlend"

    // Per-layer ON toggles. When OFF, the layer is NOT composited (the
    // view branch is skipped entirely) so T judges real presence/absence.
    static let baseOn              = "sf.baseOn"
    static let materialOn          = "sf.materialOn"
    static let sheenOn             = "sf.sheenOn"
    static let prismaticOn         = "sf.prismaticOn"
    static let rimOn               = "sf.rimOn"
    static let noiseOn             = "sf.noiseOn"
    static let glintOn             = "sf.glintOn"
    static let edgeGlowOn          = "sf.edgeGlowOn"
    static let bloomOn             = "sf.bloomOn"

    // Values
    static let tintLightness       = "sf.tintLightness"
    static let tintOpacity         = "sf.tintOpacity"
    static let sheenStrength       = "sf.sheenStrength"
    static let prismaticStrength   = "sf.prismaticStrength"
    static let prismaticDesaturate = "sf.prismaticDesaturate"
    static let rimBrightness       = "sf.rimBrightness"
    static let rimWidth            = "sf.rimWidth"
    static let noiseOpacity        = "sf.noiseOpacity"
    static let cornerRadius        = "sf.cornerRadius"

    // Edge glow — inner colored halo on the panel perimeter; cross-
    // fades color/opacity when a field gains focus.
    static let edgeGlowWidth         = "sf.edgeGlowWidth"
    static let edgeGlowBlur          = "sf.edgeGlowBlur"
    static let edgeGlowIdleOpacity   = "sf.edgeGlowIdleOpacity"
    static let edgeGlowActiveOpacity = "sf.edgeGlowActiveOpacity"

    // Active-field glow — emanation locked to the focused field's
    // capsule. Outer pass (wider blur, lower opacity) gives the
    // Playground halo; inner pass (small blur, higher opacity) gives
    // crisper edge brightness. `bloomOn` above stays as the layer
    // toggle (no rename — preserves AppStorage continuity through
    // the bloom→field-glow swap).
    static let fieldGlowWidth        = "sf.fieldGlowWidth"
    static let fieldGlowBlur         = "sf.fieldGlowBlur"
    static let fieldGlowOpacity      = "sf.fieldGlowOpacity"
    static let fieldGlowInnerBlur    = "sf.fieldGlowInnerBlur"
    static let fieldGlowInnerOpacity = "sf.fieldGlowInnerOpacity"

    // Ask-specific outer-pass overrides — the Ask field is shorter and
    // squatter than Search in a busier area, so it reads flatter at the
    // shared `fieldGlow*` values. Width / blur / opacity override the
    // shared keys for the Ask call site only (Search keeps using the
    // shared values). Inner-pass blur/opacity stay shared (they're
    // already crisp at any field size).
    static let askGlowWidth          = "sf.askGlowWidth"
    static let askGlowBlur           = "sf.askGlowBlur"
    static let askGlowOpacity        = "sf.askGlowOpacity"

    // Peek-pill flare — masked LIVE color layer behind the peek pill
    // text. The prismatic mesh provides the color; a hand-painted
    // grayscale PNG ("PeekPillMask") carries the falloff so color is
    // full-strength at the center and feathers softly to transparent
    // at the perimeter. Replaces the prior alpha-matte experiments.
    static let peekFlareOn           = "sf.peekFlareOn"
    static let peekFlarePalette      = "sf.peekFlarePalette"
    static let peekFlareStrength     = "sf.peekFlareStrength"
    static let peekFlareDesat        = "sf.peekFlareDesat"
    static let peekFlareMaskOpacity  = "sf.peekFlareMaskOpacity"
    static let peekFlareColorA       = "sf.peekFlareColorA"
    static let peekFlareColorB       = "sf.peekFlareColorB"
}

// MARK: - Defaults
// Seeded to a sane Solar Flare starting point per the spike spec.
// All layers ON except glint; glint OFF by default so the spike opens
// with no animation at all.

enum SolarFlareTuningDefaults {
    static let materialBase: String         = "thin"
    static let palette: String              = "Solar"
    static let noiseBlend: String           = "softLight"

    static let baseOn: Bool                 = true
    static let materialOn: Bool             = true
    static let sheenOn: Bool                = true
    static let prismaticOn: Bool            = true
    static let rimOn: Bool                  = true
    static let noiseOn: Bool                = true
    static let glintOn: Bool                = false
    // edgeGlowOn defaults FALSE: the field-edge emanation (bloomOn /
    // SolarFlareFieldGlow) now carries the active-field signal, so the
    // panel-perimeter glow is redundant. The layer code + tuner toggle
    // remain in place so it can be re-enabled for experiments.
    static let edgeGlowOn: Bool             = false
    static let bloomOn: Bool                = true

    static let tintLightness: Double        = 0.05
    static let tintOpacity: Double          = 0.55
    static let sheenStrength: Double        = 0.06
    static let prismaticStrength: Double    = 0.25
    static let prismaticDesaturate: Double  = 0.5
    static let rimBrightness: Double        = 0.22
    static let rimWidth: Double             = 1
    static let noiseOpacity: Double         = 0.04
    static let cornerRadius: Double         = 39

    static let edgeGlowWidth: Double         = 10
    static let edgeGlowBlur: Double          = 8
    static let edgeGlowIdleOpacity: Double   = 0.06
    static let edgeGlowActiveOpacity: Double = 0.4

    static let fieldGlowWidth: Double         = 3
    static let fieldGlowBlur: Double          = 12
    static let fieldGlowOpacity: Double       = 0.7
    static let fieldGlowInnerBlur: Double     = 2
    static let fieldGlowInnerOpacity: Double  = 0.9

    // Ask defaults: wider blur + hotter opacity than Search so the
    // shorter capsule radiates with comparable presence. Width starts
    // matched to Search; raise to hit harder.
    static let askGlowWidth: Double           = 3
    static let askGlowBlur: Double            = 16
    static let askGlowOpacity: Double         = 0.8

    // Peek-flare defaults — Solar palette to match the panel material's
    // default, near-full strength so the color reads behind the text,
    // no desaturation so the prism reads vivid at peek.
    static let peekFlareOn: Bool              = true
    static let peekFlarePalette: String       = "Solar"
    static let peekFlareStrength: Double      = 0.90
    static let peekFlareDesat: Double         = 0.00
    static let peekFlareMaskOpacity: Double   = 1.0
    static let peekFlareColorA: String        = "Coral"
    static let peekFlareColorB: String        = "Indigo"
}

// MARK: - Palette
// Named presets only — T is colorblind, so accent COLORS are referenced
// by hex literals (verifiable in code) and the picker exposes them by
// NAME only, never as a hue picker.

enum SolarFlarePalette: String, CaseIterable {
    case solar = "Solar"
    case klein = "Klein"
    case mango = "Mango"

    /// Two accent points per palette. Mostly the dark base fills the
    /// 3x3 mesh; these accents land in 2 of the 9 cells.
    var accents: [Color] {
        switch self {
        case .solar:
            // Indigo + teal — desaturated by the prismaticDesaturate
            // slider toward mid-grey for the "oil slick" end of the
            // dial. At desat=0 these are vivid; at desat=1 fully grey.
            return [Color(hexString: "6366F1"), Color(hexString: "14B8A6")]
        case .klein:
            return [Color(hexString: "1B59C2"), Color(hexString: "00BFFF")]
        case .mango:
            return [Color(hexString: "E8820A"), Color(hexString: "E36B4E")]
        }
    }
}

/// On-device color vocabulary for the peek flare's two gradient ends.
/// Chosen BY NAME only — no hue/color wheel — so the tuner stays usable
/// for T (colorblind). Hex literals are the verifiable source of truth.
enum SolarFlareNamedColor: String, CaseIterable {
    case klein = "Klein", cyan = "Cyan", mango = "Mango", coral = "Coral"
    case indigo = "Indigo", teal = "Teal", violet = "Violet", magenta = "Magenta"
    var hex: String {
        switch self {
        case .klein:   return "1B59C2"
        case .cyan:    return "00BFFF"
        case .mango:   return "E8820A"
        case .coral:   return "E36B4E"
        case .indigo:  return "6366F1"
        case .teal:    return "14B8A6"
        case .violet:  return "8B5CF6"
        case .magenta: return "D6409F"
        }
    }
    var color: Color { Color(hexString: hex) }
}

// MARK: - Noise cache
// Procedural noise tile, generated ONCE at first access and cached
// forever. Re-rendering SolarFlareMaterial is free after the first call.
// If you ever find yourself calling ImageRenderer from `body`, STOP —
// that's the trap the spec explicitly calls out.

@MainActor
private enum SolarFlareNoiseCache {
    static var cached: UIImage?

    static func tile() -> UIImage? {
        if let cached { return cached }
        let renderer = ImageRenderer(content:
            Canvas { ctx, size in
                for _ in 0..<1200 {
                    let x = CGFloat.random(in: 0..<size.width)
                    let y = CGFloat.random(in: 0..<size.height)
                    let alpha = Double.random(in: 0.04...0.22)
                    let rect = CGRect(x: x, y: y, width: 1, height: 1)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(alpha)))
                }
            }
            .frame(width: 120, height: 120)
        )
        renderer.scale = 1
        let img = renderer.uiImage
        cached = img
        return img
    }
}

// MARK: - Material

/// Layered Solar Flare material. Replaces the flat `.regularMaterial` in
/// LibrarianSurface's morph ZStack. Outer contract preserved: takes
/// `isDragging` from `LibrarianPanelStateModel`, applies the -150 spring-
/// overshoot anti-flash bottom pad, and the corner radius is dialed via
/// `sf.cornerRadius` (default 39 = matches surfaceCornerRadius).
///
/// Six static layers + one optional drag-driven glint, each independently
/// toggleable via @AppStorage("sf.*On") so each layer can be removed
/// from the stack entirely (true absence, not zeroed slider) for
/// isolated visual judgment.
struct SolarFlareMaterial: View {
    /// Pass-through from `LibrarianPanelStateModel.isDragging`. Only the
    /// glint layer (L7) reads this; everything else is static.
    let isDragging: Bool

    /// Optional focus accent — when a field in `LibrarianSurface` gains
    /// focus, the surface passes the field's identity color in (Mango
    /// for Search, Klein for Ask) so the edge-glow layer cross-fades
    /// from idle (white at low opacity) to the focused field's hue.
    /// `nil` = idle.
    var activeAccent: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Segmented choices
    @AppStorage(SolarFlareTuningKey.materialBase) private var materialBase: String = SolarFlareTuningDefaults.materialBase
    @AppStorage(SolarFlareTuningKey.palette) private var paletteRaw: String = SolarFlareTuningDefaults.palette
    @AppStorage(SolarFlareTuningKey.noiseBlend) private var noiseBlendRaw: String = SolarFlareTuningDefaults.noiseBlend

    // Per-layer toggles
    @AppStorage(SolarFlareTuningKey.baseOn) private var baseOn: Bool = SolarFlareTuningDefaults.baseOn
    @AppStorage(SolarFlareTuningKey.materialOn) private var materialOn: Bool = SolarFlareTuningDefaults.materialOn
    @AppStorage(SolarFlareTuningKey.sheenOn) private var sheenOn: Bool = SolarFlareTuningDefaults.sheenOn
    @AppStorage(SolarFlareTuningKey.prismaticOn) private var prismaticOn: Bool = SolarFlareTuningDefaults.prismaticOn
    @AppStorage(SolarFlareTuningKey.rimOn) private var rimOn: Bool = SolarFlareTuningDefaults.rimOn
    @AppStorage(SolarFlareTuningKey.noiseOn) private var noiseOn: Bool = SolarFlareTuningDefaults.noiseOn
    @AppStorage(SolarFlareTuningKey.glintOn) private var glintOn: Bool = SolarFlareTuningDefaults.glintOn
    @AppStorage(SolarFlareTuningKey.edgeGlowOn) private var edgeGlowOn: Bool = SolarFlareTuningDefaults.edgeGlowOn

    // Values
    @AppStorage(SolarFlareTuningKey.tintLightness) private var tintLightness: Double = SolarFlareTuningDefaults.tintLightness
    @AppStorage(SolarFlareTuningKey.tintOpacity) private var tintOpacity: Double = SolarFlareTuningDefaults.tintOpacity
    @AppStorage(SolarFlareTuningKey.sheenStrength) private var sheenStrength: Double = SolarFlareTuningDefaults.sheenStrength
    @AppStorage(SolarFlareTuningKey.prismaticStrength) private var prismaticStrength: Double = SolarFlareTuningDefaults.prismaticStrength
    @AppStorage(SolarFlareTuningKey.prismaticDesaturate) private var prismaticDesaturate: Double = SolarFlareTuningDefaults.prismaticDesaturate
    @AppStorage(SolarFlareTuningKey.rimBrightness) private var rimBrightness: Double = SolarFlareTuningDefaults.rimBrightness
    @AppStorage(SolarFlareTuningKey.rimWidth) private var rimWidth: Double = SolarFlareTuningDefaults.rimWidth
    @AppStorage(SolarFlareTuningKey.noiseOpacity) private var noiseOpacity: Double = SolarFlareTuningDefaults.noiseOpacity
    @AppStorage(SolarFlareTuningKey.cornerRadius) private var cornerRadius: Double = SolarFlareTuningDefaults.cornerRadius

    @AppStorage(SolarFlareTuningKey.edgeGlowWidth) private var edgeGlowWidth: Double = SolarFlareTuningDefaults.edgeGlowWidth
    @AppStorage(SolarFlareTuningKey.edgeGlowBlur) private var edgeGlowBlur: Double = SolarFlareTuningDefaults.edgeGlowBlur
    @AppStorage(SolarFlareTuningKey.edgeGlowIdleOpacity) private var edgeGlowIdleOpacity: Double = SolarFlareTuningDefaults.edgeGlowIdleOpacity
    @AppStorage(SolarFlareTuningKey.edgeGlowActiveOpacity) private var edgeGlowActiveOpacity: Double = SolarFlareTuningDefaults.edgeGlowActiveOpacity

    @State private var glintProgress: CGFloat = 0.5

    private var palette: SolarFlarePalette {
        SolarFlarePalette(rawValue: paletteRaw) ?? .solar
    }

    private var noiseBlendMode: BlendMode {
        noiseBlendRaw == "overlay" ? .overlay : .softLight
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            // L2 TRANSLUCENCY — system material as the shape's fill. Placed
            // at the BACK so the material's blur source is the canvas
            // behind the panel, not a uniform color from L1. (If L1 sat
            // behind L2, the material would blur the solid tint —
            // boring and useless.) Spec wording "back-to-front" with L1
            // listed first is conceptual; visually L2 must be rendered
            // first to expose canvas to its blur.
            if materialOn {
                materialFill(shape: shape)
            }

            // L1 BASE TINT — single semi-transparent fill at
            // `Color(white: tintLightness).opacity(tintOpacity)`,
            // sitting OVER the material (the spec's "L1 tint composited
            // over it at sf.tintOpacity"). With materialOn OFF, this
            // becomes the only visible base layer — the tint shows over
            // the bare canvas so T can judge tint independent of the
            // system blur.
            if baseOn {
                shape.fill(
                    Color(white: tintLightness).opacity(tintOpacity)
                )
            }

            // L3 GRADIENT SHEEN — soft top-to-center white fade for the
            // glassy "light catches the top edge" lift. Static.
            if sheenOn {
                shape.fill(
                    LinearGradient(
                        colors: [.white.opacity(sheenStrength), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            }

            // L4 PRISMATIC MESH — static 3x3 MeshGradient with the dark
            // base filling most cells and two desaturated accents from
            // the chosen palette. The desat slider lerps each accent
            // toward mid-grey (oil-slick vs neon). Static points — never
            // animated, never re-laid-out, so this is just a one-time
            // gradient render and stays cheap. Definition lives in
            // SolarFlarePrismaticMesh so the peek-flare can reuse the
            // exact same mesh the panel shows.
            if prismaticOn {
                SolarFlarePrismaticMesh(palette: palette, desaturate: prismaticDesaturate)
                    .opacity(prismaticStrength)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }

            // L4b EDGE GLOW — inner colored halo on the perimeter.
            // Idle = white at very low opacity (ambient identity). When
            // `activeAccent` is non-nil (a field is focused), the stroke
            // color and opacity cross-fade to the focused field's hue
            // (Mango for Search, Klein for Ask). The .animation is
            // attached to the layer itself so the cross-fade fires
            // implicitly when activeAccent changes — no withAnimation
            // needed in the parent. Sits between the mesh (L4) and the
            // crisp rim (L5) so the rim stays sharp on top of the glow.
            if edgeGlowOn {
                let isActive = activeAccent != nil
                let glowColor = activeAccent ?? .white
                let glowOpacity = isActive ? edgeGlowActiveOpacity : edgeGlowIdleOpacity
                shape
                    .strokeBorder(glowColor.opacity(glowOpacity), lineWidth: edgeGlowWidth)
                    .blur(radius: edgeGlowBlur)
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3),
                               value: activeAccent)
            }

            // L5 RIM LIGHT + hairline outer separator. Both static
            // strokes. The rim's gradient (white top → near-clear
            // bottom) gives the panel a lit-from-above feel; the
            // hairline black stroke provides crisp separation from
            // whatever canvas content is behind. The bottom -150
            // overshoot pushes the bottom edge off-screen, so only the
            // top + side strokes are visible — correct.
            if rimOn {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(rimBrightness),
                            .white.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: rimWidth
                )
                shape.stroke(.black.opacity(0.5), lineWidth: 0.5)
            }

            // L6 NOISE / GRAIN — pre-rendered 120x120 tile, tiled,
            // clipped to shape, blended at low opacity. Cached on a
            // static so the ImageRenderer call only runs once per app
            // launch; subsequent renders of SolarFlareMaterial just
            // reuse the UIImage.
            if noiseOn, let tile = SolarFlareNoiseCache.tile() {
                Image(uiImage: tile)
                    .resizable(resizingMode: .tile)
                    .opacity(noiseOpacity)
                    .blendMode(noiseBlendMode)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }

            // L7 INTERACTION GLINT — the ONLY animated layer. A soft
            // radial white highlight that sweeps horizontally during
            // finger-drag (reusing isDragging) and centers when at
            // rest. No blur animation — just a position change on a
            // static radial gradient, so the cost is minimal. Gated
            // off entirely if reduceMotion is on.
            if glintOn && !reduceMotion {
                glintLayer(shape: shape)
            }
        }
        .padding(.bottom, -150)
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: isDragging) { _, dragging in
            updateGlint(dragging: dragging)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func materialFill(shape: RoundedRectangle) -> some View {
        switch materialBase {
        case "ultraThin": shape.fill(.ultraThinMaterial)
        case "regular":   shape.fill(.regularMaterial)
        default:          shape.fill(.thinMaterial)
        }
    }

    @ViewBuilder
    private func glintLayer(shape: RoundedRectangle) -> some View {
        GeometryReader { geo in
            let glintW: CGFloat = 280
            let glintH: CGFloat = 160
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.18), .white.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 140
                    )
                )
                .frame(width: glintW, height: glintH)
                .position(
                    x: glintProgress * geo.size.width,
                    y: geo.size.height * 0.20
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
    }

    /// Start/stop the glint sweep. Dragging → slow horizontal
    /// repeatForever between 0.5↔0.85 (autoreverses); not dragging →
    /// settle back to centered. Repeat is OK here per the spec's perf
    /// carve-out: the glint is a `.position` change on a static
    /// gradient, no blur, so it's cheap.
    private func updateGlint(dragging: Bool) {
        if dragging {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                glintProgress = 0.85
            }
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                glintProgress = 0.5
            }
        }
    }
}

// MARK: - Active-field glow (emanation)

/// Colored halo locked to the focused FIELD'S OWN shape — Playground/
/// Genmoji look where the glow radiates *from the field's edge
/// outward*, not from a blob behind the field. Two stacked stroked
/// passes on the parameterized `shape` (so the halo is concentric with
/// whatever capsule/rounded-rect the field is using):
///   - Outer pass: wider blur, lower opacity → soft radiated halo.
///   - Inner pass: small blur, higher opacity → crisp edge brightness.
/// Both strokes use a 3-stop linear gradient (accent→secondary→accent)
/// so the halo carries a subtle hue shift across the field instead of
/// reading as one flat color.
///
/// `.stroke` (not `.strokeBorder`) so the stroke is centered on the
/// path edge; half the line bleeds outward (gives the emanation) and
/// half bleeds inward (covered by the field's own fill). NO `.clipShape`
/// — the blur must extend past the field's bounds; the surface clips
/// the panel as a whole.
///
/// Stays in the tree always so cross-fades between fields are a smooth
/// opacity ramp; isVisible=false collapses the layer to 0 opacity.
/// `bloomOn` (kept from the bloom rev for AppStorage continuity) is the
/// layer toggle — surfaces gate on it so the layer is truly absent for
/// isolated judgment.
struct SolarFlareFieldGlow<S: Shape>: View {
    let shape: S
    let accent: Color
    let secondary: Color
    let isVisible: Bool

    /// Per-field outer-pass overrides — when non-nil, win over the
    /// shared `sf.fieldGlow*` AppStorage. The Ask field is shorter and
    /// squatter in a busier area, so it reads flatter at Search's
    /// numbers; the Ask call site passes `sf.askGlow*` here while
    /// Search passes nil (uses the shared knobs). Inner-pass blur/
    /// opacity stay shared since they're already crisp at any size.
    var widthOverride: Double? = nil
    var blurOverride: Double? = nil
    var opacityOverride: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(SolarFlareTuningKey.fieldGlowWidth) private var fieldGlowWidth: Double = SolarFlareTuningDefaults.fieldGlowWidth
    @AppStorage(SolarFlareTuningKey.fieldGlowBlur) private var fieldGlowBlur: Double = SolarFlareTuningDefaults.fieldGlowBlur
    @AppStorage(SolarFlareTuningKey.fieldGlowOpacity) private var fieldGlowOpacity: Double = SolarFlareTuningDefaults.fieldGlowOpacity
    @AppStorage(SolarFlareTuningKey.fieldGlowInnerBlur) private var fieldGlowInnerBlur: Double = SolarFlareTuningDefaults.fieldGlowInnerBlur
    @AppStorage(SolarFlareTuningKey.fieldGlowInnerOpacity) private var fieldGlowInnerOpacity: Double = SolarFlareTuningDefaults.fieldGlowInnerOpacity

    var body: some View {
        let gradient = LinearGradient(
            colors: [accent, secondary, accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        let w = widthOverride ?? fieldGlowWidth
        let outerBlur = blurOverride ?? fieldGlowBlur
        let outerOpacity = opacityOverride ?? fieldGlowOpacity

        ZStack {
            // Outer pass — wide soft halo, the bulk of the radiated
            // emanation. Larger blur diffuses the stroke into a soft
            // glow on both sides of the edge; the inward half is
            // covered by the field interior, outward bleeds into
            // the panel.
            shape
                .stroke(gradient, lineWidth: w)
                .blur(radius: outerBlur)
                .opacity(outerOpacity)

            // Inner pass — tight bright rim that defines the edge
            // crisply on top of the diffuse halo. Without this the
            // outer pass alone reads as a fuzzy fog; with it the
            // field's outline stays articulated.
            shape
                .stroke(gradient, lineWidth: w)
                .blur(radius: fieldGlowInnerBlur)
                .opacity(fieldGlowInnerOpacity)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3),
                   value: isVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3),
                   value: accent)
    }
}

// MARK: - Prismatic mesh (reusable)

/// The Solar Flare panel material's L4 — a static 3×3 MeshGradient
/// with the dark base filling most cells and two palette accents
/// landing in two of the nine. Factored out so the peek-flare can
/// reuse the same mesh definition the panel uses; behavior is
/// otherwise identical to the prior inline copy in
/// `SolarFlareMaterial`.
struct SolarFlarePrismaticMesh: View {
    let palette: SolarFlarePalette
    let desaturate: Double

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: Self.points,
            colors: colors
        )
    }

    /// 3×3 grid of corner/edge/center anchors. Static — only the
    /// colors vary by palette + desat.
    private static let points: [SIMD2<Float>] = [
        SIMD2(0, 0),   SIMD2(0.5, 0),   SIMD2(1, 0),
        SIMD2(0, 0.5), SIMD2(0.5, 0.5), SIMD2(1, 0.5),
        SIMD2(0, 1),   SIMD2(0.5, 1),   SIMD2(1, 1)
    ]

    /// Mostly dark base; two palette accents at top-mid and bottom-left.
    private var colors: [Color] {
        let baseDark = Color(white: 0.06)
        let a1 = Self.desat(palette.accents[0], by: desaturate)
        let a2 = Self.desat(palette.accents[1], by: desaturate)
        return [
            baseDark, a1,       baseDark,
            baseDark, baseDark, baseDark,
            a2,       baseDark, baseDark
        ]
    }

    /// Lerp `color` toward its own mid-grey by `amount` (0 = original
    /// hue, 1 = fully grey). Used to dial the prismatic mesh from
    /// neon (0) → oil-slick (~0.5) → dust (1).
    static func desat(_ color: Color, by amount: Double) -> Color {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let grey: CGFloat = (r + g + b) / 3
        let t = CGFloat(amount)
        return Color(
            red: Double(r * (1 - t) + grey * t),
            green: Double(g * (1 - t) + grey * t),
            blue: Double(b * (1 - t) + grey * t)
        )
    }
}

// MARK: - Peek-pill masked flare

/// The peek pill's interior — ONE mask asset, used TWICE, opposite
/// polarity, replacing both the dark center plate AND the standalone
/// color layer that previously fought each other (the prior pass left
/// a glossy dark slab visible behind the masked color).
///
/// `PeekPillMask` is white-on-transparent: the painted soft-edged pill
/// shape is the WHITE region; the surrounding canvas is fully clear.
/// One polarity → dark center, other polarity → color edges:
///   - **Dark center**: `Color.black.mask(PNG as-is)` — the white core
///     punches through to opaque black, transparent edges drop the
///     black entirely. The mask itself provides the dark; no extra
///     plate behind.
///   - **Color edges**: same PNG, INVERTED via a `destinationOut`
///     punch through a full-opaque rectangle. Result is opaque
///     wherever the PNG was transparent (perimeter) and clear
///     wherever the PNG was white (center) — color reveals at the
///     edges only.
/// The colors are a leading→trailing lerp of the palette's two
/// accents (same accents the panel material's L4 mesh uses), so the
/// peek flare reads as a sibling treatment of the panel chrome.
///
/// `allowsHitTesting(false)` — purely visual.
struct SolarFlarePeekFlare: View {
    let colorA: Color
    let colorB: Color
    let desaturate: Double
    let strength: Double
    let maskOpacity: Double

    var body: some View {
        let a0 = SolarFlarePrismaticMesh.desat(colorA, by: desaturate)
        let a1 = SolarFlarePrismaticMesh.desat(colorB, by: desaturate)
        let colorField = LinearGradient(
            colors: [a0, a1], startPoint: .leading, endPoint: .trailing
        )
        ZStack {
            colorField
                .opacity(strength)
                .mask(
                    ZStack {
                        Rectangle().fill(.white)
                        Image("PeekPillMask").resizable().blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
            Color.black
                .opacity(maskOpacity)
                .mask(Image("PeekPillMask").resizable())
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tuning panel (DEBUG)

#if DEBUG
/// Floating Solar Flare tuner widget. Drag by the header; parent owns
/// `position` so the widget survives close/re-open within a session.
/// Mounted in CanvasView's ZStack (NOT inside the FloatingPanel surface,
/// which would eat its touches). Copy button dumps every sf.* value as
/// a yaml-ish block, same export contract as the retired peek tuner.
struct SolarFlareTuningPanel: View {
    @Binding var isPresented: Bool
    @Binding var position: CGSize

    @AppStorage(SolarFlareTuningKey.materialBase) private var materialBase: String = SolarFlareTuningDefaults.materialBase
    @AppStorage(SolarFlareTuningKey.palette) private var paletteRaw: String = SolarFlareTuningDefaults.palette
    @AppStorage(SolarFlareTuningKey.noiseBlend) private var noiseBlendRaw: String = SolarFlareTuningDefaults.noiseBlend

    @AppStorage(SolarFlareTuningKey.baseOn) private var baseOn: Bool = SolarFlareTuningDefaults.baseOn
    @AppStorage(SolarFlareTuningKey.materialOn) private var materialOn: Bool = SolarFlareTuningDefaults.materialOn
    @AppStorage(SolarFlareTuningKey.sheenOn) private var sheenOn: Bool = SolarFlareTuningDefaults.sheenOn
    @AppStorage(SolarFlareTuningKey.prismaticOn) private var prismaticOn: Bool = SolarFlareTuningDefaults.prismaticOn
    @AppStorage(SolarFlareTuningKey.rimOn) private var rimOn: Bool = SolarFlareTuningDefaults.rimOn
    @AppStorage(SolarFlareTuningKey.noiseOn) private var noiseOn: Bool = SolarFlareTuningDefaults.noiseOn
    @AppStorage(SolarFlareTuningKey.glintOn) private var glintOn: Bool = SolarFlareTuningDefaults.glintOn
    @AppStorage(SolarFlareTuningKey.edgeGlowOn) private var edgeGlowOn: Bool = SolarFlareTuningDefaults.edgeGlowOn
    @AppStorage(SolarFlareTuningKey.bloomOn) private var bloomOn: Bool = SolarFlareTuningDefaults.bloomOn

    @AppStorage(SolarFlareTuningKey.tintLightness) private var tintLightness: Double = SolarFlareTuningDefaults.tintLightness
    @AppStorage(SolarFlareTuningKey.tintOpacity) private var tintOpacity: Double = SolarFlareTuningDefaults.tintOpacity
    @AppStorage(SolarFlareTuningKey.sheenStrength) private var sheenStrength: Double = SolarFlareTuningDefaults.sheenStrength
    @AppStorage(SolarFlareTuningKey.prismaticStrength) private var prismaticStrength: Double = SolarFlareTuningDefaults.prismaticStrength
    @AppStorage(SolarFlareTuningKey.prismaticDesaturate) private var prismaticDesaturate: Double = SolarFlareTuningDefaults.prismaticDesaturate
    @AppStorage(SolarFlareTuningKey.rimBrightness) private var rimBrightness: Double = SolarFlareTuningDefaults.rimBrightness
    @AppStorage(SolarFlareTuningKey.rimWidth) private var rimWidth: Double = SolarFlareTuningDefaults.rimWidth
    @AppStorage(SolarFlareTuningKey.noiseOpacity) private var noiseOpacity: Double = SolarFlareTuningDefaults.noiseOpacity
    @AppStorage(SolarFlareTuningKey.cornerRadius) private var cornerRadius: Double = SolarFlareTuningDefaults.cornerRadius

    @AppStorage(SolarFlareTuningKey.edgeGlowWidth) private var edgeGlowWidth: Double = SolarFlareTuningDefaults.edgeGlowWidth
    @AppStorage(SolarFlareTuningKey.edgeGlowBlur) private var edgeGlowBlur: Double = SolarFlareTuningDefaults.edgeGlowBlur
    @AppStorage(SolarFlareTuningKey.edgeGlowIdleOpacity) private var edgeGlowIdleOpacity: Double = SolarFlareTuningDefaults.edgeGlowIdleOpacity
    @AppStorage(SolarFlareTuningKey.edgeGlowActiveOpacity) private var edgeGlowActiveOpacity: Double = SolarFlareTuningDefaults.edgeGlowActiveOpacity

    @AppStorage(SolarFlareTuningKey.fieldGlowWidth) private var fieldGlowWidth: Double = SolarFlareTuningDefaults.fieldGlowWidth
    @AppStorage(SolarFlareTuningKey.fieldGlowBlur) private var fieldGlowBlur: Double = SolarFlareTuningDefaults.fieldGlowBlur
    @AppStorage(SolarFlareTuningKey.fieldGlowOpacity) private var fieldGlowOpacity: Double = SolarFlareTuningDefaults.fieldGlowOpacity
    @AppStorage(SolarFlareTuningKey.fieldGlowInnerBlur) private var fieldGlowInnerBlur: Double = SolarFlareTuningDefaults.fieldGlowInnerBlur
    @AppStorage(SolarFlareTuningKey.fieldGlowInnerOpacity) private var fieldGlowInnerOpacity: Double = SolarFlareTuningDefaults.fieldGlowInnerOpacity

    @AppStorage(SolarFlareTuningKey.askGlowWidth) private var askGlowWidth: Double = SolarFlareTuningDefaults.askGlowWidth
    @AppStorage(SolarFlareTuningKey.askGlowBlur) private var askGlowBlur: Double = SolarFlareTuningDefaults.askGlowBlur
    @AppStorage(SolarFlareTuningKey.askGlowOpacity) private var askGlowOpacity: Double = SolarFlareTuningDefaults.askGlowOpacity

    @AppStorage(SolarFlareTuningKey.peekFlareOn) private var peekFlareOn: Bool = SolarFlareTuningDefaults.peekFlareOn
    @AppStorage(SolarFlareTuningKey.peekFlarePalette) private var peekFlarePaletteRaw: String = SolarFlareTuningDefaults.peekFlarePalette
    @AppStorage(SolarFlareTuningKey.peekFlareStrength) private var peekFlareStrength: Double = SolarFlareTuningDefaults.peekFlareStrength
    @AppStorage(SolarFlareTuningKey.peekFlareDesat) private var peekFlareDesat: Double = SolarFlareTuningDefaults.peekFlareDesat
    @AppStorage(SolarFlareTuningKey.peekFlareMaskOpacity) private var peekFlareMaskOpacity: Double = SolarFlareTuningDefaults.peekFlareMaskOpacity
    @AppStorage(SolarFlareTuningKey.peekFlareColorA) private var peekFlareColorA: String = SolarFlareTuningDefaults.peekFlareColorA
    @AppStorage(SolarFlareTuningKey.peekFlareColorB) private var peekFlareColorB: String = SolarFlareTuningDefaults.peekFlareColorB

    @GestureState private var dragTranslation: CGSize = .zero
    @State private var justCopied: Bool = false

    private static let widgetWidth: CGFloat = 320

    var body: some View {
        // Pinned header + scrollable body. Header stays grabbable at the
        // top while every control below scrolls — the stack grew past
        // the screen as sections accumulated (edge glow / field glow /
        // ask glow / peek matte), and an un-scrolled tuner was
        // occluding the peek pill at the bottom of the screen. ScrollView
        // is capped to ~420pt so even fully extended the widget can't
        // reach the bottom-edge peek pill (~21pt above safe area), and
        // parent-owned `position` still lets it be dragged clear.
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        materialPicker
                        palettePicker
                        noiseBlendPicker
                    }

                    layerToggles

                    Group {
                        sliderRow(label: "tint L",  value: $tintLightness,        range: 0...0.22, step: 0.005, gated: !baseOn)
                        sliderRow(label: "tint α",  value: $tintOpacity,          range: 0...0.85, step: 0.01,  gated: !baseOn)
                        sliderRow(label: "sheen",   value: $sheenStrength,        range: 0...0.20, step: 0.005, gated: !sheenOn)
                        sliderRow(label: "prism",   value: $prismaticStrength,    range: 0...0.60, step: 0.01,  gated: !prismaticOn)
                        sliderRow(label: "desat",   value: $prismaticDesaturate,  range: 0...1,    step: 0.02,  gated: !prismaticOn)
                        sliderRow(label: "rim L",   value: $rimBrightness,        range: 0...0.40, step: 0.01,  gated: !rimOn)
                        sliderRow(label: "rim W",   value: $rimWidth,             range: 0.5...2,  step: 0.1,   gated: !rimOn)
                        sliderRow(label: "noise α", value: $noiseOpacity,         range: 0...0.10, step: 0.005, gated: !noiseOn)
                        sliderRow(label: "corner",  value: $cornerRadius,         range: 16...56,  step: 1)
                    }

                    sectionHeader("edge glow")
                    Group {
                        sliderRow(label: "glow W",   value: $edgeGlowWidth,           range: 0...32,    step: 0.5,  gated: !edgeGlowOn)
                        sliderRow(label: "glow blur", value: $edgeGlowBlur,           range: 0...30,    step: 0.5,  gated: !edgeGlowOn)
                        sliderRow(label: "idle α",   value: $edgeGlowIdleOpacity,     range: 0...0.4,   step: 0.005, gated: !edgeGlowOn)
                        sliderRow(label: "active α", value: $edgeGlowActiveOpacity,   range: 0...1,     step: 0.01,  gated: !edgeGlowOn)
                    }

                    sectionHeader("field glow (search + shared inner)")
                    Group {
                        sliderRow(label: "glow W",    value: $fieldGlowWidth,         range: 1...12,    step: 0.5,   gated: !bloomOn)
                        sliderRow(label: "out blur",  value: $fieldGlowBlur,          range: 2...30,    step: 0.5,   gated: !bloomOn)
                        sliderRow(label: "out α",     value: $fieldGlowOpacity,       range: 0...1,     step: 0.01,  gated: !bloomOn)
                        sliderRow(label: "in blur",   value: $fieldGlowInnerBlur,     range: 0...8,     step: 0.25,  gated: !bloomOn)
                        sliderRow(label: "in α",      value: $fieldGlowInnerOpacity,  range: 0...1,     step: 0.01,  gated: !bloomOn)
                    }

                    // Ask outer-pass overrides — shorter, squatter capsule
                    // reads flatter at Search's numbers, so these dial Ask
                    // hotter independently. Inner-pass is shared above.
                    sectionHeader("ask glow (outer override)")
                    Group {
                        sliderRow(label: "ask W",     value: $askGlowWidth,           range: 1...12,    step: 0.5,   gated: !bloomOn)
                        sliderRow(label: "ask blur",  value: $askGlowBlur,            range: 2...30,    step: 0.5,   gated: !bloomOn)
                        sliderRow(label: "ask α",     value: $askGlowOpacity,         range: 0...1,     step: 0.01,  gated: !bloomOn)
                    }

                    // Peek-pill masked LIVE color flare. Replaces the
                    // flat-fill innerBgOpacity behavior on the morphing
                    // field's peek posture with the prismatic mesh
                    // clipped by the hand-painted PeekPillMask PNG —
                    // palette/strength/desat dialable on-device, falloff
                    // shape edited by repainting the mask.
                    sectionHeader("peek flare")
                    HStack(spacing: 8) {
                        Picker("L", selection: $peekFlareColorA) {
                            ForEach(SolarFlareNamedColor.allCases, id: \.rawValue) { c in
                                Text(c.rawValue).tag(c.rawValue)
                            }
                        }.pickerStyle(.menu)
                        Picker("R", selection: $peekFlareColorB) {
                            ForEach(SolarFlareNamedColor.allCases, id: \.rawValue) { c in
                                Text(c.rawValue).tag(c.rawValue)
                            }
                        }.pickerStyle(.menu)
                    }
                    .opacity(peekFlareOn ? 1 : 0.3)
                    .allowsHitTesting(peekFlareOn)
                    Group {
                        sliderRow(label: "strength", value: $peekFlareStrength,   range: 0...1, step: 0.01, gated: !peekFlareOn)
                        sliderRow(label: "mask α",   value: $peekFlareMaskOpacity, range: 0...1, step: 0.01, gated: !peekFlareOn)
                        sliderRow(label: "desat",    value: $peekFlareDesat,       range: 0...1, step: 0.02, gated: !peekFlareOn)
                    }
                }
            }
            // 420pt keeps header + scroll ≤ ~⅔ of an iPhone 17 Pro Max's
            // 956pt portrait height — well clear of the peek pill at the
            // bottom (~21pt above safe area). Tune if a section grows
            // enough that the cap feels cramped.
            .frame(maxHeight: 420)
            .scrollIndicators(.visible)
        }
        .padding(12)
        .frame(width: Self.widgetWidth)
        .modifier(WidgetSurface())
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
        .offset(x: position.width + dragTranslation.width,
                y: position.height + dragTranslation.height)
    }

    // MARK: - Header (drag handle + copy + close)

    private var header: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
            HStack(spacing: 4) {
                Text("Solar Flare")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { copyValues() } label: {
                    Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(justCopied ? Color.green : .secondary)
                        .contentShape(Rectangle())
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy values")
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        // Drag ONLY on the header — putting it on the whole widget
        // would fight the sliders' own gesture (TileTuningPanel pattern).
        .gesture(
            DragGesture()
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    position.width  += value.translation.width
                    position.height += value.translation.height
                }
        )
    }

    // MARK: - Segmented pickers

    private var materialPicker: some View {
        Picker("Material", selection: $materialBase) {
            Text("ultraThin").tag("ultraThin")
            Text("thin").tag("thin")
            Text("regular").tag("regular")
        }
        .pickerStyle(.segmented)
    }

    private var palettePicker: some View {
        Picker("Palette", selection: $paletteRaw) {
            ForEach(SolarFlarePalette.allCases, id: \.rawValue) { p in
                Text(p.rawValue).tag(p.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }

    private var noiseBlendPicker: some View {
        Picker("Noise Blend", selection: $noiseBlendRaw) {
            Text("softLight").tag("softLight")
            Text("overlay").tag("overlay")
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Layer toggles (9 mini pills, ~3 rows of 4)

    private var layerToggles: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                layerToggle("base",  isOn: $baseOn)
                layerToggle("mat",   isOn: $materialOn)
                layerToggle("sheen", isOn: $sheenOn)
                layerToggle("prism", isOn: $prismaticOn)
            }
            HStack(spacing: 4) {
                layerToggle("glow",  isOn: $edgeGlowOn)
                layerToggle("rim",   isOn: $rimOn)
                layerToggle("noise", isOn: $noiseOn)
                layerToggle("glint", isOn: $glintOn)
            }
            HStack(spacing: 4) {
                // "field" rather than "glow" — that label is already
                // taken by the edge-glow pill (row 2). `bloomOn` is
                // the underlying key; the bloom→field-glow rewrite
                // kept the key for AppStorage continuity.
                layerToggle("field", isOn: $bloomOn)
                // "flare" → peek-pill masked LIVE color flare. Flip OFF
                // to fall back to the legacy flat-fill innerBgOpacity
                // behavior on the morphing field's peek state.
                layerToggle("flare", isOn: $peekFlareOn)
                // Two empty cells keep this row aligned to the 4-pill
                // grid above without stretching the active pills.
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
    }

    /// Tiny in-panel label for grouping the new edge-glow / bloom
    /// slider blocks. Matches the rest of the tuner's monospaced caption
    /// style so the section bars don't visually compete with the sliders.
    private func sectionHeader(_ label: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)
        }
        .padding(.top, 4)
    }

    private func layerToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn.wrappedValue
                              ? Color.accentColor.opacity(0.85)
                              : Color.gray.opacity(0.18))
                )
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.secondary)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slider row

    @ViewBuilder
    private func sliderRow(label: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double,
                           gated: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 56, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: step)
            Text(String(format: "%.3f", value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .opacity(gated ? 0.3 : 1)
        .allowsHitTesting(!gated)
    }

    // MARK: - Copy values

    /// Read every @AppStorage knob and copy a yaml-ish snapshot to the
    /// pasteboard. Used to dump observed-on-device numbers so they can
    /// be baked into static constants in a follow-up pass.
    private func copyValues() {
        let lines: [String] = [
            "solar_flare:",
            "  segmented:",
            "    materialBase:        \(materialBase)",
            "    palette:             \(paletteRaw)",
            "    noiseBlend:          \(noiseBlendRaw)",
            "  layers:",
            "    baseOn:                 \(baseOn)",
            "    materialOn:             \(materialOn)",
            "    sheenOn:                \(sheenOn)",
            "    prismaticOn:            \(prismaticOn)",
            "    edgeGlowOn:             \(edgeGlowOn)",
            "    rimOn:                  \(rimOn)",
            "    noiseOn:                \(noiseOn)",
            "    glintOn:                \(glintOn)",
            "    bloomOn:                \(bloomOn)",
            "    peekFlareOn:            \(peekFlareOn)",
            "  values:",
            "    tintLightness:          \(String(format: "%.3f", tintLightness))",
            "    tintOpacity:            \(String(format: "%.2f", tintOpacity))",
            "    sheenStrength:          \(String(format: "%.3f", sheenStrength))",
            "    prismaticStrength:      \(String(format: "%.2f", prismaticStrength))",
            "    prismaticDesaturate:    \(String(format: "%.2f", prismaticDesaturate))",
            "    rimBrightness:          \(String(format: "%.2f", rimBrightness))",
            "    rimWidth:               \(String(format: "%.2f", rimWidth))",
            "    noiseOpacity:           \(String(format: "%.3f", noiseOpacity))",
            "    cornerRadius:           \(String(format: "%.0f", cornerRadius))",
            "  edgeGlow:",
            "    edgeGlowWidth:          \(String(format: "%.2f", edgeGlowWidth))",
            "    edgeGlowBlur:           \(String(format: "%.2f", edgeGlowBlur))",
            "    edgeGlowIdleOpacity:    \(String(format: "%.3f", edgeGlowIdleOpacity))",
            "    edgeGlowActiveOpacity:  \(String(format: "%.2f", edgeGlowActiveOpacity))",
            "  fieldGlow:",
            "    fieldGlowWidth:         \(String(format: "%.2f", fieldGlowWidth))",
            "    fieldGlowBlur:          \(String(format: "%.2f", fieldGlowBlur))",
            "    fieldGlowOpacity:       \(String(format: "%.2f", fieldGlowOpacity))",
            "    fieldGlowInnerBlur:     \(String(format: "%.2f", fieldGlowInnerBlur))",
            "    fieldGlowInnerOpacity:  \(String(format: "%.2f", fieldGlowInnerOpacity))",
            "  askGlow:",
            "    askGlowWidth:           \(String(format: "%.2f", askGlowWidth))",
            "    askGlowBlur:            \(String(format: "%.2f", askGlowBlur))",
            "    askGlowOpacity:         \(String(format: "%.2f", askGlowOpacity))",
            "  peekFlare:",
            "    peekFlareColorA:        \(peekFlareColorA)",
            "    peekFlareColorB:        \(peekFlareColorB)",
            "    peekFlareMaskOpacity:   \(String(format: "%.2f", peekFlareMaskOpacity))",
            "    peekFlareStrength:      \(String(format: "%.2f", peekFlareStrength))",
            "    peekFlareDesat:         \(String(format: "%.2f", peekFlareDesat))"
        ]
        UIPasteboard.general.string = lines.joined(separator: "\n")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            justCopied = false
        }
    }
}

// MARK: - WidgetSurface
// Liquid Glass on iOS 26+, `.thinMaterial` fallback — mirrors the
// TileTuningPanel widget's surface so the two debug tuners read as part
// of the same chrome family.

private struct WidgetSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}
#endif
