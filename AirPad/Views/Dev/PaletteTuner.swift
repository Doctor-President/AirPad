#if DEBUG
import SwiftUI
import Observation

// ── PALETTE TUNER (DEBUG ONLY) ──────────────────────────────────────────────────────────────────
// The instrument T dials the whole app palette on, on device, one change at a time (he is
// colourblind — he reads/reports HEX, not swatches). Every token in AppearancePalette + the
// CardSurface ground/shadow resolves through this override layer IN DEBUG; in Release the token
// sites use their baked literals and NONE of this file compiles (whole file is `#if DEBUG`).
//
// LIVE UPDATE mechanism: this store is `@Observable`, and the token resolvers (PaletteTuner.color/
// floatVal) read `overrides` SYNCHRONOUSLY during a view's `body` evaluation. SwiftUI's Observation
// therefore tracks the dependency and re-renders exactly the views reading a changed token — live,
// per-token, no full-tree rebuild, no data reload. The deferred `UIColor { trait }` closure only
// picks dark/light between two ALREADY-resolved hexes, so the override read stays inside body eval.

enum PaletteKind: String { case primary = "PRIMARY", derived = "DERIVED", recipe = "RECIPE" }

/// One editable value type. Colours get the HSL picker; floats get a numeric field.
enum PaletteValueType { case color, float }

/// A token in the registry. `hasDark` is false for light-only recipe scalars.
struct PaletteTokenDef: Identifiable {
    let id: String
    let name: String
    let kind: PaletteKind
    let type: PaletteValueType
    let bakedDark: String
    let bakedLight: String
    var hasDark: Bool = true
    /// Per-appearance baked alpha for shadow/lift colours (nil = no alpha knob for that appearance).
    var alphaDark: Float? = nil
    var alphaLight: Float? = nil
    /// For `float` tokens: the slider range.
    var range: ClosedRange<Float> = 0...1
    var note: String? = nil
}

@Observable
final class PaletteTuner {
    static let shared = PaletteTuner()

    /// Flat override store, keyed "<id>.dark" / "<id>.light" → hex (colour) or number-as-string
    /// (float). Absent → the baked value. Persisted to UserDefaults on every change.
    private(set) var overrides: [String: String] = [:]
    /// Whether the panel is open (also gates the preview colorScheme force).
    var isPresented = false
    /// Which appearance the panel is editing + forcing on the preview (nil = follow the system).
    var previewDark: Bool? = nil

    private let defaultsKey = "PaletteTuner.overrides.v1"

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] {
            overrides = saved
        }
    }

    // MARK: value access (read during body eval → Observation-tracked → live)

    func hex(_ id: String, dark: Bool) -> String? { overrides["\(id).\(dark ? "dark" : "light")"] }

    func set(_ id: String, dark: Bool, value: String) {
        overrides["\(id).\(dark ? "dark" : "light")"] = value
        persist()
    }
    func alpha(_ id: String, dark: Bool) -> Float? { overrides["\(id).alpha.\(dark ? "dark" : "light")"].flatMap { Float($0) } }
    func setAlpha(_ id: String, dark: Bool, _ a: Double) {
        overrides["\(id).alpha.\(dark ? "dark" : "light")"] = String(format: "%.3f", a)
        persist()
    }
    func resetOne(_ id: String) {
        overrides["\(id).dark"] = nil
        overrides["\(id).light"] = nil
        overrides["\(id).alpha.dark"] = nil
        overrides["\(id).alpha.light"] = nil
        persist()
    }
    func resetAll() { overrides = [:]; persist() }

    private func persist() { UserDefaults.standard.set(overrides, forKey: defaultsKey) }

    // MARK: resolvers the token sites call (AppearancePalette / CardSurfaceResolved, DEBUG paths)

    /// A dynamic colour whose dark/light hex may be overridden. Reads both overrides HERE (tracked),
    /// then defers only the trait pick.
    static func color(_ id: String, dark: String, light: String) -> Color {
        let d = shared.hex(id, dark: true) ?? dark
        let l = shared.hex(id, dark: false) ?? light
        return Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? d : l
            let (r, g, b) = PaletteColor.rgb(hex)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
    }

    /// A dynamic colour carrying a per-appearance ALPHA (shadows). Hex + alpha both overridable; the
    /// override string for the alpha slot is stored under "<id>.alpha.dark/light".
    static func colorAlpha(_ id: String, dark: String, darkAlpha: CGFloat,
                           light: String, lightAlpha: CGFloat) -> Color {
        let dHex = shared.hex(id, dark: true) ?? dark
        let lHex = shared.hex(id, dark: false) ?? light
        let dA = shared.overrides["\(id).alpha.dark"].flatMap { Float($0) }.map { CGFloat($0) } ?? darkAlpha
        let lA = shared.overrides["\(id).alpha.light"].flatMap { Float($0) }.map { CGFloat($0) } ?? lightAlpha
        return Color(UIColor { trait in
            let isDark = trait.userInterfaceStyle == .dark
            let (r, g, b) = PaletteColor.rgb(isDark ? dHex : lHex)
            return UIColor(red: r, green: g, blue: b, alpha: isDark ? dA : lA)
        })
    }

    /// A per-appearance FLOAT (e.g. mapGridDotOpacity).
    static func floatVal(_ id: String, dark: Bool, bakedDark: Float, bakedLight: Float) -> Float {
        if let s = shared.hex(id, dark: dark), let v = Float(s) { return v }
        return dark ? bakedDark : bakedLight
    }

    /// A single light-only scalar (cw* recipe values).
    static func scalar(_ id: String, baked: Float) -> Float {
        if let s = shared.overrides["\(id).light"], let v = Float(s) { return v }
        return baked
    }

    // MARK: couplings — tokens whose CURRENT value equals this one (same appearance). Coincidental
    // equality, surfaced so T can choose "move the group" or "move just this one". Never auto-linked.

    func currentValue(_ id: String, dark: Bool) -> String? {
        if let o = hex(id, dark: dark) { return o }
        return PaletteTuner.registry.first { $0.id == id }.map { dark ? $0.bakedDark : $0.bakedLight }
    }

    /// Other tokens sharing this token's current value in this appearance (colour tokens only).
    func coupledTokens(_ id: String, dark: Bool) -> [PaletteTokenDef] {
        guard let mine = currentValue(id, dark: dark)?.uppercased() else { return [] }
        return PaletteTuner.registry.filter { def in
            def.id != id && def.type == .color && (dark ? def.hasDark : true) &&
            (currentValue(def.id, dark: dark)?.uppercased() == mine)
        }
    }

    // MARK: export — the settled palette as pasteable Swift/hex (only tokens T actually changed)

    func exportSwift() -> String {
        let changed = PaletteTuner.registry.filter { def in
            ["dark", "light"].contains { overrides["\(def.id).\($0)"] != nil } ||
            overrides["\(def.id).alpha.dark"] != nil || overrides["\(def.id).alpha.light"] != nil
        }
        if changed.isEmpty { return "// PaletteTuner: no overrides — every token is at its baked value." }
        var out = "// PaletteTuner export — dialed \(changed.count) token(s). Bake these into source.\n"
        for def in changed {
            let d = currentValue(def.id, dark: true) ?? def.bakedDark
            let l = currentValue(def.id, dark: false) ?? def.bakedLight
            if def.hasDark {
                out += "\(def.id): dark \(d)  ·  light \(l)"
            } else {
                out += "\(def.id): \(l)"
            }
            if let da = overrides["\(def.id).alpha.dark"], let la = overrides["\(def.id).alpha.light"] {
                out += "   (alpha dark \(da) · light \(la))"
            }
            out += "\n"
        }
        return out
    }

    // MARK: the registry — the token map (Ops/architecture/appearance-token-map.md), in source order

    static let registry: [PaletteTokenDef] = [
        .init(id: "bgBase",        name: "bgBase",        kind: .primary, type: .color, bakedDark: "1A1A1A", bakedLight: "F4EFE3", note: "base ground"),
        .init(id: "bgElevated",    name: "bgElevated",    kind: .primary, type: .color, bakedDark: "1A1A1A", bakedLight: "FAF6EC", note: "raised panel"),
        .init(id: "ink",           name: "ink",           kind: .primary, type: .color, bakedDark: "FFFFFF", bakedLight: "232A2E", note: "text / icons"),
        .init(id: "onInk",         name: "onInk",         kind: .primary, type: .color, bakedDark: "000000", bakedLight: "F4EFE3", note: "glyph on ink (capture +)"),
        .init(id: "panelShadow",   name: "panelShadow",   kind: .primary, type: .color, bakedDark: "000000", bakedLight: "000000", alphaDark: 0.35, alphaLight: 0.10, note: "note lift"),
        .init(id: "listRowLift",   name: "listRowLift",   kind: .primary, type: .color, bakedDark: "000000", bakedLight: "43372A", hasDark: false, alphaLight: 0.75, note: "list row band (light only; dark = clear)"),
        .init(id: "mapGridDotRGB", name: "mapGridDotRGB", kind: .primary, type: .color, bakedDark: "FFFFFF", bakedLight: "2E3A40", note: "map dot colour"),
        .init(id: "mapGridDotOpacity", name: "mapGridDotOpacity", kind: .primary, type: .float, bakedDark: "0.18", bakedLight: "0.47", note: "map dot peak alpha"),
        .init(id: "mapBackground", name: "mapBackground", kind: .primary, type: .color, bakedDark: "111115", bakedLight: "F4EFE3", note: "MAP + card catalogue (CardSurface.groundHex)"),
        .init(id: "cardShadow",    name: "cardShadow",    kind: .primary, type: .color, bakedDark: "000000", bakedLight: "43372A", alphaDark: 0.32, alphaLight: 0.07, note: "card lift (CardSurface)"),
        // RECIPE
        .init(id: "cwParchmentHex",   name: "cwParchmentHex",   kind: .recipe, type: .color, bakedDark: "F4EFE3", bakedLight: "F4EFE3", hasDark: false, note: "light pigment parchment"),
        .init(id: "cwBaseLightness",  name: "cwBaseLightness",  kind: .recipe, type: .float, bakedDark: "0.98", bakedLight: "0.98", hasDark: false, range: 0.85...1.10, note: "≠ CardSurface baseLightness 1.100"),
        .init(id: "cwPigmentStrength", name: "cwPigmentStrength", kind: .recipe, type: .float, bakedDark: "1.0", bakedLight: "1.0", hasDark: false, range: 0...2, note: "pigment strength"),
        // DERIVED (shown for visibility; editing overrides only where the token reads the tuner)
        .init(id: "cardCreamInk",  name: "cardCreamInk (dark)", kind: .derived, type: .color, bakedDark: "FFF9F0", bakedLight: "232A2E", note: "dark fixed cream; light = ink·light"),
        .init(id: "dashboardRim",  name: "dashboardRim",  kind: .derived, type: .color, bakedDark: "FFFFFF", bakedLight: "FFFFFF", alphaDark: 0.12, alphaLight: 0.12, note: "dashboard pane rim"),
    ]
}
#endif
