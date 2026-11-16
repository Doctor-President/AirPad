// rframe — click → PIXELS latency (Mac E fix-up 3, H1): what the user sees. A ScreenCaptureKit stream watches a screen
// rect (a control, or the area its effect draws in) at up to 120 fps; each step posts a real click (CGEvent at the
// window server) and finds the first frame, displayed after the mouse-up, that differs from the pre-press frame and
// stays different (the new state). Its display time − the mouse-up time = the latency. No lasting change within the
// timeout = a MISS. Needs Accessibility + Screen Recording for the app that runs it. Runs on Release (no hooks).
//   rframe <pid> <n> <gap ms> <wander pt> <click-id> [<watch-id> | x,y,w,h]
//     gap: pause after each step's verdict before the next press · watch: the rect watched (default the clicked control)
// Prints one line per click and   SUMMARY n · seen · miss · p50 · p95 · max (ms)
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia

let args = CommandLine.arguments
guard args.count >= 6, let pid = pid_t(args[1]), let n = Int(args[2]), let gap = Double(args[3]),
      let wander = Double(args[4]) else { print("usage"); exit(2) }
let clickID = args[5]
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = a(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = a(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func find(_ key: String) -> AXUIElement? {
    var found: AXUIElement?
    func walk(_ e: AXUIElement, _ d: Int) {
        if found != nil { return }
        if (a(e, "AXIdentifier") as? String) == key { found = e; return }
        guard d < 40, let kids = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
        kids.forEach { walk($0, d + 1) }
    }
    ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).forEach { walk($0, 0) }
    return found
}
func post(_ t: CGEventType, _ p: CGPoint) {
    // A real click's down AND up carry click state 1 (an unset field posts the up with clickCount 0).
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
    if t == .leftMouseDown || t == .leftMouseUp || t == .leftMouseDragged { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
    e?.post(tap: .cghidEventTap)
}
func owned(_ p: CGPoint) -> Bool {
    var e: AXUIElement?, owner: pid_t = 0
    return AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &e) == .success && e != nil
        && AXUIElementGetPid(e!, &owner) == .success && owner == pid
}
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ms(_ mach: UInt64) -> Double { Double(mach) * Double(tb.numer) / Double(tb.denom) / 1e6 }

/// Frames: (display time ms, a small grey thumbnail).
final class Sink: NSObject, SCStreamOutput {
    let lock = NSLock()
    var frames: [(Double, [UInt8])] = []
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let t = (info[.displayTime] as? UInt64).map(ms) ?? 0
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
        let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
        var g = [UInt8](); g.reserveCapacity(w * h)
        for y in 0..<h { for x in 0..<w { let o = y * row + x * 4; g.append(UInt8((Int(base[o]) + Int(base[o + 1]) + Int(base[o + 2])) / 3)) } }
        lock.lock(); frames.append((t, g)); lock.unlock()
    }
    func snapshot() -> [(Double, [UInt8])] { lock.lock(); defer { lock.unlock() }; return frames }
    func clear() { lock.lock(); frames.removeAll(); lock.unlock() }
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
guard let clickEl = find(clickID) else { print("no \(clickID)"); exit(1) }
var watchRect: CGRect
if args.count > 6 {
    let p = args[6].split(separator: ",").compactMap { Double($0) }
    if p.count == 4 { watchRect = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
    else if let e = find(args[6]) { watchRect = frame(e) } else { print("no \(args[6])"); exit(1) }
} else { watchRect = frame(clickEl) }

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let display = content.displays.first(where: { $0.frame.contains(watchRect.origin) }) ?? content.displays.first else { exit(1) }
let cfg = SCStreamConfiguration()
cfg.sourceRect = watchRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
cfg.width = max(8, Int(watchRect.width)); cfg.height = max(8, Int(watchRect.height))
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
cfg.queueDepth = 6
cfg.showsCursor = false
let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
let sink = Sink()
try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
try await stream.startCapture()
usleep(500_000)

var lat: [Double] = [], miss = 0
let timeout = 1500.0
let threshold = 0.04
for i in 0..<n {
    let f = frame(clickEl); let p = CGPoint(x: f.midX, y: f.midY)
    guard owned(p) else { print("COVERED \(clickID) at (\(Int(p.x)),\(Int(p.y)))"); try? await stream.stopCapture(); exit(3) }
    post(.mouseMoved, p); usleep(350_000)              // hover wash settles before the baseline
    guard let before = sink.snapshot().last?.1 else { print("no frames"); exit(4) }
    sink.clear()
    post(.leftMouseDown, p); usleep(40_000)
    var q = p
    if wander > 0 { q = CGPoint(x: p.x + wander, y: p.y); post(.leftMouseDragged, q); usleep(20_000) }
    post(.leftMouseUp, q)
    let tUp = ms(mach_absolute_time())
    usleep(useconds_t(timeout * 1000))
    let fr = sink.snapshot().filter { $0.0 > tUp }
    // The new look's onset: the first frame closer to the final look than to the pre-press one, from which every later
    // frame is too (the pressed look and an animated fill don't count as the change). Needs a lasting change at all.
    var first: Double?
    if let final = fr.last?.1, diff(final, before) > threshold {
        for (k, x) in fr.enumerated() where diff(x.1, final) < diff(x.1, before) {
            if fr[k...].allSatisfy({ diff($0.1, final) < diff($0.1, before) }) { first = x.0; break }
        }
    }
    if ProcessInfo.processInfo.environment["RFRAME_TRACE"] != nil {
        print("  trace: " + fr.map { String(format: "%.0f:%.2f", $0.0 - tUp, diff($0.1, before)) }.joined(separator: " "))
    }
    if let first {
        lat.append(first - tUp)
        print(String(format: "%3d %@ new look %.0f ms (frames %d)", i, clickID, first - tUp, fr.count))
    } else {
        miss += 1
        print("\(i) \(clickID) MISS (no lasting change in \(Int(timeout)) ms; frames \(fr.count))")
    }
    usleep(useconds_t(gap * 1000))
}
try? await stream.stopCapture()
lat.sort()
func pct(_ p: Double) -> Double { lat.isEmpty ? .nan : lat[min(lat.count - 1, Int((Double(lat.count) * p).rounded(.up)) - 1)] }
print(String(format: "SUMMARY n %d · seen %d · miss %d · p50 %.0f · p95 %.0f · max %.0f ms", n, lat.count, miss, pct(0.5), pct(0.95), lat.last ?? .nan))
