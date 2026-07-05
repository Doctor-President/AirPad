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
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Related Nodes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .textCase(.uppercase)
                    .tracking(0.8)

                VStack(spacing: 8) {
                    ForEach(rows, id: \.conn.id) { pair in
                        Button {
                            // Established cross-context open-node handoff — works
                            // whether the detail is hosted in a canvas stack or
                            // the Dashboard stack. Entry-level peek is a later
                            // phase; v1 lands on the node.
                            router.pendingNodeNavigationID = pair.target.id
                        } label: {
                            row(pair.conn, pair.target)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Backlink", systemImage: "link.badge.minus", role: .destructive) {
                                Task { await store.removeConnection(id: pair.conn.id, from: nodeID) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
        }
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
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // Entry-level qualifier, when the edge points at a specific entry.
                if let entryID = conn.entryID,
                   let entry = target.items.first(where: { $0.id == entryID }) {
                    Text(BacklinkLabels.entry(entry))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
