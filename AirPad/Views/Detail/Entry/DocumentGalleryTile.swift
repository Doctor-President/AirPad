import SwiftUI
import UIKit

/// Stage 4.6 commit 3 — single tile for a `DocumentItem`, parent-owned
/// sizing (the parent applies `.frame(width:height:)` and clips).
/// Parallel to `LinkGalleryTile`. Two visual states:
///   - With thumbnail (PDF page-1 rendered by `DocumentExtractionService`):
///     thumbnail letterboxed at the top in a fixed 100pt block, title +
///     metrics below.
///   - Without thumbnail (TXT/MD/RTF/HTML, or PDF mid-extraction / extraction
///     failed): a centered SF Symbol icon on the same 100pt block, title +
///     metrics below.
///
/// Letterbox (`scaledToFit`) is the deliberate choice over a top-crop:
/// a document's page-1 is the document's visual identity (title block,
/// header, layout) and cropping the top would hide what makes it
/// recognizable. The tinted backdrop fills the dead space so the slot
/// reads as "document preview," not as a half-empty image.
///
/// Extraction backfill via `.task`: parallels
/// `DocumentEntryBody.extractIfNeeded` — staleness-gated, supported-
/// formats only, routes the result back via
/// `CorpusStore.applyDocumentExtraction`. Per-tile firing means N parallel
/// extractions on first appear when an entry was just created with N
/// files; they serialize at the `DocumentExtractionService` actor.
///
/// C3 ships no tap target and no per-tile `…` menu — Quick Look + the
/// menu (Open / Copy filename / Delete) land in C4 together. The whole
/// entry can still be deleted via the EntryCard menu in the meantime.
struct DocumentGalleryTile: View {

    let documentItem: DocumentItem
    let entryID: String
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var thumbnail: UIImage? = nil

    private static let thumbnailHeight: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailBlock
            textBlock
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await extractIfNeeded() }
    }

    private var thumbnailBlock: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06))
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(6)
            } else {
                Image(systemName: documentIconName)
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(height: Self.thumbnailHeight)
        .task(id: documentItem.thumbnailFile) {
            thumbnail = nil
            guard let url = await store.documentThumbnailFileURL(for: documentItem, nodeID: nodeID) else { return }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                thumbnail = img
            }
        }
    }

    private var documentIconName: String {
        // PDF gets the page-style icon; HTML gets the globe (its content is
        // a web page); everything else (TXT / MD / RTF / unknown) gets the
        // generic doc icon. Signal at-a-glance what the user is looking at.
        switch documentItem.fileType.lowercased() {
        case "pdf":            return "doc.richtext.fill"
        case "html", "htm":    return "globe"
        default:               return "doc.fill"
        }
    }

    private var displayTitle: String {
        documentItem.documentTitle ?? documentItem.fileName
    }

    private var metricsLine: String? {
        var parts: [String] = []
        if let pages = documentItem.pageCount, pages > 0 {
            parts.append(pages == 1 ? "1 page" : "\(pages) pages")
        }
        if let words = documentItem.wordCount, words > 0 {
            parts.append("\(words) words")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let metricsLine {
                Text(metricsLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private func extractIfNeeded() async {
        if let attemptedAt = documentItem.extractionAttemptedAt,
           Date().timeIntervalSince(attemptedAt) < DocumentExtractionService.staleness {
            return
        }
        let normalized = documentItem.fileType.lowercased()
        guard DocumentExtractionService.supportedExtensions.contains(normalized) else { return }
        guard let url = await store.documentFileURL(for: documentItem, nodeID: nodeID) else { return }
        let extraction = await DocumentExtractionService().extract(
            fileURL: url,
            fileType: normalized
        )
        await store.applyDocumentExtraction(
            nodeID: nodeID,
            entryID: entryID,
            documentItemID: documentItem.id,
            extraction: extraction
        )
    }
}
