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
        var out = scored
        var perSrc: [Int: Int] = [:], n = 0, chars = 0
        for i in out.indices.sorted(by: { out[$0].score > out[$1].score }) {
            let p = out[i]
            guard p.score >= floor, n < topK, perSrc[p.source, default: 0] < perSource, chars + p.text.count <= budget else { continue }
            out[i].kept = true; n += 1; chars += p.text.count; perSrc[p.source, default: 0] += 1
        }
        return out
    }

    /// The characters of passages the model sees: the Host / server turn, and Apple's smaller window.
    static let hostBudget = 3_000
    /// How much of a read page's text joins the rerank.
    static let pageChars = 6_000
    static let appleBudget = 1_500
}
