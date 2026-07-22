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
    static let shared = MSDFFont()

    let loaded: Bool
    let atlasTexture: SKTexture
    let atlasW: CGFloat, atlasH: CGFloat
    let distanceRange: CGFloat      // pxrange, in atlas texels
    let atlasSize: CGFloat          // px per em in the atlas
    let lineHeightEm: CGFloat       // font line height (em) for multi-line stacking
    private let glyphs: [Int: MSDFAtlasJSON.Glyph]
    private var subTexCache: [Int: SKTexture] = [:]

    private init() {
        guard let jsonURL = Bundle.main.url(forResource: "fraunces_msdf", withExtension: "json"),
              let pngPath = Bundle.main.path(forResource: "fraunces_msdf", ofType: "png"),
              let data = try? Data(contentsOf: jsonURL),
              let parsed = try? JSONDecoder().decode(MSDFAtlasJSON.self, from: data),
              let tex = MSDFFont.loadDataTexture(path: pngPath) else {
            print("[MSDF] ERROR — atlas not found/loadable (fraunces_msdf.png/.json)")
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
    fileprivate func advance(_ scalar: UInt32) -> CGFloat { CGFloat(glyphs[Int(scalar)]?.advance ?? 0.25) }

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
    static func textWidth(_ text: String, pointSize: CGFloat) -> CGFloat {
        MSDFFont.shared.width(text, pointSize: pointSize)
    }

    /// Build a MULTI-LINE MSDF glyph container from pre-broken `lines` (Phase 2: the
    /// line breaking / tiering / hyphenation is done upstream in glyph-space so it
    /// matches the raster wrap). Each line is laid out L→R by advance and CENTERED
    /// horizontally; lines are STACKED by the font line-height and the whole block is
    /// CENTERED vertically on the origin. Returns an `SKNode` named `containerName`
    /// (drop-in for the raster title sprite: child of orb, z 2, alpha-driven by LOD).
    static func makeContainer(lines: [String], pointSize: CGFloat, color: UIColor,
                              fullTitle: String) -> SKNode {
        let container = SKNode()
        container.zPosition = 2
        container.name = containerName
        container.userData = NSMutableDictionary()
        container.userData?["fullTitle"] = fullTitle
        container.userData?["isFocal"] = false
        container.userData?[markerKey] = true
        container.userData?[pointSizeKey] = pointSize

        let font = MSDFFont.shared
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
        let font = MSDFFont.shared
        guard let pt = container.userData?[pointSizeKey] as? CGFloat, pt > 0 else { return }
        // screenPxRange = pxrange · (screen px per atlas texel).
        // screen px per atlas texel = (pt · worldToScreenPt · contentScale) / atlasSize  (em cancels).
        let screenPxRange = max(1.0, font.distanceRange * pt * worldToScreenPt * contentScale / font.atlasSize)
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
