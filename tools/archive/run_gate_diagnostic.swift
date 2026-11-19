#!/usr/bin/env swift

import Foundation

// MARK: - Gate Logic (duplicated from BatchParser and CorpusStore)

struct BatchParser {
    static let minChars = 50

    static func isFragment(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        // Short blocks (< 10 words) containing a pure reaction word
        if words.count < 10 {
            let stripped = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            if stripped.contains(where: { reactionWords.contains($0) }) {
                return true
            }
        }

        // Starts with an apology phrase
        if apologyPhrases.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        // Starts with a pure reaction phrase
        if reactionPhrases.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        // Short exclamation (≤ 5 words, ends with ! or !!)
        if words.count <= 5 && (text.hasSuffix("!") || text.hasSuffix("!!")) {
            return true
        }

        return false
    }

    private static let reactionWords: Set<String> = [
        "lol", "haha", "hahaha", "omg", "wtf", "wow", "damn", "lmao",
        "smh", "ffs", "bruh", "yikes", "oof", "ngl", "omfg", "rofl"
    ]

    private static let apologyPhrases = [
        "sorry", "my bad", "apologies", "forgive me", "excuse me",
        "i apologize", "i'm sorry", "so sorry"
    ]

    private static let reactionPhrases = [
        "wait what", "no way", "oh no", "oh wow", "oh man", "oh my",
        "that's crazy", "that is crazy", "can't believe", "cannot believe",
        "holy shit", "holy crap", "what the hell", "what the heck"
    ]
}

func escapeJSON(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

// MARK: - Main Test Runner

let corpusPath = NSHomeDirectory() + "/Desktop/AirPad/test_fixturess/corpus_test_master.md"
let logDateFormatter = DateFormatter()
logDateFormatter.dateFormat = "yyyyMMdd"
let logDate = logDateFormatter.string(from: Date())
let logPath = NSHomeDirectory() + "/Documents/AirPad/Logs/gate_diagnostic_\(logDate).log"

guard let rawText = try? String(contentsOfFile: corpusPath, encoding: .utf8) else {
    print("[DIAGNOSTIC] Failed to read test corpus at: \(corpusPath)")
    exit(1)
}

print("[DIAGNOSTIC] Loaded test corpus: \(rawText.count) chars")
print("[DIAGNOSTIC] Processing entries through gate...")

// Parse raw blocks
let rawBlocks = rawText
    .components(separatedBy: "\n\n")
    .map { block -> String in
        block
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[\\-•\\*]\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    .filter { !$0.isEmpty }

var logEntries: [String] = []
var stats = [
    "total": 0,
    "layer1_fail": 0,
    "layer2_fail": 0,
    "layer2_pass": 0,
    "would_invoke_layer3": 0
]

for block in rawBlocks {
    // Skip section headers
    if block.hasPrefix("## Section") || block.hasPrefix("# AirPad") {
        continue
    }

    stats["total"]! += 1

    let inputTruncated = String(block.prefix(150))
    let inputLength = block.count

    // Layer 1: Character threshold
    let layer1Pass = inputLength >= BatchParser.minChars
    let layer1Result = layer1Pass ? "pass" : "fail_too_short"

    if !layer1Pass {
        stats["layer1_fail"]! += 1
        let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_1_result\":\"\(layer1Result)\",\"layer_2_result\":\"skipped\",\"layer_3_invoked\":false,\"layer_3_result\":null,\"final_decision\":\"reject\",\"final_state\":\"silently_dropped\"}"
        logEntries.append(logLine)
        continue
    }

    // Layer 2: Heuristic fragment filter
    let layer2Pass = !BatchParser.isFragment(block)
    let layer2Result = layer2Pass ? "pass" : "fail_fragment"

    if layer2Pass {
        stats["layer2_pass"]! += 1
        stats["would_invoke_layer3"]! += 1
        // Would go to Layer 3 in real app (FM coherence check not available in script)
        let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_1_result\":\"\(layer1Result)\",\"layer_2_result\":\"\(layer2Result)\",\"layer_3_invoked\":false,\"layer_3_result\":\"not_available_in_script\",\"final_decision\":\"would_check_coherence\",\"final_state\":\"pending_layer3\"}"
        logEntries.append(logLine)
    } else {
        stats["layer2_fail"]! += 1
        let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_1_result\":\"\(layer1Result)\",\"layer_2_result\":\"\(layer2Result)\",\"layer_3_invoked\":false,\"layer_3_result\":null,\"final_decision\":\"reject\",\"final_state\":\"review_queue_heuristic\"}"
        logEntries.append(logLine)
    }
}

// Write log
do {
    let logContent = logEntries.joined(separator: "\n")
    try logContent.write(toFile: logPath, atomically: true, encoding: .utf8)
    print("[DIAGNOSTIC] Gate log written to: \(logPath)")
} catch {
    print("[DIAGNOSTIC] Failed to write log: \(error)")
    exit(1)
}

// Print summary
print("\n=== DIAGNOSTIC RUN SUMMARY ===")
print("Total entries processed: \(stats["total"]!)")
print("Layer 1 failures (< 50 chars): \(stats["layer1_fail"]!)")
print("Layer 2 failures (heuristic fragment): \(stats["layer2_fail"]!)")
print("Layer 2 passes (would invoke FM coherence): \(stats["would_invoke_layer3"]!)")
print("\nLog file: \(logPath)")
print("\nFirst 20 log lines:")
for line in logEntries.prefix(20) {
    print(line)
}
print("\n=== END SUMMARY ===")
