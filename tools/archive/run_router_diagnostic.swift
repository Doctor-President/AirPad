#!/usr/bin/env swift

import Foundation

// MARK: - BatchParser with Router (Session 2)

struct BatchParser {

    // MARK: - Layer 0

    enum Layer0Result {
        case pass(String)
        case filteredSeparator
        case filteredEmpty
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

    // MARK: - Layer 1

    enum LengthBucket: String {
        case micro, short, medium, long, veryLong
    }

    enum Format: String {
        case prose, fragment, listItem, url, hashtag, dateOnly, code, header, parenthetical, bracketedMetadata
    }

    enum Completeness: String {
        case terminalPunct, noTerminal
    }

    enum Capitalization: String {
        case startsCapital, startsLower, nonAlpha
    }

    struct Layer1Labels {
        let lengthBucket: LengthBucket
        let format: Format
        let completeness: Completeness
        let capitalization: Capitalization
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
        } else if detectFragmentSignals(text).completeThought == .no {
            format = .fragment
        } else {
            format = .prose
        }

        let terminalPunctSet = CharacterSet(charactersIn: ".!?。！？")
        let completeness: Completeness = text.unicodeScalars.last.map { terminalPunctSet.contains($0) } ?? false
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

    // MARK: - Layer 2

    enum BinaryLabel: String {
        case yes, no
    }

    enum TernaryLabel: String {
        case yes, borderline, no
    }

    struct Layer2Labels {
        let completeThought: TernaryLabel
        let verbPresent: BinaryLabel
        let multiIdeaSplitCandidate: BinaryLabel
        let noiseSignal: TernaryLabel
        let newTagVocabulary: BinaryLabel
        let sensitiveMaterial: BinaryLabel
    }

    static func classifyLayer2(_ text: String) -> Layer2Labels {
        let fragmentSignal = detectFragmentSignals(text)
        let splitCandidate = detectSplitCandidate(text)

        return Layer2Labels(
            completeThought: fragmentSignal.completeThought,
            verbPresent: .no,
            multiIdeaSplitCandidate: splitCandidate,
            noiseSignal: fragmentSignal.noiseSignal,
            newTagVocabulary: .no,
            sensitiveMaterial: .no
        )
    }

    static func detectFragmentSignals(_ text: String) -> (completeThought: TernaryLabel, noiseSignal: TernaryLabel) {
        let lower = text.lowercased()
        let words = lower.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        if words.count < 10 {
            let stripped = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            if stripped.contains(where: { reactionWords.contains($0) }) {
                return (completeThought: .no, noiseSignal: .yes)
            }
        }

        if apologyPhrases.contains(where: { lower.hasPrefix($0) }) {
            return (completeThought: .no, noiseSignal: .yes)
        }

        if reactionPhrases.contains(where: { lower.hasPrefix($0) }) {
            return (completeThought: .no, noiseSignal: .yes)
        }

        if words.count <= 5 && (text.hasSuffix("!") || text.hasSuffix("!!")) {
            return (completeThought: .no, noiseSignal: .yes)
        }

        return (completeThought: .yes, noiseSignal: .no)
    }

    static func detectSplitCandidate(_ text: String) -> BinaryLabel {
        let lines = text.components(separatedBy: .newlines)
        let bulletedLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.range(of: "^[\\-•\\*]\\s+", options: .regularExpression) != nil
        }
        if bulletedLines.count >= 2 {
            return .yes
        }

        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let terminalPunctSet = CharacterSet(charactersIn: ".!?。！？")
        let completeParagraphs = paragraphs.filter { para in
            para.unicodeScalars.last.map { terminalPunctSet.contains($0) } ?? false
        }

        if completeParagraphs.count >= 2 {
            return .yes
        }

        return .no
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

    // MARK: - Router

    enum RouterOutcome: String {
        case commitClean
        case commitWithReviewFlag
        case split
        case quarantine
        case deferToFM
    }

    static func route(text: String, l1: Layer1Labels, l2: Layer2Labels) -> (outcome: RouterOutcome, reason: String) {
        if l1.lengthBucket == .micro && l2.noiseSignal == .yes {
            return (.quarantine, "micro length with noise signal")
        }

        if l1.format == .hashtag {
            return (.quarantine, "standalone hashtag")
        }

        if l1.format == .header {
            return (.quarantine, "orphan markdown header")
        }

        if l1.format == .listItem {
            return (.quarantine, "orphan list item")
        }

        if l1.format == .dateOnly {
            return (.quarantine, "date-only entry")
        }

        if l1.format == .bracketedMetadata {
            return (.quarantine, "bracketed metadata")
        }

        if text.hasPrefix("Episode premise:") && text.count < 50 {
            return (.commitWithReviewFlag, "short episode premise")
        }

        if l1.format == .parenthetical {
            return (.commitWithReviewFlag, "standalone parenthetical")
        }

        if l1.format == .url {
            return (.commitWithReviewFlag, "standalone url")
        }

        if l2.multiIdeaSplitCandidate == .yes {
            return (.split, "multi-idea split candidate")
        }

        if l1.lengthBucket == .long && l1.format == .prose && l2.completeThought == .yes {
            return (.commitClean, "long prose with complete thought")
        }

        if l1.lengthBucket == .short && l1.format == .prose && l2.completeThought == .yes {
            return (.commitClean, "short prose with complete thought")
        }

        if l1.lengthBucket == .medium && l1.format == .prose && l2.completeThought == .yes {
            return (.commitClean, "medium prose with complete thought")
        }

        return (.deferToFM, "default case")
    }

    // MARK: - Splitter

    static func splitText(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var segments: [String] = []
        var currentSegment: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSeparator: Bool
            if trimmed.count >= 3 {
                let separatorChars = Set("-=*_")
                isSeparator = trimmed.allSatisfy { separatorChars.contains($0) }
            } else {
                isSeparator = false
            }

            if isSeparator {
                if !currentSegment.isEmpty {
                    segments.append(currentSegment.joined(separator: "\n"))
                    currentSegment = []
                }
            } else {
                currentSegment.append(line)
            }
        }

        if !currentSegment.isEmpty {
            segments.append(currentSegment.joined(separator: "\n"))
        }

        let finalSegments = segments.flatMap { segment in
            segment.components(separatedBy: "\n\n")
        }

        return finalSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Main

let corpusPath = "./test_fixtures/corpus_test_master.md"

guard let rawText = try? String(contentsOfFile: corpusPath, encoding: .utf8) else {
    print("[ERROR] Could not read corpus file at: \(corpusPath)")
    exit(1)
}

print("[DIAGNOSTIC] Loaded test corpus: \(rawText.count) chars")
print("[DIAGNOSTIC] Processing entries through L0→L1→L2→Router pipeline...")

let segments = BatchParser.splitText(rawText)

var stats: [String: Int] = [
    "total": 0,
    "l0_filtered": 0,
    "commit_clean": 0,
    "commit_review": 0,
    "quarantine": 0,
    "defer_fm": 0,
    "split": 0
]

var quarantineReasons: [String: Int] = [:]
var sampleOutputs: [(text: String, outcome: String, reason: String)] = []

for segment in segments {
    if segment.hasPrefix("## Section") || segment.hasPrefix("# AirPad") {
        continue
    }

    stats["total"]! += 1

    let l0Result = BatchParser.normalizeLayer0(segment)
    guard case .pass(let normalized) = l0Result else {
        stats["l0_filtered"]! += 1
        continue
    }

    let l1 = BatchParser.classifyLayer1(normalized)
    let l2 = BatchParser.classifyLayer2(normalized)
    let (outcome, reason) = BatchParser.route(text: normalized, l1: l1, l2: l2)

    switch outcome {
    case .commitClean:
        stats["commit_clean"]! += 1
        if stats["commit_clean"]! <= 5 {
            sampleOutputs.append((normalized, "commit_clean", reason))
        }
    case .commitWithReviewFlag:
        stats["commit_review"]! += 1
        if stats["commit_review"]! <= 5 {
            sampleOutputs.append((normalized, "commit_review", reason))
        }
    case .quarantine:
        stats["quarantine"]! += 1
        quarantineReasons[reason, default: 0] += 1
        if stats["quarantine"]! <= 5 {
            sampleOutputs.append((normalized, "quarantine", reason))
        }
    case .deferToFM:
        stats["defer_fm"]! += 1
        if stats["defer_fm"]! <= 3 {
            sampleOutputs.append((normalized, "defer_fm", reason))
        }
    case .split:
        stats["split"]! += 1
        if stats["split"]! <= 3 {
            sampleOutputs.append((normalized, "split", reason))
        }
    }
}

// Print summary
print("\n=== ROUTER DIAGNOSTIC RUN SUMMARY ===")
print("Total entries processed: \(stats["total"]!)")
print("Layer 0 filtered: \(stats["l0_filtered"]!)")
print("")
print("Router outcomes:")
print("  commit_clean: \(stats["commit_clean"]!)")
print("  commit_review: \(stats["commit_review"]!)")
print("  quarantine: \(stats["quarantine"]!)")
print("  defer_fm: \(stats["defer_fm"]!)")
print("  split: \(stats["split"]!)")
print("")
print("Quarantine breakdown:")
for (reason, count) in quarantineReasons.sorted(by: { $0.value > $1.value }) {
    print("  \(reason): \(count)")
}
print("")
print("Sample outputs (first few of each type):")
for sample in sampleOutputs {
    let preview = String(sample.text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
    print("  [\(sample.outcome)] \(preview)... (\(sample.reason))")
}
print("\n=== END SUMMARY ===")
