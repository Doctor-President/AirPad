import XCTest
@testable import AirPad

/// 1.1-D — the user's-own-server adapter, pure: detection classification, the listing parsers, the mapping to the
/// picker's rows, the per-endpoint pick, the chat window and the exact load/eject/chat request bodies.
final class CustomServerTests: XCTestCase {
    private func d(_ s: String) -> Data { Data(s.utf8) }
    private func json(_ o: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    func testDetectionClassifiesOnlyARealVersionBody() {
        XCTAssertEqual(CustomServer.classifyVersion(d(#"{"version":"0.13.2"}"#)), .ollama(version: "0.13.2"))
        XCTAssertNil(CustomServer.classifyVersion(d(#"{"error":"Unexpected endpoint or method. (GET /api/version)"}"#)))
        XCTAssertTrue(CustomServer.isLMStudioList(d(#"{"models":[{"key":"qwen/qwen3-8b","type":"llm"}]}"#)))
        XCTAssertFalse(CustomServer.isLMStudioList(d(#"{"models":[{"name":"qwen3:8b"}]}"#)), "Ollama's /api/tags is not LM Studio's list")
    }

    func testOllamaListingJoinsTagsAndLoadedWindow() {
        let m = CustomServer.parseOllama(tags: d(#"{"models":[{"name":"a:1","size":10},{"name":"b:2","size":20}]}"#),
                                         ps: d(#"{"models":[{"name":"b:2","context_length":20480}]}"#))
        XCTAssertEqual(m.map(\.id), ["a:1", "b:2"])
        XCTAssertFalse(m[0].loaded)
        XCTAssertTrue(m[1].loaded)
        XCTAssertEqual(m[1].contextTokens, 20480)
    }

    func testLMStudioListingKeepsLLMsAndInstances() {
        let m = CustomServer.parseLMStudio(d(#"""
        {"models":[{"type":"llm","key":"qwen/qwen3-8b","loaded_instances":[{"id":"qwen/qwen3-8b","config":{"context_length":8192}}],
          "max_context_length":40960,"capabilities":{"trained_for_tool_use":true,"reasoning":{"allowed_options":["off","on"]}}},
         {"type":"embedding","key":"nomic","loaded_instances":[]}]}
        """#))
        XCTAssertEqual(m.map(\.id), ["qwen/qwen3-8b"])
        XCTAssertEqual(m[0].chatID, "qwen/qwen3-8b")
        XCTAssertEqual(m[0].contextTokens, 8192)
        XCTAssertEqual(m[0].thinking, true)
    }

    func testRowsOfferTheCuratedModelsNotOnTheServer() {
        let rows = CustomServer.catalogModels(kind: .ollama(version: "0.13.2"),
                                              models: [.init(id: "qwen3:4b-instruct-2507-q4_K_M", loaded: true, contextTokens: 20480)])
        XCTAssertEqual(rows.first?.display, "Qwen3 4B")
        XCTAssertEqual(rows.first?.contextLine, "Context 20,480 tokens")
        XCTAssertEqual(rows.filter { $0.state == "not-installed" }.map(\.tag), ["qwen3:8b-q4_K_M", "qwen3:30b-a3b-instruct-2507-q4_K_M"])
        XCTAssertEqual(rows.last?.memoryNote, "For computers with 32 GB of memory or more. Runs best with nothing else loaded.")
        XCTAssertEqual(CustomServer.catalogModels(kind: .openAICompatible, models: [.init(id: "x")]).count, 1, "no downloads on a generic server")
    }

    func testPickIsPerEndpointAndFallsBackToLoadedThenFirst() {
        let a = "http://198.51.100.1:11434", b = "http://198.51.100.2:1234"
        let saved = (CustomServer.pick(for: a), CustomServer.pick(for: b))
        defer { CustomServer.setPick(saved.0, for: a); CustomServer.setPick(saved.1, for: b) }
        CustomServer.setPick("x", for: a); CustomServer.setPick("y", for: b)
        XCTAssertEqual(CustomServer.pick(for: a + "/"), "x")
        XCTAssertEqual(CustomServer.pick(for: b), "y")
        let models: [CustomServer.ServerModel] = [.init(id: "first"), .init(id: "loaded", loaded: true), .init(id: "x")]
        XCTAssertEqual(CustomServer.chatModel(models, pick: "x")?.id, "x")
        XCTAssertEqual(CustomServer.chatModel(models, pick: "gone")?.id, "loaded")
        XCTAssertEqual(CustomServer.chatModel([.init(id: "first"), .init(id: "second")], pick: nil)?.id, "first")
    }

    func testChatWindow() {
        XCTAssertEqual(CustomServer.chatContext(kind: .ollama(version: ""), model: .init(id: "m", loaded: true, contextTokens: 8192)), 8192)
        XCTAssertEqual(CustomServer.chatContext(kind: .ollama(version: ""), model: .init(id: "m")), 20_480)
        XCTAssertEqual(CustomServer.chatContext(kind: .ollama(version: ""), model: .init(id: "m", maxContext: 4096)), 4096)
        XCTAssertEqual(CustomServer.chatContext(kind: .openAICompatible, model: .init(id: "m")), 4096)
    }

    func testRequestBodies() {
        let m = CustomServer.ServerModel(id: "qwen3:8b-q4_K_M")
        XCTAssertEqual(json(CustomServer.loadBody(kind: .ollama(version: ""), model: m).body), #"{"model":"qwen3:8b-q4_K_M","options":{"num_ctx":20480}}"#)
        XCTAssertEqual(json(CustomServer.ejectBodies(kind: .ollama(version: ""), model: m)[0].body), #"{"keep_alive":0,"model":"qwen3:8b-q4_K_M"}"#)
        let l = CustomServer.ServerModel(id: "qwen/qwen3-8b", loaded: true, instances: ["qwen/qwen3-8b", "qwen/qwen3-8b:2"])
        XCTAssertEqual(json(CustomServer.loadBody(kind: .lmStudio(version: nil), model: l).body), #"{"context_length":20480,"model":"qwen/qwen3-8b"}"#)
        XCTAssertEqual(CustomServer.ejectBodies(kind: .lmStudio(version: nil), model: l).map { json($0.body) },
                       [#"{"instance_id":"qwen/qwen3-8b"}"#, #"{"instance_id":"qwen/qwen3-8b:2"}"#])
        let chat = CustomServer.ollamaChatBody(model: "m", messages: [], numCtx: 20480, think: nil, stream: true)
        XCTAssertNil(chat["keep_alive"])
        XCTAssertNil(chat["think"])
        XCTAssertEqual((chat["options"] as? [String: Int])?["num_ctx"], 20480)
    }
}
