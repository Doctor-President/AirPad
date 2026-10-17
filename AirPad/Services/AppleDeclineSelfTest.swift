#if DEBUG
import Foundation

/// live-20 (1) — `-AppleDeclineSelfTest` (run with `-StubAuthorModel -StubAppleDeclines YES`): what happens when Apple
/// Intelligence declines an entry. T's device (TF 202610151405, iOS 27, on-device model off): a sensitive entry got no
/// title/summary and the Proposals sheet showed "The model's safety guardrails were triggered." with Retry — iOS 27
/// throws the new `LanguageModelError`, which the naming path didn't recognise as a refusal.
///   • the parser + refusal classifier rows (`AppleNaming.selfTestRows`);
///   • Proposals sheet: a decline is a REFUSAL (the honest copy + the settings link), not an error to retry;
///   • Proposals sheet, on-device model installed: it names the entry, and the proposal says so;
///   • Done with auto-naming ON: the entry gets its first words as its title (T's B1 fragment rule, which T kept for
///     declines too — live-21), no proposal, and its tags decline is recorded; with the on-device model installed, it
///     names and tags the entry.
/// Runs in the `-UITestLibrary` scratch; synthetic words only.
extension CorpusStore {

    private static let declineText = "Clinic follow-up today. The STI panel came back negative; retest in three months with a new partner."

    func runAppleDeclineSelfTest() async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok || detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        for r in AppleNaming.selfTestRows() { row("parse/\(r.name)", r.ok) }

        let defaults = UserDefaults.standard
        let priorDelegate = defaults.object(forKey: AuthorshipPosture.delegateSettingKey)
        let priorLocal = defaults.object(forKey: "StubLocalModelReady")
        defaults.set(true, forKey: AuthorshipPosture.delegateSettingKey)
        defer {
            defaults.set(priorDelegate, forKey: AuthorshipPosture.delegateSettingKey)
            defaults.set(priorLocal, forKey: "StubLocalModelReady")
        }
        row("stub-declines-is-on", AIService.stubAppleDeclines, "launch with -StubAppleDeclines YES")

        var made: [String] = []
        func newEntry() async -> String {
            let id = "adt-" + UUID().uuidString.prefix(8)
            var n = Node(id: id, createdAt: Date(), updatedAt: Date(), title: "", summary: "", tags: [])
            n.items = [NodeItem(id: UUID().uuidString, type: .text, createdAt: Date(), content: Self.declineText)]
            n.entrySchemaVersion = 1
            await addNode(n, position: .zero)
            made.append(id)
            return id
        }
        func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
        /// Read through the persisted shape, so this file compiles whatever the proposal's Swift field is called.
        func proposalSaysOnDevice(_ id: String, _ kind: Proposal.Kind) -> Bool {
            guard let p = node(id)?.proposals?.first(where: { $0.kind == kind }),
                  let d = try? JSONEncoder().encode(p),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
            return (o["on_device_after_decline"] as? Bool) == true
        }
        func describe(_ f: NodeAIFailure?) -> String { f.map { String(describing: $0) } ?? "nil" }

        // 1. Proposals sheet ("Suggest"), no on-device model → a refusal.
        defaults.set(false, forKey: "StubLocalModelReady")
        do {
            let id = await newEntry()
            let reason = await processNodeWithAI(nodeID: id, suppressTagSheet: true, solicited: true, aspects: [.title])
            var isRefused = false
            if case .refused = reason { isRefused = true }
            row("sheet-decline-is-a-refusal", isRefused, "reason=\(describe(reason))")
        }
        // 2. Proposals sheet, on-device model installed → it names the entry, and the proposal says so.
        defaults.set(true, forKey: "StubLocalModelReady")
        do {
            let id = await newEntry()
            let reason = await processNodeWithAI(nodeID: id, suppressTagSheet: true, solicited: true, aspects: [.title])
            let p = node(id)?.surfacedProposal(kind: .title)?.text
            row("sheet-decline-on-device-names", reason == nil && p == "On-device stub title", "reason=\(describe(reason)) proposal=\(p ?? "nil")")
            row("sheet-decline-on-device-says-so", proposalSaysOnDevice(id, .title))
        }
        // 3. Done with auto-naming ON, no on-device model → B1: its first words are its title; the tags decline is recorded.
        defaults.set(false, forKey: "StubLocalModelReady")
        do {
            let id = await newEntry()
            await enrichIfNeeded(nodeID: id, at: .committed)
            let n = node(id)
            row("done-decline-fragment-title", n?.title == String(Self.declineText.prefix(40)) && n?.summary == "",
                "title=\"\(n?.title ?? "nil")\" summary=\"\(n?.summary ?? "nil")\"")
            row("done-decline-no-ghost", n?.surfacedProposal(kind: .title) == nil && n?.surfacedProposal(kind: .summary) == nil)
            row("done-decline-tags-recorded", n?.embeddingFailureReason == "guardrail_refused", "reason=\(n?.embeddingFailureReason ?? "nil")")
        }
        // 4. Done with auto-naming ON, on-device model installed → it names and tags the entry.
        defaults.set(true, forKey: "StubLocalModelReady")
        do {
            let id = await newEntry()
            await enrichIfNeeded(nodeID: id, at: .committed)
            let n = node(id)
            row("done-decline-on-device-names", n?.title == "On-device stub title" && n?.summary == "On-device stub summary.",
                "title=\"\(n?.title ?? "nil")\" summary=\"\(n?.summary ?? "nil")\"")
            row("done-decline-on-device-tags", n?.folksonomy == ["on-device", "stub"], "folksonomy=\(n?.folksonomy ?? [])")
        }

        for id in made { await deleteNode(id: id) }
        return "[AppleDeclineSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
