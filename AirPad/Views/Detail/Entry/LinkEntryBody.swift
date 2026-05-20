import SwiftUI

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
struct LinkEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    @State private var showingAppendSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OGPreviewView(
                item: item,
                nodeID: nodeID,
                onCommitURL: handleURLCommit
            )

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
