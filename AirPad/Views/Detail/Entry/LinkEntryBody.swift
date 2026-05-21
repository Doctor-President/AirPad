import SwiftUI
import UIKit

/// AT19.3c — body slot for `.link` entries with 0 or 1 link. Delegates
/// rendering to `OGPreviewView` (shared with the QuikCapture receipt
/// modal) and owns the fetch lifecycle: on appear it refetches when
/// stale or never-fetched; on URL commit (State A) it persists the URL
/// and kicks off the initial fetch. Both paths share `triggerFetch` so
/// writeback lives in one place.
///
/// Stage 4.5 commit 3 — chrome row added below the OG preview with a
/// "+" trigger that presents `LinkAppendSheet`. Committing a URL via
/// the sheet calls `store.appendLinkItem`, which lifts the legacy URL
/// into `linkItems[0]` and appends the new LinkItem as `linkItems[1]`;
/// at that point EntryCard's count-based `.link` dispatch swaps the
/// renderer over to `LinkGalleryBody` on the next pass.
///
/// The chrome row also appears on a fresh empty entry (State A in
/// `OGPreviewView`) so the user always has the same "+" affordance.
/// Tapping "+" before committing a URL still works — the resulting
/// entry will have a single LinkItem (the freshly appended URL) and
/// the legacy `item.url` will stay nil. The dispatch in EntryCard
/// treats both "1 URL via legacy field" and "1 URL via linkItems[0]"
/// as single-link and keeps this view on screen.
///
/// Stage 4.6 commit 5 — top-right overlaid `…` menu surfaces Open URL /
/// Copy URL / Save content (or "Update content" once a snapshot exists).
/// Delete intentionally omitted on the single-link menu: removing the
/// only LinkItem would leave the entry empty and entry-level delete
/// already lives on the EntryCard menu. The Save/Update item routes
/// through `LinkSnapshotService` and `CorpusStore.applyLinkSnapshot`;
/// `isSnapshotting` disables the item during the pass. When the
/// snapshot lands, a "N,NNN words saved" chip appears below the OG
/// preview — same surface treatment as `LinkGalleryTile`'s chip.
///
/// Snapshot affordance is gated on the presence of `linkItems[0]`. A
/// legacy v2 entry with no `linkItems` (rare post-migration; defensive
/// branch) shows Open / Copy but hides Save content, because the
/// snapshot trio has no `LinkItem` to attach to. New captures and
/// migrated entries always have `linkItems[0]`.
struct LinkEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var showingAppendSheet = false
    @State private var isSnapshotting = false

    private var snapshotLinkItem: LinkItem? { item.linkItems?.first }

    private var resolvedURLString: String? {
        if let urlString = snapshotLinkItem?.url, !urlString.isEmpty { return urlString }
        if let urlString = item.url, !urlString.isEmpty { return urlString }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OGPreviewView(
                item: item,
                nodeID: nodeID,
                onCommitURL: handleURLCommit
            )
            .overlay(alignment: .topTrailing) { tileMenu }

            if let wordCount = snapshotLinkItem?.snapshotWordCount, wordCount > 0 {
                Text("\(wordCount.formatted()) words saved")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }

            MediaEntryChrome(
                onAdd: { showingAppendSheet = true },
                accessibilityLabel: "Add link"
            ) {
                // Toggle slot stays empty on single-link entries — the
                // chrome row matches `LinkGalleryBody`'s height contract
                // so the visual transition single → multi doesn't
                // resize, exactly the way `SingleMediaBody` keeps an
                // empty trailing slot to match `GalleryBody`.
                EmptyView()
            }
        }
        .sheet(isPresented: $showingAppendSheet) {
            LinkAppendSheet { url in
                Task {
                    await store.appendLinkItem(
                        toEntryID: item.id,
                        nodeID: nodeID,
                        url: url
                    )
                }
            }
        }
        .onAppear { Task { await refetchIfStaleOrMissing() } }
    }

    /// Stage 4.6 commit 5 — single-link menu, no Delete. Same chrome
    /// posture as `DocumentEntryBody.tileMenu` (28pt black-translucent
    /// circle, top-right). The Save/Update item is hidden when there's
    /// no LinkItem to attach the snapshot to (legacy v2 defensive
    /// branch); Open/Copy still work off the legacy `item.url`.
    @ViewBuilder
    private var tileMenu: some View {
        if let urlString = resolvedURLString {
            Menu {
                if let url = URL(string: urlString) {
                    Button { openURL(url) } label: {
                        Label("Open URL", systemImage: "safari")
                    }
                }
                Button {
                    UIPasteboard.general.string = urlString
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                if snapshotLinkItem != nil {
                    Button {
                        performSnapshot()
                    } label: {
                        Label(
                            snapshotLinkItem?.snapshotAt == nil ? "Save content" : "Update content",
                            systemImage: snapshotLinkItem?.snapshotAt == nil ? "square.and.arrow.down" : "arrow.clockwise"
                        )
                    }
                    .disabled(isSnapshotting)
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
            .accessibilityLabel("Link options")
        }
    }

    /// Stage 4.6 commit 5 — user-invoked snapshot trigger from the
    /// single-link menu. Parallel shape to `LinkGalleryTile.performSnapshot`:
    /// `isSnapshotting` gates the menu item disabled during the pass;
    /// a nil result silently no-ops and the menu re-enables on the
    /// next tick. Success routes through `applyLinkSnapshot`, which
    /// writes the trio (snapshotText/snapshotAt/snapshotWordCount) on
    /// `linkItems[0]`, then the entry re-renders with the word-count
    /// chip and the menu label flipped to "Update content."
    private func performSnapshot() {
        guard !isSnapshotting,
              let linkItem = snapshotLinkItem,
              let url = URL(string: linkItem.url) else { return }
        isSnapshotting = true
        let capturedNodeID = nodeID
        let capturedEntryID = item.id
        let capturedLinkID = linkItem.id
        Task { @MainActor in
            defer { isSnapshotting = false }
            guard let result = await LinkSnapshotService().snapshot(url: url) else { return }
            await store.applyLinkSnapshot(
                nodeID: capturedNodeID,
                entryID: capturedEntryID,
                linkItemID: capturedLinkID,
                snapshot: result
            )
        }
    }

    private func handleURLCommit(_ urlString: String) {
        Task {
            await store.setLinkEntryURL(nodeID: nodeID, itemID: item.id, url: urlString)
            await triggerFetch(for: urlString)
        }
    }

    /// Stage 4.5 commit 5 — skip when `linkItems[0]` is present.
    /// `LinkGalleryTile` owns its own freshness check via `hasAnyOG` and
    /// triggers its own fetch on appear, so a single-mode entry whose
    /// data lives in `linkItems[0]` (e.g. after a 2→1 down-collapse from
    /// per-tile delete) doesn't need a parallel refetch here. Legacy-
    /// only entries (no linkItems) still flow through the original
    /// staleness check below.
    private func refetchIfStaleOrMissing() async {
        if item.linkItems?.first != nil { return }
        guard let urlString = item.url, !urlString.isEmpty else { return }
        if let fetchedAt = item.ogFetchedAt,
           Date().timeIntervalSince(fetchedAt) < OGMetadataService.staleness {
            return
        }
        await triggerFetch(for: urlString)
    }

    private func triggerFetch(for urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        let metadata = await OGMetadataService().fetch(url: url)
        await store.applyOGFetch(nodeID: nodeID, itemID: item.id, metadata: metadata)
    }
}
