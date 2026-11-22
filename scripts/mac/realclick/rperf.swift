// rperf — a scripted "normal use" session with REAL events (Mac E fix-up 4, K3): each step posts real input (CGEvent at
// the window server), and a ScreenCaptureKit stream over the whole window (≤ 120 fps, scaled down) times what the user
// sees: input → the first frame that differs (VISIBLE), → the last frame that still changes before 400 ms of stillness
// (SETTLED, capped at the step's timeout). Scroll and drag steps also report the frame intervals while they run (a
// 120 Hz display draws every 8.3 ms). Runs on Release (no hooks). Needs Accessibility + Screen Recording.
//   rperf <pid> <steps file>      → one line per step, then per-label p50/p95 and a CSV (RPERF_CSV=path)
// Steps file, one per line (# comments):  <label> <verb> <args…>
//   click <ax-id>[#n]        pointer onto it, 120 ms, press (n-th match); <ax-id> may be role:<AXRole>, placeholder:<text>,
//                            or an id prefix ending in *
//                            [cmd|shift] after the target holds that modifier (a real key down … up around the click);
//                            <ax-id>@dx,dy = that point from the element's top-left instead of its centre (sweep 2b · 2.2)
//   rclick <ax-id>[#n]       right-click (opens a context menu)
//   dclick <ax-id>[#n]       double-click (click count 1 then 2)
//   key <code> | cmdkey <code> | esc
//   type <text>              letters and spaces, one key each (each key is its own measured step)
//   scroll <ax-id|x,y> <dy> <events> [ms]   a trackpad two-finger swipe (continuous, phases)
//   drag <ax-id|x,y> <dx> <dy> <steps>     press, move, release
//   trackpad <ax-id|x,y> <seconds> [hold] [wobble] [nomomentum]   sweep 2b 0.3: what a HAND posts — may-begin, both axes
//                            with fractional deltas, jittered ~120 Hz spacing with bursts, curved paths and reversals,
//                            [hold] fingers still 0.6–1.5 s mid-swipe, momentum after lift, a re-swipe during momentum,
//                            [wobble] the pointer drifting a few points — repeated for <seconds>
//   wait <ms>                not measured
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]), let script = try? String(contentsOfFile: args[2], encoding: .utf8) else {
    print("usage: rperf <pid> <steps>"); exit(2)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = a(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = a(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func find(_ key: String, _ n: Int = 0) -> AXUIElement? {
    var out: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        if out.count > n { return }
        let id = a(e, "AXIdentifier") as? String ?? ""
        let title = (a(e, kAXTitleAttribute) as? String) ?? (a(e, kAXDescriptionAttribute) as? String) ?? ""
        let hit: Bool
        if key.hasPrefix("role:") { hit = (a(e, kAXRoleAttribute) as? String) == String(key.dropFirst(5)) }
        else if key.hasPrefix("placeholder:") { hit = (a(e, kAXPlaceholderValueAttribute) as? String) == String(key.dropFirst(12)) }
        else { hit = id == key || title == key || (key.hasSuffix("*") && id.hasPrefix(key.dropLast())) }
        if hit { out.append(e) }
        guard d < 40, let kids = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
        kids.forEach { walk($0, d + 1) }
    }
    ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).forEach { walk($0, 0) }
    return out.count > n ? out[n] : nil
}
func point(_ spec: String) -> CGPoint? {
    if let at = spec.firstIndex(of: "@") {   // sweep 2b · 2.2: <ax-id>@dx,dy — offset from the element's top-left
        let o = spec[spec.index(after: at)...].split(separator: ",").compactMap { Double($0) }
        let parts = spec[..<at].split(separator: "#"); let n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        guard o.count == 2, let e = find(String(parts[0]), n) else { return nil }
        let f = frame(e); return CGPoint(x: f.minX + o[0], y: f.minY + o[1])
    }
    let p = spec.split(separator: ",").compactMap { Double($0) }
    if p.count == 2 { return CGPoint(x: p[0], y: p[1]) }
    let parts = spec.split(separator: "#"); let n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    guard let e = find(String(parts[0]), n) else { return nil }
    let f = frame(e); return CGPoint(x: f.midX, y: f.midY)
}
func mouse(_ t: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1, flags: CGEventFlags = []) {
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: button)
    if t != .mouseMoved { e?.setIntegerValueField(.mouseEventClickState, value: clicks) }
    if !flags.isEmpty { e?.flags = flags }
    e?.post(tap: .cghidEventTap)
}
/// Sweep 2b · 2.2 — a modifier key really held: its key-down before, its key-up after (55 ⌘, 56 ⇧; see key()).
func holding(_ mod: String?, _ act: (CGEventFlags) -> Void) {
    let code: CGKeyCode, flag: CGEventFlags
    switch mod {
    case "cmd": (code, flag) = (55, .maskCommand)
    case "shift": (code, flag) = (56, .maskShift)
    default: act([]); return
    }
    let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true); d?.flags = flag; d?.post(tap: .cghidEventTap); usleep(30_000)
    act(flag)
    usleep(30_000); let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false); u?.flags = []; u?.post(tap: .cghidEventTap); usleep(20_000)
}
func key(_ code: CGKeyCode, cmd: Bool = false) {
    // A real ⌘ down … up around a ⌘-key (only flagging the key left the system's ⌘ state DOWN; see rclick cmdkey).
    if cmd { let c = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true); c?.flags = .maskCommand; c?.post(tap: .cghidEventTap); usleep(20_000) }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = cmd ? .maskCommand : []
        e?.post(tap: .cghidEventTap); usleep(30_000)
    }
    if cmd { let c = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: false); c?.flags = []; c?.post(tap: .cghidEventTap); usleep(20_000) }
}
func scroll(_ p: CGPoint, _ dy: Int32, phase: Int64, momentum: Int64 = 0) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
    e.location = p
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
    e.post(tap: .cghidEventTap)
}
let keycodes: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46, " ": 49]
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func now() -> Double { Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) / 1e6 }

final class Sink: NSObject, SCStreamOutput {
    let lock = NSLock()
    var frames: [(Double, [UInt8])] = []
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let t = (info[.displayTime] as? UInt64).map { Double($0) * Double(tb.numer) / Double(tb.denom) / 1e6 } ?? 0
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
        let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
        var g = [UInt8](); g.reserveCapacity(w * h)
        for y in 0..<h { for x in 0..<w { let o = y * row + x * 4; g.append(UInt8((Int(base[o]) + Int(base[o + 1]) + Int(base[o + 2])) / 3)) } }
        lock.lock(); frames.append((t, g)); if frames.count > 2000 { frames.removeFirst(500) }; lock.unlock()
    }
    func snapshot() -> [(Double, [UInt8])] { lock.lock(); defer { lock.unlock() }; return frames }
    func last() -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return frames.last?.1 }
    func clear() { lock.lock(); if let l = frames.last { frames = [l] }; lock.unlock() }
}
/// Share of pixels that differ by more than 6 grey levels.
func diff(_ x: [UInt8], _ y: [UInt8]) -> Double {
    guard x.count == y.count, !x.isEmpty else { return 1 }
    var c = 0
    for i in 0..<x.count where abs(Int(x[i]) - Int(y[i])) > 6 { c += 1 }
    return Double(c) / Double(x.count)
}

NSRunningApplication(processIdentifier: pid)?.activate()
usleep(600_000)
guard let win = ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first else { print("no window"); exit(1) }
let winRect = frame(win)
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let display = content.displays.first(where: { $0.frame.contains(winRect.origin) }) ?? content.displays.first else { exit(1) }
let cfg = SCStreamConfiguration()
cfg.sourceRect = winRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
cfg.width = Int(winRect.width / 3); cfg.height = Int(winRect.height / 3)
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
cfg.queueDepth = 8
cfg.showsCursor = false
let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
let sink = Sink()
try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
try await stream.startCapture()
usleep(600_000)

struct Row { let label: String; let verb: String; let visible: Double?; let settled: Double?; let frames: Int; let ivP50: Double?; let ivP95: Double? }
var rows: [Row] = []
let still = 400.0, threshold = 0.003, visibleThreshold = 0.0012
func pct(_ v: [Double], _ p: Double) -> Double? { let s = v.sorted(); return s.isEmpty ? nil : s[min(s.count - 1, max(0, Int((Double(s.count) * p).rounded(.up)) - 1))] }

/// Sweep 2b (0.3) — a two-axis continuous scroll event with fractional deltas, as a real trackpad sends them.
func scroll2(_ p: CGPoint, _ dx: Double, _ dy: Double, phase: Int64, momentum: Int64 = 0) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
    e.location = p
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded()))
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
    e.post(tap: .cghidEventTap)
}
var tpSeed: UInt64 = 0x9E3779B97F4A7C15
func tpRnd() -> Double { tpSeed = tpSeed &* 6364136223846793005 &+ 1442695040888963407; return Double((tpSeed >> 33) % 1_000_000) / 1_000_000 }
/// One hand session on the trackpad for `seconds`: swipes of 0.4–1.2 s along curved paths (some reversing without
/// lifting), optional mid-swipe holds, momentum after each lift (every other one interrupted by the next swipe).
func trackpadSession(_ p: CGPoint, seconds: Double, hold: Bool, wobble: Bool, momentum: Bool) {
    let end = Date().addingTimeInterval(seconds)
    var swipe = 0
    func gap() { usleep(useconds_t((tpRnd() < 0.12 ? 0.8 : 6.0 + tpRnd() * 5.0) * 1000)) }   // ~120 Hz, jitter, bursts
    var ptr = p
    while Date() < end {
        swipe += 1
        let ang = tpRnd() * 2 * .pi, speed = 6 + tpRnd() * 22, curve = (tpRnd() - 0.5) * 0.08
        let n = 40 + Int(tpRnd() * 100), reverseAt = tpRnd() < 0.3 ? n / 2 : -1, holdAt = hold && swipe % 2 == 1 ? n / 3 : -1
        scroll2(ptr, 0, 0, phase: 128); usleep(25_000)
        var a = ang, dir = 1.0, vx = 0.0, vy = 0.0
        for i in 0..<n {
            if i == reverseAt { dir = -dir }
            if i == holdAt { usleep(useconds_t((600 + tpRnd() * 900) * 1000)) }
            a += curve
            let env = min(1, Double(i + 1) / 8) * min(1, Double(n - i) / 10 + 0.3)
            vx = cos(a) * speed * env * dir + (tpRnd() - 0.5) * 0.6
            vy = sin(a) * speed * env * dir + (tpRnd() - 0.5) * 0.6
            scroll2(ptr, vx, vy, phase: i == 0 ? 1 : 2)
            if wobble && i % 4 == 3 { ptr = CGPoint(x: p.x + (tpRnd() - 0.5) * 6, y: p.y + (tpRnd() - 0.5) * 6); mouse(.mouseMoved, ptr) }
            gap()
        }
        scroll2(ptr, 0, 0, phase: 4); usleep(8_000)
        if momentum {
            let interrupt = swipe % 2 == 0
            scroll2(ptr, vx, vy, phase: 0, momentum: 1); usleep(8_300)
            var k = 0
            while abs(vx) + abs(vy) > 0.4 {
                vx *= 0.965; vy *= 0.965; k += 1
                scroll2(ptr, vx, vy, phase: 0, momentum: 2); usleep(8_300)
                if interrupt && k == 45 { break }
            }
            scroll2(ptr, 0, 0, phase: 0, momentum: 3)
        }
        usleep(useconds_t((40 + tpRnd() * 160) * 1000))
    }
}
/// Measures one input: `act` posts it and returns when the input has ended (mouse-up / key-up / last scroll event).
func measure(_ label: String, _ verb: String, timeout: Double = 3000, intervals: Bool = false, _ act: () -> Void) {
    usleep(150_000)
    guard let before = sink.last() else { print("no frames"); return }
    sink.clear()
    let t0 = now(), wall = Date().timeIntervalSince1970 * 1000
    act()
    let tIn = now()
    // Wait until the window has been still for `still` ms (or the timeout).
    var lastChange = tIn
    while now() - tIn < timeout {
        usleep(20_000)
        let fr = sink.snapshot()
        if let l = fr.last, l.0 > lastChange { lastChange = l.0 }
        if now() - lastChange > still { break }
    }
    let fr = sink.snapshot().filter { $0.0 > t0 }
    var visible: Double?, settled: Double?, prev = before
    for (t, g) in fr {
        if t >= tIn, visible == nil, diff(g, before) > visibleThreshold { visible = t - tIn }
        if diff(g, prev) > threshold { settled = t - tIn }
        prev = g
    }
    if ProcessInfo.processInfo.environment["RPERF_TRACE"] != nil {
        var pv = before
        print("  trace " + fr.map { f in defer { pv = f.1 }; return String(format: "%.0f:%.4f/%.4f", f.0 - tIn, diff(f.1, before), diff(f.1, pv)) }.joined(separator: " "))
    }
    var iv: [Double] = []
    if intervals { let ts = fr.map(\.0).filter { $0 >= t0 && $0 <= tIn + 50 }; iv = zip(ts.dropFirst(), ts).map { $0 - $1 } }
    let r = Row(label: label, verb: verb, visible: visible, settled: settled.map { max($0, 0) }, frames: fr.count,
                ivP50: pct(iv, 0.5), ivP95: pct(iv, 0.95))
    rows.append(r)
    func f(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "-" }
    print("\(label) \(verb) visible \(f(r.visible)) settled \(f(r.settled)) frames \(r.frames) at \(String(format: "%.0f", wall))"
          + (intervals ? " · interval p50 \(r.ivP50.map { String(format: "%.1f", $0) } ?? "-") p95 \(r.ivP95.map { String(format: "%.1f", $0) } ?? "-") ms (\(iv.count))" : ""))
}

for raw in script.split(separator: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") { continue }
    let w = line.split(separator: " ").map(String.init)
    guard w.count >= 2 else { continue }
    let label = w[0], verb = w[1], rest = Array(w.dropFirst(2))
    switch verb {
    case "wait": usleep(useconds_t((Double(rest.first ?? "500") ?? 500) * 1000))
    case "click", "rclick":
        guard let p = point(rest[0]) else { print("\(label) \(verb) NOT FOUND \(rest[0])"); continue }
        mouse(.mouseMoved, p); usleep(120_000)
        measure(label, verb) {
            let (d, u, b): (CGEventType, CGEventType, CGMouseButton) = verb == "click" ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
            holding(rest.count > 1 ? rest[1] : nil) { fl in mouse(d, p, button: b, flags: fl); usleep(60_000); mouse(u, p, button: b, flags: fl) }
        }
    case "dclick":
        guard let p = point(rest[0]) else { print("\(label) \(verb) NOT FOUND \(rest[0])"); continue }
        mouse(.mouseMoved, p); usleep(120_000)
        measure(label, verb) {
            mouse(.leftMouseDown, p, clicks: 1); usleep(50_000); mouse(.leftMouseUp, p, clicks: 1); usleep(90_000)
            mouse(.leftMouseDown, p, clicks: 2); usleep(50_000); mouse(.leftMouseUp, p, clicks: 2)
        }
    case "key": measure(label, verb) { key(CGKeyCode(rest[0])!) }
    case "cmdkey": measure(label, verb) { key(CGKeyCode(rest[0])!, cmd: true) }
    case "esc": measure(label, verb) { key(53) }
    case "type":
        for ch in rest.joined(separator: " ").lowercased() {
            guard let k = keycodes[ch] else { continue }
            measure(label, "key", timeout: 800) { key(k) }
        }
    case "scroll":
        guard let p = point(rest[0]), let dy = Double(rest[1]), let n = Int(rest[2]) else { continue }
        let msPer = rest.count > 3 ? Double(rest[3])! : 16
        mouse(.mouseMoved, p); usleep(150_000)
        measure(label, verb, intervals: true) {
            scroll(p, 0, phase: 1); usleep(useconds_t(msPer * 1000))
            var sent = 0.0
            for i in 1...n { let want = (dy / Double(n) * Double(i)).rounded() - sent; scroll(p, Int32(want), phase: 2); sent += want; usleep(useconds_t(msPer * 1000)) }
            scroll(p, 0, phase: 4)
        }
    case "scrollmove":
        // Mac perf audit (P0b) — the same swipe with the pointer moving while it runs: every 4th scroll event the
        // pointer moves 6 pt sideways (back and forth), as a hand resting on the trackpad does.
        guard let p = point(rest[0]), let dy = Double(rest[1]), let n = Int(rest[2]) else { continue }
        let msPer = rest.count > 3 ? Double(rest[3])! : 16
        mouse(.mouseMoved, p); usleep(150_000)
        measure(label, verb, intervals: true) {
            scroll(p, 0, phase: 1); usleep(useconds_t(msPer * 1000))
            var sent = 0.0
            for i in 1...n {
                let want = (dy / Double(n) * Double(i)).rounded() - sent; scroll(p, Int32(want), phase: 2); sent += want
                if i % 4 == 0 { mouse(.mouseMoved, CGPoint(x: p.x + ((i / 4) % 2 == 0 ? 6 : -6) + Double(i % 9), y: p.y + Double(i % 5))) }
                usleep(useconds_t(msPer * 1000))
            }
            scroll(p, 0, phase: 4)
        }
    case "flick", "flickmove":
        // Mac perf audit (P0b) — a trackpad FLICK: a short swipe (12 events, 8 ms apart), fingers off, then the
        // system's momentum events (decaying, ~1.4 s). `flickmove` moves the pointer 12 pt, five times, starting
        // 300 ms into the momentum (the hand settling back on the trackpad). T: "scroll stops dead when the pointer
        // moves mid-scroll" — compare `frames` and `settled` of the two.   flick <x,y> <first delta, e.g. -40>
        guard let p = point(rest[0]), let v0 = Double(rest[1]) else { continue }
        mouse(.mouseMoved, p); usleep(150_000)
        measure(label, verb, timeout: 4000, intervals: true) {
            scroll(p, 0, phase: 1); usleep(8_000)
            for _ in 1...12 { scroll(p, Int32(v0), phase: 2); usleep(8_000) }
            scroll(p, 0, phase: 4); usleep(8_000)
            var v = v0, i = 0
            scroll(p, Int32(v), phase: 0, momentum: 1); usleep(16_000)
            while abs(v) >= 1 {
                v *= 0.955; i += 1
                scroll(p, Int32(v), phase: 0, momentum: 2)
                if verb == "flickmove", i >= 18, i % 6 == 0, i < 48 { mouse(.mouseMoved, CGPoint(x: p.x + Double((i - 12) * 2), y: p.y + Double(i % 7))) }
                usleep(16_000)
            }
            scroll(p, 0, phase: 0, momentum: 3)
        }
    case "trackpad":
        guard let p = point(rest[0]), let secs = Double(rest.count > 1 ? rest[1] : "15") else { continue }
        mouse(.mouseMoved, p); usleep(150_000)
        measure(label, verb, timeout: 3000, intervals: true) {
            trackpadSession(p, seconds: secs, hold: rest.contains("hold"), wobble: rest.contains("wobble"), momentum: !rest.contains("nomomentum"))
        }
    case "move":
        // The pointer travels from a to b in n steps (hover only), measured like a drag.
        guard let p = point(rest[0]), let dx = Double(rest[1]), let dy = Double(rest[2]), let n = Int(rest[3]) else { continue }
        mouse(.mouseMoved, p); usleep(150_000)
        measure(label, verb, intervals: true) {
            for i in 1...n { mouse(.mouseMoved, CGPoint(x: p.x + dx * Double(i) / Double(n), y: p.y + dy * Double(i) / Double(n))); usleep(8_000) }
        }
    case "drag":
        guard let p = point(rest[0]), let dx = Double(rest[1]), let dy = Double(rest[2]), let n = Int(rest[3]) else { continue }
        mouse(.mouseMoved, p); usleep(150_000)
        measure(label, verb, intervals: true) {
            mouse(.leftMouseDown, p); usleep(30_000)
            for i in 1...n { mouse(.leftMouseDragged, CGPoint(x: p.x + dx * Double(i) / Double(n), y: p.y + dy * Double(i) / Double(n))); usleep(16_000) }
            mouse(.leftMouseUp, CGPoint(x: p.x + dx, y: p.y + dy))
        }
    default: print("\(label) unknown verb \(verb)")
    }
}
try? await stream.stopCapture()

print("\nSUMMARY (ms; visible = input → first changed frame, settled = → last change before 400 ms still)")
var csv = "label,verb,visible_ms,settled_ms,frames,interval_p50_ms,interval_p95_ms\n"
for r in rows { csv += "\(r.label),\(r.verb),\(r.visible.map { String(format: "%.1f", $0) } ?? ""),\(r.settled.map { String(format: "%.1f", $0) } ?? ""),\(r.frames),\(r.ivP50.map { String(format: "%.1f", $0) } ?? ""),\(r.ivP95.map { String(format: "%.1f", $0) } ?? "")\n" }
var order: [String] = []
for r in rows where !order.contains(r.label) { order.append(r.label) }
for l in order {
    let g = rows.filter { $0.label == l }
    let v = g.compactMap(\.visible), s = g.compactMap(\.settled), iv50 = g.compactMap(\.ivP50), iv95 = g.compactMap(\.ivP95)
    func f(_ x: Double?) -> String { x.map { String(format: "%.0f", $0) } ?? "-" }
    print(String(format: "%-14@ n %2d · visible p50 %@ p95 %@ · settled p50 %@ p95 %@%@", l as NSString, g.count, f(pct(v, 0.5)), f(pct(v, 0.95)),
                 f(pct(s, 0.5)), f(pct(s, 0.95)), iv50.isEmpty ? "" : " · frame interval p50 \(String(format: "%.1f", pct(iv50, 0.5)!)) p95 \(String(format: "%.1f", pct(iv95, 0.95)!)) ms"))
}
if let path = ProcessInfo.processInfo.environment["RPERF_CSV"] { try? csv.write(toFile: path, atomically: true, encoding: .utf8) }
