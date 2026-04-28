#!/usr/bin/env swift

import Foundation

// MARK: - Copy of BatchParser pipeline

struct BatchParser {

    enum Layer0Result {
        case pass(String)
        case filteredSeparator
        case filteredEmpty
    }

    static func normalizeLayer0(_ text: String) -> Layer0Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .filteredEmpty }
        if trimmed.count >= 3 {
            let separatorChars = Set("-=*_")
            let allCharactersAreSeparators = trimmed.allSatisfy { separatorChars.contains($0) }
            if allCharactersAreSeparators { return .filteredSeparator }
        }
        return .pass(trimmed)
    }

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
            ? .terminalPunct : .noTerminal

        let capitalization: Capitalization
        if let first = text.first {
            if first.isUppercase { capitalization = .startsCapital }
            else if first.isLowercase { capitalization = .startsLower }
            else { capitalization = .nonAlpha }
        } else {
            capitalization = .nonAlpha
        }

        return Layer1Labels(lengthBucket: lengthBucket, format: format, completeness: completeness, capitalization: capitalization)
    }

    enum BinaryLabel: String { case yes, no }
    enum TernaryLabel: String { case yes, borderline, no }

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
        if bulletedLines.count >= 2 { return .yes }

        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let terminalPunctSet = CharacterSet(charactersIn: ".!?。！？")
        let completeParagraphs = paragraphs.filter { para in
            para.unicodeScalars.last.map { terminalPunctSet.contains($0) } ?? false
        }

        if completeParagraphs.count >= 2 { return .yes }
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

    enum RouterOutcome {
        case commitClean
        case commitWithReviewFlag(reason: String)
        case split([String])
        case quarantine(reason: String)
        case deferToFM
    }

    static func route(text: String, l1: Layer1Labels, l2: Layer2Labels) -> RouterOutcome {
        if l1.lengthBucket == .micro && l2.noiseSignal == .yes {
            return .quarantine(reason: "micro length with noise signal")
        }
        if l1.format == .hashtag { return .quarantine(reason: "standalone hashtag") }
        if l1.format == .header { return .quarantine(reason: "orphan markdown header") }
        if l1.format == .listItem { return .quarantine(reason: "orphan list item") }
        if l1.format == .dateOnly { return .quarantine(reason: "date-only entry") }
        if l1.format == .bracketedMetadata { return .quarantine(reason: "bracketed metadata") }

        if text.hasPrefix("Episode premise:") && text.count < 50 {
            return .commitWithReviewFlag(reason: "short episode premise")
        }
        if l1.format == .parenthetical { return .commitWithReviewFlag(reason: "standalone parenthetical") }
        if l1.format == .url { return .commitWithReviewFlag(reason: "standalone url") }

        if l2.multiIdeaSplitCandidate == .yes {
            return .split([text])  // simplified
        }

        if l1.lengthBucket == .long && l1.format == .prose && l2.completeThought == .yes {
            return .commitClean
        }
        if l1.lengthBucket == .short && l1.format == .prose && l2.completeThought == .yes {
            return .commitClean
        }
        if l1.lengthBucket == .medium && l1.format == .prose && l2.completeThought == .yes {
            return .commitClean
        }

        return .deferToFM
    }

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
    print("[ERROR] Could not read corpus file")
    exit(1)
}

let segments = BatchParser.splitText(rawText)

struct CleanEntry {
    let text: String
    let l1: BatchParser.Layer1Labels
    let l2: BatchParser.Layer2Labels
}

var cleanEntries: [CleanEntry] = []

for segment in segments {
    if segment.hasPrefix("## Section") || segment.hasPrefix("# AirPad") || segment.hasPrefix("**Purpose:") || segment.hasPrefix("**Target node") || segment.hasPrefix("**Composition:") {
        continue
    }

    let l0Result = BatchParser.normalizeLayer0(segment)
    guard case .pass(let normalized) = l0Result else { continue }

    let l1 = BatchParser.classifyLayer1(normalized)
    let l2 = BatchParser.classifyLayer2(normalized)
    let outcome = BatchParser.route(text: normalized, l1: l1, l2: l2)

    if case .commitClean = outcome {
        cleanEntries.append(CleanEntry(text: normalized, l1: l1, l2: l2))
    }
}

print("=== COMMIT_CLEAN SAMPLE: 15 DIVERSE ENTRIES ===")
print("Total commit_clean entries: \(cleanEntries.count)")
print("")

// Get diverse sample: micro, short, medium, long, veryLong
let microEntries = cleanEntries.filter { $0.l1.lengthBucket == .micro }
let shortEntries = cleanEntries.filter { $0.l1.lengthBucket == .short }
let mediumEntries = cleanEntries.filter { $0.l1.lengthBucket == .medium }
let longEntries = cleanEntries.filter { $0.l1.lengthBucket == .long }
let veryLongEntries = cleanEntries.filter { $0.l1.lengthBucket == .veryLong }

print("Breakdown by length:")
print("  micro (1-10): \(microEntries.count)")
print("  short (11-50): \(shortEntries.count)")
print("  medium (51-200): \(mediumEntries.count)")
print("  long (201-500): \(longEntries.count)")
print("  veryLong (>500): \(veryLongEntries.count)")
print("")

var sample: [CleanEntry] = []

// Take 2 from each bucket if available
sample.append(contentsOf: microEntries.prefix(2))
sample.append(contentsOf: shortEntries.prefix(3))
sample.append(contentsOf: mediumEntries.prefix(4))
sample.append(contentsOf: longEntries.prefix(3))
sample.append(contentsOf: veryLongEntries.prefix(3))

for (i, entry) in sample.prefix(15).enumerated() {
    print("--- Entry \(i+1) ---")
    print("Length bucket: \(entry.l1.lengthBucket.rawValue) (\(entry.text.count) chars)")
    print("Format: \(entry.l1.format.rawValue)")
    print("Completeness: \(entry.l1.completeness.rawValue)")
    print("Capitalization: \(entry.l1.capitalization.rawValue)")
    print("L2 completeThought: \(entry.l2.completeThought.rawValue)")
    print("L2 noiseSignal: \(entry.l2.noiseSignal.rawValue)")
    print("")
    print("Text:")
    if entry.text.count > 400 {
        print(String(entry.text.prefix(400)).replacingOccurrences(of: "\n", with: "\n  "))
        print("  ... (\(entry.text.count - 400) more chars)")
    } else {
        print("  " + entry.text.replacingOccurrences(of: "\n", with: "\n  "))
    }
    print("")
}
