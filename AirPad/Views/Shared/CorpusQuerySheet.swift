import SwiftUI
import FoundationModels

struct CorpusQuerySheet: View {
    @Binding var isPresented: Bool
    let initialQuery: String
    @Environment(CorpusStore.self) private var store

    @State private var queryText: String = ""
    @State private var isLoading: Bool = false
    @State private var response: QueryResponse? = nil
    @State private var sheetDetent: PresentationDetent = .medium

    enum QueryResponse {
        case insight(String)
        case retrieval([Node])
        case error(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 32, height: 32)
                    }

                    Spacer()

                    Text("Ask your corpus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .textCase(.uppercase)

                    Spacer()

                    Button(action: {
                        sheetDetent = sheetDetent == .medium ? .large : .medium
                    }) {
                        Image(systemName: sheetDetent == .medium ? "chevron.up" : "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 32, height: 32)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Query input
                HStack(spacing: 12) {
                    TextField("Ask anything...", text: $queryText, axis: .vertical)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .lineLimit(1...4)

                    Button(action: { Task { await executeQuery() } }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading ? .white.opacity(0.2) : .white)
                    }
                    .disabled(queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    .padding(.trailing, 12)
                }
                .frame(minHeight: 52)
                .background(Color(red: 0.04, green: 0.04, blue: 0.06))
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
                .padding(.horizontal, 16)

                // Response area
                ScrollView {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 60)
                    } else if let response = response {
                        switch response {
                        case .insight(let text):
                            Text(text)
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(.white)
                                .lineSpacing(8)
                                .padding(20)
                                .frame(maxWidth: .infinity, alignment: .leading)

                        case .retrieval(let nodes):
                            LazyVStack(spacing: 12) {
                                ForEach(nodes) { node in
                                    NavigationLink(value: node.id) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(node.title)
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                            if !node.summary.isEmpty {
                                                Text(node.summary)
                                                    .font(.system(size: 14, weight: .regular))
                                                    .foregroundStyle(.white.opacity(0.7))
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .lineLimit(2)
                                            }

                                            Text(node.createdAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.system(size: 12, weight: .regular))
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                        .padding(16)
                                        .frame(maxWidth: .infinity)
                                        .background(Color.white.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(16)

                        case .error(let message):
                            Text(message)
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(Color(red: 1.0, green: 0.6, blue: 0.2))
                                .padding(20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // Empty state — show generic whispers as suggestions
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Try asking:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.4))
                                .textCase(.uppercase)
                                .padding(.bottom, 4)

                            ForEach(["What have I been thinking about most lately?",
                                     "What ideas keep coming back that I haven't acted on?",
                                     "What patterns show up in my work?"], id: \.self) { whisper in
                                Button(action: {
                                    queryText = whisper
                                }) {
                                    Text(whisper)
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(Color.white.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(20)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .background(Color(red: 0.04, green: 0.04, blue: 0.06))
            .navigationDestination(for: String.self) { nodeID in
                NodeDetailView(nodeID: nodeID)
            }
            .onAppear {
                queryText = initialQuery
            }
        }
    }

    private func executeQuery() async {
        guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoading = true
        response = nil

        // Build corpus context — truncate to 30 most recent nodes if corpus is large
        let nodesToInclude = store.nodes.count > 30 ? Array(store.nodes.prefix(30)) : store.nodes
        let corpusSummary = nodesToInclude.map { node in
            "Title: \(node.title)\nSummary: \(node.summary)\nTags: \(node.tags.joined(separator: ", "))"
        }.joined(separator: "\n---\n")

        let classifyPrompt = """
        Query: \(queryText)

        Classify this query as either "insight" (requires synthesis, pattern analysis, or reflection across the corpus) or "retrieval" (looking for specific nodes, topics, or content).

        Respond with exactly one word: insight or retrieval
        """

        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                await MainActor.run {
                    response = .error("Foundation Model not available on this device.")
                    isLoading = false
                }
                return
            }

            do {
                // Step 1: Classify the query
                let classifySession = LanguageModelSession()
                let classification = try await classifySession.respond(to: classifyPrompt).content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                if classification.contains("retrieval") {
                    // Step 2a: Retrieval mode — find matching nodes
                    let retrievalPrompt = """
                    Query: \(queryText)

                    Corpus:
                    \(corpusSummary)

                    Return the titles of nodes that best match this query, one per line, most relevant first. Maximum 5 results. Only return titles that exist exactly in the corpus above.
                    """
                    let session = LanguageModelSession()
                    let result = try await session.respond(to: retrievalPrompt).content
                    let titles = result.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let matchedNodes = titles.compactMap { title in
                        store.nodes.first { $0.title == title }
                    }
                    await MainActor.run {
                        response = .retrieval(matchedNodes)
                        isLoading = false
                    }
                } else {
                    // Step 2b: Insight mode — synthesize a response
                    let insightPrompt = """
                    You are a reflective AI that helps someone understand patterns in their own thinking.

                    Their corpus:
                    \(corpusSummary)

                    Question: \(queryText)

                    Give a thoughtful, concise response (2-4 sentences) that synthesizes patterns from their corpus. Be specific to their actual content. Do not be generic.
                    """
                    let session = LanguageModelSession()
                    let result = try await session.respond(to: insightPrompt).content
                    await MainActor.run {
                        response = .insight(result)
                        isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    response = .error("Something went wrong. Try again.")
                    isLoading = false
                }
            }
        }
    }
}
