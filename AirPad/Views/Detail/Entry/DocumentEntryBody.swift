import SwiftUI
import UIKit

/// Stage 3.1a commit (b) — body slot for `.document` entries. Renders inside
/// an `EntryCard`, so no outer padding/background — the card supplies it.
///
/// Stage 4.6 commit 2 — reads `documentItems[0]` when present (the v3→v4
/// migrated shape, also the shape every new capture lands on via
/// `CorpusStore.addDocumentEntry`). Title falls back from
/// `documentTitle` → `fileName` → legacy `item.file`'s last path
/// component; the page/word-count metrics row appears beneath the title
/// when extraction populated them.
///
/// Stage 4.6 commit 3 — count-based dispatch in `EntryCard` routes
/// `documentItems.count >= 2` to `DocumentGalleryBody`; this view is
/// only reached for count 0 / 1 / nil now.
///
/// Stage 4.6 commit 3 (amend) — restructured to match `LinkEntryBody`'s
/// chrome-pattern: thumbnail-or-icon preview block at top, title +
/// metrics below, `MediaEntryChrome` strip at the bottom carrying a
/// "+" that appends directly via `CorpusStore.appendDocumentItems`.
/// No modal — the destination is unambiguous (this entry), same
/// contract as `LinkEntryBody`'s in-entry "+". The capture-time
/// confirmationDialog in `NodeDetailView` applies only to the
/// canvas-level "+ Document" path, where the user could plausibly
/// intend either append or new entry.
///
/// Thumbnail rendering parallels `DocumentGalleryTile.thumbnailBlock`:
/// state-driven `UIImage` load via `store.documentThumbnailFileURL`,
/// format-specific SF Symbol fallback (`doc.richtext.fill` for PDF,
/// `globe` for HTML, `doc.fill` otherwise) when no thumbnail is on
/// disk (TXT / MD / RTF never produce one; PDF / HTML get one once
/// extraction completes).
///
/// First-render extraction backfill via `.task`: fires
/// `DocumentExtractionService` for supported formats whose
/// `extractionAttemptedAt` is nil or older than the staleness window,
/// then routes the result through `CorpusStore.applyDocumentExtraction`.
/// Mirrors `LinkEntryBody.refetchIfStaleOrMissing`'s on-appear staleness
/// pattern.
///
/// Acts as a safety net + the primary trigger for new single-doc
/// captures (`addDocumentEntry` populates `documentItems[0]` before
/// the view renders, so `.task` fires with the gate already open).
/// For multi-doc gallery entries the trigger lives on each
/// `DocumentGalleryTile` (same shape, same staleness gate). For
/// migrated legacy entries the primary trigger is
/// `CorpusStore.ensureEntrySchema`'s migration-driven kickoff — view
/// `.task` would otherwise race with migration and fire before
/// `documentItems[0]` exists.
struct DocumentEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var thumbnail: UIImage? = nil
    @State private var showingAppendSheet = false

    private static let thumbnailHeight: CGFloat = 120

    private var documentItem: DocumentItem? { item.documentItems?.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            previewBlock
            textBlock
            MediaEntryChrome(
                onAdd: { showingAppendSheet = true },
                accessibilityLabel: "Add document"
            ) {
                // Empty trailing slot pins the 44pt
                // `MediaEntryChromeMetrics.height` contract; matches
                // `LinkEntryBody`'s single-entry chrome so the visual
                // transition single → gallery doesn't resize.
                EmptyView()
            }
        }
        .sheet(isPresented: $showingAppendSheet) {
            DocumentPickerView { urls in
                guard !urls.isEmpty else { return }
                Task {
                    await store.appendDocumentItems(
                        toEntryID: item.id,
                        nodeID: nodeID,
                        sourceURLs: urls
                    )
                }
            }
        }
        .task { await extractIfNeeded() }
    }

    private var previewBlock: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.06))
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else {
                Image(systemName: documentIconName)
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(height: Self.thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: documentItem?.thumbnailFile) {
            thumbnail = nil
            guard let docItem = documentItem else { return }
            guard let url = await store.documentThumbnailFileURL(for: docItem, nodeID: nodeID) else { return }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                thumbnail = img
            }
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            if let metricsLine {
                Text(metricsLine)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            } else if let description = item.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var documentIconName: String {
        guard let docItem = documentItem else { return "doc.fill" }
        switch docItem.fileType.lowercased() {
        case "pdf":            return "doc.richtext.fill"
        case "html", "htm":    return "globe"
        default:               return "doc.fill"
        }
    }

    private var displayTitle: String {
        if let docItem = documentItem {
            return docItem.documentTitle ?? docItem.fileName
        }
        return item.file?.components(separatedBy: "/").last ?? "Document"
    }

    private var metricsLine: String? {
        guard let docItem = documentItem else { return nil }
        var parts: [String] = []
        if let pages = docItem.pageCount, pages > 0 {
            parts.append(pages == 1 ? "1 page" : "\(pages) pages")
        }
        if let words = docItem.wordCount, words > 0 {
            parts.append("\(words) words")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func extractIfNeeded() async {
        guard let docItem = documentItem else { return }
        // Staleness gate (parallels `LinkEntryBody.refetchIfStaleOrMissing`).
        // Skip when extraction was attempted within the staleness window;
        // re-fire for never-attempted (nil) and long-ago-attempted (older
        // than the window). Transient failures (iCloud lazy materialization,
        // momentary timeout) self-heal on the next view after the window
        // elapses; persistently broken files don't loop within the window.
        if let attemptedAt = docItem.extractionAttemptedAt,
           Date().timeIntervalSince(attemptedAt) < DocumentExtractionService.staleness {
            return
        }
        let normalized = docItem.fileType.lowercased()
        guard DocumentExtractionService.supportedExtensions.contains(normalized) else { return }
        guard let url = await store.documentFileURL(for: docItem, nodeID: nodeID) else { return }
        let extraction = await DocumentExtractionService().extract(
            fileURL: url,
            fileType: normalized
        )
        await store.applyDocumentExtraction(
            nodeID: nodeID,
            entryID: item.id,
            documentItemID: docItem.id,
            extraction: extraction
        )
    }
}
