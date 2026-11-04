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
    /// Map in-place fix R2 — the atlas texels (RGBX, row 0 = top), for composing a title's glyphs into one tile.
    fileprivate let pixels: [UInt8]
    fileprivate let pixelW: Int, pixelH: Int

    private init(atlas: String) {
        atlasName = atlas
        guard let jsonURL = Bundle.main.url(forResource: atlas, withExtension: "json"),
              let pngPath = Bundle.main.path(forResource: atlas, ofType: "png"),
              let data = try? Data(contentsOf: jsonURL),
              let parsed = try? JSONDecoder().decode(MSDFAtlasJSON.self, from: data),
              let (tex, px, pw, ph) = MSDFFont.loadDataTexture(path: pngPath) else {
            print("[MSDF] ERROR — atlas not found/loadable (\(atlas).png/.json)")
            loaded = false
            atlasTexture = SKTexture()
            atlasW = 1; atlasH = 1; distanceRange = 4; atlasSize = 48; lineHeightEm = 1.2; glyphs = [:]
            pixels = []; pixelW = 0; pixelH = 0
            return
        }
        atlasTexture = tex
        pixels = px; pixelW = pw; pixelH = ph
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
    private static func loadDataTexture(path: String) -> (SKTexture, [UInt8], Int, Int)? {
        guard let ui = UIImage(contentsOfFile: path), let cg = ui.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(), let data = ctx.data else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        let tex = SKTexture(cgImage: out)
        tex.filteringMode = .linear
        return (tex, bytes, w, h)
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
        // Map in-place fix R2 — ONE sprite per title: the same glyph quads, composed into one MSDF tile (TitleTiles), drawn
        // by the same shader with the same attributes. The container keeps its shape (an SKNode of SKSpriteNode children
        // carrying a_glyph_color / a_px_range / a_lod_alpha), so recolor, applyLOD and every reader work unchanged.
        if TitleTiles.enabled, let tile = TitleTiles.shared.tile(lines: lines, font: font, midCaps: midCaps) {
            let sprite = SKSpriteNode(texture: nil)
            TitleTiles.shared.attach(sprite, to: tile)
            sprite.size = CGSize(width: tile.emRect.width * pointSize, height: tile.emRect.height * pointSize)
            sprite.position = CGPoint(x: tile.emRect.midX * pointSize, y: tile.emRect.midY * pointSize)
            sprite.zPosition = 2
            sprite.shader = shader
            sprite.blendMode = .alpha
            sprite.setValue(SKAttributeValue(vectorFloat4: colorVec), forAttribute: "a_glyph_color")
            sprite.setValue(SKAttributeValue(float: 4.0), forAttribute: "a_px_range")     // set per-frame (smoothing)
            sprite.setValue(SKAttributeValue(float: 1.0), forAttribute: "a_lod_alpha")    // set per-frame (LOD fade)
            container.addChild(sprite)
            return container
        }
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

// MARK: - Map in-place fix R2 — titles as one sprite each

/// Composes each title's glyph quads into ONE MSDF tile — the same atlas texels, sampled at the same positions the
/// per-glyph quads would sample (bilinear, texel centres); where two glyph cells overlap, the nearer glyph's field, made
/// neutral along the switch — and packs the tiles into one shared texture, so the title sprites batch.
/// A tile is in atlas units (atlasSize texels per em), independent of point size, ink and zoom: a title is rebuilt only
/// when its text (lines) or face changes. MSDF stays resolution-independent, so no LOD-level rebuilds.
///
/// Tiles made in one run-loop turn (the whole Map at load, a renamed or new entry later) go into one BATCH. At the next
/// flush (the scene's next frame, or the main queue) the batch becomes one exactly-sized immutable texture, its sprites
/// are pointed at it and shown, and the CPU bytes are released. A later batch is its own (small) texture.
final class TitleTiles {
    static let shared = TitleTiles()

    /// Release: always on. DEBUG / bench: `-PerGlyphTitles` draws the old per-glyph sprites (A/B in one build);
    /// DEBUG `-TitleTilesFlip <s>` switches paths mid-launch (the crop gate: same camera, same layout).
    static var enabled: Bool = {
        #if DEBUG || PANBENCH
        return !ProcessInfo.processInfo.arguments.contains("-PerGlyphTitles")
        #else
        return true
        #endif
    }()

    /// A placed tile: its slot in a batch texture, and the quad in em around the title's origin (× point size).
    final class Tile {
        let emRect: CGRect
        fileprivate let slot: (x: Int, y: Int, w: Int, h: Int)
        fileprivate(set) var texture: SKTexture?          // nil until its batch is flushed
        fileprivate init(emRect: CGRect, slot: (x: Int, y: Int, w: Int, h: Int)) { self.emRect = emRect; self.slot = slot }
    }

    private final class WeakSprite { weak var node: SKSpriteNode?; init(_ n: SKSpriteNode) { node = n } }

    /// The open batch: a shelf packer over a fixed width, rows bottom-up (the texture's v = 0 row first).
    private final class Batch {
        static let width = 2048
        var bytes: [UInt8] = []
        var rows = 0                          // allocated rows (bytes.count = width × rows × 4)
        var x = 0, y = 0, shelfH = 0
        var tiles: [Tile] = []
        var jobs: [FillJob] = []
        var waiting: [(WeakSprite, Tile)] = []
        func place(_ w: Int, _ h: Int) -> (Int, Int) {
            let gw = w + 2, gh = h + 2       // a clear 1-texel gutter all round
            if x + gw > Self.width { x = 0; y += shelfH; shelfH = 0 }
            let at = (x + 1, y + 1)
            x += gw; shelfH = max(shelfH, gh)
            let need = y + shelfH
            if need > rows {
                let grow = max(need, rows * 2, 256)
                bytes.append(contentsOf: [UInt8](repeating: 0, count: (grow - rows) * Self.width * 4))
                rows = grow
            }
            return at
        }
        var usedRows: Int { y + shelfH }
    }

    private var cache: [String: Tile] = [:]           // face | midCaps | lines
    private var batch: Batch?
    private var flushScheduled = false
    #if DEBUG
    private var texelsTotal = 0, textures = 0, composeMS = 0.0
    #endif

    /// The tile for `lines` in `font` (built on first use), or nil → the caller falls back to per-glyph sprites.
    func tile(lines: [String], font: MSDFFont, midCaps: CGFloat) -> Tile? {
        let key = font.atlasName + "|" + String(describing: midCaps) + "|" + lines.joined(separator: "\n")
        if let t = cache[key] { return t }
        guard font.pixelW > 0 else { return nil }
        #if DEBUG
        let t0 = CACurrentMediaTime()
        #endif

        // The glyph quads exactly as the per-glyph path lays them out, in em (× pointSize there).
        struct Quad { let em: CGRect; let atlas: CGRect }   // atlas: px, y-from-bottom
        var quads: [Quad] = []
        let lineSpacing = font.lineHeightEm
        let topOffset = CGFloat(lines.count - 1) / 2 * lineSpacing
        for (li, line) in lines.enumerated() {
            let lineY = topOffset - CGFloat(li) * lineSpacing
            var penX = -font.width(line, pointSize: 1) / 2
            for sc in line.unicodeScalars {
                let adv = font.advance(sc.value)
                defer { penX += adv }
                guard let g = font.glyph(sc.value), let pb = g.planeBounds, let ab = g.atlasBounds else { continue }
                let w = CGFloat(pb.right - pb.left), h = CGFloat(pb.top - pb.bottom)
                let cx = penX + CGFloat(pb.left + pb.right) / 2
                let cy = CGFloat(pb.top + pb.bottom) / 2 - midCaps + lineY
                quads.append(Quad(em: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                                  atlas: CGRect(x: ab.left, y: ab.bottom, width: ab.right - ab.left, height: ab.top - ab.bottom)))
            }
        }
        guard let first = quads.first else { return nil }
        let bbox = quads.dropFirst().reduce(first.em) { $0.union($1.em) }

        // Tile grid: s texels per em plus a 1-texel margin; texel (i, j) centre = origin + (i + ½, j + ½) / s.
        let s = font.atlasSize
        let tw = Int((bbox.width * s).rounded(.up)) + 2, th = Int((bbox.height * s).rounded(.up)) + 2
        guard tw + 2 <= Batch.width else { return nil }
        let ox = bbox.minX - 1 / s, oy = bbox.minY - 1 / s
        let b = batch ?? Batch()
        batch = b
        let at = b.place(tw, th)

        // The texels are filled at the flush, all of the batch's tiles in parallel (disjoint slots).
        b.jobs.append(FillJob(font: font, quads: quads.map { ($0.em, $0.atlas) }, ox: ox, oy: oy, s: s, tw: tw, th: th, at: at))
        let t = Tile(emRect: CGRect(x: ox, y: oy, width: CGFloat(tw) / s, height: CGFloat(th) / s), slot: (at.0, at.1, tw, th))
        b.tiles.append(t)
        cache[key] = t
        scheduleFlush()
        #if DEBUG
        texelsTotal += tw * th; composeMS += (CACurrentMediaTime() - t0) * 1000   // + the parallel fill, at the flush
        #endif
        return t
    }

    /// One tile's texels to fill: its glyph quads (em rect, atlas rect in px y-from-bottom) and its slot.
    fileprivate struct FillJob {
        let font: MSDFFont
        let quads: [(em: CGRect, atlas: CGRect)]
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let tw: Int, th: Int
        let at: (Int, Int)
    }

    /// Fill one tile's slot. Thread-safe across jobs: each writes only its own slot (+ its own owner map).
    private static func fill(_ job: FillJob, into dst: UnsafeMutablePointer<UInt8>) {
        let font = job.font, quads = job.quads, ox = job.ox, oy = job.oy, s = job.s, tw = job.tw, th = job.th, at = job.at
        let aw = font.pixelW, ah = font.pixelH, W = Batch.width
        var owner = [Int16](repeating: -1, count: tw * th)   // which glyph's field each tile texel holds
        @inline(__always) func med(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 { max(min(a, b), min(max(a, b), c)) }
        font.pixels.withUnsafeBufferPointer { srcBuf in
        owner.withUnsafeMutableBufferPointer { own in
            let src = srcBuf.baseAddress!
            for (qi, q) in quads.enumerated() {
                let i0 = max(0, Int(((q.em.minX - ox) * s - 0.5).rounded(.up)))
                let i1 = min(tw - 1, Int(((q.em.maxX - ox) * s - 0.5).rounded(.down)))
                let j0 = max(0, Int(((q.em.minY - oy) * s - 0.5).rounded(.up)))
                let j1 = min(th - 1, Int(((q.em.maxY - oy) * s - 0.5).rounded(.down)))
                guard i0 <= i1, j0 <= j1 else { continue }
                // Atlas position of tile texel centre (i, j), less ½ (bilinear texel-centre convention): linear in i and j.
                let kx = Float(q.atlas.width / q.em.width / s), ky = Float(q.atlas.height / q.em.height / s)
                let ax0 = Float(q.atlas.minX + (ox + 0.5 / s - q.em.minX) / q.em.width * q.atlas.width) - 0.5
                let ay0 = Float(q.atlas.minY + (oy + 0.5 / s - q.em.minY) / q.em.height * q.atlas.height) - 0.5
                for j in j0...j1 {
                    let ay = ay0 + Float(j) * ky
                    let yf = ay.rounded(.down), ty = ay - yf
                    let yb0 = min(max(Int(yf), 0), ah - 1), yb1 = min(max(Int(yf) + 1, 0), ah - 1)
                    let row0 = (ah - 1 - yb0) * aw, row1 = (ah - 1 - yb1) * aw   // atlas rows are stored top-down
                    let dRow = (at.1 + j) * W + at.0, oRow = j * tw
                    for i in i0...i1 {
                        let ax = ax0 + Float(i) * kx
                        let xf = ax.rounded(.down), tx = ax - xf
                        let x0 = min(max(Int(xf), 0), aw - 1), x1 = min(max(Int(xf) + 1, 0), aw - 1)
                        let p00 = (row0 + x0) * 4, p10 = (row0 + x1) * 4, p01 = (row1 + x0) * 4, p11 = (row1 + x1) * 4
                        @inline(__always) func bil(_ c: Int) -> Int32 {
                            let v = (Float(src[p00 + c]) * (1 - tx) + Float(src[p10 + c]) * tx) * (1 - ty)
                                  + (Float(src[p01 + c]) * (1 - tx) + Float(src[p11 + c]) * tx) * ty
                            return Int32(min(max(v.rounded(), 0), 255))
                        }
                        let r = bil(0), g = bil(1), bl = bil(2)
                        let o = (dRow + i) * 4, k = oRow + i
                        // Overlapping cells: keep the sample whose MEDIAN is higher (the nearer glyph's own field), and
                        // remember whose it is. (A per-channel max invents dots where two glyphs' corner channels meet.)
                        if own[k] < 0 || med(r, g, bl) > med(Int32(dst[o]), Int32(dst[o + 1]), Int32(dst[o + 2])) {
                            dst[o] = UInt8(r); dst[o + 1] = UInt8(g); dst[o + 2] = UInt8(bl); dst[o + 3] = 255
                            own[k] = Int16(qi)
                        }
                    }
                }
            }
            // Where the owner switches from one glyph to another, bilinear blending would mix two DIFFERENT glyphs' channel
            // triples, which can manufacture an edge (a hairline between close stems). Every outside texel that touches
            // such a switch gets the neutral (m, m, m): blending (m, m, m) with any outside triple stays outside (the
            // median is affine under it). Texels away from a switch keep their triples, so the MSDF corners stay sharp.
            // A switch can only happen where two glyph cells meet, so only those rectangles (cells inflated 2 texels) are scanned.
            var collapse: [Int] = []
            for a in 0..<quads.count {
                for c in (a + 1)..<max(a + 1, quads.count) {
                    let x = quads[a].em.insetBy(dx: -2 / s, dy: -2 / s).intersection(quads[c].em.insetBy(dx: -2 / s, dy: -2 / s))
                    guard !x.isNull, !x.isEmpty else { continue }
                    let i0 = max(0, Int(((x.minX - ox) * s).rounded(.down)) - 2), i1 = min(tw - 1, Int(((x.maxX - ox) * s).rounded(.up)) + 1)
                    let j0 = max(0, Int(((x.minY - oy) * s).rounded(.down)) - 2), j1 = min(th - 1, Int(((x.maxY - oy) * s).rounded(.up)) + 1)
                    guard i0 <= i1, j0 <= j1 else { continue }
                    for j in j0...j1 {
                        for i in i0...i1 {
                            let k = j * tw + i, mine = own[k]
                            guard mine >= 0 else { continue }
                            var touches = false
                            for dj in -1...1 where !touches {
                                let nj = j + dj
                                guard nj >= 0, nj < th else { continue }
                                for di in -1...1 {
                                    let ni = i + di
                                    guard ni >= 0, ni < tw else { continue }
                                    let n = own[nj * tw + ni]
                                    if n >= 0 && n != mine { touches = true; break }
                                }
                            }
                            guard touches else { continue }
                            let o = ((at.1 + j) * W + at.0 + i) * 4
                            if med(Int32(dst[o]), Int32(dst[o + 1]), Int32(dst[o + 2])) < 128 { collapse.append(o) }
                        }
                    }
                }
            }
            for o in collapse {
                let m = UInt8(med(Int32(dst[o]), Int32(dst[o + 1]), Int32(dst[o + 2])))
                dst[o] = m; dst[o + 1] = m; dst[o + 2] = m
            }
        }
        }
    }

    /// Show `sprite` with `tile`: now if its batch is flushed, else hidden until the flush points it at the texture.
    func attach(_ sprite: SKSpriteNode, to tile: Tile) {
        if let tex = tile.texture { sprite.texture = tex; return }
        sprite.isHidden = true
        batch?.waiting.append((WeakSprite(sprite), tile))
    }


    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    /// Turn the open batch into one texture (W × used rows), point its tiles and waiting sprites at it, drop the bytes.
    /// Called at the top of every Map frame (a no-op without a batch) and from the main queue.
    func flush() {
        flushScheduled = false
        guard let b = batch, !b.tiles.isEmpty else { return }
        batch = nil
        let w = Batch.width, h = max(b.usedRows, 1)
        #if DEBUG
        let f0 = CACurrentMediaTime()
        #endif
        let jobs = b.jobs
        b.bytes.withUnsafeMutableBufferPointer { buf in
            let dst = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: jobs.count) { Self.fill(jobs[$0], into: dst) }
        }
        #if DEBUG
        composeMS += (CACurrentMediaTime() - f0) * 1000
        #endif
        let data = Data(b.bytes[0..<(w * h * 4)])
        let tex = SKTexture(data: data, size: CGSize(width: w, height: h))   // rows from v = 0 (bottom), as packed
        tex.filteringMode = .linear
        tex.usesMipmaps = false
        for t in b.tiles {
            let r = CGRect(x: CGFloat(t.slot.x) / CGFloat(w), y: CGFloat(t.slot.y) / CGFloat(h),
                           width: CGFloat(t.slot.w) / CGFloat(w), height: CGFloat(t.slot.h) / CGFloat(h))
            let sub = SKTexture(rect: r, in: tex)
            sub.filteringMode = .linear
            t.texture = sub
        }
        for (ws, t) in b.waiting { if let n = ws.node { n.texture = t.texture; n.isHidden = false } }
        // A face switch rebuilds every title in the new face: forget the other faces' tiles, so their batch texture is
        // freed once no sprite shows it (sprites hold their own texture references until they are rebuilt).
        let faces = Set(b.jobs.map { $0.font.atlasName })
        if faces.count == 1, let face = faces.first, b.tiles.count > 1 {
            cache = cache.filter { $0.key.hasPrefix(face + "|") }
        }
        #if DEBUG
        textures += 1
        if ProcessInfo.processInfo.arguments.contains("-TitleTilesLog") {
            NSLog("[TITLETILES] flush tiles=%d texture=%dx%d (%.1f MB) · total textures=%d tiles=%d texels=%d compose=%.0f ms",
                  b.tiles.count, w, h, Double(w * h * 4) / 1_048_576, textures, cache.count, texelsTotal, composeMS)
        }
        #endif
    }
}
