#!/usr/bin/env swift

import Foundation

// MARK: - BatchParser (Live pipeline from Session 3)

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

    enum RouterOutcome {
        case commitClean
        case commitWithReviewFlag(reason: String)
        case split([String])  // child segments
        case quarantine(reason: String)
        case deferToFM
    }

    static func route(text: String, l1: Layer1Labels, l2: Layer2Labels) -> RouterOutcome {
        if l1.lengthBucket == .micro && l2.noiseSignal == .yes {
            return .quarantine(reason: "micro length with noise signal")
        }

        if l1.format == .hashtag {
            return .quarantine(reason: "standalone hashtag")
        }

        if l1.format == .header {
            return .quarantine(reason: "orphan markdown header")
        }

        if l1.format == .listItem {
            return .quarantine(reason: "orphan list item")
        }

        if l1.format == .dateOnly {
            return .quarantine(reason: "date-only entry")
        }

        if l1.format == .bracketedMetadata {
            return .quarantine(reason: "bracketed metadata")
        }

        if text.hasPrefix("Episode premise:") && text.count < 50 {
            return .commitWithReviewFlag(reason: "short episode premise")
        }

        if text.hasPrefix("TikTok topic:") {
            return .commitWithReviewFlag(reason: "short topic stub")
        }

        if l1.format == .parenthetical {
            return .commitWithReviewFlag(reason: "standalone parenthetical")
        }

        if l1.format == .url {
            return .commitWithReviewFlag(reason: "standalone url")
        }

        if l2.multiIdeaSplitCandidate == .yes {
            // Actually split it
            let childSegments = splitMultiIdea(text)
            return .split(childSegments)
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

    /// Split multi-idea entries into child segments
    static func splitMultiIdea(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        let bulletedLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.range(of: "^[\\-•\\*]\\s+", options: .regularExpression) != nil
        }

        // If we have 2+ bulleted lines, split by bullets
        if bulletedLines.count >= 2 {
            return lines.compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.range(of: "^[\\-•\\*]\\s+", options: .regularExpression) != nil {
                    // Remove bullet marker
                    let withoutBullet = trimmed.replacingOccurrences(of: "^[\\-•\\*]\\s+", with: "", options: .regularExpression)
                    return withoutBullet.isEmpty ? nil : withoutBullet
                }
                return nil
            }
        }

        // Otherwise try splitting by double newline (paragraphs)
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.count >= 2 {
            return paragraphs
        }

        // Fallback: return as single segment
        return [text]
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

    // MARK: - Live processText with split execution (Session 3)

    struct ProcessingResult {
        let commitClean: [String]
        let commitWithReview: [String]
        let quarantined: [(text: String, reason: String)]
        let deferredToFM: [String]
    }

    static func processText(_ text: String, depth: Int = 0) -> ProcessingResult {
        let segments = splitText(text)

        var commitClean: [String] = []
        var commitWithReview: [String] = []
        var quarantined: [(text: String, reason: String)] = []
        var deferredToFM: [String] = []

        for segment in segments {
            // Layer 0: normalization
            let l0Result = normalizeLayer0(segment)
            guard case .pass(let normalized) = l0Result else {
                // Filtered by L0 (separator or empty) - skip
                continue
            }

            // Layer 1: classification
            let l1 = classifyLayer1(normalized)

            // Layer 2: semantic labels
            let l2 = classifyLayer2(normalized)

            // Router: decide outcome
            let outcome = route(text: normalized, l1: l1, l2: l2)

            switch outcome {
            case .commitClean:
                commitClean.append(normalized)

            case .commitWithReviewFlag(let reason):
                commitWithReview.append(normalized)

            case .quarantine(let reason):
                quarantined.append((normalized, reason))

            case .deferToFM:
                deferredToFM.append(normalized)

            case .split(let childSegments):
                // Recursion depth limit: max 1 level
                if depth > 0 {
                    // Already at max depth — route to deferToFM instead of splitting again
                    deferredToFM.append(contentsOf: childSegments)
                } else {
                    // Re-enter pipeline for each child segment
                    for child in childSegments {
                        let childResult = processText(child, depth: depth + 1)
                        commitClean.append(contentsOf: childResult.commitClean)
                        commitWithReview.append(contentsOf: childResult.commitWithReview)
                        quarantined.append(contentsOf: childResult.quarantined)
                        deferredToFM.append(contentsOf: childResult.deferredToFM)
                    }
                }
            }
        }

        return ProcessingResult(
            commitClean: commitClean,
            commitWithReview: commitWithReview,
            quarantined: quarantined,
            deferredToFM: deferredToFM
        )
    }
}

// MARK: - Diagnostic Entry Logging

struct DiagnosticEntry {
    let entryNumber: Int
    let inputText: String
    let l0Result: String
    let l1: BatchParser.Layer1Labels?
    let l2: BatchParser.Layer2Labels?
    let routerOutcome: String
    let reason: String
    let childCount: Int?
}

// MARK: - Main

let corpusPath = "./test_fixtures/corpus_test_master.md"

guard let rawText = try? String(contentsOfFile: corpusPath, encoding: .utf8) else {
    print("[ERROR] Could not read corpus file at: \(corpusPath)")
    exit(1)
}

print("=== SESSION 4 DIAGNOSTIC: LIVE PIPELINE VERIFICATION ===")
print("Loaded test corpus: \(rawText.count) chars")
print("Processing through live BatchParser.processText() with split execution...")
print("")

// Split into initial segments
let segments = BatchParser.splitText(rawText)
var diagnosticLog: [DiagnosticEntry] = []

// Stats
var totalEntriesProcessed = 0
var l0Filtered = 0
var commitCleanCount = 0
var commitReviewCount = 0
var splitCount = 0
var totalChildSegments = 0
var quarantineCount = 0
var deferFMCount = 0

var quarantineReasons: [String: Int] = [:]
var reviewReasons: [String: Int] = [:]

for (index, segment) in segments.enumerated() {
    // Skip section headers
    if segment.hasPrefix("## Section") || segment.hasPrefix("# AirPad") || segment.hasPrefix("**Purpose:**") || segment.hasPrefix("**Target node") || segment.hasPrefix("**Composition:") {
        continue
    }

    totalEntriesProcessed += 1
    let entryNum = totalEntriesProcessed

    // Layer 0
    let l0Result = BatchParser.normalizeLayer0(segment)

    if case .filteredEmpty = l0Result {
        l0Filtered += 1
        diagnosticLog.append(DiagnosticEntry(
            entryNumber: entryNum,
            inputText: segment,
            l0Result: "filtered_empty",
            l1: nil,
            l2: nil,
            routerOutcome: "filtered",
            reason: "empty after normalization",
            childCount: nil
        ))
        continue
    }

    if case .filteredSeparator = l0Result {
        l0Filtered += 1
        diagnosticLog.append(DiagnosticEntry(
            entryNumber: entryNum,
            inputText: segment,
            l0Result: "filtered_separator",
            l1: nil,
            l2: nil,
            routerOutcome: "filtered",
            reason: "separator line",
            childCount: nil
        ))
        continue
    }

    guard case .pass(let normalized) = l0Result else {
        continue
    }

    // Layer 1 & 2
    let l1 = BatchParser.classifyLayer1(normalized)
    let l2 = BatchParser.classifyLayer2(normalized)

    // Router
    let outcome = BatchParser.route(text: normalized, l1: l1, l2: l2)

    var outcomeStr = ""
    var reason = ""
    var childCount: Int? = nil

    switch outcome {
    case .commitClean:
        commitCleanCount += 1
        outcomeStr = "commit_clean"
        reason = "passed clean"

    case .commitWithReviewFlag(let r):
        commitReviewCount += 1
        outcomeStr = "commit_review"
        reason = r
        reviewReasons[r, default: 0] += 1

    case .quarantine(let r):
        quarantineCount += 1
        outcomeStr = "quarantine"
        reason = r
        quarantineReasons[r, default: 0] += 1

    case .deferToFM:
        deferFMCount += 1
        outcomeStr = "defer_fm"
        reason = "default fallthrough"

    case .split(let children):
        splitCount += 1
        childCount = children.count
        totalChildSegments += children.count
        outcomeStr = "split"
        reason = "multi-idea split candidate"

        // Log parent entry
        diagnosticLog.append(DiagnosticEntry(
            entryNumber: entryNum,
            inputText: normalized,
            l0Result: "pass",
            l1: l1,
            l2: l2,
            routerOutcome: "split",
            reason: reason,
            childCount: childCount
        ))

        // Process each child through the pipeline (depth=1)
        for (childIdx, child) in children.enumerated() {
            let childResult = BatchParser.processText(child, depth: 1)

            // Count child outcomes
            commitCleanCount += childResult.commitClean.count
            commitReviewCount += childResult.commitWithReview.count
            quarantineCount += childResult.quarantined.count
            deferFMCount += childResult.deferredToFM.count

            for q in childResult.quarantined {
                quarantineReasons[q.reason, default: 0] += 1
            }

            // Log child segments
            print("  Entry #\(entryNum) SPLIT → child[\(childIdx+1)/\(children.count)]: \(String(child.prefix(60)).replacingOccurrences(of: "\n", with: " "))...")
            print("    → clean: \(childResult.commitClean.count), review: \(childResult.commitWithReview.count), quarantine: \(childResult.quarantined.count), defer_fm: \(childResult.deferredToFM.count)")
        }

        continue  // Already logged, skip the append below
    }

    diagnosticLog.append(DiagnosticEntry(
        entryNumber: entryNum,
        inputText: normalized,
        l0Result: "pass",
        l1: l1,
        l2: l2,
        routerOutcome: outcomeStr,
        reason: reason,
        childCount: childCount
    ))
}

// Print detailed log
print("\n=== DETAILED PER-ENTRY LOG ===\n")
for entry in diagnosticLog.prefix(20) {  // Show first 20 for readability
    let preview = String(entry.inputText.prefix(80)).replacingOccurrences(of: "\n", with: " ")
    print("Entry #\(entry.entryNumber): \(preview)...")
    print("  L0: \(entry.l0Result)")
    if let l1 = entry.l1 {
        print("  L1: length=\(l1.lengthBucket.rawValue), format=\(l1.format.rawValue), completeness=\(l1.completeness.rawValue), cap=\(l1.capitalization.rawValue)")
    }
    if let l2 = entry.l2 {
        print("  L2: completeThought=\(l2.completeThought.rawValue), multiIdeaSplit=\(l2.multiIdeaSplitCandidate.rawValue), noiseSignal=\(l2.noiseSignal.rawValue)")
    }
    print("  Router: \(entry.routerOutcome)")
    if !entry.reason.isEmpty {
        print("    Reason: \(entry.reason)")
    }
    if let count = entry.childCount {
        print("    Child segments: \(count)")
    }
    print("")
}

if diagnosticLog.count > 20 {
    print("... (\(diagnosticLog.count - 20) more entries logged)")
    print("")
}

// Print aggregate summary
print("\n=== AGGREGATE SUMMARY ===")
print("")
print("Total entries processed: \(totalEntriesProcessed)")
print("Layer 0 filtered (separators + empty): \(l0Filtered)")
print("")
print("Router outcomes:")
print("  commit_clean: \(commitCleanCount)")
print("  commit_review: \(commitReviewCount)")
print("  split: \(splitCount) (produced \(totalChildSegments) child segments)")
print("  quarantine: \(quarantineCount)")
print("  defer_fm: \(deferFMCount)")
print("")
print("Quarantine breakdown:")
for (reason, count) in quarantineReasons.sorted(by: { $0.value > $1.value }) {
    print("  \(reason): \(count)")
}
print("")
print("Review flag breakdown:")
for (reason, count) in reviewReasons.sorted(by: { $0.value > $1.value }) {
    print("  \(reason): \(count)")
}
print("")
print("=== Comparison to SB56 predictions ===")
print("")
print("| Outcome        | SB56 Predicted | Session 2 Actual | Session 4 Target | Session 4 Actual |")
print("| commit_clean   | ~44            | ~39              | 39-44            | \(commitCleanCount)           |")
print("| commit_review  | ~12            | 9                | 9-12             | \(commitReviewCount)            |")
print("| quarantine     | ~13            | 3                | ~13              | \(quarantineCount)            |")
print("| defer_fm       | remainder      | ~171             | same or lower    | \(deferFMCount)           |")
print("| split          | N/A            | N/A              | N/A              | \(splitCount) → \(totalChildSegments) children |")
print("")
print("=== END SESSION 4 DIAGNOSTIC ===")
