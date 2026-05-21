import SwiftUI

/// Stage 3.1a commit (b) — body slot for `.document` entries. Renders inside
/// an `EntryCard`, so no outer padding/background — the card supplies it.
///
/// Stage 4.6 commit 2 — reads `documentItems[0]` when present (the v3→v4
/// migrated shape, also the shape every new capture lands on via
/// `CorpusStore.appendDocumentItem`). Title falls back from
/// `documentTitle` → `fileName` → legacy `item.file`'s last path
/// component; the page/word-count metrics row appears beneath the title
/// when extraction populated them. Pre-extraction state (migrated entry
/// just opened, or fresh capture mid-extraction) shows just the title.
///
/// First-render extraction backfill via `.task`: fires
/// `DocumentExtractionService` for supported formats whose
/// `extractionAttemptedAt` is nil or older than the staleness window,
/// then routes the result through `CorpusStore.applyDocumentExtraction`.
/// Mirrors `LinkEntryBody.refetchIfStaleOrMissing`'s on-appear staleness
/// pattern.
///
/// Acts as a safety net + the primary trigger for new captures
/// (`appendDocumentItem` populates `documentItems[0]` before the view
/// renders, so `.task` fires with the gate already open). For migrated
/// legacy entries the primary trigger is
/// `CorpusStore.ensureEntrySchema`'s migration-driven kickoff — view
/// `.task` would otherwise race with migration and fire before
/// `documentItems[0]` exists.
struct DocumentEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    private var documentItem: DocumentItem? { item.documentItems?.first }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
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
            Spacer()
        }
        .task { await extractIfNeeded() }
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
