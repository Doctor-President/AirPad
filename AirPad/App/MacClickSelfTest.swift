#if DEBUG && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Mac E fix-up — REAL pointer events for the Mac checks: AppKit mouse / key events built with NSEvent's own factories
/// and posted to the app's own event queue at a control's point in the window, so they go through the window's real hit-testing
/// (title bar, toolbar, the UIKit content) exactly as a click does. Nothing is posted to the system (this Mac's tools
/// have no event-posting access), and only the app's own (isolated) window receives them.
@MainActor
enum MacClick {
    static var app: NSObject? {
        (NSClassFromString("NSApplication") as? NSObject.Type)?.perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject
    }
    static var window: NSObject? { MacWindowChrome.nsWindow }
    private static var eventNumber = 9000

    /// The window's own coordinates (AppKit: origin bottom-left) of a point in the main UIWindow (full-size content:
    /// the UIWindow covers the whole window, under the title bar too).
    static func windowPoint(ui p: CGPoint) -> CGPoint? {
        guard let w = window, let content = (w.value(forKey: "contentView") as? NSObject)?.value(forKey: "frame") as? CGRect
        else { return nil }
        return CGPoint(x: p.x, y: content.height - p.y)
    }

    /// The window point of a point inside a toolbar item (in its hosted SwiftUI root's coordinates).
    static func windowPoint(toolbarItem id: NSToolbarItem.Identifier, _ p: CGPoint) -> CGPoint? {
        guard let v = itemView(id), let b = v.value(forKey: "bounds") as? CGRect else { return nil }
        let flipped = (v.value(forKey: "isFlipped") as? Bool) ?? false
        let local = CGPoint(x: b.minX + p.x, y: flipped ? b.minY + p.y : b.maxY - p.y)
        typealias Conv = @convention(c) (AnyObject, Selector, CGPoint, AnyObject?) -> CGPoint
        let sel = NSSelectorFromString("convertPoint:toView:")
        return unsafeBitCast(v.method(for: sel), to: Conv.self)(v, sel, local, nil)
    }

    static func itemView(_ id: NSToolbarItem.Identifier) -> NSObject? { MacWindowChrome.itemView(id) }

    /// What AppKit's hit-test finds at a window point (the frame view's `hitTest:`), as the class chain up 6 levels.
    static func hit(_ wp: CGPoint) -> (view: NSObject?, chain: String) {
        guard let cv = window?.value(forKey: "contentView") as? NSObject,
              let frameView = cv.value(forKey: "superview") as? NSObject else { return (nil, "no frame view") }
        typealias Hit = @convention(c) (AnyObject, Selector, CGPoint) -> AnyObject?
        let sel = NSSelectorFromString("hitTest:")
        let v = unsafeBitCast(frameView.method(for: sel), to: Hit.self)(frameView, sel, wp) as? NSObject
        var names: [String] = [], cur = v
        for _ in 0..<6 { guard let c = cur else { break }; names.append(String(describing: type(of: c))); cur = c.value(forKey: "superview") as? NSObject }
        return (v, names.joined(separator: " < "))
    }

    /// `mouseDownCanMoveWindow` / `isOpaque` from the hit view up to the frame view (a transparent title bar drags the
    /// window from a click on a view that says it can move it).
    static func moveChain(_ v: NSObject?) -> String {
        var out: [String] = [], cur = v
        for _ in 0..<9 {
            guard let c = cur else { break }
            let can = (c.value(forKey: "mouseDownCanMoveWindow") as? Bool).map { $0 ? "Y" : "n" } ?? "?"
            let op = (c.value(forKey: "isOpaque") as? Bool).map { $0 ? "Y" : "n" } ?? "?"
            out.append("\(String(describing: type(of: c)).prefix(32)) move=\(can) opaque=\(op)")
            cur = c.value(forKey: "superview") as? NSObject
        }
        let w = window
        out.append("window movable=\((w?.value(forKey: "isMovable") as? Bool) ?? false) byBackground=\((w?.value(forKey: "isMovableByWindowBackground") as? Bool) ?? false) transparentTitle=\((w?.value(forKey: "titlebarAppearsTransparent") as? Bool) ?? false)")
        return out.joined(separator: " < ")
    }

    /// AppKit's own answer: would a press here start a window drag (the frame view's `shouldStartWindowDragForEvent:`)?
    static func startsDrag(_ wp: CGPoint) -> Bool? {
        guard let cv = window?.value(forKey: "contentView") as? NSObject, let frame = cv.value(forKey: "superview") as? NSObject,
              let e = mouse(1, wp) else { return nil }
        let sel = NSSelectorFromString("shouldStartWindowDragForEvent:")
        guard frame.responds(to: sel) else { return nil }
        typealias Ask = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(frame.method(for: sel), to: Ask.self)(frame, sel, e)
    }

    static func isDescendant(_ v: NSObject?, of ancestor: NSObject?) -> Bool {
        var cur = v
        while let c = cur { if c === ancestor { return true }; cur = c.value(forKey: "superview") as? NSObject }
        return false
    }

    /// `type`: 1 leftMouseDown, 2 leftMouseUp, 5 mouseMoved, 6 leftMouseDragged.
    static func mouse(_ type: UInt, _ wp: CGPoint, clickCount: Int = 1) -> NSObject? {
        guard let cls: AnyClass = NSClassFromString("NSEvent"), let num = window?.value(forKey: "windowNumber") as? Int,
              let m = class_getClassMethod(cls, NSSelectorFromString("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"))
        else { return nil }
        typealias Make = @convention(c) (AnyClass, Selector, UInt, CGPoint, UInt, Double, Int, AnyObject?, Int, Int, Float) -> AnyObject?
        eventNumber += 1
        return unsafeBitCast(method_getImplementation(m), to: Make.self)(cls, method_getName(m), type, wp, 0,
            ProcessInfo.processInfo.systemUptime, num, nil, eventNumber, type == 5 ? 0 : clickCount, type == 1 || type == 6 ? 1 : 0) as? NSObject
    }

    static func key(_ chars: String, keyCode: UInt16, down: Bool) -> NSObject? {
        guard let cls: AnyClass = NSClassFromString("NSEvent"), let num = window?.value(forKey: "windowNumber") as? Int,
              let m = class_getClassMethod(cls, NSSelectorFromString("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"))
        else { return nil }
        typealias Make = @convention(c) (AnyClass, Selector, UInt, CGPoint, UInt, Double, Int, AnyObject?, NSString, NSString, Bool, UInt16) -> AnyObject?
        return unsafeBitCast(method_getImplementation(m), to: Make.self)(cls, method_getName(m), down ? 10 : 11, .zero, 0,
            ProcessInfo.processInfo.systemUptime, num, nil, chars as NSString, chars as NSString, false, keyCode) as? NSObject
    }

    /// Into the app's event queue (`postEvent:atStart:`), so the run loop dequeues it as it does a real event — and an
    /// AppKit tracking loop started by a mouse-down (title bar, toolbar) receives the mouse-up.
    /// `-MacClickVia window`: straight into the window's `sendEvent:` instead (a locked Mac never makes the app active,
    /// and NSApp drops clicks to an inactive app; the window still hit-tests and dispatches them).
    static let viaWindow = UserDefaults.standard.string(forKey: "MacClickVia") == "window"
    static func send(_ e: NSObject?) {
        guard let e, let app else { return }
        if viaWindow, let window { window.perform(NSSelectorFromString("sendEvent:"), with: e); return }
        typealias Post = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
        let sel = NSSelectorFromString("postEvent:atStart:")
        unsafeBitCast(app.method(for: sel), to: Post.self)(app, sel, e, false)
    }

    static func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// Pointer over the point (hover), then a press and a release there.
    static func click(_ wp: CGPoint) async {
        NSLog("[MacClick] click (%.0f, %.0f) via %@", wp.x, wp.y, viaWindow ? "window" : "queue")
        send(mouse(5, wp)); await settle(0.08)
        send(mouse(1, wp)); await settle(0.06)
        send(mouse(2, wp)); await settle(0.35)
    }

    static func hover(_ wp: CGPoint) async { send(mouse(5, wp)); await settle(0.25) }

    static func typeText(_ text: String) async {
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
            "n": 45, "m": 46, " ": 49]
        for ch in text {
            let code = codes[ch] ?? 0
            send(key(String(ch), keyCode: code, down: true)); await settle(0.04)
            send(key(String(ch), keyCode: code, down: false)); await settle(0.04)
        }
    }

    /// The app in front with its window key (a click on an inactive window only activates it).
    static func activate() async {
        app?.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true as NSNumber)
        window?.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
        await settle(0.6)
    }

    /// Where UIKit delivers each touch the clicks make: window, the touched view's class chain, its location (the
    /// window's `sendEvent:` traced once, DEBUG).
    static var touchLog: [String] = []
    private static var traced = false
    static func traceTouches() {
        guard !traced, let m = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))) else { return }
        traced = true
        typealias Orig = @convention(c) (UIWindow, Selector, UIEvent) -> Void
        let orig = unsafeBitCast(method_getImplementation(m), to: Orig.self)
        let block: @convention(block) (UIWindow, UIEvent) -> Void = { w, e in
            if e.type == .touches, let touches = e.allTouches {
                for t in touches where t.phase == .began || t.phase == .ended {
                    var names: [String] = [], cur: UIView? = t.view
                    for _ in 0..<5 { guard let c = cur else { break }; names.append(String(describing: type(of: c)).prefix(60).description); cur = c.superview }
                    let p = t.location(in: w)
                    MacClick.touchLog.append("\(t.phase == .began ? "began" : "ended") in \(type(of: w)) \(Int(w.bounds.width))×\(Int(w.bounds.height)) at (\(Int(p.x)), \(Int(p.y))) view \(names.joined(separator: " < "))")
                }
            }
            orig(w, #selector(UIWindow.sendEvent(_:)), e)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// Which AppKit views get `mouseDown:` (traced on the candidates, DEBUG).
    static func traceMouseDown() {
        for name in ["NSView", "UINSInputView", "NSThemeFrame", "NSTitlebarView", "NSToolbarView", "NSTitlebarContainerView",
                     "NSToolbarItemViewer", "UINSSceneView", "NSGlassEffectView", "_NSTitlebarDecorationView"] {
            guard let cls = NSClassFromString(name), let m = class_getInstanceMethod(cls, NSSelectorFromString("mouseDown:")) else { continue }
            typealias Orig = @convention(c) (NSObject, Selector, NSObject) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: Orig.self)
            let sel = method_getName(m)
            let block: @convention(block) (NSObject, NSObject) -> Void = { v, e in
                MacClick.touchLog.append("mouseDown: → \(type(of: v)) (impl \(name))")
                orig(v, sel, e)
            }
            if !class_addMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m)) {
                method_setImplementation(m, imp_implementationWithBlock(block))
            }
        }
    }

    /// Every NSWindow / title-bar method whose name has "drag" or "mouse" in it and a one-object signature, traced
    /// (what takes a mouse-down before any view sees it).
    static func traceWindowMethods() {
        for name in ["NSWindow", "UINSWindow", "NSThemeFrame", "NSTitlebarView", "NSTitlebarContainerView", "NSToolbarView", "NSNextStepFrame", "NSFrameView"] {
            guard let cls = NSClassFromString(name) else { continue }
            var count: UInt32 = 0
            guard let list = class_copyMethodList(cls, &count) else { continue }
            for i in 0..<Int(count) {
                let m = list[i]
                let sel = method_getName(m), sname = NSStringFromSelector(sel)
                let low = sname.lowercased()
                guard low.contains("drag") || low.contains("mouse"), !low.contains("moved"), !low.contains("entered"), !low.contains("exited"),
                      !low.contains("tracking"), let enc = method_getTypeEncoding(m) else { continue }
                let e = String(cString: enc)
                if e == "v24@0:8@16" {
                    typealias O = @convention(c) (NSObject, Selector, NSObject?) -> Void
                    let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
                    let b: @convention(block) (NSObject, NSObject?) -> Void = { o, a in
                        MacClick.touchLog.append("\(name) -\(sname)"); orig(o, sel, a) }
                    method_setImplementation(m, imp_implementationWithBlock(b))
                } else if e == "B24@0:8@16" || e == "c24@0:8@16" {
                    typealias O = @convention(c) (NSObject, Selector, NSObject?) -> Bool
                    let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
                    let b: @convention(block) (NSObject, NSObject?) -> Bool = { o, a in
                        let r = orig(o, sel, a); MacClick.touchLog.append("\(name) -\(sname) → \(r)"); return r }
                    method_setImplementation(m, imp_implementationWithBlock(b))
                } else if e.hasPrefix("v28@0:8@16B24") || e.hasPrefix("v28@0:8@16c24") {
                    typealias O = @convention(c) (NSObject, Selector, NSObject?, Bool) -> Void
                    let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
                    let b: @convention(block) (NSObject, NSObject?, Bool) -> Void = { o, a, f in
                        MacClick.touchLog.append("\(name) -\(sname) \(f)"); orig(o, sel, a, f) }
                    method_setImplementation(m, imp_implementationWithBlock(b))
                }
            }
            free(list)
        }
    }

    static var isLive: Bool { (app?.value(forKey: "isActive") as? Bool) == true && (window?.value(forKey: "isKeyWindow") as? Bool) == true }

    static var state: String {
        let active = (app?.value(forKey: "isActive") as? Bool) ?? false
        let key = (window?.value(forKey: "isKeyWindow") as? Bool) ?? false
        return "app active \(active) · window key \(key)"
    }
}

/// E fix-up G1/G7/G8/G9 — `-MacClickSelfTest`: every toolbar item pressed with a real click (`MacClick`) at its point,
/// what AppKit's hit-test finds there, the hover state, and the window still dragging from the bar's empty part.
@MainActor
enum MacClickSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
            NSLog("[MacClick] row %@", rows.last ?? "")
        }
        /// A click's EFFECT: a row only when the window can take clicks (app active, window key). A locked Mac never
        /// makes the app active, AppKit then passes no first click on, and the row is left to T's real click.
        let live = MacClick.isLive
        func effect(_ name: String, _ ok: Bool, _ detail: String = "") {
            if live { row(name, ok, detail) } else { rows.append("T-CHECK \(name) — window can't be key here (\(MacClick.state)); seen: \(detail)") }
        }
        let layout = MacLayout.shared
        let lead = MacToolbarController.leadingID, trail = MacToolbarController.trailingID
        NSLog("[MacClick] start")
        await MacClick.activate()
        MacClick.traceTouches()
        MacClick.traceMouseDown()
        if UserDefaults.standard.bool(forKey: "MacClickTraceWindow") { MacClick.traceWindowMethods() }
        NSLog("[MacClick] activated · %@", MacClick.state)
        rows.append("INFO method: NSEvent mouse/key events → \(MacClick.viaWindow ? "NSWindow sendEvent:" : "NSApp postEvent:atStart:") at the control's window point · \(MacClick.state)")

        func point(_ id: String) -> CGPoint? {
            guard let r = MacToolbarProbe.rect[id] else { return nil }
            let item = MacToolbarProbe.trailingIDs.contains(id) ? trail : lead
            return MacClick.windowPoint(toolbarItem: item, CGPoint(x: r.midX, y: r.midY))
        }
        /// Hit-test + hover + click one control; `check` reads the effect after the click.
        func press(_ id: String, _ name: String, _ check: () -> (Bool, String)) async {
            guard let wp = point(id) else { row("\(name): on screen", false, "no probe rect for \(id)"); return }
            let item = MacToolbarProbe.trailingIDs.contains(id) ? trail : lead
            let h = MacClick.hit(wp)
            let inItem = MacClick.isDescendant(h.view, of: MacClick.itemView(item))
            let drag = MacClick.startsDrag(wp)
            row("\(name) — a press is a click, not a window drag", drag == false, "shouldStartWindowDrag \(drag.map { "\($0)" } ?? "n/a")")
            rows.append("INFO \(id) at window (\(Int(wp.x)), \(Int(wp.y))) · hit: \(h.chain)")
            rows.append("INFO   AppKit can-move-window chain: \(MacClick.moveChain(h.view))")
            if let host = MacToolbarController.shared.hosts[item]?.view, let r = MacToolbarProbe.rect[id], let hw = host.window {
                let pIn = host.convert(CGPoint(x: r.midX, y: r.midY), to: hw)
                let uh = hw.hitTest(pIn, with: nil)
                var names: [String] = [], cur = uh
                for _ in 0..<4 { guard let c = cur else { break }; names.append(String(describing: type(of: c)).prefix(50).description); cur = c.superview }
                rows.append("INFO   UIKit: host frame \(host.frame) in \(type(of: hw)) \(hw.bounds.size) · control \(r) · hit \(uh.map { $0.isDescendant(of: host) } ?? false ? "inside the host" : "OUTSIDE") \(names.joined(separator: " < "))")
            }
            await MacClick.hover(wp)
            let hovered = MacToolbarProbe.hover
            MacClick.touchLog = []
            await MacClick.click(wp)
            let (ok, detail) = check()
            effect("\(name) — click", ok, "\(detail) · hit in its item \(inItem) · hover \(hovered ?? "none")")
            rows += MacClick.touchLog.map { "INFO   touch \($0)" }
            MacClick.touchLog.forEach { NSLog("[MacClick] touch %@", $0) }
        }

        // Start: Library, Map, sidebar on, Librarian open.
        layout.sidebarVisible = true; layout.librarianOpen = true
        router.entryMode = .dashboard; await MacClick.settle(1.2)
        router.entryMode = .canvas; await MacClick.settle(1.5)
        var s = store.filterState(for: .corpus); s.viewMode = .systemGraph; store.setFilterState(s, for: .corpus)
        await MacClick.settle(1.0)
        rows.append("INFO window \(Int(layout.windowWidth)) pt · back enabled \(router.canGoBack) · \(MacClick.state)")

        // Positive control: a sidebar row (in the main UIWindow) pressed the same way.
        if let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first,
           let el = MacFixupSelfTest.elements(in: win, { _, i in i == "sidebar.today" }).first {
            let f = win.convert(el.accessibilityFrame, from: win.screen.coordinateSpace)
            if let wp = MacClick.windowPoint(ui: CGPoint(x: f.midX, y: f.midY)) {
                MacClick.touchLog = []
                await MacClick.click(wp)
                effect("CONTROL sidebar Today — click (main window)", router.entryMode == .dashboard, "mode \(router.entryMode) · hit \(MacClick.hit(wp).chain)")
                rows += MacClick.touchLog.map { "INFO   touch \($0)" }
                router.entryMode = .canvas; await MacClick.settle(1.2)
            }
        }

        // G9 — Back / Forward.
        await press("toolbar.back", "Back") { (router.entryMode == .dashboard, "mode \(router.entryMode)") }
        await MacClick.settle(0.8)
        await press("toolbar.forward", "Forward") { (router.entryMode == .canvas, "mode \(router.entryMode)") }
        await MacClick.settle(0.8)

        // View switch (Map | List | Cards).
        for (label, mode) in [("List", ViewMode.list), ("Cards", .grid), ("Map", .systemGraph)] {
            await press("toolbar.view.\(label)", "view switch \(label)") {
                let m = store.filterState(for: .corpus).viewMode
                return (label == "Cards" ? (m != .list && m != .systemGraph) : m == mode, "view \(m.rawValue)")
            }
            await MacClick.settle(0.8)
        }

        // G7 — the Librarian button closes and opens the panel.
        await press("toolbar.librarian", "Librarian (close)") { (!layout.librarianOpen, "open \(layout.librarianOpen)") }
        await MacClick.settle(0.6)
        await press("toolbar.librarian", "Librarian (open)") { (layout.librarianOpen, "open \(layout.librarianOpen)") }
        await MacClick.settle(0.6)

        // G8 — the search field: a click focuses it, typing searches.
        await press("toolbar.search", "Search field") {
            let fr = MacToolbarController.shared.hosts[trail]?.view.flatMap { MacLayoutSelfTest.firstResponder(in: $0) }
            return (fr != nil, "first responder \(fr.map { String(describing: type(of: $0)) } ?? "none")")
        }
        let focused = MacToolbarController.shared.hosts[trail]?.view.flatMap { MacLayoutSelfTest.firstResponder(in: $0) } != nil
        if focused && !MacClick.viaWindow { await MacClick.typeText("co"); await MacClick.settle(0.6) }   // window-direct keys stall
        effect("Search field — typing searches", router.librarian.searchText == "co", "text \"\(router.librarian.searchText)\" · Librarian open \(layout.librarianOpen)")
        router.librarian.searchText = ""
        MacToolbarController.shared.hosts[trail]?.view.flatMap { MacLayoutSelfTest.firstResponder(in: $0) }?.resignFirstResponder()
        await MacClick.settle(0.5)

        // G9 — the sidebar button (last: hiding the sidebar moves it).
        await press("toolbar.sidebar", "Sidebar button (hide)") { (!layout.sidebarVisible, "sidebar \(layout.sidebarVisible)") }
        await MacClick.settle(0.8)
        await press("toolbar.sidebar", "Sidebar button (show)") { (layout.sidebarVisible, "sidebar \(layout.sidebarVisible)") }
        await MacClick.settle(0.8)

        // + New Entry (opens the capture).
        await press("toolbar.newEntry", "+ New Entry") { (router.isCapturing || store.isInDetailView, "capturing \(router.isCapturing) detail \(store.isInDetailView)") }
        await MacClick.settle(1.0)

        // The bar's empty part still drags the window (between the view switch and the search).
        if let sw = point("toolbar.view.Cards"), let se = point("toolbar.search"), let w = MacClick.window,
           let before = w.value(forKey: "frame") as? CGRect {
            let wp = CGPoint(x: (sw.x + se.x) / 2 - 40, y: sw.y)
            let h = MacClick.hit(wp)
            rows.append("INFO empty bar at (\(Int(wp.x)), \(Int(wp.y))) · hit: \(h.chain)")
            let drag = MacClick.startsDrag(wp)
            row("the bar's empty part still drags the window", drag == true, "shouldStartWindowDrag \(drag.map { "\($0)" } ?? "n/a")")
            if let wb = MacClick.windowPoint(ui: CGPoint(x: 120, y: 26)) {   // the sidebar's strip under the title bar, beside the window buttons
                let d2 = MacClick.startsDrag(wb)
                row("the sidebar's top strip still drags the window", d2 == true, "shouldStartWindowDrag \(d2.map { "\($0)" } ?? "n/a")")
            }
            MacClick.send(MacClick.mouse(1, wp)); await MacClick.settle(0.05)
            for i in 1...6 { MacClick.send(MacClick.mouse(6, CGPoint(x: wp.x + CGFloat(i * 6), y: wp.y))); await MacClick.settle(0.03) }
            MacClick.send(MacClick.mouse(2, CGPoint(x: wp.x + 36, y: wp.y))); await MacClick.settle(0.4)
            let after = w.value(forKey: "frame") as? CGRect ?? before
            rows.append("INFO window drag from the empty bar: origin \(Int(before.minX)) → \(Int(after.minX)) (AppKit drags by the cursor, so a synthetic drag may not move it: T's check)")
        }

        let counted = rows.filter { $0.hasPrefix("PASS") || $0.hasPrefix("FAIL") }.count
        let held = rows.filter { $0.hasPrefix("T-CHECK") }.count
        return "[MacClickSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(counted - fails)/\(counted)\(held > 0 ? " · \(held) for T's real click" : "")\n" + rows.joined(separator: "\n")
    }
}
#endif
