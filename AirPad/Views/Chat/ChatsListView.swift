import SwiftUI

/// Sheet-mounted chats list. The Dashboard header bubble and the
/// Librarian "Chats" tile both flip `router.showChatsList = true` →
/// this sheet presents over whichever surface is active. The sheet
/// owns its OWN `NavigationStack` so it can push into `ChatView`
/// without inheriting (or fighting) any host stack — sidesteps the
/// Librarian-has-no-stack problem and makes the two entry points open
/// a bit-identical surface.
struct ChatsListView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    /// Local push stack — independent of the host's NavigationStack. Each
    /// route is the `Chat.id` of the conversation being opened; ChatView
    /// reads `router.chat` directly so we only need the id as a token.
    @State private var path: [UUID] = []

    /// Rename flow — non-nil id presents the rename alert; `renameText` is its
    /// editable buffer (seeded from the chat's current display title).
    @State private var renamingChatID: UUID? = nil
    @State private var renameText: String = ""

    private var session: ChatSession { router.chat }
    private var chatStore: ChatStore { router.chatStore }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AppearancePalette.bgBase.ignoresSafeArea()
                content
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: UUID.self) { _ in
                // The route token exists only to drive a push; the actual
                // ChatView reads `router.chat`, which is set by `load(_:)`
                // or `startNew()` before we append to `path`.
                ChatView()
            }
        }
        .task {
            // Bootstrap the store on first sheet appearance so the list
            // hydrates from disk. ChatView's own .task also calls this,
            // but the list needs to render with rows BEFORE the user
            // pushes into a chat.
            await chatStore.loadIfNeeded()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if chatStore.chats.isEmpty {
            emptyState
        } else {
            chatList
        }
    }

    private var emptyState: some View {
        Text("No chats yet")
            .font(.system(size: 15))
            .foregroundStyle(AppearancePalette.ink.opacity(0.45))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatList: some View {
        List {
            ForEach(chatStore.chats) { chat in
                Button {
                    session.load(chat)
                    path.append(chat.id)
                } label: {
                    row(for: chat)
                }
                .buttonStyle(.plain)
                .listRowBackground(AppearancePalette.bgBase)
                .listRowSeparatorTint(AppearancePalette.ink.opacity(0.08))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(chat)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        renameText = displayTitle(for: chat)
                        renamingChatID = chat.id
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(Color(hexString: "1B59C2"))   // Klein blue (T is colorblind → named literal)
                }
                // Long-press context menu — discoverable path for Rename (the leading
                // swipe lane is easy to miss; the trailing lane is taken by Delete).
                // Mirrors both swipe actions, the standard iOS both-paths pattern.
                .contextMenu {
                    Button {
                        renameText = displayTitle(for: chat)
                        renamingChatID = chat.id
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        delete(chat)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppearancePalette.bgBase)
        .alert("Rename chat", isPresented: renameAlertPresented) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingChatID = nil }
            Button("Save") { commitRename() }
        } message: {
            Text("Renaming keeps this title — the model won't overwrite it.")
        }
    }

    /// Drives the rename alert off `renamingChatID`; dismissing clears the id.
    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renamingChatID != nil },
                set: { if !$0 { renamingChatID = nil } })
    }

    private func commitRename() {
        guard let id = renamingChatID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { chatStore.renameChat(id: id, title: trimmed) }
        renamingChatID = nil
    }

    private func row(for chat: Chat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayTitle(for: chat))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(relativeTime(chat.updatedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            }
            Text(preview(for: chat))
                .font(.system(size: 13))
                .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
                .foregroundStyle(AppearancePalette.ink)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                session.startNew()
                path.append(session.id)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppearancePalette.ink)
            }
        }
    }

    // MARK: - Helpers

    /// Stored title falls back to the first user message inline if it's
    /// empty (e.g. a chat whose first turn errored before commit).
    private func displayTitle(for chat: Chat) -> String {
        let trimmed = chat.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let firstUser = chat.messages.first(where: { $0.role == .user }) {
            let t = firstUser.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Untitled chat" : String(t.prefix(40))
        }
        return "Untitled chat"
    }

    private func preview(for chat: Chat) -> String {
        guard let last = chat.messages.last else { return "" }
        let collapsed = last.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return collapsed
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Order matters: if the live session is pointing at the chat being
    /// deleted, call `startNew()` BEFORE `delete(id:)`. `startNew()` →
    /// `reset()` → `flush()` re-writes the live chat (one wasted save),
    /// then `delete(id:)` removes it by id. Reversing the order would
    /// leave the still-live session holding a dangling id, and its
    /// next flush would resurrect the deleted chat under that id.
    private func delete(_ chat: Chat) {
        if chat.id == session.id {
            session.startNew()
        }
        chatStore.delete(id: chat.id)
    }
}
