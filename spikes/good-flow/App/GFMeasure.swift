// Good Flow spike (throwaway, never merged) · `-Measure3b <dir>`: step 3B's offscreen numbers, valid with the screen
// locked (command-buffer GPU time, fill times, texture bytes, phys_footprint, pixels read back from textures). Writes
// <Documents>/<dir>/measure.json, the equality stills per variant (v-<variant>/<reference name>.png) and the Map
// sharpness stills (map-<theme>-cap<N>.png, map-<theme>-full.png). Sections can be limited: -MeasureOnly
// timing,paced,stills,switches,map,jump,cards (default all). Cadence and presentation are NOT measured here (locked screen).
import UIKit
import Metal

enum GFMeasure {
    static func run(dir: String) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = dir.hasPrefix("/") ? URL(fileURLWithPath: dir) : docs.appendingPathComponent(dir)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let only = Set((UserDefaults.standard.string(forKey: "MeasureOnly") ?? "timing,paced,stills,switches,map,jump,cards").split(separator: ",").map(String.init))
        var res: [String: Any] = ["device": GFRenderer.shared.device.name, "startedAt": Date().description]
        func save() { try? JSONSerialization.data(withJSONObject: res, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("measure.json")) }
        let L = GFLook.shared
        let r = GFStillRenderer()
        _ = r.render(GFUniforms.make(GFCase.reference[3], L.entries[0], .light))   // warm-up

        // 1 · GPU ms per frame, per variant × case (every entry, both themes): 10 sequential frames at advancing time
        // (each its own command buffer, waited: the cost of one live frame) + a burst of 10 (span / 10).
        if only.contains("timing") {
            var rows: [[String: Any]] = []
            for v in GFVariant.allCases {
                r.mode = GFDrawMode(variant: v, benchHash: false)
                for cs in GFCase.reference {
                    var seq: [Double] = [], burst: [Double] = [], p1 = 0
                    for e in L.entries { for th in GFTheme.allCases {
                        for k in 0..<12 {
                            let u = GFUniforms.make(cs, e, th, time: L.stillTime + Double(k) / 30)
                            let (_, cb, _) = r.renderTexture(u); cb.waitUntilCompleted()
                            if k >= 2 { seq.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                        }
                        let u = GFUniforms.make(cs, e, th)
                        let cbs = (0..<10).map { _ in r.renderTexture(u).1 }
                        cbs.forEach { $0.waitUntilCompleted() }
                        burst.append((cbs.map(\.gpuEndTime).max()! - cbs.map(\.gpuStartTime).min()!) * 1000 / 10)
                        if let s = v.passScale { let q = GFDraw.pass1Rect(u, s: s); p1 = q.w * q.h }
                    } }
                    let (w, h) = cs.pixelSize
                    rows.append(["variant": v.rawValue, "case": cs.name, "px": [w, h], "pass1px": p1, "n": seq.count,
                                 "gpuMsP50": pct(seq, 50), "gpuMsP95": pct(seq, 95), "gpuMsMax": seq.max() ?? -1,
                                 "burstPerDrawP50": pct(burst, 50), "burstPerDrawMax": burst.max() ?? -1])
                    NSLog("GF measure timing \(v.rawValue) \(cs.name) p50 \(pct(seq, 50))")
                }
            }
            res["timing"] = rows; save()
        }

        // 1b · PACED, as a live surface draws: one frame every 1/30 s (and 1/60 s) for 3 s, each its own command buffer
        // (not waited between), the GPU time of each read in its completion handler. The sequential figures above
        // include the GPU's ramp from idle after every wait; these are the live surface's own conditions.
        if only.contains("paced") {
            var rows: [[String: Any]] = []
            let liveCases = Array(GFCase.reference.prefix(4))
            for rate in [30.0, 60.0] { for v in GFVariant.allCases { for cs in liveCases { for th in GFTheme.allCases {
                r.mode = GFDrawMode(variant: v, benchHash: UserDefaults.standard.string(forKey: "Hash") == "bench")
                let n = Int(rate * 3), t0 = CACurrentMediaTime()
                var cbs: [MTLCommandBuffer] = []
                for k in 0..<n {
                    let target = t0 + Double(k) / rate
                    while CACurrentMediaTime() < target { usleep(300) }
                    let u = GFUniforms.make(cs, L.entries[0], th, time: L.stillTime + Double(k) / rate)
                    cbs.append(r.renderTexture(u).1)      // committed, not waited (a live surface does not wait)
                }
                cbs.forEach { $0.waitUntilCompleted() }
                let g = cbs.dropFirst(10).map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 }
                rows.append(["rate": rate, "variant": v.rawValue, "case": cs.name, "theme": th.rawValue, "n": g.count,
                             "gpuMsP50": pct(g, 50), "gpuMsP95": pct(g, 95), "busyPct": pct(g, 50) * rate / 10])
                NSLog("GF measure paced \(rate) \(v.rawValue) \(cs.name) \(th.rawValue) p50 \(pct(g, 50)) p95 \(pct(g, 95))")
            } } } }
            res["paced"] = rows; save()
        }

        // 2 · equality stills: the 120 reference names per variant, stable hash (compare.py reads them).
        if only.contains("stills") {
            var fills: [[String: Any]] = []
            for v in GFVariant.allCases {
                r.mode = GFDrawMode(variant: v, benchHash: false)
                let vd = out.appendingPathComponent("v-\(v.rawValue)")
                try? fm.createDirectory(at: vd, withIntermediateDirectories: true)
                for e in L.entries { for th in GFTheme.allCases { for cs in GFCase.reference {
                    let x = r.render(GFUniforms.make(cs, e, th))
                    try? GFStillRenderer.writePNG(x, to: vd.appendingPathComponent("\(cs.name)__\(e.id)__\(th.rawValue).png"))
                } } }
                // fill time of one still (main-thread encode + GPU), per case, light e0..e5
                for cs in GFCase.reference.prefix(4) {
                    var gpu: [Double] = [], enc: [Double] = []
                    for e in L.entries { let x = r.render(GFUniforms.make(cs, e, .light)); gpu.append(x.gpuMs); enc.append(x.encodeMs) }
                    fills.append(["variant": v.rawValue, "case": cs.name, "gpuMsP50": pct(gpu, 50), "gpuMsMax": gpu.max()!, "encodeMsP50": pct(enc, 50)])
                }
            }
            res["stillFill"] = fills; save()
        }

        // 3 · the switches' cost (glass, edge bend) on the live surfaces, A and BD50.
        if only.contains("switches") {
            var rows: [[String: Any]] = []
            for v in [GFVariant.A, .BD50] {
                r.mode = GFDrawMode(variant: v, benchHash: false)
                for cs in GFCase.reference.prefix(4) {
                    for (glass, lens) in [(true, true), (false, true), (true, false), (false, false)] {
                        var seq: [Double] = []
                        for e in L.entries.prefix(3) { for k in 0..<10 {
                            var u = GFUniforms.make(cs, e, .light, time: L.stillTime + Double(k) / 30)
                            if !glass { u.glass = 0 }; if !lens { u.lens = 0 }
                            let (_, cb, _) = r.renderTexture(u); cb.waitUntilCompleted()
                            if k >= 2 { seq.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                        } }
                        rows.append(["variant": v.rawValue, "case": cs.name, "glass": glass, "edgeBend": lens, "gpuMsP50": pct(seq, 50), "gpuMsP95": pct(seq, 95)])
                    }
                }
            }
            res["switches"] = rows; save()
        }

        // 4 · the Map's 262 stills: memory and fill per cap, at the Mac's 2× and the iPhone's 3×; sharpness stills.
        if only.contains("map") {
            var rows: [[String: Any]] = []
            let caps = (UserDefaults.standard.string(forKey: "MapCaps") ?? "128,160,192,256").split(separator: ",").compactMap { Int($0) }
            for scale in [2.0, 3.0] { for cap in caps {
                let mac = scale == 2
                let view = mac ? CGSize(width: 1728, height: 1028) : CGSize(width: 440, height: 956)
                let p0 = GFLibrary.shared.positions[0]
                let vis = visibleOrbs(cam: (p0.x, p0.y), camScale: 1, view: view)
                sleepMs(1500)
                let before = GFRecorder.physFootprintMB()
                let c = GFOrbStillCache(cap: cap, scale: scale, theme: .light, mode: GFDrawMode(), flat: false)
                c.fill(first: vis)
                let t0 = CACurrentMediaTime()
                while c.allDone == nil, CACurrentMediaTime() - t0 < 60 { sleepMs(20) }
                sleepMs(300)
                let after = GFRecorder.physFootprintMB()
                var row = c.summary
                row["visibleOrbs"] = vis.count; row["view"] = [view.width, view.height]
                row["footprintBeforeMB"] = before; row["footprintAfterMB"] = after; row["footprintDeltaMB"] = after - before
                if mac {
                    for th in GFTheme.allCases {
                        let cc = th == .light ? c : GFOrbStillCache(cap: cap, scale: scale, theme: th, mode: GFDrawMode(), flat: false)
                        if th == .dark { cc.fill(first: vis); let t1 = CACurrentMediaTime(); while cc.allDone == nil, CACurrentMediaTime() - t1 < 60 { sleepMs(20) } }
                        writeMap(cc, theme: th, scale: scale, to: out.appendingPathComponent("map-\(th.rawValue)-cap\(cap).png"))
                    }
                }
                rows.append(row)
                NSLog("GF measure map cap \(cap) @\(scale): \(row)")
            } }
            // the uncapped reference for the sharpness sheet (every orb at its full 1.25 D × 2 px)
            for th in GFTheme.allCases {
                let c = GFOrbStillCache(cap: 4096, scale: 2, theme: th, mode: GFDrawMode(), flat: false)
                c.fill(first: [])
                let t0 = CACurrentMediaTime(); while c.allDone == nil, CACurrentMediaTime() - t0 < 60 { sleepMs(20) }
                if th == .light { var row = c.summary; row["note"] = "uncapped (reference for sharpness)"; rows.append(row) }
                writeMap(c, theme: th, scale: 2, to: out.appendingPathComponent("map-\(th.rawValue)-full.png"))
            }
            res["map"] = rows; save()
        }

        // 5 · still ↔ live: the first live frame (LiveSurfaceView.frameUniforms, the tick's own path) vs the still, and
        // the last live frame vs the still redrawn at its time value, per variant, for the live surfaces.
        if only.contains("jump") {
            var rows: [[String: Any]] = []
            let cases = [GFCase.card(w: 228, h: 320, r: 14, heroFrac: 0.43, scale: 2), GFCase.card(w: 348, h: 532, r: 30, heroFrac: 0.40, scale: 3),
                         GFCase.detail(widthPt: 440, heightPt: 262, scale: 3)]
            for v in GFVariant.allCases { for cs in cases { for e in L.entries.prefix(3) {
                let mode = GFDrawMode(variant: v, benchHash: false)
                r.mode = mode
                let u0 = GFUniforms.make(cs, e, .light)
                let (still, cb, _) = r.renderTexture(u0); cb.waitUntilCompleted()
                var first = GFUniforms(), last = GFUniforms(), endT = 0.0
                DispatchQueue.main.sync {
                    let lv = LiveSurfaceView(frame: .zero)
                    lv.mode = mode; lv.base = u0; lv.stillTime = Double(u0.time)
                    first = lv.frameUniforms(width: still.width, height: still.height)
                    lv.stillTime = Double(u0.time) + 3.7                 // as endLive leaves it: the last live frame's time
                    last = lv.frameUniforms(width: still.width, height: still.height); endT = lv.stillTime
                }
                let d1 = GFJump.compare(u: first, mode: mode, still: still)
                let u1 = GFUniforms.make(cs, e, .light, time: endT)
                let (still2, cb2, _) = r.renderTexture(u1); cb2.waitUntilCompleted()
                let d2 = GFJump.compare(u: last, mode: mode, still: still2)
                rows.append(["variant": v.rawValue, "case": "\(cs.name)-\(Int(cs.w))", "entry": e.id, "enterMean": d1.mean, "enterMax": d1.max, "leaveMean": d2.mean, "leaveMax": d2.max])
            } } }
            res["jump"] = rows; save()
        }

        // 6 · card stills: bytes each, and how many the "visible + one screen each way" rule keeps at T's window sizes.
        if only.contains("cards") {
            var rows: [[String: Any]] = []
            for (w, h) in [(1728.0, 1028.0), (1703.0, 924.0)] {
                let cols = max(1, floor((w - 48 + 10) / 238)), rowH = 330.0
                let visRows = ceil(h / rowH) + 1, aheadRows = ceil(3 * h / rowH) + 1
                let st = GFCardStill(w: 456, h: 640, time: 12, mode: GFDrawMode(), flat: false)!
                rows.append(["window": [w, h], "columns": cols, "visible": cols * visRows, "keptOneScreenEachWay": cols * aheadRows,
                             "bytesEach": st.bytes, "keptMB": Double(st.bytes) * cols * aheadRows / 1_048_576, "visibleMB": Double(st.bytes) * cols * visRows / 1_048_576])
            }
            let stp = GFCardStill(w: 1044, h: 1596, time: 12, mode: GFDrawMode(), flat: false)!
            rows.append(["window": [440, 956], "device": "iPhone carousel 348 × 532 @3", "visible": 2, "keptOneScreenEachWay": 5, "bytesEach": stp.bytes,
                         "keptMB": Double(stp.bytes) * 5 / 1_048_576])
            res["cards"] = rows; save()
        }
        res["finishedAt"] = Date().description
        save()
        try? "done\n".write(to: out.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
        NSLog("GF Measure3b done → \(out.path)")
    }

    static func pct(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted(); guard !s.isEmpty else { return -1 }
        let k = Double(s.count - 1) * p / 100, f = Int(k), c = min(f + 1, s.count - 1)
        return s[f] + (s[c] - s[f]) * (k - Double(f))
    }
    static func sleepMs(_ ms: Double) { usleep(useconds_t(ms * 1000)) }

    static func visibleOrbs(cam: (Double, Double), camScale: Double, view: CGSize) -> [Int] {
        let lib = GFLibrary.shared
        let hw = Double(view.width) / 2 * camScale, hh = Double(view.height) / 2 * camScale
        return lib.items.indices.filter { i in
            let p = lib.positions[i], r = lib.items[i].diam * 0.625
            return abs(p.x - cam.0) < hw + r && abs(p.y - cam.1) < hh + r
        }.sorted { hypot(lib.positions[$0].x - cam.0, lib.positions[$0].y - cam.1) < hypot(lib.positions[$1].x - cam.0, lib.positions[$1].y - cam.1) }
    }

    /// The Map pass offscreen at zoom 1 (900 × 560 pt around e0, at `scale`), read back to a PNG (the sharpness check).
    static func writeMap(_ c: GFOrbStillCache, theme: GFTheme, scale: Double, to url: URL) {
        let R = GFRenderer.shared
        let vw = 900.0, vh = 560.0, w = Int(vw * scale), h = Int(vh * scale)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
        let t = R.device.makeTexture(descriptor: td)!
        let g = GFColor.gamma(GFSurfaces(theme).page)
        let p0 = GFLibrary.shared.positions[0]
        var m = GFMapUniforms(cam: SIMD2(Float(p0.x + 80), Float(p0.y)), camScale: 1, pxPerPt: Float(scale), viewPt: SIMD2(Float(vw), Float(vh)),
                              ground: SIMD3(Float(g.x), Float(g.y), Float(g.z)), grain: Float(GFLook.shared.dial("grain")), time: Float(GFLook.shared.stillTime),
                              grainOn: 1, flat: 0, pad2: 0, revealOn: 0, revealSize: 0, revealR: 0, revealSoft: 0)
        let cb = R.queue.makeCommandBuffer()!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: g.x, green: g.y, blue: g.z, alpha: 1)
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        c.draw(enc, &m)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        let px = GFStillRenderer.readRGBA(t)
        try? GFStillRenderer.writePNG(.init(width: w, height: h, rgba: px, gpuMs: 0, encodeMs: 0), to: url)
    }
}

/// Round 2 (outcome 5) · `-PoolsFromAngle <dir>`: draws Chrome's own ANGLE translation of the bench shader, instrumented
/// (tools/angle_pools.py → Documents/angle_pools.metal), compiled fast / fast fp32 functions (the compile that reproduces T's
/// bench stills), and reads back the three hash11 values of every pool exactly as that shader computed them while drawing.
/// Writes <dir>/angle-pools.json {entry: 6 × [h1,h2,h3]} and the stills it drew (<case>__<entry>__<theme>.png, which must
/// still equal the reference: the instrumentation must not have changed the compile). Then quits.
enum GFPoolsAngle {
    static func run(dir: String) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appendingPathComponent(dir)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let R = GFRenderer.shared
        let hdr = try! String(contentsOf: Bundle.main.url(forResource: "GFShared", withExtension: "h.txt")!, encoding: .utf8)
        var src = try! String(contentsOf: docs.appendingPathComponent("angle_pools.metal"), encoding: .utf8)
        src = src.replacingOccurrences(of: "#include \"GFShared.h\"", with: hdr)
        let o = MTLCompileOptions(); o.mathMode = .fast; o.mathFloatingPointFunctions = .fast
        let lib = try! R.device.makeLibrary(source: src, options: o)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "gf_vertex"); d.fragmentFunction = lib.makeFunction(name: "gf_fragment")
        d.colorAttachments[0].pixelFormat = R.pixelFormat
        let pipe = try! R.device.makeRenderPipelineState(descriptor: d)
        var res: [String: Any] = [:]
        let L = GFLook.shared
        for e in L.entries { for th in GFTheme.allCases { for cs in GFCase.reference where cs.name == "detail-iphone" || cs.name == "card-mac" || cs.name == "orb-90-@2" {
            let u = GFUniforms.make(cs, e, th)
            let buf = R.device.makeBuffer(length: 18 * 4, options: .storageModeShared)!
            let p = buf.contents().bindMemory(to: Float.self, capacity: 18)
            for k in 0..<18 { p[k] = -1 }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: R.pixelFormat, width: Int(u.res.x), height: Int(u.res.y), mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
            let tex = R.device.makeTexture(descriptor: td)!
            let cb = R.queue.makeCommandBuffer()!
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
            let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
            enc.setFragmentBuffer(buf, offset: 0, index: 1)
            R.encode(enc, u, pipeline: pipe)
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            let rgba = GFStillRenderer.readRGBA(tex)
            try? GFStillRenderer.writePNG(.init(width: tex.width, height: tex.height, rgba: rgba, gpuMs: 0, encodeMs: 0),
                                          to: out.appendingPathComponent("\(cs.name)__\(e.id)__\(th.rawValue).png"))
            let vals = (0..<6).map { i in (0..<3).map { k in Double(p[i * 3 + k]) } }
            res["\(e.id)|\(cs.name)|\(th.rawValue)"] = vals
        } } }
        try? JSONSerialization.data(withJSONObject: res, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("angle-pools.json"))
        try? "done\n".write(to: out.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
    }
}
