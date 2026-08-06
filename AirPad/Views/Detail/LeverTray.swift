import SwiftUI

/// THE LEVER — Stage 2 tray (ws-lever.md § STAGE 2 · § C3). A PARTIAL-height
/// native sheet over the detail view. A native sheet is correct here: the
/// native-sheet rejection (`architecture/native-sheet-REJECTED.md`) is about the
/// Librarian over a live SpriteKit canvas; the detail view is a scrolling
/// document, so none of those four failures apply.
///
/// One row per authored aspect — title, then summary — each in ONE of two
/// states: a proposal ready to review (CURRENT vs PROPOSED, with accept / ignore
/// for that row alone) or a GENERATE action that asks for one. Same surface,
/// same grammar, whether the system got there first or the user did.
///
/// ★ THE TAGS ROW (ws-lever.md § C3, Step 1 "already yours"): now present, gated
/// on a real producer — the deterministic node-local matcher
/// (`store.tagSuggestions(forNodeID:)`). UNLIKE title/summary (one proposal, all
/// or nothing) it is SEVERAL candidate tags, each independently accept/dismiss.
/// Accept reuses the existing add-tag path; dismiss persists so the tag isn't
/// offered for THIS node again. Empty is a real row ("nothing to suggest"), not a
/// missing one. ★ No badge count. ★ Selective per row, never all-or-nothing.
struct LeverTray: View {
    let nodeID: String

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// One FM call produces title AND summary together (the § C5 known
    /// constraint), so a single flag covers the whole tray's working state.
    @State private var isGenerating = false
    /// F3 — why the last generate produced nothing (nil = no failure to show).
    /// One FM call does both aspects, so one reason covers the tray. Cleared at
    /// the start of every generate.
    @State private var failure: NodeAIFailure?

    /// THE TAG PRODUCER — Step 1 (§ C3). Candidate tags THIS node's folksonomy is
    /// close to, computed on demand (never a sweep). Held locally so accept /
    /// dismiss can drop a chip without a re-query. `tagsLoaded` gates loading vs
    /// empty-vs-populated so the empty state doesn't flash before the async match.
    @State private var tagSuggestions: [TagSuggestion] = []
    @State private var tagsLoaded = false

    private var node: Node? { store.nodes.first { $0.id == nodeID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Proposals")
                    .font(.headline)
                    .foregroundStyle(AppearancePalette.ink)

                // F4 — say WHY a generate came back empty, using the SHARED
                // failure banner (one vocabulary with chat: amber, the reason,
                // Retry + dismiss). A framework throw shows its OWN message
                // verbatim; Retry re-runs the generate; × clears it.
                if let failure, !isGenerating {
                    FMFailureBanner(
                        message: failureMessage(failure),
                        onRetry: { generate() },
                        onDismiss: { self.failure = nil }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if let node {
                    aspectRow(node: node, kind: .title, label: "Title",
                              current: node.title)
                    Divider().overlay(AppearancePalette.ink.opacity(0.12))
                    aspectRow(node: node, kind: .summary, label: "Summary",
                              current: node.summary)
                    Divider().overlay(AppearancePalette.ink.opacity(0.12))
                    tagsSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // On-demand match for THIS node only (§ C2 — never a corpus sweep). Keyed
        // on nodeID so re-opening the tray on a different node re-matches.
        .task(id: nodeID) { await loadTagSuggestions() }
        // OPENS partial (`.height(360)`) so title / summary / chips stay visible
        // above, but is DRAGGABLE TO FULL — the grabber implies drag and the
        // content overflows a low detent. ★ § "Tap → a PARTIAL-HEIGHT SHEET" is
        // AMENDED (2026-08-04): partial is the OPENING detent, not a ceiling. The
        // old "never .large" rule predated the tray carrying its own Current line;
        // the comparison now lives inside the sheet, so occluding the page behind
        // costs nothing. Low detent listed first = the opening one.
        .presentationDetents([.height(360), .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Rows

    @ViewBuilder
    private func aspectRow(node: Node, kind: Proposal.Kind, label: String,
                           current: String) -> some View {
        // `surfacedProposal` is the single show/hide predicate shared with the
        // button: a fresh proposal shows unless it is an UNSOLICITED one on a
        // user-authored field (§ C3). A SOLICITED proposal (the user tapped
        // generate) always shows — so after F2 the title row behaves exactly like
        // the summary row even when `titleSource == .user`.
        let proposal = node.surfacedProposal(kind: kind)
        let showProposal = proposal != nil
        let currentTrimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))

            fieldBlock(caption: "Current",
                       text: currentTrimmed.isEmpty ? "Nothing yet" : current,
                       muted: currentTrimmed.isEmpty)

            if showProposal, let proposal {
                fieldBlock(caption: "Proposed", text: proposal.text, muted: false)
                HStack(spacing: 16) {
                    Button {
                        Task { await store.dismissProposal(nodeID: nodeID, kind: kind) }
                    } label: {
                        Text("Ignore")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        Task { await store.acceptProposal(nodeID: nodeID, kind: kind) }
                    } label: {
                        Text("Use this")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppearancePalette.onInk)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(AppearancePalette.ink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                generateAction(currentIsEmpty: currentTrimmed.isEmpty)
            }
        }
    }

    /// The generate action. A user-authored row still OFFERS it — consent comes
    /// from tapping (the request model). ★ Working state is `ellipsis` +
    /// `.variableColor.iterative` per § GLYPH VOCABULARY — NOT the feather, which
    /// means authorship, not activity.
    @ViewBuilder
    private func generateAction(currentIsEmpty: Bool) -> some View {
        Button {
            generate()
        } label: {
            HStack(spacing: 7) {
                if isGenerating {
                    Image(systemName: "ellipsis")
                        .symbolEffect(.variableColor.iterative)
                    Text("Proposing…")
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(currentIsEmpty ? "Generate" : "Suggest another")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppearancePalette.ink.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .overlay(Capsule().stroke(AppearancePalette.ink.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
    }

    @ViewBuilder
    private func fieldBlock(caption: String, text: String, muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(AppearancePalette.ink.opacity(muted ? 0.4 : 0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tags (§ C3 — the "already yours" row)

    /// SEVERAL candidate tags, each independently acceptable or dismissable —
    /// deliberately a different shape from the title / summary blocks above (which
    /// are ONE proposal, accept-or-ignore). Loading → a quiet spinner; empty → a
    /// real "nothing to suggest" row (§ C3, not a missing row); matches → outlined
    /// chips (see `suggestionChip` for the applied-vs-suggested distinction).
    @ViewBuilder
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TAGS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.5))

            if !tagsLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for tags you already use…")
                        .font(.subheadline)
                        .foregroundStyle(AppearancePalette.ink.opacity(0.4))
                }
            } else if tagSuggestions.isEmpty {
                // A real row, not a missing one (§ C3): ~37% of the corpus has no
                // folksonomy, and a node with folksonomy can still match nothing.
                Text("Nothing to suggest here.")
                    .font(.subheadline)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            } else {
                TagFlowLayout(spacing: 8) {
                    ForEach(tagSuggestions) { suggestionChip($0) }
                }
            }
        }
    }

    /// One suggested tag. OUTLINED (not filled) so it reads as "available, not yet
    /// yours" against the FILLED applied chips in the detail view — tags are
    /// reached for, not announced (§ C2). A leading ＋ is the accept affordance;
    /// tapping it attaches the tag via the existing add-tag path. A trailing ✕
    /// dismisses it for this node.
    @ViewBuilder
    private func suggestionChip(_ s: TagSuggestion) -> some View {
        let color = tagColor(s.name)
        HStack(spacing: 5) {
            Button {
                Task { await accept(s) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text(s.name)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(AppearancePalette.ink.opacity(0.9))
            }
            .buttonStyle(.plain)

            Button {
                Task { await dismissSuggestion(s) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1.5))
        .contentShape(Capsule())
    }

    /// The tag's own color from the vocabulary (same source as `TagChip`); gray if
    /// the tag isn't found (it always should be — suggestions are drawn FROM the
    /// tag set).
    private func tagColor(_ name: String) -> Color {
        if let tag = store.tags.first(where: { $0.name == name }) {
            return Color(hex: tag.colorHex) ?? .gray
        }
        return .gray
    }

    private func loadTagSuggestions() async {
        tagsLoaded = false
        #if DEBUG
        // Sim fixture: `CardEmbeddingService`'s `.all` compute units return ZEROS
        // on the Simulator (Step 0 finding), so the real matcher yields nothing
        // there. `-TagSuggestFixture` seeds canned chips so the row renders for a
        // device-parity screenshot. Off by default; never runs on device.
        if ProcessInfo.processInfo.arguments.contains("-TagSuggestFixture") {
            tagSuggestions = [
                TagSuggestion(name: "creativity", score: 0.94),
                TagSuggestion(name: "organization", score: 0.87),
                TagSuggestion(name: "growth", score: 0.83),
            ]
            tagsLoaded = true
            return
        }
        #endif
        tagSuggestions = await store.tagSuggestions(forNodeID: nodeID)
        tagsLoaded = true
    }

    /// Accept → attach via the SINGLE add-tag path (§ C3 — no second attach
    /// written), then drop the chip. The detail view's own tag row picks the new
    /// tag up from the store.
    private func accept(_ s: TagSuggestion) async {
        await store.addTag(s.name, toNodes: [nodeID])
        tagSuggestions.removeAll { $0.id == s.id }
    }

    /// Dismiss → persist so this tag isn't offered for this node again (§ C3),
    /// then drop the chip.
    private func dismissSuggestion(_ s: TagSuggestion) async {
        await store.dismissTagSuggestion(nodeID: nodeID, tagName: s.name)
        tagSuggestions.removeAll { $0.id == s.id }
    }

    // MARK: - Generate

    /// Route through the existing `processNodeWithAI` path. Under `.propose`,
    /// `recordProposal` withholds the write and records the proposal, so no new
    /// write logic is needed. One call refreshes BOTH title and summary proposals
    /// (the § C5 known constraint) — acceptable, they are proposals, not writes.
    ///
    /// ★ Stage 2 F2 — `solicited: true`: this is the ONE path that sets it. The
    /// user tapped generate, so the user-beats-model gate opens for RECORDING (not
    /// the write) — a proposal can now be offered even for a field the user
    /// authored. Consent comes from initiating.
    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        failure = nil
        Task {
            // F3 — the returned reason (nil on success) drives the tray's copy.
            let reason = await store.processNodeWithAI(nodeID: nodeID, suppressTagSheet: true, solicited: true)
            isGenerating = false
            failure = reason
        }
    }

    /// F4 — the banner message per failure. `unavailable` / `noContent` are
    /// AirPad's OWN conditions → AirPad copy (T dials the wording). `failed`
    /// shows the framework's OWN description verbatim (e.g. "Exceeded model
    /// context window size") — not re-classified, per the amendment.
    private func failureMessage(_ f: NodeAIFailure) -> String {
        switch f {
        case .unavailable:
            return "The on-device model isn't available right now."
        case .noContent:
            return "There's nothing here to work from yet."
        case .contextOverflow:
            // F5b — the window is SHARED input+output, so a note that "fits" can
            // still overflow because the reply needs room too. (Numbers are in the
            // payload + log; copy stays plain. T dials wording.)
            return "This note fills the model's context window, leaving no room for a reply."
        case .failed(let msg):
            return msg
        }
    }
}

// MARK: - Flow layout

/// Wrapping row layout for the suggestion chips — several small chips flowing to
/// the next line, distinct from the stacked title/summary blocks. (Mirrors the
/// `FlowLayout` in `TagCreationSheet`; kept file-private here so the tray is
/// self-contained.)
private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width + (rowWidth > 0 ? spacing : 0) > maxWidth {
                height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
                rowHeight = max(rowHeight, size.height)
            }
        }
        height += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
