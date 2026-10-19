// live-28 (A6) — does the on-device model (Apple Intelligence, macOS 27) call a FoundationModels `Tool` for current-state
// questions? A `web_search` tool with @Generable arguments that returns canned synthetic results and counts its calls.
// Report-only: no app code depends on this. Synthetic results; public current-state questions.
//   scripts/fm_tool_harness/run.sh [runs]
import Foundation
import FoundationModels

final class Calls: @unchecked Sendable { var n = 0; var queries: [String] = []; let lock = NSLock() }
let calls = Calls()

struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for current information: news, who holds an office now, prices, today's events."
    @Generable struct Arguments {
        @Guide(description: "The search query") var query: String
    }
    func call(arguments: Arguments) async throws -> String {
        calls.lock.lock(); calls.n += 1; calls.queries.append(arguments.query); calls.lock.unlock()
        return "[1] Lakeview Gazette — synthetic result for \"\(arguments.query)\" (published today).\n[2] Harbour Times — a second synthetic result."
    }
}

let instructions = "You're a thoughtful, knowledgeable friend to the person you're talking with — warm, curious, plain-spoken and to the point. Answer the user's question clearly and accurately. For anything about the current state of the world — news, who holds an office now, prices, today's events — use the web_search tool and answer from its results."
let questions = [
    "Who is the current UN Secretary-General?",
    "What's the latest news about the James Webb Space Telescope?",
    "What is the price of Bitcoin today?",
    "Who won the most recent Nobel Prize in Physics?",
    "What's the weather in Paris right now?",
    "Who is the current Prime Minister of Japan?",
    "What are today's top headlines?",
    "Which films are showing in cinemas this week?",
    "What is the current US federal funds rate?",
    "Has the newest iPhone been released yet?",
]

@main struct Harness {
    static func main() async {
        guard SystemLanguageModel.default.isAvailable else { print("Apple Intelligence unavailable"); exit(3) }
        let runs = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 3 : 3
        var called = 0, total = 0, errors = 0
        for run in 1...runs {
            for q in questions {
                let before = calls.n
                let session = LanguageModelSession(tools: [WebSearchTool()], instructions: instructions)
                let t0 = Date()
                do {
                    let r = try await session.respond(to: q)
                    let used = calls.n > before
                    total += 1; if used { called += 1 }
                    print(String(format: "run %d · %@ · tool %@ · %.1fs — %@", run, q, used ? "CALLED (\(calls.queries.last ?? ""))" : "not called",
                                 Date().timeIntervalSince(t0), String(r.content.replacingOccurrences(of: "\n", with: " ").prefix(90))))
                } catch {
                    total += 1; errors += 1
                    print("run \(run) · \(q) · ERROR \(type(of: error)): \(error.localizedDescription)")
                }
            }
        }
        print("SUMMARY: tool called on \(called) of \(total) current-state questions · errors \(errors)")
    }
}
