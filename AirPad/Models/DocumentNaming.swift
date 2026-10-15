import Foundation
import PDFKit

/// live-13 (4) — an imported document is named from its REAL name, on every import path (Paste Pad, share sheet, Files
/// picker): the provider's suggested name or the picked file's name, else the PDF's own Title metadata, else
/// "PDF · <date>". Never a temp/UUID file name — T: every PDF he imported showed "this strange long string of
/// characters" (the router's / share sheet's temp file, and the schema migration's on-disk `<UUID>.pdf`).
/// The entry's title still comes from the usual ghost naming; this is the document's own name.
enum DocumentNaming {

    /// A machine-made file name: a UUID (optionally numbered), a long hex run, or a temp-file stem.
    static func looksGenerated(_ name: String) -> Bool {
        let base = ((name as NSString).deletingPathExtension).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return true }
        let patterns = [
            #"^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}([-_ ]?\d+)?$"#,   // UUID, UUID-1
            #"^[0-9A-Fa-f]{16,}$"#,                                                 // long hex
            #"^(tmp|temp|CFNetworkDownload)[-_.]?[A-Za-z0-9]{4,}$"#,                // temp-file stems
        ]
        return patterns.contains { base.range(of: $0, options: .regularExpression) != nil }
    }

    /// The name to store for a file at import: its own name when it's a real one, else "" (the shown name then falls
    /// back to the PDF title or the date — see `shownName`).
    static func storedName(_ fileName: String?) -> String {
        guard let n = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !looksGenerated(n) else { return "" }
        return n
    }

    /// The real name an item provider offers: its `suggestedName` (given the file's extension), else the vended
    /// file URL's name — nil when both are machine-made.
    static func realName(suggested: String?, url: URL?) -> String? {
        let ext = url?.pathExtension ?? ""
        if let s = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !looksGenerated(s) {
            return ext.isEmpty || !(s as NSString).pathExtension.isEmpty ? s : "\(s).\(ext)"
        }
        if let n = url?.lastPathComponent, !looksGenerated(n) { return n }
        return nil
    }

    /// What the app shows: the real name minus its extension, else the PDF's Title, else "PDF · <date>".
    static func shownName(fileName: String, documentTitle: String?, fileType: String, capturedAt: Date) -> String {
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !looksGenerated(base) { return base }
        if let t = documentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let kind = fileType.isEmpty ? "Document" : fileType.uppercased()
        return "\(kind) · " + capturedAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// The PDF's own Title metadata, when it has one.
    static func pdfTitle(data: Data) -> String? {
        guard let t = PDFDocument(data: data)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension DocumentItem {
    /// The document's own name as shown and copied (`DocumentNaming.shownName`).
    var displayName: String {
        DocumentNaming.shownName(fileName: fileName, documentTitle: documentTitle, fileType: fileType, capturedAt: capturedAt)
    }
}
