// Good Flow spike (throwaway, never merged) · the shared Metal state and the still renderer.
import Foundation
import Metal
import QuartzCore
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// One device, one queue, the pipeline (compiled into the app's metallib: a shader error fails the build).
final class GFRenderer {
    static let shared = GFRenderer()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let pixelFormat: MTLPixelFormat = .bgra8Unorm   // NOT _srgb: the shader writes the bench's gamma-encoded value

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let lib = device.makeDefaultLibrary()!
        pipeline = GFRenderer.makePipeline(device, lib, pixelFormat)
    }

    static func makePipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "gf_vertex")
        d.fragmentFunction = lib.makeFunction(name: "gf_fragment")
        d.colorAttachments[0].pixelFormat = fmt
        return try! device.makeRenderPipelineState(descriptor: d)
    }

    /// Encodes the one draw into `enc` (viewport = the slot).
    func encode(_ enc: MTLRenderCommandEncoder, _ u: GFUniforms, viewport: MTLViewport? = nil, pipeline p: MTLRenderPipelineState? = nil) {
        var u = u
        enc.setRenderPipelineState(p ?? pipeline)
        if let viewport { enc.setViewport(viewport) }
        enc.setFragmentBytes(&u, length: MemoryLayout<GFUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
    var pipeline: MTLRenderPipelineState? = nil   // a variant pipeline (nil = the app's metallib)

    /// A private render target + its draw, committed. Returns the texture and the committed command buffer.
    func renderTexture(_ u: GFUniforms, usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> (MTLTexture, MTLCommandBuffer, Double) {
        let t0 = CACurrentMediaTime()
        let w = Int(u.res.x), h = Int(u.res.y)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: R.pixelFormat, width: w, height: h, mipmapped: false)
        td.usage = usage; td.storageMode = .private
        let tex = R.device.makeTexture(descriptor: td)!
        let cb = R.queue.makeCommandBuffer()!
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        R.encode(enc, u, pipeline: pipeline)
        enc.endEncoding()
        cb.commit()
        return (tex, cb, (CACurrentMediaTime() - t0) * 1000)
    }

    /// Draw, wait, read back. The draw is its own command buffer, so its GPU time is the still's alone.
    func render(_ u: GFUniforms) -> Result {
        let (tex, cb, encMs) = renderTexture(u)
        cb.waitUntilCompleted()
        let gpu = (cb.gpuEndTime - cb.gpuStartTime) * 1000
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
        return Result(width: w, height: h, rgba: rgba, gpuMs: gpu, encodeMs: encMs)
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
/// A relative <dir> is inside the app's Documents (the Mac build is sandboxed: its container). Extra switches:
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
        let L = GFLook.shared
        // warm-up: the first draw pays pipeline residency; keep it out of the table
        _ = r.render(GFUniforms.make(GFCase.reference[4], L.entries[0], .light))
        var rows: [[String: Any]] = [], unis: [String: Any] = [:]
        let t0 = CACurrentMediaTime()
        for e in L.entries { for th in GFTheme.allCases { for cs in GFCase.reference {
            let name = "\(cs.name)__\(e.id)__\(th.rawValue).png"
            if let only, !name.contains(only) { continue }
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
        let meta: [String: Any] = ["device": dev.name, "variant": GFStillsRendererFactory.variantName, "repeats": repeats,
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
        return GFRenderer.makePipeline(R.device, lib, R.pixelFormat)
    }
}
