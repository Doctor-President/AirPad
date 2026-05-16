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
/// Long-press gesture seat on the card body is RESERVED for Stage 3.1b
/// (drag-to-reorder + multi-select). Deliberately unbound here.
struct EntryCard: View {

    let item: NodeItem
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    /// Local mirror of `item.isExpanded` so the chevron toggles instantly,
    /// independent of the persistence round-trip through the store. Kept in
    /// sync via `.onChange` against the model.
    @State private var isExpanded: Bool

    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var showDeleteConfirmation = false

    init(item: NodeItem, nodeID: String) {
        self.item = item
        self.nodeID = nodeID
        self._isExpanded = State(initialValue: item.isExpanded ?? true)
    }

    private var displayName: String {
        item.displayName ?? item.type.defaultDisplayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EntryTitleRow(
                displayName: displayName,
                timestamp: item.updatedAt ?? item.createdAt,
                isExpanded: isExpanded,
                onToggle: toggleExpansion,
                onRename: beginRename,
                onDuplicate: duplicate,
                onCopy: copyContent,
                onChangeType: {},
                onDelete: { showDeleteConfirmation = true }
            )

            if isExpanded {
                bodyView
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        }
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
    let onToggle: () -> Void
    let onRename: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    /// Stage 3.1a stub — present-but-disabled so the architectural seat
    /// for the future smart-conversion prompt is reserved. Wired to a
    /// `.disabled(true)` menu button below; the closure is never called.
    let onChangeType: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                timestampLabel
            }

            Spacer()

            Menu {
                Button("Rename", action: onRename)
                Button("Duplicate", action: onDuplicate)
                Button("Copy", action: onCopy)
                Button("Change type", action: onChangeType)
                    .disabled(true)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
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
