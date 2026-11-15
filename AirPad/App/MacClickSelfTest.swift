#if DEBUG && targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import SpriteKit

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
        var live = false   // read after `activate()` (an unlocked Mac makes the app active and the window key there)
        func effect(_ name: String, _ ok: Bool, _ detail: String = "") {
            if live { row(name, ok, detail) } else { rows.append("T-CHECK \(name) — window can't be key here (\(MacClick.state)); seen: \(detail)") }
        }
        let layout = MacLayout.shared
        let lead = MacToolbarController.leadingID, trail = MacToolbarController.trailingID
        NSLog("[MacClick] start")
        await MacClick.activate()
        live = MacClick.isLive
        MacClick.traceTouches()
        MacClick.traceMouseDown()
        if UserDefaults.standard.bool(forKey: "MacClickTraceWindow") { MacClick.traceWindowMethods() }
        NSLog("[MacClick] activated · %@", MacClick.state)
        rows.append("INFO method: NSEvent mouse/key events → \(MacClick.viaWindow ? "NSWindow sendEvent:" : "NSApp postEvent:atStart:") at the control's window point · \(MacClick.state)")

        func point(_ id: String) -> CGPoint? {
            // E fix-up 2 — the controls are in the main window: its point straight from the window frame.
            if MacToolbarController.controlsInWindow {
                return MacToolbarProbe.windowRect[id].flatMap { MacClick.windowPoint(ui: CGPoint(x: $0.midX, y: $0.midY)) }
            }
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
            if MacToolbarController.controlsInWindow {
                // E fix-up 2 — the press goes to the main window's content (the hit below), which never asks the frame
                // view; its answer for the title-bar area is kept for the record. The real-click matrix proves the click.
                rows.append("INFO \(name) — frame view's own drag answer here: \(drag.map { "\($0)" } ?? "n/a") (not consulted: hit is content)")
            } else {
                row("\(name) — a press is a click, not a window drag", drag == false, "shouldStartWindowDrag \(drag.map { "\($0)" } ?? "n/a")")
            }
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

        // G9 — Back / Forward follow the place's NavigationStack: a new entry goes on it, ‹ closes it, › re-opens it.
        router.perform(.newEntry); await MacClick.settle(1.5)
        rows.append("INFO opened a new entry · back enabled \(router.canGoBack)")
        await press("toolbar.back", "Back") { (!router.canGoBack && router.canGoForward, "back \(router.canGoBack) · forward \(router.canGoForward)") }
        await MacClick.settle(0.8)
        await press("toolbar.forward", "Forward") { (router.canGoBack && !router.canGoForward, "back \(router.canGoBack) · forward \(router.canGoForward)") }
        await MacClick.settle(0.8)
        router.perform(.back); await MacClick.settle(1.0)

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
        func searchResponder() -> UIView? { MacLayoutSelfTest.toolbarSearchResponder() }
        await press("toolbar.search", "Search field") {
            let fr = searchResponder()
            return (fr != nil, "first responder \(fr.map { String(describing: type(of: $0)) } ?? "none")")
        }
        let focused = searchResponder() != nil
        if focused && !MacClick.viaWindow { await MacClick.typeText("co"); await MacClick.settle(0.6) }   // window-direct keys stall
        effect("Search field — typing searches", router.librarian.searchText == "co", "text \"\(router.librarian.searchText)\" · Librarian open \(layout.librarianOpen)")
        router.librarian.searchText = ""
        searchResponder()?.resignFirstResponder()
        await MacClick.settle(0.5)

        // G9 — the sidebar button (last: hiding the sidebar moves it).
        await press("toolbar.sidebar", "Sidebar button (hide)") { (!layout.sidebarVisible, "sidebar \(layout.sidebarVisible)") }
        await MacClick.settle(0.8)
        await press("toolbar.sidebar", "Sidebar button (show)") { (layout.sidebarVisible, "sidebar \(layout.sidebarVisible)") }
        await MacClick.settle(0.8)

        // + New Entry (opens the capture).
        await press("toolbar.newEntry", "+ New Entry") { (router.isCapturing || store.isInDetailView, "capturing \(router.isCapturing) detail \(store.isInDetailView)") }
        await MacClick.settle(1.0)

        // Content-area targets (the main window, below the bar): the sidebar's rows, the Librarian's header and
        // resize edges, the home's Hide. A press there must reach the app's view, not start a window drag.
        if let win = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first {
            layout.librarianOpen = true; layout.sidebarVisible = true
            router.entryMode = .canvas; await MacClick.settle(1.2)
            func target(_ id: String) async {
                guard let e = MacFixupSelfTest.elements(in: win, { _, i in i == id }).first else { rows.append("INFO \(id): not on screen"); return }
                let f = win.convert(e.accessibilityFrame, from: win.screen.coordinateSpace)
                guard let wp = MacClick.windowPoint(ui: CGPoint(x: f.midX, y: f.midY)) else { return }
                let h = MacClick.hit(wp)
                let inContent = h.chain.contains("UINSSceneView") && !h.chain.contains("Toolbar")
                let drag = MacClick.startsDrag(wp)
                row("\(id) — a press reaches the app's view (not a window drag)", inContent && drag == false,
                    "hit \(h.chain.prefix(70)) · drag \(drag.map { "\($0)" } ?? "n/a")")
            }
            for id in ["sidebar.today", "sidebar.recents", "sidebar.chats", "sidebar.library", "sidebar.journal",
                       "macLibrarianHistory", "macLibrarianExpand", "macLibrarianNewChat", "macLibrarianTry",
                       "macLibrarianHide.Try", "macLibrarianHide.Recent chats", "macLibrarianRecentChat", "macLibrarianAllChats",
                       "resize.sidebar", "resize.librarian"] { await target(id) }
            router.requestMacPanel(.history); await MacClick.settle(1.0)
            for id in ["macLibrarianBack", "macChatHistoryRow", "macChatHistoryActions"] { await target(id) }
            router.requestMacPanel(.history); await MacClick.settle(0.3)
            if let back = MacFixupSelfTest.elements(in: win, { _, i in i == "macLibrarianBack" }).first { _ = back.accessibilityActivate() }
            await MacClick.settle(0.6)
        }

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

#if DEBUG && targetEnvironment(macCatalyst)
/// E fix-up G2 — `-MacResizeSelfTest`: a scripted edge drag (the handle's own begin / move / end, 60 steps a second)
/// on the Librarian's and the sidebar's edge over Map, List and Cards. Per step: the main thread's time to apply the
/// width and lay the window out; per drag: how far it fell behind its 60 Hz schedule. `-MacResizeUnfrozen` = the old
/// per-event layout (A/B).
@MainActor
enum MacResizeSelfTest {
    /// Counts (and logs the first few of) SKView frames wider than 3,000 pt with the superview chain: a view laid out
    /// wider than its slot once made the Map's SpriteView grow every pass to Metal's texture limit (G2).
    static var hugeFrames = 0
    static func traceHugeSKView() {
        for selName in ["setFrame:", "setBounds:"] {
            guard let m = class_getInstanceMethod(SKView.self, NSSelectorFromString(selName)) else { continue }
            typealias O = @convention(c) (UIView, Selector, CGRect) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: O.self)
            let sel = method_getName(m)
            let b: @convention(block) (UIView, CGRect) -> Void = { v, r in
                if r.width > 3000 {
                    hugeFrames += 1
                    guard hugeFrames <= 3 else { orig(v, sel, r); return }
                    var chain: [String] = [], cur: UIView? = v.superview
                    for _ in 0..<10 { guard let c = cur else { break }; chain.append("\(String(describing: type(of: c)).prefix(40)) \(Int(c.frame.minX)),\(Int(c.frame.width))"); cur = c.superview }
                    NSLog("[G2] SKView %@ %@ ← %@", selName, "\(r)", chain.joined(separator: " < "))
                }
                orig(v, sel, r)
            }
            method_setImplementation(m, imp_implementationWithBlock(b))
        }
    }

    static func skViews(_ v: UIView) -> [UIView] {
        (v is SKView ? [v] : []) + v.subviews.flatMap { skViews($0) }
    }

    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        let unfrozen = UserDefaults.standard.bool(forKey: "MacResizeUnfrozen")
        let layout = MacLayout.shared
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first
        else { return "[MacResizeSelfTest] FAIL — no window" }
        traceHugeSKView()
        rows.append("INFO \(unfrozen ? "UNFROZEN (old per-event layout)" : "settled widths (G2)") · window \(Int(layout.windowWidth)) pt")
        layout.sidebarVisible = true; layout.librarianOpen = true
        layout.sidebarWidth = MacLayout.sidebarWidthDefault; layout.librarianWidth = MacLayout.librarianWidthDefault
        router.entryMode = .canvas
        func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }

        for (label, mode) in [("Map", ViewMode.systemGraph), ("List", .list), ("Cards", .grid)] {
            var st = store.filterState(for: .corpus); st.viewMode = mode; store.setFilterState(st, for: .corpus)
            await MacClick.settle(2.5)
            for edge in ["Librarian", "sidebar"] {
                let start = edge == "Librarian" ? layout.librarianWidth : layout.sidebarWidth
                let range = edge == "Librarian" ? MacLayout.librarianWidthRange : MacLayout.sidebarWidthRange
                // out to the max, back to the min, home: ~1.8 s of pointer at 60 Hz, 2–4 pt a step
                var targets: [CGFloat] = []
                var w = start
                for goal in [range.upperBound, range.lowerBound, start] {
                    let step: CGFloat = goal > w ? 3 : -3
                    while abs(goal - w) > 3 { w += step; targets.append(w) }
                    targets.append(goal); w = goal
                }
                var stepMs: [Double] = []
                let t0 = CACurrentMediaTime()
                layout.beginColumnDrag()
                for (i, target) in targets.enumerated() {
                    // the pointer's schedule: step i is due at t0 + i/60
                    let due = t0 + Double(i) / 60
                    let now = CACurrentMediaTime()
                    if due > now { try? await Task.sleep(nanoseconds: UInt64((due - now) * 1_000_000_000)) }
                    let a = CACurrentMediaTime()
                    if edge == "Librarian" { layout.librarianWidth = MacLayout.clamp(target, range) } else { layout.sidebarWidth = MacLayout.clamp(target, range) }
                    window.layoutIfNeeded()
                    for v in MacToolbarController.shared.hosts.values { v.view.layoutIfNeeded() }
                    stepMs.append((CACurrentMediaTime() - a) * 1000)
                }
                let late = (CACurrentMediaTime() - t0 - Double(targets.count - 1) / 60) * 1000
                let libW = MacFixupSelfTest.elements(in: window) { _, i in i == "macLibrarianColumn" }.first?.accessibilityFrame.width ?? 0
                if libW > MacLayout.librarianWidthRange.upperBound + 2 { hugeFrames += 1; NSLog("[G2] Librarian laid out %.0f pt wide", libW) }
                let e0 = CACurrentMediaTime()
                layout.endColumnDrag()
                window.layoutIfNeeded()
                let endMs = (CACurrentMediaTime() - e0) * 1000
                let p95 = pct(stepMs, 0.95), mx = stepMs.max() ?? 0
                // A pointer step ≤ 4 ms (p50); the content's own re-layout (≤ 10×/s) is in the p95/max; the drag never
                // falls more than 100 ms behind its 60 Hz schedule (the old per-event layout fell seconds behind).
                row("\(label) · \(edge) edge drag: pointer steps ≤ 4 ms (p50), stays on its 60 Hz schedule", pct(stepMs, 0.5) <= 4 && late <= 100,
                    String(format: "%d steps · step p50 %.2f p95 %.2f max %.1f ms · behind schedule %.0f ms · release %.1f ms",
                           targets.count, pct(stepMs, 0.5), p95, mx, late, endMs))
                await MacClick.settle(1.0)
            }
        }
        row("no runaway layout (no SKView wider than 3,000 pt, the Librarian within its range)", hugeFrames == 0, "\(hugeFrames) frames")
        let saved = UserDefaults.standard.double(forKey: MacLayout.librarianWidthKey)
        row("widths saved on release", abs(saved - Double(layout.librarianWidth)) < 0.5, "saved \(saved) · width \(layout.librarianWidth)")
        var st = store.filterState(for: .corpus); st.viewMode = .systemGraph; store.setFilterState(st, for: .corpus)
        return "[MacResizeSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - 1 - fails)/\(rows.count - 1)\n" + rows.joined(separator: "\n")
    }
}
#endif

#if DEBUG && targetEnvironment(macCatalyst)
/// E fix-up G3 — `-MacZoomFitSelfTest` (with `-OpenMap`): ⌘0 (the View menu's command) on the Map from rest, the Map's
/// rest state sampled after it, then trackpad pans and pinches through the pointer paths; the Map must come back to
/// rest (0 frames) after each. Then ⌘0 with Cards showing must reach only Cards.
@MainActor
enum MacZoomFitSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
            NSLog("[G3] %@", rows.last ?? "")
        }
        func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        guard let scene = CorpusPhysicsScene.debugCurrent, let view = scene.view else { return "[MacZoomFitSelfTest] FAIL — no Map" }
        /// Waits up to `limit` s for rest; the samples on the way.
        func untilRest(_ label: String, limit: Double = 6) async -> (Bool, Double) {
            let t0 = CACurrentMediaTime()
            var last = ""
            while CACurrentMediaTime() - t0 < limit {
                if scene.debugRestPaused { return (true, CACurrentMediaTime() - t0) }
                let l = scene.debugRestLine
                if l != last { NSLog("[G3] %@ +%.2fs %@", label, CACurrentMediaTime() - t0, l); last = l }
                await settle(0.1)
            }
            rows.append("INFO   \(label) still awake: \(scene.debugRestLine)")
            return (false, limit)
        }
        let mid = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        func pans(_ n: Int) async {
            for i in 0..<n {
                scene.debugPointerGesture { s in
                    for _ in 0..<8 { s.debugPointerPan(by: CGPoint(x: i % 2 == 0 ? 6 : -6, y: 3)) }
                }
                await settle(0.016)
            }
        }
        func pinches(_ n: Int) async {
            for i in 0..<n {
                scene.debugPointerGesture { s in s.debugPointerZoom(by: i % 2 == 0 ? 1.04 : 1 / 1.04, at: mid) }
                await settle(0.016)
            }
        }
        rows.append("INFO view \(Int(view.bounds.width))×\(Int(view.bounds.height))")
        CorpusPhysicsScene.debugLabelLagOn = true
        func lag(_ name: String, _ body: () async -> Void) async {
            CorpusPhysicsScene.debugLabelLagMax = 0; CorpusPhysicsScene.debugLabelLagFrames = 0
            await body()
            let m = CorpusPhysicsScene.debugLabelLagMax
            row("pills stay on their orbs — \(name)", m <= 1.0, String(format: "max %.1f pt off over %d frames", m, CorpusPhysicsScene.debugLabelLagFrames))
        }
        let (r0, _) = await untilRest("launch", limit: 20)
        row("the Map rests before ⌘0", r0, scene.debugRestLine)

        // Control: the same pans + pinches before any ⌘0.
        await lag("pans + pinches at the start scale") { await pans(30); await pinches(20) }
        let (rc, tc) = await untilRest("control gestures")
        row("control: rests after pans + pinches (no ⌘0)", rc, String(format: "%.1f s", tc))

        for k in 1...3 {
            let zBefore = CorpusPhysicsScene.debugKeyboardZooms
            var r1 = false, t1 = 0.0
            await lag("the ⌘0 #\(k) glide") {
                router.perform(.zoomFit)
                await settle(0.05)
                (r1, t1) = await untilRest("after ⌘0 #\(k)")
            }
            row("⌘0 #\(k) reaches the Map once", CorpusPhysicsScene.debugKeyboardZooms == zBefore + 1, "\(CorpusPhysicsScene.debugKeyboardZooms - zBefore) calls")
            row("⌘0 #\(k): the Map comes back to rest", r1, String(format: "%.1f s · %@", t1, scene.debugRestLine))
            // pan right away; at ⌘0's full zoom-out the pans run past the bounds and the spring brings the camera back
            var r2 = false, t2 = 0.0
            await lag("pans + pinches + spring-back after ⌘0 #\(k)") {
                await pans(30); await pinches(20)
                (r2, t2) = await untilRest("gestures after ⌘0 #\(k)")
            }
            row("⌘0 #\(k) then pans + pinches: rests again", r2, String(format: "%.1f s · %@", t2, scene.debugRestLine))
        }
        // ⌘0 mid-gesture: a pinch while the glide runs must take over (the glide is cancelled).
        router.perform(.zoomFit); await settle(0.08)
        scene.debugPointerGesture { s in s.debugPointerZoom(by: 1.2, at: mid) }
        let kzAfter = scene.debugRestLine.contains("kz=1")
        row("a pinch during the ⌘0 glide takes over (glide cancelled)", !kzAfter, scene.debugRestLine)
        _ = await untilRest("after mid-glide pinch")

        // View scoping: Cards showing → ⌘0 resets the card size only.
        var st = store.filterState(for: .corpus); st.viewMode = .grid; store.setFilterState(st, for: .corpus)
        await settle(2.0)
        UserDefaults.standard.set(300.0, forKey: "mac.cards.width.v1"); await settle(0.5)
        let zBefore = CorpusPhysicsScene.debugKeyboardZooms
        router.perform(.zoomFit); await settle(0.6)
        let w = UserDefaults.standard.double(forKey: "mac.cards.width.v1")
        row("Cards: ⌘0 sets the default card size", abs(w - 210) < 0.5, "width \(w)")
        row("Cards: ⌘0 doesn't reach the (hidden) Map", CorpusPhysicsScene.debugKeyboardZooms == zBefore, "\(CorpusPhysicsScene.debugKeyboardZooms - zBefore) Map zooms")
        st.viewMode = .systemGraph; store.setFilterState(st, for: .corpus); await settle(2.0)
        // Map showing → ⌘0 doesn't touch the card size.
        UserDefaults.standard.set(300.0, forKey: "mac.cards.width.v1"); await settle(0.3)
        router.perform(.zoomFit); await settle(0.6)
        let w2 = UserDefaults.standard.double(forKey: "mac.cards.width.v1")
        row("Map: ⌘0 leaves the card size alone", abs(w2 - 300) < 0.5, "width \(w2)")
        UserDefaults.standard.set(210.0, forKey: "mac.cards.width.v1")
        let (rf, _) = await untilRest("final")
        row("final: the Map at rest (0 frames)", rf, scene.debugRestLine)
        return "[MacZoomFitSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.filter { !$0.hasPrefix("INFO") }.count - fails)/\(rows.filter { !$0.hasPrefix("INFO") }.count)\n" + rows.joined(separator: "\n")
    }
}
#endif

#if DEBUG && targetEnvironment(macCatalyst)
/// E fix-up G4 — `-MacCardSizeSelfTest` (with `-OpenMap`): an orb's preview card at 1,180 / 1,350 / 1,920 pt with the
/// Librarian floating and docked: at most 420 pt wide, centred in the VISIBLE Map (the Map minus a floating Librarian),
/// never under the floating panel, its 5:7 height inside the Map. Stills `<tmp>/macshots/g4-<width>-<mode>.png`.
@MainActor
enum MacCardSizeSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        let layout = MacLayout.shared
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let storeCanvas = store.canvasState else { return "[MacCardSizeSelfTest] FAIL — no window / Map" }
        let restore = (scene.sizeRestrictions?.minimumSize, scene.sizeRestrictions?.maximumSize, layout.sidebarVisible, layout.librarianWidth)
        func resize(_ w: CGFloat) async {
            guard let r = scene.sizeRestrictions else { return }
            let size = CGSize(width: w, height: 840)
            r.minimumSize = size; r.maximumSize = size
            var origin = scene.effectiveGeometry.systemFrame.origin
            origin.x = max(0, min(origin.x, scene.screen.bounds.width - w))
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: origin, size: size)))
            await settle(1.6)
        }
        // The Map's scene: the window's SpriteKit view with the most orbs (debugCurrent can be another, newer scene).
        func mapScene() -> CorpusPhysicsScene? {
            let wins = scene.windows
            let all = wins.flatMap { MacResizeSelfTest.skViews($0) }.compactMap { ($0 as? SKView)?.scene as? CorpusPhysicsScene }
            return all.max { $0.debugOrbIDs.count < $1.debugOrbIDs.count }
        }
        let diag = scene.windows.flatMap { MacResizeSelfTest.skViews($0) }.map { v -> String in
            let sc = (v as? SKView)?.scene
            return "\(type(of: v)) scene=\(sc.map { "\(type(of: $0))" } ?? "nil") orbs=\((sc as? CorpusPhysicsScene)?.debugOrbIDs.count ?? -1)"
        }
        rows.append("INFO place \(router.entryMode) · view \(store.filterState(for: .corpus).viewMode.rawValue) · SKViews: \(diag.joined(separator: "; ")) · debugCurrent orbs \(CorpusPhysicsScene.debugCurrent?.debugOrbIDs.count ?? -1)")
        guard let mapSc = mapScene(), mapSc.debugOrbIDs.count > 4 else { return "[MacCardSizeSelfTest] FAIL — no Map scene in the window\n" + rows.joined(separator: "\n") }
        let ids = mapSc.debugOrbIDs   // the orbs this Map draws
        let canvas = mapSc.canvasState ?? storeCanvas
        guard ids.count > 4 else { return "[MacCardSizeSelfTest] FAIL — no orbs on the Map (\(ids.count))" }
        rows.append("INFO \(ids.count) titled orbs · canvas \(canvas === mapSc.canvasState ? "is" : "is NOT") the Map's")
        layout.librarianOpen = true
        let configs: [(CGFloat, String, Bool, CGFloat)] = [   // width, label, sidebar, Librarian width
            (1180, "floating", true, 370), (1180, "docked", false, 370),
            (1350, "docked", true, 370), (1350, "floating", true, 520),
            (1920, "docked", true, 370)]
        for (k, (width, mode, side, lib)) in configs.enumerated() {
            await resize(width)
            layout.sidebarVisible = side; layout.librarianWidth = lib
            await settle(1.0)
            guard let sk = mapSc.view, let win = sk.window else { row("\(Int(width)) \(mode): Map on screen", false); continue }
            let floats = layout.librarianFloats
            row("\(Int(width)) pt \(mode): the Librarian \(mode == "floating" ? "floats" : "is docked")", floats == (mode == "floating"),
                "floats \(floats) · Map \(Int(sk.bounds.width)) pt")
            canvas.cardedNodeID = ids[k % ids.count]
            mapSc.wakeFromRest("cardTest")   // as a tap does
            await settle(2.8)
            let d = canvas.focalNodeFinalDiameter
            let c = sk.convert(canvas.focalNodeScreenPosition, to: win)
            let card = CGRect(x: c.x - d / 2, y: c.y - d * 0.7, width: d, height: d * 1.4)
            let map = sk.convert(sk.bounds, to: win)
            var visible = map
            var panel: CGRect?
            if layout.librarianOpen && floats {
                let pw = layout.floatingLibrarianWidth
                panel = CGRect(x: map.maxX - 10 - pw, y: map.minY + 10, width: pw, height: map.height - 20)
                visible.size.width -= pw + 20
            }
            let path = RunningOnMac.snapshot("g4-\(Int(width))-\(mode)")
            row("\(Int(width)) pt \(mode): card ≤ 420 pt wide", d <= 420.5 && d >= 160, String(format: "card %.0f × %.0f", d, d * 1.4))
            // the card sits on its orb, which settles within ~20 pt of the glide's target (live vs resting position)
            row("\(Int(width)) pt \(mode): centred in the visible Map (±24 pt)", abs(card.midX - visible.midX) <= 24 && abs(card.midY - visible.midY) <= 24,
                String(format: "card centre (%.0f, %.0f) · visible centre (%.0f, %.0f)", card.midX, card.midY, visible.midX, visible.midY))
            row("\(Int(width)) pt \(mode): never under the floating panel, inside the Map", (panel.map { !card.intersects($0) } ?? true) && map.insetBy(dx: -1, dy: -1).contains(card),
                String(format: "card x %.0f–%.0f y %.0f–%.0f · panel x %@ · Map %.0f–%.0f", card.minX, card.maxX, card.minY, card.maxY,
                       panel.map { String(format: "%.0f–%.0f", $0.minX, $0.maxX) } ?? "—", map.minX, map.maxX))
            rows.append("INFO still \(path ?? "none")")
            canvas.cardedNodeID = nil
            mapSc.wakeFromRest("cardTest")
            await settle(1.2)
        }
        if let r = scene.sizeRestrictions { r.minimumSize = restore.0 ?? .zero; r.maximumSize = restore.1 ?? .zero }
        layout.sidebarVisible = restore.2; layout.librarianWidth = restore.3
        return "[MacCardSizeSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.filter { !$0.hasPrefix("INFO") }.count - fails)/\(rows.filter { !$0.hasPrefix("INFO") }.count)\n" + rows.joined(separator: "\n")
    }
}
#endif

#if DEBUG && targetEnvironment(macCatalyst)
/// E fix-up G5 + G6 — `-MacChatsPanelSelfTest` (with `-UITestLibraryFresh -UITestSeedChats -MacWindowSize 1350x840`):
/// chats live in the Librarian panel on the Mac. Buttons are pressed through accessibility (this locked Mac takes no
/// clicks: T's real-click check). Stills `<tmp>/macshots/g5-*.png`.
@MainActor
enum MacChatsPanelSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first
        else { return "[MacChatsPanelSelfTest] FAIL — no window" }
        let layout = MacLayout.shared
        func els(_ id: String) -> [NSObject] { MacFixupSelfTest.elements(in: window) { _, i in i == id } }
        /// Distinct on-screen elements (the walker reaches one SwiftUI element by several paths).
        func count(_ id: String) -> Int { Set(els(id).map { "\($0.accessibilityFrame)" }).count }
        func has(_ id: String) -> Bool { !els(id).isEmpty }
        /// The history is up: its rows (or, with no chats, its empty line) — the ScrollView exposes no container id.
        func historyShown() -> Bool { has("macChatHistoryRow") }
        @discardableResult func press(_ id: String) async -> Bool {
            guard let e = els(id).first else { return false }
            let ok = e.accessibilityActivate()
            await settle(0.9)
            return ok
        }
        func noSheet() -> Bool {
            window.rootViewController?.presentedViewController == nil
                && (MacWindowChrome.nsWindow?.value(forKey: "attachedSheet") == nil)
        }
        await router.chatStore.loadIfNeeded()
        // A few more chats for the history (the seed has one).
        let now = Date()
        for (i, q) in ["Which entries mention the Bolex?", "Summarise my Field Notes", "What did I plan for the workshop?"].enumerated() {
            let t = now.addingTimeInterval(-Double(i + 1) * 3600 * 20)
            router.chatStore.upsert(Chat(id: UUID(), title: q, createdAt: t, updatedAt: t, messages: [
                ChatSession.Message(role: .user, text: q),
                ChatSession.Message(role: .assistant, text: "A seeded answer (\(i + 1)).")]))
        }
        await settle(0.5)
        let chats = router.chatStore.chats
        rows.append("INFO \(chats.count) chats · window \(Int(layout.windowWidth)) pt")
        router.entryMode = .canvas
        layout.librarianOpen = false; await settle(1.0)

        // Sidebar › Chats (closed panel) → the panel opens on its history; no sheet.
        await press("sidebar.chats"); await settle(0.8)
        row("sidebar Chats opens the Librarian", layout.librarianOpen)
        row("…on its history, in the panel", historyShown(), "history \(historyShown())")
        row("…and no Chats sheet", noSheet())
        row("the history lists every chat", count("macChatHistoryRow") == chats.count, "\(count("macChatHistoryRow")) rows / \(chats.count)")
        row("each row has its ··· (rename / pin / delete)", count("macChatHistoryActions") == chats.count, "\(count("macChatHistoryActions"))")
        row("‹ back shows in the header", has("macLibrarianBack"))
        _ = RunningOnMac.snapshot("g5-history")

        // A row opens the chat in the panel.
        await press("macChatHistoryRow"); await settle(0.6)
        row("a history row opens the chat in the panel", !historyShown() && router.chat.id == chats.first?.id && noSheet(),
            "chat \(router.chat.id == chats.first?.id) · history gone \(!historyShown())")
        row("‹ back in the chat", has("macLibrarianBack"))
        _ = RunningOnMac.snapshot("g5-chat")
        // ‹ → home (the first-open state).
        await press("macLibrarianBack")
        row("‹ returns to the panel's home", has("macLibrarianEmpty") && !has("macLibrarianBack"))
        _ = RunningOnMac.snapshot("g5-home")
        // The clock: history in the panel, a second press back home.
        await press("macLibrarianHistory")
        row("the clock shows the history in the panel", historyShown())
        await press("macLibrarianHistory")
        row("the clock again: back to home", has("macLibrarianEmpty") && !historyShown())
        // Home › Recent chats › a chat; › All chats → history.
        await press("macLibrarianRecentChat")
        row("home's recent chat opens in the panel", !has("macLibrarianEmpty") && has("macLibrarianBack") && noSheet())
        await press("macLibrarianBack")
        await press("macLibrarianAllChats")
        row("home's All chats → the history in the panel", historyShown() && noSheet())
        await press("macLibrarianBack")

        // An entry's pinned chat (the old sheet's deep link) → straight into that chat, in the panel.
        if let target = chats.last {
            layout.librarianOpen = false; await settle(0.6)
            router.pendingChatToOpen = target.id
            router.showChatsList = true
            await settle(1.5)
            row("a pinned-chat link opens that chat in the panel", layout.librarianOpen && router.chat.id == target.id && noSheet() && has("macLibrarianBack"),
                "open \(layout.librarianOpen) · chat \(router.chat.id == target.id) · sheet \(!noSheet())")
            await press("macLibrarianBack")
        }

        // Search: a chat matching the query opens in the panel (the results clear).
        router.librarian.searchText = "Bolex"; await settle(1.2)
        row("search lists matching chats", has("macSearchChat"), "\(count("macSearchChat")) chats")
        await press("macSearchChat")
        row("a chat result opens in the panel", router.librarian.searchText.isEmpty && has("macLibrarianBack") && router.chat.messages.first?.text.contains("Bolex") == true)
        await press("macLibrarianBack")

        // Expand: about half the window (the content keeps its minimum), toggles back, never saved.
        layout.sidebarVisible = true
        let w0 = layout.librarianWidth
        let saved0 = UserDefaults.standard.double(forKey: MacLayout.librarianWidthKey)
        await press("macLibrarianExpand"); await settle(0.6)
        let want = max(w0, min(layout.windowWidth / 2, layout.windowWidth - layout.sidebarWidth - 1 - MacLayout.contentMinWidth - 1)).rounded()
        row("expand widens the Librarian (half the window, content ≥ 616 pt)", layout.librarianExpanded && abs(layout.librarianWidth - want) < 1 && !layout.librarianFloats,
            "width \(Int(w0)) → \(Int(layout.librarianWidth)) (want \(Int(want))) · floats \(layout.librarianFloats)")
        row("expanded width isn't saved as the remembered width", UserDefaults.standard.double(forKey: MacLayout.librarianWidthKey) == saved0)
        await press("macLibrarianRecentChat"); await settle(0.5)
        _ = RunningOnMac.snapshot("g5-expanded-chat")
        await press("macLibrarianExpand"); await settle(0.6)
        row("expand toggles back", !layout.librarianExpanded && abs(layout.librarianWidth - w0) < 1, "width \(Int(layout.librarianWidth))")
        // The header at the narrowest Librarian (300 pt), in a chat: ‹ · title · mode · new chat · clock · expand.
        layout.librarianWidth = MacLayout.librarianWidthRange.lowerBound; await settle(0.8)
        // the docked panel ends at the window's right edge (screen points, as accessibility frames are)
        let winRight = UIAccessibility.convertToScreenCoordinates(window.bounds, in: window).maxX
        let expandF = els("macLibrarianExpand").first?.accessibilityFrame ?? .zero
        let backF = els("macLibrarianBack").first?.accessibilityFrame ?? .zero
        row("at 300 pt the header fits: ‹ … expand inside the panel", expandF.width > 0 && expandF.maxX <= winRight - 8 && backF.minX >= winRight - 300,
            String(format: "‹ minX %.0f · expand maxX %.0f · panel %.0f–%.0f", backF.minX, expandF.maxX, winRight - 300, winRight))
        _ = RunningOnMac.snapshot("g5-chat-300")
        layout.librarianWidth = w0; await settle(0.5)
        await press("macLibrarianBack")

        // G6 — each home section hides (remembered) and comes back from the View menu.
        UserDefaults.standard.set(false, forKey: MacLibrarianHome.hideTryKey)
        UserDefaults.standard.set(false, forKey: MacLibrarianHome.hideRecentKey)
        await settle(0.6)
        let tryBefore = count("macLibrarianTry")
        await press("macLibrarianHide.Try")
        row("G6: Try hides", els("macLibrarianTry").isEmpty && tryBefore > 0 && UserDefaults.standard.bool(forKey: MacLibrarianHome.hideTryKey),
            "\(tryBefore) → \(count("macLibrarianTry"))")
        await press("macLibrarianHide.Recent chats")
        row("G6: Recent chats hides", els("macLibrarianRecentChat").isEmpty && UserDefaults.standard.bool(forKey: MacLibrarianHome.hideRecentKey))
        _ = RunningOnMac.snapshot("g5-home-hidden")
        let firedTry = MacMenuSelfTest.fire(menu: "View", title: "Librarian Suggestions")
        let firedRecent = MacMenuSelfTest.fire(menu: "View", title: "Librarian Recent Chats")
        await settle(1.0)
        row("G6: View › Librarian Suggestions / Recent Chats bring them back", firedTry && firedRecent && !els("macLibrarianTry").isEmpty && !els("macLibrarianRecentChat").isEmpty,
            "menu items fired \(firedTry)/\(firedRecent) · try \(count("macLibrarianTry")) · recent \(count("macLibrarianRecentChat"))")
        return "[MacChatsPanelSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.filter { !$0.hasPrefix("INFO") }.count - fails)/\(rows.filter { !$0.hasPrefix("INFO") }.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
