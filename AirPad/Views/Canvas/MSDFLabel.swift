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
    fileprivate static let pointSizeKey = "msdfPointSize"

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
        let colorVec = rgbaVec(color)
        // Map in-place fix R2 — ONE sprite per title: the same glyph quads, composed into one MSDF tile (TitleTiles), drawn
        // by the same shader with the same attributes. The container keeps its shape (an SKNode of SKSpriteNode children
        // carrying a_glyph_color / a_px_range / a_lod_alpha), so recolor, applyLOD and every reader work unchanged.
        if TitleTiles.enabled, let tile = TitleTiles.shared.tile(lines: lines, font: font, midCaps: midCaps) {
            let sprite = SKSpriteNode(texture: nil)
            sprite.size = CGSize(width: tile.emRect.width * pointSize, height: tile.emRect.height * pointSize)
            sprite.position = CGPoint(x: tile.emRect.midX * pointSize, y: tile.emRect.midY * pointSize)
            sprite.zPosition = 2
            sprite.shader = shader
            sprite.blendMode = .alpha
            sprite.setValue(SKAttributeValue(vectorFloat4: colorVec), forAttribute: "a_glyph_color")
            sprite.setValue(SKAttributeValue(float: 4.0), forAttribute: "a_px_range")     // set per-frame (smoothing)
            sprite.setValue(SKAttributeValue(float: 1.0), forAttribute: "a_lod_alpha")    // set per-frame (LOD fade)
            container.addChild(sprite)
            container.userData?[tileKey] = tile
            TitleTiles.shared.attach(sprite, to: tile)   // shown once the tile is resident (fix-up F1b: on demand)
            return container
        }
        addGlyphSprites(to: container, lines: lines, pointSize: pointSize, font: font, midCaps: midCaps, colorVec: colorVec)
        return container
    }

    /// The per-glyph sprites (one per drawable glyph) — the pre-R2 path, `-PerGlyphTitles`, and the fix-up's overflow
    /// fallback (a title the fixed tile budget can't hold right now still draws, from the font atlas).
    fileprivate static func addGlyphSprites(to container: SKNode, lines: [String], pointSize: CGFloat, font: MSDFFont,
                                            midCaps: CGFloat, colorVec: vector_float4) {
        let lineSpacing = font.lineHeightEm * pointSize
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
    }

    /// Fix-up F1b — the Map's orb pass asks for the tiles of the titles that are (about to be) drawn: in view or within a
    /// margin, and at or near the LOD fade. `urgent` = drawn this frame (on screen, fade > 0). Lower `priority` = sooner.
    static func wantTile(_ container: SKNode, urgent: Bool, priority: CGFloat) {
        guard let tile = container.userData?[tileKey] as? TitleTiles.Tile else { return }
        TitleTiles.shared.want(tile, urgent: urgent, priority: priority)
    }
    fileprivate static let tileKey = "titleTile"

    #if DEBUG
    /// Fix-up F1 frame check: a tiled title with no texture to draw (and no per-glyph fallback).
    static func isTitleBlank(_ container: SKNode) -> Bool {
        guard container.userData?[tileKey] != nil, container.userData?["perGlyphFallback"] == nil else { return false }
        guard let sp = container.children.first as? SKSpriteNode else { return true }
        return sp.isHidden || sp.texture == nil
    }
    #endif

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

    fileprivate static func rgbaVec(_ c: UIColor) -> vector_float4 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return vector_float4(Float(r), Float(g), Float(b), Float(a))
    }
}

// MARK: - Map in-place fix R2 (+ fix-up F1) — titles as one sprite each, in a FIXED texture budget

/// Composes each title's glyph quads into ONE MSDF tile — the same atlas texels, sampled at the same positions the
/// per-glyph quads would sample (bilinear, texel centres); where two glyph cells overlap, the nearer glyph's field, made
/// neutral along the switch — so the title sprites batch. A tile is in atlas units (× `texelScale`), independent of point
/// size, ink and zoom: a title's tile changes only when its text (lines) or face changes.
///
/// Fix-up F1 — the tiles live in at most `maxPages` fixed pages (`pageSize`², RGBA8), whatever the library size:
/// - A tile is built only when the Map's orb pass WANTS it: the title is in view or within a margin of it, and at or near
///   its LOD fade (`MSDFLabel.wantTile`). Titles that are drawn this frame are URGENT and are always built before the
///   frame draws; the rest (the margin, the pre-fade band) are built ahead, nearest first, a few milliseconds per frame.
/// - Tiles go into the OPEN page (its bytes on the CPU), which becomes a new texture at the end of a flush that changed
///   it; a full page is SEALED (CPU bytes dropped). A new page beyond the budget EVICTS the least-recently-wanted sealed
///   page (none of its titles wanted in the current pass): its sprites are hidden (they are off screen or faded out)
///   and rebuild when wanted again.
/// - If every page holds a title wanted right now, the title draws from per-glyph sprites instead (never blank).
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

    /// Fix-up F1a — tile resolution as a fraction of the atlas's texels per em. DEBUG `-TitleTileScale <f>` overrides it.
    static let texelScale: CGFloat = {
        #if DEBUG
        let v = UserDefaults.standard.double(forKey: "TitleTileScale")
        if v > 0 { return CGFloat(v) }
        #endif
        return 0.5   // fix-up F1a: the smallest tested scale inside the crop gate (0.375 failed at zoom 4)
    }()

    /// Fix-up F1b — the budget: `maxPages` × `pageSize`² × 4 bytes. DEBUG `-TitleTilePages <n>` / `-TitleTilePageSize <px>`.
    static let pageSize: Int = {
        #if DEBUG
        let v = UserDefaults.standard.integer(forKey: "TitleTilePageSize")
        if v > 0 { return v }
        #endif
        return 512   // 1 MB a page: a page rebuild stays well under a millisecond
    }()
    static let maxPages: Int = {
        #if DEBUG
        let v = UserDefaults.standard.integer(forKey: "TitleTilePages")
        if v > 0 { return v }
        #endif
        return 16    // 16 × 1 MB = the 16 MB budget
    }()
    static var budgetBytes: Int { maxPages * pageSize * pageSize * 4 }

    /// A title's tile: its layout (always kept, small) and, while resident, its slot in a page.
    final class Tile {
        let emRect: CGRect
        fileprivate let job: FillJob
        fileprivate let lines: [String], font: MSDFFont, midCaps: CGFloat
        fileprivate weak var page: Page?
        fileprivate var slot = (x: 0, y: 0)
        fileprivate(set) var texture: SKTexture?
        fileprivate var lastWanted = -1
        fileprivate var queued = false, urgent = false, overflowed = false
        fileprivate var priority: CGFloat = 0
        fileprivate var sprites: [WeakSprite] = []
        fileprivate init(emRect: CGRect, job: FillJob, lines: [String], font: MSDFFont, midCaps: CGFloat) {
            self.emRect = emRect; self.job = job; self.lines = lines; self.font = font; self.midCaps = midCaps
        }
    }

    fileprivate final class WeakSprite { weak var node: SKSpriteNode?; init(_ n: SKSpriteNode) { node = n } }

    /// One page: a shelf packer over `pageSize`², rows bottom-up (the texture's v = 0 row first).
    fileprivate final class Page {
        let size: Int
        var bytes: [UInt8]? = nil              // the CPU copy, only while the page is open
        var x = 0, y = 0, shelfH = 0
        var tiles: [Tile] = []
        var texture: SKTexture?
        var dirty = false
        init(size: Int) { self.size = size; bytes = [UInt8](repeating: 0, count: size * size * 4) }
        var lastWanted: Int { tiles.reduce(-1) { max($0, $1.lastWanted) } }
        func canPlace(_ w: Int, _ h: Int) -> Bool {
            let gw = w + 2, gh = h + 2
            guard gw <= size, gh <= size else { return false }
            return x + gw <= size ? y + max(shelfH, gh) <= size : y + shelfH + gh <= size
        }
        /// A w × h slot with a clear 1-texel gutter all round, or nil when the page is full.
        func place(_ w: Int, _ h: Int) -> (Int, Int)? {
            let gw = w + 2, gh = h + 2
            guard gw <= size, gh <= size else { return nil }
            if x + gw > size { x = 0; y += shelfH; shelfH = 0 }
            guard y + gh <= size else { return nil }
            let at = (x + 1, y + 1)
            x += gw; shelfH = max(shelfH, gh)
            return at
        }
        func reset() {
            for t in tiles {
                t.texture = nil; t.page = nil
                for ws in t.sprites { if let n = ws.node { n.texture = nil; n.isHidden = true } }
            }
            tiles = []; texture = nil; dirty = false
            x = 0; y = 0; shelfH = 0
            bytes = [UInt8](repeating: 0, count: size * size * 4)
        }
    }

    private var cache: [String: Tile] = [:]           // face | midCaps | lines
    private var pages: [Page] = []
    private var open: Page?
    private var queue: [Tile] = []
    private var stamp = 0
    /// Set when a title is attached to a tile that isn't resident: the Map runs its orb pass next frame to want it.
    private(set) var needsPass = false
    /// Wanted tiles not yet built (the Map stays awake until they are).
    var pending: Bool { !queue.isEmpty }
    /// Budget for the non-urgent (ahead-of-time) builds per flush.
    static let aheadBudgetMS: Double = 1.5

    #if DEBUG
    private(set) var stats = Stats()
    struct Stats {
        var built = 0, urgentBuilt = 0, lateBuilt = 0, evictions = 0, compactions = 0, overflows = 0, flushes = 0
        var maxFlushMS = 0.0, maxPanFlushMS = 0.0, totalFlushMS = 0.0
        var lastLog = 0.0, windowMax = 0.0, windowBuilt = 0
        var maxFillMS = 0.0, maxTexMS = 0.0, maxPagesPerFlush = 0
    }
    private var loaded = false                       // the first urgent flush (the Map's first frame) is the load
    func resetStats() { stats = Stats(); loaded = true }
    #endif

    /// The tile for `lines` in `font` (its layout; texels are built when wanted), or nil → per-glyph sprites.
    func tile(lines: [String], font: MSDFFont, midCaps: CGFloat) -> Tile? {
        let key = font.atlasName + "|" + String(describing: midCaps) + "|" + lines.joined(separator: "\n")
        if let t = cache[key] { return t }
        guard font.pixelW > 0 else { return nil }

        // The glyph quads exactly as the per-glyph path lays them out, in em (× pointSize there).
        var quads: [(em: CGRect, atlas: CGRect)] = []
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
                quads.append((CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                              CGRect(x: ab.left, y: ab.bottom, width: ab.right - ab.left, height: ab.top - ab.bottom)))
            }
        }
        guard let first = quads.first else { return nil }
        let bbox = quads.dropFirst().reduce(first.em) { $0.union($1.em) }

        // Tile grid: s texels per em plus a 1-texel margin; texel (i, j) centre = origin + (i + ½, j + ½) / s.
        // Fix-up F1a — s is a fraction of the atlas's own texels per em (`texelScale`). The tile still holds the atlas's
        // distance values, so the shader's screen px range (computed in atlas units) is unchanged.
        let s = font.atlasSize * Self.texelScale
        let tw = Int((bbox.width * s).rounded(.up)) + 2, th = Int((bbox.height * s).rounded(.up)) + 2
        guard tw + 2 <= Self.pageSize, th + 2 <= Self.pageSize else { return nil }
        let ox = bbox.minX - 1 / s, oy = bbox.minY - 1 / s
        let job = FillJob(font: font, quads: quads, ox: ox, oy: oy, s: s, tw: tw, th: th)
        let t = Tile(emRect: CGRect(x: ox, y: oy, width: CGFloat(tw) / s, height: CGFloat(th) / s), job: job,
                     lines: lines, font: font, midCaps: midCaps)
        cache[key] = t
        if cache.count > pruneAt { pruneCache() }
        return t
    }

    /// Show `sprite` with `tile` now if it is resident; otherwise hidden until it is (the next orb pass wants it).
    func attach(_ sprite: SKSpriteNode, to tile: Tile) {
        tile.sprites.removeAll { $0.node == nil }
        tile.sprites.append(WeakSprite(sprite))
        if tile.overflowed { sprite.isHidden = true; fallBack(sprite, tile); return }
        if let tex = tile.texture { sprite.texture = tex; sprite.isHidden = false; return }
        sprite.isHidden = true
        needsPass = true
    }

    /// The orb pass starts: titles wanted from here on carry the new stamp.
    func beginPass() { stamp += 1; needsPass = false }

    func want(_ tile: Tile, urgent: Bool, priority: CGFloat) {
        tile.lastWanted = stamp
        guard tile.texture == nil, !tile.overflowed else { return }
        tile.priority = priority
        tile.urgent = tile.urgent || urgent
        if !tile.queued { tile.queued = true; queue.append(tile) }
    }

    /// One fill: a tile and where it goes.
    fileprivate struct FillJob {
        let font: MSDFFont
        let quads: [(em: CGRect, atlas: CGRect)]
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let tw: Int, th: Int
    }

    /// Build the wanted tiles: every urgent one (drawn this frame), then the rest nearest first within
    /// `aheadBudgetMS`; then turn each changed page into a texture and show the new tiles. Called twice a Map frame
    /// (top of update, and right after the orb pass); a no-op with nothing queued.
    func flush() {
        guard !queue.isEmpty else { return }
        let t0 = CACurrentMediaTime()
        // Drop tiles no longer wanted (scrolled past before they were built).
        queue.removeAll { t in
            let stale = t.lastWanted < stamp || t.texture != nil || t.overflowed
            if stale { t.queued = false; t.urgent = false }
            return stale
        }
        guard !queue.isEmpty else { return }
        queue.sort { a, b in a.urgent != b.urgent ? a.urgent : a.priority < b.priority }

        var built: [Tile] = []
        var touched: [ObjectIdentifier: Page] = [:]
        var urgentCount = 0
        // Fill in small groups (parallel within a group); stop the ahead-of-time builds at the time budget.
        var k = 0
        while k < queue.count {
            let isUrgent = queue[k].urgent
            if !isUrgent && (CACurrentMediaTime() - t0) * 1000 > Self.aheadBudgetMS { break }
            var group: [(Tile, Page, (Int, Int))] = []
            while k < queue.count, group.count < 8, queue[k].urgent == isUrgent {
                let t = queue[k]; k += 1
                t.queued = false
                guard let (page, rescued) = makeRoom(for: t, touched: touched) else { overflow(t); continue }
                func put(_ x: Tile) -> Bool {
                    guard let at = page.place(x.job.tw, x.job.th) else { return false }
                    x.page = page; x.slot = (at.0, at.1)
                    page.tiles.append(x)
                    page.dirty = true   // keeps its CPU bytes until this flush has built its texture, even if it fills up
                    group.append((x, page, at))
                    touched[ObjectIdentifier(page)] = page
                    return true
                }
                // A compacted page's titles that are wanted right now go back in first, in this same flush (no blank frame).
                for r in rescued where !put(r) { overflow(r) }
                if !put(t) { overflow(t) }
            }
            // Pages in this group all have their CPU bytes (open, or opened by `placement`).
            let byPage = Dictionary(grouping: group, by: { ObjectIdentifier($0.1) })
            for (_, items) in byPage {
                let page = items[0].1
                page.bytes!.withUnsafeMutableBufferPointer { buf in
                    let dst = buf.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: items.count) {
                        Self.fill(items[$0].0.job, at: items[$0].2, into: dst, stride: page.size)
                    }
                }
                page.dirty = true
            }
            for (t, _, _) in group { built.append(t); if t.urgent { urgentCount += 1 }; t.urgent = false }
        }
        queue.removeFirst(min(k, queue.count))

        #if DEBUG
        let tTex = CACurrentMediaTime()
        stats.maxFillMS = max(stats.maxFillMS, (tTex - t0) * 1000)
        #endif
        // Each changed page → one new texture (fixed size, so sub-rects stay put); re-point all its tiles' sprites.
        for (_, page) in touched where page.dirty {
            let n = page.size
            let tex = SKTexture(data: Data(page.bytes!), size: CGSize(width: n, height: n))
            tex.filteringMode = .linear
            tex.usesMipmaps = false
            page.texture = tex
            page.dirty = false
            for t in page.tiles {
                let r = CGRect(x: CGFloat(t.slot.x) / CGFloat(n), y: CGFloat(t.slot.y) / CGFloat(n),
                               width: CGFloat(t.job.tw) / CGFloat(n), height: CGFloat(t.job.th) / CGFloat(n))
                let sub = SKTexture(rect: r, in: tex)
                sub.filteringMode = .linear
                t.texture = sub
                for ws in t.sprites { if let node = ws.node { node.texture = sub; node.isHidden = false } }
            }
            if page !== open { page.bytes = nil }   // sealed while this flush filled it
        }

        #if DEBUG
        stats.maxTexMS = max(stats.maxTexMS, (CACurrentMediaTime() - tTex) * 1000)
        stats.maxPagesPerFlush = max(stats.maxPagesPerFlush, touched.count)
        let ms = (CACurrentMediaTime() - t0) * 1000
        stats.flushes += 1; stats.built += built.count; stats.urgentBuilt += urgentCount
        stats.totalFlushMS += ms; stats.maxFlushMS = max(stats.maxFlushMS, ms)
        if loaded { stats.lateBuilt += urgentCount; stats.maxPanFlushMS = max(stats.maxPanFlushMS, ms) }
        else if urgentCount > 0 { loaded = true }
        stats.windowMax = max(stats.windowMax, ms); stats.windowBuilt += built.count
        if ProcessInfo.processInfo.arguments.contains("-TitleTilesLog") {
            let now = CACurrentMediaTime()
            if now - stats.lastLog >= 1 {
                NSLog("[TITLETILES] 1s: built=%d maxFlush=%.2f ms · totals: built=%d urgent=%d late=%d evictions=%d compactions=%d overflows=%d maxPanFlush=%.2f ms maxFlush=%.2f ms (fill %.2f, textures %.2f, pages/flush %d) · pages=%d/%d (%.1f MB of %.1f) resident=%d queue=%d cache=%d",
                      stats.windowBuilt, stats.windowMax, stats.built, stats.urgentBuilt, stats.lateBuilt, stats.evictions, stats.compactions,
                      stats.overflows, stats.maxPanFlushMS, stats.maxFlushMS, stats.maxFillMS, stats.maxTexMS, stats.maxPagesPerFlush, pages.count, Self.maxPages,
                      Double(pages.count * Self.pageSize * Self.pageSize * 4) / 1_048_576,
                      Double(Self.budgetBytes) / 1_048_576, pages.reduce(0) { $0 + $1.tiles.count }, queue.count, cache.count)
                stats.lastLog = now; stats.windowMax = 0; stats.windowBuilt = 0
            }
        }
        #endif
    }

    /// Make the open page one that can take `t`: the current open page, else a new page within the budget, else the
    /// least-recently-wanted page that nothing in the current pass wants (evicted), else — every page holds a title wanted
    /// right now — the page with the fewest wanted titles (at most half of its titles), COMPACTED: emptied, and its wanted
    /// titles returned to be put back first. nil = no room (the title draws per-glyph). Pages this flush already filled
    /// are never chosen.
    private func makeRoom(for t: Tile, touched: [ObjectIdentifier: Page]) -> (Page, [Tile])? {
        if let p = open, p.canPlace(t.job.tw, t.job.th) { return (p, []) }
        // The open page is full: seal it (if this flush filled it, its bytes go once its texture is built).
        if let p = open, !p.dirty { p.bytes = nil }
        open = nil
        var rescued: [Tile] = []
        let page: Page
        if pages.count < Self.maxPages {
            page = Page(size: Self.pageSize); pages.append(page)
        } else {
            let free = pages.filter { touched[ObjectIdentifier($0)] == nil }
            if let lru = free.map({ ($0, $0.lastWanted) }).filter({ $0.1 < stamp }).min(by: { $0.1 < $1.1 })?.0 {
                lru.reset()
                #if DEBUG
                stats.evictions += 1
                #endif
                page = lru
            } else {
                let scored = free.map { p in (p, p.tiles.filter { $0.lastWanted >= stamp }) }
                    .filter { $0.1.count * 2 <= $0.0.tiles.count }
                guard let (p, keep) = scored.min(by: { $0.1.count < $1.1.count }) else { return nil }
                p.reset()
                #if DEBUG
                stats.compactions += 1
                #endif
                rescued = keep
                page = p
            }
        }
        open = page
        return (page, rescued)
    }

    /// No page can take `t` right now: its titles draw from per-glyph sprites (the font atlas), so none is blank.
    private func overflow(_ t: Tile) {
        t.overflowed = true; t.urgent = false
        #if DEBUG
        stats.overflows += 1
        #endif
        for ws in t.sprites { if let n = ws.node { fallBack(n, t) } }
    }

    private func fallBack(_ sprite: SKSpriteNode, _ t: Tile) {
        guard let container = sprite.parent, container.userData?["perGlyphFallback"] == nil,
              let pt = container.userData?[MSDFLabel.pointSizeKey] as? CGFloat else { return }
        container.userData?["perGlyphFallback"] = true
        sprite.isHidden = true
        let color = sprite.value(forAttributeNamed: "a_glyph_color")?.vectorFloat4Value ?? vector_float4(1, 1, 1, 1)
        MSDFLabel.addGlyphSprites(to: container, lines: t.lines, pointSize: pt, font: t.font, midCaps: t.midCaps,
                                  colorVec: color)
    }

    /// Forget layouts no sprite shows any more (old faces, deleted or renamed titles). The next prune waits until the
    /// cache has doubled, so a large library never prunes per title.
    private var pruneAt = 4096
    private func pruneCache() {
        cache = cache.filter { _, t in t.page != nil || t.sprites.contains { $0.node != nil } }
        pruneAt = max(4096, cache.count * 2)
    }

    /// Fill one tile's slot. Thread-safe across jobs: each writes only its own slot (+ its own owner map).
    private static func fill(_ job: FillJob, at: (Int, Int), into dst: UnsafeMutablePointer<UInt8>, stride W: Int) {
        let font = job.font, quads = job.quads, ox = job.ox, oy = job.oy, s = job.s, tw = job.tw, th = job.th
        let aw = font.pixelW, ah = font.pixelH
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

}
