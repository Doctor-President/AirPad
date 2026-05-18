import SwiftUI
import QuickLook

/// Stage 4.2 commit 3 — transitional QuickLook-backed fullscreen viewer used
/// by `SingleMediaBody`'s tap-to-fullscreen gesture. Renders images and
/// videos with the system QL controls (pinch-zoom, scrub, share). Commit 7
/// replaces this with a custom AirPad viewer that adds per-item delete and
/// AirPad-style Share/Copy chrome, but the trigger surface stays the same:
/// `SingleMediaBody` drives a sheet via `@State`-bound identifier so the
/// swap is content-only — no callsite changes.
struct MediaFullscreenViewer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

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

/// Identifier wrapper for the `.sheet(item:)` driver in `SingleMediaBody` —
/// `URL` doesn't conform to `Identifiable`, and we want a fresh identity
/// each time so the sheet re-presents cleanly even if the URL repeats.
struct MediaPreviewIdentity: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}
