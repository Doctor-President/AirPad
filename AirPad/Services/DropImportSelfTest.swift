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
#endif
