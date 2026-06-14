import SwiftUI
import AVKit
import UIKit

/// Stage 4.2 commit 7 — fullscreen viewer for `.imageVideo` entries.
/// Unified-media-viewer commit 2 (briefs/unified-media-viewer.md)
/// extended this from gallery-only to BOTH presentations: single-media
/// entries (`SingleMediaBody`) now present the same viewer with a
/// one-element `galleryItems` array, retiring the QuickLook-backed
/// `MediaFullscreenViewer`. The viewer assumes `galleryItems.count >= 1`
/// and clamps `startIndex` defensively (see `init`).
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
///     video renders a static poster + play button (Option A revision of
///     `briefs/media-viewer-chrome.md`). Tapping play presents
///     `FullscreenVideoPlayer` over the viewer as a modal AVPlayer —
///     keeps every pager page uniformly image-shaped so paging snap
///     targets stay uniform across mixed image+video galleries.
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
    /// Photos-style tap-to-toggle chrome (briefs/media-viewer-chrome.md).
    /// Both image and video poster pages flip this via their single-tap
    /// handlers; the play button on a poster page is a separate tap
    /// target that doesn't toggle.
    @State private var chromeVisible = true
    /// Set by a poster-page play tap → drives the `.fullScreenCover` that
    /// presents the modal AVPlayer. The pager itself never holds an
    /// AVPlayer (Option A — uniform image-shaped pages so paging snap
    /// targets stay uniform across mixed image+video galleries).
    @State private var playingItem: GalleryItem? = nil
    /// Gate for the one-shot initial scroll-position write. iOS 26 has a
    /// `.scrollTargetBehavior(.paging)` bug where a non-zero initial
    /// `.scrollPosition(id:)` value settles partially off-page; the
    /// workaround is to keep the position binding emitting `nil` during
    /// the first layout pass and flip it to the real index on the next
    /// runloop. `scrollPositionBinding` reads this flag.
    @State private var initialPositionApplied = false
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
    ///
    /// Until `initialPositionApplied` flips (one-shot in `.onAppear`),
    /// the getter returns `nil` so the scroll view doesn't try to
    /// position itself during the first (potentially mis-sized) layout
    /// pass. Workaround for iOS 26's paging-position-off bug; see
    /// `initialPositionApplied`.
    private var scrollPositionBinding: Binding<Int?> {
        Binding(
            get: { initialPositionApplied ? currentIndex : nil },
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

            // No GeometryReader: each page sizes itself with
            // `.containerRelativeFrame([.horizontal, .vertical])`, the
            // canonical iOS 17+ paging-page-size pattern. The scroll
            // container's stride and the page width are then guaranteed
            // to match, which is what `.scrollTargetBehavior(.paging)`
            // assumes. The earlier `GeometryReader { proxy.size.width }`
            // setup didn't guarantee that match, and on iOS 26 fed the
            // paging-position-off bug — pages landed partially scrolled.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(galleryItems.enumerated()), id: \.element.id) { idx, gItem in
                        GalleryFullscreenPage(
                            galleryItem: gItem,
                            nodeID: nodeID,
                            parentItem: parentItem,
                            isZoomed: pageZoomBinding(for: idx),
                            onSingleTap: {
                                withAnimation(.easeInOut) {
                                    chromeVisible.toggle()
                                }
                            },
                            onRequestPlay: { playingItem = gItem }
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
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
            .ignoresSafeArea()
            // One-shot: flip the scroll-position gate on the next runloop
            // so the binding transitions from `nil → currentIndex` AFTER
            // initial layout has settled the page sizes. On iOS 26, this
            // avoids the `.scrollTargetBehavior(.paging)` partial-page
            // settlement bug that fires when a non-zero initial
            // scrollPosition value is applied during the first layout.
            .onAppear {
                guard !initialPositionApplied else { return }
                DispatchQueue.main.async {
                    initialPositionApplied = true
                }
            }
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
                    .opacity(chromeVisible ? 1 : 0)
                    .animation(.easeInOut, value: chromeVisible)
                Spacer()
                // Option A unifies the action bar across types — video
                // pages are posters (no inline player chrome to occlude),
                // so the same bottom bar serves both. Per-action gating
                // (Copy / Set-Hero disabled for video) lives inside
                // `bottomBar(for:)`.
                if let current = currentItem {
                    bottomBar(for: current)
                        .opacity(chromeVisible ? 1 : 0)
                        .animation(.easeInOut, value: chromeVisible)
                }
            }
        }
        // Modal native player for video posters. AVPlayerViewController
        // gets the entire screen — its own transport, fullscreen, and PiP
        // surfaces all light up; nothing in the AirPad pager competes for
        // body taps. Dismissing returns to the poster page.
        .fullScreenCover(item: $playingItem) { item in
            FullscreenVideoPlayer(
                galleryItem: item,
                nodeID: nodeID,
                parentItem: parentItem
            )
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
        // Release the playback audio session when the viewer is torn down.
        // Per-page pauses already happen on scroll-off / disappear, but the
        // shared `.playback` category lingers active until something
        // deactivates it; doing it here frees other apps' audio routing
        // back up the moment the viewer is gone. See
        // `PlaybackAudioSession` for the why-it's-shared rationale.
        .onDisappear { PlaybackAudioSession.deactivate() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            chromeIconButton(systemImage: "xmark") { dismiss() }
            Spacer()
            Text("\(currentIndex + 1) / \(galleryItems.count)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .modifier(ViewerGlassCapsule())
            Spacer()
            // Balance the close-X so the index sits visually centered.
            // No video-only `•••` — actions live in the unified bottom bar.
            Color.clear.frame(width: 56, height: 56)
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
        .modifier(ViewerGlassCapsule())
        .padding(.bottom, 24)
    }

    private func chromeIconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .modifier(ViewerGlassCircle())
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
/// `.scrollDisabled`.
///
/// Video branch (Option A — revised media-viewer-chrome brief) renders a
/// static poster frame plus a centered play button. The play tap escalates
/// to a modal `AVPlayerViewController` (`FullscreenVideoPlayer`) presented
/// over the viewer; the pager itself never holds an `AVPlayer`. This makes
/// every pager page uniformly image-shaped so `.scrollTargetBehavior(.paging)`
/// snap targets stay uniform across mixed image+video galleries (the
/// inline-player version sized differently and produced half-paged swipes).
private struct GalleryFullscreenPage: View {

    let galleryItem: GalleryItem
    let nodeID: String
    let parentItem: NodeItem
    @Binding var isZoomed: Bool
    /// Background-tap → toggle viewer chrome. Wired for both image pages
    /// (via `ZoomableImageView`'s tap-with-double-tap-fail recognizer) and
    /// video poster pages (via a transparent overlay below the play button).
    let onSingleTap: () -> Void
    /// Play tap on the video poster → escalate to the modal player. Image
    /// pages never call this.
    let onRequestPlay: () -> Void

    @Environment(CorpusStore.self) private var store
    @State private var url: URL? = nil
    /// Decoded full-size still for image items; first-frame poster for video
    /// items (`MediaThumbnailLoader` reuses the cache the tile grid populates).
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            Color.black
            if url != nil {
                switch galleryItem.mediaType {
                case .image:
                    if let image {
                        ZoomableImageView(
                            image: image,
                            isZoomed: $isZoomed,
                            onSingleTap: onSingleTap
                        )
                    } else {
                        ProgressView().tint(.white)
                    }
                case .video:
                    videoPosterPage
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
            guard let url else { return }
            switch galleryItem.mediaType {
            case .image:
                // Image decode off-main, same pattern as the in-card tile.
                let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return UIImage(data: data)
                }.value
                image = decoded
            case .video:
                // First-frame poster. The loader is an actor with a
                // process-lifetime cache shared with `GalleryItemTile`, so a
                // video the user has already seen as a tile hits warm cache.
                image = await MediaThumbnailLoader.shared.thumbnail(for: url)
            }
        }
    }

    /// Static poster + centered liquid-glass play button. The poster fills
    /// the page with `.scaledToFit()` to match the image branch's framing,
    /// so swiping between an image and a video page doesn't visibly shift
    /// content geometry. A transparent rectangle behind the play button
    /// captures background taps for chrome toggle; the Button itself is on
    /// top and absorbs taps within its own bounds.
    private var videoPosterPage: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }
            // Tap-to-toggle-chrome on the poster background. Sits below
            // the Button in the ZStack so the play button wins inside its
            // own frame — and outside the button, this catches the tap.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onSingleTap() }
            Button {
                onRequestPlay()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    // Nudge the glyph optically right — `play.fill` is
                    // visually weighted left because of its triangle.
                    .offset(x: 3)
                    .frame(width: 72, height: 72)
                    .modifier(ViewerGlassCircle())
            }
        }
    }
}

/// Modal AVPlayer presented over the viewer when the user taps a poster's
/// play button. Owns the `AVPlayer` for its lifetime; auto-plays on appear
/// and pauses on dismiss. Audio session is configured here (and released
/// by the outer viewer's `.onDisappear`) so `VoiceCaptureSheet` can't
/// silently mute playback. See `PlaybackAudioSession`.
///
/// **Dismiss model:** native swipe-down (the iOS fullscreen-media
/// convention). No custom close-X — `AVPlayerViewController` puts AirPlay
/// in the top-left of its native chrome and a custom X collides with it
/// visually. The swipe-down `DragGesture` is attached via
/// `.simultaneousGesture` so it coexists with the player's own UIKit
/// gestures (transport scrubber, tap-to-show-controls). A direction guard
/// (`dy > 80 && dy > dx * 2`) keeps horizontal scrubbing from firing the
/// dismiss path.
private struct FullscreenVideoPlayer: View {

    let galleryItem: GalleryItem
    let nodeID: String
    let parentItem: NodeItem

    @Environment(\.dismiss) private var dismiss
    @Environment(CorpusStore.self) private var store
    @State private var player: AVPlayer? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayerRepresentable(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    let dy = value.translation.height
                    let dx = abs(value.translation.width)
                    // Vertical-dominant downward drag past threshold →
                    // dismiss. The horizontal-dominance check (`dy > dx * 2`)
                    // keeps the player's horizontal scrubber gesture from
                    // accidentally firing this path.
                    if dy > 80 && dy > dx * 2 {
                        dismiss()
                    }
                }
        )
        .task(id: galleryItem.id) {
            let resolved = await store.resolveGalleryItemURL(
                galleryItem,
                nodeID: nodeID,
                fallbackParentItem: parentItem
            )
            guard let resolved else { return }
            _ = PlaybackAudioSession.configure()
            let p = AVPlayer(url: resolved)
            player = p
            p.play()
        }
        .onDisappear {
            // Pause on dismiss; leave the audio session active so a
            // subsequent play during the same viewer session doesn't have
            // to renegotiate the category. The outer
            // `GalleryFullscreenViewer.onDisappear` calls
            // `PlaybackAudioSession.deactivate()` when the viewer fully
            // closes.
            player?.pause()
        }
    }
}

/// Liquid-glass treatment for the viewer's chrome, mirroring the detail
/// view's custom toolbar (`NodeDetailView`'s `InteractiveGlassCircle` /
/// `InteractiveGlassCapsule`, declared private there). Duplicated here
/// rather than promoted to a shared module — both call-sites are still
/// the only two using this pattern and the brief asked for lean.
///
/// iOS 26 gets the real `.glassEffect(.regular.interactive(), in:)`
/// lensing; earlier targets fall back to `.ultraThinMaterial`.
private struct ViewerGlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(Circle().fill(.ultraThinMaterial))
        }
    }
}

private struct ViewerGlassCapsule: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(Capsule().fill(.ultraThinMaterial))
        }
    }
}

/// `UIViewControllerRepresentable` wrapper around `AVPlayerViewController`
/// — the native fullscreen + PiP-capable host used by `FullscreenVideoPlayer`
/// when the user taps a poster's play button. Distinct from SwiftUI's
/// `VideoPlayer`, which is also AVKit-backed but doesn't surface the
/// fullscreen button.
///
/// Configures the shared playback audio session in `makeUIViewController`
/// so a session left in `.record` by `VoiceCaptureSheet` can't silently
/// mute video. `PlaybackAudioSession.configure` is idempotent.
///
/// The player itself is owned by the parent `FullscreenVideoPlayer` so it
/// can pause on dismiss without reaching into the view controller.
private struct VideoPlayerRepresentable: UIViewControllerRepresentable {

    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        _ = PlaybackAudioSession.configure()
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
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
