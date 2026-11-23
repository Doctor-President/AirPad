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
    /// Sweep 2b · 4.3 — one item (a document) or several (an entry's photos on the Mac: arrows step between them).
    let handoffs: [DocumentHandoff]
    var startIndex = 0
    /// Sweep 2b · 4.3 — lets the sheet step the controller from the keyboard (Mac ← / →).
    var handle: QuickLookHandle? = nil

    init(handoff: DocumentHandoff) { handoffs = [handoff] }
    init(handoffs: [DocumentHandoff], startIndex: Int, handle: QuickLookHandle?) {
        self.handoffs = handoffs
        self.startIndex = min(max(startIndex, 0), max(handoffs.count - 1, 0))
        self.handle = handle
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.currentPreviewItemIndex = startIndex
        handle?.controller = preview
        handle?.count = handoffs.count
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Coordinator) {
        for item in coordinator.items { item.handoff.release() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(handoffs: handoffs) }

    /// The item QuickLook shows: the named copy, titled with the display name.
    final class PreviewItem: NSObject, QLPreviewItem {
        let handoff: DocumentHandoff
        init(handoff: DocumentHandoff) { self.handoff = handoff }
        var previewItemURL: URL? { handoff.url }
        var previewItemTitle: String? { handoff.title }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let items: [PreviewItem]
        init(handoffs: [DocumentHandoff]) { items = handoffs.map(PreviewItem.init(handoff:)) }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { items.count }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            let item = items[min(max(index, 0), items.count - 1)]
            DocumentHandoffProbe.preview(doc: item.handoff.documentID, title: item.handoff.title, url: item.handoff.url)
            return item
        }
    }
}

/// Sweep 2b · 4.3 — the viewer's controller, for keyboard stepping between several items.
final class QuickLookHandle {
    weak var controller: QLPreviewController?
    var count = 1
    /// Moves to the previous (−1) / next (+1) item, stopping at the ends. Returns the new index, nil when it can't move.
    @MainActor @discardableResult func step(_ delta: Int) -> Int? {
        guard let c = controller, count > 1 else { return nil }
        let next = min(max(c.currentPreviewItemIndex + delta, 0), count - 1)
        guard next != c.currentPreviewItemIndex else { return nil }
        c.currentPreviewItemIndex = next
        return next
    }
}

/// live-19 — the document viewer sheet. QuickLook's document preview offers NO close control in our sheet on iOS 26 or
/// iOS 27 (measured on the 26.5 and 27.0 Simulators: just its title menu + Markup / Search / Share). On iOS 26 the
/// sheet's swipe-down closes it; on iOS 27 QuickLook's content swallows the swipe, so the viewer could not be closed at
/// all (found by `DocumentHandoffName` on the iOS 27 Simulator: the named copy was never released). A nav-bar item
/// doesn't survive QuickLook's chrome, so a Close button is overlaid in its empty top-leading slot, on every OS.
struct DocumentViewerSheet: View {
    let handoffs: [DocumentHandoff]
    var startIndex = 0
    @State private var handle = QuickLookHandle()
    #if targetEnvironment(macCatalyst)
    @State private var keysToken = 0
    #endif
    @Environment(\.dismiss) private var dismiss

    init(handoff: DocumentHandoff) { handoffs = [handoff] }
    /// Sweep 2b · 4.3 — an entry's photos (the Mac): Quick Look over all of them, opened on `startIndex`.
    init(handoffs: [DocumentHandoff], startIndex: Int) { self.handoffs = handoffs; self.startIndex = startIndex }

    var body: some View {
        DocumentQuickLookViewer(handoffs: handoffs, startIndex: startIndex, handle: handle)
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
            #if targetEnvironment(macCatalyst)
            // Sweep 2b · 4.3 — Space (and Esc) closes, ← / → step between the photos, as in Finder's Quick Look.
            .onAppear {
                keysToken = MacViewerKeys.open(count: handoffs.count, close: { dismiss() }, step: { handle.step($0) },
                                               isLive: { [weak handle] in handle?.controller?.viewIfLoaded?.window != nil },
                                               openCurrent: { [handoffs, weak handle] in
                                                   // Sweep 2b · 4.1 — ⌘O: a copy of the shown item (from its named copy;
                                                   // `openCopy` copies again, so the stored file is never handed out).
                                                   let i = min(max(handle?.controller?.currentPreviewItemIndex ?? startIndex, 0), handoffs.count - 1)
                                                   let h = handoffs[i]
                                                   Task { await MacDocumentActions.openCopy(of: h.url, named: h.title, ext: h.url.pathExtension) }
                                               },
                                               owns: { [weak handle] view in
                                                   guard let root = handle?.controller?.navigationController?.view ?? handle?.controller?.viewIfLoaded else { return false }
                                                   return view.isDescendant(of: root)
                                               })
                MacProofLog.note("4.3", "viewer open items \(handoffs.count) start \(startIndex)")
            }
            .onDisappear { MacViewerKeys.close(keysToken) }
            #endif
    }
}
