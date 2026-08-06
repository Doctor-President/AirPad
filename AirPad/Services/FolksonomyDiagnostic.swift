import Foundation
import CoreML

#if DEBUG
/// THE TAG PRODUCER — Step 0 (ws-lever.md). READ-ONLY corpus diagnostic: walks
/// `store.nodes`' `folksonomy` + `store.tags` and reports coverage · recurrence ·
/// long tail · fragmentation · tag overlap; then embeds the tag names + top recurring
/// terms via the shipped BGE-micro (`CardEmbeddingService`'s model + WordPiece vocab,
/// 384-dim L2-normalized) for the nearest-tag cosine calibration.
///
/// ★ WRITES NOTHING — no tag created, no proposal recorded, no node mutated, no
/// normalization applied to stored data. Gate 0. Launch-arg gated
/// (`-FolksonomyDiagnostic`), `#if DEBUG` only.
///
/// The cosine section reads its strings from `store` when populated (on-device); on an
/// empty store (e.g. the Simulator) it falls back to `Documents/folk_cosine_input.json`
/// (`{"tags":[…],"terms":[…]}`) so the calibration can be run against T's real
/// vocabulary + the real model off-device. ★ The model is loaded `.cpuOnly` here:
/// `CardEmbeddingService`'s `.all` returns zeros on the Simulator; CPU is exact.
enum FolksonomyDiagnostic {

    /// lowercase · trim · strip surrounding punctuation · simple plural→singular.
    /// (Deliberately the SIMPLE rule from the brief — its false positives, e.g.
    /// "analysis"→"analysi", are themselves a finding.)
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard s.count > 4 else { return s }
        if s.hasSuffix("ies") { s = String(s.dropLast(3)) + "y" }
        else if s.hasSuffix("sses") { s = String(s.dropLast(2)) }
        else if s.hasSuffix("es"), let c = s.dropLast(2).last, "shxzo".contains(c) { s = String(s.dropLast(2)) }
        else if s.hasSuffix("s"), !s.hasSuffix("ss") { s = String(s.dropLast(1)) }
        return s
    }

    private struct CosineInput: Decodable { let tags: [String]; let terms: [String] }

    @MainActor
    static func run(store: CorpusStore) async -> String {
        let nodes = store.nodes
        var out = "\n══════════ FOLKSONOMY DIAGNOSTIC (read-only) ══════════\n"

        var nodeCount: [String: Int] = [:]
        var withFolk = 0, termTotal = 0
        for n in nodes {
            guard let folk = n.folksonomy, !folk.isEmpty else { continue }
            withFolk += 1; termTotal += folk.count
            var seen = Set<String>()
            for raw in folk {
                let t = normalize(raw); guard !t.isEmpty else { continue }
                if seen.insert(t).inserted { nodeCount[t, default: 0] += 1 }
            }
        }

        var tags: [String]
        var terms: [String]
        if withFolk > 0 {
            let distinct = nodeCount.count
            let once = nodeCount.values.filter { $0 == 1 }.count
            out += "1. COVERAGE nodes=\(nodes.count) withFolk=\(withFolk) none=\(nodes.count - withFolk)"
            out += String(format: " mean=%.2f distinct=%d\n", Double(termTotal)/Double(withFolk), distinct)
            out += "3. LONG TAIL once=\(once)(\(distinct>0 ? once*100/distinct : 0)%) twice=\(nodeCount.values.filter{$0==2}.count) thrice=\(nodeCount.values.filter{$0==3}.count) >=4=\(nodeCount.values.filter{$0>=4}.count)\n"
            out += "2. RECURRENCE top 40:\n"
            for (t, c) in nodeCount.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(40) {
                out += "  \(c)  \(t)\n"
            }
            tags = store.tags.map { normalize($0.name) }.filter { !$0.isEmpty }
            terms = Array(nodeCount.sorted { $0.value > $1.value }.prefix(30).map { $0.key })
        } else {
            // Empty store (Simulator): take BOTH lists from the pushed input file.
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("folk_cosine_input.json")
            if let data = try? Data(contentsOf: url),
               let input = try? JSONDecoder().decode(CosineInput.self, from: data) {
                tags = input.tags.map(normalize).filter { !$0.isEmpty }
                terms = input.terms.map(normalize).filter { !$0.isEmpty }
                out += "1-3. store empty → cosine input from folk_cosine_input.json (\(tags.count) tags, \(terms.count) terms). (Coverage/recurrence/long-tail: see the Python walk of the local snapshot.)\n"
            } else {
                out += "1-6. store empty and no input file — nothing to measure.\n══════\n"; return out
            }
        }
        tags = Array(Set(tags)).sorted()

        // ── 6. Cosine calibration (CPU-only model). ──
        guard let modelURL = Bundle.main.url(forResource: "BGEMicro", withExtension: "mlmodelc"),
              let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt"),
              let tok = WordPieceTokenizer(vocabURL: vocabURL) else {
            out += "6. (model/vocab not bundled — cannot embed)\n══════\n"; return out
        }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuOnly
        guard let model = try? MLModel(contentsOf: modelURL, configuration: cfg) else {
            out += "6. (model load failed)\n══════\n"; return out
        }
        func embed(_ text: String) -> [Float]? {
            let (ids, mask) = tok.encode(text, maxLength: 512)
            func arr(_ v: [Int32]) -> MLMultiArray? {
                guard let a = try? MLMultiArray(shape: [1, NSNumber(value: v.count)], dataType: .int32) else { return nil }
                let p = a.dataPointer.bindMemory(to: Int32.self, capacity: v.count)
                for i in 0..<v.count { p[i] = v[i] }
                return a
            }
            guard let ia = arr(ids), let ma = arr(mask),
                  let prov = try? MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: ia),
                    "attention_mask": MLFeatureValue(multiArray: ma)]),
                  let o = try? model.prediction(from: prov),
                  let emb = o.featureValue(for: "embedding")?.multiArrayValue else { return nil }
            var v = [Float](repeating: 0, count: emb.count)
            for i in 0..<emb.count { v[i] = emb[i].floatValue }
            return v
        }
        func cos(_ a: [Float], _ b: [Float]) -> Float { var d: Float = 0; for i in 0..<min(a.count, b.count) { d += a[i]*b[i] }; return d }

        var tagVec: [String: [Float]] = [:]
        for t in tags { if let v = embed(t) { tagVec[t] = v } }
        var rows: [(term: String, tag: String, c: Float)] = []
        for term in terms {
            guard let tv = embed(term) else { continue }
            var best = ("", Float(-1))
            for (name, vec) in tagVec { let c = cos(tv, vec); if c > best.1 { best = (name, c) } }
            rows.append((term, best.0, best.1))
        }
        rows.sort { $0.c > $1.c }
        out += "6. COSINE — nearest existing tag per top term (\(tagVec.count) tags embedded, cos=dot):\n"
        for r in rows { out += String(format: "  %.3f  %-22@ → %@\n", r.c, r.term as NSString, r.tag as NSString) }
        let buckets: [(String, (Float) -> Bool)] = [
            (">=.90", {$0 >= 0.90}), (".80-.90", {$0 >= 0.80 && $0 < 0.90}), (".70-.80", {$0 >= 0.70 && $0 < 0.80}),
            (".60-.70", {$0 >= 0.60 && $0 < 0.70}), (".50-.60", {$0 >= 0.50 && $0 < 0.60}), ("<.50", {$0 < 0.50})]
        out += "   dist: " + buckets.map { n, f in "\(n):\(rows.filter { f($0.c) }.count)" }.joined(separator: " ") + "\n"
        out += "══════════════════════════════════════════════════════\n"
        return out
    }
}
#endif
