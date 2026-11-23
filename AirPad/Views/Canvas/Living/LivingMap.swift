import UIKit
import SwiftUI
import Metal
import QuartzCore
import simd

// Sweep 2b · 2.3 — the renderer trial (Ops design-refs/sweep-2b/renderer-trial-design.md). SCRATCH BRANCH
// ws-2b-renderer-trial: never merged. Mac only, in builds with DEBUG or DEVSWITCHES (Xcode runs, TestFlight, the bench);
// an App Store archive has none of this file.
//
//   LivingLayer    — the shared layer: one Metal device and queue, the pipelines (compiled into the app's metallib, so a
//                    shader error fails the build, never a silent white sprite), one clock.
//   LivingMapView  — scene 1: a CAMetalLayer view in the Map's slot, ticked by a CAMetalDisplayLink (120–120, or 60–60
//                    for the control) on the main run loop in common modes. The REST RULE is structural: `noteInput` is
//                    the only wake; awake = input in the last 0.4 s, a coast, a label fade or a one-shot frame (data,
//                    size, hover); otherwise the link is paused, so no tick and no main-thread work can exist.
//                    The camera changes only inside the tick; input callbacks only add to a pending pan / zoom.
//
// Switches (Settings › About › Version ×5 › Mac feel (testing)) are UserDefaults keys, so the same names are the bench's
// launch arguments: `-LivingTrial map` (map | cards | map,cards), `-LivingTrialArm full` (full | bare | pills: G1's
// probe is `bare`, plain discs on a cleared ground; `pills` = bare + today's SwiftUI region pills mounted above, forced
// visible at every zoom), `-LivingTrialRate 120` (120 | 60, the clean-60 control).

#if targetEnvironment(macCatalyst) && (DEBUG || DEVSWITCHES)

enum LivingTrial {
    static let key = "LivingTrial"
    static let armKey = "LivingTrialArm"
    static let rateKey = "LivingTrialRate"
    static func parts(_ v: String) -> Set<String> { Set(v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
    static func mapOn(_ v: String) -> Bool { parts(v).contains("map") }
    static func cardsOn(_ v: String) -> Bool { parts(v).contains("cards") }
    static func toggled(_ v: String, _ part: String, _ on: Bool) -> String {
        var p = parts(v); p.remove(""); if on { p.insert(part) } else { p.remove(part) }
        return p.sorted().joined(separator: ",")
    }
    static var mapArm: String { UserDefaults.standard.string(forKey: armKey) ?? "full" }
    static var rate: Int { UserDefaults.standard.integer(forKey: rateKey) == 60 ? 60 : 120 }
    /// G1 probe knobs (bench only): `-LivingTrialLink display|metal` (default display: a CADisplayLink + nextDrawable, the
    /// design's fallback; G1 measured CAMetalDisplayLink delivering 60 updates a second under Catalyst at a 120–120 or
    /// 30–120 range while this link delivers 120), `-LivingTrialMin <fps>` (the range's minimum; default = the rate).
    static var linkKind: String { UserDefaults.standard.string(forKey: "LivingTrialLink") ?? "display" }
    /// `-LivingTrialCS none|srgb` (the layer's colour space; none = untagged, as I read SKView's) and
    /// `-LivingTrialPresent now|target` (present as soon as the GPU is done, or at the link's target time).
    static var colorspace: String { UserDefaults.standard.string(forKey: "LivingTrialCS") ?? "none" }
    static var presentMode: String { UserDefaults.standard.string(forKey: "LivingTrialPresent") ?? "now" }
    static var rangeMin: Int { let m = UserDefaults.standard.integer(forKey: "LivingTrialMin"); return m > 0 ? m : rate }
}

/// What the trial Map draws, read once from the scene's derived values after a sync (`CorpusPhysicsScene.livingSnapshot`).
struct LivingMapSnapshot {
    struct Orb { let id: String; let home: SIMD2<Float>; let radius: Float; let fill: SIMD4<Float>; let ink: SIMD4<Float>
                 let lines: [String]; let pointSize: Float }
    struct Label { let key: String; let name: String; let colorHex: String; let members: [Int] }
    let orbs: [Orb]
    let labels: [Label]
    let isLight: Bool
    let atlasName: String
}

// MARK: - The shared layer

final class LivingLayer {
    static let shared = LivingLayer()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    /// The one clock: shader time is the link's target time minus this.
    let start = CACurrentMediaTime()
    private(set) lazy var mapPipelines = MapPipelines(self)
    private var atlases: [String: MTLTexture] = [:]

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        library = device.makeDefaultLibrary()!
    }

    struct MapPipelines {
        let ground, orb, title, pill, pillText: MTLRenderPipelineState
        init(_ L: LivingLayer) {
            func make(_ v: String, _ f: String, blend: Bool) -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = L.library.makeFunction(name: v)
                d.fragmentFunction = L.library.makeFunction(name: f)
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                if blend {   // premultiplied over
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try! L.device.makeRenderPipelineState(descriptor: d)
            }
            ground = make("lm_ground_v", "lm_ground_f", blend: false)
            orb = make("lm_orb_v", "lm_orb_f", blend: true)
            title = make("lm_title_v", "lm_glyph_f", blend: true)
            pill = make("lm_pill_v", "lm_pill_f", blend: true)
            pillText = make("lm_pilltext_v", "lm_glyph_f", blend: true)
        }
    }

    /// One MSDF atlas as a data texture (RGBX, no sRGB decode), cached by name.
    func atlas(_ font: MSDFFont) -> MTLTexture? {
        if let t = atlases[font.atlasName] { return t }
        let a = font.livingAtlas
        guard a.width > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: a.width, height: a.height, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        a.bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, a.width, a.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: a.width * 4) }
        atlases[font.atlasName] = t
        return t
    }

    /// A probe row, numbers only (`Perf.probe` without the timestamp choice).
    static func probe(_ c: MapProbe, _ v: Double = 0, at t: Double = CACurrentMediaTime()) {
        guard PerfRecorder.on else { return }
        PerfRecorder.shared.noteProbe(c.rawValue, v, at: t)
    }
}

// MARK: - Scene 1: the Map

/// Layouts match LivingMap.metal (all float4).
private struct LMFrame {
    var f0 = SIMD4<Float>(), f1 = SIMD4<Float>(), f2 = SIMD4<Float>(), f3 = SIMD4<Float>(), ring = SIMD4<Float>()
    var f5 = SIMD4<Float>(), f6 = SIMD4<Float>(), f7 = SIMD4<Float>(), f8 = SIMD4<Float>(), pillFill = SIMD4<Float>()
    var f10 = SIMD4<Float>()
}
private struct LMOrb { var o0: SIMD4<Float>; var fill: SIMD4<Float> }
private struct LMGlyph { var plane: SIMD4<Float>; var uv: SIMD4<Float>; var ink: SIMD4<Float>; var g3: SIMD4<Float> }
private struct LMLabel { var l0: SIMD4<Float>; var stroke: SIMD4<Float> }

/// The display link's delegate / target, holding the view weakly (the run loop keeps the link alive).
private final class LivingLinkProxy: NSObject, CAMetalDisplayLinkDelegate {
    weak var view: LivingMapView?
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        MainActor.assumeIsolated { view?.tick(update.drawable, target: update.targetTimestamp, start: CACurrentMediaTime()) }
    }
    @objc func step(_ l: CADisplayLink) {
        MainActor.assumeIsolated { view?.displayStep(l) }
    }
}

final class LivingMapView: UIView, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let L = LivingLayer.shared

    weak var scene: CorpusPhysicsScene?
    weak var canvasState: CanvasState?
    var onFirstFrame: (() -> Void)?

    let arm = LivingTrial.mapArm
    let rate = LivingTrial.rate
    private var bare: Bool { arm != "full" }

    private var link: CAMetalDisplayLink?
    private var dlink: CADisplayLink?      // the fallback (`-LivingTrialLink display`)
    let linkKind = LivingTrial.linkKind
    private let presentAtTarget = LivingTrial.presentMode == "target"
    private var linkPaused: Bool {
        get { link?.isPaused ?? dlink?.isPaused ?? true }
        set { link?.isPaused = newValue; dlink?.isPaused = newValue }
    }
    private let proxy = LivingLinkProxy()
    private lazy var vid: Double = MapProbeID.of(self)

    // Camera (world, y up — the SpriteKit scene's convention; 1 = one world pt per screen pt, larger = zoomed out).
    private var camX = 0.0, camY = 0.0, camScale = 1.0
    // Pending input, applied first thing in the tick (the only place the camera changes).
    private var pendPan = CGPoint.zero, pendZoom = 1.0, pendAnchor = CGPoint.zero, pendEvents = 0
    private var coast = CGPoint.zero          // pt per 60 Hz frame (the scene's units)
    private var lastInput = -1.0
    private var needsFrame = true
    private var lastTick = 0.0
    private var drewFirst = false
    private var lastPinchScale: CGFloat = 1
    private var hoverPoint: CGPoint?
    private var hovered = -1

    // The snapshot, on the GPU.
    private var snapshot: LivingMapSnapshot?
    private var snapshotDirty = true
    private var orbBuf: MTLBuffer?, titleBuf: MTLBuffer?, labelBuf: MTLBuffer?, pillTextBuf: MTLBuffer?
    private var orbCount = 0, titleCount = 0, labelCount = 0, pillTextCount = 0
    private var atlas: MTLTexture?
    private var font: MSDFFont = .shared
    private var labelAnchors: [CGPoint] = []      // world
    private var labelBoxes: [CGSize] = []         // the scene's declutter box size (RegionLabelPillMetrics)
    private var labelAlpha: [Float] = []
    private var labelPlaced = Set<Int>()
    private var labelsFading = false
    private var mountTime = 0.0
    private var zoomArg: Double? = {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-MapZoom"), i + 1 < a.count { return Double(a[i + 1]) }
        return nil
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        metalLayer.device = L.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        if LivingTrial.colorspace == "srgb" { metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
        proxy.view = self
        // Input as on today's Map (MapPointerInput): two-finger scroll / wheel pans (⌥ + wheel zooms), the trackpad's
        // magnify pinches, hover rings an orb. Callbacks only queue; the tick applies.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        for g in [pinch, scroll, hover] as [UIGestureRecognizer] {
            g.cancelsTouchesInView = false; g.delegate = self; addGestureRecognizer(g)
        }
        accessibilityIdentifier = "livingMap"
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate(); dlink?.invalidate() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func attach(scene: CorpusPhysicsScene, canvasState: CanvasState) {
        self.scene = scene; self.canvasState = canvasState
        scene.livingOnSync = { [weak self] in self?.snapshotDirty = true; self?.requestFrame("data") }
    }

    // MARK: lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { linkPaused = true; Perf.mark("living map left its window: paused"); return }
        metalLayer.contentsScale = w.traitCollection.displayScale
        if link == nil && dlink == nil {
            let range = CAFrameRateRange(minimum: Float(LivingTrial.rangeMin), maximum: Float(rate), preferred: Float(rate))
            if linkKind == "display" {
                let l = CADisplayLink(target: proxy, selector: #selector(LivingLinkProxy.step(_:)))
                l.preferredFrameRateRange = range
                l.add(to: .main, forMode: .common)
                dlink = l
            } else {
                let l = CAMetalDisplayLink(metalLayer: metalLayer)
                l.delegate = proxy
                l.preferredFrameRateRange = range
                l.add(to: .main, forMode: .common)
                link = l
            }
            mountTime = CACurrentMediaTime()
            Perf.mark("living map mounted · arm \(arm) · rate \(rate) · link \(linkKind) · range min \(LivingTrial.rangeMin) · cs \(LivingTrial.colorspace) · present \(LivingTrial.presentMode)")
            if let z = zoomArg {   // the bench's `-MapZoom <mult>`: 14 s after the Map mounts, as the scene does
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
                    guard let self else { return }
                    self.camScale = min(max(self.camScale * z, 0.25), 4); self.requestFrame("zoomArg")
                }
            }
        }
        requestFrame("window")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = metalLayer.contentsScale
        let size = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size; requestFrame("size") }
    }

    /// The one wake: input. Awake for 0.4 s after the last one.
    private func noteInput(_ reason: Int) {
        lastInput = CACurrentMediaTime()
        wake(reason)
    }
    /// A one-shot frame (data, size, hover): drawn once, then the rest rule applies.
    private func requestFrame(_ why: String) {
        needsFrame = true
        wake(MapProbeWake.code(why == "data" ? "external" : why == "size" ? "size" : why == "hover" ? "hover" : "delayed"))
    }
    private func wake(_ reason: Int) {
        guard linkPaused, link != nil || dlink != nil, window != nil else { return }
        linkPaused = false
        LivingLayer.probe(.wake, Double(reason))
    }
    private func wake(_ reason: Double) { wake(Int(reason)) }

    // MARK: input

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let paused = linkPaused
        switch g.state {
        case .began:
            LivingLayer.probe(.scrollBegan); coast = .zero; noteInput(2)
        case .changed:
            LivingLayer.probe(paused ? .scrollChangedPaused : .scrollChanged)
            let t = g.translation(in: self); g.setTranslation(.zero, in: self)
            if g.modifierFlags.contains(.alternate) {
                pendZoom *= exp(-Double(t.y) * 0.01); pendAnchor = g.location(in: self)
            } else {
                pendPan.x += t.x; pendPan.y += t.y
            }
            pendEvents += 1
            noteInput(2)
        default:
            LivingLayer.probe(.scrollEnded, Double(g.state.rawValue))
            if g.state == .ended, !g.modifierFlags.contains(.alternate) {   // Catalyst sends no momentum to the recogniser
                let v = g.velocity(in: self), c = CGPoint(x: v.x / 60, y: v.y / 60)
                if hypot(c.x, c.y) >= 2.0 { coast = c; LivingLayer.probe(.coastSeeded, Double(hypot(c.x, c.y))) }
            }
            noteInput(2)
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let paused = linkPaused
        switch g.state {
        case .began:
            LivingLayer.probe(.pinchBegan); coast = .zero; lastPinchScale = 1; applyPinch(g); noteInput(3)
        case .changed:
            LivingLayer.probe(paused ? .pinchChangedPaused : .pinchChanged, Double(g.scale - lastPinchScale))
            applyPinch(g); noteInput(3)
        default:
            LivingLayer.probe(.pinchEnded, Double(g.state.rawValue)); noteInput(3)
        }
    }
    private func applyPinch(_ g: UIPinchGestureRecognizer) {
        guard g.scale > 0 else { return }
        let delta = MapPointerInput.pinchTravel(g.scale) - MapPointerInput.pinchTravel(lastPinchScale)
        lastPinchScale = g.scale
        if delta != 0 { pendZoom *= exp(-Double(delta)); pendAnchor = g.location(in: self); pendEvents += 1 }
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: hoverPoint = g.location(in: self)
        default: hoverPoint = nil
        }
        // A moved pointer at rest draws only when the ringed orb changes.
        if linkPaused, hitOrb() != hovered { requestFrame("hover") }
    }

    // MARK: camera

    private var viewW: Double { Double(bounds.width) }
    private var viewH: Double { Double(bounds.height) }
    private func viewToWorld(_ p: CGPoint) -> (Double, Double) {
        (camX + (Double(p.x) - viewW / 2) * camScale, camY + (viewH / 2 - Double(p.y)) * camScale)
    }
    private func applyPending(dt: Double) {
        if pendEvents > 0 {
            LivingLayer.probe(.pendingCamApplied, Double(pendEvents))
            camX -= Double(pendPan.x) * 1.5 * camScale
            camY += Double(pendPan.y) * 1.5 * camScale
            if pendZoom != 1 {
                let before = viewToWorld(pendAnchor)
                camScale = min(max(camScale * pendZoom, 0.25), 4)
                let after = viewToWorld(pendAnchor)
                camX += before.0 - after.0; camY += before.1 - after.1
            }
            pendPan = .zero; pendZoom = 1; pendEvents = 0
        }
        if coast != .zero {   // the scene's coast: pt per 60 Hz frame, friction 0.95 per 60 Hz frame
            let k = min(max(dt * 60, 0.25), 4)
            camX -= Double(coast.x) * 1.5 * k * camScale
            camY += Double(coast.y) * 1.5 * k * camScale
            let f = pow(0.95, k)
            coast.x *= f; coast.y *= f
            if hypot(coast.x, coast.y) < 0.5 { coast = .zero }
        }
    }
    private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / max(e1 - e0, 0.0001), 0), 1); return t * t * (3 - 2 * t)
    }
    private var ramp: Double {
        typealias T = CorpusPhysicsScene.LensTuning
        let zin = Double(T.zoomIn), zout = Double(T.zoomOut), m = Double(T.minShrink)
        if camScale <= zin { return 1 }
        if camScale >= zout { return m }
        return 1 + (m - 1) * Self.smooth(zin, zout, camScale)
    }
    private var envelope: Double { Double(CorpusPhysicsScene.AnnulusTuning.envelope(CGFloat(camScale))) }
    /// The orb's on-screen centre and radius (the vertex shader's maths, on the CPU for hover).
    private func orbScreen(_ o: LivingMapSnapshot.Orb) -> (CGPoint, Double) {
        let hx = Double(o.home.x), hy = Double(o.home.y)
        let sd = hypot(hx - camX, hy - camY) / camScale
        let t = min(sd / Double(CorpusPhysicsScene.AnnulusTuning.radius), 1)
        let amp = 1 + Double(CorpusPhysicsScene.AnnulusTuning.amplitude) * (1 - t * t * (3 - 2 * t)) * envelope
        let w2s = ramp * amp / camScale
        return (CGPoint(x: (hx - camX) / camScale + viewW / 2, y: viewH / 2 - (hy - camY) / camScale), Double(o.radius) * w2s)
    }
    private func hitOrb() -> Int {
        guard let p = hoverPoint, let s = snapshot, !bare else { return -1 }
        for (i, o) in s.orbs.enumerated() {
            let (c, r) = orbScreen(o)
            if hypot(Double(p.x - c.x), Double(p.y - c.y)) <= r { return i }
        }
        return -1
    }

    // MARK: snapshot → buffers

    private func reloadSnapshot() {
        guard let scene else { return }
        let t0 = CACurrentMediaTime()
        let s = scene.livingSnapshot()
        snapshot = s; snapshotDirty = false
        font = MSDFFont.orb(atlas: s.atlasName)
        atlas = L.atlas(font)
        var orbs: [LMOrb] = [], glyphs: [LMGlyph] = []
        for (i, o) in s.orbs.enumerated() {
            orbs.append(LMOrb(o0: SIMD4(o.home.x, o.home.y, o.radius, 0), fill: o.fill))
            guard !o.lines.isEmpty, o.pointSize > 0 else { continue }
            for q in font.livingQuads(lines: o.lines, pointSize: CGFloat(o.pointSize)) {
                glyphs.append(LMGlyph(plane: SIMD4(Float(q.plane.minX), Float(q.plane.minY), Float(q.plane.width), Float(q.plane.height)),
                                      uv: SIMD4(Float(q.uv.minX), Float(q.uv.minY), Float(q.uv.width), Float(q.uv.height)),
                                      ink: o.ink, g3: SIMD4(Float(i), o.pointSize, 0, 0)))
            }
        }
        var labels: [LMLabel] = [], pillGlyphs: [LMGlyph] = []
        labelAnchors = []; labelBoxes = []
        let pillPt: CGFloat = RegionLabelPillMetrics.fontSize, tracking: CGFloat = 1.5
        for (li, l) in s.labels.enumerated() {
            var sx = 0.0, sy = 0.0
            for m in l.members { sx += Double(s.orbs[m].home.x); sy += Double(s.orbs[m].home.y) }
            let n = Double(l.members.count)
            labelAnchors.append(CGPoint(x: sx / n, y: sy / n))
            labelBoxes.append(RegionLabelPillMetrics.box(charCount: l.name.count, center: .zero).size)
            let text = l.name.uppercased()
            let quads = font.livingQuads(lines: [text], pointSize: pillPt, tracking: tracking)
            let textW = (quads.map(\.plane.maxX).max() ?? 0) - (quads.map(\.plane.minX).min() ?? 0)
            let w = textW + RegionLabelPillMetrics.hPad * 2
            let h = max(RegionLabelPillMetrics.fontSize + RegionLabelPillMetrics.vPad * 2, RegionLabelPillMetrics.minHeight)
            var stroke = SIMD4<Float>(0.5, 0.5, 0.5, 0.95)
            if let c = UIColor(hex: l.colorHex) {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; c.getRed(&r, green: &g, blue: &b, alpha: &a)
                stroke = SIMD4(Float(r), Float(g), Float(b), 0.95)
            }
            labels.append(LMLabel(l0: SIMD4(Float(sx / n), Float(sy / n), Float(w), Float(h)), stroke: stroke))
            for q in quads {
                pillGlyphs.append(LMGlyph(plane: SIMD4(Float(q.plane.minX), Float(q.plane.minY), Float(q.plane.width), Float(q.plane.height)),
                                          uv: SIMD4(Float(q.uv.minX), Float(q.uv.minY), Float(q.uv.width), Float(q.uv.height)),
                                          ink: SIMD4(1, 1, 1, 1), g3: SIMD4(Float(li), Float(pillPt), 0, 0)))
            }
        }
        func buf<T>(_ a: [T]) -> MTLBuffer? {
            a.isEmpty ? nil : a.withUnsafeBytes { L.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        orbBuf = buf(orbs); titleBuf = buf(glyphs); labelBuf = buf(labels); pillTextBuf = buf(pillGlyphs)
        orbCount = orbs.count; titleCount = glyphs.count; labelCount = labels.count; pillTextCount = pillGlyphs.count
        if labelAlpha.count != labelCount { labelAlpha = Array(repeating: 0, count: labelCount); labelPlaced = [] }
        let ms = (CACurrentMediaTime() - t0) * 1000
        LivingLayer.probe(.trialSnapshot, ms)
        Perf.mark(String(format: "living snapshot: %d orbs, %d title glyphs, %d labels, %d label glyphs, %.1f ms",
                         orbCount, titleCount, labelCount, pillTextCount, ms))
    }

    // MARK: region labels (the scene's declutter: two-pass hysteresis, edge fade, eased alpha)

    private func declutter(dt: Double, forceVisible: Bool) {
        labelsFading = false
        guard labelCount > 0 else { return }
        let bounds = self.bounds
        let M: CGFloat = 200, haloKeep = RegionLabelPillMetrics.halo, haloPlace = haloKeep + 26.462
        let expanded = bounds.insetBy(dx: -M, dy: -M)
        var boxes: [CGRect] = []; boxes.reserveCapacity(labelCount)
        for i in 0..<labelCount {
            let a = labelAnchors[i]
            let c = CGPoint(x: (Double(a.x) - camX) / camScale + viewW / 2, y: viewH / 2 - (Double(a.y) - camY) / camScale)
            let sz = labelBoxes[i]
            boxes.append(CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height))
        }
        var placed: [CGRect] = [], keys = Set<Int>()
        func tryPlace(_ i: Int, _ halo: CGFloat) {
            guard boxes[i].intersects(expanded) else { return }
            let p = boxes[i].insetBy(dx: -halo, dy: -halo)
            if placed.contains(where: { $0.intersects(p) }) { return }
            placed.append(p); keys.insert(i)
        }
        for i in 0..<labelCount where labelPlaced.contains(i) { tryPlace(i, haloKeep) }
        for i in 0..<labelCount where !labelPlaced.contains(i) { tryPlace(i, haloPlace) }
        let step = Float(min(max(dt, 0), 0.1) / 0.720)
        var published: [CanvasState.TerritoryLabelInfo] = []
        for i in 0..<labelCount {
            let b = boxes[i]
            let dx = max(0, max(bounds.minX - b.maxX, b.minX - bounds.maxX)), dy = max(0, max(bounds.minY - b.maxY, b.minY - bounds.maxY))
            let edge = Float(1 - Self.smooth(0, Double(M), Double(hypot(dx, dy))))
            let target: Float = keys.contains(i) ? edge : 0
            var a = labelAlpha[i]
            if target > a { a = min(target, a + step) } else if target < a { a = max(target, a - step) }
            if a != target { labelsFading = true }
            labelAlpha[i] = a
            if forceVisible, a > 0.001, let s = snapshot {
                let l = s.labels[i]
                published.append(.init(key: l.key, name: l.name, colorHex: l.colorHex, screenPosition: CGPoint(x: b.midX, y: b.midY),
                                       lodAlpha: 1, materialAlpha: 1, declutterAlpha: CGFloat(a)))
            }
        }
        labelPlaced = keys
        if forceVisible, let cs = canvasState { cs.territoryLabels = published }   // G1's `pills` arm: today's SwiftUI layer above
    }

    // MARK: the tick

    /// The fallback's tick: the drawable from the layer (its wait is a probe row, as the SpriteKit Map's).
    fileprivate func displayStep(_ l: CADisplayLink) {
        let w0 = CACurrentMediaTime()
        guard let d = metalLayer.nextDrawable() else { return }
        LivingLayer.probe(.drawableWait, (CACurrentMediaTime() - w0) * 1000, at: w0)
        tick(d, target: l.targetTimestamp, start: w0)
    }

    /// `start` = the link's callback (before any drawable wait): code 37 is callback → commit.
    fileprivate func tick(_ drawable: CAMetalDrawable, target: CFTimeInterval, start t0: CFTimeInterval) {
        LivingLayer.probe(.tickOffered, 1)
        if snapshotDirty { reloadSnapshot() }
        let dt = lastTick > 0 ? min(max(t0 - lastTick, 0), 0.1) : 1.0 / Double(rate)
        lastTick = t0
        applyPending(dt: dt)
        hovered = hitOrb()
        let regionRaw = Self.smooth(Double(RegionLabelTuning.fadeBandEnd), Double(RegionLabelTuning.fadeBandStart), camScale)
        if !bare || arm == "pills" { declutter(dt: dt, forceVisible: arm == "pills") }
        if arm == "pills", let cs = canvasState, cs.mapAtRest { cs.mapAtRest = false }

        let light = snapshot?.isLight ?? true
        var F = LMFrame()
        F.f0 = SIMD4(Float(viewW), Float(viewH), Float(camX), Float(camY))
        F.f1 = SIMD4(Float(camScale), Float(metalLayer.contentsScale), Float(ramp), Float(envelope))
        F.f2 = SIMD4(Float(CorpusPhysicsScene.AnnulusTuning.amplitude), Float(CorpusPhysicsScene.AnnulusTuning.radius),
                     Float(CorpusPhysicsScene.LensTuning.labelLOD), Float(CorpusPhysicsScene.LensTuning.labelLOD * 1.5))
        F.f3 = SIMD4(light ? MapCompTuning.orbOpacity : 1, Float(hovered), bare ? 1 : 0, Float(target - L.start))
        F.ring = light ? SIMD4(0, 0, 0, 0.35) : SIMD4(1, 1, 1, 0.5)
        let ground: SIMD3<Float> = light ? Self.rgb(MapCompTuning.lightGroundHex) : SIMD3(0.0667, 0.0667, 0.0824)
        let dot = AppearancePalette.mapGridDotRGB(dark: !light)
        F.f5 = SIMD4(ground, AppearancePalette.mapGridDotOpacity(dark: !light))
        F.f6 = SIMD4(dot.r, dot.g, dot.b, 0.5)
        F.f7 = SIMD4(83, 5, 3, Float(regionRaw))
        let ink: SIMD3<Float> = light ? Self.rgb("232A2E") : SIMD3(1, 1, 1)
        F.f8 = SIMD4(Float(Self.smooth(0, 0.2, regionRaw)), ink.x, ink.y, ink.z)
        F.pillFill = light ? SIMD4(1, 1, 1, 0.62) : SIMD4(0.11, 0.11, 0.125, 0.62)
        F.f10 = SIMD4(Float(font.distanceRange), Float(font.atlasSize), Float(RegionLabelPillMetrics.fontSize), 0)

        guard let cb = L.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = bare ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(ground.x), green: Double(ground.y), blue: Double(ground.z), alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            let P = L.mapPipelines
            enc.setVertexBytes(&F, length: MemoryLayout<LMFrame>.stride, index: 0)
            enc.setFragmentBytes(&F, length: MemoryLayout<LMFrame>.stride, index: 0)
            if !bare {
                enc.setRenderPipelineState(P.ground)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            if let ob = orbBuf {
                enc.setRenderPipelineState(P.orb)
                enc.setVertexBuffer(ob, offset: 0, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: orbCount)
                if !bare, let tb = titleBuf, let atlas {
                    enc.setRenderPipelineState(P.title)
                    enc.setVertexBuffer(tb, offset: 0, index: 2)
                    enc.setFragmentTexture(atlas, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: titleCount)
                }
            }
            if !bare, let lb = labelBuf, regionRaw > 0.001 {
                labelAlpha.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: max(4, $0.count), index: 2) }
                enc.setVertexBuffer(lb, offset: 0, index: 1)
                enc.setRenderPipelineState(P.pill)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: labelCount)
                if let pt = pillTextBuf, let atlas {
                    enc.setRenderPipelineState(P.pillText)
                    enc.setVertexBuffer(pt, offset: 0, index: 3)
                    enc.setFragmentTexture(atlas, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: pillTextCount)
                }
            }
            enc.endEncoding()
        }
        let v = vid
        if PerfRecorder.on {
            drawable.addPresentedHandler { d in
                let pt = d.presentedTime, at = pt > 0 ? pt : CACurrentMediaTime()
                LivingLayer.probe(.presented, pt > 0 ? 1 : 0, at: at)
                LivingLayer.probe(.presentedView, v + (pt > 0 ? 100000 : 0), at: at)
            }
            cb.addCompletedHandler { cb in
                LivingLayer.probe(.trialGPU, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
        }
        if presentAtTarget { cb.present(drawable, atTime: target) } else { cb.present(drawable) }
        cb.commit()
        let ms = (CACurrentMediaTime() - t0) * 1000
        LivingLayer.probe(.update, Double(rate), at: t0)
        LivingLayer.probe(.updateView, v, at: t0)
        LivingLayer.probe(.trialFrameMain, ms, at: t0)
        Perf.mapFrame(updateMs: ms)
        needsFrame = false
        if !drewFirst { drewFirst = true; onFirstFrame?() }

        // The rest rule (structural): nothing but input, a coast or a fade keeps the link running.
        let awake = t0 - lastInput < 0.4 || coast != .zero || labelsFading || pendEvents > 0
        if !awake {
            linkPaused = true
            LivingLayer.probe(.pause, 0)
            if arm == "pills", let cs = canvasState, !cs.mapAtRest { cs.mapAtRest = true }
        }
    }

    private static func rgb(_ hex: String) -> SIMD3<Float> {
        guard let c = UIColor(hex: hex) else { return SIMD3(0.5, 0.5, 0.5) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }
}

/// CanvasView mounts this INSTEAD of the SpriteView when "Trial Map" is on: the scene is never presented (it stays the
/// data source the snapshot reads), and the SwiftUI label layers are not mounted (except G1's `pills` arm).
struct LivingMapRepresentable: UIViewRepresentable {
    let scene: CorpusPhysicsScene
    let canvasState: CanvasState
    let onFirstFrame: () -> Void
    func makeUIView(context: Context) -> LivingMapView {
        let v = LivingMapView(frame: .zero)
        v.attach(scene: scene, canvasState: canvasState)
        v.onFirstFrame = onFirstFrame
        return v
    }
    func updateUIView(_ v: LivingMapView, context: Context) {}
}

#endif
