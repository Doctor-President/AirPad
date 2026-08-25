import SwiftUI
import UIKit

/// Stage 3.1a commit (b) Phase 3 — the entry primitive. Wraps a typed body
/// (`*EntryBody`) in uniform card chrome: title row with display name +
/// chevron + ellipsis menu, then the body when expanded. One card per entry,
/// regardless of type — the unified surface that replaces the legacy
/// per-type row treatments in `NodeDetailView.ItemRow`.
///
/// Visual contract (from the Stage 3.1a brief):
///   - 12pt corner radius
///   - `secondarySystemBackground` fill
///   - 12pt internal padding
///   - 44pt minimum title-row height
///   - chevron.down (expanded) / chevron.right (collapsed)
///   - no shadow
///
/// Stage 3.1b — the long-press gesture is now wired to the
/// `EntryReorderController` injected via Environment. Long-press on a card
/// chrome → controller lifts the card → drag tracks via translation →
/// release commits a single `CorpusStore.moveEntry` (the snapshot pattern,
/// per close-note in `sounding-board/2026-05-17-stage-3-1b-reorder-cleanup-close.md`).
struct EntryCard: View {

    let item: NodeItem
    let nodeID: String
    /// Index of this card within `node.items`. Required for the reorder
    /// controller's parting math — the controller works in snapshot-index
    /// space, not card-id space, so this card has to tell it where it sits.
    let index: Int
    /// All item IDs in the node, in current display order. Passed down so
    /// the long-press path can snapshot without re-reading the store.
    let snapshotIDs: [String]
    /// Backlinks v1 — fired by the entry's "Backlink" menu action; the parent
    /// (`NodeDetailView`) presents the picker anchored on this entry. Nil (e.g.
    /// in QuikCapture) hides the menu item entirely.
    let onBacklink: (() -> Void)?

    @Environment(CorpusStore.self) private var store
    @Environment(EntryReorderController.self) private var reorder

    /// Stage 4.4 — dev-only runtime visual settings (corner radius, body
    /// treatment, typography). The singleton is `@Observable`, so SwiftUI
    /// re-renders the card when any toggle changes. Commit 2 of Stage 4.4
    /// replaces these reads with `EntryCardMetrics` production constants
    /// and commit 3 deletes the settings file along with the dev panel.
    @State private var visualSettings = EntryVisualSettings.shared

    /// Local mirror of `item.isExpanded` so the chevron toggles instantly,
    /// independent of the persistence round-trip through the store. Kept in
    /// sync via `.onChange` against the model.
    @State private var isExpanded: Bool

    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var showDeleteConfirmation = false

    init(item: NodeItem, nodeID: String, index: Int, snapshotIDs: [String], onBacklink: (() -> Void)? = nil) {
        self.item = item
        self.nodeID = nodeID
        self.index = index
        self.snapshotIDs = snapshotIDs
        self.onBacklink = onBacklink
        self._isExpanded = State(initialValue: item.isExpanded ?? true)
    }

    private var displayName: String {
        // The note primitive shows "Note" as its default label. View-only — the
        // stored type/schema is unchanged, and migrated notes may carry the old
        // "Text" default, so treat that as unnamed too. Custom names pass through.
        if item.type == .text,
           item.displayName == nil || item.displayName == item.type.defaultDisplayName {
            return "Note"
        }
        return item.displayName ?? item.type.defaultDisplayName
    }

    /// ws-entry-containers — types whose spine row is BODY-owned because row 1
    /// carries body-specific content: a Note's name is its editor's first
    /// paragraph (Model C); a multi-media Gallery's collapsed row carries the
    /// 3-thumb stack. These call their body directly (the body renders the
    /// container). Everything else that wears the idiom uses the generic
    /// EntryCard-owned container below.
    private var bodyOwnsContainer: Bool {
        switch item.type {
        case .text:       return true
        case .imageVideo: return (item.mediaItems?.count ?? 0) >= 2
        default:          return false
        }
    }

    /// ws-entry-containers (step 3) — types whose body is a PURE content renderer
    /// (no self-container). EntryCard wraps them in the shared generic spine
    /// container: row 1 = displayName + type metadata (count / duration), the
    /// body folds full-width below. Links, Documents, Voice, single media
    /// (single `.imageVideo`, plus legacy `.image` / `.video`). `.chats` keeps
    /// the legacy `EntryTitleRow`; atomics are filtered out upstream.
    private var wearsGenericContainer: Bool {
        switch item.type {
        case .link, .document, .audio, .image, .video: return true
        case .imageVideo:  return (item.mediaItems?.count ?? 0) <= 1   // single media
        default:           return false
        }
    }

    /// Any container-idiom entry (body-owned or generic) — drives the flush
    /// vertical rhythm (the filled container self-separates; the inter-card gap
    /// comes from the list spacing, not per-card padding).
    private var wearsContainer: Bool { bodyOwnsContainer || wearsGenericContainer }

    /// Force-collapsed during reorder mode so every card renders as a
    /// uniform-height title row, which is what the controller's slotPitch
    /// math assumes. Restored to user-set expansion when reorder exits.
    private var effectiveExpansion: Bool {
        reorder.isReorderActive ? false : isExpanded
    }

    /// True when this card sits inside the promoted "card view" region
    /// (`index < node.foldIndex`). Drives the `onPromote` menu label flip
    /// in `EntryTitleRow` and the toggle direction in `togglePromote()`.
    /// Read from the live store so the label re-evaluates on each render
    /// after a promote/demote mutation.
    private var isAboveFold: Bool {
        guard let node = store.nodes.first(where: { $0.id == nodeID }) else { return false }
        return index < node.effectiveFoldIndex
    }

    /// Stage 4.8 — count of atomic items at the front of `node.items`.
    /// The reorder controller's snapshot is payload IDs only, so its
    /// `(from, to)` are in payload-relative space; converting back to
    /// raw `node.items` indices for `applyMoveEntry` is `+ atomicCount`.
    /// Derived from the live store on each access so it tracks
    /// rating adds/removes without needing the parent to pass it down.
    private var atomicCount: Int {
        guard let node = store.nodes.first(where: { $0.id == nodeID }) else { return 0 }
        return node.items.prefix(while: { $0.type.isAtomic }).count
    }

    /// ws-entry-containers (4b) — the reorder drag handle, RELOCATED from the
    /// card background onto the ⠿ GRIP (long-press only, collapsed rows). The
    /// card-wide recognizer is gone, so the name/body are single-purpose (T's
    /// gesture split, 2026-08-24): a drag is initiated ONLY from the grip.
    /// Callbacks are unchanged from the Stage-3.1b reorder path.
    var dragRecognizer: some View {
        LongPressDragRecognizer(
            onLift: { touchY in
                reorder.lift(itemID: item.id, snapshotIDs: snapshotIDs)
                // Seed the touch-Y so the AutoScrollDriver has a
                // valid reading before the first `.changed` fires.
                // Without this, lifting near an edge and holding
                // still would never engage auto-scroll.
                reorder.updateDrag(translationY: 0, touchWindowY: touchY)
            },
            onChange: { translationY, touchY in
                reorder.updateDrag(translationY: translationY, touchWindowY: touchY)
            },
            onEnd: {
                guard let (from, to, slotDelta) = reorder.release() else { return }
                // Apply the in-memory reorder and the drag-offset
                // compensation in the SAME synchronous @MainActor
                // tick. SwiftUI batches both @Observable mutations
                // into one render, so the lifted card's visible
                // position is unchanged across the array reflow.
                //
                // Splitting these with an `await` (the prior shape:
                // `await store.moveEntry` then compensate) let
                // SwiftUI commit one frame with the new array order
                // but uncompensated dragTranslation while the disk
                // save was in flight — visible as a slotPitch ×
                // slotDelta flash before the landing animation,
                // which is why Apple's Notes/Reminders are
                // jolt-free: the reorder and the offset adjustment
                // are atomic to the view system.
                //
                // Stage 4.8 — the reorder controller's snapshot
                // is payload IDs only, so `from` / `to` arrive in
                // payload-relative index space. `applyMoveEntry`
                // operates on raw `node.items` indices, so we
                // shift by `atomicCount` (the size of the atomic
                // prefix at the front of `node.items`).
                //
                // Stage 4.8 Commit C — fold-aware release. Snap
                // the fold boundary in payload-relative space
                // *before* any mutation so the membership check
                // uses the same coordinates as `from` / `to`.
                // `normalizeAtomicsToFront` guarantees
                // `foldIndex ≥ atomicCount`, so `payloadFold ≥
                // 0`. A drag that crosses the line shifts the
                // boundary by ±1; same-zone drags leave it
                // alone (pure reorder). `togglePromote` is the
                // menu-path counterpart of this logic — same
                // applyMoveEntry + setFoldIndex same-tick
                // pattern, just driven by a tap instead of a
                // release.
                guard let preNode = store.nodes.first(where: { $0.id == nodeID }) else {
                    reorder.exit()
                    return
                }
                let prefix = atomicCount
                let payloadFold = preNode.effectiveFoldIndex - prefix
                let foldDelta: Int
                if from >= payloadFold && to < payloadFold {
                    foldDelta = 1   // below → above (promote)
                } else if from < payloadFold && to >= payloadFold {
                    foldDelta = -1  // above → below (demote)
                } else {
                    foldDelta = 0   // same-zone reorder
                }

                guard let moved = store.applyMoveEntry(
                    nodeID: nodeID,
                    from: from + prefix,
                    to: to + prefix
                ) else {
                    reorder.exit()
                    return
                }

                // Same @MainActor tick as the move so SwiftUI
                // batches the array reflow and the fold change
                // into one render — no one-frame flash of the
                // card in the wrong zone. `setFoldIndex`
                // clamps the upper bound to `items.count`; we
                // clamp the lower bound to `prefix` here so
                // the fold never enters the atomic prefix
                // (the ±1 rule already keeps it in range, but
                // this is the single enforcement point).
                // `slotDelta` / `compensateForReorder` are
                // visual offset compensation only — not
                // entangled with the fold.
                let latest: Node
                if foldDelta != 0 {
                    let rawFold = preNode.effectiveFoldIndex + foldDelta
                    let clamped = max(prefix, rawFold)
                    latest = store.setFoldIndex(clamped, nodeID: nodeID) ?? moved
                } else {
                    latest = moved
                }

                reorder.compensateForReorder(slotDelta: slotDelta)
                Task {
                    // Persist asynchronously; yield one render so
                    // the compensated frame commits before exit()
                    // triggers the landing animation from the
                    // compensated value to 0.
                    await store.persistNode(latest)
                    await Task.yield()
                    reorder.exit()
                }
            },
            scrollDeltaProvider: { reorder.scrollDelta }
        )
    }

    var body: some View {
        let presentation = reorder.presentation(forItemID: item.id, atIndex: index)
        VStack(alignment: .leading, spacing: 0) {
            // Stage 4.8 — atomic types (rating; cook time / serving
            // size later) are filtered out of the payload list at the
            // `NodeDetailView` ForEach layer and render in a separate
            // pinned Attributes section (Commit B), so this card never
            // receives an atomic item in practice. The `EntryTitleRow`
            // / `bodyView` path is the only shape EntryCard renders.
            // The hairline below (added by `NodeDetailView`) and the
            // fold-boundary divider (also added by `NodeDetailView`)
            // both sit at the outer view layer, not the row body.
            if bodyOwnsContainer {
                // ws-entry-containers — Note + multi-media Gallery own their
                // container (TextEntryBody / GalleryBody) because row 1 carries
                // body-specific content. The container renders in BOTH fold
                // states; its body folds beneath row 1. No external EntryTitleRow
                // chrome, and — unlike a normal entry — it is NOT gated on
                // expansion (row 1 must persist when collapsed).
                switch item.type {
                case .text:
                    TextEntryBody(
                        item: item, nodeID: nodeID,
                        isExpanded: effectiveExpansion,
                        onToggleExpansion: toggleExpansion,
                        reorderActive: presentation.reorderActive,
                        headingFont: visualSettings.sectionTitle.resolvedFont(),
                        optionsMenu: AnyView(entryOptionsMenu),
                        gripDragHandle: AnyView(dragRecognizer)
                    )
                case .imageVideo:
                    GalleryBody(
                        item: item, nodeID: nodeID,
                        isExpanded: effectiveExpansion,
                        onToggleExpansion: toggleExpansion,
                        reorderActive: presentation.reorderActive,
                        name: displayName,
                        nameFont: visualSettings.sectionTitle.resolvedFont(),
                        optionsMenu: AnyView(entryOptionsMenu),
                        gripDragHandle: AnyView(dragRecognizer)
                    )
                default:
                    EmptyView()
                }
            } else if wearsGenericContainer {
                // ws-entry-containers (step 3) — pure-content bodies wrapped in
                // the shared generic container (Links / Documents / Voice / single
                // media). Row 1 + metadata is EntryCard-owned; the body is unchanged.
                genericContainer(reorderActive: presentation.reorderActive)
            } else {
            EntryTitleRow(
                displayName: displayName,
                timestamp: item.updatedAt ?? item.createdAt,
                isExpanded: effectiveExpansion,
                reorderActive: presentation.reorderActive,
                isAboveFold: isAboveFold,
                titleFont: visualSettings.sectionTitle.resolvedFont(),
                timestampFont: visualSettings.sectionTimestamp.resolvedFont(),
                onToggle: toggleExpansion,
                onPromote: togglePromote,
                onRename: beginRename,
                onDuplicate: duplicate,
                onCopy: copyContent,
                onBacklink: onBacklink,
                onChangeType: {},
                onReorder: enterReorderModeViaMenu,
                onDelete: { showDeleteConfirmation = true },
                // hero-image v1 — surface "Set as Hero Image" only on
                // standalone `.image` entries that actually have a
                // resolvable file. `.imageVideo` entries (both single
                // and multi) reach the hero through
                // `GalleryFullscreenViewer`'s bottom bar — single-media
                // entries route there too as of unified-media-viewer
                // commit 2.
                onSetAsHero: (item.type == .image && item.file != nil)
                    ? { [file = item.file!, nodeID] in
                        Task { await store.setCoverImage(relativePath: file, nodeID: nodeID) }
                    }
                    : nil,
                isNote: item.type == .text
            )
            .transition(.opacity)

            if effectiveExpansion {
                bodyView
                    .padding(.top, 8)
            }
            }
        }
        // #15 (T-dialed) — entry cards sit FLUSH with the 20pt title column
        // (NodeDetailView `.padding(20)`); the prior 12pt inset made every entry
        // read narrower than the title. 0 aligns each card's left edge to the
        // title and to its siblings. Outer gutter only — the note's internal
        // text padding (TextEntryBody 22pt) is untouched.
        .padding(.horizontal, 0)
        // SPIKE v3 — spine-type entries carry their OWN filled container (which
        // self-separates via fill + shadow), so the outer vertical padding is
        // dropped; the inter-container gap comes purely from the list spacing
        // (reference ~16pt gap). Non-container types keep the original rhythm.
        .padding(.vertical, wearsContainer ? 0 : (item.type == .text ? visualSettings.noteVerticalPadding : visualSettings.cardVerticalPadding))
        .scaleEffect(presentation.isLifted ? EntryReorderController.liftedScale : 1.0)
        .shadow(
            color: .black.opacity(presentation.isLifted ? EntryReorderController.liftedShadowOpacity : 0),
            radius: presentation.isLifted ? EntryReorderController.liftedShadowRadius : 0,
            y: presentation.isLifted ? EntryReorderController.liftedShadowOffsetY : 0
        )
        .offset(y: presentation.offsetY)
        .zIndex(presentation.isLifted ? 1 : 0)
        // Lifted card tracks the finger directly (no animation, no lag).
        // Every other card animates: parting offsets slide in smoothly,
        // and the landing on release (when isLifted flips back to false)
        // also catches this animation policy for the formerly-lifted card.
        .animation(
            presentation.isLifted
                ? nil
                : .easeInOut(duration: EntryReorderController.landingAnimationDuration),
            value: presentation.offsetY
        )
        .onChange(of: item.isExpanded) { _, newValue in
            // Keep local state in sync if the model changes from elsewhere
            // (e.g. another device in a future sync world, or a programmatic
            // bulk collapse). Today this is effectively defensive.
            if let newValue, newValue != isExpanded {
                isExpanded = newValue
            }
        }
        .alert("Rename entry", isPresented: $showRenameAlert) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { applyRename() }
        } message: {
            Text("Give this entry a name that helps you find it later.")
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the entry from the node. Can't be undone.")
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch item.type {
        case .text:     TextEntryBody(item: item, nodeID: nodeID)
        case .audio:    VoiceEntryBody(item: item, nodeID: nodeID)
        case .image:    ImageEntryBody(item: item, nodeID: nodeID)
        case .video:    VideoEntryBody(item: item, nodeID: nodeID)
        case .chats:    ChatsEntryBody(item: item, nodeID: nodeID)
        case .link:
            // Stage 4.5 commit 3 — count-based dispatch on linkItems:
            //   ≥2    → `LinkGalleryBody` (chrome shell + carousel +
            //           grid-placeholder; commit 4 lands the proper
            //           2-col grid + per-tile menu)
            //   1/0/nil → `LinkEntryBody` (preserves State A TextField
            //           when `linkItems` is nil so in-progress URL
            //           entry keeps working; renders the lifted /
            //           legacy single-link card otherwise)
            let linkCount = item.linkItems?.count ?? 0
            if linkCount >= 2 {
                LinkGalleryBody(item: item, nodeID: nodeID)
            } else {
                LinkEntryBody(item: item, nodeID: nodeID)
            }
        case .document:
            // Stage 4.6 commit 3 — count-based dispatch on `documentItems`:
            //   ≥2    → `DocumentGalleryBody` (carousel + chrome "+";
            //           the carousel/grid toggle and grid renderer land
            //           in C4 together)
            //   1/0/nil → `DocumentEntryBody` (single-doc renderer with
            //           thumbnail-less title row; reads documentItems[0]
            //           when present, falls back to legacy `file`)
            let documentCount = item.documentItems?.count ?? 0
            if documentCount >= 2 {
                DocumentGalleryBody(item: item, nodeID: nodeID)
            } else {
                DocumentEntryBody(item: item, nodeID: nodeID)
            }
        case .imageVideo:
            // Stage 4.2 commit 4 — dispatch on `mediaItems.count`:
            //   1     → `SingleMediaBody` (commit 3)
            //   ≥2    → `GalleryBody` (this commit; chrome shell + carousel/
            //           bento placeholder media area until commits 5/6)
            //   0/nil → `EmptyMediaPlaceholder` (T14 malformed-legacy path)
            // The count==1 → count==2 transition flips the dispatch on the
            // next render after `appendMediaItems` returns; the
            // first-transition viewMode default is already in place at
            // that point (written inside `appendMediaItems`).
            let count = item.mediaItems?.count ?? 0
            if count >= 2 {
                GalleryBody(item: item, nodeID: nodeID)
            } else if count == 1 {
                SingleMediaBody(item: item, nodeID: nodeID)
            } else {
                EmptyMediaPlaceholder()
            }
        case .rating, .field:
            // Atomic — rating and fields render in the pinned Attributes
            // section (`AttributesSection`), not in the payload list.
            // `NodeDetailView` filters atomics out of the payload ForEach so
            // this branch is unreachable; present only to satisfy switch
            // exhaustiveness.
            EmptyView()
        }
    }

    // MARK: - Generic container (ws-entry-containers step 3)

    /// ws-entry-containers (grip menu) — the shared entry-level options,
    /// relocated from the retired `EntryTitleRow` `…` into the grip and passed to
    /// EVERY container type (Notes prepend Read Aloud in `TextEntryBody`): promote ·
    /// set-hero (standalone image only) · rename · duplicate · copy · backlink ·
    /// change-type (disabled stub) · delete.
    ///
    /// "Reorder" is DELIBERATELY omitted (T, 2026-08-24): the menu-path
    /// `.engaged` state is under-communicated + redundant with the working
    /// hold-to-drag path, so it read as a dead item. Reordering is hold-drag on
    /// the card; item 4b owns the reorder-from-collapsed redesign + the stale
    /// `slotPitch` (92 → ~68 for container metrics). The legacy `EntryTitleRow`
    /// (`.chats` only) keeps its Reorder item untouched.
    @ViewBuilder
    private var entryOptionsMenu: some View {
        Button(isAboveFold ? "Remove from card" : "Show on card", action: togglePromote)
        if item.type == .image, let file = item.file {
            Button("Set as Hero Image") {
                Task { await store.setCoverImage(relativePath: file, nodeID: nodeID) }
            }
        }
        Divider()
        Button("Rename", action: beginRename)
        Button("Duplicate", action: duplicate)
        Button("Copy", action: copyContent)
        if let onBacklink {
            Button("Backlink", systemImage: "link", action: onBacklink)
        }
        Button("Change type", action: {}).disabled(true)
        Divider()
        Button("Delete", role: .destructive) { showDeleteConfirmation = true }
    }

    /// The shared container for pure-content bodies (Links / Documents / Voice /
    /// single media). Row 1 = chevron + displayName + type metadata + a
    /// visual-only grip (the full options menu lands in the grip step); the body
    /// renders at FULL container width (like the gallery grid — the app's rich
    /// preview blocks read better full-bleed than the reference's indented text
    /// rows) and folds beneath row 1. The body is the existing per-type
    /// `bodyView`, unchanged; only chrome moves to the container.
    @ViewBuilder
    private func genericContainer(reorderActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            EntrySpineRow(
                name: displayName,
                isPlaceholder: false,
                isExpanded: effectiveExpansion,
                reorderActive: reorderActive,
                nameFont: visualSettings.sectionTitle.resolvedFont(),
                onToggle: toggleExpansion,
                trailing: { spineMetadata },
                optionsMenu: AnyView(entryOptionsMenu),
                gripDragHandle: AnyView(dragRecognizer)
            )
            if effectiveExpansion {
                bodyView
                    .padding(.top, 10)   // reference `.body { margin-top: 10 }`
            }
        }
        .entrySpineContainer()
    }

    /// Right-side metadata for a generic-container spine (reference `.meta`):
    /// link / document COUNT (only for a true collection, ≥2 — a single link/doc
    /// carries none, matching EntryCard's ≥2 gallery dispatch), Voice DURATION
    /// (m:ss). Single media carries none.
    @ViewBuilder
    private var spineMetadata: some View {
        switch item.type {
        case .link:
            if let n = item.linkItems?.count, n >= 2 { metaLabel("\(n)") }
        case .document:
            if let n = item.documentItems?.count, n >= 2 { metaLabel("\(n)") }
        case .audio:
            if let seconds = item.durationSeconds, seconds > 0 {
                metaLabel(Self.durationString(seconds))
            }
        default:
            EmptyView()
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AppearancePalette.ink.opacity(0.30))
            .monospacedDigit()
    }

    /// m:ss for a Voice entry's duration meta (reference `2:41`).
    private static func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Reorder entry (menu path)

    /// Menu-path entry into reorder mode: engages the controller without
    /// lifting any card. User then long-presses to lift. "Done" toolbar
    /// item is the exit ramp (no card lifted ⇒ no release auto-commit).
    private func enterReorderModeViaMenu() {
        reorder.engageMenuPath(snapshotIDs: snapshotIDs)
    }

    // MARK: - Menu actions

    private func toggleExpansion() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
        let target = isExpanded
        Task { await store.setEntryExpanded(itemID: item.id, isExpanded: target, nodeID: nodeID) }
    }

    private func beginRename() {
        renameDraft = displayName
        showRenameAlert = true
    }

    private func applyRename() {
        let draft = renameDraft
        Task { await store.renameEntry(itemID: item.id, newName: draft, nodeID: nodeID) }
    }

    private func duplicate() {
        Task { await store.duplicateEntry(itemID: item.id, nodeID: nodeID) }
    }

    /// Below-fold → "Show on card": move to `foldIndex`, increment fold.
    /// Above-fold → "Remove from card": move to `foldIndex - 1`, decrement.
    /// Mirrors the reorder `onEnd` atomicity — `applyMoveEntry` (sync) and
    /// `setFoldIndex` (sync) both mutate `store.nodes[i]` inside the same
    /// @MainActor tick so SwiftUI batches them into a single render, then
    /// `persistNode` writes to disk asynchronously. Without that batching
    /// the user would see the array reflow one frame before the fold
    /// boundary updates, flashing the card briefly in the wrong zone.
    private func togglePromote() {
        guard let node = store.nodes.first(where: { $0.id == nodeID }) else { return }
        let currentFold = node.effectiveFoldIndex
        let above = index < currentFold
        let target = above ? currentFold - 1 : currentFold
        let newFold = above ? currentFold - 1 : currentFold + 1
        // Move only when the target index actually differs — `applyMoveEntry`
        // bails on `from == to` (returns nil) which is the no-op case where
        // the card is already adjacent to the fold; we still need to flip
        // the boundary.
        if target != index {
            _ = store.applyMoveEntry(nodeID: nodeID, from: index, to: target)
        }
        guard let updated = store.setFoldIndex(newFold, nodeID: nodeID) else { return }
        Task { await store.persistNode(updated) }
    }

    private func performDelete() {
        Task { await store.deleteEntry(itemID: item.id, nodeID: nodeID) }
    }

    private func copyContent() {
        UIPasteboard.general.string = copyableText
    }

    /// Best-effort textual representation of the entry for the system
    /// pasteboard. Per-type fallbacks: transcripts for media, URL for links,
    /// filename for documents, display name as last resort. Stage 3.1a is
    /// deliberately text-only; richer pasteboard types (images, files) land
    /// later if needed.
    private var copyableText: String {
        switch item.type {
        case .text:
            return item.content ?? ""
        case .audio:
            return item.transcript ?? displayName
        case .image:
            return item.description
                ?? item.file?.components(separatedBy: "/").last
                ?? displayName
        case .video:
            return item.transcript
                ?? item.file?.components(separatedBy: "/").last
                ?? displayName
        case .link:
            return item.url ?? displayName
        case .document:
            return item.file?.components(separatedBy: "/").last ?? displayName
        case .imageVideo:
            return item.mediaItems?.first?.file.components(separatedBy: "/").last
                ?? item.file?.components(separatedBy: "/").last
                ?? displayName
        case .rating:
            // Copyable form is "value/scale" (e.g. "4/5"). The atomic
            // value is the entry's content — there's no transcript,
            // file, or URL alternative.
            let value = item.rating?.value ?? 0
            let scale = item.rating?.scale ?? 5
            return "\(value)/\(scale)"
        case .field:
            // Atomic — filtered out of the payload list, so this copy-text
            // path is an unreachable exhaustiveness stub. The rich formatted
            // value belongs to the Attributes-section render (commit 3).
            return displayName
        case .chats:
            // ws-chat-lane — a REFERENCE entry; nothing meaningful to place on
            // the pasteboard (the chats live elsewhere). Fall back to the name.
            return displayName
        }
    }
}

// MARK: - Title row

/// Title bar inside an `EntryCard`. Pure view: takes a name + state and
/// fires callbacks. The card owns all state and store interaction so the
/// title row can stay trivially testable / previewable.
///
/// Two-line layout: display name (primary) over a muted relative
/// timestamp (context). The timestamp prefers `item.updatedAt` and falls
/// back to `createdAt`; the EntryCard does that selection upstream.
private struct EntryTitleRow: View {

    let displayName: String
    let timestamp: Date
    let isExpanded: Bool
    /// Stage 3.1b — when reorder mode is active, the chevron is shown but
    /// non-interactive, the ellipsis menu is hidden entirely, and the
    /// timestamp is dimmed to reinforce "you're in a different mode."
    /// Title row stays clean so the user can still read what they're
    /// dragging.
    let reorderActive: Bool
    /// Whether this row currently sits above the fold (in the card-view
    /// zone). Flips the promotion menu label between "Show on card" and
    /// "Remove from card" so the action reads as its inverse.
    let isAboveFold: Bool
    /// Stage 4.4 — fonts for the display-name (Section Title role) and the
    /// muted relative timestamp (Section Timestamp role). Both are derived
    /// from the dev-panel type scale; removed in commit 3 when the panel
    /// is deleted, with the locked choices migrating to `AirPadTypeScale`
    /// constants in commit 2.
    let titleFont: Font
    let timestampFont: Font
    let onToggle: () -> Void
    /// Toggles whether this entry sits above the fold (in the card-view
    /// zone). The card owns the move + foldIndex bump; this row just
    /// fires the callback with the label flipped by `isAboveFold`.
    let onPromote: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    /// Backlinks v1 — opens the backlink picker anchored on this entry. Nil
    /// hides the menu item (e.g. QuikCapture).
    let onBacklink: (() -> Void)?
    /// Stage 3.1a stub — present-but-disabled so the architectural seat
    /// for the future smart-conversion prompt is reserved. Wired to a
    /// `.disabled(true)` menu button below; the closure is never called.
    let onChangeType: () -> Void
    let onReorder: () -> Void
    let onDelete: () -> Void
    /// hero-image v1 — optional "Set as Hero Image" hook. When non-nil
    /// the row renders the menu item just above the divider before
    /// Rename, sitting alongside `Promote` as a primary action. `nil`
    /// for every entry type the hero set-point doesn't apply to so the
    /// menu shape is unchanged outside `.image` entries.
    var onSetAsHero: (() -> Void)? = nil
    /// Notes use a shorter title-row height so the body/PastePad sit higher.
    /// Other entry types keep the 44pt row. This is the dominant header-height
    /// lever — the fixed 44pt row (not outer padding) is what pushed content down.
    var isNote: Bool = false

    /// Title-row height for notes (also the chevron button's height). Tunable.
    /// The 44pt default is Apple's min tap target; notes trade a little vertical
    /// slop for a tighter capture area. Row grows past this if the text needs it.
    private static let noteRowHeight: CGFloat = 34

    /// Detail-View pass — non-note title-row height, dialed via the dev panel
    /// (default 44 = the prior literal). Notes keep the tighter 34pt row.
    @State private var visualSettings = EntryVisualSettings.shared

    var body: some View {
        HStack(spacing: 8) {
            // Chevron-only Button with a generous 44pt tap target. Expanding
            // the Button to the whole bar would block the background
            // long-press recognizer from seeing touches on the title area
            // (foreground Buttons claim hits exclusively in SwiftUI's hit
            // test). 44pt is Apple's recommended minimum touch target and
            // covers the 20pt visual chevron with enough forgiving slop to
            // not be finicky. Title VStack + Spacer stay outside the Button
            // so long-press on them still reaches the recognizer behind.
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(reorderActive ? 0.25 : 0.6))
                    .frame(width: 44, height: isNote ? Self.noteRowHeight : visualSettings.titleRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reorderActive)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(titleFont)
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1)
                timestampLabel
            }

            Spacer(minLength: 0)

            if !reorderActive {
                Menu {
                    Button(isAboveFold ? "Remove from card" : "Show on card", action: onPromote)
                    if let onSetAsHero {
                        Button("Set as Hero Image", action: onSetAsHero)
                    }
                    Divider()
                    Button("Rename", action: onRename)
                    Button("Duplicate", action: onDuplicate)
                    Button("Copy", action: onCopy)
                    if let onBacklink {
                        Button("Backlink", systemImage: "link", action: onBacklink)
                    }
                    Button("Change type", action: onChangeType)
                        .disabled(true)
                    Button("Reorder", action: onReorder)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                    .frame(width: 32, height: 32)
            }
        }
        .frame(minHeight: isNote ? Self.noteRowHeight : visualSettings.titleRowHeight)
    }

    /// Muted relative timestamp shown under the display name. Sized one step
    /// smaller than the title and dropped to 0.4 opacity so the eye reads
    /// display name first, timestamp second. Concatenation matches the
    /// pre-3.1a per-row footer treatment so the "5 minutes ago" phrasing
    /// is unchanged. Font is the Section Timestamp role from the dev panel.
    private var timestampLabel: some View {
        Text(timestamp, style: .relative)
            .font(timestampFont)
            .foregroundStyle(AppearancePalette.ink.opacity(0.4))
        + Text(" ago")
            .font(timestampFont)
            .foregroundStyle(AppearancePalette.ink.opacity(0.4))
    }
}

// MARK: - Spine row + container (SPIKE v3: spine-entry — THROWAWAY)

/// SPIKE v3 (`spike-entry-spine`) — the shared "row 1" that sits INSIDE an
/// entry's own filled container, applied to two types this spike (Note +
/// Gallery). Geometry maps the T-approved reference
/// (`Ops/design-refs/entry-primitives-mockup.html`):
///   `[chevron 16 · gap10 · name (flex) · gap10 · meta · gap10 · ⠿ grip]`, min-height 28.
/// Chevron 16 + gap 10 puts the name's left edge at `textMargin` (26), the same
/// edge the note body indents to. INVARIANT between fold states; only the
/// chevron rotates. Gallery media does NOT owe the text margin (full width).
/// `trailing` = metadata riding in BOTH states (Gallery: 3-thumb stack + count;
/// Note: empty). Grip is VISUAL ONLY (no menu, no reorder wiring).
struct EntrySpineRow<Trailing: View>: View {

    let name: String
    /// Ghost styling for a derived-but-empty name (a note's "Untitled").
    let isPlaceholder: Bool
    let isExpanded: Bool
    let reorderActive: Bool
    /// Entry-title type role (serif) — the app's `sectionTitle` role, mapping the
    /// reference's Fraunces name.
    let nameFont: Font
    let onToggle: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    /// The "..." options menu content (EntryCard-owned). Rendered as a TAP-ONLY
    /// ellipsis button in a fixed inner slot immediately trailing the metadata,
    /// present in BOTH fold states at the same x (the grip slot is always reserved
    /// so this never reflows). Nil → no options button (slot still reserved).
    var optionsMenu: AnyView? = nil
    /// The reorder drag handle (EntryCard's `dragRecognizer`). LONG-PRESS ONLY;
    /// hosted by the ⠿ grip, which renders ONLY in the collapsed state at the true
    /// trailing edge. Nil → no grip.
    var gripDragHandle: AnyView? = nil

    /// The name's left edge = the note body's left edge below it. Reference:
    /// chevron 16 + gap 10.
    static var textMargin: CGFloat { 26 }
    /// Reference `.spine { min-height: 28 }`.
    static var rowHeight: CGFloat { 28 }
    private static var chevronWidth: CGFloat { 16 }
    private static var gap: CGFloat { 10 }
    /// "..." ellipsis button slot width.
    static var optionsWidth: CGFloat { 28 }
    /// Grip slot width — RESERVED in BOTH fold states so the "..." button never
    /// reflows when the grip appears (collapsed) / disappears (expanded).
    static var gripSlotWidth: CGFloat { 26 }

    var body: some View {
        HStack(spacing: Self.gap) {
            // Chevron: 16pt column, rotates on toggle (reference ▶→▼).
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(reorderActive ? 0.25 : 0.40))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Self.chevronWidth, height: Self.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reorderActive)

            // Name (flex). Tap-to-expand ONLY when collapsed (single-purpose — the
            // drag handle lives on the grip now, so the name never lifts).
            Text(name)
                .font(nameFont)
                .foregroundStyle(AppearancePalette.ink.opacity(isPlaceholder ? 0.3 : 1.0))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .allowsHitTesting(!isExpanded)
                .onTapGesture { if !isExpanded { onToggle() } }

            // Right-side metadata (Gallery thumbs + count; Note none).
            trailing()

            // "..." options — TAP ONLY, fixed inner slot, present in BOTH states.
            optionsButton

            // ⠿ grip — LONG-PRESS ONLY (drag), collapsed-only, at the true trailing
            // edge. The slot width is reserved in both states so "..." never reflows.
            gripSlot
        }
        .frame(minHeight: Self.rowHeight)
    }

    /// The "..." ellipsis options trigger — a Menu that opens on TAP. It has no
    /// long-press-drag behavior and never touches the grip. Fixed-width slot so it
    /// holds the same x-position across the fold transition.
    @ViewBuilder
    private var optionsButton: some View {
        if let optionsMenu {
            Menu { optionsMenu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink.opacity(reorderActive ? 0.2 : 0.55))
                    .frame(width: Self.optionsWidth, height: Self.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reorderActive)
            .accessibilityIdentifier("entryOptions")
        } else {
            Color.clear.frame(width: Self.optionsWidth, height: Self.rowHeight)
        }
    }

    /// The reserved trailing grip slot. The ⠿ glyph + its long-press drag handle
    /// render ONLY when collapsed; expanded, the slot is empty but keeps its width
    /// so "..." holds its x-position. The glyph is inert; the drag recognizer sits
    /// on top (clear) and responds to long-press ONLY — a plain tap never fires it,
    /// so the grip has no tap behavior at all.
    @ViewBuilder
    private var gripSlot: some View {
        ZStack {
            if !isExpanded, let gripDragHandle {
                Self.gripGlyph.allowsHitTesting(false)
                gripDragHandle
            }
        }
        .frame(width: Self.gripSlotWidth, height: Self.rowHeight)
        .accessibilityIdentifier("entryGrip")
    }

    /// The ⠿ grip glyph — inert; hit-testing is owned by the drag handle above it.
    @ViewBuilder static var gripGlyph: some View {
        Text("⠿")
            .font(.system(size: 14, weight: .regular))
            .tracking(1)
            .foregroundStyle(AppearancePalette.ink.opacity(0.30))
    }
}

/// SPIKE v3 — the unified filled-panel container idiom (reference `.entry`):
/// a FILLED surface (a step lighter than the detail ground), fixed 16pt radius,
/// a top inset highlight + drop shadow, NO outline stroke, never a capsule.
/// Identical for Note and Gallery. Collapsed = the same container at row height.
struct EntryContainerStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    static let radius: CGFloat = 16
    /// Reference container padding: `12px 14px`.
    static let padH: CGFloat = 14
    static let padV: CGFloat = 12

    func body(content: Content) -> some View {
        content
            // ws-entry-containers hold-drag FIX (2026-08-24): the fill + rim are
            // PURELY VISUAL and must not hit-test. Before this, the opaque fill sat
            // in FRONT of the card's background `LongPressDragRecognizer` and
            // consumed every touch, so hold-to-drag reorder never fired on any
            // container entry (regression from the container idiom; the recognizer
            // is designed to sit "in front of the color fill"). `allowsHitTesting
            // (false)` lets touches on non-widget areas fall through to it.
            .background { fill.allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            // Top rim light — same as the note panel's (`rimOpacity 0.10`).
            .overlay(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: shadow, radius: shadowRadius, x: 0, y: shadowY)
    }

    /// The app's EXISTING raised-panel surface — the SAME tokens the note panel
    /// (`TextEntryBody.noteFill`) uses, so the container is the app's semantic
    /// panel role, not an invented value. DARK: `bgElevated` #1A1A1A (lifts by
    /// shadow + rim, same-tone with the ground — the note's proven idiom). LIGHT:
    /// the card surface #FFFFFA (`CardSurfaceResolved`), NOT `bgElevated` #FAF6EC
    /// (which read warm-cream, off the light idiom the edge/tint work was tuned to).
    static var fillDarkHex: String { "#1A1A1A" }              // AppearancePalette.bgElevated (dark)
    static var fillLightHex: String { CardSurfaceResolved.resolvedCardBackgroundHex }  // #FFFFFA
    private var fill: Color {
        colorScheme == .dark
            ? AppearancePalette.bgElevated
            : Color(hexString: Self.fillLightHex)
    }
    /// Note-panel shadow: DARK black@0.35; LIGHT the card's warm occlusion
    /// (#43372A @0.143) — the T-dialed note-panel light lift.
    private var shadow: Color {
        colorScheme == .dark
            ? AppearancePalette.panelShadow
            : Color(hexString: CardSurfaceStore.read(.shadowHex)).opacity(0.143)
    }
    private var shadowRadius: CGFloat { colorScheme == .dark ? 12 : 5.6 }
    private var shadowY: CGFloat { colorScheme == .dark ? 4 : 0 }
}

extension View {
    /// Applies the shared spike container (fill + radius + rim + shadow) with the
    /// reference's interior padding.
    func entrySpineContainer() -> some View {
        self
            .padding(.horizontal, EntryContainerStyle.padH)
            .padding(.vertical, EntryContainerStyle.padV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(EntryContainerStyle())
    }
}

/// Stage 4.2 commit 1 — defensive placeholder for an `.imageVideo` entry
/// that has no `mediaItems`. Reached only on the T14 malformed-legacy
/// path (legacy `file == nil` migrated to `mediaItems: []`). Commit 3
/// owns the proper empty-state UX inside `SingleMediaBody`.
private struct EmptyMediaPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(AppearancePalette.ink.opacity(0.06))
            .frame(height: 120)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.35))
                    Text("No media")
                        .font(.caption)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                }
            }
    }
}

