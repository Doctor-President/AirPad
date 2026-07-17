// RelatedNodesSection.swift
// Backlinks v1 — the "Related Nodes" section in node detail. This phase renders
// the USER channel only (authored backlinks, solid). The system-suggestion
// channel (derived at view time from threads/substrate, never persisted,
// one-tap accept) lands in a later phase alongside this same section.

import SwiftUI

struct RelatedNodesSection: View {
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(AppRouter.self) private var router

    /// Entry-level tap target — non-nil presents the peek sheet.
    private struct PeekTarget: Identifiable { let id: String; let nodeID: String; let entryID: String }
    @State private var peek: PeekTarget?

    /// System-suggestion channel — derived at view time from the substrate,
    /// NEVER persisted (enters `connections` only when the user accepts one).
    /// O(n) cosine over the corpus, so computed on appear + after any accept
    /// and cached here rather than recomputed every render.
    @State private var suggestions: [Node] = []

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
        let hasContent = !rows.isEmpty || !suggestions.isEmpty
        // Always in the hierarchy (even empty) so `onAppear` fires and the
        // suggestion compute runs for nodes with no authored backlinks yet.
        VStack(alignment: .leading, spacing: 18) {
            if !rows.isEmpty { userChannel(rows) }
            if !suggestions.isEmpty { suggestionChannel }
        }
        .padding(.horizontal, hasContent ? 16 : 0)
        .padding(.top, hasContent ? 20 : 0)
        .onAppear { refreshSuggestions() }
        .sheet(item: $peek) { p in
            // The REAL detail view, opened focused on the target entry — drag
            // the sheet up for full. The underlying node stays put, so the user
            // keeps their place (the peek's whole point).
            NavigationStack {
                NodeDetailView(nodeID: p.nodeID, focusEntryID: p.entryID)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - User channel (authored backlinks — primary)

    private func userChannel(_ rows: [(conn: NodeConnection, target: Node)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            channelHeader("Related Nodes", secondary: false)
            VStack(spacing: 8) {
                ForEach(rows, id: \.conn.id) { pair in
                    Button {
                        if let entryID = pair.conn.entryID {
                            // Entry-level → peek sheet (keeps the user's place).
                            peek = PeekTarget(id: pair.conn.id, nodeID: pair.target.id, entryID: entryID)
                        } else {
                            // Node-level → open directly via the cross-context
                            // open-node handoff (canvas stack or Dashboard stack).
                            router.pendingNodeNavigationID = pair.target.id
                        }
                    } label: {
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

    // MARK: - System suggestion channel (derived, never persisted)

    private var suggestionChannel: some View {
        VStack(alignment: .leading, spacing: 10) {
            channelHeader("Suggested", secondary: true)
            VStack(spacing: 8) {
                ForEach(suggestions) { suggestionRow($0) }
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
            Button {
                router.pendingNodeNavigationID = node.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                        .frame(width: 22)
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
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 22)
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
