// rfinder — REAL drags out of Finder (E fix-up 6, M1/M6). Finder windows are placed and their file icons found through
// Accessibility; the drag is posted as real HID events, so macOS runs a real drag session (other apps see it too).
//   rfinder place <window title> <x> <y> <w> <h>
//   rfinder icon <window title> <file name>                 → "x y" (the icon's centre, global points)
//   rfinder drag <x0 y0> <x1 y1> <x2 y2> [linger ms] [esc]  press at 0, wander over 1, release at 2 (esc: Esc while held at 1)
import AppKit
import ApplicationServices
import CoreGraphics

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func finder() -> AXUIElement {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ProcessInfo.processInfo.environment["RF_BID"] ?? "com.apple.finder").first else { print("no Finder"); exit(3) }
    return AXUIElementCreateApplication(app.processIdentifier)
}
func window(_ title: String) -> AXUIElement {
    for w in (attr(finder(), kAXWindowsAttribute) as? [AXUIElement]) ?? [] where (attr(w, kAXTitleAttribute) as? String) == title { return w }
    print("no Finder window \(title)"); exit(3)
}
func find(_ e: AXUIElement, _ name: String, depth: Int = 0) -> AXUIElement? {
    if depth > 14 { return nil }
    for k in kids(e) {
        let t = (attr(k, kAXTitleAttribute) as? String) ?? (attr(k, kAXValueAttribute) as? String) ?? (attr(k, kAXDescriptionAttribute) as? String)
        let role = (attr(k, kAXRoleAttribute) as? String) ?? ""
        if t == name, role == kAXImageRole || role == kAXTextFieldRole || role == kAXStaticTextRole || role == "AXCell" { return k }
        if let f = find(k, name, depth: depth + 1) { return f }
    }
    return nil
}
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
func move(from a: CGPoint, to b: CGPoint, steps: Int = 30, ms: Double = 600) {
    for i in 1...steps { let f = Double(i) / Double(steps); post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)); usleep(useconds_t(ms * 1000 / Double(steps))) }
}
func key(_ code: CGKeyCode) {
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap); usleep(40_000)
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
}
let a = Array(CommandLine.arguments.dropFirst())
switch a.first {
case "place":
    let w = window(a[1]); let n = a[2...5].compactMap(Double.init)
    var p = CGPoint(x: n[0], y: n[1]), s = CGSize(width: n[2], height: n[3])
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString); print(frame(w))
case "icon":
    guard let e = find(window(a[1]), a[2]) else { print("NOT FOUND"); exit(4) }
    let f = frame(e); print(Int(f.midX), Int(f.midY))
case "drag":
    let n = a[1...6].compactMap(Double.init); let linger = a.count > 7 ? Double(a[7]) ?? 400 : 400; let esc = a.contains("esc")
    let p0 = CGPoint(x: n[0], y: n[1]), p1 = CGPoint(x: n[2], y: n[3]), p2 = CGPoint(x: n[4], y: n[5])
    post(.mouseMoved, p0); usleep(200_000); post(.leftMouseDown, p0); usleep(300_000)
    move(from: p0, to: CGPoint(x: p0.x + 12, y: p0.y + 12), steps: 6, ms: 120)
    move(from: CGPoint(x: p0.x + 12, y: p0.y + 12), to: p1)
    // wander over the middle point so the target sees updates, then leave
    move(from: p1, to: CGPoint(x: p1.x + 40, y: p1.y + 30), steps: 10, ms: linger); move(from: CGPoint(x: p1.x + 40, y: p1.y + 30), to: p1, steps: 10, ms: linger)
    if esc { key(53); usleep(300_000) }
    let fast = a.contains("fast")
    move(from: p1, to: p2, steps: fast ? 3 : 30, ms: fast ? 50 : 700); usleep(500_000)
    post(.leftMouseUp, p2); usleep(400_000)
    print("dragged (\(Int(p0.x)),\(Int(p0.y))) → (\(Int(p1.x)),\(Int(p1.y))) → (\(Int(p2.x)),\(Int(p2.y)))\(esc ? " esc" : "")")
case "iconview":   // raise the window, ⌘1 (icon view) with Finder frontmost
    let w = window(a[1]); NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    usleep(400_000); AXUIElementPerformAction(w, kAXRaiseAction as CFString); usleep(300_000)
    func k(_ c: CGKeyCode, _ d: Bool, _ f: CGEventFlags) { let e = CGEvent(keyboardEventSource: nil, virtualKey: c, keyDown: d); e?.flags = f; e?.post(tap: .cghidEventTap); usleep(40_000) }
    k(55, true, .maskCommand); k(18, true, .maskCommand); k(18, false, .maskCommand); k(55, false, []); print("⌘1")
default: print("usage: rfinder place|icon|drag …"); exit(2)
}
