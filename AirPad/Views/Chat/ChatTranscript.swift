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
///     mutation re-renders only the tail cell, never the settled rows.
///     Streaming stays O(1) per token, not O(transcript length).
///  2. THE END IS A STATE (live-30) — the transcript is a `UICollectionView`
///     (`ChatTranscriptCollection`) whose layout keeps the reader at the end
///     through every height change while they are there, and keeps their place
///     when they have scrolled up (a new turn never yanks them down).
///     live-31: on send the question moves near the top ONCE; while the answer
///     streams nothing on screen moves (it grows beneath; ↓ when it passes the bottom).
struct ChatTranscript: View {

    let session: ChatSession
    /// Whether to render the built-in composer. ChatView uses the default
    /// (true). The Librarian passes false — it keeps its own distinctive Ask
    /// field (sparkle glyph + ContextRing + cyan glow) as the composer and
    /// reuses only the transcript / tail / read-aloud / error banner here.
    /// A pure rendering flag — no host/presentation knowledge leaks in.
    var showsComposer: Bool = true
    /// Piece 2 — tap a citation (inline superscript OR footer circle) to open its
    /// source node. The host supplies this (the Librarian wires `openNode`);
    /// ChatView leaves it nil so citations only expand/collapse. Both renderings
    /// route through this ONE closure.
    var onOpenNode: ((String) -> Void)? = nil
    /// Brief AF3 — the app-owned no-key web-search notice embeds an
    /// `airpad-settings://websearch` link; the host supplies this to open Settings on
    /// the Web-search row. nil for hosts that don't present Settings (ChatView) — the
    /// link then falls through harmlessly.
    var onOpenWebSearchSettings: (() -> Void)? = nil
    /// live-23 (5b) — a declined turn's "Switch model" opens the model picker (the Librarian's pill sheet).
    var onSwitchModel: (() -> Void)? = nil
    /// live-30 — the host shows the transcript but it isn't on screen (the Librarian keeps it mounted at peek, faded
    /// to 0): its UIKit cells leave the accessibility tree, as the SwiftUI rows did when faded out.
    var hiddenFromAccessibility: Bool = false
    /// #1-followup (chat chrome reclaim) — scroll-edge fade lengths as fractions
    /// of the transcript height. Bottom defaults to the shipped 0.06 (the old
    /// hardcoded 0.94 stop); top defaults to 0 (no top fade) so other hosts
    /// (ChatView) are unchanged. The Librarian passes a non-zero top fade when
    /// the transcript extends up into the reclaimed search-bar space.
    var topFadeFraction: CGFloat = 0
    var bottomFadeFraction: CGFloat = 0.06
    /// #1-followup — reports how far the transcript is scrolled from its TOP
    /// (`visibleRect.minY`) so the host can drive a scroll-collapsing title.
    /// nil for hosts that don't want it (ChatView).
    var onScrollTopOffset: ((CGFloat) -> Void)? = nil
    /// live-27 (4b) — the composer row's leading control (the Chat view hands in the Librarian's General / Library
    /// toggle; it replaces the old "Private" label) and the send that routes a turn (the Librarian's `groundedSend`).
    /// nil = the plain chat lane (`ChatSession.send`).
    var leadingControl: AnyView? = nil
    var onSend: ((String) async -> Void)? = nil

    @State private var input: String = ""
    @FocusState private var inputFocused: Bool
    /// Brief BN5 — the app-wide Font; the cells get it through `rowContext` (a cell has no environment of its own).
    @Environment(\.appBodyFont) private var appFont
    /// Is the reader at (or within 80 pt of) the end? Drives the ↓ arrow; the collection view reports it on change.
    @State private var isPinnedToBottom = true
    /// live-30 (1) — what every cell shares: the host's actions, per-turn UI state (sources expanded, copied), the Font.
    @State private var rowContext = TranscriptRowContext()
    @State private var scroller = TranscriptScroller()
    /// A table's full-screen viewer, presented here for the cell that asked (`ChatTablePresenter`).
    @State private var presentedTable: PresentedTable?
    /// Phase 2 — the model-picker sheet (opened by tapping the Model pill).
    @State private var showPicker = false

    private struct PresentedTable: Identifiable { let id = UUID(); let table: ChatTable }

    var body: some View {
        #if DEBUG
        let _ = FreezeProbe.hit("transcript.body")
        #endif
        VStack(spacing: 0) {
            transcript
            if let error = session.lastError {
                errorBanner(error)
            }
            if showsComposer {
                // Divider separates the TRANSCRIPT from the composer (was mistakenly between the
                // pill row and the field, cramming them). The composer itself is the shared
                // ComposerScaffold — same spacing + field metrics as the Librarian's Ask composer.
                Divider().overlay(AppearancePalette.ink.opacity(0.08))
                ComposerScaffold {
                    // Placement A (T-ruled): a persistent Private · Model · Thinking row above the field.
                    // C4b2 (T ruling 2026-10-09) — whatever the pairing: the pill always names who answers and opens the picker.
                    ModelPillRow(
                        catalog: HostCatalog.shared,
                        thinkEnabled: Binding(get: { session.thinkEnabled }, set: { session.thinkEnabled = $0 }),
                        onTapModel: { showPicker = true },
                        includePrivate: leadingControl == nil,
                        leading: leadingControl
                    )
                    inputRow
                }
                .background(AppearancePalette.bgBase)
            }
        }
        .task { HostCatalog.shared.refreshPaired(); await HostCatalog.shared.refresh() } // off-render
        .sheet(isPresented: $showPicker) {
            ModelPickerSheet(
                catalog: HostCatalog.shared,
                thinkEnabled: Binding(get: { session.thinkEnabled }, set: { session.thinkEnabled = $0 })
            )
            .presentationDetents([.medium, .large])
        }
        // Conversation identity changed (new chat / switched chat): drop the
        // half-typed composer text and re-arm bottom-follow for the new thread.
        .onChange(of: session.id) { _, _ in
            input = ""
            isPinnedToBottom = true
        }
        .fullScreenCover(item: $presentedTable) { ChatTableFullScreen(table: $0.table) }
        // ★ BUG 36 Pillar 2 — foreground re-attach for EVERY chat host. This is the
        // shared component behind both ChatView and the Librarian's "Ask" panel; the
        // Librarian is a FloatingPanel-hosted VC where `@Environment(\.scenePhase)` does
        // not reliably propagate, so we key off the app-wide `didBecomeActive`
        // notification instead. On return to the foreground, re-attach to any held Host
        // result whose stream dropped while backgrounded (the true walk-away).
        // `resumeHeldIfNeeded` is idempotent + guarded, so this composes safely with
        // ChatView's own scenePhase trigger and the send()-end trigger.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await session.resumeHeldIfNeeded() }
        }
    }

    #if DEBUG
    /// Hypothesis H3 (2026-10-05 freeze lab) — no streaming tail. Measurement only.
    private static let freezeNoTail = UserDefaults.standard.bool(forKey: "FreezeNoTail")
    /// live-29 (C1) — per-change scroll geometry to stdout (`ChatTranscriptCollection` prints it).
    static let scrollGeoLog = UserDefaults.standard.bool(forKey: "ScrollGeoLog")
    /// live-30 — `-TranscriptOpenTrace YES`: what the first open of a long chat spends its time on (stdout).
    static let openTrace = UserDefaults.standard.bool(forKey: "TranscriptOpenTrace")
    #else
    private static let freezeNoTail = false
    #endif

    /// The transcript's rows, oldest first: every message, then — while an answer streams — the live Thought process
    /// and the streaming answer (Brief AE2: the thought process heads the reply).
    private var items: [TranscriptItem] {
        var out = session.messages.map { TranscriptItem.message($0.id) }
        if session.isStreaming && !session.streamingThinking.isEmpty { out.append(.thought) }
        if session.isStreaming && !Self.freezeNoTail { out.append(.tail) }
        return out
    }

    /// The cells read these; refreshed in place each render (closures and the Font can change with the host).
    private func refreshRowContext() {
        rowContext.onOpenNode = onOpenNode
        rowContext.onOpenWebSearchSettings = onOpenWebSearchSettings
        rowContext.onSwitchModel = onSwitchModel
        rowContext.onOpenTable = { presentedTable = PresentedTable(table: $0) }
        if rowContext.appFont != appFont { rowContext.appFont = appFont }
        let switches = ChatProvenance.switches(in: session.messages)   // live-27 (4) — O(n), no I/O
        if rowContext.switches != switches { rowContext.switches = switches }
    }

    // MARK: - Transcript

    /// live-30 (1) — the UIKit transcript (`ChatTranscriptCollection`): the end is a state the layout keeps, so opening a
    /// chat, ↓ and a drag to the end stay on the last line. live-31 (1): on send the question moves near the top once and
    /// the answer streams beneath it without moving anything; asking while scrolled up moves nothing at all.
    @ViewBuilder
    private var transcript: some View {
        let _ = refreshRowContext()
        ChatTranscriptCollection(
            session: session,
            items: items,
            context: rowContext,
            scroller: scroller,
            onAtEndChange: { atEnd in
                #if DEBUG
                FreezeProbe.hit("transcript.atEnd", atEnd ? 1 : 0)
                #endif
                // Animate so the scroll-to-latest arrow fades in/out rather than snapping.
                withAnimation(.easeOut(duration: 0.18)) { isPinnedToBottom = atEnd }
            },
            onScrollTopOffset: onScrollTopOffset.map { report in
                { topOffset in
                    #if DEBUG
                    FreezeProbe.hit("transcript.topOffset", Int(topOffset))
                    #endif
                    report(topOffset)
                }
            },
            onTap: { inputFocused = false },   // tap-to-dismiss the keyboard without swallowing scroll / selection
            hiddenFromAccessibility: hiddenFromAccessibility,
            topFadeFraction: topFadeFraction
        )
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if GauntletTap.shared.isOn {
                GauntletMetricsLabels()   // its own view: a label update never re-renders the transcript
            }
        }
        #endif
        .onAppear {
            #if DEBUG || TESTFLIGHT
            ChatScrollTrace.shared.event("transcript opened", messages: session.messages.count)
            #endif
        }
        // Scroll-edge fades — bottom always on; top on only when the host
        // asks (Librarian, reclaimed space). On the transcript ONLY (the
        // composer lives outside it and stays solid). Fractions are the
        // tunables (#1-followup). topFadeFraction == 0 collapses the first
        // two stops to the same location → no top fade (default).
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: topFadeFraction),
                    .init(color: .black, location: 1 - bottomFadeFraction),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        // Scroll-to-latest arrow — applied AFTER the mask so it never fades.
        .overlay(alignment: .bottom) {
            if !isPinnedToBottom {
                Button {
                    #if DEBUG || TESTFLIGHT
                    ChatScrollTrace.shared.event("↓ arrow tapped", messages: session.messages.count)
                    #endif
                    scroller.scrollToEnd()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ChatTypography.bodyText)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(AppearancePalette.ink.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to the latest message")   // live-29 (C1): it had no label (VoiceOver read "Down Arrow")
                .accessibilityIdentifier("chat.scrollToLatest")
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    // MARK: - Read/skim receipt (Brief BN5 — what the Librarian read)

    /// Pure string builder for the receipt line (BN5/BS3) — `static` so a self-test can exercise the
    /// wording without a view. Returns MARKDOWN: an entry title is wrapped in `*…*` (rendered
    /// italic). BS3: name the entry read ("Read *Lab Report* in full · skimmed 9"); a
    /// PARTIAL names the entry + model ("*Title* is too long for {model} to read at once — I used the
    /// most relevant parts."); a SURVEY says "Skimmed N entries"; nothing matched → "No matching
    /// entries". Falls back to counts when titles are absent (legacy receipts).
    static func readReceiptText(_ r: ChatSession.Message.ReadReceipt) -> String {
        func entries(_ n: Int) -> String { "\(n) entr\(n == 1 ? "y" : "ies")" }
        let titles = r.readTitles ?? []
        if r.readInFull > 0 {
            // PARTIAL — the focus entry didn't fit the model's window.
            if r.partial {
                if let first = titles.first {
                    let model = r.partialModel ?? "this model"
                    return "*\(first)* is too long for \(model) to read at once — I used the most relevant parts."
                }
                let read = "Read \(entries(r.readInFull)) (partial)"
                return r.skimmed > 0 ? "\(read) · skimmed \(r.skimmed)" : read
            }
            // FULL — name the entry (one) or count (two+).
            let read: String
            if titles.count == 1 { read = "Read *\(titles[0])* in full" }
            else { read = "Read \(entries(r.readInFull)) in full" }
            return r.skimmed > 0 ? "\(read) · skimmed \(r.skimmed)" : read
        }
        // Brief BR3 — an empty Library turn (nothing matched) still reports, so the footer never
        // silently vanishes (which read as a plain chat, not a library that looked and found nothing).
        if r.skimmed == 0 { return "No matching entries" }
        return "Skimmed \(entries(r.skimmed))"
    }

    // MARK: - Composer

    private var inputRow: some View {
        let enabled = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isStreaming && !session.isResuming
        return TextField("Message", text: $input, axis: .vertical)
            .font(.system(size: ComposerMetrics.fieldFontSize))
            .foregroundStyle(AppearancePalette.ink)
            .tint(Color(hexString: "00BFFF"))
            .focused($inputFocused)
            .lineLimit(1...6)
            .padding(.leading, 14)
            // Reserve for the INLINE send/mic control (shared with the Librarian) — the send is now
            // incorporated into the field's trailing end, not a separate circular button.
            .padding(.trailing, ComposerMetrics.sendControlReserve)
            .padding(.vertical, ComposerMetrics.fieldTextVerticalPadding)
            .frame(minHeight: ComposerMetrics.fieldSingleLineHeight)
            .background(
                RoundedRectangle(cornerRadius: ComposerMetrics.fieldCornerRadius, style: .continuous)
                    .fill(AppearancePalette.ink.opacity(0.06))
            )
            .overlay(alignment: .bottomTrailing) {
                ComposerSendControls(
                    text: $input,
                    sendEnabled: enabled,
                    onSend: {
                        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        input = ""
                        if let onSend { session.startTurn { await onSend(text) } } else { session.startTurn { await session.send(text) } }
                    },
                    dictationToken: "chat",
                    isAnswering: session.isStreaming,
                    onStop: { session.stopAnswer() }
                )
                .frame(height: ComposerMetrics.fieldLineHeight)
                .padding(.trailing, 10)
                .padding(.bottom, ComposerMetrics.fieldTextVerticalPadding)
            }
    }

    // (was sendButton — a separate trailing circle) The send arrow is now the SHARED, INLINE
    // `ComposerSendControls` mounted on the field's trailing end (see inputRow), matching the
    // Librarian's treatment: the send control is shared idiom.

    // MARK: - Error banner

    /// Transient endpoint-failure banner. Renders the session's non-message
    /// `lastError` as a distinct state so a failed send never appears as an
    /// assistant bubble. F4 — now the SHARED `FMFailureBanner` (one failure
    /// vocabulary with THE LEVER's tray). Retry re-sends the trailing user turn;
    /// × clears it.
    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        FMFailureBanner(
            message: message,
            retryDisabled: session.isStreaming,
            retryTitle: session.loadOfferTag == nil ? "Retry" : "Load and ask",
            onRetry: {
                Task {
                    if session.loadOfferTag != nil { await session.loadAndAsk() } else { await session.retryLastUserTurn() }
                }
            },
            onDismiss: { session.clearError() }
        )
    }
}

// MARK: - Streaming tail (isolated sole reader of streamingText)

/// The part of the append-only stream not yet displayed. Counted in Unicode scalars, not Characters: a scalar that
/// arrives in a later delta can join the last shown Character (U+FE0F after "➡", a ZWJ emoji's next part, an
/// accent), so a Character count drops it from the stream for the rest of the turn (CH-B gauntlet F4).
enum StreamReveal {
    static func undisplayed(_ full: String, shown: String) -> String {
        String(full.unicodeScalars.dropFirst(shown.unicodeScalars.count))
    }
}

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
/// Brief AE1 — the tail NO LONGER follow-scrolls. The reader owns the position:
/// the only programmatic scroll per exchange is the send→question-to-top; content
/// appends below the fold without moving anything above it, and the ↓ affordance is
/// the sole way to jump to the newest text.
struct StreamingTail: View {
    let session: ChatSession
    @Environment(\.appBodyFont) private var appFont

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

    var body: some View {
        Group {
            if revealedText.isEmpty && pendingText.isEmpty {
                // Brief BW5 — a slow first READ says WHAT it is doing ("Reading <Title>…" /
                // "Skimming your library…"), never a silent spinner; the stream replaces it the
                // moment the first token lands. Falls back to the shimmer for private/general chat
                // (no prefill notice). Keeps its own leading layout — not block-wrapped text.
                HStack(alignment: .top, spacing: 8) {
                    if let notice = session.prefillNotice {
                        Text(notice)
                            .font(appFont.font(size: 15, relativeTo: .body))
                            .foregroundStyle(.secondary)
                    } else {
                        ThinkingShimmerView()
                    }
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
                .environment(\.chatAnswerGutter, 40)   // live-27 (4c) — matches the settled bubble
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
        let undisplayed = StreamReveal.undisplayed(full, shown: revealedText + pendingText)
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
        let undisplayed = StreamReveal.undisplayed(full, shown: revealedText + pendingText)
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
        #if DEBUG
        GauntletTap.shared.answerFrame(revealedText + pendingText)   // Brief CH-0 — what the answer body DISPLAYS
        #endif

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
        // Brief AE1 — NO follow-scroll on chunk. The tail grows downward below the
        // fold; the reader stays put and taps ↓ to jump to the newest text.
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
    @Environment(\.appBodyFont) private var appFont

    var body: some View {
        Text("Thinking…")
            .font(ChatTypography.thinking(appFont))
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
            .mask(Text("Thinking…").font(ChatTypography.thinking(appFont)))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

/// Collapsible tool-loop activity strip (web search / fetch). Collapsed by default;
/// expands to the query/url + TAPPABLE result links. Reads by ICON + LABEL + chevron
/// shape (colourblind-safe), not colour. Reuses the panel `AppearancePalette.ink`
/// chrome; renders in both appearance modes.
struct ActivityRow: View {
    let activity: ChatSession.ToolActivity
    /// live-30 — held by the transcript (`TranscriptRowContext`), so an opened box stays open when its cell is reused.
    @Binding var expanded: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
        #if DEBUG
            // `-ToolExpandActivity YES` — start expanded so `-Screen` can shoot the
            // links row without a tap. No-op without the arg.
            .onAppear {
                if UserDefaults.standard.bool(forKey: "ToolExpandActivity") { expanded = true }
            }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: activity.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(activity.label)
                        .font(.system(size: 13, weight: .medium))
                    if !activity.links.isEmpty {
                        Text("· \(activity.links.count)")
                            .font(.system(size: 13))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
                .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let detail = activity.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(activity.links) { link in
                        Button {
                            if let url = URL(string: link.url) { openURL(url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AppearancePalette.ink)
                                    .lineLimit(2)
                                Text(link.url)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(hexString: "1B59C2"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let s = link.snippet, !s.isEmpty {
                                    Text(s)
                                        .font(.system(size: 11))
                                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppearancePalette.ink.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppearancePalette.ink.opacity(0.08), lineWidth: 1)
        )
        .padding(.trailing, 40)
    }
}
