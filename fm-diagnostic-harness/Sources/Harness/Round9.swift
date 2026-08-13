import Foundation
import FoundationModels

// MARK: - Round 9 — enum tags without the vocabulary line + locale check
//
// Round 8 implicated the 72-tag vocabulary LINE injected into buildPrompt(). Round 2's
// A2 used a @Generable enum (VocabularyTag) for tags — but A2 carried the enum AND the
// prompt line together. Enum WITHOUT the line has never been run.
//
// Open question: are @Generable enum CASE NAMES scored by the input classifier the way
// prompt text is? If NO, constrained decoding gives the vocabulary back with zero
// classifier surface (D3 ≈ D4). If YES, the enum is not a fix (D3 throws more than D4).
//
// FIXED: default guardrails everywhere; single-stage; raw node content; same 20 nodes
// (round6-nodes.json, not re-sourced). Mac harness — the device wins on prompt-behaviour.
//
//   D1 = BASELINE   — buildPrompt WITH vocab line; tags:[String]           (Round 8 C1, re-run)
//   D2 = ENUM+LINE  — buildPrompt WITH vocab line; tags:[VocabularyTag]     (replicates Round 2 A2)
//   D3 = ENUM,NOLINE— buildPromptC2 (no vocab line); tags:[VocabularyTag]   ★ the untested headline cell
//   D4 = NOTAGS     — buildPromptC2 (no vocab line); title+summary only     (Round 8 C2 floor)
//
// STEP 0 (locale) is reported out-of-band: this Mac is AppleLocale=en_US,
// AppleLanguages primary=en-US, Siri/Apple-Intelligence Session Language=en-US — already
// en_US, so the forum-802921 non-en_US second pass is skipped per the brief.

// MARK: - Schemas (title/summary/tags @Guide strings = Round 2 A1/A2, verbatim)

/// D1 — String tags (production-style free-form).
@Generable
struct R9StringTags {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String
    @Guide(description: "One to two sentence summary capturing the idea's core essence.")
    var summary: String
    @Guide(description: "Tag names from the provided vocabulary that are genuinely relevant to this content. Return an empty array if no existing tag clearly applies — do not force a match. Return at most 5 tags. Prefer broad domain tags from the vocabulary over highly specific descriptors.")
    var tags: [String]
}

/// D2 / D3 — enum tags (VocabularyTag reused verbatim from Vocabulary.swift; not redefined).
@Generable
struct R9EnumTags {
    @Guide(description: "Concise idea title, under 60 characters. Functional, not poetic.")
    var title: String
    @Guide(description: "One to two sentence summary capturing the idea's core essence.")
    var summary: String
    @Guide(description: "Tag names from the provided vocabulary that are genuinely relevant to this content. Return an empty array if no existing tag clearly applies — do not force a match. Return at most 5 tags. Prefer broad domain tags from the vocabulary over highly specific descriptors.")
    var tags: [VocabularyTag]
}

// MARK: - Typed call helpers (default guardrails)

private func r9StringTags(prompt: String) async -> R7Call {
    let start = Date()
    do {
        let s = LanguageModelSession()
        let r = try await s.respond(to: prompt, generating: R9StringTags.self).content
        return R7Call(threw: false, error: nil, ms: Int(Date().timeIntervalSince(start) * 1000),
                      title: r.title, summary: r.summary, tags: r.tags)
    } catch {
        return R7Call(threw: true, error: "\(type(of: error)): \(error)",
                      ms: Int(Date().timeIntervalSince(start) * 1000), title: "", summary: "", tags: [])
    }
}

private func r9EnumTags(prompt: String) async -> R7Call {
    let start = Date()
    do {
        let s = LanguageModelSession()
        let r = try await s.respond(to: prompt, generating: R9EnumTags.self).content
        return R7Call(threw: false, error: nil, ms: Int(Date().timeIntervalSince(start) * 1000),
                      title: r.title, summary: r.summary, tags: r.tags.map { $0.rawValue })
    } catch {
        return R7Call(threw: true, error: "\(type(of: error)): \(error)",
                      ms: Int(Date().timeIntervalSince(start) * 1000), title: "", summary: "", tags: [])
    }
}

private func r9TitleSummary(prompt: String) async -> R7Call {
    let start = Date()
    do {
        let s = LanguageModelSession()
        let r = try await s.respond(to: prompt, generating: R7TitleSummary.self).content
        return R7Call(threw: false, error: nil, ms: Int(Date().timeIntervalSince(start) * 1000),
                      title: r.title, summary: r.summary, tags: [])
    } catch {
        return R7Call(threw: true, error: "\(type(of: error)): \(error)",
                      ms: Int(Date().timeIntervalSince(start) * 1000), title: "", summary: "", tags: [])
    }
}

// MARK: - Main

func runRound9() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let harnessDir = home.appendingPathComponent("Developer/AirPad/fm-diagnostic-harness")

    print("=== Round 9 — enum tags without the vocabulary line ===")
    print("STEP 0 locale: AppleLocale=\(Locale.current.identifier); already en_US → single pass.")
    guard SystemLanguageModel.default.isAvailable else {
        print("ERROR: SystemLanguageModel.default not available. Aborting.")
        return
    }

    let nodes: [Round6Node]
    do {
        let data = try Data(contentsOf: harnessDir.appendingPathComponent("round6-nodes.json"))
        nodes = try JSONDecoder().decode([Round6Node].self, from: data)
    } catch {
        print("ERROR loading round6-nodes.json: \(error)")
        return
    }
    print("Loaded \(nodes.count) nodes from round6-nodes.json (same set as Rounds 6–8).")

    // (cell, schema label, prompt builder, call kind). One change at a time D1→D2→D3→D4.
    struct Cell { let name: String; let schema: String; let prompt: (String) -> String; let kind: Int }
    let cells: [Cell] = [
        // kind: 0 String-tags, 1 enum-tags, 2 title+summary
        Cell(name: "D1", schema: "title+summary+tags[String]", prompt: { buildPrompt(content: $0, vocabulary: vocabulary) }, kind: 0),
        Cell(name: "D2", schema: "title+summary+tags[enum]",   prompt: { buildPrompt(content: $0, vocabulary: vocabulary) }, kind: 1),
        Cell(name: "D3", schema: "title+summary+tags[enum]",   prompt: { buildPromptC2(content: $0) },                       kind: 1),
        Cell(name: "D4", schema: "title+summary",              prompt: { buildPromptC2(content: $0) },                       kind: 2),
    ]

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]

    for cell in cells {
        print("\n--- Cell \(cell.name)  (\(cell.schema)) ---")
        var rows: [Round7ResultRow] = []
        for (i, node) in nodes.enumerated() {
            let prompt = cell.prompt(node.content)
            print("  [\(cell.name)] \(i + 1)/\(nodes.count) \(node.id8) (\(node.set))…", terminator: " ")
            fflush(stdout)
            let r: R7Call
            switch cell.kind {
            case 1:  r = await r9EnumTags(prompt: prompt)
            case 2:  r = await r9TitleSummary(prompt: prompt)
            default: r = await r9StringTags(prompt: prompt)
            }
            if r.threw {
                print("THREW \(r.ms)ms (\(r.ms < 500 ? "input-side" : "generation-side"))")
            } else {
                print("ok \(r.ms)ms \"\(r.title.prefix(24))\" tags=\(r.tags)")
            }
            rows.append(Round7ResultRow(
                nodeID: node.uuid, id8: node.id8, set: node.set,
                variant: cell.name, guardrail: "default", schema: cell.schema,
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
    print("\nRound 9 complete. Generate summary-round9.md from results-D*.json.")
}
