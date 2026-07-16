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
    /// ws-display-edit-mode — injected by `NodeDetailView`. Drives whether
    /// this card's header chrome (title / timestamp / ellipsis) shows and
    /// whether the reorder long-press is live.
    @Environment(\.displayEditMode) private var displayEditMode

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

    /// Vertical padding around a `.text` (note) entry header — tightened from
    /// the default 12 so the note body + PastePad sit higher (T's capture-area
    /// feel). Tunable. Other entry types keep 12.
    private static let noteHeaderVerticalPadding: CGFloat = 4

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

    /// Force-collapsed during reorder mode so every card renders as a
    /// uniform-height title row, which is what the controller's slotPitch
    /// math assumes. Restored to user-set expansion when reorder exits.
    ///
    /// ws-display-edit-mode — Display reads every entry open: there's no
    /// chevron to expand a collapsed entry, and the node should read as a
    /// continuous document.
    private var effectiveExpansion: Bool {
        if displayEditMode.isDisplay { return true }
        return reorder.isReorderActive ? false : isExpanded
    }

    /// True when this card sits inside the promoted "card view" region
    /// (`index < node.foldIndex`). Drives the `onPromote` menu label flip
    /// in `EntryTitleRow` and the toggle direction in `togglePromote()`.
    /// Read from the live store so the label re-evaluates on each render
    /// after a promote/demote mutation.
    private var isAboveFold: Bool {
        guard let node = store.nodes.first(where: { $0.id == nodeID }) else { return false }
        return index < node.foldIndex
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
            // ws-display-edit-mode — the whole header row (display name,
            // per-section timestamp, ellipsis menu, chevron) is Edit-only
            // chrome. In Display it hides so the body reads as a document
            // section. Entry titles aren't removed, just gated by mode.
            if !displayEditMode.isDisplay {
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
                // Read-aloud through the shared SpeechSynthesisService — notes only.
                readAloud: item.type == .text
                    ? NoteReadAloudButton(token: item.id, text: item.content ?? "")
                    : nil,
                isNote: item.type == .text
            )
            .transition(.opacity)
            }

            if effectiveExpansion {
                bodyView
                    // No header above the body in Display → no gap needed.
                    .padding(.top, displayEditMode.isDisplay ? 0 : 8)
            }
        }
        .padding(.horizontal, 12)
        // Note headers tighten the vertical padding so the body + PastePad sit
        // higher; other entry types keep the original 12.
        .padding(.vertical, item.type == .text ? Self.noteHeaderVerticalPadding : 12)
        .background {
            // Long-press recognizer lives in the background slot so foreground
            // interactive widgets (chevron, menu, text editors, waveform
            // scrub) claim their own hits via separate UIViews while touches
            // that fall outside those widgets reach the recognizer. It races
            // with the parent ScrollView's pan: hold still 0.5s → recognizer
            // wins (lift); move → scroll wins. No fill behind it any more —
            // Stage 4.8 stripped the card container; the recognizer's bounds
            // are still the full row because `.background` sizes to its
            // parent.
            ZStack {
                // ws-display-edit-mode — reorder is an Edit-only workspace
                // gesture; its slotPitch math assumes uniform collapsed rows,
                // which Display (headerless, all-open) breaks. Recognizer is
                // omitted entirely in Display.
                if !displayEditMode.isDisplay {
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
                        let payloadFold = preNode.foldIndex - prefix
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
                            let rawFold = preNode.foldIndex + foldDelta
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
            }
        }
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
        case .rating:
            // Atomic — rating renders in the pinned Attributes section
            // (Commit B), not in the payload list. `NodeDetailView`
            // filters atomics out of the payload ForEach so this
            // branch is unreachable; present only to satisfy switch
            // exhaustiveness.
            EmptyView()
        }
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
        let currentFold = node.foldIndex
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
        }
    }
}

/// Read-aloud control for a `.text` note — toggles TTS through the shared
/// `SpeechSynthesisService` (the same on-device engine + Now Playing/lock-screen
/// transport the Librarian uses). Play → pause → resume; the icon reflects
/// whether THIS note is the one currently speaking. Feeds the service
/// `item.content` (the saved text).
private struct NoteReadAloudButton: View {
    let token: String   // item.id — identifies this note to the shared service
    let text: String    // item.content

    var body: some View {
        let tts = SpeechSynthesisService.shared
        let isThisPlaying = tts.activeToken == token && tts.isSpeaking && !tts.isPaused
        Button {
            tts.toggle(token: token, text: text)
        } label: {
            Image(systemName: isThisPlaying ? "pause.fill" : "speaker.wave.2.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DetailPalette.ink.opacity(isThisPlaying ? 0.9 : 0.6))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    /// Read-aloud control — passed only for `.text` notes (nil for every other
    /// entry type, so their chrome is untouched).
    var readAloud: NoteReadAloudButton? = nil
    /// Notes use a shorter title-row height so the body/PastePad sit higher.
    /// Other entry types keep the 44pt row. This is the dominant header-height
    /// lever — the fixed 44pt row (not outer padding) is what pushed content down.
    var isNote: Bool = false

    /// Title-row height for notes (also the chevron button's height). Tunable.
    /// The 44pt default is Apple's min tap target; notes trade a little vertical
    /// slop for a tighter capture area. Row grows past this if the text needs it.
    private static let noteRowHeight: CGFloat = 34

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
                    .foregroundStyle(DetailPalette.ink.opacity(reorderActive ? 0.25 : 0.6))
                    .frame(width: 44, height: isNote ? Self.noteRowHeight : 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reorderActive)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(titleFont)
                    .foregroundStyle(DetailPalette.ink)
                    .lineLimit(1)
                timestampLabel
            }

            Spacer(minLength: 0)

            if !reorderActive {
                // Read-aloud (notes only; nil otherwise → renders nothing).
                readAloud
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
                        .foregroundStyle(DetailPalette.ink.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DetailPalette.ink.opacity(0.35))
                    .frame(width: 32, height: 32)
            }
        }
        .frame(minHeight: isNote ? Self.noteRowHeight : 44)
    }

    /// Muted relative timestamp shown under the display name. Sized one step
    /// smaller than the title and dropped to 0.4 opacity so the eye reads
    /// display name first, timestamp second. Concatenation matches the
    /// pre-3.1a per-row footer treatment so the "5 minutes ago" phrasing
    /// is unchanged. Font is the Section Timestamp role from the dev panel.
    private var timestampLabel: some View {
        Text(timestamp, style: .relative)
            .font(timestampFont)
            .foregroundStyle(DetailPalette.ink.opacity(0.4))
        + Text(" ago")
            .font(timestampFont)
            .foregroundStyle(DetailPalette.ink.opacity(0.4))
    }
}

/// Stage 4.2 commit 1 — defensive placeholder for an `.imageVideo` entry
/// that has no `mediaItems`. Reached only on the T14 malformed-legacy
/// path (legacy `file == nil` migrated to `mediaItems: []`). Commit 3
/// owns the proper empty-state UX inside `SingleMediaBody`.
private struct EmptyMediaPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(DetailPalette.ink.opacity(0.06))
            .frame(height: 120)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(DetailPalette.ink.opacity(0.35))
                    Text("No media")
                        .font(.caption)
                        .foregroundStyle(DetailPalette.ink.opacity(0.45))
                }
            }
    }
}

