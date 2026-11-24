import Foundation
import UIKit
import SwiftUI
import os
import OSLog
import SpriteKit
import QuartzCore
import Metal

// Mac performance audit (P6) — the built-in performance recorder, Mac and iPhone.
//
// While on, it keeps a rolling buffer of: display-link frame intervals (main thread), main-thread busy stretches (run
// loop wake → sleep) with stack samples of any stretch over 40 ms, input events (when the hardware event happened and
// when the app got it), which major SwiftUI views rebuilt (and, optionally, why), Map frames drawn, named marks and
// intervals, and once a second memory / CPU / thermal state. A trigger (Mac: ⌃⌥⌘P; iPhone: a three-finger long-press or
// the panel's button; harness: the Darwin notification `com.airpad.perf.save`) writes the last ~15 s to
// Caches/PerfRecordings/perf-<time>-<screen>.json. `scripts/perf/explain.py` turns a file into "what was slow and why".
//
// Nothing from the library goes into a recording: view type names, counts, timings and code symbols only.
// Compiled into builds with DEBUG or DEVSWITCHES (Xcode runs, TestFlight); an App Store archive has only the empty
// `Perf` call sites below.

/// The call sites the app uses. Each is a no-op unless the recorder is compiled in AND switched on.
enum Perf {
    /// In a view's `body`: `let _ = Perf.body(Self.self)` — counts the rebuild (and logs why with `-PerfWhy YES`).
    @inline(__always) static func body<V: View>(_ type: V.Type) {
        #if DEBUG || DEVSWITCHES
        guard PerfRecorder.on else { return }
        PerfRecorder.shared.noteBody(ObjectIdentifier(type), name: { String(describing: type) })
        if PerfRecorder.why { type._logChanges() }
        #endif
    }
    /// A named moment ("appearance dark", "open entry").
    @inline(__always) static func mark(_ name: @autoclosure () -> String) {
        #if DEBUG || DEVSWITCHES
        guard PerfRecorder.on else { return }
        PerfRecorder.shared.noteMark(name())
        #endif
    }
    /// The screen the user is on, as kinds and counts only (never names): "Map · collection", "Entry · 3 items".
    @inline(__always) static func screen(_ label: @autoclosure () -> String) {
        #if DEBUG || DEVSWITCHES
        PerfRecorder.shared.noteScreen(label())   // kept even while off, so a recorder switched on later knows the screen
        #endif
    }
    /// A measured stretch of main-thread (or any-thread) work: `Perf.interval("layout") { … }`.
    @inline(__always) static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        #if DEBUG || DEVSWITCHES
        guard PerfRecorder.on else { return try work() }
        let t0 = CACurrentMediaTime()
        defer { PerfRecorder.shared.noteInterval(name, start: t0, end: CACurrentMediaTime()) }
        return try work()
        #else
        return try work()
        #endif
    }
    /// One Map frame (the scene's `update`), with what its own work cost.
    @inline(__always) static func mapFrame(updateMs: Double) {
        #if DEBUG || DEVSWITCHES
        guard PerfRecorder.on else { return }
        PerfRecorder.shared.noteMapFrame(updateMs)
        #endif
    }
    /// Sweep 2b · 2.1 — one Map pacing event (a display tick offered to the SKView, an `update`, a pause, a scroll
    /// `.changed` …) with an optional number. Read by `scripts/perf/map_probe.py`. Numbers only.
    @inline(__always) static func probe(_ code: MapProbe, _ value: Double = 0) {
        #if DEBUG || DEVSWITCHES
        guard PerfRecorder.on else { return }
        PerfRecorder.shared.noteProbe(code.rawValue, value)
        #endif
    }
    static var isAvailable: Bool {
        #if DEBUG || DEVSWITCHES
        true
        #else
        false
        #endif
    }
}

/// Sweep 2b · 2.1 — the Map pacing probe's event codes (the recording's `probe` rows: [t, code, value]). Keep the
/// numbers stable: `scripts/perf/map_probe.py` reads them.
enum MapProbe: UInt8 {
    case tickOffered = 1        // SKViewDelegate view(_:shouldRenderAtTime:) called; value = 1 if accepted
    case update = 3             // the scene's update ran; value = the SKView's preferredFramesPerSecond
    case updateEarlyReturn = 4  // update called while the scene is paused
    case didFinishUpdate = 5
    case askSet = 6             // the scene wrote preferredFramesPerSecond; value = fps
    case pause = 7              // rest pause (value = 0) …
    case wake = 8               // … and wake; value = MapProbeWake code
    case scrollBegan = 9, scrollChanged = 10, scrollEnded = 11, scrollChangedPaused = 12
    case pinchBegan = 13, pinchChanged = 14, pinchEnded = 15, pinchChangedPaused = 16   // pinchChanged value = travel Δ
    case cameraWriteOutsideUpdate = 17
    case runLoopMode = 18       // at a scroll callback: 0 default, 1 tracking, 2 other
    case drawableWait = 19      // CAMetalLayer nextDrawable on the Map's layer: value = ms it blocked
    case presented = 20         // the Map's drawable reached the screen: t = presentedTime (0 value = dropped)
    case skvRateWrite = 21      // ANY write of SKView.preferredFramesPerSecond (scene or SwiftUI); value = fps
    case skvPauseWrite = 22     // ANY write of SKView.isPaused; value = 1 paused
    case touchFlagCleared = 23  // isTouchingMap cleared; value = 1 scroll, 2 pinch, 3 touch, 4 touch cancel
    case touchBegan = 24, touchMoved = 25, touchEnded = 26
    case hoverWake = 27
    case pendingCamApplied = 28 // fix: queued pointer deltas applied inside update; value = how many events
    case tickSkipped = 29       // fix: the pacer declined a tick (clean 60 / 30)
    case updateView = 30        // the SKView whose tick ran this update: value = view id (low pointer bits)
    case drawableView = 31      // the SKView that took a drawable: value = view id (+ 100000 on the main thread)
    case presentedView = 32     // the SKView whose drawable was presented: value = view id (+ 100000 if it reached the screen)
    case updateViewHidden = 33  // the updating view is not on screen: bits 1 no window, 2 hidden/alpha 0 up the chain, 4 scene.view ≠ this view
    case labelGap = 34          // at a tick: largest distance (pt) between a region pill's published position and its orbs now
    case ringGap = 35           // at a tick: distance (pt) between the hover ring and its orb now
    case coastSeeded = 36       // a scroll's lift launched a coast: value = speed (pt per 60 Hz frame)
    // Sweep 2b · 2.3 renderer trial (scratch branch): the trial Map's own frame rows (it also writes 1, 3, 7, 8, 9–16, 20, 30, 32)
    case trialFrameMain = 37    // main-thread ms from the display link's callback to the command buffer's commit
    case trialGPU = 38          // GPU ms of the frame's command buffer (gpuEndTime − gpuStartTime)
    case trialSnapshot = 39     // the trial re-read the scene's values: value = ms
    // Sweep 2b · 2.3 renderer trial, scene 2 (Cards backgrounds in one pass behind the collection view)
    case cardsDraw = 40         // one background pass on the main thread: value = ms (drawable wait, encode, commit, wait until scheduled, present)
    case cardsGPU = 41          // GPU ms of that pass's command buffer
    case cardsPresented = 42    // the pass reached the screen: t = presentedTime (value 0 = dropped)
    case cardsOffset = 43       // scrollViewDidScroll with a changed offset: value = |Δy| pt
    case cardsDrawableWait = 44 // nextDrawable blocked this long (ms)
    case cardsDrawReason = 45   // why a pass ran: 1 scroll, 2 layout (size / width), 3 data, 4 appear, 5 drift tick, 6 appearance
    case cardsDrawn = 46        // cards drawn in that pass (value = count)
    case cardsOwnPath = 47      // visible cards that keep their own background (cover-image cards): value = count
    case cardsCoalesced = 48    // an offset change followed by another before any pass (two offsets in one transaction)
    case cardsPicture = 49      // arm d: one card's still rendered (ImageRenderer) on the main thread: value = ms
    case cardsPassWhere = 50    // where a pass ran: 1 = the pre-commit flush (before Core Animation's commit), 0 = inside a layout pass UIKit ran (possibly the commit's own)
}

/// Sweep 2b · 2.1 probe — a stable small number for a view (low pointer bits), to tell two SKViews apart.
enum MapProbeID {
    static func of(_ o: AnyObject?) -> Double {
        guard let o else { return 0 }
        return Double((UInt(bitPattern: ObjectIdentifier(o).hashValue) >> 4) & 0xFFFF)
    }
}

/// Wake reasons as numbers (the marks carry the words).
enum MapProbeWake {
    static func code(_ reason: String) -> Double {
        switch reason {
        case "touch": 1; case "scroll": 2; case "pinch": 3; case "hover": 4; case "defaults": 5; case "external": 6
        case "delayed": 7; case "haloStep": 8; case "size": 9; case "appearance": 10; case "keyboardZoom": 11
        case "momentum": 12; case "active": 13; case "foreground": 14
        default: 99
        }
    }
}

#if DEBUG || DEVSWITCHES

final class PerfRecorder: NSObject {
    static let shared = PerfRecorder()
    static let onKey = "perf.recorder.on"
    static let saveNotification = Notification.Name("PerfRecorderDidSave")
    /// Read on every call site; written on the main thread only.
    private(set) static var on = false
    private(set) static var why = false

    // MARK: the rolling buffer (one lock; writers are the main thread and the watchdog thread)

    private struct Ring<T> {
        var items: [T] = []; var head = 0; let cap: Int
        init(_ cap: Int) { self.cap = cap; items.reserveCapacity(min(cap, 4096)) }
        mutating func push(_ x: T) { if items.count < cap { items.append(x) } else { items[head] = x; head = (head + 1) % cap } }
        func ordered() -> [T] { items.count < cap ? items : Array(items[head...] + items[..<head]) }
    }
    private struct Frame { var t: Double; var dt: Float }
    private struct Span { var t: Double; var dur: Float }
    private struct Input { var t: Double; var got: Double; var kind: UInt8; var phase: UInt8 }
    private struct Mark { var t: Double; var name: String }
    private struct Interval { var t: Double; var dur: Float; var name: StaticString; var main: Bool }
    private struct Bodies { var t: Double; var counts: [ObjectIdentifier: Int32] }
    private struct MapSecond { var t: Double; var frames: Int32; var updateMs: Float; var maxMs: Float }
    private struct Vital { var t: Double; var footprintMB: Float; var cpuPct: Float; var mainCpuPct: Float; var thermal: Int8; var lowPower: Bool }
    private struct Sample { var t: Double; var busyFor: Float; var frames: [UInt] }
    private struct ProbeEvent { var t: Double; var code: UInt8; var v: Float }

    private var lock = os_unfair_lock()
    private var seconds = 15.0
    private var frames = Ring<Frame>(1), spans = Ring<Span>(1), inputs = Ring<Input>(1), marks = Ring<Mark>(1)
    private var intervals = Ring<Interval>(1), bodies = Ring<Bodies>(1), mapSeconds = Ring<MapSecond>(1)
    private var vitals = Ring<Vital>(1), samples = Ring<Sample>(1), probes = Ring<ProbeEvent>(1)
    private var bodyNames: [ObjectIdentifier: String] = [:]
    private var bodyBucket: [ObjectIdentifier: Int32] = [:]
    private var bodyBucketStart = 0.0
    private var mapBucket = MapSecond(t: 0, frames: 0, updateMs: 0, maxMs: 0)
    private var screenLabel = "launch"

    // MARK: main-thread state the watchdog reads (plain words, written on main, read racily: fine for a sampler)

    private var busySince = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private var link: CADisplayLink?
    private var lastTick = 0.0
    private var observers: [CFRunLoopObserver] = []
    private var watchdog: Thread?
    private var running = false
    private var mainThread: thread_t = 0
    private var mainStackLo: UInt = 0, mainStackHi: UInt = 0
    private var gesture: UIGestureRecognizer?
    private var lastSaved: URL?

    // MARK: start / stop

    /// Called once at launch (and from the panel's switch). `-PerfRecorder YES` turns it on for a run;
    /// `-PerfRecorderSeconds N` sets the window (the harness keeps whole sessions); `-PerfWhy YES` logs SwiftUI's
    /// reason for each counted rebuild.
    @MainActor static func startIfEnabled() {
        let d = UserDefaults.standard
        if d.bool(forKey: "PerfRecorder") || d.bool(forKey: onKey) { shared.start() }
    }
    @MainActor static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: onKey)
        enabled ? shared.start() : shared.stop()
    }

    @MainActor func start() {
        guard !running else { return }
        running = true
        let d = UserDefaults.standard
        let s = d.double(forKey: "PerfRecorderSeconds")
        seconds = s > 0 ? s : 15
        let n = Int(seconds)
        frames = Ring(n * 125); spans = Ring(n * 130); inputs = Ring(n * 250); marks = Ring(max(256, n * 8))
        intervals = Ring(max(512, n * 40)); bodies = Ring(n * 5); mapSeconds = Ring(n + 4); vitals = Ring(n + 4)
        probes = Ring(max(20_000, n * 900))
        samples = Ring(max(600, n * ((0.1..<20).contains(UserDefaults.standard.double(forKey: "PerfSampleAfter")) ? 350 : 20)))
        busySince.pointee = 0
        mainThread = mach_thread_self()
        let me = pthread_self()
        mainStackHi = UInt(bitPattern: pthread_get_stackaddr_np(me))
        mainStackLo = mainStackHi - UInt(pthread_get_stacksize_np(me))
        Self.why = d.bool(forKey: "PerfWhy")

        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l

        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.entry.rawValue, true, CFIndex.min) { [busySince] _, _ in
            if busySince.pointee == 0 { busySince.pointee = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, CFIndex.max) { [weak self, busySince] _, _ in
            let t0 = busySince.pointee
            guard t0 != 0, let self else { return }
            busySince.pointee = 0
            let dur = CACurrentMediaTime() - t0
            if dur >= 0.004 { self.locked { self.spans.push(Span(t: t0, dur: Float(dur * 1000))) } }
        }
        for o in [wake, sleep].compactMap({ $0 }) { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes); observers.append(o) }

        Self.swizzleSendEventOnce()
        Self.hookMapViewOnce()
        #if DEBUG || PERFLOG
        hookLayerDrawsOnce()
        #endif
        let t = Thread { [weak self] in self?.watch() }
        t.name = "PerfRecorder.watchdog"; t.qualityOfService = .userInteractive
        watchdog = t; t.start()

        let name = "com.airpad.perf.save" as CFString
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { PerfRecorder.shared.save(reason: "harness", wholeBuffer: true) }
        }, name, nil, .deliverImmediately)
        installGesture()
        Self.on = true
        noteMark("recorder on")
        let current = locked { screenLabel }
        if !current.isEmpty { noteMark("screen: " + current) }   // the screen it was switched on at (iPhone: on after launch)
    }

    @MainActor func stop() {
        guard running else { return }
        Self.on = false; running = false
        link?.invalidate(); link = nil
        observers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }; observers = []
        watchdog?.cancel(); watchdog = nil
        if let g = gesture { g.view?.removeGestureRecognizer(g); gesture = nil }
    }

    private func locked<T>(_ body: () -> T) -> T { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return body() }

    // MARK: writers

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if lastTick > 0 { let f = Frame(t: now, dt: Float((now - lastTick) * 1000)); locked { frames.push(f) } }
        lastTick = now
        if now - bodyBucketStart >= 0.2 { flushBodies(now) }
    }
    private func flushBodies(_ now: Double) {
        locked {
            if !bodyBucket.isEmpty { bodies.push(Bodies(t: bodyBucketStart, counts: bodyBucket)); bodyBucket.removeAll(keepingCapacity: true) }
            bodyBucketStart = now
            if mapBucket.frames > 0, now - mapBucket.t >= 1 { mapSeconds.push(mapBucket); mapBucket = MapSecond(t: now, frames: 0, updateMs: 0, maxMs: 0) }
            else if mapBucket.frames == 0 { mapBucket.t = now }
        }
    }
    // MARK: which drawn layers were redrawn (bench + DEBUG builds only: it names a system class)

    /// One entry a second: how many times each of SwiftUI's drawn layers (text, shapes, symbols, shader fills) was
    /// redrawn, keyed by its rectangle in the window ("x,y w×h", points). A screen at rest should redraw none; a
    /// layer redrawn 60 times a second at rest is an animation that never stops, and its rectangle says where.
    private var drawBucket: [String: Int] = [:], drawBucketStart = 0.0
    private var draws: [(t: Double, counts: [String: Int])] = []
    #if DEBUG || PERFLOG
    private static var drawHooked = false
    private func hookLayerDrawsOnce() {
        guard !Self.drawHooked, let cls = NSClassFromString("RBLayer") else { return }
        let sel = NSSelectorFromString("display")
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        Self.drawHooked = true
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let block: @convention(block) (CALayer) -> Void = { layer in
            orig(layer, sel)
            PerfRecorder.shared.noteDraw(layer)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
    private func noteDraw(_ layer: CALayer) {
        guard running else { return }
        var root = layer; while let s = root.superlayer { root = s }
        let f = layer.convert(layer.bounds, to: root)
        let key = "\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))"
        let now = CACurrentMediaTime()
        locked {
            if now - drawBucketStart >= 1 {
                if !drawBucket.isEmpty { draws.append((drawBucketStart, drawBucket)); if draws.count > 4000 { draws.removeFirst(500) } }
                drawBucket.removeAll(keepingCapacity: true); drawBucketStart = now
            }
            drawBucket[key, default: 0] += 1
        }
    }
    #endif

    func noteBody(_ id: ObjectIdentifier, name: () -> String) {
        locked {
            bodyBucket[id, default: 0] += 1
            if bodyNames[id] == nil { bodyNames[id] = name() }
        }
    }
    func noteMark(_ name: String) { let m = Mark(t: CACurrentMediaTime(), name: name); locked { marks.push(m) } }
    func noteScreen(_ label: String) {
        let changed: Bool = locked { let c = screenLabel != label; screenLabel = label; return c }
        if changed { noteMark("screen: " + label) }
    }
    func noteInterval(_ name: StaticString, start: Double, end: Double) {
        guard end - start >= 0.001 else { return }
        let i = Interval(t: start, dur: Float((end - start) * 1000), name: name, main: Thread.isMainThread)
        locked { intervals.push(i) }
    }
    func noteMapFrame(_ updateMs: Double) {
        locked {
            mapBucket.frames += 1; mapBucket.updateMs += Float(updateMs); mapBucket.maxMs = max(mapBucket.maxMs, Float(updateMs))
        }
    }
    /// Every SKView that took a drawable while recording (weak), for the once-a-second "map views" mark.
    private var skViews = NSHashTable<SKView>.weakObjects()
    func noteSKView(_ v: SKView) { locked { if !skViews.contains(v) { skViews.add(v) } } }
    func knownSKViews() -> [SKView] { locked { skViews.allObjects } }
    func noteProbe(_ code: UInt8, _ v: Double, at t: Double = CACurrentMediaTime()) {
        let e = ProbeEvent(t: t, code: code, v: Float(v))
        locked { probes.push(e) }
    }
    fileprivate func noteInput(_ e: UIEvent) {
        var kind: UInt8 = 0, phase: UInt8 = 0
        switch e.type {
        case .touches:
            kind = 1
            let ps = e.allTouches?.map(\.phase) ?? []
            phase = ps.contains(.began) ? 1 : ps.contains(.ended) ? 3 : ps.contains(.cancelled) ? 4 : 2
        case .presses: kind = 2
            if let p = (e as? UIPressesEvent)?.allPresses.first { phase = p.phase == .began ? 1 : p.phase == .ended ? 3 : 2 }
        case .hover: kind = 3
        case .scroll: kind = 4
        case .transform: kind = 5
        default: kind = 9
        }
        let i = Input(t: e.timestamp, got: ProcessInfo.processInfo.systemUptime, kind: kind, phase: phase)
        locked { inputs.push(i) }
    }

    private static var swizzled = false
    private static func swizzleSendEventOnce() {
        guard !swizzled, let m = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))) else { return }
        swizzled = true
        typealias Fn = @convention(c) (UIApplication, Selector, UIEvent) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        let sel = #selector(UIApplication.sendEvent(_:))
        let block: @convention(block) (UIApplication, UIEvent) -> Void = { app, e in
            if PerfRecorder.on { PerfRecorder.shared.noteInput(e) }
            orig(app, sel, e)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    // MARK: Sweep 2b · 2.1 — the Map's frame delivery, seen from below the scene

    /// Every write of the SKView's rate and pause (the scene's own AND SwiftUI's SpriteView re-applying its settings),
    /// and the Map layer's drawables: how long `nextDrawable` blocked and when each one reached the screen
    /// (`addPresentedHandler`, public API). Installed once, when the recorder starts; each hook calls the original.
    private static var mapHooked = false
    private static func hookMapViewOnce() {
        guard !mapHooked else { return }
        mapHooked = true
        if let m = class_getInstanceMethod(SKView.self, #selector(setter: SKView.preferredFramesPerSecond)) {
            typealias Fn = @convention(c) (SKView, Selector, Int) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self), sel = #selector(setter: SKView.preferredFramesPerSecond)
            let block: @convention(block) (SKView, Int) -> Void = { v, fps in
                if PerfRecorder.on { PerfRecorder.shared.noteProbe(MapProbe.skvRateWrite.rawValue, Double(fps)) }
                orig(v, sel, fps)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(SKView.self, #selector(setter: SKView.isPaused)) {
            typealias Fn = @convention(c) (SKView, Selector, Bool) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self), sel = #selector(setter: SKView.isPaused)
            let block: @convention(block) (SKView, Bool) -> Void = { v, p in
                if PerfRecorder.on { PerfRecorder.shared.noteProbe(MapProbe.skvPauseWrite.rawValue, p ? 1 : 0) }
                orig(v, sel, p)
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
        if let m = class_getInstanceMethod(CAMetalLayer.self, #selector(CAMetalLayer.nextDrawable)) {
            typealias Fn = @convention(c) (CAMetalLayer, Selector) -> CAMetalDrawable?
            let orig = unsafeBitCast(method_getImplementation(m), to: Fn.self), sel = #selector(CAMetalLayer.nextDrawable)
            let block: @convention(block) (CAMetalLayer) -> CAMetalDrawable? = { layer in
                guard PerfRecorder.on, let skv = (layer.delegate as? SKView) ?? (layer.superlayer?.delegate as? SKView) else { return orig(layer, sel) }
                let vid = MapProbeID.of(skv)
                PerfRecorder.shared.noteSKView(skv)
                let t0 = CACurrentMediaTime()
                let d = orig(layer, sel)
                let t1 = CACurrentMediaTime()
                PerfRecorder.shared.noteProbe(MapProbe.drawableWait.rawValue, (t1 - t0) * 1000, at: t0)
                PerfRecorder.shared.noteProbe(MapProbe.drawableView.rawValue, vid + (Thread.isMainThread ? 100000 : 0), at: t0)
                #if !targetEnvironment(simulator)   // no presented handlers in the Simulator SDK
                d?.addPresentedHandler { dr in
                    // presentedTime is on the media clock; 0 = never shown (dropped).
                    let pt = dr.presentedTime, at = pt > 0 ? pt : CACurrentMediaTime()
                    PerfRecorder.shared.noteProbe(MapProbe.presented.rawValue, pt > 0 ? 1 : 0, at: at)
                    PerfRecorder.shared.noteProbe(MapProbe.presentedView.rawValue, vid + (pt > 0 ? 100000 : 0), at: at)
                }
                #endif
                return d
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    // MARK: the watchdog (its own thread): stack samples of a busy main thread, and the once-a-second vitals

    private func watch() {
        var buf = [UInt](repeating: 0, count: 96)
        var lastVital = 0.0, lastCPU = Self.cpuSeconds(), lastMainCPU = Self.threadSeconds(mainThread), lastSample = 0.0
        // `-PerfSampleAfter <ms>` (default 40): how long the main thread must have been busy before its stack is
        // sampled. 40 catches stalls; a profiling run sets ~5 to also see steady per-frame work (scrolling).
        let afterMs = UserDefaults.standard.double(forKey: "PerfSampleAfter")
        let after = afterMs > 0 ? afterMs / 1000 : 0.04
        let nap: useconds_t = after < 0.02 ? 1500 : 5000, gap = after < 0.02 ? 0.003 : 0.01
        while !Thread.current.isCancelled {
            usleep(nap)
            let now = CACurrentMediaTime()
            let since = busySince.pointee
            if since != 0, now - since > after, now - lastSample >= gap {
                lastSample = now
                let n = buf.withUnsafeMutableBufferPointer { Self.sampleStack(mainThread, lo: mainStackLo, hi: mainStackHi, into: $0) }
                if n > 0 { let s = Sample(t: now, busyFor: Float((now - since) * 1000), frames: Array(buf[0..<n])); locked { samples.push(s) } }
            }
            if now - lastVital >= 1 {
                let cpu = Self.cpuSeconds(), mcpu = Self.threadSeconds(mainThread), dt = lastVital == 0 ? 1 : now - lastVital
                let v = Vital(t: now, footprintMB: Float(Self.footprintMB()), cpuPct: Float((cpu - lastCPU) / dt * 100),
                              mainCpuPct: Float((mcpu - lastMainCPU) / dt * 100), thermal: Int8(ProcessInfo.processInfo.thermalState.rawValue),
                              lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                lastVital = now; lastCPU = cpu; lastMainCPU = mcpu
                locked { vitals.push(v) }
            }
        }
    }

    /// The main thread's return addresses, innermost first: suspend, read the registers, walk the frame pointers
    /// (each checked to lie inside the main thread's stack), resume. No allocation and no lock while it's suspended.
    private static func sampleStack(_ thread: thread_t, lo: UInt, hi: UInt, into out: UnsafeMutableBufferPointer<UInt>) -> Int {
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }
        var pc: UInt = 0, fp: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &count) } }
        guard kr == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__pc); fp = UInt(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, x86_THREAD_STATE64, $0, &count) } }
        guard kr == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__rip); fp = UInt(state.__rbp)
        #endif
        var n = 0
        out[n] = pc & 0x0000_007f_ffff_ffff; n += 1
        while n < out.count, fp >= lo, fp &+ 16 <= hi, fp & 0x7 == 0 {
            let p = UnsafePointer<UInt>(bitPattern: fp)!
            let next = p[0], ret = p[1] & 0x0000_007f_ffff_ffff
            if ret < 0x1000 { break }
            out[n] = ret; n += 1
            if next <= fp { break }
            fp = next
        }
        return n
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
    private static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    private static func threadSeconds(_ thread: thread_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) } }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    // MARK: triggers

    @MainActor private func installGesture() {
        guard !RunningOnMac.isMac, gesture == nil else { return }
        // The window may not exist yet at launch: try again shortly.
        guard let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in if self?.running == true { self?.installGesture() } }
            return
        }
        let g = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        g.numberOfTouchesRequired = 3; g.minimumPressDuration = 0.6; g.cancelsTouchesInView = false
        w.addGestureRecognizer(g); gesture = g
    }
    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        MainActor.assumeIsolated { _ = save(reason: "three-finger press") }
    }

    // MARK: save

    /// Writes the last `seconds` (or the whole buffer) and returns the file. Main thread.
    @MainActor @discardableResult func save(reason: String, wholeBuffer: Bool = false) -> URL? {
        guard running else { return nil }
        let now = CACurrentMediaTime()
        flushBodies(now)
        let from = wholeBuffer ? 0 : now - 15
        let snap = locked { (frames.ordered(), spans.ordered(), inputs.ordered(), marks.ordered(), intervals.ordered(), bodies.ordered(),
                             mapSeconds.ordered(), vitals.ordered(), samples.ordered(), bodyNames, screenLabel) }
        let (fr, sp, inp, mk, iv, bd, ms, vt, sm, names, screen) = snap
        // Uptime (input events) and media time (everything else) share the mach clock on Apple platforms; keep the
        // offset anyway, and the wall clock, so a harness can line its own steps up.
        let wallOffset = Date().timeIntervalSince1970 - now
        let uptimeOffset = ProcessInfo.processInfo.systemUptime - now
        func r(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }

        // Symbols: every distinct address once (dladdr: image + symbol), plus each image's load address for atos.
        var addrIndex: [UInt: Int] = [:], symbols: [[String: Any]] = [], images: [String: [String: String]] = [:]
        func index(_ a: UInt) -> Int {
            if let i = addrIndex[a] { return i }
            var info = Dl_info(); var entry: [String: Any] = ["a": String(a, radix: 16)]
            if dladdr(UnsafeRawPointer(bitPattern: a), &info) != 0 {
                if let f = info.dli_fname { let path = String(cString: f), img = (path as NSString).lastPathComponent; entry["i"] = img
                    if images[img] == nil { images[img] = ["base": String(UInt(bitPattern: info.dli_fbase), radix: 16), "path": path] } }
                if let s = info.dli_sname { entry["s"] = String(cString: s); entry["o"] = a - UInt(bitPattern: info.dli_saddr) }
            }
            symbols.append(entry); addrIndex[a] = symbols.count - 1; return symbols.count - 1
        }
        let sampleRows: [[String: Any]] = sm.filter { $0.t >= from }.map { ["t": r($0.t), "busy": Int($0.busyFor), "f": $0.frames.map(index)] }

        let screenSize = UIScreen.main.bounds.size
        let win = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let doc: [String: Any] = [
            "version": 1,
            "reason": reason,
            "saved": ISO8601DateFormatter().string(from: Date()),
            "now": r(now), "processStart": Self.processStartWall, "wallOffset": wallOffset, "uptimeOffset": uptimeOffset, "window": wholeBuffer ? seconds : 15,
            "screen": screen,
            "device": [
                "mac": RunningOnMac.isMac, "model": Self.sysctl("hw.model"), "machine": Self.sysctl("hw.machine"),
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "app": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")",
                "maxFPS": UIScreen.main.maximumFramesPerSecond, "scale": UIScreen.main.scale,
                "screenPt": [screenSize.width, screenSize.height], "windowPt": [win?.bounds.width ?? 0, win?.bounds.height ?? 0],
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                "cores": ProcessInfo.processInfo.activeProcessorCount, "debugBuild": Self.isDebug,
                "simulator": Self.isSimulator,
            ] as [String: Any],
            "frames": fr.filter { $0.t >= from }.map { [r($0.t), Double(($0.dt * 10).rounded() / 10)] },
            "spans": sp.filter { $0.t >= from }.map { [r($0.t), Double(($0.dur * 10).rounded() / 10)] },
            "inputs": inp.filter { $0.t - uptimeOffset >= from }.map { [r($0.t - uptimeOffset), r($0.got - uptimeOffset), Double($0.kind), Double($0.phase)] },
            "marks": mk.filter { $0.t >= from }.map { [r($0.t), $0.name] as [Any] },
            "intervals": iv.filter { $0.t >= from }.map { [r($0.t), Double(($0.dur * 10).rounded() / 10), "\($0.name)", $0.main] as [Any] },
            "bodies": bd.filter { $0.t >= from }.map { b in [r(b.t), Dictionary(uniqueKeysWithValues: b.counts.map { (names[$0.key] ?? "?", Int($0.value)) })] as [Any] },
            "map": ms.filter { $0.t >= from }.map { [r($0.t), Double($0.frames), Double($0.updateMs), Double($0.maxMs)] },
            "vitals": vt.filter { $0.t >= from }.map { [r($0.t), Double($0.footprintMB), Double($0.cpuPct), Double($0.mainCpuPct), Double($0.thermal), $0.lowPower ? 1 : 0] },
            "probe": locked { probes.ordered() }.filter { $0.t >= from }.map { [r($0.t), Double($0.code), Double(($0.v * 100).rounded() / 100)] },
            "samples": sampleRows, "symbols": symbols, "images": images,
            "draws": locked { draws + (drawBucket.isEmpty ? [] : [(drawBucketStart, drawBucket)]) }.filter { $0.t >= from }.map { [r($0.t), $0.counts] as [Any] },
            "why": Self.why ? Self.swiftUIChanges(since: wholeBuffer ? seconds : 15) : [],
        ]
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("PerfRecordings", isDirectory: true),
              let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let slug = screen.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { if !($1 == "-" && $0.hasSuffix("-")) { $0.append($1) } }
        let url = dir.appendingPathComponent("perf-\(f.string(from: Date()))-\(slug.prefix(40)).json")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        // Keep the newest 40 files.
        if let all = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }), all.count > 40 {
            all[40...].forEach { try? FileManager.default.removeItem(at: $0) }
        }
        lastSaved = url
        NSLog("[PerfRecorder] saved %@ (%@)", url.path, reason)
        NotificationCenter.default.post(name: Self.saveNotification, object: url)
        if reason != "harness" { showSavedNote(win) }
        return url
    }
    @MainActor var lastRecording: URL? { lastSaved }
    @MainActor static var recordings: [URL] {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("PerfRecordings") else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    @MainActor private func showSavedNote(_ window: UIWindow?) {
        guard let window else { return }
        let label = UILabel()
        label.text = "  Performance recording saved  "
        label.font = .systemFont(ofSize: 13, weight: .medium); label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.78); label.layer.cornerRadius = 14; label.layer.masksToBounds = true
        label.sizeToFit(); label.frame.size.height = 28
        label.center = CGPoint(x: window.bounds.midX, y: window.safeAreaInsets.top + 34)
        label.isUserInteractionEnabled = false
        window.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 1.4, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    /// SwiftUI's own "why did this body run" lines (`_logChanges`, subsystem com.apple.SwiftUI) from this process's log.
    private static func swiftUIChanges(since seconds: Double) -> [[Any]] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let pos = store.position(date: Date().addingTimeInterval(-seconds))
        guard let entries = try? store.getEntries(at: pos, matching: NSPredicate(format: "subsystem == %@", "com.apple.SwiftUI")) else { return [] }
        var out: [[Any]] = []
        for case let e as OSLogEntryLog in entries where e.category == "Changed Body Properties" {
            out.append([e.date.timeIntervalSince1970, e.composedMessage])
            if out.count >= 4000 { break }
        }
        return out
    }

    /// When this process started (wall clock), for launch → usable.
    private static let processStartWall: Double = {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard Darwin.sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }()
    private static func sysctl(_ name: String) -> String {
        var size = 0; sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size); sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
    private static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

/// Names the screen for a recording, as kinds and counts only: "Library · Map", "Collection · List",
/// "Entry (note 3 · 5,200 words; gallery 2 · 48 media; documents 1 · 3; links 5)". A leaf view, so the rest of the
/// window doesn't re-run when these change.
struct PerfScreenWatcher: View {
    let router: AppRouter
    let store: CorpusStore
    var body: some View {
        Color.clear
            .onChange(of: label, initial: true) { _, l in Perf.screen(l) }
    }
    private var label: String {
        if store.isInDetailView, let id = router.openEntryID, let n = store.nodes.first(where: { $0.id == id }) {
            var notes = 0, words = 0, galleries = 0, media = 0, docItems = 0, docs = 0, links = 0, other = 0
            for i in n.items {
                switch i.type {
                case .text: notes += 1; words += (i.content ?? "").split(separator: " ").count
                case .imageVideo, .image, .video: galleries += 1; media += i.mediaItems?.count ?? 1
                case .document: docItems += 1; docs += i.documentItems?.count ?? 1
                case .link: links += 1
                default: other += 1
                }
            }
            return "Entry (notes \(notes) · \(words) words; galleries \(galleries) · \(media) media; documents \(docItems) · \(docs); links \(links); other \(other))"
        }
        let place: String
        switch router.entryMode {
        case .dashboard: place = "Today"
        case .recents: place = "Recents"
        case .canvas: place = "Library"
        case .quikCapture: place = "Quick capture"
        case .collectionCanvas: place = "Collection"
        default: place = "Place"
        }
        guard place == "Library" || place == "Collection" || place == "Place" else { return place }
        let view: String
        switch store.filterState.viewMode {
        case .systemGraph, .userGraph: view = "Map"
        case .list: view = "List"
        case .grid: view = "Cards"
        case .timeline: view = "Timeline"
        }
        return "\(place) · \(view) · \(store.nodes.count) entries"
    }
}

/// The recorder's switch and buttons: Settings › About, after the taps on the version line (Mac: inside "Mac feel
/// (testing)"; iPhone: its own panel).
struct PerfRecorderPanel: View {
    @AppStorage(PerfRecorder.onKey) private var on = false
    @State private var last: URL?
    @State private var count = PerfRecorder.recordings.count

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance recorder (testing)").font(.system(size: 13, weight: .semibold)).foregroundStyle(AppearancePalette.ink)
            Toggle("Record while I use AirPad", isOn: Binding(get: { on }, set: { PerfRecorder.setEnabled($0) }))
                .accessibilityIdentifier("perfRecorderOn")
            Text(RunningOnMac.isMac
                 ? "When something feels slow, press ⌃⌥⌘P straight away. It saves the last 15 seconds: timings and view names only, nothing from your library."
                 : "When something feels slow, press and hold with three fingers straight away. It saves the last 15 seconds: timings and view names only, nothing from your library.")
                .font(.system(size: 11)).foregroundStyle(AppearancePalette.ink.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Save now") { last = PerfRecorder.shared.save(reason: "panel button"); count = PerfRecorder.recordings.count }
                    .disabled(!on).accessibilityIdentifier("perfRecorderSave")
                if let url = last ?? PerfRecorder.recordings.first {
                    ShareLink(item: url) { Text(RunningOnMac.isMac ? "Share last…" : "Send last…") }.accessibilityIdentifier("perfRecorderShare")
                }
                Text("\(count) saved").foregroundStyle(AppearancePalette.ink.opacity(0.45))
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .background(AppearancePalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("perfRecorderPanel")
        .onReceive(NotificationCenter.default.publisher(for: PerfRecorder.saveNotification)) { n in
            last = n.object as? URL; count = PerfRecorder.recordings.count
        }
    }
}

#endif
