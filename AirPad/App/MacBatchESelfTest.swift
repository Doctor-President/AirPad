#if DEBUG && targetEnvironment(macCatalyst)
import UIKit

/// Mac batch E — `-MacBatchESelfTest` (run with `-MacWindowSize 1350x840`): T's v3 layout picks checked in the running
/// app, Sample Library scratch (E1's toolbar rows are in `MacLayoutSelfTest`). One row per claim; stills are the
/// visual half.
@MainActor
enum MacBatchESelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double = 1.0) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first, let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        else { return "[MacBatchESelfTest] FAIL — no window" }
        let layout = MacLayout.shared
        func els(_ id: String) -> [NSObject] { MacFixupSelfTest.elements(in: window) { _, i in i == id } }
        func frame(_ id: String) -> CGRect? { els(id).first?.accessibilityFrame }   // screen points
        let win = { UIAccessibility.convertToScreenCoordinates(window.bounds, in: window) }
        func resize(_ w: CGFloat, _ h: CGFloat = 840) async {
            guard let r = scene.sizeRestrictions else { return }
            let size = CGSize(width: w, height: h)
            r.minimumSize = size; r.maximumSize = size
            var origin = scene.effectiveGeometry.systemFrame.origin
            origin.x = max(0, min(origin.x, scene.screen.bounds.width - w))
            scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: origin, size: size)))
            await settle(1.4)
        }
        let restore = (scene.sizeRestrictions?.minimumSize, scene.sizeRestrictions?.maximumSize, layout.sidebarWidth, layout.librarianWidth,
                       layout.sidebarVisible, layout.librarianOpen)
        rows.append("INFO window \(Int(window.bounds.width))×\(Int(window.bounds.height))")

        // E2 — the Librarian announces itself.
        layout.sidebarVisible = true; layout.librarianOpen = true
        layout.librarianWidth = MacLayout.librarianWidthDefault; layout.sidebarWidth = MacLayout.sidebarWidthDefault
        router.entryMode = .canvas; await settle(1.5)
        let libIDs = MacFixupSelfTest.elements(in: window) { _, i in i?.hasPrefix("macLibrarian") == true }
            .compactMap { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ($0.value(forKey: "accessibilityIdentifier") as? String) }
        rows.append("INFO Librarian ids: \(Dictionary(grouping: libIDs, by: { $0 }).mapValues(\.count))")
        let libW = frame("macLibrarianColumn")?.width ?? 0
        row("E2 toolbar button = glyph + \"Librarian\" (drawn in the trailing item)", MacToolbarProbe.x["toolbar.librarian"] != nil)
        row("E2 default width 370", MacLayout.librarianWidthDefault == 370 && abs(libW - 370) < 2, "\(libW) pt")
        row("E2 header: New chat + Chat history", !els("macLibrarianNewChat").isEmpty && !els("macLibrarianHistory").isEmpty)
        // The walk meets each button more than once (as a view and as its element): count distinct rows.
        let tries = Set(els("macLibrarianTry").map { Int($0.accessibilityFrame.minY.rounded()) }).count
        row("E2 first open: intro + 3 questions to try", !els("macLibrarianEmpty").isEmpty && tries == 3, "try rows \(tries)")

        // E3 — Today = the compact home: one column (≤ 860, centred), Activity | Priority, Pick up again, no collections.
        router.entryMode = .dashboard; await settle(1.8)
        for (w, side, want) in [(1350, true, 2), (1920, true, 2), (900, true, 1)] as [(CGFloat, Bool, Int)] {
            await resize(w); layout.sidebarVisible = side
            if w == 900 { layout.sidebarWidth = 300 }
            await settle(1.0)
            let home = els("macTodayHome-\(want)").first?.accessibilityFrame
            let content = frame("macLibrarianColumn").map { lib -> CGRect in
                let left = win().minX + (layout.sidebarVisible ? layout.sidebarWidth + 1 : 0)
                return CGRect(x: left, y: 0, width: (layout.librarianFloats ? win().maxX : lib.minX - 1) - left, height: 1)
            }
            let centred = home.flatMap { h in content.map { abs(h.midX - $0.midX) < 3 } } ?? false
            let collectionsShown = MacFixupSelfTest.elements(in: window) { l, _ in l == "Collections" || l == "COLLECTIONS" }
                .contains { $0.accessibilityFrame.minX > win().minX + layout.sidebarWidth + 2 }
            row("E3 \(Int(window.bounds.width)) pt: \(want == 2 ? "Activity | Priority side by side" : "one column"), ≤ 860, centred, no collections",
                home != nil && (home?.width ?? 999) <= 861 && centred && !collectionsShown
                && !els("macTodayActivity").isEmpty && !els("macTodayPriority").isEmpty,
                "home \(home.map { "\(Int($0.width)) at \(Int($0.midX - win().minX))" } ?? "nil") · content mid \(content.map { Int($0.midX - win().minX) } ?? -1)")
            layout.sidebarWidth = MacLayout.sidebarWidthDefault
        }
        await resize(1350)
        let pickUp = Set(els("macTodayPickUpTile").map { Int($0.accessibilityFrame.minX.rounded()) }).count
        let homeCount = UserDefaults.standard.bool(forKey: "MacTodaySample") ? store.nodes.filter { store.isSample($0.id) }.count : store.userNodes.count
        row("E3 Pick up again: up to 3 tiles (next three recent entries)", pickUp == max(0, min(3, homeCount - 3)),
            "tiles \(pickUp) · entries Today reads \(homeCount)")

        // E4 — Cards default 210 (a remembered size wins).
        let key = NodeGridView.macCardWidthKey
        UserDefaults.standard.removeObject(forKey: key)
        row("E4 Cards default 210", NodeGridView.macCardWidthDefault == 210)
        UserDefaults.standard.set(330.0, forKey: key)
        row("E4 a remembered size wins", UserDefaults.standard.double(forKey: key) == 330)
        UserDefaults.standard.removeObject(forKey: key)

        // E5 — the open entry's + never meets the Librarian (column or floating) or the window edge.
        if let entry = store.nodes.first(where: { !$0.isPrivate && !$0.title.isEmpty }) {
            router.entryMode = .sampleCanvas; await settle(1.5)
            router.pendingNodeNavigationID = entry.id; await settle(2.5)
            for (w, sw, lw, side) in [(1350, 232, 370, true), (1180, 232, 370, true), (1920, 232, 520, true), (900, 300, 520, true),
                                      (900, 232, 520, false), (1220, 232, 370, true)] as [(CGFloat, CGFloat, CGFloat, Bool)] {
                await resize(w)
                layout.sidebarVisible = side; layout.sidebarWidth = sw; layout.librarianWidth = lw; layout.librarianOpen = true
                await settle(1.2)
                let plus = frame("entryAddButton"), lib = frame("macLibrarianColumn"), wf = win()
                let leftEdge = wf.minX + (side ? sw + 1 : 0)
                let ok = plus.map { p in
                    !(lib.map { p.intersects($0.insetBy(dx: -6, dy: 0)) } ?? false)
                        && p.minX >= leftEdge + 8 && p.maxX <= wf.maxX - 8 && p.maxY <= wf.maxY - 8
                } ?? false
                row("E5 \(Int(w)) pt, sidebar \(side ? Int(sw) : 0), Librarian \(Int(lw)) \(layout.librarianFloats ? "floating" : "column"): + clear",
                    ok, "+ \(plus.map { "\(Int($0.minX - wf.minX))…\(Int($0.maxX - wf.minX))" } ?? "nil") · Librarian \(lib.map { "\(Int($0.minX - wf.minX))…\(Int($0.maxX - wf.minX))" } ?? "nil")")
            }
            router.perform(.back); await settle(1.0)
        } else { row("E5 an entry to open", false) }

        if let mn = restore.0, let mx = restore.1, let r = scene.sizeRestrictions { r.minimumSize = mn; r.maximumSize = mx }
        await resize(restore.1?.width ?? 1350, restore.1?.height ?? 840)
        layout.sidebarWidth = restore.2; layout.librarianWidth = restore.3; layout.sidebarVisible = restore.4; layout.librarianOpen = restore.5

        rows += await e6Rows(store: store, router: router)
        let checks = rows.filter { !$0.hasPrefix("INFO") }.count
        return "[MacBatchESelfTest] \(fails == 0 ? "PASS" : "FAIL") \(checks - fails)/\(checks)\n" + rows.joined(separator: "\n")
    }

    /// E6 rows (collection colours) — filled in with E6.
    static func e6Rows(store: CorpusStore, router: AppRouter) async -> [String] { [] }
}
#endif
