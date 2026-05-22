import Foundation
import UIKit
import UniformTypeIdentifiers

/// Stage 4.7 — Paste Pad's content router. Reads `UIPasteboard` contents
/// and classifies them into a typed `ClipboardContent` enum so the
/// downstream paste handlers in `NodeDetailView` can route to the correct
/// entry kind (URL → link, image → gallery, file URL → document, etc.).
///
/// Synchronous-classification posture: every case the router emits is
/// built from data the pasteboard makes available synchronously
/// (`url`, `string`, `image`, plus per-item type queries). Async
/// itemProvider data loads (e.g., fetching the bytes of a video file URL
/// reported by a Share-Sheet caller) are deferred to the per-type paste
/// handlers — the router answers "what's on the clipboard?", not
/// "give me the bytes." This matches the Phase 1 audit decision that
/// `UIPasteboard.general` is sufficient for detail-view scope; richer
/// itemProvider classification arrives later for the canvas-level Paste
/// Pad in `ws-quikcapture-v2`.
///
/// Disambiguation rules (locked 2026-05-21 gym-walk session):
///   - URL precedence over plain text. If the pasteboard exposes a URL
///     OR the string parses as one with an http/https scheme, classify
///     as `.url`. The "Paste link here" label wins over "Paste text
///     here" without surfacing a disambiguator.
///   - Image precedence over text. `pasteboard.image` (or any item
///     conforming to `public.image`) classifies as `.image`.
///   - Multi-item only when more than one item produces a non-empty
///     classification; a single survivor collapses back to its own
///     case. (Empty items get filtered.)
///   - Unsupported content coerces to `.text` if any string
///     representation exists, else `.empty`. The brief's Option-3 soft
///     fallback to Option-1.
///
/// Privacy: reads of `UIPasteboard.general` trigger iOS 14+'s "pasted
/// from <app>" banner. The router is invoked from `PastePadView` only
/// on `.onAppear` and `UIPasteboard.changedNotification`, never on
/// every redraw — matches the Phase 1 audit's clipboard-observation
/// lifecycle.
enum ClipboardContent {
    case url(URL)
    case image(UIImage)
    /// File URL for a video. The router materializes pasteboard bytes
    /// to a temp file under the concrete UTI's preferred extension
    /// (e.g., `.mp4`) and returns the temp URL — Files.app's Copy
    /// publishes video data under the concrete content type, not
    /// `public.file-url`, so the URL the handler receives is owned by
    /// the router's temp dir, not by the source app. The temp file is
    /// reaped by iOS automatically; `persistMediaFiles` copies out
    /// (not moves) so the URL remains valid through the handler's
    /// defensive temp-copy step.
    case video(URL)
    /// File URL plus a lowercase extension hint (`"pdf"`, `"docx"`,
    /// `"txt"`, …) for paste handlers to drive the Stage 4.6 documents
    /// flow and the append-vs-new-entry modal. As with `.video`, the
    /// URL points into the router's temp dir when the pasteboard
    /// shape is the Files.app typed-data form (the common case); rare
    /// third-party apps that register `public.file-url` directly are
    /// surfaced via the legacy fallback in classify path 5.
    case file(URL, fileType: String)
    case text(String)
    /// Multi-item batch. Per-item classifications in clipboard order;
    /// guaranteed non-nested (the router collapses single-survivor
    /// batches before emitting `.multi`).
    case multi([ClipboardContent])
    case empty
}

enum ClipboardContentRouter {

    /// Synchronous classification entry point. Default argument
    /// `.general` matches the production call site in `PastePadView`;
    /// tests pass in `UIPasteboard.withUniqueName()` for isolation.
    static func classify(_ pasteboard: UIPasteboard = .general) -> ClipboardContent {
        let count = pasteboard.numberOfItems
        if count == 0 { return .empty }

        var items: [ClipboardContent] = []
        items.reserveCapacity(count)
        for i in 0..<count {
            let classified = classifyItem(pasteboard, at: i)
            if case .empty = classified { continue }
            items.append(classified)
        }

        if items.isEmpty { return .empty }
        if items.count == 1 { return items[0] }
        return .multi(items)
    }

    // MARK: - Per-item classification

    private static func classifyItem(_ pasteboard: UIPasteboard, at index: Int) -> ClipboardContent {
        let indexSet = IndexSet(integer: index)
        let types = (pasteboard.types(forItemSet: indexSet)?.first) ?? []

        // 1. URL precedence — direct `public.url` first, then string-parsed URL.
        //    Apply `isWebURL` so a non-http(s) URI surfaced by iOS's
        //    pasteboard machinery (e.g., `mailto:`, `tel:`, custom app
        //    schemes — iOS auto-promotes plain-text URI strings onto
        //    `public.url` when assigned via `pasteboard.string`) falls
        //    through to path 6, where it classifies as `.text` content.
        //    The user copied content that looks like a URI, not a web
        //    link to fetch OG metadata for.
        if conforms(types, to: .url),
           let url = firstValue(pasteboard, type: UTType.url.identifier, in: indexSet) as? URL,
           isWebURL(url) {
            return .url(url)
        }

        // 2. Image.
        if conforms(types, to: .image),
           let imageTypeID = types.first(where: { UTType($0)?.conforms(to: .image) == true }),
           let data = firstData(pasteboard, type: imageTypeID, in: indexSet),
           let image = UIImage(data: data) {
            return .image(image)
        }

        // 3. Video — Files.app's Copy publishes the bytes under the
        //    concrete UTI (e.g., `public.mpeg-4`), not the abstract
        //    `public.movie`. A direct query against `public.movie`
        //    returns nil on that path, so the C2 shape (a single
        //    `public.movie` URL query) missed every real-world video
        //    paste from Files.app. Walk the declared types, pick the
        //    first concrete identifier that conforms to `public.movie`,
        //    then try Data first (Files.app / Share-Sheet shape — bytes
        //    materialized to a temp file the handler can copy out of)
        //    and URL second (legacy shape, retained so any source that
        //    DOES register a URL still classifies).
        if let videoTypeID = types.first(where: { UTType($0)?.conforms(to: .movie) == true }) {
            if let data = firstData(pasteboard, type: videoTypeID, in: indexSet) {
                let ext = UTType(videoTypeID)?.preferredFilenameExtension ?? "mov"
                if let tempURL = writeTempFile(data: data, ext: ext) {
                    return .video(tempURL)
                }
            }
            if let url = firstValue(pasteboard, type: videoTypeID, in: indexSet) as? URL {
                return .video(url)
            }
        }

        // 4. Document file — Files.app and most share flows place the
        //    file's bytes on the pasteboard under the file's content
        //    UTI (e.g., `com.adobe.pdf` for a PDF, `public.zip` for a
        //    zip), NOT under `public.file-url`. The C2 shape only
        //    queried `public.file-url`, so the PDF-from-Files.app paste
        //    fell through every path and classified as `.empty`. Walk
        //    the declared types; pick the first identifier that (a)
        //    conforms to `public.data`, (b) isn't already handled by
        //    paths 1–3, and (c) doesn't conform to `public.text` (so
        //    plain-text / RTF / HTML stay on the text path below — see
        //    "TXT-from-Files.app" follow-up note). Materialize to a
        //    temp file so downstream handlers see a stable URL.
        if let fileTypeID = types.first(where: { typeID in
            guard let ut = UTType(typeID) else { return false }
            if ut.conforms(to: .image) { return false }
            if ut.conforms(to: .movie) { return false }
            if ut.conforms(to: .url) { return false }
            if ut.conforms(to: .text) { return false }
            return ut.conforms(to: .data)
        }),
        let data = firstData(pasteboard, type: fileTypeID, in: indexSet) {
            let ext = UTType(fileTypeID)?.preferredFilenameExtension ?? "bin"
            if let tempURL = writeTempFile(data: data, ext: ext) {
                return .file(tempURL, fileType: ext)
            }
        }

        // 5. Legacy `public.file-url` fallback. Retained for the rare
        //    third-party app that DOES put a file URL directly on the
        //    pasteboard (instead of the typed-data shape Files.app
        //    uses). Files.app paste does not reach this branch in
        //    practice — path 4 catches it.
        if let fileURL = firstValue(pasteboard, type: UTType.fileURL.identifier, in: indexSet) as? URL {
            let ext = fileURL.pathExtension.lowercased()
            return .file(fileURL, fileType: ext)
        }

        // 6. Plain text — including URL-in-text coercion (URL precedence
        //    rule, but applied here because the pasteboard didn't
        //    surface a `public.url` directly).
        if conforms(types, to: .text),
           let text = firstValue(pasteboard, type: UTType.text.identifier, in: indexSet) as? String,
           !text.isEmpty {
            if let parsed = parseHTTPURL(from: text) {
                return .url(parsed)
            }
            return .text(text)
        }

        return .empty
    }

    // MARK: - Helpers

    /// Returns true when any UTType identifier in `types` conforms to
    /// the target type. `UTType(_:)` returns nil for unknown
    /// identifiers, which we treat as non-conforming.
    private static func conforms(_ types: [String], to target: UTType) -> Bool {
        types.contains { UTType($0)?.conforms(to: target) == true }
    }

    private static func firstValue(_ pasteboard: UIPasteboard, type: String, in set: IndexSet) -> Any? {
        pasteboard.values(forPasteboardType: type, inItemSet: set)?.first
    }

    private static func firstData(_ pasteboard: UIPasteboard, type: String, in set: IndexSet) -> Data? {
        firstValue(pasteboard, type: type, in: set) as? Data
    }

    /// Writes pasteboard-materialized bytes into the temp directory so
    /// downstream paste handlers (`handlePastedVideo`, `handlePastedFile`)
    /// receive a stable file URL. The temp file is not tracked: iOS's
    /// tmp-dir reaper handles cleanup, and `persistMediaFiles` /
    /// `saveItemFile` both copy out (not move), so the handler's own
    /// temp-copy step still works against this URL without competing
    /// with the source. Returns nil on a write failure — caller falls
    /// through to the next classification branch (`.empty` in the worst
    /// case).
    private static func writeTempFile(data: Data, ext: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Parses a string as an http/https URL only. Trims surrounding
    /// whitespace; rejects strings containing internal whitespace
    /// (multi-line paste of prose that happens to start with a URL
    /// stays as text). The scheme + host check delegates to
    /// `isWebURL` so the same web-link filter applies whether the URL
    /// arrived via `public.url` (path 1) or via string coercion
    /// (path 6).
    private static func parseHTTPURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        guard let url = URL(string: trimmed), isWebURL(url) else { return nil }
        return url
    }

    /// Web-link filter shared by path 1 (direct `public.url`) and
    /// path 6 (string-parsed URL). A URL classifies as `.url` only if
    /// it has an http or https scheme AND a non-empty host. Non-web
    /// URI schemes (`mailto:`, `tel:`, `sms:`, `airpad://`, etc.) and
    /// schemeless or host-less URLs fall through to `.text` — they're
    /// content, not "Paste link here" targets.
    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
