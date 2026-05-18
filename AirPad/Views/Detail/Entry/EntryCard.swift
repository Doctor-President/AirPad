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

    @Environment(CorpusStore.self) private var store
    @Environment(EntryReorderController.self) private var reorder

    /// Local mirror of `item.isExpanded` so the chevron toggles instantly,
    /// independent of the persistence round-trip through the store. Kept in
    /// sync via `.onChange` against the model.
    @State private var isExpanded: Bool

    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var showDeleteConfirmation = false

    init(item: NodeItem, nodeID: String, index: Int, snapshotIDs: [String]) {
        self.item = item
        self.nodeID = nodeID
        self.index = index
        self.snapshotIDs = snapshotIDs
        self._isExpanded = State(initialValue: item.isExpanded ?? true)
    }

    private var displayName: String {
        item.displayName ?? item.type.defaultDisplayName
    }

    /// Force-collapsed during reorder mode so every card renders as a
    /// uniform-height title row, which is what the controller's slotPitch
    /// math assumes. Restored to user-set expansion when reorder exits.
    private var effectiveExpansion: Bool {
        reorder.isReorderActive ? false : isExpanded
    }

    var body: some View {
        let presentation = reorder.presentation(forItemID: item.id, atIndex: index)
        VStack(alignment: .leading, spacing: 0) {
            EntryTitleRow(
                displayName: displayName,
                timestamp: item.updatedAt ?? item.createdAt,
                isExpanded: effectiveExpansion,
                reorderActive: presentation.reorderActive,
                onToggle: toggleExpansion,
                onRename: beginRename,
                onDuplicate: duplicate,
                onCopy: copyContent,
                onChangeType: {},
                onReorder: enterReorderModeViaMenu,
                onDelete: { showDeleteConfirmation = true }
            )

            if effectiveExpansion {
                bodyView
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .background {
            // Color fill at the back, long-press recognizer in front of
            // it but behind the foreground card content. Foreground
            // interactive widgets (chevron, menu, text editors, waveform
            // scrub) claim their own hits via separate UIViews. Touches
            // that fall outside those widgets reach the recognizer, which
            // races with the parent ScrollView's pan: hold still 0.5s →
            // recognizer wins (lift); move → scroll wins.
            ZStack {
                Color(.secondarySystemBackground)
                    .allowsHitTesting(false)
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
                        guard let updated = store.applyMoveEntry(nodeID: nodeID, from: from, to: to) else {
                            reorder.exit()
                            return
                        }
                        reorder.compensateForReorder(slotDelta: slotDelta)
                        Task {
                            // Persist asynchronously; yield one render so
                            // the compensated frame commits before exit()
                            // triggers the landing animation from the
                            // compensated value to 0.
                            await store.persistNode(updated)
                            await Task.yield()
                            reorder.exit()
                        }
                    },
                    scrollDeltaProvider: { reorder.scrollDelta }
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        case .link:     LinkEntryBody(item: item, nodeID: nodeID)
        case .document: DocumentEntryBody(item: item, nodeID: nodeID)
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
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    /// Stage 3.1a stub — present-but-disabled so the architectural seat
    /// for the future smart-conversion prompt is reserved. Wired to a
    /// `.disabled(true)` menu button below; the closure is never called.
    let onChangeType: () -> Void
    let onReorder: () -> Void
    let onDelete: () -> Void

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
                    .foregroundStyle(.white.opacity(reorderActive ? 0.25 : 0.6))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reorderActive)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                timestampLabel
            }

            Spacer(minLength: 0)

            if !reorderActive {
                Menu {
                    Button("Rename", action: onRename)
                    Button("Duplicate", action: onDuplicate)
                    Button("Copy", action: onCopy)
                    Button("Change type", action: onChangeType)
                        .disabled(true)
                    Button("Reorder", action: onReorder)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 32, height: 32)
            }
        }
        .frame(minHeight: 44)
    }

    /// Muted relative timestamp shown under the display name. Sized one step
    /// smaller than the title (`.caption2` vs `.subheadline`) and dropped to
    /// 0.4 opacity so the eye reads display name first, timestamp second.
    /// Concatenation matches the pre-3.1a per-row footer treatment so the
    /// "5 minutes ago" phrasing is unchanged.
    private var timestampLabel: some View {
        Text(timestamp, style: .relative)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.4))
        + Text(" ago")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.4))
    }
}

/// Stage 4.2 commit 1 — defensive placeholder for an `.imageVideo` entry
/// that has no `mediaItems`. Reached only on the T14 malformed-legacy
/// path (legacy `file == nil` migrated to `mediaItems: []`). Commit 3
/// owns the proper empty-state UX inside `SingleMediaBody`.
private struct EmptyMediaPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.06))
            .frame(height: 120)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.35))
                    Text("No media")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
    }
}
