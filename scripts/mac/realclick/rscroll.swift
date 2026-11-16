// rscroll — REAL scroll-wheel events at a screen point (Mac E fix-up 3, H5): a trackpad two-finger swipe (continuous,
// pixel deltas, scroll phases began → changed… → ended) or a mouse wheel (discrete line clicks, no phases), posted at
// the window server like rclick's clicks. Positive dy = the content moves down (a two-finger swipe DOWN with natural
// scrolling; a wheel rolled toward you with it off).
//   rscroll <x> <y> trackpad <dy total> <steps> [ms per step]   → one swipe, then (optionally) momentum is left out
//   rscroll <x> <y> wheel <lines> [ms per line]                  → discrete wheel clicks (sign = direction)
import AppKit
import CoreGraphics

let a = CommandLine.arguments
guard a.count >= 5, let x = Double(a[1]), let y = Double(a[2]) else { print("usage"); exit(2) }
let p = CGPoint(x: x, y: y)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(150_000)
func scroll(_ dy: Int32, continuous: Bool, phase: Int64) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
    e.location = p
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
    if continuous {
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)   // 1 began · 2 changed · 4 ended
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
    }
    e.post(tap: .cghidEventTap)
}
switch a[3] {
case "trackpad":
    guard a.count >= 6, let total = Double(a[4]), let steps = Int(a[5]) else { exit(2) }
    let ms = a.count > 6 ? Double(a[6])! : 16
    let per = total / Double(steps)
    scroll(0, continuous: true, phase: 1); usleep(useconds_t(ms * 1000))
    var sent = 0.0
    for i in 1...steps {
        let want = (per * Double(i)).rounded() - sent
        scroll(Int32(want), continuous: true, phase: 2); sent += want
        usleep(useconds_t(ms * 1000))
    }
    scroll(0, continuous: true, phase: 4)
    print("trackpad swipe dy \(Int(sent)) in \(steps) steps at (\(Int(x)),\(Int(y)))")
case "wheel":
    guard let lines = Int(a[4]) else { exit(2) }
    let ms = a.count > 5 ? Double(a[5])! : 60
    for _ in 0..<abs(lines) { scroll(lines > 0 ? 1 : -1, continuous: false, phase: 0); usleep(useconds_t(ms * 1000)) }
    print("wheel \(lines) lines at (\(Int(x)),\(Int(y)))")
default: print("mode?"); exit(2)
}
usleep(300_000)
