import Foundation

/// live-27 (4) — who wrote an answer: the route, the model tag that was on the wire, and what fed it (a web search, the
/// library). Recorded on every answer when it commits (`ChatSession`, from `ModelRouter.lastAnswerSource`) and saved
/// with the chat (`ChatSession.Message.provenance` → `Chat.messages`). Answers saved before live-27 have none and show
/// no caption. App chrome: never part of the answer's text, its copy or its share.
struct ChatProvenance: Codable, Hashable, Sendable {
    enum Route: String, Codable, Sendable { case apple, host, server }
    var route: Route
    /// The model tag on the wire ("qwen3:4b-instruct-2507-q4_K_M"), or "Apple Intelligence".
    var model: String
    /// The model as the pill named it when the answer was written ("Qwen3 4B Instruct").
    var name: String
    var web: Bool? = nil
    var library: Bool? = nil

    /// The caption under the answer, in the meta style: "Apple Intelligence" · "Qwen3 4B Instruct · Host" ·
    /// "… + web" when a search fed it.
    var caption: String {
        var s: String
        switch route {
        case .apple: s = name
        case .host: s = "\(name) · Host"
        case .server: s = "\(name) · Server"
        }
        if web == true { s += " + web" }
        return s
    }

    /// The "Switched to <model>" divider goes above an answer whose model differs from the previous answer's (both
    /// recorded). Keyed by the answer's message id.
    static func switches(in messages: [ChatSession.Message]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        var last: ChatProvenance?
        for m in messages where m.role == .assistant {
            guard let p = m.provenance else { continue }
            if let l = last, l.route != p.route || l.model != p.model { out[m.id] = "Switched to \(p.name)" }
            last = p
        }
        return out
    }

    /// The name the pill shows for a Host / server tag.
    @MainActor static func displayName(route: Route, model: String) -> String {
        if route == .apple { return ModelRouter.foundationModelName }
        if let m = HostCatalog.shared.models.first(where: { $0.tag == model }) { return HostCatalog.shared.name(m) }
        return CatalogModel.friendlyName(forTag: model)
    }
}

#if DEBUG
/// `-ChatProvenanceSelfTest` — old answers decode with no provenance; a stored chat keeps it; the captions; the switch
/// divider; and the REAL send path (`-StubAnswerModels`, set here) records who wrote each answer.
enum ChatProvenanceSelfTest {
    @MainActor static func run() async -> String {
        var rows: [(String, Bool, String)] = []
        func row(_ n: String, _ ok: Bool, _ d: String = "") { rows.append((n, ok, d)) }

        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"An old answer."}"#
        let decoded = try? JSONDecoder().decode(ChatSession.Message.self, from: Data(old.utf8))
        row("an-old-answer-decodes-with-no-provenance", decoded != nil && decoded?.provenance == nil)

        let apple = ChatProvenance(route: .apple, model: "Apple Intelligence", name: "Apple Intelligence")
        let qwen = ChatProvenance(route: .host, model: "qwen3:4b-instruct-2507-q4_K_M", name: "Qwen3 4B Instruct")
        var web = qwen; web.web = true
        let server = ChatProvenance(route: .server, model: "gemma3:12b", name: "Gemma 3 12B")
        row("captions", apple.caption == "Apple Intelligence" && qwen.caption == "Qwen3 4B Instruct · Host"
            && web.caption == "Qwen3 4B Instruct · Host + web" && server.caption == "Gemma 3 12B · Server",
            [apple, qwen, web, server].map(\.caption).joined(separator: " | "))

        var a1 = ChatSession.Message(role: .assistant, text: "One."); a1.provenance = apple
        var a2 = ChatSession.Message(role: .assistant, text: "Two."); a2.provenance = apple
        var a3 = ChatSession.Message(role: .assistant, text: "Three."); a3.provenance = qwen
        let legacy = ChatSession.Message(role: .assistant, text: "Old.")
        let u = { ChatSession.Message(role: .user, text: "Q") }
        let sw = ChatProvenance.switches(in: [legacy, u(), a1, u(), a2, u(), a3])
        row("a-divider-only-where-the-model-changes", sw.count == 1 && sw[a3.id] == "Switched to Qwen3 4B Instruct", "\(sw.values)")

        let chat = Chat(id: UUID(), title: "t", createdAt: Date(), updatedAt: Date(), messages: [u(), a3])
        let back = (try? JSONEncoder().encode(chat)).flatMap { try? JSONDecoder().decode(Chat.self, from: $0) }
        row("a-stored-chat-keeps-it", back?.messages.last?.provenance == qwen)

        // The real send path: two answers, Apple Intelligence then the Host's qwen (a switch in the middle).
        let d = UserDefaults.standard, prior = d.string(forKey: "StubAnswerModels")
        d.set("apple,qwen3:4b-instruct-2507-q4_K_M", forKey: "StubAnswerModels"); ModelRouter.stubAnswerCount = 0
        let s = ChatSession()
        await s.send("First question")
        await s.send("Second question")
        if let prior { d.set(prior, forKey: "StubAnswerModels") } else { d.removeObject(forKey: "StubAnswerModels") }
        let answers = s.messages.filter { $0.role == .assistant }
        let p = answers.map(\.provenance)
        row("send-records-who-wrote-each-answer", answers.count == 2 && p[0]?.route == .apple && p[0]?.model == "Apple Intelligence"
            && p[1]?.route == .host && p[1]?.model == "qwen3:4b-instruct-2507-q4_K_M" && p[1]?.web != true,
            "\(p.map { $0?.caption ?? "nil" })")
        row("the-switch-shows-a-divider", answers.count == 2 && ChatProvenance.switches(in: s.messages)[answers[1].id]?.hasPrefix("Switched to ") == true)
        row("the-answer-text-is-unchanged (copy / share)", answers.allSatisfy { !$0.text.contains("·") && !$0.text.contains("Host") })

        let fails = rows.filter { !$0.1 }
        return (fails.isEmpty ? "PASS — \(rows.count)/\(rows.count)" : "FAIL — \(rows.count - fails.count)/\(rows.count)")
            + rows.map { "\n\($0.1 ? "PASS" : "FAIL") \($0.0)\($0.2.isEmpty ? "" : " — \($0.2)")" }.joined()
    }
}
#endif
