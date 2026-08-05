import Foundation

/// THE LEVER — Stage 1 self-test (ws-lever.md § C6). Mirrors
/// `FieldValueSelfTest` / `SubstrateSelfTest`: no XCTest target, returns a
/// one-line-or-multi-line summary for a headless launch-arg run
/// (`-ProposalSelfTest`, wired in `CorpusStore.load`).
///
/// ★ Stage 1 is deliberately INVISIBLE — the proposal record lands alongside the
/// existing write, so nothing on screen changes. It therefore cannot be verified
/// by looking; this is the objective verification the brief specifies.
///
/// ★ GATE 0 — this test is PURELY IN-MEMORY. It constructs `Node` values and
/// exercises `Node.recordProposal` + the JSON coders; it never reads or writes
/// the live corpus, never injects a fixture into `CorpusStore.nodes`, and never
/// arms a backfill. So there is no scratch-root redirection to do (unlike
/// `-FieldFixtureNode`, which injects a node and roots at a throwaway dir).
///
/// Coverage (the six the brief names, plus one seam assertion):
///   1 — a node with blank title+summary and content accrues one proposal of
///       each kind (the mechanism is kind-generic; the LIVE path drives only
///       title+summary — `.tags` has no producer yet, § THE TAG PRODUCER).
///   2 — proposals survive an encode→decode round trip, `sourceEmbedding` intact.
///   3 — a legacy `node.json` with no `proposals` key decodes cleanly (nil, no throw).
///   4 — a user-authored summary (`summarySource == .user`) records NO proposal
///       and reports "do not write".
///   5 — regeneration REPLACES the prior proposal of that kind, never appends.
///   6 — under `.automatic` the summary is still written (no behaviour change);
///       under `.propose` the write is withheld but the proposal is still recorded
///       (the posture seam is wired for Stage 3).
@available(iOS 17.0, *)
enum ProposalSelfTest {

    private static let date0 = Date(timeIntervalSince1970: 1_700_000_000)
    // Exactly representable in Float, so they survive JSON round-trips losslessly.
    private static let vec: [Float] = [0.5, -0.25, 0.75, 1.0]

    static func run() -> String {
        var failures: [String] = []
        var ran = 0

        // 1 — blank title+summary + content accrues one proposal of each kind.
        do {
            ran += 1
            var node = makeNode(title: "", summary: "", content: "a node with real content")
            _ = node.recordProposal(kind: .title, text: "A Fresh Title", currentSource: nil,
                                    sourceEmbedding: vec, posture: .automatic, generatedAt: date0)
            _ = node.recordProposal(kind: .summary, text: "A fresh summary.", currentSource: nil,
                                    sourceEmbedding: vec, posture: .automatic, generatedAt: date0)
            // `.tags` exercises the kind-generic mechanism (no live producer yet).
            _ = node.recordProposal(kind: .tags, text: "alpha, beta", currentSource: nil,
                                    sourceEmbedding: vec, posture: .automatic, generatedAt: date0)
            let kinds = Set((node.proposals ?? []).map { $0.kind })
            if node.proposals?.count != 3 {
                failures.append("1: expected 3 proposals, got \(node.proposals?.count ?? 0)")
            }
            if kinds != [.title, .summary, .tags] {
                failures.append("1: expected one of each kind, got \(kinds.map { $0.rawValue }.sorted())")
            }
        }

        // 2 — round-trip preserves proposals + sourceEmbedding.
        do {
            ran += 1
            var node = makeNode(title: "", summary: "", content: "content")
            _ = node.recordProposal(kind: .summary, text: "keep me", currentSource: nil,
                                    sourceEmbedding: vec, posture: .automatic, generatedAt: date0)
            do {
                let data = try JSONEncoder.airPad.encode(node)
                let back = try JSONDecoder.airPad.decode(Node.self, from: data)
                if back.proposals != node.proposals {
                    failures.append("2: proposals changed across round-trip")
                }
                if back.proposals?.first?.sourceEmbedding != vec {
                    failures.append("2: sourceEmbedding lost across round-trip (\(String(describing: back.proposals?.first?.sourceEmbedding)))")
                }
            } catch {
                failures.append("2: round-trip threw \(error)")
            }
        }

        // 3 — legacy node.json (no `proposals` key) decodes clean → nil.
        do {
            ran += 1
            let legacyJSON: [String: Any] = [
                "id": "legacy",
                "title": "old",
                "summary": "",
                "tags": [],
                "is_meta": false,
                "threads": [],
                "items": [],
                "created_at": "2023-01-15T09:00:00Z",
                "updated_at": "2023-01-15T10:00:00Z"
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: legacyJSON)
                let node = try JSONDecoder.airPad.decode(Node.self, from: data)
                if node.proposals != nil { failures.append("3: legacy proposals should be nil, got \(String(describing: node.proposals))") }
            } catch {
                failures.append("3: legacy decode threw \(error)")
            }
        }

        // 4 — user-authored summary records NO proposal and says "do not write".
        do {
            ran += 1
            var node = makeNode(title: "", summary: "my own words", content: "content",
                                summarySource: .user)
            let shouldWrite = node.recordProposal(kind: .summary, text: "the model's idea",
                                                  currentSource: node.summarySource,
                                                  sourceEmbedding: vec, posture: .automatic,
                                                  generatedAt: date0)
            if shouldWrite { failures.append("4: a .user summary must not be written") }
            if (node.proposals ?? []).contains(where: { $0.kind == .summary }) {
                failures.append("4: a .user summary must not accrue a proposal")
            }
        }

        // 5 — regeneration REPLACES, never appends.
        do {
            ran += 1
            var node = makeNode(title: "", summary: "", content: "content")
            _ = node.recordProposal(kind: .title, text: "First", currentSource: nil,
                                    sourceEmbedding: vec, posture: .automatic, generatedAt: date0)
            _ = node.recordProposal(kind: .title, text: "Second", currentSource: .model,
                                    sourceEmbedding: vec, posture: .automatic, generatedAt: date0)
            let titles = (node.proposals ?? []).filter { $0.kind == .title }
            if titles.count != 1 { failures.append("5: expected 1 title proposal after regen, got \(titles.count)") }
            if titles.first?.text != "Second" { failures.append("5: regen did not replace text (got \(titles.first?.text ?? "nil"))") }
        }

        // 6 — .automatic still writes; .propose withholds the write but still records.
        do {
            ran += 1
            // .automatic — the Stage-1 default → behaviour unchanged (summary written).
            var auto = makeNode(title: "", summary: "", content: "content")
            let write = auto.recordProposal(kind: .summary, text: "written summary",
                                            currentSource: auto.summarySource,
                                            sourceEmbedding: vec, posture: .automatic,
                                            generatedAt: date0)
            if !write { failures.append("6: .automatic must report write=true") }
            if write { auto.summary = "written summary"; auto.summarySource = .model }   // mirror the call site
            if auto.summary != "written summary" { failures.append("6: .automatic did not write the summary") }
            if auto.summarySource != .model { failures.append("6: .automatic did not stamp .model") }

            // .propose — the write is withheld, but the proposal is still recorded
            // (unreachable in Stage 1; asserts the posture seam for Stage 3).
            var prop = makeNode(title: "", summary: "", content: "content")
            let writeP = prop.recordProposal(kind: .summary, text: "proposed only",
                                             currentSource: prop.summarySource,
                                             sourceEmbedding: vec, posture: .propose,
                                             generatedAt: date0)
            if writeP { failures.append("6: .propose must report write=false") }
            if !(prop.proposals ?? []).contains(where: { $0.kind == .summary }) {
                failures.append("6: .propose must still record the proposal")
            }
        }

        // 7 — Stage 2 F2: the SOLICITED bypass. On a user-authored field an
        // UNSOLICITED generate records nothing (gate holds) and nothing is
        // surfaced; a SOLICITED one records + surfaces, marks the proposal
        // solicited, and STILL does not write (posture governs the write).
        do {
            ran += 1
            // unsolicited on a `.user` title → no record, nothing surfaced.
            var u = makeNode(title: "my title", summary: "", content: "content", titleSource: .user)
            let wU = u.recordProposal(kind: .title, text: "model title", currentSource: u.titleSource,
                                      sourceEmbedding: vec, posture: .propose, generatedAt: date0,
                                      solicited: false)
            if wU { failures.append("7: unsolicited .user must report write=false") }
            if (u.proposals ?? []).contains(where: { $0.kind == .title }) {
                failures.append("7: unsolicited generate must not record on a .user field")
            }
            // solicited on a `.user` title → records, marked solicited, surfaced,
            // and STILL no write.
            var s = makeNode(title: "my title", summary: "", content: "content", titleSource: .user)
            let wS = s.recordProposal(kind: .title, text: "asked-for title", currentSource: s.titleSource,
                                      sourceEmbedding: vec, posture: .propose, generatedAt: date0,
                                      solicited: true)
            if wS { failures.append("7: solicited must NEVER bypass the write (report false)") }
            let sp = s.proposals?.first { $0.kind == .title }
            if sp == nil { failures.append("7: solicited generate must record on a .user field") }
            if sp?.solicited != true { failures.append("7: recorded proposal must be marked solicited") }
            if s.surfacedProposal(kind: .title) == nil {
                failures.append("7: a solicited proposal on a .user field must be surfaced")
            }
            // and an UNSOLICITED proposal that predates authorship stays hidden:
            // record while nil, then the field becomes `.user`.
            var e = makeNode(title: "", summary: "", content: "content")
            _ = e.recordProposal(kind: .title, text: "auto title", currentSource: e.titleSource,
                                 sourceEmbedding: vec, posture: .propose, generatedAt: date0)
            e.titleSource = .user   // user then writes their own → authored
            if e.surfacedProposal(kind: .title) != nil {
                failures.append("7: an unsolicited proposal on a now-.user field must stay hidden (§ C3)")
            }
        }

        if failures.isEmpty {
            return "Proposal: \(ran)/\(ran) passed"
        } else {
            return "Proposal FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: - Helpers

    private static func makeNode(title: String,
                                 summary: String,
                                 content: String,
                                 titleSource: TagSource? = nil,
                                 summarySource: TagSource? = nil) -> Node {
        Node(
            id: UUID().uuidString,
            createdAt: date0,
            updatedAt: date0,
            title: title,
            summary: summary,
            tags: [],
            items: [NodeItem(id: "i1", type: .text, createdAt: date0, content: content)],
            summarySource: summarySource,
            titleSource: titleSource
        )
    }
}
