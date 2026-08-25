import SwiftUI
import PhotosUI

/// Stage 4.2 commit 4 — body slot for `.imageVideo` entries with `mediaItems
/// .count >= 2`. Hosts the chrome strip (the "+" add-more button on the
/// left, `ViewModeToggle` on the right) and a media area that branches on
/// the resolved view mode.
///
/// Two view modes: `.carousel` renders `GalleryHorizontalBento` (the vertical
/// bento's packer rotated 90° — columns across a fixed 220pt band; superseded
/// the original snap-to-tile carousel), `.bento` renders the vertical
/// `GalleryBento` (deterministic packed grid filling the card width). Both
/// share `GalleryItemTile` as the per-item primitive, sized externally by each
/// parent.
struct GalleryBody: View {

    let item: NodeItem
    let nodeID: String

    // ws-entry-containers — the gallery ALWAYS renders as the in-container heading
    // row (row 1 = displayName + a 3-thumb/count metadata stack); the media grid
    // folds beneath it. Rendered exclusively by `EntryCard` (mediaItems.count ≥ 2).
    var isExpanded: Bool = true
    var onToggleExpansion: () -> Void = {}
    var reorderActive: Bool = false
    var name: String = ""
    var nameFont: Font? = nil
    /// ws-entry-containers — the "..." options menu content + the reorder grip drag
    /// handle, both EntryCard-owned; forwarded straight to the spine row.
    var optionsMenu: AnyView? = nil
    var gripDragHandle: AnyView? = nil

    @Environment(CorpusStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingPicker = false
    /// #4 (launch list) — presents the drag-to-reorder sheet. The gallery's
    /// carousel/bento aren't Lists, so reordering happens in a modal List
    /// (the one place `.onMove` works); see `GalleryReorderSheet`.
    @State private var showingReorder = false
    /// Per-session aspect-ratio overrides keyed by `GalleryItem.id`. Tiles
    /// report their measured aspect on first load via
    /// `onMeasuredAspect`; the override takes precedence over the model's
    /// persisted `aspectRatio` during this session so layout updates
    /// immediately without waiting for the store's @Observable round-trip.
    /// Persistence is fire-and-forget alongside the override write — future
    /// sessions read the persisted value and skip the measurement.
    @State private var measuredAspects: [String: Double] = [:]
    /// Drives the tap-to-fullscreen swipeable viewer (commit 7). Holds the
    /// start index so the viewer opens on whichever tile the user tapped;
    /// cleared on dismiss.
    @State private var viewerStart: GalleryViewerStart? = nil
    /// Deferred-deletion buffer (commit 7). Set when the user confirms a
    /// per-item delete inside the viewer; the actual store delete runs in
    /// the sheet's `onDismiss` closure so the card behind the sheet
    /// doesn't mutate while the viewer is still visible. See
    /// `GalleryFullscreenViewer`'s top-of-file "Delete timing" section
    /// for the full sequence.
    @State private var pendingDeletion: String? = nil
    /// Import-failure surface — set when picked photos couldn't be copied (e.g.
    /// iCloud-hosted originals that failed to download). The import loop counts
    /// failures instead of silently dropping them.
    @State private var importFailureCount = 0
    @State private var showImportFailure = false

    private var galleryItems: [GalleryItem] { item.mediaItems ?? [] }

    /// Resolution of the active view mode — a FALLBACK, never a migration: it
    /// reads `item.viewMode` and only computes a default when it's nil. Nothing
    /// here writes back; a persisted value (from `appendMediaItems` /
    /// `addMediaItems` / an explicit toggle) always wins and is preserved.
    ///
    /// Default rule (T's call): ≤3 → strip, ≥4 → HORIZONTAL bento. Vertical bento
    /// is OPT-IN only — never auto-selected — because it's too disruptive to the
    /// efficient survey of a node to be a default. Un-set entries (nil viewMode —
    /// a migrated v1→v2 entry that grew via an uncovered path) take this default;
    /// their stored value stays nil (a default is not a write).
    private var effectiveViewMode: GalleryViewMode {
        if let viewMode = item.viewMode { return viewMode }
        return galleryItems.count <= 3 ? .carousel : .horizontalBento
    }

    var body: some View {
        // `GalleryBody` is only reached from `EntryCard` when `mediaItems.count >= 2`.
        // Belt-and-suspenders: 0/1 items → render nothing rather than feed the layout
        // planner degenerate input.
        if galleryItems.count >= 2 {
            container
        }
    }

    /// The in-container heading row on media. Row 1 (displayName + 3-thumb/count
    /// metadata) sits inside the SAME unified filled container as a note; the media
    /// grid folds beneath it at FULL container width (it does NOT owe the text
    /// margin). The container persists in both fold states; collapsed = row only.
    private var container: some View {
        galleryPresentations(
            VStack(alignment: .leading, spacing: 0) {
                EntrySpineRow(
                    name: name.isEmpty ? "Gallery" : name,
                    isPlaceholder: false,
                    isExpanded: isExpanded,
                    reorderActive: reorderActive,
                    nameFont: nameFont ?? .body,
                    onToggle: onToggleExpansion,
                    trailing: { galleryMetadata },
                    optionsMenu: optionsMenu,
                    gripDragHandle: gripDragHandle
                )
                if isExpanded {
                    galleryInner
                        .padding(.top, 10)   // reference `.grid { margin-top: 10 }`
                }
            }
            .entrySpineContainer()
        )
    }

    /// The media area + optional description + add/reorder/mode chrome. Shared by
    /// the legacy and spine renderings. Full container width (no text-margin indent).
    private var galleryInner: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaArea

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    .padding(.horizontal, 4)
            }

            MediaEntryChrome(
                onAdd: { showingPicker = true },
                accessibilityLabel: "Add more media"
            ) {
                HStack(spacing: 12) {
                    // #4 — reorder trigger. Mirrors the "+" button's shape so
                    // the chrome reads as one control cluster.
                    Button { showingReorder = true } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                            .frame(width: 32, height: 32)
                            .background(AppearancePalette.ink.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("Reorder media")

                    ViewModeToggle(active: effectiveViewMode) { newMode in
                        Task {
                            await store.setEntryViewMode(
                                itemID: item.id,
                                nodeID: nodeID,
                                viewMode: newMode
                            )
                        }
                    }
                }
            }
        }
    }

    /// SPIKE v3 — right-side metadata for a gallery spine (reference geometry).
    /// The 3-thumb overlap stack rides ONLY in the COLLAPSED row (it stands in for
    /// the hidden media); the EXPANDED row shows the count alone (the grid is right
    /// below it). Count is always present.
    private var galleryMetadata: some View {
        HStack(spacing: 6) {
            if !isExpanded { thumbstack }
            Text("\(galleryItems.count)")
                .font(.system(size: 12))
                .foregroundStyle(AppearancePalette.ink.opacity(0.30))
                .monospacedDigit()
        }
    }

    /// Collapsed-row thumbstack: 3 overlapping thumbs (19pt, r5, 1.5pt
    /// container-fill ring so overlaps don't collide — reference `margin-left:-7`).
    private var thumbstack: some View {
        let shown = Array(galleryItems.prefix(3))
        let thumb: CGFloat = 19
        let step: CGFloat = 12          // 19 thumb − 7 overlap
        // Ring = the container fill (app raised-panel surface) so overlaps read cut out.
        let ring = colorScheme == .dark
            ? AppearancePalette.bgElevated
            : Color(hexString: EntryContainerStyle.fillLightHex)
        return ZStack(alignment: .leading) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, gItem in
                GalleryItemTile(galleryItem: gItem, nodeID: nodeID, parentItem: item)
                    .frame(width: thumb, height: thumb)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(ring, lineWidth: 1.5)
                    )
                    .offset(x: CGFloat(idx) * step)
                    .zIndex(Double(shown.count - idx))
            }
        }
        // F2 — leading alignment: `.offset` doesn't grow the ZStack's intrinsic
        // width (19pt), so a default (center) frame would push the offset thumbs
        // PAST the frame's right edge, INTO the count. Leading pins thumb 0 at x=0
        // so the last thumb's right edge = the frame width (no overflow into count).
        .frame(width: thumb + CGFloat(max(shown.count - 1, 0)) * step, height: thumb,
               alignment: .leading)
    }

    /// The gallery's presentations (add-picker, reorder sheet, fullscreen viewer,
    /// import-failure alert). Applied by both renderings; only one is in the tree
    /// per instance (spine vs legacy) so the bindings never double-present.
    private func galleryPresentations<V: View>(_ content: V) -> some View {
        content
            .sheet(isPresented: $showingPicker) {
                MediaPickerWrapper { results in
                    Task { await handlePickedMedia(results) }
                }
            }
            .sheet(isPresented: $showingReorder) {
                GalleryReorderSheet(item: item, nodeID: nodeID)
                    .environment(store)
            }
            .fullScreenCover(item: $viewerStart, onDismiss: flushPendingDeletion) { start in
                GalleryFullscreenViewer(
                    galleryItems: galleryItems,
                    nodeID: nodeID,
                    parentItem: item,
                    startIndex: start.index,
                    onRequestDelete: { gItem in
                        // Stash the ID — the actual store delete runs in the
                        // dismiss callback above so the card behind the sheet
                        // can't mutate while the viewer is still visible.
                        pendingDeletion = gItem.id
                    }
                )
                .environment(store)
            }
            .alert("Couldn’t add \(importFailureCount) \(importFailureCount == 1 ? "item" : "items")",
                   isPresented: $showImportFailure) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("They may be stored in iCloud and need to be downloaded first. Try again once they’ve finished downloading.")
            }
    }

    /// Runs after the fullscreen viewer fully dismisses. If a per-item
    /// delete was requested, this is where it actually hits the store —
    /// so the dispatch flip (gallery → single on 2→1) lands on a card
    /// that's no longer covered by the sheet.
    private func flushPendingDeletion() {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        Task {
            await store.deleteGalleryItem(
                entryID: item.id,
                nodeID: nodeID,
                galleryItemID: id
            )
        }
    }

    // MARK: - Media area

    @ViewBuilder
    private var mediaArea: some View {
        switch effectiveViewMode {
        case .carousel:
            GalleryCarousel(
                galleryItems: galleryItems,
                nodeID: nodeID,
                parentItem: item,
                aspectFor: { aspectForTile($0) },
                onMeasuredAspect: { itemID, aspect in
                    recordMeasured(itemID: itemID, aspect: aspect)
                },
                onTapTile: openViewer
            )
        case .horizontalBento:
            GalleryHorizontalBento(
                galleryItems: galleryItems,
                nodeID: nodeID,
                parentItem: item,
                aspectFor: { aspectForTile($0) },
                onMeasuredAspect: { itemID, aspect in
                    recordMeasured(itemID: itemID, aspect: aspect)
                },
                onTapTile: openViewer
            )
        case .bento:
            GalleryBento(
                galleryItems: galleryItems,
                nodeID: nodeID,
                parentItem: item,
                aspectFor: { aspectForTile($0) },
                onMeasuredAspect: { itemID, aspect in
                    recordMeasured(itemID: itemID, aspect: aspect)
                },
                onTapTile: openViewer
            )
        }
    }

    /// Maps a tapped tile back to its index in `galleryItems` and opens
    /// the swipeable viewer at that position. No-op if the item isn't
    /// found (e.g., the gallery shrank between tap-emit and handler run);
    /// the viewer's init also clamps defensively.
    private func openViewer(_ tappedItem: GalleryItem) {
        guard let idx = galleryItems.firstIndex(where: { $0.id == tappedItem.id }) else { return }
        viewerStart = GalleryViewerStart(index: idx)
    }

    // MARK: - Aspect override pipeline

    /// In-session aspect for a tile, falling back through:
    ///   1. `measuredAspects[id]` — tile reported during this session.
    ///   2. `galleryItem.aspectRatio` — persisted from an earlier session.
    ///   3. `1.0` — square placeholder until the first measurement lands.
    /// Clamped to the bento brief's anticipated working range (0.3, 4.0) so
    /// a malformed/EXIF-mangled aspect can't produce a degenerate tile.
    private func aspectForTile(_ galleryItem: GalleryItem) -> Double {
        let raw = measuredAspects[galleryItem.id] ?? galleryItem.aspectRatio ?? 1.0
        return min(max(raw, 0.3), 4.0)
    }

    /// Records a tile's measured aspect both in the session override (so
    /// the next render uses it immediately) and on the persisted
    /// `GalleryItem` (so future sessions skip the measurement). Idempotent
    /// at the store layer — `setGalleryItemAspectRatio` no-ops if the
    /// stored value already matches.
    private func recordMeasured(itemID: String, aspect: Double) {
        measuredAspects[itemID] = aspect
        Task {
            await store.setGalleryItemAspectRatio(
                entryID: item.id,
                nodeID: nodeID,
                galleryItemID: itemID,
                aspectRatio: aspect
            )
        }
    }

    // MARK: - "+" handler (parity with SingleMediaBody)

    private func handlePickedMedia(_ results: [PHPickerResult]) async {
        guard !results.isEmpty else { return }

        var pending: [CorpusStore.PendingMediaItem] = []
        var failures = 0
        for result in results {
            let provider = result.itemProvider
            if MediaPickerWrapper.isImageProvider(provider) {
                // Copy the ORIGINAL bytes — no decode, no re-encode. The photo
                // keeps its source format (HEIC/JPEG/PNG/RAW) at full quality.
                if let (tmpURL, ext) = await MediaPickerWrapper.loadOriginalImageFile(from: provider) {
                    pending.append(.init(itemID: UUID().uuidString, mediaType: .image, sourceURL: tmpURL, fileExtension: ext))
                } else {
                    failures += 1   // e.g. iCloud-hosted original that failed to download
                }
            } else if let (tmpURL, ext) = await MediaPickerWrapper.loadVideo(from: provider) {
                pending.append(.init(itemID: UUID().uuidString, mediaType: .video, sourceURL: tmpURL, fileExtension: ext))
            } else {
                failures += 1
            }
        }

        // Never lose a picked item silently — surface the count (the prior code
        // `continue`d past failures with no user-visible signal).
        if failures > 0 {
            importFailureCount = failures
            showImportFailure = true
        }

        guard !pending.isEmpty else { return }
        await store.appendMediaItems(toEntryID: item.id, nodeID: nodeID, mediaItems: pending)
    }
}

/// Horizontal bento renderer — the `.horizontalBento` mode. The vertical bento's
/// packer rotated 90° (`BentoLayout.planHorizontal`): columns march across a
/// FIXED 220pt band, tall items get full-height columns, everything else stacks
/// two-deep. (The uniform STRIP is a separate mode — `.carousel` →
/// `GalleryCarousel`; both scroll horizontally and carry the scroll-edge fade.)
///
///   - **Fixed band = footprint invariant.** Always `bandHeight` (220, the
///     strip's tile height), so a gallery occupies the same height with 3 images
///     or 30 in ANY mode — nothing in the detail view shifts on toggle.
///   - **FREE SCROLL.** No paging/snap: columns are variable-width and this mode
///     exists to sweep the WHOLE gallery in one gesture.
///   - **Scroll-edge fade** at both ends, only when there's off-screen content.
///   - Reuses `GalleryItemTile` (parent-owned sizing), aspect resolution,
///     tap-to-lightbox, and per-tile chrome — nothing forked.
///
/// Plan recomputes each redraw (cheap + deterministic); a landing measurement
/// reflows in one pass. No GeometryReader — the band height is fixed.
private struct GalleryHorizontalBento: View {

    let galleryItems: [GalleryItem]
    let nodeID: String
    let parentItem: NodeItem
    let aspectFor: (GalleryItem) -> Double
    let onMeasuredAspect: (_ itemID: String, _ aspect: Double) -> Void
    let onTapTile: (GalleryItem) -> Void

    /// The fixed gallery band height (the retired carousel's `tileHeight`) — the
    /// footprint invariant across mode and count.
    private static let bandHeight: CGFloat = 220

    private var plan: BentoLayout.HorizontalPlan {
        BentoLayout.planHorizontal(
            items: galleryItems,
            columnHeight: Self.bandHeight,
            aspectFor: { aspectFor($0) }
        )
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BentoLayout.defaultGutter) {
                ForEach(Array(plan.columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: BentoLayout.defaultGutter) {
                        ForEach(column.indices, id: \.self) { itemIdx in
                            let galleryItem = galleryItems[itemIdx]
                            GalleryItemTile(
                                galleryItem: galleryItem,
                                nodeID: nodeID,
                                parentItem: parentItem,
                                showsCaption: true,
                                onMeasuredAspect: { aspect in
                                    onMeasuredAspect(galleryItem.id, aspect)
                                }
                            )
                            .frame(
                                width: column.width,
                                height: BentoLayout.tileHeight(
                                    forAspect: aspectFor(galleryItem),
                                    columnWidth: column.width
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                            .onTapGesture { onTapTile(galleryItem) }
                        }
                    }
                    .frame(width: column.width, height: Self.bandHeight)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: Self.bandHeight)
        .horizontalScrollEdgeFade()
    }
}

/// Uniform-height horizontal STRIP — the `.carousel` mode (restored as a distinct
/// mode alongside the horizontal bento, per T's 3-mode call). Snap-to-tile paging,
/// uniform 220pt `tileHeight`, aspect-driven widths. Restored verbatim from
/// `6d2a1a6`; the scroll-edge fade is the only addition (shared with the
/// horizontal bento).
private struct GalleryCarousel: View {

    let galleryItems: [GalleryItem]
    let nodeID: String
    let parentItem: NodeItem
    let aspectFor: (GalleryItem) -> Double
    let onMeasuredAspect: (_ itemID: String, _ aspect: Double) -> Void
    let onTapTile: (GalleryItem) -> Void

    /// Uniform tile height — matches the horizontal bento's band and the
    /// commit-4 placeholder so a mode toggle never reflows the entry card.
    private static let tileHeight: CGFloat = 220

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(galleryItems) { galleryItem in
                    GalleryItemTile(
                        galleryItem: galleryItem,
                        nodeID: nodeID,
                        parentItem: parentItem,
                        showsCaption: true,
                        onMeasuredAspect: { aspect in
                            onMeasuredAspect(galleryItem.id, aspect)
                        }
                    )
                    .frame(
                        width: Self.tileHeight * aspectFor(galleryItem),
                        height: Self.tileHeight
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                    .onTapGesture { onTapTile(galleryItem) }
                }
            }
            .padding(.horizontal, 2)
            .scrollTargetLayout()
        }
        .frame(height: Self.tileHeight)
        .scrollTargetBehavior(.viewAligned)
        .horizontalScrollEdgeFade()
    }
}

/// Scroll-edge fade for a HORIZONTAL `ScrollView` — subtle leading/trailing fades
/// implying off-screen content, DRIVEN BY SCROLL OFFSET (never always-on). The
/// leading fade appears only when scrolled away from the start; the trailing only
/// when content remains to the right; at rest with content that fits, NEITHER
/// shows. Implemented as a `.mask` (a horizontal gradient), NOT an overlay of a
/// background colour — the detail view behind isn't a flat fill, so an overlay
/// would band. Offset/size read via `onScrollGeometryChange` (no GeometryReader
/// wrapper). Shared by the strip and the horizontal bento (not the vertical bento).
private struct HorizontalScrollEdgeFade: ViewModifier {
    /// Baked fade width (single literal, no tuner).
    var fadeWidth: CGFloat = 24
    @State private var showLeading = false
    @State private var showTrailing = false

    private struct Edges: Equatable { var leading: Bool; var trailing: Bool }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edges.self) { geo in
                let eps: CGFloat = 1
                return Edges(
                    leading: geo.visibleRect.minX > eps,
                    trailing: geo.visibleRect.maxX < geo.contentSize.width - eps
                )
            } action: { _, e in
                showLeading = e.leading
                showTrailing = e.trailing
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle().fill(LinearGradient(
                        colors: showLeading ? [.clear, .white] : [.white, .white],
                        startPoint: .leading, endPoint: .trailing))
                        .frame(width: fadeWidth)
                    Rectangle().fill(.white)
                    Rectangle().fill(LinearGradient(
                        colors: showTrailing ? [.white, .clear] : [.white, .white],
                        startPoint: .leading, endPoint: .trailing))
                        .frame(width: fadeWidth)
                }
            }
    }
}

private extension View {
    func horizontalScrollEdgeFade() -> some View {
        modifier(HorizontalScrollEdgeFade())
    }
}

/// Stage 4.2 commit 6 — bento renderer. Wraps `BentoLayout` (the pure
/// algorithm) and reuses `GalleryItemTile` (parent-owned-sizing contract
/// from commit 5) so this struct's job is purely "consume a plan, draw the
/// rows."
///
/// The plan recomputes on every redraw — it's cheap and deterministic, and
/// recomputing means tile measurements (when a new aspect lands and
/// `aspectFor(_:)` returns a fresh value) reflow the grid in one render
/// pass without any explicit invalidation.
///
/// Width discovery: `.background { GeometryReader }` writes the container
/// width into `@State availableWidth`. The first render uses a placeholder
/// (cardWidth == 0 → empty plan → zero-height frame), the GeometryReader
/// fires, `availableWidth` updates, and the second render lays out for
/// real. SwiftUI handles the two-pass transparently; the only visible
/// effect is a single-frame "0 height" on first appearance, which is the
/// same behavior the carousel exhibits while its first tile loads.
private struct GalleryBento: View {

    let galleryItems: [GalleryItem]
    let nodeID: String
    let parentItem: NodeItem
    let aspectFor: (GalleryItem) -> Double
    let onMeasuredAspect: (_ itemID: String, _ aspect: Double) -> Void
    let onTapTile: (GalleryItem) -> Void

    @State private var availableWidth: CGFloat = 0

    private var plan: BentoLayout.Plan {
        BentoLayout.plan(
            items: galleryItems,
            cardWidth: availableWidth,
            aspectFor: { aspectFor($0) }
        )
    }

    var body: some View {
        VStack(spacing: BentoLayout.defaultGutter) {
            ForEach(Array(plan.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: BentoLayout.defaultGutter) {
                    ForEach(row.indices, id: \.self) { itemIdx in
                        let galleryItem = galleryItems[itemIdx]
                        GalleryItemTile(
                            galleryItem: galleryItem,
                            nodeID: nodeID,
                            parentItem: parentItem,
                            showsCaption: true,
                            onMeasuredAspect: { aspect in
                                onMeasuredAspect(galleryItem.id, aspect)
                            }
                        )
                        .frame(
                            width: BentoLayout.tileWidth(
                                forAspect: aspectFor(galleryItem),
                                rowHeight: row.height
                            ),
                            height: row.height
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .onTapGesture { onTapTile(galleryItem) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in
                        availableWidth = newValue
                    }
            }
        }
    }
}

/// #4 (launch list) — drag-to-reorder sheet for a gallery entry's media.
///
/// The in-card gallery renders as a horizontal carousel or a 2-D bento;
/// neither is a `List`, and SwiftUI's inline `.onMove` only works inside a
/// `List`. The app's other reorder idiom (`EntryReorderController`) is a
/// bespoke *vertical-list-only* drag controller and doesn't translate to a
/// horizontal strip or a 2-D grid. So reordering happens here, in a modal
/// `List` pinned to permanent edit mode — the one place `.onMove` applies —
/// with system drag handles.
///
/// `workingItems` is a local copy that drives the List, so a drag animates
/// immediately without waiting on the store's `@Observable` round-trip. Each
/// move persists the *resulting order* (by ID) via
/// `CorpusStore.setGalleryItemOrder` — one write per move, matching
/// `moveEntry`'s one-commit-per-reorder philosophy. The card behind the sheet
/// reflects the persisted order once the sheet dismisses.
private struct GalleryReorderSheet: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var workingItems: [GalleryItem]

    init(item: NodeItem, nodeID: String) {
        self.item = item
        self.nodeID = nodeID
        _workingItems = State(initialValue: item.mediaItems ?? [])
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(workingItems) { galleryItem in
                    reorderRow(galleryItem)
                }
                .onMove(perform: move)
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func reorderRow(_ galleryItem: GalleryItem) -> some View {
        HStack(spacing: 12) {
            GalleryItemTile(
                galleryItem: galleryItem,
                nodeID: nodeID,
                parentItem: item
            )
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(galleryItem.mediaType == .video ? "Video" : "Photo")
                .font(.body)
                .foregroundStyle(AppearancePalette.ink)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Applies the List's move to the local working copy (instant, smooth),
    /// then persists the new order by ID. Both stay in lock-step because the
    /// working copy starts equal to `mediaItems` and every move is applied to
    /// it before the ID snapshot is taken.
    private func move(from source: IndexSet, to destination: Int) {
        workingItems.move(fromOffsets: source, toOffset: destination)
        let orderedIDs = workingItems.map(\.id)
        Task {
            await store.setGalleryItemOrder(
                entryID: item.id,
                nodeID: nodeID,
                orderedIDs: orderedIDs
            )
        }
    }
}
