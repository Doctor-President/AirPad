// Good Flow spike (throwaway, never merged) · the switches (step 3B), one place for the panel and the launch arguments.
// Every switch is also a launch argument of the same name (UserDefaults' argument domain):
//   -Case Detail|Cards|Map   -Theme light|dark   -Glass on|off   -EdgeBend on|off   -Variant A|B|BD75|BD50
//   -Hash stable|bench       -LiveRate 30|60     -Live on|off    -Flat on|off       -DetailFit bench|width
//   -MapCap 128|256 (the Map stills' master cap; 128 = the measured choice)
// Round 2:  -Pools bench|cpu|shader (the pool table, Look.swift GFPools; default bench)
//           -DetailZoom <z> (Mac detail scale: 1 = Bench, band w/h = Width)  -ScrolledBand on|off|only  -DeepFix on|off
//           -Override "fringe=0,grain=0,deep=0,…" (bisecting)
//           -LiveScale 2  -LiveZone card|image  -ScrollRedraw on|off  -Pass2Only YES (timing arm)
//           -Reveal on|off  -RevealSize <pt>  -RevealAnnulus <pt>  -RevealSoft <k>  -RevealStills near|all  -RevealCap  -RevealSlots
// Simulated platform states (the live rule's other inputs; the real APIs are read as well):
//   -SimReduceMotion YES   -SimLowPower YES   -SimThermal serious|critical
import Foundation
import UIKit

extension Notification.Name {
    static let gfSettingsChanged = Notification.Name("gf.settings.changed")
}

final class GFSettings {
    static let shared = GFSettings()

    enum Case: String, CaseIterable { case detail = "Detail", cards = "Cards", map = "Map" }

    var caseName: Case = .detail { didSet { changed("case") } }
    var theme: GFTheme = .light { didSet { changed("theme") } }
    var glass = true { didSet { changed("glass") } }              // on = the bench default, Clear 0.6
    var edgeBend = true { didSet { changed("edgeBend") } }        // on = the bench default, 0.5
    var variant: GFVariant = .A { didSet { changed("variant") } }
    var benchHash = false { didSet { changed("hash") } }          // false = the stable hash (default)
    var liveRate = 30 { didSet { changed("liveRate") } }
    var live = true { didSet { changed("live") } }                // the one live surface of each case (a, b)
    var flat = false { didSet { changed("flat") } }               // the flat control arm
    var detailFitWidth = false { didSet { changed("detailFit") } }// Mac: bench (short side) | width
    var mapCap = 128 { didSet { changed("mapCap") } }             // the Map stills' master size cap (px): 128 meets both memory bars
    var pools: GFPoolsMode = .bench { didSet { changed("pools") } }  // round 2: the pool table (Look.swift GFPools)
    /// Round 2 (outcome 1): the Mac detail field's scale as a zoom over the bench's own sizing (field half-size = zoom ×
    /// half the band's height; Bench = 1, Width = band width / band height). nil = Bench (or Width with -DetailFit width).
    var detailZoom: Double? = nil { didSet { changed("detailZoom") } }
    /// Round 2: the scrolled band (today's AirPad Mac detail: a pinned band fades in as the hero scrolls away), drawn at
    /// Width scale. -ScrolledBand on|off|only (only = the narrow band alone, pinned, at full opacity).
    var scrolledBand = "on" { didSet { changed("scrolledBand") } }
    /// Round 2: uniform overrides for bisecting (-Override "fringe=0,grain=0,deep=0,…"; GFSettings.apply).
    var overrides: [String: Double] = [:] { didSet { changed("overrides") } }
    /// Round 2 (outcome 2): the Map's reveal. -Reveal on|off (off = all Good Flow, round 1), -RevealSize <screen pt>
    /// (an orb's on-screen diameter must be ≥ this), -RevealAnnulus <screen pt> (its centre within this of the view's
    /// centre; AirPad's own lens radius is 300), -RevealSoft <0…0.6> (the blend band), -RevealStills near|all (near = stills
    /// only for orbs near the reveal, filled on demand into a small pool at a higher cap; all = the 262 of round 1).
    var reveal = true { didSet { changed("reveal") } }
    var revealSize = 80.0 { didSet { changed("revealDial") } }
    var revealAnnulus = 300.0 { didSet { changed("revealDial") } }
    var revealSoft = 0.25 { didSet { changed("revealDial") } }
    var revealStills = "near" { didSet { changed("reveal") } }
    var revealCap = 256 { didSet { changed("reveal") } }
    var revealSlots = 48 { didSet { changed("reveal") } }
    /// Round 2 (outcome 4): the phone's live layer. -LiveScale <px per pt> (2 on the 3× phone; default: the display's),
    /// -LiveZone card|image (image = the live card drawn over its image zone only), -ScrollRedraw on|off (default OFF:
    /// a scroll MOVES the live layer and never redraws it; round 1 redrew at the display's rate on every scroll frame).
    var liveScale: Double? = nil { didSet { changed("liveLayer") } }
    var liveZoneImage = false { didSet { changed("liveLayer") } }
    var scrollRedraw = false { didSet { changed("liveLayer") } }
    /// Round 2: the deep pool's tint set everywhere (the dark-cast fix). -DeepFix on|off, default on.
    var deepFix = true { didSet { changed("deepFix") } }

    var simReduceMotion = false { didSet { changed("sim") } }
    var simLowPower = false { didSet { changed("sim") } }
    var simThermal = 0 { didSet { changed("sim") } }              // ProcessInfo.ThermalState raw value to simulate (0 = none)

    var mode: GFDrawMode { GFDrawMode(variant: variant, benchHash: benchHash) }
    private var quiet = false

    private init() {
        let d = UserDefaults.standard
        quiet = true
        func on(_ k: String) -> Bool? { d.string(forKey: k).map { ["on", "yes", "1", "true"].contains($0.lowercased()) } }
        if let c = d.string(forKey: "Case"), let v = Case.allCases.first(where: { $0.rawValue.lowercased() == c.lowercased() }) { caseName = v }
        if let b = d.string(forKey: "Bench"), let v = Case.allCases.first(where: { $0.rawValue.lowercased() == b.lowercased() }) { caseName = v }
        if d.string(forKey: "Theme")?.lowercased() == "dark" { theme = .dark }
        if let v = on("Glass") { glass = v }
        if let v = on("EdgeBend") { edgeBend = v }
        if let v = GFVariant.parse(d.string(forKey: "Variant")) { variant = v }
        if d.string(forKey: "Hash")?.lowercased() == "bench" { benchHash = true }
        if d.integer(forKey: "LiveRate") == 60 { liveRate = 60 }
        if let v = on("Live") { live = v }
        if let v = on("Flat") { flat = v }
        if d.string(forKey: "DetailFit")?.lowercased() == "width" { detailFitWidth = true }
        if d.integer(forKey: "MapCap") > 0 { mapCap = d.integer(forKey: "MapCap") }
        if let v = GFPoolsMode.parse(d.string(forKey: "Pools")) { pools = v }
        if let z = d.string(forKey: "DetailZoom").flatMap(Double.init), z > 0 { detailZoom = z }
        if let v = d.string(forKey: "ScrolledBand")?.lowercased(), ["on", "off", "only"].contains(v) { scrolledBand = v }
        if let v = on("DeepFix") { deepFix = v }
        if let v = d.string(forKey: "LiveScale").flatMap(Double.init), v > 0 { liveScale = v }
        if d.string(forKey: "LiveZone")?.lowercased() == "image" { liveZoneImage = true }
        if let v = on("ScrollRedraw") { scrollRedraw = v }
        if let v = on("Reveal") { reveal = v }
        if let v = d.string(forKey: "RevealSize").flatMap(Double.init) { revealSize = v }
        if let v = d.string(forKey: "RevealAnnulus").flatMap(Double.init) { revealAnnulus = v }
        if let v = d.string(forKey: "RevealSoft").flatMap(Double.init) { revealSoft = v }
        if let v = d.string(forKey: "RevealStills")?.lowercased(), ["near", "all"].contains(v) { revealStills = v }
        if d.integer(forKey: "RevealCap") > 0 { revealCap = d.integer(forKey: "RevealCap") }
        if d.integer(forKey: "RevealSlots") > 0 { revealSlots = d.integer(forKey: "RevealSlots") }
        if let o = d.string(forKey: "Override") { overrides = Self.parseOverrides(o) }
        simReduceMotion = d.bool(forKey: "SimReduceMotion")
        simLowPower = d.bool(forKey: "SimLowPower")
        switch d.string(forKey: "SimThermal")?.lowercased() { case "serious": simThermal = 2; case "critical": simThermal = 3; default: break }
        quiet = false
    }

    private func changed(_ what: String) {
        guard !quiet else { return }
        GFRecorder.shared.mark("switch \(what) → \(describe)")
        NotificationCenter.default.post(name: .gfSettingsChanged, object: self, userInfo: ["what": what])
    }

    /// The housing switches and the flat arm, applied to a card / detail picture's uniforms.
    func apply(_ u: inout GFUniforms) {
        let H = GFLook.shared.housing
        u.glass = glass ? Int32(H["glass"] ?? 1) : 0
        u.lens = edgeBend ? Float(H["lens"] ?? 0.5) : 0
        u.flat = flat ? 1 : 0
        Self.applyOverrides(&u, overrides)
    }
    static func parseOverrides(_ s: String) -> [String: Double] {
        var o: [String: Double] = [:]
        for kv in s.split(whereSeparator: { $0 == "," || $0 == "|" }) {
            let p = kv.split(separator: "="); if p.count == 2, let v = Double(p[1]) { o[String(p[0])] = v }
        }
        return o
    }
    /// Bisecting switches (the shader's own uniforms; keys as the bench names them, lower case).
    static func applyOverrides(_ u: inout GFUniforms, _ o: [String: Double]) {
        for (k, v) in o {
            let f = Float(v)
            switch k {
            case "fringe": u.fringe = f
            case "grain": u.grainOn = v == 0 ? 0 : 1
            case "lineop": u.lineop = f
            case "lines": u.lines = f
            case "glass": u.glass = Int32(v)
            case "lens": u.lens = f
            case "medium": u.medium = f
            case "gmix": u.gmix = f
            case "rim": u.rim = f
            case "contrast": u.contrast = f
            case "sat": u.sat = f
            case "power": u.power = f
            case "deep": u.deepAlways = Int32(v)
            case "fadeB": u.fadeB = f
            default: break
            }
        }
    }

    /// The live rule's platform inputs (design §1): Reduce Motion, Low Power Mode, thermal ≥ serious → the still.
    /// Each is the real API OR its simulation; `liveBlockedBy` names which.
    var liveBlockedBy: String? {
        let pi = ProcessInfo.processInfo
        if UIAccessibility.isReduceMotionEnabled { return "reduceMotion" }
        if simReduceMotion { return "reduceMotion(sim)" }
        if pi.isLowPowerModeEnabled { return "lowPower" }
        if simLowPower { return "lowPower(sim)" }
        if pi.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return "thermal" }
        if simThermal >= ProcessInfo.ThermalState.serious.rawValue { return "thermal(sim)" }
        return nil
    }

    var describe: String {
        "case \(caseName.rawValue) theme \(theme.rawValue) glass \(glass ? "on" : "off") bend \(edgeBend ? "on" : "off") variant \(variant.rawValue) "
            + "hash \(benchHash ? "bench" : "stable") rate \(liveRate) live \(live ? "on" : "off") flat \(flat ? "on" : "off") fit \(detailFitWidth ? "width" : "bench") zoom \(detailZoom.map { String(format: "%.2f", $0) } ?? "-") cap \(mapCap) pools \(pools.rawValue) deepFix \(deepFix ? "on" : "off") band \(scrolledBand) reveal \(reveal ? "on" : "off") \(Int(revealSize))pt/\(Int(revealAnnulus))pt/\(revealSoft) stills \(revealStills) liveScale \(liveScale.map { String($0) } ?? "display") zone \(liveZoneImage ? "image" : "card") scrollRedraw \(scrollRedraw ? "on" : "off")\(GFDraw.pass2OnlyArm ? " PASS2ONLY" : "")" + (overrides.isEmpty ? "" : " override \(overrides)")
            + (simReduceMotion || simLowPower || simThermal > 0 ? " sim[rm \(simReduceMotion) lp \(simLowPower) th \(simThermal)]" : "")
    }
    var dict: [String: Any] {
        ["case": caseName.rawValue, "theme": theme.rawValue, "glass": glass, "edgeBend": edgeBend, "variant": variant.rawValue,
         "hash": benchHash ? "bench" : "stable", "liveRate": liveRate, "live": live, "flat": flat, "detailFit": detailFitWidth ? "width" : "bench", "mapCap": mapCap, "pools": pools.rawValue, "detailZoom": detailZoom ?? -1, "scrolledBand": scrolledBand, "deepFix": deepFix, "reveal": reveal, "revealSize": revealSize, "revealAnnulus": revealAnnulus, "revealSoft": revealSoft, "revealStills": revealStills, "revealCap": revealCap, "revealSlots": revealSlots, "liveScale": liveScale ?? -1, "liveZone": liveZoneImage ? "image" : "card", "scrollRedraw": scrollRedraw, "pass2Only": GFDraw.pass2OnlyArm, "overrides": overrides,
         "simReduceMotion": simReduceMotion, "simLowPower": simLowPower, "simThermal": simThermal]
    }

    /// The page colour (gamma) for a theme, as UIKit wants it.
    static func pageColor(_ t: GFTheme) -> UIColor { color(GFColor.gamma(GFSurfaces(t).page)) }
    static func cardColor(_ t: GFTheme) -> UIColor { color(GFColor.gamma(GFSurfaces(t).card)) }
    static func color(_ g: SIMD3<Double>) -> UIColor { UIColor(red: g.x, green: g.y, blue: g.z, alpha: 1) }
}
