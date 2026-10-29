//  TitleInkRule.swift
//  1.1-A (4) — ONE deterministic title-ink rule for every Map look × palette × ground.
//
//  The rule (pure: samples in, ink + halo out): sample the colours a look actually draws under an orb's title box
//  (`TitleInkTwin`, a CPU twin per look, ground showing through where the orb is transparent or faint), take each of the
//  look's two candidate inks, score each by its WORST-case WCAG contrast over every sample, and pick the better. When
//  neither reaches 4.5:1 the title also gets a soft halo in the other ink. The ground is an explicit input to every twin
//  that lets it show through, so a custom background (1.1-B) plugs in as one parameter.

import simd

enum TitleInkRule {
    /// A look's two candidate inks (sRGB 0…1).
    struct Inks: Equatable {
        var light: SIMD3<Float>
        var dark: SIMD3<Float>
    }

    struct Pick: Equatable {
        var ink: SIMD3<Float>
        /// The other ink, drawn as a soft halo (nil = no halo).
        var halo: SIMD3<Float>?
        /// The chosen ink's worst-case contrast over the samples.
        var worst: Float
        var lightInk: Bool
    }

    /// WCAG AA body-text contrast.
    static let minContrast: Float = 4.5
    /// The halo's peak opacity (the shader fades it to 0 over the glyph field's reach just outside the outline).
    static let haloAlpha: Float = 0.55

    /// The study looks' inks (Aura · Eclipse · Wash · Riso · Gradient): #F4F2F8 / #1B1A20.
    static let studyInks = Inks(light: SIMD3(0xF4, 0xF2, 0xF8) / 255, dark: SIMD3(0x1B, 0x1A, 0x20) / 255)
    /// Flat / Outline (and the dark half of Fresnel / Glass): the warm off-white / near-black pair (`legibleInk`).
    static let legibleInks = Inks(light: SIMD3(1.0, 0.98, 0.95), dark: SIMD3(0.08, 0.07, 0.06))

    /// WCAG 2.x relative luminance of an sRGB colour.
    static func relLum(_ c: SIMD3<Float>) -> Float {
        func lin(_ v: Float) -> Float { let x = min(max(v, 0), 1); return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
    }
    static func contrast(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let la = relLum(a), lb = relLum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    /// The ink's contrast against its worst sample (21 = no samples).
    static func worstContrast(_ ink: SIMD3<Float>, over samples: [SIMD3<Float>]) -> Float {
        var w: Float = 21
        for s in samples { w = min(w, contrast(ink, s)) }
        return w
    }

    /// THE rule. Ties go to the light ink (as `legibleInk` did).
    static func pick(samples: [SIMD3<Float>], inks: Inks, minContrast: Float = minContrast) -> Pick {
        let wl = worstContrast(inks.light, over: samples), wd = worstContrast(inks.dark, over: samples)
        let light = wl >= wd
        let w = max(wl, wd)
        let other = light ? inks.dark : inks.light
        return Pick(ink: light ? inks.light : inks.dark, halo: w < minContrast && inks.light != inks.dark ? other : nil,
                    worst: w, lightInk: light)
    }

    /// A title's box in orb radii, y up, as a 7 × 5 grid of sample points over ± halfWidth × ± halfHeight — the extent of
    /// the set type (its widest line × its lines' cap-height span), so only what is actually under the letters counts.
    static func box(halfWidth hw: Float, halfHeight hh: Float) -> [SIMD2<Float>] {
        (0..<5).flatMap { iy in (0..<7).map { ix in SIMD2<Float>(hw * (-1 + Float(ix) / 3), hh * (-1 + Float(iy) / 2)) } }
    }
    /// When the set type isn't known: live-45's sampled box, ± 0.6 × ± 0.35 (the middle of the 1.4-radius label box).
    static let titleBox: [SIMD2<Float>] = box(halfWidth: 0.6, halfHeight: 0.35)
}

/// CPU twins of what each Map look draws under a title's box (`TitleInkRule.box`), one sRGB colour per sample point.
/// Every twin is a port of its shader's maths at those points; what each leaves out is named on it. Inputs are the
/// colours the shader is given (the orb's colour after the Map's own boost / translate, the study stops) and the GROUND.
enum TitleInkTwin {
    typealias C3 = SIMD3<Float>

    // MARK: shared maths (the shaders', float for float)

    static func ss(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let u = min(max((x - e0) / (e1 - e0), 0), 1); return u * u * (3 - 2 * u)
    }
    static func mix(_ a: C3, _ b: C3, _ t: Float) -> C3 { a + (b - a) * t }
    static func clamp01(_ c: C3) -> C3 { simd_clamp(c, C3(repeating: 0), C3(repeating: 1)) }
    static func fract(_ x: Float) -> Float { x - x.rounded(.down) }
    static func hash(_ x: Float, _ y: Float) -> Float {
        var p = C3(fract(x * 0.1031), fract(y * 0.1031), fract(x * 0.1031))
        let d = p.x * (p.y + 33.33) + p.y * (p.z + 33.33) + p.z * (p.x + 33.33)
        p += C3(repeating: d)
        return fract((p.x + p.y) * p.z)
    }
    static func noise(_ x: Float, _ y: Float) -> Float {
        let ix = x.rounded(.down), iy = y.rounded(.down), fx = x - ix, fy = y - iy
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
    }
    /// The study's 3-octave fbm (= StudyNoise's texture, which the shaders sample).
    static func fbm(_ x0: Float, _ y0: Float) -> Float {
        var x = x0, y = y0, a: Float = 0.6, s: Float = 0
        for _ in 0..<3 { s += a * noise(x, y); x = x * 1.9 + 17.1; y = y * 1.9 + 9.2; a *= 0.32 }
        return s
    }
    static func ramp(_ A: C3, _ B: C3, _ C: C3, _ t0: Float) -> C3 {
        let t = min(max(t0, 0), 1)
        let ab = mix(A, B, ss(0, 0.55, t))
        return mix(ab, C, ss(0.45, 1, t))
    }
    static func disk(_ d: Float, _ s: Float) -> Float { 1 - ss(1 - s, 1 + s, d) }

    /// An orb's study stops (a, b, c + rim) and seed.
    struct Stops { var a, b, c, r: C3; var seed: Float }

    // MARK: Flat, Outline

    /// Flat, dark Map: the boosted fill, opaque, with the AE inner glow (white by default) mixed in from the edge inward
    /// over `glowSize` (uv; the orb radius is 0.5 uv). Leaves out the focus band's dim (per frame, by camera position).
    static func flatDark(fill c: C3, glow: C3, glowOpacity: Float, glowSize: Float, box: [SIMD2<Float>] = TitleInkRule.titleBox) -> [C3] {
        box.map { q in
            let d = simd_length(q) * 0.5
            let edgeIn = min(max((0.5 - d) / max(glowSize, 1e-4), 0), 1)
            var gf = 1 - edgeIn; gf = gf * gf * (3 - 2 * gf)
            return clamp01(mix(c, glow, glowOpacity * gf))
        }
    }
    /// Flat, light Map: the translated orb colour at the orb opacity over the ground (uniform under the title).
    static func flatLight(orb c: C3, opacity: Float, ground g: C3) -> [C3] { [clamp01(c * opacity + g * (1 - opacity))] }
    /// Outline (both Maps): the ring is at the edge, so under the title only the faint fill at `fillOpacity` over the
    /// ground shows.
    static func outline(fill c: C3, fillOpacity: Float, ground g: C3) -> [C3] {
        [clamp01(c * fillOpacity + g * (1 - fillOpacity))]
    }

    // MARK: Fresnel, Glass (the orb sprite shader's dark-Map branches; Glass on both Maps)

    /// Fresnel (dark Map): the dark body (ground tinted toward the orb's colour, darkened), the rim, the inner glow and the
    /// top-left highlight, at each sample. `col` = the boosted fill.
    static func fresnel(col: C3, ground g: C3, _ f: FresnelLook, box: [SIMD2<Float>] = TitleInkRule.titleBox) -> [C3] {
        box.map { q in
            let rr = min(simd_length(q), 1), p = q * 0.5
            let body = mix(g, col, Float(f.bodyTint)) * Float(1 - f.bodyDarkness)
            let w = Float(f.rimWidth)
            let rimT = min(max((rr - (1 - w)) / max(w, 0.001), 0), 1)
            let rimF = pow(rimT, Float(f.rimPower)) * Float(f.rimIntensity)
            var fc = body + col * Float(f.rimBrightness) * rimF
            let cIn = 1 - rr
            fc += col * Float(f.innerGlow) * cIn * cIn
            let hs = ss(0.24, 0, simd_distance(p, SIMD2(-0.19, 0.21)))
            fc += C3(repeating: Float(f.highlight) * hs * hs)
            return clamp01(fc)
        }
    }

    /// Glass (both Maps): what shows through the bead (the ground, dimmed, under the family tint and the frosted lift),
    /// the inner shadow, the broad highlight, the caustic and the window — over the ground. `col` = the orb colour the
    /// shader starts from (dark: the boosted fill; light: the translated light fill); `hc` = the highlight centre (uv,
    /// tilt off = (−0.16, 0.19)). Leaves out what never reaches the title box (the rim glint, edge line and arcs live at
    /// rr > 0.9) and the lens dots (a sparse dot lattice).
    static func glass(col: C3, ground g: C3, _ gl: GlassLook, hc: SIMD2<Float> = SIMD2(-0.16, 0.19),
                      box: [SIMD2<Float>] = TitleInkRule.titleBox) -> [C3] {
        let tint = Float(gl.tint), lift = Float(gl.brightness), dim = Float(gl.dim)
        let ld = simd_normalize(hc + SIMD2(repeating: 0.0001))
        return box.map { q in
            let p = q * 0.5, pl = simd_length(p), rr = min(simd_length(q), 1)
            let dir = pl > 0.0001 ? p / pl : SIMD2<Float>(0, 1)
            let tw = tint * (0.4 + 0.6 * rr * rr)
            var glT = (1 - dim) * (1 - tw) * (1 - lift)
            var glC = col * tw * (1 - lift) + C3(repeating: lift)
            let lit = simd_dot(dir, ld) * 0.5 + 0.5
            let shK = 1 - Float(gl.innerShadow) * ss(0.6, 0.97, rr) * (1 + (0.35 - 1) * lit)
            glC *= shK; glT *= shK
            var gc = C3(repeating: 0)
            let hs = ss(Float(gl.highlightSize), 0, simd_distance(p, hc))
            gc += C3(repeating: Float(gl.highlightIntensity) * hs * hs)
            if gl.caustic > 0 {
                let cw = max(Float(gl.causticSize), 0.02), cSoft = 0.06 + 0.45 * cw
                let cOut = 1 - ss(0.97 - cSoft, 0.97, simd_length(q))
                let cIn = 1 - ss(0.97 - cSoft, 0.97, simd_length(q - ld * cw))
                gc += mix(col, C3(repeating: 1), Float(gl.causticColour)) * (min(max(cOut - cIn, 0), 1) * Float(gl.caustic))
            }
            if gl.window > 0 {
                let wsz = max(Float(gl.windowSize), 0.02)
                let b = SIMD2<Float>(wsz, wsz * 0.72), r = wsz * 0.3
                let wq = simd_abs(q - hc * 2) - b + SIMD2(repeating: r)
                let sdw = min(max(wq.x, wq.y), 0) + simd_length(simd_max(wq, SIMD2(repeating: 0))) - r
                let wEdge = (0.02 + 0.15 * wsz) * (1 - min(max(Float(gl.windowSharpness), 0), 1))
                gc += C3(repeating: Float(gl.window) * (1 - (wEdge > 0 ? ss(-wEdge, wEdge, sdw) : (sdw < 0 ? 0 : 1))))
            }
            return clamp01(clamp01(glC + gc) + g * glT)
        }
    }

    // MARK: the study looks (Aura, Wash, Eclipse, Riso, Gradient)

    /// Aura (dark Map) and Wash (light Map) — live-45 / 47's sampled twin (`studyTitleLuma`), per sample. Aura: the warped
    /// ramp + rim tint + shading, opaque. Wash (`washGround` set): the ground × (1 − absorb), the pigment lifted 14% toward
    /// white, density 0.6 × bloom (no pooling this far in; the granulation averages out). Leaves out the grain (± 1 pt).
    static func studySamples(_ st: Stops, spread: Double, warp: Double, rim: Double, washGround: C3? = nil,
                             box: [SIMD2<Float>] = TitleInkRule.titleBox) -> [C3] {
        let warp = Float(warp), spread = Float(spread), rimK = Float(rim), seed = st.seed
        let ang = seed * 6.2831853, dir = SIMD2<Float>(cos(ang), sin(ang)), perp = SIMD2<Float>(-dir.y, dir.x)
        return box.map { q in
            let w = q * 0.62 + SIMD2(seed * 13.1, seed * 7.7)
            let nv = SIMD2<Float>(fbm(w.x, w.y), fbm(w.x * 1.15 + 5.2, w.y * 1.15 + 1.3)) - 0.4
            let qw = q + warp * nv * 1.8
            var t = simd_dot(qw, dir) * 0.5 * spread + 0.5
            t += 0.3 * warp * sin(simd_dot(qw, perp) * 1.9 + seed * 11)
            t = min(max(t, 0), 1)
            let ab = st.a + (st.b - st.a) * ss(0, 0.55, t)
            var body = ab + (st.c - ab) * ss(0.45, 1, t)
            if let g = washGround {
                let pig = body + (C3(repeating: 1) - body) * 0.14
                let dens = 0.6 * (0.88 + 0.3 * nv.x)
                let absorb = simd_clamp((C3(repeating: 1) - pig) * dens, C3(repeating: 0), C3(repeating: 1))
                body = g * (C3(repeating: 1) - absorb)
            } else {
                let d = simd_length(q), rb = ss(0.62, 1.02, d)
                body += (st.r - body) * (rb * rb * rimK)
                body *= 0.9 + 0.14 * (max(0, 1 - min(d * d, 1))).squareRoot()
            }
            return simd_min(body, C3(repeating: 1))
        }
    }

    /// Eclipse (dark Map; stops sorted dark → light): the glow rising from a dark top — the ramp by height (warped), the
    /// dark cap, the rim and the crescent cut by the occluding disc. Full warp (the small-orb level of detail, which drops
    /// it under ~28 pt radius on screen, is zoom-dependent). Leaves out the grain.
    static func eclipse(_ st: Stops, _ e: EclipseLook, box: [SIMD2<Float>] = TitleInkRule.titleBox) -> [C3] {
        let warp = Float(e.warp), spread = Float(e.spread), rimK = Float(e.rim), s = Float(e.softness), seed = st.seed
        let arc = e.arcScale
        return box.map { q in
            let d = simd_length(q)
            let w = q * 0.62 + SIMD2(seed * 13.1, seed * 7.7)
            let ny = fbm(w.x * 1.15 + 5.2, w.y * 1.15 + 1.3) - 0.4
            let vv = 0.5 - 0.5 * (q.y + warp * ny * 0.35)
            let glow = ramp(st.a, st.b, st.c, ss(0.28, 1, vv) * spread)
            let dk = pow(1 - ss(0, 0.62, vv), 1.5)
            var body = mix(glow, C3(0.012, 0.01, 0.03), dk)
            let rb = ss(0.7, 1.02, d) * ss(0.15, 0.6, vv)
            body = mix(body, simd_min(st.r * 1.15, C3(repeating: 1)), rb * rimK)
            let occ = disk(simd_length(q - SIMD2(0, -0.07) * arc) / (0.95 + 0.05 * (1 - arc)), s * 0.6)
            let cres = (1 - occ) * ss(0, 0.55, q.y / max(d, 0.001))
            body = mix(body, C3(1, 0.93, 0.84), cres * min(max(rimK * 1.6, 0), 1))
            return clamp01(body)
        }
    }

    /// Riso (both Maps; stops sorted dark → light): two flat ink plates (the second offset by the misregistration and cut
    /// by the shape), multiplied into the ground on the light Map, screened over it on the dark Map. The speckle (1 pt
    /// value-noise cells) is taken at its mean thinning (≈ 0.3 of its depth).
    static func riso(_ st: Stops, _ r: RisoLook, dark: Bool, ground g: C3, box: [SIMD2<Float>] = TitleInkRule.titleBox) -> [C3] {
        let spread = Float(r.spread), warp = Float(r.warp), s = Float(r.softness), seed = st.seed
        let ang = seed * 6.2831853, dir = SIMD2<Float>(cos(ang), sin(ang)), per = SIMD2<Float>(-dir.y, dir.x)
        let spk = 1 - Float(r.grain) * 0.5 * 0.3
        let one = C3(repeating: 1)
        return box.map { q in
            let d = simd_length(q)
            let tt = simd_dot(q, dir) * 0.5 * spread + 0.5 + 0.22 * warp * sin(simd_dot(q, per) * 2.2 + seed * 11)
            let cut = ss(0.5 - 0.04 - s * 2, 0.5 + 0.04 + s * 2, tt)
            let off = SIMD2<Float>(0.7, -0.6) * Float(r.fringe) * 0.04
            var c1 = disk(d, s), c2 = disk(simd_length(q + off), s) * cut * Float(r.haloReach)
            c1 *= Float(r.rim) * spk; c2 *= Float(r.rim) * spk
            let i1 = st.b, i2 = dark ? st.c : st.a
            if dark {
                let src = one - (one - i1 * c1) * (one - i2 * c2 * 0.85)
                return clamp01(one - (one - g) * (one - src))
            }
            let src = (one - (one - i1) * c1 * 0.92) * (one - (one - i2) * c2 * 0.85)
            return clamp01(g * src)
        }
    }

    /// Gradient (both Maps; stops sorted dark → light): the ramp, the shading from the upper-left light, the sheen,
    /// opaque inside the disc. Leaves out the grain.
    static func gradient(_ st: Stops, _ gr: GradientLook, box: [SIMD2<Float>] = TitleInkRule.titleBox) -> [C3] {
        let spread = Float(gr.spread), warp = Float(gr.warp), seed = st.seed
        let ang = seed * 6.2831853, dir = SIMD2<Float>(cos(ang), sin(ang)), per = SIMD2<Float>(-dir.y, dir.x)
        let L = simd_normalize(C3(-0.45, 0.55, 0.7))
        return box.map { q in
            let d = simd_length(q)
            let tt = simd_dot(q, dir) * 0.5 * spread + 0.5 + 0.22 * warp * sin(simd_dot(q, per) * 2.2 + seed * 11)
            let z = max(0, 1 - min(d * d, 1)).squareRoot()
            let nl = simd_dot(C3(q.x, q.y, z), L)
            var body = ramp(st.a, st.b, st.c, tt)
            body *= 1 + (0.78 + 0.34 * max(nl, 0) - 1) * Float(gr.rim)
            let sq = q - SIMD2(-0.35, 0.42)
            body = mix(body, C3(repeating: 1), exp(-simd_dot(sq, sq) * 7) * Float(gr.haloReach) * 0.35)
            let rl = exp(-pow((d - 0.965) / 0.025, 2))
            body = mix(body, mix(body, C3(repeating: 1), 0.6), rl * Float(gr.fringe))
            return clamp01(body)
        }
    }
}
