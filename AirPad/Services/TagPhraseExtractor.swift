import Foundation
import NaturalLanguage

/// THE TAG PRODUCER — Step 2 (ws-lever.md § STEP 1.5, measured 2026-08-06). Pulls
/// short noun phrases from a node's RAW text so the "already yours" matcher can run
/// with the FM disabled entirely. This is the Step-1.5 Mac diagnostic ported
/// verbatim — the exact method the coverage/quality numbers were measured against
/// (96% of nodes yield a phrase; 57% of no-folksonomy nodes get a ≥0.80 proposal).
///
/// ★ Method: `NLTagger` lexical class, `.word` unit, punctuation/whitespace/other
/// omitted. Maximal runs of (Adjective|Noun)⁺ ending in a Noun → the run capped to
/// its last 3 words, PLUS each individual noun. Deterministic, no model, nothing
/// that can refuse.
enum TagPhraseExtractor {

    /// Contentless nouns dropped as standalone candidates (the run they sit in can
    /// still be emitted). Kept identical to the measured Step-1.5 set.
    static let stopNouns: Set<String> = [
        "thing", "things", "stuff", "way", "ways", "lot", "bit", "one", "part", "kind",
        "type", "time", "times", "day", "days", "today", "yesterday", "tomorrow",
        "someone", "something", "anything", "everything", "nothing", "people", "person",
        "idea", "ideas", "point", "case", "fact", "number", "end", "side",
    ]

    /// Extract lowercased noun phrases from `text`.
    ///
    /// `minNounLength` is the floor for STANDALONE nouns (multi-word runs are always
    /// kept). ⚠️ Set it from the shortest EXISTING tag name (§ STEP 1.5 acronym fix)
    /// so a 2-char tag like `AI` — which the old ≥4 rule silently dropped — is
    /// reachable. Runs are unaffected, so `3D Print` matches via the `3d print` run
    /// regardless.
    static func phrases(from text: String, minNounLength: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        let floor = max(2, minNounLength)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther]

        var out: [String] = []
        var run: [String] = []
        func flush() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let phrase = (run.count <= 3 ? run : Array(run.suffix(3))).joined(separator: " ")
            out.append(phrase)
            for w in run where w.count >= floor { out.append(w) }   // individual nouns too
        }

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lexicalClass, options: opts) { tag, range in
            let word = String(text[range]).lowercased()
            if let tag, tag == .noun || tag == .adjective, word.count >= 2,
               word.rangeOfCharacter(from: .letters) != nil {
                run.append(word)
            } else {
                flush()
            }
            return true
        }
        flush()

        // clean · filter · dedup (preserve first-seen order)
        var seen = Set<String>()
        var result: [String] = []
        for raw in out {
            let p = raw.trimmingCharacters(in: .whitespaces)
            guard p.count >= 3, !stopNouns.contains(p) else { continue }
            if seen.insert(p).inserted { result.append(p) }
        }
        return result
    }
}
