// RelatedNodesSection.swift
// Backlinks v1 — the "Related Nodes" section in node detail. This phase renders
// the USER channel only (authored backlinks, solid). The system-suggestion
// channel (derived at view time from threads/substrate, never persisted,
// one-tap accept) lands in a later phase alongside this same section.

import SwiftUI

struct RelatedNodesSection: View {
    let nodeID: String

    @Environment(CorpusStore.self) private var store

    /// Presents the node-level backlink authoring picker (see `relatedHeader`).
    @State private var showLinkPicker = false

    /// System-suggestion channel — derived at view time from the substrate,
    /// NEVER persisted (enters `connections` only when the user accepts one).
    /// O(n) cosine over the corpus, so computed on appear + after any accept
    /// and cached here rather than recomputed every render.
    @State private var suggestions: [Node] = []

    /// Whether the Suggested channel is collapsed. A GLOBAL UI preference (one
    /// tap quiets suggestions corpus-wide, not per node), persisted in
    /// UserDefaults via @AppStorage and defaulting to EXPANDED. Deliberately NOT
    /// a per-suggestion dismiss: a declined-set would be keyed to suggestion
    /// identity and go stale as the corpus drifts. Collapse keys to nothing —
    /// suggestions keep recomputing behind the closed door, so expanding always
    /// shows CURRENT proposals rather than a frozen list of past declines.
    @AppStorage("suggestionsCollapsed") private var suggestionsCollapsed = false

    /// Live connections on this node, newest first. Dangling edges (target
    /// deleted) are dropped by resolving against the live corpus.
    private var resolved: [(conn: NodeConnection, target: Node)] {
        let node = store.nodes.first { $0.id == nodeID }
        let conns: [NodeConnection] = (node?.connections ?? []).sorted { $0.createdAt > $1.createdAt }
        var out: [(conn: NodeConnection, target: Node)] = []
        for c in conns {
            if let target = store.nodes.first(where: { $0.id == c.nodeID }) {
                out.append((c, target))
            }
        }
        return out
    }

    var body: some View {
        let rows = resolved
        // `userChannel` always renders — its header carries the "+ Link to node"
        // authoring control, which must be reachable even on a node with no
        // backlinks yet. Suggestions render only when present.
        VStack(alignment: .leading, spacing: 18) {
            userChannel(rows)
            if !suggestions.isEmpty { suggestionChannel }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .onAppear { refreshSuggestions() }
        .sheet(isPresented: $showLinkPicker) {
            // The standard backlink creation flow with a WHOLE-NODE source
            // (`sourceEntryID: nil`) — the case the entry "..." menu can't
            // author. Screen 2's node-level option writes `entryID == nil`.
            BacklinkPickerSheet(sourceNodeID: nodeID, sourceEntryID: nil)
                .onDisappear { refreshSuggestions() }
        }
    }

    // MARK: - User channel (authored backlinks — primary)

    private func userChannel(_ rows: [(conn: NodeConnection, target: Node)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            relatedHeader
            if !rows.isEmpty {
                VStack(spacing: 8) {
                    ForEach(rows, id: \.conn.id) { pair in
                        // A STACKING push (NavigationLink appends to the enclosing
                        // surface's NavigationStack), so back returns to THIS detail
                        // — following a link, not being teleported. `entryID` (nil
                        // for node-level, set for entry-level) rides along and drives
                        // NodeDetailView's scroll-to-entry on arrival.
                        NavigationLink(value: NodeDetailRoute(nodeID: pair.target.id,
                                                              entryID: pair.conn.entryID)) {
                            row(pair.conn, pair.target)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Backlink", systemImage: "link.badge.minus", role: .destructive) {
                                Task {
                                    await store.removeConnection(id: pair.conn.id, from: nodeID)
                                    refreshSuggestions()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// "Related Nodes" header + a muted, secondary "+ Link to node" authoring
    /// control. Node-level see-also links (`NodeConnection.entryID == nil`) were
    /// representable but uncreatable — the entry "..." menu always fills in a
    /// source entryID. This opens the standard picker with a whole-node source.
    /// Kept quiet on purpose: the section was just de-glyphed, so the control
    /// stays subordinate to the header, never a prominent button.
    private var relatedHeader: some View {
        HStack(spacing: 8) {
            channelHeader("Related Nodes", secondary: false)
            Spacer(minLength: 8)
            Button { showLinkPicker = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Link to node")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - System suggestion channel (derived, never persisted)

    private var suggestionChannel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The header doubles as the collapse control. Collapsed = the label
            // plus an expand affordance and nothing else (the rows are gone, not
            // dimmed). Global + persisted (see `suggestionsCollapsed`). This is
            // presentation only — how suggestions are generated, ranked, and
            // accepted is untouched; the `+` action below is unchanged.
            Button {
                withAnimation(.easeInOut(duration: 0.28)) { suggestionsCollapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    channelHeader("Suggested", secondary: true)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.3))
                        .rotationEffect(.degrees(suggestionsCollapsed ? 0 : 90))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !suggestionsCollapsed {
                VStack(spacing: 8) {
                    ForEach(suggestions) { suggestionRow($0) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func channelHeader(_ text: String, secondary: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppearancePalette.ink.opacity(secondary ? 0.3 : 0.45))
            .textCase(.uppercase)
            .tracking(0.8)
    }

    private func suggestionRow(_ node: Node) -> some View {
        HStack(spacing: 10) {
            // Previewing a suggestion is link-following too — STACK it (back
            // returns to this detail). Suggestions are whole-node candidates, so
            // entryID is nil. The `+` accept button (below) is unchanged.
            NavigationLink(value: NodeDetailRoute(nodeID: node.id, entryID: nil)) {
                // No leading glyph. The SUGGESTED header + the trailing `+` already
                // say "proposed, tap to add"; a third telling (and sparkles in
                // particular) would brand the user's own node. App-wide ban on
                // sparkles/wand/magic iconography — it reads as an empty "AI"
                // promise; AirPad's posture is patient, legible work.
                HStack(spacing: 10) {
                    Text(BacklinkLabels.title(node))
                        .font(.system(size: 15))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // One-tap accept → promotes into the user channel (the only way a
            // suggestion ever enters `connections`; the system never auto-writes).
            Button {
                Task {
                    await store.addConnection(from: nodeID, to: node.id)
                    refreshSuggestions()
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(AppearancePalette.ink.opacity(0.02), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Derive the top substrate candidates at view time — genuine proposals
    /// (`exclusion == nil`) not already backlinked, capped. Never persisted.
    private func refreshSuggestions() {
        guard let node = store.nodes.first(where: { $0.id == nodeID }) else {
            suggestions = []
            return
        }
        let backlinked = Set(node.connections.map(\.nodeID))
        let cands = SubstrateThreadService.candidates(forNode: node, in: store.nodes)
        var picked: [Node] = []
        for c in cands where c.exclusion == nil && !backlinked.contains(c.other.id) {
            picked.append(c.other)
            if picked.count >= 5 { break }
        }
        suggestions = picked
    }

    private func row(_ conn: NodeConnection, _ target: Node) -> some View {
        // No leading link glyph. This section shows the user their OWN corpus,
        // adjacent — the Librarian noticed proximity, it did not author these
        // nodes. Marking that with a glyph claims credit for showing someone their
        // own material. The trailing chevron already signals "opens".
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(BacklinkLabels.title(target))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1)
                // Entry-level qualifier, when the edge points at a specific entry.
                if let entryID = conn.entryID,
                   let entry = target.items.first(where: { $0.id == entryID }) {
                    Text(BacklinkLabels.entry(entry))
                        .font(.system(size: 12))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(AppearancePalette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
