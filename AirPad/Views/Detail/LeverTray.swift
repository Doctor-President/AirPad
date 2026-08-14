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
    /// STEP 4 — the SECOND tier: folksonomy terms matching NO existing tag, offered as
    /// brand-new tags (§ THE TAG PRODUCER · "would be new"). Held separately from the
    /// "already yours" list so the two render as distinct groups. Carries `total` (item 3)
    /// so the group label can say "3 of N" and the dismiss-to-page behaviour is legible.
    @State private var newTier: NewTagTier = .empty
    @State private var tagsLoaded = false

    /// ws-local-model Stage 2 — routes the refusal surface into AirPad's own Settings
    /// (where the on-device model is downloaded + enabled). Presented as a nested sheet
    /// OVER the tray so there's no dismiss-then-present race; closing it returns here.
    @State private var showSettings = false

    private var node: Node? { store.nodes.first { $0.id == nodeID } }

    /// GAP 27 copy — whether the on-device private model is opted in AND ready (the same
    /// test `ModelRouter.structuredProvider` uses). When true, the refusal banners drop the
    /// "Set up the private model" CTA (it would route the user to something already done) and
    /// stop pitching a model the user already has.
    private var localModelReady: Bool {
        UserDefaults.standard.bool(forKey: ModelRouter.useLocalEnrichmentKey)
            && LocalModelService.shared.state == .ready
    }

    /// Trailing sentence of a refusal banner: pitch the private model when it isn't set up,
    /// or note it's already active when it is. (Wording held for T.)
    private var privateModelPitch: String {
        localModelReady
            ? "Your private model isn't limited the same way."
            : "AirPad's optional private model handles a wider range of subjects."
    }

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
                    if case .refused(let msg) = failure {
                        // FM DECLINED the TITLE+SUMMARY call (`processNode`, ws-local-model
                        // Stage 2). Not an error to retry — offer AirPad's optional on-device
                        // model and route into Settings to set it up. The tags locus has its
                        // own, separate notice in `tagsSection`.
                        LeverRefusalBanner(
                            message: "Apple Intelligence declined to summarize this one. \(privateModelPitch)",
                            frameworkMessage: msg,
                            onSetUp: localModelReady ? nil : { showSettings = true },
                            onDismiss: { self.failure = nil }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        FMFailureBanner(
                            message: failureMessage(failure),
                            onRetry: { generate() },
                            onDismiss: { self.failure = nil }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                if let node {
                    // Both aspects ALWAYS render (correction to dbb9175, which withheld a
                    // no-op row entirely). A NO-OP proposal — byte-identical to Current, an
                    // already-accepted aspect, or a Generate that returned the same string
                    // — collapses the row to Current + "Suggest another" INSIDE aspectRow,
                    // never to nothing: withholding the row hid the only route back to a new
                    // proposal and made accepting IRREVERSIBLE. So the tray can never
                    // collapse to a bare header; the tags section keeps its own empty state
                    // (still DISTINCT from the guardrail_refused notice).
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
        // Nested sheet OVER the tray — the refusal surface's "set up" route lands the
        // user in AirPad's own Settings (local-model download + enable). No AppRouter
        // plumbing, no dismiss-then-present race; closing returns to the tray.
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: - Rows

    /// True when `kind` has a surfaced proposal whose text, trimmed, EQUALS the current
    /// value — a re-fire that rewrote nothing. Such a proposal offers no decision, so
    /// `aspectRow` collapses to its "Suggest another" state instead of presenting a fake
    /// Ignore / Use this (the row is NEVER withheld — see `body`). No proposal at all ⇒
    /// false, which also lands the "Suggest another" state.
    ///
    /// ⚠️ This hides a SYMPTOM only: a model-written title is still silently regenerated
    /// on a substrate-only refire (the gate fires on `substrateMissing`; a `.model` title
    /// passes the user-beats-model check). Whether Automatic means "write once into blanks"
    /// or "keep current" is Stage 3's call, not this commit's.
    private func aspectIsNoOp(_ node: Node, kind: Proposal.Kind, current: String) -> Bool {
        guard let p = node.surfacedProposal(kind: kind) else { return false }
        return p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            == current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func aspectRow(node: Node, kind: Proposal.Kind, label: String,
                           current: String) -> some View {
        // `surfacedProposal` is the single show/hide predicate shared with the
        // button: a fresh proposal shows unless it is an UNSOLICITED one on a
        // user-authored field (§ C3). A SOLICITED proposal (the user tapped
        // generate) always shows — so after F2 the title row behaves exactly like
        // the summary row even when `titleSource == .user`.
        let proposal = node.surfacedProposal(kind: kind)
        // Correction to dbb9175: a NO-OP proposal (Proposed == Current after trimming) is
        // not a decision, so collapse to the "Suggest another" state (the else branch)
        // rather than present a fake Ignore / Use this. The row still renders — the route
        // back to a new proposal is never withheld, so accepting stays reversible.
        // `aspectIsNoOp` is the predicate; here it selects the row's STATE, not its
        // presence.
        let showProposal = proposal != nil && !aspectIsNoOp(node, kind: kind, current: current)
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
            } else if node?.embeddingFailureReason == "guardrail_refused" {
                // ws-local-model Stage 2 — the SUBSTRATE refusal, made HONEST. The
                // folksonomy call (`processSubstrate`) refused → `folksonomy` nil →
                // no suggestions. Before, this rendered "Nothing to suggest here.",
                // INDISTINGUISHABLE from a node that simply has no tags yet — the
                // failure T saw on day one and could not see. The persisted
                // `embeddingFailureReason == "guardrail_refused"` is what tells them
                // apart. Say WHICH capability was lost: the tags were declined; the
                // title and summary (a SEPARATE call) are unaffected when the node
                // still has a summary — and don't claim so if it doesn't (both refused).
                LeverRefusalBanner(
                    message: tagsRefusalMessage,
                    onSetUp: localModelReady ? nil : { showSettings = true }
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if tagSuggestions.isEmpty && newTier.shown.isEmpty {
                // A real row, not a missing one (§ C3): ~37% of the corpus has no
                // folksonomy, and a node with folksonomy can still match nothing in
                // EITHER tier. Distinct from the guardrail-refused branch above.
                Text("Nothing to suggest here.")
                    .font(.subheadline)
                    .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            } else {
                // TWO TIERS, distinguished by SHAPE + LABEL, never hue (T is colorblind,
                // and a brand-new tag has no color yet anyway). "Already yours" =
                // SOLID-outlined chips in the tag's own color; "would be new" = a labeled
                // group of DASHED, neutral chips reading as provisional. Each group's
                // sub-label shows only when that tier has chips.
                VStack(alignment: .leading, spacing: 16) {
                    if !tagSuggestions.isEmpty {
                        tierGroup(caption: "Tags you already use") {
                            ForEach(tagSuggestions) { suggestionChip($0) }
                        }
                    }
                    if !newTier.shown.isEmpty {
                        tierGroup(caption: newTierCaption) {
                            ForEach(newTier.shown) { newSuggestionChip($0) }
                        }
                    }
                }
            }
        }
    }

    /// Item 3 — the "would be new" group label. When more candidates exist than the cap
    /// shows, surface the count so the dismiss-to-page behaviour is legible (dismiss a chip
    /// → the next candidate fills the freed slot). PLACEHOLDER COPY — T dials on device.
    private var newTierCaption: String {
        newTier.total > newTier.shown.count
            ? "New tags — \(newTier.shown.count) of \(newTier.total)"
            : "New tags — tap ＋ to create"
    }

    /// A labeled tier group: a small caption over a wrapping chip row. The caption is a
    /// TEXT distinction (colorblind-safe) between the two tiers; the chip SHAPE carries
    /// it too (solid vs dashed). T dials the copy on device.
    @ViewBuilder
    private func tierGroup(caption: String, @ViewBuilder chips: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppearancePalette.ink.opacity(0.4))
            TagFlowLayout(spacing: 8) { chips() }
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

    /// STEP 4 — one "would be new" chip. Deliberately a DIFFERENT SHAPE from
    /// `suggestionChip`: a DASHED, neutral (hueless) outline reading as "provisional,
    /// not yet in your vocabulary" — the tag doesn't exist until accepted, so it has no
    /// color to show, and the dash carries the distinction WITHOUT relying on hue (T is
    /// colorblind). Leading ＋ promotes it to a real tag (`promoteNewTag`, `.promoted`
    /// provenance); trailing ✕ dismisses it for this node (same persist path as the
    /// "already yours" tier).
    @ViewBuilder
    private func newSuggestionChip(_ s: TagSuggestion) -> some View {
        HStack(spacing: 5) {
            Button {
                Task { await acceptNew(s) }
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
                Task { await dismissNewSuggestion(s) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(
            Capsule().stroke(
                AppearancePalette.ink.opacity(0.5),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        )
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

    /// Honest copy for a SUBSTRATE (tags) refusal. Names the tags capability as the one
    /// lost; appends "its title and summary are unaffected" ONLY when the node actually
    /// has a summary (the sibling `processNode` call succeeded) — so it never implies
    /// total failure, and never falsely claims they survived when both calls refused.
    private var tagsRefusalMessage: String {
        let hasSummary = !((node?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        return hasSummary
            ? "Apple Intelligence declined to suggest tags for this note — its title and summary are unaffected. \(privateModelPitch)"
            : "Apple Intelligence declined to suggest tags for this note. \(privateModelPitch)"
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
            // STEP 4 — canned "would be new" chips so the dashed tier renders for a
            // device-parity screenshot (the real matcher yields nothing on the Sim).
            // `total: 5` > 2 shown so the "2 of 5" count (item 3) renders too.
            newTier = NewTagTier(shown: [
                TagSuggestion(name: "Air Force Fighter Pilot", score: 1.0),
                TagSuggestion(name: "Coming of Age", score: 0.99),
            ], total: 5)
            tagsLoaded = true
            return
        }
        #endif
        tagSuggestions = await store.tagSuggestions(forNodeID: nodeID)
        newTier = await store.newTagSuggestions(forNodeID: nodeID)
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

    /// STEP 4 — accept a "would be new" chip: PROMOTE the term to a real tag via the
    /// create-then-apply-`.promoted` path (§ THE TAG PRODUCER, constraint 2). NOT the
    /// "already yours" `accept` — that attaches an existing tag; this mints one.
    ///
    /// RE-QUERY BOTH TIERS afterward (reuse `loadTagSuggestions`), never a local
    /// removeAll: (1) the new tier shows 3 of N (newTagCap), so draining it locally
    /// strands the other N−3 until the tray reopens — the re-query promotes the next
    /// candidate into the freed slot; and (2) minting a Tag CHANGES the vocabulary the
    /// remaining folksonomy terms are tested against, so a term that had no ≥ 0.80 match
    /// may now clear against the tag just created and must leave the new tier (accept
    /// "Transgender" → "Gender Identity" is no longer "would be new"). The detail view's
    /// tag row picks the new tag up from the store.
    private func acceptNew(_ s: TagSuggestion) async {
        await store.promoteNewTag(s.name, toNodeID: nodeID)
        await loadTagSuggestions()
    }

    /// STEP 4 — dismiss a "would be new" chip. Same persist path as the "already yours"
    /// tier (`dismissTagSuggestion` keys by normalized name), so a rejected new term
    /// isn't offered for this node again — whether or not it later becomes a real tag.
    ///
    /// RE-QUERY the new tier afterward, never a local removeAll: the producer filters on
    /// `dismissedTagNames`, so the dismissed term won't return, and the re-query is what
    /// promotes the next candidate into the freed slot (the tier shows 3 of N). Dismiss
    /// changes no tag, so it can't move a term between tiers — only the new tier reloads.
    private func dismissNewSuggestion(_ s: TagSuggestion) async {
        await store.dismissTagSuggestion(nodeID: nodeID, tagName: s.name)
        newTier = await store.newTagSuggestions(forNodeID: nodeID)
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
        case .refused(let msg):
            // Not shown through this path — `.refused` renders LeverRefusalBanner, not
            // FMFailureBanner — but the switch must stay exhaustive. Returns the verbatim
            // framework text as a safe fallback.
            return msg
        }
    }
}

/// ws-local-model Stage 2 — the FM-declined surface. Distinct from `FMFailureBanner`
/// (an error to retry): a refusal is a capability boundary, so this OFFERS AirPad's
/// optional on-device model and routes into Settings to set it up, rather than a Retry.
/// Colorblind-safe by construction: meaning is carried by the icon SHAPE + text, on a
/// neutral (hueless) ground — never by color alone (T is colorblind).
///
/// ★ `message` is HONEST about WHICH capability was lost — the two capture calls are
/// independent refusal loci: the title+summary call (`processNode`) and the folksonomy
/// call (`processSubstrate`) can refuse separately, and the copy says which. When we
/// have the framework's verbatim words (the title+summary locus routes them through
/// `.refused`), they're kept beneath so no information is lost; the tags locus has no
/// persisted message, so `frameworkMessage` is empty there. `onDismiss` is optional: a
/// transient banner (title+summary) shows a ×; a notice derived from the node's persisted
/// state (tags) omits it — dismissing a persisted fact would just reappear on reload.
private struct LeverRefusalBanner: View {
    let message: String
    var frameworkMessage: String = ""
    /// Nil HIDES the "Set up the private model" CTA — used when the local model is already
    /// opted in + ready, so the banner never routes the user to something they've done.
    var onSetUp: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(AppearancePalette.ink.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    if !frameworkMessage.isEmpty {
                        Text(frameworkMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppearancePalette.ink.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }
            if let onSetUp {
                Button(action: onSetUp) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill").font(.system(size: 12))
                        Text("Set up the private model").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color(hexString: "00BFFF"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppearancePalette.ink.opacity(0.06))
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
