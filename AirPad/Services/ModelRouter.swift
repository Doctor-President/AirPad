import Foundation
import FoundationModels

/// Librarian model routing. Reads the Keychain for configured providers
/// and dispatches `generate(...)` to the active one.
///
/// Privacy oath: Foundation Model is the default. Ollama only runs when
/// the user has explicitly configured an endpoint in Settings (no key, no
/// call). Frontier providers (Anthropic / OpenAI / DeepSeek) are stored
/// for future routing — today their keys are recognized for display in
/// Settings but no HTTP dispatch exists; routing them lands in a later
/// commit and would be a privacy-policy change (corpus content leaving
/// the device boundary), so we don't ship a half-wired path today.
///
/// Single static dispatch so the call site (`LibrarianState`) doesn't
/// hold a router instance — every query reads the latest Keychain state.
enum ModelRouter {

    /// Resolved provider for the current Keychain state. Frontier
    /// providers map to `.foundationModel` until their HTTP paths land.
    enum Provider: Sendable {
        case foundationModel
        case ollama(endpoint: String)

        var displayName: String {
            switch self {
            case .foundationModel: return "Foundation Model"
            case .ollama: return "Ollama (local)"
            }
        }
    }

    /// Resolves the active provider. Ollama wins over FM only when the
    /// endpoint is non-empty *and* parses as a URL — anything else falls
    /// back to FM so a malformed setting can't strand the user with no
    /// model.
    static var active: Provider {
        let endpoint = (KeychainHelper.load(key: "ollamaEndpoint") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty, URL(string: endpoint) != nil {
            return .ollama(endpoint: endpoint)
        }
        return .foundationModel
    }

    /// Friendly, quiet name for the on-device Foundation Model — no network, safe
    /// to return instantly. (Wording confirmed by T.)
    static let foundationModelName = "Apple Intelligence"

    /// Resting label for a configured-but-not-yet-known remote endpoint (not
    /// probed, or unreachable). Clear and calm — never a blank or an error.
    static let remoteRestingName = "No model"

    /// Human-readable name of the model that will answer the NEXT turn. Reads the
    /// live provider (Keychain), so an endpoint swapped in Settings is reflected.
    /// Call this OFF the render path — it may hit the network for a remote endpoint
    /// (and the Keychain read is XPC-backed). FM returns instantly; a remote
    /// endpoint is probed for its first model id (the SAME `firstOllamaModel` the
    /// generate path uses), falling back to the resting label if unreachable — so
    /// the caller always gets a display string, never a throw or an empty value.
    static func resolveActiveModelName() async -> String {
        switch active {
        case .foundationModel:
            return foundationModelName
        case .ollama(let endpoint):
            guard let base = URL(string: endpoint) else { return remoteRestingName }
            return (try? await firstOllamaModel(base: base)) ?? remoteRestingName
        }
    }

    /// One-shot text generation. The system prompt is sent as a separate
    /// role for Ollama (OpenAI chat-completions shape); for FM it's
    /// concatenated since `LanguageModelSession` doesn't expose a system
    /// channel today.
    static func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        switch active {
        case .foundationModel:
            return try await generateFoundationModel(systemPrompt: systemPrompt, userPrompt: userPrompt)
        case .ollama(let endpoint):
            return try await generateOllama(endpoint: endpoint, systemPrompt: systemPrompt, userPrompt: userPrompt)
        }
    }

    /// Streaming text generation. Yields incremental string deltas as they
    /// arrive. For Ollama this is real SSE streaming via `URLSession.bytes`
    /// — the per-chunk clock dissolves the silent 60s timeout that plagues
    /// the one-shot `generate(...)` path. For Foundation Model this is
    /// `LanguageModelSession.streamResponse(to:)`, whose cumulative snapshots
    /// are converted to deltas in `streamFoundationModel` so both providers
    /// present the identical delta contract to call sites.
    static func generateStreaming(
        systemPrompt: String,
        userPrompt: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    switch active {
                    case .foundationModel:
                        guard #available(iOS 26.0, *) else {
                            throw RouterError.foundationModelUnavailable
                        }
                        try await streamFoundationModel(
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            continuation: continuation
                        )
                        continuation.finish()
                    case .ollama(let endpoint):
                        try await streamOllama(
                            endpoint: endpoint,
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            continuation: continuation
                        )
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    enum RouterError: LocalizedError {
        case foundationModelUnavailable
        case ollamaNoModels
        case ollamaBadEndpoint(String)
        case ollamaTransport(String)
        case ollamaHTTPError(path: String, status: Int, body: String)
        case ollamaBadResponse(path: String, body: String)

        var errorDescription: String? {
            switch self {
            case .foundationModelUnavailable: return "Foundation Model not available on this device."
            case .ollamaNoModels: return "Endpoint is reachable but no models are loaded. Load a model in LM Studio / pull one with `ollama pull <name>`."
            case .ollamaBadEndpoint(let s): return "Ollama endpoint is not a valid URL: \(s)"
            case .ollamaTransport(let s): return "Couldn't reach Ollama: \(s)"
            case .ollamaHTTPError(let path, let status, let body):
                return "Endpoint returned HTTP \(status) at \(path): \(Self.truncate(body))"
            case .ollamaBadResponse(let path, let body):
                return "Endpoint returned an unexpected response at \(path): \(Self.truncate(body))"
            }
        }

        private static func truncate(_ s: String) -> String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
        }
    }

    // MARK: - Foundation Model

    private static func generateFoundationModel(systemPrompt: String, userPrompt: String) async throws -> String {
        guard #available(iOS 26.0, *) else {
            throw RouterError.foundationModelUnavailable
        }
        guard SystemLanguageModel.default.isAvailable else {
            throw RouterError.foundationModelUnavailable
        }
        let session = LanguageModelSession()
        let combined = systemPrompt.isEmpty
            ? userPrompt
            : "\(systemPrompt)\n\n\(userPrompt)"
        return try await session.respond(to: combined).content
    }

    /// Streaming sibling of `generateFoundationModel`. `LanguageModelSession`
    /// exposes `streamResponse(to:)`, which for a `String` output yields a
    /// `ResponseStream<String>` whose element is a `Snapshot` carrying
    /// `.content: String` — a CUMULATIVE view of the whole response so far,
    /// NOT a delta. We convert to deltas at THIS boundary so every call site
    /// sees the same delta contract the Ollama path already provides
    /// (`ChatSession.send` does `streamingText += delta`); a snapshot must
    /// never leak upward or it duplicates exponentially.
    @available(iOS 26.0, *)
    private static func streamFoundationModel(
        systemPrompt: String,
        userPrompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard SystemLanguageModel.default.isAvailable else {
            throw RouterError.foundationModelUnavailable
        }
        let session = LanguageModelSession()
        let combined = systemPrompt.isEmpty
            ? userPrompt
            : "\(systemPrompt)\n\n\(userPrompt)"

        // Snapshots are CUMULATIVE. Convert to deltas via suffix-diff.
        var emitted = ""
        for try await snapshot in session.streamResponse(to: combined) {
            let full = snapshot.content
            guard full.count > emitted.count else { continue }
            guard full.hasPrefix(emitted) else {
                // Model revised earlier text — suffix-diff is invalid. Don't
                // silently patch: yield the tail so nothing is lost, but flag
                // it loudly so this surfaces during device verify.
                print("[ModelRouter] FM snapshot NOT append-only. Stop.")
                continuation.yield(String(full.dropFirst(emitted.count)))
                emitted = full
                continue
            }
            continuation.yield(String(full.dropFirst(emitted.count)))
            emitted = full
        }
    }

    // MARK: - Ollama

    /// OpenAI-compatible chat completions against the user's local
    /// endpoint. Picks the first available model via `/v1/models` rather
    /// than hardcoding — most home setups have exactly one model loaded,
    /// and a hardcoded default would fail silently when the user runs
    /// something else (qwen, mistral, gemma).
    ///
    /// System prompt is folded into the first user message rather than
    /// sent as a separate `system` role. Mistral's Jinja chat template
    /// (and several other instruction templates) reject a standalone
    /// system message with HTTP 400, since the template expects the
    /// conversation to start with `user`. Concatenation works across all
    /// OpenAI-compatible templates so we always fold.
    private static func generateOllama(
        endpoint: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        guard let base = URL(string: endpoint) else {
            throw RouterError.ollamaBadEndpoint(endpoint)
        }
        let modelName = try await firstOllamaModel(base: base)

        let path = "v1/chat/completions"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let foldedUserContent = systemPrompt.isEmpty
            ? userPrompt
            : "\(systemPrompt)\n\n\(userPrompt)"
        let body: [String: Any] = [
            "model": modelName,
            "stream": false,
            "messages": [
                ["role": "user", "content": foldedUserContent]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await runRequest(request, path: path)
        let bodyString = String(data: data, encoding: .utf8) ?? ""

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            print("[ModelRouter] \(path) HTTP \(http.statusCode): \(bodyString)")
            throw RouterError.ollamaHTTPError(path: path, status: http.statusCode, body: bodyString)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            print("[ModelRouter] \(path) parse failure. body=\(bodyString)")
            throw RouterError.ollamaBadResponse(path: path, body: bodyString)
        }
        return content
    }

    /// Streaming sibling of `generateOllama`. Body construction, model
    /// selection, and error semantics match the one-shot variant exactly
    /// — only `stream: true` and `URLSession.bytes` differ. SSE lines are
    /// parsed in the OpenAI chat-completions delta shape and yielded as
    /// they arrive; `URLSession.bytes` resets its inactivity clock on each
    /// chunk, so the silent-60s timeout that affects `.data(for:)` does
    /// not apply here.
    private static func streamOllama(
        endpoint: String,
        systemPrompt: String,
        userPrompt: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        guard let base = URL(string: endpoint) else {
            throw RouterError.ollamaBadEndpoint(endpoint)
        }
        let modelName = try await firstOllamaModel(base: base)

        let path = "v1/chat/completions"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let foldedUserContent = systemPrompt.isEmpty
            ? userPrompt
            : "\(systemPrompt)\n\n\(userPrompt)"
        let body: [String: Any] = [
            "model": modelName,
            "stream": true,
            "messages": [
                ["role": "user", "content": foldedUserContent]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            print("[ModelRouter] \(path) transport: \(error.localizedDescription)")
            throw RouterError.ollamaTransport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var bodyData = Data()
            for try await byte in bytes { bodyData.append(byte) }
            let bodyString = String(data: bodyData, encoding: .utf8) ?? ""
            print("[ModelRouter] \(path) HTTP \(http.statusCode): \(bodyString)")
            throw RouterError.ollamaHTTPError(path: path, status: http.statusCode, body: bodyString)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }

            if let data = payload.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = parsed["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                continuation.yield(content)
            }
        }
    }

    private static func firstOllamaModel(base: URL) async throws -> String {
        // LM Studio moved model listing to api/v0/models in a recent update
        // and broke the OpenAI-compatible /v1/models endpoint. Response shape
        // (data array, each entry has an id string) is unchanged.
        let path = "api/v0/models"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "GET"

        let (data, response) = try await runRequest(request, path: path)
        let bodyString = String(data: data, encoding: .utf8) ?? ""

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            print("[ModelRouter] \(path) HTTP \(http.statusCode): \(bodyString)")
            throw RouterError.ollamaHTTPError(path: path, status: http.statusCode, body: bodyString)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]]
        else {
            print("[ModelRouter] \(path) parse failure. body=\(bodyString)")
            throw RouterError.ollamaBadResponse(path: path, body: bodyString)
        }
        guard let firstID = entries.compactMap({ $0["id"] as? String }).first else {
            throw RouterError.ollamaNoModels
        }
        print("[ModelRouter] picked model id=\(firstID) from \(path)")
        return firstID
    }

    private static func runRequest(_ request: URLRequest, path: String) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            print("[ModelRouter] \(path) transport: \(error.localizedDescription)")
            throw RouterError.ollamaTransport(error.localizedDescription)
        }
    }
}

// MARK: - Agentic tool calling (web search / fetch)

/// One structured link surfaced by a tool — the unit the collapsible activity row
/// renders TAPPABLE (url + title). Codable so it can ride along in a persisted
/// transcript message.
struct ToolLink: Codable, Hashable, Sendable, Identifiable {
    let title: String
    let url: String
    let snippet: String?
    var id: String { url }
}

/// What a `ToolExecutor` returns for one call: the text handed BACK to the model
/// (tool-role message content) plus any structured links for the activity UI.
struct ToolResult: Sendable {
    let textForModel: String
    let links: [ToolLink]
}

/// One tool call the model requested (OpenAI shape). `argumentsJSON` is the raw
/// JSON string; `arguments` decodes it lazily.
struct ToolCall: Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}

/// Result of one model turn in the agentic loop: streamed content (already handed
/// to the caller via the delta callback) plus any tool calls the model requested.
struct AgentTurn: Sendable {
    let content: String
    let toolCalls: [ToolCall]
}

/// ★ THE LOAD-BEARING SEAM. The agent loop is identical whether AIRPAD executes the
/// tool or a relay / BYO-key backend does — only this one method differs. This build
/// ships `WebSearchToolExecutor` (AirPad-executes via free DuckDuckGo HTML scraping,
/// zero cost / no key — a DEV/TEST executor, NOT the declared launch backend). A
/// thin-relay or keyed implementation drops in behind the SAME method later without
/// touching the loop.
protocol ToolExecutor: Sendable {
    func execute(name: String, arguments: [String: Any]) async -> ToolResult
}

/// The FIXED tool contract — identical names/shapes in the test executor AND the
/// eventual launch backend, so swapping executors never changes the wire the model
/// sees.
enum AgentTools {
    static let webSearch = "web_search"
    static let fetchURL  = "fetch_url"

    /// OpenAI `tools` schema, attached to every private-mode remote request.
    static let schema: [[String: Any]] = [
        ["type": "function", "function": [
            "name": webSearch,
            "description": "Search the web and return a list of results (title, url, snippet). Use for current events, facts you are unsure of, or anything needing up-to-date information.",
            "parameters": ["type": "object",
                "properties": ["query": ["type": "string", "description": "The search query."]],
                "required": ["query"]]
        ]],
        ["type": "function", "function": [
            "name": fetchURL,
            "description": "Fetch the readable text of a web page by URL. Use to read a result found via web_search.",
            "parameters": ["type": "object",
                "properties": ["url": ["type": "string", "description": "The absolute URL to fetch."]],
                "required": ["url"]]
        ]]
    ]
}

extension ModelRouter {

    /// Raw model id for the request `model` field (remote endpoints). Reuses the
    /// same discovery the generate path uses.
    static func firstModelID(endpoint: String) async throws -> String {
        guard let base = URL(string: endpoint) else { throw RouterError.ollamaBadEndpoint(endpoint) }
        return try await firstOllamaModel(base: base)
    }

    /// One agentic model turn against a remote OpenAI-compatible endpoint. Streams
    /// content deltas via `onContentDelta` (so a NORMAL answer streams like today)
    /// AND accumulates any `tool_call` fragments, returning the assembled turn. If
    /// `toolCalls` is empty the streamed content IS the final answer; otherwise the
    /// caller runs the tools and calls again with results appended. Non-tool models
    /// simply never emit tool_calls → the loop degrades to a single streamed answer.
    static func streamAgentTurn(
        endpoint: String,
        model: String,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        onContentDelta: @Sendable @escaping (String) -> Void
    ) async throws -> AgentTurn {
        guard let base = URL(string: endpoint) else { throw RouterError.ollamaBadEndpoint(endpoint) }
        let path = "v1/chat/completions"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "stream": true, "messages": messages]
        if let tools { body["tools"] = tools }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw RouterError.ollamaTransport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes { data.append(b) }
            let s = String(data: data, encoding: .utf8) ?? ""
            throw RouterError.ollamaHTTPError(path: path, status: http.statusCode, body: s)
        }

        var content = ""
        // Tool calls stream in fragments keyed by index (id/name once, arguments in
        // pieces). Accumulate per index, assemble at end.
        var accum: [Int: (id: String, name: String, args: String)] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            if let c = delta["content"] as? String, !c.isEmpty {
                content += c
                onContentDelta(c)
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let idx = call["index"] as? Int ?? 0
                    var e = accum[idx] ?? (id: "", name: "", args: "")
                    if let id = call["id"] as? String, !id.isEmpty { e.id = id }
                    if let fn = call["function"] as? [String: Any] {
                        if let n = fn["name"] as? String { e.name += n }
                        if let a = fn["arguments"] as? String { e.args += a }
                    }
                    accum[idx] = e
                }
            }
        }
        let toolCalls = accum.sorted { $0.key < $1.key }.map { idx, e in
            ToolCall(id: e.id.isEmpty ? "call_\(idx)" : e.id, name: e.name, argumentsJSON: e.args)
        }
        return AgentTurn(content: content, toolCalls: toolCalls)
    }
}

/// ★ DEV/TEST executor — AirPad-executes the fixed tool pair for zero cost, no key,
/// no provider account, so T can watch the loop work. `web_search` scrapes the free
/// DuckDuckGo HTML endpoint (the same approach LM Studio's local-web-search plugin
/// uses); `fetch_url` is a plain HTTPS GET + readability trim. ⚠️ Direct-from-device
/// scraping does NOT scale (per-install traffic → rate-limit / block risk) — this is
/// NOT the launch backend; a thin-relay or BYO-key executor swaps in behind
/// `ToolExecutor` later. See the launch-backend flag in the report.
struct WebSearchToolExecutor: ToolExecutor {

    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func execute(name: String, arguments: [String: Any]) async -> ToolResult {
        switch name {
        case AgentTools.webSearch:
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return ToolResult(textForModel: "No query provided.", links: []) }
            let links = await Self.duckDuckGoSearch(query)
            guard !links.isEmpty else {
                return ToolResult(textForModel: "No results found for \"\(query)\".", links: [])
            }
            let text = links.enumerated().map { i, l in
                "[\(i + 1)] \(l.title)\n\(l.url)\n\(l.snippet ?? "")"
            }.joined(separator: "\n\n")
            return ToolResult(textForModel: text, links: links)

        case AgentTools.fetchURL:
            let raw = (arguments["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
                return ToolResult(textForModel: "Invalid URL: \(raw)", links: [])
            }
            let text = await Self.fetchReadable(url)
            return ToolResult(textForModel: text, links: [])

        default:
            return ToolResult(textForModel: "Unknown tool: \(name)", links: [])
        }
    }

    // MARK: DuckDuckGo HTML scrape

    private static func duckDuckGoSearch(_ query: String) async -> [ToolLink] {
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return [] }
        return parseDDG(html)
    }

    private static func parseDDG(_ html: String) -> [ToolLink] {
        let anchors  = regexCaptures(#"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, html)
        let snippets = regexCaptures(#"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#, html)
        var out: [ToolLink] = []
        for (i, a) in anchors.enumerated() where i < 8 {
            guard a.count >= 2 else { continue }
            let href = decodeDDGHref(a[0])
            let title = decodeEntities(stripTags(a[1])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !title.isEmpty else { continue }
            let snippet = i < snippets.count && !snippets[i].isEmpty
                ? decodeEntities(stripTags(snippets[i][0])).trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            out.append(ToolLink(title: title, url: href, snippet: snippet))
        }
        return out
    }

    /// DDG result hrefs are redirects like `//duckduckgo.com/l/?uddg=<encoded>&rut=…`.
    /// Pull the `uddg` target (URLComponents percent-decodes query values).
    private static func decodeDDGHref(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("//") { s = "https:" + s }
        guard let comps = URLComponents(string: s) else { return raw }
        if let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        return s
    }

    // MARK: fetch_url readability

    private static func fetchReadable(_ url: URL, budget: Int = 6000) async -> String {
        var req = URLRequest(url: url)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else {
            return "Couldn't fetch \(url.absoluteString)."
        }
        var text = removeBlocks(html, tag: "script")
        text = removeBlocks(text, tag: "style")
        text = stripTags(text)
        text = decodeEntities(text)
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if text.count > budget { text = String(text.prefix(budget)) + "…" }
        return text.isEmpty ? "No readable text at \(url.absoluteString)." : text
    }

    // MARK: HTML helpers

    private static func regexCaptures(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { g -> String in
                let r = m.range(at: g)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func removeBlocks(_ html: String, tag: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)[^>]*>.*?</\(tag)>", options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return html }
        let ns = html as NSString
        return re.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
    }

    private static func stripTags(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>", options: [.dotMatchesLineSeparators]) else { return html }
        let ns = html as NSString
        return re.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#x27;": "'", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#x2F;": "/"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}
