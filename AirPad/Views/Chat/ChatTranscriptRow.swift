import SwiftUI
import AVFoundation
import UIKit   // UIPasteboard — footer copy + user-bubble long-press copy

/// live-30 (1) — one row of the UIKit transcript (`ChatTranscriptCollection`). Each row is a self-sizing collection-view
/// cell whose content is this SwiftUI view (`UIHostingConfiguration`). The rows are the old `ChatTranscript` bubbles,
/// moved here unchanged; what a cell can't keep on its own (it is reused, and it has no environment from the transcript)
/// lives in `TranscriptRowContext`: the host's actions, the per-turn UI state (sources expanded, copied, a search box
/// expanded) and the app Font.
enum TranscriptItem: Hashable {
    case message(UUID)
    /// The live "Thought process" while an answer streams (it moves into the answer's bubble when the answer commits).
    case thought
    /// The streaming answer (`StreamingTail`, the only reader of `session.streamingText`).
    case tail
}

/// Shared by every cell of one transcript. A reference type: a cell keeps it across reuse, and the transcript updates
/// it in place (new closures, a new Font) without reconfiguring cells; rows observe what they read.
@Observable
final class TranscriptRowContext {
    @ObservationIgnored var onOpenNode: ((String) -> Void)?
    @ObservationIgnored var onOpenWebSearchSettings: (() -> Void)?
    @ObservationIgnored var onSwitchModel: (() -> Void)?
    /// A table's expand control presents from the transcript (a cell's hosting configuration has no controller to
    /// present from).
    @ObservationIgnored var onOpenTable: ((ChatTable) -> Void)?
    var appFont: EntryBodyFont = .fallback
    /// Piece 1 — assistant turns whose citation footer is expanded (collapsed by default).
    var expandedCitations: Set<UUID> = []
    /// The footer copy icon shows a checkmark for ~1.2 s on this message.
    var copiedMessageID: UUID?
    /// A "Searched the web" box the reader opened (kept when its cell scrolls away and back).
    var expandedActivities: Set<UUID> = []
    /// live-27 (4) — "Switched to <model>" above the answers where the model changes, by message id.
    var switches: [UUID: String] = [:]
}

/// The content of one cell.
struct TranscriptItemView: View {
    #if DEBUG
    static let cellSpace = "transcriptCell"
    #endif
    let item: TranscriptItem
    let session: ChatSession
    let context: TranscriptRowContext

    var body: some View {
        Group {
            switch item {
            case .message(let id):
                if let message = session.messages.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 18) {
                        if let s = context.switches[id] { ChatModelSwitchDivider(text: s) }
                        ChatMessageRow(message: message, session: session, context: context)
                            #if DEBUG
                            .freezeRowProbe("row.\(message.role)")
                            #endif
                    }
                }
            case .thought:
                // Brief AE2 — while streaming, the thought process renders at the HEAD of the reply (before the
                // answer tail). On completion it moves INTO the committed assistant bubble's top (same position).
                ThoughtProcessBlock(session: session)
            case .tail:
                StreamingTail(session: session)
                    #if DEBUG
                    .freezeRowProbe("row.tail")
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TranscriptItemView.cellSpace)).minY } action: { y in
                        if TranscriptMotion.on { TranscriptMotion.shared.tailContentY = y }   // live-31 — a shift inside the cell
                    }
                    #endif
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(TopPinnedInCell())
        #if DEBUG
        .coordinateSpace(.named(Self.cellSpace))
        #endif
        .environment(\.appBodyFont, context.appFont)
        .environment(\.chatTablePresenter, context.onOpenTable.map { open in ChatTablePresenter(open: open) })
    }
}

/// live-31 (1) — a cell's content hangs from the cell's TOP. When an answer grows, SwiftUI lays out the taller content a
/// frame before UIKit resizes the cell, and the hosting view centres content that doesn't fit its bounds: the streaming
/// text jumped up by half the new line, then back (measured on the recording: up to ~15 pt per line while the question
/// above stayed on the same pixel row — T's "swim"). So the root reports the cell's own height when it is being placed
/// in one (a finite proposal), with the content pinned to its top: the extra height only reaches downward, into the
/// space the cell is about to take. Measuring (no height, or an unbounded one) still returns the content's own height.
private struct TopPinnedInCell: ViewModifier {
    func body(content: Content) -> some View {
        if ChatTranscriptCollection.Coordinator.live30 { content } else { TopPinned { content } }
    }
}
private struct TopPinned: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let own = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        guard let h = proposal.height, h > 1, h < 100_000 else { return own }
        return CGSize(width: own.width, height: h)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// live-27 (4) — a quiet divider where the model changes mid-chat: "Switched to <model>".
struct ChatModelSwitchDivider: View {
    let text: String
    @Environment(\.appBodyFont) private var appFont

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(ChatTypography.secondaryText.opacity(0.35)).frame(height: 0.5)
            Text(text)
                .font(appFont.font(size: 12, relativeTo: .caption1))
                .foregroundStyle(ChatTypography.secondaryText)
                .lineLimit(1)
                .fixedSize()
            Rectangle().fill(ChatTypography.secondaryText.opacity(0.35)).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.modelSwitch")
    }
}

/// One settled message: a user bubble, an assistant answer with its footers, or a tool-activity strip.
struct ChatMessageRow: View {
    let message: ChatSession.Message
    let session: ChatSession
    let context: TranscriptRowContext

    /// Ambient URL opener — web-citation chips (real scraped URLs) open through this.
    /// (Corpus chips navigate to a node via `onOpenNode` instead.)
    @Environment(\.openURL) private var openURL
    /// Brief BN5 — the app-wide Font (serif/SF face), so the read/skim receipt line follows the Font.
    @Environment(\.appBodyFont) private var appFont
    private var speech: SpeechSynthesisService { SpeechSynthesisService.shared }
    private var isLast: Bool { message.id == session.messages.last?.id }

    var body: some View {
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
                if showsCompletedThoughtProcess {
                    ThoughtProcessBlock(session: session)
                }
                // Block-laid-out markdown. Full width minus a 40pt right
                // gutter (the block VStack is greedy — its bullet rows use
                // maxWidth:.infinity — so it takes an explicit frame + trailing
                // padding rather than an HStack Spacer, which it would fight).
                if message.declined == true {
                    declinedRow   // live-23 (5b) — an honest decline, not an answer
                } else {
                    MarkdownBlockText(raw: message.text)
                        .environment(\.chatAnswerGutter, 40)   // live-27 (4c) — a table reclaims the gutter
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 40)
                        #if DEBUG
                        .gauntletID("chat.answer", combine: true)   // Brief CH-0 — XCUITest reads the on-screen answer
                        #endif
                }
                // Brief BN5 — "Read 1 entry in full · skimmed 6" / "Skimmed 9 entries".
                readReceiptLine
                // live-28 (1) — an answer a cap or Stop ended early says so, under what arrived.
                if let stop = message.stopped {
                    Text(AnswerCap.line(for: stop))
                        .font(appFont.font(size: 13, relativeTo: .footnote))
                        .foregroundStyle(ChatTypography.secondaryText)
                        .padding(.top, 1)
                        .accessibilityIdentifier("chat.stopped")
                }
                // CH Session 2 — a General answer no web result backs says so (app chrome, not model text).
                if message.generalKnowledge == true {
                    Text(message.searchUnconfirmed == true ? WebGrounding.searchUnconfirmedNote
                         : message.datedKnowledge == true ? WebGrounding.datedKnowledgeNote : WebGrounding.generalKnowledgeNote)
                        .font(appFont.font(size: 13, relativeTo: .footnote))
                        .foregroundStyle(ChatTypography.secondaryText)
                        .padding(.top, 1)
                        #if DEBUG
                        .gauntletID("chat.generalKnowledge")
                        #endif
                }
                // live-27 (4) — who wrote this answer (app chrome, the meta style). None on answers saved before live-27;
                // a decline already names Apple Intelligence.
                if let p = message.provenance, message.declined != true {
                    Text(p.caption)
                        .font(appFont.font(size: 12, relativeTo: .caption1))
                        .foregroundStyle(ChatTypography.secondaryText)
                        .lineLimit(1)
                        .accessibilityLabel("Written by \(p.caption)")
                        .accessibilityIdentifier("chat.provenance")
                }
                // Piece 1 — collapsible grounded-Ask sources (chrome, not content).
                citationFooter
                // ★ BUG 36 — a turn that stopped early (stream dropped while
                // backgrounded): calm resume affordance, never a red banner.
                if message.isPartial == true {
                    partialResumeControl
                }
                // Per-turn read-aloud on settled assistant bubbles — each turn
                // independently replayable via its per-message UUID token.
                readAloudControl
            }
            // Piece 2 — inline superscript taps arrive as `airpad-citation://n`
            // links. Resolve n against THIS turn's citations → source node →
            // onOpenNode (same closure the footer circles use). Non-citation
            // links fall through to the system handler.
            .environment(\.openURL, OpenURLAction { url in
                #if DEBUG
                print("[CitationTap] url=\(url.absoluteString)")   // live-19 (3b) — SelectableTextTaps
                #endif
                // Brief AF3 — the no-key web-search notice's tap: open Settings on the
                // Web-search row. Checked before citations (distinct scheme).
                if url.scheme == "airpad-settings", url.host == "websearch" {
                    context.onOpenWebSearchSettings?()
                    return .handled
                }
                if let n = CitationReference.index(from: url),
                   let cite = message.citations?.first(where: { $0.index == n }) {
                    // Web citation → open the real scraped URL; corpus citation →
                    // navigate to the node (as today).
                    if let nodeID = cite.nodeID {
                        context.onOpenNode?(nodeID)
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
                ActivityRow(activity: activity, expanded: Binding(
                    get: { context.expandedActivities.contains(message.id) },
                    set: { if $0 { context.expandedActivities.insert(message.id) } else { context.expandedActivities.remove(message.id) } }))
            }
        }
    }

    /// Brief AE2 — the latest turn's ephemeral thought process renders inside its
    /// (now-committed) assistant bubble, at the top. True only for the LAST message
    /// once streaming has ended and thinking was captured; on the next send
    /// `streamingThinking` resets and this prior turn's panel disappears (ephemeral).
    private var showsCompletedThoughtProcess: Bool {
        message.role == .assistant
            && !session.isStreaming
            && isLast
            && !session.streamingThinking.isEmpty
    }

    // MARK: - Read/skim receipt (Brief BN5 — what the Librarian read)

    /// Brief BN5 — under the answer: "Read 1 entry in full · skimmed 6" on a READ turn, or "Skimmed 9 entries" on a
    /// SURVEY turn (`ChatTranscript.readReceiptText`). Rendered only for Librarian turns that carry a receipt.
    @ViewBuilder
    private var readReceiptLine: some View {
        if let r = message.readReceipt {
            // BS3 — the entry title is emphasised (markdown `*…*`); the whole line follows the Font.
            let md = ChatTranscript.readReceiptText(r)
            let attributed = (try? AttributedString(markdown: md)) ?? AttributedString(md)
            Text(attributed)
                .font(appFont.font(size: 13, relativeTo: .footnote))
                .foregroundStyle(ChatTypography.secondaryText)
                .padding(.top, 1)
                .accessibilityLabel(md.replacingOccurrences(of: "*", with: ""))
                .accessibilityIdentifier("chat.readReceipt")   // live-27 (4b) — the Library route's mark
        }
    }

    // MARK: - Citation footer (Piece 1 — collapsible grounded sources)

    @ViewBuilder
    private var citationFooter: some View {
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
            let isExpanded = forceExpand || context.expandedCitations.contains(message.id)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if isExpanded { context.expandedCitations.remove(message.id) }
                    else { context.expandedCitations.insert(message.id) }
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
                            // route through onOpenNode.
                            Button {
                                // Web chip → open the real scraped URL; corpus chip →
                                // navigate to the node.
                                if let urlStr = c.url, let real = URL(string: urlStr) {
                                    openURL(real)
                                } else if let nodeID = c.nodeID {
                                    context.onOpenNode?(nodeID)
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
                            .accessibilityHint(context.onOpenNode == nil ? "" : "Opens \(c.title)")
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

    // MARK: - Decline (live-23 5b) and partial-turn resume (BUG 36)

    /// live-23 (5b) — Apple Intelligence declined: one line saying so, then Try again (the same question, fresh — the
    /// decline is never history) and Switch model (the model picker, one tap). No "general knowledge" label.
    private var declinedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(AppleChat.declineLine, systemImage: "hand.raised")
                .font(appFont.font(size: 15, relativeTo: .body))
                .foregroundStyle(ChatTypography.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                // One element (a hosted cell would otherwise expose the icon and the text as two "chat.declined").
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AppleChat.declineLine)
                .accessibilityIdentifier("chat.declined")
            if isLast {
                HStack(spacing: 16) {
                    Button { Task { await session.regenerateLast() } } label: {
                        Label("Try again", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                    }
                    .disabled(session.isStreaming)
                    .accessibilityIdentifier("chat.declined.retry")
                    if let onSwitchModel = context.onSwitchModel {
                        Button(action: onSwitchModel) {
                            Label("Switch model", systemImage: "cpu").font(.system(size: 13, weight: .semibold))
                        }
                        .accessibilityIdentifier("chat.declined.switchModel")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(hexString: "00BFFF"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 40)
    }

    /// A turn that stopped early — the stream dropped while the app was
    /// backgrounded, so the text shown is what arrived before the drop, KEPT
    /// (not discarded) and persisted. Calm, quiet affordance (icon + word,
    /// shape not hue — T is colorblind), never the red failure banner. "Continue"
    /// resumes onto this same bubble; shown only on the trailing turn (that's
    /// what `continuePartial()` merges onto), older partials just read as stopped.
    private var partialResumeControl: some View {
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
    private var readAloudControl: some View {
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
                    context.copiedMessageID = message.id
                    let id = message.id, context = context
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1200))
                        if context.copiedMessageID == id { context.copiedMessageID = nil }
                    }
                } label: {
                    Image(systemName: context.copiedMessageID == message.id ? "checkmark" : "doc.on.doc")
                        .font(ChatTypography.footerIcon)
                        .foregroundStyle(ChatTypography.secondaryText)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy message")

                // Regenerate — LAST assistant turn only; disabled mid-stream.
                if isLast {
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
}
