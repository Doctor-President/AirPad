import SwiftUI
import AVFoundation

/// Host-agnostic chat component. Renders ONE conversation end to end —
/// transcript + isolated streaming tail + per-turn read-aloud + error banner +
/// composer — from a single `ChatSession`. It knows NOTHING about where it
/// lives: no panels, sheets, navigation, detents, or full-screen-vs-embedded.
/// Entry / exit / persistence / presentation are the HOST's job (ChatView now,
/// the Librarian sheet later). The only dependency is the session passed in.
///
/// Two perf properties are built in:
///  1. STREAMING-TAIL ISOLATION — `StreamingTail` is the SOLE reader of
///     `session.streamingText`. This body depends on `session.messages` and
///     `session.isStreaming` (a Bool) but NOT `streamingText`, so a per-token
///     mutation re-renders only the tail child, never the ForEach of settled
///     bubbles. Streaming stays O(1) per token, not O(transcript length).
///  2. READ-FROM-TOP SCROLL — a new turn reveals the query + start of the
///     answer near the TOP; the tail is followed to the bottom ONLY while the
///     user is pinned there. Scrolling up cancels follow; returning re-arms it.
///     Turn commit never yanks the viewport.
struct ChatTranscript: View {

    let session: ChatSession

    @State private var speech = SpeechSynthesisService.shared
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool
    /// Live "is the user reading at/near the bottom?" — gates the stream-follow.
    /// Assigned ONLY on change (below) so scroll geometry callbacks don't churn
    /// this body (and re-parse settled bubbles) on every frame.
    @State private var isPinnedToBottom = true

    private static let tailAnchor = "__chat_transcript_tail__"
    private static let bottomFollowThreshold: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let error = session.lastError {
                errorBanner(error)
            }
            Divider().overlay(Color.white.opacity(0.08))
            inputRow
        }
        // Conversation identity changed (new chat / switched chat): drop the
        // half-typed composer text and re-arm bottom-follow for the new thread.
        .onChange(of: session.id) { _, _ in
            input = ""
            isPinnedToBottom = true
        }
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
                        // Isolated: the ONLY reader of streamingText. Owns the
                        // pinned-only stream-follow. Its own id is the follow
                        // anchor.
                        StreamingTail(
                            session: session,
                            proxy: proxy,
                            anchor: Self.tailAnchor,
                            isPinned: { isPinnedToBottom }
                        )
                        .id(Self.tailAnchor)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            // Tap-to-dismiss the keyboard without swallowing scroll / selection.
            .simultaneousGesture(
                TapGesture().onEnded { inputFocused = false }
            )
            .scrollDismissesKeyboard(.interactively)
            // Live bottom-pinned tracking. Assign only on change so a pinned
            // stream (whose per-token scrollTo keeps distance ≈ 0) never
            // invalidates this body — the ForEach of settled bubbles stays put.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height - geo.visibleRect.maxY
            } action: { _, distanceFromBottom in
                let pinned = distanceFromBottom <= Self.bottomFollowThreshold
                if pinned != isPinnedToBottom { isPinnedToBottom = pinned }
            }
            .onChange(of: session.messages.count) { oldCount, newCount in
                // New user turn → reveal the query + START of the response near
                // the TOP (read-from-top), not the bottom. Assistant commit →
                // leave the user where they are (no yank). Bulk change (restore
                // / switch) → jump to the latest.
                if newCount == oldCount + 1, let last = session.messages.last {
                    switch last.role {
                    case .user:
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(last.id, anchor: .top)
                        }
                    case .assistant:
                        break
                    }
                } else if let last = session.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = session.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    AssistantMarkdownText(raw: message.text)
                    Spacer(minLength: 40)
                }
                // Per-turn read-aloud on settled assistant bubbles — each turn
                // independently replayable via its per-message UUID token.
                readAloudControl(message: message)
            }
        }
    }

    // MARK: - Read-aloud (per settled assistant turn)

    @ViewBuilder
    private func readAloudControl(message: ChatSession.Message) -> some View {
        if !message.text.isEmpty {
            let token = message.id.uuidString
            let isActive = speech.activeToken == token
            let showPause = isActive && speech.isSpeaking && !speech.isPaused
            let voiceSelection = Binding<String?>(
                get: { speech.selectedVoiceIdentifier },
                set: { speech.selectedVoiceIdentifier = $0 }
            )
            HStack(spacing: 14) {
                Button {
                    speech.toggle(token: token, text: message.text)
                } label: {
                    Image(systemName: showPause ? "pause" : "play")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPause ? "Pause" : "Play")

                Menu {
                    Picker("Voice", selection: voiceSelection) {
                        Text("Best available").tag(String?.none)
                        ForEach(SpeechSynthesisService.availableVoices, id: \.identifier) { v in
                            Text(Self.voiceLabel(v)).tag(Optional(v.identifier))
                        }
                    }
                } label: {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose voice")
            }
            .padding(.top, 2)
        }
    }

    private static func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium:  q = "Premium"
        case .enhanced: q = "Enhanced"
        default:        q = "Default"
        }
        return "\(v.name) — \(q)"
    }

    // MARK: - Composer

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

// MARK: - Streaming tail (isolated sole reader of streamingText)

/// The in-flight tail. Mounted only while streaming. As the SOLE view reading
/// `session.streamingText`, a per-token mutation re-renders only this child —
/// never the ForEach of settled bubbles.
///
/// CHUNKED REVEAL: `session.streamingText` (the source of truth) is untouched;
/// chunking is display-only. The PRIMARY boundary is the NEWLINE — buffered
/// tokens are revealed up to and including the last complete line, holding any
/// partial remainder for the next newline. A time window is only a SAFETY VALVE
/// so a long unbroken line still reveals progressively (deliberately long so it
/// doesn't fragment prose into token slices). An idle flush reveals any
/// remainder when the stream stops growing. Each revealed chunk fades in via a
/// run-opacity animation; already-revealed text stays put. Plain text (not
/// markdown) mid-stream — the settled bubble is markdown at commit.
///
/// Owns the pinned-only follow-scroll, driven on commit (chunk cadence).
private struct StreamingTail: View {
    let session: ChatSession
    let proxy: ScrollViewProxy
    let anchor: String
    /// LIVE read of the pinned state at commit time (not a captured Bool).
    let isPinned: () -> Bool

    /// Fully faded-in text (opacity 1); never re-animated.
    @State private var revealedText: String = ""
    /// Newest revealed chunk, currently fading in.
    @State private var pendingText: String = ""
    /// Animatable opacity of the pending chunk's run.
    @State private var pendingOpacity: Double = 1
    /// Wall-clock of the last reveal; `.distantPast` reveals the first chunk
    /// immediately.
    @State private var lastFlush: Date = .distantPast

    /// Safety valve ONLY — a long line with no newline still reveals; longer
    /// than a line's worth of tokens so it doesn't pre-empt natural breaks.
    private static let safetyWindow: TimeInterval = 0.25
    /// Idle debounce: reveal the buffered remainder when tokens stop arriving.
    private static let idleFlush: TimeInterval = 0.2
    private static let fadeDuration: TimeInterval = 0.18

    private var displayedLength: Int { revealedText.count + pendingText.count }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if revealedText.isEmpty && pendingText.isEmpty {
                ThinkingShimmerView()
            } else {
                (Text(revealedText)
                    + Text(pendingText).foregroundStyle(.white.opacity(pendingOpacity)))
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                StreamingCursorView()
            }
            Spacer(minLength: 40)
        }
        .onChange(of: session.streamingText) { _, newValue in
            reveal(from: newValue)
        }
        .onAppear {
            reveal(from: session.streamingText)
        }
        .task(id: session.streamingText) {
            // Idle / final flush: when the stream stops growing (mid-stream
            // pause), reveal any buffered remainder rather than holding a
            // trailing partial line.
            try? await Task.sleep(for: .seconds(Self.idleFlush))
            guard !Task.isCancelled else { return }
            revealAllRemaining(from: session.streamingText)
        }
    }

    /// Reveal complete lines as they arrive (newline primary; window as valve).
    private func reveal(from full: String) {
        if full.isEmpty {
            revealedText = ""
            pendingText = ""
            pendingOpacity = 1
            lastFlush = .distantPast
            return
        }
        // streamingText is append-only within a turn, so the un-displayed part
        // is exactly the suffix past what we've shown.
        let undisplayed = String(full.dropFirst(displayedLength))
        guard !undisplayed.isEmpty else { return }

        if let lastNewline = undisplayed.lastIndex(where: { $0.isNewline }) {
            commit(chunk: String(undisplayed[...lastNewline]))
            return
        }
        if Date().timeIntervalSince(lastFlush) >= Self.safetyWindow {
            commit(chunk: undisplayed)
        }
    }

    private func revealAllRemaining(from full: String) {
        let undisplayed = String(full.dropFirst(displayedLength))
        guard !undisplayed.isEmpty else { return }
        commit(chunk: undisplayed)
    }

    /// Promote the previous pending chunk, fade in the new one, and follow the
    /// bottom if the user is pinned there.
    private func commit(chunk: String) {
        revealedText += pendingText
        pendingText = chunk
        pendingOpacity = 0
        lastFlush = Date()
        withAnimation(.easeOut(duration: Self.fadeDuration)) {
            pendingOpacity = 1
        }
        if isPinned() {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }
}

// MARK: - Assistant markdown

/// Settled assistant bubble body — inline markdown, cached so a body re-eval
/// (e.g. a pinned-state flip) doesn't re-parse. Committed text is immutable, so
/// a given raw string always parses to the same AttributedString.
private struct AssistantMarkdownText: View {
    let raw: String
    var body: some View {
        Text(Self.parse(raw))
            .font(.system(size: 15))
            .foregroundStyle(.white)
            .lineSpacing(5)
            .textSelection(.enabled)
    }

    private static var cache: [String: AttributedString] = [:]
    private static func parse(_ raw: String) -> AttributedString {
        if let cached = cache[raw] { return cached }
        let result: AttributedString
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            result = attr
        } else {
            result = AttributedString(raw)
        }
        if cache.count > 200 { cache.removeAll(keepingCapacity: true) }
        cache[raw] = result
        return result
    }
}

// MARK: - Streaming indicators (canonical home; Librarian dedups here in step 3)
//
// `private` for now: LibrarianSurface still has its own file-private copies, and
// a module-internal type here would collide with them ("invalid redeclaration").
// Step 3 promotes these to internal and deletes the Librarian duplicates.

/// Silent pre-token indicator — pulsing "Thinking…" from request-fired until
/// the first streamed delta arrives.
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

/// Quiet blinking caret at the tail of the streamed text.
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
