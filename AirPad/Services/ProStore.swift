import Foundation
import StoreKit
import Observation

/// pro-build — the user's Map look: ONE pick, paired across the Maps as the looks always were (Glass ↔ Glass with each
/// Map's own values; Aura ↔ Wash; Riso, Gradient, Outline on both). 1.1-C (C7): Eclipse is dropped; a saved Eclipse pick
/// reads as Aura (and is rewritten as Aura). Flat is free; every other look needs Pro.
/// The pick survives a lost entitlement (a refund shows Flat, and the pick comes back with Pro). Fresh install = Flat.
/// Static + cached: the Map reads `effective` every frame.
enum MapLookChoice {
    static let storageKey = "mapLook.v1"
    /// The lineups each Map's picker shows. On the light Map, `.aura` is shown as "Wash" (Aura draws Wash there).
    static let darkLineup: [MapOrbLook] = [.flat, .glass, .aura, .riso, .gradient, .outline]
    static let lightLineup: [MapOrbLook] = [.flat, .glass, .aura, .riso, .gradient, .outline]
    /// The Pro sheet's list: every Pro look once (Wash = the light Map's half of Aura).
    static let proListNames = ["Glass", "Aura", "Wash", "Riso", "Gradient", "Outline"]

    /// Looks that don't ship read as the one that replaced them: Fresnel → Flat, Eclipse → Aura (1.1-C, C7).
    static func shipping(_ l: MapOrbLook) -> MapOrbLook {
        switch l { case .fresnel: .flat; case .eclipse: .aura; default: l }
    }
    private static var cached: MapOrbLook = {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? MapOrbLook.flat.rawValue
        let saved = MapOrbLook(rawValue: raw) ?? .flat
        let l = shipping(saved)
        if l != saved { UserDefaults.standard.set(l.rawValue, forKey: storageKey) }   // migrate the saved pick once
        return l
    }()
    /// What the user picked (kept even when Pro isn't active).
    static var picked: MapOrbLook {
        get { cached }
        set {
            let v = shipping(newValue)
            cached = v
            UserDefaults.standard.set(v.rawValue, forKey: storageKey)
        }
    }
    #if DEBUG
    /// The still / audit harnesses that set a look at launch (they also unlock Pro: see ProEntitlement).
    static let debugLookHookActive: Bool = ["-MapLookSet", "-MapLookCycle", "-MapOrbRender", "-MapOrbCycle", "-AuraSizeScript"]
        .contains { ProcessInfo.processInfo.arguments.contains($0) }
    #endif
    /// What the Map draws: the pick when it is free or Pro is unlocked, Flat otherwise.
    static var effective: MapOrbLook { picked == .flat || ProEntitlement.isPro ? picked : .flat }

    /// The picker's name for a look on a Map.
    static func name(_ l: MapOrbLook, light: Bool) -> String { light && l.drawsWashOnLight ? "Wash" : l.label }
    /// Is `l` the selected row on this Map's picker?
    static func isSelected(_ l: MapOrbLook, light: Bool, picked p: MapOrbLook) -> Bool {
        light && l == .aura ? p.drawsWashOnLight : l == p
    }
    /// The pick a row stands for ("Wash" on the light Map is Aura).
    static func pick(for l: MapOrbLook, light: Bool, current: MapOrbLook) -> MapOrbLook { l }
}

/// 1.1-A fix-up (2) — the Dashboard panes' surface. Everyone gets Glass (T's pick); the others come with AirPad Pro, the
/// same way as the Map looks (the pick is kept when Pro isn't active; what draws falls back to Glass).
enum DashboardSurfaceChoice: Int, CaseIterable, Identifiable {
    case thin = 0, glass = 1, clear = 2, panel = 3
    /// 1.1-A's single pick. 1.1-B fix-up (C): one pick per appearance (`storageKey(dark:)`); until an appearance has its
    /// own, it reads this one, so an existing pick carries over to both.
    static let storageKey = "dashboard.surface.v1"
    static func storageKey(dark: Bool) -> String { dark ? "dashboard.surface.dark.v1" : "dashboard.surface.light.v1" }
    /// The default for an appearance's pick: the 1.1-A pick if there is one, else Glass.
    static var legacyRaw: Int { UserDefaults.standard.object(forKey: storageKey) as? Int ?? free.rawValue }
    static let free: DashboardSurfaceChoice = .glass
    static let lineup: [DashboardSurfaceChoice] = [.glass, .thin, .clear, .panel]
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .thin: "Frosted"
        case .glass: "Glass"
        case .clear: "Clear glass"
        case .panel: "Solid"
        }
    }
    var isFree: Bool { self == Self.free }
    static func effective(pickedRaw: Int, isPro: Bool) -> DashboardSurfaceChoice {
        let p = DashboardSurfaceChoice(rawValue: pickedRaw) ?? free
        return p.isFree || isPro ? p : free
    }
}

/// 1.1-A fix-up (1) — the "Gravity" Appearance toggle (1.1-B: was "Gravity wells") (on by default): the Map's ground dips under the orbs you can
/// read. Off by itself in Low Power Mode and at thermal ≥ .serious (`MapHeatGuard.stressed`), back by itself when that
/// ends. Zoomed out the wells were already off (no title visible → every weight 0), so that is unchanged.
enum MapWells {
    static let storageKey = "map.gravityWells.v1"
    private static var cached: Bool = UserDefaults.standard.object(forKey: storageKey) == nil
        ? true : UserDefaults.standard.bool(forKey: storageKey)
    /// The user's setting.
    static var userOn: Bool {
        get { cached }
        set { cached = newValue; UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
    /// What the Map draws this frame.
    static var active: Bool { cached && !MapHeatGuard.shared.stressed }
}

/// 1.1-B — a Pro look's strength (T's Subtle / Medium / Strong, Ops/reference/orb-strengths-2026-10-29.json).
enum LookStrength: Int, CaseIterable, Identifiable {
    case subtle = 0, medium = 1, strong = 2
    var id: Int { rawValue }
    var label: String { switch self { case .subtle: "Subtle"; case .medium: "Medium"; case .strong: "Strong" } }
}

/// 1.1-B — the Strength picker beside Map look: one strength per Pro look (each look keeps its own), Medium by default.
/// Pro only: without Pro the Map is Flat, which has no strength.
enum MapLookStrength {
    static let storageKey = "mapLook.strength.v1"   // [look rawValue: LookStrength rawValue]
    /// The looks with T's strengths. Glass has none: the study's Glass is the light-Map Light Glass, not the shipping one.
    static func has(_ l: MapOrbLook) -> Bool { [.aura, .riso, .gradient, .outline].contains(l) }
    private static var cached: [String: Int] = (UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]).compactMapValues {
        ($0 as? NSNumber)?.intValue ?? ($0 as? String).flatMap { Int($0) }   // launch-argument values arrive as strings
    }
    static func picked(_ l: MapOrbLook) -> LookStrength { cached[l.rawValue].flatMap(LookStrength.init(rawValue:)) ?? .medium }
    static func set(_ s: LookStrength, for l: MapOrbLook) {
        cached[l.rawValue] = s.rawValue
        UserDefaults.standard.set(cached, forKey: storageKey)
    }
    /// What the Map draws for look `l`.
    static func effective(_ l: MapOrbLook) -> LookStrength { has(l) && ProEntitlement.isPro ? picked(l) : .medium }
}

/// 1.1-B — the background, editable with Pro per appearance (T's ground study, Ops/reference/ground-values-2026-10-29.json;
/// amended 2026-10-29: a custom background applies to every view in that appearance — the Map, cards, lists and the
/// Dashboard's backdrop; the dots stay the Map's): its colour, an optional two-stop gradient across the screen (colour 2 +
/// angle, as the study draws it) and the Map dots' colour + opacity. Until a Pro user customises an appearance
/// (`custom` false), every view keeps today's ground (the Map #111115 / #FFEEED, the library #1A1A1A / #F4F2ED).
struct MapGroundSide: Codable, Equatable {
    var custom = false      // false = today's per-view grounds (the values below are then only the editor's start)
    var color: String       // "RRGGBB"
    var gradient: Bool
    var color2: String
    var angle: Double       // degrees, 0 = toward the right edge, 90 = toward the top
    var dot: String
    var dotOpacity: Double

    static let darkDefault = MapGroundSide(color: "111115", gradient: false, color2: "1D1D26", angle: 90, dot: "FFFFFF", dotOpacity: 0.809)
    static let lightDefault = MapGroundSide(color: "FFEEED", gradient: false, color2: "FFF8EF", angle: 90, dot: "3B362F", dotOpacity: 0.805)

    init(custom: Bool = false, color: String, gradient: Bool, color2: String, angle: Double, dot: String, dotOpacity: Double) {
        self.custom = custom; self.color = color; self.gradient = gradient; self.color2 = color2; self.angle = angle
        self.dot = dot; self.dotOpacity = dotOpacity
    }

    static func rgb(_ hex: String) -> SIMD3<Float> {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return SIMD3(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255
    }
    var colorRGB: SIMD3<Float> { Self.rgb(color) }
    var color2RGB: SIMD3<Float> { Self.rgb(color2) }
    var dotRGB: SIMD3<Float> { Self.rgb(dot) }
    /// The gradient's direction (unit, y up), the study's (cos a, sin a).
    var direction: SIMD2<Float> { SIMD2(Float(cos(angle * .pi / 180)), Float(sin(angle * .pi / 180))) }
    /// The ground at a point of the screen (pt from the centre, y up) on a viewport `vp` — the study's `groundAt`, the
    /// shader's mix: t = clamp(0.5 + dot(offset, dir) / (|vp.x·dir.x| + |vp.y·dir.y|)).
    func ground(atOffset o: SIMD2<Float>, viewport vp: SIMD2<Float>) -> SIMD3<Float> {
        guard gradient else { return colorRGB }
        let d = direction, ext = max(abs(vp.x * d.x) + abs(vp.y * d.y), 1e-3)
        let t = min(max(0.5 + (o.x * d.x + o.y * d.y) / ext, 0), 1)
        return colorRGB + (color2RGB - colorRGB) * t
    }
    /// One colour for what can't follow the gradient per pixel (the orb shaders' "ground"): its middle.
    var meanRGB: SIMD3<Float> { gradient ? (colorRGB + color2RGB) * 0.5 : colorRGB }
}

enum MapGround {
    static let storageKey = "map.ground.v1"
    struct Stored: Codable, Equatable { var dark: MapGroundSide; var light: MapGroundSide }
    static let defaults = Stored(dark: .darkDefault, light: .lightDefault)

    private static var cached: Stored = {
        #if DEBUG || PANBENCH
        // `-MapGroundDebug <base64 of a Stored as JSON>` for stills (base64: a bare `{…}` argument is parsed as a plist).
        if let b = UserDefaults.standard.string(forKey: "MapGroundDebug"), let d = Data(base64Encoded: b),
           let s = try? JSONDecoder().decode(Stored.self, from: d) {
            let r = s.readable
            NSLog("[GROUND] debug ground: dark %@%@ → %@%@ · light %@%@ → %@%@", s.dark.color, s.dark.gradient ? "→" + s.dark.color2 : "",
                  r.dark.color, r.dark.gradient ? "→" + r.dark.color2 : "", s.light.color, s.light.gradient ? "→" + s.light.color2 : "",
                  r.light.color, r.light.gradient ? "→" + r.light.color2 : "")
            return r
        }
        #endif
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(Stored.self, from: d) else { return defaults }
        return s.readable
    }()
    /// The user's edit (kept even without Pro, like the Map look; drawn only with Pro).
    static var edited: Stored {
        get { cached }
        set {
            let v = newValue.readable   // a ground text can't read on is never stored (ReadableGround)
            cached = v
            if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: storageKey) }
            Observed.shared.version += 1
            NotificationCenter.default.post(name: .mapGroundChanged, object: nil)
        }
    }
    static func edited(light: Bool) -> MapGroundSide { light ? cached.light : cached.dark }
    /// Store an edit; returns what was stored (moved out of the unreadable band when it had to be: compare to `s`).
    @discardableResult static func setEdited(_ s: MapGroundSide, light: Bool) -> MapGroundSide {
        var v = cached
        if light { v.light = s } else { v.dark = s }
        edited = v
        return edited(light: light)
    }
    static var proActive: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProLocked") { return false }
        #endif
        return ProEntitlement.isPro
    }
    /// The custom background this appearance draws, or nil = today's per-view grounds exactly (no Pro, or not customised).
    static func override(light: Bool) -> MapGroundSide? {
        _ = Observed.shared.version   // SwiftUI bodies that draw the background re-render on an edit
        guard proActive else { return nil }
        #if DEBUG || PANBENCH
        if PanBench.noGround { return nil }
        #endif
        let e = edited(light: light)
        return e.custom ? e : nil
    }

    /// Observation hook: views reading `override` depend on this.
    @Observable final class Observed { static let shared = Observed(); var version = 0 }

    // MARK: text on the custom background

    /// The two inks text on the custom background chooses between: the light appearance's ink #232A2E and white.
    static let groundInks = TitleInkRule.Inks(light: SIMD3(1, 1, 1), dark: SIMD3(0x23, 0x2A, 0x2E) / 255)
    /// The background's colours across a view (a 7 × 5 grid over a 440 × 956 pt screen; one colour without a gradient).
    static func samples(_ g: MapGroundSide) -> [SIMD3<Float>] {
        guard g.gradient else { return [g.colorRGB] }
        let vp = SIMD2<Float>(440, 956)
        return TitleInkRule.box(halfWidth: vp.x / 2, halfHeight: vp.y / 2).map { g.ground(atOffset: $0, viewport: vp) }
    }
    /// THE rule for text on the custom background (the orb titles' p80 rule over the background's samples), cached per
    /// edit: nil = no custom background in that appearance (text keeps today's ink).
    static func inkPick(light: Bool, pane: Bool = false) -> TitleInkRule.Pick? {
        guard let g = override(light: light) else { return nil }
        let key = light ? (pane ? 3 : 1) : (pane ? 2 : 0)
        if let c = pickCache[key], c.0 == g { return c.1 }
        let s = samples(g).map { pane ? paneOver($0, light: light) : $0 }
        let p = TitleInkRule.pick(samples: s, inks: groundInks)
        pickCache[key] = (g, p)
        return p
    }
    private static var pickCache: [Int: (MapGroundSide, TitleInkRule.Pick)] = [:]
    /// A see-through Dashboard pane (Glass) over the background, as measured on the Simulator (#808080 → #C3–CB light,
    /// #777777 → #70–80 dark): Light lifts the ground 56% toward white; Dark leaves it about where it is.
    static func paneOver(_ c: SIMD3<Float>, light: Bool) -> SIMD3<Float> { light ? c + (SIMD3(repeating: 1) - c) * 0.56 : c }
    /// A text style's contrast on the custom background: `ink` at `opacity` over the background, at the 80th percentile.
    static func styleContrast(light: Bool, opacity: Float, pane: Bool = false) -> Float? {
        guard let g = override(light: light), let p = inkPick(light: light, pane: pane) else { return nil }
        return p80(samples(g).map { pane ? paneOver($0, light: light) : $0 }, ink: p.ink, opacity: opacity)
    }
    private static func p80(_ s: [SIMD3<Float>], ink: SIMD3<Float>, opacity: Float) -> Float {
        let shown = s.map { $0 + (ink - $0) * opacity }
        return zip(shown, s).map { TitleInkRule.contrast($0, $1) }.sorted()[max(0, s.count - Int((0.8 * Float(s.count)).rounded(.up)))]
    }
    /// 1.1-B (T: "floors on custom backgrounds") — the lowest opacity at which the picked ink reaches 4.5:1 (p80) on the
    /// custom background, so a fainter text style on it is raised to this floor (`groundInk`). Always ≤ 1: the limit
    /// (`ReadableGround`) keeps full-strength ink at 4.5:1. nil = no custom background in that appearance.
    static func inkFloor(light: Bool, pane: Bool = false) -> Double? {
        guard let g = override(light: light), let p = inkPick(light: light, pane: pane) else { return nil }
        let key = light ? (pane ? 3 : 1) : (pane ? 2 : 0)
        if let c = floorCache[key], c.0 == g { return c.1 }
        let s = samples(g).map { pane ? paneOver($0, light: light) : $0 }
        var lo: Float = 0, hi: Float = 1
        for _ in 0..<16 { let m = (lo + hi) / 2; if p80(s, ink: p.ink, opacity: m) >= TitleInkRule.minContrast { hi = m } else { lo = m } }
        let f = (Double(hi) * 100).rounded(.up) / 100
        floorCache[key] = (g, f)
        return f
    }
    private static var floorCache: [Int: (MapGroundSide, Double)] = [:]
}

/// 1.1-B — where this copy of AirPad came from, read at RUNTIME so one binary (archived in App Store config) can carry
/// TestFlight-only switches: StoreKit's `AppTransaction` environment is `.sandbox` on a TestFlight install, `.production`
/// from the App Store. Read once per launch off the main thread; cached for the next launch's synchronous read. Until it
/// resolves (first launch) the answer is "not TestFlight", so a TF-only switch can only appear late, never wrongly.
/// DEBUG builds count as TestFlight; DEBUG `-InstallChannel appstore|testflight` overrides.
enum InstallChannel {
    static let cacheKey = "install.isTestFlight.v1"
    private static var cached: Bool = {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "InstallChannel") {
        case "appstore": return false
        case "testflight": return true
        default: return true
        }
        #else
        return UserDefaults.standard.bool(forKey: cacheKey)
        #endif
    }()
    static var isTestFlight: Bool { cached }

    /// Call once at launch.
    static func resolve() {
        #if !DEBUG
        Task.detached(priority: .utility) {
            guard let r = try? await AppTransaction.shared, case .verified(let t) = r else { return }
            let tf = t.environment == .sandbox
            await MainActor.run {
                UserDefaults.standard.set(tf, forKey: cacheKey)
                guard tf != cached else { return }
                cached = tf
                NotificationCenter.default.post(name: .installChannelResolved, object: nil)
            }
        }
        #endif
    }
}

/// 1.1-B — the Map ground's SHEEN (T's ground study, variant "wellsSlope"): a soft light across the wells' slopes. T
/// decides on the 1.1-B TestFlight, so it is a TestFlight-only switch: shown and ON by default on TestFlight installs,
/// hidden and OFF from the App Store. It reads the wells' field, so it is off whenever the wells are (Gravity off, Low
/// Power, hot phone).
enum MapSheen {
    /// T's values (ground-values-2026-10-29.json). `reach` (1.38) only shapes the study's depth / static variants, which
    /// weren't ported, so it isn't here.
    static let amount: Float = 0.06, lightAngleDeg: Float = 253, lightHeightDeg: Float = 62
    static let softness: Float = 0.25, relief: Float = 1.58, colour: Float = 0.63, falloffNearWells: Float = 0.62
    /// The light direction, the study's (cos a · cos e, sin a · cos e, sin e).
    static var light: SIMD3<Float> {
        let a = lightAngleDeg * .pi / 180, e = lightHeightDeg * .pi / 180
        return SIMD3(cos(a) * cos(e), sin(a) * cos(e), sin(e))
    }
    /// 1.1-B fix-up (G) — Sheen ships, on for everyone, with no switch of its own: it draws whenever Gravity draws (so Low
    /// Power and the heat guard turn it off with the wells). DEBUG / bench builds: `-MapSheenOff YES` (and `debugOff`).
    #if DEBUG || PANBENCH
    static var debugOff = UserDefaults.standard.bool(forKey: "MapSheenOff")
    static var active: Bool { !debugOff && MapWells.active }
    #else
    static var active: Bool { MapWells.active }
    #endif
}

extension MapGround.Stored {
    var readable: Self { Self(dark: dark.readable, light: light.readable) }
}

/// 1.1-B (T 2026-10-29: "limit the colour picker away from mid tones") — a custom background must let full-strength text
/// reach 4.5:1 with one of the two inks (white / #232A2E) at every point, so a ground's WCAG relative luminance may not
/// sit in the band where neither does:
///   white reaches 4.5:1 ⇔ L ≤ 1.05 / 4.5 − 0.05 = 0.18333;  #232A2E (L 0.022105) ⇔ L ≥ 4.5 · 0.072105 − 0.05 = 0.27447.
/// A colour inside (0.18333, 0.27447) moves to the nearer side in OKLab lightness, hue kept and chroma kept as far as
/// the sRGB gamut allows; a gradient's two stops sit on the same side (else colour 2 moves to colour 1's side), and
/// every point between them is checked. Applied where an edit is stored and where one is loaded, so an unreadable
/// ground can't exist.
enum ReadableGround {
    static let darkMax = 1.05 / 4.5 - 0.05                       // 0.18333: white text ≥ 4.5:1 at or below
    static let lightMin = 4.5 * (lum(SIMD3(0x23, 0x2A, 0x2E) / 255) + 0.05) - 0.05   // 0.27447: #232A2E ≥ 4.5:1 at or above

    static func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func enc(_ v: Double) -> Double { let x = min(max(v, 0), 1); return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    static func lum(_ c: SIMD3<Float>) -> Double { 0.2126 * lin(Double(c.x)) + 0.7152 * lin(Double(c.y)) + 0.0722 * lin(Double(c.z)) }
    static func inBand(_ c: SIMD3<Float>) -> Bool { let l = lum(c); return l > darkMax && l < lightMin }
    /// Which side of the band a colour is on (true = light: dark ink); in-band colours by their nearer bound.
    static func lightSide(_ c: SIMD3<Float>) -> Bool { lum(c) >= (darkMax + lightMin) / 2 }

    // OKLab ↔ sRGB (encoded 0…1)
    static func oklab(_ c: SIMD3<Float>) -> (Double, Double, Double) {
        let r = lin(Double(c.x)), g = lin(Double(c.y)), b = lin(Double(c.z))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
    /// OKLCH → sRGB, chroma stepped down until in gamut.
    static func srgb(L: Double, C c0: Double, h: Double) -> SIMD3<Float> {
        var c = c0
        while true {
            let a = c * cos(h), b = c * sin(h)
            let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3), m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
            let rgb = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                       -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
            if c <= 0 || rgb.allSatisfy({ $0 >= -0.0005 && $0 <= 1.0005 }) {
                return SIMD3(Float(enc(rgb[0])), Float(enc(rgb[1])), Float(enc(rgb[2])))
            }
            c = max(0, c - 0.004)
        }
    }
    static func hex(_ c: SIMD3<Float>) -> String {
        String(format: "%02X%02X%02X", Int((min(max(c.x, 0), 1) * 255).rounded()), Int((min(max(c.y, 0), 1) * 255).rounded()),
               Int((min(max(c.z, 0), 1) * 255).rounded()))
    }
    /// The colour moved onto one side of the band (`light` nil = the nearer side in OKLab lightness), `margin` past the bound.
    static func moved(_ hexIn: String, toLight forced: Bool? = nil, margin: Double = 0.002) -> String {
        let c = MapGroundSide.rgb(hexIn)
        if let f = forced { if f ? lum(c) >= lightMin + margin : lum(c) <= darkMax - margin { return hexIn } } else if !inBand(c) { return hexIn }
        let (L0, a, b) = oklab(c), C = (a * a + b * b).squareRoot(), h = atan2(b, a)
        func solve(light: Bool) -> (Double, String) {
            let target = light ? lightMin + margin : darkMax - margin
            var lo = light ? L0 : 0.0, hi = light ? 1.0 : L0
            for _ in 0..<48 {
                let mid = (lo + hi) / 2, l = lum(srgb(L: mid, C: C, h: h))
                if light { if l < target { lo = mid } else { hi = mid } } else { if l > target { hi = mid } else { lo = mid } }
            }
            let L = light ? hi : lo
            var out = hex(srgb(L: L, C: C, h: h))
            let q = MapGroundSide.rgb(out)
            if light ? lum(q) < lightMin : lum(q) > darkMax { out = moved(out, toLight: light, margin: margin * 2) }   // 8-bit rounding
            return (abs(L - L0), out)
        }
        if let f = forced { return solve(light: f).1 }
        let d = solve(light: false), l = solve(light: true)
        return d.0 <= l.0 ? d.1 : l.1
    }
    /// Every point of a gradient (the shader's mix of the encoded stops) readable?
    static func gradientReadable(_ c1: SIMD3<Float>, _ c2: SIMD3<Float>) -> Bool {
        (0...32).allSatisfy { i in let t = Float(i) / 32; return !inBand(c1 + (c2 - c1) * t) }
    }
}

extension MapGroundSide {
    /// This side with its colour (and a gradient's colour 2) out of the unreadable band (`ReadableGround`).
    var readable: MapGroundSide {
        var s = self
        s.color = ReadableGround.moved(color)
        guard gradient else { return s }
        let side = ReadableGround.lightSide(MapGroundSide.rgb(s.color))
        s.color2 = ReadableGround.moved(color2, toLight: side)
        var margin = 0.004
        while !ReadableGround.gradientReadable(s.colorRGB, s.color2RGB), margin < 0.2 {   // a dip between the stops
            s.color2 = ReadableGround.moved(s.color2, toLight: side, margin: margin)
            margin *= 2
        }
        if !ReadableGround.gradientReadable(s.colorRGB, s.color2RGB) { s.color2 = s.color }
        return s
    }
}

extension Notification.Name {
    static let mapGroundChanged = Notification.Name("MapGroundChanged")
    static let installChannelResolved = Notification.Name("InstallChannelResolved")
}

/// pro-build — the Pro entitlement as the app last verified it, cached so the Map never flashes Flat → Pro at launch.
/// Written ONLY by `ProStore` from `Transaction.currentEntitlements` / `Transaction.updates` (local, verified by StoreKit).
enum ProEntitlement {
    static let storageKey = "pro.unlocked.v1"
    private static var cached: Bool = {
        #if DEBUG || PANBENCH
        if UserDefaults.standard.bool(forKey: "ProUnlocked") { return true }   // `-ProUnlocked YES`
        #endif
        #if DEBUG
        if MapLookChoice.debugLookHookActive { return true }   // still hooks
        #endif
        return UserDefaults.standard.bool(forKey: storageKey)
    }()
    static var isPro: Bool { cached }
    static func set(_ v: Bool) {
        #if DEBUG || PANBENCH
        if UserDefaults.standard.bool(forKey: "ProUnlocked") { return }
        #endif
        #if DEBUG
        if MapLookChoice.debugLookHookActive { return }
        #endif
        guard v != cached else { return }
        cached = v
        UserDefaults.standard.set(v, forKey: storageKey)
        NotificationCenter.default.post(name: .proEntitlementChanged, object: nil)
    }
}

extension Notification.Name {
    static let proEntitlementChanged = Notification.Name("ProEntitlementChanged")
}

/// pro-build — StoreKit 2, no server: products, purchase, restore, the entitlement and the tip jar.
@MainActor @Observable
final class ProStore {
    static let shared = ProStore()

    static let proID = "com.doctorpresident.airpad.pro"
    static let tipIDs = ["com.doctorpresident.airpad.tip.small", "com.doctorpresident.airpad.tip.medium",
                         "com.doctorpresident.airpad.tip.large"]
    static var allIDs: [String] { [proID] + tipIDs }

    enum LoadState: Equatable { case idle, loading, loaded, failed }
    enum Outcome: Equatable { case purchased, pending, cancelled, failed(String) }

    private(set) var products: [String: Product] = [:]
    private(set) var loadState: LoadState = .idle
    private(set) var isPro: Bool = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProLocked") { return false }
        #endif
        return ProEntitlement.isPro
    }()
    /// A purchase in flight (its product id), for the buttons' spinners.
    private(set) var busyID: String?
    /// Ask to Buy: Pro was requested and waits for approval.
    private(set) var proPending = false

    private var updatesTask: Task<Void, Never>?

    private init() {}

    /// At launch: listen for transactions (Ask to Buy approvals, refunds, purchases made elsewhere), finish what a crash
    /// left unfinished, and re-verify the entitlement.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates { await self?.handle(result) }
        }
        Task {
            for await result in Transaction.unfinished { await handle(result) }
            await refreshEntitlement()
        }
    }

    /// The entitlement from `Transaction.currentEntitlements` (verified, not revoked). A revoked / refunded Pro → false.
    func refreshEntitlement() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.proID, t.revocationDate == nil { pro = true }
        }
        setPro(pro)
    }

    private func setPro(_ v: Bool) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProLocked") { isPro = false; return }   // `-ProLocked YES`: the locked rows' stills
        if UserDefaults.standard.bool(forKey: "ProUnlocked") || MapLookChoice.debugLookHookActive { isPro = true; return }   // 1.1-B: Pro stills
        #endif
        isPro = v
        if v { proPending = false }
        ProEntitlement.set(v)
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let t) = result else { return }   // unverified: ignore (never unlocks)
        if t.productID == Self.proID { await refreshEntitlement() }
        await t.finish()
    }

    /// Prices come from the App Store (`displayPrice`), never from the app.
    func loadProducts() async {
        if loadState == .loading { return }
        loadState = .loading
        do {
            let list = try await Product.products(for: Self.allIDs)
            products = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            loadState = products[Self.proID] == nil ? .failed : .loaded
            #if DEBUG || TESTFLIGHT
            NSLog("[ProStore] products=%d %@", list.count, loadState == .loaded ? "loaded" : "failed (no Pro product)")
            #endif
        } catch {
            loadState = .failed
            #if DEBUG || TESTFLIGHT
            NSLog("[ProStore] products failed: %@", String(describing: error))
            #endif
        }
    }

    func price(_ id: String) -> String? { products[id]?.displayPrice }

    func buy(_ id: String) async -> Outcome {
        guard let product = products[id] else { return .failed("Couldn't reach the App Store. Try again.") }
        busyID = id
        defer { busyID = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let t) = verification else { return .failed("The App Store couldn't verify this purchase.") }
                if t.productID == Self.proID { await refreshEntitlement() }
                await t.finish()
                return .purchased
            case .pending:
                if id == Self.proID { proPending = true }
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .cancelled
            }
        } catch {
            return .failed("Couldn't reach the App Store. Try again.")
        }
    }

    /// Restore Purchases: sync with the App Store, then re-read the entitlement.
    func restore() async -> Bool {
        busyID = "restore"
        defer { busyID = nil }
        do { try await AppStore.sync() } catch { await refreshEntitlement(); return false }
        await refreshEntitlement()
        return true
    }
}
