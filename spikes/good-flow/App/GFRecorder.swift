// Good Flow spike (throwaway, never merged) · the frame recorder (design §3: the app's own numbers).
// Per frame: link timestamp, target timestamp, present time (drawable.addPresentedHandler), main-thread ms in the tick,
// command-buffer GPU ms, the wake that caused it ("input", "live", "oneshot:<why>"), the surface's name, the vsync.
// Per second (a background timer, never the main thread): thermal state, phys_footprint, process CPU %.
// Saved as JSON into the app's Documents (inside the container) by ⌃⌥⌘P on the Mac, or `GFRecorder.shared.save()`.
import Foundation
import QuartzCore
import UIKit
import Darwin

final class GFRecorder {
    static let shared = GFRecorder()

    struct Frame {
        var surface: String
        var wake: String
        var linkT: Double        // CADisplayLink.timestamp
        var targetT: Double      // CADisplayLink.targetTimestamp
        var vsync: Double        // the link's duration (s): one display refresh
        var rate: Double         // the link's preferred rate when this frame was asked for (30 / 60 live, the display's on input)
        var startT: Double       // tick start (CACurrentMediaTime)
        var mainMs: Double       // main thread in the tick (callback → commit)
        var gpuMs: Double = -1
        var presentT: Double = -1
        var px: Int = 0          // pixels drawn
        var waitMs: Double = 0   // of mainMs: the time nextDrawable() blocked (a locked screen stalls it; reported apart)
    }
    struct Sample { var t: Double; var thermal: Int; var footprintMB: Double; var cpuPct: Double; var lowPower: Bool }
    struct Mark { var t: Double; var what: String }
    /// A still drawn (step 3B): which, why, its GPU and main-thread cost. "Stills redrawn while moving" reads these.
    struct Still { var t: Double; var kind: String; var reason: String; var gpuMs: Double; var mainMs: Double; var px: Int }

    private let lock = NSLock()
    private var frames: [Frame] = []
    /// Bumped by reset(): a frame begun before a reset can still report its GPU / present time afterwards (Metal's
    /// completion queue). Its handle carries the generation, so a stale report is dropped instead of indexing past the end
    /// of the cleared list (the crash at T's touch, 2026-11-27: EXC_BREAKPOINT in the presented handler at a bench start).
    private var generation = 0
    private var samples: [Sample] = []
    private var marks: [Mark] = []
    private var stills: [Still] = []
    private var ticks: [(Double, String, Bool)] = []   // every link callback: time, surface, drew a frame
    private var timer: DispatchSourceTimer?
    private var lastCPU: (wall: Double, cpu: Double)?
    let t0 = CACurrentMediaTime()

    private init() {
        frames.reserveCapacity(100_000); startSampler()
        // Scripted Mac runs save with `notifyutil -p com.goodflow.save` (the trial's pattern; no key events needed).
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async { GFRecorder.shared.save(name: "scripted-" + GFRecorder.stamp(), meta: GFRecorder.extraMeta?() ?? [:]) }
        }, "com.goodflow.save" as CFString, nil, .deliverImmediately)
    }
    /// The screen adds what it knows (case, caches, live state) to every save.
    static var extraMeta: (() -> [String: Any])?
    static func stamp() -> String { let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"; return df.string(from: Date()) }

    // MARK: frames

    /// Begin a frame; returns its index for the GPU / present handlers.
    func begin(surface: String, wake: String, linkT: Double, targetT: Double, vsync: Double, rate: Double, startT: Double, px: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        frames.append(Frame(surface: surface, wake: wake, linkT: linkT, targetT: targetT, vsync: vsync, rate: rate, startT: startT, mainMs: -1, px: px))
        return (generation << 32) | (frames.count - 1)
    }
    /// The live index for a handle from begin(), or nil if a reset came between.
    private func slot(_ h: Int) -> Int? {
        let i = h & 0xFFFF_FFFF
        return (h >> 32) == generation && i < frames.count ? i : nil
    }
    /// Every display-link callback, drawn or not ("0 ticks at rest" is read from these).
    func tick(surface: String, at t: Double, drew: Bool) { lock.lock(); ticks.append((t, surface, drew)); lock.unlock() }
    func setMain(_ h: Int, _ ms: Double) { lock.lock(); if let i = slot(h) { frames[i].mainMs = ms }; lock.unlock() }
    func setGPU(_ h: Int, _ ms: Double) { lock.lock(); if let i = slot(h) { frames[i].gpuMs = ms }; lock.unlock() }
    func setWait(_ h: Int, _ ms: Double) { lock.lock(); if let i = slot(h) { frames[i].waitMs = ms }; lock.unlock() }
    func setPresent(_ h: Int, _ t: Double) { lock.lock(); if let i = slot(h) { frames[i].presentT = t }; lock.unlock() }
    /// Input events and other moments (part B marks gesture begin / end, live on / off…).
    func mark(_ what: String, at t: Double = CACurrentMediaTime()) { lock.lock(); marks.append(Mark(t: t, what: what)); lock.unlock() }
    func still(kind: String, reason: String, gpuMs: Double, mainMs: Double, px: Int, at t: Double = CACurrentMediaTime()) {
        lock.lock(); stills.append(Still(t: t, kind: kind, reason: reason, gpuMs: gpuMs, mainMs: mainMs, px: px)); lock.unlock()
    }
    func reset() { lock.lock(); generation += 1; frames.removeAll(keepingCapacity: true); samples.removeAll(); marks.removeAll(); ticks.removeAll(); stills.removeAll(); lock.unlock() }
    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    // MARK: 1 Hz samples

    private func startSampler() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "gf.recorder.sampler", qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume(); timer = t
    }
    private func sample() {
        let now = CACurrentMediaTime(), cpu = Self.processCPUSeconds()
        var pct = -1.0
        if let l = lastCPU, now > l.wall { pct = (cpu - l.cpu) / (now - l.wall) * 100 }
        lastCPU = (now, cpu)
        let s = Sample(t: now, thermal: ProcessInfo.processInfo.thermalState.rawValue, footprintMB: Self.physFootprintMB(),
                       cpuPct: pct, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        lock.lock(); samples.append(s); lock.unlock()
    }
    static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    static func processCPUSeconds() -> Double {
        var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6 + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    // MARK: save

    /// Writes the recording to Documents/recordings/<name or timestamp>.json and returns its URL.
    @discardableResult
    func save(name: String? = nil, meta: [String: Any] = [:]) -> URL? {
        lock.lock(); let fr = frames, sa = samples, mk = marks, tk = ticks, st = stills; lock.unlock()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = docs.appendingPathComponent((name ?? "rec-" + df.string(from: Date())) + ".json")
        let screen = UIScreen.main
        var m: [String: Any] = ["t0": t0, "savedT": CACurrentMediaTime(), "maxFPS": screen.maximumFramesPerSecond,
                                "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
                                "macCatalyst": ProcessInfo.processInfo.isMacCatalystApp]
        m["settings"] = GFSettings.shared.dict
        m.merge(meta) { $1 }
        let obj: [String: Any] = [
            "meta": m,
            "frames": fr.map { ["surface": $0.surface, "wake": $0.wake, "linkT": $0.linkT, "targetT": $0.targetT, "vsync": $0.vsync, "rate": $0.rate,
                                "startT": $0.startT, "mainMs": $0.mainMs, "gpuMs": $0.gpuMs, "presentT": $0.presentT, "px": $0.px, "waitMs": $0.waitMs] },
            "samples": sa.map { ["t": $0.t, "thermal": $0.thermal, "footprintMB": $0.footprintMB, "cpuPct": $0.cpuPct, "lowPower": $0.lowPower] },
            "marks": mk.map { ["t": $0.t, "what": $0.what] },
            "ticks": tk.map { ["t": $0.0, "surface": $0.1, "drew": $0.2] },
            "stills": st.map { ["t": $0.t, "kind": $0.kind, "reason": $0.reason, "gpuMs": $0.gpuMs, "mainMs": $0.mainMs, "px": $0.px] },
        ]
        do {
            try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
            NSLog("GF recorder: \(fr.count) frames, \(sa.count) samples → \(url.path)")
            return url
        } catch { NSLog("GF recorder save failed: \(error)"); return nil }
    }
}

/// The UIKit screens' own cadence while they move (cases a and b): a display link that runs only while input is recent
/// (0.4 s, the rest rule's input wake) and records each callback as a "host" frame. A late callback is a frame the main
/// thread missed; the screen's Metal layers record their own frames beside it. At rest it is paused: 0 ticks.
final class GFHostLink {
    private var link: CADisplayLink?
    private var lastInput = -1.0
    private final class Proxy: NSObject { weak var o: GFHostLink?; @objc func step(_ l: CADisplayLink) { o?.tick(l) } }
    private let proxy = Proxy()
    init() { proxy.o = self }
    deinit { link?.invalidate() }
    func stop() { link?.invalidate(); link = nil }
    func noteInput() {
        lastInput = CACurrentMediaTime()
        if link == nil {
            let l = CADisplayLink(target: proxy, selector: #selector(Proxy.step(_:)))
            let maxFPS = Float(UIScreen.main.maximumFramesPerSecond)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maxFPS), maximum: maxFPS, preferred: maxFPS)
            l.add(to: .main, forMode: .common); link = l
        }
        link?.isPaused = false
    }
    private func tick(_ l: CADisplayLink) {
        let t0 = CACurrentMediaTime()
        guard t0 - lastInput < 0.4 else { GFRecorder.shared.tick(surface: "host", at: t0, drew: false); l.isPaused = true; return }
        GFRecorder.shared.tick(surface: "host", at: t0, drew: true)
        let i = GFRecorder.shared.begin(surface: "host", wake: "input", linkT: l.timestamp, targetT: l.targetTimestamp, vsync: l.duration,
                                        rate: Double(l.preferredFrameRateRange.preferred ?? 0), startT: t0, px: 0)
        GFRecorder.shared.setMain(i, (CACurrentMediaTime() - t0) * 1000)
    }
}
