// rlat — click → effect LATENCY with real events (Mac E fix-up 3, H1). Each step posts a real click (CGEvent at the
// window server, like rclick) or a key, then polls one Accessibility attribute every 4 ms until it changes; the time
// from the mouse-up to the change is the latency. No change within the timeout = a MISS. Runs on Release (no hooks).
//   rlat <pid> <n> <mode> <gap ms> <wander pt> <step> [<step> …]
//     step   = <click-id>:<watch-id>:<attr>   (click the first, watch the second's attribute change)
//            | key<code>:<watch-id>:<attr>      (press a key instead of clicking)
//     mode   = wait   → the next step starts <gap> ms after the effect showed (or after the timeout)
//            | fixed  → the next step starts <gap> ms after the mouse-up, effect or not (a burst)
//     wander = points the pointer moves between down and up (0 = a still click; a trackpad click moves 0–2 pt)
// The steps repeat in order until n clicks have been posted. Prints one line per click and a summary:
//   SUMMARY n <n> · seen <k> · miss <m> · p50 <ms> · p95 <ms> · max <ms>
// Refuses a press another app covers (exit 3), as rclick does.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 7, let pid = pid_t(args[1]), let n = Int(args[2]), let gap = Double(args[4]),
      let wander = Double(args[5]) else { print("usage"); exit(2) }
let mode = args[3]
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
var cache: [String: AXUIElement] = [:]
func el(_ key: String) -> AXUIElement? {
    if let e = cache[key], a(e, kAXRoleAttribute) != nil { return e }
    let e = find(key); cache[key] = e; return e
}
func read(_ key: String, _ attr: String) -> String {
    guard let e = el(key) else { return "∅" }
    guard let v = a(e, attr) else { return "nil" }
    return "\(v)"
}
func now() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }
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

NSRunningApplication(processIdentifier: pid)?.activate()
usleep(600_000)
let steps = args[7...].map { $0.split(separator: ":").map(String.init) } + [args[6].split(separator: ":").map(String.init)]
let ordered = [steps.last!] + steps.dropLast()
var lat: [Double] = [], miss = 0, unseen = 0
let timeout = Double(ProcessInfo.processInfo.environment["RLAT_TIMEOUT"] ?? "") ?? 1500
for i in 0..<n {
    let s = ordered[i % ordered.count]
    let (what, watch, attr) = (s[0], s[1], s[2])
    let v0 = read(watch, attr)
    var tUp = 0.0
    if what.hasPrefix("key") {
        let code = CGKeyCode(what.dropFirst(3))!
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        tUp = now()
    } else {
        guard let e = el(what) else { print("\(i) \(what) NOT FOUND"); miss += 1; continue }
        let f = frame(e); let p = CGPoint(x: f.midX, y: f.midY)
        guard owned(p) else { print("COVERED \(what) at (\(Int(p.x)),\(Int(p.y)))"); exit(3) }
        post(.mouseMoved, p); usleep(60_000)
        post(.leftMouseDown, p); usleep(40_000)
        var q = p
        if wander > 0 { q = CGPoint(x: p.x + wander, y: p.y); post(.leftMouseDragged, q); usleep(20_000) }
        post(.leftMouseUp, q)
        tUp = now()
    }
    var v = v0, t = tUp
    let limit = mode == "fixed" ? min(timeout, gap) : timeout
    while v == v0, now() - tUp < limit { usleep(4_000); v = read(watch, attr); t = now() }
    if v != v0 {
        let ms = t - tUp
        lat.append(ms)
        print(String(format: "%3d %@ → %@.%@ %@ → %@  %.0f ms  up=%.0f", i, what, watch, attr, v0, v, ms, tUp))
    } else if mode == "fixed" {
        unseen += 1
        print("\(i) \(what) → \(watch).\(attr) not seen within the burst gap (\(Int(gap)) ms) · \(v0)")
    } else {
        miss += 1
        print("\(i) \(what) → \(watch).\(attr) MISS (no change in \(Int(timeout)) ms) · \(v0)  up=\(Int(tUp))")
    }
    let wait = mode == "fixed" ? max(0, gap - (now() - tUp)) : gap
    usleep(useconds_t(wait * 1000))
}
lat.sort()
func pct(_ p: Double) -> Double { lat.isEmpty ? .nan : lat[min(lat.count - 1, Int((Double(lat.count) * p).rounded(.up)) - 1)] }
print(String(format: "SUMMARY n %d · seen %d · miss %d · unseen-in-burst %d · p50 %.0f · p95 %.0f · max %.0f ms",
             n, lat.count, miss, unseen, pct(0.5), pct(0.95), lat.last ?? .nan))
