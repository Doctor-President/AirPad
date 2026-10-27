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
    /// live-26 (1) — the Ask bar's own stored look in T's 2026-10-18 paste. It doesn't render ("Match Search" is on, so
    /// Ask shows Search's); kept verbatim so Reset and Copy values are exactly his file.
    static let t1018LightAskStored = PillLook(variant: .clear,
        grade: GradedTint(on: false, top: 0.9, bottom: 0.15, start: 0.75, softness: 1, direction: .vertical, color: .nearBlack),
        rim: PillRim(rest: .off, width: 1, brightness: 0.8, color: .white, active: .none, activeBrightness: 1))
    static let t1018DarkAskStored = PillLook(variant: .clear,
        grade: GradedTint(on: true, top: 1, bottom: 0.25, start: 0.27, softness: 1, direction: .vertical, color: .nearBlack),
        rim: PillRim(rest: .off, width: 0.5, brightness: 0.11, color: .white, active: .none, activeBrightness: 1))
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
    var fadeLength: Double = CardHeroFade.bakedLight.length   // fraction of the hero zone the photo fades over
    var fadeCurve: Double = CardHeroFade.bakedLight.curve     // 0 linear · 1 smoothstep · 2 smootherstep
    var fadeIntoBody: Double = 0                              // live-26 (3c): 0 today … 1 to the title block's bottom
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
        CardHeroFade.Shape(length: fadeLength, curve: fadeCurve, overshoot: CardHeroFade.bakedLight.overshoot, intoBody: fadeIntoBody)
    }

    /// ★ live-26 (1) / live-27 (0) — T's tuning (2026-10-18 (b), TF 202610180346, Ops
    /// `reference/appearance-tuning-2026-10-18-b.md`), verbatim = Reset = what ships. The hero fade over 39% of the zone,
    /// curve 0.5, carried 14% into the body. Light: L2 · F2, the shadow at 50% with radius 24, the hairline 0.5 pt @ 0.25; the
    /// Librarian on Liquid Glass (Regular, off-white #FBF9F5 at 20%, veil 30%) with a panel grade 0.10 → 0.75, the
    /// content behind dimmed 10.5%; the pills as `LibrarianGlassLook.shippedLight`. The frost numbers (tint 0.51,
    /// blur 0.58, saturation 0.4) are kept as T left them; they show only if the panel is switched to Frost.
    static let lightDefault = AppearanceTuningValues(
        palette: "L2", fieldStep: 1, shadowStrength: 0.5, shadowRadius: 24,
        hairline: true, hairlineWidth: 0.5, hairlineOpacity: 0.25,
        panel: .custom, tintOpacity: 0.51, blur: 0.58, saturation: 0.4, glassControls: true,
        dimBehind: true, dimAmount: 0.105, fadeLength: 0.25, fadeCurve: 2, fadeIntoBody: 0.15,   // live-29 (B1): T's 10-19
        panelMode: .glass, glass: LibrarianGlassLook.shippedLight.panelGlass!, panelGrade: LibrarianGlassLook.shippedLight.panelGrade,
        peekPill: .shippedLightPeek, searchPill: .shippedLightSearch, askPill: .t1018LightAskStored, askMatchesSearch: true)

    /// ★ live-26 (1) — dark: the field half a step lighter (#1A1A1A), the shadow as before, a white hairline 1 pt @ 12% on
    /// every edge; the Librarian on Liquid Glass (Regular, near-black #0A0A0A at 20%, veil 30%) with a panel grade
    /// 0.73 → 0.32, nothing dimmed; the hero fade over 35%, nearly linear (curve 0.15), carried 18% into the body. The frost numbers (tint 0.5, blur
    /// 1.53, saturation 0.4) and the dim amount (0.20, with dim off) are kept but don't render.
    static let darkDefault = AppearanceTuningValues(
        palette: "L2", fieldStep: 0.5, shadowStrength: 1, shadowRadius: 12,
        hairline: true, hairlineWidth: 1, hairlineOpacity: 0.12,
        panel: .custom, tintOpacity: 0.5, blur: 1.53, saturation: 0.4, glassControls: true,
        dimBehind: false, dimAmount: 0.20, fadeLength: 0.35, fadeCurve: 0.15, fadeIntoBody: 0,   // live-29 (B1): T's 10-19
        panelMode: .glass, glass: LibrarianGlassLook.shippedDark.panelGlass!, panelGrade: LibrarianGlassLook.shippedDark.panelGrade,
        peekPill: .shippedDarkPeek, searchPill: .shippedDarkSearch, askPill: .t1018DarkAskStored, askMatchesSearch: true)

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
        fadeLength = try c.decodeIfPresent(Double.self, forKey: .fadeLength) ?? CardHeroFade.bakedLight.length
        fadeCurve = try c.decodeIfPresent(Double.self, forKey: .fadeCurve) ?? CardHeroFade.bakedLight.curve
        fadeIntoBody = try c.decodeIfPresent(Double.self, forKey: .fadeIntoBody) ?? 0
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

/// Which card content the faces render (live-23 (4)): the faces before live-23 ("Before"), or the proposal — which
/// ships since live-26 (1).
enum CardContentMode: String, Codable, CaseIterable, Identifiable {
    case today, proposal
    var id: String { rawValue }
    var label: String { self == .today ? "Before" : "Proposal" }
}

/// Which capture controls render (live-23 (5c)): the solid pills before ("Before"), or Liquid Glass — which ships since
/// live-26 (1).
enum CaptureControlsMode: String, Codable, CaseIterable, Identifiable {
    case today, glass
    var id: String { rawValue }
    var label: String { self == .today ? "Before" : "Glass" }
}

/// live-26 (3d) — the floating "+" Capture and view switcher (bottom right): today's solid ink discs, or Liquid Glass.
enum FloatingButtonsMode: String, Codable, CaseIterable, Identifiable {
    case today, glass
    var id: String { rawValue }
    var label: String { self == .today ? "Today" : "Glass" }
}

struct AppearanceTuningState: Codable, Equatable {
    var light: AppearanceTuningValues
    var dark: AppearanceTuningValues
    var cardContent: CardContentMode = .proposal
    var captureControls: CaptureControlsMode = .glass
    /// live-26 (3d) / live-27 (0) — T chose Glass (2026-10-18 (b)): the tuner starts there and the App Store build
    /// renders it (`FloatingButtonsStyle.bakedGlass`); Today stays in the tuner.
    var floatingButtons: FloatingButtonsMode = .glass
    /// live-28 (A1) / live-29 (B1) — T picked A (10-19): the tuner starts there and the App Store build ships it.
    var lightFade: LightFadeMode = .band
    /// live-39 — the Map in dark mode: background, highlights, flat ↔ Fresnel orbs.
    var mapDark: MapDarkTuning = .today
    static let defaults = AppearanceTuningState(light: .lightDefault, dark: .darkDefault)

    init(light: AppearanceTuningValues, dark: AppearanceTuningValues, cardContent: CardContentMode = .proposal,
         captureControls: CaptureControlsMode = .glass, floatingButtons: FloatingButtonsMode = .glass) {
        self.light = light; self.dark = dark; self.cardContent = cardContent; self.captureControls = captureControls
        self.floatingButtons = floatingButtons
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        light = try c.decode(AppearanceTuningValues.self, forKey: .light)
        dark = try c.decode(AppearanceTuningValues.self, forKey: .dark)
        cardContent = try c.decodeIfPresent(CardContentMode.self, forKey: .cardContent) ?? .proposal
        captureControls = try c.decodeIfPresent(CaptureControlsMode.self, forKey: .captureControls) ?? .glass
        floatingButtons = try c.decodeIfPresent(FloatingButtonsMode.self, forKey: .floatingButtons) ?? .glass
        lightFade = try c.decodeIfPresent(LightFadeMode.self, forKey: .lightFade) ?? .band
        mapDark = (try? c.decodeIfPresent(MapDarkTuning.self, forKey: .mapDark)) ?? .today
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
        // live-26 (3c) — `-FadeRender matchFluted|max`: the hero fade at "Match fluted", or "Fade into body" at 100%.
        if let f = UserDefaults.standard.string(forKey: "FadeRender") {
            for d in [false, true] {
                update(dark: d) { v in
                    if f == "matchFluted" {
                        let m = CardHeroFade.matchFluted(dark: d)
                        v.fadeLength = m.length; v.fadeCurve = m.curve; v.fadeIntoBody = m.intoBody
                    } else if f == "max" { v.fadeIntoBody = 1 }
                }
            }
        }
        // `-RimAnimationRender shimmer|breathe` — the rim's "while answering" motion on Search + Ask (with
        // `-RenderGenerating YES`); `-RimRestRender off|static|dim` — the rim at rest on all three pills.
        if let a = UserDefaults.standard.string(forKey: "RimAnimationRender").flatMap(PillRimActive.init(rawValue:)) {
            for d in [false, true] { update(dark: d) { $0.searchPill.rim.active = a; $0.askPill.rim.active = a } }
        }
        // live-39 stills — `-MapOrbRender flat|subtle|medium|strong` and `-MapGroundRender <hex>`.
        if let o = UserDefaults.standard.string(forKey: "MapOrbRender") {
            // live-40: `glass-subtle|glass-medium|glass-strong` too.
            if o.hasPrefix("glass") {
                state.mapDark.orbLook = .glass
                if let p = GlassLook.presets.first(where: { "glass-" + $0.0.lowercased() == o }) { state.mapDark.glass = p.1 }
            } else {
                state.mapDark.orbLook = o == "flat" ? .flat : .fresnel
                if let p = FresnelLook.presets.first(where: { $0.0.lowercased() == o }) { state.mapDark.fresnel = p.1 }
            }
        }
        // live-40 stills — `-MapShrinkRender off` (uniform dots); `-MapGlassTilt x,y` (a simulated tilt, −1…1).
        if UserDefaults.standard.string(forKey: "MapShrinkRender") == "off" { state.mapDark.dotShrinkOn = false }
        if let g = UserDefaults.standard.string(forKey: "MapGroundRender") { state.mapDark.ground = TunerHSL(hex: g) }
        // `-MapOrbCycle <start-s>`: one launch steps flat → subtle → medium → strong every 4 s from <start-s> (same layout +
        // framing for the comparison stills); NSLog `[MAPCYCLE] <look>` at each step.
        // live-40: the cycle is flat → Fresnel medium → Glass subtle/medium/strong → Glass medium at two simulated tilts →
        // Glass medium with the dot shrink off.
        if let start = UserDefaults.standard.string(forKey: "MapOrbCycle").flatMap(Double.init) {
            typealias Step = (String, (inout MapDarkTuning) -> Void)
            let steps: [Step] = [
                ("flat", { $0.orbLook = .flat }),
                ("fresnel-medium", { $0.orbLook = .fresnel; $0.fresnel = .medium }),
                ("glass-subtle", { $0.orbLook = .glass; $0.glass = .subtle }),
                ("glass-medium", { $0.orbLook = .glass; $0.glass = .medium }),
                ("glass-strong", { $0.orbLook = .glass; $0.glass = .strong }),
                ("glass-medium-tilt-left-up", { $0.glass = .medium; MapGlassDebug.tilt = SIMD2(-1, 1) }),
                ("glass-medium-tilt-right-down", { _ in MapGlassDebug.tilt = SIMD2(1, -1) }),
                ("glass-medium-shrink-off", { $0.dotShrinkOn = false; MapGlassDebug.tilt = .zero }),
            ]
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(i) * 4) { [weak self] in
                    guard let self else { return }
                    step.1(&self.state.mapDark)
                    NSLog("[MAPCYCLE] %@", step.0)
                }
            }
        }
        // live-41 — `-MapGlassCycle <start-s>`: today's Glass (T's Copy values via `-MapGlassToday '<glass block JSON>'`, else
        // live-40 Medium) · arcs only · frost 0.3 / 0.6 / 0.9 · dim only · arcs + frost 0.6 · the new Medium at two simulated
        // tilts. Every 4 s, NSLog `[MAPCYCLE] <step>`.
        if let start = UserDefaults.standard.string(forKey: "MapGlassCycle").flatMap(Double.init) {
            var today = GlassLook.live40Medium
            var tTilt: Double? = nil
            if let j = UserDefaults.standard.string(forKey: "MapGlassToday"),
               let o = (try? JSONSerialization.jsonObject(with: Data(j.utf8))) as? [String: Any] {
                let md = (o["mapDark"] as? [String: Any]) ?? o           // a full Copy values, its mapDark block, or a glass block
                if md["ground"] != nil { state.mapDark.apply(exportJSON: md) }
                let gb = (md["glass"] as? [String: Any]) ?? md
                today.apply(exportJSON: gb)
                if gb["topArc"] == nil { today.topArc = 0; today.bottomArc = 0 }   // a live-40 export: no arcs yet
                tTilt = today.tiltResponse
            }
            let arcs = GlassLook.medium
            // The tilt stills: today's values as T's device will load them on this build (live-40 values migrate: tilt
            // × 0.2, edge → 0, arcs at Medium), else the new Medium.
            var migrated = today; migrated.edge = 0; migrated.tiltResponse = (tTilt ?? 0.8) * 0.2
            migrated.topArc = arcs.topArc; migrated.bottomArc = arcs.bottomArc
            let tiltBase = UserDefaults.standard.string(forKey: "MapGlassToday") != nil ? migrated : GlassLook.medium
            func with(_ f: (inout GlassLook) -> Void) -> GlassLook { var g = today; f(&g); return g }
            let steps: [(String, GlassLook, SIMD2<Float>?)] = [
                ("glass-today", today, nil),
                ("arcs-only", with { $0.edge = 0; $0.topArc = arcs.topArc; $0.bottomArc = arcs.bottomArc; $0.arcSpan = arcs.arcSpan
                                     $0.arcThickness = arcs.arcThickness; $0.arcSoftness = arcs.arcSoftness }, nil),
                ("frost-0.3", with { $0.frost = 0.3 }, nil),
                ("frost-0.6", with { $0.frost = 0.6 }, nil),
                ("frost-0.9", with { $0.frost = 0.9 }, nil),
                ("dim-only", with { $0.dim = 0.5 }, nil),
                ("arcs-frost-0.6", with { $0.edge = 0; $0.topArc = arcs.topArc; $0.bottomArc = arcs.bottomArc; $0.arcSpan = arcs.arcSpan
                                          $0.arcThickness = arcs.arcThickness; $0.arcSoftness = arcs.arcSoftness; $0.frost = 0.6 }, nil),
                ("tilt-left-up", tiltBase, SIMD2(-1, 1)),
                ("tilt-right-down", tiltBase, SIMD2(1, -1)),
            ]
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(i) * 4) { [weak self] in
                    guard let self else { return }
                    self.state.mapDark.orbLook = .glass
                    self.state.mapDark.glass = step.1
                    MapGlassDebug.tilt = step.2 ?? .zero
                    NSLog("[MAPCYCLE] %@", step.0)
                }
            }
        }
        // live-43 stills — `-MapLookCycle <start-s>`: one launch steps flat → Glass (T's values via `-MapGlassToday
        // 'json:{Copy values}'`, else Medium) → Aura → Eclipse → Outline → Wash Subtle / Medium / Strong every 4 s; `[MAPCYCLE] <look>`.
        // `-MapLookSet <look>` (flat|glass|aura|eclipse|outline|wash-subtle|wash-medium|wash-strong) holds one look.
        do {
            var glassA = GlassLook.medium
            if var j = UserDefaults.standard.string(forKey: "MapGlassToday") {
                if j.hasPrefix("json:") { j.removeFirst(5) }   // a bare {…} argument is parsed into a dictionary
                if let o = (try? JSONSerialization.jsonObject(with: Data(j.utf8))) as? [String: Any] {
                    let md = (o["mapDark"] as? [String: Any]) ?? o
                    if md["ground"] != nil { state.mapDark.apply(exportJSON: md) }
                    glassA.apply(exportJSON: (md["glass"] as? [String: Any]) ?? md)
                }
            }
            let steps: [(String, (inout MapDarkTuning) -> Void)] = [
                ("flat", { $0.orbLook = .flat }),
                ("glass", { $0.orbLook = .glass; $0.glass = glassA }),
                ("aura", { $0.orbLook = .aura; $0.aura = AuraLook() }),
                ("eclipse", { $0.orbLook = .eclipse; $0.eclipse = EclipseLook() }),
                ("outline", { $0.orbLook = .outline }),
                // live-46 / 47 — Wash on the light Map (the Pro looks draw Wash there): the study's presets
                ("wash-subtle", { $0.orbLook = .aura; $0.wash = .subtle }),
                ("wash-medium", { $0.orbLook = .aura; $0.wash = .medium }),
                ("wash-strong", { $0.orbLook = .aura; $0.wash = .strong }),
                // live-49 — Light Glass (Glass on the light Map), Riso and Gradient (both Maps), T's values
                ("lightglass", { $0.orbLook = .glass; $0.lightGlass = LightGlassLook() }),
                ("riso", { $0.orbLook = .riso; $0.riso = RisoLook() }),
                ("gradient", { $0.orbLook = .gradient; $0.gradient = GradientLook() }),
            ]
            if let one = UserDefaults.standard.string(forKey: "MapLookSet"), let st = steps.first(where: { $0.0 == one }) {
                st.1(&state.mapDark)
            }
            // live-50 stills — `-MapLightGlassJSON 'json:{…}'`: a Copy-values `lightGlass` block (+ optional "tilt" keys for
            // the shared Glass tilt: tiltLight / tiltResponse), applied after -MapLookSet.
            if var j = UserDefaults.standard.string(forKey: "MapLightGlassJSON") {
                if j.hasPrefix("json:") { j.removeFirst(5) }
                if let o = (try? JSONSerialization.jsonObject(with: Data(j.utf8))) as? [String: Any] {
                    state.mapDark.lightGlass.apply(exportJSON: o); state.mapDark.lightGlass.applyGlassExtras(o)
                    if let b = o["tiltLight"] as? Bool { state.mapDark.glass.tiltLight = b }
                    if let r = (o["tiltResponse"] as? NSNumber)?.doubleValue { state.mapDark.glass.tiltResponse = r }
                }
            }
            if let start = UserDefaults.standard.string(forKey: "MapLookCycle").flatMap(Double.init) {
                for (i, step) in steps.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(i) * 4) { [weak self] in
                        guard let self else { return }
                        step.1(&self.state.mapDark)
                        NSLog("[MAPCYCLE] %@", step.0); print("[MAPCYCLE] \(step.0)")
                    }
                }
            }
        }
        if let t = UserDefaults.standard.string(forKey: "MapGlassTilt") {
            let v = t.split(separator: ",").compactMap { Float($0) }
            if v.count == 2 { MapGlassDebug.tilt = SIMD2(v[0], v[1]) }
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
                "\"fadeLength\":\(num(v.fadeLength))", "\"fadeCurve\":\(num(v.fadeCurve))", "\"fadeIntoBody\":\(num(v.fadeIntoBody))",
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
        return "{\"airpadAppearance\":1,\"build\":\"\(build)\",\"editing\":\"\(mode)\",\"cardContent\":\"\(s.cardContent.rawValue)\",\"captureControls\":\"\(s.captureControls.rawValue)\",\"floatingButtons\":\"\(s.floatingButtons.rawValue)\",\"lightFade\":\"\(s.lightFade.rawValue)\","
            + "\"light\":\(block(s.light, dark: false)),\"dark\":\(block(s.dark, dark: true)),\"mapDark\":\(mapDarkJSON(s.mapDark))}"
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
                      "tint", "blur", "saturation", "glassControls", "fadeLength", "fadeCurve", "fadeIntoBody", "panelMode", "panelGrade",
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
        for k in ["cardContent", "captureControls", "floatingButtons", "lightFade"] { if let v = top[k] { st[k] = v } }
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
        // live-26 (1): dark's card edge is T's hairline — white, 1 pt at 12%, every edge (was the top-only 1.5 pt fade).
        row("dark-shadow-unchanged-hairline-1pt-12%-all-edges", CardSurfaceResolved.shadowRadius(dark: true) == 12
            && (isLive || CardSurfaceResolved.rimWidth(dark: true) == 1 && !CardSurfaceResolved.rimIsTopOnly(dark: true))
            && CardSurfaceResolved.bakedDarkHairline.map { close($0.opacity, 0.12) && $0.width == 1 } == true
            && hex(AppearancePalette.bgBase, dark: true) == "000000")
        let bl = LibrarianSurfaceSpec.baked(dark: false), bd = LibrarianSurfaceSpec.baked(dark: true)
        // live-26 (1): T's 2026-10-18 values (the frost numbers are kept but the panel ships on Liquid Glass).
        row("baked-librarian-light-glass-controls-dim-0.105 (frost 0.51 / 0.58 / 0.4 kept)",
            close(bl.tint, 0.51) && close(bl.blur, 0.58) && close(bl.saturation, 0.4) && bl.glassControls && close(bl.dim, 0.105)
            && !bl.wholePanelGlass, "\(bl)")
        row("baked-librarian-dark-glass-controls-no-dim (frost 0.5 / 1.53 / 0.4 kept)",
            close(bd.tint, 0.5) && close(bd.blur, 1.53) && close(bd.saturation, 0.4) && bd.glassControls && close(bd.dim, 0)
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
            && Dk.shadowRadius == 12 && Dk.hairline && Dk.hairlineWidth == 1 && close(Dk.hairlineOpacity, 0.12))
        row("tuner-librarian-defaults-are-what-ships", L.librarianSpec == bl && Dk.librarianSpec == bd,
            "light=\(L.librarianSpec) dark=\(Dk.librarianSpec)")
        row("field-steps-hit-the-render-hexes", fieldHex(withStep(L, -1), dark: false) == "E6E2DA"
            && fieldHex(withStep(L, 0), dark: false) == "EFECE6" && fieldHex(withStep(L, 1), dark: false) == "F4F2ED"
            && fieldHex(withStep(L, 2), dark: false) == "F8F6F2")
        row("hairline-off-is-the-prior-rim", resolve(.rimHex, noHairline(L), baked: "") == "FFFFFF"
            && resolve(.rimOpacity, noHairline(L), baked: 0) == 0.95 && resolve(.rimTopOnly, noHairline(L), baked: false))

        // live-23 (3) — the hero photo's fade into the card body: longer and eased, like the fluted cards' blend.
        let F = CardHeroFade.self, fb = F.bakedLight
        // live-29 (B1) — T's light fade (10-19): over 25% of the zone, curve 2, carried 15% into the body.
        row("hero-fade-baked-light-0.25-curve-2-into-0.15-past-the-edge-0.10",
            close(fb.length, 0.25) && close(fb.curve, 2) && close(fb.intoBody, 0.15) && close(fb.overshoot, 0.10), "\(fb)")
        // The easing itself, on live-23's smoothstep shape: a quarter of the way into the fade the photo is still mostly
        // there (eased, not a linear ramp).
        let e = CardHeroFade.Shape(length: 0.60, curve: 1, overshoot: 0.10)
        let fadeTop = 1 - e.length / (1 + e.overshoot)
        let quarter = F.alpha(e, at: fadeTop + (1 - fadeTop) * 0.25), half = F.alpha(e, at: fadeTop + (1 - fadeTop) * 0.5)
        row("hero-fade-is-eased", quarter > 0.8 && abs(half - 0.5) < 0.02, "quarter=\(quarter) half=\(half)")
        row("hero-fade-opaque-above-clear-at-the-end", close(F.alpha(e, at: fadeTop - 0.01), 1) && close(F.alpha(e, at: 1), 0)
            && close(F.alpha(fb, at: 1), 0))
        let st = F.stops(fb)
        row("hero-fade-stops-monotone-and-match-alpha", st.count >= 8 && zip(st, st.dropFirst()).allSatisfy { $0.location <= $1.location }
            && st.allSatisfy { s in abs(F.alpha(fb, at: Double(s.location)) - Double(UIColor(s.color).cgColor.alpha)) < 0.02 },
            "stops=\(st.count)")
        let old = F.stops(F.live22)
        row("hero-fade-live22-shape-is-the-old-mask", old.count == 3 && old[1].location == 0.78
            && close(F.alpha(F.live22, at: 0.89), 0.5))
        // live-26 (1) — T chose the proposal and glass capture controls: the tuner starts there and an App Store build (and
        // plain DEBUG) render them; "Before" stays in the tuner.
        row("card-content-and-capture-controls-start-on-proposal-and-glass",
            AppearanceTuningState.defaults.cardContent == .proposal && AppearanceTuningState.defaults.captureControls == .glass
            && CardContentMode.today.label == "Before" && CaptureControlsMode.today.label == "Before")
        row("plain-debug-renders-glass-capture-controls",
            UserDefaults.standard.string(forKey: "CaptureControls") != nil || isLive || CaptureControlsStyle.glassChosen)
        row("tuner-fade-defaults-are-baked (dark 0.35 / 0.15)", L.heroFade == fb && Dk.heroFade == CardHeroFade.bakedDark
            && close(CardHeroFade.bakedDark.length, 0.35) && close(CardHeroFade.bakedDark.curve, 0.15), "\(L.heroFade) \(Dk.heroFade)")

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
            row("live-22-stored-values-survive-new-keys", back.light.fieldStep == 2 && back.light.heroFade == CardHeroFade.bakedLight
                && back.cardContent == .proposal && back.captureControls == .glass)
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
        // live-26 (1) — what ships is T's 2026-10-18 look; outside the tuner every surface renders it.
        row("ships-T's-1018-look (glass panel, graded, Ask = Search)", L.glassLook == .shipped(dark: false)
            && Dk.glassLook == .shipped(dark: true) && LibrarianGlassLook.shippedLight.ask == LibrarianGlassLook.shippedLight.search
            && LibrarianGlassLook.shippedDark.ask == LibrarianGlassLook.shippedDark.search
            && LibrarianGlassLook.shippedLight.panelGlass != nil && LibrarianGlassLook.shippedDark.panelGlass != nil
            && PillLook.off.rim.rest == .off && !PillLook.off.grade.on
            && (isLive || LibrarianGlassLook.current(dark: false) == .shipped(dark: false) && LibrarianGlassLook.current(dark: true) == .shipped(dark: true)))
        // live-26 (1): Search + Ask — no rim at rest, the cyan shimmer only while answering; Peek a dim white rim.
        func shimmersOnlyAnswering(_ g: LibrarianGlassLook) -> Bool {
            let search = g.search.rim, peek = g.peek.rim
            let searchOK = search.rest == .off && search.active == .shimmer && search.color == .cyan
            let peekOK = peek.rest == .dim && peek.active == .none && peek.color == .white
            return searchOK && peekOK && g.peek.variant == .clear && g.search.variant == .clear
        }
        row("shipped-search-shimmers-cyan-only-while-answering, peek-dim-rim",
            shimmersOnlyAnswering(.shippedLight) && shimmersOnlyAnswering(.shippedDark))
        if var legacyGlass = (try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(
            AppearanceTuningState(light: { var x = L; x.apply(.liquidGlass); return x }(), dark: Dk))) ?? Data())) as? [String: Any],
           var lg = legacyGlass["light"] as? [String: Any] {
            for k in ["panelMode", "glass", "panelGrade", "peekPill", "searchPill", "askPill", "askMatchesSearch"] {
                lg.removeValue(forKey: k)
            }
            legacyGlass["light"] = lg
            let back = effective(stored: try? JSONSerialization.data(withJSONObject: legacyGlass), offered: true)
            row("a-stored-live-23-liquid-glass-opens-in-glass-mode", back.light.panelMode == .glass && back.dark.glassLook == Dk.glassLook
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
            && sp.panelMode == L.panelMode && sp.panelGrade == L.panelGrade, "\(spP)")
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
            return ratio(mix(back, ink, LibrarianPillChrome.clearGlyphOpacity(LibrarianPillChrome.controlsScheme(g, appearance: appearance, glassControls: true))), back)
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
            if r < 3 { glyphOK = false }   // live-26 (2): 3:1 outright (the plain light pill's × is 60% ink now)
            glyphRows.append("\(name)/\(appearance == .dark ? "dark" : "light")=\(String(format: "%.2f", r)) (plain \(String(format: "%.2f", plain)))")
        }
        row("pill-glyphs-flip-with-the-text (× send mic stop)", flipOK)
        // live-26 (2) — on the plain pill of each appearance (the solid fallback's hex), the × reaches 3:1, the
        // placeholder 4.5:1, and light's send / feather / mic are solid Klein #1B59C2 (≈ 6:1; the gradient's #00BFFF top
        // is ≈ 1.9:1). Dark keeps its gradient (it passes). The stills measure the real glass.
        var inkRows: [String] = [], inkOK = true
        for appearance in [ColorScheme.light, .dark] {
            let page = rgb(LibrarianGlassAccessibility.solidHex(dark: appearance == .dark))
            let ink = rgb(LibrarianPillChrome.inkHex(appearance))
            let x = ratio(mix(page, ink, LibrarianPillChrome.clearGlyphOpacity(appearance)), page)
            let ph = LibrarianPillChrome.placeholderOpacity(appearance).map { ratio(mix(page, ink, $0), page) } ?? 0
            let mag = ratio(mix(page, ink, LibrarianPillChrome.peekMagnifierOpacity(appearance) * 0.66), page)
            if x < 3 || ph < 4.5 || mag < 3 { inkOK = false }
            inkRows.append(String(format: "%@ ×=%.2f placeholder=%.2f magnifier=%.2f", appearance == .dark ? "dark" : "light", x, ph, mag))
        }
        row("pill-x-3:1-placeholder-4.5:1-magnifier-3:1-on-the-plain-pill", inkOK, inkRows.joined(separator: " · "))
        let klein = ratio(rgb("1B59C2"), rgb(LibrarianGlassAccessibility.solidHex(dark: false)))
        row("light-send-feather-mic-solid-klein (dark keeps the gradient)", LibrarianPillChrome.accentIsSolidKlein(.light)
            && !LibrarianPillChrome.accentIsSolidKlein(.dark) && klein >= 3, String(format: "klein on the light pill %.2f", klein))
        row("ask-clear-glyph-3:1-on-every-grade (siri · T 10-17, light + dark)", glyphOK, glyphRows.joined(separator: " "))
        // live-27 (1) — the light card faces' secondary text (source/time, counts, tags, list markers, "+N more", link
        // sites, document pages) is the ink at the swept alpha; on the plain light card body (#FBF9F5) its stills' solid
        // core (85% of full ink, the measurement's floor) reaches 4.5:1. Swept on real renders: 0.74 → 4.31, 0.76 → 4.55.
        // Dark's meta ink passes (≥ 5.5 measured) and stays the cream at each face's own opacity.
        let metaA = Double(AppearancePalette.bakedMetaLightAlpha)
        let cardBody = rgb("FBF9F5"), cardInk = rgb("232A2E")
        let metaCore = ratio(mix(cardBody, cardInk, metaA * 0.85), cardBody)
        let darkMeta = UIColor(AppearancePalette.cardMetaInk(0.68)).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let lightMeta = UIColor(AppearancePalette.cardMetaInk(0.55)).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        row("light-card-meta-ink-AA (the swept 0.76; core ≥ 4.5 on the plain body; dark unchanged)",
            close(metaA, 0.76) && metaCore >= 4.5 && close(Double(darkMeta.cgColor.alpha), 0.68)
            && (AppearancePalette.cardMetaLightAlpha == nil || close(Double(lightMeta.cgColor.alpha), metaA)),
            String(format: "alpha %.2f core %.2f · dark alpha %.2f · light (0.55 face) alpha %.2f", metaA, metaCore,
                   darkMeta.cgColor.alpha, lightMeta.cgColor.alpha))
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
        // From an all-off look (live-26: T's light look IS the Graded panel preset, so the sheet marks it at Reset).
        var bare = L; bare.panelMode = .frost; bare.panelGrade = .off; bare.editPills { $0 = .off }
        var spBare = bare; spBare.apply(.siriPill, dark: false)
        row("presets-are-marked-when-applied", spBare.matches(.siriPill, dark: false) && !spBare.matches(.gradedPanel, dark: false)
            && both.matches(.both, dark: false) && !L.matches(.siriPill, dark: false) && L.matches(.gradedPanel, dark: false))
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
        ind.editPills { $0 = .off }
        ind.peekPill.grade.on = true; ind.searchPill.variant = .clear
        row("pills-are-independent (peek · search · Ask)", ind.glassLook.peek.grade.on && !ind.glassLook.search.grade.on
            && ind.glassLook.search.variant == .clear && ind.glassLook.peek.variant == .regular && !ind.glassLook.ask.grade.on,
            "peek=\(ind.glassLook.peek.grade.on) search=\(ind.glassLook.search.grade.on)")
        var mir = Dk
        mir.editPills { $0 = .off }
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
            row("t1017-paste-is-superseded-by-1018", imp != .defaults)
        } else {
            row("t1017-paste-loads-into-peek-search-ask-alike", false, "the paste didn't import")
        }

        // live-29 (B1) — ★ T's latest paste (2026-10-19, TF 202610191107, Ops reference/appearance-tuning-2026-10-19.md,
        // verbatim) is BOTH Reset and the App Store look, light and dark, with Light fade A; Copy values at the defaults
        // reads it back, every key. It supersedes 10-18 (b) (live-27 (0)), which still loads.
        let t18b = ##"{"airpadAppearance":1,"build":"202610180346","editing":"dark","cardContent":"proposal","captureControls":"glass","floatingButtons":"glass","light":{"palette":"L2","field":"F2","fieldStep":1,"fieldHex":"#F4F2ED","shadow":0.5,"shadowAlpha":0.131,"shadowRadius":24,"hairline":true,"hairlineWidth":0.5,"hairlineOpacity":0.25,"panel":"custom","tint":0.51,"blur":0.58,"saturation":0.4,"glassControls":true,"dim":0.105,"fadeLength":0.39,"fadeCurve":0.5,"fadeIntoBody":0.14,"panelMode":"glass","glassVariant":"regular","glassTint":"offWhite","glassTintHex":"#FBF9F5","glassTintStrength":0.2,"veil":0.3,"panelGrade":{"on":true,"top":0.1,"bottom":0.75,"start":0.04,"softness":0.4,"direction":"vertical","color":"offWhite","hex":"#FBF9F5"},"peekPill":{"variant":"clear","grade":{"on":true,"top":0.9,"bottom":0.05,"start":0.3,"softness":1,"direction":"vertical","color":"offWhite","hex":"#FBF9F5"},"rim":{"rest":"dim","width":1,"brightness":0.8,"color":"white","hex":"#FFFFFF","active":"none","activeBrightness":1}},"searchPill":{"variant":"clear","grade":{"on":false,"top":0.9,"bottom":0.42,"start":0.59,"softness":0.66,"direction":"vertical","color":"offWhite","hex":"#FBF9F5"},"rim":{"rest":"off","width":1,"brightness":0.8,"color":"cyan","hex":"#00BFFF","active":"shimmer","activeBrightness":1}},"askPill":{"variant":"clear","grade":{"on":false,"top":0.9,"bottom":0.15,"start":0.75,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"rim":{"rest":"off","width":1,"brightness":0.8,"color":"white","hex":"#FFFFFF","active":"none","activeBrightness":1}},"askMatchesSearch":true},"dark":{"field":"F+0.50","fieldStep":0.5,"fieldHex":"#1A1A1A","shadow":1,"shadowAlpha":0.742,"shadowRadius":12,"hairline":true,"hairlineWidth":1,"hairlineOpacity":0.12,"panel":"custom","tint":0.5,"blur":1.53,"saturation":0.4,"glassControls":true,"dim":0,"fadeLength":0.35,"fadeCurve":0.15,"fadeIntoBody":0.18,"panelMode":"glass","glassVariant":"regular","glassTint":"nearBlack","glassTintHex":"#0A0A0A","glassTintStrength":0.2,"veil":0.3,"panelGrade":{"on":true,"top":0.73,"bottom":0.32,"start":0.04,"softness":0.22,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"peekPill":{"variant":"clear","grade":{"on":true,"top":1,"bottom":0.25,"start":0.27,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"rim":{"rest":"dim","width":0.75,"brightness":0.41,"color":"white","hex":"#FFFFFF","active":"none","activeBrightness":1}},"searchPill":{"variant":"clear","grade":{"on":true,"top":0.72,"bottom":0.44,"start":0.27,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"rim":{"rest":"off","width":0.5,"brightness":0.11,"color":"cyan","hex":"#00BFFF","active":"shimmer","activeBrightness":1}},"askPill":{"variant":"clear","grade":{"on":true,"top":1,"bottom":0.25,"start":0.27,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"rim":{"rest":"off","width":0.5,"brightness":0.11,"color":"white","hex":"#FFFFFF","active":"none","activeBrightness":1}},"askMatchesSearch":true}}"##
        let t1019 = ##"{"airpadAppearance":1,"build":"202610191107","editing":"light","cardContent":"proposal","captureControls":"glass","floatingButtons":"glass","lightFade":"band","light":{"palette":"L2","field":"F2","fieldStep":1,"fieldHex":"#F4F2ED","shadow":0.5,"shadowAlpha":0.131,"shadowRadius":24,"hairline":true,"hairlineWidth":0.5,"hairlineOpacity":0.25,"panel":"custom","tint":0.51,"blur":0.58,"saturation":0.4,"glassControls":true,"dim":0.105,"fadeLength":0.25,"fadeCurve":2,"fadeIntoBody":0.15,"panelMode":"glass","glassVariant":"regular","glassTint":"offWhite","glassTintHex":"#FBF9F5","glassTintStrength":0.2,"veil":0.3,"panelGrade":{"on":true,"top":0.1,"bottom":0.75,"start":0.04,"softness":0.4,"direction":"vertical","color":"offWhite","hex":"#FBF9F5"},"peekPill":{"variant":"clear","grade":{"on":true,"top":0.9,"bottom":0.05,"start":0.3,"softness":1,"direction":"vertical","color":"offWhite","hex":"#FBF9F5"},"rim":{"rest":"dim","width":1,"brightness":0.8,"color":"white","hex":"#FFFFFF","active":"none","activeBrightness":1}},"searchPill":{"variant":"clear","grade":{"on":false,"top":0.9,"bottom":0.42,"start":0.59,"softness":0.66,"direction":"vertical","color":"offWhite","hex":"#FBF9F5"},"rim":{"rest":"off","width":1,"brightness":0.8,"color":"cyan","hex":"#00BFFF","active":"shimmer","activeBrightness":1}},"askPill":{"variant":"clear","grade":{"on":false,"top":0.9,"bottom":0.15,"start":0.75,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"rim":{"rest":"off","width":1,"brightness":0.8,"color":"white","hex":"#FFFFFF","active":"none","activeBrightness":1}},"askMatchesSearch":true},"dark":{"field":"F+0.50","fieldStep":0.5,"fieldHex":"#1A1A1A","shadow":1,"shadowAlpha":0.742,"shadowRadius":12,"hairline":true,"hairlineWidth":1,"hairlineOpacity":0.12,"panel":"custom","tint":0.5,"blur":1.53,"saturation":0.4,"glassControls":true,"dim":0,"fadeLength":0.35,"fadeCurve":0.15,"fadeIntoBody":0,"panelMode":"glass","glassVariant":"regular","glassTint":"nearBlack","glassTintHex":"#0A0A0A","glassTintStrength":0.2,"veil":0.3,"panelGrade":{"on":true,"top":0.73,"bottom":0.32,"start":0.04,"softness":0.22,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"peekPill":{"variant":"clear","grade":{"on":true,"top":1,"bottom":0.25,"start":0.27,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"rim":{"rest":"dim","width":0.75,"brightness":0.41,"color":"white","hex":"#FFFFFF","active":"none","activeBrightness":1}},"searchPill":{"variant":"clear","grade":{"on":true,"top":0.72,"bottom":0.44,"start":0.27,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"rim":{"rest":"off","width":0.5,"brightness":0.11,"color":"cyan","hex":"#00BFFF","active":"shimmer","activeBrightness":1}},"askPill":{"variant":"clear","grade":{"on":true,"top":1,"bottom":0.25,"start":0.27,"softness":1,"direction":"vertical","color":"nearBlack","hex":"#0A0A0A"},"rim":{"rest":"off","width":0.5,"brightness":0.11,"color":"white","hex":"#FFFFFF","active":"none","activeBrightness":1}},"askMatchesSearch":true}}"##
        func keyDiff(_ a: Any?, _ b: Any?, _ path: String, _ skip: Set<String> = []) -> [String] {
            if let x = a as? [String: Any], let y = b as? [String: Any] {
                return Set(x.keys).union(y.keys).sorted().filter { !skip.contains($0) }
                    .flatMap { keyDiff(x[$0], y[$0], path.isEmpty ? $0 : "\(path).\($0)", skip) }
            }
            let sa = a.map { "\($0)" } ?? "—", sb = b.map { "\($0)" } ?? "—"
            return sa == sb ? [] : ["\(path): \(sa) ≠ \(sb)"]
        }
        func encoded(_ s: AppearanceTuningState) -> Any? {
            (try? JSONEncoder().encode(s)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        if let old = importExport(t18b) {
            // The 10-18 (b) file differs from the defaults only in what 10-19 changed: the light fade, its mode, and dark's
            // Fade into body.
            let d = keyDiff(encoded(old), encoded(.defaults), "")
            row("t1018b-paste-is-superseded-by-1019", old != .defaults && d.allSatisfy {
                $0.hasPrefix("lightFade:") || $0.hasPrefix("light.fade") || $0.hasPrefix("dark.fadeIntoBody") },
                d.joined(separator: "; "))
        } else {
            row("t1018b-paste-is-superseded-by-1019", false, "the 10-18 (b) paste didn't import")
        }
        if let imp = importExport(t1019) {
            row("reset-is-T's-1019-values", imp == AppearanceTuningState.defaults,
                keyDiff(encoded(imp), encoded(.defaults), "").joined(separator: "; "))
            for dark in [false, true] {
                let v = dark ? imp.dark : imp.light, mode = dark ? "dark" : "light"
                var off: [String] = []
                if v.glassLook != LibrarianGlassLook.shipped(dark: dark) { off.append("glass look") }
                if v.librarianSpec != LibrarianSurfaceSpec.baked(dark: dark) { off.append("panel spec \(LibrarianSurfaceSpec.baked(dark: dark))") }
                if v.heroFade != CardHeroFade.baked(dark: dark) { off.append("hero fade \(CardHeroFade.baked(dark: dark))") }
                if dark {
                    let h = CardSurfaceResolved.bakedDarkHairline
                    if v.hairline != (h != nil) || (v.hairline && (!close(h!.opacity, v.hairlineOpacity) || !close(h!.width, v.hairlineWidth))) {
                        off.append("dark hairline \(h.map { "\($0)" } ?? "none")")
                    }
                    if fieldHex(v, dark: true) != "1A1A1A" || !close(darkShadowAlpha * v.shadowStrength, 0.742) || v.shadowRadius != 12 {
                        off.append("dark field / shadow")
                    }
                } else {
                    let ok = CardSurfaceDial.allCases.allSatisfy { close(resolve($0, v, baked: D.value($0)), D.value($0)) }
                        && CardSurfaceHex.allCases.allSatisfy { resolve($0, v, baked: D.hex($0)) == D.hex($0) }
                        && CardSurfaceFlag.allCases.allSatisfy { resolve($0, v, baked: D.flag($0)) == D.flag($0) }
                        && palette(named: v.palette) == .shipped
                    if !ok { off.append("cards / field") }
                }
                row("app-store-look-is-T's-1019-\(mode)", off.isEmpty, off.joined(separator: "; "))
            }
            row("app-store-card-content-proposal-capture-controls-glass-floating-glass", CardContentPresentation.bakedProposal
                && CaptureControlsStyle.bakedGlass && FloatingButtonsStyle.bakedGlass && imp.cardContent == .proposal
                && imp.captureControls == .glass && imp.floatingButtons == .glass,
                "proposal=\(CardContentPresentation.bakedProposal) glass=\(CaptureControlsStyle.bakedGlass) floating=\(FloatingButtonsStyle.bakedGlass)")
            // Copy values at the defaults → T's file, every key (build + editing are the session's, not values).
            var back = (try? JSONSerialization.jsonObject(with: Data(exportJSON(.defaults, editing: "light", build: "202610191107").utf8)))
            // live-39's Map (dark) block postdates the 10-19 file (its own rows check it: map-dark-*).
            if var o = back as? [String: Any] { o.removeValue(forKey: "mapDark"); back = o }
            let file = try? JSONSerialization.jsonObject(with: Data(t1019.utf8))
            // T's 10-19 file has every key this build writes (lightFade included): all compared, none skipped, none added.
            let d = keyDiff(back, file, "")
            row("copy-values-at-defaults-is-T's-1019-file", d.isEmpty, d.joined(separator: "; "))
        } else {
            row("reset-is-T's-1019-values", false, "the paste didn't import")
        }

        // live-28 (A1) — light fade Today / A / B: the tuner starts on B, the App Store build stays Today until T picks;
        // Copy values carries it; A and B drop the full-width veil (above the dateline the photo is T's fade alone) and
        // protect the dateline with a band that reaches at most 8 pt above its row; B holds the photo longer, same end.
        // live-29 (B1) — T picked A (10-19): the tuner starts on A and the App Store build ships A.
        row("light-fade-A-in-tuner-and-app-store", AppearanceTuningState.defaults.lightFade == .band
            && CardHeroFade.bakedLightMode == .band && LightFadeMode.allCases.map(\.label) == ["Today", "A", "B"])
        do {
            var st = AppearanceTuningState.defaults; st.lightFade = .band
            let j = exportJSON(st, editing: "light", build: "x")
            row("copy-values-carries-lightFade", j.contains("\"lightFade\":\"band\"") && importExport(j)?.lightFade == .band, String(j.prefix(160)))
        }
        do {
            var plain = CardHeroFade.bakedLight; plain.scrim = 0
            var b = plain; b.perceptual = true
            let ys = (0...100).map { Double($0) / 100 }
            let holds = ys.allSatisfy { CardHeroFade.alpha(b, at: $0) >= CardHeroFade.alpha(plain, at: $0) - 1e-9 }
            row("B-holds-the-photo-longer-and-ends-where-T's-fade-ends", holds && CardHeroFade.alpha(b, at: 1) < 1e-6
                && CardHeroFade.alpha(b, at: CardHeroFade.fadeTop(b)) == 1)
            row("A/B-band-feather-at-most-8pt-above-the-row", CardHeroFade.bandFeather <= 8)
        }

        // live-26 (3c) — "Fade into body": 0 is the pre-live-26 mask exactly; 100% ends the photo at 1.6 zones; "Match
        // fluted" is the measured fit per appearance; the text veil only comes with the extension.
        let F0 = CardHeroFade.self
        var today0 = fb; today0.intoBody = 0
        row("fade-into-body-0-is-the-plain-mask", F0.stops(today0).map(\.location)
            == F0.stops(CardHeroFade.Shape(length: fb.length, curve: fb.curve, overshoot: fb.overshoot)).map(\.location)
            && abs(Double(F0.frameHeight(zone: 100, today0)) - 110) < 0.001)
        // live-29 (B1) — T's 10-19 values: light carries the photo 15% into the body, dark not at all (Reset + App Store).
        row("fade-into-body-defaults-are-T's (light 0.15 · dark 0)", close(L.fadeIntoBody, 0.15) && close(Dk.fadeIntoBody, 0)
            && close(CardHeroFade.baked(dark: false).intoBody, 0.15) && close(CardHeroFade.baked(dark: true).intoBody, 0),
            "tuner \(L.fadeIntoBody) / \(Dk.fadeIntoBody) · baked \(CardHeroFade.baked(dark: false).intoBody) / \(CardHeroFade.baked(dark: true).intoBody)")
        var full = fb; full.intoBody = 1
        row("fade-into-body-100%-ends-the-photo-at-1.6-zones", abs(Double(F0.frameHeight(zone: 100, full)) - 160) < 0.01
            && close(F0.alpha(full, at: 1), 0) && F0.alpha(full, at: 1.05 / 1.6) > F0.alpha(today0, at: min(1.05 / 1.1, 1)),
            "\(F0.frameHeight(zone: 100, full))")
        let mfD = F0.matchFluted(dark: true), mfL = F0.matchFluted(dark: false)
        row("match-fluted-is-the-measured-fit (dark 0.80/1.9/0.50 · light 0.80/0.8/1.00)",
            close(mfD.length, 0.80) && close(mfD.curve, 1.9) && close(mfD.intoBody, 0.50)
            && close(mfL.length, 0.80) && close(mfL.curve, 0.8) && close(mfL.intoBody, 1.00))
        var veiled = full; veiled.scrim = 0.5
        let curL = CardHeroFade.current(dark: false), curD = CardHeroFade.current(dark: true)
        // live-29 (B1) — light ships A (10-19): A / B carry no full-width veil (live-28 (A1)); Today keeps it.
        let lightVeil = CardHeroFade.lightMode == .today ? CardHeroFade.veil(intoBody: curL.intoBody, dark: false) : 0
        row("the-text-veil-only-with-the-extension (light A: none)", close(curL.scrim, lightVeil)
            && close(curD.scrim, CardHeroFade.veil(intoBody: curD.intoBody, dark: true))
            && CardHeroFade.veil(intoBody: 0, dark: false) == 0 && CardHeroFade.veil(intoBody: 0, dark: true) == 0
            && close(F0.alpha(veiled, at: 1.2 / 1.6) / max(F0.alpha(full, at: 1.2 / 1.6), 1e-9), 0.5)
            && close(F0.alpha(veiled, at: 0.5 / 1.6), F0.alpha(full, at: 0.5 / 1.6)))
        // live-27 (1) — the light veil re-fit with the AA meta ink, on the stills (Ops design-refs/live27-*/fade-veil.md): at
        // T's 0.14 the least is 0.9 (0.8 leaves the landscape dateline at 4.49); at Match fluted and 100% it's still 1.0
        // (0.9 → 4.38 / 4.29). So light's veil comes in fully by 10% of the extension; dark scales with it as before
        // (0.45 at 100%; T's 0.18 → 0.08 passes, ≥ 6.2).
        row("light-veil-full-from-10%-(T's 0.14 → 1.0) dark-scales (0.18 → 0.08)",
            close(CardHeroFade.veil(intoBody: 0.14, dark: false), 1) && close(CardHeroFade.veil(intoBody: 1, dark: false), 1)
            && close(CardHeroFade.veil(intoBody: 0.05, dark: false), 0.5) && close(CardHeroFade.veil(intoBody: 0.18, dark: true), 0.081)
            && close(CardHeroFade.veil(intoBody: 1, dark: true), 0.45),
            String(format: "light 0.14 → %.2f · dark 0.18 → %.3f", CardHeroFade.veil(intoBody: 0.14, dark: false),
                   CardHeroFade.veil(intoBody: 0.18, dark: true)))
        var withFade = AppearanceTuningState.defaults; withFade.light.fadeIntoBody = 0.37; withFade.floatingButtons = .today
        let fadeJSON = exportJSON(withFade, editing: "light", build: "0")
        let fadeBack = importExport(fadeJSON)
        row("copy-values-carries-fadeIntoBody-and-floatingButtons", fadeJSON.contains("\"fadeIntoBody\":0.37")
            && fadeJSON.contains("\"floatingButtons\":\"today\"") && fadeBack?.light.fadeIntoBody == 0.37 && fadeBack?.floatingButtons == .today)
        // live-27 (0) — the floating buttons: T chose Glass (10-18 (b)), in the tuner and the App Store build; Today stays
        // in the tuner; Reduce Transparency / Increase Contrast keep the solid discs.
        row("floating-buttons-glass-in-tuner-and-app-store", AppearanceTuningState.defaults.floatingButtons == .glass
            && FloatingButtonsStyle.bakedGlass && FloatingButtonsMode.today.label == "Today")
        // live-27 (4d) — T (device, TF 202610180346): Reduce Transparency in LIGHT turned the open search pill and the Ask
        // bar solid dark charcoal under dark ink. Under RT every pill is a solid fill on the side its text resolves to, at
        // T's baked values and at each preset, light and dark: text ≥ 4.5, glyphs (× at its ink opacity) ≥ 3.
        var rtRows: [String] = [], rtOK = true
        for appearance in [ColorScheme.light, .dark] {
            let dk = appearance == .dark
            var looks: [(String, AppearanceTuningValues)] = [("baked", dk ? Dk : L)]
            for p in LibrarianGlassPreset.allCases { var v = dk ? Dk : L; v.apply(p, dark: dk); looks.append((p.rawValue, v)) }
            for (name, v) in looks {
                for (pill, look) in [("peek", v.peekPill), ("search", v.searchPill), ("ask", v.askLook)] {
                    let scheme = LibrarianPillChrome.textScheme(look.grade, appearance: appearance, glassControls: true)
                    let ink = rgb(LibrarianPillChrome.inkHex(scheme))
                    guard let fillHex = LibrarianGlassAccessibility.solidPillHex(look, appearance: appearance) else {
                        rtOK = false; rtRows.append("\(dk ? "dark" : "light")/\(name)/\(pill)=system glass"); continue
                    }
                    let fill = rgb(fillHex.replacingOccurrences(of: "#", with: ""))
                    let text = ratio(ink, fill), glyph = ratio(mix(fill, ink, LibrarianPillChrome.clearGlyphOpacity(scheme)), fill)
                    if text < 4.5 || glyph < 3 {
                        rtOK = false; rtRows.append(String(format: "%@/%@/%@ text %.2f glyph %.2f", dk ? "dark" : "light", name, pill, text, glyph))
                    }
                }
            }
        }
        row("reduce-transparency-every-pill-solid-and-readable (baked + presets, light + dark)", rtOK, rtRows.joined(separator: " · "))
        // Increase Contrast too: the system's high-contrast Clear glass is dark charcoal in light as well (stills, (4d)).
        row("increase-contrast-pills-solid-too", LibrarianGlassAccessibility.pillIsSolid(reduceTransparency: false, increaseContrast: true)
            && LibrarianGlassAccessibility.pillIsSolid(reduceTransparency: true, increaseContrast: false)
            && !LibrarianGlassAccessibility.pillIsSolid(reduceTransparency: false, increaseContrast: false))
        // live-28 (4) — Increase Contrast only: the light open-search magnifier takes the ink (≥ 3:1 on the solid pill).
        do {
            let fill = rgb(LibrarianGlassAccessibility.solidHex(dark: false))
            let ink = ratio(rgb(LibrarianPillChrome.inkHex(.light)), fill), mango = ratio(rgb("E8820A"), fill)
            row("increase-contrast-light-magnifier-is-ink", LibrarianPillChrome.searchMagnifierUsesInk(.light, increaseContrast: true)
                && ink >= 3 && !LibrarianPillChrome.searchMagnifierUsesInk(.light, increaseContrast: false)
                && !LibrarianPillChrome.searchMagnifierUsesInk(.dark, increaseContrast: true)
                && !LibrarianPillChrome.searchMagnifierUsesInk(.dark, increaseContrast: false),
                String(format: "ink %.2f · Mango %.2f on #FBF9F5", ink, mango))
        }
        row("floating-buttons-solid-under-reduce-transparency-and-increase-contrast",
            FloatingButtonsStyle.isOn(chosen: true, reduceTransparency: false, increaseContrast: false)
            && !FloatingButtonsStyle.isOn(chosen: true, reduceTransparency: true, increaseContrast: false)
            && !FloatingButtonsStyle.isOn(chosen: true, reduceTransparency: false, increaseContrast: true)
            && !FloatingButtonsStyle.isOn(chosen: false, reduceTransparency: false, increaseContrast: false))

        // Export — at the defaults, Copy values reads back T's reference JSON verbatim (with this build's number).
        let json = exportJSON(.defaults, editing: "light", build: "202610161756")
        let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        row("copy-values-is-json-with-both-modes", parsed?["dark"] != nil && parsed?["light"] != nil, json)
        // (live-23's 2026-10-16 reference row is superseded by copy-values-at-defaults-is-T's-1018-file above.)
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
        for (name, ok, detail) in mapDarkSelfTestRows() { row(name, ok, detail) }
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

// MARK: - live-39 — the Map in dark mode (background, highlights, Fresnel orbs)

#if DEBUG || TESTFLIGHT

/// A tuner colour held as HSL (so a hue survives a trip through grey) with its 8-bit hex derived. Defaults are built
/// from today's hex and round-trip to it exactly.
struct TunerHSL: Codable, Equatable {
    var h: Double   // 0…360
    var s: Double   // 0…1
    var l: Double   // 0…1

    init(h: Double, s: Double, l: Double) { self.h = h; self.s = s; self.l = l }
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        l = (mx + mn) / 2
        s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        var hue: Double = 0
        if d != 0 {
            if mx == r { hue = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { hue = (b - r) / d + 2 }
            else { hue = (r - g) / d + 4 }
        }
        hue *= 60; if hue < 0 { hue += 360 }
        h = hue
    }
    /// 0…1 sRGB.
    var rgb: (r: Double, g: Double, b: Double) {
        let c = (1 - abs(2 * l - 1)) * s, hp = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        func q(_ v: Double) -> Double { (min(max(v + m, 0), 1) * 255).rounded() / 255 }   // snapped to 8 bits = the hex
        return (q(r1), q(g1), q(b1))
    }
    var hex: String {
        let c = rgb
        return String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }
    var uiColor: UIColor { let c = rgb; return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1) }
    var color: Color { Color(uiColor) }
    var simd: SIMD3<Float> { let c = rgb; return SIMD3(Float(c.r), Float(c.g), Float(c.b)) }
}

/// The Map's orb look: today's flat emissive fill, a dark bubble lit at its rim (Fresnel), a glass bead over the real
/// background (Glass), a grainy multi-hue gradient (Aura), a glow rising from a dark top (Eclipse), or a ring in the
/// territory colour over a faint fill (Outline). Fresnel and Glass are dark-Map only (the light Map draws Flat for them);
/// Outline shows on both grounds; the Pro looks Aura and Eclipse draw Wash on the light Map (live-46 / live-47).
enum MapOrbLook: String, Codable, CaseIterable, Identifiable {
    case flat, fresnel, glass, aura, eclipse, outline, riso, gradient
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flat: "Flat"; case .fresnel: "Fresnel"; case .glass: "Glass"; case .aura: "Aura"; case .eclipse: "Eclipse"
        case .outline: "Outline"; case .riso: "Riso"; case .gradient: "Gradient"
        }
    }
    /// Looks that also draw on the light Map (live-49: Riso and Gradient draw themselves on both).
    var bothGrounds: Bool { self == .outline || self == .riso || self == .gradient }
    /// live-49 — Glass draws Light Glass on the light Map (its pair).
    var drawsLightGlassOnLight: Bool { self == .glass }
    /// live-47 — the Pro looks Aura and Eclipse both draw Wash on the light Map.
    var drawsWashOnLight: Bool { self == .aura || self == .eclipse }
    /// live-47 — the tuner's pickers: dark Map = Flat · Glass · Aura · Eclipse · Outline (Fresnel still decodes).
    static let darkPicker: [MapOrbLook] = [.flat, .glass, .aura, .eclipse, .riso, .gradient, .outline]
}

/// The study's light-on-dark looks (Ops/reference/aura-orb-study.html v5) — Aura and Eclipse share the study's seven
/// controls (the study's KEYS: spread, warp, soft, reach, rim, fringe, grain) and its bound.
protocol StudyOrbLook: Codable, Equatable {
    var spread: Double { get set }
    var warp: Double { get set }
    var softness: Double { get set }
    var haloReach: Double { get set }
    var rim: Double { get set }
    var fringe: Double { get set }
    var grain: Double { get set }
    var drift: Bool { get set }
    /// The study's bound for this look, orb radii (the shader draws nothing beyond; the sprite's size).
    var spriteExtent: Double { get }
}
extension StudyOrbLook {
    /// The study's bound for Aura / Eclipse: 1 + max(reach, 0.02)·3.2 + softness orb radii (the shader draws nothing beyond).
    var spriteExtent: Double { 1 + max(haloReach, 0.02) * 3.2 + softness }
    /// Apply a Copy-values block; unknown keys (live-45's softnessFloor / grainSize / contrast / hueSpread) are ignored.
    mutating func apply(exportJSON o: [String: Any]) {
        func d(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        if let v = d("spread") { spread = v }; if let v = d("warp") { warp = v }; if let v = d("softness") { softness = v }
        if let v = d("haloReach") { haloReach = v }; if let v = d("rim") { rim = v }; if let v = d("fringe") { fringe = v }
        if let v = d("grain") { grain = v }; if let b = o["drift"] as? Bool { drift = b }
    }
}

/// live-43 — the Aura look. live-47: an EXACT port of the study's aura branch (v5), like Wash — per orb its territory's
/// study palette (one of 12), a seeded 3-stop ramp warped by two fbm fields, a rim tint, a smoothstep edge (softness = a
/// fraction of the radius), a chromatic rim, an optional halo and the study's 1 pt grain. live-45's Contrast, softness
/// floor, grain size and territory-derived stops are gone (T: the re-interpretation read as messy, fuzzy clusters). Old
/// saved values still load; their extra keys are ignored.
struct AuraLook: StudyOrbLook {
    // T's values (study v4 on iPhone, 2026-10-27, Ops/reference/orb-study-values-2026-10-27.json) = the study's Medium.
    var spread = 0.82
    var warp = 1.36
    var softness = 0.03         // edge softness (fraction of the orb's radius)
    var haloReach = 0.0
    var rim = 0.45
    var fringe = 0.35           // chromatic fringe (the edge at three radii, red outermost)
    var grain = 1.0
    var drift = false           // slow gradient flow; on → the Map renders at 30 fps

    static let subtle = AuraLook(0.7, 0.6, 0.02, 0, 0.3, 0.2, 0.6)
    static let medium = AuraLook()
    static let strong = AuraLook(1.1, 1.5, 0.06, 0.15, 0.7, 0.7, 1)
    static let presets: [(String, AuraLook)] = [("Subtle", .subtle), ("Medium", .medium), ("Strong", .strong)]

    init() {}
    init(_ spread: Double, _ warp: Double, _ softness: Double, _ haloReach: Double, _ rim: Double, _ fringe: Double, _ grain: Double) {
        self.spread = spread; self.warp = warp; self.softness = softness; self.haloReach = haloReach; self.rim = rim
        self.fringe = fringe; self.grain = grain
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AuraLook()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        spread = v(.spread, d.spread); warp = v(.warp, d.warp); softness = v(.softness, d.softness)
        haloReach = v(.haloReach, d.haloReach); rim = v(.rim, d.rim); fringe = v(.fringe, d.fringe)
        grain = v(.grain, d.grain); drift = v(.drift, d.drift)
    }
}

/// live-47 — Eclipse returns (dark Map), an exact port of the study's REWORKED eclipse branch (v5): the glow rises
/// gradually from a dark top (no hard line), the middle of each orb sits on its deepest colour so white titles read; a
/// rim light, a crescent (an offset disc), the chromatic rim and a small halo in the rim colour. Each orb's palette stops
/// run sorted dark → light by luma. Title ink is always light.
struct EclipseLook: StudyOrbLook {
    // T's values (2026-10-27).
    var spread = 0.87
    var warp = 0.76
    var softness = 0.01
    var haloReach = 0.12
    var rim = 0.56
    var fringe = 0.39
    var grain = 0.8
    var drift = false

    static let subtle = EclipseLook(0.85, 0.6, 0.03, 0.06, 0.35, 0.3, 0.6)
    static let medium = EclipseLook(0.95, 0.9, 0.04, 0.12, 0.5, 0.45, 0.8)
    static let strong = EclipseLook(1.1, 1.3, 0.07, 0.3, 0.75, 0.8, 1)
    static let presets: [(String, EclipseLook)] = [("Subtle", .subtle), ("Medium", .medium), ("Strong", .strong)]

    init() {}
    init(_ spread: Double, _ warp: Double, _ softness: Double, _ haloReach: Double, _ rim: Double, _ fringe: Double, _ grain: Double) {
        self.spread = spread; self.warp = warp; self.softness = softness; self.haloReach = haloReach; self.rim = rim
        self.fringe = fringe; self.grain = grain
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EclipseLook()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        spread = v(.spread, d.spread); warp = v(.warp, d.warp); softness = v(.softness, d.softness)
        haloReach = v(.haloReach, d.haloReach); rim = v(.rim, d.rim); fringe = v(.fringe, d.fringe)
        grain = v(.grain, d.grain); drift = v(.drift, d.drift)
    }
}

/// live-49 — the study's v7 looks (Ops/reference/aura-orb-study.html v7), ported exactly like Aura: Light Glass (the
/// `glass` branch: the light-Map pair of Glass — frosted body, tinted edge line, white highlight, a soft shadow), Riso and
/// Gradient (the `cheap` branch: no fbm; both Maps). They share the study's seven keys; the struct fields keep Aura's
/// names (spread · warp · softness · haloReach · rim · fringe · grain = the study's spread · warp · soft · reach · rim ·
/// fringe · grain) and the tuner shows the study's labels. Defaults = T's values (Ops/reference/orb-study-values-2026-10-27b.json),
/// presets = the study's Subtle / Medium / Strong.
struct LightGlassLook: StudyOrbLook {
    var spread = 0.68           // Tint
    var warp = 0.6              // Frost
    var softness = 0.01         // Edge softness
    var haloReach = 0.36        // Shadow
    var rim = 0.7               // Highlight
    var fringe = 0.41           // Edge line
    var grain = 0.0
    var drift = false
    // live-50 — dark Glass's controls, each defaulting to the value that changes nothing (Light Glass = the study's until T
    // moves one). Rim light = white arcs screened over the rim (light catching the edge, never a dark line); the tilt
    // settings are SHARED with dark Glass (GlassLook.tiltLight / tiltResponse / tiltSmoothing), so one switch serves both.
    var topArc = 0.0
    var bottomArc = 0.0
    var arcSpan = 120.0             // degrees each arc covers
    var arcThickness = 0.07         // fraction of the radius
    var arcSoftness = 0.6
    var dispersion = 0.0            // Colour fringe: the edge line + arcs at three radii, one per channel
    var highlightSize = 1 / 70.0.squareRoot()   // the study's glint width (exp(−d²·70)), orb radii
    var innerShadow = 0.0
    var label = TunerHSL(hex: "1B1A20")           // the study's dark ink
    /// The study's glass bound: 1.45 + shadow·0.4.
    var spriteExtent: Double { 1.45 + haloReach * 0.4 }
    static let presets: [(String, LightGlassLook)] = [("Subtle", .init(0.35, 0.45, 0.015, 0.4, 0.5, 0.4, 0.2)),
                                                      ("Medium", .init(0.55, 0.6, 0.02, 0.6, 0.7, 0.6, 0.3)),
                                                      ("Strong", .init(0.8, 0.8, 0.03, 0.9, 0.9, 0.85, 0.45))]
    static let labels = ["Tint", "Frost", "Edge softness", "Shadow", "Highlight", "Edge line", "Grain"]
    init() {}
    init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double, _ g: Double) {
        spread = a; warp = b; softness = c; haloReach = d; rim = e; fringe = f; grain = g
    }
    init(from decoder: Decoder) throws {
        self = try StudyLookDecode.decode(decoder, LightGlassLook())
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        topArc = v(.topArc, topArc); bottomArc = v(.bottomArc, bottomArc); arcSpan = v(.arcSpan, arcSpan)
        arcThickness = v(.arcThickness, arcThickness); arcSoftness = v(.arcSoftness, arcSoftness)
        dispersion = v(.dispersion, dispersion); highlightSize = v(.highlightSize, highlightSize)
        innerShadow = v(.innerShadow, innerShadow); label = v(.label, label)
    }
    /// live-50 — the Copy values block: the study's seven + dark Glass's controls.
    var exportJSON: String {
        func n(_ x: Double) -> String { "\(x)" }   // the shortest text that reads back as the same Double (0.68 → "0.68")
        return "{\"spread\":\(n(spread)),\"warp\":\(n(warp)),\"softness\":\(n(softness)),\"haloReach\":\(n(haloReach)),"
            + "\"rim\":\(n(rim)),\"fringe\":\(n(fringe)),\"grain\":\(n(grain)),\"topArc\":\(n(topArc)),\"bottomArc\":\(n(bottomArc)),"
            + "\"arcSpan\":\(n(arcSpan)),\"arcThickness\":\(n(arcThickness)),\"arcSoftness\":\(n(arcSoftness)),"
            + "\"dispersion\":\(n(dispersion)),\"highlightSize\":\(n(highlightSize)),\"innerShadow\":\(n(innerShadow)),"
            + "\"label\":\"#\(label.hex)\"}"
    }
    mutating func applyGlassExtras(_ o: [String: Any]) {
        func d(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        if let v = d("topArc") { topArc = v }; if let v = d("bottomArc") { bottomArc = v }; if let v = d("arcSpan") { arcSpan = v }
        if let v = d("arcThickness") { arcThickness = v }; if let v = d("arcSoftness") { arcSoftness = v }
        if let v = d("dispersion") { dispersion = v }; if let v = d("highlightSize") { highlightSize = v }
        if let v = d("innerShadow") { innerShadow = v }
        if let h = o["label"] as? String { label = TunerHSL(hex: h.replacingOccurrences(of: "#", with: "")) }
    }
}
struct RisoLook: StudyOrbLook {
    var spread = 0.72           // Shape
    var warp = 0.95             // Swirl
    var softness = 0.01
    var haloReach = 0.42        // Second ink
    var rim = 0.84              // Ink density
    var fringe = 0.71           // Misregistration
    var grain = 0.23            // Speckle
    var drift = false
    /// The study's cheap bound: 1.04 + softness·1.2 + fringe·0.05.
    var spriteExtent: Double { 1.04 + softness * 1.2 + fringe * 0.05 }
    static let presets: [(String, RisoLook)] = [("Subtle", .init(0.8, 0.3, 0.01, 0.4, 0.75, 0.25, 0.3)),
                                                ("Medium", .init(1, 0.6, 0.015, 0.65, 0.85, 0.5, 0.5)),
                                                ("Strong", .init(1.2, 1, 0.02, 0.9, 0.95, 0.85, 0.75))]
    static let labels = ["Shape", "Swirl", "Edge softness", "Second ink", "Ink density", "Misregistration", "Speckle"]
    init() {}
    init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double, _ g: Double) {
        spread = a; warp = b; softness = c; haloReach = d; rim = e; fringe = f; grain = g
    }
    init(from decoder: Decoder) throws { self = try StudyLookDecode.decode(decoder, RisoLook()) }
}
struct GradientLook: StudyOrbLook {
    var spread = 1.01
    var warp = 0.96             // Swirl
    var softness = 0.01
    var haloReach = 0.4         // Sheen
    var rim = 0.52              // Shading
    var fringe = 0.1            // Rim line
    var grain = 0.0
    var drift = false
    var spriteExtent: Double { 1.04 + softness * 1.2 + fringe * 0.05 }
    static let presets: [(String, GradientLook)] = [("Subtle", .init(0.7, 0.2, 0.01, 0.2, 0.3, 0.2, 0)),
                                                    ("Medium", .init(1, 0.45, 0.012, 0.4, 0.45, 0.35, 0)),
                                                    ("Strong", .init(1.3, 0.8, 0.02, 0.7, 0.7, 0.6, 0.15))]
    static let labels = ["Gradient spread", "Swirl", "Edge softness", "Sheen", "Shading", "Rim line", "Grain"]
    init() {}
    init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double, _ g: Double) {
        spread = a; warp = b; softness = c; haloReach = d; rim = e; fringe = f; grain = g
    }
    init(from decoder: Decoder) throws { self = try StudyLookDecode.decode(decoder, GradientLook()) }
}
/// Every key optional: a missing one keeps the look's default.
enum StudyLookDecode {
    enum K: String, CodingKey { case spread, warp, softness, haloReach, rim, fringe, grain, drift }
    static func decode<L: StudyOrbLook>(_ decoder: Decoder, _ d: L) throws -> L {
        let c = try decoder.container(keyedBy: K.self)
        func v<T: Decodable>(_ k: K, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        var o = d
        o.spread = v(.spread, d.spread); o.warp = v(.warp, d.warp); o.softness = v(.softness, d.softness)
        o.haloReach = v(.haloReach, d.haloReach); o.rim = v(.rim, d.rim); o.fringe = v(.fringe, d.fringe)
        o.grain = v(.grain, d.grain); o.drift = v(.drift, d.drift)
        return o
    }
}

/// live-47 — the study's 12 territory palettes (its `okLin` / `ok` / `hueToward` + the T12 loop, the same Double maths
/// as the page's JavaScript, so the same floats): family i at OKLCH hue 15 + 30·i; dark (L .38, C .17, hue pulled 35%
/// toward 290°), mid (.62, .22, h), light (.89, .08, hue pulled 30% toward 95°); even i = [dark, mid, light], odd =
/// [mid, light, dark]; rim (.78, .15, h + 150); chroma stepped down by 0.004 until in the sRGB gamut. Used by Aura,
/// Eclipse and Wash. Hex table: Ops/reference/orb-study-families-2026-10-27.md.
enum OrbStudyPalettes {
    struct Family { let name: String; let hue: Double; let a, b, c, r: SIMD3<Float> }
    static let names = ["Rose", "Coral", "Amber", "Saffron", "Lime", "Fern", "Jade", "Lagoon", "Cobalt", "Indigo", "Violet", "Orchid"]

    static func okLin(_ L: Double, _ C: Double, _ h: Double) -> [Double] {
        let a = C * cos(h * Double.pi / 180), b = C * sin(h * Double.pi / 180)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3), m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
    }
    static func enc(_ x0: Double) -> Double { let x = min(1, max(0, x0)); return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    static func ok(_ L: Double, _ C: Double, _ h: Double) -> SIMD3<Float> {
        var c = C
        while c > 0 {
            let r = okLin(L, c, h)
            if r.allSatisfy({ $0 >= -0.0005 && $0 <= 1.0005 }) { return SIMD3(Float(enc(r[0])), Float(enc(r[1])), Float(enc(r[2]))) }
            c -= 0.004
        }
        let r = okLin(L, 0, h); return SIMD3(Float(enc(r[0])), Float(enc(r[1])), Float(enc(r[2])))
    }
    /// JS `((t-h+540)%360)-180`: % keeps the dividend's sign, as truncatingRemainder does.
    static func hueToward(_ h: Double, _ t: Double, _ k: Double) -> Double {
        let d = (t - h + 540).truncatingRemainder(dividingBy: 360) - 180
        return (h + d * k + 360).truncatingRemainder(dividingBy: 360)
    }
    static let families: [Family] = names.enumerated().map { i, name in
        let h = 15 + 30 * Double(i)
        let dark = ok(0.38, 0.17, hueToward(h, 290, 0.35)), mid = ok(0.62, 0.22, h), light = ok(0.89, 0.08, hueToward(h, 95, 0.3))
        let st = i % 2 == 0 ? [dark, mid, light] : [mid, light, dark]
        return Family(name: name, hue: h, a: st[0], b: st[1], c: st[2], r: ok(0.78, 0.15, (h + 150).truncatingRemainder(dividingBy: 360)))
    }
    static func hex(_ c: SIMD3<Float>) -> String {
        String(format: "%02X%02X%02X", Int((c.x * 255).rounded()), Int((c.y * 255).rounded()), Int((c.z * 255).rounded()))
    }
    /// The study's luma (on the encoded sRGB values).
    static func lum(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    static func hueDist(_ x: Double, _ y: Double) -> Double {
        let d = abs((x - y).truncatingRemainder(dividingBy: 360)); return min(d, 360 - d)
    }
    /// Territory → family, ONE-TO-ONE by hue: territories sorted by hue are laid onto the families (sorted by hue) in
    /// the same circular order, choosing the placement with the least total hue distance. 12 territories = the best of
    /// the 12 rotations; fewer = the best order-keeping placement (a DP per starting family); more than 12 = the first
    /// 12 placed that way, the rest take their nearest family (collisions reported by the caller).
    static func assign(territoryHues: [Int: Double]) -> [Int: Int] {
        let terr = territoryHues.sorted { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }
        let n = terr.count, F = families.count
        guard n > 0 else { return [:] }
        let k = min(n, F)
        var best: (cost: Double, map: [Int])? = nil
        for start in 0..<F {
            // DP over territories 0..<k placed at increasing family offsets 0..<F from `start`.
            let inf = Double.infinity
            var dp = Array(repeating: Array(repeating: inf, count: F), count: k)
            var from = Array(repeating: Array(repeating: -1, count: F), count: k)
            for j in 0..<F where j <= F - k {
                dp[0][j] = hueDist(terr[0].value, families[(start + j) % F].hue)
            }
            if k > 1 {
                for i in 1..<k {
                    var runMin = inf, runArg = -1
                    for j in i..<F {
                        if dp[i - 1][j - 1] < runMin { runMin = dp[i - 1][j - 1]; runArg = j - 1 }
                        if runMin < inf, j <= F - k + i {
                            dp[i][j] = runMin + hueDist(terr[i].value, families[(start + j) % F].hue); from[i][j] = runArg
                        }
                    }
                }
            }
            guard let endJ = (0..<F).min(by: { dp[k - 1][$0] < dp[k - 1][$1] }), dp[k - 1][endJ] < inf else { continue }
            var map = Array(repeating: 0, count: k); var j = endJ
            for i in stride(from: k - 1, through: 0, by: -1) { map[i] = (start + j) % F; j = from[i][j] }
            if best.map({ dp[k - 1][endJ] < $0.cost - 1e-12 }) ?? true { best = (dp[k - 1][endJ], map) }
        }
        var out: [Int: Int] = [:]
        for i in 0..<k { out[terr[i].key] = best?.map[i] ?? 0 }
        for i in k..<n { out[terr[i].key] = nearest(hue: terr[i].value) }
        return out
    }
    static func nearest(hue: Double) -> Int { (0..<families.count).min { hueDist(hue, families[$0].hue) < hueDist(hue, families[$1].hue) }! }
}

/// live-46 — the Wash look for the LIGHT Map (port of the study's `wash` branch, Ops/reference/aura-orb-study.html v2; T:
/// "I like this a lot … as similar as possible"). Pigment on paper: the study's family palettes (by territory hue) lifted
/// toward white, multiplied into the ground (SKBlendMode.multiply), with ink bleed, edge pooling, riso misregistration
/// and granulation; the paper fibres + grain live on the ground (the grid shader). The Pro "Aura" look = Aura on the
/// dark Map + Wash on the light Map. Slider names follow the study's Wash labels.
struct WashLook: Codable, Equatable {
    var spread = 1.0            // Gradient spread
    var warp = 0.9              // Warp
    var softness = 0.05         // Edge softness (orb radii)
    var bleed = 0.6             // Bleed (the study's `reach` slot)
    var pooling = 0.55          // Edge pooling (`rim`)
    var misregistration = 0.6   // Misregistration (`fringe`)
    var paper = 0.6             // Paper grain (`grain`): fibres + grain on the ground, granulation in the orb

    static let medium = WashLook()
    static let subtle = WashLook(spread: 0.8, warp: 0.5, softness: 0.03, bleed: 0.3, pooling: 0.3, misregistration: 0.3, paper: 0.4)
    static let strong = WashLook(spread: 1.2, warp: 1.3, softness: 0.08, bleed: 1.0, pooling: 0.85, misregistration: 1.0, paper: 0.85)
    static let presets: [(String, WashLook)] = [("Subtle", .subtle), ("Medium", .medium), ("Strong", .strong)]

    init() {}
    init(spread: Double, warp: Double, softness: Double, bleed: Double, pooling: Double, misregistration: Double, paper: Double) {
        self.spread = spread; self.warp = warp; self.softness = softness; self.bleed = bleed; self.pooling = pooling
        self.misregistration = misregistration; self.paper = paper
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WashLook()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        spread = v(.spread, d.spread); warp = v(.warp, d.warp); softness = v(.softness, d.softness); bleed = v(.bleed, d.bleed)
        pooling = v(.pooling, d.pooling); misregistration = v(.misregistration, d.misregistration); paper = v(.paper, d.paper)
    }

    /// The study's bound: 1.2 + softness + misregistration·0.05 + bleed·0.1 orb radii (no halo).
    var spriteExtent: Double { 1.2 + softness + misregistration * 0.05 + bleed * 0.1 }

    mutating func apply(exportJSON o: [String: Any]) {
        func d(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        if let v = d("spread") { spread = v }; if let v = d("warp") { warp = v }; if let v = d("softness") { softness = v }
        if let v = d("bleed") { bleed = v }; if let v = d("pooling") { pooling = v }
        if let v = d("misregistration") { misregistration = v }; if let v = d("paper") { paper = v }
    }
}

/// live-43-A — the Outline look: each orb a ring in its territory colour over a very faint fill of the same colour. No
/// halo, no gradient. A branch of the shared orb shader (u_fr_on 3, levers in u_gl_look col 0 → no new binding).
struct OutlineLook: Codable, Equatable {
    var ringWidth = 2.0          // pt on screen, constant across zoom (doubles on the focused / selected orb)
    var ringOpacityDark = 0.85
    var ringOpacityLight = 1.0
    var fillOpacity = 0.06       // 0 … 0.3

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OutlineLook()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        ringWidth = v(.ringWidth, d.ringWidth); ringOpacityDark = v(.ringOpacityDark, d.ringOpacityDark)
        ringOpacityLight = v(.ringOpacityLight, d.ringOpacityLight); fillOpacity = v(.fillOpacity, d.fillOpacity)
    }
    mutating func apply(exportJSON o: [String: Any]) {
        func d(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        if let v = d("ringWidth") { ringWidth = v }; if let v = d("ringOpacityDark") { ringOpacityDark = v }
        if let v = d("ringOpacityLight") { ringOpacityLight = v }; if let v = d("fillOpacity") { fillOpacity = v }
    }
}

/// live-40 — the Glass orb. live-43 (Companion ruled 2026-10-26): NO refraction — the real background shows through the
/// body (behind-glass dim, a light tint of the orb's family colour, a frosted lift), then a soft inner shadow, the top /
/// bottom rim arcs, an optional thin edge and a highlight + rim glint that can follow the phone's tilt (default off).
/// `refraction`, `lensCurve`, `magnification` and `frost` are no longer drawn: kept only so saved values still decode.
/// All global → the orbs stay one batch.
struct GlassLook: Codable, Equatable {
    var refraction: Double          // how far the rim reaches beyond the edge for what it shows (orb radii)
    var lensCurve: Double           // exponent: higher = a flatter centre, the bend gathered at the rim
    var magnification: Double       // zoom at the centre (1 = none)
    var tint: Double                // the orb's family colour over the refracted grid
    var brightness: Double          // a light frosted lift of the body
    var frost: Double               // live-41: DIFFUSES the refracted grid (dot contrast melts into its average), dots don't grow
    var edge: Double                // the old uniform edge line (live-41: optional, default 0 — the rim arcs replace it)
    var innerShadow: Double         // a soft shadow just inside the rim (depth)
    var dispersion: Double          // a colour fringe at the rim
    var highlightSize: Double
    var highlightIntensity: Double  // the broad highlight; the rim glint rides with it
    var tiltResponse: Double        // how far the light follows the phone's tilt (negative = the other way)
    var label: TunerHSL             // title ink
    // live-41 — Liquid-Glass rim light: a brighter TOP arc (key) and a softer BOTTOM arc (bounce), fading toward the sides.
    var topArc = 0.9
    var bottomArc = 0.45
    var arcSpan = 120.0             // degrees each arc covers (centre ± span/2)
    var arcThickness = 0.07         // fraction of the radius the arc reaches in from the edge
    var arcSoftness = 0.6           // 0 = hard arc ends · 1 = fades all the way from the arc's centre
    var dim = 0.0                   // behind-glass dim: darkens what the lens shows
    var tiltLight = false           // off = static highlights + arcs (live-43: default off)
    var tiltSmoothing = 0.8         // seconds: the light drifts toward the tilt instead of tracking it

    static let subtle = GlassLook(refraction: 0.25, lensCurve: 3.0, magnification: 1.05, tint: 0.14, brightness: 0.03,
                                  frost: 0.25, edge: 0, innerShadow: 0.25, dispersion: 0.0, highlightSize: 0.22,
                                  highlightIntensity: 0.22, tiltResponse: 0.12, label: TunerHSL(hex: "FFFFFF"),
                                  topArc: 0.6, bottomArc: 0.3, arcSpan: 110, arcThickness: 0.06)
    static let medium = GlassLook(refraction: 0.55, lensCurve: 2.4, magnification: 1.15, tint: 0.22, brightness: 0.04,
                                  frost: 0.35, edge: 0, innerShadow: 0.4, dispersion: 0.15, highlightSize: 0.28,
                                  highlightIntensity: 0.42, tiltResponse: 0.16, label: TunerHSL(hex: "FFFFFF"))
    static let strong = GlassLook(refraction: 0.95, lensCurve: 1.9, magnification: 1.3, tint: 0.32, brightness: 0.08,
                                  frost: 0.5, edge: 0, innerShadow: 0.55, dispersion: 0.3, highlightSize: 0.34,
                                  highlightIntensity: 0.65, tiltResponse: 0.2, label: TunerHSL(hex: "FFFFFF"),
                                  topArc: 1.3, bottomArc: 0.65, arcSpan: 135, arcThickness: 0.09, arcSoftness: 0.55)
    static let presets: [(String, GlassLook)] = [("Subtle", .subtle), ("Medium", .medium), ("Strong", .strong)]

    /// live-40's Medium as it shipped on TF 202610231523 (uniform edge line, full tilt, no arcs, no frost) — the stills'
    /// "today" when T's Copy values aren't given.
    static let live40Medium = GlassLook(refraction: 0.55, lensCurve: 2.4, magnification: 1.15, tint: 0.22, brightness: 0.04,
                                        frost: 0, edge: 0.6, innerShadow: 0.4, dispersion: 0.15, highlightSize: 0.28,
                                        highlightIntensity: 0.42, tiltResponse: 0.8, label: TunerHSL(hex: "FFFFFF"),
                                        topArc: 0, bottomArc: 0)

    /// Apply a Copy-values `glass` block (numbers by key, `label` as "#HEX"); unknown keys are ignored.
    mutating func apply(exportJSON: [String: Any]) {
        func d(_ k: String) -> Double? { (exportJSON[k] as? NSNumber)?.doubleValue }
        if let v = d("refraction") { refraction = v }; if let v = d("lensCurve") { lensCurve = v }
        if let v = d("magnification") { magnification = v }; if let v = d("tint") { tint = v }
        if let v = d("brightness") { brightness = v }; if let v = d("frost") { frost = v }; if let v = d("edge") { edge = v }
        if let v = d("innerShadow") { innerShadow = v }; if let v = d("dispersion") { dispersion = v }
        if let v = d("highlightSize") { highlightSize = v }; if let v = d("highlightIntensity") { highlightIntensity = v }
        if let v = d("tiltResponse") { tiltResponse = v }
        if let v = d("topArc") { topArc = v }; if let v = d("bottomArc") { bottomArc = v }; if let v = d("arcSpan") { arcSpan = v }
        if let v = d("arcThickness") { arcThickness = v }; if let v = d("arcSoftness") { arcSoftness = v }; if let v = d("dim") { dim = v }
        if let v = d("tiltSmoothing") { tiltSmoothing = v }; if let b = exportJSON["tiltLight"] as? Bool { tiltLight = b }
        if let h = exportJSON["label"] as? String { label = TunerHSL(hex: h.replacingOccurrences(of: "#", with: "")) }
    }
}

extension GlassLook {
    /// Tolerant decode. A value saved by the live-40 build (no `topArc` key) is MIGRATED to live-41's asks: its tilt
    /// response × 0.2 and its uniform edge line → 0 (the top/bottom arcs replace it); everything else T dialled is kept.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let m = GlassLook.medium
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        self.init(refraction: v(.refraction, m.refraction), lensCurve: v(.lensCurve, m.lensCurve),
                  magnification: v(.magnification, m.magnification), tint: v(.tint, m.tint), brightness: v(.brightness, m.brightness),
                  frost: v(.frost, m.frost), edge: v(.edge, m.edge), innerShadow: v(.innerShadow, m.innerShadow),
                  dispersion: v(.dispersion, m.dispersion), highlightSize: v(.highlightSize, m.highlightSize),
                  highlightIntensity: v(.highlightIntensity, m.highlightIntensity), tiltResponse: v(.tiltResponse, m.tiltResponse),
                  label: v(.label, m.label), topArc: v(.topArc, m.topArc), bottomArc: v(.bottomArc, m.bottomArc),
                  arcSpan: v(.arcSpan, m.arcSpan), arcThickness: v(.arcThickness, m.arcThickness),
                  arcSoftness: v(.arcSoftness, m.arcSoftness), dim: v(.dim, m.dim), tiltLight: v(.tiltLight, m.tiltLight),
                  tiltSmoothing: v(.tiltSmoothing, m.tiltSmoothing))
        if !c.contains(.topArc) {   // saved by live-40
            tiltResponse *= 0.2
            edge = 0
        }
    }
}

/// The Fresnel orb: a dark body near the background, tinted by the orb's family colour, with a rim that glows in the
/// orb's colour and falls off toward the centre (rim = f(radius)^power). All global → the orbs stay one batch.
struct FresnelLook: Codable, Equatable {
    var bodyTint: Double        // 0 = the background · 1 = the orb's colour
    var bodyDarkness: Double    // 0 = as tinted · 1 = black
    var rimBrightness: Double   // rim colour = orb colour × this
    var rimWidth: Double        // fraction of the radius the rim reaches in from the edge (1 = to the centre)
    var rimPower: Double        // falloff exponent
    var rimIntensity: Double
    var innerGlow: Double       // a soft glow in the orb's colour at the centre
    var highlight: Double       // a faint top-left light
    var label: TunerHSL         // title ink on a dark body

    static let subtle = FresnelLook(bodyTint: 0.14, bodyDarkness: 0.25, rimBrightness: 1.0, rimWidth: 0.45, rimPower: 2.6,
                                    rimIntensity: 0.55, innerGlow: 0.0, highlight: 0.0, label: TunerHSL(hex: "F5F2EC"))
    static let medium = FresnelLook(bodyTint: 0.20, bodyDarkness: 0.15, rimBrightness: 1.25, rimWidth: 0.65, rimPower: 2.2,
                                    rimIntensity: 0.95, innerGlow: 0.06, highlight: 0.10, label: TunerHSL(hex: "FFFCF5"))
    static let strong = FresnelLook(bodyTint: 0.28, bodyDarkness: 0.05, rimBrightness: 1.6, rimWidth: 0.85, rimPower: 1.7,
                                    rimIntensity: 1.5, innerGlow: 0.14, highlight: 0.22, label: TunerHSL(hex: "FFFFFF"))
    static let presets: [(String, FresnelLook)] = [("Subtle", .subtle), ("Medium", .medium), ("Strong", .strong)]
}

/// live-39 — every dark-Map colour T can dial. Defaults = what ships today, so an untouched tuner renders today's Map.
struct MapDarkTuning: Codable, Equatable {
    var ground = TunerHSL(hex: "111115")          // the grid's opaque ground (BackgroundGridNode u_ground_color)
    var ambientAmount = 0.067                     // the mass-field ripple: mix toward the ambient colour away from orbs
    var ambient = TunerHSL(hex: "FFFFFF")
    var dot = TunerHSL(hex: "FFFFFF")             // the dot grid
    var dotOpacity = 0.809
    var pillTint = TunerHSL(hex: "FFFFFF")        // a tint laid over the territory pill's glass (0 = none)
    var pillTintAmount = 0.0
    var pillOutlineCustom = false                 // false = each territory's own colour (today)
    var pillOutline = TunerHSL(hex: "FFFFFF")
    var pillOutlineOpacity = 0.95
    var pillOutlineWidth = 1.5
    var pillTextOpacity = 0.95
    var focusRing = TunerHSL(hex: "00BFFF")       // the focused orb's ring
    var selectionRing = TunerHSL(hex: "1B59C2")   // the multi-select ring
    var orbGlow = TunerHSL(hex: "FFFFFF")         // every orb's edge glow (AE inner glow)
    var orbGlowOpacity = 0.12
    var orbLook: MapOrbLook = .flat
    var fresnel: FresnelLook = .medium
    var glass: GlassLook = .medium
    var aura = AuraLook()                         // live-43
    var eclipse = EclipseLook()                   // live-47
    var outline = OutlineLook()                   // live-43-A
    var wash = WashLook()                         // live-46 — the light Map's half of the Pro "Aura" look
    var lightGlass = LightGlassLook()             // live-49 — the light Map's half of Glass
    var riso = RisoLook()                         // live-49 — both Maps
    var gradient = GradientLook()                 // live-49 — both Maps
    // live-40 — the grid's dots shrink under/near orbs (mass field). Drives the background AND the grid inside Glass orbs.
    var dotShrinkOn = true
    var dotShrink = 1.0                           // GridWarpTuning.dotShrink(dark) — today
    var shrinkReach = 6.0                         // GridWarpTuning.reachOrbRadii — today (the field also drives the ripple)

    static let today = MapDarkTuning()
    init() {}

    /// Every field optional, so values saved by an older build (live-39 had no Glass / shrink) keep T's dialled colours.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MapDarkTuning()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        ground = v(.ground, d.ground); ambientAmount = v(.ambientAmount, d.ambientAmount); ambient = v(.ambient, d.ambient)
        dot = v(.dot, d.dot); dotOpacity = v(.dotOpacity, d.dotOpacity)
        pillTint = v(.pillTint, d.pillTint); pillTintAmount = v(.pillTintAmount, d.pillTintAmount)
        pillOutlineCustom = v(.pillOutlineCustom, d.pillOutlineCustom); pillOutline = v(.pillOutline, d.pillOutline)
        pillOutlineOpacity = v(.pillOutlineOpacity, d.pillOutlineOpacity); pillOutlineWidth = v(.pillOutlineWidth, d.pillOutlineWidth)
        pillTextOpacity = v(.pillTextOpacity, d.pillTextOpacity)
        focusRing = v(.focusRing, d.focusRing); selectionRing = v(.selectionRing, d.selectionRing)
        orbGlow = v(.orbGlow, d.orbGlow); orbGlowOpacity = v(.orbGlowOpacity, d.orbGlowOpacity)
        orbLook = v(.orbLook, d.orbLook); fresnel = v(.fresnel, d.fresnel); glass = v(.glass, d.glass)
        aura = v(.aura, d.aura); eclipse = v(.eclipse, d.eclipse); outline = v(.outline, d.outline); wash = v(.wash, d.wash)
        lightGlass = v(.lightGlass, d.lightGlass); riso = v(.riso, d.riso); gradient = v(.gradient, d.gradient)
        dotShrinkOn = v(.dotShrinkOn, d.dotShrinkOn); dotShrink = v(.dotShrink, d.dotShrink); shrinkReach = v(.shrinkReach, d.shrinkReach)
    }

    /// Apply a Copy-values `mapDark` block (colours as "#HEX"); unknown keys are ignored. Debug stills only.
    mutating func apply(exportJSON o: [String: Any]) {
        func d(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        func c(_ k: String) -> TunerHSL? { (o[k] as? String).map { TunerHSL(hex: $0.replacingOccurrences(of: "#", with: "")) } }
        if let v = c("ground") { ground = v }; if let v = d("ambient") { ambientAmount = v }; if let v = c("ambientColor") { ambient = v }
        if let v = c("dots") { dot = v }; if let v = d("dotOpacity") { dotOpacity = v }
        if let v = c("pillTint") { pillTint = v }; if let v = d("pillTintAmount") { pillTintAmount = v }
        if let h = o["pillOutline"] as? String { pillOutlineCustom = h != "territory"; if pillOutlineCustom, let v = c("pillOutline") { pillOutline = v } }
        if let v = d("pillOutlineOpacity") { pillOutlineOpacity = v }; if let v = d("pillOutlineWidth") { pillOutlineWidth = v }
        if let v = d("pillTextOpacity") { pillTextOpacity = v }
        if let v = c("focusRing") { focusRing = v }; if let v = c("selectionRing") { selectionRing = v }
        if let v = c("orbGlow") { orbGlow = v }; if let v = d("orbGlowOpacity") { orbGlowOpacity = v }
        if let b = o["dotShrinkOn"] as? Bool { dotShrinkOn = b }; if let v = d("dotShrink") { dotShrink = v }
        if let v = d("shrinkReach") { shrinkReach = v }
        if let l = (o["orbLook"] as? String).flatMap(MapOrbLook.init(rawValue:)) { orbLook = l }
        if let a = o["aura"] as? [String: Any] { aura.apply(exportJSON: a) }
        if let e = o["eclipse"] as? [String: Any] { eclipse.apply(exportJSON: e) }
        if let b = o["outline"] as? [String: Any] { outline.apply(exportJSON: b) }
        if let w = o["wash"] as? [String: Any] { wash.apply(exportJSON: w) }
        if let x = o["lightGlass"] as? [String: Any] { lightGlass.apply(exportJSON: x); lightGlass.applyGlassExtras(x) }
        if let x = o["riso"] as? [String: Any] { riso.apply(exportJSON: x) }
        if let x = o["gradient"] as? [String: Any] { gradient.apply(exportJSON: x) }
    }

    /// The shrink the grid shader receives (0 = uniform dots).
    var effectiveShrink: Double { dotShrinkOn ? dotShrink : 0 }

    /// What the Map's background shows. The ripple mixes the ground toward (R × ambient colour) at `ambientAmount`, with
    /// R = 0 within reach of orbs (6 orb radii — measured: nearly the whole screen, `#101014` today) and R = 1 only in
    /// open space past every orb's reach (`#212125` today).
    var fieldHex: String { mixHex(r: 0) }
    var openSpaceHex: String { mixHex(r: 1) }
    private func mixHex(r: Double) -> String {
        let g = ground.rgb, a = ambient.rgb, t = ambientAmount
        func m(_ x: Double, _ y: Double) -> Int { Int(((x * (1 - t) + y * r * t) * 255).rounded()) }
        return String(format: "%02X%02X%02X", m(g.r, a.r), m(g.g, a.g), m(g.b, a.b))
    }
}

#if DEBUG
/// live-40 stills — a simulated tilt for the Glass highlight (the Simulator has no gyro). nil = the real tilt.
enum MapGlassDebug { static var tilt: SIMD2<Float>? }
#endif

extension AppearanceTuning {
    /// The dark Map's tuner values, or nil when the tuner isn't live (the Map then renders its baked literals).
    static var mapDark: MapDarkTuning? { isLive ? AppearanceTuner.shared.state.mapDark : nil }

    static func mapDarkJSON(_ m: MapDarkTuning) -> String {
        func n(_ x: Double) -> String {
            var t = String(format: "%.3f", x)
            while t.contains(".") && (t.hasSuffix("0") || t.hasSuffix(".")) { t.removeLast() }
            return t
        }
        func c(_ x: TunerHSL) -> String { "\"#\(x.hex)\"" }
        let f = m.fresnel, g = m.glass, a = m.aura, e = m.eclipse, ol = m.outline, w = m.wash
        func study<L: StudyOrbLook>(_ x: L) -> String {
            "{\"spread\":\(n(x.spread)),\"warp\":\(n(x.warp)),\"softness\":\(n(x.softness)),\"haloReach\":\(n(x.haloReach)),"
                + "\"rim\":\(n(x.rim)),\"fringe\":\(n(x.fringe)),\"grain\":\(n(x.grain)),\"drift\":\(x.drift)}"
        }
        return "{\"ground\":\(c(m.ground)),\"field\":\"#\(m.fieldHex)\",\"openSpace\":\"#\(m.openSpaceHex)\",\"ambient\":\(n(m.ambientAmount)),"
            + "\"ambientColor\":\(c(m.ambient)),\"dots\":\(c(m.dot)),\"dotOpacity\":\(n(m.dotOpacity)),"
            + "\"pillTint\":\(c(m.pillTint)),\"pillTintAmount\":\(n(m.pillTintAmount)),"
            + "\"pillOutline\":\(m.pillOutlineCustom ? c(m.pillOutline) : "\"territory\""),"
            + "\"pillOutlineOpacity\":\(n(m.pillOutlineOpacity)),\"pillOutlineWidth\":\(n(m.pillOutlineWidth)),"
            + "\"pillTextOpacity\":\(n(m.pillTextOpacity)),\"focusRing\":\(c(m.focusRing)),\"selectionRing\":\(c(m.selectionRing)),"
            + "\"orbGlow\":\(c(m.orbGlow)),\"orbGlowOpacity\":\(n(m.orbGlowOpacity)),\"orbLook\":\"\(m.orbLook.rawValue)\","
            + "\"fresnel\":{\"bodyTint\":\(n(f.bodyTint)),\"bodyDarkness\":\(n(f.bodyDarkness)),\"rimBrightness\":\(n(f.rimBrightness)),"
            + "\"rimWidth\":\(n(f.rimWidth)),\"rimPower\":\(n(f.rimPower)),\"rimIntensity\":\(n(f.rimIntensity)),"
            + "\"innerGlow\":\(n(f.innerGlow)),\"highlight\":\(n(f.highlight)),\"label\":\(c(f.label))},"
            + "\"dotShrinkOn\":\(m.dotShrinkOn),\"dotShrink\":\(n(m.dotShrink)),\"shrinkReach\":\(n(m.shrinkReach)),"
            + "\"glass\":{"
            + "\"tint\":\(n(g.tint)),\"brightness\":\(n(g.brightness)),\"edge\":\(n(g.edge)),"
            + "\"innerShadow\":\(n(g.innerShadow)),\"dispersion\":\(n(g.dispersion)),\"highlightSize\":\(n(g.highlightSize)),"
            + "\"highlightIntensity\":\(n(g.highlightIntensity)),\"tiltResponse\":\(n(g.tiltResponse)),\"label\":\(c(g.label)),"
            + "\"topArc\":\(n(g.topArc)),\"bottomArc\":\(n(g.bottomArc)),\"arcSpan\":\(n(g.arcSpan)),\"arcThickness\":\(n(g.arcThickness)),"
            + "\"arcSoftness\":\(n(g.arcSoftness)),\"dim\":\(n(g.dim)),\"tiltLight\":\(g.tiltLight),\"tiltSmoothing\":\(n(g.tiltSmoothing))},"
            + "\"palettes\":\"12 territories\",\"aura\":\(study(a)),\"eclipse\":\(study(e)),"
            + "\"lightGlass\":\(m.lightGlass.exportJSON),\"riso\":\(study(m.riso)),\"gradient\":\(study(m.gradient)),"
            + "\"outline\":{\"ringWidth\":\(n(ol.ringWidth)),\"ringOpacityDark\":\(n(ol.ringOpacityDark)),"
            + "\"ringOpacityLight\":\(n(ol.ringOpacityLight)),\"fillOpacity\":\(n(ol.fillOpacity))},"
            + "\"wash\":{\"spread\":\(n(w.spread)),\"warp\":\(n(w.warp)),\"softness\":\(n(w.softness)),\"bleed\":\(n(w.bleed)),"
            + "\"pooling\":\(n(w.pooling)),\"misregistration\":\(n(w.misregistration)),\"paper\":\(n(w.paper))}}"
    }

    /// `-AppearanceTuningSelfTest` rows for the Map section (pure).
    static func mapDarkSelfTestRows() -> [(String, Bool, String)] {
        let t = MapDarkTuning.today
        let hexes = ["111115", "FFFFFF", "00BFFF", "1B59C2", "1A1A1A", "0B0B0E", "F5F2EC"]
        let trips = hexes.allSatisfy { TunerHSL(hex: $0).hex == $0 }
        return [
            ("map-dark-hsl-round-trips-today's-hexes", trips, hexes.map { "\($0)→\(TunerHSL(hex: $0).hex)" }.joined(separator: " ")),
            ("map-dark-defaults-are-today (ground 111115 · ripple 0.067 · dots FFFFFF@0.809 · focus 00BFFF · select 1B59C2 · glow FFFFFF@0.12 · flat)",
             t.ground.hex == "111115" && t.ambientAmount == 0.067 && t.dot.hex == "FFFFFF" && t.dotOpacity == 0.809
                && t.focusRing.hex == "00BFFF" && t.selectionRing.hex == "1B59C2" && t.orbGlow.hex == "FFFFFF"
                && t.orbGlowOpacity == 0.12 && t.orbLook == .flat && t.pillTintAmount == 0 && !t.pillOutlineCustom
                && t.pillOutlineOpacity == 0.95 && t.pillOutlineWidth == 1.5 && t.pillTextOpacity == 0.95, ""),
            ("map-dark-field-today-101014-open-space-212125 (measured on a Sim still: 101014)",
             t.fieldHex == "101014" && t.openSpaceHex == "212125", "\(t.fieldHex) / \(t.openSpaceHex)"),
            ("map-dark-shrink-defaults-are-today (on · 1.0 · reach 6 orb radii)",
             t.dotShrinkOn && t.dotShrink == 1.0 && t.shrinkReach == 6.0 && t.effectiveShrink == 1.0, ""),
            ("map-dark-live39-saved-values-decode (no glass/shrink keys → ground kept, glass = medium)", {
                let old = #"{"ground":{"h":240,"s":0.1,"l":0.04},"orbLook":"fresnel"}"#
                guard let m = try? JSONDecoder().decode(MapDarkTuning.self, from: Data(old.utf8)) else { return false }
                return m.orbLook == .fresnel && m.ground.l == 0.04 && m.glass == .medium && m.dotShrinkOn
            }(), ""),
            ("glass-live40-saved-value-migrates (tilt ×0.2, edge → 0, rest kept)", {
                let old = #"{"refraction":0.7,"lensCurve":2.4,"magnification":1.2,"tint":0.3,"brightness":0.05,"frost":0.2,"edge":0.6,"innerShadow":0.4,"dispersion":0.1,"highlightSize":0.3,"highlightIntensity":0.5,"tiltResponse":0.8,"label":{"h":0,"s":0,"l":1}}"#
                guard let g = try? JSONDecoder().decode(GlassLook.self, from: Data(old.utf8)) else { return false }
                return abs(g.tiltResponse - 0.16) < 1e-9 && g.edge == 0 && g.refraction == 0.7 && g.topArc == GlassLook.medium.topArc
            }(), ""),
            ("glass-live41-value-round-trips-unmigrated", {
                var g = GlassLook.medium; g.edge = 0.5; g.tiltResponse = 0.9
                guard let data = try? JSONEncoder().encode(g), let back = try? JSONDecoder().decode(GlassLook.self, from: data) else { return false }
                return back == g
            }(), ""),
            ("glass-export-applies-back (the lens + frost keys left the export at live-43)", {
                var g = GlassLook.subtle
                g.refraction = t.glass.refraction; g.lensCurve = t.glass.lensCurve; g.magnification = t.glass.magnification
                g.frost = t.glass.frost
                guard let all = try? JSONSerialization.jsonObject(with: Data(mapDarkJSON(t).utf8)) as? [String: Any],
                      let block = all["glass"] as? [String: Any] else { return false }
                g.apply(exportJSON: block)
                return g == t.glass
            }(), ""),
            ("aura-defaults-are-T's-2026-10-27-values (spread 0.82 · warp 1.36 · soft 0.03 · halo 0 · rim 0.45 · fringe 0.35 · grain 1; extent 1.094 = the study's bound)", {
                let a = t.aura
                return a.spread == 0.82 && a.warp == 1.36 && a.softness == 0.03 && a.haloReach == 0 && a.rim == 0.45
                    && a.fringe == 0.35 && a.grain == 1.0 && !a.drift && a == AuraLook.medium && abs(a.spriteExtent - 1.094) < 1e-9
            }(), String(format: "extent %.3f", t.aura.spriteExtent)),
            ("eclipse-defaults-are-T's-2026-10-27-values (0.87 · 0.76 · 0.01 · halo 0.12 · rim 0.56 · fringe 0.39 · grain 0.8; extent 1.394)", {
                let e = t.eclipse
                return e.spread == 0.87 && e.warp == 0.76 && e.softness == 0.01 && e.haloReach == 0.12 && e.rim == 0.56
                    && e.fringe == 0.39 && e.grain == 0.8 && !e.drift && abs(e.spriteExtent - 1.394) < 1e-9
            }(), String(format: "extent %.3f", t.eclipse.spriteExtent)),
            ("aura-eclipse-presets-are-the-study's (Aura Subtle .7/.6/.02/0/.3/.2/.6 · Eclipse Medium .95/.9/.04/.12/.5/.45/.8)",
             AuraLook.subtle == AuraLook(0.7, 0.6, 0.02, 0, 0.3, 0.2, 0.6) && AuraLook.strong.haloReach == 0.15
                && EclipseLook.medium == EclipseLook(0.95, 0.9, 0.04, 0.12, 0.5, 0.45, 0.8) && EclipseLook.strong.haloReach == 0.3, ""),
            ("study-12-palettes-match-the-hex-table (Ops/reference/orb-study-families-2026-10-27.md)", {
                let want = ["770055 EC305A FDCFC0 37D59F", "D85A04 FDD1AE 7C0438 1AD1D1", "810013 B2790C F6D69E 10CAFD",
                            "928A0F E5DDA0 702901 87BAFD", "004D4A 519C03 D1E4A9 B0ADFE", "0D9E73 BBE9BA 004C55 DB98F9",
                            "014961 0C9999 A8ECCE FA8ECD", "0994BA 9CEDE3 004575 FF939C", "1C339B 0083FC 9AEAF6 FE9A6C",
                            "7F69FE FEC7EF 422696 EFA831", "5A1987 B64FDE FFCADB C6BC33", "DA3AA4 FECDCD 6C0871 8CCC66"]
                let got = OrbStudyPalettes.families.map { f in [f.a, f.b, f.c, f.r].map(OrbStudyPalettes.hex).joined(separator: " ") }
                return got == want
            }(), OrbStudyPalettes.families.map { "\($0.name) " + OrbStudyPalettes.hex($0.a) }.joined(separator: " · ")),
            ("study-palette-assignment-is-one-to-one-by-hue (12 → the best rotation; 5 → order kept, no family twice)", {
                let twelve = Dictionary(uniqueKeysWithValues: (0..<12).map { ($0, Double(($0 * 30 + 100) % 360)) })
                let m12 = OrbStudyPalettes.assign(territoryHues: twelve)
                // hue 100 + 30i is 5° past family (i + 3)'s hue 15 + 30(i + 3) → rotation +3
                let rot = (0..<12).allSatisfy { m12[$0] == ($0 + 3) % 12 }
                let five: [Int: Double] = [0: 10, 1: 40, 2: 200, 3: 210, 4: 290]
                let m5 = OrbStudyPalettes.assign(territoryHues: five)
                return rot && Set(m5.values).count == 5 && m5[0] == 0 && m5[1] == 1 && m5[2] == 6 && m5[3] == 7 && m5[4] == 9
            }(), ""),
            ("aura-live46-saved-values-load (softnessFloor / grainSize / contrast / hueSpread ignored, the rest kept)", {
                let old = #"{"spread":1.1,"softnessFloor":4,"grainSize":1,"contrast":1.5,"hueSpread":40,"grain":0.4,"softness":0.09}"#
                guard let a = try? JSONDecoder().decode(AuraLook.self, from: Data(old.utf8)) else { return false }
                var b = AuraLook(); b.apply(exportJSON: ["spread": 1.1, "softnessFloor": 4, "contrast": 1.5, "grain": 0.4, "softness": 0.09])
                return a.spread == 1.1 && a.grain == 0.4 && a.softness == 0.09 && a.warp == 1.36 && b == a
            }(), ""),
            ("export-has-aura-eclipse-wash-blocks + palettes (no live-45 keys)", {
                guard let all = try? JSONSerialization.jsonObject(with: Data(mapDarkJSON(t).utf8)) as? [String: Any],
                      let au = all["aura"] as? [String: Any], let ec = all["eclipse"] as? [String: Any] else { return false }
                return au["contrast"] == nil && au["softnessFloor"] == nil && au["haloReach"] != nil && ec["haloReach"] != nil
                    && all["wash"] != nil && (all["palettes"] as? String) == "12 territories"
            }(), ""),
            ("aura-eclipse-and-outline-export-apply-back", {
                var m = MapDarkTuning(); m.aura.warp = 0.5; m.aura.drift = true; m.aura.haloReach = 0.2; m.outline.fillOpacity = 0.2
                m.eclipse = .strong; m.eclipse.rim = 0.33
                m.orbLook = .eclipse
                var back = MapDarkTuning()
                guard let all = try? JSONSerialization.jsonObject(with: Data(mapDarkJSON(m).utf8)) as? [String: Any] else { return false }
                back.apply(exportJSON: all)
                return back.aura == m.aura && back.eclipse == m.eclipse && back.outline == m.outline && back.orbLook == .eclipse
            }(), ""),
            // live-49 — the study's v7 looks: T's values (orb-study-values-2026-10-27b.json), the study's bounds, Copy values
            // round trip, older saved values (no lightGlass / riso / gradient keys) decode to the defaults.
            ("map-v7-looks-defaults-are-T's-values (Light Glass .68/.6/.01/.36/.7/.41/0 · Riso .72/.95/.01/.42/.84/.71/.23 · Gradient 1.01/.96/.01/.4/.52/.1/0)", {
                func k<L: StudyOrbLook>(_ x: L) -> [Double] { [x.spread, x.warp, x.softness, x.haloReach, x.rim, x.fringe, x.grain] }
                return k(t.lightGlass) == [0.68, 0.6, 0.01, 0.36, 0.7, 0.41, 0] && k(t.riso) == [0.72, 0.95, 0.01, 0.42, 0.84, 0.71, 0.23]
                    && k(t.gradient) == [1.01, 0.96, 0.01, 0.4, 0.52, 0.1, 0]
                    && abs(t.lightGlass.spriteExtent - 1.594) < 1e-9 && abs(t.riso.spriteExtent - 1.0875) < 1e-9
                    && abs(t.gradient.spriteExtent - 1.057) < 1e-9
            }(), String(format: "extents %.4f %.4f %.4f", t.lightGlass.spriteExtent, t.riso.spriteExtent, t.gradient.spriteExtent)),
            ("map-v7-looks-copy-values-round-trip + old values decode", {
                var m = MapDarkTuning(); m.orbLook = .riso; m.riso = RisoLook.presets[2].1; m.lightGlass = LightGlassLook.presets[0].1
                m.gradient.haloReach = 0.9
                var back = MapDarkTuning()
                guard let all = try? JSONSerialization.jsonObject(with: Data(mapDarkJSON(m).utf8)) as? [String: Any] else { return false }
                back.apply(exportJSON: all)
                let old = #"{"orbLook":"eclipse","aura":{"spread":0.9}}"#
                guard let o = try? JSONDecoder().decode(MapDarkTuning.self, from: Data(old.utf8)) else { return false }
                return back.riso == m.riso && back.lightGlass == m.lightGlass && back.gradient == m.gradient && back.orbLook == .riso
                    && o.lightGlass == LightGlassLook() && o.riso == RisoLook() && o.gradient == GradientLook() && o.orbLook == .eclipse
            }(), ""),
            // live-50 — Light Glass's dark-Glass controls start at "no change" and travel in Copy values
            ("light-glass-extras-default-to-no-change + copy-values round trip (live-50)", {
                let d = LightGlassLook()
                var x = d; x.topArc = 1.2; x.bottomArc = 0.5; x.arcSpan = 90; x.dispersion = 0.6; x.innerShadow = 0.4
                x.highlightSize = 0.3; x.label = TunerHSL(hex: "1B59C2")
                var m = MapDarkTuning(); m.lightGlass = x
                var back = MapDarkTuning()
                guard let all = try? JSONSerialization.jsonObject(with: Data(mapDarkJSON(m).utf8)) as? [String: Any] else { return false }
                back.apply(exportJSON: all)
                let r = back.lightGlass
                return d.topArc == 0 && d.bottomArc == 0 && d.dispersion == 0 && d.innerShadow == 0
                    && abs(1 / (d.highlightSize * d.highlightSize) - 70) < 1e-9 && TunerHSL(hex: "1B1A20").hex == "1B1A20"
                    && r.topArc == 1.2 && r.bottomArc == 0.5 && r.arcSpan == 90 && r.dispersion == 0.6 && r.innerShadow == 0.4
                    && r.highlightSize == 0.3 && r.label.hex == "1B59C2" && r.spread == x.spread
            }(), ""),
            ("map-v7-lineup (dark Flat·Glass·Aura·Eclipse·Riso·Gradient·Outline; Riso / Gradient / Outline on both; Glass ↔ Light Glass)",
             MapOrbLook.darkPicker == [.flat, .glass, .aura, .eclipse, .riso, .gradient, .outline]
                && MapOrbLook.riso.bothGrounds && MapOrbLook.gradient.bothGrounds && MapOrbLook.glass.drawsLightGlassOnLight
                && !MapOrbLook.glass.bothGrounds, ""),
            ("glass-tilt-light-defaults-off (live-43)", !t.glass.tiltLight && !GlassLook.medium.tiltLight, ""),
            ("map-dark-live42-saved-values-decode (no aura/outline keys → defaults)", {
                let old = #"{"orbLook":"glass","glass":{"tint":0.3,"tiltLight":true}}"#
                guard let m = try? JSONDecoder().decode(MapDarkTuning.self, from: Data(old.utf8)) else { return false }
                return m.orbLook == .glass && m.glass.tiltLight && m.aura == AuraLook() && m.outline == OutlineLook()
                    && m.eclipse == EclipseLook()
            }(), ""),
            ("wash-defaults-are-the-study's-Medium (spread 1 · warp 0.9 · soft 0.05 · bleed 0.6 · pooling 0.55 · misreg 0.6 · paper 0.6; extent 1.34)", {
                let w = t.wash
                return w == .medium && w.spread == 1 && w.warp == 0.9 && w.softness == 0.05 && w.bleed == 0.6 && w.pooling == 0.55
                    && w.misregistration == 0.6 && w.paper == 0.6 && abs(w.spriteExtent - 1.34) < 1e-9
            }(), String(format: "extent %.3f", t.wash.spriteExtent)),
            ("wash-presets-are-the-study's (Subtle .8/.5/.03/.3/.3/.3/.4 · Strong 1.2/1.3/.08/1/.85/1/.85)",
             WashLook.subtle == WashLook(spread: 0.8, warp: 0.5, softness: 0.03, bleed: 0.3, pooling: 0.3, misregistration: 0.3, paper: 0.4)
                && WashLook.strong.bleed == 1 && WashLook.strong.pooling == 0.85 && WashLook.strong.paper == 0.85, ""),
            ("wash-export-applies-back + live-45 values without a wash key decode", {
                var m = MapDarkTuning(); m.wash = .strong; m.wash.paper = 0.33
                var back = MapDarkTuning()
                guard let all = try? JSONSerialization.jsonObject(with: Data(mapDarkJSON(m).utf8)) as? [String: Any] else { return false }
                back.apply(exportJSON: all)
                let old = #"{"orbLook":"aura","aura":{"contrast":1.5,"spread":1.2}}"#
                guard let o = try? JSONDecoder().decode(MapDarkTuning.self, from: Data(old.utf8)) else { return false }
                return back.wash == m.wash && o.wash == .medium && o.aura.spread == 1.2 && o.eclipse == EclipseLook()
            }(), ""),
            ("map-dark-export-parses", (try? JSONSerialization.jsonObject(with: Data(mapDarkJSON(t).utf8))) != nil, mapDarkJSON(t)),
        ]
    }
}

#endif
