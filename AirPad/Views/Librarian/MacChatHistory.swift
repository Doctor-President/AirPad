#if targetEnvironment(macCatalyst)
import SwiftUI

/// E fix-up G5 (T ruled 2026-11-14: "unify") — on the Mac the chats live in the Librarian panel: its clock, the
/// sidebar's Chats and "All chats" show this list IN the panel (no Chats sheet). Every chat, newest first; a click
/// continues it in the panel; right-click or the row's ··· renames, pins to an entry, deletes (as the phone's list).
struct MacChatHistory: View {
    let onOpen: (Chat) -> Void
    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(\.appBodyFont) private var appFont

    @State private var renamingChatID: UUID?
    @State private var renameText = ""
    @State private var pinningChatID: UUID?
    @State private var pendingDeleteChat: Chat?
    @State private var pendingDeleteNodeName = ""

    private var chats: [Chat] { router.chatStore.chats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if chats.isEmpty {
                    Text("No chats yet. Ask below to start one.")
                        .font(appFont.font(size: 13))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                        .padding(.vertical, 10)
                } else {
                    ForEach(chats) { chat in
                        MacChatHistoryRow(chat: chat, pinnedTo: store.nodePinned(forChatID: chat.id)?.title,
                                          onOpen: { onOpen(chat) },
                                          onRename: { renameText = ChatsEntryBody.displayTitle(chat); renamingChatID = chat.id },
                                          onPin: { pinningChatID = chat.id },
                                          onDelete: { delete(chat) })
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .task { await router.chatStore.loadIfNeeded() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("macChatHistory")
        .alert("Rename chat", isPresented: Binding(get: { renamingChatID != nil }, set: { if !$0 { renamingChatID = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingChatID = nil }
            Button("Save") {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = renamingChatID, !t.isEmpty { router.chatStore.renameChat(id: id, title: t) }
                renamingChatID = nil
            }
        }
        .alert("Delete pinned chat?", isPresented: Binding(get: { pendingDeleteChat != nil }, set: { if !$0 { pendingDeleteChat = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeleteChat = nil }
            Button("Delete", role: .destructive) {
                if let c = pendingDeleteChat { performDelete(c) }
                pendingDeleteChat = nil
            }
        } message: {
            Text("This chat is pinned to \(pendingDeleteNodeName). Deleting it removes it from that entry too.")
        }
        .appSheet(isPresented: Binding(get: { pinningChatID != nil }, set: { if !$0 { pinningChatID = nil } })) {
            if let id = pinningChatID { PinChatSheet(chatID: id).environment(store) }
        }
    }

    /// As the phone's list: a pinned chat asks first (it leaves its entry too).
    private func delete(_ chat: Chat) {
        if let node = store.nodePinned(forChatID: chat.id) {
            pendingDeleteNodeName = node.title.isEmpty ? "Untitled" : node.title
            pendingDeleteChat = chat
        } else {
            performDelete(chat)
        }
    }

    /// The live session moves off a chat before it's deleted (else its next flush would bring it back).
    private func performDelete(_ chat: Chat) {
        if chat.id == router.chat.id { router.chat.startNew() }
        router.chatStore.delete(id: chat.id)
        Task { await store.unpinChat(chatID: chat.id) }
    }
}

private struct MacChatHistoryRow: View {
    let chat: Chat
    let pinnedTo: String?
    let onOpen: () -> Void
    let onRename: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @Environment(\.appBodyFont) private var appFont
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ChatsEntryBody.displayTitle(chat))
                            .font(appFont.font(size: 13, weight: .medium))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.9))
                            .lineLimit(1)
                        if let pinnedTo {
                            Label(pinnedTo.isEmpty ? "Untitled" : pinnedTo, systemImage: "pin")
                                .font(appFont.font(size: 11.5))
                                .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(chat.updatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                        .font(appFont.font(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("macChatHistoryRow")
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).frame(width: 22, height: 22)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(AppearancePalette.ink.opacity(hovering ? 0.7 : 0.3))
            .help("Rename, pin or delete")
            .accessibilityLabel("Chat actions")
            .accessibilityIdentifier("macChatHistoryActions")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppearancePalette.ink.opacity(hovering ? 0.05 : 0)))
        .overlay(alignment: .top) { Rectangle().fill(AppearancePalette.ink.opacity(0.08)).frame(height: 1).padding(.horizontal, 6) }
        .onHover { hovering = $0 }
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button(action: onOpen) { Label("Open", systemImage: "bubble.left") }
        Button(action: onRename) { Label("Rename", systemImage: "pencil") }
        Button(action: onPin) { Label(pinnedTo != nil ? "Change pin…" : "Pin to entry…", systemImage: "pin") }
        Divider()
        Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
    }
}
#endif

/// E fix-up G6 — the Librarian's first-open sections T can hide (remembered; View › Librarian shows them again).
enum MacLibrarianHome {
    static let hideTryKey = "mac.librarian.hideTry.v1"
    static let hideRecentKey = "mac.librarian.hideRecent.v1"
}
