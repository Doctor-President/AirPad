import SwiftUI
import AVFoundation
import UIKit   // UIPasteboard — footer copy + user-bubble long-press copy

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
    /// Whether to render the built-in composer. ChatView uses the default
    /// (true). The Librarian passes false — it keeps its own distinctive Ask
    /// field (sparkle glyph + ContextRing + cyan glow) as the composer and
    /// reuses only the transcript / tail / read-aloud / error banner here.
    /// A pure rendering flag — no host/presentation knowledge leaks in.
    var showsComposer: Bool = true

    @State private var speech = SpeechSynthesisService.shared
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool
    /// Live "is the user reading at/near the bottom?" — gates the stream-follow.
    /// Assigned ONLY on change (below) so scroll geometry callbacks don't churn
    /// this body (and re-parse settled bubbles) on every frame.
    @State private var isPinnedToBottom = true
    /// Per-message copy confirmation — the footer copy icon shows a checkmark
    /// for ~1.2s on the message whose id matches, then clears (mirrors
    /// SolarFlareTuningPanel.justCopied).
    @State private var copiedMessageID: UUID?
    /// Piece 1 — assistant turns whose citation footer is expanded. Collapsed by
    /// default (Claude-style); tapping toggles. No navigation yet (Piece 2).
    @State private var expandedCitations: Set<UUID> = []

    private static let tailAnchor = "__chat_transcript_tail__"
    private static let bottomFollowThreshold: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let error = session.lastError {
                errorBanner(error)
            }
            if showsComposer {
                Divider().overlay(Color.white.opacity(0.08))
                inputRow
            }
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
                // Keep the guard — it stops per-frame body churn during a
                // pinned stream. Animate so the scroll-to-latest arrow fades
                // in/out rather than snapping.
                if pinned != isPinnedToBottom {
                    withAnimation(.easeOut(duration: 0.18)) { isPinnedToBottom = pinned }
                }
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
            // Bottom scroll-edge fade — always on, both hosts, all postures.
            // On the ScrollView ONLY (the composer lives outside it and stays
            // solid). 0.94 is the tunable.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.94),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            // Scroll-to-latest arrow — applied AFTER the mask so it never
            // fades. Uses the existing isPinnedToBottom state (no new tracking).
            .overlay(alignment: .bottom) {
                if !isPinnedToBottom {
                    Button {
                        // Branch the whole call — the tail anchor is a String
                        // and a message id is a UUID, which can't share one
                        // ternary argument.
                        withAnimation(.easeOut(duration: 0.25)) {
                            if session.isStreaming {
                                proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                            } else if let last = session.messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ChatTypography.bodyText)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
                    .font(ChatTypography.userBody)
                    .foregroundStyle(ChatTypography.userBubbleText)
                    .lineSpacing(ChatTypography.userLine)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(hexString: "00BFFF").opacity(0.18))
                    )
                    // On the bubble composite (its textSelection is off), so the
                    // long-press has no selection gesture to fight.
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                // Block-laid-out markdown. Full width minus a 40pt right
                // gutter (the block VStack is greedy — its bullet rows use
                // maxWidth:.infinity — so it takes an explicit frame + trailing
                // padding rather than an HStack Spacer, which it would fight).
                MarkdownBlockText(raw: message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 40)
                // Piece 1 — collapsible grounded-Ask sources (chrome, not content).
                citationFooter(message: message)
                // Per-turn read-aloud on settled assistant bubbles — each turn
                // independently replayable via its per-message UUID token.
                readAloudControl(message: message)
            }
        }
    }

    // MARK: - Citation footer (Piece 1 — collapsible grounded sources)

    @ViewBuilder
    private func citationFooter(message: ChatSession.Message) -> some View {
        if let citations = message.citations, !citations.isEmpty {
            let isExpanded = expandedCitations.contains(message.id)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if isExpanded { expandedCitations.remove(message.id) }
                    else { expandedCitations.insert(message.id) }
                } label: {
                    HStack(spacing: 6) {
                        // Tapping only expands/collapses — no navigation (Piece 2).
                        Text("◇ \(citations.count) source\(citations.count == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide sources" : "Show \(citations.count) sources")

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(citations) { c in
                            HStack(alignment: .top, spacing: 8) {
                                Text("[\(c.index)]")
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.75))
                                    Text(c.snippet)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
            .padding(.top, 2)
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

                // Copy the assistant turn's plain text; icon confirms for ~1.2s.
                Button {
                    UIPasteboard.general.string = message.text
                    copiedMessageID = message.id
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1200))
                        if copiedMessageID == message.id { copiedMessageID = nil }
                    }
                } label: {
                    Image(systemName: copiedMessageID == message.id ? "checkmark" : "doc.on.doc")
                        .font(ChatTypography.footerIcon)
                        .foregroundStyle(ChatTypography.secondaryText)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy message")

                // Regenerate — LAST assistant turn only; disabled mid-stream.
                if message.id == session.messages.last?.id {
                    Button {
                        Task { await session.regenerateLast() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(ChatTypography.footerIcon)
                            .foregroundStyle(ChatTypography.secondaryText)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isStreaming)
                    .accessibilityLabel("Regenerate response")
                }
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
/// remainder when the stream stops growing. Each newly-revealed BLOCK fades in;
/// already-revealed blocks stay put. The tail renders the SAME MarkdownBlock
/// layout the settled bubble does — parsed from `revealedText + pendingText` in
/// `commit()` and held in `@State` — so nothing reflows when the stream ends.
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
    /// Animatable opacity of the newest (last) block.
    @State private var pendingOpacity: Double = 1
    /// Parsed blocks of `revealedText + pendingText`. Written ONLY from
    /// `commit(chunk:)` and the reset path — never in `body` (body re-evals
    /// per token; parsing there would run the parser on the full response on
    /// every token). Chunk commits are newline-gated, so the parse is cheap.
    @State private var blocks: [MarkdownBlock] = []
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
        Group {
            if revealedText.isEmpty && pendingText.isEmpty {
                // Pre-token indicator keeps its own leading layout — it is not
                // text and does not need to match the block wrapper.
                HStack(alignment: .top, spacing: 6) {
                    ThinkingShimmerView()
                    Spacer(minLength: 40)
                }
            } else {
                // Render the SAME blocks the settled bubble renders (parsed in
                // commit(), held in @State) so nothing reflows at commit. Only
                // the newest block carries the fade. Key on OFFSET — a block's
                // only identity is position, so two identical bullets don't
                // collapse mid-stream. No trailing caret: the block fade-in
                // already signals liveness (retired). Wrapper MATCHES the
                // settled bubble (3.4): greedy frame + 40pt trailing gutter,
                // not an HStack Spacer, or the text reflows to a new width at
                // commit.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        MarkdownBlockView(block: block)
                            .opacity(index == blocks.count - 1 ? pendingOpacity : 1)
                            .padding(.top, BlockSpacing.topPad(
                                index: index, blocks: blocks,
                                listSpacing: ChatTypography.listSpacing,
                                blockSpacing: ChatTypography.blockSpacing,
                                headingSpaceBefore: ChatTypography.headingSpaceBefore))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 40)
            }
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
            blocks = []
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

    /// Promote the previous pending chunk, re-parse the full displayed text
    /// into blocks, fade in the newest block ONLY when a block boundary was
    /// crossed, and follow the bottom if the user is pinned there.
    private func commit(chunk: String) {
        revealedText += pendingText
        pendingText = chunk
        lastFlush = Date()

        // Parse the CONCATENATION, never the two strings separately: the
        // revealed/pending split is a character boundary, not a block one, so
        // parsing apart would split one paragraph into two blocks with a seam.
        let newBlocks = MarkdownBlockParser.parse(revealedText + pendingText)
        // Fade off BLOCK COUNT, not chunk arrival: a chunk that only extends
        // the current last block must not re-fade text the user is reading.
        let gainedBlock = newBlocks.count > blocks.count
        blocks = newBlocks
        if gainedBlock {
            pendingOpacity = 0
            withAnimation(.easeOut(duration: Self.fadeDuration)) {
                pendingOpacity = 1
            }
        }
        if isPinned() {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }
}

// MARK: - Streaming indicators

// `private` and the sole copy: LibrarianSurface adopted the shared
// ChatTranscript component, so it renders this indicator too — there is no
// Librarian duplicate to keep in sync (the old "promote in step 3" note is
// obsolete).

/// Silent pre-token indicator — a highlight sweeps L→R across "Thinking…"
/// from request-fired until the first streamed delta arrives. Reduce Motion:
/// static text, no overlay, no animation (NOT a fallback opacity pulse).
private struct ThinkingShimmerView: View {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("Thinking…")
            .font(ChatTypography.thinking)
            .foregroundStyle(ChatTypography.secondaryText)
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Color(hexString: "F5F3F0").opacity(0.9), location: 0.5),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 90)
                    .offset(x: phase * 160)
                    .blendMode(.plusLighter)
                }
            }
            .mask(Text("Thinking…").font(ChatTypography.thinking))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
