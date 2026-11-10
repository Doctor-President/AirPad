#if DEBUG
import UIKit

/// Mac batch C3 — `-EditorRoundTripSelfTest`: every Format command on a scratch entry's note, through the real Format
/// menu on the Mac (the same state closures elsewhere), then save → the markdown on disk is exactly `expected` →
/// close and re-open the entry → the editor re-renders the same markdown. Also: the inline bar shows while editing,
/// Tab indents a list item, ⌘↩ ticks a checkbox, Add Link… and Insert Table open their editors.
@MainActor
enum EditorRoundTripSelfTest {

    static let lines = ["Title line", "Heading line", "Subheading line", "Body line", "Bold word here", "Italic word here",
                        "Underline word here", "Strike word here", "Bullet one", "Bullet two", "Number one",
                        "Check one", "Check two", "Toggle twice"]

    /// The markdown the commands must produce (golden, each line checked against the codec's rules). Checklists save as
    /// `- \\[x]` / `- \\[ ]` (the codec escapes the bracket; pre-existing, flagged for T: other Markdown apps won't read
    /// them as tasks).
    static let expected = """
    # Title line
    ## Heading line
    ### Subheading line
    Body line
    **Bold** word here
    *Italic* word here
    <u>Underline</u> word here
    ~~Strike~~ word here
    - Bullet one
      - Bullet two
    1. Number one
    - \\[x] Check one
    - \\[ ] Check two
    Toggle twice
    """

    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func settle(_ s: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func editor(containing marker: String) -> RichTextUIView? {
            func walk(_ v: UIView) -> RichTextUIView? {
                if let t = v as? RichTextUIView, (t.text ?? "").contains(marker) { return t }
                for s in v.subviews { if let r = walk(s) { return r } }
                return nil
            }
            for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                if let r = walk(w) { return r }
            }
            return nil
        }
        func presented() -> UIViewController? {
            var vc = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                .compactMap(\.rootViewController).first { $0.presentedViewController != nil }?.presentedViewController
            while let n = vc?.presentedViewController { vc = n }
            return vc
        }

        // A scratch entry with the plain lines.
        let id = "ert-" + UUID().uuidString.prefix(8)
        var n = Node(id: id, createdAt: Date(), updatedAt: Date(), title: "Round trip", summary: "", tags: [])
        let itemID = UUID().uuidString
        n.items = [NodeItem(id: itemID, type: .text, createdAt: Date(), content: lines.joined(separator: "\n"))]
        n.entrySchemaVersion = 1
        n.titleSource = .user
        await store.addNode(n, position: .zero)
        router.pendingNodeNavigationID = id
        await settle(2.0)
        guard let tv = editor(containing: "Subheading line") else {
            return "[EditorRoundTripSelfTest] FAIL — the entry's editor never appeared (depth=\(store.detailViewDepth))"
        }
        tv.becomeFirstResponder()
        await settle(0.6)
        row("editing → the inline bar's editor is registered", ActiveRichTextEditor.shared.state != nil,
            "usesInlineBar=\(ActiveRichTextEditor.usesInlineBar) accessory=\(tv.inputAccessoryView != nil)")
        row("no keyboard-bar accessory while inline", ActiveRichTextEditor.usesInlineBar ? tv.inputAccessoryView == nil : true)

        func select(_ marker: String, word: String? = nil) {
            let ns = (tv.text ?? "") as NSString
            let r = ns.range(of: marker)
            if let word { tv.selectedRange = NSRange(location: r.location, length: (word as NSString).length) }
            else { tv.selectedRange = NSRange(location: r.location + r.length, length: 0) }
            tv.delegate?.textViewDidChangeSelection?(tv)
        }
        func command(_ title: String, _ run: (RichTextEditorState) -> Void) async {
            #if targetEnvironment(macCatalyst)
            if MacMenuSelfTest.fire(menu: "Format", title: title) { await settle(); return }
            row("menu/Format›\(title) present + enabled", false)
            #endif
            if let s = ActiveRichTextEditor.shared.state { run(s) } else { row("no active editor for \(title)", false) }
            await settle()
        }
        select("Title line");       await command("Title") { $0.applyHeading(.title) }
        select("Heading line");     await command("Heading") { $0.applyHeading(.heading) }
        select("Subheading line");  await command("Subheading") { $0.applyHeading(.subheading) }
        select("Body line");        await command("Heading") { $0.applyHeading(.heading) }
        select("Body line");        await command("Body") { $0.applyHeading(nil) }
        select("Bold word", word: "Bold");           await command("Bold") { $0.toggleBold() }
        select("Italic word", word: "Italic");       await command("Italic") { $0.toggleItalic() }
        select("Underline word", word: "Underline"); await command("Underline") { $0.toggleUnderline() }
        select("Strike word", word: "Strike");       await command("Strikethrough") { $0.toggleStrikethrough() }
        select("Bullet one");       await command("Bulleted List") { $0.toggleBulletList() }
        select("Bullet two");       await command("Bulleted List") { $0.toggleBulletList() }
        select("Bullet two")
        let tabbed = tv.onTabKey?(false) == true   // the hardware Tab key's path
        row("Tab in a list item indents it", tabbed)
        await settle()
        select("Number one");       await command("Numbered List") { $0.toggleNumberedList() }
        select("Check one");        await command("Checklist") { $0.toggleChecklist() }
        select("Check two");        await command("Checklist") { $0.toggleChecklist() }
        select("Toggle twice");     await command("Checklist") { $0.toggleChecklist() }
        select("Toggle twice");     await command("Checklist") { $0.toggleChecklist() }
        row("Checklist twice → plain again (state)", ActiveRichTextEditor.shared.state?.isChecklist == false)
        select("Check one");        await command("Toggle Checkbox") { $0.toggleCheckboxAtCaret() }

        // Save (focus leaves), then the markdown in the store and on disk.
        tv.resignFirstResponder()
        await settle(1.5)
        let md = store.nodes.first { $0.id == id }?.items.first { $0.id == itemID }?.content ?? ""
        let disk = await store.debugReloadFromDisk(id: id)?.items.first { $0.id == itemID }?.content ?? ""
        NSLog("[EditorRoundTripSelfTest] markdown on disk:\n%@", disk)
        row("saved: the store and the file on disk agree", !md.isEmpty && md == disk)
        row("the markdown on disk is exactly the expected", disk == expected, disk == expected ? "" : "diff at \(firstDiff(disk, expected))")
        let reencoded = MarkdownCodec.encode(MarkdownCodec.decode(disk))
        row("decode → encode reproduces it (lossless)", reencoded == disk, reencoded == disk ? "" : "diff at \(firstDiff(reencoded, disk))")

        // Close and re-open the entry: the editor re-renders the same markdown.
        router.perform(.back); await settle(1.2)
        router.perform(.forward); await settle(2.0)
        if let tv2 = editor(containing: "Subheading line") {
            let again = MarkdownCodec.encode(tv2.attributedText ?? NSAttributedString())
            row("re-opened, it renders the same markdown", again == disk, again == disk ? "" : "diff at \(firstDiff(again, disk))")
            row("re-opened, the same visible text", tv2.text == MarkdownCodec.decode(disk).string)
            // Add Link… and Insert Table open their editors.
            tv2.becomeFirstResponder(); await settle(0.6)
            tv2.selectedRange = NSRange(location: ((tv2.text ?? "") as NSString).length, length: 0)
            await command("Add Link…") { $0.insertLink() }
            await settle(0.6)
            let alert = presented() as? UIAlertController
            row("⌘K opens Add Link", alert?.title == "Add Link", "presented=\(presented().map { String(describing: type(of: $0)) } ?? "nil")")
            alert?.dismiss(animated: false); await settle(0.6)
            tv2.becomeFirstResponder(); await settle(0.4)
            let before = (tv2.text ?? "").count
            await command("Insert Table") { $0.insertTable() }
            await settle(1.0)
            row("⌥⌘T inserts a table and opens it", (tv2.text ?? "").count != before || presented() != nil,
                "presented=\(presented().map { String(describing: type(of: $0)) } ?? "nil")")
            presented()?.dismiss(animated: false); await settle(0.6)
        } else {
            row("re-opened, the editor is there", false)
        }
        // C4 — an image dropped / pasted onto the note goes in at the caret (the editor's drop path).
        if let tv3 = editor(containing: "Subheading line") {
            tv3.becomeFirstResponder(); await settle(0.5)
            let ns = (tv3.text ?? "") as NSString
            let at = ns.range(of: "Body line")
            tv3.selectedRange = NSRange(location: at.location + at.length, length: 0)
            let img = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { c in
                UIColor(red: 0xE8 / 255.0, green: 0x82 / 255.0, blue: 0x0A / 255.0, alpha: 1).setFill()
                c.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
            tv3.paste(itemProviders: [NSItemProvider(object: img)])
            await settle(2.0)
            let md3 = MarkdownCodec.encode(tv3.attributedText ?? NSAttributedString())
            let lines3 = md3.components(separatedBy: "\n")
            let i = lines3.firstIndex(of: "Body line") ?? -1
            let next = i >= 0 && i + 1 < lines3.count ? lines3[i + 1] : ""
            row("an image dropped on the note goes in at the point", RichTextEditor.Coordinator.takesRichDrops ? next.hasPrefix(MarkdownCodec.imageTokenPrefix) || (md3.components(separatedBy: "Body line").dropFirst().first ?? "").hasPrefix(MarkdownCodec.imageTokenPrefix) : true,
                "after Body line: \(next.prefix(60))")
            tv3.resignFirstResponder(); await settle(0.8)
        }
        router.perform(.back); await settle(1.0)
        await store.deleteNode(id: id)
        return "[EditorRoundTripSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }

    private static func firstDiff(_ a: String, _ b: String) -> String {
        let x = Array(a), y = Array(b)
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        func ctx(_ c: [Character]) -> String { String(c[max(0, i - 12)..<min(c.count, i + 12)]).replacingOccurrences(of: "\n", with: "⏎") }
        return "\(i): got «\(ctx(x))» want «\(ctx(y))»"
    }
}
#endif
