// Good Flow spike (throwaway, never merged) · the switches (step 3B), one place for the panel and the launch arguments.
// Every switch is also a launch argument of the same name (UserDefaults' argument domain):
//   -Case Detail|Cards|Map   -Theme light|dark   -Glass on|off   -EdgeBend on|off   -Variant A|B|BD75|BD50
//   -Hash stable|bench       -LiveRate 30|60     -Live on|off    -Flat on|off       -DetailFit bench|width
//   -MapCap 128|256 (the Map stills' master cap; 128 = the measured choice)
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
            + "hash \(benchHash ? "bench" : "stable") rate \(liveRate) live \(live ? "on" : "off") flat \(flat ? "on" : "off") fit \(detailFitWidth ? "width" : "bench") cap \(mapCap)"
            + (simReduceMotion || simLowPower || simThermal > 0 ? " sim[rm \(simReduceMotion) lp \(simLowPower) th \(simThermal)]" : "")
    }
    var dict: [String: Any] {
        ["case": caseName.rawValue, "theme": theme.rawValue, "glass": glass, "edgeBend": edgeBend, "variant": variant.rawValue,
         "hash": benchHash ? "bench" : "stable", "liveRate": liveRate, "live": live, "flat": flat, "detailFit": detailFitWidth ? "width" : "bench", "mapCap": mapCap,
         "simReduceMotion": simReduceMotion, "simLowPower": simLowPower, "simThermal": simThermal]
    }

    /// The page colour (gamma) for a theme, as UIKit wants it.
    static func pageColor(_ t: GFTheme) -> UIColor { color(GFColor.gamma(GFSurfaces(t).page)) }
    static func cardColor(_ t: GFTheme) -> UIColor { color(GFColor.gamma(GFSurfaces(t).card)) }
    static func color(_ g: SIMD3<Double>) -> UIColor { UIColor(red: g.x, green: g.y, blue: g.z, alpha: 1) }
}
