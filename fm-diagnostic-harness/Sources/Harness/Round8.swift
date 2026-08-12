import Foundation
import FoundationModels

// MARK: - Round 8 — prompt surface, not schema
//
// Rounds 6+7 varied guardrails, schema size, and free-text vs Generable — none varied
// the PROMPT. Every cell used buildPrompt(), which injects the full 72-tag vocabulary
// (incl. Masculinity, Hyper-masculinity, Darkness, Fear, Manipulation, Conflict, Power,
// Morality, Religion) as a comma-separated line directly above the user's text. A
// classifier scoring the payload cannot know that line is a picklist, not subject matter.
//
// Round 8 varies ONLY the prompt. FIXED across every cell: default guardrails; the
// title+summary schema (Round 7's B3 = R7TitleSummary); single-stage; raw node content;
// same 20 nodes (round6-nodes.json, not re-sourced). One change per cell so any win is
// attributable. Mac harness — the device wins on prompt-behaviour verdicts.
//
//   C1  = REPLICATE — buildPrompt() verbatim (full vocab line). Round 7's B3, re-run
//         THREE TIMES (C1a/C1b/C1c) to establish run-to-run stability.
//   C2  = VOCABULARY REMOVED — the "Tag vocabulary: …" line + the "Only suggest tags…"
//         sentence deleted; everything else byte-identical.
//   C3  = TRANSFORMATION FRAME — evaluation → restatement instruction.
//   C4  = DELIMITED CONTENT — C3 with the user's text fenced in triple quotes.

// MARK: - Prompt builders (byte-precise per the brief; C1 reuses production buildPrompt)

/// C2 — buildPrompt minus the vocabulary line and the tag sentence.
func buildPromptC2(content: String) -> String {
    "Analyze this captured idea.\n\nIdea:\n\(content)"
}

/// C3 — transformation frame (restatement, not evaluation).
func buildPromptC3(content: String) -> String {
    "The following text was written by a person in their personal notes.\nRestate it more briefly.\n\n\(content)"
}

/// C4 — C3 with the content triple-quote fenced so it reads as quoted material.
func buildPromptC4(content: String) -> String {
    "The following text was written by a person in their personal notes.\nRestate it more briefly.\n\n\"\"\"\n\(content)\n\"\"\""
}

// MARK: - Fixed-schema call (title + summary only; default guardrails)

private func r8TitleSummary(prompt: String, model: SystemLanguageModel) async -> R7Call {
    let start = Date()
    do {
        let s = LanguageModelSession(model: model)
        let r = try await s.respond(to: prompt, generating: R7TitleSummary.self).content
        return R7Call(threw: false, error: nil, ms: Int(Date().timeIntervalSince(start) * 1000),
                      title: r.title, summary: r.summary, tags: [])
    } catch {
        return R7Call(threw: true, error: "\(type(of: error)): \(error)",
                      ms: Int(Date().timeIntervalSince(start) * 1000), title: "", summary: "", tags: [])
    }
}

// MARK: - Main

func runRound8() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let harnessDir = home.appendingPathComponent("Developer/AirPad/fm-diagnostic-harness")

    print("=== Round 8 — prompt surface (default guardrails, title+summary schema, raw content) ===")
    guard SystemLanguageModel.default.isAvailable else {
        print("ERROR: SystemLanguageModel.default not available. Aborting.")
        return
    }
    let model = SystemLanguageModel.default   // DEFAULT guardrails everywhere (Round 7 settled permissive is inert)

    let nodes: [Round6Node]
    do {
        let data = try Data(contentsOf: harnessDir.appendingPathComponent("round6-nodes.json"))
        nodes = try JSONDecoder().decode([Round6Node].self, from: data)
    } catch {
        print("ERROR loading round6-nodes.json: \(error)")
        return
    }
    print("Loaded \(nodes.count) nodes from round6-nodes.json (same set as Rounds 6/7).")

    // (cell name, prompt builder). C1 runs three times for a stability baseline.
    let cells: [(name: String, prompt: (String) -> String)] = [
        ("C1a", { buildPrompt(content: $0, vocabulary: vocabulary) }),
        ("C1b", { buildPrompt(content: $0, vocabulary: vocabulary) }),
        ("C1c", { buildPrompt(content: $0, vocabulary: vocabulary) }),
        ("C2",  { buildPromptC2(content: $0) }),
        ("C3",  { buildPromptC3(content: $0) }),
        ("C4",  { buildPromptC4(content: $0) }),
    ]

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]

    for cell in cells {
        print("\n--- Cell \(cell.name) ---")
        var rows: [Round7ResultRow] = []
        for (i, node) in nodes.enumerated() {
            let prompt = cell.prompt(node.content)
            print("  [\(cell.name)] \(i + 1)/\(nodes.count) \(node.id8) (\(node.set))…", terminator: " ")
            fflush(stdout)
            let r = await r8TitleSummary(prompt: prompt, model: model)
            if r.threw {
                print("THREW \(r.ms)ms (\(r.ms < 500 ? "input-side" : "generation-side"))")
            } else {
                print("ok \(r.ms)ms \"\(r.title.prefix(30))\"")
            }
            rows.append(Round7ResultRow(
                nodeID: node.uuid, id8: node.id8, set: node.set,
                variant: cell.name, guardrail: "default", schema: "title+summary",
                contentSource: node.contentSource, contentLen: node.contentLen,
                prompt: prompt, threw: r.threw, error: r.error, elapsedMs: r.ms,
                title: r.title, summary: r.summary, tags: r.tags
            ))
        }
        let outURL = harnessDir.appendingPathComponent("results-\(cell.name).json")
        do {
            let data = try enc.encode(rows.sorted { ($0.set, $0.id8) < ($1.set, $1.id8) })
            try data.write(to: outURL)
            print("  wrote \(outURL.lastPathComponent) (\(rows.count) rows)")
        } catch {
            print("  ERROR writing \(outURL.lastPathComponent): \(error)")
        }
    }
    print("\nRound 8 complete. Generate summary-round8.md from results-C*.json.")
}
