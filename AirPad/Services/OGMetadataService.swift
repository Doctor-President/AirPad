import Foundation
import LinkPresentation
import UniformTypeIdentifiers

// AT19.3c — Open Graph metadata fetch for link entries. Hybrid strategy:
// `LPMetadataProvider` supplies title + image (Apple-blessed path, source
// format preserved); a focused HTML scrape supplies description + site name
// because `LPLinkMetadata`'s public API does not expose those fields. The
// two fetches run independently — partial success is still meaningfully
// better than bare URL, so a scrape miss does not invalidate a successful
// LP fetch and vice versa. Returns nil only when no meaningful field
// landed; that nil is the trigger for State D (bare URL fallback).
//
// Actor isolation matches `iCloudDriveService`'s pattern and gives us a
// single coherent concurrency domain so we never cross task-group
// boundaries with non-Sendable `LPLinkMetadata`/`LPMetadataProvider`.

struct OGMetadata: Equatable, Sendable {
    var title: String?
    var description: String?
    var siteName: String?
    /// Temp file URL holding the downloaded image in its source format.
    /// Caller moves it into the corpus via `iCloudDriveService.saveItemFile`.
    var imageTempURL: URL?
    /// File extension matching `imageTempURL`'s format, e.g. "jpg", "png".
    var imageExtension: String?
}

actor OGMetadataService {

    /// Lazy-fallback threshold from the AT19.3c brief. Re-fetch on view when
    /// the stored `ogFetchedAt` is older than this.
    static let staleness: TimeInterval = 7 * 24 * 60 * 60

    private let lpSoftTimeout: TimeInterval = 5
    private let lpHardTimeout: TimeInterval = 10
    private let scrapeTimeout: TimeInterval = 5
    private let userAgent = "Mozilla/5.0 (compatible; AirPad/1.0)"

    init() {}

    func fetch(url: URL) async -> OGMetadata? {
        async let lp = fetchLP(url: url)
        async let scrape = scrapeOG(url: url)
        let lpResult = await lp
        let scrapeResult = await scrape

        let title = lpResult?.title
        let description = scrapeResult?.description
        let scrapeSite = scrapeResult?.siteName
        let siteName = scrapeSite ?? url.host
        let imageTempURL = lpResult?.imageTempURL
        let imageExtension = lpResult?.imageExtension

        // Bare URL fallback only when no meaningful field landed. `url.host`
        // alone (without LP or scrape success) does NOT count — otherwise
        // every link with no OG data would still render as State C with
        // just a host string, defeating the lazy-fallback retry signal.
        let hasMeaningful = title != nil
            || description != nil
            || imageTempURL != nil
            || scrapeSite != nil
        guard hasMeaningful else { return nil }

        return OGMetadata(
            title: title,
            description: description,
            siteName: siteName,
            imageTempURL: imageTempURL,
            imageExtension: imageExtension
        )
    }

    // MARK: - LP fetch (title + image)

    private struct LPResult: Sendable {
        var title: String?
        var imageTempURL: URL?
        var imageExtension: String?
    }

    private func fetchLP(url: URL) async -> LPResult? {
        // Keep `LPMetadataProvider` and `LPLinkMetadata` inside the timeout
        // closure so neither (non-Sendable) type crosses the task-group
        // boundary; only the Sendable `LPResult` does.
        let softTimeout = lpSoftTimeout
        do {
            return try await withTimeout(seconds: lpHardTimeout) {
                let provider = LPMetadataProvider()
                provider.timeout = softTimeout
                let metadata = try await provider.startFetchingMetadata(for: url)
                let title = metadata.title?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                var imageTempURL: URL?
                var imageExt: String?
                if let imageProvider = metadata.imageProvider {
                    (imageTempURL, imageExt) = await Self.loadImage(from: imageProvider)
                }
                if title == nil && imageTempURL == nil { return nil }
                return LPResult(title: title, imageTempURL: imageTempURL, imageExtension: imageExt)
            }
        } catch {
            return nil
        }
    }

    private static func loadImage(from provider: NSItemProvider) async -> (URL?, String?) {
        // Preserve the original format (consultation #2). Probe registered
        // type identifiers in priority order, load raw bytes, write to a
        // temp file. UIImage round-trip would force a JPEG/PNG re-encode
        // and lose quality on the small thumbnail-sized OG images.
        let candidates: [(typeID: String, ext: String)] = [
            (UTType.jpeg.identifier, "jpg"),
            (UTType.png.identifier, "png"),
            (UTType.webP.identifier, "webp"),
            (UTType.heic.identifier, "heic")
        ]
        guard let chosen = candidates.first(where: { provider.hasItemConformingToTypeIdentifier($0.typeID) }) else {
            return (nil, nil)
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<(URL?, String?), Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: chosen.typeID) { data, _ in
                guard let data, !data.isEmpty else {
                    cont.resume(returning: (nil, nil))
                    return
                }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("og-\(UUID().uuidString).\(chosen.ext)")
                do {
                    try data.write(to: tmp, options: .atomic)
                    cont.resume(returning: (tmp, chosen.ext))
                } catch {
                    cont.resume(returning: (nil, nil))
                }
            }
        }
    }

    // MARK: - HTML scrape (description + site name)

    private struct ScrapeResult: Sendable {
        var description: String?
        var siteName: String?
    }

    private func scrapeOG(url: URL) async -> ScrapeResult? {
        var request = URLRequest(url: url, timeoutInterval: scrapeTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let html = Self.decodeHTML(data: data)
        else { return nil }

        let description = Self.ogTagValue(in: html, property: "og:description")
            ?? Self.metaName(in: html, name: "description")
        let siteName = Self.ogTagValue(in: html, property: "og:site_name")

        if description == nil && siteName == nil { return nil }
        return ScrapeResult(description: description, siteName: siteName)
    }

    private static func decodeHTML(data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return nil
    }

    private static func ogTagValue(in html: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        // Both attribute orderings: property=…content=… and content=…property=….
        let patterns = [
            #"<meta\s+[^>]*property=["']\#(escaped)["'][^>]*content=["']([^"']*)["']"#,
            #"<meta\s+[^>]*content=["']([^"']*)["'][^>]*property=["']\#(escaped)["']"#
        ]
        for pattern in patterns {
            if let match = firstCaptureGroup(html, pattern: pattern) {
                return decodeHTMLEntities(match.trimmingCharacters(in: .whitespacesAndNewlines)).nilIfEmpty
            }
        }
        return nil
    }

    private static func metaName(in html: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            #"<meta\s+[^>]*name=["']\#(escaped)["'][^>]*content=["']([^"']*)["']"#,
            #"<meta\s+[^>]*content=["']([^"']*)["'][^>]*name=["']\#(escaped)["']"#
        ]
        for pattern in patterns {
            if let match = firstCaptureGroup(html, pattern: pattern) {
                return decodeHTMLEntities(match.trimmingCharacters(in: .whitespacesAndNewlines)).nilIfEmpty
            }
        }
        return nil
    }

    private static func firstCaptureGroup(_ source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard
            let match = regex.firstMatch(in: source, options: [], range: range),
            match.numberOfRanges >= 2,
            let captureRange = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[captureRange])
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        var result = s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
        // Numeric escapes &#NN; — process in reverse so range replacements stay valid.
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = regex.matches(in: result, options: [], range: range).reversed()
            for m in matches {
                guard
                    let full = Range(m.range, in: result),
                    let digits = Range(m.range(at: 1), in: result),
                    let code = UInt32(result[digits]),
                    let scalar = Unicode.Scalar(code)
                else { continue }
                result.replaceSubrange(full, with: String(Character(scalar)))
            }
        }
        return result
    }
}

// MARK: - Timeout helper

private enum OGFetchError: Error { case timeout }

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
            throw OGFetchError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw OGFetchError.timeout
        }
        return first
    }
}

// MARK: - String helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
