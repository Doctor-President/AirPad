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
