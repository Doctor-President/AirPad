import Foundation
import FoundationModels

// MARK: - Round 7 — Generable + permissive guardrails (isolate the guardrail/schema variable)
//
// Round 6 ran stage 2 (Generable) at DEFAULT guardrails in every variant. Production
// (AIService) also builds plain LanguageModelSession() everywhere, so permissive has
// NEVER been tested on a guided-generation call. The claim "permissiveContentTransformations
// does not apply to Generable" is a developer-forum report (secondary source), never
// verified against this SDK. Round 7 verifies it directly.
//
// SINGLE-STAGE: a direct Generable call on the RAW node content, production prompt
// (buildPrompt), no free-text stage. This isolates the guardrail (and, on the second
// axis, the output-schema size) against the raw-content baseline.
//
//   B1 = default guardrails,   full 5-field shape (reproduces the Round 5 baseline)
//   B2 = permissive guardrails, full 5-field shape (the untested cell — one variable vs B1)
//   B3 = permissive, MINIMAL shape (title + summary only)
//   B4 = permissive, title ONLY (single field)
//   B3/B4 share B2's prompt + guardrails; only the output schema shrinks.
//
// Mac harness — the device wins on prompt-behaviour verdicts. Not device-verified.
// Reuses round6-nodes.json (same 20 nodes; not re-derived), buildPrompt + vocabulary,
// and SummaryFirstStage1 (the Round 5 production shape) verbatim.

// MARK: - Shrunk schemas (title/summary @Guide strings verbatim from AIService.NodeAIResult)

/// B3 — minimal: title + summary only (this is exactly the current app `NodeAIResult` shape).
@Generable
struct R7TitleSummary {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String
    @Guide(description: "One to two sentence summary capturing the idea's core essence.")
    var summary: String
}

/// B4 — single field: title only.
@Generable
struct R7TitleOnly {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String
}

// MARK: - Output row

struct Round7ResultRow: Encodable {
    let nodeID: String
    let id8: String
    let set: String
    let variant: String        // B1..B4
    let guardrail: String      // "default" | "permissive"
    let schema: String         // "full-5field" | "title+summary" | "title-only"
    let contentSource: String
    let contentLen: Int
    let prompt: String         // the exact buildPrompt string sent
    let threw: Bool
    let error: String?         // FULL error description
    let elapsedMs: Int         // precise — sub-500ms throw = input-side; multi-second = generation-side
    let title: String          // FULL, untruncated
    let summary: String        // FULL, untruncated
    let tags: [String]
}

// MARK: - Typed call helpers (one variable is the schema)

struct R7Call {
    let threw: Bool; let error: String?; let ms: Int
    let title: String; let summary: String; let tags: [String]
}

private func r7Full(prompt: String, model: SystemLanguageModel) async -> R7Call {
    let start = Date()
    do {
        let s = LanguageModelSession(model: model)
        let r = try await s.respond(to: prompt, generating: SummaryFirstStage1.self).content
        return R7Call(threw: false, error: nil, ms: Int(Date().timeIntervalSince(start) * 1000),
                      title: r.title, summary: r.summary, tags: r.tags)
    } catch {
        return R7Call(threw: true, error: "\(type(of: error)): \(error)",
                      ms: Int(Date().timeIntervalSince(start) * 1000), title: "", summary: "", tags: [])
    }
}

private func r7TitleSummary(prompt: String, model: SystemLanguageModel) async -> R7Call {
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

private func r7TitleOnly(prompt: String, model: SystemLanguageModel) async -> R7Call {
    let start = Date()
    do {
        let s = LanguageModelSession(model: model)
        let r = try await s.respond(to: prompt, generating: R7TitleOnly.self).content
        return R7Call(threw: false, error: nil, ms: Int(Date().timeIntervalSince(start) * 1000),
                      title: r.title, summary: "", tags: [])
    } catch {
        return R7Call(threw: true, error: "\(type(of: error)): \(error)",
                      ms: Int(Date().timeIntervalSince(start) * 1000), title: "", summary: "", tags: [])
    }
}

// MARK: - Cells

struct R7Cell {
    let name: String        // B1..B4
    let guardrail: String   // default | permissive
    let schema: String      // full-5field | title+summary | title-only
    let permissive: Bool
    let kind: Int           // 0 full, 1 title+summary, 2 title-only
}

// MARK: - Main

func runRound7() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let harnessDir = home.appendingPathComponent("Developer/AirPad/fm-diagnostic-harness")

    print("=== Round 7 — Generable + permissive guardrails ===")
    guard SystemLanguageModel.default.isAvailable else {
        print("ERROR: SystemLanguageModel.default not available. Aborting.")
        return
    }
    let permissiveModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    print("default model available: true; permissive model available: \(permissiveModel.isAvailable)")

    let nodes: [Round6Node]
    do {
        let data = try Data(contentsOf: harnessDir.appendingPathComponent("round6-nodes.json"))
        nodes = try JSONDecoder().decode([Round6Node].self, from: data)
    } catch {
        print("ERROR loading round6-nodes.json: \(error)")
        return
    }
    print("Loaded \(nodes.count) nodes from round6-nodes.json (same set as Round 6).")

    let cells: [R7Cell] = [
        .init(name: "B1", guardrail: "default",    schema: "full-5field",   permissive: false, kind: 0),
        .init(name: "B2", guardrail: "permissive", schema: "full-5field",   permissive: true,  kind: 0),
        .init(name: "B3", guardrail: "permissive", schema: "title+summary", permissive: true,  kind: 1),
        .init(name: "B4", guardrail: "permissive", schema: "title-only",    permissive: true,  kind: 2),
    ]

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]

    for cell in cells {
        print("\n--- Cell \(cell.name)  (\(cell.guardrail) / \(cell.schema)) ---")
        let model = cell.permissive ? permissiveModel : SystemLanguageModel.default
        var rows: [Round7ResultRow] = []
        for (i, node) in nodes.enumerated() {
            let prompt = buildPrompt(content: node.content, vocabulary: vocabulary)
            print("  [\(cell.name)] \(i + 1)/\(nodes.count) \(node.id8) (\(node.set))…", terminator: " ")
            fflush(stdout)
            let r: R7Call
            switch cell.kind {
            case 1:  r = await r7TitleSummary(prompt: prompt, model: model)
            case 2:  r = await r7TitleOnly(prompt: prompt, model: model)
            default: r = await r7Full(prompt: prompt, model: model)
            }
            if r.threw {
                let side = r.ms < 500 ? "input-side" : "generation-side"
                print("THREW \(r.ms)ms (\(side))")
            } else {
                print("ok \(r.ms)ms \"\(r.title.prefix(30))\"")
            }
            rows.append(Round7ResultRow(
                nodeID: node.uuid, id8: node.id8, set: node.set,
                variant: cell.name, guardrail: cell.guardrail, schema: cell.schema,
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
    print("\nRound 7 complete. Generate summary-round7.md from results-B*.json.")
}
