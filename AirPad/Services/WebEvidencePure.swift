import Foundation

/// live-33 — the pure parts of the web pipeline (`WebEvidence`: Foundation only), so the macOS harness
/// (`scripts/fm_chat_harness`, `pipeline`) compiles exactly what the app runs: the sources and passages, the floor and
/// the selection, the last-resort query.
enum WebEvidence {

    /// One fetched source before the rerank.
    struct Source: Sendable {
        let title: String
        let url: String
        let published: Date?
        let wikipedia: Bool
        let text: String
    }

    /// One scored passage (the trace and the self-test read these).
    struct Scored: Sendable {
        let source: Int
        let text: String
        let score: Float
        var kept: Bool
    }

    /// DEBUG `-Live32Web YES` — live-32's query and evidence (the RED baseline for the live-33 rows): the question as the
    /// query on a first turn, every result passed whole (no rerank). Always false in Release.
    static var live32: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "Live32Web")
        #else
        false
        #endif
    }

    /// The question with its request words removed ("Can you print for me a table of the last 10 US presidents up until
    /// today" → "the last 10 US presidents up until today"): the last resort, never the raw sentence.
    static func strippedQuestion(_ q: String) -> String {
        var t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = #"^(?:(?:hey|hi|ok|okay|so|and|please|pls|kindly)[,!]?\s+)*(?:(?:can|could|would|will) you\s+(?:please\s+)?|i(?:'d| would) like (?:you )?to\s+|i want (?:you )?to\s+|help me\s+)?(?:(?:print|show|make|give|get|find|list|tell|write|create|draw up|put together|build|generate|search(?: the web)? for|look up)\s+)?(?:(?:me|us)\s+|for me\s+)?(?:(?:a|an|the)\s+)?(?:(?:table|list|chart|rundown|summary|timeline|overview)\s+of\s+)?"#
        t = t.replacingOccurrences(of: lead, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s*(?:,?\s*please)?[?.!]+$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return t.isEmpty ? q : t
    }

    /// A passage: about two to four sentences.
    static let passageChars = 420
    /// The floor a passage's similarity to the query must clear; the best `topK` above it are kept. Calibrated on the
    /// live-33 runs (BGE-micro's cosines are compressed): off-topic passages 0.42–0.58 (a car-buying page 0.42–0.50); on-topic
    /// ones 0.64–0.91 — the lead sentence "The incumbent president is Donald Trump…" scored 0.66 for one rewrite. The floor
    /// drops the off-topic; it can't tell on-topic from junk a bad query brings (≤ 0.71) — the query step is the fix for that.
    static var floor: Float {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "WebRerankFloor"), let f = Float(s) { return f }
        #endif
        return 0.60
    }
    /// How many passages the model sees, at most, and how many from one source.
    static let topK = 6
    static let perSource = 3

    /// The text split into passages on sentence boundaries (a sentence longer than a passage is cut at a word).
    static func passages(_ text: String, size: Int = passageChars) -> [String] {
        var out: [String] = [], cur = ""
        for para in text.components(separatedBy: "\n") {
            for s in sentences(para) {
                var s = s
                while s.count > size {   // a run-on (a list, a table row dump): cut at a space
                    let cut = s.prefix(size).lastIndex(of: " ") ?? s.index(s.startIndex, offsetBy: size)
                    if !cur.isEmpty { out.append(cur); cur = "" }
                    out.append(String(s[..<cut]).trimmingCharacters(in: .whitespaces))
                    s = String(s[cut...]).trimmingCharacters(in: .whitespaces)
                }
                if cur.count + s.count + 1 > size, !cur.isEmpty { out.append(cur); cur = "" }
                cur += (cur.isEmpty ? "" : " ") + s
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { $0.count >= 12 }   // only fragments go: a short last sentence can be the answer ("Ilsa Vane took office.")
    }

    static func sentences(_ s: String) -> [String] {
        let flat = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty, let re = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z0-9"“(])"#) else { return flat.isEmpty ? [] : [flat] }
        var out: [String] = []; var start = flat.startIndex
        for m in re.matches(in: flat, range: NSRange(flat.startIndex..., in: flat)) {
            guard let r = Range(m.range, in: flat) else { continue }
            out.append(String(flat[start..<r.lowerBound])); start = r.upperBound
        }
        out.append(String(flat[start...]))
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }

    /// The selection, pure (the self-test drives it with fixed scores): passages at or above the floor, best first, at most
    /// `topK` and `perSource` per source, within `budget` characters. Returns the kept flags.
    static func select(_ scored: [Scored], floor: Float, budget: Int) -> [Scored] {
        select(scored, floor: floor, budget: Budget(chars: budget, topK: topK, perSource: perSource, label: "fixed"))
    }
    static func select(_ scored: [Scored], floor: Float, budget b: Budget) -> [Scored] {
        var out = scored
        var perSrc: [Int: Int] = [:], n = 0, chars = 0
        for i in out.indices.sorted(by: { out[$0].score > out[$1].score }) {
            let p = out[i]
            guard p.score >= floor, n < b.topK, perSrc[p.source, default: 0] < b.perSource, chars + p.text.count <= b.chars else { continue }
            out[i].kept = true; n += 1; chars += p.text.count; perSrc[p.source, default: 0] += 1
        }
        return out
    }

    /// live-37 (2) — how much evidence the model sees, sized to its window (live-36: "cut by top-k / budget" was the largest
    /// loss stage on every Host tier while prompts used ~10% of the Host's 20,480 and Apple a median 649 of 4,096 tokens).
    /// Tokens of passages: Apple on-device ~450, the 4B / 8B ~1,200, the 30B-A3B ~2,000 (live-38b, T ruled speed: live-37's
    /// 2,000 / 6,000 / 10,000 took the 4B's first word from 5.7 to 15.7 s; halving them left it at 15.5 s because few turns
    /// filled the budget). Characters per token measured on the smoke runs (Ops `design-refs/live37-2026-10-22/`).
    struct Budget: Sendable, Equatable {
        let chars: Int
        let topK: Int
        /// Sane for a two-entity question (live-36: the UN + NATO question lost Rutte to a cap of 3 per source and 6 in all).
        let perSource: Int
        let label: String
    }
    static let appleTokens = 450, hostSmallTokens = 1_200, hostLargeTokens = 2_000
    /// Apple's tokenizer on the evidence text, measured on the first retrieval-only smoke run (`tokenCount(for:)`, 14
    /// searched turns): 2.9–3.6 characters a token, ~3.4 overall. Qwen's: from the Host's prompt_eval on the answer run.
    static let appleCharsPerToken = 3.4, qwenCharsPerToken = 4.0
    static func budget(tokens: Int, charsPerToken: Double, label: String) -> Budget {
        let chars = Int(Double(tokens) * charsPerToken)
        let k = max(topK, chars / (passageChars * 3 / 4))   // passages run ~¾ of `passageChars`
        return Budget(chars: chars, topK: k, perSource: max(perSource, k / 3), label: label)
    }
    /// Apple Intelligence on-device (4,096-token window).
    static var appleWebBudget: Budget {
        Live37.selection ? budget(tokens: appleTokens, charsPerToken: appleCharsPerToken, label: "apple ~\(appleTokens) tok")
            : Budget(chars: appleBudget, topK: topK, perSource: perSource, label: "live-36 apple")
    }
    /// A Host / server model by its tag: the 30B-A3B class (≥ 14B parameters, or an MoE "a3b") gets the larger budget.
    static func hostWebBudget(model: String?) -> Budget {
        guard Live37.selection else { return Budget(chars: hostBudget, topK: topK, perSource: perSource, label: "live-36 host") }
        let m = (model ?? "").lowercased()
        let size = m.range(of: #"(\d+(\.\d+)?)b"#, options: .regularExpression).flatMap { Double(m[$0].dropLast()) } ?? 0
        return size >= 14 ? budget(tokens: hostLargeTokens, charsPerToken: qwenCharsPerToken, label: "host large ~\(hostLargeTokens) tok")
            : budget(tokens: hostSmallTokens, charsPerToken: qwenCharsPerToken, label: "host ~\(hostSmallTokens) tok")
    }

    /// live-37 (2) — the order the model reads the sources in: the best first, the second best LAST, and so on inward
    /// (models use the start and the end of a long context best — "lost in the middle"). `ranked` is best first.
    static func edgesFirst<T>(_ ranked: [T]) -> [T] {
        guard Live37.selection, ranked.count > 2 else { return ranked }
        var front: [T] = [], back: [T] = []
        for (i, x) in ranked.enumerated() { if i % 2 == 0 { front.append(x) } else { back.insert(x, at: 0) } }
        return front + back
    }

    /// live-37 (3) — page boilerplate: navigation, menus, link lists, footer text ("Skip Navigation Markets Pre-Markets
    /// U.S.", "Markets Currencies … Funds & ETFs Business Economy" outranked "iPhone 18 Pro will start at $1,199" in
    /// live-36). The jusText-style test (Pomikálek 2011, the standard boilerplate classifier): a block of text that is
    /// mostly short capitalised fragments with almost no function words isn't prose. Figures keep a passage (a table row
    /// of names and years has no function words either: "Joe Biden 2021 2025 Democratic").
    static func isBoilerplate(_ passage: String) -> Bool {
        let words = passage.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        let digits = words.filter { $0.contains(where: \.isNumber) }.count
        if Double(digits) / Double(words.count) >= 0.12 { return false }
        let stop = words.filter { stopwords.contains($0) }.count
        let density = Double(stop) / Double(words.count)
        // a short fragment: a menu item, a button, a breadcrumb — unless it ends like a sentence ("Ilsa Vane took office.")
        let sentence = passage.trimmingCharacters(in: .whitespaces).range(of: #"[a-z0-9)%]["”’)]?[.!?]$"#, options: .regularExpression) != nil
        if words.count < 8 { return density < 0.15 && !sentence }
        return density < 0.10
    }
    static let stopwords: Set<String> = ["the", "a", "an", "of", "to", "in", "is", "was", "and", "for", "on", "with", "at", "by",
        "from", "as", "are", "were", "be", "been", "has", "have", "had", "it", "its", "that", "this", "which", "who", "he", "she",
        "they", "his", "her", "their", "will", "would", "not", "but", "or", "after", "before", "since", "into", "than", "also",
        "can", "about", "over", "more", "when", "while", "there", "these", "those", "said", "says", "did", "does", "do", "one"]

    /// The characters of passages the model sees: the Host / server turn, and Apple's smaller window.
    static let hostBudget = 3_000
    /// How much of a read page's text joins the rerank.
    static let pageChars = 6_000
    static let appleBudget = 1_500
}

/// live-37 — the three fixes, each on unless DEBUG `-Live37Off query,selection,boilerplate` (`rerank` = boilerplate, `all`) turns it off (the RED baselines; the
/// smoke runs measure each step). Always on in Release.
enum Live37 {
    static func on(_ name: String) -> Bool {
        #if DEBUG
        return !(UserDefaults.standard.string(forKey: "Live37Off") ?? "").split(separator: ",").contains { $0 == name || $0 == "all" }
        #else
        return true
        #endif
    }
    /// (1) the rewrite may not add names or numbers; a shorter rewrite timeout; "until today" isn't news.
    static var query: Bool { on("query") }
    /// (2) the evidence budget sized to the model; best sources first and last.
    static var selection: Bool { on("selection") }
    /// (3) boilerplate passages out (`boilerplate`).
    static var boilerplate: Bool { on("rerank") && on("boilerplate") }
    /// (3) the passage embedded without its page title — OFF (DEBUG `-Live37TitleOut YES` turns it on). Measured on the
    /// smoke runs: it lowers every passage's score (median 0.69 → 0.63) against a floor calibrated WITH titles, so 81–88%
    /// of passages cleared the floor before and 62–68% after; the Wikipedia lead "The incumbent president is Donald Trump…"
    /// fell to 0.593 (the self-test row). Recall: Apple 12 → 13, 4B 14 → 13 (neither attributable). The menus it was for
    /// are dropped by the boilerplate test (≈30 passages a run; the iPhone price passes on both tiers without it). Taking
    /// the title out needs the floor recalibrated first — a call for the next round.
    static var titleOut: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "Live37TitleOut")
        #else
        return false
        #endif
    }
}
