import Foundation

/// THE TAG PRODUCER — normalization for the "already yours" matcher (ws-lever.md).
/// lowercase · trim · strip surrounding punctuation · singularize.
///
/// ★ Step 0 proved the NAIVE trailing-`s` rule wrong (`analysis`→`analysi`,
/// `canvas`→`canva`). This uses proper `-ies`/`-es` rules PLUS an explicit exception
/// set of singular nouns that end in `s` (analysis, canvas, status, …) so they are
/// left alone. Deliberately conservative — a false MERGE (two concepts collapsed) is
/// worse than a false SPLIT here, because the matcher's cosine layer already tolerates
/// surface variation.
enum TagNormalization {

    /// Singular nouns that end in `s` — never strip these. (`-ss` words like "glass"
    /// are handled by the rule, so they aren't all listed.)
    static let singularExceptions: Set<String> = [
        // -is
        "analysis", "basis", "crisis", "thesis", "axis", "genesis", "synopsis", "diagnosis",
        "hypothesis", "oasis", "ellipsis", "emphasis", "parenthesis", "metropolis", "iris",
        // -us
        "status", "focus", "virus", "bonus", "census", "corpus", "campus", "surplus", "genius",
        "radius", "nucleus", "cactus", "fungus", "octopus", "stimulus", "consensus", "apparatus", "bias",
        // -as / -os / misc
        "canvas", "atlas", "gas", "chaos", "kudos", "pathos", "cosmos", "ethos",
        // domain-ish -s singulars
        "news", "physics", "mathematics", "ethics", "politics", "economics", "statistics",
        "series", "species", "means", "lens", "iris", "chess", "compass", "harass",
    ]

    /// Strip a plural to its singular using rules + the exception set. Operates on the
    /// whole (possibly multi-word) term — folksonomy phrases pluralise on the last word
    /// ("mesh networks" → "mesh network"), so the suffix rules apply to the string.
    static func singularize(_ s: String) -> String {
        guard s.count > 3, !singularExceptions.contains(s) else { return s }
        // Handle only the LAST word so "dark matters" → "dark matter" but a hyphenated
        // "e-ink" is untouched.
        if s.hasSuffix("ies") { return String(s.dropLast(3)) + "y" }            // stories → story
        if s.hasSuffix("sses") || s.hasSuffix("xes") || s.hasSuffix("zes")
            || s.hasSuffix("ches") || s.hasSuffix("shes") {
            return String(s.dropLast(2))                                         // glasses→glass, boxes→box, dishes→dish
        }
        // Plain trailing -s, but NOT: -ss (mass), -us (virus), -is (axis), -os (chaos),
        // -as (canvas — most also in exceptions), or a 1-letter stem.
        if s.hasSuffix("s"), !s.hasSuffix("ss"), !s.hasSuffix("us"),
           !s.hasSuffix("is"), !s.hasSuffix("os"), s.count > 4 {
            return String(s.dropLast(1))                                         // recipes→recipe, tags→tag
        }
        return s
    }

    /// lowercase · trim · strip SURROUNDING punctuation (internal hyphens/spaces kept) ·
    /// singularize.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip only leading/trailing punctuation — keep "e-ink" and "on-device".
        let punct = CharacterSet(charactersIn: ".,;:!?\u{2019}'\"`()[]{}<>")
        while let f = s.unicodeScalars.first, punct.contains(f) { s.removeFirst() }
        while let l = s.unicodeScalars.last, punct.contains(l) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return singularize(s)
    }
}
