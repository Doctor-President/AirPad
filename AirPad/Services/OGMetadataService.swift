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
    /// Stage 4.5 commit 4 — temp file URL holding the downloaded favicon
    /// in its source format. Independent of `imageTempURL`; the favicon
    /// renders as a smaller fallback in `LinkGalleryTile` when the OG
    /// image is missing. Sourced via the favicon scraper or the
    /// `/favicon.ico` convention fallback.
    var faviconTempURL: URL?
    /// File extension matching `faviconTempURL`'s format, e.g. "ico", "png".
    var faviconExtension: String?
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

        // Favicon download is sequential after scrape so we can prefer the
        // scraped `<link rel="icon">` URL when present. The `/favicon.ico`
        // convention fallback (last resort) lives inside `fetchFavicon`.
        let (faviconTempURL, faviconExtension) = await fetchFavicon(
            scrapedURL: scrapeResult?.faviconRawURL,
            pageURL: url
        )

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
        // Favicon counts as meaningful — a recognizable mark + host beats a
        // bare URL string, which is the whole reason commit 4 added it.
        let hasMeaningful = title != nil
            || description != nil
            || imageTempURL != nil
            || scrapeSite != nil
            || faviconTempURL != nil
        guard hasMeaningful else { return nil }

        return OGMetadata(
            title: title,
            description: description,
            siteName: siteName,
            imageTempURL: imageTempURL,
            imageExtension: imageExtension,
            faviconTempURL: faviconTempURL,
            faviconExtension: faviconExtension
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

    // MARK: - HTML scrape (description + site name + favicon URL)

    private struct ScrapeResult: Sendable {
        var description: String?
        var siteName: String?
        /// Stage 4.5 commit 4 — `<link rel="icon|shortcut icon|apple-touch-icon">`
        /// resolved to an absolute URL using the page URL as base. Caller
        /// downloads it in a second pass; the `/favicon.ico` convention
        /// fallback runs when this is nil OR the download fails.
        var faviconRawURL: URL?
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
        let faviconRawURL = Self.extractFaviconURL(in: html, base: url)

        if description == nil && siteName == nil && faviconRawURL == nil { return nil }
        return ScrapeResult(
            description: description,
            siteName: siteName,
            faviconRawURL: faviconRawURL
        )
    }

    // MARK: - Favicon fetch

    /// Stage 4.5 commit 4 — two-stage cascade. Prefer the scraped
    /// `<link rel="...">` URL when present (typically apple-touch-icon
    /// at ~180px, far better than 16×16 `/favicon.ico`); fall back to
    /// the `/favicon.ico` convention when scrape returned nothing or
    /// the scraped URL failed to download. Returns `(nil, nil)` only
    /// when both paths failed — most well-known domains will hit at
    /// least the convention fallback.
    private func fetchFavicon(scrapedURL: URL?, pageURL: URL) async -> (URL?, String?) {
        if let scraped = scrapedURL,
           let result = await Self.downloadFavicon(from: scraped, userAgent: userAgent) {
            return result
        }
        if let scheme = pageURL.scheme,
           let host = pageURL.host,
           let fallback = URL(string: "\(scheme)://\(host)/favicon.ico"),
           let result = await Self.downloadFavicon(from: fallback, userAgent: userAgent) {
            return result
        }
        return (nil, nil)
    }

    private static func downloadFavicon(from url: URL, userAgent: String) async -> (URL, String)? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            !data.isEmpty
        else { return nil }
        // Some sites return 200 + HTML for missing favicons. Reject non-2xx
        // when we have a status code; accept anything when the response
        // isn't HTTPURLResponse (file:// etc., which shouldn't happen but
        // shouldn't crash either).
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }

        // Extension priority: URL path extension when it's a known image
        // format; otherwise "ico" because the `/favicon.ico` convention
        // path has no explicit extension to read.
        let pathExt = url.pathExtension.lowercased()
        let normalizedExt: String
        switch pathExt {
        case "ico", "png", "gif", "svg", "webp":
            normalizedExt = pathExt
        case "jpg", "jpeg":
            normalizedExt = "jpg"
        default:
            normalizedExt = "ico"
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("favicon-\(UUID().uuidString).\(normalizedExt)")
        do {
            try data.write(to: tmp, options: .atomic)
            return (tmp, normalizedExt)
        } catch {
            return nil
        }
    }

    /// Stage 4.5 commit 4 — pulls the first matching `<link rel="...">`
    /// href from the page HTML. Priority is apple-touch-icon → icon →
    /// shortcut icon (Apple's hi-res variant first, then plain, then
    /// the IE6-era legacy). Relative hrefs are resolved against
    /// `base` so the caller always gets an absolute URL it can hand
    /// straight to `URLSession`.
    private static func extractFaviconURL(in html: String, base: URL) -> URL? {
        let priorities = ["apple-touch-icon", "icon", "shortcut icon"]
        for rel in priorities {
            if let href = linkRelHref(in: html, rel: rel),
               let resolved = URL(string: href, relativeTo: base)?.absoluteURL {
                return resolved
            }
        }
        return nil
    }

    private static func linkRelHref(in html: String, rel: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: rel)
        // Both attribute orderings: rel=…href=… and href=…rel=….
        let patterns = [
            #"<link\s+[^>]*rel=["']\#(escaped)["'][^>]*href=["']([^"']*)["']"#,
            #"<link\s+[^>]*href=["']([^"']*)["'][^>]*rel=["']\#(escaped)["']"#
        ]
        for pattern in patterns {
            if let match = firstCaptureGroup(html, pattern: pattern) {
                return decodeHTMLEntities(match.trimmingCharacters(in: .whitespacesAndNewlines)).nilIfEmpty
            }
        }
        return nil
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
