// Good Flow spike (throwaway, never merged) · the shared Metal state and the still renderer.
import Foundation
import Metal
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Step 3B's cheaper routes (design §2 B and D, one knob): A = the faithful one pass; B = the body once into an
/// offscreen picture at the slot's size, then the fringe's three taps; BD75 / BD50 = the same picture at 0.75 / 0.5 ×.
enum GFVariant: String, CaseIterable {
    case A, B, BD75, BD50
    /// The pass-1 picture's scale (nil = one pass).
    var passScale: Double? {
        switch self { case .A: return nil; case .B: return 1; case .BD75: return 0.75; case .BD50: return 0.5 }
    }
    static func parse(_ s: String?) -> GFVariant? { s.flatMap { v in allCases.first { $0.rawValue.lowercased() == v.lowercased() } } }
}

/// How one picture is drawn: the variant and the hash. A still and the live surface showing it always share one.
struct GFDrawMode: Equatable {
    var variant: GFVariant = .A
    var benchHash = false            // false = the stable hash (the spike's default); true = the bench's sin hash
    var label: String { "\(variant.rawValue)·\(benchHash ? "bench" : "stable")" }
}

/// One device, one queue, the pipelines (compiled into the app's metallib: a shader error fails the build; the hash is a
/// function constant, so each pipeline is specialised once and cached).
final class GFRenderer {
    static let shared = GFRenderer()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let lib: MTLLibrary
    let pixelFormat: MTLPixelFormat = .bgra8Unorm   // NOT _srgb: the shader writes the bench's gamma-encoded value
    private var pipes: [String: MTLRenderPipelineState] = [:]
    private let lock = NSLock()

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        lib = device.makeDefaultLibrary()!
    }

    /// The faithful pipeline (A) with the stable hash, for callers that only want "the" look.
    var pipeline: MTLRenderPipelineState { pipe("gf_fragment", benchHash: false) }

    /// `fragment` ∈ gf_fragment (A), gf_body (pass 1: rgba16Float + r16Float), gf_fringe (pass 2), gf_map_fragment.
    func pipe(_ fragment: String, benchHash: Bool, lib l: MTLLibrary? = nil) -> MTLRenderPipelineState {
        let key = "\(fragment)|\(benchHash)|\(l.map { ObjectIdentifier($0).hashValue } ?? 0)"
        lock.lock(); defer { lock.unlock() }
        if let p = pipes[key] { return p }
        let lb = l ?? lib
        let cv = MTLFunctionConstantValues()
        var bh = benchHash
        cv.setConstantValue(&bh, type: .bool, index: 0)
        let d = MTLRenderPipelineDescriptor()
        if fragment == "gf_map_fragment" {
            d.vertexFunction = lb.makeFunction(name: "gf_map_vertex")
            d.fragmentFunction = try! lb.makeFunction(name: fragment, constantValues: cv)
            d.colorAttachments[0].pixelFormat = pixelFormat
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        } else {
            d.vertexFunction = lb.makeFunction(name: "gf_vertex")
            d.fragmentFunction = try! lb.makeFunction(name: fragment, constantValues: cv)
            if fragment == "gf_body" {
                d.colorAttachments[0].pixelFormat = .rgba16Float
                d.colorAttachments[1].pixelFormat = .r16Float
            } else {
                d.colorAttachments[0].pixelFormat = pixelFormat
            }
        }
        let p = try! device.makeRenderPipelineState(descriptor: d)
        pipes[key] = p
        return p
    }

    static func makePipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ fmt: MTLPixelFormat, benchHash: Bool = true) -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        let cv = MTLFunctionConstantValues(); var bh = benchHash; cv.setConstantValue(&bh, type: .bool, index: 0)
        d.vertexFunction = lib.makeFunction(name: "gf_vertex")
        d.fragmentFunction = try! lib.makeFunction(name: "gf_fragment", constantValues: cv)
        d.colorAttachments[0].pixelFormat = fmt
        return try! device.makeRenderPipelineState(descriptor: d)
    }

    /// Encodes one full-target draw into `enc`.
    func encode(_ enc: MTLRenderCommandEncoder, _ u: GFUniforms, viewport: MTLViewport? = nil, pipeline p: MTLRenderPipelineState? = nil) {
        var u = u
        enc.setRenderPipelineState(p ?? pipeline)
        if let viewport { enc.setViewport(viewport) }
        enc.setFragmentBytes(&u, length: MemoryLayout<GFUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

/// The pass-1 pictures of one drawer (a live surface, a fill queue). Reused while the size holds; Metal orders the
/// reuse across command buffers on one queue (tracked resources), so one scratch per queue.
final class GFScratch {
    private(set) var col: MTLTexture?
    private(set) var glow: MTLTexture?
    func ensure(_ w: Int, _ h: Int) -> (MTLTexture, MTLTexture) {
        if let c = col, let g = glow, c.width == w, c.height == h { return (c, g) }
        let dev = GFRenderer.shared.device
        func make(_ f: MTLPixelFormat) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
            return dev.makeTexture(descriptor: td)!
        }
        col = make(.rgba16Float); glow = make(.r16Float)
        return (col!, glow!)
    }
    var bytes: Int { (col?.allocatedSize ?? 0) + (glow?.allocatedSize ?? 0) }
}

/// THE draw: every still and every live frame goes through here, so a still and its live surface cannot differ in
/// variant or hash by construction.
enum GFDraw {
    /// Round 2 (outcome 4): `-Pass2Only YES`, a timing arm for the LIVE surfaces only (LiveSurfaceView passes it): pass 1
    /// once, then pass 2 alone each frame. Stills never use it.
    static let pass2OnlyArm = UserDefaults.standard.bool(forKey: "Pass2Only")
    /// The pass-1 picture's rectangle in the slot's y-up fc pixels: every point the three taps can reach (the slot
    /// scaled by 1 ± fr about the field's centre), plus two texels for the bilinear taps. x0 / y1 whole pixels.
    static func pass1Rect(_ u: GFUniforms, s: Double, visibleH: Double? = nil) -> (x0: Double, y1: Double, w: Int, h: Int) {
        let W = Double(u.res.x), H = Double(u.res.y)
        // Round 2: a target showing only the slot's top `visibleH` pixels (a card's image zone) needs pass 1 only for the
        // points the three taps reach FROM those pixels: the slot's rows fc.y ∈ [H − visibleH, H].
        let yLo = visibleH.map { max(0, H - $0) } ?? 0
        let fr = Double(u.fringe) * 0.04 * (1 + 0.6 * Double(u.patina))
        let cx = W * 0.5 + Double(u.ctr.x), cy = H * 0.5 + Double(u.ctr.y)
        var xs: [Double] = [], ys: [Double] = []
        for k in [1 - fr, 1.0, 1 + fr] {
            for x in [0, W] { xs.append(cx + (x - cx) * k) }
            for y in [yLo, H] { ys.append(cy + (y - cy) * k) }
        }
        var m = 2.0 / s + 1
        if u.glass == 2 { m += 20 * Double(u.pt) }            // the flutes move p sideways (not a spike switch; kept honest)
        let x0 = floor(xs.min()! - m), x1 = ceil(xs.max()! + m), y0 = floor(ys.min()! - m), y1 = ceil(ys.max()! + m)
        return (x0, y1, max(2, Int(ceil((x1 - x0) * s))), max(2, Int(ceil((y1 - y0) * s))))
    }

    /// Encodes the picture `u` into `target` (whole target; `u.res` / `u.org` place the slot in it).
    /// Returns the pass-1 picture's pixel count (0 for A or flat).
    @discardableResult
    static func encode(_ cb: MTLCommandBuffer, target: MTLTexture, _ u: GFUniforms, _ mode: GFDrawMode, scratch: GFScratch?, pass2Only: Bool = false) -> Int {
        let R = GFRenderer.shared
        guard let s = mode.variant.passScale, u.flat == 0 else {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
            let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
            R.encode(enc, u, pipeline: R.pipe("gf_fragment", benchHash: mode.benchHash))
            enc.endEncoding()
            return 0
        }
        let r = pass1Rect(u, s: s, visibleH: target.height < Int(u.res.y) ? Double(target.height) : nil)
        let sc = scratch ?? GFScratch()
        let reuse = pass2Only && sc.col?.width == r.w && sc.col?.height == r.h
        let (tc, tg) = sc.ensure(r.w, r.h)
        var u1 = u
        u1.r1 = SIMD4(Float(r.x0), Float(r.y1), Float(s), 0); u1.r1Size = SIMD2(Float(r.w), Float(r.h)); u1.fwScale = Float(s)
        var u2 = u1; u2.fwScale = 1
        let rp1 = MTLRenderPassDescriptor()
        rp1.colorAttachments[0].texture = tc; rp1.colorAttachments[0].loadAction = .dontCare; rp1.colorAttachments[0].storeAction = .store
        rp1.colorAttachments[1].texture = tg; rp1.colorAttachments[1].loadAction = .dontCare; rp1.colorAttachments[1].storeAction = .store
        if !reuse {   // -Pass2Only: a TIMING arm (the picture freezes): pass 1 is drawn once, then only pass 2 a frame
            let e1 = cb.makeRenderCommandEncoder(descriptor: rp1)!
            R.encode(e1, u1, pipeline: R.pipe("gf_body", benchHash: mode.benchHash))
            e1.endEncoding()
        }
        let rp2 = MTLRenderPassDescriptor()
        rp2.colorAttachments[0].texture = target; rp2.colorAttachments[0].loadAction = .dontCare; rp2.colorAttachments[0].storeAction = .store
        let e2 = cb.makeRenderCommandEncoder(descriptor: rp2)!
        e2.setFragmentTexture(tc, index: 0); e2.setFragmentTexture(tg, index: 1)
        R.encode(e2, u2, pipeline: R.pipe("gf_fringe", benchHash: mode.benchHash))
        e2.endEncoding()
        return r.w * r.h
    }
}

/// Renders one entry × case × theme into an offscreen texture in one draw and reads it back as 8-bit RGBA, top row
/// first. Part B: `render(_:)` for a still's pixels + timings; `renderTexture(_:)` to keep the texture on the GPU.
final class GFStillRenderer {
    struct Result {
        let width: Int, height: Int
        let rgba: [UInt8]          // top row first (Metal's row 0 is the top already: no flip needed after the y-up fc)
        let gpuMs: Double          // command buffer gpuEndTime − gpuStartTime
        let encodeMs: Double       // CPU: descriptor + encoder + draw + commit, on the calling thread
    }
    let R = GFRenderer.shared
    var pipeline: MTLRenderPipelineState? = nil   // a diagnostic runtime pipeline (-ShaderVariant; A only)
    var mode = GFDrawMode()
    let scratch = GFScratch()

    /// A private render target + its draw, committed. Returns the texture and the committed command buffer.
    func renderTexture(_ u: GFUniforms, usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> (MTLTexture, MTLCommandBuffer, Double) {
        let t0 = CACurrentMediaTime()
        let w = Int(u.res.x), h = Int(u.res.y)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: R.pixelFormat, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = .private
        let tex = R.device.makeTexture(descriptor: td)!
        let cb = R.queue.makeCommandBuffer()!
        if let pipeline {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
            let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
            R.encode(enc, u, pipeline: pipeline)
            enc.endEncoding()
        } else {
            GFDraw.encode(cb, target: tex, u, mode, scratch: scratch)
        }
        cb.commit()
        return (tex, cb, (CACurrentMediaTime() - t0) * 1000)
    }

    /// Draw, wait, read back. The draw is its own command buffer, so its GPU time is the still's alone.
    func render(_ u: GFUniforms) -> Result {
        let (tex, cb, encMs) = renderTexture(u)
        cb.waitUntilCompleted()
        let gpu = (cb.gpuEndTime - cb.gpuStartTime) * 1000
        let rgba = Self.readRGBA(tex)
        return Result(width: tex.width, height: tex.height, rgba: rgba, gpuMs: gpu, encodeMs: encMs)
    }

    /// Reads a bgra8 texture back as 8-bit RGBA, top row first.
    static func readRGBA(_ tex: MTLTexture) -> [UInt8] {
        let R = GFRenderer.shared
        let w = tex.width, h = tex.height, bpr = w * 4
        let buf = R.device.makeBuffer(length: bpr * h, options: .storageModeShared)!
        let cb2 = R.queue.makeCommandBuffer()!, bl = cb2.makeBlitCommandEncoder()!
        bl.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: w, height: h, depth: 1),
                to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        bl.endEncoding(); cb2.commit(); cb2.waitUntilCompleted()
        let p = buf.contents().bindMemory(to: UInt8.self, capacity: bpr * h)
        var rgba = [UInt8](repeating: 0, count: bpr * h)
        for i in stride(from: 0, to: bpr * h, by: 4) {   // BGRA → RGBA
            rgba[i] = p[i + 2]; rgba[i + 1] = p[i + 1]; rgba[i + 2] = p[i]; rgba[i + 3] = 255
        }
        return rgba
    }

    static func writePNG(_ r: Result, to url: URL) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let data = Data(r.rgba) as CFData
        let img = CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                          space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "GF", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG destination \(url.path)"])
        }
        CGImageDestinationAddImage(dst, img, nil)
        if !CGImageDestinationFinalize(dst) { throw NSError(domain: "GF", code: 2) }
    }
}

/// `-RenderStills <dir>`: the 120 reference stills by the reference's names, plus timings.json and uniforms.json.
/// A relative <dir> is inside the app's Documents (the Mac build is sandboxed: its container). Step 3B: `-Variant
/// A|B|BD75|BD50` and `-Hash stable|bench` (default A, stable; -ShaderVariant overrides with a runtime A). Extra switches:
/// `-StillsGrain 0` (bake without the final grain term), `-StillsRepeat N` (GPU timings: N draws, default 5).
enum GFStillsBatch {
    static func run(dir: String) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = dir.hasPrefix("/") ? URL(fileURLWithPath: dir) : docs.appendingPathComponent(dir)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let grainOn: Int32 = (d.object(forKey: "StillsGrain") as? String).map { $0 == "0" ? 0 : 1 } ?? 1
        let repeats = max(1, d.integer(forKey: "StillsRepeat") == 0 ? 5 : d.integer(forKey: "StillsRepeat"))
        let only = d.string(forKey: "StillsOnly")
        let r = GFStillsRendererFactory.make()
        r.mode = GFDrawMode(variant: GFVariant.parse(d.string(forKey: "Variant")) ?? .A, benchHash: d.string(forKey: "Hash") == "bench")
        let L = GFLook.shared
        // warm-up: the first draw pays pipeline residency; keep it out of the table
        _ = r.render(GFUniforms.make(GFCase.reference[4], L.entries[0], .light))
        var rows: [[String: Any]] = [], unis: [String: Any] = [:]
        let t0 = CACurrentMediaTime()
        let scaleOver = d.double(forKey: "StillsScale3to")   // round 2: draw the 3× cases at this scale (the 2× live layer)
        for e in L.entries { for th in GFTheme.allCases { for cs0 in GFCase.reference {
            let name = "\(cs0.name)__\(e.id)__\(th.rawValue).png"
            if let only, !name.contains(only) { continue }
            let cs = (scaleOver > 0 && cs0.scale == 3) ? GFCase(name: cs0.name, kind: cs0.kind, w: cs0.w, h: cs0.h, scale: scaleOver, r: cs0.r, heroRect: cs0.heroRect) : cs0
            var u = GFUniforms.make(cs, e, th); u.grainOn = grainOn
            let first = r.render(u)
            var gpus = [first.gpuMs], encs = [first.encodeMs]
            for _ in 1..<repeats { let x = r.render(u); gpus.append(x.gpuMs); encs.append(x.encodeMs) }
            // burst: 10 draws committed back to back (the GPU at a sustained clock, as a live surface keeps it),
            // each its own command buffer; the isolated draws above include the GPU's ramp from idle.
            // Command buffers in flight together overlap on the GPU, so the burst's figure is its span / 10.
            let cbs = (0..<10).map { _ in r.renderTexture(u).1 }
            cbs.forEach { $0.waitUntilCompleted() }
            let span = (cbs.map(\.gpuEndTime).max()! - cbs.map(\.gpuStartTime).min()!) * 1000 / 10
            do { try GFStillRenderer.writePNG(first, to: out.appendingPathComponent(name)) } catch { NSLog("GF png \(name): \(error)") }
            let sg = gpus.sorted(), se = encs.sorted()
            rows.append(["file": name, "case": cs.name, "entry": e.id, "theme": th.rawValue, "px": [first.width, first.height],
                         "gpuMs": gpus, "gpuMsMedian": sg[sg.count / 2], "gpuMsMin": sg[0],
                         "encodeMsMedian": se[se.count / 2], "gpuMsBurstPerDraw": span, "grainOn": Int(grainOn)])
            unis[name] = u.benchNamed
        } } }
        let dev = GFRenderer.shared.device
        let meta: [String: Any] = ["device": dev.name, "variant": GFStillsRendererFactory.variantName, "mode": r.mode.label, "repeats": repeats,
                                   "totalS": CACurrentMediaTime() - t0, "stills": rows]
        try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("timings.json"))
        try? JSONSerialization.data(withJSONObject: unis, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("uniforms.json"))
        try? "done \(rows.count)\n".write(to: out.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
        NSLog("GF RenderStills: \(rows.count) stills → \(out.path)")
    }
}

/// Shader variants for the equality hunt (`-ShaderVariant metallib|safe|fast|precise-sin`): `metallib` (default) is
/// the build's own GoodFlow.metal (MTL_FAST_MATH = NO); the others compile the bundled source at run time.
enum GFStillsRendererFactory {
    static var variantName: String { UserDefaults.standard.string(forKey: "ShaderVariant") ?? "metallib" }
    static func make() -> GFStillRenderer {
        let r = GFStillRenderer()
        let v = variantName
        if v != "metallib" { r.pipeline = runtimePipeline(v) }
        return r
    }
    static func runtimePipeline(_ v: String) -> MTLRenderPipelineState {
        let R = GFRenderer.shared
        let b = Bundle.main
        let hdr = try! String(contentsOf: b.url(forResource: "GFShared", withExtension: "h.txt")!, encoding: .utf8)
        var src = try! String(contentsOf: b.url(forResource: "GoodFlow", withExtension: "metal.txt")!, encoding: .utf8)
        // `angle-…`: a diagnostic only. Documents/angle_wrapped.metal = Chrome's own ANGLE translation of the bench shader
        // (WEBGL_debug_shaders), wrapped to read GFUniforms; tells port mistakes from compiler / precision differences.
        if v.hasPrefix("angle") {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            src = try! String(contentsOf: docs.appendingPathComponent("angle_wrapped.metal"), encoding: .utf8)
        }
        src = src.replacingOccurrences(of: "#include \"GFShared.h\"", with: hdr)
        // <mode>[-fastfn|-precisefn][-psin|-fsin]: math mode safe|relaxed|fast, fp32 function precision, hash11's sin
        let o = MTLCompileOptions()
        let parts = Set(v.split(separator: "-").map(String.init))
        o.mathMode = parts.contains("fast") ? .fast : parts.contains("relaxed") ? .relaxed : .safe
        if parts.contains("fastfn") { o.mathFloatingPointFunctions = .fast }
        if parts.contains("precisefn") { o.mathFloatingPointFunctions = .precise }
        if parts.contains("psin") { src = "#define GF_SIN(x) metal::precise::sin(x)\n" + src }
        if parts.contains("fsin") { src = "#define GF_SIN(x) metal::fast::sin(x)\n" + src }
        if parts.contains("qhash") { src = "#define GF_QHASH 1\n" + src }
        let lib = try! R.device.makeLibrary(source: src, options: o)
        return GFRenderer.makePipeline(R.device, lib, R.pixelFormat, benchHash: true)   // the diagnostics keep the sin hash (qhash snaps it)
    }
}
