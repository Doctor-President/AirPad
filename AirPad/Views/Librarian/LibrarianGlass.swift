import SwiftUI

/// live-24 — the Librarian on REAL Liquid Glass, plus a "Siri-style" graded tint, all live in the TestFlight tuner.
///
/// Apple's Liquid Glass exposes a variant (regular / clear), a tint, a shape, interactivity and container merging —
/// nothing else. Blur, refraction and translucency belong to the system (and to the user: iOS 27's Liquid Glass
/// slider in Settings). So the tuner's glass mode only turns the knobs Apple offers, and everything else is OUR layer
/// drawn inside the glass shape, over the real `.glassEffect`:
///   • a reading veil — a soft-edged layer behind the transcript, so the panel's edges keep the lensing while the area
///     behind paragraphs calms;
///   • a graded tint (T's reference: iOS 27's Spotlight / Siri "Search or Ask" pill) — dense where the text sits,
///     thinning toward an edge, where the glass still lenses what's underneath;
///   • on the pills, an optional thin rim in AirPad's own palette, which can move while an answer is generating.
///     Never Apple's Apple Intelligence multicolour edge: that marks Apple Intelligence, and this pill may be fronting
///     Qwen through the Host.
/// live-26 (1): what ships is T's 2026-10-18 tuning (`LibrarianGlassLook.shipped(dark:)`); the TestFlight tuner varies it live.

// MARK: - Choices

enum GlassVariant: String, Codable, CaseIterable, Identifiable {
    case regular, clear
    var id: String { rawValue }
    var label: String { self == .regular ? "Regular" : "Clear" }
    var glass: Glass { self == .regular ? .regular : .clear }
}

/// The tint colours the glass + graded tint offer (T, 2026-10-17). Hex only.
enum GlassTintColor: String, Codable, CaseIterable, Identifiable {
    case offWhite, nearBlack, deepKlein
    var id: String { rawValue }
    var hex: String {
        switch self {
        case .offWhite:  return "FBF9F5"   // the light panel tint (L2)
        case .nearBlack: return "0A0A0A"
        case .deepKlein: return "0E2D61"   // Klein #1B59C2 at half brightness
        }
    }
    var label: String {
        switch self {
        case .offWhite:  return "Off-white"
        case .nearBlack: return "Near-black"
        case .deepKlein: return "Deep Klein"
        }
    }
    /// A dark tint wants light text on it.
    var isDark: Bool { self != .offWhite }
    var color: Color { Color(hexString: hex) }
}

/// The pill rim's colours — AirPad's palette only (never Apple's multicolour Apple Intelligence edge).
enum PillRimColor: String, Codable, CaseIterable, Identifiable {
    case white, klein, cyan, mango
    var id: String { rawValue }
    var hex: String {
        switch self {
        case .white: return "FFFFFF"
        case .klein: return "1B59C2"
        case .cyan:  return "00BFFF"
        case .mango: return "E8820A"
        }
    }
    var label: String {
        switch self {
        case .white: return "White"
        case .klein: return "Klein"
        case .cyan:  return "Electric Cyan"
        case .mango: return "Mango"
        }
    }
    var color: Color { Color(hexString: hex) }
}

/// What the rim shows while the pill is idle (2026-10-17 brief: "off at rest, shimmer while thinking").
enum PillRimRest: String, Codable, CaseIterable, Identifiable {
    case off, `static`, dim
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:    return "Off"
        case .static: return "On"
        case .dim:    return "Dim"
        }
    }
    /// The rest stroke's share of the rim's brightness.
    var share: Double {
        switch self {
        case .off:    return 0
        case .static: return 1
        case .dim:    return 0.4
        }
    }
}

/// What the rim does while an answer is generating (never under Reduce Motion).
enum PillRimActive: String, Codable, CaseIterable, Identifiable {
    case none, shimmer, breathe
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:    return "Off"
        case .shimmer: return "Slow shimmer"
        case .breathe: return "Breathe"
        }
    }
}

enum GradeDirection: String, Codable, CaseIterable, Identifiable {
    case vertical, radial
    var id: String { rawValue }
    var label: String { self == .vertical ? "Vertical" : "Radial from text" }
}

// MARK: - Values

/// The panel as real Liquid Glass (the tuner's "Liquid Glass" mode).
struct PanelGlass: Codable, Equatable {
    var variant: GlassVariant
    var tint: GlassTintColor
    var tintStrength: Double   // 0…0.80, the glass's own tint
    var veil: Double           // 0…1, our reading veil between the glass and the transcript

    static let lightDefault = PanelGlass(variant: .regular, tint: .offWhite, tintStrength: 0.30, veil: 0.40)
    static let darkDefault = PanelGlass(variant: .regular, tint: .nearBlack, tintStrength: 0.40, veil: 0.50)
}

/// A graded tint inside a glass shape: `top` density until `start` (0 = the top edge, 1 = the bottom), then an eased
/// fall to `bottom` over `softness` of what's left. Radial: the same curve from the text's centre out to the edge.
struct GradedTint: Codable, Equatable {
    var on: Bool
    var top: Double
    var bottom: Double
    var start: Double
    var softness: Double
    var direction: GradeDirection
    var color: GlassTintColor

    static let off = GradedTint(on: false, top: 0.9, bottom: 0.15, start: 0.35, softness: 0.65, direction: .vertical,
                                color: .nearBlack)

    /// Opacity at `t` (0…1 down the shape, or out from the centre when radial). Pure.
    func alpha(at t: Double) -> Double {
        let a = min(max(top, 0), 1), b = min(max(bottom, 0), 1)
        let s = min(max(start, 0), 1)
        let x = min(max(t, 0), 1)
        guard x > s else { return a }
        let span = max(0.02, min(max(softness, 0), 1) * (1 - s))
        let p = min((x - s) / span, 1)
        return a + (b - a) * (p * p * (3 - 2 * p))   // smoothstep
    }

    /// 17 stops of `alpha` in the tint colour.
    var stops: [Gradient.Stop] {
        (0...16).map { i in
            let t = Double(i) / 16
            return .init(color: color.color.opacity(alpha(at: t)), location: t)
        }
    }

    /// The density where a single line of text sits (the vertical centre, or the radial centre).
    var alphaBehindText: Double { direction == .radial ? alpha(at: 0) : alpha(at: 0.5) }
}

/// The pill's rim: what it shows at rest, and what it does while an answer is generating. The two are independent, so
/// a rim can be off at rest and shimmer only while the Librarian thinks.
struct PillRim: Codable, Equatable {
    var rest: PillRimRest
    var width: Double            // 0.5…2 pt
    var brightness: Double       // 0…1, the rest stroke
    var color: PillRimColor
    var active: PillRimActive
    var activeBrightness: Double // 0…1, the shimmer's peak / the breath's top

    static let off = PillRim(rest: .off, width: 1, brightness: 0.8, color: .white, active: .none, activeBrightness: 1)

    init(rest: PillRimRest, width: Double, brightness: Double, color: PillRimColor, active: PillRimActive,
         activeBrightness: Double) {
        self.rest = rest; self.width = width; self.brightness = brightness; self.color = color
        self.active = active; self.activeBrightness = activeBrightness
    }

    /// The rim moves only while an answer is generating, never under Reduce Motion. Pure.
    static func animates(_ r: PillRim, generating: Bool, reduceMotion: Bool) -> Bool {
        r.active != .none && generating && !reduceMotion
    }

    /// Anything of the rim can show (at rest, or while generating).
    var isUsed: Bool { rest != .off || active != .none }

    private enum CodingKeys: String, CodingKey { case rest, width, brightness, color, active, activeBrightness, on, animation }

    /// live-24's rim (`on` + `animation`, TF 202610170354) loads as it rendered: on → a rim at rest, and the
    /// animation only where the rim was on (an off rim never moved).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.8
        color = (try? c.decodeIfPresent(PillRimColor.self, forKey: .color)) ?? .white
        activeBrightness = try c.decodeIfPresent(Double.self, forKey: .activeBrightness) ?? 1
        if let r = try? c.decodeIfPresent(PillRimRest.self, forKey: .rest) {
            rest = r
            active = (try? c.decodeIfPresent(PillRimActive.self, forKey: .active)) ?? .none
        } else {
            let on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? false
            rest = on ? .static : .off
            let old = (try? c.decodeIfPresent(String.self, forKey: .animation)) ?? "off"
            active = !on ? .none : old == "shimmer" ? .shimmer : old == "pulse" ? .breathe : .none
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rest, forKey: .rest); try c.encode(width, forKey: .width); try c.encode(brightness, forKey: .brightness)
        try c.encode(color, forKey: .color); try c.encode(active, forKey: .active)
        try c.encode(activeBrightness, forKey: .activeBrightness)
    }
}

/// One pill's look (the peek pill, the search pill, the Ask bar each have their own; 2026-10-17 brief).
struct PillLook: Codable, Equatable {
    var variant: GlassVariant
    var grade: GradedTint
    var rim: PillRim

    static let off = PillLook(variant: .regular, grade: .off, rim: .off)

    init(variant: GlassVariant, grade: GradedTint, rim: PillRim) {
        self.variant = variant; self.grade = grade; self.rim = rim
    }
    private enum CodingKeys: String, CodingKey { case variant, grade, rim }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variant = (try? c.decodeIfPresent(GlassVariant.self, forKey: .variant)) ?? .regular
        grade = (try? c.decodeIfPresent(GradedTint.self, forKey: .grade)) ?? .off
        rim = (try? c.decodeIfPresent(PillRim.self, forKey: .rim)) ?? .off
    }
}

/// live-26 (1) — T's 2026-10-18 pills, verbatim (the Ask bar ships Search's: "Match Search" is on).
extension PillLook {
    static let shippedLightPeek = PillLook(variant: .clear,
        grade: GradedTint(on: true, top: 0.9, bottom: 0.05, start: 0.3, softness: 1, direction: .vertical, color: .offWhite),
        rim: PillRim(rest: .dim, width: 1, brightness: 0.8, color: .white, active: .none, activeBrightness: 1))
    static let shippedLightSearch = PillLook(variant: .clear,
        grade: GradedTint(on: false, top: 0.9, bottom: 0.42, start: 0.59, softness: 0.66, direction: .vertical, color: .offWhite),
        rim: PillRim(rest: .off, width: 1, brightness: 0.8, color: .cyan, active: .shimmer, activeBrightness: 1))
    static let shippedDarkPeek = PillLook(variant: .clear,
        grade: GradedTint(on: true, top: 1, bottom: 0.25, start: 0.27, softness: 1, direction: .vertical, color: .nearBlack),
        rim: PillRim(rest: .dim, width: 0.75, brightness: 0.41, color: .white, active: .none, activeBrightness: 1))
    static let shippedDarkSearch = PillLook(variant: .clear,
        grade: GradedTint(on: true, top: 0.72, bottom: 0.44, start: 0.27, softness: 1, direction: .vertical, color: .nearBlack),
        rim: PillRim(rest: .off, width: 0.5, brightness: 0.11, color: .cyan, active: .shimmer, activeBrightness: 1))
}

/// Everything live-24 adds to the Librarian's look, for one appearance. The three pills are independent: the peek pill
/// and the search pill are ONE morphing view (`LibrarianSurface.morphingField`), so its look blends from `peek` to
/// `search` as the panel opens; the Ask bar has `ask`.
struct LibrarianGlassLook: Equatable {
    var panelGlass: PanelGlass?      // nil = the frost (LibrarianSurfaceSpec)
    var panelGrade: GradedTint
    var peek: PillLook
    var search: PillLook
    var ask: PillLook

    /// The frost, nothing graded, no rim (live-24's App Store look; the tuner's "All off").
    static let allOff = LibrarianGlassLook(panelGlass: nil, panelGrade: .off, peek: .off, search: .off, ask: .off)

    /// What an App Store build renders for an appearance.
    /// ★ live-26 (1) — T's final tuning (2026-10-18, TF 202610171546, Ops `reference/appearance-tuning-2026-10-18.md`),
    /// light and dark alike in kind: the panel on Liquid Glass (Regular, tint 20%, reading veil 30%) with a graded tint;
    /// every pill Clear; Peek graded with a dim white rim at rest; Search (and the Ask bar, which matches it) no rim at
    /// rest, a cyan #00BFFF shimmer only while answering. Light: off-white #FBF9F5, Search ungraded. Dark: near-black
    /// #0A0A0A, Search graded.
    static func shipped(dark: Bool) -> LibrarianGlassLook { dark ? shippedDark : shippedLight }
    static let shippedLight = LibrarianGlassLook(
        panelGlass: PanelGlass(variant: .regular, tint: .offWhite, tintStrength: 0.2, veil: 0.3),
        panelGrade: GradedTint(on: true, top: 0.1, bottom: 0.75, start: 0.04, softness: 0.4, direction: .vertical, color: .offWhite),
        peek: .shippedLightPeek, search: .shippedLightSearch, ask: .shippedLightSearch)
    static let shippedDark = LibrarianGlassLook(
        panelGlass: PanelGlass(variant: .regular, tint: .nearBlack, tintStrength: 0.2, veil: 0.3),
        panelGrade: GradedTint(on: true, top: 0.73, bottom: 0.32, start: 0.04, softness: 0.22, direction: .vertical, color: .nearBlack),
        peek: .shippedDarkPeek, search: .shippedDarkSearch, ask: .shippedDarkSearch)

    /// What renders: the tuner's values in DEBUG (with `-AppearanceTuner YES`) / TestFlight, else `shipped`.
    static func current(dark: Bool) -> LibrarianGlassLook {
        #if DEBUG || TESTFLIGHT
        if let v = AppearanceTuning.values(dark: dark) { return v.glassLook }
        #endif
        return shipped(dark: dark)
    }

    /// Text over a pill: a dense dark grade wants light text, a dense light one dark text; nil = the appearance's.
    static func pillScheme(_ g: GradedTint) -> ColorScheme? {
        guard g.on, g.alphaBehindText >= 0.5 else { return nil }
        return g.color.isDark ? .dark : .light
    }

    /// The morphing pill's share of the search look: 0 at peek, 1 once the peek styling has faded (p ≈ 0.35). Pure.
    static func searchShare(peekVisibility: Double) -> Double { min(max(1 - peekVisibility, 0), 1) }
}

/// live-25 (1) — which light/dark side the text and the glyphs on a pill resolve to. On a dense graded tint the text
/// flips (light text on near-black); the glyphs beside it (the Ask bar's × / send / mic / stop, the search pill's
/// magnifier, × and mic) must flip WITH it, or a light-mode × in dark ink sits on near-black, nearly invisible.
enum LibrarianPillChrome {
    /// The pill text's scheme.
    static func textScheme(_ grade: GradedTint, appearance: ColorScheme, glassControls: Bool) -> ColorScheme {
        glassControls ? (LibrarianGlassLook.pillScheme(grade) ?? appearance) : appearance
    }
    /// The glyphs' scheme (the Ask bar's send-controls overlay sits outside the text row, so it's set on its own).
    static func controlsScheme(_ grade: GradedTint, appearance: ColorScheme, glassControls: Bool) -> ColorScheme {
        textScheme(grade, appearance: appearance, glassControls: glassControls)
    }
    /// `AppearancePalette.ink` on each side (the × is this ink at `clearGlyphOpacity`).
    static func inkHex(_ scheme: ColorScheme) -> String { scheme == .dark ? "FFFFFF" : "232A2E" }

    // live-26 (2) — the pill glyphs and placeholders reach WCAG non-text 3:1 / text 4.5:1 on T's baked look (measured
    // in the Simulator over a busy Card grid, light + dark; Ops design-refs/live26-*/contrast.md).
    /// The ×'s ink opacity (Ask bar, search pill, composer).
    static func clearGlyphOpacity(_ scheme: ColorScheme) -> Double { sweep("PillClearOpacity", scheme) ?? (scheme == .light ? 0.6 : 0.4) }   // light: was 0.4 (2.02:1); 0.55 = 2.77, 0.60 = 3.14
    /// The resting search pill's magnifier ink (× the pill's 0.66 → 1 icon fade).
    static func peekMagnifierOpacity(_ scheme: ColorScheme) -> Double { sweep("PillMagnifierOpacity", scheme) ?? (scheme == .light ? 0.9 : 0.85) }   // light: was 0.85 (2.87:1); 0.90 = 3.07
    /// The "Search" / "Ask" placeholders' ink opacity (nil = the system placeholder colour).
    static func placeholderOpacity(_ scheme: ColorScheme) -> Double? { sweep("PillPlaceholderOpacity", scheme) ?? (scheme == .light ? 0.8 : 0.55) }   // was the system colour (1.6 / 2.0:1); light 0.75 = 4.45
    /// live-28 (4) — the open search pill's magnifier under Increase Contrast in light takes the pill's ink (Mango on the
    /// solid light pill measured 2.09:1; ink is 15:1). Everyone else keeps Mango (T: "keep it").
    static func searchMagnifierUsesInk(_ scheme: ColorScheme, increaseContrast: Bool) -> Bool { increaseContrast && scheme == .light }
    /// Send / feather / mic / stop: light → solid Klein (the cyan top of the gradient is ~1.8:1 on a light pill).
    static func accentIsSolidKlein(_ scheme: ColorScheme) -> Bool { scheme == .light }
    /// DEBUG `-<key>Light 0.75` / `-<key>Dark 0.55`: an opacity sweep for the contrast stills. Nil otherwise.
    private static func sweep(_ key: String, _ scheme: ColorScheme) -> Double? {
        #if DEBUG
        let k = key + (scheme == .light ? "Light" : "Dark")
        if UserDefaults.standard.object(forKey: k) != nil { return UserDefaults.standard.double(forKey: k) }
        #endif
        return nil
    }
    /// A placeholder in the pill's ink at `placeholderOpacity`.
    static func placeholder(_ text: String, _ scheme: ColorScheme) -> Text {
        guard let o = placeholderOpacity(scheme) else { return Text(text) }
        return Text(text).foregroundStyle(Color(hexString: inkHex(scheme)).opacity(o))
    }
    static func accent(_ scheme: ColorScheme) -> AnyShapeStyle {
        accentIsSolidKlein(scheme) ? AnyShapeStyle(Color(hexString: "1B59C2"))
            : AnyShapeStyle(LinearGradient(colors: [Color(hexString: "00BFFF"), Color(hexString: "1B59C2")],
                                           startPoint: .top, endPoint: .bottom))
    }
}

/// Reduce Transparency / Increase Contrast, resolved once (pure, for the self-test).
struct LibrarianGlassAccessibility: Equatable {
    var solid: Bool            // Reduce Transparency: an opaque panel + pills instead of glass
    var veilFloor: Double      // Increase Contrast: the reading veil never thinner than this
    var strokeOpacity: Double  // Increase Contrast: a firmer edge

    static func resolve(reduceTransparency: Bool, increaseContrast: Bool) -> LibrarianGlassAccessibility {
        LibrarianGlassAccessibility(solid: reduceTransparency, veilFloor: increaseContrast ? 0.85 : 0,
                                    strokeOpacity: increaseContrast ? 0.45 : 0.10)
    }
    /// The solid fallback's fill: the panel tint of the appearance.
    static func solidHex(dark: Bool) -> String { dark ? "141414" : "FBF9F5" }
    /// live-27 (4d) — the solid fill a pill takes under Reduce Transparency: ALWAYS ours, on the side its text and glyphs
    /// resolve to (`LibrarianGlassLook.pillScheme`, else the appearance) — a dense dark grade keeps its colour, everything
    /// else is the panel's solid. T (TF 202610180346): light's ungraded Search / Ask pills fell to the system's own RT
    /// glass, solid dark charcoal under dark ink. (Non-optional; the optional return is kept for the self-test's shape.)
    /// Whether a pill drops its glass for `solidPillHex`.
    /// Reduce Transparency or Increase Contrast (live-27 (4d): the system's high-contrast Clear glass is dark charcoal
    /// in light as well).
    static func pillIsSolid(reduceTransparency: Bool, increaseContrast: Bool) -> Bool { reduceTransparency || increaseContrast }
    static func solidPillHex(_ look: PillLook, appearance: ColorScheme) -> String? {
        let side = LibrarianGlassLook.pillScheme(look.grade) ?? appearance
        if side == .dark { return look.grade.on && look.grade.color.isDark ? look.grade.color.hex : solidHex(dark: true) }
        return solidHex(dark: false)
    }
}

// MARK: - Views

/// The graded tint as a fill for a shape (vertical, or elliptical from `center`).
struct GradedTintFill<S: Shape>: View {
    let shape: S
    let grade: GradedTint
    var center: UnitPoint = .center

    var body: some View {
        switch grade.direction {
        case .vertical:
            shape.fill(LinearGradient(stops: grade.stops, startPoint: .top, endPoint: .bottom))
        case .radial:
            shape.fill(EllipticalGradient(stops: grade.stops, center: center, startRadiusFraction: 0, endRadiusFraction: 0.75))
        }
    }
}

/// The whole Librarian panel as real Liquid Glass (+ the reading veil, + an optional graded tint). The -150 bottom
/// buffer matches the other panel materials so the morph geometry is identical.
struct LibrarianGlassPanel: View {
    let glass: PanelGlass
    let grade: GradedTint
    let dark: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 40, style: .continuous)
        let a11y = LibrarianGlassAccessibility.resolve(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
        let veil = max(glass.veil, a11y.veilFloor)
        ZStack {
            if a11y.solid {
                shape.fill(Color(hexString: LibrarianGlassAccessibility.solidHex(dark: dark)))
            } else {
                Color.clear
                    .glassEffect(glass.variant.glass.tint(glass.tint.color.opacity(min(max(glass.tintStrength, 0), 0.8))), in: shape)
                if grade.on { GradedTintFill(shape: shape, grade: grade, center: UnitPoint(x: 0.5, y: 0.55)) }
                if veil > 0 { ReadingVeil(dark: dark, opacity: veil) }
            }
            shape.strokeBorder((dark ? Color.white : Color(hexString: "232A2E")).opacity(a11y.strokeOpacity),
                               lineWidth: a11y.strokeOpacity > 0.2 ? 1 : 0.5)
        }
        .padding(.bottom, -150)
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// A graded tint over the frost panel (the frost keeps its own look; the grade sits inside its shape).
struct LibrarianPanelGradeOverlay: View {
    let grade: GradedTint
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if grade.on && !reduceTransparency {
            GradedTintFill(shape: RoundedRectangle(cornerRadius: 40, style: .continuous), grade: grade,
                           center: UnitPoint(x: 0.5, y: 0.55))
                .padding(.bottom, -150)
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
        }
    }
}

/// Our own calm layer behind the transcript: inset from the panel's edges with a soft falloff, so the edges keep the
/// glass's lensing and only the reading area quiets down.
struct ReadingVeil: View {
    let dark: Bool
    let opacity: Double

    static let inset: CGFloat = 18, feather: CGFloat = 26, top: CGFloat = 96, bottomBuffer: CGFloat = 150

    private var fill: Color {
        Color(hexString: LibrarianGlassAccessibility.solidHex(dark: dark)).opacity(min(max(opacity, 0), 1))
    }

    /// Under the header + search field down to the panel's visible bottom (the material carries a 150 pt buffer below
    /// it), inset from the sides; the blur softens the edge by `feather`.
    static func rect(in size: CGSize) -> CGRect {
        let side: CGFloat = inset + feather / 2
        let bottom: CGFloat = size.height - bottomBuffer - feather / 2
        let w: CGFloat = max(0, size.width - 2 * side)
        let h: CGFloat = max(0, bottom - top)
        return CGRect(x: side, y: top, width: w, height: h)
    }

    var body: some View {
        GeometryReader { geo in
            let rect = Self.rect(in: geo.size)
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(fill)
                .frame(width: rect.width, height: rect.height)
                .blur(radius: Self.feather / 2)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
    }
}

/// A pill face on real Liquid Glass with its optional graded tint and rim. The Ask bar draws one look; the morphing
/// peek → search pill passes `from` (the peek look) and `share` (0 at peek → 1 expanded), and the two cross-fade.
struct LibrarianPillGlass<S: InsettableShape>: View {
    let shape: S
    let pill: PillLook
    var generating = false
    var from: PillLook? = nil
    var share: Double = 1
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// The look that dominates now (the variant + the solid fallback can't blend).
    private var dominant: PillLook { (from != nil && share < 0.5) ? from! : pill }
    private var layers: [(PillLook, Double, Bool)] { Self.layers(pill: pill, from: from, share: share) }

    /// The layers to draw: (look, opacity, can animate). One when there's nothing to blend. Pure (self-tested).
    static func layers(pill: PillLook, from: PillLook?, share: Double) -> [(PillLook, Double, Bool)] {
        // Identical looks: one layer, which moves once the pill is the search field (the peek pill never answers).
        guard let f = from, f != pill else { return [(pill, 1, from == nil || share >= 0.5)] }
        let t = min(max(share, 0), 1)
        return [(f, 1 - t, false), (pill, t, true)].filter { $0.1 > 0.001 }
    }

    var body: some View {
        let d = dominant
        ZStack {
            // Reduce Transparency: every pill turns solid on the side its text resolves to (live-27 (4d): the system's own
            // RT glass was dark charcoal under light's dark ink).
            if LibrarianGlassAccessibility.pillIsSolid(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased),
               let hex = LibrarianGlassAccessibility.solidPillHex(d, appearance: colorScheme) {
                shape.fill(Color(hexString: hex))
            } else {
                Color.clear.glassEffect(d.variant.glass, in: shape)
                ForEach(Array(layers.enumerated()), id: \.offset) { _, l in
                    if l.0.grade.on { GradedTintFill(shape: shape, grade: l.0.grade).opacity(l.1) }
                }
            }
        }
        .overlay {
            ForEach(Array(layers.enumerated()), id: \.offset) { _, l in
                if l.0.rim.isUsed {
                    PillRimView(shape: shape, rim: l.0.rim,
                                animating: l.2 && PillRim.animates(l.0.rim, generating: generating, reduceMotion: reduceMotion))
                        .opacity(l.1)
                }
            }
        }
    }
}

/// The thin rim: its rest stroke (off / on / dim), and — only while generating — a slow light running around it or a
/// gentle breath. Start and stop fade over 0.2 s, so a rim that's off at rest never pops in or out.
struct PillRimView<S: InsettableShape>: View {
    let shape: S
    let rim: PillRim
    let animating: Bool

    var body: some View {
        let w = CGFloat(min(max(rim.width, 0.5), 2))
        let color = rim.color.color
        let restAlpha = min(max(rim.brightness, 0), 1) * rim.rest.share
        let peak = color.opacity(min(max(rim.activeBrightness, 0), 1))
        ZStack {
            if restAlpha > 0 { shape.strokeBorder(color.opacity(restAlpha), lineWidth: w).opacity(animating ? 0 : 1) }
            if animating {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    switch rim.active {
                    case .shimmer:
                        let angle = Angle.degrees((t.truncatingRemainder(dividingBy: 4) / 4) * 360)   // one lap / 4 s
                        shape.strokeBorder(AngularGradient(stops: [
                            .init(color: peak.opacity(0.35), location: 0), .init(color: peak, location: 0.08),
                            .init(color: peak.opacity(0.35), location: 0.22), .init(color: peak.opacity(0.35), location: 1),
                        ], center: .center, angle: angle), lineWidth: w)
                    default:
                        let k = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.6))                   // 1.6 s breath
                        shape.strokeBorder(peak.opacity(k), lineWidth: w)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: animating)
    }
}

// MARK: - Generating (for the rim)

private struct LibrarianGeneratingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True while the Librarian is generating an answer (the pill rim's animation runs only then).
    var librarianGenerating: Bool {
        get { self[LibrarianGeneratingKey.self] }
        set { self[LibrarianGeneratingKey.self] = newValue }
    }
}
