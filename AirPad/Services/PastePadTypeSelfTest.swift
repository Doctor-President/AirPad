#if DEBUG
import Foundation
import UIKit
import UniformTypeIdentifiers

/// live-13 (3) — `-PastePadTypeSelfTest`: Paste Pad sorts a paste by what it IS. A copied selection (plain or rich text
/// present, no file) becomes TEXT — never a document; only real files become documents; a bare URL becomes a link.
/// Synthetic pasteboards (`UIPasteboard.withUniqueName()`, never the system clipboard) mirror the type sets real
/// sources publish: Safari's selection (plain + RTF/RTFD + HTML + web archive), Notes, a Files PDF, an image, a URL.
/// Both the tap-time `classify` and the prompt-free `detectKind` (the label) must agree. Synthetic text only.
@MainActor
enum PastePadTypeSelfTest {

    static let article = "The harbour town grew around a small fishing port. By the eighteenth century it had a customs house, two churches and a market square."

    static func run() async -> String {
        var rows: [String] = [], fails = 0
        var names: [UIPasteboard.Name] = []
        defer { names.forEach { UIPasteboard.remove(withName: $0) } }

        func pasteboard(_ item: [String: Any]) -> UIPasteboard {
            let pb = UIPasteboard.withUniqueName(); names.append(pb.name)
            pb.items = [item]
            return pb
        }
        func kind(_ c: ClipboardContent) -> String {
            switch c {
            case .url: return "url"; case .image: return "image"; case .video: return "video"
            case .file(_, let ext): return "file(\(ext))"; case .text: return "text"
            case .multi: return "multi"; case .empty: return "empty"
            }
        }
        func row(_ name: String, _ item: [String: Any], expect: String, detect: ClipboardKind, text: String? = nil) {
            let pb = pasteboard(item)
            let got = ClipboardContentRouter.classify(pb), detected = ClipboardContentRouter.detectKind(pb)
            var ok = kind(got) == expect && detected == detect
            if let text, case .text(let s) = got { ok = ok && s == text }
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok ? "" : " — classify=\(kind(got)) detect=\(detected) want=\(expect)/\(detect)"))
            if !ok { fails += 1 }
        }

        let rtf = try? NSAttributedString(string: article).data(from: NSRange(location: 0, length: article.count),
                                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtfd = try? NSAttributedString(string: article).data(from: NSRange(location: 0, length: article.count),
                                                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let html = "<p>\(article)</p>"
        let webArchive = Data("synthetic-web-archive".utf8)
        let pdf = Data("%PDF-1.4\n% synthetic\n".utf8)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor(red: 0x1B / 255, green: 0x59 / 255, blue: 0xC2 / 255, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }

        // Safari: a selection on a web page (Wikipedia-style article text).
        row("safari-selection-plain-rtf-html-webarchive-is-text", [
            UTType.utf8PlainText.identifier: article, UTType.rtf.identifier: rtf ?? Data(),
            UTType.html.identifier: html, UTType.webArchive.identifier: webArchive,
        ], expect: "text", detect: .text, text: article)
        row("safari-selection-with-rtfd-is-text", [
            UTType.utf8PlainText.identifier: article, UTType.flatRTFD.identifier: rtfd ?? Data(),
            UTType.html.identifier: html, UTType.webArchive.identifier: webArchive,
        ], expect: "text", detect: .text, text: article)
        // Notes: a selection, with Notes' own private rich-text type.
        row("notes-selection-is-text", [
            UTType.utf8PlainText.identifier: article, UTType.html.identifier: html,
            UTType.flatRTFD.identifier: rtfd ?? Data(), "com.apple.notes.richtext": Data("synthetic".utf8),
        ], expect: "text", detect: .text, text: article)
        // Rich text with no plain-text form: the words come from the RTF.
        row("rich-only-selection-is-text", [
            UTType.rtf.identifier: rtf ?? Data(), UTType.webArchive.identifier: webArchive,
        ], expect: "text", detect: .text, text: article)
        // Real files.
        row("files-pdf-is-document", [UTType.pdf.identifier: pdf], expect: "file(pdf)", detect: .file)
        row("files-pdf-with-a-text-name-is-document", [UTType.pdf.identifier: pdf, UTType.utf8PlainText.identifier: "Report.pdf"],
            expect: "file(pdf)", detect: .file)
        row("files-docx-is-document", ["org.openxmlformats.wordprocessingml.document": Data("PK synthetic".utf8)],
            expect: "file(docx)", detect: .file)
        row("file-url-is-document", [UTType.fileURL.identifier: URL(fileURLWithPath: "/tmp/Synthetic Notes.pdf")],
            expect: "file(pdf)", detect: .file)
        // An image; a bare URL; Safari's Copy Link (URL + its own string).
        row("image-is-image", [UTType.png.identifier: png], expect: "image", detect: .image)
        row("bare-url-is-link", [UTType.url.identifier: URL(string: "https://example.org/harbour")!], expect: "url", detect: .url)
        row("copied-link-url-plus-string-is-link", [
            UTType.url.identifier: URL(string: "https://example.org/harbour")!, UTType.utf8PlainText.identifier: "https://example.org/harbour",
        ], expect: "url", detect: .url)

        // The router's own contract (T1–T13) still holds.
        let contract = await ClipboardContentRouterDiagnostic.run()
        let contractOK = !contract.contains("FAIL")
        rows.append("\(contractOK ? "PASS" : "FAIL") router-contract-T1-T13" + (contractOK ? "" : " — \(contract.prefix(200))"))
        if !contractOK { fails += 1 }

        return "[PastePadTypeSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
