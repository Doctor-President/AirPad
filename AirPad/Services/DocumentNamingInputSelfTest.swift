#if DEBUG
import Foundation
import UIKit
import UniformTypeIdentifiers

/// live-15 (1) — `-DocumentNamingInputSelfTest` (run with `-StubAuthorModel -StubEchoInput`): an imported document is
/// named from ITS OWN text, right after another capture. T's device: a capture, then an 11-page PDF whose title was
/// invented (no summary) — the naming call saw only the 22-character file name. `-StubEchoInput` makes the title and
/// summary out of the words the naming call was given, so each row asserts what reached the model:
///   • title + summary overlap the PDF's own terms; neither carries the earlier capture's terms; both set or both absent;
///   • per import path — Files picker (`addDocumentEntry`, the document's screen never shown, so nothing else extracts
///     it), Paste Pad (pasteboard PDF → router → `addDocumentEntry`), share sheet (the inbox record exactly as the
///     extension stages it → `refreshShareInbox`);
///   • a PDF with no text → no invented name (both absent);
///   • a proposal made for another entry never commits here.
/// Runs in the `-UITestLibrary` scratch; synthetic words only.
extension CorpusStore {

    private static let captureText = "Orchard notes: the frost arrived early this year, so the apple harvest moved forward a week and the pickers worked the hillside rows until dusk."
    private static let captureTerms = ["orchard", "frost", "apple", "harvest", "pickers", "hillside"]
    private static let pdfPages = [
        "Breakwater Survey. The lighthouse keepers logged the spring tides along the northern breakwater every evening.",
        "Beacon maintenance: the keepers replaced the beacon lens and recorded tide heights at the harbour mouth.",
        "Summary of the season: the breakwater held through four storms; the lighthouse beacon never failed.",
    ]
    private static let pdfTerms = ["breakwater", "survey", "lighthouse", "keepers", "tides", "beacon", "harbour", "tide", "heights", "storms", "season", "maintenance"]

    /// A multi-page synthetic PDF with `pages` of text (none → one blank page), no Title metadata.
    static func syntheticTextPDF(pages: [String]) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 400)).pdfData { ctx in
            for text in pages.isEmpty ? [""] : pages {
                ctx.beginPage()
                (text as NSString).draw(in: CGRect(x: 20, y: 20, width: 360, height: 360),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
    }

    func runDocumentNamingInputSelfTest() async -> String {
        var rows: [String] = [], fails = 0
        let priorSetting = UserDefaults.standard.object(forKey: AuthorshipPosture.delegateSettingKey)
        UserDefaults.standard.set(true, forKey: AuthorshipPosture.delegateSettingKey)
        defer { UserDefaults.standard.set(priorSetting, forKey: AuthorshipPosture.delegateSettingKey) }

        func words(_ s: String) -> Set<String> { Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)) }
        func hits(_ s: String, _ terms: [String]) -> [String] { terms.filter { words(s).contains($0) } }
        /// The entry's committed title + summary must be about the PDF, carry nothing of the capture, and come as a pair.
        func checkAboutPDF(_ name: String, _ id: String) {
            guard let n = nodes.first(where: { $0.id == id }) else { row(name, false, "entry missing"); return }
            let t = n.title, s = n.summary
            let leaked = hits(t + " " + s, Self.captureTerms)
            let ok = !hits(t, Self.pdfTerms).isEmpty && !hits(s, Self.pdfTerms).isEmpty && leaked.isEmpty
            row(name, ok, "title=\"\(t)\" (\(hits(t, Self.pdfTerms).count) PDF terms) summary \(s.count) chars (\(hits(s, Self.pdfTerms).count) PDF terms) capture terms=\(leaked)")
        }
        func row(_ name: String, _ ok: Bool, _ detail: String) {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        func newEntry(_ id: String, items: [NodeItem] = []) async {
            var n = Node(id: id, createdAt: Date(), updatedAt: Date(), title: "", summary: "", tags: [])
            n.items = items
            n.entrySchemaVersion = 1
            await addNode(n, position: .zero)
        }
        /// The earlier capture: typed text, Done — named first, as on T's device.
        func captureFirst() async -> String {
            let id = "dni-cap-" + UUID().uuidString.prefix(6)
            await newEntry(id, items: [NodeItem(id: UUID().uuidString, type: .text, createdAt: Date(), content: Self.captureText)])
            await enrichIfNeeded(nodeID: id, at: .committed)
            return id
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let pdf = Self.syntheticTextPDF(pages: Self.pdfPages)
        var made: [String] = []

        // 1. Files picker — a capture, then a new entry with a picked PDF; Done before its screen ever shows.
        do {
            made.append(await captureFirst())
            let url = tmp.appendingPathComponent("quarterly-brief.pdf"); try? pdf.write(to: url)
            let id = "dni-files-" + UUID().uuidString.prefix(6)
            await newEntry(id); made.append(id)
            await addDocumentEntry(nodeID: id, sourceURLs: [url])
            await enrichIfNeeded(nodeID: id, at: .committed)
            checkAboutPDF("files-picker-after-capture-names-from-the-pdf", id)
        }

        // 2. Paste Pad — a pasteboard PDF (the router's temp file → addDocumentEntry).
        do {
            made.append(await captureFirst())
            let pb = UIPasteboard.withUniqueName(); defer { UIPasteboard.remove(withName: pb.name) }
            let p = NSItemProvider(item: pdf as NSData, typeIdentifier: UTType.pdf.identifier)
            p.suggestedName = "quarterly-brief"
            pb.setItemProviders([p], localOnly: true, expirationDate: nil)
            let id = "dni-paste-" + UUID().uuidString.prefix(6)
            await newEntry(id); made.append(id)
            if case .file(let url, _) = ClipboardContentRouter.classify(pb) {
                await addDocumentEntry(nodeID: id, sourceURLs: [url])
                await enrichIfNeeded(nodeID: id, at: .committed)
                checkAboutPDF("paste-pad-after-capture-names-from-the-pdf", id)
            } else { row("paste-pad-after-capture-names-from-the-pdf", false, "the paste was not a document") }
        }

        // 3. Share sheet — the inbox record exactly as the extension stages it (a legacy document item: file + the
        //    name it was given, the file name as placeholder title, needsAIProcessing), then the app's import.
        func shared(_ fileName: String, _ data: Data) async -> String? {
            let id = UUID().uuidString, itemID = UUID().uuidString
            let n = Node(id: id, createdAt: Date(), updatedAt: Date(), title: (fileName as NSString).deletingPathExtension,
                         summary: "", tags: [], mood: nil, isMeta: false, provenance: nil, threads: [], location: nil,
                         items: [NodeItem(id: itemID, type: .document, createdAt: Date(), content: nil, file: "items/\(itemID).pdf",
                                          description: fileName, transcript: nil, durationSeconds: nil, url: nil,
                                          title: nil, preview: nil)],
                         domain: nil, domainConfirmed: false, needsAIProcessing: true)
            guard let inbox = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.doctorpresident.airpad")?
                .appendingPathComponent("AirPad/inbox/\(id)") else { return nil }
            try? FileManager.default.createDirectory(at: inbox.appendingPathComponent("items"), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try? enc.encode(n).write(to: inbox.appendingPathComponent("node.json"), options: .atomic)
            try? data.write(to: inbox.appendingPathComponent("items/\(itemID).pdf"), options: .atomic)
            await refreshShareInbox(); made.append(id)
            return id
        }
        do {
            made.append(await captureFirst())
            if let id = await shared("quarterly-brief.pdf", pdf) {
                checkAboutPDF("share-sheet-after-capture-names-from-the-pdf", id)
            } else { row("share-sheet-after-capture-names-from-the-pdf", false, "no App Group container") }
        }

        // 4. A PDF with no text (a scan): only its file name to go on → no invented title, no summary.
        do {
            made.append(await captureFirst())
            let url = tmp.appendingPathComponent("scan-0001.pdf"); try? Self.syntheticTextPDF(pages: []).write(to: url)
            let id = "dni-scan-" + UUID().uuidString.prefix(6)
            await newEntry(id); made.append(id)
            await addDocumentEntry(nodeID: id, sourceURLs: [url])
            await enrichIfNeeded(nodeID: id, at: .committed)
            let n = nodes.first { $0.id == id }
            row("no-text-pdf-is-not-given-an-invented-name", n?.title.isEmpty == true && n?.summary.isEmpty == true,
                "title=\"\(n?.title ?? "<gone>")\" summary \(n?.summary.count ?? -1) chars")
        }

        // 4b. …the same scan via the share sheet, where the file name IS handed to naming (T's device case, minus its
        //     text): 19 characters, nothing the user wrote → no invented title, no summary.
        do {
            made.append(await captureFirst())
            if let id = await shared("scan-0001.pdf", Self.syntheticTextPDF(pages: [])) {
                let n = nodes.first { $0.id == id }
                let t = n?.title ?? "<gone>", src = n?.titleSource
                // The placeholder title the extension staged (the file name) may stay; a MODEL title or any summary may not.
                row("no-text-pdf-shared-is-not-given-an-invented-name", src != .model && (n?.summary.isEmpty ?? false),
                    "title=\"\(t)\" [\(src.map { "\($0)" } ?? "nil")] summary \(n?.summary.count ?? -1) chars")
            } else { row("no-text-pdf-shared-is-not-given-an-invented-name", false, "no App Group container") }
        }

        // 5. A proposal made for ANOTHER entry (same text, so even its content hash matches) never commits here.
        do {
            let a = "dni-a-" + UUID().uuidString.prefix(6), b = "dni-b-" + UUID().uuidString.prefix(6)
            let item = { NodeItem(id: UUID().uuidString, type: .text, createdAt: Date(), content: Self.captureText) }
            await newEntry(a, items: [item()]); await newEntry(b, items: [item()]); made += [a, b]
            await enrichIfNeeded(nodeID: a, at: .composing)   // a's own ghosts, for this text
            let foreign = nodes.first(where: { $0.id == a })?.proposals ?? []
            if foreign.contains(where: { $0.kind == .title }), foreign.contains(where: { $0.kind == .summary }) {
                let planted = foreign.map { p -> Proposal in var p = p; p.text = "Foreign Ghost " + p.kind.rawValue; return p }
                await mutateNode(id: b) { $0.proposals = planted }
                await enrichIfNeeded(nodeID: b, at: .committed)
                let n = nodes.first { $0.id == b }
                let t = n?.title ?? "<gone>", s = n?.summary ?? "<gone>"
                row("another-entry's-proposal-never-commits", !t.hasPrefix("Foreign Ghost") && !s.hasPrefix("Foreign Ghost") && !t.isEmpty,
                    "b's title=\"\(t)\" summary=\"\(s)\"")
            } else { row("another-entry's-proposal-never-commits", false, "a recorded no title+summary ghosts") }
        }

        for id in made { await deleteNode(id: id) }
        try? FileManager.default.removeItem(at: tmp)
        return "[DocumentNamingInputSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.joined(separator: "\n")
    }
}
#endif
