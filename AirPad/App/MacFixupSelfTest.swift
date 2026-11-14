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

    static func run(store: CorpusStore, router: AppRouter) async -> String {
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
        row("B4 no phone back chevron in Recents", elements(in: window) { l, _ in l == "Back" || l == "chevron.backward" }.isEmpty)
        router.perform(.back); await settle(1.2)
        row("B4 Back from Recents → the place is Today (title follows)", router.entryMode == .dashboard, "\(router.entryMode)")

        // B5 — the JOURNALS section is on screen without scrolling.
        router.entryMode = .canvas; await settle(1.0)
        let journal = elements(in: window) { l, _ in l?.hasPrefix("Journal,") == true }.first
        let jf = journal.map(screenFrame) ?? .null
        row("B5 sidebar Journal row present", journal != nil)
        row("B5 Journal row inside the window (no scrolling)", journal != nil && jf.maxY <= winScreen.maxY,
            "row bottom \(Int(jf.maxY - winScreen.minY)) pt of a \(Int(winScreen.height)) pt window")

        // B6 — the List's collection column at ≥ 820 pt.
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
        row("F3 View › Zoom In (⌘+) enabled on Cards and grows the cards", zin && w1 == NodeGridView.macCardWidthDefault + NodeGridView.macCardWidthStep, "width \(Int(w1))")
        _ = MacMenuSelfTest.fire(menu: "View", title: "Zoom Out"); _ = MacMenuSelfTest.fire(menu: "View", title: "Zoom Out"); await settle(0.6)
        let w2 = UserDefaults.standard.double(forKey: key)
        row("F3 View › Zoom Out (⌘−) shrinks them (remembered in defaults)", w2 == NodeGridView.macCardWidthDefault - NodeGridView.macCardWidthStep, "width \(Int(w2))")
        _ = MacMenuSelfTest.fire(menu: "View", title: "Zoom to Fit"); await settle(0.6)
        row("F3 ⌘0 back to the default size", UserDefaults.standard.double(forKey: key) == NodeGridView.macCardWidthDefault)

        let checks = rows.filter { !$0.hasPrefix("INFO") }.count
        return "[MacFixupSelfTest] \(fails == 0 ? "PASS" : "FAIL") \(checks - fails)/\(checks)\n" + rows.joined(separator: "\n")
    }
}
#endif
