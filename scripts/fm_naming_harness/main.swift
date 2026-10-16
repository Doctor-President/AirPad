// live-20 (1) — Apple Intelligence naming, measured on this Mac (macOS 27 + Apple Intelligence) with the app's OWN
// prompt + parse code (AirPad/Services/AppleNaming.swift is compiled in). Synthetic notes only.
//   scripts/fm_naming_harness/run.sh <notes.json> [before|after|both] [runs]
// BEFORE = today's path (guided generation, @Generable, default guardrails — ModelRouter.nodeSummaryFoundationModel /
// substrateFoundationModel). AFTER = AppleNaming (plain String, .permissiveContentTransformations, parsed).
import Foundation
import FoundationModels

// Copies of today's @Generable types, verbatim (AIService.swift).
@Generable
struct NodeAIResult {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String
    @Guide(description: "One or two sentences stating what the note is ABOUT — an impersonal catalogue fragment. Never refer to the note's own author (no 'she', 'he', 'they', 'you', 'the author', 'the writer') and never narrate the author's actions; people the note is about may be named, but the writer is never the subject.")
    var summary: String
}
@Generable
struct SubstrateInterpretation {
    @Guide(description: "One or two sentences stating what the note is ABOUT, specific to the actual content (this seeds the embedding, so accuracy matters). An impersonal fragment: never refer to the note's own author (no 'she'/'he'/'they'/'you'/'the author') and never narrate their actions; name people the note is about, but never the writer.")
    var summary: String
    @Guide(description: "Free-form tags describing this idea. Pick whatever words best capture the content — no fixed vocabulary, no schema list. Aim for 3 to 8 short tags. Concrete nouns and topical phrases work better than abstract single words.")
    var tags: [String]
}

struct Note: Decodable { let id: String; let kind: String; let text: String }

/// What today's `AIService.nodeFailure` makes of an error: it recognises ONLY `GenerationError` refusals.
func todaysClassification(_ error: any Error) -> String {
    if let g = error as? LanguageModelSession.GenerationError {
        switch g { case .refusal, .guardrailViolation: return "refused"; default: break }
    }
    return "failed"
}
func describe(_ error: any Error) -> String {
    let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    return "\(type(of: error)) · today→\(todaysClassification(error)) · new→\(AppleNaming.isRefusal(error) ? "refused" : "failed") · \"\(msg)\""
}
func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }

@main struct Harness {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 2, let data = FileManager.default.contents(atPath: a[1]),
              let notes = try? JSONDecoder().decode([Note].self, from: data) else { print("usage: harness notes.json [before|after|both] [runs]"); exit(2) }
        let mode = a.count > 2 ? a[2] : "both"
        let runs = a.count > 3 ? Int(a[3]) ?? 1 : 1
        guard SystemLanguageModel.default.isAvailable else { print("Apple Intelligence unavailable"); exit(3) }

        let rows = AppleNaming.selfTestRows()
        print("parser self-test: \(rows.filter(\.ok).count)/\(rows.count)" + rows.filter { !$0.ok }.map { " FAIL \($0.name)" }.joined())

        var tally: [String: (ok: Int, n: Int)] = [:]
        func count(_ k: String, _ ok: Bool) { var t = tally[k] ?? (0, 0); t.n += 1; if ok { t.ok += 1 }; tally[k] = t }
        print("| run | note | kind | path | call | outcome |\n|---|---|---|---|---|---|")
        for run in 1...runs {
            for n in notes {
                let content = AppleNaming.namingPrompt(content: n.text)
                let sub = AppleNaming.substratePrompt(content: n.text)
                if mode != "after" {
                    do {
                        let r = try await LanguageModelSession().respond(to: content, generating: NodeAIResult.self).content
                        print("| \(run) | \(n.id) | \(n.kind) | before | naming | OK · \(cell(r.title)) — \(cell(r.summary)) |"); count("before.naming", true)
                    } catch { print("| \(run) | \(n.id) | \(n.kind) | before | naming | ERROR · \(cell(describe(error))) |"); count("before.naming", false) }
                    do {
                        let r = try await LanguageModelSession().respond(to: sub, generating: SubstrateInterpretation.self).content
                        print("| \(run) | \(n.id) | \(n.kind) | before | tags | OK · \(cell(r.tags.joined(separator: ", "))) |"); count("before.tags", true)
                    } catch { print("| \(run) | \(n.id) | \(n.kind) | before | tags | ERROR · \(cell(describe(error))) |"); count("before.tags", false) }
                }
                if mode != "before" {
                    do {
                        let r = try await AppleNaming.name(prompt: content)
                        print("| \(run) | \(n.id) | \(n.kind) | after | naming | OK · \(cell(r.title)) — \(cell(r.summary)) |"); count("after.naming", true)
                    } catch { print("| \(run) | \(n.id) | \(n.kind) | after | naming | ERROR · \(cell(describe(error))) |"); count("after.naming", false) }
                    do {
                        let r = try await AppleNaming.substrate(prompt: sub)
                        print("| \(run) | \(n.id) | \(n.kind) | after | tags | OK · \(cell(r.tags.joined(separator: ", "))) |"); count("after.tags", true)
                    } catch { print("| \(run) | \(n.id) | \(n.kind) | after | tags | ERROR · \(cell(describe(error))) |"); count("after.tags", false) }
                }
            }
        }
        print("\nSUMMARY (named / asked):")
        for k in tally.keys.sorted() { let t = tally[k]!; print("  \(k): \(t.ok)/\(t.n) named, \(t.n - t.ok) not") }
    }
}
