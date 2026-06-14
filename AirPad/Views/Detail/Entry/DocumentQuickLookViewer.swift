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
struct DocumentQuickLookViewer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// Stage 4.6 commit 4 — identity wrapper for `.sheet(item:)` drivers in
/// `DocumentGalleryTile` and `DocumentEntryBody`. `URL` doesn't conform
/// to `Identifiable`; wrapping in a fresh-id struct lets the sheet
/// re-present cleanly even if the user taps the same document twice in
/// a row.
struct DocumentPreviewIdentity: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}
