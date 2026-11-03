#if DEBUG
import Foundation
import UIKit

/// `-Batch11CSelfTest` — 1.1-C: the table codec round trip (storage ↔ editor ↔ storage, paste sources, previews), private
/// entries at every read path, the Eclipse → Aura migration, the adaptive 120 / 60 rate, the export's Markdown, and the
/// share sheet's index / append record. Synthetic entries are added in memory only (never saved) and removed after.
/// Launch with `-mapLook.v1 eclipse` to also check the saved-pick migration.
@MainActor
enum Batch11CSelfTest {
    static func run(store: CorpusStore) async -> String {
        var fails: [String] = []
        var n = 0
        func check(_ name: String, _ ok: @autoclosure () -> Bool) {
            n += 1
            let v = ok()   // once: some rows drive state (the rate controller)
            if !v { fails.append(name) }
            NSLog("[Batch11CSelfTest] %@ %@", v ? "ok" : "FAIL-ROW", name)
        }

        // MARK: Tables — storage
        let t1 = "Intro line\n| a | b |\n| --- | --- |\n| 1 | 2 |\nAfter"
        check("splitGFM-join-round-trip (prose · table · prose)", TableConverter.join(TableConverter.splitGFM(t1)) == t1)
        let t2 = "| h1 | h2 |\n| --- | --- |\n| x | y |"
        check("table-only note round trip", TableConverter.join(TableConverter.splitGFM(t2)) == t2)
        let t3 = "Top\n\n| h1 | h2 |\n| --- | --- |\n| x | y |\n\n| c | d |\n| --- | --- |\n| 3 | 4 |\n"
        check("two tables, blank lines, trailing newline round trip", TableConverter.join(TableConverter.splitGFM(t3)) == t3)
        check("split finds 2 tables", TableConverter.splitGFM(t3).filter { if case .table = $0 { return true }; return false }.count == 2)
        check("no table → one text segment", TableConverter.splitGFM("a | b\nno separator") == [.text("a | b\nno separator")])
        check("escaped pipe in a cell", TableConverter.cells("| a \\| b | c |") == ["a | b", "c"])
        let esc = MarkdownTable(headers: ["x|y", "z"], rows: [["1", "line\nbreak"]])
        if case .table(let back)? = TableConverter.splitGFM(TableConverter.gfm(esc)).first {
            check("gfm escapes pipes + line breaks and reads them back", back == esc)
        } else { check("gfm escapes pipes + line breaks and reads them back", false) }
        check("aligned / unbordered separator rows parse", TableConverter.splitGFM("a | b\n:-- | --:\n1 | 2").count == 1
              && { if case .table(let t) = TableConverter.splitGFM("a | b\n:-- | --:\n1 | 2")[0] { return t.rows == [["1", "2"]] }; return false }())

        // Editor codec: decode → one attachment per table; encode → the same Markdown.
        let dec = MarkdownCodec.decode(t1)
        var tables = 0
        dec.enumerateAttribute(.airpadTableID, in: NSRange(location: 0, length: dec.length)) { v, _, _ in if v != nil { tables += 1 } }
        check("decode: one table attachment, no pipes in the display text", tables == 1 && !dec.string.contains("|"))
        check("encode(decode(note with a table)) == note", MarkdownCodec.encode(dec) == t1)
        check("encode(decode(two tables)) == note", MarkdownCodec.encode(MarkdownCodec.decode(t3)) == t3)
        let typedAfter = NSMutableAttributedString(attributedString: MarkdownCodec.decode(t2))
        typedAfter.append(NSAttributedString(string: "typed"))
        check("text typed right after a table lands on its own line", MarkdownCodec.encode(typedAfter) == t2 + "\ntyped")

        // Paste sources.
        let html = "<p>Hello <b>there</b></p><table><thead><tr><th>A</th><th>B</th></tr></thead><tr><td>1</td><td>2&amp;3</td></tr></table><p>Bye</p>"
        let hs = TableConverter.segments(html: html, text: "ignored") ?? []
        check("HTML paste: prose · table · prose", hs.count == 3
              && { if case .table(let t) = hs[1] { return t.headers == ["A", "B"] && t.rows == [["1", "2&3"]] }; return false }()
              && { if case .text(let a) = hs[0], case .text(let b) = hs[2] { return a.contains("Hello there") && b.contains("Bye") }; return false }())
        check("HTML layout table (nested) stays prose", (TableConverter.segments(html: "<table><tr><td><table><tr><td>x</td><td>y</td></tr></table></td></tr></table>", text: nil) ?? [])
              .allSatisfy { if case .text = $0 { return true }; return false })
        let tsv = TableConverter.segments(html: nil, text: "Before\nName\tAge\nSam\t3\nJo\t4\nAfter") ?? []
        check("TSV (Numbers / Excel) mixed with prose", tsv.count == 3
              && { if case .table(let t) = tsv[1] { return t.headers == ["Name", "Age"] && t.rows.count == 2 }; return false }())
        check("pipe table pasted from chat", { if case .table? = TableConverter.segments(html: nil, text: t2)?.first { return true }; return false }())
        check("CSV (whole text)", { if case .table(let t)? = TableConverter.segments(html: nil, text: "a,b,c\n1,\"2,5\",3")?.first { return t.rows == [["1", "2,5", "3"]] }; return false }())
        check("a letter with commas is not CSV", TableConverter.segments(html: nil, text: "Hi Sam,\nThanks,\nBob") == nil)
        check("prose with one comma per line is not CSV", TableConverter.segments(html: nil, text: "We went out, and it rained all day long in the end\nThen we came home, tired and very wet indeed") == nil)
        check("plain prose → no table (system paste)", TableConverter.segments(html: nil, text: "just words") == nil)

        // Previews never show pipes.
        let plain = MarkdownPlain.text(t1)
        check("MarkdownPlain.text: rows as 'a · b', no pipes", !plain.contains("|") && plain.contains("a · b") && plain.contains("1 · 2"))
        check("MarkdownPlain.block on a stored row / separator", MarkdownPlain.block("| a | b |") == "a · b" && MarkdownPlain.block("| --- | --- |").isEmpty)
        check("card decoder input has no pipes", !MarkdownPlain.forDecoder(t1).contains("|"))

        // TextKit (reported; the live editor logs [TEXTKIT] too).
        let probe = RichTextUIView()
        NSLog("[Batch11CSelfTest] textkit=%@", probe.usesTextKit2 ? "2" : "1")

        // MARK: Export (C5)
        let now = Date()
        func item(_ type: NodeItemType, content: String? = nil, file: String? = nil, url: String? = nil, title: String? = nil, id: String = UUID().uuidString) -> NodeItem {
            NodeItem(id: id, type: type, createdAt: now, content: content, file: file, description: nil, transcript: nil,
                     durationSeconds: nil, url: url, title: title, preview: nil)
        }
        let imgID = "IMG1"
        var exportNode = Node(id: "export-test", createdAt: now, updatedAt: now, title: "Trip / plan", summary: "", tags: [], mood: nil,
                              isMeta: false, provenance: nil, threads: [], location: nil,
                              items: [item(.text, content: "- \\[ ] pack\n- \\[x] book\n\(MarkdownCodec.imageToken(itemID: imgID))\n" + t2),
                                      item(.imageVideo, file: "items/IMG1.jpg", id: imgID),
                                      item(.link, url: "https://example.com", title: "Example")],
                              domain: nil, domainConfirmed: false, needsAIProcessing: false)
        let withAssets = EntryExporter.markdown(for: exportNode, withAssets: true) { _, _ in URL(fileURLWithPath: "/tmp/x.jpg") }
        NSLog("[Batch11CSelfTest] export sample:\n%@", withAssets.text)
        check("export: title heading, checkboxes standard, table GFM, image → assets/, link", withAssets.text.hasPrefix("# Trip / plan")
              && withAssets.text.contains("- [ ] pack") && withAssets.text.contains("- [x] book")
              && withAssets.text.contains("| h1 | h2 |") && withAssets.text.contains("![](assets/image-1.jpg)")
              && withAssets.text.contains("[Example](https://example.com)") && withAssets.assets.count == 1
              && !withAssets.text.contains("airpad-image"))
        let mdOnly = EntryExporter.markdown(for: exportNode, withAssets: false) { _, _ in nil }
        check("export .md alone: no assets, no image tokens", mdOnly.assets.isEmpty && !mdOnly.text.contains("assets/") && !mdOnly.text.contains("airpad-image"))
        check("export file name is safe", EntryExporter.baseName(exportNode) == "Trip   plan" || !EntryExporter.baseName(exportNode).contains("/"))

        // MARK: Save to folder… (1.1-C fix-up (3)) — on a scratch folder, through the same file work as the real save
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("folder-export-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let srcImg = scratch.appendingPathComponent("src.jpg")
        try? Data([0xFF, 0xD8, 0xFF]).write(to: srcImg)
        let vault = scratch.appendingPathComponent("Vault", isDirectory: true)
        try? fm.createDirectory(at: vault, withIntermediateDirectories: true)
        let base = EntryExporter.baseName(exportNode)
        let first = try? EntryExporter.writeNote(exportNode, into: vault) { _, _ in srcImg }
        let firstText = (try? String(contentsOf: vault.appendingPathComponent(base + ".md"), encoding: .utf8)) ?? ""
        let img1 = "\(base) image-1.jpg"
        check("folder: <name>.md + attachments/<name> image-1.jpg, linked relatively", first == base + ".md"
              && fm.fileExists(atPath: vault.appendingPathComponent("attachments/" + img1).path)
              && firstText.contains("![](attachments/" + img1.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + ")")
              && !firstText.contains("assets/"))
        let second = try? EntryExporter.writeNote(exportNode, into: vault) { _, _ in srcImg }
        check("folder: a name clash adds \" 2\" (note and its files), the first is untouched", second == base + " 2.md"
              && fm.fileExists(atPath: vault.appendingPathComponent("attachments/\(base) 2 image-1.jpg").path)
              && ((try? String(contentsOf: vault.appendingPathComponent(base + ".md"), encoding: .utf8)) ?? "") == firstText)
        try? Data([0]).write(to: vault.appendingPathComponent("attachments/\(base) 3 image-1.jpg"))
        let third = try? EntryExporter.writeNote(exportNode, into: vault) { _, _ in srcImg }
        let thirdText = (try? String(contentsOf: vault.appendingPathComponent(base + " 3.md"), encoding: .utf8)) ?? ""
        check("folder: an attachment clash adds \" 2\" and the link follows", third == base + " 3.md"
              && thirdText.contains(("attachments/\(base) 3 image-1 2.jpg").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))
        let textOnly = Node(id: "export-text", createdAt: now, updatedAt: now, title: "Just text", summary: "", tags: [], mood: nil,
                            isMeta: false, provenance: nil, threads: [], location: nil, items: [item(.text, content: "Hello")],
                            domain: nil, domainConfirmed: false, needsAIProcessing: false)
        let plainDir = scratch.appendingPathComponent("Plain", isDirectory: true)
        try? fm.createDirectory(at: plainDir, withIntermediateDirectories: true)
        _ = try? EntryExporter.writeNote(textOnly, into: plainDir) { _, _ in nil }
        check("folder: a text-only note is just the .md (no attachments/)",
              (try? fm.contentsOfDirectory(atPath: plainDir.path)) == ["Just text.md"])
        check("freeName: stem, stem 2, stem 3", PickedFolder.freeName("a", ext: "md") { ["a.md", "a 2.md"].contains($0) } == "a 3.md")
        let picked = PickedFolder(key: "selftest.pickedFolder")
        try? picked.remember(vault)
        check("picked folder: the bookmark resolves to the folder", picked.url?.standardizedFileURL.resolvingSymlinksInPath().path
              == vault.standardizedFileURL.resolvingSymlinksInPath().path && picked.name == "Vault")
        picked.forget()
        check("picked folder: forget clears it", picked.url == nil)
        try? fm.removeItem(at: scratch)
        exportNode.items = []

        // MARK: Dots (1.1-C fix-up (2))
        func side(_ json: String) -> MapGroundSide? { try? JSONDecoder().decode(MapGroundSide.self, from: Data(json.utf8)) }
        let oldDefault = side(#"{"custom":true,"color":"FFEEED","gradient":false,"color2":"FFF8EF","angle":90,"dot":"FFFFFF","dotOpacity":0.809}"#)
        let oldPicked = side(#"{"custom":true,"color":"111115","gradient":false,"color2":"FFF8EF","angle":90,"dot":"FF8800","dotOpacity":0.5}"#)
        check("dots: a 1.1-B ground still decodes; a default dot colour counts as not picked, another as picked",
              oldDefault?.dotEdited == false && oldPicked?.dotEdited == true && oldPicked?.dotShown == "FF8800")
        check("dots: not picked → the default dots of the background's side",
              oldDefault?.dotShown == MapGroundSide.lightDefault.dot
              && MapGroundSide(custom: true, color: "0A1A3A", gradient: false, color2: "0A1A3A", angle: 90, dot: "3B362F", dotOpacity: 0.805).dotShown == "FFFFFF")
        check("dots: no custom background → the library's dots unchanged",
              BackgroundGridSKView.dots(dark: true, ground: nil).opacity == AppearancePalette.libraryGridDotOpacity(dark: true)
              && BackgroundGridSKView.dots(dark: false, ground: nil).opacity == AppearancePalette.libraryGridDotOpacity(dark: false))
        let custom = MapGroundSide(custom: true, color: "1B2A4A", gradient: false, color2: "1B2A4A", angle: 90, dot: "FF8800", dotOpacity: 0.4, dotEdited: true)
        let libDots = BackgroundGridSKView.dots(dark: true, ground: custom)
        check("dots: a custom background's Dots reach the list / cards / grid", libDots.opacity == 0.4 && libDots.rgb == MapGroundSide.rgb("FF8800"))
        // Visible at the default opacity: the dot's peak over the ground, as contrast, on a few custom backgrounds.
        var worst: Float = 99
        for (light, hexes) in [(false, ["111115", "1B2A4A", "3A0F2A", "FFEEED", "E8F0FF"]), (true, ["FFEEED", "FFF6D8", "D9F2E6", "111115", "2A1B3A"])] {
            for h in hexes {
                var g = light ? MapGroundSide.lightDefault : MapGroundSide.darkDefault
                g.custom = true; g.color = h; g = g.readable
                let d = BackgroundGridSKView.dots(dark: !light, ground: g)
                let peak = g.colorRGB + (d.rgb - g.colorRGB) * d.opacity
                let cr = TitleInkRule.contrast(peak, g.colorRGB)
                worst = min(worst, cr)
                NSLog("[Batch11CSelfTest] dots %@ on #%@: %.2f:1", light ? "light" : "dark", g.color, cr)
            }
        }
        check("dots: visible at the default opacity on custom backgrounds, both appearances (worst ≥ 3:1)", worst >= 3)

        // MARK: Share sheet index / append (C1)
        let idx = ShareIndex(entries: [.init(id: "1", title: "Garden notes", updatedAt: now, isPrivate: false),
                                       .init(id: "2", title: "Private garden", updatedAt: now, isPrivate: true)])
        check("share index hides private unless unlocked", idx.visible(query: "garden", showPrivate: false).map(\.id) == ["1"]
              && idx.visible(query: "garden", showPrivate: true).count == 2 && idx.visible(query: "notes", showPrivate: true).map(\.id) == ["1"])
        let rec = ShareAppendRecord(target: "T", items: [item(.text, content: "hi")])
        let recData = try? JSONEncoder.airPad.encode(rec)
        check("append record round trip", recData.flatMap { try? JSONDecoder.airPad.decode(ShareAppendRecord.self, from: $0) }?.items.first?.content == "hi")

        // MARK: Private entries (C3) — every read path
        let priv = PrivateEntries.shared
        let wasRevealed = priv.revealed
        let colID = "selftest-col-\(UUID().uuidString)"
        func mk(_ id: String, _ title: String, privateFlag: Bool, collection: Bool = false) -> Node {
            var x = Node(id: id, createdAt: now, updatedAt: now, title: title, summary: "", tags: ["selftest-private-tag"], mood: nil,
                         isMeta: false, provenance: nil, threads: [], location: nil, items: [item(.text, content: "zqxprivword body")],
                         domain: nil, domainConfirmed: false, needsAIProcessing: false)
            x.isPrivate = privateFlag
            if collection { x.collectionIDs = [colID] }
            return x
        }
        let pub = mk("st-pub-\(UUID().uuidString)", "zqxpubtitle", privateFlag: false, collection: true)
        let hid = mk("st-hid-\(UUID().uuidString)", "zqxprivtitle", privateFlag: true, collection: true)
        store.nodes.insert(contentsOf: [pub, hid], at: 0)
        defer { store.nodes.removeAll { $0.id == pub.id || $0.id == hid.id } }
        priv.debugSetRevealed(false)
        func has(_ a: [Node], _ x: Node) -> Bool { a.contains { $0.id == x.id } }
        check("hidden: userNodes", has(store.userNodes, pub) && !has(store.userNodes, hid))
        check("hidden: corpusRoomNodes (Map, search, Librarian room)", !has(store.corpusRoomNodes, hid))
        check("hidden: filteredNodes / visibleNodes (Map, list, grid)", !has(store.filteredNodes, hid) && !has(store.visibleNodes, hid))
        check("hidden: a collection's nodes + count", has(store.nodes(in: .collection(colID)), pub) && !has(store.nodes(in: .collection(colID)), hid)
              && store.visibleNodes(in: .collection(colID)).count == 1)
        check("hidden: tag counts", store.userNodeCount(forTag: "selftest-private-tag") == 1)
        check("hidden: priority / recents derive from userNodes", !store.priorityNodes.contains { $0.id == hid.id })
        check("hidden: hiddenNodeIDs + isHidden", store.hiddenNodeIDs.contains(hid.id) && store.isHidden(hid) && !store.isHidden(pub))
        let lib = LibrarianState()
        lib.searchText = "zqxprivtitle"
        lib.updateSearchMatches(store: store)
        check("hidden: search (title)", !lib.searchMatches.contains { $0.id == hid.id })
        lib.searchText = "zqxprivword"
        lib.updateSearchMatches(store: store)
        check("hidden: search (body) finds only the public entry", lib.searchMatches.contains { $0.id == pub.id } && !lib.searchMatches.contains { $0.id == hid.id })
        let blocks = await store.blocksForNodes(query: "x", nodeIDs: [hid.id])
        check("hidden: Librarian block reads skip it", blocks.isEmpty)
        check("hidden: the share index still lists it, flagged", { store.writeShareIndex(); return ShareIndex.load()?.entries.first { $0.id == hid.id }?.isPrivate == true }())
        priv.debugSetRevealed(true)
        check("shown: userNodes / room / collection", has(store.userNodes, hid) && has(store.corpusRoomNodes, hid) && has(store.nodes(in: .collection(colID)), hid))
        lib.searchText = "zqxprivtitle"
        lib.updateSearchMatches(store: store)
        check("shown: search finds it", lib.searchMatches.contains { $0.id == hid.id })
        priv.scenePhaseChanged(.background)
        check("background hides again", !priv.revealed && !has(store.userNodes, hid))
        priv.debugSetRevealed(wasRevealed)
        // Codable: the flag round-trips; an old entry reads as not private.
        if let d = try? JSONEncoder.airPad.encode(hid), let back = try? JSONDecoder.airPad.decode(Node.self, from: d),
           var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            obj.removeValue(forKey: "is_private")
            let old = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { try? JSONDecoder.airPad.decode(Node.self, from: $0) }
            check("Node.isPrivate round trip; absent = false", back.isPrivate && old?.isPrivate == false)
        } else { check("Node.isPrivate round trip; absent = false", false) }
        store.writeShareIndex()

        // MARK: Looks (C7)
        check("Eclipse → Aura", MapLookChoice.shipping(.eclipse) == .aura && !MapLookChoice.darkLineup.contains(.eclipse)
              && !MapLookChoice.proListNames.contains("Eclipse") && !MapLookStrength.has(.eclipse))
        if ProcessInfo.processInfo.arguments.contains("-mapLook.v1") {
            check("a saved Eclipse pick reads as Aura (launched with -mapLook.v1 eclipse)", MapLookChoice.picked == .aura)
        }
        let before = MapLookChoice.picked
        MapLookChoice.picked = .eclipse
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[MapLookChoice.storageKey] as? String
        check("picking Eclipse stores Aura", MapLookChoice.picked == .aura && stored == "aura")
        MapLookChoice.picked = before
        check("Aura = T's final values (aura-final-2026-10-30.json)", AuraLook() == AuraLook(1.02, 0.53, 0.01, 0, 0.29, 0, 0.19)
              && AuraLook.subtle == AuraLook(0.61, 0.82, 0.01, 0, 0.41, 0, 0.11) && AuraLook.strong == AuraLook(0.68, 1.26, 0.01, 0, 0.29, 0, 0.28))

        // MARK: Adaptive 120 (C8)
        var a = MapAdaptiveRate()
        var t: TimeInterval = 100
        func frames(_ k: Int, dt: TimeInterval, regime: Int = 1, start: Bool = false) -> Int {
            var r = 0
            for i in 0..<k { t += dt; r = a.frame(at: t, regime: regime, gestureStart: start && i == 0) }
            return r
        }
        check("steady 120 holds", frames(60, dt: 1.0 / 120, start: true) == 120)
        _ = frames(2, dt: 1.0 / 60)
        check("two misses don't drop", a.rate == 120)
        check("a third miss in 0.2 s drops to 60", frames(1, dt: 1.0 / 60) == 60)
        check("no way back up mid-gesture", frames(120, dt: 1.0 / 60) == 60)
        a.gestureEnded(regime: 1)
        t += 1
        check("a new gesture inside the hold stays 60", frames(10, dt: 1.0 / 60, start: true) == 60)
        a.gestureEnded(regime: 1)
        check("other regime (wells off) still gets 120", frames(10, dt: 1.0 / 120, regime: 0, start: true) == 120)
        a.gestureEnded(regime: 0)
        t += 5
        check("after the 4 s hold, the next gesture tries 120", frames(10, dt: 1.0 / 120, start: true) == 120)
        _ = frames(4, dt: 1.0 / 60)
        check("failing again holds longer (15 s)", a.rate == 60 && (a.regimes[1].holdUntil - t) > 10)
        a.gestureEnded(regime: 1)
        t += 16
        _ = frames(60, dt: 1.0 / 120, start: true)
        a.gestureEnded(regime: 1)
        check("a gesture that holds 120 to its end resets the failures", a.regimes[1].failures == 0 && a.rate == 120)
        check("120 Hz plist key present (one-line revert)", (Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool) == true)

        let verdict = fails.isEmpty ? "PASS — \(n)/\(n)" : "FAIL — \(n - fails.count)/\(n); failed: \(fails.joined(separator: " | "))"
        return verdict
    }
}
#endif
