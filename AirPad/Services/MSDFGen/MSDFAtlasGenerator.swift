#if DEBUG
import UIKit
import CoreText

//  Brief BE1 (SPIKE) — build an MSDF atlas ON DEVICE, in the exact format the Map shader
//  already consumes, from any Core Text font.
//
//  Why this exists: SF Pro and New York cannot be shipped as pre-baked atlases (Apple's
//  font licence forbids redistributing their outlines), so the only legitimate route to
//  "SF Pro on the Map" is to rasterise them at runtime through the OS. This proves that is
//  possible, at what cost, and at what quality.
//
//  Output matches msdf-atlas-gen's JSON contract: `atlas{distanceRange,size,width,height}`,
//  `metrics{lineHeight}`, `glyphs[{unicode,advance,planeBounds,atlasBounds}]`, y-from-bottom.

struct GeneratedAtlas {
    let png: Data
    let json: Data
    let glyphCount: Int
    let requestedCount: Int
    let width: Int
    let height: Int
    let seconds: Double
    let peakMemoryMB: Double
}

enum MSDFAtlasGenerator {

    /// The BD charset — must stay wide or the Map silently drops characters (Brief BC0).
    static var defaultCharset: [UInt32] {
        var cps: [UInt32] = []
        cps += (0x20...0x7E).map { UInt32($0) }      // ASCII
        cps += (0xA0...0xFF).map { UInt32($0) }      // Latin-1 (accents, ¿ ¡)
        cps += (0x100...0x17F).map { UInt32($0) }    // Latin Extended-A
        cps += [0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026]
        return cps
    }

    /// Generate an atlas for `font`. `pxPerEm`/`pxRange` MUST match the shipping atlases
    /// (48 / 4) — `MSDFLabel.applyLOD` derives screenPxRange from them, so a mismatch
    /// silently mis-scales antialiasing.
    static func generate(font: CTFont,
                         charset: [UInt32] = defaultCharset,
                         pxPerEm: Double = 48,
                         pxRange: Double = 4,
                         overlapSupport: Bool = true) -> GeneratedAtlas {
        let t0 = CFAbsoluteTimeGetCurrent()
        let mem0 = residentMB()

        // 1 — rasterise every glyph
        var results: [MSDFGlyphResult] = []
        results.reserveCapacity(charset.count)
        for cp in charset {
            if let g = MSDFBridge.generate(forCharacter: cp, font: font,
                                           pxPerEm: pxPerEm, pxRange: pxRange,
                                           overlapSupport: overlapSupport) {
                results.append(g)
            }
        }

        // 2 — shelf-pack the bitmaps into a square-ish atlas (1px gutter avoids bleed
        //     between neighbours under the shader's linear sampling).
        let pad = 1
        let drawn = results.filter { $0.hasBitmap }
        let totalArea = drawn.reduce(0) { $0 + (Int($1.width) + pad) * (Int($1.height) + pad) }
        var side = max(64, Int(Double(totalArea).squareRoot() * 1.12))
        side = min(4096, side)

        var placements: [(MSDFGlyphResult, Int, Int)] = []
        var packed = false
        var atlasW = side, atlasH = side
        // Tallest-first shelf packing; grow and retry if it doesn't fit.
        let sorted = drawn.sorted { $0.height > $1.height }
        for _ in 0..<6 {
            placements.removeAll(keepingCapacity: true)
            var penX = pad, penY = pad, rowH = 0
            var ok = true
            for g in sorted {
                let w = Int(g.width), h = Int(g.height)
                if penX + w + pad > atlasW { penX = pad; penY += rowH + pad; rowH = 0 }
                if penY + h + pad > atlasH { ok = false; break }
                placements.append((g, penX, penY))
                penX += w + pad
                rowH = max(rowH, h)
            }
            if ok { packed = true; break }
            atlasW = min(4096, atlasW * 2); atlasH = atlasW
        }
        guard packed else {
            return GeneratedAtlas(png: Data(), json: Data(), glyphCount: 0,
                                  requestedCount: charset.count, width: 0, height: 0,
                                  seconds: CFAbsoluteTimeGetCurrent() - t0, peakMemoryMB: 0)
        }

        // 3 — blit into one RGBX buffer.
        //
        // ★ 4 bytes/pixel, not 3: CoreGraphics on iOS has no 24bpp RGB context, so a
        // 3-channel buffer makes `CGContext(...)` return nil and the PNG comes out empty.
        // The unused 4th channel is `noneSkipLast` (NOT alpha), so nothing is premultiplied
        // and the msdf distance bytes survive — the same contract `MSDFFont.loadDataTexture`
        // already reads the baked atlases with.
        //
        // Rows are written TOP-DOWN here (CGContext row 0 is the top) while msdf geometry is
        // y-up, so row `atlasH-1-y` receives source row `y`. That bakes the flip into the
        // blit instead of relying on an image orientation flag, which `pngData()` ignores.
        var rgbx = [UInt8](repeating: 0, count: atlasW * atlasH * 4)
        for (g, x0, y0) in placements {
            guard let src = g.rgb else { continue }
            src.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let s = raw.bindMemory(to: UInt8.self)
                for y in 0..<Int(g.height) {
                    let dstY = atlasH - 1 - (y0 + y)
                    if dstY < 0 || dstY >= atlasH { continue }
                    for x in 0..<Int(g.width) {
                        let si = (y * Int(g.width) + x) * 3
                        let di = (dstY * atlasW + (x0 + x)) * 4
                        rgbx[di] = s[si]; rgbx[di+1] = s[si+1]; rgbx[di+2] = s[si+2]; rgbx[di+3] = 255
                    }
                }
            }
        }

        // 4 — encode PNG
        let cs = CGColorSpaceCreateDeviceRGB()
        var pngData = Data()
        rgbx.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            guard let ctx = CGContext(data: buf.baseAddress, width: atlasW, height: atlasH,
                                      bitsPerComponent: 8, bytesPerRow: atlasW * 4,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let cg = ctx.makeImage() else { return }
            pngData = UIImage(cgImage: cg).pngData() ?? Data()
        }

        // 5 — JSON in msdf-atlas-gen's shape
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        var glyphs: [[String: Any]] = []
        let placedByCp = Dictionary(uniqueKeysWithValues: placements.map { (UInt32($0.0.unicode), $0) })
        for g in results {
            var e: [String: Any] = ["unicode": Int(g.unicode), "advance": g.advance]
            if let (gg, x0, y0) = placedByCp[UInt32(g.unicode)] {
                e["planeBounds"] = ["left": gg.planeLeft, "bottom": gg.planeBottom,
                                    "right": gg.planeRight, "top": gg.planeTop]
                e["atlasBounds"] = ["left": Double(x0), "bottom": Double(y0),
                                    "right": Double(x0 + Int(gg.width)),
                                    "top": Double(y0 + Int(gg.height))]
            }
            glyphs.append(e)
        }
        let root: [String: Any] = [
            "atlas": ["distanceRange": pxRange, "size": pxPerEm,
                      "width": atlasW, "height": atlasH, "yOrigin": "bottom"],
            "metrics": ["lineHeight": (ascent + descent + leading)],
            "glyphs": glyphs,
        ]
        let jsonData = (try? JSONSerialization.data(withJSONObject: root)) ?? Data()

        return GeneratedAtlas(png: pngData, json: jsonData,
                              glyphCount: results.count, requestedCount: charset.count,
                              width: atlasW, height: atlasH,
                              seconds: CFAbsoluteTimeGetCurrent() - t0,
                              peakMemoryMB: max(0, residentMB() - mem0))
    }

    /// Resident footprint (MB). `phys_footprint` is what jetsam actually measures.
    private static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}
#endif
