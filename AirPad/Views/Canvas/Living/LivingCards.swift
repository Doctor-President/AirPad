import UIKit
import SwiftUI
import Metal
import QuartzCore

// Sweep 2b · 2.3 — the renderer trial, scene 2: the Cards backgrounds (Ops design-refs/sweep-2b/renderer-trial-design.md
// §3.3). SCRATCH BRANCH ws-2b-renderer-trial: never merged. Mac only, DEBUG or DEVSWITCHES builds only.
//
// Host: 2.2's arm B collection view (MacCardsSpike.swift). Arms (`-LivingTrialArm a|b|c|d|cdrift`, or Settings › About ›
// Version ×5 › Mac feel (testing) › "Trial Cards background" + its arm picker; reopen Cards after switching):
//   a       backgrounds off: a flat base in each cell (the host's ceiling)
//   b       today: each card's own `.colorEffect` field in a `TimelineView` (30 a second while on screen)
//   c       one pass: `LivingCardsView` is the collection view's backgroundView (sized to the visible area, not scrolled);
//           every visible card's background (drop shadow + field) in ONE instanced draw; the cell is clear there. The
//           layer presents WITH the Core Animation transaction, drawn in the collection view's layout pass after a scroll
//           offset change (so it lands in the same screen update as the cells' move); no link: at rest nothing draws
//           (one-shot passes on appearance, data, size / width change).
//   cdrift  stretch: c plus a 30 fps drift at rest (a CADisplayLink at 30 draws the field with the clock).
//   d       a still picture per card, drawn once (ImageRenderer of the card's own field at time 0) and cached.
// Cover-image cards keep their own path in every arm (their body has no colour field); the pass counts them.
// Knob: `-LivingTrialCardsTxn NO` presents outside the transaction (the offset control: the background should then lag).

#if targetEnvironment(macCatalyst) && (DEBUG || DEVSWITCHES)

extension LivingTrial {
    static let cardsArmKey = "LivingTrialCardsArm"
    static let cardsArms = ["a", "b", "c", "d", "cdrift"]
    static var cardsArm: String {
        let d = UserDefaults.standard
        if let a = d.string(forKey: armKey), cardsArms.contains(a) { return a }
        if let a = d.string(forKey: cardsArmKey), cardsArms.contains(a) { return a }
        return "c"
    }
    static var cardsEnabled: Bool { cardsOn(UserDefaults.standard.string(forKey: key) ?? "") }
    static var cardsInTransaction: Bool {
        UserDefaults.standard.object(forKey: "LivingTrialCardsTxn") == nil ? true : UserDefaults.standard.bool(forKey: "LivingTrialCardsTxn")
    }
    /// Scene 2 fix (offset stills, 2026-11-24): `precommit` (default) runs the collection view's layout (and so the pass) from
    /// a run-loop observer just before Core Animation's commit observer, so the drawable is presented inside the open
    /// transaction; `layout` = as first built (the pass ran in whatever layout pass UIKit ran, which can be the commit's own).
    static var cardsWhen: String { UserDefaults.standard.string(forKey: "LivingTrialCardsWhen") ?? "precommit" }
    /// Scene 2 fix 2 (2026-11-24): `tiles` (default) = the pass draws into content-anchored bands (CAMetalLayers inside the
    /// pinned background view, 1,024 pt tall, moved by Core Animation in the same commit as the cells; each band drawn once
    /// when it comes within one band of the visible area, presented on completion, redrawn only on a data / width /
    /// appearance change or a drift tick). A drawable's latency then shows only as a band arriving late at the edge, never
    /// as an offset. `screen` = the first build (one screen-sized drawable per scroll step, presented with the transaction).
    static var cardsMode: String { UserDefaults.standard.string(forKey: "LivingTrialCardsMode") ?? "tiles" }
    /// Knob: drawables in the pass's pool (2 or 3; default 3).
    static var cardsDrawables: Int { let n = UserDefaults.standard.integer(forKey: "LivingTrialCardsDrawables"); return n == 2 ? 2 : 3 }
    static func cardBG(_ arm: String?) -> LivingCardBG {
        switch arm {
        case "a": return .flat
        case "c", "cdrift": return .clear
        case "d": return .picture
        default: return .own
        }
    }
}

extension LivingTrial {
    /// Leftover (b), one look at the ~8 ms nextDrawable episodes: every CAMetalLayer under `view` with the settings that
    /// decide how drawables come back (logged once for SKView's layer and the trial Map's, to compare).
    static func describeMetalLayers(_ name: String, in view: UIView) {
        var out: [String] = []
        func walk(_ l: CALayer, _ depth: Int) {
            if let m = l as? CAMetalLayer {
                let cs = m.colorspace.flatMap { $0.name as String? } ?? "untagged"
                out.append("\(type(of: m)) depth \(depth) bounds \(m.bounds.width)×\(m.bounds.height) frame-in-window \(m.convert(m.bounds, to: nil).origin.x),\(m.convert(m.bounds, to: nil).origin.y) scale \(m.contentsScale) drawable \(Int(m.drawableSize.width))×\(Int(m.drawableSize.height)) max \(m.maximumDrawableCount) sync \(m.displaySyncEnabled) txn \(m.presentsWithTransaction) timeout \(m.allowsNextDrawableTimeout) fbOnly \(m.framebufferOnly) fmt \(m.pixelFormat.rawValue) cs \(cs) opaque \(m.isOpaque) edr \(m.wantsExtendedDynamicRangeContent) gravity \(m.contentsGravity.rawValue)")
            }
            for s in l.sublayers ?? [] { walk(s, depth + 1) }
        }
        walk(view.layer, 0)
        let line = "metal layers \(name): " + (out.isEmpty ? "none" : out.joined(separator: " | "))
        Perf.mark(line)
        FileHandle.standardError.write(Data(("LIVINGLAYERS " + line + "\n").utf8))
    }
}

/// The background pass behind the cards. Owned by the collection view (its `backgroundView`).
final class LivingCardsView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var ml: CAMetalLayer { layer as! CAMetalLayer }
    private let L = LivingLayer.shared
    private static var pipeline: MTLRenderPipelineState?

    weak var collectionView: UICollectionView?
    var nodeAt: ((IndexPath) -> Node?)?
    let arm: String
    private let inTxn = LivingTrial.cardsInTransaction
    private var drift: CADisplayLink?
    private var packed: [String: [Float]] = [:]          // per entry (id + primary tag): the three blobs, CARD layout
    private var lastSig: [Double] = []
    private var dataVersion = 0
    private var pendingScroll = false
    private var lastOffset: CGPoint?
    private var appeared = false
    private lazy var vid: Double = MapProbeID.of(self)
    /// The tile's zone (its `heroPercent_2col`): the blobs ride up into the top 43 % of a card without a cover.
    private let zone: CGFloat = {
        let v = UserDefaults.standard.object(forKey: TileTuningKey.heroPercent_2col) as? Double
        return CGFloat(v ?? TileTuningDefaults.heroPercent_2col)
    }()
    private let circleScale: CGFloat = {
        let v = UserDefaults.standard.object(forKey: TileTuningKey.gradientCircleScale_2col) as? Double
        return CGFloat(v ?? TileTuningDefaults.gradientCircleScale_2col)
    }()
    private let vignette: Float = {
        let v = UserDefaults.standard.object(forKey: TileTuningKey.gradientVignette_2col) as? Double
        return Float(v ?? TileTuningDefaults.gradientVignette_2col)
    }()

    init(arm: String) {
        self.arm = arm
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        ml.device = L.device
        ml.pixelFormat = .bgra8Unorm
        ml.framebufferOnly = true
        ml.isOpaque = false
        ml.maximumDrawableCount = LivingTrial.cardsDrawables
        ml.presentsWithTransaction = inTxn
        if LivingTrial.colorspace == "srgb" { ml.colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
        accessibilityIdentifier = "livingCards"
        if Self.pipeline == nil {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = L.library.makeFunction(name: "lc_card_v")
            d.fragmentFunction = L.library.makeFunction(name: "lc_card_f")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true   // premultiplied over (a shadow may fall on a neighbour)
            c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            Self.pipeline = try? L.device.makeRenderPipelineState(descriptor: d)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        drift?.invalidate()
        if let o = flush { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
    }

    /// The pre-commit flush (`LivingTrial.cardsWhen == "precommit"`): before the run loop sleeps, and before Core Animation's
    /// own commit observer (order 2,000,000), lay the collection view out if a scroll is pending, so the pass draws and
    /// presents into the transaction that is about to commit with the cells' move.
    private var flush: CFRunLoopObserver?
    private var inFlush = false
    private func installFlush() {
        guard flush == nil, LivingTrial.cardsWhen == "precommit" else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                   true, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingScroll, let cv = self.collectionView, self.window != nil else { return }
                self.inFlush = true
                cv.layoutIfNeeded()
                if self.pendingScroll { self.layoutDraw() }   // layout ran nothing (no layout was pending): draw anyway
                self.inFlush = false
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        flush = o
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { drift?.isPaused = true; return }
        ml.contentsScale = w.traitCollection.displayScale
        if arm == "cdrift", drift == nil {
            let l = CADisplayLink(target: self, selector: #selector(driftStep(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            l.add(to: .main, forMode: .common)
            drift = l
        }
        drift?.isPaused = false
        installFlush()
        Perf.mark("living cards mounted · arm \(arm) · in transaction \(inTxn) · when \(LivingTrial.cardsWhen) · drawables \(ml.maximumDrawableCount)")
        appeared = false
        collectionView?.setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { dataVersion += 1; reason = 6; collectionView?.setNeedsLayout() }
    }

    private var reason = 0
    func dataChanged() { dataVersion += 1; if reason == 0 { reason = 3 }; collectionView?.setNeedsLayout() }

    /// From scrollViewDidScroll: one offset change.
    func noteScroll(_ offset: CGPoint) {
        guard offset != lastOffset else { return }
        if let o = lastOffset { LivingLayer.probe(.cardsOffset, Double(abs(offset.y - o.y) + abs(offset.x - o.x))) }
        if pendingScroll { LivingLayer.probe(.cardsCoalesced) }
        pendingScroll = true
        lastOffset = offset
    }

    // MARK: tiles mode
    private let tiled = LivingTrial.cardsMode == "tiles"
    private static let bandH: CGFloat = 1024
    private final class Band { let layer = CAMetalLayer(); var index = Int.min; var drawnSig: [Double] = [] }
    private var bands: [Band] = []
    private var tileSig: [Double] = []

    private func tileLayout(_ cv: UICollectionView) {
        let b = cv.bounds, cs = cv.contentSize, s = ml.contentsScale
        // What a band's picture depends on (not the offset): width, content size, data, look.
        let sig = [Double(b.width), Double(cs.width), Double(cs.height), Double(dataVersion), Double(traitCollection.userInterfaceStyle.rawValue), Double(s)]
        let changed = sig != tileSig
        let why = !appeared ? 4 : changed ? (reason != 0 ? reason : 2) : 1
        tileSig = sig; appeared = true; pendingScroll = false; reason = 0
        let lo = Int(floor((b.minY - Self.bandH) / Self.bandH)), hi = Int(floor((b.maxY + Self.bandH) / Self.bandH))
        let want = Set(max(0, lo)...max(0, hi))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Free bands far from view; give wanted bands a layer (visible ones first).
        for band in bands where !want.contains(band.index) { band.index = Int.min; band.layer.isHidden = true }
        let order = want.sorted { abs(CGFloat($0) * Self.bandH - b.midY) < abs(CGFloat($1) * Self.bandH - b.midY) }
        for i in order {
            let band: Band
            if let have = bands.first(where: { $0.index == i }) { band = have }
            else if let free = bands.first(where: { $0.index == Int.min }) { band = free; band.index = i; band.drawnSig = []; band.layer.isHidden = true }
            else {
                band = Band(); band.index = i
                let l = band.layer
                l.isHidden = true
                l.device = L.device; l.pixelFormat = .bgra8Unorm; l.framebufferOnly = true; l.isOpaque = false
                l.maximumDrawableCount = 2; l.presentsWithTransaction = false; l.contentsScale = s
                if LivingTrial.colorspace == "srgb" { l.colorspace = CGColorSpace(name: CGColorSpace.sRGB) }
                l.anchorPoint = .zero
                layer.addSublayer(l); bands.append(band)
            }
            // Content-anchored: band i covers content y [i·H, (i+1)·H); the host view is pinned to the visible area.
            let r = CGRect(x: b.minX, y: CGFloat(i) * Self.bandH, width: b.width, height: Self.bandH)
            band.layer.bounds = CGRect(origin: .zero, size: r.size)
            band.layer.position = CGPoint(x: 0, y: r.minY - b.minY)
            band.layer.contentsScale = s
            if band.drawnSig != sig {
                band.drawnSig = sig
                LivingLayer.probe(.cardsPassWhere, 2)
                // A new or reassigned band stays hidden until its picture is on the GPU (it would show the band it last
                // held); a band redrawn in place (data / width / look) keeps showing its old picture until the new one lands.
                draw(why, into: band.layer, rect: r, txn: false, done: band.layer.isHidden ? i : nil)
            }
        }
        CATransaction.commit()
    }

    private func reveal(_ i: Int) {
        guard let band = bands.first(where: { $0.index == i }), band.drawnSig == tileSig else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); band.layer.isHidden = false; CATransaction.commit()
    }

    /// From the collection view's layoutSubviews, after its own layout (same transaction as a scroll's cell moves).
    func layoutDraw() {
        guard let cv = collectionView, window != nil else { return }
        if frame != cv.bounds { frame = cv.bounds }
        if tiled { tileLayout(cv); return }
        let b = cv.bounds, cs = cv.contentSize
        let sig = [Double(b.minX), Double(b.minY), Double(b.width), Double(b.height), Double(cs.width), Double(cs.height), Double(dataVersion)]
        guard sig != lastSig || !appeared else { pendingScroll = false; return }
        let why = !appeared ? 4 : pendingScroll ? 1 : reason != 0 ? reason : 2
        lastSig = sig
        appeared = true
        pendingScroll = false
        reason = 0
        LivingLayer.probe(.cardsPassWhere, inFlush ? 1 : 0)
        draw(why)
    }

    @objc private func driftStep(_ l: CADisplayLink) {
        MainActor.assumeIsolated {
            guard tiled else { draw(5); return }
            guard let cv = collectionView else { return }
            let b = cv.bounds
            for band in bands where band.index != Int.min {
                let r = CGRect(x: b.minX, y: CGFloat(band.index) * Self.bandH, width: b.width, height: Self.bandH)
                if r.intersects(b) { draw(5, into: band.layer, rect: r, txn: false) }
            }
        }
    }

    private func entry(_ n: Node) -> [Float] {
        let k = n.id + "|" + (n.primaryTag ?? "")
        if let p = packed[k] { return p }
        let layer = NodeGradientLayer(node: n, circleScale: circleScale, vignette: CGFloat(vignette),
                                      glowStart: GradientBake.gridGlowStart, glowEnd: GradientBake.gridGlowEnd,
                                      glowStrength: GradientBake.gridRadial, bloom: GradientBake.gridBloom,
                                      animated: false, anchor: .center, blobExpr: 2, glassSurface: .grid, showsBlobs: true)
        // The view's phase is a random @State per instance; the trial takes a stable one per entry.
        let phase = Double(NodeGradientLayer.stableHash(n.id) % 10_000) / 100
        var p = layer.livingCardPacked(phase: phase)
        if p.count < 48 { p += Array(repeating: 0, count: 48 - p.count) }
        packed[k] = Array(p.prefix(48))
        return packed[k]!
    }

    private static func rgb(_ c: Color, _ t: UITraitCollection) -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).resolvedColor(with: t).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }

    private func draw(_ why: Int) {
        guard let cv = collectionView else { return }
        draw(why, into: ml, rect: cv.bounds, txn: inTxn)
    }

    /// One pass: the cards intersecting `b` (content coordinates) into `ml`, whose (0,0) is `b`'s top-left.
    private func draw(_ why: Int, into ml: CAMetalLayer, rect b: CGRect, txn inTxn: Bool, done band: Int? = nil) {
        guard let cv = collectionView, window != nil, let pipe = Self.pipeline, b.width > 1 else { return }
        let t0 = CACurrentMediaTime()
        let s = ml.contentsScale
        let px = CGSize(width: max(1, b.width * s), height: max(1, b.height * s))
        if ml.drawableSize != px { ml.drawableSize = px }
        // (cards just outside `b` still cast their shadow into it)
        let attrs = (cv.collectionViewLayout.layoutAttributesForElements(in: b.insetBy(dx: 0, dy: -64)) ?? []).filter { $0.representedElementCategory == .cell }
        var floats: [Float] = []
        floats.reserveCapacity(attrs.count * 56)
        var n = 0, own = 0
        for a in attrs {
            guard let node = nodeAt?(a.indexPath) else { continue }
            if node.coverImageRelativePath != nil { own += 1; continue }
            let f = a.frame
            floats += [Float(f.minX - b.minX), Float(f.minY - b.minY), Float(f.width), Float(f.height)]
            floats += [Float((f.height * zone - f.height) / 2), Float(min(f.width / 360, 1)), 0, 0]
            floats += entry(node)
            n += 1
        }
        let t = traitCollection
        let dark = t.userInterfaceStyle == .dark
        var F = LCFrameS()
        let time: Float = arm == "cdrift" ? Float((t0 - L.start).truncatingRemainder(dividingBy: 1000)) : 0
        F.f0 = SIMD4(Float(b.width), Float(b.height), time, Float(s))
        let glass = FlutedGlass.shared.active(.grid)?.packed(GlassGeometry.current, tilt: .zero)
        F.f1 = SIMD4(dark ? 1 : 0, dark ? 2 : 0, dark ? Float(GradientBake.gridBloom) : 0, glass != nil ? 1 : 0)
        var base = dark ? Self.rgb(AppearancePalette.mapBackground(dark: true), t)
            : Self.rgb(AppearancePalette.parchmentGround(AppearancePalette.cwParchmentHex, lightness: CardSurfaceResolved.baseLightness), t)
        base.w = 14
        F.base = base
        F.shadow = Self.rgb(AppearancePalette.cardShadow, t)
        F.sh2 = SIMD4(Float(CardSurfaceResolved.shadowRadius(dark: dark)), Float(CardSurfaceResolved.shadowY(dark: dark)), vignette,
                      Float(GradientBake.gridRadial))
        F.glow = SIMD4(Float(GradientBake.gridGlowStart), Float(GradientBake.gridGlowEnd), 0, 0)
        var g = glass ?? Array(repeating: 0, count: 10)
        g += [0, 0]

        let w0 = CACurrentMediaTime()
        guard let drawable = ml.nextDrawable() else { LivingLayer.probe(.cardsDrawableWait, -1); return }
        let waitMs = (CACurrentMediaTime() - w0) * 1000
        guard let cb = L.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            if n > 0, let buf = floats.withUnsafeBytes({ L.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) {
                enc.setRenderPipelineState(pipe)
                enc.setVertexBytes(&F, length: MemoryLayout<LCFrameS>.stride, index: 0)
                enc.setFragmentBytes(&F, length: MemoryLayout<LCFrameS>.stride, index: 0)
                enc.setVertexBuffer(buf, offset: 0, index: 1)
                enc.setFragmentBuffer(buf, offset: 0, index: 1)
                g.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
            }
            enc.endEncoding()
        }
        if PerfRecorder.on {
            let v = vid
            drawable.addPresentedHandler { d in
                let pt = d.presentedTime, at = pt > 0 ? pt : CACurrentMediaTime()
                LivingLayer.probe(.cardsPresented, pt > 0 ? 1 : 0, at: at)
                _ = v
            }
            cb.addCompletedHandler { cb in LivingLayer.probe(.cardsGPU, (cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        if let i = band { cb.addCompletedHandler { _ in Task { @MainActor [weak self] in self?.reveal(i) } } }
        if inTxn {
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        } else {
            cb.present(drawable)
            cb.commit()
        }
        let ms = (CACurrentMediaTime() - t0) * 1000
        LivingLayer.probe(.cardsDrawReason, Double(why), at: t0)
        LivingLayer.probe(.cardsDrawn, Double(n), at: t0)
        LivingLayer.probe(.cardsOwnPath, Double(own), at: t0)
        LivingLayer.probe(.cardsDrawableWait, waitMs, at: t0)
        LivingLayer.probe(.cardsDraw, ms, at: t0)
    }
}

/// Matches LCFrame in LivingCards.metal (all float4).
private struct LCFrameS {
    var f0 = SIMD4<Float>(), f1 = SIMD4<Float>(), base = SIMD4<Float>(), shadow = SIMD4<Float>(), sh2 = SIMD4<Float>(), glow = SIMD4<Float>()
}

// MARK: - Arm d: a still per card, drawn once and kept

@MainActor final class LivingCardPictures {
    static let shared = LivingCardPictures()
    let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 700_000_000; return c
    }()
}

/// The card's own field (its NodeGradientLayer at time 0, with the glass), rendered once per entry, size and look; a flat
/// base until it exists. Rendering yields first, on the main thread (ImageRenderer), and is counted (code 49).
struct LivingCardPicture<Content: View>: View {
    let id: String
    let size: CGSize
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @State private var renderedKey = ""

    private var key: String { "\(id)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))-\(scheme == .dark ? "d" : "l")" }

    var body: some View {
        let k = key
        let _ = renderedKey
        if let img = LivingCardPictures.shared.cache.object(forKey: k as NSString) {
            Image(uiImage: img).resizable()
        } else {
            LivingCardFlat()
                .task(id: k) {
                    await Task.yield()
                    guard LivingCardPictures.shared.cache.object(forKey: k as NSString) == nil, size.width > 1 else { renderedKey = k; return }
                    let t0 = CACurrentMediaTime()
                    let r = ImageRenderer(content: content().frame(width: size.width, height: size.height)
                        .environment(\.colorScheme, scheme))
                    r.scale = displayScale
                    r.isOpaque = true
                    if let ui = r.uiImage {
                        LivingCardPictures.shared.cache.setObject(ui, forKey: k as NSString,
                                                                  cost: Int(size.width * size.height * displayScale * displayScale * 4))
                    }
                    LivingLayer.probe(.cardsPicture, (CACurrentMediaTime() - t0) * 1000)
                    renderedKey = k
                }
        }
    }
}

#endif
