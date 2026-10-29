//  MSDFLabel.swift
//  In-scene MSDF (multi-channel signed-distance-field) glyph label rendering — the
//  SOLE map node-label path (the UIKit raster path was retired in Phase 3). Labels are
//  resolution-independent (razor-crisp at any zoom, where the raster blurred past ~2×)
//  and batch to ~1 draw (shared atlas + shader), and track the orb 1:1 as children.
//
//  Pipeline: makeTitleSprite → resolveTitleLines (glyph-space wrap/tier/hyphenation,
//  measured with atlas advances) → makeContainer (multi-line glyph sprites). Per-frame
//  scale-aware smoothing is fed from applyOrbScales; restyleLabels recolors on
//  appearance flip. Ink = legibleInk over the dark-boosted fill (matches the orb).
//
//  Atlas: AirPad/Resources/MSDF/fraunces_msdf.{png,json}, baked with (Bold = mapLabelFont):
//    msdf-atlas-gen -font Fraunces_72pt-Bold.ttf -charset '[32,126]' \
//      -type msdf -format png -size 48 -pxrange 4 -yorigin bottom
//  msdf (opaque RGB) → no alpha channel to be premultiplied/corrupted on load.

import SpriteKit
import UIKit
import simd

// MARK: - Atlas JSON (msdf-atlas-gen layout)

private struct MSDFAtlasJSON: Decodable {
    struct Atlas: Decodable { let distanceRange, size, width, height: Double }
    struct Metrics: Decodable { let lineHeight: Double }   // em (font line height)
    struct Bounds: Decodable { let left, bottom, right, top: Double }
    struct Glyph: Decodable {
        let unicode: Int
        let advance: Double
        let planeBounds: Bounds?   // em space, baseline origin (nil for space)
        let atlasBounds: Bounds?   // atlas px, y-from-bottom (nil for space)
    }
    let atlas: Atlas
    let metrics: Metrics
    let glyphs: [Glyph]
}

// MARK: - Atlas loader (loaded once)

final class MSDFFont {
    /// The DEFAULT orb-title face (Space Grotesk Bold — T device-final 2026-09-14,
    /// `tuner-state-accepted.md`) AND the universal fallback. ★ Brief BF repointed this off
    /// `fraunces_msdf` (Fraunces retired). Every chosen Orb font resolves through `orb(atlas:)`,
    /// which falls back HERE if an atlas can't load, so a title can never silently vanish.
    /// ★ Orb-title METRICS (distanceRange/atlasSize) travel WITH the container now (stored in
    /// `makeContainer`, read by `applyLOD`), so a per-face swap keeps its own AA scale.
    static let shared = MSDFFont(atlas: "spacegroteskbold_msdf")
    /// Curated MSDF atlases loaded by NAME, cached (one texture each; sub-rects still batch).
    /// Brief BF addendum — the Edit Map… Orb-font picker resolves each of its 5 baked faces
    /// through here. A missing/unloadable atlas falls back to `shared` (never a blank title).
    private static var cache: [String: MSDFFont] = [:]
    static func orb(atlas name: String) -> MSDFFont {
        if name == shared.atlasName { return shared }
        if let f = cache[name] { return f.loaded ? f : shared }
        let f = MSDFFont(atlas: name); cache[name] = f
        return f.loaded ? f : shared
    }
    let atlasName: String

    let loaded: Bool
    let atlasTexture: SKTexture
    let atlasW: CGFloat, atlasH: CGFloat
    let distanceRange: CGFloat      // pxrange, in atlas texels
    let atlasSize: CGFloat          // px per em in the atlas
    let lineHeightEm: CGFloat       // font line height (em) for multi-line stacking
    private let glyphs: [Int: MSDFAtlasJSON.Glyph]
    private var subTexCache: [Int: SKTexture] = [:]

    private init(atlas: String) {
        atlasName = atlas
        guard let jsonURL = Bundle.main.url(forResource: atlas, withExtension: "json"),
              let pngPath = Bundle.main.path(forResource: atlas, ofType: "png"),
              let data = try? Data(contentsOf: jsonURL),
              let parsed = try? JSONDecoder().decode(MSDFAtlasJSON.self, from: data),
              let tex = MSDFFont.loadDataTexture(path: pngPath) else {
            print("[MSDF] ERROR — atlas not found/loadable (\(atlas).png/.json)")
            loaded = false
            atlasTexture = SKTexture()
            atlasW = 1; atlasH = 1; distanceRange = 4; atlasSize = 48; lineHeightEm = 1.2; glyphs = [:]
            return
        }
        atlasTexture = tex
        atlasW = CGFloat(parsed.atlas.width)
        atlasH = CGFloat(parsed.atlas.height)
        distanceRange = CGFloat(parsed.atlas.distanceRange)
        atlasSize = CGFloat(parsed.atlas.size)
        lineHeightEm = CGFloat(parsed.metrics.lineHeight)
        var map: [Int: MSDFAtlasJSON.Glyph] = [:]
        for g in parsed.glyphs { map[g.unicode] = g }
        glyphs = map
        loaded = true
    }

    /// Load the atlas PNG as a DATA texture: redraw through DeviceRGB with `.copy` so
    /// the raw msdf distance bytes survive (no sRGB gamma, no premultiply — msdf is
    /// opaque so `.noneSkipLast` drops the unused alpha). Bilinear filtering is
    /// REQUIRED for MSDF sampling.
    private static func loadDataTexture(path: String) -> SKTexture? {
        guard let ui = UIImage(contentsOfFile: path), let cg = ui.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        let tex = SKTexture(cgImage: out)
        tex.filteringMode = .linear
        return tex
    }

    fileprivate func glyph(_ scalar: UInt32) -> MSDFAtlasJSON.Glyph? { glyphs[Int(scalar)] }

    /// Advance (em) for a scalar. **Brief BD3 — a character the atlas cannot DRAW must not
    /// RESERVE space.** This used to fall back to `0.25`, so any glyph outside the atlas
    /// (every accent, dash and curly quote, since atlases were ASCII-only) rendered as an
    /// invisible hole AND shifted the wrap — `Cléo de 5 à 7` came out as `CL O DE 5 7`.
    ///
    /// ★ The fix belongs HERE and only here: `makeContainer` (render) and `width` (the
    /// wrap/fit measurer) both read this one function, so correcting it keeps the two
    /// consistent by construction rather than by two matching guards. A missing glyph now
    /// takes **zero** advance and draws nothing — it disappears cleanly instead of leaving a
    /// gap. (The atlases carry no `.notdef`, so there is no visible glyph to substitute; if
    /// one is ever baked in, prefer substituting it over dropping.)
    ///
    /// U+0020 is a real atlas entry with a real advance and no `planeBounds`, so spaces keep
    /// working — they're "present but not drawable", which is not the missing case.
    fileprivate func advance(_ scalar: UInt32) -> CGFloat {
        guard let a = glyphs[Int(scalar)]?.advance else {
            MSDFFont.noteMissingGlyph(scalar, atlas: atlasName)
            return 0
        }
        return CGFloat(a)
    }

    /// DEBUG-only: report each missing codepoint ONCE per atlas, so a title in a script the
    /// atlas doesn't cover (emoji, CJK) is visible in the console instead of failing silently.
    /// Release compiles this to an empty call.
    fileprivate static func noteMissingGlyph(_ scalar: UInt32, atlas: String) {
        #if DEBUG
        let key = "\(atlas)#\(scalar)"
        guard !reportedMissing.contains(key) else { return }
        reportedMissing.insert(key)
        let ch = Unicode.Scalar(scalar).map(String.init) ?? "?"
        print(String(format: "[MSDF] missing glyph U+%04X '%@' in atlas '%@' — dropped (0 advance)",
                     scalar, ch, atlas))
        #endif
    }
    #if DEBUG
    private static var reportedMissing: Set<String> = []
    #endif

    /// Rendered width (points) of `text` at `pointSize` — the SAME atlas advances that
    /// drive the glyph render, so fit and render share one metric system.
    fileprivate func width(_ text: String, pointSize: CGFloat) -> CGFloat {
        text.unicodeScalars.reduce(CGFloat(0)) { $0 + advance($1.value) } * pointSize
    }

    /// Cached `SKTexture(rect:in:)` sub-rect for a glyph — sub-rects of the ONE atlas
    /// texture batch (spike-proven, draws:5 for 144 glyphs). Cache keyed by unicode so
    /// every instance of a letter shares one sub-texture object.
    fileprivate func subTexture(_ g: MSDFAtlasJSON.Glyph) -> SKTexture? {
        guard let ab = g.atlasBounds else { return nil }
        if let cached = subTexCache[g.unicode] { return cached }
        let rect = CGRect(x: CGFloat(ab.left) / atlasW,
                          y: CGFloat(ab.bottom) / atlasH,          // y-from-bottom == SKTexture bottom-left
                          width: CGFloat(ab.right - ab.left) / atlasW,
                          height: CGFloat(ab.top - ab.bottom) / atlasH)
        let sub = SKTexture(rect: rect, in: atlasTexture)
        sub.filteringMode = .linear
        subTexCache[g.unicode] = sub
        return sub
    }
}

// MARK: - MSDF label helper

enum MSDFLabel {
    /// Container marker + point-size stash (for per-frame smoothing).
    static let containerName = "titleLabel"   // the label child's name → all seams find it
    private static let markerKey = "msdfGlyph"
    private static let pointSizeKey = "msdfPointSize"

    /// Shared MSDF shader. median-of-RGB → screenPxDistance (scaled by the per-glyph
    /// `a_px_range` smoothing) → premultiplied opacity. Color is per-glyph `a_glyph_color`
    /// (each label its own ink, still one batch — attributes don't break batching).
    /// SKTexture(rect:in:) means `v_tex_coord` already spans the glyph sub-rect, so no
    /// UV attribute is needed. No `fwidth` (SKShader GLSL may not expose it) — smoothing
    /// is CPU-fed per frame. The LOD fade rides a per-glyph `a_lod_alpha`: a custom shader
    /// writes gl_FragColor directly, so SpriteKit does NOT fold SKNode.alpha into it —
    /// setting the container's alpha would never reach the glyphs (→ pop-in). See applyLOD.
    static let shader: SKShader = {
        let src = """
        float median3(vec3 m) { return max(min(m.r, m.g), min(max(m.r, m.g), m.b)); }
        void main() {
            vec3 msd = texture2D(u_texture, v_tex_coord).rgb;
            float sd = median3(msd);
            float screenPxDistance = a_px_range * (sd - 0.5);
            float opacity = clamp(screenPxDistance + 0.5, 0.0, 1.0);
            float a = a_glyph_color.a * opacity * a_lod_alpha;   // a_lod_alpha = LOD fade
            gl_FragColor = vec4(a_glyph_color.rgb * a, a);   // premultiplied
        }
        """
        let shader = SKShader(source: src)
        shader.attributes = [
            SKAttribute(name: "a_glyph_color", type: .vectorFloat4),
            SKAttribute(name: "a_px_range", type: .float),
            SKAttribute(name: "a_lod_alpha", type: .float)
        ]
        return shader
    }()

    /// True if `node` is an MSDF glyph container (vs a raster SKSpriteNode).
    static func isGlyphContainer(_ node: SKNode) -> Bool {
        (node.userData?[markerKey] as? Bool) == true
    }

    /// Rendered width (points) of `text` at `pointSize` — the measurer the glyph-space
    /// line breaker feeds to the shared resolveTitleLines pass logic.
    static func textWidth(_ text: String, pointSize: CGFloat, font: MSDFFont = .shared) -> CGFloat {
        font.width(text, pointSize: pointSize)
    }

    /// Build a MULTI-LINE MSDF glyph container from pre-broken `lines` (Phase 2: the
    /// line breaking / tiering / hyphenation is done upstream in glyph-space so it
    /// matches the raster wrap). Each line is laid out L→R by advance and CENTERED
    /// horizontally; lines are STACKED by the font line-height and the whole block is
    /// CENTERED vertically on the origin. Returns an `SKNode` named `containerName`
    /// (drop-in for the raster title sprite: child of orb, z 2, alpha-driven by LOD).
    static func makeContainer(lines: [String], pointSize: CGFloat, color: UIColor,
                              fullTitle: String, font: MSDFFont = .shared) -> SKNode {
        let container = SKNode()
        container.zPosition = 2
        container.name = containerName
        container.userData = NSMutableDictionary()
        container.userData?["fullTitle"] = fullTitle
        container.userData?["isFocal"] = false
        container.userData?[markerKey] = true
        container.userData?[pointSizeKey] = pointSize
        // Brief BF — the AA scale (`applyLOD`) derives screenPxRange from THIS face's
        // distanceRange/atlasSize, so they must travel with the container (the orb font is
        // now selectable, so `applyLOD` can no longer hardcode one atlas's metrics).
        container.userData?["msdfDistanceRange"] = font.distanceRange
        container.userData?["msdfAtlasSize"] = font.atlasSize

        guard font.loaded, pointSize > 0, !lines.isEmpty else { return container }

        let midCaps: CGFloat = 0.355                 // cap-box center (em) → vertical centering
        let lineSpacing = font.lineHeightEm * pointSize
        let colorVec = rgbaVec(color)
        // Top line highest, block centered on y = 0.
        let topOffset = CGFloat(lines.count - 1) / 2 * lineSpacing
        for (li, line) in lines.enumerated() {
            let lineY = topOffset - CGFloat(li) * lineSpacing
            let lineWidth = font.width(line, pointSize: pointSize)
            var penX = -lineWidth / 2
            for s in line.unicodeScalars {
                let adv = font.advance(s.value)
                defer { penX += adv * pointSize }
                guard let g = font.glyph(s.value), let pb = g.planeBounds,
                      let sub = font.subTexture(g) else { continue }   // skip space / missing glyphs
                let sprite = SKSpriteNode(texture: sub)
                sprite.size = CGSize(width: CGFloat(pb.right - pb.left) * pointSize,
                                     height: CGFloat(pb.top - pb.bottom) * pointSize)
                sprite.position = CGPoint(x: penX + CGFloat(pb.left + pb.right) / 2 * pointSize,
                                          y: (CGFloat(pb.top + pb.bottom) / 2 - midCaps) * pointSize + lineY)
                sprite.zPosition = 2
                sprite.shader = shader
                sprite.blendMode = .alpha
                sprite.setValue(SKAttributeValue(vectorFloat4: colorVec), forAttribute: "a_glyph_color")
                sprite.setValue(SKAttributeValue(float: 4.0), forAttribute: "a_px_range")     // set per-frame (smoothing)
                sprite.setValue(SKAttributeValue(float: 1.0), forAttribute: "a_lod_alpha")    // set per-frame (LOD fade)
                container.addChild(sprite)
            }
        }
        return container
    }

    /// Recolor an existing glyph container in place (appearance flip — no rebuild).
    static func recolor(container: SKNode, color: UIColor) {
        let v = rgbaVec(color)
        for glyph in container.children {
            (glyph as? SKSpriteNode)?.setValue(SKAttributeValue(vectorFloat4: v), forAttribute: "a_glyph_color")
        }
    }

    /// Per-frame per-glyph LOD refresh — ONE pass over the children sets BOTH:
    ///   • `a_px_range` — scale-aware MSDF smoothing from the on-screen size.
    ///     `worldToScreenPt` = spriteScale / cameraScale (screen points per world point);
    ///     `contentScale` = view.contentScaleFactor. All glyphs share `pointSize`, so it's
    ///     one value per label.
    ///   • `a_lod_alpha` — the LOD fade. The glyph shader writes gl_FragColor directly, so
    ///     SpriteKit never folds the container's SKNode.alpha into it; the fade has to reach
    ///     the glyphs as an attribute or the label pops (full-opacity above the threshold,
    ///     gone at 0) instead of fading.
    /// Folding both into one child loop avoids a second per-frame iteration. Call across the
    /// WHOLE fade band (incl. `lodAlpha` → 0) so the fade-IN from zero is smooth; the caller
    /// loop only runs on zoom-change / annulus, so this stays cheap.
    static func applyLOD(container: SKNode, lodAlpha: CGFloat,
                         worldToScreenPt: CGFloat, contentScale: CGFloat) {
        // Brief BF — the face's metrics travel with the container (set in `makeContainer`),
        // so the AA scale is correct for WHICHEVER orb font built these glyphs, not a
        // hardcoded atlas. Falls back to `shared`'s metrics for any pre-existing container.
        guard let pt = container.userData?[pointSizeKey] as? CGFloat, pt > 0 else { return }
        let distanceRange = (container.userData?["msdfDistanceRange"] as? CGFloat) ?? MSDFFont.shared.distanceRange
        let atlasSize = (container.userData?["msdfAtlasSize"] as? CGFloat) ?? MSDFFont.shared.atlasSize
        // screenPxRange = pxrange · (screen px per atlas texel).
        // screen px per atlas texel = (pt · worldToScreenPt · contentScale) / atlasSize  (em cancels).
        let screenPxRange = max(1.0, distanceRange * pt * worldToScreenPt * contentScale / atlasSize)
        let px = Float(screenPxRange)
        let lod = Float(lodAlpha)
        for case let glyph as SKSpriteNode in container.children {
            glyph.setValue(SKAttributeValue(float: px), forAttribute: "a_px_range")
            glyph.setValue(SKAttributeValue(float: lod), forAttribute: "a_lod_alpha")
        }
    }

    private static func rgbaVec(_ c: UIColor) -> vector_float4 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return vector_float4(Float(r), Float(g), Float(b), Float(a))
    }
}
