// NodeConnection.swift
// Backlinks v1 — a user-asserted relational edge between two nodes.
//
// The RELATIONAL channel of hybrid-authorship (tags are the organizational
// channel): the user asserts "these two connect," durably and independent of
// substrate similarity. The SYSTEM NEVER auto-writes connections — they enter
// a node only through explicit user action (drawing a backlink, or accepting a
// system suggestion into the user channel). See ws-backlinks.md.

import Foundation

struct NodeConnection: Codable, Identifiable, Equatable, Hashable {
    /// Shared across BOTH directions of the edge. Backlinks are bidirectional —
    /// each endpoint node carries a `NodeConnection` pointing at the OTHER node,
    /// and both records share this `id` so the pair is created and removed as a
    /// unit (match on `id` to delete both sides).
    let id: String

    /// The node at the far end of this edge (never this node's own id).
    let nodeID: String

    /// Optional target entry within `nodeID` — an entry-level backlink, which
    /// navigates via a peek sheet. `nil` is a node-level link (navigates
    /// straight to the node).
    let entryID: String?

    /// When the user drew this connection. Ordering + display only.
    let createdAt: Date

    init(id: String = UUID().uuidString,
         nodeID: String,
         entryID: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.nodeID = nodeID
        self.entryID = entryID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case entryID = "entry_id"
        case createdAt = "created_at"
    }
}
