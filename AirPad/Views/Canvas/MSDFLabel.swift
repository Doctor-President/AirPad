//  MSDFLabel.swift
//  In-scene MSDF (multi-channel signed-distance-field) glyph label rendering —
//  the real foundation promoted from the throwaway spike (which returned PROCEED:
//  razor-crisp at 12× zoom, 144 glyphs → 1 draw, tracks the orb 1:1 as a child).
//
//  Phase 0 (this file): atlas loader (as a DATA texture, not sRGB) + the MSDF shader
//  + a single-line glyph-container builder. Phase 1 wires it into makeTitleSprite /
//  applyOrbScales / restyleLabels behind the `SPRGlyphLabels` flag, in PARALLEL with
//  the raster path (nothing ships broken; A/B on device). Phase 2 = the multi-line
//  layout port (resolveTitle's wrap/hyphenation into glyph-space). Phase 3 deletes
//  the raster path.
//
//  Atlas: AirPad/Resources/MSDF/fraunces_msdf.{png,json}, baked with
//    msdf-atlas-gen -font Fraunces_72pt-Regular.ttf -charset '[32,126]' \
//      -type msdf -format png -size 48 -pxrange 4 -yorigin bottom
//  msdf (opaque RGB) → no alpha channel to be premultiplied/corrupted on load.

import SpriteKit
import UIKit
import simd

// MARK: - Atlas JSON (msdf-atlas-gen layout)

private struct MSDFAtlasJSON: Decodable {
    struct Atlas: Decodable { let distanceRange, size, width, height: Double }
    struct Bounds: Decodable { let left, bottom, right, top: Double }
    struct Glyph: Decodable {
        let unicode: Int
        let advance: Double
        let planeBounds: Bounds?   // em space, baseline origin (nil for space)
        let atlasBounds: Bounds?   // atlas px, y-from-bottom (nil for space)
    }
    let atlas: Atlas
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
            atlasW = 1; atlasH = 1; distanceRange = 4; atlasSize = 48; glyphs = [:]
            return
        }
        atlasTexture = tex
        atlasW = CGFloat(parsed.atlas.width)
        atlasH = CGFloat(parsed.atlas.height)
        distanceRange = CGFloat(parsed.atlas.distanceRange)
        atlasSize = CGFloat(parsed.atlas.size)
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
    /// Parallel-path flag. OFF (default) = the shipping raster labels; ON = MSDF glyph
    /// labels. Set via the `SPRGlyphLabels` launch arg (works in the -SPRMeasure harness
    /// and when running from Xcode with the scheme arg). Nothing ships broken: default
    /// OFF keeps the raster path.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "SPRGlyphLabels") }

    /// Container marker + point-size stash (for per-frame smoothing).
    static let containerName = "titleLabel"   // SAME name as the raster sprite → all seams find it
    private static let markerKey = "msdfGlyph"
    private static let pointSizeKey = "msdfPointSize"

    /// Shared MSDF shader. median-of-RGB → screenPxDistance (scaled by the per-glyph
    /// `a_px_range` smoothing) → premultiplied opacity. Color is per-glyph `a_glyph_color`
    /// (each label its own ink, still one batch — attributes don't break batching).
    /// SKTexture(rect:in:) means `v_tex_coord` already spans the glyph sub-rect, so no
    /// UV attribute is needed. No `fwidth` (SKShader GLSL may not expose it) — smoothing
    /// is CPU-fed per frame.
    static let shader: SKShader = {
        let src = """
        float median3(vec3 m) { return max(min(m.r, m.g), min(max(m.r, m.g), m.b)); }
        void main() {
            vec3 msd = texture2D(u_texture, v_tex_coord).rgb;
            float sd = median3(msd);
            float screenPxDistance = a_px_range * (sd - 0.5);
            float opacity = clamp(screenPxDistance + 0.5, 0.0, 1.0);
            float a = a_glyph_color.a * opacity;
            gl_FragColor = vec4(a_glyph_color.rgb * a, a);   // premultiplied
        }
        """
        let shader = SKShader(source: src)
        shader.attributes = [
            SKAttribute(name: "a_glyph_color", type: .vectorFloat4),
            SKAttribute(name: "a_px_range", type: .float)
        ]
        return shader
    }()

    /// True if `node` is an MSDF glyph container (vs a raster SKSpriteNode).
    static func isGlyphContainer(_ node: SKNode) -> Bool {
        (node.userData?[markerKey] as? Bool) == true
    }

    /// Build a single-line MSDF glyph container for `text`, centered on the origin, at
    /// `pointSize` pt-per-em, all glyphs colored `color`. Returns an `SKNode` named
    /// `containerName` (drop-in for the raster title sprite: child of the orb, z 2,
    /// alpha-driven by LOD). Phase-1 layout is LEFT-TO-RIGHT single-line (no wrap /
    /// hyphenation / truncation — that's Phase 2); long titles overflow the box.
    static func makeContainer(text: String, pointSize: CGFloat, color: UIColor,
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
        guard font.loaded, pointSize > 0 else { return container }

        let scalars = Array(text.unicodeScalars)
        let midCaps: CGFloat = 0.355   // cap-box center (em) → vertical centering
        let totalAdvance = scalars.reduce(CGFloat(0)) { $0 + font.advance($1.value) } * pointSize
        let colorVec = rgbaVec(color)
        var penX: CGFloat = -totalAdvance / 2
        for s in scalars {
            let adv = font.advance(s.value)
            defer { penX += adv * pointSize }
            guard let g = font.glyph(s.value), let pb = g.planeBounds,
                  let sub = font.subTexture(g) else { continue }   // skip space / missing glyphs
            let sprite = SKSpriteNode(texture: sub)
            sprite.size = CGSize(width: CGFloat(pb.right - pb.left) * pointSize,
                                 height: CGFloat(pb.top - pb.bottom) * pointSize)
            sprite.position = CGPoint(x: penX + CGFloat(pb.left + pb.right) / 2 * pointSize,
                                      y: (CGFloat(pb.top + pb.bottom) / 2 - midCaps) * pointSize)
            sprite.zPosition = 2
            sprite.shader = shader
            sprite.blendMode = .alpha
            sprite.setValue(SKAttributeValue(vectorFloat4: colorVec), forAttribute: "a_glyph_color")
            sprite.setValue(SKAttributeValue(float: 4.0), forAttribute: "a_px_range")   // set per-frame
            container.addChild(sprite)
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

    /// Refresh scale-aware smoothing for a VISIBLE glyph container from its on-screen
    /// size. `worldToScreenPt` = spriteScale / cameraScale (how many screen points one
    /// world point occupies); `contentScale` = view.contentScaleFactor. All glyphs of a
    /// label share `pointSize`, so it's one value per label — set on each glyph as
    /// `a_px_range`. Bounded: call only when the label is on-screen (alpha > 0).
    static func refreshSmoothing(container: SKNode, worldToScreenPt: CGFloat, contentScale: CGFloat) {
        let font = MSDFFont.shared
        guard let pt = container.userData?[pointSizeKey] as? CGFloat, pt > 0 else { return }
        // screenPxRange = pxrange · (screen px per atlas texel).
        // screen px per atlas texel = (pt · worldToScreenPt · contentScale) / atlasSize  (em cancels).
        let screenPxRange = max(1.0, font.distanceRange * pt * worldToScreenPt * contentScale / font.atlasSize)
        let v = Float(screenPxRange)
        for glyph in container.children {
            (glyph as? SKSpriteNode)?.setValue(SKAttributeValue(float: v), forAttribute: "a_px_range")
        }
    }

    private static func rgbaVec(_ c: UIColor) -> vector_float4 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return vector_float4(Float(r), Float(g), Float(b), Float(a))
    }
}
