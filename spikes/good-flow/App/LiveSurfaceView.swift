// Good Flow spike (throwaway, never merged) · LiveSurfaceView: one Good Flow surface in its own CAMetalLayer.
//
// The 2b trial's core, re-hosted (AirPad/Views/Canvas/Living/LivingMap.swift, read only): CADisplayLink + nextDrawable
// on the main run loop in common modes (CAMetalDisplayLink gives 60 under Catalyst), bgra8Unorm, opaque, 3 drawables.
// THE REST RULE, with two named wakes (design §1):
//   input    — `noteInput()`: awake 0.4 s after the last input, at the display's rate, then the link pauses;
//   live     — while `isLive` and the surface is visible, the app active, Reduce Motion off, Low Power Mode off and the
//              thermal state below serious: draws `liveRate` (30, or 60) a second;
//   oneshot  — `requestFrame(why)`: one frame for a size / data change, then the rule applies again.
// Otherwise the link is paused: 0 ticks, 0 frames. Every frame goes through GFRecorder with its wake.
// The live clock starts at `stillTime` (the time value the still was drawn at), so the first live frame IS the still;
// when live ends, the last live frame's time becomes `stillTime` (and `onLiveEnded` is told).
import UIKit
import Metal
import QuartzCore

final class LiveSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let R = GFRenderer.shared

    /// The surface's name in recordings.
    var surfaceName = "live"
    /// The shader's values (entry, case, theme). `res` is overwritten with the drawable's size; `time` with the clock.
    var base = GFUniforms() { didSet { requestFrame("data") } }
    /// Variant + hash (step 3B). The still under / behind this surface is drawn with the same mode (GFDraw).
    var mode = GFDrawMode() { didSet { if mode != oldValue { requestFrame("mode") } } }
    private let scratch = GFScratch()
    /// Called once with the first live frame's uniforms (the still ↔ live check renders them offscreen).
    var onFirstLiveFrame: ((GFUniforms) -> Void)?
    /// The time value of the still this surface shows (the bench's uTime; look.json stillTime).
    var stillTime: Double {
        get { stillT }
        set { stillT = newValue; if !liveRunning { requestFrame("time") } }
    }
    private var stillT = GFLook.shared.stillTime
    var isLive = false { didSet { if isLive != oldValue { GFRecorder.shared.mark("\(surfaceName) live \(isLive)"); reevaluate() } } }
    var liveRate = 30 { didSet { if liveRate != oldValue { applyRange(); reevaluate() } } }
    /// Called after each tick's commit (part B: apply pending input here, as the trial does).
    var onTick: ((LiveSurfaceView, _ dt: Double) -> Void)?
    var onLiveEnded: ((Double) -> Void)?
    /// The time value the next frame is drawn at.
    var currentTime: Double { stillT + liveElapsed }
    private(set) var drawnFrames = 0, ticks = 0

    private var link: CADisplayLink?
    private var lastInput = -1.0
    private var oneShot: String?
    private var liveRunning = false         // the previous drawn frame was a live-clock frame
    private var liveElapsed = 0.0
    private var lastLiveTarget = 0.0
    private var lastTick = 0.0
    private var rangeIsInput = false
    private var observers: [NSObjectProtocol] = []
    private var appActive = UIApplication.shared.applicationState == .active

    private final class Proxy: NSObject {
        weak var v: LiveSurfaceView?
        @objc func step(_ l: CADisplayLink) { v?.tick(l) }
    }
    private let proxy = Proxy()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        metalLayer.device = R.device
        metalLayer.pixelFormat = R.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)   // the bench's canvas is sRGB; never P3
        proxy.v = self
        let nc = NotificationCenter.default
        let re: (Notification) -> Void = { [weak self] _ in self?.reevaluate() }
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] n in self?.appActive = true; re(n) })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] n in self?.appActive = false; re(n) })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] n in self?.appActive = false; re(n) })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: re))
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: re))
        observers.append(nc.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main, using: re))
        observers.append(nc.addObserver(forName: .gfSettingsChanged, object: nil, queue: .main, using: re))   // simulated states
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate(); observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { link?.isPaused = true; return }
        metalLayer.contentsScale = w.traitCollection.displayScale
        if link == nil {
            let l = CADisplayLink(target: proxy, selector: #selector(Proxy.step(_:)))
            l.isPaused = true
            l.add(to: .main, forMode: .common)
            link = l
            applyRange()
        }
        setNeedsLayout()
        requestFrame("window")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = metalLayer.contentsScale
        let size = CGSize(width: max(1, (bounds.width * s).rounded()), height: max(1, (bounds.height * s).rounded()))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size; requestFrame("size") }
    }

    override var isHidden: Bool { didSet { reevaluate() } }
    override var alpha: CGFloat { didSet { reevaluate() } }

    // MARK: wakes

    /// Wake 1: input. Awake 0.4 s after the last one.
    func noteInput() {
        lastInput = CACurrentMediaTime()
        if !rangeIsInput { applyRange() }
        wake()
    }
    /// A one-shot frame (size, data): drawn once, then the rest rule applies.
    func requestFrame(_ why: String) {
        if oneShot == nil { oneShot = why }
        wake()
    }
    /// Re-read every live condition (visibility, app state, power, thermal, Reduce Motion). Wakes or pauses.
    func reevaluate() {
        if liveAllowed { wake(); return }
        if liveRunning { endLive() }
        // Nothing else awake: pause now rather than spend one empty tick finding out.
        if CACurrentMediaTime() - lastInput >= 0.4, oneShot == nil { link?.isPaused = true }
    }

    /// Wake 2's conditions.
    var liveAllowed: Bool {
        guard isLive, appActive, isVisibleOnScreen else { return false }
        return GFSettings.shared.liveBlockedBy == nil      // Reduce Motion, Low Power, thermal ≥ serious (real or simulated)
    }
    var isVisibleOnScreen: Bool {
        guard let w = window, !isHidden, alpha > 0.01, bounds.width > 0, bounds.height > 0 else { return false }
        var v: UIView? = superview
        while let s = v { if s.isHidden || s.alpha < 0.01 { return false }; v = s.superview }
        return convert(bounds, to: w).intersects(w.bounds)
    }

    private func wake() {
        guard let link, link.isPaused, window != nil else { return }
        lastTick = 0
        link.isPaused = false
    }
    private func applyRange() {
        guard let link else { return }
        let inputAwake = CACurrentMediaTime() - lastInput < 0.4
        rangeIsInput = inputAwake
        let maxFPS = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = inputAwake
            ? CAFrameRateRange(minimum: min(80, maxFPS), maximum: maxFPS, preferred: maxFPS)
            : CAFrameRateRange(minimum: Float(liveRate), maximum: Float(liveRate), preferred: Float(liveRate))
    }
    private func endLive() {
        liveRunning = false
        stillT += liveElapsed; liveElapsed = 0          // the last live frame becomes the still (no redraw: it is on screen)
        GFRecorder.shared.mark("\(surfaceName) live ended at t=\(stillT)")
        onLiveEnded?(stillT)
    }

    /// The uniforms of the frame drawn now (the still ↔ live check draws exactly these offscreen).
    func frameUniforms(width: Int, height: Int) -> GFUniforms {
        var u = base
        u.res = SIMD2(Float(width), Float(height)); u.org = SIMD2(0, 0)
        u.time = Float(currentTime)
        return u
    }
    /// Pass-1 bytes held by this surface (memory accounting).
    var scratchBytes: Int { scratch.bytes }

    // MARK: the tick

    private func tick(_ l: CADisplayLink) {
        let t0 = CACurrentMediaTime()
        ticks += 1
        let inputAwake = t0 - lastInput < 0.4
        if rangeIsInput != inputAwake { applyRange() }
        let live = liveAllowed
        let wakeReason: String? = oneShot.map { "oneshot:" + $0 } ?? (inputAwake ? "input" : (live ? "live" : nil))
        guard let reason = wakeReason else {          // the rest rule: nothing keeps it awake
            GFRecorder.shared.tick(surface: surfaceName, at: t0, drew: false)
            l.isPaused = true
            if liveRunning { endLive() }
            return
        }
        // The live clock: advances only between consecutive live-allowed frames; the first live frame is the still.
        var firstLive = false
        if live {
            if liveRunning { liveElapsed += min(max(l.targetTimestamp - lastLiveTarget, 0), 0.25) } else { firstLive = true }
            liveRunning = true; lastLiveTarget = l.targetTimestamp
        } else if liveRunning { endLive() }

        let tw = CACurrentMediaTime()
        guard let drawable = metalLayer.nextDrawable() else { GFRecorder.shared.tick(surface: surfaceName, at: t0, drew: false); return }
        GFRecorder.shared.tick(surface: surfaceName, at: t0, drew: true)
        let dt = lastTick > 0 ? t0 - lastTick : l.duration
        lastTick = t0
        let tex = drawable.texture
        let u = frameUniforms(width: tex.width, height: tex.height)
        if firstLive { onFirstLiveFrame?(u) }
        let waitMs = (CACurrentMediaTime() - tw) * 1000
        let rec = GFRecorder.shared
        let idx = rec.begin(surface: surfaceName, wake: reason, linkT: l.timestamp, targetT: l.targetTimestamp, vsync: l.duration,
                            rate: Double(l.preferredFrameRateRange.preferred ?? 0), startT: t0, px: tex.width * tex.height)
        let cb = R.queue.makeCommandBuffer()!
        GFDraw.encode(cb, target: tex, u, mode, scratch: scratch)
        drawable.addPresentedHandler { d in rec.setPresent(idx, d.presentedTime) }
        cb.addCompletedHandler { cb in rec.setGPU(idx, (cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        cb.present(drawable)
        cb.commit()
        oneShot = nil
        drawnFrames += 1
        onTick?(self, dt)
        rec.setMain(idx, (CACurrentMediaTime() - t0) * 1000); rec.setWait(idx, waitMs)
        // Pause now if nothing will need the next tick (saves one empty tick).
        if !(CACurrentMediaTime() - lastInput < 0.4) && !live && oneShot == nil { l.isPaused = true }
    }
}
