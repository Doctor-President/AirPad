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
    /// standard Markdown tasks `- [x]` / `- [ ]` (Mac fix-up X11; they were `- \\[x]`, which other apps read as text).
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
    - [x] Check one
    - [ ] Check two
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
        let depthAtDelete = store.detailViewDepth
        await store.deleteNode(id: id)
        await settle(5)
        let survived = store.nodes.contains { $0.id == id }
        let onDisk = await store.debugReloadFromDisk(id: id) != nil
        NSLog("[EditorRoundTripSelfTest] cleanup: depthAtDelete=%d inStore=%@ onDisk=%@", depthAtDelete, survived ? "Y" : "n", onDisk ? "Y" : "n")
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

/// Mac D0.8 (T N5) — `-EmptyLineListSelfTest` (iPhone, iPad, Mac; Sample scratch): Checklist, Bulleted List and
/// Numbered List on an EMPTY line make an empty item with the caret ready after its marker, on an empty line between two
/// lines and on the empty last line; typing then fills the item and it saves as standard Markdown. On the Mac through
/// the real Format menu; elsewhere the same editor state closures the bars call.
@MainActor
enum EmptyLineListSelfTest {
    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        let kinds: [(name: String, menu: String, run: (RichTextEditorState) -> Void, md: String)] = [
            ("checklist", "Checklist", { $0.toggleChecklist() }, "- [ ] "),
            ("bulleted", "Bulleted List", { $0.toggleBulletList() }, "- "),
            ("numbered", "Numbered List", { $0.toggleNumberedList() }, "1. "),
        ]
        for kind in kinds {
            let id = "ell-" + UUID().uuidString.prefix(8)
            let original = "D test lists \(kind.name)\nAbove\n\nBelow"
            var n = Node(id: id, createdAt: Date(), updatedAt: Date(), title: "D test lists", summary: "", tags: [])
            let itemID = UUID().uuidString
            n.items = [NodeItem(id: itemID, type: .text, createdAt: Date(), content: original)]
            n.entrySchemaVersion = 1
            n.titleSource = .user
            await store.addNode(n, position: .zero)
            router.pendingNodeNavigationID = id
            await settle(2.5)
            func editor() -> RichTextUIView? {
                func walk(_ v: UIView) -> RichTextUIView? {
                    if let t = v as? RichTextUIView, (t.text ?? "").contains("D test lists \(kind.name)") { return t }
                    for s in v.subviews { if let r = walk(s) { return r } }
                    return nil
                }
                for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                    if let r = walk(w) { return r }
                }
                return nil
            }
            guard let tv = editor() else { row("\(kind.name): the entry's editor appeared", false); continue }
            tv.becomeFirstResponder()
            await settle(0.8)
            func command() async {
                #if targetEnvironment(macCatalyst)
                if MacMenuSelfTest.fire(menu: "Format", title: kind.menu) { await settle(); return }
                row("\(kind.name): menu Format›\(kind.menu) present + enabled", false)
                #endif
                if let s = ActiveRichTextEditor.shared.state { kind.run(s) } else { row("\(kind.name): no active editor", false) }
                await settle()
            }
            /// The paragraph the caret is in, and the caret's offset into it.
            func caretLine() -> (line: String, offset: Int) {
                let ns = (tv.text ?? "") as NSString
                let loc = min(tv.selectedRange.location, ns.length)
                let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
                let line = ns.substring(with: para).trimmingCharacters(in: .newlines)
                return (line, loc - para.location)
            }
            // 1. The empty line between "Above" and "Below".
            let ns = (tv.text ?? "") as NSString
            let below = ns.range(of: "\nBelow")
            tv.selectedRange = NSRange(location: below.location, length: 0)
            tv.delegate?.textViewDidChangeSelection?(tv)
            await command()
            let mid = caretLine()
            row("\(kind.name): empty middle line → an empty item, caret after its marker",
                !mid.line.isEmpty && mid.line.trimmingCharacters(in: .whitespaces).count <= 2 && mid.offset == (mid.line as NSString).length,
                "line=\"\(mid.line)\" caret at \(mid.offset)")
            tv.insertText("Middle item"); await settle(0.3)
            // 2. The empty last line (after a final newline).
            tv.selectedRange = NSRange(location: ((tv.text ?? "") as NSString).length, length: 0)
            tv.insertText("\n"); await settle(0.3)
            if caretLine().line.isEmpty == false {   // Return in "Below" — a plain line; make sure it's empty
                row("\(kind.name): Return made an empty last line", false, "line=\"\(caretLine().line)\"")
            }
            await command()
            let end = caretLine()
            row("\(kind.name): empty last line → an empty item, caret after its marker",
                !end.line.isEmpty && end.offset == (end.line as NSString).length, "line=\"\(end.line)\" caret at \(end.offset)")
            tv.insertText("Last item"); await settle(0.3)
            tv.resignFirstResponder()
            await settle(2.5)
            let stored = store.nodes.first { $0.id == id }?.items.first { $0.id == itemID }?.content ?? ""
            let want = "D test lists \(kind.name)\nAbove\n\(kind.md)Middle item\nBelow\n\(kind.md)Last item"
            row("\(kind.name): saved as standard Markdown", stored == want, stored.replacingOccurrences(of: "\n", with: "⏎"))
            router.perform(.back); await settle(1.5)
            await store.deleteNode(id: id)
        }
        return "[EmptyLineListSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}

/// Mac fix-up X8 — `-NoteWeightSelfTest` (iPhone, iPad, Mac; Sample scratch): T's ruling on note weight, through the
/// real editor on a scratch entry. Note text is regular body weight by default, paragraph 1 too (no auto-title bold);
/// opening a note rewrites nothing; B bolds and un-bolds paragraph 1 and the un-bold survives the editor's restyle
/// passes; a stored `**bold**` un-bolds and stays plain; Body keeps a user's bold and adds none.
@MainActor
enum NoteWeightSelfTest {
    static let original = "Fix test weight first line\nSecond line with **kept bold** word\nThird line plain"

    static func run(store: CorpusStore, router: AppRouter) async -> String {
        var out: [String] = [], total = 0, failed = 0
        for face in [nil, EntryBodyFont.sourceSerif4] {   // the app default, and Source Serif (Regular body since D0.3)
            let (rows, fails) = await pass(store: store, router: router, face: face)
            out.append("  — face \(face.map { "\($0)" } ?? "default")"); out += rows
            total += rows.count; failed += fails
            router.perform(.back); try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return "[NoteWeightSelfTest] \(failed == 0 ? "PASS" : "FAIL") — \(total - failed)/\(total)\n" + out.joined(separator: "\n")
    }

    static func pass(store: CorpusStore, router: AppRouter, face: EntryBodyFont?) async -> ([String], Int) {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func settle(_ s: Double = 0.5) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func editor() -> RichTextUIView? {
            func walk(_ v: UIView) -> RichTextUIView? {
                if let t = v as? RichTextUIView, (t.text ?? "").contains("Fix test weight") { return t }
                for s in v.subviews { if let r = walk(s) { return r } }
                return nil
            }
            for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
                if let r = walk(w) { return r }
            }
            return nil
        }
        let id = "nw-" + UUID().uuidString.prefix(8)
        var n = Node(id: id, createdAt: Date(), updatedAt: Date(), title: "Fix test weight", summary: "", tags: [])
        let itemID = UUID().uuidString
        n.items = [NodeItem(id: itemID, type: .text, createdAt: Date(), content: original)]
        n.entrySchemaVersion = 1
        n.titleSource = .user
        n.perEntryBodyFont = face
        await store.addNode(n, position: .zero)
        router.pendingNodeNavigationID = id
        await settle(2.5)
        guard let tv = editor() else { return (["FAIL the entry's editor never appeared"], 1) }
        tv.becomeFirstResponder()
        await settle(0.8)
        // The editor's own state (Mac / iPad register it for the inline bar; on iPhone it rides the keyboard bar).
        guard let state = ActiveRichTextEditor.shared.state ?? (tv.delegate as? RichTextEditor.Coordinator)?.state
        else { return (["FAIL no editor state"], 1) }
        func stored() -> String { store.nodes.first { $0.id == id }?.items.first { $0.id == itemID }?.content ?? "" }
        func range(_ s: String) -> NSRange { ((tv.text ?? "") as NSString).range(of: s) }
        func select(_ s: String) { tv.selectedRange = range(s); tv.delegate?.textViewDidChangeSelection?(tv) }
        func caret(in s: String) { let r = range(s); tv.selectedRange = NSRange(location: r.location + 1, length: 0); tv.delegate?.textViewDidChangeSelection?(tv) }
        func userBold(_ s: String) -> Bool {
            let r = range(s); var all = true
            tv.attributedText.enumerateAttributes(in: r, options: []) { a, _, stop in if !NoteTypography.isUserBold(a) { all = false; stop.pointee = true } }
            return all
        }
        func weight(_ s: String) -> CGFloat { (tv.attributedText.attribute(.font, at: range(s).location, effectiveRange: nil) as? UIFont)?.airpadWeightValue ?? -1 }
        func size(_ s: String) -> CGFloat { (tv.attributedText.attribute(.font, at: range(s).location, effectiveRange: nil) as? UIFont)?.pointSize ?? -1 }
        /// A keystroke at the end of the last line: runs the editor's restyle passes like typing does.
        func type(_ t: String) async {
            tv.selectedRange = NSRange(location: ((tv.text ?? "") as NSString).length, length: 0)
            tv.insertText(t)
            await settle(0.3)
        }

        // 1. Default weight: paragraph 1 is body, like paragraph 3 (same size + weight), and not bold.
        row("paragraph 1 renders at the body weight, not bold", !userBold("first") && abs(weight("first") - weight("Third")) < 0.01
            && abs(size("first") - size("Third")) < 0.5, "p1 weight \(weight("first")) size \(size("first")) · p3 weight \(weight("Third")) size \(size("Third"))")
        // Mac D0.3 (T R-X8) — the body is Regular in every face (Source Serif's was Semibold).
        row("the body is Regular", abs(weight("Third") - UIFont.Weight.regular.rawValue) < 0.01, "p3 weight \(weight("Third"))")
        row("the stored bold renders bold", userBold("kept bold"))
        await settle(2.5)
        row("opening the note rewrote nothing", stored() == original, stored())

        // 2. B on paragraph 1: on, then off, and off survives the restyle passes.
        select("first"); state.toggleBold()
        row("B bolds a word in paragraph 1 (and its button shows it)", userBold("first") && state.isBold, "bold=\(userBold("first")) button=\(state.isBold)")
        await type(" a")
        row("…and it stays bold while typing on", userBold("first"))
        select("first"); state.toggleBold(); await type(" b"); await type(" c")
        row("B again un-bolds it, and it stays un-bolded while typing on", !userBold("first"))
        // 3. B on the stored bold: off, and stays off (the stored-bold mark used to re-bold it on the next keystroke).
        select("kept bold"); state.toggleBold(); await type(" d"); await type(" e")
        row("B un-bolds a stored **bold** and it stays plain", !userBold("kept bold"))
        // 4. Body keeps the user's bold and adds none.
        select("kept bold"); state.toggleBold(); await settle(0.2)
        caret(in: "Second"); state.applyHeading(nil); await type(" f")
        row("Body on a line with a bold word keeps the bold", userBold("kept bold"))
        caret(in: "first"); state.applyHeading(nil)
        // The caret moves to the end (UIKit resets the typing attributes from the text), then one keystroke, then the
        // typing-pause save: that last keystroke used to be stored `**…**` on Source Serif.
        await type(" g")
        row("Body on paragraph 1 adds no bold", !userBold("Fix test") && !userBold("first"))
        await settle(2.5)
        let want = "Fix test weight first line\nSecond line with **kept bold** word\nThird line plain a b c d e f g"
        row("saved markdown: only the user's bold is stored", stored() == want, stored())
        tv.resignFirstResponder()
        await settle(1.0)
        await store.deleteNode(id: id)
        return (rows, fails)
    }
}

/// Mac fix-up X11 — `-ChecklistCodecSelfTest`: checklists through the editor's passes (decode → applyInPlace → encode →
/// decode), both stored forms. The old `- \\[x]` / `- \\[ ]` (every note saved before) reads as a checklist and saves as
/// standard `- [x]` / `- [ ]` on its next save; the standard form round-trips unchanged; nested items, a bold word in an
/// item and a literal `[x]` in plain text are kept as they were.
enum ChecklistCodecSelfTest {
    @MainActor static func run() -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok || detail.isEmpty ? "" : " — \(detail)")); if !ok { fails += 1 }
        }
        func states(_ a: NSAttributedString) -> [Int] {
            var out: [Int] = []
            a.enumerateAttribute(.airpadChecklistGlyph, in: NSRange(location: 0, length: a.length), options: []) { v, _, _ in
                if let s = v as? Int { out.append(s) }
            }
            return out
        }
        for font in [NoteFontChoice.system, .sourceSerif4] {
            func roundTrip(_ md: String) -> (read: [Int], saved: String, reread: [Int]) {
                let tv = UITextView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
                tv.font = NoteTypographyHelper.bodyFont
                tv.attributedText = MarkdownCodec.decode(md)
                NoteTypography.applyInPlace(to: tv, font: font)
                let saved = MarkdownCodec.encode(tv.attributedText)
                return (states(tv.attributedText), saved, states(MarkdownCodec.decode(saved)))
            }
            let tag = "\(font)"
            let old = "- \\[x] Fix test done\n- \\[ ] Fix test open\n  - \\[x] Fix test nested"
            let std = "- [x] Fix test done\n- [ ] Fix test open\n  - [x] Fix test nested"
            let o = roundTrip(old)
            row("old form `- \\[x]` reads as checklists (\(tag))", o.read == [1, 0, 1], "\(o.read)")
            row("old form saves as standard `- [x]` / `- [ ]` (\(tag))", o.saved == std, o.saved)
            row("…and reads back the same (\(tag))", o.reread == [1, 0, 1], "\(o.reread)")
            let n = roundTrip(std)
            row("standard form reads as checklists (\(tag))", n.read == [1, 0, 1], "\(n.read)")
            row("standard form round-trips unchanged (\(tag))", n.saved == std, n.saved)
            let mixed = "- [x] Fix test **bold** task\nplain line \\[x] stays text"
            let m = roundTrip(mixed)
            row("a bold word in an item and a literal [x] in text are kept (\(tag))", m.saved == mixed && m.read == [1], "\(m.saved) \(m.read)")
        }
        return "[ChecklistCodecSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
