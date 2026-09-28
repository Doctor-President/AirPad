import Foundation

/// THE ENRICHMENT GATE — self-test (2026-09-16). Mirrors `ProposalSelfTest` /
/// `ShimmerSelfTest`: no XCTest target, returns a printable summary for a headless
/// launch-arg run (`-EnrichmentGateSelfTest`, wired in `CorpusStore.load`).
///
/// ★ WHAT THIS MEASURES, AND WHAT IT DOESN'T. It counts the FM calls the gate
/// DECIDES to make, by replaying the four scenarios against the real
/// `EnrichmentGate` and the real `Proposal` type. It does NOT call FoundationModels
/// — the point is the decision, not the latency, and the decision is the whole fix.
/// A number here is a fact about the predicate, not a measurement of a device.
///
/// ★ WHY IT NEEDS A BEFORE COLUMN. "Two calls per note" means nothing on its own.
/// `Before` replays the predicate this arc replaced — `needsAuthorship =
/// title.isEmpty || summary.isEmpty`, with `needsSubstrate` computed and then
/// IGNORED by `processNodeWithAI`, and Done calling it unconditionally. That is the
/// control. Without it a passing number proves nothing (see: every "0 hits" that
/// turned out to be a broken probe).
///
/// ★ THE POSTURE IS THE WHOLE POINT. All of this is under
/// `AuthorshipPosture.propose`, where the FM never writes `title`/`summary` — it
/// records an offer. That is precisely why the old emptiness predicate could never
/// go false, and why the before-column numbers grow with the number of pauses.
@available(iOS 17.0, *)
enum EnrichmentGateSelfTest {

    private static let date0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// The slice of node state the gate reads, plus a replay of the two pipelines.
    /// Content doubles as its own hash — any stable key works, and using the content
    /// itself keeps the scenarios readable.
    private struct Sim {
        var content: String = ""
        var proposals: [Proposal] = []
        var titleSource: TagSource?
        var summarySource: TagSource?
        var substratePresent = false
        var substrateHash: String?
        /// Under `.propose` these are never written. Kept so the BEFORE predicate can
        /// be replayed exactly as it was, rather than described.
        var title = ""
        var summary = ""

        var authorshipCalls = 0
        var substrateCalls = 0
        var total: Int { authorshipCalls + substrateCalls }

        mutating func runAuthorship(aspects: [Proposal.Kind], solicited: Bool) {
            authorshipCalls += 1
            for kind in aspects {
                let source: TagSource? = (kind == .title) ? titleSource : summarySource
                _ = record(kind: kind, source: source, solicited: solicited)
            }
        }

        mutating func record(kind: Proposal.Kind, source: TagSource?, solicited: Bool) -> Bool {
            var n = Node(id: "sim", createdAt: date0, updatedAt: date0,
                         title: title, summary: summary, tags: [])
            n.proposals = proposals
            let wrote = n.recordProposal(kind: kind, text: "model text",
                                         currentSource: source,
                                         sourceEmbedding: nil,
                                         sourceContentHash: content,
                                         posture: .propose,
                                         generatedAt: date0,
                                         solicited: solicited)
            proposals = n.proposals ?? []
            return wrote
        }

        mutating func runSubstrate() {
            substrateCalls += 1
            substratePresent = true
            substrateHash = content
        }

        func needs(at moment: EnrichmentGate.Moment) -> EnrichmentGate.Needs {
            EnrichmentGate.needs(proposals: proposals,
                                 titleSource: titleSource,
                                 summarySource: summarySource,
                                 substrateIsPresent: substratePresent,
                                 substrateContentHash: substrateHash,
                                 contentHash: content,
                                 at: moment)
        }

        // MARK: the two worlds

        /// AFTER — the gate decides both halves, at both moments.
        mutating func eagerAfter() {
            let n = needs(at: .composing)
            guard n.any else { return }
            if n.authorship { runAuthorship(aspects: [.title, .summary], solicited: false) }
            if n.substrate { runSubstrate() }
        }
        mutating func doneAfter() {
            let n = needs(at: .committed)
            guard n.any else { return }
            if n.authorship { runAuthorship(aspects: [.title, .summary], solicited: false) }
            if n.substrate { runSubstrate() }
        }

        /// BEFORE — `title.isEmpty || summary.isEmpty` (stuck true under `.propose`),
        /// `needsSubstrate` computed but ignored downstream, Done unconditional.
        mutating func eagerBefore() {
            let needsAuthorship = title.isEmpty || summary.isEmpty
            let needsSubstrate = !substratePresent
            guard needsAuthorship || needsSubstrate, !content.isEmpty else { return }
            runAuthorship(aspects: [.title, .summary], solicited: false)   // ran regardless
            runSubstrate()                                                 // param ignored
        }
        mutating func doneBefore() {
            runAuthorship(aspects: [.title, .summary], solicited: false)
            runSubstrate()
        }

        /// The tray's per-row generate: solicited, ONE aspect, substrate withheld.
        /// Identical in both worlds — the user asked, so no gate is consulted.
        mutating func lever(_ kind: Proposal.Kind) {
            runAuthorship(aspects: [kind], solicited: true)
        }
        mutating func accept(_ kind: Proposal.Kind) {
            if kind == .title { titleSource = .model } else { summarySource = .model }
            proposals.removeAll { $0.kind == kind }
        }

        /// Brief BI — PROMOTE at Done under `.automatic`: write a FRESH, content-matching
        /// proposal into an UNTITLED aspect with NO model call (mirrors
        /// `CorpusStore.promoteMatchingProposals` → `acceptProposal`). Returns whether it
        /// promoted. Note: `authorshipCalls` is NOT bumped — promotion never calls the FM.
        mutating func promote(_ kind: Proposal.Kind) -> Bool {
            let source: TagSource? = (kind == .title) ? titleSource : summarySource
            guard source == nil,
                  let p = proposals.first(where: { $0.kind == kind && $0.state == .fresh }),
                  p.sourceContentHash == content else { return false }
            if kind == .title { title = p.text; titleSource = .model }
            else { summary = p.text; summarySource = .model }
            proposals.removeAll { $0.kind == kind }
            return true
        }
    }

    private struct Row {
        let name: String
        let before: Int
        let after: Int
    }

    static func run() -> String {
        var rows: [Row] = []
        var failures: [String] = []

        // a — short note, one pause, no Lever.
        rows.append(pair("a. short note, 1 pause, no Lever", after: { s in
            s.content = "a short note"
            s.eagerAfter()
            s.doneAfter()
        }, before: { s in
            s.content = "a short note"
            s.eagerBefore()
            s.doneBefore()
        }))

        // b — long note, five pauses, no Lever. THE ONE THAT SHOULD COLLAPSE.
        rows.append(pair("b. long note, 5 pauses, no Lever", after: { s in
            for i in 1...5 { s.content = String(repeating: "para \(i). ", count: i); s.eagerAfter() }
            s.doneAfter()
        }, before: { s in
            for i in 1...5 { s.content = String(repeating: "para \(i). ", count: i); s.eagerBefore() }
            s.doneBefore()
        }))

        // c — the user pulls the Lever and accepts.
        rows.append(pair("c. 1 pause, Lever pulled + accepted", after: { s in
            s.content = "a note worth titling"
            s.eagerAfter()
            s.lever(.title)
            s.accept(.title)
            s.doneAfter()
        }, before: { s in
            s.content = "a note worth titling"
            s.eagerBefore()
            s.lever(.title)
            s.accept(.title)
            s.doneBefore()
        }))

        // d — the user keeps typing after a proposal fires.
        rows.append(pair("d. proposal fires, user types on", after: { s in
            s.content = "first thought"
            s.eagerAfter()
            s.content = "first thought, then a second one"
            s.eagerAfter()
            s.doneAfter()
        }, before: { s in
            s.content = "first thought"
            s.eagerBefore()
            s.content = "first thought, then a second one"
            s.eagerBefore()
            s.doneBefore()
        }))

        // Invariants worth failing on, not just counting.
        do {
            // (1) A settled note asks for nothing at Done — the whole point.
            var s = Sim(); s.content = "settled"; s.eagerAfter()
            if s.needs(at: .committed).any { failures.append("settled note still needs work at Done") }
            // (2) A note typed on after a proposal DOES still reconcile at Done.
            var t = Sim(); t.content = "one"; t.eagerAfter(); t.content = "one two"
            if !t.needs(at: .committed).substrate { failures.append("stale substrate not caught at Done") }
            // (3) A dismissed proposal is not re-offered for unchanged content.
            var u = Sim(); u.content = "x"; u.eagerAfter()
            u.proposals = u.proposals.map { var p = $0; p.state = .dismissed; return p }
            if u.needs(at: .composing).authorship { failures.append("dismissed proposal re-offered") }
            // (4) A user-authored field is never asked about.
            var v = Sim(); v.content = "y"; v.titleSource = .user; v.summarySource = .user
            if v.needs(at: .composing).authorship { failures.append("user-authored field asked about") }
            // (5) Legacy proposal with no hash reads stale exactly once.
            var w = Sim(); w.content = "z"; w.eagerAfter()
            w.proposals = w.proposals.map { var p = $0; p.sourceContentHash = nil; return p }
            if !w.needs(at: .composing).authorship { failures.append("hashless legacy proposal read as fresh") }

            // ── Brief BI (Done-delegates) ──────────────────────────────────────────
            // (6) THE RESOLVER — the ONLY source of posture. Done on a capture delegates
            //     only with the setting ON; authoring/off always propose.
            if AuthorshipPosture.resolve(for: .committedCapture, setting: true)  != .automatic { failures.append("BI resolver: committed+on ≠ automatic") }
            if AuthorshipPosture.resolve(for: .committedCapture, setting: false) != .propose   { failures.append("BI resolver: committed+off ≠ propose") }
            if AuthorshipPosture.resolve(for: .authoring,        setting: true)  != .propose   { failures.append("BI resolver: authoring ≠ propose") }
            // (7) THE TRAP (BI1, measured): the eager `.composing` pass records a proposal
            //     matching the content, so at Done the gate reports NO authorship need — the
            //     "commit skip" that leaves the entry untitled without the promote.
            var d = Sim(); d.content = "delegate me"; d.eagerAfter()
            if d.needs(at: .committed).authorship { failures.append("BI trap: expected commit-skip (needs.authorship false) with a matching proposal") }
            let callsBefore = d.authorshipCalls
            // (8) PROMOTE (BI3): writes the untitled field, stamps .model, drops the
            //     proposal, and makes NO model call. After promoting both aspects, Done
            //     needs nothing (fields are .model).
            let pT = d.promote(.title); let pS = d.promote(.summary)
            if !pT || !pS { failures.append("BI promote: a fresh matching proposal was not promoted") }
            if d.authorshipCalls != callsBefore { failures.append("BI promote: made a model call (should be zero)") }
            if d.titleSource != .model || d.title.isEmpty { failures.append("BI promote: title not written/stamped .model") }
            if d.needs(at: .committed).authorship { failures.append("BI promote: still needs authorship after promoting both") }
            // (9) PER-ASPECT: a typed (.user) title is NEVER promoted; an empty summary is.
            var e = Sim(); e.content = "typed title only"; e.titleSource = .user
            e.eagerAfter()   // records a summary proposal only (title is .user, gate skips it)
            if e.promote(.title)  { failures.append("BI per-aspect: promoted a user-authored title") }
            if !e.promote(.summary) { failures.append("BI per-aspect: did not promote the empty summary") }
            if e.titleSource != .user || e.summarySource != .model { failures.append("BI per-aspect: sources wrong after promote") }
        }

        var out = "\n  scenario                              before   after\n"
        out += "  ------------------------------------  ------   -----\n"
        for r in rows {
            out += "  \(r.name.padding(toLength: 36, withPad: " ", startingAt: 0))  \(String(r.before).padding(toLength: 6, withPad: " ", startingAt: 0))   \(r.after)\n"
        }
        out += "  (counts are FM calls per note: processNode + processSubstrate)\n"
        out += failures.isEmpty
            ? "  invariants: 9/9 PASS (incl. Brief BI resolver · trap · promote · per-aspect)\n"
            : "  invariants FAILED: \(failures.joined(separator: " | "))\n"
        return out
    }

    private static func pair(_ name: String,
                             after: (inout Sim) -> Void,
                             before: (inout Sim) -> Void) -> Row {
        var a = Sim(); after(&a)
        var b = Sim(); before(&b)
        return Row(name: name, before: b.total, after: a.total)
    }
}
