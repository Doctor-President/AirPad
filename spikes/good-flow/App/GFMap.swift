// Good Flow spike (throwaway, never merged) · case (c): Map orbs as stills.
// 262 synthetic orbs (GFLibrary: 60 pt + 8 per further item, 120 at most; 8 loose clusters; no overlap). One
// CAMetalLayer view on the trial's pattern (AirPad/Views/Canvas/Living/LivingMap.swift, read only): two-finger scroll or
// a drag pans, the trackpad's magnify / a two-finger pinch zooms, a coast after the scroll ends; input callbacks only
// queue, the tick applies; the link runs only while input, a coast or a fill frame needs it: at rest 0 ticks.
// Each orb is a STILL: the bench's orb (uTheme 0, padded 1.5 D slot, mass 1, zoom = fit) drawn once by GFDraw WITHOUT
// the final grain term, cropped to the centre 1.25 D (the disc, its soft edge and its rim glow), at
// min(1.25 D × display scale, cap) pixels, with mipmaps, in a texture array per size bucket (16 px steps). The Map pass
// draws them as instanced quads and adds the grain per screen pixel (design §1's departure). Until its still lands an
// orb is a flat disc in its hue. The fill runs off the main thread on its own queue, visible orbs first, in command
// buffers of ~2 ms of GPU, each followed by one frame.
import UIKit
import Metal

final class GFOrbStillCache {
    struct Bucket {
        let m: Int                       // master size (px, square)
        var orbs: [Int]                  // library indices; slice = position
        let array: MTLTexture            // texture2DArray, mipmapped
        let instances: MTLBuffer         // GFOrbInstance × orbs.count
    }
    private(set) var buckets: [Bucket] = []
    private var where_: [Int: (b: Int, slice: Int)] = [:]
    let cap: Int, scale: Double, theme: GFTheme, mode: GFDrawMode, flat: Bool
    private let lib = GFLibrary.shared
    private let cq = GFRenderer.shared.device.makeCommandQueue()!
    private let fillQ = DispatchQueue(label: "gf.map.fill", qos: .userInitiated)
    private var cancelled = false
    var onBatch: (() -> Void)?
    // timings (CACurrentMediaTime)
    private(set) var fillStart = 0.0, visibleDone: Double?, allDone: Double?
    private(set) var gpuPerOrbMs: [Double] = []      // per batch: GPU ms / orbs in it
    private(set) var batchGpuMs: [Double] = []
    private(set) var readyCount = 0

    /// Master size for an orb: the crop (1.25 D) at the display scale, in 16 px steps, capped.
    static func master(diam: Double, scale: Double, cap: Int) -> Int {
        let need = Int((1.25 * diam * scale).rounded(.up))
        return min(cap, (need + 15) / 16 * 16)
    }

    init(cap: Int, scale: Double, theme: GFTheme, mode: GFDrawMode, flat: Bool) {
        self.cap = cap; self.scale = scale; self.theme = theme; self.mode = mode; self.flat = flat
        let dev = GFRenderer.shared.device
        var groups: [Int: [Int]] = [:]
        for (i, it) in lib.items.enumerated() { groups[Self.master(diam: it.diam, scale: scale, cap: cap), default: []].append(i) }
        for m in groups.keys.sorted() {
            let orbs = groups[m]!
            let td = MTLTextureDescriptor()
            td.textureType = .type2DArray; td.pixelFormat = .bgra8Unorm; td.width = m; td.height = m; td.arrayLength = orbs.count
            td.mipmapLevelCount = Int(log2(Double(m))) + 1; td.usage = [.shaderRead]; td.storageMode = .private
            let arr = dev.makeTexture(descriptor: td)!
            let buf = dev.makeBuffer(length: MemoryLayout<GFOrbInstance>.stride * orbs.count, options: .storageModeShared)!
            let p = buf.contents().bindMemory(to: GFOrbInstance.self, capacity: orbs.count)
            for (k, i) in orbs.enumerated() {
                let it = lib.items[i], pos = lib.positions[i], fc = GFColor.flat(it.entry.hue, theme)
                p[k] = GFOrbInstance(center: SIMD2(Float(pos.x), Float(pos.y)), diam: Float(it.diam), halfSize: Float(0.625 * it.diam),
                                     flatCol: SIMD3(Float(fc.x), Float(fc.y), Float(fc.z)), patina: Float(it.entry.patina),
                                     ready: 0, slice: Float(k), uvScale: 1, pad: 0)
                where_[i] = (buckets.count, k)
            }
            buckets.append(Bucket(m: m, orbs: orbs, array: arr, instances: buf))
        }
    }
    deinit { cancelled = true }
    func cancel() { cancelled = true }

    /// Bytes held by the stills (texture arrays with their mips) and the instance buffers.
    var bytes: Int { buckets.reduce(0) { $0 + $1.array.allocatedSize + $1.instances.allocatedSize } }

    /// The orb still's uniforms: the bench's orb slot (1.5 D) at the master's scale, offset so the m × m target is its
    /// centre 1.25 D; no final grain (the Map adds it per screen pixel).
    func uniforms(_ i: Int, m: Int) -> GFUniforms {
        let it = lib.items[i]
        let sEff = Double(m) / (1.25 * it.diam)
        var u = GFUniforms.make(GFCase.orb(diam: it.diam, scale: sEff), it.entry, theme)
        let res = Float(1.2 * Double(m))
        u.res = SIMD2(res, res); u.org = SIMD2(-0.1 * Float(m), -0.1 * Float(m)); u.pt = Float(sEff)
        u.grainOn = 0; u.flat = flat ? 1 : 0
        return u
    }

    /// Fill every still, `first` (the orbs on screen) before the rest.
    func fill(first: [Int]) {
        fillStart = CACurrentMediaTime()
        let firstSet = Set(first)
        let order = first + lib.items.indices.filter { !firstSet.contains($0) }
        let nFirst = first.count
        fillQ.async { [weak self] in self?.run(order, nFirst: nFirst) }
    }

    private func run(_ order: [Int], nFirst: Int) {
        let dev = GFRenderer.shared.device
        var temps: [Int: MTLTexture] = [:]
        func temp(_ m: Int) -> MTLTexture {
            if let t = temps[m] { return t }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: m, height: m, mipmapped: true)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .private
            let t = dev.makeTexture(descriptor: td)!; temps[m] = t; return t
        }
        let scratch = GFScratch()
        var idx = 0, perOrbGuess = 1.0, done = 0
        while idx < order.count, !cancelled {
            // A batch of ~2 ms of GPU (the refill budget per frame, design §1), at least one orb.
            let n = max(1, min(16, Int(2.0 / max(perOrbGuess, 0.05))))
            let batch = Array(order[idx..<min(order.count, idx + n)]); idx += batch.count
            let cb = cq.makeCommandBuffer()!
            for i in batch {
                let (b, slice) = where_[i]!
                let m = buckets[b].m, t = temp(m)
                GFDraw.encode(cb, target: t, uniforms(i, m: m), mode, scratch: scratch)
                let bl = cb.makeBlitCommandEncoder()!
                bl.generateMipmaps(for: t)
                for lv in 0..<t.mipmapLevelCount {
                    let s = max(1, m >> lv)
                    bl.copy(from: t, sourceSlice: 0, sourceLevel: lv, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: s, height: s, depth: 1),
                            to: buckets[b].array, destinationSlice: slice, destinationLevel: lv, destinationOrigin: MTLOrigin())
                }
                bl.endEncoding()
            }
            cb.commit(); cb.waitUntilCompleted()
            let g = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            batchGpuMs.append(g); perOrbGuess = g / Double(batch.count); gpuPerOrbMs.append(perOrbGuess)
            done += batch.count
            let doneNow = done
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else { return }
                for i in batch { let (b, s) = self.where_[i]!; self.buckets[b].instances.contents().bindMemory(to: GFOrbInstance.self, capacity: self.buckets[b].orbs.count)[s].ready = 1 }
                self.readyCount = doneNow
                let now = CACurrentMediaTime()
                if self.visibleDone == nil, doneNow >= nFirst { self.visibleDone = now; GFRecorder.shared.mark(String(format: "map visible filled (%d orbs) in %.0f ms", nFirst, (now - self.fillStart) * 1000)) }
                if doneNow == order.count { self.allDone = now; GFRecorder.shared.mark(String(format: "map all %d filled in %.0f ms", doneNow, (now - self.fillStart) * 1000)) }
                GFRecorder.shared.still(kind: "orb×\(batch.count)", reason: "fill", gpuMs: g, mainMs: 0, px: batch.reduce(0) { $0 + self.buckets[self.where_[$1]!.b].m * self.buckets[self.where_[$1]!.b].m })
                self.onBatch?()
            }
        }
    }

    var summary: [String: Any] {
        ["cap": cap, "scale": scale, "theme": theme.rawValue, "mode": mode.label, "bytes": bytes, "MB": Double(bytes) / 1_048_576,
         "buckets": buckets.map { ["m": $0.m, "n": $0.orbs.count, "bytes": $0.array.allocatedSize] },
         "visibleFillMs": visibleDone.map { ($0 - fillStart) * 1000 } ?? -1, "allFillMs": allDone.map { ($0 - fillStart) * 1000 } ?? -1,
         "batchGpuMsMax": batchGpuMs.max() ?? -1, "batches": batchGpuMs.count, "batchGpuMs": batchGpuMs,
         "batchGpuMsP50": GFMeasure.pct(batchGpuMs, 50), "batchGpuMsP95": GFMeasure.pct(batchGpuMs, 95),
         "gpuPerOrbMsMedian": gpuPerOrbMs.sorted().dropFirst(gpuPerOrbMs.count / 2).first ?? -1]
    }

    /// Encodes the orbs into `enc` (the Map pass).
    func draw(_ enc: MTLRenderCommandEncoder, _ m: inout GFMapUniforms) {
        enc.setRenderPipelineState(GFRenderer.shared.pipe("gf_map_fragment", benchHash: false))
        enc.setVertexBytes(&m, length: MemoryLayout<GFMapUniforms>.stride, index: 1)
        enc.setFragmentBytes(&m, length: MemoryLayout<GFMapUniforms>.stride, index: 1)
        for b in buckets {
            enc.setVertexBuffer(b.instances, offset: 0, index: 0)
            enc.setFragmentTexture(b.array, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: b.orbs.count)
        }
    }
}

/// The Map view: the trial's camera and rest rule, the orbs from GFOrbStillCache.
final class GFMapView: UIView, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let R = GFRenderer.shared
    private var link: CADisplayLink?
    private final class Proxy: NSObject { weak var v: GFMapView?; @objc func step(_ l: CADisplayLink) { v?.tick(l) } }
    private let proxy = Proxy()

    // Camera (world, y up; 1 = one world pt per screen pt, larger = zoomed out). Changed only in the tick.
    var camX = 0.0, camY = 0.0, camScale = 1.0
    private var pendPan = CGPoint.zero, pendZoom = 1.0, pendAnchor = CGPoint.zero, pendEvents = 0
    private var coast = CGPoint.zero
    private var lastInput = -1.0
    private var oneShot: String?
    private var lastTick = 0.0
    private var lastPinchScale: CGFloat = 1
    var cache: GFOrbStillCache? { didSet { requestFrame("data") } }
    var onTick: ((Double) -> Void)?        // the programmatic driver adds its input here
    private(set) var drawnFrames = 0, ticks = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        metalLayer.device = R.device; metalLayer.pixelFormat = R.pixelFormat; metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true; metalLayer.maximumDrawableCount = 3
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        proxy.v = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []                       // trackpad / wheel scrolls only (the trial's pattern)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))   // a finger (iPhone) or a mouse drag (Mac)
        drag.maximumNumberOfTouches = 1
        for g in [pinch, scroll, drag] as [UIGestureRecognizer] { g.cancelsTouchesInView = false; g.delegate = self; addGestureRecognizer(g) }
        accessibilityIdentifier = "map.view"
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate() }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { link?.isPaused = true; return }
        metalLayer.contentsScale = w.traitCollection.displayScale
        if link == nil {
            let l = CADisplayLink(target: proxy, selector: #selector(Proxy.step(_:)))
            let m = Float(w.windowScene?.screen.maximumFramesPerSecond ?? 120)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, m), maximum: m, preferred: m)
            l.isPaused = true
            l.add(to: .main, forMode: .common); link = l
        }
        requestFrame("window")
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let s = metalLayer.contentsScale
        let size = CGSize(width: max(1, (bounds.width * s).rounded()), height: max(1, (bounds.height * s).rounded()))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size; requestFrame("size") }
    }

    func noteInput() { lastInput = CACurrentMediaTime(); wake() }
    func requestFrame(_ why: String) { if oneShot == nil { oneShot = why }; wake() }
    private func wake() { guard let link, link.isPaused, window != nil else { return }; lastTick = 0; link.isPaused = false }

    // MARK: input (callbacks only queue)
    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: coast = .zero; noteInput(); GFRecorder.shared.mark("scroll began")
        case .changed:
            let t = g.translation(in: self); g.setTranslation(.zero, in: self)
            if g.modifierFlags.contains(.alternate) { pendZoom *= exp(-Double(t.y) * 0.01); pendAnchor = g.location(in: self) }
            else { pendPan.x += t.x * 1.5; pendPan.y += t.y * 1.5 }   // the trial's scroll factor
            pendEvents += 1; noteInput()
        default:
            if g.state == .ended, !g.modifierFlags.contains(.alternate) {   // Catalyst sends no momentum to the recogniser
                let v = g.velocity(in: self), c = CGPoint(x: v.x / 60 * 1.5, y: v.y / 60 * 1.5)
                if hypot(c.x, c.y) >= 3.0 { coast = c }
            }
            noteInput(); GFRecorder.shared.mark("scroll ended")
        }
    }
    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: coast = .zero; noteInput()
        case .changed:
            let t = g.translation(in: self); g.setTranslation(.zero, in: self)
            pendPan.x += t.x; pendPan.y += t.y; pendEvents += 1; noteInput()
        default:
            if g.state == .ended { let v = g.velocity(in: self), c = CGPoint(x: v.x / 60, y: v.y / 60); if hypot(c.x, c.y) >= 2.0 { coast = c } }
            noteInput()
        }
    }
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: coast = .zero; lastPinchScale = 1; applyPinch(g); noteInput(); GFRecorder.shared.mark("pinch began")
        case .changed: applyPinch(g); noteInput()
        default: noteInput(); GFRecorder.shared.mark("pinch ended")
        }
    }
    private func applyPinch(_ g: UIPinchGestureRecognizer) {
        guard g.scale > 0 else { return }
        let d = Double(g.scale / lastPinchScale); lastPinchScale = g.scale
        if d != 1 { pendZoom /= d; pendAnchor = g.location(in: self); pendEvents += 1 }
    }
    /// Programmatic input (bench runs): the same queue the gestures use.
    func queue(pan: CGPoint, zoom: Double, anchor: CGPoint) {
        pendPan.x += pan.x; pendPan.y += pan.y; pendZoom *= zoom; pendAnchor = anchor; pendEvents += 1; noteInput()
    }

    // MARK: camera
    private func viewToWorld(_ p: CGPoint) -> (Double, Double) {
        (camX + (Double(p.x) - Double(bounds.width) / 2) * camScale, camY + (Double(bounds.height) / 2 - Double(p.y)) * camScale)
    }
    private func applyPending(dt: Double) {
        if pendEvents > 0 {
            camX -= Double(pendPan.x) * camScale; camY += Double(pendPan.y) * camScale
            if pendZoom != 1 {
                let before = viewToWorld(pendAnchor)
                camScale = min(max(camScale * pendZoom, 0.25), 4)
                let after = viewToWorld(pendAnchor)
                camX += before.0 - after.0; camY += before.1 - after.1
            }
            pendPan = .zero; pendZoom = 1; pendEvents = 0
        }
        if coast != .zero {   // pt per 60 Hz frame, friction 0.95 per 60 Hz frame (the trial's coast)
            let k = min(max(dt * 60, 0.25), 4)
            camX -= Double(coast.x) * k * camScale; camY += Double(coast.y) * k * camScale
            let f = pow(0.95, k); coast.x *= f; coast.y *= f
            if hypot(coast.x, coast.y) < 0.5 { coast = .zero }
        }
    }
    /// Library indices whose orb is on screen now, nearest the centre first.
    func visibleOrbs() -> [Int] {
        let lib = GFLibrary.shared
        let hw = Double(bounds.width) / 2 * camScale, hh = Double(bounds.height) / 2 * camScale
        return lib.items.indices.filter { i in
            let p = lib.positions[i], r = lib.items[i].diam * 0.625
            return abs(p.x - camX) < hw + r && abs(p.y - camY) < hh + r
        }.sorted { a, b in
            let pa = lib.positions[a], pb = lib.positions[b]
            return hypot(pa.x - camX, pa.y - camY) < hypot(pb.x - camX, pb.y - camY)
        }
    }

    // MARK: the tick (the only place the camera changes; the rest rule)
    private func tick(_ l: CADisplayLink) {
        let t0 = CACurrentMediaTime()
        ticks += 1
        let dt = lastTick > 0 ? t0 - lastTick : l.duration
        lastTick = t0
        onTick?(dt)
        let inputAwake = t0 - lastInput < 0.4
        let reason: String? = oneShot.map { "oneshot:" + $0 } ?? (inputAwake || pendEvents > 0 ? "input" : (coast != .zero ? "coast" : nil))
        guard let reason else {
            GFRecorder.shared.tick(surface: "map", at: t0, drew: false); l.isPaused = true; return
        }
        applyPending(dt: dt)
        let tw = CACurrentMediaTime()
        guard let drawable = metalLayer.nextDrawable() else { GFRecorder.shared.tick(surface: "map", at: t0, drew: false); return }
        GFRecorder.shared.tick(surface: "map", at: t0, drew: true)
        let waitMs = (CACurrentMediaTime() - tw) * 1000
        let rec = GFRecorder.shared
        let idx = rec.begin(surface: "map", wake: reason, linkT: l.timestamp, targetT: l.targetTimestamp, vsync: l.duration,
                            rate: Double(l.preferredFrameRateRange.preferred ?? 0), startT: t0, px: drawable.texture.width * drawable.texture.height)
        let cb = R.queue.makeCommandBuffer()!
        encode(cb, target: drawable.texture)
        drawable.addPresentedHandler { d in rec.setPresent(idx, d.presentedTime) }
        cb.addCompletedHandler { cb in rec.setGPU(idx, (cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        cb.present(drawable); cb.commit()
        oneShot = nil; drawnFrames += 1
        rec.setMain(idx, (CACurrentMediaTime() - t0) * 1000); rec.setWait(idx, waitMs)
        if !(CACurrentMediaTime() - lastInput < 0.4) && coast == .zero && pendEvents == 0 && oneShot == nil { l.isPaused = true }
    }

    /// The Map pass into any target the view's size (also used offscreen for the sharpness stills).
    func encode(_ cb: MTLCommandBuffer, target: MTLTexture) {
        let S = GFSettings.shared
        let ground = GFColor.gamma(GFSurfaces(S.theme).page)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: ground.x, green: ground.y, blue: ground.z, alpha: 1)
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        if let cache {
            var m = GFMapUniforms(cam: SIMD2(Float(camX), Float(camY)), camScale: Float(camScale), pxPerPt: Float(metalLayer.contentsScale),
                                  viewPt: SIMD2(Float(bounds.width), Float(bounds.height)), ground: SIMD3(Float(ground.x), Float(ground.y), Float(ground.z)),
                                  grain: Float(GFLook.shared.dial("grain")), time: Float(GFLook.shared.stillTime), grainOn: 1, flat: S.flat ? 1 : 0, pad2: 0)
            cache.draw(enc, &m)
        }
        enc.endEncoding()
    }
}

final class GFMapViewController: UIViewController, GFCaseScreen {
    let map = GFMapView()
    private var settingsObs: NSObjectProtocol?
    private var programmatic = false
    private var progT = 0.0
    private var cacheKey = ""
    /// -MapCap / the panel (default 128: the only cap whose 262 mipmapped stills fit both memory bars; results-3b.md).
    static var cap: Int { GFSettings.shared.mapCap }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(map)
        map.cache = nil
        let p0 = GFLibrary.shared.positions[0]          // start at zoom 1 on e0's cluster
        map.camX = p0.x; map.camY = p0.y
        if let z = UserDefaults.standard.object(forKey: "MapZoom") as? String, let v = Double(z) { map.camScale = v }
        settingsObs = NotificationCenter.default.addObserver(forName: .gfSettingsChanged, object: nil, queue: .main) { [weak self] _ in self?.rebuildIfNeeded() }
        map.onTick = { [weak self] dt in self?.progStep(dt) }
    }
    deinit { settingsObs.map(NotificationCenter.default.removeObserver); map.cache?.cancel() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); map.frame = view.bounds; rebuildIfNeeded() }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); rebuildIfNeeded() }

    /// A new still set when the look's inputs change: theme, variant, hash, flat, display scale (design §1: never on
    /// pan, zoom or the clock).
    private func rebuildIfNeeded() {
        guard map.bounds.width > 0, view.window != nil else { return }
        let S = GFSettings.shared
        let scale = Double(view.window!.traitCollection.displayScale)
        let key = "\(S.theme)|\(S.mode.label)|\(S.flat)|\(scale)|\(Self.cap)"
        guard key != cacheKey else { return }
        cacheKey = key
        map.cache?.cancel()
        let before = GFRecorder.physFootprintMB()
        let c = GFOrbStillCache(cap: Self.cap, scale: scale, theme: S.theme, mode: S.mode, flat: S.flat)
        c.onBatch = { [weak self] in self?.map.requestFrame("fill") }
        map.cache = c
        view.backgroundColor = GFSettings.pageColor(S.theme)
        GFRecorder.shared.mark(String(format: "map stills: cap %d, %.1f MB of textures, footprint before %.1f MB", Self.cap, Double(c.bytes) / 1_048_576, before))
        c.fill(first: map.visibleOrbs())
    }

    // MARK: programmatic motion: a slow circle pan with a zoom breathing 0.6 ↔ 1.6, plus a pinch every 3 s.
    func setProgrammatic(_ on: Bool) {
        programmatic = on; progT = 0
        GFRecorder.shared.mark(on ? "programmatic start: map pan circle + zoom 0.6↔1.6" : "programmatic end")
        if on { map.noteInput() }
    }
    private func progStep(_ dt: Double) {
        guard programmatic else { return }
        progT += dt
        let v = 9.0   // pt per frame at 120
        let pan = CGPoint(x: cos(progT * 0.7) * v, y: sin(progT * 0.9) * v)
        let target = 1.1 + 0.5 * sin(progT * 2 * .pi / 6)
        let z = pow(target / map.camScale, min(1, dt * 4))
        map.queue(pan: pan, zoom: z, anchor: CGPoint(x: map.bounds.midX, y: map.bounds.midY))
    }

    var recordingMeta: [String: Any] {
        ["screen": "map", "cam": [map.camX, map.camY, map.camScale], "drawnFrames": map.drawnFrames, "ticks": map.ticks,
         "stills": map.cache?.summary ?? [:], "footprintMB": GFRecorder.physFootprintMB(), "programmatic": programmatic]
    }
}
