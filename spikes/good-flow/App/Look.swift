// Good Flow spike (throwaway, never merged) · look.json and how each case sets the shader's uniforms.
// Mirrors spikes/good-flow/reference/page.html `render()` value for value (the reference stills' uniforms are in
// build/reference/manifest.json; `-RenderStills` writes the port's into uniforms.json and compare.py checks they agree).
import Foundation
import simd

struct GFEntry: Decodable {
    let id: String
    let hue, mass, parts, conn, tempo, amp, patina, seed: Double
    /// Round 2 (outcome 5): the bench's own pool table for this entry (6 × [h1, h2, h3]), as headless Chrome (ANGLE Metal,
    /// M1 Max) computed it: tools/bench_pools.mjs. nil for the invented library entries (the CPU works theirs out).
    var pools: [[Double]]? = nil
    init(id: String, hue: Double, mass: Double, parts: Double, conn: Double, tempo: Double, amp: Double, patina: Double, seed: Double) {
        self.id = id; self.hue = hue; self.mass = mass; self.parts = parts; self.conn = conn; self.tempo = tempo; self.amp = amp
        self.patina = patina; self.seed = seed
    }
}

/// Round 2 (outcome 5): the pool table. hash11 = fract(sin(n·127.1)·43758.5453) only places and sizes the six pools, once
/// per entry; on the GPU its sin is the chip's fast sin, which differs per GPU family (the phone drew every entry
/// differently, 0/120). Worked out here instead and passed in (GFUniforms.pool), every chip draws the same entry the same way.
///   bench  (default) the bench's own values where look.json has them (e0–e5: T's bench draw), the CPU's for the rest
///   cpu    the CPU's for every entry (what a real build would compute: double-precision sin, the same on every device)
///   shader the old in-shader hash (with -Hash stable|bench), for comparison
enum GFPoolsMode: String, CaseIterable { case bench, cpu, shader
    static func parse(_ s: String?) -> GFPoolsMode? { s.flatMap { v in allCases.first { $0.rawValue == v.lowercased() } } }
}
enum GFPools {
    /// The three hash values of pool i, worked out on the CPU: the argument in float32 as the shader forms it, sin in double.
    static func cpu(seed: Double, i: Int) -> SIMD3<Float> {
        func h(_ a: Float, _ b: Float) -> Float {
            let fi = Float(i), sd = Float(seed)
            let n = Double(fi * a + sd * b)
            let x = sin(n * 127.1) * 43758.5453
            return Float(x - floor(x))
        }
        return SIMD3(h(7.3, 19), h(3.9, 29), h(5.7, 7))
    }
    static func table(_ e: GFEntry, _ mode: GFPoolsMode) -> [SIMD3<Float>] {
        if mode == .bench, let p = e.pools, p.count == 6 { return p.map { SIMD3(Float($0[0]), Float($0[1]), Float($0[2])) } }
        return (0..<6).map { cpu(seed: e.seed, i: $0) }
    }
    static func apply(_ u: inout GFUniforms, _ e: GFEntry, _ mode: GFPoolsMode) {
        guard mode != .shader else { u.poolTable = 0; return }
        let t = table(e, mode).map { SIMD4<Float>($0, 0) }
        u.pool = (t[0], t[1], t[2], t[3], t[4], t[5]); u.poolTable = 1
    }
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

    /// A detail image at any width (case a).
    static func detail(widthPt: Double, heightPt: Double, scale: Double) -> GFCase {
        GFCase(name: "detail", kind: .hero, w: widthPt, h: heightPt, scale: scale)
    }
    /// A card with its image zone on top (`heroFrac` of its height): the Mac grid tile (228 × 320, r 14, 0.43) or the
    /// iPhone carousel card (348 × 532, r 30, 0.40).
    static func card(w: Double, h: Double, r: Double, heroFrac: Double, scale: Double) -> GFCase {
        GFCase(name: "card", kind: .card, w: w, h: h, scale: scale, r: r, heroRect: (0, 0, w, h * heroFrac))
    }
    /// An orb's padded slot (1.5 × D) at `scale`.
    static func orb(diam: Double, scale: Double) -> GFCase {
        GFCase(name: "orb", kind: .orb, w: 1.5 * diam, h: 1.5 * diam, scale: scale)
    }
}

/// The synthetic library (cases b and c): 262 invented entries, e0–e5 among them (the first six), the rest spread so
/// small and large, quiet and busy entries all show. Nothing here comes from a real library. Deterministic.
struct GFLibrary {
    struct Item {
        let entry: GFEntry
        let items: Int          // the entry's item count (the Map orb's size: 60 pt + 8 per further item, 120 at most)
        let cluster: Int
        /// Round 2 (outcome 2): the entry's REGION (the Map is coloured by region, ruled 11-18): six regions over the
        /// eight loose clusters (cluster mod 6), so two regions are split across two places, as a real region can be.
        var region: Int { cluster % GFColor.regions.count }
        var diam: Double { min(60 + 8 * Double(items - 1), 120) }
        var title: String { "Entry \(entry.id.dropFirst()) · placeholder title" }
    }
    let items: [Item]
    /// Map positions (world pt, y up), no two orbs closer than their radii + a gap.
    let positions: [SIMD2<Double>]
    static let shared = GFLibrary(count: 262)

    struct RNG { var s: UInt64
        mutating func next() -> Double { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; z ^= z >> 31; return Double(z >> 11) / Double(1 << 53) }
        mutating func gauss() -> Double { let u = max(next(), 1e-9), v = next(); return sqrt(-2 * log(u)) * cos(2 * .pi * v) }
    }

    init(count: Int) {
        var r = RNG(s: 0x600D_F10E)
        let L = GFLook.shared
        let clusters = 8
        let clusterHue = (0..<clusters).map { Double($0) * 45 + 12 }
        let fixedItems = [3, 1, 2, 4, 7, 9]                      // e0…e5: one of each size band, two large
        func drawItems() -> Int {
            let x = r.next()
            let cdf: [(Double, Int)] = [(0.50, 1), (0.67, 2), (0.77, 3), (0.84, 4), (0.89, 5), (0.92, 6), (0.94, 7), (0.96, 8)]
            for (p, n) in cdf where x < p { return n }
            return 9 + Int(r.next() * 4)                         // the tail: 120 pt
        }
        var out: [Item] = []
        for k in 0..<count {
            let c = k % clusters
            if k < L.entries.count && k < 6 {
                out.append(Item(entry: L.entries[k], items: fixedItems[k], cluster: c)); continue
            }
            let e = GFEntry(id: "e\(k)", hue: (clusterHue[c] + r.gauss() * 22 + 360).truncatingRemainder(dividingBy: 360),
                            mass: pow(r.next(), 1.4), parts: 1 + 4 * r.next(), conn: r.next(), tempo: 0.05 + 0.9 * r.next(),
                            amp: 0.1 + 0.85 * r.next(), patina: r.next(), seed: r.next())
            out.append(Item(entry: e, items: drawItems(), cluster: c))
        }
        items = out
        // Placement: 8 loose clusters on a ring, each orb by rejection around its cluster's centre, no overlap.
        let centres = (0..<clusters).map { i -> SIMD2<Double> in
            let a = Double(i) / Double(clusters) * 2 * .pi + 0.3
            let rad = 1050.0 + 220 * sin(Double(i) * 1.7)
            return SIMD2(rad * cos(a) * 1.25, rad * sin(a) * 0.85)
        }
        var pos: [SIMD2<Double>] = []
        for (k, it) in out.enumerated() {
            var spread = 120.0, placed = false
            while !placed {
                for _ in 0..<60 {
                    let p = centres[it.cluster] + SIMD2(r.gauss() * spread, r.gauss() * spread)
                    let ok = pos.enumerated().allSatisfy { j, q in
                        let dj = out[j].diam, gap = 0.15 * max(dj, it.diam) + 6
                        return simd_length(p - q) >= (dj + it.diam) / 2 + gap
                    }
                    if ok { pos.append(p); placed = true; break }
                }
                spread *= 1.15
            }
            _ = k
        }
        positions = pos
    }
}

/// The bench's `vivid()` (OKLab), on the CPU: the flat fills shown until a still lands.
enum GFColor {
    static func vivid(_ hdeg: Double) -> SIMD3<Double> {
        let h = hdeg * .pi / 180
        let L = 0.66, a = 0.11 * cos(h), b = 0.11 * sin(h)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b, m_ = L - 0.1055613458 * a - 0.0638541728 * b, s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        var c = SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        c -= SIMD3(repeating: min(c.x, c.y, c.z) * 0.93)
        c /= max(c.x, c.y, c.z, 1e-4)
        let lum = max(c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722, 0.03)
        return c * pow(0.45 / lum, 0.22)
    }
    /// A gamma-encoded flat colour in the entry's hue on the theme's ground (roughly what the still will show).
    static func flat(_ hue: Double, _ theme: GFTheme) -> SIMD3<Double> {
        let v = simd_min(vivid(hue), SIMD3(repeating: 1))
        let lin = theme == .light ? simd_mix(SIMD3(0.9, 0.9, 0.885), v, SIMD3(repeating: 0.7)) : v * 0.55
        return SIMD3(pow(lin.x, 1 / 2.2), pow(lin.y, 1 / 2.2), pow(lin.z, 1 / 2.2))
    }
    /// Round 2: the plain orbs' region colours (gamma-encoded sRGB, as hex).
    static let regionHex: [UInt32] = [0x1B59C2, 0xE8820A, 0x2E9E6A, 0xC2365F, 0x7B5CC7, 0x00A3C4]
    static var regions: [SIMD3<Double>] { regionHex.map { SIMD3(Double(($0 >> 16) & 0xFF), Double(($0 >> 8) & 0xFF), Double($0 & 0xFF)) / 255 } }
    static func gamma(_ lin: SIMD3<Double>) -> SIMD3<Double> { SIMD3(pow(lin.x, 1 / 2.2), pow(lin.y, 1 / 2.2), pow(lin.z, 1 / 2.2)) }
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
        u.grainOn = 1; u.flat = 0; u.fwScale = 1
        GFPools.apply(&u, e, GFSettings.shared.pools)
        u.deepAlways = GFSettings.shared.deepFix ? 1 : 0
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
