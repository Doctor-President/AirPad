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
/// Stage 4.6 commit 4 — tap → Quick Look via
/// `DocumentQuickLookViewer` sheet driven by `DocumentPreviewIdentity`
/// (`@State` so each tap presents fresh). Top-right overlaid `…` menu
/// surfaces Open / Share / Copy filename / Delete. Same chrome posture
/// as `LinkGalleryTile`: `.contentShape(Rectangle()) + .onTapGesture`
/// (not SwiftUI `Link`) so the tile's tap area doesn't broadcast
/// `.isLink` traits across the EntryCard and eat chevron/menu/long-press.
/// The Menu's own tap target intercepts before the tile's tap gesture
/// fires.
struct DocumentGalleryTile: View {

    let documentItem: DocumentItem
    let entryID: String
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var thumbnail: UIImage? = nil
    @State private var previewIdentity: DocumentPreviewIdentity? = nil
    @State private var shareIdentity: DocumentShareIdentity? = nil

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
        .contentShape(Rectangle())
        .onTapGesture { Task { await openInQuickLook() } }
        .overlay(alignment: .topTrailing) { tileMenu }
        .task { await extractIfNeeded() }
        .sheet(item: $previewIdentity) { identity in
            DocumentQuickLookViewer(url: identity.url)
                .ignoresSafeArea()
        }
        .sheet(item: $shareIdentity) { identity in
            DocumentShareSheet(items: [identity.url])
        }
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

    // MARK: - Per-tile menu

    /// Stage 4.6 commit 4 — overlaid in the top-right corner so it floats
    /// above the thumbnail or icon block without disrupting the tile's
    /// tap region. Same 28pt black-translucent circle treatment as
    /// `LinkGalleryTile.tileMenu` — reads as chrome, not content. The
    /// Menu's own tap target intercepts before the tile's
    /// `.onTapGesture` fires.
    ///
    /// Delete is destructive on `DocumentItem` (per-tile removal), not on
    /// the whole entry — entry-level delete still lives on the EntryCard
    /// menu. `removeDocumentItem` handles the file blob + thumbnail
    /// sidecar cleanup; if the count drops to 1, `EntryCard` swaps the
    /// renderer to `DocumentEntryBody` on the next pass.
    private var tileMenu: some View {
        Menu {
            Button {
                Task { await openInQuickLook() }
            } label: {
                Label("Open", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                Task { await prepareShare() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = documentItem.fileName
            } label: {
                Label("Copy filename", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                Task {
                    await store.removeDocumentItem(
                        entryID: entryID,
                        nodeID: nodeID,
                        documentItemID: documentItem.id
                    )
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: 28, height: 28)
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(6)
        .accessibilityLabel("Document options")
    }

    // MARK: - Quick Look / Share triggers

    /// Resolves the on-disk URL and presents Quick Look. Silently bails
    /// if the document file can't be located (iCloud lazy materialization
    /// races, or a sidecar that's been cleaned up but whose entry hasn't
    /// reloaded yet). The tile remains tappable on the next try — no
    /// error state needed for v1 per the brief's "no per-tile error
    /// surface" stance.
    @MainActor
    private func openInQuickLook() async {
        guard let url = await store.documentFileURL(for: documentItem, nodeID: nodeID) else { return }
        previewIdentity = DocumentPreviewIdentity(url: url)
    }

    @MainActor
    private func prepareShare() async {
        guard let url = await store.documentFileURL(for: documentItem, nodeID: nodeID) else { return }
        shareIdentity = DocumentShareIdentity(url: url)
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

/// Stage 4.6 commit 4 — identity wrapper for the share sheet's
/// `.sheet(item:)` driver. Same pattern as `DocumentPreviewIdentity`
/// (fresh id per tap) so repeated taps re-present cleanly. Lives in
/// this file because it's shared between `DocumentGalleryTile` and
/// `DocumentEntryBody`; the two views import this file transitively
/// through the shared compilation unit.
struct DocumentShareIdentity: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// Stage 4.6 commit 4 — thin `UIViewControllerRepresentable` around
/// `UIActivityViewController`. Duplicated from
/// `GalleryFullscreenViewer`'s private `ShareSheet` rather than
/// promoted to shared scope — same precedent as `withTimeout` being
/// duplicated between `OGMetadataService` and `DocumentExtractionService`
/// (small helpers each own their copy so neither file depends on the
/// other's internals).
struct DocumentShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
