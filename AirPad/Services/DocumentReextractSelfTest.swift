#if DEBUG
import Foundation

/// live-20 (2) — `-DocumentReextractSelfTest`: the weekly re-extraction never wipes a document (found in live-19). A
/// document's screen re-extracts it when the last attempt is over a week old; a pass that FAILED (the file unreadable
/// for the moment, a timeout) used to write nil over the title, the text, the thumbnail and the page count — until the
/// next week's pass.
///   • a real extraction through `DocumentExtractionService` + `applyDocumentExtraction` fills the fields;
///   • the file then goes unreadable, its attempt is a week old, and the real service re-extracts it: a failed pass
///     keeps every field and only stamps the attempt time;
///   • a partial pass (no thumbnail, no title, no text — counts only) keeps what it didn't produce;
///   • a good pass still replaces the fields (the refresh still works).
/// Runs in the `-UITestLibrary` scratch; synthetic PDF only.
extension CorpusStore {

    func runDocumentReextractSelfTest() async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok || detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let pdfURL = tmp.appendingPathComponent("harbour-survey.pdf")
        try? Self.syntheticTextPDF(pages: ["Harbour survey. The breakwater held through four storms.",
                                           "Tide heights at the harbour mouth, logged every evening.",
                                           "The beacon lens was replaced in spring."]).write(to: pdfURL)

        let nodeID = "dre-" + UUID().uuidString.prefix(8)
        var n = Node(id: nodeID, createdAt: Date(), updatedAt: Date(), title: "", summary: "", tags: [])
        n.entrySchemaVersion = 4
        await addNode(n, position: .zero)
        guard let entry = await addDocumentEntry(nodeID: nodeID, sourceURLs: [pdfURL]),
              let docID = entry.documentItems?.first?.id else {
            await deleteNode(id: nodeID)
            return "[DocumentReextractSelfTest] FAIL — the document entry wasn't made"
        }
        func doc() -> DocumentItem? {
            nodes.first { $0.id == nodeID }?.items.first { $0.id == entry.id }?.documentItems?.first { $0.id == docID }
        }
        typealias Snapshot = (title: String?, text: String?, thumb: String?, pages: Int?, words: Int?)
        func snap() -> Snapshot { let d = doc(); return (d?.documentTitle, d?.extractedText, d?.thumbnailFile, d?.pageCount, d?.wordCount) }
        func same(_ a: Snapshot, _ b: Snapshot) -> Bool {
            a.title == b.title && a.text == b.text && a.thumb == b.thumb && a.pages == b.pages && a.words == b.words
        }
        func describe(_ s: Snapshot) -> String { "title=\(s.title ?? "nil") text=\(s.text?.count ?? -1) thumb=\(s.thumb ?? "nil") pages=\(s.pages ?? -1) words=\(s.words ?? -1)" }
        /// The document screen's own path (`DocumentEntryBody.extractIfNeeded`): the file the store holds, the real service.
        func reextract() async {
            guard let d = doc(), let url = await documentFileURL(for: d, nodeID: nodeID) else { return }
            let x = await DocumentExtractionService().extract(fileURL: url, fileType: d.fileType.lowercased())
            await applyDocumentExtraction(nodeID: nodeID, entryID: entry.id, documentItemID: docID, extraction: x)
        }
        func ageAttempt() async {
            await mutateNode(id: nodeID) { n in
                guard let i = n.items.firstIndex(where: { $0.id == entry.id }),
                      let j = n.items[i].documentItems?.firstIndex(where: { $0.id == docID }) else { return }
                n.items[i].documentItems?[j].extractionAttemptedAt = Date().addingTimeInterval(-8 * 24 * 3600)
            }
        }

        // 1. A real extraction fills the fields.
        await reextract()
        let good = snap()
        row("first-extraction-fills", (good.text?.contains("breakwater") ?? false) && good.thumb != nil && good.pages == 3, describe(good))

        // 2. The file goes unreadable; a week later the screen re-extracts it through the real service.
        await ageAttempt()
        if let d = doc(), let url = await documentFileURL(for: d, nodeID: nodeID) {
            try? Data("not a pdf any more".utf8).write(to: url)
        }
        let before = Date()
        await reextract()
        let afterFail = snap()
        row("failed-reextraction-keeps-every-field", same(afterFail, good), "before \(describe(good)) · after \(describe(afterFail))")
        row("failed-reextraction-stamps-the-attempt", (doc()?.extractionAttemptedAt ?? .distantPast) >= before)

        // 3. A partial pass (counts only: no title, text or thumbnail) keeps what it didn't produce.
        await applyDocumentExtraction(nodeID: nodeID, entryID: entry.id, documentItemID: docID,
                                      extraction: DocumentExtraction(documentTitle: nil, extractedText: nil, pageCount: 3, wordCount: 21,
                                                                     thumbnailTempURL: nil, thumbnailExtension: nil))
        let afterPartial = snap()
        row("partial-reextraction-keeps-the-rest", afterPartial.text == good.text && afterPartial.thumb == good.thumb
            && afterPartial.title == good.title && afterPartial.words == 21, describe(afterPartial))

        // 4. A good pass still replaces them.
        await applyDocumentExtraction(nodeID: nodeID, entryID: entry.id, documentItemID: docID,
                                      extraction: DocumentExtraction(documentTitle: "Revised Survey", extractedText: "The revised harbour survey.",
                                                                     pageCount: 4, wordCount: 4, thumbnailTempURL: nil, thumbnailExtension: nil))
        let afterGood = snap()
        row("good-reextraction-replaces", afterGood.title == "Revised Survey" && afterGood.text == "The revised harbour survey." && afterGood.pages == 4,
            describe(afterGood))

        await deleteNode(id: nodeID)
        try? FileManager.default.removeItem(at: tmp)
        return "[DocumentReextractSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
