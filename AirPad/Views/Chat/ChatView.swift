import SwiftUI

/// Full-screen chat host — passage-free FM instrument, reachable from the
/// Dashboard header. Thin by design: it owns the CHROME (black background,
/// navigation title, new-chat toolbar) and the HOST lifecycle (restore on
/// appear, flush on background) and delegates the entire conversation —
/// transcript, streaming tail, read-aloud, error banner, composer — to the
/// host-agnostic `ChatTranscript`. The same component backs the Librarian
/// chat lane (step 3).
struct ChatView: View {

    @Environment(AppRouter.self) private var router
    @Environment(CorpusStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var didRestoreOnAppear: Bool = false
    @State private var showingPinSheet: Bool = false

    private var session: ChatSession { router.chat }
    private var isPinned: Bool { store.nodePinned(forChatID: session.id) != nil }

    var body: some View {
        ZStack {
            AppearancePalette.bgBase.ignoresSafeArea()
            ChatTranscript(session: session)
        }
        .task {
            guard !didRestoreOnAppear else { return }
            didRestoreOnAppear = true
            await session.restoreIfNeededFromStore()
            // BUG 36 Pillar 2 — a cold launch that restored a dropped Host partial (an app
            // KILL mid-stream) re-attaches to the held answer right away (D3, the app-kill case).
            await session.resumeHeldIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                session.flush()
            case .active:
                // Returning to the foreground: re-attach to any held Host result whose stream
                // dropped while we were backgrounded — the true walk-away (BUG 36 Pillar 2).
                Task { await session.resumeHeldIfNeeded() }
            default:
                break
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Pin this chat to a node (ws-chat-lane). Filled = already pinned
                // (shape, not hue — T is colorblind). Flush first so the chat is
                // persisted in ChatStore and resolves in the node's Chats entry.
                Button {
                    session.flush()
                    showingPinSheet = true
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink)
                }
                .accessibilityLabel(isPinned ? "Change pinned node" : "Pin chat to a node")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    session.reset()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink)
                }
                .disabled(session.isStreaming || session.isResuming)
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showingPinSheet) {
            PinChatSheet(chatID: session.id).environment(store)
        }
    }
}
