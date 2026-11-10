#if DEBUG
import UIKit

/// Mac batch C5 — `-EntryMenuSelfTest` (with `-OpenMap -StubAuthorModel`): the right-click entry menu's actions, through
/// the same router request a menu choice sends, answered at the root: Open, Make Private / Not Private, Export…, Delete
/// (its confirmation shows; the delete then sticks). The Map's orb menu: on an orb it offers the entry actions, off the
/// orbs nothing. And a delete right after an edit stays deleted (the C4 observation). Synthetic entries only.
@MainActor
enum EntryMenuSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func settle(_ s: Double = 1.0) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func presented() -> UIViewController? {
            var vc = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                .compactMap(\.rootViewController).first { $0.presentedViewController != nil }?.presentedViewController
            while let n = vc?.presentedViewController { vc = n }
            return vc
        }
        func editor(_ marker: String) -> RichTextUIView? {
            func walk(_ v: UIView) -> RichTextUIView? {
                if let t = v as? RichTextUIView, (t.text ?? "").contains(marker) { return t }
                for s in v.subviews { if let r = walk(s) { return r } }
                return nil
            }
            return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).lazy.compactMap(walk).first
        }
        func newEntry(_ text: String) async -> String {
            let id = "emt-" + UUID().uuidString.prefix(8)
            var n = Node(id: id, createdAt: Date(), updatedAt: Date(), title: "Menu test", summary: "", tags: [])
            n.items = [NodeItem(id: UUID().uuidString, type: .text, createdAt: Date(), content: text)]
            n.entrySchemaVersion = 1
            n.titleSource = .user
            await store.addNode(n, position: .zero)
            return id
        }
        func onDisk(_ id: String) async -> Bool { await store.debugReloadFromDisk(id: id) != nil }

        // 1. Open / Export / Make Private / Delete through the entry action request.
        let a = await newEntry("Entry menu test, first entry.")
        router.requestEntryAction(.open, a); await settle(1.5)
        row("Open → the entry opens", store.isInDetailView && router.openEntryID == a, "depth=\(store.detailViewDepth)")
        router.perform(.back); await settle()
        router.requestEntryAction(.export, a); await settle(1.2)
        row("Export… → the Export sheet", router.exportEntryID == a && presented() != nil,
            "presented=\(presented().map { String(describing: type(of: $0)) } ?? "nil")")
        presented()?.dismiss(animated: false); router.exportEntryID = nil; await settle()
        if PrivateEntries.shared.available {
            router.requestEntryAction(.togglePrivate, a); await settle()
            row("Make Private", store.userNodesIncludingPrivate.first { $0.id == a }?.isPrivate == true)
            router.requestEntryAction(.togglePrivate, a); await settle()
            row("Make Not Private", store.nodes.first { $0.id == a }?.isPrivate == false)
        } else {
            row("Make Private hidden (no login password / passcode here)", true, "PrivateEntries.available=false")
        }
        router.requestEntryAction(.delete, a); await settle(1.0)
        let dialog = presented() as? UIAlertController
        row("Delete… → the confirmation", router.deleteEntryID == a && dialog?.title == "Delete this entry?",
            "presented=\(presented().map { String(describing: type(of: $0)) } ?? "nil") title=\(dialog?.title ?? "nil")")
        dialog?.dismiss(animated: false); router.deleteEntryID = nil; await settle(0.6)
        row("Cancel keeps it", store.nodes.contains { $0.id == a })
        await store.deleteNode(id: a); await settle(3)   // the dialog's Delete runs exactly this
        let aOnDisk = await onDisk(a)
        row("Delete removes it (store + disk)", !store.nodes.contains { $0.id == a } && !aOnDisk)

        // 2. Edit, close, delete at once: it stays deleted.
        let b = await newEntry("Delete after edit test.")
        router.requestEntryAction(.open, b); await settle(1.8)
        if let tv = editor("Delete after edit") {
            tv.becomeFirstResponder(); await settle(0.4)
            tv.selectedRange = NSRange(location: ((tv.text ?? "") as NSString).length, length: 0)
            tv.insertText(" One more line typed.")
            tv.resignFirstResponder()
            router.perform(.back); await settle(0.3)
            await store.deleteNode(id: b)
            await settle(5)
            let back = store.nodes.contains { $0.id == b }
            let disk = await onDisk(b)
            row("edit → close → delete at once: stays deleted", !back && !disk, "inStore=\(back) onDisk=\(disk)")
        } else {
            row("edit → close → delete: the editor", false)
            await store.deleteNode(id: b)
        }

        // 2b. Insert a table, close it and the entry, delete at once: it stays deleted.
        let c = await newEntry("Delete after table test.")
        router.requestEntryAction(.open, c); await settle(1.8)
        if let tv = editor("Delete after table") {
            tv.becomeFirstResponder(); await settle(0.5)
            ActiveRichTextEditor.shared.state?.insertTable(); await settle(1.2)
            presented()?.dismiss(animated: false); await settle(0.6)
            tv.resignFirstResponder()
            router.perform(.back); await settle(0.3)
            await store.deleteNode(id: c)
            await settle(5)
            let back = store.nodes.contains { $0.id == c }
            let disk = await onDisk(c)
            row("table → close → delete at once: stays deleted", !back && !disk, "inStore=\(back) onDisk=\(disk)")
        } else {
            row("table → delete: the editor", false); await store.deleteNode(id: c)
        }

        // 3. The Map's orb menu.
        if let scene = CorpusPhysicsScene.debugCurrent {
            let size = scene.view?.bounds.size ?? .zero
            let on = scene.debugOrbIDs.compactMap { scene.debugOrbViewPoint($0) }
                .first { $0.x > 20 && $0.x < size.width - 20 && $0.y > 20 && $0.y < size.height - 20 }
            if let on {
                let t = scene.debugContextMenuTitles(at: on)
                row("right-click on an orb → the entry menu", t.contains("Open") && t.contains("Export…") && t.contains("Delete…"), "\(t)")
            } else { row("an orb on screen", false) }
            row("right-click off the orbs → no menu", scene.debugContextMenuTitles(at: CGPoint(x: 3, y: 3)).isEmpty)
        } else {
            row("the Map", false, "launch with -OpenMap")
        }
        return "[EntryMenuSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
