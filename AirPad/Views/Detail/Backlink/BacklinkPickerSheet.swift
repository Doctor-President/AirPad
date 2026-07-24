// BacklinkPickerSheet.swift
// Backlinks v1 — creation flow. Invoked from an entry's "Backlink" action (or,
// later, the inline word/phrase anchor). Two screens:
//   1. Pick the target node (recents + search).
//   2. Pick granularity — the node itself (node-level) or one of its entries
//      (entry-level) — then Done writes the bidirectional connection.
// One backlink per pass (no multi-select), per ws-backlinks.md.

import SwiftUI

struct BacklinkPickerSheet: View {
    /// The node the backlink originates from (the detail view we're in).
    let sourceNodeID: String
    /// The entry the "Backlink" action fired on — recorded as the source anchor
    /// on the target's mirror edge. Nil for a whole-node source.
    let sourceEntryID: String?

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var pickedNodeID: String?

    /// Candidate target nodes: everything except the source and any node already
    /// linked to it, most-recent first, narrowed by the search text.
    private var candidates: [Node] {
        let source = store.nodes.first { $0.id == sourceNodeID }
        let alreadyLinked: Set<String> = Set((source?.connections ?? []).map(\.nodeID))
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [Node] = store.nodes.filter { node in
            node.id != sourceNodeID && !alreadyLinked.contains(node.id)
        }
        if !q.isEmpty {
            result = result.filter { BacklinkLabels.title($0).lowercased().contains(q) }
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    var body: some View {
        NavigationStack {
            List(candidates) { node in
                Button {
                    pickedNodeID = node.id
                } label: {
                    HStack(spacing: 12) {
                        Text(BacklinkLabels.title(node))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AppearancePalette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.3))
                    }
                    .contentShape(Rectangle())
                }
                .listRowBackground(AppearancePalette.ink.opacity(0.04))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppearancePalette.bgBase.ignoresSafeArea())
            .searchable(text: $searchText, prompt: "Search nodes")
            .navigationTitle("Backlink to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(item: $pickedNodeID) { targetID in
                BacklinkTargetPicker(
                    sourceNodeID: sourceNodeID,
                    sourceEntryID: sourceEntryID,
                    targetNodeID: targetID,
                    onComplete: { dismiss() }
                )
            }
        }
    }
}

// MARK: - Screen 2 — node-vs-entry granularity

private struct BacklinkTargetPicker: View {
    let sourceNodeID: String
    let sourceEntryID: String?
    let targetNodeID: String
    let onComplete: () -> Void

    @Environment(CorpusStore.self) private var store

    /// What the user has selected to link to: the node as a whole, or one of
    /// its entries. Nil until they tap a row (Done stays disabled).
    private enum Target: Equatable {
        case node
        case entry(String)
    }
    @State private var selection: Target?

    private var targetNode: Node? { store.nodes.first { $0.id == targetNodeID } }
    /// Payload entries only — atomics (ratings) aren't meaningful link targets.
    private var entries: [NodeItem] { targetNode?.items.filter { !$0.type.isAtomic } ?? [] }

    /// Backlinks v1 — soft warning threshold. No hard cap; ~20 is just where a
    /// node gets dense enough to nudge the user.
    private var sourceConnectionCount: Int {
        store.nodes.first { $0.id == sourceNodeID }?.connections.count ?? 0
    }

    var body: some View {
        List {
            if sourceConnectionCount >= 20 {
                Text("This node already has \(sourceConnectionCount) connections. Adding more is fine — just getting dense.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.orange.opacity(0.10))
            }
            // Node-level target.
            row(
                title: targetNode.map(BacklinkLabels.title) ?? "Untitled",
                indent: false,
                isSelected: selection == .node,
                systemImage: "doc.text"
            ) { selection = .node }

            // Entry-level targets, indented beneath the node.
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { item in
                        row(
                            title: BacklinkLabels.entry(item),
                            indent: true,
                            isSelected: selection == .entry(item.id),
                            systemImage: BacklinkLabels.icon(item.type)
                        ) { selection = .entry(item.id) }
                    }
                } header: {
                    Text("Or an entry")
                        .font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppearancePalette.bgBase.ignoresSafeArea())
        .navigationTitle("Link to")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { commit() }
                    .disabled(selection == nil)
            }
        }
    }

    private func row(title: String,
                     indent: Bool,
                     isSelected: Bool,
                     systemImage: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if indent { Spacer().frame(width: 16) }
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: indent ? 15 : 16, weight: indent ? .regular : .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.blue : AppearancePalette.ink.opacity(0.3))
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(AppearancePalette.ink.opacity(0.04))
    }

    private func commit() {
        guard let selection else { return }
        let targetEntryID: String? = {
            if case .entry(let id) = selection { return id }
            return nil
        }()
        Task {
            await store.addConnection(
                from: sourceNodeID,
                sourceEntryID: sourceEntryID,
                to: targetNodeID,
                targetEntryID: targetEntryID
            )
            await MainActor.run { onComplete() }
        }
    }
}

// MARK: - Labels

enum BacklinkLabels {
    static func title(_ node: Node) -> String {
        let t = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }

    static func entry(_ item: NodeItem) -> String {
        switch item.type {
        case .text:
            let s = (item.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let first = s.split(separator: "\n").first.map(String.init) ?? ""
            return first.isEmpty ? "Note" : String(first.prefix(60))
        case .audio:              return "Voice note"
        case .image, .imageVideo, .video: return "Media"
        case .link:               return "Link"
        case .document:           return "Document"
        case .rating:             return "Rating"
        }
    }

    static func icon(_ type: NodeItemType) -> String {
        switch type {
        case .text:               return "note.text"
        case .audio:              return "waveform"
        case .image, .imageVideo, .video: return "photo"
        case .link:               return "link"
        case .document:           return "doc"
        case .rating:             return "star"
        }
    }
}
