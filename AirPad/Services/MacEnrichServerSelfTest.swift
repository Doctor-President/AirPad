#if DEBUG
import Foundation

/// Mac batch C0 — `-MacEnrichServerSelfTest` (launch with `-MacEnrichEndpoint http://127.0.0.1:11434`, no
/// `-StubAuthorModel`): on the Mac, the user's own server names and tags an entry when Apple Intelligence is
/// unavailable or declines it; with no server, nothing changes. Real server calls; the Apple Intelligence states are
/// the DEBUG stubs (`StubOnDeviceUnavailable`, `StubAppleDeclines`), set and cleared here (never pass them as launch
/// args: an argument outranks these writes). Synthetic Sample-safe text; the entries it makes are deleted after.
/// On iPhone/iPad (not a Mac) the server rows expect today's behaviour: no server fallback.
extension CorpusStore {

    private static let enrichText = "Sourdough starter log. Fed it at nine with equal flour and water; it doubled by two. Next bake on Saturday at seventy-five percent hydration, with a longer cold proof."

    func runMacEnrichServerSelfTest() async -> String {
        var rows: [String] = [], fails = 0
        func row(_ name: String, _ ok: Bool, _ detail: String = "") {
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (detail.isEmpty ? "" : " — \(detail)"))
            if !ok { fails += 1 }
        }
        let d = UserDefaults.standard
        let endpoint = d.string(forKey: "MacEnrichEndpoint") ?? "http://127.0.0.1:11434"
        let keys = ["StubOnDeviceUnavailable", "StubAppleDeclines", "DebugEndpointURL", "StubLocalModelReady",
                    AuthorshipPosture.delegateSettingKey]
        let prior = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, prior) { d.set(v, forKey: k) } }
        d.set(true, forKey: AuthorshipPosture.delegateSettingKey)
        d.set(false, forKey: "StubLocalModelReady")
        let isMac = RunningOnMac.isMac
        row("context", true, "isMac=\(isMac) endpoint=\(endpoint) pairing=\(HostPairing.load() != nil)")

        var made: [String] = []
        func newEntry() async -> String {
            let id = "mes-" + UUID().uuidString.prefix(8)
            var n = Node(id: id, createdAt: Date(), updatedAt: Date(), title: "", summary: "", tags: [])
            n.items = [NodeItem(id: UUID().uuidString, type: .text, createdAt: Date(), content: Self.enrichText)]
            n.entrySchemaVersion = 1
            await addNode(n, position: .zero)
            made.append(id)
            return id
        }
        func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
        func describe(_ f: NodeAIFailure?) -> String { f.map { String(describing: $0) } ?? "nil" }
        func setState(unavailable: Bool, declines: Bool, server: String?) {
            if unavailable { d.set("notReady", forKey: "StubOnDeviceUnavailable") } else { d.removeObject(forKey: "StubOnDeviceUnavailable") }
            d.set(declines, forKey: "StubAppleDeclines")
            if let server { d.set(server, forKey: "DebugEndpointURL") } else { d.removeObject(forKey: "DebugEndpointURL") }
            ModelRouter.endpointUnreachable = false
        }
        func sheet(_ label: String, expectNamed: Bool) async {
            let id = await newEntry()
            let t0 = Date()
            let reason = await processNodeWithAI(nodeID: id, suppressTagSheet: true, solicited: true)
            let title = node(id)?.surfacedProposal(kind: .title)?.text ?? ""
            let secs = String(format: "%.1fs", Date().timeIntervalSince(t0))
            if expectNamed {
                row("\(label)/sheet-named", reason == nil && !title.isEmpty, "reason=\(describe(reason)) title=\"\(title)\" \(secs)")
            } else {
                row("\(label)/sheet-not-named", reason != nil && title.isEmpty, "reason=\(describe(reason)) \(secs)")
            }
        }
        func done(_ label: String, expectTagged: Bool) async {
            let id = await newEntry()
            await enrichIfNeeded(nodeID: id, at: .committed)
            let n = node(id)
            let folk = n?.folksonomy ?? []
            if expectTagged {
                row("\(label)/done-titled-and-tagged", !(n?.title ?? "").isEmpty && !folk.isEmpty,
                    "title=\"\(n?.title ?? "nil")\" tags=\(folk)")
            } else {
                row("\(label)/done-quiet", n != nil && folk.isEmpty, "title=\"\(n?.title ?? "nil")\" reason=\(n?.embeddingFailureReason ?? "nil")")
            }
        }

        // 1. No Apple Intelligence, no server → today's quiet fallback (a pairing would count as a server).
        setState(unavailable: true, declines: false, server: nil)
        if HostPairing.load() == nil {
            await sheet("unavailable-no-server", expectNamed: false)
            await done("unavailable-no-server", expectTagged: false)
            let sub = await AIService().processSubstrate(content: Self.enrichText)
            var quiet = false
            if case .otherError(let e) = sub, e.errorType == "model_unavailable" { quiet = true }
            row("unavailable-no-server/substrate-unavailable", quiet, "\(sub)")
        }
        // 2. No Apple Intelligence, the user's server → the server names and tags it (Mac only).
        setState(unavailable: true, declines: false, server: endpoint)
        await sheet("unavailable-server", expectNamed: isMac)
        await done("unavailable-server", expectTagged: isMac)
        // 3. Apple Intelligence declines, the user's server → the server names and tags it (Mac only).
        setState(unavailable: false, declines: true, server: endpoint)
        await sheet("declines-server", expectNamed: isMac)
        await done("declines-server", expectTagged: isMac)
        // 4. Apple Intelligence declines, the server doesn't answer → the decline, as before.
        setState(unavailable: false, declines: true, server: "http://127.0.0.1:9")
        do {
            let id = await newEntry()
            let reason = await processNodeWithAI(nodeID: id, suppressTagSheet: true, solicited: true)
            var refused = false
            if case .refused = reason { refused = true }
            row("declines-dead-server/sheet-refusal", refused, "reason=\(describe(reason))")
        }

        for id in made { await deleteNode(id: id) }
        return "[MacEnrichServerSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n" + rows.joined(separator: "\n")
    }
}
#endif
