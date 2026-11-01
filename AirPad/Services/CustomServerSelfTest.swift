#if DEBUG
import Foundation

/// 1.1-D — `-CustomServerSelfTest`: the user's-own-server adapter, pure (no network). Detection, the listing parsers
/// (Ollama tags+ps+show, LM Studio /api/v1/models, /v1/models), the mapping to the picker's rows, the per-endpoint pick,
/// the context resolution, the exact load/eject/chat request shapes, the pull progress and the plain error words.
/// Fixtures are the documented shapes (LM Studio's list is its docs example verbatim).
@MainActor enum CustomServerSelfTest {
    static func run() -> String {
        var fails: [String] = [], ran = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            ran += 1
            if !ok { fails.append("FAIL \(name)\(detail().isEmpty ? "" : " — \(detail())")") }
        }
        func d(_ s: String) -> Data { Data(s.utf8) }
        typealias S = CustomServer

        // Detection.
        check("version → Ollama", S.classifyVersion(d(#"{"version":"0.13.2"}"#)) == .ollama(version: "0.13.2"))
        check("other body → not Ollama", S.classifyVersion(d(#"{"error":"Unexpected endpoint"}"#)) == nil)
        let lmDoc = #"""
        {"models":[{"type":"llm","publisher":"google","key":"google/gemma-4-26b-a4b","display_name":"Gemma 4 26B A4B",
          "architecture":"gemma4","quantization":{"name":"Q4_K_M","bits_per_weight":4},"size_bytes":17990911801,
          "params_string":"26B-A4B","loaded_instances":[{"id":"google/gemma-4-26b-a4b","config":{"context_length":4096,
          "eval_batch_size":512,"parallel":4,"flash_attention":true,"num_experts":8,"offload_kv_cache_to_gpu":true}}],
          "max_context_length":262144,"format":"gguf","capabilities":{"vision":true,"trained_for_tool_use":true,
          "reasoning":{"allowed_options":["off","on"],"default":"on"}},"description":null},
         {"type":"embedding","key":"text-embedding-nomic-embed-text-v1.5","size_bytes":84106624,"loaded_instances":[]},
         {"type":"llm","key":"qwen/qwen3-4b-2507","size_bytes":2497280000,"loaded_instances":[],"max_context_length":262144,
          "capabilities":{"vision":false,"trained_for_tool_use":true}}]}
        """#
        let ollamaTags = #"{"models":[{"name":"qwen3:4b-instruct-2507-q4_K_M","size":2497293803,"digest":"0edc"},{"name":"llama3.2:latest","size":2019393189,"digest":"a80c"}]}"#
        check("LM Studio list recognised", S.isLMStudioList(d(lmDoc)))
        check("CONTROL: Ollama's /api/tags is not an LM Studio list", !S.isLMStudioList(d(ollamaTags)))
        check("/v1/models parses", S.parseOpenAIList(d(#"{"object":"list","data":[{"id":"a"},{"id":"b"}]}"#))?.map(\.id) == ["a", "b"])
        check("non-list → nil", S.parseOpenAIList(d(#"{"models":[]}"#)) == nil)
        check("labels", S.Kind.ollama(version: "0.13.2").label == "Ollama 0.13.2" && S.Kind.lmStudio(version: "0.4.14").label == "LM Studio 0.4.14"
              && S.Kind.lmStudio(version: nil).label == "LM Studio" && S.Kind.openAICompatible.label == "OpenAI-compatible server")
        check("generic server can't be managed", !S.Kind.openAICompatible.canManage && S.Kind.lmStudio(version: nil).canManage)

        // Ollama listing.
        let ps = #"{"models":[{"name":"qwen3:4b-instruct-2507-q4_K_M","model":"qwen3:4b-instruct-2507-q4_K_M","context_length":20480,"size_vram":4800000000}]}"#
        let om = S.parseOllama(tags: d(ollamaTags), ps: d(ps))
        check("ollama: 2 installed", om.count == 2, "\(om.count)")
        check("ollama: loaded + its window", om.first?.loaded == true && om.first?.contextTokens == 20480, "\(String(describing: om.first))")
        check("ollama: unloaded", om.last?.loaded == false && om.last?.contextTokens == nil)
        let show = S.parseOllamaShow(d(#"{"capabilities":["completion","tools","thinking"],"model_info":{"qwen3.context_length":40960,"qwen3.embedding_length":4096}}"#))
        check("show: claims + max window", show.thinking == true && show.tools == true && show.maxContext == 40960, "\(show)")
        let show2 = S.parseOllamaShow(d(#"{"capabilities":["completion"],"model_info":{}}"#))
        check("show: no thinking, no tools", show2.thinking == false && show2.tools == false && show2.maxContext == nil)

        // LM Studio listing.
        let lm = S.parseLMStudio(d(lmDoc))
        check("lm: embeddings dropped", lm.map(\.id) == ["google/gemma-4-26b-a4b", "qwen/qwen3-4b-2507"], "\(lm.map(\.id))")
        check("lm: loaded instance + window + max", lm[0].loaded && lm[0].instances == ["google/gemma-4-26b-a4b"]
              && lm[0].contextTokens == 4096 && lm[0].maxContext == 262144)
        check("lm: claims", lm[0].thinking == true && lm[0].tools == true && lm[1].thinking == false && lm[1].tools == true)
        check("lm: chat id = instance", lm[0].chatID == "google/gemma-4-26b-a4b" && lm[1].chatID == "qwen/qwen3-4b-2507")

        // Adapter → picker rows.
        var om2 = om; om2[0].thinking = false; om2[0].tools = true; om2[1].thinking = nil
        let rows = S.catalogModels(kind: .ollama(version: "0.13.2"), models: om2)
        check("rows: installed then the curated not on it", rows.map(\.tag) == ["qwen3:4b-instruct-2507-q4_K_M", "llama3.2:latest",
              "qwen3:8b-q4_K_M", "qwen3:30b-a3b-instruct-2507-q4_K_M"], "\(rows.map(\.tag))")
        check("rows: curated name + recommended", rows[0].display == "Qwen3 4B" && rows[0].recommended && rows[0].isResident)
        check("rows: off-list friendly name", rows[1].friendlyName == "Llama 3.2" && !rows[1].isResident && rows[1].isInstalled)
        check("rows: download row", rows[2].state == "not-installed" && rows[2].sizeBytes == 5_225_388_164)
        check("rows: memory note says computers", rows[3].memoryNote == "For computers with 32 GB of memory or more. Runs best with nothing else loaded.",
              rows[3].memoryNote ?? "nil")
        check("rows: window shown on the loaded model only", rows[0].contextLine == "Context 20,480 tokens" && rows[1].contextLine == nil,
              rows[0].contextLine ?? "nil")
        check("rows: thinking claim unverified / unsaid → nothing", rows[2].thinkingLine == "Thinking (unverified)" && rows[0].thinkingLine == nil
              && rows[1].thinkingLine == nil, "\(rows.map { $0.thinkingLine ?? "-" })")
        check("rows: tools claim unverified", rows[0].toolsCopy == "Tools (unverified)")
        check("CONTROL: the Host's measured ladder is unchanged", ModelPickSelfTestHook.hostThinkingLine() == "No thinking")
        let lmRows = S.catalogModels(kind: .lmStudio(version: nil), models: lm)
        check("lm rows: curated key matched, others offered", lmRows.map(\.tag) == ["google/gemma-4-26b-a4b", "qwen/qwen3-4b-2507",
              "qwen/qwen3-8b", "qwen/qwen3-30b-a3b-2507"], "\(lmRows.map(\.tag))")
        check("lm rows: curated display on the key", lmRows[1].display == "Qwen3 4B" && lmRows[1].recommended)
        check("lm rows: friendly name from a key", lmRows[0].friendlyName == "Gemma 4 26B-A4B", lmRows[0].friendlyName)
        let gen = S.catalogModels(kind: .openAICompatible, models: [.init(id: "mistral-small")])
        check("generic: list only, no downloads", gen.map(\.tag) == ["mistral-small"])

        // Pick, per endpoint.
        let e1 = "http://192.0.2.10:11434", e2 = "http://192.0.2.11:1234"
        check("pick key ignores case + trailing slash", S.pickKey(e1) == S.pickKey("HTTP://192.0.2.10:11434/") && S.pickKey(e1) != S.pickKey(e2))
        let saved = (S.pick(for: e1), S.pick(for: e2))
        S.setPick("llama3.2:latest", for: e1); S.setPick("qwen/qwen3-4b-2507", for: e2)
        check("picks persist per endpoint", S.pick(for: e1) == "llama3.2:latest" && S.pick(for: e2) == "qwen/qwen3-4b-2507")
        check("pick wins over a loaded model", S.chatModel(om, pick: S.pick(for: e1))?.id == "llama3.2:latest")
        check("no pick → the loaded model", S.chatModel(om.reversed(), pick: nil)?.id == "qwen3:4b-instruct-2507-q4_K_M")
        check("pick gone → loaded", S.chatModel(om, pick: "gone:latest")?.id == "qwen3:4b-instruct-2507-q4_K_M")
        check("nothing loaded → the first", S.chatModel([.init(id: "a"), .init(id: "b")], pick: nil)?.id == "a")
        check("no models → nil", S.chatModel([], pick: "a") == nil)
        S.setPick(saved.0, for: e1); S.setPick(saved.1, for: e2)

        // Context.
        check("loaded window wins", S.chatContext(kind: .ollama(version: ""), model: om[0]) == 20480)
        check("unloaded on Ollama → the load window", S.chatContext(kind: .ollama(version: ""), model: om[1]) == 20_480)
        var small = om[1]; small.maxContext = 8192
        check("never above the model's max", S.loadContext(small) == 8192)
        check("LM Studio loaded at 4,096 → 4,096", S.chatContext(kind: .lmStudio(version: nil), model: lm[0]) == 4096)
        check("generic → 4,096", S.chatContext(kind: .openAICompatible, model: .init(id: "x")) == 4096)

        // Request shapes.
        func js(_ o: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self) }
        let ol = S.loadBody(kind: .ollama(version: ""), model: om[1])
        check("ollama load: /api/generate, num_ctx, NO keep_alive", ol.path == "api/generate"
              && js(ol.body) == #"{"model":"llama3.2:latest","options":{"num_ctx":20480}}"#, js(ol.body))
        let oe = S.ejectBodies(kind: .ollama(version: ""), model: om[0])
        check("ollama eject: keep_alive 0", oe.count == 1 && js(oe[0].body) == #"{"keep_alive":0,"model":"qwen3:4b-instruct-2507-q4_K_M"}"#)
        let ll = S.loadBody(kind: .lmStudio(version: nil), model: lm[1])
        check("lm load: /api/v1/models/load + context_length", ll.path == "api/v1/models/load"
              && js(ll.body) == #"{"context_length":20480,"model":"qwen/qwen3-4b-2507"}"#, js(ll.body))
        let le = S.ejectBodies(kind: .lmStudio(version: nil), model: lm[0])
        check("lm unload: per instance", le.map(\.path) == ["api/v1/models/unload"] && js(le[0].body) == #"{"instance_id":"google/gemma-4-26b-a4b"}"#)
        let cb = S.ollamaChatBody(model: "m", messages: [["role": "user", "content": "hi"]], numCtx: 20480, think: nil, stream: true)
        check("chat body: num_ctx, no keep_alive, no think when unsaid", (cb["options"] as? [String: Int])?["num_ctx"] == 20480
              && cb["keep_alive"] == nil && cb["think"] == nil && cb["tools"] == nil)
        check("chat body: think false when the model thinks", S.ollamaChatBody(model: "m", messages: [], numCtx: 1, think: false, stream: true)["think"] as? Bool == false)

        // Native chat lines.
        let l1 = S.parseChatLine(#"{"message":{"role":"assistant","content":"Hel","thinking":""},"done":false}"#)
        check("chat line: content", l1?.content == "Hel" && l1?.done == false)
        let l2 = S.parseChatLine(#"{"message":{"role":"assistant","content":"","thinking":"hmm"},"done":false}"#)
        check("chat line: thinking", l2?.thinking == "hmm" && l2?.content == "")
        let l3 = S.parseChatLine(#"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"web_search","arguments":{"query":"x"}}}]},"done":false}"#)
        check("chat line: tool call arguments → JSON text", l3?.toolCalls.first?.name == "web_search" && l3?.toolCalls.first?.args == #"{"query":"x"}"#)
        check("chat line: error", S.parseChatLine(#"{"error":"model requires more system memory (12 GiB) than is available (8 GiB)"}"#)?.error
              == "model requires more system memory (12 GiB) than is available (8 GiB)")
        check("chat line: done", S.parseChatLine(#"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#)?.done == true)

        // Pull progress over every layer.
        var p = S.PullProgress()
        _ = p.feed(["status": "pulling manifest"])
        let a = p.feed(["status": "pulling a", "digest": "sha256:a", "total": 900, "completed": 450])
        let b = p.feed(["status": "pulling b", "digest": "sha256:b", "total": 100, "completed": 100])
        check("pull: one percent over layers", a == 50 && b == 55, "\(String(describing: a)) \(String(describing: b))")

        // Plain errors.
        check("refusal: Ollama shape", S.refusalText(d(#"{"error":"insufficient disk space"}"#)) == "insufficient disk space")
        check("refusal: OpenAI shape", S.refusalText(d(#"{"error":{"message":"Model not found","type":"invalid_request_error"}}"#)) == "Model not found")
        check("unreachable wording", S.ServerError.unreachable(host: S.hostLabel(e1)).errorDescription == "Can't reach the server at 192.0.2.10:11434.")
        check("can't connect → unreachable", (S.transport(URLError(.cannotConnectToHost), endpoint: e2) as? S.ServerError) == .unreachable(host: "192.0.2.11:1234"))
        check("401 → token line", S.httpRefusal(status: 401, body: Data(), endpoint: e2).errorDescription?.hasPrefix("The server at 192.0.2.11:1234 needs an API token") == true)
        check("curated: 3–5, both names each", (3...5).contains(S.curated.count) && S.curated.allSatisfy { !$0.ollamaTag.isEmpty && $0.lmStudioKey.contains("/") }
              && S.curated.filter(\.recommended).count == 1)

        return fails.isEmpty ? "PASS \(ran)/\(ran)" : "FAIL \(fails.count)/\(ran)\n" + fails.joined(separator: "\n")
    }
}

/// The Host path's thinking line for a model that can't think, unchanged by the server's claims-only wording.
enum ModelPickSelfTestHook {
    static func hostThinkingLine() -> String? {
        CatalogModel(tag: "t", display: "t", state: "installed-loaded", sizeBytes: 0, tier: 16, recommended: false, capabilities: [],
                     verified: true, note: "", supportsThinking: false, thinkingMeasured: true, thinkingToggleable: false,
                     toggleMeasured: true, supportsTools: false, toolsMeasured: true, capability: "", posture: "").thinkingLine
    }
}

/// 1.1-D — `-CustomServerFakeSelfTest -FakeOllamaURL <u> -FakeLMStudioURL <u> -FakeLMLockedURL <u> -FakeClosedURL <u>`:
/// the real network paths against `scripts/gauntlet/restore_fake.py` (`ollama`, `lmstudio`): detect, list, pick, load,
/// the chat's window (the fake counts a reload whenever a request asks for a different window), download with progress
/// and a refusal shown verbatim, eject, unreachable and token-needed wording. Run by `scripts/server/fake_selftest.sh`.
@MainActor enum CustomServerFakeSelfTest {
    static func run() async -> String {
        var fails: [String] = [], ran = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            ran += 1
            if !ok { fails.append("FAIL \(name)\(detail().isEmpty ? "" : " — \(detail())")") }
            NSLog("[CustomServerFakeSelfTest] %@ %@", ok ? "ok" : "FAIL-ROW", name)
        }
        let args = UserDefaults.standard
        guard let ollama = args.string(forKey: "FakeOllamaURL"), let lms = args.string(forKey: "FakeLMStudioURL"),
              let locked = args.string(forKey: "FakeLMLockedURL"), let closed = args.string(forKey: "FakeClosedURL") else {
            return "FAIL 1/1\nFAIL missing -Fake*URL args"
        }
        func stats(_ e: String) async -> [String: Any] {
            guard let u = URL(string: e + "/_fake/stats"), let (d, _) = try? await URLSession.shared.data(from: u) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        let savedRoute = ModelRouter.chosenRoute
        let savedPicks = (CustomServer.pick(for: ollama), CustomServer.pick(for: lms))
        defer {
            UserDefaults.standard.removeObject(forKey: "DebugEndpointURL")
            CustomServer.setPick(savedPicks.0, for: ollama); CustomServer.setPick(savedPicks.1, for: lms)
            ModelRouter.chosenRoute = savedRoute
        }

        // Detection.
        let ko = try? await CustomServer.detect(endpoint: ollama)
        check("detect Ollama", ko == .ollama(version: "0.13.2-fake"), "\(String(describing: ko))")
        let kl = try? await CustomServer.detect(endpoint: lms)
        check("detect LM Studio", kl?.isLMStudio == true, "\(String(describing: kl))")
        do { _ = try await CustomServer.detect(endpoint: closed); check("unreachable throws", false) }
        catch { check("unreachable wording", (error as? LocalizedError)?.errorDescription == "Can't reach the server at \(CustomServer.hostLabel(closed)).",
                      (error as? LocalizedError)?.errorDescription ?? "\(error)") }
        do { _ = try await CustomServer.detect(endpoint: locked); check("token needed throws", false) }
        catch { check("token needed wording", (error as? LocalizedError)?.errorDescription?.contains("needs an API token") == true,
                      (error as? LocalizedError)?.errorDescription ?? "\(error)") }
        // 1.1-D fix-up (D2) — Settings' network hint shows under "Can't reach" only, never under the token line.
        UserDefaults.standard.set(closed, forKey: "DebugEndpointURL")
        HostCatalog.server.debugResetForTest()
        await HostCatalog.server.refreshServer(redetect: true)
        check("hint: closed port → hint", HostCatalog.server.serverUnreachable && HostCatalog.server.serverError?.hasPrefix("Can't reach") == true,
              HostCatalog.server.serverError ?? "nil")
        UserDefaults.standard.set(locked, forKey: "DebugEndpointURL")
        await HostCatalog.server.refreshServer(redetect: true)
        check("hint: token needed → no hint", !HostCatalog.server.serverUnreachable && HostCatalog.server.serverError?.contains("needs an API token") == true,
              HostCatalog.server.serverError ?? "nil")
        UserDefaults.standard.set(ollama, forKey: "DebugEndpointURL")
        await HostCatalog.server.refreshServer(redetect: true)
        check("hint: reachable → no hint", !HostCatalog.server.serverUnreachable && HostCatalog.server.serverError == nil)

        // Ollama through the real router: pick an UNLOADED model, the ask loads it at the load window, no reload after.
        UserDefaults.standard.set(ollama, forKey: "DebugEndpointURL")
        ModelRouter.chosenRoute = .endpoint
        HostCatalog.server.debugResetForTest()
        await HostCatalog.server.refreshServer(redetect: true)
        check("server catalog: Ollama rows", HostCatalog.server.serverKind == .ollama(version: "0.13.2-fake")
              && HostCatalog.server.installed.count == 2, "\(HostCatalog.server.models.map(\.tag))")
        await HostCatalog.server.use("qwen3:8b-q4_K_M")   // loads it (it's installed, not loaded)
        check("pick persisted", CustomServer.pick(for: ollama) == "qwen3:8b-q4_K_M")
        check("pick loaded at 20,480", HostCatalog.server.models.first { $0.tag == "qwen3:8b-q4_K_M" }?.contextTokens == 20480,
              "\(String(describing: HostCatalog.server.models.first { $0.tag == "qwen3:8b-q4_K_M" }))")
        check("context window from the listing", ModelRouter.contextWindowTokens == 20480, "\(ModelRouter.contextWindowTokens)")
        let before = await stats(ollama)
        var answer = ""
        do {
            for try await delta in ModelRouter.generateStreaming(messages: [["role": "system", "content": "s"], ["role": "user", "content": "hello"]],
                                                                  numCtx: ModelRouter.contextWindowTokens) {
                if case .answer(let s) = delta { answer += s }
            }
        } catch { check("ollama chat streams", false, "\(error)") }
        let after = await stats(ollama)
        check("ollama chat streams", answer.contains("fake answer"), answer)
        check("ollama chat used /api/chat at the loaded window", (after["last_chat_path"] as? String) == "/api/chat"
              && (after["last_num_ctx"] as? Int) == 20480, "\(after)")
        check("ollama chat: no reload", (after["reloads"] as? Int) == (before["reloads"] as? Int), "\(before["reloads"] ?? "-") → \(after["reloads"] ?? "-")")
        check("ollama chat: no keep_alive sent", (after["last_keep_alive"] as? String) == "none", "\(after["last_keep_alive"] ?? "-")")
        check("ollama chat: real system role", (after["last_roles"] as? [String]) == ["system", "user"], "\(after["last_roles"] ?? "-")")
        let title = try? await ModelRouter.generate(systemPrompt: "Title", userPrompt: "hello")
        let afterTitle = await stats(ollama)
        check("one-shot at the same window, no reload", title?.isEmpty == false && (afterTitle["last_num_ctx"] as? Int) == 20480
              && (afterTitle["reloads"] as? Int) == (before["reloads"] as? Int), "\(afterTitle)")
        check("pill name = the pick", HostCatalog.shared.endpointName == "Qwen3 8B", HostCatalog.shared.endpointName)
        // CONTROL — the fake DOES count a reload: the OpenAI-compatible path (no num_ctx) at the default window.
        if let u = URL(string: ollama + "/v1/chat/completions") {
            var r = URLRequest(url: u); r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": "qwen3:8b-q4_K_M", "stream": true,
                                                                      "messages": [["role": "user", "content": "x"]]])
            _ = try? await URLSession.shared.data(for: r)
        }
        let ctl = await stats(ollama)
        check("CONTROL: a /v1 turn reloads at the default window", (ctl["reloads"] as? Int) == ((before["reloads"] as? Int) ?? 0) + 1
              && (ctl["last_num_ctx"] as? Int) == 4096, "\(ctl)")
        await HostCatalog.server.refreshServer()
        check("a model someone else loaded keeps ITS window (no reload from AirPad)", ModelRouter.contextWindowTokens == 4096, "\(ModelRouter.contextWindowTokens)")

        // Download: progress, then the model is listed; a refusal is shown verbatim.
        var seen: [Int] = []
        HostCatalog.server.debugProgressSink = { seen.append($0) }
        await HostCatalog.server.install("qwen3:4b-instruct-2507-q4_K_M")
        check("ollama download: progress", seen.contains { $0 > 0 && $0 < 100 } && HostCatalog.server.lastActionError == nil,
              "\(seen) \(HostCatalog.server.lastActionError ?? "")")
        check("ollama download: now installed", HostCatalog.server.installed.contains { $0.tag == "qwen3:4b-instruct-2507-q4_K_M" })
        await HostCatalog.server.install("qwen3:30b-a3b-instruct-2507-q4_K_M")
        check("ollama download refusal verbatim", HostCatalog.server.lastActionError == "not enough disk space to pull this model (fake)",
              HostCatalog.server.lastActionError ?? "nil")
        await HostCatalog.server.eject("qwen3:8b-q4_K_M")
        check("ollama eject settles", HostCatalog.server.models.first { $0.tag == "qwen3:8b-q4_K_M" }?.isResident == false
              && HostCatalog.server.lastActionError == nil, HostCatalog.server.lastActionError ?? "")

        // LM Studio: pick an unloaded model → the ask loads it first (context_length) and chats with the instance.
        UserDefaults.standard.set(lms, forKey: "DebugEndpointURL")
        HostCatalog.server.debugResetForTest()
        await HostCatalog.server.refreshServer(redetect: true)
        check("server catalog: LM Studio rows", HostCatalog.server.serverKind?.isLMStudio == true
              && HostCatalog.server.installed.map(\.tag) == ["qwen/qwen3-8b"], "\(HostCatalog.server.models.map(\.tag))")
        CustomServer.setPick("qwen/qwen3-8b", for: lms)
        answer = ""
        do {
            for try await delta in ModelRouter.generateStreaming(messages: [["role": "user", "content": "hello"]], numCtx: 4096) {
                if case .answer(let s) = delta { answer += s }
            }
        } catch { check("lm chat streams", false, "\(error)") }
        let ls = await stats(lms)
        check("lm chat streams", answer.contains("fake answer"), answer)
        check("lm: the ask loaded the pick at 20,480", (ls["last_load_context"] as? Int) == 20480 && (ls["last_chat_model"] as? String) == "qwen/qwen3-8b",
              "\(ls)")
        check("lm: window cached for the next ask", ModelRouter.contextWindowTokens == 20480, "\(ModelRouter.contextWindowTokens)")
        seen = []
        await HostCatalog.server.install("qwen/qwen3-4b-2507")
        check("lm download: polled progress", seen.contains { $0 > 0 && $0 < 100 } && HostCatalog.server.lastActionError == nil,
              "\(seen) \(HostCatalog.server.lastActionError ?? "")")
        check("lm download: now installed", HostCatalog.server.installed.contains { $0.tag == "qwen/qwen3-4b-2507" })
        await HostCatalog.server.eject("qwen/qwen3-8b")
        let unloaded = (await stats(lms))["last_unload"] as? String
        check("lm eject (unload instance)", HostCatalog.server.models.first { $0.tag == "qwen/qwen3-8b" }?.isResident == false
              && unloaded == "qwen/qwen3-8b", HostCatalog.server.lastActionError ?? "")
        HostCatalog.server.debugProgressSink = nil
        return fails.isEmpty ? "PASS \(ran)/\(ran)" : "FAIL \(fails.count)/\(ran)\n" + fails.joined(separator: "\n")
    }
}
/// 1.1-D — `-CustomServerRealCheck -RealEndpoint <url> -RealModel <id> [-RealDownload <id>] [-RealKeepLoaded YES]`: the
/// app's REAL paths against a REAL server (only with T's OK, T present; `scripts/server/real_check.sh` records the
/// server's loaded state before and restores it after). Logs ids and numbers only — the address is redacted from
/// every line. Detect · list · pick + load at AirPad's window · one streamed chat + one one-shot through the router ·
/// the window after each (a reload shows as a changed window or a new load) · optional download · eject what it loaded.
@MainActor enum CustomServerRealCheck {
    static func run() async {
        let a = UserDefaults.standard
        guard let e = a.string(forKey: "RealEndpoint"), let model = a.string(forKey: "RealModel") else {
            NSLog("[RealCheck] DONE missing -RealEndpoint/-RealModel"); return
        }
        let host = CustomServer.hostLabel(e)
        func say(_ s: String) { NSLog("[RealCheck] %@", s.replacingOccurrences(of: host, with: "<server>").replacingOccurrences(of: e, with: "<server>")) }
        func row(_ snap: CustomServer.Snapshot?, _ id: String) -> String {
            guard let m = snap?.models.first(where: { $0.id == id }) else { return "\(id): not listed" }
            return "\(id): loaded=\(m.loaded) ctx=\(m.contextTokens.map(String.init) ?? "-") instances=\(m.instances.count) max=\(m.maxContext.map(String.init) ?? "-") thinking=\(m.thinking.map { "\($0)" } ?? "-") tools=\(m.tools.map { "\($0)" } ?? "-")"
        }
        let savedRoute = ModelRouter.chosenRoute, savedPick = CustomServer.pick(for: e)
        UserDefaults.standard.set(e, forKey: "DebugEndpointURL")
        ModelRouter.chosenRoute = .endpoint
        defer { ModelRouter.chosenRoute = savedRoute; CustomServer.setPick(savedPick, for: e); UserDefaults.standard.removeObject(forKey: "DebugEndpointURL") }
        do {
            let t0 = Date()
            let kind = try await CustomServer.detect(endpoint: e)
            say("detect \(kind.label) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            var snap = try await CustomServer.snapshot(endpoint: e, redetect: true)
            say("list \(snap.models.count) models; loaded: \(snap.models.filter(\.loaded).map { "\($0.id)@\($0.contextTokens.map(String.init) ?? "-")" })")
            let wasLoaded = snap.models.first { $0.id == model }?.loaded == true
            say("before " + row(snap, model))
            HostCatalog.server.debugResetForTest()
            await HostCatalog.server.refreshServer(redetect: true)
            let t1 = Date()
            await HostCatalog.server.use(model)
            snap = try await CustomServer.snapshot(endpoint: e)
            say("pick+load \(Int(Date().timeIntervalSince(t1))) s; error=\(HostCatalog.server.lastActionError ?? "none"); " + row(snap, model))
            say("contextWindowTokens=\(ModelRouter.contextWindowTokens) pill=\(HostCatalog.shared.endpointName)")
            var answer = "", thought = 0
            let t2 = Date()
            for try await d in ModelRouter.generateStreaming(messages: [["role": "system", "content": "Answer in one short sentence."],
                                                                        ["role": "user", "content": "What colour is the sky on a clear day?"]],
                                                             numCtx: ModelRouter.contextWindowTokens) {
                switch d { case .answer(let s): answer += s; case .thinking(let s): thought += s.count; default: break }
            }
            snap = try await CustomServer.snapshot(endpoint: e)
            say("chat \(Int(Date().timeIntervalSince(t2) * 1000)) ms, answer \(answer.count) chars [\(answer.prefix(60))], thinking \(thought) chars; after " + row(snap, model))
            let t3 = Date()
            let title = try await ModelRouter.generate(systemPrompt: "Write a three-word title.", userPrompt: "The sky on a clear day.")
            snap = try await CustomServer.snapshot(endpoint: e)
            say("one-shot \(Int(Date().timeIntervalSince(t3) * 1000)) ms [\(title.prefix(40))]; after " + row(snap, model))
            // The agent loop's tool turn, shaped as ChatSession.runCalls builds it: a call, then the tool's answer.
            let tools: [[String: Any]] = [["type": "function", "function": [
                "name": "get_weather", "description": "Current weather for a city.",
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]]]
            var working: [[String: Any]] = [["role": "system", "content": "Use the get_weather tool to answer weather questions."],
                                             ["role": "user", "content": "What's the weather in Paris right now?"]]
            let t5 = Date()
            let r1 = try await ModelRouter.streamAgentTurn(endpoint: e, model: model, messages: working, tools: tools,
                                                           onContentDelta: { _ in }, reasoningOff: true)
            say("tool turn 1 \(Int(Date().timeIntervalSince(t5) * 1000)) ms: calls \(r1.toolCalls.map { "\($0.name)(\($0.argumentsJSON))" })")
            if let call = r1.toolCalls.first {
                working.append(["role": "assistant", "content": r1.content, "tool_calls": r1.toolCalls.map { c in
                    ["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.argumentsJSON]] }])
                working.append(["role": "tool", "tool_call_id": call.id, "content": "Sunny, 21 °C."])
                let r2 = try await ModelRouter.streamAgentTurn(endpoint: e, model: model, messages: working, tools: tools,
                                                               onContentDelta: { _ in }, reasoningOff: true)
                snap = try await CustomServer.snapshot(endpoint: e)
                say("tool turn 2: [\(r2.content.prefix(60))] uses the result=\(r2.content.contains("21")); after " + row(snap, model))
            }
            if let dl = a.string(forKey: "RealDownload"), !dl.isEmpty {
                var pcts: [Int] = []
                HostCatalog.server.debugProgressSink = { p in if pcts.last != p { pcts.append(p) } }
                let t4 = Date()
                await HostCatalog.server.install(dl)
                HostCatalog.server.debugProgressSink = nil
                snap = try await CustomServer.snapshot(endpoint: e)
                say("download \(dl) \(Int(Date().timeIntervalSince(t4))) s; progress samples \(pcts.count) [\(pcts.prefix(3).map(String.init).joined(separator: ","))…\(pcts.last.map(String.init) ?? "-")]; error=\(HostCatalog.server.lastActionError ?? "none"); listed=\(snap.models.contains { $0.id == dl })")
            }
            if !wasLoaded && !a.bool(forKey: "RealKeepLoaded") {
                await HostCatalog.server.eject(model)
                snap = try await CustomServer.snapshot(endpoint: e)
                say("eject error=\(HostCatalog.server.lastActionError ?? "none"); after " + row(snap, model))
            }
            say("DONE ok")
        } catch {
            say("DONE error \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }
}
#endif
