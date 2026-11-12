#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

/// Mac batch C1 — `-MacMenuSelfTest`: reads the REAL menu bar (AppKit's `NSApp.mainMenu`, through the runtime), checks
/// each AirPad item's title and key equivalent, and fires items the way a click does (`NSMenu
/// performActionForItemAtIndex:`), asserting what each one did. Logs the whole menu bar too (the evidence of what is in
/// it). Run on the isolated Mac copy, Sample Library scratch.
@MainActor
enum MacMenuSelfTest {

    private struct Item {
        let menu: NSObject
        let index: Int
        let title: String
        let key: String
        let mods: UInt
        let enabled: Bool
    }

    private static let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20

    private static var mainMenu: NSObject? {
        guard let cls = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = cls.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        return app.value(forKey: "mainMenu") as? NSObject
    }

    private static func items(_ menu: NSObject) -> [Item] {
        menu.perform(NSSelectorFromString("update"))   // runs validation, so `enabled` is current
        let array = menu.value(forKey: "itemArray") as? [NSObject] ?? []
        return array.enumerated().map { i, it in
            Item(menu: menu, index: i, title: it.value(forKey: "title") as? String ?? "",
                 key: it.value(forKey: "keyEquivalent") as? String ?? "",
                 mods: (it.value(forKey: "keyEquivalentModifierMask") as? NSNumber)?.uintValue ?? 0,
                 enabled: (it.value(forKey: "enabled") as? NSNumber)?.boolValue ?? false)
        }
    }

    private static func submenu(_ title: String) -> NSObject? {
        guard let main = mainMenu else { return nil }
        let array = main.value(forKey: "itemArray") as? [NSObject] ?? []
        return array.first { ($0.value(forKey: "title") as? String) == title }?.value(forKey: "submenu") as? NSObject
    }

    private static func find(_ menuTitle: String, _ title: String) -> Item? {
        submenu(menuTitle).flatMap { items($0).first { $0.title == title } }
    }

    private static func fire(_ item: Item) {
        typealias Perform = @convention(c) (AnyObject, Selector, Int) -> Void
        let sel = NSSelectorFromString("performActionForItemAtIndex:")
        let imp = item.menu.method(for: sel)
        unsafeBitCast(imp, to: Perform.self)(item.menu, sel, item.index)
    }

    /// Fire `menu › title` as a click does; false if it's missing or disabled.
    static func fire(menu: String, title: String) -> Bool {
        guard let i = find(menu, title), i.enabled else { return false }
        fire(i); return true
    }

    private static func shortcut(_ i: Item) -> String {
        var s = ""
        if i.mods & control != 0 { s += "⌃" }
        if i.mods & option != 0 { s += "⌥" }
        if i.mods & shift != 0 { s += "⇧" }
        if i.mods & command != 0 { s += "⌘" }
        return i.key.isEmpty ? "" : s + i.key.uppercased()
    }

    /// The menu bar as text: `Menu › Item  ⌘K  (disabled)`.
    static func dump() -> [String] {
        guard let main = mainMenu else { return ["(no NSApp.mainMenu)"] }
        var lines: [String] = []
        func walk(_ menu: NSObject, _ prefix: String) {
            for i in items(menu) where !(i.title.isEmpty && i.key.isEmpty) {
                let arr = menu.value(forKey: "itemArray") as? [NSObject] ?? []
                let sub = arr[i.index].value(forKey: "submenu") as? NSObject
                lines.append("\(prefix)\(i.title)\(shortcut(i).isEmpty ? "" : "  \(shortcut(i))")\(i.enabled || sub != nil ? "" : "  (disabled)")")
                if let sub, !prefix.isEmpty || true { walk(sub, prefix + "    ") }
            }
        }
        walk(main, "")
        return lines
    }

    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func settle(_ s: Double = 1.2) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func presented() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for w in scenes.flatMap(\.windows) {
                var vc = w.rootViewController?.presentedViewController
                while let next = vc?.presentedViewController { vc = next }
                if let vc { return vc }
            }
            return nil
        }
        func dismissPresented() async {
            presented()?.dismiss(animated: false)
            router.showSettings = false; router.showNewCollection = false
            await settle(0.8)
        }
        func firstResponderIsText() -> Bool {
            final class Probe { static weak var found: UIResponder? }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            func search(_ v: UIView) -> UIResponder? {
                if v.isFirstResponder { return v }
                for s in v.subviews { if let r = search(s) { return r } }
                return nil
            }
            for w in scenes.flatMap(\.windows) { if let r = search(w), r is UITextField || r is UITextView { return true } }
            return false
        }

        // 1. The items, their titles and keys.
        let expected: [(menu: String, title: String, key: String)] = [
            ("AirPad", "Settings…", "⌘,"),
            ("File", "New Entry", "⌘N"), ("File", "New Collection", "⇧⌘N"), ("File", "Close Window", "⌘W"),
            ("File", "Export Entry…", "⇧⌘E"),
            ("Edit", "Find", "⌘F"),
            ("View", "Map", "⌘1"), ("View", "List", "⌘2"), ("View", "Cards", "⌘3"), ("View", "Librarian", "⌘L"),
            ("Go", "Back", "⌘["), ("Go", "Forward", "⌘]"), ("Go", "Today", "⌘0"),
        ]
        for e in expected {
            let i = find(e.menu, e.title)
            row("menu/\(e.menu)›\(e.title) \(e.key)", i.map(shortcut) == e.key, "found=\(i.map { "\($0.title) \(shortcut($0))" } ?? "nil")")
        }
        let all = dump()
        row("menu/no ⌃⌘S binding (kept for batch D)", !all.contains { $0.hasSuffix("⌃⌘S") }, "")
        row("menu/no Help item", !all.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("AirPad Help") })
        row("menu/no Print", !all.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Print") })
        let dead = ["Duplicate", "Move", "Rename…", "Export As…", "Show Toolbar", "Customize Toolbar…", "Close All"]
        row("menu/no document or toolbar items", !all.contains { dead.contains($0.trimmingCharacters(in: .whitespaces).components(separatedBy: "  ")[0]) })
        let view = submenu("View").map { items($0).map(\.title).filter { ["Map", "List", "Cards", "Librarian"].contains($0) } } ?? []
        row("menu/View in order", view == ["Map", "List", "Cards", "Librarian"], "\(view)")
        let keys = all.compactMap { l -> String? in
            guard let r = l.range(of: "  ", options: .backwards) else { return nil }
            let k = String(l[r.upperBound...]).replacingOccurrences(of: "  (disabled)", with: "")
            return k.hasPrefix("⌘") || k.hasPrefix("⇧") || k.hasPrefix("⌥") || k.hasPrefix("⌃") ? k : nil
        }
        let dupes = Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        row("menu/no shortcut used twice", dupes.isEmpty, "dupes=\(dupes)")

        // 2. Fire them.
        func go(_ menu: String, _ title: String) async -> Bool {
            guard let i = find(menu, title) else { return false }
            guard i.enabled else { return false }
            fire(i); await settle(); return true
        }
        row("fire/Go›Today → Dashboard", await go("Go", "Today") && router.entryMode == .dashboard, "mode=\(router.entryMode)")
        row("fire/View›List → List", await go("View", "List") && router.entryMode == .canvas
            && store.filterState(for: .corpus).viewMode == .list, "mode=\(router.entryMode) view=\(store.filterState(for: .corpus).viewMode)")
        row("fire/View›Cards → Cards", await go("View", "Cards") && store.filterState(for: .corpus).viewMode == .grid)
        row("fire/View›Map → Map", await go("View", "Map") && store.filterState(for: .corpus).viewMode == .systemGraph)
        row("state/Back disabled at the top", find("Go", "Back")?.enabled == false)
        row("state/Export disabled with no entry open", find("File", "Export Entry…")?.enabled == false)
        row("fire/View›Librarian raises it", await go("View", "Librarian") && !router.librarianAtPeek, "atPeek=\(router.librarianAtPeek)")
        row("fire/View›Librarian again lowers it", await go("View", "Librarian") && router.librarianAtPeek, "atPeek=\(router.librarianAtPeek)")
        row("fire/Edit›Find focuses the search", await go("Edit", "Find") && firstResponderIsText() && !router.librarianAtPeek,
            "text focused=\(firstResponderIsText()) atPeek=\(router.librarianAtPeek)")
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        _ = await go("View", "Librarian"); await settle(0.5)
        if !router.librarianAtPeek { _ = await go("View", "Librarian") }

        // Open an entry from the List, as a click does, then Back / Forward / Export.
        _ = await go("View", "List")
        if let entry = store.nodes.first(where: { !$0.isPrivate && !$0.title.isEmpty }) {
            router.pendingNodeNavigationID = entry.id
            await settle(1.5)
            row("open/an entry", store.isInDetailView && router.openEntryID == entry.id, "depth=\(store.detailViewDepth)")
            row("fire/File›Export Entry… opens Export", await go("File", "Export Entry…") && presented() != nil,
                "presented=\(presented().map { String(describing: type(of: $0)) } ?? "nil")")
            await dismissPresented()
            row("fire/Go›Back closes it", await go("Go", "Back") && !store.isInDetailView, "depth=\(store.detailViewDepth)")
            row("fire/Go›Forward re-opens it", await go("Go", "Forward") && store.isInDetailView && router.openEntryID == entry.id,
                "depth=\(store.detailViewDepth)")
            row("fire/View›Map from an entry shows the Map", await go("View", "Map") && !store.isInDetailView
                && store.filterState(for: .corpus).viewMode == .systemGraph, "depth=\(store.detailViewDepth)")
        } else {
            row("open/an entry", false, "no entry")
        }
        row("fire/File›New Collection opens its sheet", await go("File", "New Collection") && router.showNewCollection && presented() != nil)
        await dismissPresented()
        row("fire/Settings… opens Settings", await go("AirPad", "Settings…") && router.showSettings && presented() != nil)
        await dismissPresented()
        let before = store.nodes.count
        row("fire/File›New Entry opens a new entry", await go("File", "New Entry") && router.isCapturing && store.isInDetailView,
            "capturing=\(router.isCapturing) depth=\(store.detailViewDepth) nodes \(before)→\(store.nodes.count)")
        row("state/New Entry disabled while capturing", find("File", "New Entry")?.enabled == false)
        _ = await go("Go", "Back"); await settle(1.5)
        row("fire/Go›Back leaves the empty capture", !router.isCapturing && !store.isInDetailView,
            "capturing=\(router.isCapturing) depth=\(store.detailViewDepth)")

        // Last: Close Window. For a one-window app it is the window's close button, which ends the app: the result is
        // logged first, and the harness checks the app has quit (`[MacMenuSelfTest] closing` then the process exits).
        let menuDump = dump()
        let report = "[MacMenuSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.joined(separator: "\n") + "\n[MacMenuSelfTest] menu bar:\n" + menuDump.joined(separator: "\n")
        NSLog("%@", report)
        NSLog("[MacMenuSelfTest] closing: visible windows %d", RunningOnMac.visibleWindowCount)
        _ = await go("File", "Close Window"); await settle(3)
        NSLog("[MacMenuSelfTest] after Close Window: visible windows %d", RunningOnMac.visibleWindowCount)
        return "[MacMenuSelfTest] done"
    }
}


/// Mac fix-up X7 — `-CaptureClickSelfTest`: a new entry from the "+" (as the button does), text typed, Apple's proposals
/// arrived (T's step 12), then REAL clicks: mouse-down/up events built by AppKit and sent into the app's own window at
/// the pill's place, through the window's hit-testing like a trackpad click. Logs what the click hits; checks Done
/// leaves the new-entry state.
/// Mac fix-up X7 — `-CaptureClickSelfTest` (Sample scratch): T's step 12 on the Mac. A new entry from the "+" (as the
/// button does), text typed, Apple's proposals arrived; then the Proposals sheet (`-ProposalsScroll`): it is attached to
/// the window (a window with an attached sheet takes no clicks — why Done and Delete behind it "didn't respond"), it fits
/// on the Mac and has its own Done, which closes it; then the entry's Done leaves the new-entry state and applies the
/// title. Buttons are pressed through accessibility: a locked Mac can't make the app active, and AppKit drops synthetic
/// clicks and scrolls to an inactive app (measured: none reached UIKit, even on the known-good "+"), so the real click is
/// T's check.
@MainActor
enum CaptureClickSelfTest {
    private static var nsWindow: NSObject? {
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return nil }
        return (app.value(forKey: "windows") as? [NSObject])?.first { String(describing: type(of: $0)).contains("UINSWindow") }
    }

    /// The accessibility elements with this label.
    static func elementObjects(_ label: String, in window: UIWindow) -> [NSObject] {
        var out: [NSObject] = []
        func walk(_ o: NSObject, depth: Int) {
            guard depth < 60 else { return }
            if o.accessibilityLabel == label, !(o is UIWindow) { out.append(o) }
            if let v = o as? UIView { v.subviews.forEach { walk($0, depth: depth + 1) } }
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth: depth + 1) } } }
            (o.accessibilityElements as? [NSObject])?.forEach { walk($0, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return out
    }

    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)
        else { return "[CaptureClickSelfTest] FAIL — no window" }

        // The "+" (CanvasChrome.captureTriggerButton), then text, as typed.
        guard let node = await store.createCaptureNode() else { return "[CaptureClickSelfTest] FAIL — no capture node" }
        router.isCapturing = true; router.captureNodeID = node.id; router.captureDraftHasText = false
        router.pendingNodeNavigationID = node.id
        await settle(2.5)
        if let item = store.nodes.first(where: { $0.id == node.id })?.items.first(where: { $0.type == .text }) {
            await store.updateTextItem(itemID: item.id, newContent: "Fix test click. Sourdough starter log: fed it at nine, doubled by two; bake Saturday at seventy-five percent hydration.", nodeID: node.id)
        }
        router.captureDraftHasText = true
        for _ in 0..<40 {   // Apple's proposals arrive (the typing pause's enrichment) — T's step 12 state
            await settle(0.5)
            if store.nodes.first(where: { $0.id == node.id })?.surfacedProposal(kind: .title) != nil { break }
        }
        let proposed = store.nodes.first { $0.id == node.id }?.surfacedProposal(kind: .title)?.text ?? ""
        row("proposals arrived before Done (T's step 12 state)", !proposed.isEmpty, "title proposal \"\(proposed)\"")
        await settle(1.0)
        row("in the new-entry state", store.isComposing(nodeID: node.id))

        // The Proposals sheet (the feather).
        let opened = elementObjects("Review proposals", in: window).last?.accessibilityActivate() ?? false
        await settle(2.0)
        var vc = window.rootViewController?.presentedViewController
        while let next = vc?.presentedViewController { vc = next }
        func scrollViews(_ v: UIView) -> [UIScrollView] { ((v as? UIScrollView).map { [$0] } ?? []) + v.subviews.flatMap(scrollViews) }
        let sv = (vc.map { scrollViews($0.view) } ?? []).max { $0.contentSize.height < $1.contentSize.height }
        row("Proposals sheet open", opened && sv != nil, "sheet \(vc?.view.bounds.size ?? .zero)")
        func attached() -> NSObject? { nsWindow?.value(forKey: "attachedSheet") as? NSObject }
        row("while it's up the sheet is attached to the window (macOS gives that window no clicks)", attached() != nil)
        if let sv {
            let overflow = Int(sv.contentSize.height - sv.bounds.height)
            row("the tray's title, summary and tags are in view on the Mac", overflow <= 44, "view \(sv.bounds.size) content \(sv.contentSize) overflow \(overflow) pt")
            RunningOnMac.snapshot("proposals-sheet")
        }
        let closer = elementObjects("Done", in: vc?.view.window ?? window)
            .first { ((($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier) ?? "") == "proposalsDone" || $0.accessibilityFrame.width < 120 }
        row("the sheet has its own Done on the Mac", closer != nil)
        _ = closer?.accessibilityActivate()
        await settle(1.5)
        row("its Done closes it and the window takes clicks again", attached() == nil && window.rootViewController?.presentedViewController == nil)

        // The entry's Done (the capture bar's pill).
        RunningOnMac.snapshot("capture-done-bar")
        let done = elementObjects("Done", in: window).last
        row("the entry's Done pressed", done?.accessibilityActivate() ?? false)
        await settle(2.0)
        row("Done leaves the new-entry state", !store.isComposing(nodeID: node.id) && !router.isCapturing,
            "composing=\(store.isComposing(nodeID: node.id)) capturing=\(router.isCapturing)")
        await settle(6.0)
        let n = store.nodes.first { $0.id == node.id }
        row("after Done the title is applied (as on iPhone: the same finishCapture → enrichIfNeeded(.committed))", !(n?.title ?? "").isEmpty, "title=\"\(n?.title ?? "nil")\"")
        if let id = n?.id { await store.deleteNode(id: id) }
        return "[CaptureClickSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.filter { $0.hasPrefix("PASS") }.count)/\(rows.filter { $0.hasPrefix("PASS") || $0.hasPrefix("FAIL") }.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
