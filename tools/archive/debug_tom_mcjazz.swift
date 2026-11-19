#!/usr/bin/env swift

import Foundation

// MARK: - Minimal splitter + split detector

func splitText(_ text: String) -> [String] {
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

enum BinaryLabel: String {
    case yes, no
}

func detectSplitCandidate(_ text: String) -> BinaryLabel {
    let lines = text.components(separatedBy: .newlines)
    let bulletedLines = lines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "^[\\-•\\*]\\s+", options: .regularExpression) != nil
    }

    print("    DEBUG detectSplitCandidate:")
    print("      Total lines: \(lines.count)")
    print("      Bulleted lines found: \(bulletedLines.count)")
    if !bulletedLines.isEmpty {
        print("      First bulleted line: \(bulletedLines[0])")
    }

    if bulletedLines.count >= 2 {
        print("      → Result: YES (2+ bulleted lines)")
        return .yes
    }

    let paragraphs = text.components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let terminalPunctSet = CharacterSet(charactersIn: ".!?。！？")
    let completeParagraphs = paragraphs.filter { para in
        para.unicodeScalars.last.map { terminalPunctSet.contains($0) } ?? false
    }

    print("      Total paragraphs (split by \\n\\n): \(paragraphs.count)")
    print("      Paragraphs with terminal punct: \(completeParagraphs.count)")

    if completeParagraphs.count >= 2 {
        print("      → Result: YES (2+ complete paragraphs)")
        return .yes
    }

    print("      → Result: NO")
    return .no
}

// MARK: - Main

let corpusPath = "./test_fixtures/corpus_test_master.md"

guard let rawText = try? String(contentsOfFile: corpusPath, encoding: .utf8) else {
    print("[ERROR] Could not read corpus file")
    exit(1)
}

// Find the Tom McJazz section
let lines = rawText.components(separatedBy: .newlines)
var inTomSection = false
var tomSectionLines: [String] = []

for line in lines {
    if line.contains("## Section C — Tom McJazz") {
        inTomSection = true
        continue
    }
    if inTomSection {
        if line.hasPrefix("## Section") {
            break
        }
        tomSectionLines.append(line)
    }
}

let tomSection = tomSectionLines.joined(separator: "\n")

print("=== TOM MCJAZZ SECTION RAW TEXT ===")
print(String(tomSection.prefix(500)))
print("... (\(tomSection.count) total chars)")
print("")

print("=== AFTER SPLITTER ===")
let segments = splitText(tomSection)
print("Splitter produced \(segments.count) segments")
print("")

// Show first 5 segments
for (i, segment) in segments.prefix(5).enumerated() {
    print("--- Segment \(i+1) ---")
    print("Length: \(segment.count) chars")
    print("Text: \(String(segment.prefix(200)))")
    print("")

    // Run split detector on it
    let splitResult = detectSplitCandidate(segment)
    print("")
}

// Check if any segment has the pattern we're looking for
print("=== CHECKING FOR MULTI-IDEA PATTERNS ===")
for (i, segment) in segments.enumerated() {
    if segment.contains("Episode premise") && segments.indices.contains(i+1) && segments[i+1].contains("Episode premise") {
        print("Found consecutive 'Episode premise' entries at segments \(i) and \(i+1)")
        print("But they're SEPARATE segments (already split by ---)")
    }
}
