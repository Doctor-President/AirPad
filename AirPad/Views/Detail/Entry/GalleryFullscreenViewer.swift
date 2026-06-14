import SwiftUI
import AVKit
import UIKit

/// Stage 4.2 commit 7 — fullscreen viewer for `.imageVideo` entries in
/// gallery (multi-item) presentation. Replaces the commit-3 single-URL
/// QuickLook sheet for the gallery path. Single-item entries still go
/// through `MediaFullscreenViewer` from `SingleMediaBody` — this viewer
/// is gallery-only and assumes `galleryItems.count >= 1`.
///
/// ## Features
///   • Swipeable paging across all items via a horizontal paging
///     `ScrollView` (`.scrollTargetBehavior(.paging)`); paging is gated
///     off whenever the current page is pinch-zoomed past 1× so the
///     inner pan gesture wins over page-turns. See
///     `briefs/unified-media-viewer.md` and the validating spike at
///     `briefs/spike-zoom-paging.md`.
///   • Per-item chrome at the bottom: Share / Copy / Set Hero / Delete.
///   • Top-of-view close button + index indicator (`3 / 7`).
///   • Image renders via `ZoomableImageView` (pinch + double-tap zoom);
///     video renders via inline `AVKit.VideoPlayer` (commit 3 of the
///     brief swaps this for true-fullscreen).
///
/// ## Delete timing (Stage 4.2 commit 7 directive)
///
/// The card behind the sheet must NOT mutate while the viewer is up. We
/// achieve that by deferring the actual store-level delete until the
/// sheet has fully dismissed:
///
///   1. User taps Delete → confirmation dialog.
///   2. On confirm → `onRequestDelete(item)` callback fires; parent
///      (`GalleryBody`) stashes the ID in `pendingDeletion` @State.
///   3. Viewer calls `dismiss()` → sheet animates out.
///   4. `sheet(item:onDismiss:)` callback in `GalleryBody` fires AFTER
///      the dismiss animation completes → store delete runs there.
///   5. `@Observable` store notifies → `EntryCard` re-renders → if count
///      dropped 2→1, dispatch flips to `SingleMediaBody`.
///
/// User perceives: viewer fades out, then the entry updates to its new
/// state. No mid-sheet card mutation.
///
/// **Single delete per viewer session.** The viewer always dismisses on a
/// confirmed delete (even at count 3→2 where the gallery would still
/// exist). This keeps the timing rule simple and uniform; if the user
/// wants to delete more, they re-tap a tile to reopen at the new index.
///
/// ## Copy semantics
///
/// `Copy` writes a `UIImage` to `UIPasteboard.general` for image items.
/// Disabled for video items — `UIPasteboard` has no clean video-copy
/// affordance (the file URL would be in the iCloud sandbox and
/// unreachable to other apps), and the Share path handles video export
/// properly via the activity sheet.
struct GalleryFullscreenViewer: View {

    let galleryItems: [GalleryItem]
    let nodeID: String
    let parentItem: NodeItem
    let startIndex: Int
    /// Called when the user confirms deletion of an item. Parent must
    /// stash the ID and run the actual store delete in the sheet's
    /// `onDismiss` callback (see top-of-file delete-timing section).
    let onRequestDelete: (GalleryItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(CorpusStore.self) private var store

    @State private var currentIndex: Int
    @State private var pendingDelete: GalleryItem? = nil
    @State private var shareIdentity: ShareIdentity? = nil
    /// Per-page zoom flag, parallel to `galleryItems` by index. The current
    /// page's flag gates `.scrollDisabled` on the pager so paging only
    /// fires at zoom == 1 — when a page is zoomed in, horizontal drag
    /// pans the image instead of turning the page. Off-screen pages are
    /// reset to `false` defensively when `currentIndex` changes.
    @State private var pageZoomed: [Bool]

    init(
        galleryItems: [GalleryItem],
        nodeID: String,
        parentItem: NodeItem,
        startIndex: Int,
        onRequestDelete: @escaping (GalleryItem) -> Void
    ) {
        self.galleryItems = galleryItems
        self.nodeID = nodeID
        self.parentItem = parentItem
        self.startIndex = startIndex
        self.onRequestDelete = onRequestDelete
        // Clamp the start index defensively in case the gallery shrank
        // between the tap-emit and the sheet present (e.g., a concurrent
        // delete from elsewhere). Without this clamp, an out-of-range
        // currentIndex would render an empty pager with no recovery.
        let clamped = min(max(0, startIndex), max(0, galleryItems.count - 1))
        _currentIndex = State(initialValue: clamped)
        _pageZoomed = State(initialValue: Array(repeating: false, count: galleryItems.count))
    }

    private var currentItem: GalleryItem? {
        guard galleryItems.indices.contains(currentIndex) else { return nil }
        return galleryItems[currentIndex]
    }

    private var isCurrentPageZoomed: Bool {
        guard pageZoomed.indices.contains(currentIndex) else { return false }
        return pageZoomed[currentIndex]
    }

    /// Bridges the `Int` `currentIndex` to the `Binding<Int?>` shape that
    /// `.scrollPosition(id:)` requires. Nil writes (which the modifier
    /// can emit mid-scroll) are dropped — we never want to lose the
    /// active page index.
    private var scrollPositionBinding: Binding<Int?> {
        Binding(
            get: { currentIndex },
            set: { newValue in
                if let newValue { currentIndex = newValue }
            }
        )
    }

    private func pageZoomBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { pageZoomed.indices.contains(index) ? pageZoomed[index] : false },
            set: { newValue in
                guard pageZoomed.indices.contains(index) else { return }
                pageZoomed[index] = newValue
            }
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(galleryItems.enumerated()), id: \.element.id) { idx, gItem in
                            GalleryFullscreenPage(
                                galleryItem: gItem,
                                nodeID: nodeID,
                                parentItem: parentItem,
                                isZoomed: pageZoomBinding(for: idx)
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: scrollPositionBinding)
                // Paging-only-at-zoom==1: when the visible page is zoomed,
                // its inner UIScrollView swallows horizontal drag to pan
                // the image rather than the outer ScrollView paging.
                // (Validated in `briefs/spike-zoom-paging.md`.)
                .scrollDisabled(isCurrentPageZoomed)
            }
            .ignoresSafeArea()
            // Off-screen pages: clear any stale zoom flag so they don't
            // un-gate paging if the user lands back on them. The actual
            // UIScrollView zoom state on a recycled LazyHStack page will
            // re-fire `scrollViewDidZoom` and rewrite the flag if it's
            // still zoomed in when it scrolls back on.
            .onChange(of: currentIndex) { _, newIndex in
                for i in pageZoomed.indices where i != newIndex {
                    pageZoomed[i] = false
                }
            }

            VStack {
                topBar
                Spacer()
                if let current = currentItem {
                    bottomBar(for: current)
                }
            }
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                onRequestDelete(item)
                pendingDelete = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .sheet(item: $shareIdentity) { identity in
            ShareSheet(items: [identity.url])
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            chromeIconButton(systemImage: "xmark") { dismiss() }
            Spacer()
            Text("\(currentIndex + 1) / \(galleryItems.count)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
            Spacer()
            // Balance the close button so the index sits visually centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func bottomBar(for item: GalleryItem) -> some View {
        HStack(spacing: 24) {
            actionButton(systemImage: "square.and.arrow.up", label: "Share") {
                Task { await resolveAndShare(item) }
            }
            actionButton(systemImage: "doc.on.doc", label: "Copy") {
                Task { await resolveAndCopy(item) }
            }
            .disabled(item.mediaType == .video)
            .opacity(item.mediaType == .video ? 0.35 : 1.0)
            // hero-image v1 — image-only (mirrors Copy's video gate).
            // `item.file` IS the relative path so we skip the URL
            // resolve and hand it directly to the store. Sets without
            // dismissing — viewer-dismiss is reserved for Delete (see
            // top-of-file delete-timing section).
            actionButton(systemImage: "photo.badge.checkmark", label: "Set as Hero") {
                Task { await store.setCoverImage(relativePath: item.file, nodeID: nodeID) }
            }
            .disabled(item.mediaType == .video)
            .opacity(item.mediaType == .video ? 0.35 : 1.0)
            actionButton(systemImage: "trash", label: "Delete", tint: .red) {
                pendingDelete = item
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 22)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 24)
    }

    private func chromeIconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
        }
    }

    private func actionButton(
        systemImage: String,
        label: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(minWidth: 56)
        }
    }

    // MARK: - Actions

    private func resolveAndShare(_ item: GalleryItem) async {
        guard let url = await store.resolveGalleryItemURL(
            item,
            nodeID: nodeID,
            fallbackParentItem: parentItem
        ) else { return }
        await MainActor.run { shareIdentity = ShareIdentity(url: url) }
    }

    private func resolveAndCopy(_ item: GalleryItem) async {
        guard item.mediaType == .image,
              let url = await store.resolveGalleryItemURL(
                  item,
                  nodeID: nodeID,
                  fallbackParentItem: parentItem
              ) else { return }
        // Off-main decode — same pattern as `GalleryItemTile`. UIPasteboard
        // writes touch UIKit state so the assignment itself hops back to
        // main via MainActor.run.
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        guard let image else { return }
        await MainActor.run { UIPasteboard.general.image = image }
    }
}

/// One page inside the swipeable pager. Resolves its own sidecar URL
/// lazily on appear — keeps the viewer's open-time work bounded to the
/// initial page (others resolve as the user swipes through).
///
/// Image branch hosts a `ZoomableImageView`, which reports its own zoom
/// state up via the `isZoomed` binding so the outer pager can gate its
/// `.scrollDisabled`. Video branch stays inline (true-fullscreen lives
/// in commit 3 of `briefs/unified-media-viewer.md`).
private struct GalleryFullscreenPage: View {

    let galleryItem: GalleryItem
    let nodeID: String
    let parentItem: NodeItem
    @Binding var isZoomed: Bool

    @Environment(CorpusStore.self) private var store
    @State private var url: URL? = nil
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            Color.black
            if let url {
                switch galleryItem.mediaType {
                case .image:
                    if let image {
                        ZoomableImageView(image: image, isZoomed: $isZoomed)
                    } else {
                        ProgressView().tint(.white)
                    }
                case .video:
                    VideoPlayer(player: AVPlayer(url: url))
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: galleryItem.id) {
            url = await store.resolveGalleryItemURL(
                galleryItem,
                nodeID: nodeID,
                fallbackParentItem: parentItem
            )
            // Image decode off-main, same pattern as the in-card tile.
            if galleryItem.mediaType == .image, let url {
                let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return UIImage(data: data)
                }.value
                image = decoded
            }
        }
    }
}

/// Identity wrapper so `.sheet(item:)` re-presents cleanly if the user
/// taps Share multiple times for the same URL.
private struct ShareIdentity: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Identity wrapper for `GalleryBody`'s viewer-start state. Wrapping the
/// start index in an `Identifiable` lets us drive the sheet via
/// `.sheet(item:onDismiss:)`, which is the only sheet variant that
/// provides the `onDismiss` callback we need for deferred deletion.
struct GalleryViewerStart: Identifiable, Equatable {
    let id = UUID()
    let index: Int
}
