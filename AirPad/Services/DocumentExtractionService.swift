import Foundation
import PDFKit
import UIKit
import WebKit

// Stage 4.6 — extracts visible text + optional metadata from a captured
// document file. The substrate's embedding pipeline reads
// `DocumentItem.extractedText` the same way it reads
// `LinkItem.snapshotText` for snapshotted links — both are the
// "extracted text on every collectible" seam from the Stage 4.6 brief.
//
// Dispatcher by file extension. v1 supports PDF (PDFKit), HTML
// (WKWebView), TXT/MD (String load), RTF (NSAttributedString).
// Unsupported extensions return nil — the entry still renders via Quick
// Look at the C4 surface but contributes no signal to the substrate.
//
// Actor isolation matches `OGMetadataService`: single coherent
// concurrency domain so non-Sendable types (PDFDocument, WKWebView,
// NSAttributedString) never cross task-group boundaries; only the
// Sendable `DocumentExtraction` result does.

/// Sendable result of a document extraction pass. Thumbnail lives at a
/// temp file URL in `FileManager.default.temporaryDirectory`; the caller
/// (`CorpusStore.applyDocumentExtraction`) moves it into the corpus via
/// `iCloudDriveService.saveItemFile` and removes the temp.
struct DocumentExtraction: Sendable {
    var documentTitle: String?
    var extractedText: String?
    var pageCount: Int?
    var wordCount: Int?
    /// Temp file URL holding the thumbnail in its source format
    /// (currently always JPEG). Nil for formats that don't render a
    /// thumbnail (TXT/MD/RTF — the renderer falls back to a generic
    /// icon-with-extension overlay).
    var thumbnailTempURL: URL?
    /// File extension matching `thumbnailTempURL`'s format, e.g. "jpg".
    var thumbnailExtension: String?
}

actor DocumentExtractionService {

    /// Lazy-fallback threshold matching `OGMetadataService.staleness`.
    /// `DocumentEntryBody.extractIfNeeded` re-fires extraction when the
    /// stored `DocumentItem.extractionAttemptedAt` is older than this —
    /// transient failures (iCloud lazy materialization, momentary
    /// timeout) self-heal on the next view after the window elapses;
    /// persistently broken files don't loop forever within the window.
    static let staleness: TimeInterval = 7 * 24 * 60 * 60

    /// Allow-list of file extensions this service has extractors for.
    /// Callers that gate at their own boundary (the migration-driven
    /// kickoff in `CorpusStore.ensureEntrySchema`, the renderer-side
    /// `.task` in `DocumentEntryBody`) consult this to avoid firing
    /// `extract()` for formats that would no-op. `extract()` itself
    /// also returns nil for unknown extensions, so the gate is an
    /// optimization, not a safety check.
    static let supportedExtensions: Set<String> = [
        "pdf", "html", "htm", "txt", "md", "markdown", "rtf"
    ]

    /// Per-format hard timeout. PDF and HTML are the realistic risk
    /// surface — large PDFs (1000+ pages) and JS-heavy HTML can hang.
    /// TXT/MD/RTF are bounded by file size and don't need an aggressive
    /// timeout, but get one for consistency.
    private let hardTimeout: TimeInterval = 10
    /// HTML soft delay after `didFinish` to let late JS content render.
    /// Matches the 500ms suggested by the Phase 1 audit's WKWebView
    /// reliability section. Distinct from the hard timeout.
    private let htmlPostFinishDelay: TimeInterval = 0.5

    init() {}

    func extract(fileURL: URL, fileType: String) async -> DocumentExtraction? {
        let normalized = fileType.lowercased()
        do {
            return try await withTimeout(seconds: hardTimeout) { [htmlPostFinishDelay] in
                switch normalized {
                case "pdf":
                    return await Self.extractPDF(fileURL: fileURL)
                case "html", "htm":
                    return await HTMLExtractor.extract(
                        fileURL: fileURL,
                        postFinishDelay: htmlPostFinishDelay
                    )
                case "txt", "md", "markdown":
                    return Self.extractPlainText(fileURL: fileURL)
                case "rtf":
                    return Self.extractRTF(fileURL: fileURL)
                default:
                    return nil
                }
            }
        } catch {
            return nil
        }
    }

    // MARK: - PDF

    @MainActor
    private static func extractPDF(fileURL: URL) async -> DocumentExtraction? {
        guard let pdf = PDFDocument(url: fileURL) else { return nil }

        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var combined = ""
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            if let s = page.string, !s.isEmpty {
                if !combined.isEmpty { combined.append("\n\n") }
                combined.append(s)
            }
        }
        let extractedText = combined.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let wordCount = extractedText.map { countWords($0) }

        // Page-1 thumbnail. PDFKit's `thumbnail(of:for:)` handles the
        // CGContext flip + white background internally; output is a
        // standard UIImage we JPEG-encode for the sidecar.
        var thumbTemp: URL?
        if let page = pdf.page(at: 0) {
            let pageRect = page.bounds(for: .mediaBox)
            let targetWidth: CGFloat = 600
            let scale = targetWidth / max(pageRect.width, 1)
            let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
            let image = page.thumbnail(of: size, for: .mediaBox)
            if let jpeg = image.jpegData(compressionQuality: 0.7) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("doc-thumb-\(UUID().uuidString).jpg")
                if (try? jpeg.write(to: tmp, options: .atomic)) != nil {
                    thumbTemp = tmp
                }
            }
        }

        return DocumentExtraction(
            documentTitle: title,
            extractedText: extractedText,
            pageCount: pdf.pageCount > 0 ? pdf.pageCount : nil,
            wordCount: wordCount,
            thumbnailTempURL: thumbTemp,
            thumbnailExtension: thumbTemp != nil ? "jpg" : nil
        )
    }

    // MARK: - Plain text (TXT / MD)

    private static func extractPlainText(fileURL: URL) -> DocumentExtraction? {
        let raw: String
        if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) {
            raw = utf8
        } else if let latin1 = try? String(contentsOf: fileURL, encoding: .isoLatin1) {
            raw = latin1
        } else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return DocumentExtraction(
            documentTitle: nil,
            extractedText: trimmed,
            pageCount: nil,
            wordCount: trimmed.map { countWords($0) },
            thumbnailTempURL: nil,
            thumbnailExtension: nil
        )
    }

    // MARK: - RTF

    private static func extractRTF(fileURL: URL) -> DocumentExtraction? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        guard let attr = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else { return nil }
        let text = attr.string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return DocumentExtraction(
            documentTitle: nil,
            extractedText: text,
            pageCount: nil,
            wordCount: text.map { countWords($0) },
            thumbnailTempURL: nil,
            thumbnailExtension: nil
        )
    }

    // MARK: - Word count

    private static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

// MARK: - HTML extractor (@MainActor — WKWebView is main-thread only)

@MainActor
private enum HTMLExtractor {

    /// Loads `fileURL` into an off-screen `WKWebView`, waits for
    /// navigation completion plus a short post-finish delay so late JS
    /// content renders, then evaluates JS to pull `document.title` and
    /// `document.body.innerText`. Takes a viewport snapshot for the
    /// thumbnail; snapshot failure does NOT invalidate text extraction.
    static func extract(fileURL: URL, postFinishDelay: TimeInterval) async -> DocumentExtraction? {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        let frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let webView = WKWebView(frame: frame, configuration: config)

        // Hold a strong reference to the delegate for the duration of
        // the load — WKWebView's `navigationDelegate` property is weak.
        let coordinator = NavigationCoordinator()
        webView.navigationDelegate = coordinator

        // `allowingReadAccessTo` is the file URL's parent dir so the
        // page can resolve sibling assets (CSS, images). Pure HTML
        // files without dependencies work either way.
        let readAccess = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccess)

        await coordinator.awaitFinish()
        try? await Task.sleep(nanoseconds: UInt64(postFinishDelay * 1_000_000_000))

        // Explicit do-catch around `evaluateJavaScript` — `try?` on an
        // async throwing function returning `Any?` produces `Any??`,
        // which doesn't cast cleanly inline. Unwrapping in two steps
        // keeps the types straight.
        let titleAny: Any?
        do { titleAny = try await webView.evaluateJavaScript("document.title") }
        catch { titleAny = nil }
        let title = (titleAny as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let bodyAny: Any?
        do { bodyAny = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''") }
        catch { bodyAny = nil }
        let bodyText = (bodyAny as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let wordCount = bodyText.map { $0.split(whereSeparator: { $0.isWhitespace }).count }

        var thumbTemp: URL?
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.afterScreenUpdates = true
        if let image = try? await webView.takeSnapshot(configuration: snapshotConfig),
           let jpeg = image.jpegData(compressionQuality: 0.7) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("doc-thumb-\(UUID().uuidString).jpg")
            if (try? jpeg.write(to: tmp, options: .atomic)) != nil {
                thumbTemp = tmp
            }
        }

        return DocumentExtraction(
            documentTitle: title,
            extractedText: bodyText,
            pageCount: nil,
            wordCount: wordCount,
            thumbnailTempURL: thumbTemp,
            thumbnailExtension: thumbTemp != nil ? "jpg" : nil
        )
    }
}

/// Bridges `WKNavigationDelegate`'s callback-based finish signal into a
/// single `awaitFinish()` async call. Resumes on the first of
/// `didFinish`, `didFail`, or `didFailProvisionalNavigation` so a load
/// failure unblocks the extractor instead of hanging until the outer
/// hard timeout trips.
@MainActor
private final class NavigationCoordinator: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didResume = false

    func awaitFinish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    private func resumeOnce() {
        guard !didResume else { return }
        didResume = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeOnce()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeOnce()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resumeOnce()
    }
}

// MARK: - Timeout helper (duplicated from OGMetadataService — both files
// own their own copy so neither depends on the other's internals)

private enum DocumentExtractionError: Error { case timeout }

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await work()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DocumentExtractionError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw DocumentExtractionError.timeout
        }
        return first
    }
}

// MARK: - String helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
