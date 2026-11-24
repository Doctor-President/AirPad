import Foundation

/// 1.1-C (C8) — the Map's panning rate on a 120 Hz iPhone: 120 only while the frames keep up, else a steady 60.
///
/// SpriteKit doesn't hand the app its GPU timings, so the proof of headroom is the frames themselves: at 120 a frame
/// that lands more than 1.5 vsyncs (12.5 ms) after the last one missed its slot, whether the GPU or the main thread
/// was late. A missed 120 judders worse than a steady 60, so:
/// - **Down fast:** 3 misses in the last 24 frames at 120 (0.2 s) → 60, at once, even mid-pan.
/// - **Up slowly:** back to 120 only when a new gesture starts (never mid-motion, so the cadence never flips under the
///   finger) and only after a hold that grows with each failure (4 s → 15 s → 60 s); a gesture that holds 120 to its
///   end resets the hold.
/// - **Per regime:** the Gravity wells cost most of the GPU and draw only zoomed in, so "wells drawing" and "not" keep
///   separate verdicts; a failure zoomed in doesn't keep the overview at 60.
/// Low Power, thermal ≥ .serious (`MapHeatGuard.stressed`) and the 8 fps idle stay as they were (the scene decides
/// those before asking here).
///
/// One-line revert: remove `CADisableMinimumFrameDurationOnPhone` from project.yml (the system then caps at 60), or
/// set `enabled` to false.
struct MapAdaptiveRate {
    #if DEBUG || PANBENCH
    /// `-MapRate60 YES`: the A/B baseline, a fixed 60 while panning (the bench's "60" column).
    static let enabled = !UserDefaults.standard.bool(forKey: "MapRate60")
    #else
    static let enabled = true
    #endif
    static let fast = 120, steady = 60

    static let missInterval: TimeInterval = 1.5 / 120   // 12.5 ms
    #if targetEnvironment(macCatalyst)
    /// Mac sweep 1 · 1.1 (measured, T's "Map definitely not 120"): on the Mac a stray late frame (a 16.7 ms gap now and
    /// then, from the window's other work) is normal, and 3 in 24 demoted the Map to 60 for 4–60 s on every pan; at 60
    /// on a 120 Hz display it then alternated 16.7 / 25 ms gaps ≈ 42–45 fps (recorder, 284-entry library, every look).
    /// Held at 120 the same pans ran at a median 8.3 ms (Map 42 → 75 fps). So the Mac demotes only on SUSTAINED misses:
    /// a quarter of the frames late over half a second (a Mac whose GPU really can't keep 120 still gets the steady 60).
    static let window = 60
    static let missesToDrop = 15
    #else
    static let window = 24
    static let missesToDrop = 3
    #endif
    static let holds: [TimeInterval] = [4, 15, 60]
    /// Frames ignored after the rate changes (the display settles into the new cadence).
    static let settleFrames = 3

    struct Regime {
        var holdUntil: TimeInterval = 0
        var failures = 0
        var demoted = false
    }
    private(set) var regimes = [Regime(), Regime()]   // [wells not drawing, wells drawing]
    private var recent: [Bool] = []                   // miss flags for the last `window` frames at 120
    private var settle = 0
    private var lastTime: TimeInterval = 0
    private var gestureActive = false
    /// Sweep 2b · 2.1: starts at `steady` when the controller is off (bench `-MapRate60 YES`: the Map is held at 60 — before,
    /// `rate` stayed at its initial 120 and the switch did nothing).
    private(set) var rate = enabled ? fast : steady
    /// The last few decisions (for the bench report): (time, rate, regime).
    private(set) var switches: [(t: TimeInterval, rate: Int, regime: Int)] = []

    /// Call once per rendered frame while the Map is active (panning, coasting, zooming).
    /// `regime`: 1 while the wells draw, else 0. `gestureStart`: true on the first active frame after rest / a touch-down.
    mutating func frame(at t: TimeInterval, regime: Int, gestureStart: Bool) -> Int {
        guard Self.enabled else { return Self.steady }
        #if PERFLOG
        if perfAB("map120") { return Self.fast }   // sweep 1 · 1.1 bench A/B: never demote
        #endif
        let r = max(0, min(1, regime))
        if gestureStart || !gestureActive {
            gestureActive = true
            // A new gesture: a demoted regime may try 120 again once its hold is over.
            if regimes[r].demoted && t >= regimes[r].holdUntil { regimes[r].demoted = false }
            lastTime = 0
            settle = Self.settleFrames   // waking from the idle rate: the first intervals are the display catching up
        }
        let want = regimes[r].demoted ? Self.steady : Self.fast
        if want != rate { setRate(want, at: t, regime: r) }
        if rate == Self.fast {
            if lastTime > 0 {
                let dt = t - lastTime
                if settle > 0 { settle -= 1 } else {
                    #if PERFLOG
                    recentDT.append(dt); if recentDT.count > Self.window { recentDT.removeFirst() }
                    #endif
                    recent.append(dt > Self.missInterval)
                    if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
                    if recent.filter({ $0 }).count >= Self.missesToDrop { demote(r, at: t) }
                }
            }
        }
        lastTime = t
        return rate
    }

    /// Call when the Map goes back to rest (the idle rate takes over). A gesture that kept 120 to its end clears the
    /// regime's failure count.
    mutating func gestureEnded(regime: Int) {
        guard gestureActive else { return }
        gestureActive = false
        let r = max(0, min(1, regime))
        if rate == Self.fast && !regimes[r].demoted { regimes[r].failures = 0 }
        recent.removeAll()
        lastTime = 0
    }

    #if PERFLOG
    private var recentDT: [TimeInterval] = []
    #endif

    private mutating func demote(_ r: Int, at t: TimeInterval) {
        #if PERFLOG
        let gaps = recentDT.map { String(format: "%.1f", $0 * 1000) }.joined(separator: " ")
        Perf.mark("map rate 120→60 regime \(r) gaps(ms) \(gaps)")
        recentDT.removeAll()
        #endif
        let hold = Self.holds[min(regimes[r].failures, Self.holds.count - 1)]
        regimes[r].failures += 1
        regimes[r].demoted = true
        regimes[r].holdUntil = t + hold
        setRate(Self.steady, at: t, regime: r)
    }

    private mutating func setRate(_ v: Int, at t: TimeInterval, regime: Int) {
        rate = v
        recent.removeAll()
        settle = Self.settleFrames
        switches.append((t, v, regime))
        if switches.count > 64 { switches.removeFirst(switches.count - 64) }
    }
}

/// Sweep 2b · 2.1 — the Mac Map's frame pacer, pure (no view, so a self-test drives it with tick times): the SKView runs
/// at the display rate and the Map draws every `every`-th display tick (1 = 120, 2 = a clean 60, 4 = 30, 15 = 8 on a
/// 120 Hz display) — counted, never timed.
/// Step 5 fix-up (verifier finding 3) — the step is keyed to the tick rate MEASURED from the ticks themselves, not to the
/// launch-time `UIScreen.main` rate: a window on a 60 Hz display while the launch-time screen said 120 (a ProMotion
/// MacBook with an external display) drew an asked 60 as every 2nd tick = 30 fps, 8 as 4. Until a second of ticks has
/// been seen (and whenever the ticks can't be read) the launch-time rate stands, so the built-in 120 Hz display steps
/// exactly as before. The lower quartile of the recent gaps: a late tick (a busy main thread) only lengthens a gap, so it
/// never re-keys a 120 Hz display to 60.
struct MapTickPacer {
    private(set) var every = 1
    private var count = 0
    private var asked = 120
    /// The display's tick rate the step is keyed to (Hz).
    private(set) var tickHz: Int
    private var lastTick: TimeInterval?
    private var gaps: [Double] = []
    private static let gapWindow = 32, minGaps = 16

    init(launchHz: Int) { tickHz = launchHz }

    /// A new asked rate (fps); true when the step changed.
    mutating func ask(_ fps: Int) -> Bool {
        asked = fps
        return restep()
    }

    private mutating func restep() -> Bool {
        let e = max(1, Int((Double(tickHz) / Double(max(asked, 1))).rounded()))
        guard e != every else { return false }
        every = e
        return true
    }

    /// One display tick at `time` (s): draw it?
    mutating func tick(at time: TimeInterval) -> Bool {
        if let last = lastTick {
            let g = time - last
            if g > 0.002 && g < 0.05 {   // a pause (the Map at rest) or a clock step is not a tick gap
                gaps.append(g)
                if gaps.count > Self.gapWindow { gaps.removeFirst() }
            }
        }
        lastTick = time
        if gaps.count >= Self.minGaps {
            let hz = Int((1 / gaps.sorted()[gaps.count / 4]).rounded())
            if abs(hz - tickHz) > max(4, tickHz / 10) { tickHz = hz; _ = restep() }   // ±10 %: jitter never re-keys
        }
        count &+= 1
        return every <= 1 || count % every == 0
    }

    /// The rate the Map is drawn at now.
    var askedFPS: Int { tickHz / max(every, 1) }
}
