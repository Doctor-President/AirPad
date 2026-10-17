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

extension PillLook {
    /// The 2026-10-17 brief: T's light pills on TF 202610170354 — a white rim at rest, 1 pt at 80%, on all three
    /// (dark: no rim). TestFlight defaults only; what ships stays `PillLook.off`.
    static let tunedLight1017 = PillLook(variant: .regular, grade: .off,
                                         rim: PillRim(rest: .static, width: 1, brightness: 0.8, color: .white, active: .none,
                                                      activeBrightness: 1))
}

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
    /// The frost presets the sheet offers (Custom is what a slider edit becomes). live-24: Liquid Glass is its own
    /// panel mode now (`LibrarianPanelMode`), not a preset a slider can kick out of; `.liquidGlass` stays decodable.
    static let offered: [LibrarianPanelPreset] = [.today, .frost35, .frost50, .frost65, .frost50Glass]
}

/// live-24 (1) — the Librarian panel is a frost (our blur + tint) or real Liquid Glass (Apple's knobs + our veil).
enum LibrarianPanelMode: String, Codable, CaseIterable, Identifiable {
    case frost, glass
    var id: String { rawValue }
    var label: String { self == .frost ? "Frost" : "Liquid Glass" }
}

/// live-24 (2) — the graded-tint presets (T's reference: iOS 27's Spotlight / Siri "Search or Ask" pill).
enum LibrarianGlassPreset: String, CaseIterable, Identifiable {
    case siriPill, gradedPanel, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .siriPill:    return "Siri-style pill"
        case .gradedPanel: return "Graded panel"
        case .both:        return "Both"
        }
    }
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
    // Liquid Glass + graded tint (live-24) — all off in what ships
    var panelMode: LibrarianPanelMode = .frost
    var glass: PanelGlass = .lightDefault
    var panelGrade: GradedTint = .off
    // The three pills, each its own look (2026-10-17 brief). Peek + Search are one morphing view; Ask can mirror Search.
    var peekPill: PillLook = .off
    var searchPill: PillLook = .off
    var askPill: PillLook = .off
    var askMatchesSearch: Bool = true

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
        dimBehind: true, dimAmount: 0.10,
        peekPill: .tunedLight1017, searchPill: .tunedLight1017, askPill: .tunedLight1017)

    /// ★ live-23 (1) — dark: the field half a step lighter (#1A1A1A), the shadow and top rim as before; the Librarian a
    /// real frost (tint 0.56, blur 2, colour at 40%) with glass controls, the content behind dimmed 20%.
    static let darkDefault = AppearanceTuningValues(
        palette: "L2", fieldStep: 0.5, shadowStrength: 1, shadowRadius: 12,
        hairline: false, hairlineWidth: 0.5, hairlineOpacity: 0.12,
        panel: .custom, tintOpacity: 0.56, blur: 2, saturation: 0.4, glassControls: true,
        dimBehind: true, dimAmount: 0.20, glass: .darkDefault)

    /// The Librarian surface these values render (live-23).
    var librarianSpec: LibrarianSurfaceSpec {
        LibrarianSurfaceSpec(tint: tintOpacity, blur: blur, saturation: saturation, glassControls: glassControls,
                             dim: dimBehind ? min(max(dimAmount, 0), 0.20) : 0, wholePanelGlass: panel == .liquidGlass)
    }

    /// live-24 — the glass + graded-tint look these values render.
    var glassLook: LibrarianGlassLook {
        LibrarianGlassLook(panelGlass: panelMode == .glass ? glass : nil, panelGrade: panelGrade, peek: peekPill,
                           search: searchPill, ask: askLook)
    }
    /// The Ask bar's look as it renders: Search's while "Match Search" is on.
    var askLook: PillLook { askMatchesSearch ? searchPill : askPill }

    /// "Match Search" off copies Search's look into Ask, which then diverges; on mirrors Search again.
    mutating func setAskMatchesSearch(_ on: Bool) {
        if !on && askMatchesSearch { askPill = searchPill }
        askMatchesSearch = on
    }
    /// Every pill at once (the presets, "All off").
    mutating func editPills(_ change: (inout PillLook) -> Void) {
        change(&peekPill); change(&searchPill); change(&askPill)
    }

    /// A frost slider: the panel becomes a custom frost.
    mutating func editFrost(_ change: (inout AppearanceTuningValues) -> Void) {
        change(&self); panel = .custom; panelMode = .frost
    }
    /// A Liquid Glass control (variant, tint colour + strength, veil): the panel STAYS Liquid Glass (live-24 (1): T
    /// found every slider flipped the old "Liquid Glass" preset to Custom).
    mutating func editGlass(_ change: (inout PanelGlass) -> Void) {
        change(&glass); panelMode = .glass
    }

    /// The graded-tint presets. `dark` picks the panel's grade colour (light: off-white, so the dark text keeps reading).
    mutating func apply(_ preset: LibrarianGlassPreset, dark: Bool) {
        switch preset {
        case .siriPill:
            // T's reference: a near-black grade dense across the top and centre where the text sits, thinning to the
            // bottom edge; a thin white rim; a clearer glass beneath. The fade starts BELOW the text line (0.75): light
            // text on a grade that thins inside the line fails AA over a light page (live-24 (3): worst 2.85).
            // All three pills (peek, search, Ask).
            glassControls = true
            editPills {
                $0.variant = .clear
                $0.grade = GradedTint(on: true, top: 0.9, bottom: 0.15, start: 0.75, softness: 1, direction: .vertical,
                                      color: .nearBlack)
                $0.rim = PillRim(rest: .static, width: 1, brightness: 0.8, color: .white, active: .none, activeBrightness: 1)
            }
        case .gradedPanel:
            // Real glass, the grade densest behind the transcript and thinning toward the top edge (where the
            // content behind still lenses through).
            panelMode = .glass
            glass = PanelGlass(variant: .regular, tint: dark ? .nearBlack : .offWhite, tintStrength: 0.2, veil: 0.3)
            panelGrade = GradedTint(on: true, top: 0.1, bottom: dark ? 0.7 : 0.75, start: 0.04, softness: 0.4,
                                    direction: .vertical, color: dark ? .nearBlack : .offWhite)
        case .both:
            apply(.siriPill, dark: dark); apply(.gradedPanel, dark: dark)
        }
    }

    /// Whether these values are a preset as it was applied (so the sheet can mark it).
    func matches(_ preset: LibrarianGlassPreset, dark: Bool) -> Bool {
        var p = self; p.apply(preset, dark: dark); return p == self
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
        case .liquidGlass:  glassControls = true; panelMode = .glass; return
        case .custom:       break
        }
        if preset != .custom { panelMode = .frost }
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
        // live-24: a stored "Liquid Glass" preset (TF 202610162306) opens in the Liquid Glass mode.
        panelMode = try c.decodeIfPresent(LibrarianPanelMode.self, forKey: .panelMode) ?? (panel == .liquidGlass ? .glass : .frost)
        glass = try c.decodeIfPresent(PanelGlass.self, forKey: .glass) ?? .lightDefault
        panelGrade = try c.decodeIfPresent(GradedTint.self, forKey: .panelGrade) ?? .off
        // 2026-10-17 brief: the three pills. live-24's one shared pill look (TF 202610170354: `pillVariant`,
        // `pillGrade`, `pillRim`) loads into all three, Ask mirroring Search, so T's stored look renders as it did.
        let legacy = LegacyPillKeys.decode(from: decoder)
        peekPill = (try? c.decodeIfPresent(PillLook.self, forKey: .peekPill)) ?? legacy ?? .off
        searchPill = (try? c.decodeIfPresent(PillLook.self, forKey: .searchPill)) ?? legacy ?? .off
        askPill = (try? c.decodeIfPresent(PillLook.self, forKey: .askPill)) ?? legacy ?? .off
        askMatchesSearch = (try? c.decodeIfPresent(Bool.self, forKey: .askMatchesSearch)) ?? true
    }
}

/// live-24's shared pill keys, read only to migrate them (never written).
private enum LegacyPillKeys: String, CodingKey {
    case pillVariant, pillGrade, pillRim

    static func decode(from decoder: Decoder) -> PillLook? {
        guard let c = try? decoder.container(keyedBy: LegacyPillKeys.self),
              c.contains(.pillVariant) || c.contains(.pillGrade) || c.contains(.pillRim) else { return nil }
        return PillLook(variant: (try? c.decodeIfPresent(GlassVariant.self, forKey: .pillVariant)) ?? .regular,
                        grade: (try? c.decodeIfPresent(GradedTint.self, forKey: .pillGrade)) ?? .off,
                        rim: (try? c.decodeIfPresent(PillRim.self, forKey: .pillRim)) ?? .off)
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
        if UserDefaults.standard.bool(forKey: "AppearanceTunerReset") {   // UI tests start from (1), every section closed
            state = .defaults
            UserDefaults.standard.removeObject(forKey: AppearanceTuning.openSectionKey)
        }
        // live-25 (3) — `-AppearanceTunerImportFile <name>`: a Copy values paste (in the app's Documents) loaded for stills.
        if let name = UserDefaults.standard.string(forKey: "AppearanceTunerImportFile"),
           let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let json = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
           let imported = AppearanceTuning.importExport(json) {
            state = imported
        }
        // live-24 (5) stills — `-AppearanceTuner YES -AppearanceTunerReset YES -GlassPresetRender siriPill|gradedPanel|both`.
        if let raw = UserDefaults.standard.string(forKey: "GlassPresetRender") {
            if let p = LibrarianGlassPreset(rawValue: raw) {
                state.light.apply(p, dark: false); state.dark.apply(p, dark: true)
            } else if raw == "glass" {   // the Liquid Glass mode at its defaults, nothing graded
                state.light.editGlass { _ in }; state.dark.editGlass { _ in }
            }
        }
        // `-RimAnimationRender shimmer|breathe` — the rim's "while answering" motion on Search + Ask (with
        // `-RenderGenerating YES`); `-RimRestRender off|static|dim` — the rim at rest on all three pills.
        if let a = UserDefaults.standard.string(forKey: "RimAnimationRender").flatMap(PillRimActive.init(rawValue:)) {
            for d in [false, true] { update(dark: d) { $0.searchPill.rim.active = a; $0.askPill.rim.active = a } }
        }
        if let r = UserDefaults.standard.string(forKey: "RimRestRender").flatMap(PillRimRest.init(rawValue:)) {
            for d in [false, true] { update(dark: d) { $0.editPills { $0.rim.rest = r } } }
        }
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
    /// Which tuner section is open (the sheet's accordion), so it reopens where T left it.
    static let openSectionKey = "AppearanceTunerOpenSection"

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
        func grade(_ g: GradedTint) -> String {
            "{\"on\":\(g.on),\"top\":\(num(g.top)),\"bottom\":\(num(g.bottom)),\"start\":\(num(g.start)),"
                + "\"softness\":\(num(g.softness)),\"direction\":\"\(g.direction.rawValue)\",\"color\":\"\(g.color.rawValue)\","
                + "\"hex\":\"#\(g.color.hex)\"}"
        }
        func rim(_ r: PillRim) -> String {
            "{\"rest\":\"\(r.rest.rawValue)\",\"width\":\(num(r.width)),\"brightness\":\(num(r.brightness)),"
                + "\"color\":\"\(r.color.rawValue)\",\"hex\":\"#\(r.color.hex)\",\"active\":\"\(r.active.rawValue)\","
                + "\"activeBrightness\":\(num(r.activeBrightness))}"
        }
        func pill(_ p: PillLook) -> String {
            "{\"variant\":\"\(p.variant.rawValue)\",\"grade\":\(grade(p.grade)),\"rim\":\(rim(p.rim))}"
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
                // live-24 — Liquid Glass + the graded tint + the pill rim
                "\"panelMode\":\"\(v.panelMode.rawValue)\"", "\"glassVariant\":\"\(v.glass.variant.rawValue)\"",
                "\"glassTint\":\"\(v.glass.tint.rawValue)\"", "\"glassTintHex\":\"#\(v.glass.tint.hex)\"",
                "\"glassTintStrength\":\(num(v.glass.tintStrength))", "\"veil\":\(num(v.glass.veil))",
                "\"panelGrade\":\(grade(v.panelGrade))",
                // 2026-10-17 brief — the three pills (live-24's shared pillVariant / pillGrade / pillRim are gone)
                "\"peekPill\":\(pill(v.peekPill))", "\"searchPill\":\(pill(v.searchPill))", "\"askPill\":\(pill(v.askPill))",
                "\"askMatchesSearch\":\(v.askMatchesSearch)",
            ]
            return "{" + parts.joined(separator: ",") + "}"
        }
        return "{\"airpadAppearance\":1,\"build\":\"\(build)\",\"editing\":\"\(mode)\",\"cardContent\":\"\(s.cardContent.rawValue)\",\"captureControls\":\"\(s.captureControls.rawValue)\","
            + "\"light\":\(block(s.light, dark: false)),\"dark\":\(block(s.dark, dark: true))}"
    }
}

// MARK: - Import (assessment only)

extension AppearanceTuning {
    /// live-25 (3) — a Copy values paste → the stored state, decoded by the REAL decoder, so live-24's shared pill keys
    /// (`pillVariant` / `pillGrade` / `pillRim`) take the tuner brief's migration into Peek, Search and Ask. Keys the
    /// paste lacks keep the appearance's TestFlight default. For assessing T's values on a build (DEBUG
    /// `-AppearanceTunerImportFile`); it never becomes a default and never touches Reset. Pure.
    static func importExport(_ json: String) -> AppearanceTuningState? {
        guard let top = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        func block(_ b: [String: Any]?, dark: Bool) -> [String: Any]? {
            guard let b, let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(
                dark ? AppearanceTuningValues.darkDefault : .lightDefault)) as? [String: Any] else { return nil }
            var o = base
            // A live-24 paste carries the shared pill keys: let the decoder migrate them (drop the defaults' new keys).
            if b["peekPill"] == nil && (b["pillGrade"] != nil || b["pillVariant"] != nil || b["pillRim"] != nil) {
                for k in ["peekPill", "searchPill", "askPill", "askMatchesSearch"] { o.removeValue(forKey: k) }
            }
            let renamed = ["shadow": "shadowStrength", "tint": "tintOpacity"]
            for k in ["palette", "fieldStep", "shadow", "shadowRadius", "hairline", "hairlineWidth", "hairlineOpacity", "panel",
                      "tint", "blur", "saturation", "glassControls", "fadeLength", "fadeCurve", "panelMode", "panelGrade",
                      "pillGrade", "pillVariant", "pillRim", "peekPill", "searchPill", "askPill", "askMatchesSearch"] {
                if let v = b[k] { o[renamed[k] ?? k] = v }
            }
            if let dim = b["dim"] as? Double { o["dimBehind"] = dim > 0; if dim > 0 { o["dimAmount"] = dim } }
            var glass = o["glass"] as? [String: Any] ?? [:]
            for (from, to) in [("glassVariant", "variant"), ("glassTint", "tint"), ("glassTintStrength", "tintStrength"), ("veil", "veil")] {
                if let v = b[from] { glass[to] = v }
            }
            o["glass"] = glass
            return o
        }
        guard let l = block(top["light"] as? [String: Any], dark: false), let d = block(top["dark"] as? [String: Any], dark: true)
        else { return nil }
        var st: [String: Any] = ["light": l, "dark": d]
        for k in ["cardContent", "captureControls"] { if let v = top[k] { st[k] = v } }
        guard let data = try? JSONSerialization.data(withJSONObject: st) else { return nil }
        return try? JSONDecoder().decode(AppearanceTuningState.self, from: data)
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

        // live-24 (1) — the Liquid Glass mode: Apple's knobs (variant, tint) + our veil; no slider kicks it out.
        var g = L; g.panelMode = .glass
        g.editGlass { $0.variant = .clear }; g.editGlass { $0.tint = .deepKlein }
        g.editGlass { $0.tintStrength = 0.6 }; g.editGlass { $0.veil = 0.8 }
        row("liquid-glass-mode-survives-every-glass-control", g.panelMode == .glass
            && g.glass == PanelGlass(variant: .clear, tint: .deepKlein, tintStrength: 0.6, veil: 0.8)
            && g.glassLook.panelGlass == g.glass, "mode=\(g.panelMode) panel=\(g.panel)")
        var fz = g; fz.editFrost { $0.tintOpacity = 0.5 }
        row("a-frost-slider-is-the-frost-mode", fz.panelMode == .frost && fz.panel == .custom && fz.glassLook.panelGlass == nil)
        row("glass-tint-colours-are-the-three-hexes", GlassTintColor.allCases.map(\.hex) == ["FBF9F5", "0A0A0A", "0E2D61"])
        row("ships-unchanged (glass, grades, rims all off)", LibrarianGlassLook.shipped == LibrarianGlassLook(panelGlass: nil,
            panelGrade: .off, peek: .off, search: .off, ask: .off) && PillLook.off.rim.rest == .off && !PillLook.off.grade.on
            && Dk.glassLook == .shipped
            && (isLive || LibrarianGlassLook.current(dark: false) == .shipped && LibrarianGlassLook.current(dark: true) == .shipped))
        // The 2026-10-17 brief: the TestFlight defaults are T's look on TF 202610170354 (light: a white rim, 1 pt at
        // 80%, on all three pills; dark: none); everything else as live-24.
        let wantRim = PillRim(rest: .static, width: 1, brightness: 0.8, color: .white, active: .none, activeBrightness: 1)
        row("tuner-light-defaults-are-T's-1017-pills (white rim 1 pt 80%, dark none)",
            [L.peekPill, L.searchPill, L.askPill].allSatisfy { $0.rim == wantRim && !$0.grade.on && $0.variant == .regular }
            && L.askMatchesSearch && L.glassLook.panelGlass == nil && !L.glassLook.panelGrade.on
            && [Dk.peekPill, Dk.searchPill, Dk.askPill].allSatisfy { $0 == .off })
        if var legacyGlass = (try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(
            AppearanceTuningState(light: { var x = L; x.apply(.liquidGlass); return x }(), dark: Dk))) ?? Data())) as? [String: Any],
           var lg = legacyGlass["light"] as? [String: Any] {
            for k in ["panelMode", "glass", "panelGrade", "peekPill", "searchPill", "askPill", "askMatchesSearch"] {
                lg.removeValue(forKey: k)
            }
            legacyGlass["light"] = lg
            let back = effective(stored: try? JSONSerialization.data(withJSONObject: legacyGlass), offered: true)
            row("a-stored-live-23-liquid-glass-opens-in-glass-mode", back.light.panelMode == .glass && back.dark.glassLook == .shipped
                && back.light.searchPill == .off,
                "light mode=\(back.light.panelMode)")
        } else {
            row("a-stored-live-23-liquid-glass-opens-in-glass-mode", false, "couldn't build the blob")
        }

        // live-24 (2) — the graded tint + the presets.
        let gt = GradedTint(on: true, top: 0.9, bottom: 0.15, start: 0.2, softness: 1, direction: .vertical, color: .nearBlack)
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { gt.alpha(at: $0) }
        row("graded-tint-top-then-eased-to-bottom", close(gt.alpha(at: 0), 0.9) && close(gt.alpha(at: 0.2), 0.9)
            && close(gt.alpha(at: 1), 0.15) && zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 - 1e-9 }
            && gt.alpha(at: 0.3) > 0.85, "samples=\(samples.map { String(format: "%.2f", $0) })")
        row("graded-tint-stops-carry-the-curve", gt.stops.count == 17 && close(Double(gt.stops.last!.location), 1))
        var sp = L; sp.apply(.siriPill, dark: false)
        let spP = sp.searchPill
        row("preset-siri-pill (near-black 0.9 → 0.15, white rim 1 pt) on all three pills", spP.grade.on && spP.grade.color == .nearBlack
            && close(spP.grade.top, 0.9) && close(spP.grade.bottom, 0.15) && spP.grade.direction == .vertical && spP.variant == .clear
            && spP.rim.rest == .static && spP.rim.color == .white && close(spP.rim.width, 1) && sp.glassControls
            && sp.peekPill == spP && sp.askPill == spP && sp.glassLook.ask == spP && sp.glassLook.peek == spP
            && sp.panelMode == L.panelMode && !sp.panelGrade.on, "\(spP)")
        row("siri-pill-text-turns-light", LibrarianGlassLook.pillScheme(spP.grade) == .dark)
        // live-25 (1) — the glyphs beside the pill text flip with it. The Ask bar's × (ink at 40%) on a grade is then no
        // worse than on the plain pill of the same appearance (light #FBF9F5 / dark #141414 page under the pill). The
        // 40% × itself is ~2.4:1 on the plain light pill — under 3:1 before any grade (reported, not changed here).
        func rgb(_ h: String) -> [Double] {
            var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
            return [Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF)].map { $0 / 255 }
        }
        func lum(_ c: [Double]) -> Double {
            let l = c.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        }
        func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] { zip(a, b).map { $0 + ($1 - $0) * t } }
        func ratio(_ a: [Double], _ b: [Double]) -> Double { let x = lum(a), y = lum(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
        func clearGlyph(_ g: GradedTint, _ appearance: ColorScheme) -> Double {
            let ink = rgb(LibrarianPillChrome.inkHex(LibrarianPillChrome.controlsScheme(g, appearance: appearance, glassControls: true)))
            let page = rgb(LibrarianGlassAccessibility.solidHex(dark: appearance == .dark))
            let back = g.on ? mix(page, rgb(g.color.hex), g.alpha(at: 0.5)) : page
            return ratio(mix(back, ink, 0.4), back)
        }
        // The grades T chooses between: the Siri-style pill, and T's 2026-10-17 pills (light: off-white 0.71 → 0.15 from
        // 0.5; dark: near-black 1 → 0.25 from 0.27).
        let t17L = GradedTint(on: true, top: 0.71, bottom: 0.15, start: 0.5, softness: 1, direction: .vertical, color: .offWhite)
        let t17D = GradedTint(on: true, top: 1, bottom: 0.25, start: 0.27, softness: 1, direction: .vertical, color: .nearBlack)
        var flipOK = true
        for g in [spP.grade, t17L, t17D, GradedTint.off] {
            for appearance in [ColorScheme.light, .dark] where LibrarianPillChrome.controlsScheme(g, appearance: appearance, glassControls: true)
                != LibrarianPillChrome.textScheme(g, appearance: appearance, glassControls: true) { flipOK = false }
        }
        var glyphRows: [String] = [], glyphOK = true
        for (name, g, appearance) in [("siri", spP.grade, ColorScheme.light), ("siri", spP.grade, .dark), ("t1017", t17L, .light),
                                      ("t1017", t17D, .dark)] {
            let r = clearGlyph(g, appearance), plain = clearGlyph(.off, appearance)
            if r < plain - 0.05 { glyphOK = false }
            glyphRows.append("\(name)/\(appearance == .dark ? "dark" : "light")=\(String(format: "%.2f", r)) (plain \(String(format: "%.2f", plain)))")
        }
        row("pill-glyphs-flip-with-the-text (× send mic stop)", flipOK)
        row("ask-clear-glyph-no-worse-on-a-grade-than-on-the-plain-pill", glyphOK, glyphRows.joined(separator: " "))
        // live-24 (3) — light text needs the grade dense through the WHOLE text line (a one-line pill's text spans
        // ~0.25–0.75 of its height, descenders included): ≥ 0.6 near-black keeps white text AA over a white backdrop.
        let band = stride(from: 0.2, through: 0.75, by: 0.05).map { spP.grade.alpha(at: $0) }
        row("siri-pill-dense-through-the-text-line (≥ 0.6 from 0.20 to 0.75)", band.allSatisfy { $0 >= 0.6 },
            "band=\(band.map { String(format: "%.2f", $0) })")
        var gpL = L; gpL.apply(.gradedPanel, dark: false)
        var gpD = Dk; gpD.apply(.gradedPanel, dark: true)
        row("preset-graded-panel (glass, denser behind the transcript, thinning to the top)",
            gpL.panelMode == .glass && gpL.panelGrade.on && gpL.panelGrade.top < gpL.panelGrade.bottom
            && gpL.panelGrade.color == .offWhite && gpD.panelGrade.color == .nearBlack && gpL.searchPill == L.searchPill,
            "\(gpL.panelGrade)")
        var both = L; both.apply(.both, dark: false)
        row("preset-both = siri pill + graded panel", both.peekPill == spP && both.searchPill == spP && both.askPill == spP
            && both.panelGrade == gpL.panelGrade && both.panelMode == .glass)
        row("presets-are-marked-when-applied", sp.matches(.siriPill, dark: false) && !sp.matches(.gradedPanel, dark: false)
            && both.matches(.both, dark: false) && !L.matches(.siriPill, dark: false))
        row("rim-colours-are-airpad's-palette-only (no Apple Intelligence multicolour)",
            Set(PillRimColor.allCases.map(\.hex)) == ["FFFFFF", "1B59C2", "00BFFF", "E8820A"])
        let anim = PillRim(rest: .static, width: 1, brightness: 0.8, color: .cyan, active: .shimmer, activeBrightness: 1)
        row("rim-moves-only-while-generating-never-under-reduce-motion",
            PillRim.animates(anim, generating: true, reduceMotion: false)
            && !PillRim.animates(anim, generating: false, reduceMotion: false)
            && !PillRim.animates(anim, generating: true, reduceMotion: true)
            && !PillRim.animates({ var r = anim; r.active = .none; return r }(), generating: true, reduceMotion: false))

        // 2026-10-17 brief (B) — the rim's rest and its "while answering" motion are independent: off at rest, shimmer
        // while thinking (T couldn't set that on TF 202610170354: the shimmer only ran on a rim that was on).
        let thinking = PillRim(rest: .off, width: 1, brightness: 0.8, color: .white, active: .shimmer, activeBrightness: 1)
        row("rim-off-at-rest-shimmers-only-while-generating", thinking.isUsed && thinking.rest.share == 0
            && PillRim.animates(thinking, generating: true, reduceMotion: false)
            && !PillRim.animates(thinking, generating: false, reduceMotion: false)
            && !PillRim.animates(thinking, generating: true, reduceMotion: true))
        row("rim-rest-dim-is-quieter-than-on", PillRimRest.dim.share > 0 && PillRimRest.dim.share < PillRimRest.static.share
            && PillRimRest.off.share == 0 && !PillRim.off.isUsed)

        // 2026-10-17 brief (A) — peek, search and Ask each have their own look; Ask mirrors Search until it's let go.
        var ind = Dk
        ind.peekPill.grade.on = true; ind.searchPill.variant = .clear
        row("pills-are-independent (peek · search · Ask)", ind.glassLook.peek.grade.on && !ind.glassLook.search.grade.on
            && ind.glassLook.search.variant == .clear && ind.glassLook.peek.variant == .regular && !ind.glassLook.ask.grade.on,
            "peek=\(ind.glassLook.peek.grade.on) search=\(ind.glassLook.search.grade.on)")
        var mir = Dk
        mir.searchPill.rim.rest = .dim
        let mirrored = mir.glassLook.ask.rim.rest == .dim && mir.askMatchesSearch
        mir.setAskMatchesSearch(false)
        let copied = mir.askPill == mir.searchPill
        mir.askPill.grade.on = true
        row("ask-mirrors-search-then-diverges", mirrored && copied && mir.glassLook.ask.grade.on && !mir.glassLook.search.grade.on
            && mir.glassLook.ask.rim.rest == .dim, "mirrored=\(mirrored) copied=\(copied)")
        let shim = PillLook(variant: .regular, grade: .off, rim: thinking)
        let same = LibrarianPillGlass<Capsule>.layers(pill: shim, from: shim, share: 1)
        let atPeek = LibrarianPillGlass<Capsule>.layers(pill: shim, from: shim, share: 0)
        let mixed = LibrarianPillGlass<Capsule>.layers(pill: shim, from: .off, share: 0.4)
        row("only-the-search-side-of-the-morphing-pill-moves", same.count == 1 && same[0].2 && atPeek.count == 1 && !atPeek[0].2
            && mixed.count == 2 && !mixed[0].2 && mixed[1].2 && close(mixed[1].1, 0.4)
            && LibrarianPillGlass<Capsule>.layers(pill: shim, from: nil, share: 1).first?.2 == true)
        row("the-morphing-pill-hands-peek-to-search", LibrarianGlassLook.searchShare(peekVisibility: 1) == 0
            && LibrarianGlassLook.searchShare(peekVisibility: 0) == 1 && LibrarianGlassLook.searchShare(peekVisibility: 0.5) == 0.5)

        // 2026-10-17 brief (C) — live-24's stored shared pill look (TF 202610170354) loads into all three pills.
        let legacyPill = ##"{"pillVariant":"clear","pillGrade":{"on":true,"top":0.9,"bottom":0.15,"start":0.75,"softness":1,"direction":"vertical","color":"nearBlack"},"pillRim":{"on":true,"width":1.5,"brightness":0.6,"color":"cyan","animation":"pulse"}}"##
        if var st = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceTuningState(light: L, dark: Dk)))) as? [String: Any],
           var ll = st["light"] as? [String: Any], var dd = st["dark"] as? [String: Any],
           let extra = (try? JSONSerialization.jsonObject(with: Data(legacyPill.utf8))) as? [String: Any] {
            for k in ["peekPill", "searchPill", "askPill", "askMatchesSearch"] { ll.removeValue(forKey: k); dd.removeValue(forKey: k) }
            for (k, v) in extra { ll[k] = v }
            dd["pillRim"] = ["on": false, "width": 1, "brightness": 0.8, "color": "white", "animation": "shimmer"]
            st["light"] = ll; st["dark"] = dd
            let back = effective(stored: try? JSONSerialization.data(withJSONObject: st), offered: true)
            let wantL = PillLook(variant: .clear, grade: spP.grade,
                                 rim: PillRim(rest: .static, width: 1.5, brightness: 0.6, color: .cyan, active: .breathe, activeBrightness: 1))
            row("live-24-stored-pill-look-loads-into-all-three", back.light.peekPill == wantL && back.light.searchPill == wantL
                && back.light.askPill == wantL && back.light.askMatchesSearch && back.light.fieldStep == L.fieldStep,
                "peek=\(back.light.peekPill)")
            row("live-24-off-rim-with-shimmer-stays-still", back.dark.searchPill.rim.rest == .off
                && back.dark.searchPill.rim.active == .none && !back.dark.searchPill.rim.isUsed, "\(back.dark.searchPill.rim)")
        } else {
            row("live-24-stored-pill-look-loads-into-all-three", false, "couldn't build the blob")
        }
        var trip = AppearanceTuningState(light: sp, dark: mir)
        trip.dark.peekPill.rim = thinking
        let tripBack = (try? JSONEncoder().encode(trip)).flatMap { try? JSONDecoder().decode(AppearanceTuningState.self, from: $0) }
        row("stored-values-round-trip", tripBack == trip)

        // live-24 (3) — Reduce Transparency → solid; Increase Contrast → a firm veil + edge.
        let rt = LibrarianGlassAccessibility.resolve(reduceTransparency: true, increaseContrast: false)
        let ic = LibrarianGlassAccessibility.resolve(reduceTransparency: false, increaseContrast: true)
        let none = LibrarianGlassAccessibility.resolve(reduceTransparency: false, increaseContrast: false)
        row("reduce-transparency-is-solid-increase-contrast-firms-the-veil", rt.solid && !ic.solid && !none.solid
            && ic.veilFloor >= 0.85 && none.veilFloor == 0 && ic.strokeOpacity > none.strokeOpacity)

        // live-25 (3) — T's 2026-10-17 paste (TF 202610170354, Ops reference/appearance-tuning-2026-10-17.md), loaded
        // through the migration: one pill look into Peek, Search and Ask; dark's rim (off, "shimmer") → no shimmer.
        // Assessment only: it is not the default.
        let t17 = ##"{"airpadAppearance":1,"build":"202610170354","editing":"light","cardContent":"proposal","captureControls":"glass","light":{"palette":"L2","field":"F2","fieldStep":1,"fieldHex":"#F4F2ED","shadow":0.5,"shadowAlpha":0.131,"shadowRadius":24,"hairline":true,"hairlineWidth":0.5,"hairlineOpacity":0.25,"panel":"custom","tint":0.56,"blur":2,"saturation":0.4,"glassControls":true,"dim":0.105,"fadeLength":0.6,"fadeCurve":1,"panelMode":"glass","glassVariant":"regular","glassTint":"offWhite","glassTintHex":"#FBF9F5","glassTintStrength":0.61,"veil":0.08,"panelGrade":{"on":false,"top":0.1,"bottom":0.75,"start":0.04,"softness":0.4,"direction":"vertical","color":"offWhite","hex":"#FBF9F5"},"pillGrade":{"on":true,"top":0.71,"bottom":0.15,"start":0.5,"softness":1,"direction":"vertical","color":"offWhite","hex":"#FBF9F5"},"pillVariant":"clear","pillRim":{"on":true,"width":1,"brightness":0.8,"color":"white","hex":"#FFFFFF","animation":"off"}},"dark":{"field":"F+0.50","fieldStep":0.5,"fieldHex":"#1A1A1A","shadow":1,"shadowAlpha":0.742,"shadowRadius":12,"hairline":true,"hairlineWidth":1,"hairlineOpacity":0.12,"panel":"custom","tint":0.77,"blur":1.01,"saturation":0.05,"glassControls":true,"dim":0.2,"fadeLength":0.35,"fadeCurve":0.15,"panelMode":"glass","glassVariant":"regular","glassTint":"nearBlack","glassTintHex":"#0A0A0A","glassTintStrength":0.2,"veil":0.79,"panelGrade":{"on":true,"top":0.73,"bottom":0.32,"start":0.04,"softness":0.22,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"pillGrade":{"on":true,"top":1,"bottom":0.25,"start":0.27,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"pillVariant":"clear","pillRim":{"on":false,"width":0.5,"brightness":0.11,"color":"white","hex":"#FFFFFF","animation":"shimmer"}}}"##
        if let imp = importExport(t17) {
            let L17 = imp.light, D17 = imp.dark
            let wantL17 = PillLook(variant: .clear, grade: GradedTint(on: true, top: 0.71, bottom: 0.15, start: 0.5, softness: 1,
                                                                     direction: .vertical, color: .offWhite),
                                   rim: PillRim(rest: .static, width: 1, brightness: 0.8, color: .white, active: .none, activeBrightness: 1))
            row("t1017-paste-loads-into-peek-search-ask-alike", L17.peekPill == wantL17 && L17.searchPill == wantL17 && L17.askPill == wantL17
                && L17.askMatchesSearch && D17.peekPill == D17.searchPill && D17.searchPill == D17.askPill
                && D17.searchPill.grade == GradedTint(on: true, top: 1, bottom: 0.25, start: 0.27, softness: 1, direction: .vertical, color: .nearBlack),
                "light peek=\(L17.peekPill)")
            row("t1017-dark-rim-off-with-shimmer-is-no-shimmer", D17.searchPill.rim.rest == .off && D17.searchPill.rim.active == .none
                && !D17.searchPill.rim.isUsed, "\(D17.searchPill.rim)")
            row("t1017-paste-keeps-its-other-values", L17.panelMode == .glass && L17.glass == PanelGlass(variant: .regular, tint: .offWhite,
                tintStrength: 0.61, veil: 0.08) && close(L17.tintOpacity, 0.56) && close(L17.blur, 2) && close(L17.saturation, 0.4)
                && close(L17.dimAmount, 0.105) && D17.panelGrade.on && close(D17.glass.veil, 0.79) && close(D17.fadeCurve, 0.15)
                && D17.hairline && imp.cardContent == .proposal && imp.captureControls == .glass)
            row("t1017-paste-is-not-baked", imp != .defaults && AppearanceTuningState.defaults.light.glassLook.panelGlass == nil
                && LibrarianGlassLook.shipped.search == .off)
        } else {
            row("t1017-paste-loads-into-peek-search-ask-alike", false, "the paste didn't import")
        }

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
        let newKeys = ["panelMode", "glassVariant", "glassTint", "glassTintHex", "glassTintStrength", "veil", "panelGrade",
                       "peekPill", "searchPill", "askPill", "askMatchesSearch"]
        let lightOut = parsed?["light"] as? [String: Any] ?? [:]
        row("copy-values-carries-the-pill-keys", newKeys.allSatisfy { lightOut[$0] != nil }
            && ["pillGrade", "pillVariant", "pillRim"].allSatisfy { lightOut[$0] == nil },
            "missing: \(newKeys.filter { lightOut[$0] == nil })")
        // Copy values round-trips: each exported pill reads back as the look it was copied from.
        let rtJSON = exportJSON(trip, editing: "dark", build: "0")
        let rtOut = (try? JSONSerialization.jsonObject(with: Data(rtJSON.utf8))) as? [String: Any] ?? [:]
        func pillBack(_ mode: String, _ key: String) -> PillLook? {
            guard let m = rtOut[mode] as? [String: Any], let o = m[key],
                  let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
            return try? JSONDecoder().decode(PillLook.self, from: d)
        }
        row("copy-values-pills-read-back", pillBack("light", "peekPill") == trip.light.peekPill
            && pillBack("dark", "peekPill") == trip.dark.peekPill && pillBack("dark", "askPill") == trip.dark.askPill
            && pillBack("dark", "searchPill") == trip.dark.searchPill, rtJSON)

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
