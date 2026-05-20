import SwiftUI

/// AT19.3c — body slot for `.link` entries. Delegates rendering to
/// `OGPreviewView` (shared with the QuikCapture receipt modal in commit 6)
/// and owns the fetch lifecycle: on appear it refetches when stale or
/// never-fetched; on URL commit (State A) it persists the URL and kicks
/// off the initial fetch. Both paths share `triggerFetch` so writeback
/// lives in one place.
///
/// Stage 4.5 commit 3 will wrap `OGPreviewView` in a VStack and add a
/// `MediaEntryChrome`-parallel chrome row below it with a "+" button
/// presenting `LinkAppendSheet` (the primitive that landed in commit 2).
/// The sheet's `onCommit` will call `store.appendLinkItem(toEntryID:
/// nodeID:url:)`, which lifts the legacy URL into `linkItems[0]` and
/// appends the new LinkItem — at that point the multi-link → 2 transition
/// kicks the renderer over to `LinkGalleryBody` via EntryCard's
/// count-based dispatch.
struct LinkEntryBody: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    var body: some View {
        OGPreviewView(
            item: item,
            nodeID: nodeID,
            onCommitURL: handleURLCommit
        )
        .onAppear { Task { await refetchIfStaleOrMissing() } }
    }

    private func handleURLCommit(_ urlString: String) {
        Task {
            await store.setLinkEntryURL(nodeID: nodeID, itemID: item.id, url: urlString)
            await triggerFetch(for: urlString)
        }
    }

    private func refetchIfStaleOrMissing() async {
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
