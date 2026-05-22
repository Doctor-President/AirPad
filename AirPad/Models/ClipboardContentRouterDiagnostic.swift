import Foundation
import UIKit
import UniformTypeIdentifiers

/// Stage 4.7 — `ClipboardContentRouter` self-test. Permanent diagnostic
/// infrastructure (not throwaway scaffolding): pins the classification
/// contract the Paste Pad and its eventual second consumer
/// (QuikCapture v2) read against. Mirrors `EntryDeletionDiagnostic`'s
/// shape — in-process assertions, no XCTest target, returns a
/// one-line-or-multi-line summary `SubstrateInspectView` surfaces
/// (green on pass, red on FAIL).
///
/// Uses `UIPasteboard.withUniqueName()` for each test so the user's
/// system clipboard is never touched and the iOS 14+ "pasted from"
/// banner is not provoked during a diagnostic run (the banner attaches
/// to `.general`, not named pasteboards). Each test removes its
/// pasteboard at the end via `UIPasteboard.remove(withName:)`.
///
/// Coverage:
///   T1 — empty pasteboard → `.empty`
///   T2 — direct URL (`pasteboard.url`) → `.url`
///   T3 — plain-text https URL string → `.url` (URL precedence over
///        text per brief)
///   T4 — plain text containing a URL embedded in prose (whitespace
///        present) → `.text` (rejection of multi-token strings as URL)
///   T5 — `mailto:` text → `.text` (non-http/https schemes don't
///        promote to `.url`; only web links do)
///   T6 — image via `pasteboard.image` → `.image`
///   T7 — bare plain text → `.text`
///   T8 — URL + text co-present on same item → `.url` (precedence)
///   T9 — multi-item, all URLs (3 items) → `.multi([.url, .url, .url])`
///        in clipboard order
///   T10 — multi-item, mixed types (URL + text + image) → `.multi(...)`
///        in clipboard order with each per-type classification preserved
///   T11 — multi-item with one empty item → single-survivor collapses
///        back to `.url` (the router strips empty items before deciding
///        single-vs-multi)
///   T12 — PDF data under the concrete `com.adobe.pdf` UTI → `.file`
///        with extension `"pdf"`. Pins the Files.app-copy shape: the
///        bytes arrive under the file's content UTI (not under
///        `public.file-url`), and the router materializes them to a
///        temp file the handler can copy out of. Locked in when the
///        C3 follow-up fix added the typed-data path 4 after the
///        original `public.file-url`-only path 4 returned `.empty`
///        on real-world Files.app paste.
///   T13 — MP4 data under the concrete `public.mpeg-4` UTI → `.video`
///        with the temp URL ending in `.mp4`. Same Files.app-copy
///        shape as T12 but exercising the video branch (path 3),
///        which similarly walks the declared types for the concrete
///        `.movie`-conforming identifier rather than querying the
///        abstract `public.movie` (which returns nil on the typed-
///        data store).
@available(iOS 17.0, *)
@MainActor
enum ClipboardContentRouterDiagnostic {

    static func run() async -> String {
        var failures: [String] = []
        var ran = 0
        var cleanup: [UIPasteboard.Name] = []

        // T1 — empty pasteboard.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            let result = ClipboardContentRouter.classify(pb)
            if case .empty = result {} else {
                failures.append("T1: expected .empty, got \(label(result))")
            }
        }

        // T2 — direct URL via the convenience accessor.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.url = URL(string: "https://example.com")!
            let result = ClipboardContentRouter.classify(pb)
            if case .url(let url) = result {
                if url.absoluteString != "https://example.com" {
                    failures.append("T2: URL mismatch \(url.absoluteString)")
                }
            } else {
                failures.append("T2: expected .url, got \(label(result))")
            }
        }

        // T3 — bare https string in `pasteboard.string` (no `.url` set).
        //      The router's URL-in-text coercion fires; result is `.url`,
        //      not `.text`. Pins the "Paste link here" precedence rule.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.string = "https://example.com/path?q=1"
            let result = ClipboardContentRouter.classify(pb)
            if case .url(let url) = result {
                if url.absoluteString != "https://example.com/path?q=1" {
                    failures.append("T3: URL mismatch \(url.absoluteString)")
                }
            } else {
                failures.append("T3: expected .url from text, got \(label(result))")
            }
        }

        // T4 — prose containing a URL stays `.text`. The router rejects
        //      strings with internal whitespace from URL coercion — a
        //      multi-token string is content, not a link.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.string = "check this out https://example.com it's great"
            let result = ClipboardContentRouter.classify(pb)
            if case .text(let s) = result {
                if !s.contains("https://example.com") {
                    failures.append("T4: text payload missing URL: \(s)")
                }
            } else {
                failures.append("T4: expected .text, got \(label(result))")
            }
        }

        // T5 — `mailto:` scheme stays `.text`. Only http/https promote
        //      to `.url`; other URI schemes (tel:, sms:, custom app
        //      schemes) are content, not web links.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.string = "mailto:t@example.com"
            let result = ClipboardContentRouter.classify(pb)
            if case .text = result {} else {
                failures.append("T5: expected .text for mailto:, got \(label(result))")
            }
        }

        // T6 — UIImage via the convenience accessor. iOS stores it under
        //      a `public.image`-conforming type identifier; router path
        //      2 fires.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.image = makeTestImage()
            let result = ClipboardContentRouter.classify(pb)
            if case .image = result {} else {
                failures.append("T6: expected .image, got \(label(result))")
            }
        }

        // T7 — bare plain text.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.string = "hello world"
            let result = ClipboardContentRouter.classify(pb)
            if case .text(let s) = result {
                if s != "hello world" {
                    failures.append("T7: text mismatch \(s)")
                }
            } else {
                failures.append("T7: expected .text, got \(label(result))")
            }
        }

        // T8 — URL + text both set on the same item. URL wins. (Common
        //      shape: Safari copy puts the URL string under both
        //      `public.url` and `public.utf8-plain-text`.)
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.items = [[
                UTType.url.identifier: URL(string: "https://example.com")!,
                UTType.utf8PlainText.identifier: "https://example.com"
            ]]
            let result = ClipboardContentRouter.classify(pb)
            if case .url = result {} else {
                failures.append("T8: expected .url (precedence over text), got \(label(result))")
            }
        }

        // T9 — multi-item, all URLs.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.items = [
                [UTType.url.identifier: URL(string: "https://a.example.com")!],
                [UTType.url.identifier: URL(string: "https://b.example.com")!],
                [UTType.url.identifier: URL(string: "https://c.example.com")!]
            ]
            let result = ClipboardContentRouter.classify(pb)
            if case .multi(let items) = result {
                if items.count != 3 {
                    failures.append("T9: expected 3 items, got \(items.count)")
                }
                for (i, item) in items.enumerated() {
                    if case .url = item {} else {
                        failures.append("T9: item \(i) expected .url, got \(label(item))")
                    }
                }
            } else {
                failures.append("T9: expected .multi, got \(label(result))")
            }
        }

        // T10 — multi-item, mixed (URL + text + image) in clipboard order.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            let img = makeTestImage()
            let imgData = img.pngData() ?? Data()
            pb.items = [
                [UTType.url.identifier: URL(string: "https://example.com")!],
                [UTType.utf8PlainText.identifier: "some note"],
                [UTType.png.identifier: imgData]
            ]
            let result = ClipboardContentRouter.classify(pb)
            if case .multi(let items) = result {
                if items.count != 3 {
                    failures.append("T10: expected 3 items, got \(items.count)")
                } else {
                    if case .url = items[0] {} else {
                        failures.append("T10: item 0 expected .url, got \(label(items[0]))")
                    }
                    if case .text = items[1] {} else {
                        failures.append("T10: item 1 expected .text, got \(label(items[1]))")
                    }
                    if case .image = items[2] {} else {
                        failures.append("T10: item 2 expected .image, got \(label(items[2]))")
                    }
                }
            } else {
                failures.append("T10: expected .multi, got \(label(result))")
            }
        }

        // T11 — multi-item with one empty item collapses to the single
        //       surviving classification (.multi never has count 1).
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            pb.items = [
                [:],
                [UTType.url.identifier: URL(string: "https://example.com")!]
            ]
            let result = ClipboardContentRouter.classify(pb)
            if case .url = result {} else {
                failures.append("T11: expected .url (collapsed survivor), got \(label(result))")
            }
        }

        // T12 — PDF data under the concrete content UTI. Mirrors the
        //       Files.app-copy shape: bytes registered under
        //       `com.adobe.pdf`, not under `public.file-url`. The
        //       router walks declared types, picks the first
        //       `.data`-conforming non-text non-image non-movie non-url
        //       identifier, materializes its bytes to a temp file, and
        //       returns `.file(tempURL, fileType: "pdf")`.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            let pdfData = makeTinyPDFData()
            pb.items = [[UTType.pdf.identifier: pdfData]]
            let result = ClipboardContentRouter.classify(pb)
            if case .file(let url, let fileType) = result {
                if fileType != "pdf" {
                    failures.append("T12: expected fileType 'pdf', got '\(fileType)'")
                }
                if url.pathExtension.lowercased() != "pdf" {
                    failures.append("T12: temp URL extension expected 'pdf', got '\(url.pathExtension)'")
                }
                if !FileManager.default.fileExists(atPath: url.path) {
                    failures.append("T12: temp file does not exist at \(url.path)")
                }
                // Clean up the router's temp file so we don't leak in
                // diagnostic runs. Production relies on iOS's tmp-dir
                // reaper; the diagnostic clears its own bytes.
                try? FileManager.default.removeItem(at: url)
            } else {
                failures.append("T12: expected .file, got \(label(result))")
            }
        }

        // T13 — MP4 data under the concrete `public.mpeg-4` UTI.
        //       Mirrors the Files.app-copy shape for video: bytes
        //       under the concrete `.movie`-conforming identifier,
        //       not under the abstract `public.movie`. Router walks
        //       declared types, picks the `.movie`-conforming
        //       identifier, materializes bytes to a temp file under
        //       its preferred extension, returns `.video(tempURL)`.
        do {
            ran += 1
            let pb = UIPasteboard.withUniqueName()
            cleanup.append(pb.name)
            // Tiny placeholder bytes — the router doesn't validate the
            // payload, only that `firstData(...)` returns non-nil under
            // a `.movie`-conforming UTI. Real MP4 byte validity is the
            // downstream AVFoundation pipeline's concern.
            let videoData = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
            pb.items = [[UTType.mpeg4Movie.identifier: videoData]]
            let result = ClipboardContentRouter.classify(pb)
            if case .video(let url) = result {
                if url.pathExtension.lowercased() != "mp4" {
                    failures.append("T13: temp URL extension expected 'mp4', got '\(url.pathExtension)'")
                }
                if !FileManager.default.fileExists(atPath: url.path) {
                    failures.append("T13: temp file does not exist at \(url.path)")
                }
                try? FileManager.default.removeItem(at: url)
            } else {
                failures.append("T13: expected .video, got \(label(result))")
            }
        }

        // Cleanup: drop every uniquely-named pasteboard we created. Any
        // leftover named pasteboard from a crashed mid-run is invisible
        // to `.general` and is reaped by iOS on process exit anyway.
        for name in cleanup {
            UIPasteboard.remove(withName: name)
        }

        if failures.isEmpty {
            return "ClipboardContentRouter: \(ran)/\(ran) passed"
        } else {
            return "ClipboardContentRouter FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Helpers

    private static func makeTestImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// Tiny placeholder bytes used by T12. Not a valid PDF — the
    /// router doesn't validate the payload, it only checks that the
    /// pasteboard returns non-nil `Data` for a `.data`-conforming
    /// non-text UTI. Header bytes mimic the PDF magic so anything
    /// downstream that DOES sniff content (extraction services) will
    /// see "looks like a PDF" without us shipping a full corpus
    /// fixture for the diagnostic.
    private static func makeTinyPDFData() -> Data {
        Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]) // "%PDF-1.4"
    }

    private static func label(_ content: ClipboardContent) -> String {
        switch content {
        case .url: return ".url"
        case .image: return ".image"
        case .video: return ".video"
        case .file: return ".file"
        case .text: return ".text"
        case .multi(let items): return ".multi(\(items.count))"
        case .empty: return ".empty"
        }
    }
}
