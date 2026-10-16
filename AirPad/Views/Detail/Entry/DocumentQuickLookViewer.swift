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
/// Wrapped in a `UINavigationController` deliberately: it hosts QuickLook's title bar (the display-name title + its
/// actions menu). (It once also hosted QuickLook's Done; iOS 26/27 no longer show one there — the Close button is
/// `DocumentViewerSheet`'s, live-19.) Future reader: do not "harmonize" by removing the wrap.
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

/// live-19 — the document viewer sheet. QuickLook's document preview offers NO close control in our sheet on iOS 26 or
/// iOS 27 (measured on the 26.5 and 27.0 Simulators: just its title menu + Markup / Search / Share). On iOS 26 the
/// sheet's swipe-down closes it; on iOS 27 QuickLook's content swallows the swipe, so the viewer could not be closed at
/// all (found by `DocumentHandoffName` on the iOS 27 Simulator: the named copy was never released). A nav-bar item
/// doesn't survive QuickLook's chrome, so a Close button is overlaid in its empty top-leading slot, on every OS.
struct DocumentViewerSheet: View {
    let handoff: DocumentHandoff
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DocumentQuickLookViewer(handoff: handoff)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("documentViewerClose")
                .padding(.top, 19)
                .padding(.leading, 19)
            }
    }
}
