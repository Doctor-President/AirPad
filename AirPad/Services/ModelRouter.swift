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
        /// A paired desktop AirPad Host reached over the tunnel with app-layer E2E
        /// (Stage 4). Wins over everything when a pairing exists — it's the deliberate
        /// "reach my computer's model from anywhere" path.
        case host(HostPairing)
        /// On-device MLX model (Stage 1's `LocalModelService`). Resolved ONLY by
        /// `structuredProvider()` for the enrichment lever — `active` (the free-text
        /// Librarian path) never returns it, by design (see `structuredProvider`).
        case local

        var displayName: String {
            switch self {
            case .foundationModel: return "Foundation Model"
            case .ollama: return "Ollama (local)"
            case .host(let p): return "Host — \(p.displayHost)"
            case .local: return "Private model (on-device)"
            }
        }
    }

    /// Resolves the active provider. A paired Host wins over everything (it's the marquee
    /// remote path); then Ollama over FM when the endpoint parses; else FM so a malformed
    /// setting can't strand the user.
    static var active: Provider {
        if let pairing = HostPairing.load() {
            return .host(pairing)
        }
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

    /// Brief BN3 — the active backend's real context window, in TOKENS. The Librarian's
    /// read-in-full budget is DERIVED from this (minus system prompt, history, and an answer
    /// reserve), replacing the fixed `askPassageCharBudget`/`contextBudgetChars` that were sized
    /// for a 4096-token stock window. The same rule then degrades gracefully per backend —
    /// generous on the Host, tight on FM — instead of one constant that either overflows the small
    /// window or starves the big one.
    ///
    /// The numbers, by provider:
    ///   • `.host` — 20,480. Brief BW3: right-sized DOWN from 32,768. The read context is capped at
    ///     `readContextTargetTokens` (12k, BT2), so a whole-entry read + system + a few turns of
    ///     history + the answer reserve fits comfortably under 20k (measured: read turns prompt-eval
    ///     ~6–7k tokens). A smaller num_ctx means a smaller KV allocation (~10 GB → ~6–7 GB on
    ///     qwen3:8b), which frees memory during a mixed session (capture, Done authoring) and cuts the
    ///     chance Ollama evicts the model — the "no reload in a session" goal. Measured finding: the
    ///     window size does NOT change PREFILL speed (that's token-count-bound, ~200 tok/s on M1 Max);
    ///     the win here is memory + load, not prefill. The request num_ctx overrides the Modelfile pin.
    ///   • `.foundationModel` — 4,096. Apple's on-device model is a hard 4K window; the budget
    ///     must never overflow it, so a big entry degrades to its best passages ("partial").
    ///   • `.ollama` — 4,096. A direct LAN endpoint (Ollama/LM Studio) self-reports no reliable
    ///     served `num_ctx`, and both commonly default low, so we stay conservative and never
    ///     overflow. (A future brief can probe `/api/show` for the real value.)
    ///   • `.local` — 4,096. The on-device MLX model is small and not wired to free-text Ask
    ///     anyway; a safe floor for exhaustiveness.
    /// Reads the Keychain (XPC) via `active` — call OFF the SwiftUI render path.
    static var contextWindowTokens: Int {
        #if DEBUG
        // Brief CH-A (T ruling 3) — `-GauntletHostNumCtx <n>` measures resident memory + read pass rate at a
        // smaller window with NO Host change: the app's num_ctx wins over the Host's `--num-ctx`, and the
        // read budget derives from this same value, so one override moves both, as production would.
        if case .host = active, UserDefaults.standard.integer(forKey: "GauntletHostNumCtx") > 0 {
            return UserDefaults.standard.integer(forKey: "GauntletHostNumCtx")
        }
        #endif
        switch active {
        case .host:            return 20_480   // Brief BW3 — right-sized from 32768 (read cap is 12k; frees KV RAM)
        case .foundationModel: return 4_096
        case .ollama:          return 4_096
        case .local:           return 4_096
        }
    }

    // Brief BY — the app NO LONGER sends `keep_alive`. Retention is owned SOLELY by the Host's
    // residency mode (Always-ready/Manual = -1, Dynamic = the idle default), applied on the chat path
    // by the Host. BW's app-side `keep_alive=30m` was overriding Always-ready's -1 hold and stranding
    // held models (Brief BY). One owner, no override.

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
        case .host(let pairing):
            // LOAD = SELECT: the label reflects what is RESIDENT (true by construction); only if
            // nothing is loaded do we fall back to the filtered list, then the resting label.
            if let resident = try? await residentHostModel(pairing: pairing), !resident.isEmpty {
                return resident
            }
            return (try? await firstHostModel(pairing: pairing)) ?? remoteRestingName
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
        case .host(let pairing):
            return try await generateHost(pairing: pairing, systemPrompt: systemPrompt, userPrompt: userPrompt)
        case .local:
            // Unreachable: `active` never resolves to .local — the on-device model serves only the
            // enrichment lever via `generateStructured`, not the free-text Librarian path. Defensive → FM.
            return try await generateFoundationModel(systemPrompt: systemPrompt, userPrompt: userPrompt)
        }
    }

    /// Two channels a model turn can carry. `.answer` is the reply that persists; `.thinking`
    /// is a reasoning-model's thought process — EPHEMERAL to the latest turn, never persisted
    /// (the TYPE enforces the split, not a remembered `if`). Only the Host path emits `.thinking`
    /// (its native /api/chat separates the two, translated at the Host); FM/Ollama emit `.answer`.
    enum ModelDelta: Sendable {
        case answer(String)
        case thinking(String)
    }

    /// Streaming text generation. Yields incremental deltas as they arrive. For Ollama this is
    /// real SSE streaming via `URLSession.bytes` — the per-chunk clock dissolves the silent 60s
    /// timeout that plagues the one-shot `generate(...)` path. For Foundation Model this is
    /// `LanguageModelSession.streamResponse(to:)`, whose cumulative snapshots are converted to
    /// deltas in `streamFoundationModel` so both providers present the identical delta contract.
    /// `think` (per-chat, OFF by default) reaches only the Host path — the sole endpoint that
    /// honors it (Ollama's native /api/chat, via the Host).
    /// One chat message on the wire. `role` ∈ {"system","user","assistant"}.
    typealias WireMessage = [String: String]

    /// Streaming from a SINGLE folded prompt (legacy shape). Kept for the BUG-36 continuation path,
    /// which hands a pre-rendered transcript. Builds `[system?, user]` and dispatches.
    static func generateStreaming(
        systemPrompt: String,
        userPrompt: String,
        requestID: String? = nil,
        think: Bool = false
    ) -> AsyncThrowingStream<ModelDelta, Error> {
        var msgs: [WireMessage] = []
        if !systemPrompt.isEmpty { msgs.append(["role": "system", "content": systemPrompt]) }
        msgs.append(["role": "user", "content": userPrompt])
        return generateStreaming(messages: msgs, numCtx: nil, requestID: requestID, think: think)
    }

    /// Brief BR — streaming from a proper CHAT: `system` + real-role `history` + the current `user`
    /// turn, with an explicit `numCtx` so the backend serves a window big enough for the packet.
    /// This is the ONE shape all live Library turns use — never a flattened "User:/Assistant:"
    /// string. Two things went wrong on the Host path before this: the read packet was folded into a
    /// single user message ending "Assistant:" (so Qwen3 continued a transcript, leaking "Assistant:"
    /// + echoing the question), and Ollama served the model's DEFAULT window (qwen3:8b → 4096) and
    /// TRUNCATED the ~6k-token entry — the receipt said "Read 1 entry in full" while the model saw
    /// only the tail. Real roles fix the first; `numCtx` (forwarded by the Host into
    /// `options.num_ctx`) fixes the second.
    static func generateStreaming(
        systemPrompt: String,
        history: [WireMessage],
        userContent: String,
        numCtx: Int?,
        requestID: String? = nil,
        think: Bool = false
    ) -> AsyncThrowingStream<ModelDelta, Error> {
        var msgs: [WireMessage] = []
        if !systemPrompt.isEmpty { msgs.append(["role": "system", "content": systemPrompt]) }
        msgs.append(contentsOf: history)
        msgs.append(["role": "user", "content": userContent])
        return generateStreaming(messages: msgs, numCtx: numCtx, requestID: requestID, think: think)
    }

    #if DEBUG
    /// Brief BR verify — the wire message array the chat path builds (system + real-role history +
    /// current user), so a self-test can assert the SHAPE without a live backend: system leads,
    /// history roles are preserved, the current turn is a `user` message, and NOTHING is a flattened
    /// "User:/Assistant:" transcript. Locks the contract against a regression back to the fold.
    static func debugWireMessages(systemPrompt: String, history: [WireMessage], userContent: String) -> [WireMessage] {
        var msgs: [WireMessage] = []
        if !systemPrompt.isEmpty { msgs.append(["role": "system", "content": systemPrompt]) }
        msgs.append(contentsOf: history)
        msgs.append(["role": "user", "content": userContent])
        return msgs
    }
    #endif

    /// The streaming dispatcher — every provider consumes the SAME message array + `numCtx`.
    static func generateStreaming(
        messages: [WireMessage],
        numCtx: Int?,
        requestID: String? = nil,
        think: Bool = false
    ) -> AsyncThrowingStream<ModelDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    #if DEBUG
                    // Brief CH-0 — `-GauntletReplay`: stream a RECORDED turn instead of the model, so the
                    // known-bad corpus runs through the real retrieval → ChatSession → UI capture path.
                    if let replay = GauntletTap.shared.nextReplayTurn() {
                        GauntletTap.shared.noteModel("replay")
                        for d in replay.deltas {
                            try await Task.sleep(for: .milliseconds(replay.delayMs))
                            continuation.yield(d.thinking ? .thinking(d.s) : .answer(d.s))
                        }
                        continuation.finish()
                        return
                    }
                    #endif
                    switch active {
                    case .foundationModel:
                        guard #available(iOS 26.0, *) else {
                            throw RouterError.foundationModelUnavailable
                        }
                        try await streamFoundationModel(messages: messages, continuation: continuation)
                        continuation.finish()
                    case .ollama(let endpoint):
                        try await streamOllama(endpoint: endpoint, messages: messages, numCtx: numCtx, continuation: continuation)
                        continuation.finish()
                    case .host(let pairing):
                        try await streamHost(
                            pairing: pairing,
                            messages: messages,
                            numCtx: numCtx,
                            requestID: requestID, // BUG 36: opt this turn into hold-and-resume
                            think: think,
                            continuation: continuation
                        )
                        continuation.finish()
                    case .local:
                        // Unreachable via `active`: the on-device model serves only the structured
                        // enrichment levers (generateNodeSummary / generateSubstrate), not the
                        // free-text Librarian path. Defensive → FM.
                        guard #available(iOS 26.0, *) else { throw RouterError.foundationModelUnavailable }
                        try await streamFoundationModel(messages: messages, continuation: continuation)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Fold a message array into a single prompt for a provider with NO role API (Foundation
    /// Model). System text leads; prior turns are labelled; the final user turn is raw. FM is the
    /// on-device fallback (not the reported Host bug) and has no chat-messages API, so a fold is
    /// unavoidable here — but it keeps the system prompt intact and doesn't append an "Assistant:"
    /// continuation cue.
    private static func flattenForFM(_ messages: [WireMessage]) -> String {
        var parts: [String] = []
        for (i, m) in messages.enumerated() {
            let c = (m["content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty else { continue }
            let isLast = i == messages.count - 1
            switch m["role"] {
            case "system":    parts.append(c)
            case "assistant": parts.append("Assistant: \(c)")
            case "user":      parts.append(isLast ? c : "User: \(c)")
            default:          parts.append(c)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// For the DIRECT `/v1/chat/completions` path: fold a leading `system` message into the first
    /// user turn (some local chat templates — legacy Mistral — HTTP-400 on a standalone system
    /// role), while KEEPING real user/assistant roles for history (no transcript flattening). The
    /// Host path does not use this — it forwards a real `system` role to Ollama's native /api/chat.
    private static func foldSystemForV1(_ messages: [WireMessage]) -> [WireMessage] {
        var system = ""
        var out: [WireMessage] = []
        var foldedIntoUser = false
        for m in messages {
            if m["role"] == "system" { system += (system.isEmpty ? "" : "\n\n") + (m["content"] ?? ""); continue }
            var mm = m
            if !system.isEmpty, m["role"] == "user", !foldedIntoUser {
                mm["content"] = system + "\n\n" + (m["content"] ?? "")
                foldedIntoUser = true
            }
            out.append(mm)
        }
        if !system.isEmpty, !foldedIntoUser { out.insert(["role": "user", "content": system], at: 0) }
        return out
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
        case .foundationModel, .ollama, .host:
            // structuredProvider() only ever returns .foundationModel/.local; .ollama/.host are
            // unreachable here (they're free-text chat providers, not the enrichment lever) but
            // handled for exhaustiveness → the FM path.
            // The FM branch requires iOS 26; the `.local` branch above runs on the iOS 18
            // floor (LocalModelService has no OS floor, only a runtime Metal-GPU check). This
            // is GAP 27's shape in the type system — the availability guard belongs on the FM
            // branch, not around the whole router method.
            guard #available(iOS 26.0, *) else { throw RouterError.foundationModelUnavailable }
            return try await nodeSummaryFoundationModel(prompt: prompt)
        }
    }

    /// Brief CD5 (BP5) — FORCE the on-device model regardless of the opt-in flag, for the silent
    /// retry when Apple Intelligence REFUSES a title/summary and the model is installed (`.ready`).
    /// The caller gates on readiness; this throws (via `generate`) if the model can't run.
    static func nodeSummaryLocalForced(prompt: String) async throws -> NodeSummaryResult {
        try await nodeSummaryLocal(prompt: prompt)
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
        case .foundationModel, .ollama, .host:
            // structuredProvider() only ever returns .foundationModel/.local; .ollama/.host are
            // unreachable here (they're free-text chat providers, not the enrichment lever) but
            // handled for exhaustiveness → the FM path.
            // The FM branch requires iOS 26; the `.local` branch above runs on the iOS 18 floor.
            guard #available(iOS 26.0, *) else { throw RouterError.foundationModelUnavailable }
            return try await substrateFoundationModel(prompt: prompt)
        }
    }

    /// Brief CD5 (BP5) — FORCE the on-device model for the silent retry when the substrate FM call
    /// refuses and the model is installed (`.ready`). Caller gates on readiness.
    static func substrateLocalForced(prompt: String, responseLanguage: String? = nil) async throws -> SubstrateResult {
        try await substrateLocal(prompt: prompt, responseLanguage: responseLanguage)
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
        messages: [WireMessage],
        continuation: AsyncThrowingStream<ModelDelta, Error>.Continuation
    ) async throws {
        guard SystemLanguageModel.default.isAvailable else {
            throw RouterError.foundationModelUnavailable
        }
        let session = LanguageModelSession()
        let combined = flattenForFM(messages)   // FM has no role API — fold (system leads, no "Assistant:" cue)

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
                continuation.yield(.answer(String(full.dropFirst(emitted.count))))
                emitted = full
                continue
            }
            continuation.yield(.answer(String(full.dropFirst(emitted.count))))
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
        applyEndpointAuth(&request)

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
        messages: [WireMessage],
        numCtx: Int?,
        continuation: AsyncThrowingStream<ModelDelta, Error>.Continuation
    ) async throws {
        guard let base = URL(string: endpoint) else {
            throw RouterError.ollamaBadEndpoint(endpoint)
        }
        let modelName = try await firstOllamaModel(base: base)

        let path = "v1/chat/completions"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyEndpointAuth(&request)

        // Brief BR — real roles (system folded into the first user for /v1 template safety; history
        // keeps user/assistant roles — never a flattened transcript).
        var body: [String: Any] = [
            "model": modelName,
            "stream": true,
            "messages": foldSystemForV1(messages)
        ]
        // Best-effort context window (Ollama's /v1 accepts an `options` passthrough; ignored by
        // strict OpenAI servers, harmless). The Host path is where num_ctx is load-bearing.
        if let numCtx { body["options"] = ["num_ctx": numCtx] }
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
                continuation.yield(.answer(content))
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
        applyEndpointAuth(&request)

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

    /// Optional bearer credential for the configured local endpoint. When the user has
    /// set an "API token" in Settings (Keychain `ollamaAPIToken`), attach it as
    /// `Authorization: Bearer <token>` on every request to that endpoint; an empty token
    /// leaves the request unchanged (today's behavior). Read live from the Keychain —
    /// like the endpoint itself — so a token set in Settings takes effect on the next
    /// request without a restart. Needed for the AirPad Bridge/Host path (the Host
    /// requires the QR-derived bearer) and for any authenticated proxy in front of a
    /// local model server.
    private static func applyEndpointAuth(_ request: inout URLRequest) {
        guard let token = KeychainHelper.load(key: "ollamaAPIToken")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - Host (Stage 4: paired desktop Host over the tunnel, app-layer E2E)

    /// Pinned browser User-Agent on every Host request (P8): Cloudflare's edge bot-management
    /// 403s unusual UAs (measured). Kept identical to the UA the Host itself pins.
    private static let hostUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Brief AD2 — session for the Host STREAM. `timeoutIntervalForRequest` is the
    /// IDLE (between-bytes) timeout: with Thinking ON a reasoning model can take a
    /// while to emit its first token, and a buffered hop could withhold bytes, so
    /// allow 90 s (≥ 60 s) before declaring the connection dead — vs `URLSession.shared`'s
    /// 60 s default. Each streamed chunk resets it, so a long answer never trips it;
    /// `timeoutIntervalForResource` caps the whole turn generously.
    private static let hostStreamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = false   // a genuine no-route must fail fast → honest "offline"
        return URLSession(configuration: cfg)
    }()

    /// Discover the model to name in a chat request: the Host's FILTERED /v1/models over the tunnel.
    private static func firstHostModel(pairing: HostPairing) async throws -> String {
        guard let url = pairing.modelsURL else { throw RouterError.ollamaBadEndpoint(pairing.tunnelURL) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(pairing.authToken)", forHTTPHeaderField: "Authorization")
        req.setValue(hostUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await runRequest(req, path: "v1/models")
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RouterError.ollamaHTTPError(path: "v1/models", status: http.statusCode,
                                              body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]],
              let id = arr.compactMap({ $0["id"] as? String }).first
        else { throw RouterError.ollamaNoModels }
        return id
    }

    /// The model the Mac currently holds IN MEMORY. Under LOAD = SELECT, the resident model IS the
    /// selection (one at a time), so this is what should answer — NOT `.first of /v1/models`
    /// (install-order), which left a deliberately-loaded 30B unreachable from the phone. Reads
    /// /v1/catalog and returns the tag whose `state == "installed-loaded"`, or nil if none is
    /// loaded (the caller falls back; the Host's residency mode then decides what an ask does).
    private static func residentHostModel(pairing: HostPairing) async throws -> String? {
        try await resolveHostModel(pairing: pairing).resident
    }

    /// Brief BU3 — WHICH MODEL ANSWERS, resolved from the CURATED catalog. Three ordered answers:
    ///
    ///  1. `resident` — the model the Mac holds in memory. Under LOAD = SELECT the resident model IS
    ///     the selection (one at a time), so it answers — NOT `.first of /v1/models` (install-order),
    ///     which left a deliberately-loaded 30B unreachable from the phone.
    ///  2. `preferred` — what to ASK FOR when nothing is resident (a restarted Host, an idle-eject, a
    ///     fresh install: T's "set to load only when you choose"). It is the user's LAST-USED model if
    ///     still installed, else the largest installed CURATED model. Naming it lets the Host's Dynamic
    ///     mode auto-load the right weights; Manual/Always-on still refuse honestly, as ruled.
    ///
    /// ★ The bug this closes (measured through the sealed path, Brief BU): with nothing resident the
    /// phone fell through to `firstHostModel` = install order = `llama3.2:latest` — a deliberately
    /// UNCURATED dev/conformance fixture (no `tier`, absent from /v1/catalog). Retrieval, packet and
    /// delivery were all correct and a 3B fixture answered a read-in-full lab question. A turn must
    /// never be served by a model the catalog doesn't offer.
    private static func resolveHostModel(pairing: HostPairing) async throws -> (resident: String?, preferred: String?) {
        guard let url = pairing.catalogURL else { return (nil, nil) }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(pairing.authToken)", forHTTPHeaderField: "Authorization")
        req.setValue(hostUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await runRequest(req, path: "v1/catalog")
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            NSLog("[ModelRouter] catalog: non-2xx (%d) — cannot resolve the curated model",
                  (response as? HTTPURLResponse)?.statusCode ?? -1)
            return (nil, nil)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            NSLog("[ModelRouter] catalog: unparseable (%d bytes) — cannot resolve the curated model", data.count)
            return (nil, nil)
        }
        func tag(_ m: [String: Any]) -> String? { m["tag"] as? String }
        func state(_ m: [String: Any]) -> String { (m["state"] as? String) ?? "" }
        func tier(_ m: [String: Any]) -> Int { (m["tier"] as? Int) ?? 0 }
        func isRecommended(_ m: [String: Any]) -> Bool { (m["recommended"] as? Bool) ?? false }

        // ★ CURATED ONLY — every candidate below is filtered to `tier > 0`. An untiered entry
        // (`llama3.2:latest`, `deepseek-r1`) is a deliberate dev/conformance fixture that the phone's
        // picker never offers, so it can NEVER be "the user's model" — not even when it is RESIDENT.
        // Measured: run 1's fallback loaded llama3.2, which left it `installed-loaded`, and honouring
        // LOAD = SELECT then made the accident STICKY — a 3B fixture kept answering read-in-full lab
        // questions on run 2. LOAD = SELECT still holds, but only over models the user could select.
        let curated = models.filter { tier($0) > 0 }
        let resident = curated.first(where: { state($0) == "installed-loaded" }).flatMap(tag)
        let installed = curated.filter { state($0).hasPrefix("installed") }
        // The model the USER PICKED in the phone's picker (T's ruling: that IS the default in V1 —
        // no separate setting). Used only while it is still installed; an ejected-but-installed pick is
        // fine (naming it makes Dynamic load it), a DELETED one falls through.
        let picked = userPickedHostModel.flatMap { p in installed.first { tag($0) == p }.flatMap(tag) }
        // The V1 DEFAULT when nothing was ever picked: the Host's RECOMMENDED model (Qwen3 4B) if
        // installed, else the smallest curated shelf (`tier` = the GB shelf — fastest to load, least
        // surprising to spend a load on unasked). Brief BZ replaced the bare smallest-tier proxy with
        // the Host's explicit `recommended` flag so "the default" is a curated decision, not an accident.
        let recommended = installed.first(where: isRecommended).flatMap(tag)
        let smallestCurated = installed.min(by: { tier($0) < tier($1) }).flatMap(tag)
        let defaultPick = recommended ?? smallestCurated
        // ★ Brief BZ — the user's PICK WINS EVERYWHERE. When they picked a model (still installed),
        // that is what every path names — chat, warm ping, title gen, Librarian — EVEN IF a different
        // model is momentarily resident, so the Host loads/holds the pick and a stale 8B can't override
        // a 4B pick (the field bug: picked 4B, 8B kept answering). Resident-first ONLY when NOTHING was
        // ever picked (don't spend a load unasked; use what's warm). Nothing picked + nothing resident →
        // the recommended default. Naming the pick also makes a Manual/Always-ready mode that can't
        // serve it REFUSE HONESTLY (the Host's 409, surfaced) rather than silently answering as another
        // model — "never silently switch". `resident` (first return) still drives the live label.
        let preferred = picked ?? resident ?? defaultPick
        return (resident, preferred)
    }

    /// ★ The model the USER PICKED in the phone's model picker — T's ruling (2026-09-29): that IS the
    /// default model for V1, with no separate setting. Written by `HostCatalog.load` (the one funnel
    /// every picker "Load" goes through) and read by `resolveHostModel` when nothing is resident, so a
    /// cold/idle-ejected Host is asked for the user's own choice rather than Ollama's install order.
    /// Deliberately NOT overwritten by whichever model happened to answer a turn — a fallback pick
    /// must never silently become the default (that is how `llama3.2` got sticky). Plain UserDefaults:
    /// a preference, not a secret.
    private static let userPickedHostModelKey = "airpadUserPickedHostModel"
    static var userPickedHostModel: String? {
        get { UserDefaults.standard.string(forKey: userPickedHostModelKey) }
        set { UserDefaults.standard.set(newValue, forKey: userPickedHostModelKey) }
    }

    /// One-shot Host generation (accumulates the streamed answer). Short prompts (compaction /
    /// chat-title / summary labels).
    ///
    /// ★ Brief BW2 — sends the SAME `num_ctx` as the Librarian chat (`contextWindowTokens`), NOT nil.
    /// A nil `num_ctx` let Ollama fall back to qwen3:8b's DEFAULT 4096, which is a DIFFERENT KV
    /// allocation than the chat's 32768 — so Ollama RELOADED the model (measured: `ollama ps` flipped
    /// 32768→4096, load≈1.5s) and DISCARDED the KV cache. Since chat-title generation fires right
    /// after the first Librarian answer, every session thrashed 32768⇄4096 and each question paid a
    /// full cold prefill. One shared `num_ctx` keeps ONE resident instance; a small label prompt fits
    /// 32768 trivially. (T's "the model needed to be loaded again.")
    private static func generateHost(pairing: HostPairing, systemPrompt: String, userPrompt: String) async throws -> String {
        var msgs: [WireMessage] = []
        if !systemPrompt.isEmpty { msgs.append(["role": "system", "content": systemPrompt]) }
        msgs.append(["role": "user", "content": userPrompt])
        var out = ""
        let stream = AsyncThrowingStream<ModelDelta, Error> { cont in
            Task {
                do {
                    try await streamHost(pairing: pairing, messages: msgs, numCtx: contextWindowTokens, continuation: cont)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
        }
        for try await d in stream { if case .answer(let t) = d { out += t } } // one-shot: answer only
        return out
    }

    /// Brief BW4 — WARM the paired Host's chat model so the FIRST Librarian question finds it
    /// resident (skips the ~cold load) with its KV allocation already at the chat's `num_ctx`, so the
    /// first real turn neither loads nor reloads. Fire-and-forget: a 1-token chat at the SAME
    /// `num_ctx` (32768) + `keep_alive` as a real turn. No-op unless the active backend is `.host`;
    /// errors are swallowed (a failed warm just means the first question loads as it does today).
    static func warmHostModel() {
        guard case .host(let pairing) = active else { return }
        Task.detached(priority: .utility) {
            let msgs: [WireMessage] = [["role": "user", "content": "ok"]]
            let stream = AsyncThrowingStream<ModelDelta, Error> { cont in
                Task {
                    do { try await streamHost(pairing: pairing, messages: msgs, numCtx: contextWindowTokens, continuation: cont); cont.finish() }
                    catch { cont.finish(throwing: error) }
                }
            }
            do { for try await _ in stream {} } catch { /* warm is best-effort */ }
        }
    }

    /// Streaming Host generation over the tunnel with app-layer E2E. Seals the OpenAI chat
    /// request into an envelope, POSTs it, and opens each sealed SSE frame — yielding the inner
    /// assistant deltas live. The edge sees only ciphertext; the Host decrypts on the user's own
    /// machine and streams the local model's answer back sealed. Mirrors the Go/CryptoKit
    /// conformance path exactly.
    private static func streamHost(
        pairing: HostPairing,
        messages: [WireMessage],
        numCtx: Int?,
        requestID: String? = nil,
        think: Bool = false,
        continuation: AsyncThrowingStream<ModelDelta, Error>.Continuation
    ) async throws {
        guard let hpk = pairing.hostPublicKey, let chatURL = pairing.chatURL else {
            throw RouterError.ollamaBadEndpoint(pairing.tunnelURL)
        }
        // LOAD = SELECT: name the RESIDENT model. With NOTHING resident, name the user's default (last
        // used, else the largest installed CURATED model) so a cold/idle-ejected Host loads the right
        // weights (Brief BU3). `firstHostModel` is the last resort ONLY — on its own it picked
        // `llama3.2:latest`, an uncurated dev fixture, to answer a read-in-full lab question.
        let model: String
        #if DEBUG
        // Brief BX3 — `-DebugHostModel <tag>` forces the chat model, so the gauntlet can measure an
        // UNCURATED shelf (e.g. `qwen3:4b`, absent from the manifest) side by side with the curated
        // default WITHOUT manifest surgery. Release-inert; measurement only.
        let dbgArgs = ProcessInfo.processInfo.arguments
        if let i = dbgArgs.firstIndex(of: "-DebugHostModel"), i + 1 < dbgArgs.count {
            model = dbgArgs[i + 1]
        } else {
            let resolved = try await resolveHostModel(pairing: pairing)
            if let pick = resolved.preferred { model = pick } else { model = try await firstHostModel(pairing: pairing) }
        }
        #else
        let resolved = try await resolveHostModel(pairing: pairing)
        if let pick = resolved.preferred {
            model = pick
        } else {
            model = try await firstHostModel(pairing: pairing)
        }
        #endif
        #if DEBUG
        GauntletTap.shared.noteModel(model)   // Brief CH-0 — the tag actually put on the wire
        #endif
        // NOTE: deliberately does NOT write `userPickedHostModel` — the default is the user's PICKER
        // choice, not whatever a fallback happened to resolve to (see that property).
        // Brief BR — send REAL roles (system + history + user), never a folded "User:/Assistant:"
        // string, and set `options.num_ctx` so the Host tells Ollama to serve a window big enough
        // for the read-in-full packet (else it truncates to the model's 4096 default). The Host's
        // `ollamaChatBody` forwards `messages` + `options` raw to Ollama's native /api/chat.
        // `think` (per-chat, off by default) is honored only by that /api/chat path.
        var body: [String: Any] = ["model": model, "stream": true, "think": think, "messages": messages]
        if let numCtx { body["options"] = ["num_ctx": numCtx] }
        // ★ Brief BY — the app does NOT send `keep_alive`. The Host's RESIDENCY MODE owns retention and
        // applies it on the chat path (Always-ready/Manual = -1, Dynamic = the idle default). BW's
        // app-side keep_alive=30m overrode Always-ready's -1 hold → the held model idle-ejected → every
        // ask was then refused. One owner (the Mac's mode), no override from the phone.
        // BUG 36 Pillar 2: a client-generated requestID (sealed inside the body — D1) opts this
        // generation into the Host's finish-and-hold, so a mid-stream drop can be resumed.
        if let requestID { body["requestID"] = requestID }
        let plaintext = try JSONSerialization.data(withJSONObject: body)
        let (envelope, session) = try HostE2E.sealRequest(master: pairing.master, hostStaticPub: hpk, plaintext: plaintext)

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(hostUserAgent, forHTTPHeaderField: "User-Agent") // P8
        request.setValue("Bearer \(pairing.authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(envelope)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await hostStreamSession.bytes(for: request) }
        catch { throw RouterError.ollamaTransport(error.localizedDescription) }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw RouterError.ollamaHTTPError(path: "v1/chat/completions", status: http.statusCode,
                                              body: String(data: data, encoding: .utf8) ?? "")
        }

        // Sealed frames carry RAW upstream SSE byte-chunks (not line-aligned). Accumulate the
        // decrypted bytes and parse complete `data:` lines to yield inner assistant deltas live.
        var buffer = Data()
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break } // outer (sealed-frame) stream end
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let epk = obj["epk"] as? String { try session.setHostEphemeral(epk); continue }
            guard let ct = obj["ct"] as? String else { continue }
            buffer.append(try session.openFrame(ct))
            drainInnerSSE(&buffer, continuation)
        }
    }

    // MARK: - Host agentic tool turn (web search over the SEALED path)

    /// Which remote path runs the agentic tool loop.
    enum AgentBackend {
        case ollama(endpoint: String, model: String)
        case host(pairing: HostPairing)
    }

    /// One agentic model turn over the SEALED `.host` path — the tool-loop sibling of
    /// `streamAgentTurn` (which only ever ran against a direct `.ollama` endpoint; that is why web
    /// search never worked over a paired Host — it was NEVER WIRED for `.host`, not a regression
    /// from the `/api/chat` switch). Seals the OpenAI working-set + tool schema exactly like
    /// `streamHost`, then accumulates content + `tool_calls` out of the sealed SSE (the Host now
    /// translates Ollama's native `tool_calls` back into `delta.tool_calls`). It does NOT opt into
    /// BUG 36 hold/resume (no requestID): an agentic turn is short and the loop owns retries, so the
    /// one-shot hold path (`streamHost`) stays byte-for-byte untouched.
    /// Brief AF2 — THE synthesis-502 fix. The Host forwards the working set RAW to
    /// Ollama's NATIVE `/api/chat`, which rejects OpenAI-shape tool_calls whose
    /// `function.arguments` is a JSON STRING (measured: HTTP 400 "cannot unmarshal
    /// string into ToolCallFunctionArguments" → Host 502 → Cloudflare HTML — exactly
    /// the device banner). The first call has no tool history so it passes; the
    /// SYNTHESIS call echoes the assistant tool_call back and 400s. Normalise
    /// `arguments` (string → object) for the native endpoint. The direct `/v1` path
    /// (`streamAgentTurn`) leaves it a string, which OpenAI-compat wants.
    static func nativizeToolMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { m in
            guard let calls = m["tool_calls"] as? [[String: Any]] else { return m }
            var out = m
            out["tool_calls"] = calls.map { call -> [String: Any] in
                var c = call
                if var fn = c["function"] as? [String: Any], let argStr = fn["arguments"] as? String {
                    fn["arguments"] = (try? JSONSerialization.jsonObject(with: Data(argStr.utf8))) ?? [String: Any]()
                    c["function"] = fn
                }
                return c
            }
            return out
        }
    }

    static func streamHostAgentTurn(
        pairing: HostPairing,
        messages: [[String: Any]],
        tools: [[String: Any]]?,
        think: Bool = false,
        onContentDelta: @Sendable @escaping (String) -> Void,
        onReasoningDelta: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws -> AgentTurn {
        guard let hpk = pairing.hostPublicKey, let chatURL = pairing.chatURL else {
            throw RouterError.ollamaBadEndpoint(pairing.tunnelURL)
        }
        // ★ Brief BZ — route the SEARCH turn through the SAME resolution as chat/warm/title so the
        // user's pick wins here too. It used to be `resident ?? firstHostModel`, never consulting the
        // pick — so a General/web-search turn on a cold Host fell to `firstHostModel` (install order),
        // the uncurated-fixture trap. Now: pick > resident > recommended default, `firstHostModel` last.
        let model: String
        if let pick = try await resolveHostModel(pairing: pairing).preferred {
            model = pick
        } else {
            model = try await firstHostModel(pairing: pairing)
        }
        // Brief AL3 — honour the user's Thinking toggle on SEARCH turns too (was hardcoded
        // false, so a reasoning model never reasoned on the agent path). With `think` on, the
        // Host routes the thought process to the reasoning channel (rendered live via
        // `onReasoningDelta`), leaving the answer clean.
        var body: [String: Any] = ["model": model, "stream": true, "think": think, "messages": Self.nativizeToolMessages(messages)]
        if let tools { body["tools"] = tools }
        let plaintext = try JSONSerialization.data(withJSONObject: body)
        let (envelope, session) = try HostE2E.sealRequest(master: pairing.master, hostStaticPub: hpk, plaintext: plaintext)

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(hostUserAgent, forHTTPHeaderField: "User-Agent") // P8
        request.setValue("Bearer \(pairing.authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(envelope)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await hostStreamSession.bytes(for: request) }
        catch { throw RouterError.ollamaTransport(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw RouterError.ollamaHTTPError(path: "v1/chat/completions", status: http.statusCode,
                                              body: String(data: data, encoding: .utf8) ?? "")
        }

        var buffer = Data()
        var content = ""
        var accum: [Int: (id: String, name: String, args: String)] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break } // outer sealed-frame stream end
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let epk = obj["epk"] as? String { try session.setHostEphemeral(epk); continue }
            guard let ct = obj["ct"] as? String else { continue }
            buffer.append(try session.openFrame(ct))
            drainInnerAgentSSE(&buffer, content: &content, accum: &accum, onContentDelta: onContentDelta, onReasoningDelta: onReasoningDelta)
        }
        let toolCalls = accum.sorted { $0.key < $1.key }.map { idx, e in
            ToolCall(id: e.id.isEmpty ? "call_\(idx)" : e.id, name: e.name, argumentsJSON: e.args)
        }
        return AgentTurn(content: content, toolCalls: toolCalls)
    }

    /// Parse complete inner `data:` lines out of the decrypted buffer, ACCUMULATING content +
    /// tool-call fragments — the agentic sibling of `drainInnerSSE` (which yields live ModelDeltas).
    private static func drainInnerAgentSSE(
        _ buffer: inout Data,
        content: inout String,
        accum: inout [Int: (id: String, name: String, args: String)],
        onContentDelta: @Sendable (String) -> Void,
        onReasoningDelta: @Sendable (String) -> Void = { _ in }
    ) {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") { line = String(line.dropLast()) }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any] {
                accumulateAgentDelta(delta, content: &content, accum: &accum, onContentDelta: onContentDelta, onReasoningDelta: onReasoningDelta)
            }
        }
    }

    /// Fold one OpenAI `delta` into the running content + tool-call accumulator (keyed by index) —
    /// the ONE definition both the `.ollama` (streamAgentTurn) and `.host` (streamHostAgentTurn)
    /// loops use, so the two parse `tool_calls` identically and can't drift.
    static func accumulateAgentDelta(
        _ delta: [String: Any],
        content: inout String,
        accum: inout [Int: (id: String, name: String, args: String)],
        onContentDelta: @Sendable (String) -> Void,
        onReasoningDelta: @Sendable (String) -> Void = { _ in }
    ) {
        // Brief AL3 — the reasoning channel on the agent path (Host /api/chat, translated).
        // Previously dropped here, so Thinking-on SEARCH turns showed no thought process even
        // when the model reasoned. Streamed live (ephemeral), never folded into the answer.
        if let r = delta["reasoning"] as? String, !r.isEmpty {
            onReasoningDelta(r)
        }
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

    // MARK: - Host resume (BUG 36 Pillar 2)

    /// Re-attach to a HELD Host result after a mid-stream drop. Seals `{requestID}` into a
    /// FRESH envelope, POSTs `/v1/chat/resume`, and opens the sealed SSE frames the Host
    /// re-seals under a new handshake — yielding the inner deltas of the FULL held answer
    /// (the Host replays from start). Throws `RouterError.ollamaHTTPError(status: 404)` when
    /// the held result is gone (expired / already consumed), so the caller keeps its partial.
    static func resumeHostStream(pairing: HostPairing, requestID: String) -> AsyncThrowingStream<ModelDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await streamHostResume(pairing: pairing, requestID: requestID, continuation: continuation)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    private static func streamHostResume(
        pairing: HostPairing,
        requestID: String,
        continuation: AsyncThrowingStream<ModelDelta, Error>.Continuation
    ) async throws {
        guard let hpk = pairing.hostPublicKey, let resumeURL = pairing.resumeURL else {
            throw RouterError.ollamaBadEndpoint(pairing.tunnelURL)
        }
        // The resume request body is just the id; the Host looks up the held result under it.
        let plaintext = try JSONSerialization.data(withJSONObject: ["requestID": requestID])
        let (envelope, session) = try HostE2E.sealRequest(master: pairing.master, hostStaticPub: hpk, plaintext: plaintext)

        var request = URLRequest(url: resumeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(hostUserAgent, forHTTPHeaderField: "User-Agent") // P8
        request.setValue("Bearer \(pairing.authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(envelope)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await hostStreamSession.bytes(for: request) }
        catch { throw RouterError.ollamaTransport(error.localizedDescription) }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw RouterError.ollamaHTTPError(path: "v1/chat/resume", status: http.statusCode,
                                              body: String(data: data, encoding: .utf8) ?? "")
        }

        // Sealed frames carry raw upstream SSE byte-chunks (re-sealed under the fresh handshake).
        var buffer = Data()
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let epk = obj["epk"] as? String { try session.setHostEphemeral(epk); continue }
            guard let ct = obj["ct"] as? String else { continue }
            buffer.append(try session.openFrame(ct))
            drainInnerSSE(&buffer, continuation)
        }
    }

    /// Parse complete inner `data:` lines out of the decrypted buffer, yielding assistant deltas.
    private static func drainInnerSSE(_ buffer: inout Data, _ continuation: AsyncThrowingStream<ModelDelta, Error>.Continuation) {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") { line = String(line.dropLast()) }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any] {
                // Two channels (Host /api/chat, translated): reasoning = thought process, content
                // = the answer. `.thinking` is rendered live + discarded; `.answer` is the reply.
                if let r = delta["reasoning"] as? String, !r.isEmpty { continuation.yield(.thinking(r)) }
                if let c = delta["content"] as? String, !c.isEmpty { continuation.yield(.answer(c)) }
            }
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
        onContentDelta: @Sendable @escaping (String) -> Void,
        onReasoningDelta: @Sendable @escaping (String) -> Void = { _ in }
    ) async throws -> AgentTurn {
        guard let base = URL(string: endpoint) else { throw RouterError.ollamaBadEndpoint(endpoint) }
        let path = "v1/chat/completions"
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyEndpointAuth(&request)
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
            Self.accumulateAgentDelta(delta, content: &content, accum: &accum, onContentDelta: onContentDelta, onReasoningDelta: onReasoningDelta)
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
        let text = extractReadable(from: html, budget: budget)
        return text.isEmpty ? "No readable text at this URL." : text
    }

    /// Brief BL3.3 — the pure HTML → readable-text core, split out of `fetchReadable`
    /// so `OGMetadataService` can reuse the HTML it already fetched (no third network
    /// trip). Two improvements over the old whole-page strip:
    ///   1. Drop boilerplate BLOCKS — `script`, `style`, `nav`, `header`, `footer`,
    ///      `aside`, `form` — before stripping, so their text never reaches the output.
    ///   2. Prefer the MAIN content region — first `<article>`, else `<main>`, else an
    ///      element with `role="main"` — and read only that. Fall back to the whole
    ///      (boilerplate-stripped) body when a page marks up none of them.
    /// The result is the article, not the site chrome ("Skip Navigation … VISIT / APPLY").
    /// Returns "" (not a sentinel) when nothing readable remains — callers add their own.
    static func extractReadable(from html: String, budget: Int) -> String {
        var cleaned = html
        for tag in ["script", "style", "nav", "header", "footer", "aside", "form"] {
            cleaned = removeBlocks(cleaned, tag: tag)
        }
        // Main-content region, in priority order. `<article>`/`<main>` are unambiguous;
        // `role="main"` is matched on any element carrying that attribute.
        let region = firstBlock(cleaned, tag: "article")
            ?? firstBlock(cleaned, tag: "main")
            ?? firstRoleMainBlock(cleaned)
            ?? cleaned
        var text = stripTags(region)
        text = decodeEntities(text)
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if text.count > budget { text = String(text.prefix(budget)) + "…" }
        return text
    }

    /// First `<tag …>…</tag>` block's inner HTML (greedy to the LAST close so a nested
    /// same-tag doesn't truncate the article), or nil when the tag is absent.
    private static func firstBlock(_ html: String, tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)[^>]*>([\\s\\S]*)</\(tag)>", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// First element carrying `role="main"` (or `role='main'`) → its inner HTML to the
    /// matching-depth close is hard in regex; approximate by taking from the tag to the
    /// end of the document, then letting boilerplate-strip + budget bound it. Nil when absent.
    private static func firstRoleMainBlock(_ html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<[^>]*role=[\"']main[\"'][^>]*>([\\s\\S]*)", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
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

    /// Brief BM3 — decode HTML entities: numeric (`&#DDDD;` / `&#xHHHH;`, universal) plus a
    /// table of the named entities that actually appear in web titles/descriptions (Latin-1
    /// supplement letters + common punctuation/symbols). `&amp;` is applied LAST so a
    /// double-escaped `&amp;copy;` decodes to the literal "&copy;", not ©.
    static func decodeEntities(_ s: String) -> String {
        var out = replaceNumericEntities(s)
        for (k, v) in namedEntities { out = out.replacingOccurrences(of: k, with: v) }
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }

    /// Brief BM3 — the canonical link-text cleanup applied to every OG/meta field: decode
    /// entities, THEN repair the classic double-encoding mojibake.
    static func sanitize(_ s: String) -> String { repairMojibake(decodeEntities(s)) }

    /// Brief BM3/BO3 — repair UTF-8 bytes that were misread as Latin-1 ("Pokémon" → "PokÃ©mon").
    /// PER-RUN, not whole-string: a real og:description almost always contains at least one
    /// character outside Latin-1 (an em dash, a curly quote), and the old whole-string round-trip
    /// bailed on the ENTIRE string the moment it saw one — leaving "PokÃ©mon" on screen. This
    /// walks maximal runs of Latin-1-representable characters (a non-Latin-1 char separates runs
    /// and passes through untouched) and repairs each run that both contains a `Ã`/`Â` lead AND
    /// round-trips cleanly as Latin-1 → UTF-8. Genuine accented text ("São Paulo", "café") has no
    /// `Ã`/`Â` (its accents are lowercase / already correct), so it never enters the repair.
    static func repairMojibake(_ s: String) -> String {
        guard s.contains("Ã") || s.contains("Â") else { return s }
        var result = ""
        var run = ""
        func flush() {
            if run.isEmpty { return }
            if (run.contains("Ã") || run.contains("Â")),
               let latin1 = run.data(using: .isoLatin1),
               let utf8 = String(data: latin1, encoding: .utf8),
               utf8 != run {
                result += utf8
            } else {
                result += run
            }
            run = ""
        }
        for ch in s {
            if ch.unicodeScalars.count == 1, let u = ch.unicodeScalars.first, u.value <= 0xFF {
                run.append(ch)          // Latin-1-representable — part of the current run
            } else {
                flush()
                result.append(ch)       // outside Latin-1 (em dash, curly quote) — separates runs
            }
        }
        flush()
        return result
    }

    private static func replaceNumericEntities(_ s: String) -> String {
        var out = s
        if let re = try? NSRegularExpression(pattern: "&#([0-9]{1,7});") {
            out = replaceEntityMatches(out, re, radix: 10)
        }
        if let re = try? NSRegularExpression(pattern: "&#[xX]([0-9A-Fa-f]{1,6});") {
            out = replaceEntityMatches(out, re, radix: 16)
        }
        return out
    }

    private static func replaceEntityMatches(_ s: String, _ re: NSRegularExpression, radix: Int) -> String {
        var result = s
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let full = Range(m.range, in: result),
                  let g = Range(m.range(at: 1), in: result),
                  let cp = UInt32(result[g], radix: radix),
                  let scalar = Unicode.Scalar(cp) else { continue }
            result.replaceSubrange(full, with: String(Character(scalar)))
        }
        return result
    }

    private static let namedEntities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "),
        ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™"), ("&mdash;", "—"), ("&ndash;", "–"),
        ("&hellip;", "…"), ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"), ("&ldquo;", "\u{201C}"),
        ("&rdquo;", "\u{201D}"), ("&bull;", "•"), ("&middot;", "·"), ("&deg;", "°"), ("&sect;", "§"),
        ("&para;", "¶"), ("&euro;", "€"), ("&pound;", "£"), ("&yen;", "¥"), ("&cent;", "¢"),
        ("&times;", "×"), ("&divide;", "÷"), ("&plusmn;", "±"), ("&frac12;", "½"), ("&frac14;", "¼"),
        ("&frac34;", "¾"), ("&dagger;", "†"), ("&Dagger;", "‡"), ("&laquo;", "«"), ("&raquo;", "»"),
        ("&iquest;", "¿"), ("&iexcl;", "¡"),
        ("&Agrave;", "À"), ("&Aacute;", "Á"), ("&Acirc;", "Â"), ("&Atilde;", "Ã"), ("&Auml;", "Ä"),
        ("&Aring;", "Å"), ("&AElig;", "Æ"), ("&Ccedil;", "Ç"), ("&Egrave;", "È"), ("&Eacute;", "É"),
        ("&Ecirc;", "Ê"), ("&Euml;", "Ë"), ("&Igrave;", "Ì"), ("&Iacute;", "Í"), ("&Icirc;", "Î"),
        ("&Iuml;", "Ï"), ("&ETH;", "Ð"), ("&Ntilde;", "Ñ"), ("&Ograve;", "Ò"), ("&Oacute;", "Ó"),
        ("&Ocirc;", "Ô"), ("&Otilde;", "Õ"), ("&Ouml;", "Ö"), ("&Oslash;", "Ø"), ("&Ugrave;", "Ù"),
        ("&Uacute;", "Ú"), ("&Ucirc;", "Û"), ("&Uuml;", "Ü"), ("&Yacute;", "Ý"), ("&THORN;", "Þ"),
        ("&szlig;", "ß"),
        ("&agrave;", "à"), ("&aacute;", "á"), ("&acirc;", "â"), ("&atilde;", "ã"), ("&auml;", "ä"),
        ("&aring;", "å"), ("&aelig;", "æ"), ("&ccedil;", "ç"), ("&egrave;", "è"), ("&eacute;", "é"),
        ("&ecirc;", "ê"), ("&euml;", "ë"), ("&igrave;", "ì"), ("&iacute;", "í"), ("&icirc;", "î"),
        ("&iuml;", "ï"), ("&eth;", "ð"), ("&ntilde;", "ñ"), ("&ograve;", "ò"), ("&oacute;", "ó"),
        ("&ocirc;", "ô"), ("&otilde;", "õ"), ("&ouml;", "ö"), ("&oslash;", "ø"), ("&ugrave;", "ù"),
        ("&uacute;", "ú"), ("&ucirc;", "û"), ("&uuml;", "ü"), ("&yacute;", "ý"), ("&thorn;", "þ"),
        ("&yuml;", "ÿ")
    ]
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
        // Brief AF2 (a) — top 5 (was 8): a smaller synthesis payload → faster first
        // token → the tunnel can't time the upstream out mid-answer.
        comps?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "5")]
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
        // Brief AF2 (a) — cap at 5 results, snippet ≤ 300 chars, never a page body.
        return results.prefix(5).compactMap { r -> ToolLink? in
            guard let title = r["title"] as? String, let urlStr = r["url"] as? String, !urlStr.isEmpty else { return nil }
            let cleanTitle = WebReadability.decodeEntities(WebReadability.stripTags(title)).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = (r["description"] as? String).map { raw -> String in
                let clean = WebReadability.decodeEntities(WebReadability.stripTags(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.count > 300 ? String(clean.prefix(300)) + "…" : clean
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

    /// Brief AF1/AF3 — is a usable Brave key configured? The caller (LibrarianState)
    /// reads this BEFORE composing a turn so it can withhold the tool entirely (declare
    /// nothing, say nothing) when there's no key, rather than letting the model call a
    /// tool that can only report "unavailable". Mirrors `make()`'s key resolution so the
    /// two can't disagree (the DEBUG test-key overrides both).
    static var hasKey: Bool {
        #if DEBUG
        if let k = UserDefaults.standard.string(forKey: "BraveTestKey"), !k.isEmpty { return true }
        #endif
        return !((KeychainHelper.load(key: keychainKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

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
