import SwiftUI
import UIKit

/// ws-dark-light-mode — Map (canvas) live tuner. Same three-part shape as
/// `SolarFlareTuning` (Key enum + Defaults enum + `#if DEBUG` panel), but the
/// Map is a SpriteKit surface, so the render side PULLS values from
/// `UserDefaults` (the scene / layout / shader read `MapTuning.*`) rather than
/// relying on `@AppStorage` auto-observation.
///
/// SHIP DIALS, NOT VALUES — every default below is the CURRENT shipped value,
/// so the tuner is a no-op until T moves a slider. T is colorblind: colors are
/// a NAMED picker (hex in code, verifiable), never a hue swatch.
///
/// Four groups (T's asks): background color · dot matrix (size / opacity /
/// spacing / recursion) · node scale + spacing · label font.

// MARK: - Keys

enum MapTuningKey {
    static let on            = "map.tuner.on"            // master gate — off = defaults, tuner ignored
    // Background — custom RGB hex (the color picker writes these)
    static let bgDarkHex      = "map.bg.darkHex"         // #07070A shipped
    static let bgLightHex     = "map.bg.lightHex"        // #F4EFE3 shipped
    // Dot matrix
    static let dotSizePx      = "map.dot.sizePx"         // BackgroundGridNode dotBasePx (1.5)
    static let dotOpacity     = "map.dot.opacity"        // baseOpac (0.25)
    static let dotPeriod      = "map.dot.period"         // p1 dominant period (50)
    static let dotRatio       = "map.dot.ratio"          // lattice nest ratio N → N×N dots per cell (5 = 25)
    static let dotLevels      = "map.dot.levels"         // recursion: 1 / 2 / 3 (default 3)
    // Node
    static let nodeBaseRadius = "map.node.baseRadius"    // bubbleRadius base (30)
    static let nodePerItem    = "map.node.perItem"       // +radius per item (4)
    static let nodeRadiusCap  = "map.node.radiusCap"     // cap (60)
    static let nodeRingSpacing = "map.node.ringSpacing"  // TagTerritoryLayout.nodeRingSpacing (82) — LAYOUT, not in tuner
    static let territoryRadius = "map.node.territoryRadius" // territoryRingRadius (720) — LAYOUT, not in tuner
    static let nodeSizeScale  = "map.node.sizeScale"     // live draw-scale × on node sprites (1.0)
    // Label
    static let labelFont      = "map.label.font"         // segmented: condensed / sans / serif
    static let labelMaxSize   = "map.label.maxSize"      // fittedTitleFont ceiling (18)
}

// MARK: - Defaults (== current shipped values)

enum MapTuningDefaults {
    static let on = false
    static let bgDarkHex   = "07070A"        // shipped canvas base (Void)
    static let bgLightHex  = "F4EFE3"        // Cucumber Water first pass (Cream)
    static let dotSizePx: Double   = 1.5
    static let dotOpacity: Double  = 0.25
    static let dotPeriod: Double   = 50
    static let dotRatio: Double    = 5        // 5×5 = 25 dots per cell — the shipped ratio-5 nesting
    static let dotLevels: Int      = 3
    static let nodeBaseRadius: Double = 30
    static let nodePerItem: Double    = 4
    static let nodeRadiusCap: Double  = 60
    static let nodeRingSpacing: Double = 82
    static let territoryRadius: Double = 720
    static let nodeSizeScale: Double = 1.0    // shipped size (no scale)
    static let labelFont = "Condensed"        // current: SF condensed semibold
    static let labelMaxSize: Double = 18
}

// MARK: - Named colors (colorblind-safe: hex in code, picked by name)

enum MapNamedColor: String, CaseIterable {
    // dark options
    case pureBlack = "Pure Black"   // #000000 — the "surfaces float in a void" problem
    case voidBlue  = "Void"         // #07070A — shipped canvas base
    case darkGrey  = "Dark Grey"    // #1A1A1A — the detail-view ground (T: "should be a dark grey")
    case slate     = "Slate"        // #22242A
    // light options
    case cream     = "Cream"        // #F4EFE3 — Cucumber Water parchment
    case paper     = "Paper"        // #FAF6EC — brighter warm
    case white     = "White"        // #FFFFFF

    var hex: String {
        switch self {
        case .pureBlack: return "000000"
        case .voidBlue:  return "07070A"
        case .darkGrey:  return "1A1A1A"
        case .slate:     return "22242A"
        case .cream:     return "F4EFE3"
        case .paper:     return "FAF6EC"
        case .white:     return "FFFFFF"
        }
    }
}

enum MapLabelFont: String, CaseIterable {
    case condensed = "Condensed"   // SF condensed semibold (current)
    case sans      = "Sans"        // SF regular (non-condensed — T's "before")
    case serif     = "Serif"       // Source Serif 4 Bold (the pre-1fc49b8 resting label)
}

// MARK: - Read helpers (the render side pulls these)

/// Static reads for the SpriteKit scene / layout / shader. Every getter returns
/// the shipped default when the tuner is OFF, so nothing changes until T opts in.
enum MapTuning {
    private static var d: UserDefaults { .standard }

    /// ws-chat-lane scar gate. The tuner's UI + every `@AppStorage` live inside
    /// `#if DEBUG` (MapTuningPanel), but these read helpers do NOT — the render
    /// side calls them every frame, so an ungated `isOn` would query UserDefaults
    /// per frame in a RELEASE build, on the Map (the surface already carrying an
    /// open render-cost item). Gate the read path: in Release `isOn` is a
    /// compile-time `false`, so every dbl/int/str short-circuits to its shipped
    /// default with ZERO UserDefaults access. The tuner is a pure no-op in
    /// Release; it only touches UserDefaults in DEBUG, where the panel exists.
    static var isOn: Bool {
        #if DEBUG
        return d.object(forKey: MapTuningKey.on) as? Bool ?? MapTuningDefaults.on
        #else
        return false
        #endif
    }

    private static func dbl(_ key: String, _ def: Double) -> Double {
        guard isOn, d.object(forKey: key) != nil else { return def }
        return d.double(forKey: key)
    }
    private static func int(_ key: String, _ def: Int) -> Int {
        guard isOn, d.object(forKey: key) != nil else { return def }
        return d.integer(forKey: key)
    }
    private static func str(_ key: String, _ def: String) -> String {
        guard isOn, let v = d.string(forKey: key) else { return def }
        return v
    }

    // Background — resolves the custom RGB hex for the current interface style.
    static func backgroundColor(dark: Bool) -> UIColor {
        let hex = dark
            ? str(MapTuningKey.bgDarkHex, MapTuningDefaults.bgDarkHex)
            : str(MapTuningKey.bgLightHex, MapTuningDefaults.bgLightHex)
        return UIColor(Color(hexString: hex))
    }

    // Dot matrix
    static var dotSizePx: Float  { Float(dbl(MapTuningKey.dotSizePx, MapTuningDefaults.dotSizePx)) }
    static var dotOpacity: Float { Float(dbl(MapTuningKey.dotOpacity, MapTuningDefaults.dotOpacity)) }
    static var dotPeriod: Float  { Float(dbl(MapTuningKey.dotPeriod, MapTuningDefaults.dotPeriod)) }
    static var dotRatio: Float   { Float(dbl(MapTuningKey.dotRatio, MapTuningDefaults.dotRatio)) }
    static var dotLevels: Int    { int(MapTuningKey.dotLevels, MapTuningDefaults.dotLevels) }

    // Node
    static var nodeBaseRadius: CGFloat { CGFloat(dbl(MapTuningKey.nodeBaseRadius, MapTuningDefaults.nodeBaseRadius)) }
    static var nodePerItem: CGFloat    { CGFloat(dbl(MapTuningKey.nodePerItem, MapTuningDefaults.nodePerItem)) }
    static var nodeRadiusCap: CGFloat  { CGFloat(dbl(MapTuningKey.nodeRadiusCap, MapTuningDefaults.nodeRadiusCap)) }
    static var nodeRingSpacing: CGFloat { CGFloat(dbl(MapTuningKey.nodeRingSpacing, MapTuningDefaults.nodeRingSpacing)) }
    static var territoryRadius: CGFloat { CGFloat(dbl(MapTuningKey.territoryRadius, MapTuningDefaults.territoryRadius)) }
    static var nodeSizeScale: CGFloat  { CGFloat(dbl(MapTuningKey.nodeSizeScale, MapTuningDefaults.nodeSizeScale)) }

    // Label
    static var labelFont: MapLabelFont {
        MapLabelFont(rawValue: str(MapTuningKey.labelFont, MapTuningDefaults.labelFont)) ?? .condensed
    }
    static var labelMaxSize: CGFloat { CGFloat(dbl(MapTuningKey.labelMaxSize, MapTuningDefaults.labelMaxSize)) }
}

// MARK: - Panel (DEBUG only)

#if DEBUG
/// Posted by the tuner's "Measure label cost" button; `CanvasView` observes it
/// and calls the scene's `measureLabelCost()` (prints resident label-texture
/// memory + full re-raster time — the SDF-migration numbers).
extension Notification.Name {
    static let mapTunerMeasureLabels = Notification.Name("mapTunerMeasureLabels")
}

/// Floating, draggable Map tuner. Mount inside `CanvasChrome`'s DEBUG block.
struct MapTuningPanel: View {
    @Binding var isPresented: Bool
    @Binding var position: CGSize

    @AppStorage(MapTuningKey.on) private var on = MapTuningDefaults.on
    @AppStorage(MapTuningKey.bgDarkHex) private var bgDarkHex = MapTuningDefaults.bgDarkHex
    @AppStorage(MapTuningKey.bgLightHex) private var bgLightHex = MapTuningDefaults.bgLightHex
    @AppStorage(MapTuningKey.dotSizePx) private var dotSize = MapTuningDefaults.dotSizePx
    @AppStorage(MapTuningKey.dotOpacity) private var dotOpacity = MapTuningDefaults.dotOpacity
    @AppStorage(MapTuningKey.dotPeriod) private var dotPeriod = MapTuningDefaults.dotPeriod
    @AppStorage(MapTuningKey.dotRatio) private var dotRatio = MapTuningDefaults.dotRatio
    @AppStorage(MapTuningKey.dotLevels) private var dotLevels = MapTuningDefaults.dotLevels
    @AppStorage(MapTuningKey.nodeSizeScale) private var nodeSizeScale = MapTuningDefaults.nodeSizeScale
    @AppStorage(MapTuningKey.labelFont) private var labelFont = MapTuningDefaults.labelFont
    @AppStorage(MapTuningKey.labelMaxSize) private var labelMaxSize = MapTuningDefaults.labelMaxSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Tuner ON (off = shipped defaults)", isOn: $on)
                        .font(.caption.weight(.semibold))

                    section("Background — RGB picker (hex shown for verification)")
                    colorRow("Dark (Solar Flare)", $bgDarkHex, presets: [.pureBlack, .voidBlue, .darkGrey, .slate])
                    colorRow("Light (Cucumber Water)", $bgLightHex, presets: [.cream, .paper, .white])

                    section("Dot matrix — T: “recursive dot matrix is too much”")
                    slider("Dot size (px)", $dotSize, 0.4...4, 0.1)
                    slider("Dot opacity", $dotOpacity, 0.0...0.6, 0.01)
                    slider("Spacing / period", $dotPeriod, 20...160, 1)
                    slider("Subdivision N (N×N per cell — 5 = 25)", $dotRatio, 2...8, 1)
                    stepper("Recursion levels (1 = off)", $dotLevels, 1...3)

                    section("Node size — LIVE ×  (spacing/territory are layout — not tunable here)")
                    slider("Node size ×  (>1 may overlap — positions are fixed)", $nodeSizeScale, 0.5...2.0, 0.05)

                    section("Label — T: condensed → wants the denser ‘before’")
                    fontPicker
                    slider("Max font size", $labelMaxSize, 10...28, 1)

                    HStack(spacing: 12) {
                        Button("Copy values") { copyValues() }
                        Button("Measure label cost") {
                            NotificationCenter.default.post(name: .mapTunerMeasureLabels, object: nil)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                }
                .padding(12)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 300)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))
        .foregroundStyle(.white)
        .shadow(radius: 20, y: 8)
        .offset(position)
    }

    private var header: some View {
        HStack {
            Text("MAP TUNER").font(.caption2.weight(.bold)).tracking(1)
            Spacer()
            Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(white: 0.16))
        .contentShape(Rectangle())
        .gesture(DragGesture().onChanged { position = CGSize(width: $0.translation.width + dragStart.width,
                                                             height: $0.translation.height + dragStart.height) }
            .onEnded { _ in dragStart = position })
    }
    @State private var dragStart: CGSize = .zero

    private func section(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.5))
            .padding(.top, 8)
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2)
                Spacer()
                Text(String(format: "%.2f", v.wrappedValue)).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.7))
            }
            Slider(value: v, in: range, step: step).disabled(!on)
        }
    }

    private func stepper(_ label: String, _ v: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        Stepper(value: v, in: range) {
            HStack { Text(label).font(.caption2); Spacer(); Text("\(v.wrappedValue)").font(.caption2.monospaced()) }
        }.disabled(!on)
    }

    /// RGB color row: a system `ColorPicker` (its sheet has RGB sliders + a hex
    /// field) + a monospace hex readout — T is colorblind and reads/enters hex,
    /// never a swatch — + a quick preset menu that writes the hex.
    private func colorRow(_ label: String, _ hex: Binding<String>, presets: [MapNamedColor]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption2)
                Spacer()
                Text("#\(hex.wrappedValue)").font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.7))
                ColorPicker("", selection: colorBinding(hex), supportsOpacity: false)
                    .labelsHidden().frame(width: 28).disabled(!on)
            }
            Menu {
                ForEach(presets, id: \.hex) { c in
                    Button("\(c.rawValue)  #\(c.hex)") { hex.wrappedValue = c.hex }
                }
            } label: {
                HStack(spacing: 3) { Image(systemName: "eyedropper.halffull"); Text("presets") }
                    .font(.caption2).foregroundStyle(.white.opacity(0.6))
            }.disabled(!on)
        }
    }

    /// Bridges the hex `@AppStorage` to `ColorPicker`'s `Binding<Color>`.
    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hexString: hex.wrappedValue) },
                set: { hex.wrappedValue = Self.hex6(from: $0) })
    }

    /// SwiftUI `Color` → 6-digit sRGB hex (no `#`).
    private static func hex6(from color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func ch(_ v: CGFloat) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
        return String(format: "%02X%02X%02X", ch(r), ch(g), ch(b))
    }

    private var fontPicker: some View {
        Picker("Font", selection: $labelFont) {
            ForEach(MapLabelFont.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
        }.pickerStyle(.segmented).disabled(!on)
    }

    private func copyValues() {
        UIPasteboard.general.string = """
        map.tuner.on: \(on)
        bg.darkHex: #\(bgDarkHex)  bg.lightHex: #\(bgLightHex)
        dot.size: \(dotSize)  dot.opacity: \(dotOpacity)  dot.period: \(dotPeriod)  dot.ratio: \(dotRatio)  dot.levels: \(dotLevels)
        node.sizeScale: \(nodeSizeScale)
        label.font: \(labelFont)  label.maxSize: \(labelMaxSize)
        """
    }
}
#endif
