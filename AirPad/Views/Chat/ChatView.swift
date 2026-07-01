import SwiftUI

/// Clean chat surface — passage-free FM instrument. Reachable from the
/// Dashboard header. Renders prior turns plus an in-flight tail; sends
/// to `ChatSession` which routes through `ModelRouter` with no corpus
/// passages. Visual language matches LibrarianSurface bubbles but the
/// shimmer / cursor are duplicated as private types here so this view
/// doesn't depend on Librarian internals.
struct ChatView: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var input: String = ""
    @State private var didRestoreOnAppear: Bool = false
    @FocusState private var inputFocused: Bool

    private var session: ChatSession { router.chat }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                transcript
                if let error = session.lastError {
                    errorBanner(error)
                }
                Divider().overlay(Color.white.opacity(0.08))
                inputRow
            }
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
                    input = ""
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

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(session.messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                    if session.isStreaming {
                        inFlightTail
                            .id("__tail__")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            // .simultaneousGesture (not .onTapGesture) coexists with text
            // selection on assistant bubbles and doesn't swallow scroll or
            // long-press. Sits ABOVE .scrollDismissesKeyboard so the tap
            // path works even on short transcripts that never overflow —
            // the interactive-drag dismissal only fires when content
            // actually scrolls, so a short chat would otherwise have no
            // dismissal at all.
            .simultaneousGesture(
                TapGesture().onEnded { inputFocused = false }
            )
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: session.streamingText) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if session.isStreaming {
                proxy.scrollTo("__tail__", anchor: .bottom)
            } else if let last = session.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: ChatSession.Message) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(hexString: "00BFFF").opacity(0.18))
                    )
            }
        case .assistant:
            HStack {
                assistantText(message.text)
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private func assistantText(_ raw: String) -> some View {
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .lineSpacing(5)
                .textSelection(.enabled)
        } else {
            Text(raw)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .lineSpacing(5)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var inFlightTail: some View {
        HStack(alignment: .top, spacing: 6) {
            if session.streamingText.isEmpty {
                ThinkingShimmerView()
            } else {
                assistantText(session.streamingText)
                StreamingCursorView()
            }
            Spacer(minLength: 40)
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $input, axis: .vertical)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(Color(hexString: "00BFFF"))
                .focused($inputFocused)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(white: 0.12))
                )

            sendButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black)
    }

    private var sendButton: some View {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = !trimmed.isEmpty && !session.isStreaming
        return Button {
            let text = trimmed
            input = ""
            Task { await session.send(text) }
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(
                    enabled
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color(hexString: "00BFFF"), Color(hexString: "1B59C2")],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                        : AnyShapeStyle(Color.white.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(width: 36, height: 36)
    }

    // MARK: - Error banner

    /// Transient endpoint-failure banner. Renders the session's non-message
    /// `lastError` as a distinct state (amber, Retry + dismiss) so a failed
    /// send never appears as an assistant bubble. Retry re-sends the trailing
    /// user turn; × clears it.
    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hexString: "E8820A"))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                Task { await session.retryLastUserTurn() }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hexString: "00BFFF"))
            .buttonStyle(.plain)
            .disabled(session.isStreaming)
            Button {
                session.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hexString: "E8820A").opacity(0.12))
    }
}

// MARK: - Private indicators (don't depend on LibrarianSurface internals)

private struct ThinkingShimmerView: View {
    @State private var opacity: Double = 1.0
    var body: some View {
        Text("Thinking…")
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.55))
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    opacity = 0.25
                }
            }
    }
}

private struct StreamingCursorView: View {
    @State private var visible: Bool = true
    var body: some View {
        Text("▋")
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.55))
            .opacity(visible ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}
