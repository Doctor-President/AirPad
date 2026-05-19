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
///   • Swipeable paging across all items via `TabView(.page)`.
///   • Per-item chrome at the bottom: Share / Copy / Delete.
///   • Top-of-view close button + index indicator (`3 / 7`).
///   • Image renders fit-to-screen with black letterbox; video renders
///     via `AVKit.VideoPlayer` (inline controls — scrub, play/pause).
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
        // currentIndex would render an empty TabView with no recovery.
        let clamped = min(max(0, startIndex), max(0, galleryItems.count - 1))
        _currentIndex = State(initialValue: clamped)
    }

    private var currentItem: GalleryItem? {
        guard galleryItems.indices.contains(currentIndex) else { return nil }
        return galleryItems[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(galleryItems.enumerated()), id: \.element.id) { idx, gItem in
                    GalleryFullscreenPage(
                        galleryItem: gItem,
                        nodeID: nodeID,
                        parentItem: parentItem
                    )
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

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

/// One page inside the swipeable TabView. Resolves its own sidecar URL
/// lazily on appear — keeps the viewer's open-time work bounded to the
/// initial page (others resolve as the user swipes through).
private struct GalleryFullscreenPage: View {

    let galleryItem: GalleryItem
    let nodeID: String
    let parentItem: NodeItem

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
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
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
