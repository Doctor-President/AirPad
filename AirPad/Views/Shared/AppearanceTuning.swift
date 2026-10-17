import SwiftUI
import UIKit

/// live-22 (2) — ★ the on-device, live appearance tuner (TestFlight only). T judges the Librarian surface and the
/// light palette on his phone, in the real views, instead of from Simulator stills. A floating handle sits over every
/// view (`AppearanceTunerOverlay`); its sheet varies the Librarian surface (presets + tint / blur / saturation / dim)
/// and the cards + field (shadow, hairline, field brightness, palette L1/L2/L3), live, per appearance.
///
/// ⚠ GATE — exactly the speech-engine switch's (`SpeechEngineTesting`): STRUCTURAL, at compile time. Everything but
/// `isOffered` is inside `#if DEBUG || TESTFLIGHT`; `scripts/testflight_upload.sh` sets TESTFLIGHT unless
/// `AIRPAD_APP_STORE_BUILD=1`, so an App Store archive has no handle, no sheet, no stored-value read, and every
/// surface renders its baked value. Values persist in UserDefaults on this device only (never the library, never
/// iCloud). `-AppearanceTuningSelfTest` proves the gate's logic and that the tuner at its defaults renders exactly
/// what ships (live-22 (1): T's picks).
enum AppearanceTuning {
    /// Compile-time: DEBUG or a TestFlight archive.
    static let isOffered: Bool = {
        #if DEBUG || TESTFLIGHT
        return true
        #else
        return false
        #endif
    }()
}

#if DEBUG || TESTFLIGHT

// MARK: - Values

/// The Librarian surface presets (live-22 directive (2)).
enum LibrarianPanelPreset: String, Codable, CaseIterable, Identifiable {
    case today, frost35, frost50, frost65, frost50Glass, liquidGlass, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today:        return "Before"   // live-23: the pre-live-23 panel (Cucumber Water / Solar Flare)
        case .frost35:      return "Frost 35%"
        case .frost50:      return "Frost 50%"
        case .frost65:      return "Frost 65%"
        case .frost50Glass: return "Frost 50% + glass"
        case .liquidGlass:  return "Liquid Glass"
        case .custom:       return "Custom"
        }
    }
    /// The presets the sheet offers (Custom is what a slider edit becomes).
    static let offered: [LibrarianPanelPreset] = [.today, .frost35, .frost50, .frost65, .frost50Glass, .liquidGlass]
}

/// One appearance's tuner values. Light and dark each have their own; the tuner edits the one on screen.
struct AppearanceTuningValues: Codable, Equatable {
    // Cards / field
    var palette: String          // "L1" | "L2" | "L3" — light only (dark has one palette)
    var fieldStep: Double        // -1 = F4 (one darker) · 0 = F1 · 1 = F2 · 2 = F3; fractional steps interpolate
    var shadowStrength: Double   // 0…1 × today's shadow (light: alpha 0.262 — live-21's S1; dark: 0.742)
    var shadowRadius: Double
    var hairline: Bool           // off = the edge before live-22 (light: the white top rim)
    var hairlineWidth: Double    // pt, 0…1
    var hairlineOpacity: Double
    // Librarian surface
    var panel: LibrarianPanelPreset
    var tintOpacity: Double      // the warm-neutral tint over the frost
    var blur: Double             // passes of the system material's blur: 0 none · 1 today · 2, 3 heavier (no public radius)
    var saturation: Double       // 1 = the backdrop as it is · 0 = grey
    var glassControls: Bool      // the search pill + Ask bar as real Liquid Glass
    var dimBehind: Bool
    var dimAmount: Double        // 0…0.20 black over the content behind, scaled by how far the panel is up
    // Hero photo fade (live-23 (3)) — carousel + grid cards
    var fadeLength: Double = CardHeroFade.baked.length   // fraction of the hero zone the photo fades over
    var fadeCurve: Double = CardHeroFade.baked.curve     // 0 linear · 1 smoothstep · 2 smootherstep

    var heroFade: CardHeroFade.Shape {
        CardHeroFade.Shape(length: fadeLength, curve: fadeCurve, overshoot: CardHeroFade.baked.overshoot)
    }

    /// ★ live-23 (1) — T's on-device tuning (2026-10-16, Ops `reference/appearance-tuning-2026-10-16.md`), = what
    /// ships: L2 · F2, the shadow at 50% with radius 24, the hairline 0.5 pt @ 0.25; the Librarian a near-solid frost
    /// (tint 0.85, blur 1.74, full colour) with glass controls, the content behind dimmed 10%.
    static let lightDefault = AppearanceTuningValues(
        palette: "L2", fieldStep: 1, shadowStrength: 0.5, shadowRadius: 24,
        hairline: true, hairlineWidth: 0.5, hairlineOpacity: 0.25,
        panel: .custom, tintOpacity: 0.85, blur: 1.74, saturation: 1, glassControls: true,
        dimBehind: true, dimAmount: 0.10)

    /// ★ live-23 (1) — dark: the field half a step lighter (#1A1A1A), the shadow and top rim as before; the Librarian a
    /// real frost (tint 0.56, blur 2, colour at 40%) with glass controls, the content behind dimmed 20%.
    static let darkDefault = AppearanceTuningValues(
        palette: "L2", fieldStep: 0.5, shadowStrength: 1, shadowRadius: 12,
        hairline: false, hairlineWidth: 0.5, hairlineOpacity: 0.12,
        panel: .custom, tintOpacity: 0.56, blur: 2, saturation: 0.4, glassControls: true,
        dimBehind: true, dimAmount: 0.20)

    /// The Librarian surface these values render (live-23).
    var librarianSpec: LibrarianSurfaceSpec {
        LibrarianSurfaceSpec(tint: tintOpacity, blur: blur, saturation: saturation, glassControls: glassControls,
                             dim: dimBehind ? min(max(dimAmount, 0), 0.20) : 0, wholePanelGlass: panel == .liquidGlass)
    }

    /// Set the Librarian sliders to a preset. Dim is left as it is (it's its own toggle).
    mutating func apply(_ preset: LibrarianPanelPreset) {
        panel = preset
        switch preset {
        case .today:        tintOpacity = 0.35; blur = 1; saturation = 1;   glassControls = false
        case .frost35:      tintOpacity = 0.35; blur = 2; saturation = 0.4; glassControls = false   // heavy blur = 2 passes
        case .frost50:      tintOpacity = 0.50; blur = 2; saturation = 0.4; glassControls = false
        case .frost65:      tintOpacity = 0.65; blur = 2; saturation = 0.4; glassControls = false
        case .frost50Glass: tintOpacity = 0.50; blur = 2; saturation = 0.4; glassControls = true
        case .liquidGlass:  glassControls = true
        case .custom:       break
        }
    }
}

extension AppearanceTuningValues {
    /// Keys added after a build T tuned on (live-23: the fade) decode to their defaults, so his stored values survive.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        palette = try c.decode(String.self, forKey: .palette)
        fieldStep = try c.decode(Double.self, forKey: .fieldStep)
        shadowStrength = try c.decode(Double.self, forKey: .shadowStrength)
        shadowRadius = try c.decode(Double.self, forKey: .shadowRadius)
        hairline = try c.decode(Bool.self, forKey: .hairline)
        hairlineWidth = try c.decode(Double.self, forKey: .hairlineWidth)
        hairlineOpacity = try c.decode(Double.self, forKey: .hairlineOpacity)
        panel = try c.decode(LibrarianPanelPreset.self, forKey: .panel)
        tintOpacity = try c.decode(Double.self, forKey: .tintOpacity)
        blur = try c.decode(Double.self, forKey: .blur)
        saturation = try c.decode(Double.self, forKey: .saturation)
        glassControls = try c.decode(Bool.self, forKey: .glassControls)
        dimBehind = try c.decode(Bool.self, forKey: .dimBehind)
        dimAmount = try c.decode(Double.self, forKey: .dimAmount)
        fadeLength = try c.decodeIfPresent(Double.self, forKey: .fadeLength) ?? CardHeroFade.baked.length
        fadeCurve = try c.decodeIfPresent(Double.self, forKey: .fadeCurve) ?? CardHeroFade.baked.curve
    }
}

/// Which card content the faces render (live-23 (4)): today's, or the proposal T compares it with.
enum CardContentMode: String, Codable, CaseIterable, Identifiable {
    case today, proposal
    var id: String { rawValue }
    var label: String { self == .today ? "Today" : "Proposal" }
}

/// Which capture controls render (live-23 (5c)): today's solid pills, or Liquid Glass.
enum CaptureControlsMode: String, Codable, CaseIterable, Identifiable {
    case today, glass
    var id: String { rawValue }
    var label: String { self == .today ? "Today" : "Glass" }
}

struct AppearanceTuningState: Codable, Equatable {
    var light: AppearanceTuningValues
    var dark: AppearanceTuningValues
    var cardContent: CardContentMode = .today
    var captureControls: CaptureControlsMode = .today
    static let defaults = AppearanceTuningState(light: .lightDefault, dark: .darkDefault)

    init(light: AppearanceTuningValues, dark: AppearanceTuningValues, cardContent: CardContentMode = .today,
         captureControls: CaptureControlsMode = .today) {
        self.light = light; self.dark = dark; self.cardContent = cardContent; self.captureControls = captureControls
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        light = try c.decode(AppearanceTuningValues.self, forKey: .light)
        dark = try c.decode(AppearanceTuningValues.self, forKey: .dark)
        cardContent = try c.decodeIfPresent(CardContentMode.self, forKey: .cardContent) ?? .today
        captureControls = try c.decodeIfPresent(CaptureControlsMode.self, forKey: .captureControls) ?? .today
    }
}

// MARK: - The live store

/// The tuner's state. `@Observable`, so every surface that reads a value in its `body` re-renders when T moves a
/// control — live, no reload.
@Observable
final class AppearanceTuner {
    static let shared = AppearanceTuner()

    var state: AppearanceTuningState {
        didSet {
            guard state != oldValue, let data = try? JSONEncoder().encode(state) else { return }
            UserDefaults.standard.set(data, forKey: AppearanceTuning.storageKey)
        }
    }
    /// Long-press on the handle: hidden until the next launch (in memory only).
    var hiddenUntilRelaunch = false

    private init() {
        state = AppearanceTuning.effective(stored: UserDefaults.standard.data(forKey: AppearanceTuning.storageKey),
                                           offered: AppearanceTuning.isLive)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "AppearanceTunerReset") { state = .defaults }   // UI tests start from (1)
        #endif
    }

    func values(dark: Bool) -> AppearanceTuningValues { dark ? state.dark : state.light }
    func update(dark: Bool, _ change: (inout AppearanceTuningValues) -> Void) {
        if dark { change(&state.dark) } else { change(&state.light) }
    }
    func reset() { state = .defaults }
}

// MARK: - Gate + resolvers

extension AppearanceTuning {
    static let storageKey = "appearanceTuning.v1"

    /// A TestFlight build: always live. DEBUG: only with `-AppearanceTuner YES`, so Simulator runs (self-tests,
    /// stills, UI tests) render exactly what ships and can't be contaminated by values left from a tuning session.
    static let isLive: Bool = {
        #if TESTFLIGHT
        return true
        #else
        return UserDefaults.standard.bool(forKey: "AppearanceTuner")
        #endif
    }()

    /// The state a launch starts from: stored values only when the tuner is offered; anything unreadable → defaults.
    static func effective(stored: Data?, offered: Bool) -> AppearanceTuningState {
        guard offered, let stored, let s = try? JSONDecoder().decode(AppearanceTuningState.self, from: stored) else {
            return .defaults
        }
        return s
    }

    private static var tuner: AppearanceTuner { AppearanceTuner.shared }

    /// The tuner's values for an appearance, or nil when it isn't live (callers then use the baked value).
    static func values(dark: Bool) -> AppearanceTuningValues? {
        isLive ? tuner.values(dark: dark) : nil
    }

    // Palettes

    static let palettes: [LightPalette] = [.l1, .l2, .l3]
    static func palette(named name: String) -> LightPalette {
        palettes.first { $0.name == name } ?? .shipped
    }
    static var lightPalette: LightPalette {
        guard let v = values(dark: false) else { return .shipped }
        return palette(named: v.palette)
    }

    /// The field hex at a (fractional) F-step. Light: the palette's F4 · F1 · F2 · F3 at -1 · 0 · 1 · 2.
    /// Dark has no palettes; its steps are ±7 per channel around today's #161616.
    static func fieldHex(_ v: AppearanceTuningValues, dark: Bool) -> String {
        let anchors: [String]
        if dark {
            anchors = ["0F0F0F", "161616", "1D1D1D", "242424"]
        } else {
            let p = palette(named: v.palette)
            anchors = [p.fieldSteps[2], p.field, p.fieldSteps[0], p.fieldSteps[1]]
        }
        let s = min(max(v.fieldStep, -1), 2) + 1          // 0…3 over the anchors
        let i = min(Int(s.rounded(.down)), 2)
        let t = s - Double(i)
        let a = rgb255(anchors[i]), b = rgb255(anchors[i + 1])
        func mix(_ x: Double, _ y: Double) -> Int { Int((x + (y - x) * t).rounded()) }
        return String(format: "%02X%02X%02X", mix(a.0, b.0), mix(a.1, b.1), mix(a.2, b.2))
    }

    /// "F2" at a whole step, "F1.5" between (T's render vocabulary).
    static func fieldLabel(_ step: Double) -> String {
        let names: [Double: String] = [-1: "F4", 0: "F1", 1: "F2", 2: "F3"]
        let r = (step * 20).rounded() / 20
        if let n = names[r] { return n }
        return String(format: "F%+.2f", r)
    }

    private static func rgb255(_ hex: String) -> (Double, Double, Double) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    // Card surface — LIGHT (`CardSurfaceStore.read` routes here)

    static func light(_ d: CardSurfaceDial, baked: Double) -> Double {
        guard let v = values(dark: false) else { return baked }
        return resolve(d, v, baked: baked)
    }
    static func light(_ h: CardSurfaceHex, baked: String) -> String {
        guard let v = values(dark: false) else { return baked }
        return resolve(h, v, baked: baked)
    }
    static func light(_ f: CardSurfaceFlag, baked: Bool) -> Bool {
        guard let v = values(dark: false) else { return baked }
        return resolve(f, v, baked: baked)
    }

    /// Pure: what a light dial reads for a set of tuner values.
    static func resolve(_ d: CardSurfaceDial, _ v: AppearanceTuningValues, baked: Double) -> Double {
        switch d {
        case .baseLightness: return palette(named: v.palette).cardLightness
        case .shadowAlpha:   return CardSurfaceDefaults.referenceShadowAlpha * v.shadowStrength
        case .shadowRadius:  return v.shadowRadius
        case .rimOpacity:    return v.hairline ? v.hairlineOpacity : CardSurfaceDefaults.priorRimOpacity
        case .rimWidth:      return v.hairline ? v.hairlineWidth : CardSurfaceDefaults.priorRimWidth
        default:             return baked
        }
    }
    static func resolve(_ h: CardSurfaceHex, _ v: AppearanceTuningValues, baked: String) -> String {
        switch h {
        case .groundHex: return fieldHex(v, dark: false)
        case .shadowHex: return palette(named: v.palette).shadow
        case .rimHex:    return v.hairline ? CardSurfaceDefaults.hairlineHex : CardSurfaceDefaults.priorRimHex
        default:         return baked
        }
    }
    static func resolve(_ f: CardSurfaceFlag, _ v: AppearanceTuningValues, baked: Bool) -> Bool {
        f == .rimTopOnly ? !v.hairline : baked
    }

    // Card surface — DARK (the dark resolvers' shipped literals, scaled by the tuner)

    static let darkShadowAlpha: Double = 0.742
    static func darkShadowAlpha(baked: Double) -> Double {
        guard let v = values(dark: true) else { return baked }
        return darkShadowAlpha * v.shadowStrength
    }
    static func darkShadowRadius(baked: CGFloat) -> CGFloat {
        guard let v = values(dark: true) else { return baked }
        return CGFloat(v.shadowRadius)
    }
    static func darkGroundHex(baked: String) -> String {
        guard let v = values(dark: true) else { return baked }
        return fieldHex(v, dark: true)
    }
    /// A dark hairline (white, all edges) when T turns it on; nil = today's dark top rim.
    static var darkHairline: (opacity: Double, width: Double)? {
        guard let v = values(dark: true), v.hairline else { return nil }
        return (v.hairlineOpacity, v.hairlineWidth)
    }

    // Librarian: `LibrarianSurfaceSpec.current(dark:)` / `.glassControls(dark:)` / `.dimAmount(dark:)` read the tuner.

    // MARK: Copy values

    /// The compact JSON T pastes to Companion: both appearances, plus the derived numbers (field hex, shadow alpha).
    static func exportJSON(_ s: AppearanceTuningState, editing mode: String, build: String) -> String {
        func num(_ x: Double) -> String {
            var t = String(format: "%.3f", x)
            while t.contains(".") && (t.hasSuffix("0") || t.hasSuffix(".")) { t.removeLast() }
            return t == "-0" ? "0" : t
        }
        func block(_ v: AppearanceTuningValues, dark: Bool) -> String {
            let reference = dark ? darkShadowAlpha : CardSurfaceDefaults.referenceShadowAlpha
            var parts: [String] = []
            if !dark { parts.append("\"palette\":\"\(v.palette)\"") }
            parts += [
                "\"field\":\"\(fieldLabel(v.fieldStep))\"", "\"fieldStep\":\(num(v.fieldStep))",
                "\"fieldHex\":\"#\(fieldHex(v, dark: dark))\"",
                "\"shadow\":\(num(v.shadowStrength))", "\"shadowAlpha\":\(num(reference * v.shadowStrength))",
                "\"shadowRadius\":\(num(v.shadowRadius))",
                "\"hairline\":\(v.hairline)", "\"hairlineWidth\":\(num(v.hairlineWidth))",
                "\"hairlineOpacity\":\(num(v.hairlineOpacity))",
                "\"panel\":\"\(v.panel.rawValue)\"", "\"tint\":\(num(v.tintOpacity))", "\"blur\":\(num(v.blur))",
                "\"saturation\":\(num(v.saturation))", "\"glassControls\":\(v.glassControls)",
                "\"dim\":\(v.dimBehind ? num(v.dimAmount) : "0")",
                "\"fadeLength\":\(num(v.fadeLength))", "\"fadeCurve\":\(num(v.fadeCurve))",
            ]
            return "{" + parts.joined(separator: ",") + "}"
        }
        return "{\"airpadAppearance\":1,\"build\":\"\(build)\",\"editing\":\"\(mode)\",\"cardContent\":\"\(s.cardContent.rawValue)\",\"captureControls\":\"\(s.captureControls.rawValue)\","
            + "\"light\":\(block(s.light, dark: false)),\"dark\":\(block(s.dark, dark: true))}"
    }
}

// MARK: - Self-test

extension AppearanceTuning {
    /// `-AppearanceTuningSelfTest` — live-22 (1) T's picks are what ships; (2) the gate, the stored-value guard, the
    /// presets and the export. Pure.
    static func selfTest() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok || detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0005 }
        func hex(_ c: Color, dark: Bool) -> String {
            let ui = UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }

        // live-23 (1) — T's on-device tuning (2026-10-16, Ops reference/appearance-tuning-2026-10-16.md) is what ships.
        let D = CardSurfaceDefaults.self
        row("baked-palette-is-L2", LightPalette.shipped == .l2, "shipped=\(LightPalette.shipped.name)")
        row("baked-field-is-L2-F2", D.hex(.groundHex) == "F4F2ED", "ground=\(D.hex(.groundHex))")
        row("baked-card-face-FBF9F5", CardSurfaceResolved.resolvedCardBackgroundHex == "#FBF9F5",
            "card=\(CardSurfaceResolved.resolvedCardBackgroundHex)")
        row("baked-shadow-half-of-0.262 (0.131)", close(D.value(.shadowAlpha), 0.131), "alpha=\(D.value(.shadowAlpha))")
        row("baked-shadow-radius-24-y-11", D.value(.shadowRadius) == 24 && D.value(.shadowY) == 11,
            "radius=\(D.value(.shadowRadius)) y=\(D.value(.shadowY))")
        row("baked-shadow-hex-L2", D.hex(.shadowHex) == "3F3A33", "shadowHex=\(D.hex(.shadowHex))")
        row("baked-hairline-0.5pt-black-0.25-all-edges",
            D.hex(.rimHex) == "000000" && close(D.value(.rimOpacity), 0.25) && D.value(.rimWidth) == 0.5 && !D.flag(.rimTopOnly),
            "rim=\(D.hex(.rimHex))@\(D.value(.rimOpacity)) w\(D.value(.rimWidth)) topOnly=\(D.flag(.rimTopOnly))")
        row("baked-detail-ground-EFECE6", hex(AppearancePalette.bgBase, dark: false) == "EFECE6",
            "bgBase=\(hex(AppearancePalette.bgBase, dark: false))")
        row("baked-raised-FBF9F5", hex(AppearancePalette.bgElevated, dark: false) == "FBF9F5",
            "bgElevated=\(hex(AppearancePalette.bgElevated, dark: false))")
        row("baked-panel-tint-FBF9F5-stroke-DCD6CC",
            LightPalette.shipped.panelTint == "FBF9F5" && LightPalette.shipped.panelStroke == "DCD6CC")
        row("baked-dots-L2-hue-same-opacity",
            LightPalette.shipped.dot == "3B362F" && AppearancePalette.libraryGridDotOpacity(dark: false) == 0.523)
        row("baked-dark-field-1A1A1A (F+0.50)", hex(CardSurfaceResolved.ground(dark: true), dark: true) == "1A1A1A",
            "dark ground=\(hex(CardSurfaceResolved.ground(dark: true), dark: true))")
        row("dark-shadow-and-rim-unchanged", CardSurfaceResolved.shadowRadius(dark: true) == 12
            && CardSurfaceResolved.rimWidth(dark: true) == 1.5 && CardSurfaceResolved.rimIsTopOnly(dark: true)
            && hex(AppearancePalette.bgBase, dark: true) == "000000")
        let bl = LibrarianSurfaceSpec.baked(dark: false), bd = LibrarianSurfaceSpec.baked(dark: true)
        row("baked-librarian-light-tint-0.85-blur-1.74-sat-1-glass-dim-0.10",
            close(bl.tint, 0.85) && close(bl.blur, 1.74) && close(bl.saturation, 1) && bl.glassControls && close(bl.dim, 0.10)
            && !bl.wholePanelGlass, "\(bl)")
        row("baked-librarian-dark-tint-0.56-blur-2-sat-0.4-glass-dim-0.20",
            close(bd.tint, 0.56) && close(bd.blur, 2) && close(bd.saturation, 0.4) && bd.glassControls && close(bd.dim, 0.20)
            && !bd.wholePanelGlass, "\(bd)")

        // The tuner at its defaults renders exactly what ships ("Reset to defaults" = T's values).
        let L = AppearanceTuningValues.lightDefault
        let dialsMatch = CardSurfaceDial.allCases.allSatisfy { close(resolve($0, L, baked: D.value($0)), D.value($0)) }
        let hexesMatch = CardSurfaceHex.allCases.allSatisfy { resolve($0, L, baked: D.hex($0)) == D.hex($0) }
        let flagsMatch = CardSurfaceFlag.allCases.allSatisfy { resolve($0, L, baked: D.flag($0)) == D.flag($0) }
        row("tuner-defaults-render-what-ships", dialsMatch && hexesMatch && flagsMatch && palette(named: L.palette) == .shipped,
            "dials=\(dialsMatch) hexes=\(hexesMatch) flags=\(flagsMatch)")
        let Dk = AppearanceTuningValues.darkDefault
        row("tuner-dark-defaults-are-T's", fieldHex(Dk, dark: true) == "1A1A1A" && close(darkShadowAlpha * Dk.shadowStrength, 0.742)
            && Dk.shadowRadius == 12 && !Dk.hairline)
        row("tuner-librarian-defaults-are-what-ships", L.librarianSpec == bl && Dk.librarianSpec == bd,
            "light=\(L.librarianSpec) dark=\(Dk.librarianSpec)")
        row("field-steps-hit-the-render-hexes", fieldHex(withStep(L, -1), dark: false) == "E6E2DA"
            && fieldHex(withStep(L, 0), dark: false) == "EFECE6" && fieldHex(withStep(L, 1), dark: false) == "F4F2ED"
            && fieldHex(withStep(L, 2), dark: false) == "F8F6F2")
        row("hairline-off-is-the-prior-rim", resolve(.rimHex, noHairline(L), baked: "") == "FFFFFF"
            && resolve(.rimOpacity, noHairline(L), baked: 0) == 0.95 && resolve(.rimTopOnly, noHairline(L), baked: false))

        // live-23 (3) — the hero photo's fade into the card body: longer and eased, like the fluted cards' blend.
        let F = CardHeroFade.self, fb = F.baked
        row("hero-fade-baked-0.60-of-the-zone-smoothstep-past-the-edge-0.10",
            close(fb.length, 0.60) && close(fb.curve, 1) && close(fb.overshoot, 0.10), "\(fb)")
        // A quarter of the way into the fade the photo is still mostly there (eased, not a linear ramp).
        let fadeTop = 1 - fb.length / (1 + fb.overshoot)
        let quarter = F.alpha(fb, at: fadeTop + (1 - fadeTop) * 0.25), half = F.alpha(fb, at: fadeTop + (1 - fadeTop) * 0.5)
        row("hero-fade-is-eased", quarter > 0.8 && abs(half - 0.5) < 0.02, "quarter=\(quarter) half=\(half)")
        row("hero-fade-opaque-above-clear-at-the-end", close(F.alpha(fb, at: fadeTop - 0.01), 1) && close(F.alpha(fb, at: 1), 0))
        let st = F.stops(fb)
        row("hero-fade-stops-monotone-and-match-alpha", st.count >= 8 && zip(st, st.dropFirst()).allSatisfy { $0.location <= $1.location }
            && st.allSatisfy { s in abs(F.alpha(fb, at: Double(s.location)) - Double(UIColor(s.color).cgColor.alpha)) < 0.02 },
            "stops=\(st.count)")
        let old = F.stops(F.live22)
        row("hero-fade-live22-shape-is-the-old-mask", old.count == 3 && old[1].location == 0.78
            && close(F.alpha(F.live22, at: 0.89), 0.5))
        // live-23 (4) + (5c) — the taste switches start on Today; an App Store build (and plain DEBUG) render Today.
        row("card-content-and-capture-controls-start-on-today",
            AppearanceTuningState.defaults.cardContent == .today && AppearanceTuningState.defaults.captureControls == .today)
        row("plain-debug-renders-today-capture-controls",
            UserDefaults.standard.string(forKey: "CaptureControls") == "glass" || isLive || !CaptureControlsStyle.glassChosen)
        row("tuner-fade-defaults-are-baked", L.heroFade == fb && Dk.heroFade == fb, "\(L.heroFade) \(Dk.heroFade)")

        // Gate + storage.
        let stored = try? JSONEncoder().encode(AppearanceTuningState(light: withStep(L, 2), dark: Dk))
        row("closed-gate-ignores-stored-values", effective(stored: stored, offered: false) == .defaults)
        row("open-gate-uses-stored-values", effective(stored: stored, offered: true).light.fieldStep == 2)
        // T's stored values from TF 202610161756 (no fade / card-content keys) survive live-23's new keys.
        if var legacy = (try? JSONSerialization.jsonObject(with: stored ?? Data())) as? [String: Any],
           var l = legacy["light"] as? [String: Any] {
            l.removeValue(forKey: "fadeLength"); l.removeValue(forKey: "fadeCurve"); legacy["light"] = l
            var dd = legacy["dark"] as? [String: Any] ?? [:]
            dd.removeValue(forKey: "fadeLength"); dd.removeValue(forKey: "fadeCurve"); legacy["dark"] = dd
            legacy.removeValue(forKey: "cardContent"); legacy.removeValue(forKey: "captureControls")
            let data = try? JSONSerialization.data(withJSONObject: legacy)
            let back = effective(stored: data, offered: true)
            row("live-22-stored-values-survive-new-keys", back.light.fieldStep == 2 && back.light.heroFade == CardHeroFade.baked
                && back.cardContent == .today && back.captureControls == .today)
        } else {
            row("live-22-stored-values-survive-new-keys", false, "couldn't build the legacy blob")
        }
        row("unreadable-stored-value-is-defaults", effective(stored: Data("{\"light\":1}".utf8), offered: true) == .defaults)
        #if DEBUG
        row("debug-sim-runs-render-what-ships (no -AppearanceTuner)",
            UserDefaults.standard.bool(forKey: "AppearanceTuner") || !isLive)
        #endif

        // Presets.
        var p = L
        p.apply(.frost65); let f65 = p
        p.apply(.frost50Glass); let f50g = p
        p.apply(.today); let before = p
        row("presets-set-their-values", close(f65.tintOpacity, 0.65) && close(f65.saturation, 0.4) && !f65.glassControls
            && f50g.glassControls && close(f50g.tintOpacity, 0.5)
            && before.panel == .today && close(before.tintOpacity, 0.35) && close(before.blur, 1) && !before.glassControls)

        // Export — at the defaults, Copy values reads back T's reference JSON verbatim (with this build's number).
        let json = exportJSON(.defaults, editing: "light", build: "202610161756")
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        row("copy-values-is-json-with-both-modes", parsed?["dark"] != nil && parsed?["light"] != nil, json)
        let reference = ##"{"airpadAppearance":1,"build":"202610161756","editing":"light","light":{"palette":"L2","field":"F2","fieldStep":1,"fieldHex":"#F4F2ED","shadow":0.5,"shadowAlpha":0.131,"shadowRadius":24,"hairline":true,"hairlineWidth":0.5,"hairlineOpacity":0.25,"panel":"custom","tint":0.85,"blur":1.74,"saturation":1,"glassControls":true,"dim":0.1},"dark":{"field":"F+0.50","fieldStep":0.5,"fieldHex":"#1A1A1A","shadow":1,"shadowAlpha":0.742,"shadowRadius":12,"hairline":false,"hairlineWidth":0.5,"hairlineOpacity":0.12,"panel":"custom","tint":0.56,"blur":2,"saturation":0.4,"glassControls":true,"dim":0.2}}"##
        // Every key T's export carried reads back the same value (live-23 adds keys; none of T's may change).
        let ref = (try? JSONSerialization.jsonObject(with: Data(reference.utf8))) as? [String: Any] ?? [:]
        var mismatches: [String] = []
        for mode in ["light", "dark"] {
            let want = ref[mode] as? [String: Any] ?? [:], got = parsed?[mode] as? [String: Any] ?? [:]
            for (k, v) in want where !(got[k].map { "\($0)" == "\(v)" } ?? false) {
                mismatches.append("\(mode).\(k): want \(v) got \(got[k].map { "\($0)" } ?? "—")")
            }
        }
        row("copy-values-at-defaults-reads-back-T's-reference", !ref.isEmpty && mismatches.isEmpty,
            mismatches.joined(separator: "; "))

        #if DEBUG || TESTFLIGHT
        row("this-build-offers-it (DEBUG / TESTFLIGHT)", isOffered)
        #endif
        return "[AppearanceTuningSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.joined(separator: "\n")
    }

    private static func withStep(_ v: AppearanceTuningValues, _ s: Double) -> AppearanceTuningValues {
        var c = v; c.fieldStep = s; return c
    }
    private static func noHairline(_ v: AppearanceTuningValues) -> AppearanceTuningValues {
        var c = v; c.hairline = false; return c
    }
}

#endif
