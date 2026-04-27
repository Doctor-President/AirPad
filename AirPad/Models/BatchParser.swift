import Foundation

/// Shared batch-text parser. Used by the main app (ImportIdeasSheet) and the share extension.
enum BatchParser {

    static let maxNodes = 200
    static let minChars = 50

    // MARK: - Quarantine storage

    /// In-memory store for quarantined entries. Thread-safe via lock.
    private static var quarantineStorage: [QuarantinedEntry] = []
    private static let quarantineLock = NSLock()

    /// Returns current quarantined entries (for UI display).
    static var quarantinedEntries: [QuarantinedEntry] {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        return quarantineStorage
    }

    /// Stores a quarantined entry.
    static func storeQuarantined(_ entry: QuarantinedEntry) {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        quarantineStorage.append(entry)
    }

    /// Removes entries older than 48 hours.
    static func pruneExpiredQuarantined() {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        let cutoff = Date().addingTimeInterval(-48 * 60 * 60)  // 48 hours ago
        quarantineStorage.removeAll { $0.importedAt < cutoff }
    }

    // MARK: - Public API

    /// Splits raw text into Node objects ready for import.
    /// Uses full L0→L1→L2→Router pipeline (Session 2).
    /// Returns at most `maxNodes` nodes.
    static func parse(text: String, importTimestamp: String) -> [Node] {
        let result = processText(text)

        // Create nodes from commit_clean (no review flag)
        var nodes = makeNodes(texts: result.commitClean, importTimestamp: importTimestamp, needsReview: false)

        // Create nodes from commit_review (with review flag)
        nodes.append(contentsOf: makeNodes(texts: result.commitWithReview, importTimestamp: importTimestamp, needsReview: true))

        // Create nodes from defer_fm (needs AI processing, no review flag yet)
        nodes.append(contentsOf: makeNodes(texts: result.deferredToFM, importTimestamp: importTimestamp, needsReview: false))

        // Store quarantined entries (NOT converted to nodes)
        for entry in result.quarantined {
            storeQuarantined(entry)
        }

        return Array(nodes.prefix(maxNodes))
    }

    /// Two-pass splitter: first splits on separator lines, then on \n\n within segments.
    /// A separator line is ≥3 chars exclusively from {-, =, *, _} after trimming whitespace.
    /// Drops empty segments.
    static func splitText(_ text: String) -> [String] {
        // Pass 1: Split on separator lines
        let lines = text.components(separatedBy: .newlines)
        var segments: [String] = []
        var currentSegment: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check if this line is a separator
            let isSeparator: Bool
            if trimmed.count >= 3 {
                let separatorSet = CharacterSet(charactersIn: "-=*_")
                isSeparator = trimmed.unicodeScalars.allSatisfy { separatorSet.contains($0) }
            } else {
                isSeparator = false
            }

            if isSeparator {
                // Separator line - flush current segment if non-empty
                if !currentSegment.isEmpty {
                    segments.append(currentSegment.joined(separator: "\n"))
                    currentSegment = []
                }
                // Don't include the separator line itself in any segment
            } else {
                currentSegment.append(line)
            }
        }

        // Flush final segment
        if !currentSegment.isEmpty {
            segments.append(currentSegment.joined(separator: "\n"))
        }

        // Pass 2: Within each segment, split on \n\n
        let finalSegments = segments.flatMap { segment in
            segment.components(separatedBy: "\n\n")
        }

        // Drop empty segments
        return finalSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Process raw text through the full L0→L1→L2→Router pipeline.
    /// Returns categorized results for each routing outcome.
    /// - Parameter depth: Recursion depth for split handling. Max depth is 1.
    static func processText(_ text: String, depth: Int = 0) -> ProcessingResult {
        let segments = splitText(text)
        let now = Date()

        var commitClean: [String] = []
        var commitWithReview: [String] = []
        var quarantined: [QuarantinedEntry] = []
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

            case .commitWithReviewFlag:
                commitWithReview.append(normalized)

            case .quarantine(let reason):
                let entry = QuarantinedEntry(
                    rawText: normalized,
                    l1Labels: l1,
                    reason: reason,
                    importedAt: now
                )
                quarantined.append(entry)

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

        // Apply maxNodes cap to committed entries
        let totalCommits = commitClean.count + commitWithReview.count
        if totalCommits > maxNodes {
            let cleanCount = min(commitClean.count, maxNodes)
            commitClean = Array(commitClean.prefix(cleanCount))
            commitWithReview = Array(commitWithReview.prefix(max(0, maxNodes - cleanCount)))
        }

        return ProcessingResult(
            commitClean: commitClean,
            commitWithReview: commitWithReview,
            quarantined: quarantined,
            deferredToFM: deferredToFM
        )
    }

    /// Constructs Node objects from pre-filtered text blocks.
    static func makeNodes(texts: [String], importTimestamp: String, needsReview: Bool = false) -> [Node] {
        let source = "import-\(importTimestamp)"
        let now = Date()
        return texts.map { blockText in
            let nodeID = UUID().uuidString
            let item = NodeItem(
                id: UUID().uuidString,
                type: .text,
                createdAt: now,
                content: blockText
            )
            return Node(
                id: nodeID,
                createdAt: now,
                updatedAt: now,
                title: "",
                summary: "",
                tags: [],
                items: [item],
                needsAIProcessing: true,
                needsReview: needsReview,
                source: source
            )
        }
    }

    /// Returns the number of parseable blocks (≥ minChars) without applying the cap.
    static func detectedCount(text: String) -> Int {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minChars }
            .count
    }

    // MARK: - Layer 0: Structural normalization

    enum Layer0Result {
        case pass(String)           // normalized text ready for L1
        case filteredSeparator      // separator-only line (---, ===, etc.)
        case filteredEmpty          // empty after normalization
    }

    // MARK: - Layer 1: Classification labels

    enum LengthBucket: String, Codable {
        case micro = "micro"             // 1-10
        case short = "short"             // 11-50
        case medium = "medium"           // 51-200
        case long = "long"               // 201-500
        case veryLong = "very_long"      // >500
    }

    enum Format: String, Codable {
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

    enum Completeness: String, Codable {
        case terminalPunct = "terminal_punct"
        case noTerminal = "no_terminal"
    }

    enum Capitalization: String, Codable {
        case startsCapital = "starts_capital"
        case startsLower = "starts_lower"
        case nonAlpha = "non_alpha"
    }

    struct Layer1Labels: Codable {
        let lengthBucket: LengthBucket
        let format: Format
        let completeness: Completeness
        let capitalization: Capitalization
    }

    /// Layer 1 classification: analyzes normalized text and returns structural labels.
    /// No pass/fail decision - just classification.
    static func classifyLayer1(_ text: String) -> Layer1Labels {
        let length = text.count

        // Length bucket
        let lengthBucket: LengthBucket
        switch length {
        case 1...10: lengthBucket = .micro
        case 11...50: lengthBucket = .short
        case 51...200: lengthBucket = .medium
        case 201...500: lengthBucket = .long
        default: lengthBucket = .veryLong
        }

        // Format detection (regex/structural)
        let format: Format
        if text.hasPrefix("#") && !text.contains(" ") {
            format = .hashtag
        } else if text.hasPrefix("[") && text.hasSuffix("]") {
            format = .bracketedMetadata
        } else if text.hasPrefix("(") && text.hasSuffix(")") {
            format = .parenthetical
        } else if text.hasPrefix("#") && text.contains(" ") {
            format = .header  // markdown header
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

        // Completeness - check for terminal punctuation
        let terminalPunctSet = CharacterSet(charactersIn: ".!?。！？")
        let completeness: Completeness = text.unicodeScalars.last.map { terminalPunctSet.contains($0) } ?? false
            ? .terminalPunct
            : .noTerminal

        // Capitalization - check first character
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

    /// Layer 0 normalization: filters separators and normalizes whitespace.
    /// A line is a separator if and only if, after stripping whitespace,
    /// it contains exclusively characters from {-, =, *, _} and is ≥3 chars.
    static func normalizeLayer0(_ text: String) -> Layer0Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty after trimming
        guard !trimmed.isEmpty else {
            return .filteredEmpty
        }

        // Check if separator-only (≥3 chars, exclusively from {-, =, *, _})
        if trimmed.count >= 3 {
            let separatorSet = CharacterSet(charactersIn: "-=*_")
            let allCharactersAreSeparators = trimmed.unicodeScalars.allSatisfy { separatorSet.contains($0) }
            if allCharactersAreSeparators {
                return .filteredSeparator
            }
        }

        return .pass(trimmed)
    }

    // MARK: - Layer 2: Semantic classification

    enum BinaryLabel: String {
        case yes = "yes"
        case no = "no"
    }

    enum TernaryLabel: String {
        case yes = "yes"
        case borderline = "borderline"
        case no = "no"
    }

    struct Layer2Labels {
        let completeThought: TernaryLabel
        let verbPresent: BinaryLabel
        let multiIdeaSplitCandidate: BinaryLabel
        let noiseSignal: TernaryLabel
        let newTagVocabulary: BinaryLabel
        let sensitiveMaterial: BinaryLabel
    }

    /// Layer 2 classification: semantic analysis of text.
    /// Returns structured labels for routing decisions.
    static func classifyLayer2(_ text: String) -> Layer2Labels {
        // completeThought & noiseSignal - derived from existing fragment heuristics
        let fragmentSignal = detectFragmentSignals(text)

        // multiIdeaSplitCandidate - basic detection
        let splitCandidate = detectSplitCandidate(text)

        // Stubs for future implementation
        let verbPresent: BinaryLabel = .no
        let newTagVocabulary: BinaryLabel = .no
        let sensitiveMaterial: BinaryLabel = .no

        return Layer2Labels(
            completeThought: fragmentSignal.completeThought,
            verbPresent: verbPresent,
            multiIdeaSplitCandidate: splitCandidate,
            noiseSignal: fragmentSignal.noiseSignal,
            newTagVocabulary: newTagVocabulary,
            sensitiveMaterial: sensitiveMaterial
        )
    }

    /// Detect if text is a candidate for splitting into multiple ideas.
    /// Returns .yes if: 2+ bulleted lines OR 2+ paragraphs each ending in terminal punctuation.
    private static func detectSplitCandidate(_ text: String) -> BinaryLabel {
        // Check for 2+ bulleted lines
        let lines = text.components(separatedBy: .newlines)
        let bulletedLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.range(of: "^[\\-•\\*]\\s+", options: .regularExpression) != nil
        }
        if bulletedLines.count >= 2 {
            return .yes
        }

        // Check for 2+ paragraphs with terminal punctuation
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

    /// Detect fragment signals (reaction words, apologies, etc.).
    /// Returns completeThought and noiseSignal labels.
    private static func detectFragmentSignals(_ text: String) -> (completeThought: TernaryLabel, noiseSignal: TernaryLabel) {
        let lower = text.lowercased()
        let words = lower
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        // Short blocks (< 10 words) containing a pure reaction word
        if words.count < 10 {
            let stripped = words.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            if stripped.contains(where: { reactionWords.contains($0) }) {
                return (completeThought: .no, noiseSignal: .yes)
            }
        }

        // Starts with an apology phrase
        if apologyPhrases.contains(where: { lower.hasPrefix($0) }) {
            return (completeThought: .no, noiseSignal: .yes)
        }

        // Starts with a pure reaction phrase
        if reactionPhrases.contains(where: { lower.hasPrefix($0) }) {
            return (completeThought: .no, noiseSignal: .yes)
        }

        // Short exclamation (≤ 5 words, ends with ! or !!)
        if words.count <= 5 && (text.hasSuffix("!") || text.hasSuffix("!!")) {
            return (completeThought: .no, noiseSignal: .yes)
        }

        // Default: complete thought, not noise
        return (completeThought: .yes, noiseSignal: .no)
    }

    // MARK: - Quarantine

    /// A text entry that has been quarantined (rejected from corpus).
    /// Stored separately from Nodes. Auto-deletes 48 hours after import.
    struct QuarantinedEntry: Codable {
        let rawText: String
        let l1Labels: Layer1Labels
        let reason: String
        let importedAt: Date
    }

    /// Result of processing text through the full pipeline.
    struct ProcessingResult {
        let commitClean: [String]           // Ready for Node creation
        let commitWithReview: [String]      // Node creation with needsReview=true
        let quarantined: [QuarantinedEntry] // Rejected entries
        let deferredToFM: [String]          // Needs FM processing to decide
    }

    // MARK: - Router

    enum RouterOutcome {
        case commitClean
        case commitWithReviewFlag
        case split([String])  // associated value: the split segments
        case quarantine(reason: String)
        case deferToFM
    }

    /// Routes a text entry based on L0+L1+L2 classification labels.
    /// Returns a RouterOutcome indicating how to handle the entry.
    static func route(text: String, l1: Layer1Labels, l2: Layer2Labels) -> RouterOutcome {
        // Apply routing rules from SB56 routing table

        // Rule: length=micro + noiseSignal=yes → quarantine
        if l1.lengthBucket == .micro && l2.noiseSignal == .yes {
            return .quarantine(reason: "micro length with noise signal")
        }

        // Rule: format=hashtag (alone) → quarantine
        if l1.format == .hashtag {
            return .quarantine(reason: "standalone hashtag")
        }

        // Rule: format=header (markdown orphan) → quarantine
        if l1.format == .header {
            return .quarantine(reason: "orphan markdown header")
        }

        // Rule: format=listItem (no parent context) → quarantine
        if l1.format == .listItem {
            return .quarantine(reason: "orphan list item")
        }

        // Rule: format=dateOnly → quarantine
        if l1.format == .dateOnly {
            return .quarantine(reason: "date-only entry")
        }

        // Rule: format=bracketedMetadata → quarantine
        if l1.format == .bracketedMetadata {
            return .quarantine(reason: "bracketed metadata")
        }

        // Rule: starts with "Episode premise:" + length<50 → commit_with_review_flag
        if text.hasPrefix("Episode premise:") && text.count < 50 {
            return .commitWithReviewFlag
        }

        // Rule: starts with "TikTok topic:" → commit_with_review_flag
        if text.hasPrefix("TikTok topic:") {
            return .commitWithReviewFlag
        }

        // Rule: format=parenthetical (alone) → commit_with_review_flag
        if l1.format == .parenthetical {
            return .commitWithReviewFlag
        }

        // Rule: format=url (alone) → commit_with_review_flag
        if l1.format == .url {
            return .commitWithReviewFlag
        }

        // Rule: L2 detects multiIdeaSplitCandidate=yes → split
        if l2.multiIdeaSplitCandidate == .yes {
            // For now, return split outcome with placeholder segments
            // Actual split execution is Session 3
            return .split([text])  // Placeholder - real splitting comes in Session 3
        }

        // Rule: length=long + format=prose + completeThought=yes → commit_clean
        if l1.lengthBucket == .long && l1.format == .prose && l2.completeThought == .yes {
            return .commitClean
        }

        // Rule: length=short + format=prose + completeThought=yes → commit_clean
        if l1.lengthBucket == .short && l1.format == .prose && l2.completeThought == .yes {
            return .commitClean
        }

        // Rule: length=medium + format=prose + completeThought=yes → commit_clean
        // (Not explicitly in table but follows the pattern)
        if l1.lengthBucket == .medium && l1.format == .prose && l2.completeThought == .yes {
            return .commitClean
        }

        // Default: Everything else → defer_to_fm
        return .deferToFM
    }

    // MARK: - Heuristic fragment detection (backward compatibility)

    /// Returns true if the block looks like a fragment (pure reaction, apology, exclamation)
    /// rather than a complete standalone idea.
    /// NOTE: This is now a wrapper around Layer 2's detectFragmentSignals.
    /// Use classifyLayer2 for new code.
    static func isFragment(_ text: String) -> Bool {
        let signals = detectFragmentSignals(text)
        return signals.completeThought == .no
    }

    // MARK: - Fragment signal sets

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

    // MARK: - Unit Tests

    /// Unit tests for separator-aware splitter.
    /// Returns (passed, failed) test names.
    static func testSplitter() -> (passed: [String], failed: [String]) {
        var passed: [String] = []
        var failed: [String] = []

        // Test 1: Separator with blank lines around it
        let test1 = "A\n\n---\n\nB"
        let result1 = splitText(test1)
        if result1.count == 2 && result1[0] == "A" && result1[1] == "B" {
            passed.append("separator_with_blank_lines")
        } else {
            failed.append("separator_with_blank_lines (got \(result1.count) segments: \(result1))")
        }

        // Test 2: Separator without blank lines
        let test2 = "A\n---\nB"
        let result2 = splitText(test2)
        if result2.count == 2 && result2[0] == "A" && result2[1] == "B" {
            passed.append("separator_without_blank_lines")
        } else {
            failed.append("separator_without_blank_lines (got \(result2.count) segments: \(result2))")
        }

        // Test 3: Separator at start
        let test3 = "---\nA"
        let result3 = splitText(test3)
        if result3.count == 1 && result3[0] == "A" {
            passed.append("separator_at_start")
        } else {
            failed.append("separator_at_start (got \(result3.count) segments: \(result3))")
        }

        // Test 4: Separator at end
        let test4 = "A\n---"
        let result4 = splitText(test4)
        if result4.count == 1 && result4[0] == "A" {
            passed.append("separator_at_end")
        } else {
            failed.append("separator_at_end (got \(result4.count) segments: \(result4))")
        }

        return (passed, failed)
    }
}
