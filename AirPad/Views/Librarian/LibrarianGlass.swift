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
/// Everything here is OFF in what ships (`LibrarianGlassLook.shipped`); only the TestFlight tuner turns it on.

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

enum PillRimAnimation: String, Codable, CaseIterable, Identifiable {
    case off, shimmer, pulse
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off:     return "Off"
        case .shimmer: return "Slow shimmer"
        case .pulse:   return "Pulse"
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

/// The pill's rim.
struct PillRim: Codable, Equatable {
    var on: Bool
    var width: Double          // 0.5…2 pt
    var brightness: Double     // 0…1
    var color: PillRimColor
    var animation: PillRimAnimation

    static let off = PillRim(on: false, width: 1, brightness: 0.8, color: .white, animation: .off)

    /// The rim moves only while an answer is generating, never under Reduce Motion. Pure.
    static func animates(_ r: PillRim, generating: Bool, reduceMotion: Bool) -> Bool {
        r.on && r.animation != .off && generating && !reduceMotion
    }
}

/// Everything live-24 adds to the Librarian's look, for one appearance.
struct LibrarianGlassLook: Equatable {
    var panelGlass: PanelGlass?      // nil = the frost (LibrarianSurfaceSpec)
    var panelGrade: GradedTint
    var pillGrade: GradedTint
    var pillVariant: GlassVariant
    var rim: PillRim

    /// What ships: the frost, nothing graded, no rim — the App Store build never changes.
    static let shipped = LibrarianGlassLook(panelGlass: nil, panelGrade: .off, pillGrade: .off, pillVariant: .regular, rim: .off)

    /// What renders: the tuner's values in DEBUG (with `-AppearanceTuner YES`) / TestFlight, else `shipped`.
    static func current(dark: Bool) -> LibrarianGlassLook {
        #if DEBUG || TESTFLIGHT
        if let v = AppearanceTuning.values(dark: dark) { return v.glassLook }
        #endif
        return .shipped
    }

    /// Text over the pill: a dense dark grade wants light text, a dense light one dark text; nil = the appearance's.
    static func pillScheme(_ g: GradedTint) -> ColorScheme? {
        guard g.on, g.alphaBehindText >= 0.5 else { return nil }
        return g.color.isDark ? .dark : .light
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

/// A pill face (the search pill / the Ask bar) on real Liquid Glass with the optional graded tint and rim. Used by
/// `PeekPillBackground` and the Ask bar when glass controls are on.
struct LibrarianPillGlass<S: InsettableShape>: View {
    let shape: S
    let look: LibrarianGlassLook
    var generating = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Reduce Transparency: a graded pill turns solid (its grade colour when dark, else the panel's). The plain
            // glass pill that ships keeps the system's own Reduce Transparency treatment.
            if reduceTransparency && look.pillGrade.on {
                shape.fill(Color(hexString: look.pillGrade.color.isDark ? look.pillGrade.color.hex
                                 : LibrarianGlassAccessibility.solidHex(dark: colorScheme == .dark)))
            } else {
                Color.clear.glassEffect(look.pillVariant.glass, in: shape)
                if look.pillGrade.on { GradedTintFill(shape: shape, grade: look.pillGrade) }
            }
        }
        .overlay {
            if look.rim.on { PillRimView(shape: shape, rim: look.rim,
                                         animating: PillRim.animates(look.rim, generating: generating, reduceMotion: reduceMotion)) }
        }
    }
}

/// The thin rim: static, or (only while generating) a slow light running around it / a gentle brightness pulse.
/// The animation stops cleanly — the view falls back to the static rim the frame generation ends.
struct PillRimView<S: InsettableShape>: View {
    let shape: S
    let rim: PillRim
    let animating: Bool

    var body: some View {
        let w = CGFloat(min(max(rim.width, 0.5), 2))
        let base = rim.color.color.opacity(min(max(rim.brightness, 0), 1))
        if animating {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                switch rim.animation {
                case .shimmer:
                    let angle = Angle.degrees((t.truncatingRemainder(dividingBy: 4) / 4) * 360)   // one lap / 4 s
                    shape.strokeBorder(AngularGradient(stops: [
                        .init(color: base.opacity(0.35), location: 0), .init(color: base, location: 0.08),
                        .init(color: base.opacity(0.35), location: 0.22), .init(color: base.opacity(0.35), location: 1),
                    ], center: .center, angle: angle), lineWidth: w)
                default:
                    let k = 0.65 + 0.35 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.6))                   // 1.6 s breath
                    shape.strokeBorder(base.opacity(k), lineWidth: w)
                }
            }
        } else {
            shape.strokeBorder(base, lineWidth: w)
        }
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
