import SwiftUI
import QuickLook

/// Stage 4.6 commit 4 — Quick Look-backed preview sheet for `.document`
/// entries. Drives the tap-to-open gesture on both `DocumentGalleryTile`
/// (per-tile in the multi-doc gallery) and `DocumentEntryBody` (the
/// single-doc preview block). Thin `UIViewControllerRepresentable`
/// wrapper around `QLPreviewController`. Separately owned from the
/// (now-retired) media-side QuickLook viewer so this surface isn't
/// entangled with the unified-media-viewer arc, which moved media off
/// QuickLook entirely (briefs/unified-media-viewer.md commit 2).
///
/// Quick Look handles a broad set of formats natively (PDF, HTML, TXT,
/// MD, RTF, common images, .docx, .xlsx, .pptx, .pages, .numbers, .key,
/// .csv, and more). The brief's stance on Office formats: render via
/// Quick Look even when text extraction isn't implemented, so capture
/// is never gated by extension.
///
/// Wrapped in a `UINavigationController` deliberately. Image/video
/// QuickLook previews overlay their own Done button on top of the
/// media, but document preview (PDF / HTML / TXT / MD / RTF) renders
/// edge-to-edge and exposes Done only as a `leftBarButtonItem` on the
/// host nav bar. Without a hosting nav controller the bar item has
/// nowhere to render and the sheet becomes undismissable (QL's
/// full-screen content consumes the swipe-down gesture too). Future
/// reader: do not "harmonize" by removing the wrap.
///
/// live-17 — handed a `DocumentHandoff`: QuickLook titles the viewer with the document's display name and its own Share
/// button sends the named copy, never the stored UUID file. The copy is removed when the viewer closes.
struct DocumentQuickLookViewer: UIViewControllerRepresentable {
    let handoff: DocumentHandoff

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Coordinator) {
        coordinator.item.handoff.release()
    }

    func makeCoordinator() -> Coordinator { Coordinator(handoff: handoff) }

    /// The item QuickLook shows: the named copy, titled with the display name.
    final class PreviewItem: NSObject, QLPreviewItem {
        let handoff: DocumentHandoff
        init(handoff: DocumentHandoff) { self.handoff = handoff }
        var previewItemURL: URL? { handoff.url }
        var previewItemTitle: String? { handoff.title }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: PreviewItem
        init(handoff: DocumentHandoff) { item = PreviewItem(handoff: handoff) }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            DocumentHandoffProbe.preview(doc: item.handoff.documentID, title: item.handoff.title, url: item.handoff.url)
            return item
        }
    }
}
