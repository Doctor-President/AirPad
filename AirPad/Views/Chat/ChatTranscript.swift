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

    @State private var speech = SpeechSynthesisService.shared
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool
    /// Ambient URL opener — web-citation chips (real scraped URLs) open through this.
    /// (Corpus chips navigate to a node via `onOpenNode` instead.)
    @Environment(\.openURL) private var openURL
    /// Brief BN5 — the app-wide Font (serif/SF face), so the read/skim receipt line follows the Font.
    @Environment(\.appBodyFont) private var appFont
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
    /// Phase 2 — the model-picker sheet (opened by tapping the Model pill).
    @State private var showPicker = false

    private static let tailAnchor = "__chat_transcript_tail__"
    private static let bottomFollowThreshold: CGFloat = 80

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
                    if HostCatalog.shared.isPaired {
                        // Placement A (T-ruled): a persistent Private · Model · Thinking row above the field.
                        ModelPillRow(
                            catalog: HostCatalog.shared,
                            thinkEnabled: Binding(get: { session.thinkEnabled }, set: { session.thinkEnabled = $0 }),
                            onTapModel: { showPicker = true }
                        )
                    }
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
    /// Measurement only (perf A/B + freeze repro): `-FreezeLazyStack YES` = the pre-fix all-lazy stack;
    /// `-FreezeEagerAll YES` = every row eager (the first fix, which failed the scroll perf gate).
    private static let freezeLazyStack = UserDefaults.standard.bool(forKey: "FreezeLazyStack")
    private static let freezeEagerAll = UserDefaults.standard.bool(forKey: "FreezeEagerAll")
    /// Hypothesis H3 — the streaming tail is the oscillating lazy row. Measurement only.
    private static let freezeNoTail = UserDefaults.standard.bool(forKey: "FreezeNoTail")
    #else
    private static let freezeNoTail = false
    #endif

    /// Index of the LATEST exchange: the last user message onward (its answer, plus the live Thought
    /// process / streaming tail while it streams).
    private var liveStart: Int {
        session.messages.lastIndex(where: { $0.role == .user }) ?? session.messages.count
    }

    /// FREEZE FIX (V1 mitigation, CH Session 2) — a chat of up to `eagerAllLimit` messages renders
    /// EVERY row eagerly, so it has no lazy row at all and the lazy-stack layout loop cannot happen. Every
    /// freeze observed so far was in such a chat: keyboard dismiss after the 5th turn (10 messages), the
    /// turn-5 web chat (~14), the follow-up after a short answer. A longer chat keeps option 1 (lazy history
    /// + eager latest exchange), which passed the 200-message scroll gate.
    /// Measured and rejected (Session 2): "the newest 20 eager, the rest lazy" put the lazy/eager boundary
    /// MID-content, and a fling through it looped (main thread busy 30 s, 2 of 2 runs, content 60,336 ↔
    /// 60,436 pt at the boundary). The durable fix is the UIKit transcript (1.1).
    /// DEBUG `-TranscriptEagerAll 0` = the old split everywhere (the A/B baseline).
    #if DEBUG
    private static let eagerAllLimit: Int = {
        let d = UserDefaults.standard
        return d.object(forKey: "TranscriptEagerAll") == nil ? 24 : max(0, d.integer(forKey: "TranscriptEagerAll"))
    }()
    #else
    private static let eagerAllLimit = 24
    #endif

    /// Where the lazy history ends: nowhere in a short chat (all eager), else the latest exchange.
    private var eagerStart: Int {
        session.messages.count <= Self.eagerAllLimit ? 0 : liveStart
    }

    /// The transcript rows (Brief CH follow-up freeze, 2026-10-04). Settled HISTORY stays in a
    /// `LazyVStack` (a long chat must scroll at full frame rate — an all-eager stack measured ~30 fps
    /// flings on a 100-turn chat); the LATEST exchange renders in an eager `VStack` below it. Why: on
    /// iOS 26+ a lazy stack whose trailing row (the 18 pt streaming tail, or the just-sent user bubble)
    /// sits at the materialisation edge never reaches a layout fixed point — measured it shrinks the
    /// stack, estimated (~ the average row height) it grows it, so materialisation flips every pass and
    /// the main thread spins forever (Apple Forums 805306). The rows that appear and change size during a
    /// turn are therefore never estimated.
    @ViewBuilder
    private var rows: some View {
        #if DEBUG
        if Self.freezeLazyStack {
            LazyVStack(alignment: .leading, spacing: 18) { historyRows(0..<session.messages.count); liveTail }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)
        } else if Self.freezeEagerAll {
            VStack(alignment: .leading, spacing: 18) { historyRows(0..<session.messages.count); liveTail }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)
        } else {
            splitRows
        }
        #else
        splitRows
        #endif
    }

    @ViewBuilder
    private var splitRows: some View {
        let split = eagerStart
        VStack(alignment: .leading, spacing: 18) {
            if split > 0 {
                LazyVStack(alignment: .leading, spacing: 18) { historyRows(0..<split) }
            }
            historyRows(split..<session.messages.count)
            liveTail
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)
    }

    @ViewBuilder
    private func historyRows(_ range: Range<Int>) -> some View {
        ForEach(session.messages[range]) { message in
            bubble(for: message)
                .id(message.id)
                #if DEBUG
                .freezeRowProbe("row.\(message.role)")
                #endif
        }
    }

    @ViewBuilder
    private var liveTail: some View {
        if session.isStreaming && !session.streamingThinking.isEmpty {
            // Brief AE2 — while streaming, the thought process renders at the
            // HEAD of the reply (before the answer tail). On completion it
            // moves INTO the committed assistant bubble's top (same position),
            // so it never jumps below the answer/sources.
            ThoughtProcessBlock(session: session)
                .id("__thought_process__")
        }
        if session.isStreaming && !Self.freezeNoTail {
            // Isolated: the ONLY reader of streamingText. Its own id is the ↓
            // jump anchor (Brief AE1 — no automatic follow-scroll).
            StreamingTail(session: session)
                .id(Self.tailAnchor)
                #if DEBUG
                .freezeRowProbe("row.tail")
                #endif
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                rows
            }
            #if DEBUG
            // Perf gate: the first committed layout of the transcript (one runloop after mount).
            .onAppear { DispatchQueue.main.async { GauntletMetrics.shared.transcriptLaidOut(messages: session.messages.count) } }
            .overlay(alignment: .topLeading) {
                if GauntletTap.shared.isOn {
                    GauntletMetricsLabels()   // its own view: a label update never re-renders the transcript
                }
            }
            #endif
            // Tap-to-dismiss the keyboard without swallowing scroll / selection.
            .simultaneousGesture(
                TapGesture().onEnded { inputFocused = false }
            )
            .scrollDismissesKeyboard(.interactively)
            // Live bottom-pinned tracking. Assign only on change so a pinned
            // stream (whose per-token scrollTo keeps distance ≈ 0) never
            // invalidates this body — the ForEach of settled bubbles stays put.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                #if DEBUG
                FreezeProbe.hit("geo.transform", "content=\(Int(geo.contentSize.height)) container=\(Int(geo.containerSize.height)) offY=\(Int(geo.contentOffset.y)) visMaxY=\(Int(geo.visibleRect.maxY)) insetT=\(Int(geo.contentInsets.top)) insetB=\(Int(geo.contentInsets.bottom))")
                StreamGeoRecorder.shared.note(content: geo.contentSize.height, offset: geo.contentOffset.y, streaming: session.isStreaming)
                #endif
                return geo.contentSize.height - geo.visibleRect.maxY
            } action: { _, distanceFromBottom in
                #if DEBUG
                FreezeProbe.hit("transcript.distFromBottom", Int(distanceFromBottom))
                #endif
                let pinned = distanceFromBottom <= Self.bottomFollowThreshold
                // Keep the guard — it stops per-frame body churn during a
                // pinned stream. Animate so the scroll-to-latest arrow fades
                // in/out rather than snapping.
                if pinned != isPinnedToBottom {
                    withAnimation(.easeOut(duration: 0.18)) { isPinnedToBottom = pinned }
                }
            }
            // #1-followup — report scroll distance from the TOP so the host can
            // drive a scroll-collapsing title. Only wired when a host opts in.
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.visibleRect.minY
            } action: { _, topOffset in
                #if DEBUG
                FreezeProbe.hit("transcript.topOffset", Int(topOffset))
                #endif
                onScrollTopOffset?(topOffset)
            }
            .onChange(of: session.messages.count) { oldCount, newCount in
                #if DEBUG
                FreezeProbe.hit("transcript.msgCount", newCount)
                #endif
                // New user turn → reveal the query + START of the response near
                // the TOP (read-from-top), not the bottom. Assistant commit →
                // leave the user where they are (no yank). Bulk change (restore
                // / switch) → jump to the latest.
                if newCount == oldCount + 1, let last = session.messages.last {
                    switch last.role {
                    case .user:
                        // NOT animated (Brief CH follow-up freeze): the animated scroll-to-top moved the
                        // trailing row across the lazy materialisation edge each frame and was one of the
                        // triggers. A jump lands the question at the top in one layout.
                        proxy.scrollTo(last.id, anchor: .top)
                    case .assistant:
                        break
                    case .activity:
                        // Reveal each tool phase as it lands so the search is visible.
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
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
            // Scroll-edge fades — bottom always on; top on only when the host
            // asks (Librarian, reclaimed space). On the ScrollView ONLY (the
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
                            .overlay(Circle().strokeBorder(AppearancePalette.ink.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

    /// Brief AE2 — the latest turn's ephemeral thought process renders inside its
    /// (now-committed) assistant bubble, at the top. True only for the LAST message
    /// once streaming has ended and thinking was captured; on the next send
    /// `streamingThinking` resets and this prior turn's panel disappears (ephemeral).
    private func showsCompletedThoughtProcess(_ message: ChatSession.Message) -> Bool {
        message.role == .assistant
            && !session.isStreaming
            && message.id == session.messages.last?.id
            && !session.streamingThinking.isEmpty
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
                            // Per-mode (ChatTypography): dark cyan@0.18 byte-identical;
                            // light bolder cyan@0.90 so the bubble reads on cream.
                            .fill(ChatTypography.userBubbleFillResolved)
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
                // Brief AE2 — the just-completed turn's thought process stays at the
                // HEAD of the reply (above the answer), the same place it streamed;
                // it does NOT relocate below the sources. Ephemeral `streamingThinking`
                // is retained until the next send, and `ThoughtProcessBlock` reads it
                // statically (isStreaming == false → collapsed one-line header).
                if showsCompletedThoughtProcess(message) {
                    ThoughtProcessBlock(session: session)
                }
                // Block-laid-out markdown. Full width minus a 40pt right
                // gutter (the block VStack is greedy — its bullet rows use
                // maxWidth:.infinity — so it takes an explicit frame + trailing
                // padding rather than an HStack Spacer, which it would fight).
                MarkdownBlockText(raw: message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 40)
                    #if DEBUG
                    .gauntletID("chat.answer", combine: true)   // Brief CH-0 — XCUITest reads the on-screen answer
                    #endif
                // Brief BN5 — "Read 1 entry in full · skimmed 6" / "Skimmed 9 entries".
                readReceiptLine(message: message)
                // Piece 1 — collapsible grounded-Ask sources (chrome, not content).
                citationFooter(message: message)
                // ★ BUG 36 — a turn that stopped early (stream dropped while
                // backgrounded): calm resume affordance, never a red banner.
                if message.isPartial == true {
                    partialResumeControl(message: message)
                }
                // Per-turn read-aloud on settled assistant bubbles — each turn
                // independently replayable via its per-message UUID token.
                readAloudControl(message: message)
            }
            // Piece 2 — inline superscript taps arrive as `airpad-citation://n`
            // links. Resolve n against THIS turn's citations → source node →
            // onOpenNode (same closure the footer circles use). Non-citation
            // links fall through to the system handler.
            .environment(\.openURL, OpenURLAction { url in
                // Brief AF3 — the no-key web-search notice's tap: open Settings on the
                // Web-search row. Checked before citations (distinct scheme).
                if url.scheme == "airpad-settings", url.host == "websearch" {
                    onOpenWebSearchSettings?()
                    return .handled
                }
                if let n = CitationReference.index(from: url),
                   let cite = message.citations?.first(where: { $0.index == n }) {
                    // Web citation → open the real scraped URL; corpus citation →
                    // navigate to the node (as today).
                    if let nodeID = cite.nodeID {
                        onOpenNode?(nodeID)
                        return .handled
                    }
                    if let urlStr = cite.url, let real = URL(string: urlStr) {
                        return .systemAction(real)
                    }
                }
                return .systemAction
            })
        case .activity:
            // Tool-loop phase (web search / fetch) — a collapsible activity strip,
            // collapsed by default, expandable to the query + tappable links.
            if let activity = message.activity {
                ActivityRow(activity: activity)
            }
        }
    }

    // MARK: - Read/skim receipt (Brief BN5 — what the Librarian read)

    /// Brief BN5 — under the answer: "Read 1 entry in full · skimmed 6" on a READ turn (singular/
    /// plural, and "(partial)" when the focus entry didn't fully fit the budget), or "Skimmed 9
    /// entries" on a SURVEY turn. Counts come from the packet (`Message.ReadReceipt`), independent of
    /// the citation chips — a full read the model didn't superscript still reads "Read 1 entry".
    /// Follows the app Font (serif/SF face), matching the answer's voice; warm-grey like the sources
    /// header. Rendered only for Librarian turns that carry a receipt (plain/General chat has none).
    @ViewBuilder
    private func readReceiptLine(message: ChatSession.Message) -> some View {
        if let r = message.readReceipt {
            // BS3 — the entry title is emphasised (markdown `*…*`); the whole line follows the Font.
            let md = Self.readReceiptText(r)
            let attributed = (try? AttributedString(markdown: md)) ?? AttributedString(md)
            Text(attributed)
                .font(appFont.font(size: 13, relativeTo: .footnote))
                .foregroundStyle(ChatTypography.secondaryText)
                .padding(.top, 1)
                .accessibilityLabel(md.replacingOccurrences(of: "*", with: ""))
        }
    }

    /// Pure string builder for the receipt line (BN5/BS3) — `static` so a self-test can exercise the
    /// wording without a view. Returns MARKDOWN: an entry title is wrapped in `*…*` (rendered
    /// italic). BS3: name the entry read ("Read *Medical – Lab Tests* in full · skimmed 9"); a
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

    // MARK: - Citation footer (Piece 1 — collapsible grounded sources)

    @ViewBuilder
    private func citationFooter(message: ChatSession.Message) -> some View {
        if let citations = message.citations, !citations.isEmpty {
            // Citations are stored PER-BLOCK (each inline [n] carries its own
            // nodeID) so inline taps resolve. The footer, though, lists SOURCES —
            // dedup by node (first occurrence wins its circle number) so two
            // passages from one node read as one source, not two.
            let sources: [ChatSession.Message.Citation] = {
                var seen = Set<String>()
                // Dedup by source identity — nodeID (corpus) or url (web); fall back to
                // the index so a malformed citation still shows once.
                return citations.filter { seen.insert($0.nodeID ?? $0.url ?? "\($0.index)").inserted }
            }()
            #if DEBUG
            // `-CitationExpand YES` — start expanded so `-Screen` can shoot the chips.
            let forceExpand = UserDefaults.standard.bool(forKey: "CitationExpand")
            #else
            let forceExpand = false
            #endif
            let isExpanded = forceExpand || expandedCitations.contains(message.id)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if isExpanded { expandedCitations.remove(message.id) }
                    else { expandedCitations.insert(message.id) }
                } label: {
                    HStack(spacing: 6) {
                        // Tapping the header only expands/collapses. Navigation
                        // lives on the individual source rows (Piece 2).
                        Text("◇ \(sources.count) source\(sources.count == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide sources" : "Show \(sources.count) sources")

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sources) { c in
                            // Piece 2 — tapping a source row opens its node,
                            // identical to tapping the inline superscript. Both
                            // route through onOpenNode. No-op when the host
                            // didn't supply one (ChatView).
                            Button {
                                // Web chip → open the real scraped URL; corpus chip →
                                // navigate to the node.
                                if let urlStr = c.url, let real = URL(string: urlStr) {
                                    openURL(real)
                                } else if let nodeID = c.nodeID {
                                    onOpenNode?(nodeID)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    // Footer marker: solid ENCIRCLED number (the
                                    // destination), distinct from the light inline
                                    // superscript. Monochrome. No brackets.
                                    Image(systemName: CitationReference.footerSymbolName(c.index))
                                        .font(.system(size: 15))
                                        .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(AppearancePalette.ink.opacity(0.75))
                                        Text(c.snippet)
                                            .font(.system(size: 12))
                                            .foregroundStyle(AppearancePalette.ink.opacity(0.45))
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(onOpenNode == nil ? "" : "Opens \(c.title)")
                            #if DEBUG
                            .gauntletID("chat.source")   // Brief CH-0 — the rendered citation chip
                            #endif
                        }
                    }
                    .padding(.leading, 2)
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: - Partial-turn resume (BUG 36)

    /// A turn that stopped early — the stream dropped while the app was
    /// backgrounded, so the text shown is what arrived before the drop, KEPT
    /// (not discarded) and persisted. Calm, quiet affordance (icon + word,
    /// shape not hue — T is colorblind), never the red failure banner. "Continue"
    /// resumes onto this same bubble; shown only on the trailing turn (that's
    /// what `continuePartial()` merges onto), older partials just read as stopped.
    @ViewBuilder
    private func partialResumeControl(message: ChatSession.Message) -> some View {
        let isLast = message.id == session.messages.last?.id
        HStack(spacing: 10) {
            if isLast && session.isResuming {
                // ★ BUG 36 Pillar 2 — auto re-attaching to the held FULL answer on the Host.
                ProgressView().controlSize(.mini)
                Text("Resuming…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
            } else {
                Label("Stopped early", systemImage: "pause.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                if isLast {
                    Button {
                        Task { await session.continuePartial() }
                    } label: {
                        Label("Continue", systemImage: "arrow.turn.down.right")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hexString: "00BFFF"))
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isStreaming || session.isResuming)
                    .accessibilityLabel("Continue the answer")
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Read-aloud (per settled assistant turn)

    @ViewBuilder
    private func readAloudControl(message: ChatSession.Message) -> some View {
        if !message.text.isEmpty {
            let token = message.id.uuidString
            let isActive = speech.activeToken == token
            let showPause = isActive && speech.isSpeaking && !speech.isPaused
            // Drives the AVSpeech voice the service reads aloud with — this
            // footer IS the real control, not a parallel one.
            let systemSelection = Binding<String?>(
                get: { speech.selectedVoiceIdentifier },
                set: { speech.selectedVoiceIdentifier = $0 }
            )
            HStack(spacing: 14) {
                Button {
                    speech.toggle(token: token, text: message.text)
                } label: {
                    Image(systemName: showPause ? "pause" : "play")
                        .font(.system(size: 22))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.6))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPause ? "Pause" : "Play")

                Menu {
                    Picker("Voice", selection: systemSelection) {
                        Text("Best available").tag(String?.none)
                        ForEach(SpeechSynthesisService.availableVoices, id: \.identifier) { v in
                            Text(Self.voiceLabel(v)).tag(Optional(v.identifier))
                        }
                    }
                } label: {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 15))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.45))
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
                    .disabled(session.isStreaming || session.isResuming)
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
                        Task { await session.send(text) }
                    },
                    dictationToken: "chat"
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
private struct StreamingTail: View {
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

    private var displayedLength: Int { revealedText.count + pendingText.count }

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
private struct ActivityRow: View {
    let activity: ChatSession.ToolActivity
    @State private var expanded = false
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
