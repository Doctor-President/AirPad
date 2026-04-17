import Foundation
import FoundationModels

// MARK: - Thread suggestion type (no availability gate — CorpusStore references freely)

struct ThreadSuggestion: Identifiable, Equatable {
    let id: UUID
    let nodeIDs: [String]
    let description: String
    let confidence: Double
}

// MARK: - Structured output (iOS 26+)

@available(iOS 26.0, *)
@Generable
struct ThreadSuggestionAI {
    @Guide(description: "IDs of the 2–4 connected nodes from the provided list, comma-separated. Must be exact IDs from the input.")
    var nodeIDsCSV: String
    @Guide(description: "One crisp observation sentence (max 20 words) describing the non-obvious connection between the nodes. Be concrete, not vague. No paragraph — one sentence only.")
    var description: String
    @Guide(description: "Confidence 0.0–1.0. Use 0.0 if the connection is weak or obvious.")
    var confidence: Double
}

@available(iOS 26.0, *)
@Generable
struct CorpusAnalysisResult {
    @Guide(description: "Thread 1 node IDs, comma-separated. Empty string if no thread 1.")
    var thread1NodeIDs: String
    @Guide(description: "Thread 1: one crisp sentence (max 20 words) on the non-obvious connection. Empty string if no thread 1.")
    var thread1Description: String
    @Guide(description: "Thread 1 confidence 0.0–1.0. Use 0.0 if no thread 1.")
    var thread1Confidence: Double

    @Guide(description: "Thread 2 node IDs, comma-separated. Empty string if no thread 2.")
    var thread2NodeIDs: String
    @Guide(description: "Thread 2: one crisp sentence (max 20 words) on the non-obvious connection. Empty string if no thread 2.")
    var thread2Description: String
    @Guide(description: "Thread 2 confidence 0.0–1.0. Use 0.0 if no thread 2.")
    var thread2Confidence: Double

    @Guide(description: "Thread 3 node IDs, comma-separated. Empty string if no thread 3.")
    var thread3NodeIDs: String
    @Guide(description: "Thread 3: one crisp sentence (max 20 words) on the non-obvious connection. Empty string if no thread 3.")
    var thread3Description: String
    @Guide(description: "Thread 3 confidence 0.0–1.0. Use 0.0 if no thread 3.")
    var thread3Confidence: Double
}

// MARK: - Service

@available(iOS 26.0, *)
actor ThreadService {

    func analyzeCorpus(nodes: [Node], tags: [Tag]) async -> [ThreadSuggestion] {
        guard SystemLanguageModel.default.isAvailable else { return [] }
        guard nodes.count >= 10 else { return [] }

        let corpusLines = nodes.map { node in
            "ID:\(node.id) | \(node.title) | tags:\(node.tags.joined(separator: ",")) | \(node.summary)"
        }.joined(separator: "\n")

        let prompt = """
        Analyze this idea corpus and find latent connections the user hasn't explicitly made.

        Rules:
        - Each thread must connect 2–4 nodes
        - The connection must be non-obvious (not just shared tags)
        - Confidence > 0.7 only
        - Leave description empty if you can't find a strong thread

        Corpus (ID | Title | Tags | Summary):
        \(corpusLines)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: CorpusAnalysisResult.self)
            let r = response.content

            let rawThreads: [(csv: String, desc: String, conf: Double)] = [
                (r.thread1NodeIDs, r.thread1Description, r.thread1Confidence),
                (r.thread2NodeIDs, r.thread2Description, r.thread2Confidence),
                (r.thread3NodeIDs, r.thread3Description, r.thread3Confidence),
            ]

            return rawThreads.compactMap { item -> ThreadSuggestion? in
                guard !item.csv.isEmpty, !item.desc.isEmpty, item.conf > 0.7 else { return nil }
                let ids = item.csv
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { id in nodes.contains { $0.id == id } }
                guard ids.count >= 2 else { return nil }
                return ThreadSuggestion(id: UUID(), nodeIDs: ids, description: item.desc, confidence: item.conf)
            }
        } catch {
            return []
        }
    }
}
