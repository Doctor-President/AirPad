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
    @Environment(\.scenePhase) private var scenePhase
    @State private var didRestoreOnAppear: Bool = false

    private var session: ChatSession { router.chat }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ChatTranscript(session: session)
        }
        .task {
            guard !didRestoreOnAppear else { return }
            didRestoreOnAppear = true
            await session.restoreIfNeededFromStore()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.flush() }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    session.reset()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .disabled(session.isStreaming)
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}
