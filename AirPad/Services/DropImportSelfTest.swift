#if DEBUG
import UIKit
import UniformTypeIdentifiers

/// Mac batch C4 — `-DropImportSelfTest` (with `-StubAuthorModel`): drops built from real `NSItemProvider`s, through
/// the window's drop handler (`importDrop`, the share extension's staging + the inbox import): plain text, two `.md`
/// files (one entry each), a web URL, an image; a drop with an entry open (added to it); an image put into a note at the
/// caret (the editor's drop / paste path). Nothing may stay outside the library (the staging folder goes).
/// Synthetic text and pixels only; the entries it makes are deleted.
extension CorpusStore {
    func runDropImportSelfTest() async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
        let tmp = FileManager.default.temporaryDirectory
        func stagingLeft() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).filter { $0.hasPrefix("drop-inbox-") }
        }
        var made: [String] = []

        // 1. Plain text.
        let t = await importDrop([NSItemProvider(object: "Dropped text: the drop test's first line." as NSString)])
        made += t
        row("text → one new entry with the text", t.count == 1 && node(t[0])?.items.first?.type == .text
            && node(t[0])?.items.first?.content == "Dropped text: the drop test's first line.", "\(t.count) entries")

        // 2. Two .md files → one entry each, their text as the note.
        var urls: [URL] = []
        for (i, body) in ["# Drop one\nFirst file body.", "Second file, plain text."].enumerated() {
            let u = tmp.appendingPathComponent("drop-test-\(i + 1).md")
            try? body.write(to: u, atomically: true, encoding: .utf8)
            urls.append(u)
        }
        let md = await importDrop(urls.compactMap { NSItemProvider(contentsOf: $0) })
        made += md
        row(".md files → one entry each", md.count == 2, "\(md.count) entries")
        row(".md text is the note", md.count == 2 && node(md[0])?.items.first?.content == "# Drop one\nFirst file body."
            && node(md[1])?.items.first?.content == "Second file, plain text.",
            md.map { (node($0)?.items.first?.content ?? "nil").debugDescription }.joined(separator: " | "))
        urls.forEach { try? FileManager.default.removeItem(at: $0) }

        // 3. A web URL → a link entry.
        let up = NSItemProvider(object: URL(string: "https://example.com/airpad-drop-test")! as NSURL)
        let probe: String = await withCheckedContinuation { c in
            up.loadItem(forTypeIdentifier: UTType.url.identifier) { item, err in
                c.resume(returning: "types=\(up.registeredTypeIdentifiers) item=\(item.map { String(describing: type(of: $0)) } ?? "nil") err=\(err.map { "\($0)" } ?? "nil")")
            }
        }
        NSLog("[DropImportSelfTest] url provider: %@", probe)
        let link = await importDrop([NSItemProvider(object: URL(string: "https://example.com/airpad-drop-test")! as NSURL)])
        made += link
        row("URL → a link entry", link.count == 1 && node(link[0])?.items.first?.type == .link
            && node(link[0])?.items.first?.url == "https://example.com/airpad-drop-test")

        // 4. An image → an entry with the picture saved in the library.
        let img = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { c in
            UIColor(red: 0x1B / 255.0, green: 0x59 / 255.0, blue: 0xC2 / 255.0, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let pic = await importDrop([NSItemProvider(object: img)])
        made += pic
        let picNode = pic.first.flatMap(node)
        let media = picNode?.items.first { [.image, .imageVideo].contains($0.type) }
        let file = media?.file ?? media?.mediaItems?.first?.file
        var onDisk: URL? = nil
        if let id = pic.first, let file { onDisk = await resolveItemPathForSelfTest(nodeID: id, relativePath: file) }
        row("image → an entry, picture in the library", picNode != nil && file != nil
            && onDisk.map { FileManager.default.fileExists(atPath: $0.path) } == true,
            "type=\(media.map { "\($0.type)" } ?? "nil") file=\(file ?? "nil")")

        // 5. With an entry open, a drop is added to it (the share's "Existing entry" path).
        if let target = t.first {
            let before = node(target)?.items.count ?? 0
            let r = await importDrop([NSItemProvider(object: "Added by a drop onto the open entry." as NSString)], appendTo: target)
            row("drop with an entry open → added to it", r == [target] && (node(target)?.items.count ?? 0) == before + 1
                && node(target)?.items.last?.content == "Added by a drop onto the open entry.")
        }
        row("nothing left outside the library (staging removed)", stagingLeft().isEmpty, "\(stagingLeft())")

        for id in made { await deleteNode(id: id) }
        return "[DropImportSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}

/// Mac fix-up X9 — `-ShareAppendSelfTest`: a share / drop of a link INTO an existing entry, through the one path the
/// share extension's inbox import and a drop onto an open entry both take (`importDrop(appendTo:)` → `importShareAppend`
/// → `appendSharedItems`), with real `NSItemProvider`s staged by `ShareItemLoader`. Per case the entry as saved on
/// disk: the link lands in the entry's Link item (the last of two), a new Link item only when there is none, text
/// alongside becomes a Note, an empty text never does. Scratch entries, deleted after.
extension CorpusStore {
    func runShareAppendSelfTest() async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        var made: [String] = []
        let now = Date()
        func entry(note: String, links: [[String]]) async -> String {
            let id = "sa-" + UUID().uuidString.prefix(8)
            var n = Node(id: id, createdAt: now, updatedAt: now, title: "Fix test share", summary: "", tags: [])
            n.items = [ShareItemLoader.makeTextItem(text: note, now: now)]
            for group in links {
                let itemID = UUID().uuidString
                var item = NodeItem(id: itemID, type: .link, createdAt: now, url: group.first,
                                    linkItems: group.enumerated().map { i, u in
                                        LinkItem(id: i == 0 ? itemID : UUID().uuidString, url: u, title: "t", description: nil,
                                                 imageFile: nil, siteName: nil, faviconFile: nil, capturedAt: now) })
                item.ogFetchedAt = now   // no page fetch for the existing links
                n.items.append(item)
            }
            n.entrySchemaVersion = 1
            n.titleSource = .user
            await addNode(n, position: .zero)
            made.append(id)
            return id
        }
        func providers(link: String, text: String?) -> [NSItemProvider] {
            var p = [NSItemProvider(object: URL(string: link)! as NSURL)]
            if let text { p.append(NSItemProvider(object: text as NSString)) }
            return p
        }
        /// (link items, urls per link item, notes) of the entry as saved on disk.
        func onDisk(_ id: String) async -> (links: Int, urls: [[String]], notes: [String]) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            let n = await debugReloadFromDisk(id: id)
            let links = (n?.items ?? []).filter { $0.type == .link }
            return (links.count, links.map { ($0.linkItems ?? []).map(\.url) }, (n?.items ?? []).filter { $0.type == .text }.map { $0.content ?? "" })
        }
        let A = "https://example.com/share-a", B = "https://example.org/share-b", NEW = "https://example.net/share-new"

        // 1. Entry WITH a Link item × link only → into that Link item; nothing else.
        let e1 = await entry(note: "Fix test note one", links: [[A]])
        _ = await importDrop(providers(link: NEW, text: nil), appendTo: e1)
        let d1 = await onDisk(e1)
        row("with a Link item · link only → added to it, no new item", d1.links == 1 && d1.urls.first == [A, NEW] && d1.notes == ["Fix test note one"],
            "\(d1)")
        // 2. Entry WITH a Link item × link + text → link into it, the text a Note.
        let e2 = await entry(note: "Fix test note two", links: [[A]])
        _ = await importDrop(providers(link: NEW, text: "Shared page title"), appendTo: e2)
        let d2 = await onDisk(e2)
        row("with a Link item · link + text → link added to it, the text a Note", d2.links == 1 && d2.urls.first == [A, NEW]
            && d2.notes == ["Fix test note two", "Shared page title"], "\(d2)")
        // 3. Entry WITHOUT a Link item × link only → one new Link item, no empty Note.
        let e3 = await entry(note: "Fix test note three", links: [])
        _ = await importDrop(providers(link: NEW, text: nil), appendTo: e3)
        let d3 = await onDisk(e3)
        row("no Link item · link only → one new Link item, no Note added", d3.links == 1 && d3.notes == ["Fix test note three"], "\(d3)")
        // 4. Entry WITHOUT a Link item × link + EMPTY text (a page with nothing selected) → no empty Note.
        let e4 = await entry(note: "Fix test note four", links: [])
        _ = await importDrop(providers(link: NEW, text: "  "), appendTo: e4)
        let d4 = await onDisk(e4)
        row("no Link item · link + empty text → one new Link item, never an empty Note", d4.links == 1 && d4.notes == ["Fix test note four"], "\(d4)")
        // 4b. Link + its own URL as text (what a browser can hand over) → nothing extra.
        let e4b = await entry(note: "Fix test note four b", links: [[A]])
        _ = await importDrop(providers(link: NEW, text: NEW), appendTo: e4b)
        let d4b = await onDisk(e4b)
        row("with a Link item · link + its URL as text → no Note repeating the link", d4b.links == 1 && d4b.notes == ["Fix test note four b"], "\(d4b)")
        // 5. Entry with TWO Link items × link → into the LAST one.
        let e5 = await entry(note: "Fix test note five", links: [[A], [B]])
        _ = await importDrop(providers(link: NEW, text: nil), appendTo: e5)
        let d5 = await onDisk(e5)
        row("two Link items · link → into the last one", d5.links == 2 && d5.urls == [[A], [B, NEW]], "\(d5)")
        // 6. A new entry from a link + empty text (the share's "New entry") → no empty Note either.
        let n6 = await importDrop(providers(link: NEW, text: ""))
        made += n6
        try? await Task.sleep(nanoseconds: 600_000_000)
        let d6 = await debugReloadFromDisk(id: n6.first ?? "")
        row("new entry · link + empty text → no empty Note", d6.map { !$0.items.contains { $0.type == .text && ($0.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } } ?? false,
            "\(d6?.items.map { "\($0.type)" } ?? [])")

        for id in made { await deleteNode(id: id) }
        return "[ShareAppendSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
