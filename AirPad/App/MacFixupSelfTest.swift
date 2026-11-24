#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

/// Mac D fix-up — `-MacFixupSelfTest` (run with `-MacWindowSize 1350x840`): the fix-up's layout items checked in the
/// running app, Sample Library scratch. One row per claim; the stills are the visual half.
@MainActor
enum MacFixupSelfTest {
    /// Accessibility elements (SwiftUI's included) whose label or identifier matches.
    static func elements(in window: UIWindow, _ match: (_ label: String?, _ id: String?) -> Bool) -> [NSObject] {
        var out: [NSObject] = []
        func walk(_ o: NSObject, _ depth: Int) {
            guard depth < 60 else { return }
            let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? (o.value(forKey: "accessibilityIdentifier") as? String)
            if !(o is UIWindow), match(o.accessibilityLabel, id) { out.append(o) }
            if let v = o as? UIView { v.subviews.forEach { walk($0, depth + 1) } }
            let n = o.accessibilityElementCount()
            if n != NSNotFound, n > 0 { for i in 0..<n { if let e = o.accessibilityElement(at: i) as? NSObject { walk(e, depth + 1) } } }
            (o.accessibilityElements as? [NSObject])?.forEach { walk($0, depth + 1) }
        }
        walk(window, 0)
        return out
    }

    static func run(store: CorpusStore, router: AppRouter, selection: SelectionService) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double = 1.0) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first
        else { return "[MacFixupSelfTest] FAIL — no window" }
        func screenFrame(_ e: NSObject) -> CGRect { e.accessibilityFrame }   // screen points
        let winScreen = UIAccessibility.convertToScreenCoordinates(window.bounds, in: window)
        rows.append("INFO window \(Int(window.bounds.width))×\(Int(window.bounds.height))")

        // B4 — Recents is the recent-entries list, and leaving it says so.
        router.entryMode = .dashboard; await settle(1.2)
        router.entryMode = .recents; await settle(1.5)
        let recentsHeader = elements(in: window) { l, _ in l == "Recents" }
        row("B4 Today → Recents shows the Recents list (its header), not Today", !recentsHeader.isEmpty)
        // (The toolbar's own ‹, drawn in the window since E fix-up 2, isn't the phone's chevron.)
        row("B4 no phone back chevron in Recents", elements(in: window) { l, i in (l == "Back" || l == "chevron.backward") && i != "toolbar.back" }.isEmpty)
        router.perform(.back); await settle(1.2)
        row("B4 Back from Recents → the place is Today (title follows)", router.entryMode == .dashboard, "\(router.entryMode)")

        // B5 — the JOURNALS section is on screen without scrolling.
        router.entryMode = .canvas; await settle(1.0)
        let journal = elements(in: window) { l, _ in l?.hasPrefix("Journal,") == true }.first
        let jf = journal.map(screenFrame) ?? .null
        row("B5 sidebar Journal row present", journal != nil)
        row("B5 Journal row inside the window (no scrolling)", journal != nil && jf.maxY <= winScreen.maxY,
            "row bottom \(Int(jf.maxY - winScreen.minY)) pt of a \(Int(winScreen.height)) pt window")

        // B6 — the List's collection column at ≥ 660 pt (batch E; was 720, 820).
        let scope = CanvasScope.nodeIDs(store.sampleNodeIDs)
        router.entryMode = .sampleCanvas; await settle(1.0)
        var fs = store.filterState(for: scope); fs.viewMode = .list; store.setFilterState(fs, for: scope)
        await settle(1.5)
        // A row is one Button: its label joins title, summary, collection, age (the cell's own identifier is merged away).
        var seen = Set<String>()
        let listRows = elements(in: window) { _, id in id?.hasPrefix("listRow-") == true }
            .filter { seen.insert(($0.value(forKey: "accessibilityIdentifier") as? String) ?? "").inserted }
        var named = 0, filed = 0
        for r in listRows {
            let id = ((r.value(forKey: "accessibilityIdentifier") as? String) ?? "").replacingOccurrences(of: "listRow-", with: "")
            guard let node = store.nodes.first(where: { $0.id == id }),
                  let c = store.collections.first(where: { !$0.isSystem && node.collectionIDs.contains($0.id) }) else { continue }
            filed += 1
            if r.accessibilityLabel?.contains(c.name) == true { named += 1 }
        }
        if let r = listRows.first { rows.append("INFO first row label: \(r.accessibilityLabel ?? "nil") frame \(Int(r.accessibilityFrame.width)) pt") }
        let listW = elements(in: window) { _, id in id == "macListHeader" }.first.map { _ in winScreen.width } ?? 0
        row("B6 collection column shown (rows name their collection)", filed > 0 && named == filed,
            "\(named)/\(filed) filed rows of \(listRows.count) on screen; window \(Int(listW)) pt")

        // F3 — Cards: the size slider, ⌘+ / ⌘− / ⌘0 through the real View menu, remembered.
        fs = store.filterState(for: scope); fs.viewMode = .grid; store.setFilterState(fs, for: scope)
        await settle(1.5)
        let key = NodeGridView.macCardWidthKey
        UserDefaults.standard.set(NodeGridView.macCardWidthDefault, forKey: key); await settle(0.5)
        row("F3 card-size slider in the Cards header", !elements(in: window) { _, id in id == "cardsSizeSlider" }.isEmpty)
        let zin = MacMenuSelfTest.fire(menu: "View", title: "Zoom In"); await settle(0.6)
        let w1 = UserDefaults.standard.double(forKey: key)
        row("F3 View › Zoom In (⌘+) enabled on Cards and grows the cards", zin && w1 > NodeGridView.macCardWidthDefault, "width \(Int(w1))")
        _ = MacMenuSelfTest.fire(menu: "View", title: "Zoom Out"); _ = MacMenuSelfTest.fire(menu: "View", title: "Zoom Out"); await settle(0.6)
        let w2 = UserDefaults.standard.double(forKey: key)
        row("F3 View › Zoom Out (⌘−) shrinks them (remembered in defaults)", w2 < NodeGridView.macCardWidthDefault, "width \(Int(w2))")
        _ = MacMenuSelfTest.fire(menu: "View", title: "Zoom to Fit"); await settle(0.6)
        row("F3 ⌘0 back to the default size", UserDefaults.standard.double(forKey: key) == NodeGridView.macCardWidthDefault)

        // F4 — no iPhone leftovers.
        func has(_ label: String) -> Bool { !elements(in: window) { l, _ in l == label }.isEmpty }
        func hasID(_ id: String) -> Bool { !elements(in: window) { _, i in i == id }.isEmpty }
        for mode in [ViewMode.systemGraph, .list, .grid] {
            fs = store.filterState(for: scope); fs.viewMode = mode; store.setFilterState(fs, for: scope); await settle(1.2)
            row("F4 no floating ✓ ≡ pill on \(mode == .systemGraph ? "Map" : mode == .list ? "List" : "Cards")", !hasID("chrome.menu") && !has("Menu"))
        }
        let selOK = MacMenuSelfTest.fire(menu: "View", title: "Select Entries"); await settle(0.8)
        row("F4 View › Select Entries enters selection", selOK && selection.isActive)
        selection.exit(); await settle(0.5)
        fs = store.filterState(for: scope); fs.viewMode = .list; store.setFilterState(fs, for: scope); await settle(1.0)
        let sortOK = MacMenuSelfTest.fire(menu: "View", title: "Sort List By")   // a submenu: present + enabled
        row("F4 View › Sort List By (enabled on List)", sortOK || MacMenuSelfTest.dump().contains { $0.contains("Sort List By") && !$0.contains("(disabled)") })
        let menuText = MacMenuSelfTest.dump()
        for t in ["Analyze Library", "Show Private Entries", "Filter…"] {
            row("F4 View › \(t) in the menu bar", menuText.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(t) })
        }
        router.entryMode = .dashboard; await settle(1.5)
        row("F4 Today: no own logo / chats / ≡ buttons", !hasID("dashboard.menu"))
        row("F4 Librarian: interim empty state, no launcher tiles", hasID("macLibrarianEmpty") && elements(in: window) { l, _ in l?.contains("Coming soon") == true }.isEmpty)
        row("F4 Librarian header: chat history", hasID("macLibrarianHistory") || has("Chat history"))
        row("F4 no phone Back bar", !has("Back to Librarian home"))

        // F5 — resizable panels (the real drag is T's check: a locked Mac takes no mouse drags).
        let layout = MacLayout.shared
        layout.sidebarVisible = true; layout.librarianOpen = true; await settle(0.6)
        row("F5 drag handles on the sidebar and Librarian edges", hasID("resize.sidebar") && hasID("resize.librarian"))
        layout.librarianWidth = 440; layout.sidebarWidth = 260; await settle(0.8)
        let libW = elements(in: window) { _, i in i == "macLibrarianColumn" }.first?.accessibilityFrame.width ?? 0
        let sideW = elements(in: window) { _, i in i == "macSidebar" }.first?.accessibilityFrame.width ?? 0
        row("F5 the Librarian takes its new width", abs(libW - 440) < 2, "\(Int(libW)) pt")
        row("F5 the sidebar takes its new width", abs(sideW - 260) < 2, "\(Int(sideW)) pt")
        row("F5 widths remembered", UserDefaults.standard.double(forKey: MacLayout.librarianWidthKey) == 440
            && UserDefaults.standard.double(forKey: MacLayout.sidebarWidthKey) == 260)
        row("F5 limits: Librarian 300–520, sidebar 200–300",
            MacLayout.clamp(700, MacLayout.librarianWidthRange) == 520 && MacLayout.clamp(100, MacLayout.librarianWidthRange) == 300
            && MacLayout.clamp(900, MacLayout.sidebarWidthRange) == 300 && MacLayout.clamp(10, MacLayout.sidebarWidthRange) == 200)
        layout.floatChosen = false   // E fix-up 5 (L5): the column, not the remembered float choice
        layout.librarianWidth = 520; layout.sidebarWidth = 300; await settle(0.8)
        row("F5 at 1,350 pt with both panels widest the Librarian floats (content would be 528 < 616)", layout.librarianFloats)
        layout.librarianWidth = MacLayout.librarianWidthDefault; layout.sidebarWidth = MacLayout.sidebarWidthDefault; await settle(0.8)
        row("F5 at the default widths it pushes in (content 756 pt)", !layout.librarianFloats)

        let checks = rows.filter { !$0.hasPrefix("INFO") }.count
        return "[MacFixupSelfTest] \(fails == 0 ? "PASS" : "FAIL") \(checks - fails)/\(checks)\n" + rows.joined(separator: "\n")
    }
}

/// Sweep 2b · step 5 fix-ups — `-Sweep2bFixupSelfTest`: the verifier's Mac findings that a headless run can prove.
/// 3: the Map's tick pacer (`MapTickPacer`) fed display ticks at 120 Hz and at 60 Hz (a window on a 60 Hz display while
/// the launch-time screen said 120).
@MainActor
enum Sweep2bFixupSelfTest {
    static func run() async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }

        // 3 — frames drawn per second of display ticks: `ticks` at `hz` (optional late ticks), asked `fps`, the
        // launch-time screen saying `launch`. Counted over the last second (after the pacer has seen a second of ticks).
        func drawn(hz: Double, launch: Int, fps: Int, lateEvery: Int = 0) -> (perSecond: Int, asked: Int) {
            var p = MapTickPacer(launchHz: launch)
            _ = p.ask(fps)
            var t = 1000.0, n = 0
            let gap = 1 / hz
            for i in 0..<Int(hz * 2) {
                // a late tick (the main thread busy): the next tick time is a whole period later, as vsync skips it
                t += (lateEvery > 0 && i % lateEvery == lateEvery - 1) ? 2 * gap : gap
                let drew = p.tick(at: t)
                if i >= Int(hz) && drew { n += 1 }
            }
            let secs = (Double(Int(hz * 2) - Int(hz)) * gap) + (lateEvery > 0 ? Double(Int(hz) / lateEvery) * gap : 0)
            return (Int((Double(n) / secs).rounded()), p.askedFPS)
        }
        // The proven case, unchanged: the built-in 120 Hz display.
        for (fps, want) in [(120, 120), (60, 60), (30, 30), (8, 8)] {
            let r = drawn(hz: 120, launch: 120, fps: fps)
            row("pacer 120 Hz display, asked \(fps) → \(want) fps", r.perSecond == want && r.asked == want, "drawn \(r.perSecond)/s · asked \(r.asked)")
        }
        // A busy main thread (every 4th tick late) on the 120 Hz display keeps the 120 Hz step (a clean 60 stays every 2nd).
        let busy = drawn(hz: 120, launch: 120, fps: 60, lateEvery: 4)
        row("pacer 120 Hz display with late ticks keeps its step (asked 60)", busy.asked == 60, "asked \(busy.asked) · drawn \(busy.perSecond)/s")
        // Finding 3: the window on a 60 Hz display while the launch-time screen said 120.
        for (fps, want) in [(120, 60), (60, 60), (30, 30)] {
            let r = drawn(hz: 60, launch: 120, fps: fps)
            row("pacer 60 Hz display (launch said 120), asked \(fps) → \(want) fps", r.perSecond == want, "drawn \(r.perSecond)/s · asked \(r.asked)")
        }
        let idle60 = drawn(hz: 60, launch: 120, fps: 8)
        row("pacer 60 Hz display, asked 8 → about 8 fps (not 4)", (7...9).contains(idle60.perSecond), "drawn \(idle60.perSecond)/s")

        let checks = rows.count
        return "[Sweep2bFixupSelfTest] \(fails == 0 ? "PASS" : "FAIL") \(checks - fails)/\(checks)\n" + rows.joined(separator: "\n")
    }
}
#endif
