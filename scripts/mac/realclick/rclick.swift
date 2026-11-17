// rclick — REAL pointer/keyboard events (CGEvent → the window server, .cghidEventTap) on a running app, located and
// checked through the Accessibility API from OUTSIDE the app, so it runs on a Release build with no hooks.
// Needs Accessibility for the app that runs it (Terminal). Mac E fix-up 2.
//   rclick find  <pid> <id-or-title>            → frame of the first match (an id ending in * matches a prefix)
//   rclick click <pid> <id-or-title> [n]        → move + down/up at its centre (n-th match, default 0)
//   rclick clickat <pid> <x> <y>                → at a screen point (top-left origin)
//   rclick dclickat <pid> <x> <y>               → a double click at a screen point
//   rclick drag  <pid> <x> <y> <dx> <dy>        → press, move in 10 steps, release
//   rclick type  <pid> <text>                   → key events (a–z, space)
//   rclick key   <pid> <keycode>                → one key (53 = Esc)
//   rclick cmdkey <pid> <keycode>               → the key with ⌘ (43 = ",")
//   rclick get   <pid> <id-or-title> <attr>     → an attribute (AXValue, AXFocused, AXSelected …)
//   rclick has   <pid> <id-or-title>            → "yes <frame>" / "no"
//   rclick hover <pid> <id-or-title>            → the pointer onto its centre, no press
//   rclick focus <pid>                          → the app's focused element
//   rclick menu <pid> <menu> <item-prefix>      → press a menu-bar item (AX; for setup)
//   rclick winsize <pid> <w> <h>                → resize the main window (AX)
//   rclick winpos <pid>                         → the main window's frame
//   rclick winmove <pid> <x> <y>                → move the main window (clear of banners in the screen's corners)
// A press whose point another app covers (a notification banner, a window) is NOT posted: "COVERED … by <app>", exit 3.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else { print("usage"); exit(2) }
let app = AXUIElementCreateApplication(pid)
func a(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = a(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = a(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func matches(_ key: String) -> [AXUIElement] {
    var out: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        let id = a(e, "AXIdentifier") as? String ?? ""
        let title = (a(e, kAXTitleAttribute) as? String) ?? (a(e, kAXDescriptionAttribute) as? String) ?? ""
        if id == key || title == key || (key.hasSuffix("*") && id.hasPrefix(key.dropLast())) { out.append(e) }
        guard d < 40, let kids = a(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
        kids.forEach { walk($0, d + 1) }
    }
    ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).forEach { walk($0, 0) }
    return out
}
func fmt(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))" }
/// Bring the app forward and wait until its window stops moving (Stage Manager slides it on activation).
func front() {
    NSRunningApplication(processIdentifier: pid)?.activate()
    var last = CGRect.null
    for _ in 0..<30 {
        usleep(150_000)
        let w = ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first.map(frame) ?? .null
        if w == last { return }
        last = w
    }
}
func post(_ t: CGEventType, _ p: CGPoint) {
    // A real click's down AND up carry click state 1 (an unset field posts the up with clickCount 0).
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
    // RCLICK_UP0=1 posts the up with the field unset (fix-up 2's events), for the A/B.
    if t == .leftMouseDown || t == .leftMouseDragged || (t == .leftMouseUp && ProcessInfo.processInfo.environment["RCLICK_UP0"] == nil) {
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
    }
    e?.post(tap: .cghidEventTap)
}
/// Exits unless the topmost element at `p` belongs to the app (a banner over the point would take the click).
func ensureOwned(_ p: CGPoint) {
    var e: AXUIElement?, owner: pid_t = 0
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &e) == .success, let e,
          AXUIElementGetPid(e, &owner) == .success, owner == pid else {
        let who = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? "pid \(owner)"
        print("COVERED at (\(Int(p.x)),\(Int(p.y))) by \(who)"); exit(3)
    }
}
func clickAt(_ p: CGPoint) {
    ensureOwned(p)
    // E fix-up 3 (H1): who is frontmost right before the press (a click on an inactive app only activates it).
    if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != pid {
        print("NOT-FRONT before press: \(f.bundleIdentifier ?? "pid \(f.processIdentifier)")")
    }
    post(.mouseMoved, p); usleep(120_000)
    post(.leftMouseDown, p); usleep(70_000)
    post(.leftMouseUp, p); usleep(450_000)
}
func target(_ key: String, _ n: Int = 0) -> AXUIElement? {
    let m = matches(key); guard n < m.count else { print("no match \(key) [\(n)] (\(m.count) found)"); return nil }
    return m[n]
}
let mode = args[1]
switch mode {
case "find":
    if let e = target(args[3]) { print(fmt(frame(e))) } else { exit(1) }
case "has":
    let m = matches(args[3]); print(m.isEmpty ? "no" : "yes \(fmt(frame(m[0])))")
case "click":
    front()
    guard let e = target(args[3], args.count > 4 ? Int(args[4])! : 0) else { exit(1) }
    let r = frame(e); clickAt(CGPoint(x: r.midX, y: r.midY)); print("clicked \(args[3]) at (\(Int(r.midX)),\(Int(r.midY))) \(fmt(r))")
case "dclickat":
    front(); let p = CGPoint(x: Double(args[3])!, y: Double(args[4])!); ensureOwned(p)
    post(.mouseMoved, p); usleep(120_000)
    for n in 1...2 {
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(n)); e?.post(tap: .cghidEventTap); usleep(60_000)
        }
    }
    usleep(600_000); print("double-clicked at (\(Int(p.x)),\(Int(p.y)))")
case "hover":   // move the pointer onto an element's centre, no press
    front(); guard let e = target(args[3]) else { exit(1) }
    let r = frame(e); post(.mouseMoved, CGPoint(x: r.midX, y: r.midY)); usleep(100_000); print("hovering \(args[3])")
case "clickat":
    front(); let p = CGPoint(x: Double(args[3])!, y: Double(args[4])!); clickAt(p); print("clicked at (\(Int(p.x)),\(Int(p.y)))")
case "drag":
    front()
    let p = CGPoint(x: Double(args[3])!, y: Double(args[4])!), dx = Double(args[5])!, dy = Double(args[6])!
    ensureOwned(p)
    post(.mouseMoved, p); usleep(120_000); post(.leftMouseDown, p); usleep(120_000)
    for i in 1...10 { post(.leftMouseDragged, CGPoint(x: p.x + dx * Double(i) / 10, y: p.y + dy * Double(i) / 10)); usleep(30_000) }
    post(.leftMouseUp, CGPoint(x: p.x + dx, y: p.y + dy)); usleep(400_000); print("dragged from (\(Int(p.x)),\(Int(p.y))) by (\(Int(dx)),\(Int(dy)))")
case "type":
    front()
    let codes: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, " ": 49]
    for ch in args[3] { guard let k = codes[ch] else { continue }
        CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: true)?.post(tap: .cghidEventTap); usleep(40_000)
        CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: false)?.post(tap: .cghidEventTap); usleep(40_000) }
    usleep(300_000); print("typed \(args[3])")
case "key":
    front(); let k = CGKeyCode(args[3])!
    CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: true)?.post(tap: .cghidEventTap); usleep(40_000)
    CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: false)?.post(tap: .cghidEventTap); usleep(300_000); print("key \(k)")
case "cmdkey":   // rclick cmdkey <pid> <keycode>: the key with ⌘ (43 = ",")
    front(); let k = CGKeyCode(args[3])!
    // E fix-up 4 — a real ⌘ down … up around the key. Posting only the key with the ⌘ flag left the window server's
    // modifier state at ⌘ DOWN: every later event of every harness run was a ⌘-event (typing ran Format commands,
    // a "q" quit the app). Checked after: the state must read ⌘ up.
    let cmd = CGKeyCode(55)
    let cd = CGEvent(keyboardEventSource: nil, virtualKey: cmd, keyDown: true); cd?.flags = .maskCommand; cd?.post(tap: .cghidEventTap); usleep(30_000)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: down); e?.flags = .maskCommand; e?.post(tap: .cghidEventTap); usleep(40_000)
    }
    let cu = CGEvent(keyboardEventSource: nil, virtualKey: cmd, keyDown: false); cu?.flags = []; cu?.post(tap: .cghidEventTap); usleep(30_000)
    if CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) { print("WARNING ⌘ still down after cmdkey") }
    usleep(500_000); print("⌘ key \(k)")
case "get":
    guard let e = target(args[3]) else { exit(1) }
    print(a(e, args[4]).map { "\($0)" } ?? "nil")
case "focus":   // the app's focused element: role · identifier · description
    guard let f = a(app, kAXFocusedUIElementAttribute) else { print("none"); exit(0) }
    let e = f as! AXUIElement
    print("\(a(e, kAXRoleAttribute) ?? "?" as AnyObject) · \(a(e, "AXIdentifier") ?? "-" as AnyObject) · \(a(e, kAXDescriptionAttribute) ?? "-" as AnyObject) · \(fmt(frame(e)))")
case "menu":   // rclick menu <pid> <menu> <item>: press a menu-bar item through Accessibility (setup, not a click test)
    front()
    guard let bar = a(app, kAXMenuBarAttribute) else { print("no menu bar"); exit(1) }
    func kids(_ e: AnyObject) -> [AXUIElement] { (a(e as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    guard let top = kids(bar).first(where: { (a($0, kAXTitleAttribute) as? String) == args[3] }) else { print("no menu \(args[3])"); exit(1) }
    let items = kids(top).flatMap { kids($0 as AnyObject) }
    guard let it = items.first(where: { ((a($0, kAXTitleAttribute) as? String) ?? "").hasPrefix(args[4]) }) else {
        print("no item \(args[4]) in \(items.compactMap { a($0, kAXTitleAttribute) as? String })"); exit(1) }
    AXUIElementPerformAction(it, kAXPressAction as CFString); usleep(800_000); print("pressed \(args[3]) › \(args[4])")
case "press":   // rclick press <pid> <id-or-title> [n|last]: AXPress (setup only, not a click test)
    let m = matches(args[3]); guard !m.isEmpty else { print("no match"); exit(1) }
    let e = args.count > 4 ? (args[4] == "last" ? m.last! : m[Int(args[4])!]) : m[0]
    AXUIElementPerformAction(e, kAXPressAction as CFString); usleep(600_000); print("pressed \(args[3]) (\(m.count) found)")
case "winsize":  // rclick winsize <pid> <w> <h>
    guard let w = ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first else { exit(1) }
    var sz = CGSize(width: Double(args[3])!, height: Double(args[4])!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &sz)!)
    usleep(700_000); print(fmt(frame(w)))
case "winpos":
    let w = ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first
    print(w.map { fmt(frame($0)) } ?? "none")
case "winmove":
    guard let w = ((a(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).first else { exit(1) }
    var p = CGPoint(x: Double(args[3])!, y: Double(args[4])!)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
    usleep(500_000); print(fmt(frame(w)))
default: print("unknown mode"); exit(2)
}
