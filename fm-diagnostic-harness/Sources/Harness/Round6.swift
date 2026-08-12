import Foundation
import FoundationModels

// MARK: - Round 6 — Free-text stage 1, then Generable stage 2 over the model's prose
//
// Round 2's A5/A6 tested a two-stage design, but stage 1 was the PRODUCTION shape
// (runSummaryStage1 → buildPrompt + @Generable SummaryFirstStage1) — the shape that
// refuses. Round 6 tests a genuinely different stage 1: FREE-TEXT (session.respond
// returning String, no Generable, chat register), then a Generable stage 2 over the
// model's own prose.
//
// Four variants = 2 prompts × 2 guardrail settings:
//   P1 (bare)              = the node's raw content text, nothing prepended
//   P2 (subject-direction) = the node text, a blank line, then the question below
//   G1 = default guardrails      G2 = permissive (permissiveContentTransformations)
//   A7a=P1/G1  A7b=P1/G2  A7c=P2/G1  A7d=P2/G2
//
// Stage 2 is Generable over the stage-1 STRING ONLY (never the raw node text),
// default guardrails, reusing the CURRENT production @Guide strings verbatim
// (title/summary from AIService.NodeAIResult, tags from AIService.ProcessNodeResult).
//
// Node content is sourced from the audited `round6-nodes.json` (built + provenance-
// checked out-of-band, because 12 of the 20 briefed nodes have been DELETED from the
// live corpus since the May snapshot the sets were defined against). This is a Mac
// harness: the device wins on prompt-behaviour verdicts. Nothing here is device-verified.

// The exact subject-direction line for P2 (verbatim per the brief).
let round6P2Question = "What are the core ideas at work here?"

// MARK: - Stage 2 schema (production @Guide strings, verbatim)

/// Stage 2 over the stage-1 prose. `title`/`summary` reuse `AIService.NodeAIResult`'s
/// Guide strings verbatim; `tags` reuses `AIService.ProcessNodeResult.tags` verbatim
/// (NodeAIResult in current source carries only title+summary — the tags Guide lives
/// on ProcessNodeResult, the production corpus-aware call). See summary-round6.md §1.
@Generable
struct Round6Stage2 {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String

    @Guide(description: "One to two sentence summary capturing the idea's core essence.")
    var summary: String

    @Guide(description: "Up to 5 tags from the supplied vocabulary. Prefer compound or specific tags over single broad ones when both are valid; e.g., a recipe-app idea should be tagged with both 'Recipe' and 'Technology' rather than 'Technology' alone. Return an empty array if the content is too thin to support confident tagging.")
    var tags: [String]
}

// MARK: - Input + output shapes

/// One row of the audited `round6-nodes.json`.
struct Round6Node: Decodable {
    let id8: String
    let uuid: String
    let set: String            // "REFUSED" | "CONTROL"
    let contentSource: String
    let contentLen: Int
    let note: String
    let content: String
}

/// Per (node, variant) result. Same conventions as the other results-*.json
/// (array of objects, pretty-printed, sorted keys) with Round-6-specific fields.
struct Round6ResultRow: Encodable {
    let nodeID: String         // full uuid, or id8 when the node is deleted
    let id8: String
    let set: String
    let variant: String        // "A7a".."A7d"
    let promptVariant: String  // "P1" | "P2"
    let guardrail: String      // "G1-default" | "G2-permissive"
    let contentSource: String
    let contentLen: Int
    let sourceNote: String
    let stage1Prompt: String   // the exact string sent to stage 1
    let stage1Raw: String      // FULL, untruncated — the primary artifact
    let stage1Threw: Bool
    let stage1Error: String?
    let stage1SoftRefusal: Bool
    let stage1Ms: Int
    let stage2Ran: Bool        // false when stage 1 produced nothing
    let stage2Title: String
    let stage2Summary: String
    let stage2Tags: [String]
    let stage2Threw: Bool
    let stage2Error: String?
    let stage2Ms: Int
}

// MARK: - Soft-refusal heuristic (reading aid, NOT authoritative)

/// Apple DTS states refusals cannot be reliably caught outside guided generation, so
/// this is a reading aid for T, not a verdict. Flags if the output is under ~200
/// chars OR opens with a refusal phrase OR mentions guidelines/unsafe content.
func round6SoftRefusal(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count < 200 { return true }
    let lower = trimmed.lowercased()
    for p in ["i cannot", "i can't", "i can’t", "i'm unable", "i’m unable", "i am unable"] {
        if lower.hasPrefix(p) { return true }
    }
    for m in ["guideline", "unsafe content", "unsafe", "can't help", "can’t help", "cannot assist", "can't assist"] {
        if lower.contains(m) { return true }
    }
    return false
}

// MARK: - Sessions

/// Build the two stage-1 models once. G1 = default; G2 = permissive. Stage 2 always
/// uses default guardrails, so it reuses the default model.
private func makeModel(permissive: Bool) -> SystemLanguageModel {
    permissive ? SystemLanguageModel(guardrails: .permissiveContentTransformations)
               : SystemLanguageModel.default
}

// MARK: - Variant runner

struct Round6Variant {
    let name: String           // A7a..A7d
    let promptVariant: String  // P1 | P2
    let guardrail: String      // G1-default | G2-permissive
    let permissive: Bool
    let directed: Bool         // P2 appends the subject-direction question
}

func round6BuildStage1Prompt(content: String, directed: Bool) -> String {
    directed ? content + "\n\n" + round6P2Question : content
}

func runRound6Variant(_ v: Round6Variant, nodes: [Round6Node]) async -> [Round6ResultRow] {
    let stage1Model = makeModel(permissive: v.permissive)
    var rows: [Round6ResultRow] = []

    for (i, node) in nodes.enumerated() {
        print("  [\(v.name)] \(i + 1)/\(nodes.count) \(node.id8) (\(node.set))…", terminator: " ")
        fflush(stdout)

        // ---- Stage 1: free text, no Generable ----
        let s1Prompt = round6BuildStage1Prompt(content: node.content, directed: v.directed)
        var stage1Raw = ""
        var stage1Threw = false
        var stage1Error: String? = nil
        let s1Start = Date()
        do {
            let session = LanguageModelSession(model: stage1Model)
            let response = try await session.respond(to: s1Prompt)
            stage1Raw = response.content
        } catch {
            stage1Threw = true
            stage1Error = "\(type(of: error)): \(error)"
        }
        let s1ms = Int(Date().timeIntervalSince(s1Start) * 1000)
        let soft = stage1Threw ? true : round6SoftRefusal(stage1Raw)

        // ---- Stage 2: Generable over stage-1 string ONLY, default guardrails ----
        // Skip when stage 1 produced nothing (threw, or empty output).
        var stage2Ran = false
        var s2Title = "", s2Summary = ""
        var s2Tags: [String] = []
        var stage2Threw = false
        var stage2Error: String? = nil
        var s2ms = 0
        let stage1Empty = stage1Raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !stage1Threw && !stage1Empty {
            stage2Ran = true
            let s2Prompt = buildPrompt(content: stage1Raw, vocabulary: vocabulary)
            let s2Start = Date()
            do {
                let session = LanguageModelSession()   // default guardrails
                let response = try await session.respond(to: s2Prompt, generating: Round6Stage2.self)
                let r = response.content
                s2Title = r.title; s2Summary = r.summary
                s2Tags = r.tags
            } catch {
                stage2Threw = true
                stage2Error = "\(type(of: error)): \(error)"
            }
            s2ms = Int(Date().timeIntervalSince(s2Start) * 1000)
        }

        if stage1Threw {
            print("s1 THREW \(s1ms)ms")
        } else {
            let flag = soft ? " [soft-refusal]" : ""
            print("s1 \(stage1Raw.count)ch\(flag) \(s1ms)ms → s2 \(stage2Ran ? (stage2Threw ? "THREW" : "\"\(s2Title.prefix(28))\"") : "skipped") \(s2ms)ms")
        }

        rows.append(Round6ResultRow(
            nodeID: node.uuid, id8: node.id8, set: node.set,
            variant: v.name, promptVariant: v.promptVariant, guardrail: v.guardrail,
            contentSource: node.contentSource, contentLen: node.contentLen, sourceNote: node.note,
            stage1Prompt: s1Prompt, stage1Raw: stage1Raw,
            stage1Threw: stage1Threw, stage1Error: stage1Error,
            stage1SoftRefusal: soft, stage1Ms: s1ms,
            stage2Ran: stage2Ran, stage2Title: s2Title, stage2Summary: s2Summary, stage2Tags: s2Tags,
            stage2Threw: stage2Threw, stage2Error: stage2Error, stage2Ms: s2ms
        ))
    }
    return rows
}

// MARK: - Main

func runRound6() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let harnessDir = home.appendingPathComponent("Developer/AirPad/fm-diagnostic-harness")
    let nodesURL = harnessDir.appendingPathComponent("round6-nodes.json")

    print("=== Round 6 — free-text stage 1, Generable stage 2 ===")

    // STEP 0 (a): permissive guardrail option — verified present in the SDK
    // (SystemLanguageModel.Guardrails.permissiveContentTransformations). Both G1 and
    // G2 run. If it were absent we would run P1/P2 (G1 only) and say so; it is present.
    guard SystemLanguageModel.default.isAvailable else {
        print("ERROR: SystemLanguageModel.default not available (Apple Intelligence off / model not ready). Aborting.")
        return
    }
    let permissiveAvailable = makeModel(permissive: true).isAvailable
    print("default model available: true; permissive model available: \(permissiveAvailable)")

    let nodes: [Round6Node]
    do {
        let data = try Data(contentsOf: nodesURL)
        nodes = try JSONDecoder().decode([Round6Node].self, from: data)
    } catch {
        print("ERROR loading round6-nodes.json: \(error)")
        return
    }
    let refused = nodes.filter { $0.set == "REFUSED" }.count
    let control = nodes.filter { $0.set == "CONTROL" }.count
    print("Loaded \(nodes.count) nodes (\(refused) REFUSED, \(control) CONTROL) from round6-nodes.json.")

    let variants: [Round6Variant] = [
        .init(name: "A7a", promptVariant: "P1", guardrail: "G1-default",    permissive: false, directed: false),
        .init(name: "A7b", promptVariant: "P1", guardrail: "G2-permissive", permissive: true,  directed: false),
        .init(name: "A7c", promptVariant: "P2", guardrail: "G1-default",    permissive: false, directed: true),
        .init(name: "A7d", promptVariant: "P2", guardrail: "G2-permissive", permissive: true,  directed: true),
    ]

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]

    for v in variants {
        print("\n--- Variant \(v.name)  (\(v.promptVariant) / \(v.guardrail)) ---")
        let rows = await runRound6Variant(v, nodes: nodes)
        let outURL = harnessDir.appendingPathComponent("results-\(v.name).json")
        do {
            let data = try enc.encode(rows.sorted { ($0.set, $0.id8) < ($1.set, $1.id8) })
            try data.write(to: outURL)
            print("  wrote \(outURL.lastPathComponent) (\(rows.count) rows)")
        } catch {
            print("  ERROR writing \(outURL.lastPathComponent): \(error)")
        }
    }
    print("\nRound 6 complete. Generate summary-round6.md from results-A7*.json.")
}
