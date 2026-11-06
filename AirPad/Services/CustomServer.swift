import Foundation
import CryptoKit

/// 1.1-D (T 2026-10-31) — the user's own model server (Settings → Your own models), managed from the phone.
///
/// Three kinds, told apart by what the server answers (never by its port):
///   • Ollama — `GET /api/version`. List `/api/tags` + `/api/ps`, load/eject through `/api/generate`, download through
///     `/api/pull`, and chat over Ollama's NATIVE `/api/chat` with `options.num_ctx` = the loaded window (so a turn never
///     reloads the model at the server's default window).
///   • LM Studio 0.4+ — its native REST `/api/v1/models` (+ `/load`, `/unload`, `/download`, `/download/status/<job>`).
///     Chat stays on `/v1/chat/completions`, which answers with the loaded instance.
///   • Anything else OpenAI-compatible — `/v1/models`: list + pick only.
///
/// The phone's picker UI is the parked Host's (`HostCatalog` + `ModelPickerSheet`): `catalogModels` maps the server's
/// state to `CatalogModel` rows and `HostCatalog(source: .server)` maps the row actions to these endpoints.
/// No app `keep_alive` on any chat or load (the server's own retention policy holds; Brief BY); eject = keep_alive 0.
enum CustomServer {

    // MARK: - Kind

    enum Kind: Equatable, Sendable {
        case ollama(version: String)
        case lmStudio(version: String?)
        case openAICompatible

        /// What Settings shows: "Ollama 0.13.2", "LM Studio 0.4.14", "OpenAI-compatible server".
        var label: String {
            switch self {
            case .ollama(let v): return v.isEmpty ? "Ollama" : "Ollama \(v)"
            case .lmStudio(let v): return v.map { "LM Studio \($0)" } ?? "LM Studio"
            case .openAICompatible: return "OpenAI-compatible server"
            }
        }
        /// Load, eject and download from the phone (Ollama, LM Studio). A generic server is list + pick only.
        var canManage: Bool {
            if case .openAICompatible = self { return false }
            return true
        }
        var isOllama: Bool { if case .ollama = self { return true }; return false }
        var isLMStudio: Bool { if case .lmStudio = self { return true }; return false }
    }

    // MARK: - Curated downloads (from the Host's catalog manifest, airpad-host 8e1b88e manifest.json)

    /// One curated model, offered for download on either server. Prose, tiers and `recommended` are the Host
    /// manifest's; each entry carries BOTH names (the Ollama tag and the LM Studio catalog key).
    struct Curated: Sendable, Equatable {
        let ollamaTag: String
        let lmStudioKey: String
        let display: String
        let sizeBytes: Int64       // the Ollama registry build (LM Studio picks its own format per computer)
        let tier: Int
        let recommended: Bool
        let tools: Bool
        let thinking: Bool
        let capability: String
        let posture: String

        func id(for kind: Kind) -> String { kind.isLMStudio ? lmStudioKey : ollamaTag }
    }

    static let curated: [Curated] = [
        Curated(ollamaTag: "qwen3:4b-instruct-2507-q4_K_M", lmStudioKey: "qwen/qwen3-4b-2507", display: "Qwen3 4B",
                sizeBytes: 2_497_293_803, tier: 16, recommended: true, tools: true, thinking: false,
                capability: "The fast default - quick, direct answers for chat and everyday questions. A real step up from the model your \(RunningOnMac.isMac ? "Mac" : "phone") runs on its own.",
                posture: "Made by Alibaba (Qwen). Open license (Apache-2.0). May decline some topics."),
        Curated(ollamaTag: "qwen3:8b-q4_K_M", lmStudioKey: "qwen/qwen3-8b", display: "Qwen3 8B",
                sizeBytes: 5_225_388_164, tier: 16, recommended: false, tools: true, thinking: true,
                capability: "A larger, more thorough model - slower to answer but stronger on detailed reasoning, long notes, and nuanced questions. Choose it when you want depth over speed.",
                posture: "Made by Alibaba (Qwen). Open license (Apache-2.0). May decline some topics."),
        Curated(ollamaTag: "qwen3:30b-a3b-instruct-2507-q4_K_M", lmStudioKey: "qwen/qwen3-30b-a3b-2507", display: "Qwen3 30B-A3B",
                sizeBytes: 18_556_699_186, tier: 32, recommended: false, tools: true, thinking: false,
                capability: "A big, capable model that stays fast - it only wakes the part it needs for each answer, so you get large-model quality at a smaller model's speed. Good for detailed work, long notes, and using tools in the app.",
                posture: "Made by Alibaba (Qwen). Open license (Apache-2.0). May decline some topics."),
    ]

    static func curated(id: String, kind: Kind) -> Curated? {
        guard kind.canManage else { return nil }
        return curated.first { $0.id(for: kind) == id }
    }

    // MARK: - Server state

    /// One model on the server, the same shape whatever the kind.
    struct ServerModel: Equatable, Sendable {
        /// The name a load/download/chat request carries: the Ollama tag, the LM Studio key, the `/v1/models` id.
        let id: String
        var loaded: Bool = false
        /// LM Studio: the loaded instance ids (chat names the first; eject unloads each). Empty on Ollama / generic.
        var instances: [String] = []
        /// The window the loaded model was loaded with (Ollama `/api/ps` context_length, LM Studio instance config).
        var contextTokens: Int? = nil
        /// The model's own maximum window, where the server says (LM Studio `max_context_length`, Ollama /api/show).
        var maxContext: Int? = nil
        var sizeBytes: Int64 = 0
        /// The server's CLAIM (Ollama /api/show capabilities, LM Studio capabilities) — never probed. nil = not said.
        var thinking: Bool? = nil
        var tools: Bool? = nil
        var digest: String = ""

        /// The id a chat request names: LM Studio's loaded instance, else the model id.
        var chatID: String { instances.first ?? id }
    }

    struct Snapshot: Equatable, Sendable {
        let kind: Kind
        let models: [ServerModel]
    }

    // MARK: - Errors (plain words; a server's own refusal verbatim)

    enum ServerError: LocalizedError, Equatable {
        case unreachable(host: String)
        case unauthorized(host: String)
        case refused(String)
        case noModels
        case badEndpoint

        var errorDescription: String? {
            switch self {
            case .unreachable(let h): return "Can't reach the server at \(h)."
            case .unauthorized(let h): return "The server at \(h) needs an API token. Add it in Settings → Your own models."
            case .refused(let m): return m
            case .noModels: return "The server has no models yet. Download one in Settings → Your own models."
            case .badEndpoint: return "The server address isn't a valid URL."
            }
        }
    }

    /// 1.1-D fix-up (D2) — under "Can't reach the server": out of the box Ollama and LM Studio answer only their own
    /// computer. The setting names are the apps' own labels (Ollama 0.13.2 Settings; LM Studio 0.4 Server Settings).
    static let networkHint = "Let other devices connect: turn on “Expose Ollama to the network” in Ollama, or “Serve on Local Network” in LM Studio."

    #if DEBUG
    static var debugForceUnreachable = false   // the gauntlet's forced failure (case 5)
    #endif

    static func hostLabel(_ endpoint: String) -> String {
        guard let u = URL(string: endpoint), let h = u.host else { return endpoint }
        return u.port.map { "\(h):\($0)" } ?? h
    }

    /// A server's own error words from a JSON body: Ollama `{"error":"…"}`, LM Studio / OpenAI `{"error":{"message":"…"}}`.
    static func refusalText(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = json["error"] as? String, !s.isEmpty { return s }
        if let e = json["error"] as? [String: Any], let m = e["message"] as? String, !m.isEmpty { return m }
        if let m = json["message"] as? String, !m.isEmpty, json["status"] as? String == "error" { return m }
        return nil
    }

    /// Couldn't connect at all → "Can't reach the server at …"; a connected failure keeps its own description.
    static func transport(_ error: Error, endpoint: String) -> Error {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .timedOut, .networkConnectionLost, .badServerResponse:
                return ServerError.unreachable(host: hostLabel(endpoint))
            default: break
            }
        }
        return error
    }

    /// A non-2xx from the server, in plain words: 401/403 → it needs a token; otherwise its own message.
    static func httpRefusal(status: Int, body: Data, endpoint: String) -> ServerError {
        if status == 401 || status == 403 { return .unauthorized(host: hostLabel(endpoint)) }
        return .refused(refusalText(body) ?? "The server answered HTTP \(status).")
    }

    // MARK: - HTTP

    static func request(_ base: URL, _ path: String, method: String = "GET", body: [String: Any]? = nil,
                        timeout: TimeInterval = 8) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        r.httpMethod = method
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        ModelRouter.applyEndpointAuth(&r)
        return r
    }

    /// One request, its status checked: 401/403 → unauthorized, any other non-2xx → the server's own words (or the status).
    static func send(_ r: URLRequest, endpoint: String) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: r) }
        catch { throw transport(error, endpoint: endpoint) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ServerError.unauthorized(host: hostLabel(endpoint)) }
        guard (200...299).contains(status) else {
            throw ServerError.refused(refusalText(data) ?? "The server answered HTTP \(status).")
        }
        return data
    }

    // MARK: - Detection

    /// Which server answers at `endpoint`. Ollama first (`/api/version`), then LM Studio's native list, then `/v1/models`.
    static func detect(endpoint: String) async throws -> Kind {
        guard let base = URL(string: endpoint), base.scheme != nil, base.host != nil else { throw ServerError.badEndpoint }
        var firstError: Error?
        do {
            let d = try await send(request(base, "api/version", timeout: 5), endpoint: endpoint)
            if let k = classifyVersion(d) { return k }
        } catch ServerError.unreachable(let h) {
            throw ServerError.unreachable(host: h)   // nothing listens there: don't try twice more
        } catch { firstError = error }
        do {
            let r = request(base, "api/v1/models", timeout: 6)
            let (d, resp): (Data, URLResponse)
            do { (d, resp) = try await URLSession.shared.data(for: r) } catch { throw transport(error, endpoint: endpoint) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw ServerError.unauthorized(host: hostLabel(endpoint)) }
            if (200...299).contains(status), isLMStudioList(d) {
                return .lmStudio(version: lmStudioVersion(resp as? HTTPURLResponse))
            }
        } catch ServerError.unauthorized(let h) { throw ServerError.unauthorized(host: h) }
        catch { firstError = firstError ?? error }
        do {
            let d = try await send(request(base, "v1/models", timeout: 6), endpoint: endpoint)
            if parseOpenAIList(d) != nil { return .openAICompatible }
            throw ServerError.refused("The server at \(hostLabel(endpoint)) didn't answer like Ollama, LM Studio or an OpenAI-compatible server.")
        } catch {
            throw (error as? ServerError) ?? firstError ?? error
        }
    }

    /// `/api/version` → Ollama only when the body is `{"version": "<string>"}`.
    static func classifyVersion(_ data: Data) -> Kind? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = json["version"] as? String else { return nil }
        return .ollama(version: v)
    }

    static func isLMStudioList(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.isEmpty || models.contains { $0["key"] is String }
    }

    /// LM Studio puts no version in `/api/v1/models`; read one from a response header if the server sends one.
    static func lmStudioVersion(_ r: HTTPURLResponse?) -> String? {
        guard let r else { return nil }
        for (k, v) in r.allHeaderFields {
            let key = String(describing: k).lowercased()
            if key.contains("version"), key.contains("lm"), let s = v as? String, !s.isEmpty { return s }
        }
        return nil
    }

    // MARK: - Listing (pure parsers + the fetch)

    /// Ollama: `/api/tags` (installed) joined with `/api/ps` (loaded, with the window it was loaded at).
    static func parseOllama(tags: Data, ps: Data) -> [ServerModel] {
        let t = (try? JSONSerialization.jsonObject(with: tags) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        let p = (try? JSONSerialization.jsonObject(with: ps) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        var loaded: [String: Int?] = [:]
        for m in p { if let n = (m["name"] as? String) ?? (m["model"] as? String) { loaded[n] = (m["context_length"] as? Int) } }
        return t.compactMap { m in
            guard let name = (m["name"] as? String) ?? (m["model"] as? String), !name.isEmpty else { return nil }
            var s = ServerModel(id: name)
            s.sizeBytes = Int64((m["size"] as? Int) ?? 0)
            s.digest = m["digest"] as? String ?? ""
            if let ctx = loaded[name] { s.loaded = true; s.contextTokens = ctx }
            return s
        }
    }

    /// Ollama `/api/show`: the capability CLAIM and the model's own maximum window.
    static func parseOllamaShow(_ data: Data) -> (thinking: Bool?, tools: Bool?, maxContext: Int?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil, nil) }
        let caps = json["capabilities"] as? [String]
        let info = json["model_info"] as? [String: Any] ?? [:]
        let maxCtx = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int
        return (caps.map { $0.contains("thinking") }, caps.map { $0.contains("tools") }, maxCtx)
    }

    /// LM Studio `/api/v1/models` — LLMs only (embedding models can't chat).
    static func parseLMStudio(_ data: Data) -> [ServerModel] {
        let arr = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return arr.compactMap { m in
            guard let key = m["key"] as? String, !key.isEmpty, (m["type"] as? String ?? "llm") == "llm" else { return nil }
            var s = ServerModel(id: key)
            let inst = m["loaded_instances"] as? [[String: Any]] ?? []
            s.instances = inst.compactMap { $0["id"] as? String }
            s.loaded = !s.instances.isEmpty
            s.contextTokens = inst.first.flatMap { ($0["config"] as? [String: Any])?["context_length"] as? Int }
            s.maxContext = m["max_context_length"] as? Int
            s.sizeBytes = Int64((m["size_bytes"] as? Int) ?? 0)
            if let caps = m["capabilities"] as? [String: Any] {
                s.tools = caps["trained_for_tool_use"] as? Bool
                if let r = caps["reasoning"] as? [String: Any] {
                    s.thinking = !((r["allowed_options"] as? [String]) ?? []).filter { $0.lowercased() != "off" }.isEmpty
                } else { s.thinking = false }
            }
            return s
        }
    }

    /// `/v1/models` → ids (nil when the body isn't an OpenAI list).
    static func parseOpenAIList(_ data: Data) -> [ServerModel]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return nil }
        return arr.compactMap { ($0["id"] as? String).map { ServerModel(id: $0) } }
    }

    private static let showLock = NSLock()
    nonisolated(unsafe) private static var showCache: [String: (Bool?, Bool?, Int?)] = [:]

    static func list(endpoint: String, kind: Kind) async throws -> [ServerModel] {
        guard let base = URL(string: endpoint) else { throw ServerError.badEndpoint }
        switch kind {
        case .ollama:
            async let tags = send(request(base, "api/tags"), endpoint: endpoint)
            async let ps = send(request(base, "api/ps"), endpoint: endpoint)
            var models = parseOllama(tags: try await tags, ps: try await ps)
            // The capability claim + max window, once per model build (cached by digest).
            await withTaskGroup(of: (Int, (Bool?, Bool?, Int?)).self) { g in
                for (i, m) in models.enumerated() {
                    let key = m.id + "@" + m.digest
                    if let hit = showLock.withLock({ showCache[key] }) { models[i].thinking = hit.0; models[i].tools = hit.1; models[i].maxContext = hit.2; continue }
                    g.addTask {
                        guard let d = try? await send(request(base, "api/show", method: "POST", body: ["model": m.id], timeout: 5), endpoint: endpoint)
                        else { return (i, (nil, nil, nil)) }
                        let r = parseOllamaShow(d)
                        showLock.withLock { showCache[key] = (r.thinking, r.tools, r.maxContext) }
                        return (i, (r.thinking, r.tools, r.maxContext))
                    }
                }
                for await (i, r) in g { models[i].thinking = r.0; models[i].tools = r.1; models[i].maxContext = r.2 }
            }
            return models
        case .lmStudio:
            return parseLMStudio(try await send(request(base, "api/v1/models"), endpoint: endpoint))
        case .openAICompatible:
            let d = try await send(request(base, "v1/models"), endpoint: endpoint)
            guard let m = parseOpenAIList(d) else { throw ServerError.refused("The server's model list didn't parse.") }
            return m
        }
    }

    // MARK: - Adapter: server state → the picker's rows

    /// The server's models as the picker's `CatalogModel` rows: installed models in the server's order (curated ones
    /// wear the Host manifest's name, prose and tier), then the curated models not on it yet (Download; Ollama and
    /// LM Studio only). Loaded = "installed-loaded" with its window; capabilities are the server's claim, unverified.
    static func catalogModels(kind: Kind, models: [ServerModel]) -> [CatalogModel] {
        var rows: [CatalogModel] = models.map { m in
            let c = curated(id: m.id, kind: kind)
            return CatalogModel(
                tag: m.id, display: c?.display ?? m.id,
                state: m.loaded ? "installed-loaded" : "installed-ejected",
                sizeBytes: m.sizeBytes, tier: c?.tier ?? 0, recommended: c?.recommended ?? false,
                capabilities: [], verified: false, note: "",
                supportsThinking: m.thinking ?? c?.thinking ?? false, thinkingMeasured: false,
                thinkingToggleable: false, toggleMeasured: false,
                supportsTools: m.tools ?? c?.tools ?? false, toolsMeasured: false,
                capability: c?.capability ?? "", posture: c?.posture ?? "",
                contextTokens: m.loaded ? m.contextTokens : nil, machineNoun: "computers", claimsOnly: true)
        }
        guard kind.canManage else { return rows }
        for c in curated where !models.contains(where: { $0.id == c.id(for: kind) }) {
            rows.append(CatalogModel(
                tag: c.id(for: kind), display: c.display, state: "not-installed",
                sizeBytes: kind.isOllama ? c.sizeBytes : 0, tier: c.tier, recommended: c.recommended,
                capabilities: [], verified: false, note: "",
                supportsThinking: c.thinking, thinkingMeasured: false, thinkingToggleable: false, toggleMeasured: false,
                supportsTools: c.tools, toolsMeasured: false, capability: c.capability, posture: c.posture,
                contextTokens: nil, machineNoun: "computers", claimsOnly: true))
        }
        return rows
    }

    // MARK: - Detection + listing cache (routing reads it synchronously)

    struct Cached: Sendable { var kind: Kind; var models: [ServerModel]; var at: Date }
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]

    static func cached(_ endpoint: String) -> Cached? { cacheLock.withLock { cache[endpoint] } }
    static func forget(_ endpoint: String?) {
        cacheLock.withLock { if let endpoint { cache[endpoint] = nil } else { cache = [:] } }
    }
    private static func store(_ endpoint: String, _ c: Cached) { cacheLock.withLock { cache[endpoint] = c } }

    /// Detect (cached per endpoint for the launch; `redetect` re-asks — endpoint change, sheet open) and list.
    static func snapshot(endpoint: String, redetect: Bool = false) async throws -> Snapshot {
        let kind: Kind
        if !redetect, let c = cached(endpoint) { kind = c.kind } else { kind = try await detect(endpoint: endpoint) }
        do {
            let models = try await list(endpoint: endpoint, kind: kind)
            store(endpoint, Cached(kind: kind, models: models, at: Date()))
            return Snapshot(kind: kind, models: models)
        } catch {
            if !redetect { forget(endpoint) }   // the server changed under us: detect again next time
            throw error
        }
    }

    // MARK: - Pick (persisted per endpoint) + the chat model

    /// The pick is keyed by a hash of the endpoint, so the address itself is never written outside the Keychain.
    static func pickKey(_ endpoint: String) -> String {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while e.hasSuffix("/") { e.removeLast() }
        return SHA256.hash(data: Data(e.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    private static let picksKey = "airpadServerModelPicks"
    static func pick(for endpoint: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: picksKey) as? [String: String])?[pickKey(endpoint)]
    }
    static func setPick(_ id: String?, for endpoint: String) {
        var d = (UserDefaults.standard.dictionary(forKey: picksKey) as? [String: String]) ?? [:]
        d[pickKey(endpoint)] = id
        UserDefaults.standard.set(d, forKey: picksKey)
    }

    /// THE model a chat names (one derivation for routing and the pill): the user's pick while the server still lists
    /// it, else a loaded model, else the first.
    static func chatModel(_ models: [ServerModel], pick: String?) -> ServerModel? {
        if let pick, let m = models.first(where: { $0.id == pick }) { return m }
        return models.first(where: \.loaded) ?? models.first
    }

    // MARK: - Context window

    /// The window AirPad loads a model at — the Host's measured window (`DefaultNumCtx`, Brief BW3), never above the
    /// model's own maximum.
    static let defaultLoadContext = 20_480
    static func loadContext(_ m: ServerModel) -> Int { min(defaultLoadContext, m.maxContext ?? defaultLoadContext) }

    /// The window a chat with `m` runs in: the loaded window when loaded; on Ollama an unloaded model is loaded BY the
    /// chat at `loadContext`; LM Studio is loaded first (`ensureLoaded`); a generic server stays at a safe 4,096.
    static func chatContext(kind: Kind, model m: ServerModel) -> Int {
        if m.loaded, let c = m.contextTokens, c > 0 { return c }
        switch kind {
        case .ollama, .lmStudio: return loadContext(m)
        case .openAICompatible: return 4_096
        }
    }

    /// For `ModelRouter.contextWindowTokens` (sync, off the render path): the chat model's window from the last listing.
    static func cachedContext(endpoint: String) -> Int? {
        guard let c = cached(endpoint), let m = chatModel(c.models, pick: pick(for: endpoint)) else { return nil }
        return chatContext(kind: c.kind, model: m)
    }

    // MARK: - Actions (request bodies are pure, so the self-test checks the exact shapes)

    static func loadBody(kind: Kind, model m: ServerModel) -> (path: String, body: [String: Any]) {
        if kind.isLMStudio {
            return ("api/v1/models/load", ["model": m.id, "context_length": loadContext(m)])
        }
        // No keep_alive: the server's own retention applies (a chat never sends one either, so it can't undo it).
        return ("api/generate", ["model": m.id, "options": ["num_ctx": loadContext(m)]])
    }
    static func ejectBodies(kind: Kind, model m: ServerModel) -> [(path: String, body: [String: Any])] {
        if kind.isLMStudio { return m.instances.map { ("api/v1/models/unload", ["instance_id": $0]) } }
        return [("api/generate", ["model": m.id, "keep_alive": 0])]
    }

    static func load(endpoint: String, kind: Kind, model: ServerModel) async throws {
        guard kind.canManage, let base = URL(string: endpoint) else { return }
        let (path, body) = loadBody(kind: kind, model: model)
        // A big model takes a while to read into memory.
        _ = try await send(request(base, path, method: "POST", body: body, timeout: 300), endpoint: endpoint)
    }

    static func eject(endpoint: String, kind: Kind, model: ServerModel) async throws {
        guard kind.canManage, let base = URL(string: endpoint) else { return }
        for (path, body) in ejectBodies(kind: kind, model: model) {
            _ = try await send(request(base, path, method: "POST", body: body, timeout: 30), endpoint: endpoint)
        }
    }

    /// Ollama `/api/pull` streams `{status, digest, total, completed}` per layer → one percent over every layer.
    struct PullProgress {
        private var layers: [String: (total: Int64, done: Int64)] = [:]
        mutating func feed(_ line: [String: Any]) -> Int? {
            guard let digest = line["digest"] as? String, let total = (line["total"] as? NSNumber)?.int64Value, total > 0 else { return nil }
            layers[digest] = (total, (line["completed"] as? NSNumber)?.int64Value ?? 0)
            let t = layers.values.reduce(Int64(0)) { $0 + $1.total }, d = layers.values.reduce(Int64(0)) { $0 + $1.done }
            return t > 0 ? Int(min(100, d * 100 / t)) : nil
        }
    }

    /// Download `id` (a curated entry's name for this kind). Progress 0–100; a refusal (disk, unknown model) is thrown
    /// with the server's own words.
    static func download(endpoint: String, kind: Kind, id: String, progress: @escaping @MainActor (Int) -> Void) async throws {
        guard let base = URL(string: endpoint) else { throw ServerError.badEndpoint }
        switch kind {
        case .ollama:
            var r = request(base, "api/pull", method: "POST", body: ["model": id, "stream": true], timeout: 120)
            r.timeoutInterval = 120
            let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
            do { (bytes, resp) = try await URLSession.shared.bytes(for: r) } catch { throw transport(error, endpoint: endpoint) }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(status) {
                var d = Data(); for try await b in bytes { d.append(b) }
                if status == 401 || status == 403 { throw ServerError.unauthorized(host: hostLabel(endpoint)) }
                throw ServerError.refused(refusalText(d) ?? "The server answered HTTP \(status).")
            }
            var p = PullProgress(), succeeded = false
            for try await line in bytes.lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let e = obj["error"] as? String { throw ServerError.refused(e) }
                if let pct = p.feed(obj) { await progress(pct) }
                if obj["status"] as? String == "success" { succeeded = true }
            }
            if !succeeded { throw ServerError.refused("The download stopped before it finished. Try again.") }
        case .lmStudio:
            let d = try await send(request(base, "api/v1/models/download", method: "POST", body: ["model": id], timeout: 60), endpoint: endpoint)
            let start = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            if let s = start["status"] as? String, s == "already_downloaded" || s == "completed" { await progress(100); return }
            if start["status"] as? String == "failed" { throw ServerError.refused(lmFailure(start) ?? "LM Studio couldn't download this model.") }
            guard let job = start["job_id"] as? String else { throw ServerError.refused("LM Studio didn't start the download.") }
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
                let sd = try await send(request(base, "api/v1/models/download/status/\(job)"), endpoint: endpoint)
                let st = (try? JSONSerialization.jsonObject(with: sd) as? [String: Any]) ?? [:]
                if let total = (st["total_size_bytes"] as? NSNumber)?.int64Value, total > 0,
                   let done = (st["downloaded_bytes"] as? NSNumber)?.int64Value {
                    await progress(Int(min(100, done * 100 / total)))
                }
                switch st["status"] as? String {
                case "completed"?, "already_downloaded"?:
                    await progress(100)
                    // LM Studio lists the model a moment after the job reads "completed" (seen on a real server) — wait
                    // for it, or the row would flip back to Download right after reaching 100%.
                    for _ in 0..<20 {
                        if let l = try? await list(endpoint: endpoint, kind: kind), l.contains(where: { $0.id == id }) { return }
                        try await Task.sleep(for: .seconds(1))
                    }
                    return
                case "failed"?: throw ServerError.refused(lmFailure(st) ?? "LM Studio couldn't download this model.")
                default: continue   // downloading / paused
                }
            }
        case .openAICompatible:
            throw ServerError.refused("This server doesn't take downloads from AirPad.")
        }
    }
    private static func lmFailure(_ j: [String: Any]) -> String? {
        if let e = j["error"] as? String { return e }
        if let e = j["error"] as? [String: Any] { return e["message"] as? String }
        return j["message"] as? String
    }

    // MARK: - Chat target (what the next turn names, on which window)

    struct ChatTarget: Equatable, Sendable {
        let kind: Kind
        let model: String        // the id on the wire
        let contextTokens: Int
        let thinking: Bool?      // the server's claim (Ollama: send `think` only when it says the model thinks)
    }

    /// Resolve the turn's model and window from a FRESH listing (`maxAge` lets an agent loop's later steps reuse it).
    /// LM Studio: a picked model that isn't loaded is loaded first at `loadContext` (so its window is known and JIT
    /// being off on the server doesn't fail the turn); the pill narrates it.
    static func chatTarget(endpoint: String, maxAge: TimeInterval = 0) async throws -> ChatTarget {
        var snap: Snapshot
        if maxAge > 0, let c = cached(endpoint), Date().timeIntervalSince(c.at) < maxAge {
            snap = Snapshot(kind: c.kind, models: c.models)
        } else {
            snap = try await snapshot(endpoint: endpoint)
        }
        #if DEBUG
        // live-32 (1) — pin the server's model.
        if let m = UserDefaults.standard.string(forKey: "DebugEndpointModel"), !m.isEmpty {
            let sm = snap.models.first { $0.id == m || $0.chatID == m } ?? ServerModel(id: m)
            return ChatTarget(kind: snap.kind, model: sm.chatID, contextTokens: chatContext(kind: snap.kind, model: sm), thinking: sm.thinking)
        }
        #endif
        guard var m = chatModel(snap.models, pick: pick(for: endpoint)) else { throw ServerError.noModels }
        if snap.kind.isLMStudio, !m.loaded {
            let loadingID = m.id
            await MainActor.run { HostCatalog.server.beginAskLoad(loadingID) }
            do { try await load(endpoint: endpoint, kind: snap.kind, model: m) }
            catch { await MainActor.run { HostCatalog.server.endAskLoadQuietly() }; throw error }
            snap = try await snapshot(endpoint: endpoint)
            await MainActor.run { HostCatalog.server.endAskLoadQuietly() }
            m = snap.models.first { $0.id == m.id } ?? m
        }
        return ChatTarget(kind: snap.kind, model: m.chatID, contextTokens: chatContext(kind: snap.kind, model: m), thinking: m.thinking)
    }

    // MARK: - Ollama native chat (/api/chat)

    /// The `/api/chat` body: real roles (Ollama applies the model's own template), `options.num_ctx` = the turn's
    /// window, `think` only for a model the server says can think, NO keep_alive.
    static func ollamaChatBody(model: String, messages: [[String: Any]], numCtx: Int, think: Bool?,
                               stream: Bool, tools: [[String: Any]]? = nil, maxTokens: Int? = nil) -> [String: Any] {
        var options: [String: Any] = ["num_ctx": numCtx]
        if let maxTokens { options["num_predict"] = maxTokens }
        var b: [String: Any] = ["model": model, "messages": messages, "stream": stream, "options": options]
        if let think { b["think"] = think }
        if let tools, !tools.isEmpty { b["tools"] = tools }
        return b
    }

    /// One NDJSON line of `/api/chat`.
    struct ChatLine: Equatable {
        var content = "", thinking = ""
        var toolCalls: [(name: String, args: String)] = []
        var done = false
        var error: String? = nil
        static func == (a: ChatLine, b: ChatLine) -> Bool {
            a.content == b.content && a.thinking == b.thinking && a.done == b.done && a.error == b.error
                && a.toolCalls.map { $0.name + $0.args } == b.toolCalls.map { $0.name + $0.args }
        }
    }
    static func parseChatLine(_ line: String) -> ChatLine? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        var l = ChatLine()
        if let e = obj["error"] as? String { l.error = e; return l }
        if let e = obj["error"] as? [String: Any] { l.error = e["message"] as? String ?? "The server stopped the answer."; return l }
        let msg = obj["message"] as? [String: Any] ?? [:]
        l.content = msg["content"] as? String ?? ""
        l.thinking = msg["thinking"] as? String ?? ""
        for c in msg["tool_calls"] as? [[String: Any]] ?? [] {
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String else { continue }
            let args: String
            if let s = f["arguments"] as? String { args = s }
            else if let o = f["arguments"], let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
                args = String(decoding: d, as: UTF8.self)
            } else { args = "{}" }
            l.toolCalls.append((name, args))
        }
        l.done = obj["done"] as? Bool ?? false
        return l
    }

    /// Stream one `/api/chat` turn. Content and thinking go to their callbacks; returns the whole content + tool calls.
    static func streamOllamaChat(endpoint: String, body: [String: Any],
                                 onContent: @escaping (String) -> Void,
                                 onThinking: @escaping (String) -> Void) async throws -> (content: String, toolCalls: [ToolCall]) {
        guard let base = URL(string: endpoint) else { throw ServerError.badEndpoint }
        var r = request(base, "api/chat", method: "POST", body: body, timeout: 300)
        r.timeoutInterval = 300   // a cold load + a long prefill before the first line
        let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, resp) = try await URLSession.shared.bytes(for: r) } catch { throw transport(error, endpoint: endpoint) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200...299).contains(status) {
            var d = Data(); for try await b in bytes { d.append(b) }
            if status == 401 || status == 403 { throw ServerError.unauthorized(host: hostLabel(endpoint)) }
            throw ServerError.refused(refusalText(d) ?? "The server answered HTTP \(status).")
        }
        var content = "", calls: [ToolCall] = []
        #if DEBUG
        // 1.1-D fix-up (D3) — the server route's presence-only delivery line (the Host's `--observe` equivalent): which
        // model, the window asked for, the roles, the packet size and Ollama's prompt_eval — never any content.
        let msgs = body["messages"] as? [[String: Any]] ?? []
        let chars = msgs.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) }
        let numCtx = (body["options"] as? [String: Any])?["num_ctx"] as? Int ?? 0
        GauntletTap.shared.noteModel(body["model"] as? String ?? "?")
        #endif
        for try await line in bytes.lines {
            guard let l = parseChatLine(line) else { continue }
            if let e = l.error { throw ServerError.refused(e) }
            if !l.thinking.isEmpty { onThinking(l.thinking) }
            if !l.content.isEmpty { content += l.content; onContent(l.content) }
            for c in l.toolCalls { calls.append(ToolCall(id: "call_\(calls.count)", name: c.name, argumentsJSON: c.args)) }
            if l.done {
                #if DEBUG
                let done = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
                NSLog("[ServerChat] done model=%@ num_ctx=%d roles=[%@] totalChars=%d tools=%d think=%@ prompt_eval=%d eval=%d done_reason=%@ toolCalls=%d",
                      body["model"] as? String ?? "?", numCtx, msgs.compactMap { $0["role"] as? String }.joined(separator: " "), chars,
                      (body["tools"] as? [Any])?.count ?? 0, body["think"].map { "\($0)" } ?? "none",
                      (done["prompt_eval_count"] as? Int) ?? -1, (done["eval_count"] as? Int) ?? -1,
                      done["done_reason"] as? String ?? "?", calls.count)
                #endif
                break
            }
        }
        return (content, calls)
    }
}
