#if DEBUG
import Foundation
import UIKit
import UniformTypeIdentifiers

/// live-13 (4) — `-DocumentNamingSelfTest`: an imported document is named from its REAL name, never a temp/UUID file
/// name. Per path, with synthetic files whose providers hand over a temp/UUID path: Paste Pad (a pasteboard PDF, with
/// and without the provider's suggested name), the share sheet (the staged item the app imports through the schema
/// migration), the Files picker (a picked file; a picked temp copy). Then the shown-name order: the real name (minus
/// its extension), else the PDF's own Title, else "PDF · <date>". Runs in the `-UITestLibrary` scratch; synthetic only.
extension CorpusStore {

    /// What the app shows as the document's name.
    private func shownDocumentName(_ d: DocumentItem) -> String { d.displayName }

    func runDocumentNamingSelfTest() async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ got: String, _ want: String) {
            let ok = got == want
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok ? "" : " — shown=\"\(got)\" want=\"\(want)\""))
            if !ok { fails += 1 }
        }
        let today = Date()
        let dated = "PDF · " + today.formatted(date: .abbreviated, time: .omitted)
        let pdf = Self.syntheticPDF(title: nil), titled = Self.syntheticPDF(title: "Synthetic Harbour Report")
        let tmp = FileManager.default.temporaryDirectory
        let uuidPDF = { () -> URL in
            let u = tmp.appendingPathComponent(UUID().uuidString + ".pdf"); try? pdf.write(to: u); return u
        }

        // One scratch entry per row; the newest document item it holds.
        func imported(_ urls: [URL]) async -> DocumentItem? {
            let id = "docname-" + UUID().uuidString.prefix(8)
            var node = Node(id: id, createdAt: today, updatedAt: today, title: "", summary: "", tags: [])
            node.entrySchemaVersion = 1
            await addNode(node, position: .zero)
            await addDocumentEntry(nodeID: id, sourceURLs: urls)
            return nodes.first { $0.id == id }?.items.last { $0.type == .document }?.documentItems?.first
        }

        // Paste Pad — the pasteboard hands over bytes; the router writes them to a temp file.
        do {
            let pb = UIPasteboard.withUniqueName(); defer { UIPasteboard.remove(withName: pb.name) }
            let p = NSItemProvider(item: pdf as NSData, typeIdentifier: UTType.pdf.identifier)
            p.suggestedName = "Harbour Survey"
            pb.setItemProviders([p], localOnly: true, expirationDate: nil)
            if case .file(let url, _) = ClipboardContentRouter.classify(pb), let d = await imported([url]) {
                row("paste-pad-pdf-uses-suggested-name", shownDocumentName(d), "Harbour Survey")
            } else { row("paste-pad-pdf-uses-suggested-name", "not a document", "Harbour Survey") }
        }
        do {
            let pb = UIPasteboard.withUniqueName(); defer { UIPasteboard.remove(withName: pb.name) }
            pb.items = [[UTType.pdf.identifier: pdf]]
            if case .file(let url, _) = ClipboardContentRouter.classify(pb), let d = await imported([url]) {
                row("paste-pad-pdf-no-name-no-title-is-dated", shownDocumentName(d), dated)
            } else { row("paste-pad-pdf-no-name-no-title-is-dated", "not a document", dated) }
        }

        // Share sheet — the extension stages a legacy document item (file + the name it was given); the app's
        // schema migration turns it into the document.
        func shared(file: String, given: String?) -> DocumentItem? {
            var n = Node(id: "share-" + UUID().uuidString.prefix(8), createdAt: today, updatedAt: today, title: "", summary: "", tags: [])
            n.items = [NodeItem(id: UUID().uuidString, type: .document, createdAt: today, content: nil, file: file,
                                description: given, transcript: nil, durationSeconds: nil, url: nil, title: nil, preview: nil)]
            _ = migrateEntrySchemaIfNeeded(&n)
            return n.items.first?.documentItems?.first
        }
        let itemFile = "items/\(UUID().uuidString).pdf"
        row("share-sheet-keeps-the-name-it-was-given", shared(file: itemFile, given: "Harbour Survey.pdf").map(shownDocumentName) ?? "none",
            "Harbour Survey")
        row("share-sheet-temp-name-is-dated", shared(file: itemFile, given: UUID().uuidString + ".pdf").map(shownDocumentName) ?? "none",
            dated)
        row("share-sheet-provider-suggested-name-wins",
            DocumentNaming.realName(suggested: "Harbour Survey", url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).pdf")) ?? "none",
            "Harbour Survey.pdf")

        // Files picker — a picked file keeps its name (minus the extension); a temp copy doesn't leak a UUID.
        do {
            let dir = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let picked = dir.appendingPathComponent("Harbour Survey.pdf"); try? pdf.write(to: picked)
            row("files-picker-keeps-the-file-name", await imported([picked]).map(shownDocumentName) ?? "none", "Harbour Survey")
            row("files-picker-temp-uuid-is-dated", await imported([uuidPDF()]).map(shownDocumentName) ?? "none", dated)
        }

        // The shown-name order.
        let base = DocumentItem(id: "x", filePath: "items/x.pdf", fileName: "", fileType: "pdf", documentTitle: nil, extractedText: nil,
                                thumbnailFile: nil, pageCount: nil, wordCount: nil, capturedAt: today)
        var d = base; d.documentTitle = "Synthetic Harbour Report"
        row("no-real-name-uses-pdf-title", shownDocumentName(d), "Synthetic Harbour Report")
        d = DocumentItem(id: "x", filePath: "items/x.pdf", fileName: "Harbour Survey.pdf", fileType: "pdf", documentTitle: "Untitled-1",
                         extractedText: nil, thumbnailFile: nil, pageCount: nil, wordCount: nil, capturedAt: today)
        row("real-name-beats-pdf-title", shownDocumentName(d), "Harbour Survey")
        d = DocumentItem(id: "x", filePath: "items/x.pdf", fileName: "\(UUID().uuidString).pdf", fileType: "pdf", documentTitle: nil,
                         extractedText: nil, thumbnailFile: nil, pageCount: nil, wordCount: nil, capturedAt: today)
        row("legacy-uuid-name-shows-dated", shownDocumentName(d), dated)
        // The PDF's Title metadata, read from a real synthetic PDF.
        row("pdf-title-metadata-is-read", DocumentNaming.pdfTitle(data: titled) ?? "none", "Synthetic Harbour Report")

        rows.append("INFO drag-and-drop: the app has no drop target (no onDrop/dropDestination) — no path to name")
        return "[DocumentNamingSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - 1 - fails)/\(rows.count - 1)\n"
            + rows.joined(separator: "\n")
    }

    /// A one-page synthetic PDF, with Title metadata when given.
    static func syntheticPDF(title: String?) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        if let title { format.documentInfo = [kCGPDFContextTitle as String: title] }
        return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200), format: format).pdfData { ctx in
            ctx.beginPage()
            ("Synthetic page." as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
    }
}
#endif
