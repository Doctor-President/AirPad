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
/// ★ No tags row (no producer — a permanently-dead row is worse than an absent
/// one). ★ No badge count. ★ Selective per row, never all-or-nothing.
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
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
