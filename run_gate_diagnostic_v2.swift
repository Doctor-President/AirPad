#!/usr/bin/env swift

import Foundation

// MARK: - Gate Logic (updated to match BatchParser Layer 0 + Layer 1)

struct BatchParser {
    static let minChars = 50

    enum Layer0Result {
        case pass(String)
        case filteredSeparator
        case filteredEmpty
    }

    enum LengthBucket: String {
        case micro = "micro"
        case short = "short"
        case medium = "medium"
        case long = "long"
        case veryLong = "very_long"
    }

    enum Format: String {
        case prose = "prose"
        case fragment = "fragment"
        case listItem = "list_item"
        case url = "url"
        case hashtag = "hashtag"
        case dateOnly = "date_only"
        case code = "code"
        case header = "header"
        case parenthetical = "parenthetical"
        case bracketedMetadata = "bracketed_metadata"
    }

    enum Completeness: String {
        case terminalPunct = "terminal_punct"
        case noTerminal = "no_terminal"
    }

    enum Capitalization: String {
        case startsCapital = "starts_capital"
        case startsLower = "starts_lower"
        case nonAlpha = "non_alpha"
    }

    struct Layer1Labels {
        let lengthBucket: LengthBucket
        let format: Format
        let completeness: Completeness
        let capitalization: Capitalization
    }

    static func normalizeLayer0(_ text: String) -> Layer0Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .filteredEmpty
        }

        if trimmed.count >= 3 {
            let separatorChars = Set("-=*_")
            let allCharactersAreSeparators = trimmed.allSatisfy { separatorChars.contains($0) }
            if allCharactersAreSeparators {
                return .filteredSeparator
            }
        }

        return .pass(trimmed)
    }

    static func classifyLayer1(_ text: String) -> Layer1Labels {
        let length = text.count

        let lengthBucket: LengthBucket
        switch length {
        case 1...10: lengthBucket = .micro
        case 11...50: lengthBucket = .short
        case 51...200: lengthBucket = .medium
        case 201...500: lengthBucket = .long
        default: lengthBucket = .veryLong
        }

        let format: Format
        if text.hasPrefix("#") && !text.contains(" ") {
            format = .hashtag
        } else if text.hasPrefix("[") && text.hasSuffix("]") {
            format = .bracketedMetadata
        } else if text.hasPrefix("(") && text.hasSuffix(")") {
            format = .parenthetical
        } else if text.hasPrefix("#") && text.contains(" ") {
            format = .header
        } else if text.range(of: "^(https?://|www\\.)", options: .regularExpression) != nil {
            format = .url
        } else if text.range(of: "^[\\-•\\*]\\s+", options: .regularExpression) != nil {
            format = .listItem
        } else if text.range(of: "^\\d{1,2}/\\d{1,2}(/\\d{2,4})?$", options: .regularExpression) != nil {
            format = .dateOnly
        } else if text.range(of: "^```|^\\s{4,}|^\\t", options: .regularExpression) != nil {
            format = .code
        } else if isFragment(text) {
            format = .fragment
        } else {
            format = .prose
        }

        let terminalPunctSet = Set(".!?。！？")
        let completeness: Completeness = text.last.map { terminalPunctSet.contains($0) } ?? false
            ? .terminalPunct
            : .noTerminal

        let capitalization: Capitalization
        if let first = text.first {
            if first.isUppercase {
                capitalization = .startsCapital
            } else if first.isLowercase {
                capitalization = .startsLower
            } else {
                capitalization = .nonAlpha
            }
        } else {
            capitalization = .nonAlpha
        }

        return Layer1Labels(
            lengthBucket: lengthBucket,
            format: format,
            completeness: completeness,
            capitalization: capitalization
        )
    }

    static func isFragment(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        if words.count < 10 {
            let stripped = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            if stripped.contains(where: { reactionWords.contains($0) }) {
                return true
            }
        }

        if apologyPhrases.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        if reactionPhrases.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

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

let corpusPath = NSHomeDirectory() + "/Desktop/AirPad/test_fixtures/corpus_test_master.md"
let logDateFormatter = DateFormatter()
logDateFormatter.dateFormat = "yyyyMMdd"
let logDate = logDateFormatter.string(from: Date())
let logPath = NSHomeDirectory() + "/Documents/AirPad/Logs/gate_diagnostic_\(logDate)_v2.log"

guard let rawText = try? String(contentsOfFile: corpusPath, encoding: .utf8) else {
    print("[DIAGNOSTIC] Failed to read test corpus at: \(corpusPath)")
    exit(1)
}

print("[DIAGNOSTIC] Loaded test corpus: \(rawText.count) chars")
print("[DIAGNOSTIC] Processing entries through Layer 0 + Layer 1 gate...")

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
    "layer0_filtered": 0,
    "layer1_dropped": 0,
    "layer2_fail": 0,
    "layer2_pass": 0
]

for block in rawBlocks {
    if block.hasPrefix("## Section") || block.hasPrefix("# AirPad") {
        continue
    }

    stats["total"]! += 1

    // Layer 0
    let layer0Result = BatchParser.normalizeLayer0(block)

    switch layer0Result {
    case .filteredSeparator:
        stats["layer0_filtered"]! += 1
        let inputTruncated = String(block.prefix(150))
        let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(block.count),\"layer_0_result\":\"filtered_separator\",\"layer_1_length_bucket\":null,\"layer_1_format\":null,\"layer_1_completeness\":null,\"layer_1_capitalization\":null,\"layer_2_result\":\"skipped\",\"layer_3_invoked\":false,\"layer_3_result\":null,\"final_decision\":\"reject\",\"final_state\":\"filtered_layer_0\"}"
        logEntries.append(logLine)

    case .filteredEmpty:
        stats["layer0_filtered"]! += 1
        let inputTruncated = String(block.prefix(150))
        let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(block.count),\"layer_0_result\":\"filtered_empty\",\"layer_1_length_bucket\":null,\"layer_1_format\":null,\"layer_1_completeness\":null,\"layer_1_capitalization\":null,\"layer_2_result\":\"skipped\",\"layer_3_invoked\":false,\"layer_3_result\":null,\"final_decision\":\"reject\",\"final_state\":\"filtered_layer_0\"}"
        logEntries.append(logLine)

    case .pass(let normalizedText):
        // Layer 1
        let layer1Labels = BatchParser.classifyLayer1(normalizedText)
        let inputTruncated = String(normalizedText.prefix(150))
        let inputLength = normalizedText.count

        // Behavior preservation shim
        let shouldDropPerOldLogic = inputLength < BatchParser.minChars

        if shouldDropPerOldLogic {
            stats["layer1_dropped"]! += 1
            let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_0_result\":\"pass\",\"layer_1_length_bucket\":\"\(layer1Labels.lengthBucket.rawValue)\",\"layer_1_format\":\"\(layer1Labels.format.rawValue)\",\"layer_1_completeness\":\"\(layer1Labels.completeness.rawValue)\",\"layer_1_capitalization\":\"\(layer1Labels.capitalization.rawValue)\",\"layer_2_result\":\"skipped\",\"layer_3_invoked\":false,\"layer_3_result\":null,\"final_decision\":\"reject\",\"final_state\":\"silently_dropped\"}"
            logEntries.append(logLine)
        } else {
            // Layer 2
            let layer2Pass = !BatchParser.isFragment(normalizedText)
            let layer2Result = layer2Pass ? "pass" : "fail_fragment"

            if layer2Pass {
                stats["layer2_pass"]! += 1
                let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_0_result\":\"pass\",\"layer_1_length_bucket\":\"\(layer1Labels.lengthBucket.rawValue)\",\"layer_1_format\":\"\(layer1Labels.format.rawValue)\",\"layer_1_completeness\":\"\(layer1Labels.completeness.rawValue)\",\"layer_1_capitalization\":\"\(layer1Labels.capitalization.rawValue)\",\"layer_2_result\":\"\(layer2Result)\",\"layer_3_invoked\":false,\"layer_3_result\":\"not_available_in_script\",\"final_decision\":\"would_check_coherence\",\"final_state\":\"pending_layer3\"}"
                logEntries.append(logLine)
            } else {
                stats["layer2_fail"]! += 1
                let logLine = "{\"input_text\":\"\(escapeJSON(inputTruncated))\",\"input_length\":\(inputLength),\"layer_0_result\":\"pass\",\"layer_1_length_bucket\":\"\(layer1Labels.lengthBucket.rawValue)\",\"layer_1_format\":\"\(layer1Labels.format.rawValue)\",\"layer_1_completeness\":\"\(layer1Labels.completeness.rawValue)\",\"layer_1_capitalization\":\"\(layer1Labels.capitalization.rawValue)\",\"layer_2_result\":\"\(layer2Result)\",\"layer_3_invoked\":false,\"layer_3_result\":null,\"final_decision\":\"reject\",\"final_state\":\"review_queue_heuristic\"}"
                logEntries.append(logLine)
            }
        }
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
print("\n=== DIAGNOSTIC RUN SUMMARY (Layer 0 + Layer 1) ===")
print("Total entries processed: \(stats["total"]!)")
print("Layer 0 filtered (separators/empty): \(stats["layer0_filtered"]!)")
print("Layer 1 dropped (< 50 chars, behavior shim): \(stats["layer1_dropped"]!)")
print("Layer 2 failures (heuristic fragment): \(stats["layer2_fail"]!)")
print("Layer 2 passes (would invoke FM coherence): \(stats["layer2_pass"]!)")
print("\nLog file: \(logPath)")
print("\nFirst 20 log lines:")
for line in logEntries.prefix(20) {
    print(line)
}
print("\n=== END SUMMARY ===")
