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
    }
    struct Sample { var t: Double; var thermal: Int; var footprintMB: Double; var cpuPct: Double; var lowPower: Bool }
    struct Mark { var t: Double; var what: String }

    private let lock = NSLock()
    private var frames: [Frame] = []
    private var samples: [Sample] = []
    private var marks: [Mark] = []
    private var ticks: [(Double, String, Bool)] = []   // every link callback: time, surface, drew a frame
    private var timer: DispatchSourceTimer?
    private var lastCPU: (wall: Double, cpu: Double)?
    let t0 = CACurrentMediaTime()

    private init() { frames.reserveCapacity(100_000); startSampler() }

    // MARK: frames

    /// Begin a frame; returns its index for the GPU / present handlers.
    func begin(surface: String, wake: String, linkT: Double, targetT: Double, vsync: Double, rate: Double, startT: Double, px: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        frames.append(Frame(surface: surface, wake: wake, linkT: linkT, targetT: targetT, vsync: vsync, rate: rate, startT: startT, mainMs: -1, px: px))
        return frames.count - 1
    }
    /// Every display-link callback, drawn or not ("0 ticks at rest" is read from these).
    func tick(surface: String, at t: Double, drew: Bool) { lock.lock(); ticks.append((t, surface, drew)); lock.unlock() }
    func setMain(_ i: Int, _ ms: Double) { lock.lock(); frames[i].mainMs = ms; lock.unlock() }
    func setGPU(_ i: Int, _ ms: Double) { lock.lock(); frames[i].gpuMs = ms; lock.unlock() }
    func setPresent(_ i: Int, _ t: Double) { lock.lock(); frames[i].presentT = t; lock.unlock() }
    /// Input events and other moments (part B marks gesture begin / end, live on / off…).
    func mark(_ what: String, at t: Double = CACurrentMediaTime()) { lock.lock(); marks.append(Mark(t: t, what: what)); lock.unlock() }
    func reset() { lock.lock(); frames.removeAll(keepingCapacity: true); samples.removeAll(); marks.removeAll(); ticks.removeAll(); lock.unlock() }
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
        lock.lock(); let fr = frames, sa = samples, mk = marks, tk = ticks; lock.unlock()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let url = docs.appendingPathComponent((name ?? "rec-" + df.string(from: Date())) + ".json")
        let screen = UIScreen.main
        var m: [String: Any] = ["t0": t0, "savedT": CACurrentMediaTime(), "maxFPS": screen.maximumFramesPerSecond,
                                "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
                                "macCatalyst": ProcessInfo.processInfo.isMacCatalystApp]
        m.merge(meta) { $1 }
        let obj: [String: Any] = [
            "meta": m,
            "frames": fr.map { ["surface": $0.surface, "wake": $0.wake, "linkT": $0.linkT, "targetT": $0.targetT, "vsync": $0.vsync, "rate": $0.rate,
                                "startT": $0.startT, "mainMs": $0.mainMs, "gpuMs": $0.gpuMs, "presentT": $0.presentT, "px": $0.px] },
            "samples": sa.map { ["t": $0.t, "thermal": $0.thermal, "footprintMB": $0.footprintMB, "cpuPct": $0.cpuPct, "lowPower": $0.lowPower] },
            "marks": mk.map { ["t": $0.t, "what": $0.what] },
            "ticks": tk.map { ["t": $0.0, "surface": $0.1, "drew": $0.2] },
        ]
        do {
            try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(to: url)
            NSLog("GF recorder: \(fr.count) frames, \(sa.count) samples → \(url.path)")
            return url
        } catch { NSLog("GF recorder save failed: \(error)"); return nil }
    }
}
