import Foundation
import FoundationModels

/// The note-summary lever's result, provider-agnostic (`processNode`'s shape). Title + summary,
/// nothing else — the corpus-aware extras (tags/mood/domain/neighborhood) belong to the DORMANT
/// `processNodeCorpusAware` path, which is NOT routed here.
struct NodeSummaryResult: Sendable {
    var title: String
    var summary: String
}

/// The substrate lever's result, provider-agnostic (`processSubstrate`'s shape). Summary + a
/// FREE-FORM folksonomy. ★ There is deliberately NO vocabulary enum here: the substrate call
/// produces open folksonomy by settled decision (ws-lever.md § THE TAG PRODUCER); normalization
/// and embedding-match against the user's existing tags happen DETERMINISTICALLY downstream. This
/// is a SEPARATE shape from `NodeSummaryResult`, and a SEPARATE refusal locus — a node can lose
/// its summary, its tags, or both, independently. (This is why there are two methods, not one
/// struct with empty fields: `tags: []` going invisible for months is exactly the failure the
/// two-shape split avoids.)
struct SubstrateResult: Sendable {
    var summary: String
    var folksonomy: [String]
}

/// Decoding shape for the on-device model's node-summary JSON. Both fields optional — a local
/// model omits or mistypes keys; the caller coerces to `NodeSummaryResult`'s non-optionals.
private struct LocalNodeSummaryJSON: Decodable {
    var title: String?
    var summary: String?
}

/// Decoding shape for the on-device model's substrate JSON. Both fields optional; `tags` is the
/// free-form folksonomy (no fixed vocabulary — matches `SubstrateInterpretation`).
private struct LocalSubstrateJSON: Decodable {
    var summary: String?
    var tags: [String]?
}

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
        /// On-device MLX model (Stage 1's `LocalModelService`). Resolved ONLY by
        /// `structuredProvider()` for the enrichment lever — `active` (the free-text
        /// Librarian path) never returns it, by design (see `structuredProvider`).
        case local

        var displayName: String {
            switch self {
            case .foundationModel: return "Foundation Model"
            case .ollama: return "Ollama (local)"
            case .local: return "Private model (on-device)"
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

    /// STATE 2 for the free-text Ask/chat path: NO usable provider exists. True only when
    /// `active` resolves to FM (i.e. NO ollama endpoint configured) AND FM itself is
    /// unavailable (iOS < 26, or Apple Intelligence off / unsupported). ★ The on-device LOCAL
    /// model is deliberately NOT counted here — it is wired to the structured lever only, not
    /// to free-text Ask, so downloading it does not (yet) enable chat. Because `active` picks
    /// ollama first, this is ALWAYS false when an LM Studio / Ollama endpoint is set up — a
    /// user with a working endpoint is never told they have no model.
    /// ⚠️ Reads the Keychain (XPC) via `active`; call OFF the SwiftUI render path and cache the
    /// result (LibrarianState.askUnavailable) — never from a `body`.
    static var askHasNoProvider: Bool {
        guard case .foundationModel = active else { return false }
        if #available(iOS 26.0, *) { return !SystemLanguageModel.default.isAvailable }
        return true
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
            // STEP 2 — honest on the floor: the FM name ONLY when FM is actually usable.
            // On iOS 18-25 / no Apple Intelligence, FM resolves as the provider but can't run,
            // so the chip must NOT claim "Apple Intelligence" (that contradicted the Ask
            // no-model notice). Fall back to the resting "No model" label.
            if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
                return foundationModelName
            }
            return remoteRestingName
        case .ollama(let endpoint):
            guard let base = URL(string: endpoint) else { return remoteRestingName }
            return (try? await firstOllamaModel(base: base)) ?? remoteRestingName
        case .local:
            // Unreachable via `active` (structured-lever only); present for exhaustiveness.
            return "Private model"
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
        case .local:
            // Unreachable: `active` never resolves to .local — the on-device model serves only the
            // enrichment lever via `generateStructured`, not the free-text Librarian path. Defensive → FM.
            return try await generateFoundationModel(systemPrompt: systemPrompt, userPrompt: userPrompt)
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
                    case .local:
                        // Unreachable via `active`: the on-device model serves only the structured
                        // enrichment levers (generateNodeSummary / generateSubstrate), not the
                        // free-text Librarian path. Defensive → FM.
                        guard #available(iOS 26.0, *) else { throw RouterError.foundationModelUnavailable }
                        try await streamFoundationModel(
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
        case localBadJSON(String)

        var errorDescription: String? {
            switch self {
            case .foundationModelUnavailable: return "Foundation Model not available on this device."
            case .localBadJSON(let s): return "The on-device model didn't return valid JSON: \(Self.truncate(s))"
            case .ollamaNoModels: return "Endpoint is reachable but no models are loaded. Load a model in LM Studio / pull one with `ollama pull <name>`."
            case .ollamaBadEndpoint(let s): return "The endpoint is not a valid URL: \(s)"
            case .ollamaTransport(let s): return "Couldn't reach the local server: \(s)"
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

    // MARK: - Structured enrichment (the note lever)

    /// UserDefaults flag: the user has opted into the on-device model for note enrichment.
    /// FM stays the default; this flag is the ONLY thing that can move the lever to local. The
    /// Settings toggle that sets it (gated on `.ready`) lands with the routing in the next commit —
    /// until then the flag is unset, so `structuredProvider()` always resolves to FM.
    static let useLocalEnrichmentKey = "useLocalModelForEnrichment"

    /// Which provider answers the enrichment lever. Resolution order (stated per the brief):
    ///   1. `.local` — ONLY when the user opted in (`useLocalEnrichmentKey`) AND the model is
    ///                 downloaded and `.ready` on disk. Configured-but-absent falls through.
    ///   2. `.foundationModel` — the default, and the fallback for every other state.
    /// `.ollama` is deliberately NOT a structured-lever provider: corpus content stays on the FM /
    /// on-device boundary (the privacy oath), and Ollama offers neither guided generation nor the
    /// catchable refusal the refusal surface depends on. So local's precedence is "above FM when
    /// ready + opted-in, otherwise FM"; Ollama never enters this path.
    static func structuredProvider() async -> Provider {
        guard UserDefaults.standard.bool(forKey: useLocalEnrichmentKey) else { return .foundationModel }
        let ready = await MainActor.run { LocalModelService.shared.state == .ready }
        return ready ? .local : .foundationModel
    }

    // TWO methods, not one with an associated result type. The two live capture calls need
    // genuinely different shapes — `processNode` wants title + summary, `processSubstrate` wants
    // summary + free-form folksonomy — with different local-JSON decode shapes and, critically,
    // INDEPENDENT refusal loci (a node can lose its summary, its tags, or both). A single generic
    // method would push toward a shared struct (empty fields → the `tags: []` invisibility that
    // hid the substrate producer for months) or protocol gymnastics over two @Generable types.
    // Two small methods keep each locus honest and separate.

    /// THE NOTE-SUMMARY LEVER — title + summary (`processNode`'s shape). FM uses guided generation
    /// (`NodeAIResult` is @Generable), so a refusal arrives as a catchable `GenerationError` and is
    /// thrown UP for the caller to surface — the ONE provider difference, exposed not worked around.
    /// The local model is prompted for strict JSON and parsed; it effectively does not refuse.
    static func generateNodeSummary(prompt: String) async throws -> NodeSummaryResult {
        switch await structuredProvider() {
        case .local:
            return try await nodeSummaryLocal(prompt: prompt)
        case .foundationModel, .ollama:
            // The FM branch requires iOS 26; the `.local` branch above runs on the iOS 18
            // floor (LocalModelService has no OS floor, only a runtime Metal-GPU check). This
            // is GAP 27's shape in the type system — the availability guard belongs on the FM
            // branch, not around the whole router method.
            guard #available(iOS 26.0, *) else { throw RouterError.foundationModelUnavailable }
            return try await nodeSummaryFoundationModel(prompt: prompt)
        }
    }

    @available(iOS 26.0, *)
    private static func nodeSummaryFoundationModel(prompt: String) async throws -> NodeSummaryResult {
        guard SystemLanguageModel.default.isAvailable else { throw RouterError.foundationModelUnavailable }
        let session = LanguageModelSession()
        // KEEP guided generation: NodeAIResult is @Generable, so a refusal arrives as a catchable
        // GenerationError, thrown up to `AIService.processNode` → `nodeFailure` → `.refused`.
        let r = try await session.respond(to: prompt, generating: NodeAIResult.self).content
        return NodeSummaryResult(
            title:   r.title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // No @available: the on-device model path touches NO FoundationModels type — only
    // LocalModelService (Metal-gated at runtime, no OS floor) + JSON decode. Gating it to
    // iOS 26 is what stranded the local model on the floor where it's the ONLY option.
    private static func nodeSummaryLocal(prompt: String) async throws -> NodeSummaryResult {
        let jsonInstruction = """
        Respond with ONLY a single minified JSON object and nothing else — no prose, no code fences, no commentary. Use exactly these keys:
        {"title": string, "summary": string}
        Use "" for anything you cannot fill. Do not add keys.
        """
        let raw = try await LocalModelService.shared.generate(systemPrompt: jsonInstruction, userPrompt: prompt)
        guard let obj: LocalNodeSummaryJSON = decodeOutermostJSON(raw) else {
            throw RouterError.localBadJSON(String(raw.prefix(240)))
        }
        return NodeSummaryResult(
            title:   (obj.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            summary: (obj.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// THE SUBSTRATE LEVER — summary + free-form folksonomy (`processSubstrate`'s shape). Same
    /// provider split, DELIBERATELY SEPARATE from the note-summary lever (independent refusal
    /// locus, different shape). ★ The folksonomy is FREE-FORM by settled decision — the model
    /// proposes whatever words fit; there is NO vocabulary enum and NO picklist, because
    /// normalization + embedding-match against existing tags happen deterministically downstream
    /// (ws-lever.md § THE TAG PRODUCER). Constraining this call with an enum would reverse that.
    /// FM's guided generation throws its refusal up (→ `processSubstrate` → `.guardrailRefused`);
    /// the local model is prompted for JSON and parsed.
    /// `responseLanguage` (item 2) pins the LOCAL model's output to the note's own language
    /// (an English display name, e.g. "Spanish"); nil = don't constrain. The FM path ignores
    /// it — Apple's guided generation doesn't exhibit the Chinese-drift and its prompt is
    /// deliberately untouched.
    static func generateSubstrate(prompt: String, responseLanguage: String? = nil) async throws -> SubstrateResult {
        switch await structuredProvider() {
        case .local:
            return try await substrateLocal(prompt: prompt, responseLanguage: responseLanguage)
        case .foundationModel, .ollama:
            // The FM branch requires iOS 26; the `.local` branch above runs on the iOS 18 floor.
            guard #available(iOS 26.0, *) else { throw RouterError.foundationModelUnavailable }
            return try await substrateFoundationModel(prompt: prompt)
        }
    }

    @available(iOS 26.0, *)
    private static func substrateFoundationModel(prompt: String) async throws -> SubstrateResult {
        guard SystemLanguageModel.default.isAvailable else { throw RouterError.foundationModelUnavailable }
        let session = LanguageModelSession()
        // KEEP guided generation: SubstrateInterpretation is @Generable, so a refusal arrives as a
        // catchable GenerationError, thrown up to `processSubstrate` → `.guardrailRefused`.
        let r = try await session.respond(to: prompt, generating: SubstrateInterpretation.self).content
        return SubstrateResult(
            summary: r.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            folksonomy: r.tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    // No @available: like nodeSummaryLocal, this path touches NO FoundationModels type.
    private static func substrateLocal(prompt: String, responseLanguage: String? = nil) async throws -> SubstrateResult {
        // No vocabulary is added to the prompt — the folksonomy is free-form by construction.
        // ★ Item 2 — Qwen3 is a Chinese-base model and, on a bare tag list with no language
        // constraint, intermittently returns Chinese folksonomy for an English note (T
        // device-observed: 未来 · 平行宇宙 · 教堂). STEP 4 mints these permanently on tap, so pin
        // the OUTPUT LANGUAGE to the note's own language. The prior-art pass (ws-lever) found NO
        // supported template/param/grammar knob in mlx-swift/Qwen3 — a system-prompt line is the
        // only lever, and naming the language explicitly (in English, keeping the prompt
        // all-English) beats "same language as input", which Qwen drifts around. LOCAL ONLY —
        // the FM path is deliberately untouched.
        let languageLine = responseLanguage.map {
            "\nWrite `summary` and every entry in `tags` in \($0)."
        } ?? ""
        let jsonInstruction = """
        Respond with ONLY a single minified JSON object and nothing else — no prose, no code fences, no commentary. Use exactly these keys:
        {"summary": string, "tags": [string]}
        `tags` are free-form — pick whatever short words best describe the idea; there is no fixed vocabulary. Use "" or [] for anything you cannot fill. Do not add keys.\(languageLine)
        """
        let raw = try await LocalModelService.shared.generate(systemPrompt: jsonInstruction, userPrompt: prompt)
        guard let obj: LocalSubstrateJSON = decodeOutermostJSON(raw) else {
            throw RouterError.localBadJSON(String(raw.prefix(240)))
        }
        let folk = (obj.tags ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return SubstrateResult(
            summary: (obj.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            folksonomy: Array(folk.prefix(8))
        )
    }

    /// Local models wrap JSON in prose or code fences despite instructions; pull the outermost
    /// `{ … }` and decode it as `T`. Returns nil if there's no object or it doesn't decode.
    private static func decodeOutermostJSON<T: Decodable>(_ raw: String) -> T? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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

    /// Result of a Settings "Test connection" probe — three honest, in-place outcomes.
    enum EndpointProbe {
        case needsEndpoint                 // field empty — no connection attempted
        case reachable(model: String)      // answered; names the model that's loaded
        case unreachable(reason: String)   // failed; the typed RouterError reason
    }

    /// Probe the local-server endpoint (Ollama / LM Studio) for the Settings "Test connection"
    /// button. Reuses the SAME `firstOllamaModel` path the live Librarian uses, so a green result
    /// means the real feature will work. Never throws — returns one of the three honest outcomes.
    static func probeEndpoint(_ endpoint: String) async -> EndpointProbe {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .needsEndpoint }
        guard let base = URL(string: trimmed), base.scheme != nil, base.host != nil else {
            return .unreachable(reason: RouterError.ollamaBadEndpoint(trimmed).errorDescription
                                        ?? "The endpoint is not a valid URL.")
        }
        do {
            return .reachable(model: try await firstOllamaModel(base: base))
        } catch {
            return .unreachable(reason: (error as? LocalizedError)?.errorDescription
                                        ?? error.localizedDescription)
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
    /// The provider throttled us (distinct from a genuine empty result). Backend-
    /// agnostic: the Brave backend sets it on a 429; a future keyed backend would set it
    /// on its own throttle signal. The loop reads it only to word the give-up message
    /// honestly — the cap/backoff live in the executor.
    var rateLimited: Bool = false
    /// No search backend is configured (web search with no Brave key). Distinct from an
    /// empty result: NOTHING ran. The loop renders an honest "not configured" chip — never
    /// "no results", which would assert a search that didn't happen — and withholds the tool
    /// schema from the rest of the turn, so the model can't retry a tool that cannot succeed.
    var unavailable: Bool = false
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

/// ★ THE LOAD-BEARING SEAM. The agent loop is identical whether a BYO-key backend or a
/// relay executes the tool — only this one method differs. This build ships
/// `BraveSearchToolExecutor` (BYO Brave key) with `WebSearchUnavailableExecutor` as the
/// keyless state; a thin-relay implementation drops in behind the SAME method later
/// without touching the loop.
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

/// The keyless web-search state: no Brave key configured, so web search is OFF. Reuses the
/// `ToolExecutor` seam so the agent loop stays UNCHANGED — when the model calls web_search
/// or fetch_url, it gets a plain factual note it relays to the user. No scraping, no silent
/// failure, no dangling affordance.
/// ★ T's ruling 2026-08-14: web search requires a user-supplied Brave key, consistent with
/// every other external provider in the app (frontier keys, the Ollama endpoint). The prior
/// keyless DuckDuckGo scraper was REMOVED — it parsed DDG's HTML with no API and no
/// agreement (breaks on markup change, blocks under volume) and was the only path that sent
/// user text somewhere T didn't deliberately choose.
struct WebSearchUnavailableExecutor: ToolExecutor {
    func execute(name: String, arguments: [String: Any]) async -> ToolResult {
        ToolResult(textForModel: "Web search requires a Brave Search API key, which can be added in Settings.", links: [], unavailable: true)
    }
}

/// Shared web-content utilities (readability fetch + HTML cleanup). These formerly lived on
/// the removed `WebSearchToolExecutor` (the keyless DDG scraper); `BraveSearchToolExecutor`
/// reuses them for `fetch_url` and for cleaning result snippets, so they outlive the scraper.
enum WebReadability {

    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: fetch_url readability

    static func fetchReadable(_ url: URL, budget: Int = 6000) async -> String {
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

    private static func removeBlocks(_ html: String, tag: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)[^>]*>.*?</\(tag)>", options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return html }
        let ns = html as NSString
        return re.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
    }

    static func stripTags(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>", options: [.dotMatchesLineSeparators]) else { return html }
        let ns = html as NSString
        return re.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#x27;": "'", "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&#x2F;": "/"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }
}

/// ★ THE web-search executor — Brave Search API (real independent index, JSON, no scraping /
/// no anti-bot throttle). Per-turn cap/throttle machinery behind the ToolExecutor seam
/// (Brave rarely trips it — its own 429 maps to the shared `rateLimited` signal).
/// `fetch_url` is provider-agnostic and reuses `WebReadability`'s readability fetch.
///
/// ⚠️ DEV/PERSONAL only: the key lives in the user's Keychain (entered in Settings). A
/// shipped build carrying/entering a per-install key is the "key in the app" problem —
/// the launch version moves it behind a relay (T's pending interrogation).
final class BraveSearchToolExecutor: ToolExecutor, @unchecked Sendable {

    private let apiKey: String
    init(apiKey: String) { self.apiKey = apiKey }

    // Per-turn budget/throttle contract behind the ToolExecutor seam, so a backend swap
    // changes nothing for the loop. Brave's own 429 maps to the shared `rateLimited` signal.
    private let maxSearchesPerTurn = 2
    private var searchCount = 0
    private var throttled = false

    func execute(name: String, arguments: [String: Any]) async -> ToolResult {
        switch name {
        case AgentTools.webSearch:
            let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return ToolResult(textForModel: "No query provided.", links: []) }
            if throttled {
                return ToolResult(textForModel: "Web search is temporarily rate-limited by the provider. Do NOT search again this turn — answer now from the results you already have; if you have none, tell the user web search is rate-limited right now and to try again shortly.", links: [], rateLimited: true)
            }
            if searchCount >= maxSearchesPerTurn {
                return ToolResult(textForModel: "You have used your web search budget for this question (\(maxSearchesPerTurn) searches). Do NOT search again — answer now from the results you already have.", links: [])
            }
            searchCount += 1
            let (links, rateLimited) = await braveSearch(query)
            if rateLimited {
                throttled = true
                return ToolResult(textForModel: "Web search is temporarily rate-limited by the provider (too many requests in a short time). Do NOT keep retrying — answer from what you already have, or if you have nothing, tell the user web search is rate-limited right now and to try again shortly.", links: [], rateLimited: true)
            }
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
            // Provider-agnostic readability fetch (shared helper on WebReadability).
            let text = await WebReadability.fetchReadable(url)
            return ToolResult(textForModel: text, links: [])

        default:
            return ToolResult(textForModel: "Unknown tool: \(name)", links: [])
        }
    }

    /// GET the Brave web-search API → `[{title,url,snippet}]`. HTTP 429 (Brave's own
    /// rate-limit) → the shared `rateLimited` signal. Descriptions can carry `<strong>`
    /// highlight tags → stripped via the shared HTML helpers.
    private func braveSearch(_ query: String) async -> (links: [ToolLink], rateLimited: Bool) {
        var comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "8")]
        guard let url = comps?.url else { return ([], false) }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return ([], false) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status == 429 { return ([], true) }  // Brave rate-limit → distinct signal
        return (Self.parseBrave(data), false)
    }

    #if DEBUG
    /// STEP-verification — raw Brave request capturing status + body head + parse count
    /// (proves wiring with a fake key even without a live subscription; real results with T's key).
    static func diagnose(query: String, apiKey: String) async -> String {
        var comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        comps?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "8")]
        guard let url = comps?.url else { return "BAD URL" }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let parsed = parseBrave(data).count
            let head = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "").replacingOccurrences(of: "\n", with: " ")
            return "BRAVE q=\(query)  STATUS: \(status)  PARSED: \(parsed)  HEAD: \(head)"
        } catch { return "BRAVE ERROR: \(error.localizedDescription)" }
    }
    #endif

    /// Map Brave JSON (`web.results[].{title,url,description}`) → `ToolLink`. Static +
    /// internal so it's unit-testable via the DEBUG hook without a live key.
    static func parseBrave(_ data: Data) -> [ToolLink] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else { return [] }
        return results.prefix(8).compactMap { r -> ToolLink? in
            guard let title = r["title"] as? String, let urlStr = r["url"] as? String, !urlStr.isEmpty else { return nil }
            let cleanTitle = WebReadability.decodeEntities(WebReadability.stripTags(title)).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = (r["description"] as? String).map {
                WebReadability.decodeEntities(WebReadability.stripTags($0)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !cleanTitle.isEmpty else { return nil }
            return ToolLink(title: cleanTitle, url: urlStr, snippet: snippet)
        }
    }
}

/// Selects the web-search backend BEHIND the seam: Brave when the user configured a key,
/// else `WebSearchUnavailableExecutor` — web search REQUIRES a user-supplied Brave key,
/// there is no keyless fallback (T's ruling 2026-08-14). The loop calls `make()` per turn
/// and never knows which backend it got.
enum WebSearchBackend {
    static let keychainKey = "braveSearchAPIKey"

    static func make() -> ToolExecutor {
        #if DEBUG
        if let k = UserDefaults.standard.string(forKey: "BraveTestKey"), !k.isEmpty {
            return BraveSearchToolExecutor(apiKey: k)
        }
        #endif
        let key = (KeychainHelper.load(key: keychainKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? WebSearchUnavailableExecutor() : BraveSearchToolExecutor(apiKey: key)
    }
}
