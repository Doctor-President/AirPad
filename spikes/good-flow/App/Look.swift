// Good Flow spike (throwaway, never merged) · look.json and how each case sets the shader's uniforms.
// Mirrors spikes/good-flow/reference/page.html `render()` value for value (the reference stills' uniforms are in
// build/reference/manifest.json; `-RenderStills` writes the port's into uniforms.json and compare.py checks they agree).
import Foundation
import simd

struct GFEntry: Decodable {
    let id: String
    let hue, mass, parts, conn, tempo, amp, patina, seed: Double
}

struct GFLook: Decodable {
    let look: [String: Double]
    let housing: [String: Double]
    let stillTime: Double
    let entries: [GFEntry]

    static let shared: GFLook = {
        let url = Bundle.main.url(forResource: "look", withExtension: "json")!
        return try! JSONDecoder().decode(GFLook.self, from: Data(contentsOf: url))
    }()
    func entry(_ id: String) -> GFEntry { entries.first { $0.id == id } ?? entries[0] }
    func dial(_ k: String) -> Double { look[k] ?? 0 }
}

enum GFTheme: String, CaseIterable { case light, dark
    var ground: Int32 { self == .light ? 1 : 0 }
}

/// Where the look is shown. Sizes in points; `scale` = pixels per point.
struct GFCase {
    enum Kind { case hero, card, orb }
    let name: String
    let kind: Kind
    let w: Double, h: Double, scale: Double
    var r: Double = 0                       // card corner radius (pt)
    var heroRect: (Double, Double, Double, Double) = (0, 0, 1, 1)   // card image zone (pt, y down from the card top)

    var pixelSize: (Int, Int) { (max(2, Int((w * scale).rounded())), max(2, Int((h * scale).rounded()))) }

    /// The reference's cases (page.html CASES), in its order.
    static let reference: [GFCase] = {
        var c: [GFCase] = [
            GFCase(name: "detail-iphone", kind: .hero, w: 440, h: 262, scale: 3),
            GFCase(name: "detail-mac", kind: .hero, w: 1728, h: 252, scale: 2),
            GFCase(name: "card-iphone", kind: .card, w: 348, h: 532, scale: 3, r: 30, heroRect: (0, 0, 348, 212.8)),
            GFCase(name: "card-mac", kind: .card, w: 228, h: 320, scale: 2, r: 14, heroRect: (0, 0, 228, 137.6)),
        ]
        for d in [60.0, 90, 120] { for s in [2.0, 3] {
            c.append(GFCase(name: "orb-\(Int(d))-@\(Int(s))", kind: .orb, w: 1.5 * d, h: 1.5 * d, scale: s))
        } }
        return c
    }()

    /// A detail image at any width (the test screen, part B).
    static func detail(widthPt: Double, heightPt: Double, scale: Double) -> GFCase {
        GFCase(name: "detail", kind: .hero, w: widthPt, h: heightPt, scale: scale)
    }
}

private func frac(_ x: Double) -> Double { x - floor(x) }

/// Linear surfaces (bench drawSlots / page.html surfs()).
struct GFSurfaces {
    let page: SIMD3<Double>, card: SIMD3<Double>, band: SIMD3<Double>
    init(_ t: GFTheme) {
        let g = t == .light
        page = g ? SIMD3(0.83, 0.83, 0.82) : SIMD3(0.0012, 0.0012, 0.0018)
        card = g ? SIMD3(0.94, 0.93, 0.90) : SIMD3(0, 0, 0)
        band = g ? SIMD3(0.90, 0.90, 0.885) : page
    }
}

extension GFUniforms {
    /// The uniforms the reference used for one entry × case × theme at time `time`, faithful (grain on).
    static func make(_ cs: GFCase, _ e: GFEntry, _ theme: GFTheme, look L: GFLook = .shared, time: Double? = nil) -> GFUniforms {
        var u = GFUniforms()
        let sf = GFSurfaces(theme), sc = cs.scale, H = L.housing
        let (w, h) = cs.pixelSize
        func f(_ x: Double) -> Float { Float(x) }
        func v3(_ x: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(x.x), Float(x.y), Float(x.z)) }
        // look dials the Flow path reads (entry-owned dials come from the entry below)
        u.power = f(L.dial("power")); u.size = f(L.dial("size")); u.lsoft = f(L.dial("lsoft")); u.bodyl = f(L.dial("bodyl"))
        u.stir = f(L.dial("stir")); u.detail = f(L.dial("detail")); u.stretch = f(L.dial("stretch")); u.lines = f(L.dial("lines"))
        u.lineop = f(L.dial("lineop")); u.lblend = Int32(L.dial("lblend")); u.fall = Int32(L.dial("fall")); u.fsoft = f(L.dial("fsoft"))
        u.light = f(L.dial("light") * Double.pi / 180); u.spread = f(L.dial("spread")); u.soft = f(L.dial("soft")); u.rim = f(L.dial("rim"))
        u.fringe = f(L.dial("fringe")); u.gmix = f(L.dial("gmix")); u.grain = f(L.dial("grain")); u.contrast = f(L.dial("contrast"))
        u.sat = f(L.dial("sat")); u.flow = f(L.dial("flow")); u.look = Int32(L.dial("look"))
        u.ground = theme.ground
        u.grid = SIMD2(1, 1); u.sheet = 0; u.slot = 1; u.shape = 0; u.live = 0; u.liveT = 0
        u.time = f(time ?? L.stillTime)
        u.back = v3(sf.page)
        u.glass = Int32(H["glass"] ?? 1); u.glassAmt = f(H["glassAmt"] ?? 0.6); u.medium = f(H["medium"] ?? 0.6)
        u.tdrift = f(H["tdrift"] ?? 0.6); u.flute = f(H["flute"] ?? 0.45); u.pt = f(sc); u.lens = f(H["lens"] ?? 0.5)
        u.res = SIMD2(Float(w), Float(h)); u.org = SIMD2(0, 0)
        let fit = 0.986 * 1.3 / 1.5
        var cx = 0.0, cy = 0.0, zoom = 1.0, mass = e.mass, theme_: Int32 = 1, tank: Int32 = 2, mask: Int32 = 0, maskR = 0.0
        var surf = sf.band, fadeV = SIMD2<Double>(0, 0), fadeB = 0.0, tankH = SIMD2<Double>(1, 1)
        switch cs.kind {
        case .hero: surf = sf.band; fadeB = 0.24
        case .card:
            let (hx, hy, hw, hh) = cs.heroRect, hmn = min(hw, hh), hf = hh / cs.h
            cx = (hx + hw / 2 - cs.w / 2) * sc; cy = -(hy + hh / 2 - cs.h / 2) * sc
            tankH = SIMD2(hw / hmn, hh / hmn); mask = 1; maskR = cs.r * sc; surf = sf.card; fadeV = SIMD2(hf * 0.62, hf)
        case .orb:
            theme_ = 0; tank = 0; surf = sf.page; zoom = fit; mass = 1
        }
        u.theme = theme_; u.tank = tank; u.tankH = SIMD2(f(tankH.x), f(tankH.y)); u.fadeB = f(fadeB)
        u.fadeV = SIMD2(f(fadeV.x), f(fadeV.y)); u.fade = SIMD2(0, 0)
        u.mask = mask; u.maskR = f(maskR); u.maskR2 = 0; u.surf = v3(surf); u.ctr = SIMD2(f(cx), f(cy)); u.zoom = f(zoom)
        u.rot = f((frac(sin(e.seed * 91.7) * 43758.5453) - 0.5) * 1.4)
        u.hue = f(e.hue); u.mass = f(mass); u.parts = f(e.parts); u.conn = f(e.conn); u.tempo = f(e.tempo)
        u.amp = f(e.amp); u.patina = f(e.patina); u.seed = f(e.seed)
        u.grainOn = 1; u.flat = 0
        return u
    }

    /// The bench's names for the values (for uniforms.json, checked against the reference manifest).
    var benchNamed: [String: Any] {
        func a2(_ v: SIMD2<Float>) -> [Double] { [Double(v.x), Double(v.y)] }
        func a3(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }
        return [
            "uRes": a2(res), "uCtr": a2(ctr), "uFade": a2(fade), "uFadeV": a2(fadeV), "uTankH": a2(tankH), "uGrid": a2(grid),
            "uBack": a3(back), "uSurf": a3(surf), "uZoom": zoom, "uMaskR": maskR, "uMaskR2": maskR2, "uRot": rot,
            "uGlassAmt": glassAmt, "uMedium": medium, "uTdrift": tdrift, "uFlute": flute, "uPt": pt, "uFadeB": fadeB, "uLens": lens,
            "uTime": time, "uLiveT": liveT, "uHue": hue, "uMass": mass, "uParts": parts, "uConn": conn, "uTempo": tempo, "uAmp": amp,
            "uPatina": patina, "uSeed": seed, "uSoft": soft, "uRim": rim, "uFringe": fringe, "uSpread": spread, "uGrain": grain,
            "uLight": light, "uPower": power, "uSize": size, "uLsoft": lsoft, "uBodyl": bodyl, "uGmix": gmix, "uContrast": contrast,
            "uSat": sat, "uStir": stir, "uDetail": detail, "uStretch": stretch, "uLines": lines, "uLineop": lineop, "uFsoft": fsoft,
            "uFlow": flow, "uSlot": slot, "uMask": mask, "uTank": tank, "uGlass": glass, "uTheme": theme, "uShape": shape,
            "uGround": ground, "uLook": look, "uFall": fall, "uLblend": lblend, "uLive": live, "uSheet": sheet,
        ].mapValues { v -> Any in
            if let x = v as? Float { return Double(x) }
            if let x = v as? Int32 { return Int(x) }
            return v
        }
    }
}
