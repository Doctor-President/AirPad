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
/// Stage 4.6 commit 4 — preview-block tap → Quick Look via
/// `DocumentQuickLookViewer` sheet driven by a `DocumentHandoff` (live-17)
/// (`@State` so each tap presents fresh, same pattern as
/// `DocumentGalleryTile`). Top-right overlaid `…` menu surfaces Open /
/// Share / Copy filename — Delete intentionally omitted on the
/// single-doc menu because removing the only `DocumentItem` would
/// leave an empty `.document` entry; entry-level delete still lives
/// on the EntryCard menu and is the correct affordance for that flow.
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
    @Environment(\.appBodyFont) private var appFont   // 1.1-A type pass

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var thumbnail: UIImage? = nil
    @State private var showingAppendSheet = false
    @State private var previewIdentity: DocumentHandoff? = nil
    @State private var shareIdentity: DocumentHandoff? = nil
    #if targetEnvironment(macCatalyst)
    @State private var macDoc = MacDocumentState()   // sweep 1 · N4
    #endif

    private static let thumbnailHeight: CGFloat = 120

    /// Sweep 1 review (N1) — a document appended before the fix is still a legacy-shaped item (no `documentItems`): it is
    /// read as a document all the same (its stored file, its real name from `description`), so Quick Look, Share, Open a
    /// Copy and Reveal work for it too. Display only — nothing is written back.
    private var documentItem: DocumentItem? {
        if let d = item.documentItems?.first { return d }
        guard item.type == .document, let file = item.file, !file.isEmpty else { return nil }
        return DocumentItem(id: item.id, filePath: file, fileName: DocumentNaming.storedName(item.description),
                            fileType: (file as NSString).pathExtension.lowercased(), documentTitle: nil, extractedText: nil,
                            thumbnailFile: nil, pageCount: nil, wordCount: nil, capturedAt: item.createdAt)
    }

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
        .appSheet(isPresented: $showingAppendSheet) {
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
        .appSheet(item: $previewIdentity) { identity in
            DocumentViewerSheet(handoff: identity)
                .ignoresSafeArea()
        }
        .appSheet(item: $shareIdentity) { identity in
            DocumentShareSheet(handoff: identity)
                .macSheetClose()   // Mac D0.11 — a visible × + Esc around the share panel
        }
        .task { await extractIfNeeded() }
    }

    private var previewBlock: some View {
        ZStack {
            Rectangle().fill(AppearancePalette.ink.opacity(0.06))
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else {
                Image(systemName: documentIconName)
                    .font(.largeTitle)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.35))
            }
        }
        .frame(height: Self.thumbnailHeight)
        .accessibilityIdentifier("documentOpen-\(documentItem?.id ?? item.id)")
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { Task { await openInQuickLook() } }
        #if targetEnvironment(macCatalyst)
        .macDocumentActions(macDoc, doc: documentItem, nodeID: nodeID, cornerRadius: 8) { Task { await openInQuickLook() } }
        #endif
        .overlay(alignment: .topTrailing) { tileMenu }
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
                .font(appFont.font(size: 15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(AppearancePalette.ink)
                .lineLimit(2)
            if let metricsLine {
                Text(metricsLine)
                    .font(appFont.font(size: 12, relativeTo: .caption1))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    .lineLimit(1)
            } else if let description = item.description, item.documentItems != nil || DocumentNaming.storedName(description).isEmpty {
                Text(description)
                    .font(appFont.font(size: 12, relativeTo: .caption1))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
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
            return docItem.displayName
        }
        // Mac sweep 1 · N1 — a legacy-shaped item (appended by a drop/share before the fix): the real name it was given
        // (`description`), never the stored `<UUID>.<ext>` (`shownName` falls back to "PDF · <date>").
        let ext = ((item.file ?? "") as NSString).pathExtension.lowercased()
        return DocumentNaming.shownName(fileName: item.description ?? "", documentTitle: nil, fileType: ext,
                                        capturedAt: item.createdAt)
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

    private var tileMenu: some View {
        Menu {
            Button {
                Task { await openInQuickLook() }
            } label: {
                Label(RunningOnMac.isMac ? "Quick Look" : "Open", systemImage: "doc.text.magnifyingglass")   // N4
            }
            #if targetEnvironment(macCatalyst)
            MacDocumentMenuItems(state: macDoc)
            #endif
            Button {
                Task { await prepareShare() }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                // Sweep 1 · N2: the file's name as shown, with its extension (a legacy-shaped item too).
                UIPasteboard.general.string = DocumentHandoff.fileName(displayTitle, ext: documentItem?.fileType ?? "")
            } label: {
                Label("Copy filename", systemImage: "doc.on.doc")
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
        .help("Document options")
        .accessibilityIdentifier("documentMenu-\(documentItem?.id ?? item.id)")
    }

    @MainActor
    private func openInQuickLook() async {
        guard let docItem = documentItem else { return }
        previewIdentity = await store.documentHandoff(for: docItem, nodeID: nodeID)
    }

    @MainActor
    private func prepareShare() async {
        guard let docItem = documentItem else { return }
        shareIdentity = await store.documentHandoff(for: docItem, nodeID: nodeID)
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
