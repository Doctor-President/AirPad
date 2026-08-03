import SwiftUI

/// ws-chat-lane §1–2 — the ONE grouped "Chats" entry body: lists every chat
/// pinned to this node. A REFERENCE view — the chats live in `ChatStore`; this
/// resolves session ids to titles and taps open them. A session id that no
/// longer resolves is dropped (no ghost row, no crash).
///
/// Baked defaults matching the entry visual language; T will art-direct after it
/// lands. No hue-only state (T is colorblind).
struct ChatsEntryBody: View {
    let item: NodeItem
    let nodeID: String

    @Environment(AppRouter.self) private var router

    private var pinnedChats: [Chat] {
        let store = router.chatStore
        return (item.chatSessionIDs ?? []).compactMap { idStr -> Chat? in
            guard let id = UUID(uuidString: idStr) else { return nil }
            return store.chats.first(where: { $0.id == id })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pinnedChats) { chat in
                Button { open(chat) } label: { row(chat) }
                    .buttonStyle(.plain)
                if chat.id != pinnedChats.last?.id {
                    Divider().overlay(AppearancePalette.ink.opacity(0.08))
                }
            }
        }
        // Chats resolve out of ChatStore, which may not have hydrated yet if the
        // user hasn't opened the chats surface this session.
        .task { await router.chatStore.loadIfNeeded() }
    }

    private func row(_ chat: Chat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                .frame(width: 22)
            Text(Self.displayTitle(chat))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppearancePalette.ink.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.3))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// Deep-link into the chats sheet, pushed straight to this chat.
    private func open(_ chat: Chat) {
        router.pendingChatToOpen = chat.id
        router.showChatsList = true
    }

    /// User-renamed titles (`titleSource == .user`) live in `chat.title` and must
    /// display as renamed. Falls back to the first user message when empty.
    static func displayTitle(_ chat: Chat) -> String {
        let t = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let firstUser = chat.messages.first(where: { $0.role == .user }) {
            let s = firstUser.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? "Untitled chat" : String(s.prefix(40))
        }
        return "Untitled chat"
    }
}

/// ws-chat-lane §3,5 — pins a chat to a node. A searchable node list; tapping a
/// node pins the chat there (REFERENCE, one node per chat) and dismisses. Shows
/// the current pin so re-pinning reads as a MOVE. Shared by the Chats list
/// (retroactive pin) and from inside a chat.
struct PinChatSheet: View {
    let chatID: UUID

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var currentPinNodeID: String? { store.nodePinned(forChatID: chatID)?.id }

    private var candidates: [Node] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = store.nodes.sorted { $0.updatedAt > $1.updatedAt }
        guard !q.isEmpty else { return all }
        return all.filter { ($0.title.isEmpty ? "untitled" : $0.title.lowercased()).contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(candidates) { node in
                    Button {
                        Task { await store.pinChat(chatID: chatID, toNodeID: node.id); dismiss() }
                    } label: {
                        HStack(spacing: 8) {
                            Text(node.title.isEmpty ? "Untitled" : node.title)
                                .font(.system(size: 15))
                                .foregroundStyle(AppearancePalette.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if node.id == currentPinNodeID {
                                Image(systemName: "pin.fill")   // shape, not hue (colorblind-safe)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppearancePalette.bgBase)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppearancePalette.bgBase)
            .searchable(text: $query, prompt: "Pin to node")
            .navigationTitle("Pin chat to a node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(AppearancePalette.ink)
                }
                if currentPinNodeID != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Unpin", role: .destructive) {
                            Task { await store.unpinChat(chatID: chatID); dismiss() }
                        }
                    }
                }
            }
        }
        .presentationBackground(AppearancePalette.bgBase)
    }
}
