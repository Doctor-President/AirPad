// Sweep 2b · 3.3 — the dry-run engine: calls NO model. It answers from the suite's own expectations with a few
// planted faults (a wrong pick, a guardrail error that forces the plain-text fallback, a guardrail error in Q4, a
// no-match case that answers) so the results file carries every field the grader reads, off-device.
import Foundation
import FoundationModels

struct DryRunError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

struct DryEngine: SpikeEngine {
    let label: String

    private func tick() async { try? await Task.sleep(for: .milliseconds(2)) }
    private func question(_ prompt: String) -> String { prompt.components(separatedBy: "Question: ").last ?? "" }
    private func firstSentence(_ s: String) -> String { (s.components(separatedBy: ". ").first ?? s) + "." }
    private func sensitiveNote(_ prompt: String) -> Sensitive.Note? {
        Sensitive.notes.first { n in
            question(prompt) == n.question && (prompt.contains("[1] " + SpikeData.passage(n.passage)) || prompt.hasPrefix("Note: "))
        }
    }
    private var guardrail: DryRunError { DryRunError(description: "dry-run stand-in for LanguageModelError.guardrailViolation") }
    private func usage(_ text: String) -> SpikeUsage { SpikeUsage(input: 300, output: max(1, text.split(separator: " ").count * 4 / 3), reasoning: 0) }

    func sort(_ question: String) async throws -> (QuestionKind, SpikeUsage?) {
        await tick(); return (.library, SpikeUsage(input: 60, output: 3, reasoning: 0))
    }

    func pick(instructions: String, prompt: String) async throws -> (Pick, SpikeUsage?) {
        await tick()
        let q = question(prompt)
        if instructions == SpikeData.pickInstructions, let c = SpikeData.probeQuestions.first(where: { $0.q == q }) {
            return (Pick(passage: c.passage, sentence: firstSentence(SpikeData.probePassages[c.passage - 1])), usage(prompt))
        }
        if let n = sensitiveNote(prompt), !prompt.hasPrefix("Note: "), prompt.contains("[1] " + SpikeData.passage(n.passage)) {
            if n.id == "H4" { throw guardrail }
            return (Pick(passage: 1, sentence: firstSentence(SpikeData.passage(n.passage))), usage(prompt))
        }
        guard let c = Suite.cases.first(where: { $0.question == q }) else { throw DryRunError(description: "dry run: unknown question") }
        switch c.id {
        case "S1": throw guardrail                                   // → plain-text fallback path
        case "A4": return (Pick(passage: 1, sentence: ""), usage(prompt))   // wrong passage → fail
        case "N2": return (Pick(passage: 1, sentence: ""), usage(prompt))   // answers a no-match → fail
        default:
            let s = c.expectedPassage == 0 ? "" : firstSentence(SpikeData.passage(c.packet[c.expectedPassage - 1]))
            return (Pick(passage: c.expectedPassage, sentence: s), usage(prompt))
        }
    }

    func text(instructions: String, prompt: String, maxTokens: Int) async throws -> (String, SpikeUsage?) {
        await tick()
        let q = question(prompt)
        let reply: String
        if instructions == SpikeData.coldInstructions {
            reply = "Ready."
        } else if instructions == SpikeData.rewriteInstructions {
            reply = "When was that?"
        } else if instructions == Suite.fallbackPickInstructions {
            if let n = sensitiveNote(prompt) { _ = n; reply = "1" }
            else { reply = "\(Suite.cases.first { $0.question == q }?.expectedPassage ?? 0)" }
        } else if let n = sensitiveNote(prompt), label == "apple", n.id == "H4" {
            throw guardrail
        } else if let c = Suite.cases.first(where: { $0.question == q }), !c.keys.isEmpty {
            reply = "Your note says \(c.keys[0])." + (c.conflictKeys.isEmpty ? "" : " The well-known date is \(c.conflictKeys[0]).")
        } else if let n = sensitiveNote(prompt) {
            reply = "Your note says: \(firstSentence(SpikeData.passage(n.passage)))"
        } else if let c = SpikeData.probeQuestions.first(where: { $0.q == q }) {
            reply = "Your note says \(c.word)."
        } else if let c = Suite.cases.first(where: { $0.question == q }), c.id == "N2" {
            reply = "Your note says the hallway paint is Chalk Mist."
        } else {
            reply = Array(repeating: "dry", count: 80).joined(separator: " ")
        }
        return (reply, usage(reply))
    }

    func stream(instructions: String, prompt: String, maxTokens: Int) async throws -> (String, Double?, SpikeUsage?) {
        let (t, u) = try await text(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
        return (t, 1.0, u)
    }
}
