// Sweep 2b · 3.3 — the spike's battery, shared by the phone app and the Mac runner.
//
// Order (design.md §15): Apple first — Q1/Q2 model facts, the probe's latency jobs cold + warm (Q3), the 12-case suite
// (Q2/Q6), the sensitive-topic picks under default guardrails (Q4), ten turns (speed/heat/battery) — then MLX: weights
// on disk, load, the same latency jobs, the same suite, the same ten turns, and the guided-generation verdict (Q5/Q6).
// Fresh session per call, greedy sampling, every call through FoundationModels' LanguageModelSession.
//
// Results: <out>/spike-results.json (rewritten after every step, so a crash keeps what ran) and
// <out>/spike-progress.json (one line per step; `done: true` at the end). Dry run: the same code with a stand-in engine
// that calls no model, so the file shape and the grader can be proved off-device.
import Foundation
import FoundationModels

// MARK: - Engine seam

struct SpikeUsage {
    var input: Int?, output: Int?, reasoning: Int?
    var dict: [String: Any] { ["inputTokens": input ?? -1, "outputTokens": output ?? -1, "reasoningTokens": reasoning ?? -1] }
}

protocol SpikeEngine {
    var label: String { get }
    func sort(_ question: String) async throws -> (QuestionKind, SpikeUsage?)
    func pick(instructions: String, prompt: String) async throws -> (Pick, SpikeUsage?)
    func text(instructions: String, prompt: String, maxTokens: Int) async throws -> (String, SpikeUsage?)
    /// Streamed: the whole text, ms to the first non-empty snapshot, usage.
    func stream(instructions: String, prompt: String, maxTokens: Int) async throws -> (String, Double?, SpikeUsage?)
}

func greedy(_ n: Int) -> GenerationOptions { GenerationOptions(samplingMode: .greedy, maximumResponseTokens: n) }

/// Any FoundationModels `LanguageModel`: Apple's `SystemLanguageModel` or the MLX adapter's `MLXLanguageModel`.
struct FMEngine<M: LanguageModel>: SpikeEngine {
    let label: String
    let model: M

    private func session(_ instructions: String) -> LanguageModelSession { LanguageModelSession(model: model, instructions: instructions) }
    private func usage(_ u: LanguageModelSession.Usage) -> SpikeUsage {
        SpikeUsage(input: u.input.totalTokenCount, output: u.output.totalTokenCount, reasoning: u.output.reasoningTokenCount)
    }

    func sort(_ question: String) async throws -> (QuestionKind, SpikeUsage?) {
        let r = try await session(SpikeData.sortInstructions).respond(to: question, generating: Sorted.self, options: greedy(20))
        return (r.content.kind, usage(r.usage))
    }
    func pick(instructions: String, prompt: String) async throws -> (Pick, SpikeUsage?) {
        let r = try await session(instructions).respond(to: prompt, generating: Pick.self, options: greedy(Suite.maxPickTokens))
        return (r.content, usage(r.usage))
    }
    func text(instructions: String, prompt: String, maxTokens: Int) async throws -> (String, SpikeUsage?) {
        let r = try await session(instructions).respond(to: prompt, options: greedy(maxTokens))
        return (r.content, usage(r.usage))
    }
    func stream(instructions: String, prompt: String, maxTokens: Int) async throws -> (String, Double?, SpikeUsage?) {
        let s = session(instructions)
        let t0 = ContinuousClock.now
        var first: Double? = nil
        var last = ""
        for try await snap in s.streamResponse(to: prompt, options: greedy(maxTokens)) {
            if first == nil, !snap.content.isEmpty { first = ms(since: t0) }
            last = snap.content
        }
        return (last, first, usage(s.usage))
    }
}

func ms(since t: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - t
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// Every error verbatim: its type, its case, its text. `kind` sorts guardrail / refusal / other for the grader.
func describeError(_ e: Error) -> [String: Any] {
    var d: [String: Any] = ["type": String(reflecting: type(of: e)), "description": String(describing: e), "reflecting": String(reflecting: e)]
    if let l = e as? LocalizedError {
        d["errorDescription"] = l.errorDescription ?? ""
        d["failureReason"] = l.failureReason ?? ""
        d["recoverySuggestion"] = l.recoverySuggestion ?? ""
    }
    let all = "\(d["type"]!) \(d["reflecting"]!)".lowercased()
    d["kind"] = all.contains("guardrail") ? "guardrail" : all.contains("refus") ? "refusal" : all.contains("context") ? "context" : "other"
    return d
}

// MARK: - Runner

struct SpikeConfig {
    var phases: Set<String> = ["apple", "mlx"]
    var dryRun = false
    var appleRepeats = 6
    var mlxRepeats = 3
    var modelDir: URL
    var outDir: URL
    var platform: String
}

@MainActor final class SpikeRunner: ObservableObject {
    @Published private(set) var line = "starting"
    @Published private(set) var finished = false
    let config: SpikeConfig
    private var results: [String: Any] = [:]
    private var step = 0
    private let started = Date()
    private var peak = PeakSampler()

    init(config: SpikeConfig) { self.config = config }

    // MARK: progress + results files

    private func progress(_ phase: String, _ text: String, done: Bool = false, error: String? = nil) {
        step += 1
        line = "\(phase): \(text)"
        var p: [String: Any] = ["step": step, "phase": phase, "line": text, "done": done, "elapsedS": Int(Date().timeIntervalSince(started)),
                                "updated": ISO8601DateFormatter().string(from: Date())]
        if let error { p["error"] = error }
        write(p, to: "spike-progress.json")
        print("[spike] \(Int(Date().timeIntervalSince(started)))s \(phase): \(text)")
    }

    private func save() { write(results, to: "spike-results.json") }

    private func write(_ obj: [String: Any], to name: String) {
        try? FileManager.default.createDirectory(at: config.outDir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            print("[spike] could not serialise \(name)"); return
        }
        try? data.write(to: config.outDir.appendingPathComponent(name), options: .atomic)
    }

    private func put(_ section: String, _ key: String, _ value: Any) {
        var s = results[section] as? [String: Any] ?? [:]
        s[key] = value
        results[section] = s
        save()
    }

    // MARK: run

    func run() async {
        results["meta"] = [
            "spike": "sweep-2b-3.3", "platform": config.platform, "dryRun": config.dryRun, "phases": config.phases.sorted(),
            "appleRepeats": config.appleRepeats, "mlxRepeats": config.mlxRepeats, "started": ISO8601DateFormatter().string(from: started),
            "device": Metrics.deviceInfo(), "startReading": Metrics.snapshot(), "freeBytes": Metrics.freeBytes(at: config.outDir) ?? -1,
        ] as [String: Any]
        save()
        if config.phases.contains("apple") { await runApple() }
        if config.phases.contains("mlx") { await runMLX() }
        var meta = results["meta"] as? [String: Any] ?? [:]
        meta["endReading"] = Metrics.snapshot()
        meta["totalS"] = Int(Date().timeIntervalSince(started))
        results["meta"] = meta
        save()
        progress("all", "done in \(Int(Date().timeIntervalSince(started))) s", done: true)
        finished = true
    }

    // MARK: Apple

    private func appleInfo() -> [String: Any] {
        if config.dryRun {
            return ["dryRun": true, "isAvailable": true, "availability": "available", "contextSize": 4096, "variant": "dry-run",
                    "isCore3": false, "isCoreAdvanced3": false, "capabilities": "dry-run", "supportedLanguages": 0, "supportsCurrentLocale": true]
        }
        let m = SystemLanguageModel.default
        var d: [String: Any] = ["isAvailable": m.isAvailable, "availability": String(describing: m.availability)]
        d["contextSize"] = m.contextSize
        d["variant"] = m.variant.displayName
        d["variantDescription"] = String(reflecting: m.variant)
        d["isCore3"] = m.variant == .core3
        d["isCoreAdvanced3"] = m.variant == .coreAdvanced3
        d["core3DisplayName"] = SystemLanguageModel.Variant.core3.displayName
        d["coreAdvanced3DisplayName"] = SystemLanguageModel.Variant.coreAdvanced3.displayName
        d["capabilities"] = String(reflecting: m.capabilities)
        d["executorConfiguration"] = String(reflecting: m.executorConfiguration)
        d["supportedLanguages"] = m.supportedLanguages.count
        d["supportsCurrentLocale"] = m.supportsLocale()
        d["contentTaggingContextSize"] = SystemLanguageModel(useCase: .contentTagging).contextSize
        let pcc = PrivateCloudComputeLanguageModel()
        d["privateCloudCompute"] = ["isAvailable": pcc.isAvailable, "availability": String(describing: pcc.availability)]
        return d
    }

    private func runApple() async {
        progress("apple", "reading the model's facts (Q1, Q2)")
        let info = appleInfo()
        put("apple", "info", info)
        guard info["isAvailable"] as? Bool == true else {
            progress("apple", "Apple Intelligence not available: \(info["availability"] ?? "?") — skipping Apple phases", error: "apple unavailable")
            return
        }
        let engine: SpikeEngine = config.dryRun ? DryEngine(label: "apple") : FMEngine(label: "apple", model: SystemLanguageModel.default)
        let permissive: SpikeEngine = config.dryRun ? DryEngine(label: "apple-permissive")
            : FMEngine(label: "apple-permissive", model: SystemLanguageModel(guardrails: .permissiveContentTransformations))

        progress("apple", "cold call (first call of the process)")
        put("apple", "cold", await coldCall(engine))
        progress("apple", "latency jobs ×\(config.appleRepeats) (Q3)")
        put("apple", "latency", await latency(engine, repeats: config.appleRepeats, phase: "apple"))
        progress("apple", "12-case suite (Q2)")
        put("apple", "suite", await suite(engine, phase: "apple"))
        progress("apple", "sensitive-topic picks (Q4)")
        put("apple", "sensitive", await sensitive(engine, permissive: permissive))
        progress("apple", "ten turns")
        put("apple", "tenTurns", await tenTurns(engine, phase: "apple"))
    }

    // MARK: MLX

    private func runMLX() async {
        // devicectl may land a copied folder inside the destination (…/X/X): accept either.
        var dir = config.modelDir
        let nested = dir.appendingPathComponent(dir.lastPathComponent)
        func hasConfig(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.appendingPathComponent("config.json").path) }
        if !hasConfig(dir), hasConfig(nested) { dir = nested }
        let present = hasConfig(dir)
        var weights: [String: Any] = ["dir": dir.lastPathComponent, "present": present]
        if present {
            weights["bytesOnDisk"] = Metrics.directorySize(dir)
            weights["files"] = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        }
        put("mlx", "weights", weights)
        let engine: SpikeEngine
        if config.dryRun {
            engine = DryEngine(label: "mlx")
            put("mlx", "load", ["dryRun": true, "loadMs": 0, "before": Metrics.snapshot(), "after": Metrics.snapshot()])
            put("mlx", "sameAPI", SpikeMLX.sameAPIFact)
        } else {
            guard present else {
                progress("mlx", "no weights at \(dir.path) — skipping MLX phases", error: "weights missing")
                return
            }
            progress("mlx", "loading Qwen3.5 4B (Q5)")
            peak.start()
            let before = Metrics.snapshot()
            let t = ContinuousClock.now
            do {
                let loaded = try await SpikeMLX.load(directory: dir)
                let loadMs = ms(since: t)
                put("mlx", "load", ["loadMs": Int(loadMs), "before": before, "after": Metrics.snapshot(), "info": loaded.info])
                put("mlx", "sameAPI", SpikeMLX.sameAPIFact)
                engine = loaded.engine
            } catch {
                put("mlx", "load", ["error": describeError(error), "ms": Int(ms(since: t)), "before": before, "after": Metrics.snapshot()])
                progress("mlx", "load failed: \(error)", error: "\(error)")
                peak.stop(); put("mlx", "memoryPeak", peak.dict)
                return
            }
        }
        progress("mlx", "cold call (first call after load: shader compile)")
        put("mlx", "cold", await coldCall(engine))
        progress("mlx", "latency jobs ×\(config.mlxRepeats)")
        put("mlx", "latency", await latency(engine, repeats: config.mlxRepeats, phase: "mlx"))
        progress("mlx", "12-case suite (Q6)")
        put("mlx", "suite", await suite(engine, phase: "mlx"))
        progress("mlx", "ten turns (Q5 heat/battery/speed)")
        put("mlx", "tenTurns", await tenTurns(engine, phase: "mlx"))
        peak.stop()
        put("mlx", "memoryPeak", peak.dict)
        put("mlx", "afterReading", Metrics.snapshot())
    }

    // MARK: jobs

    private func coldCall(_ e: SpikeEngine) async -> [String: Any] {
        let t = ContinuousClock.now
        do {
            let (text, u) = try await e.text(instructions: SpikeData.coldInstructions, prompt: SpikeData.coldPrompt, maxTokens: 8)
            return ["ms": Int(ms(since: t)), "reply": text, "usage": u?.dict ?? [:], "reading": Metrics.snapshot()]
        } catch {
            return ["ms": Int(ms(since: t)), "error": describeError(error)]
        }
    }

    /// The probe's loop, verbatim in shape: per repeat a sort, a pick from 4 and from 12, a streamed phrase, a rewrite.
    /// Repeat 0's calls are also reported apart as `firstOfKind` (each job's first call of the process).
    private func latency(_ e: SpikeEngine, repeats: Int, phase: String) async -> [String: Any] {
        var sortMs: [Double] = [], pick4: [Double] = [], pick12: [Double] = [], phraseFirst: [Double] = [], phraseAll: [Double] = [], rewrite: [Double] = []
        var first: [String: Int] = [:], errors: [[String: Any]] = [], sortKinds: [String] = []
        var pickRight = 0, pickVerbatim = 0, pickN = 0, promptTokens: [String: Int] = [:], guidedOK = 0, guidedErr = 0
        func note(_ job: String, _ r: Int, _ v: Double) { if r == 0 { first[job] = Int(v) } }
        func fail(_ job: String, _ err: Error) { if errors.count < 12 { var d = describeError(err); d["job"] = job; errors.append(d) } }

        for r in 0..<repeats {
            progress(phase, "latency round \(r + 1)/\(repeats)")
            let sq = SpikeData.sortQuestions[r % SpikeData.sortQuestions.count]
            var t = ContinuousClock.now
            do {
                let (k, _) = try await e.sort(sq)
                let v = ms(since: t); sortMs.append(v); note("sort", r, v); sortKinds.append("\(k)"); guidedOK += 1
            } catch { fail("sort", error); guidedErr += 1 }

            let c = SpikeData.probeQuestions[r % SpikeData.probeQuestions.count]
            for n in [4, 12] {
                let prompt = SpikeData.pickPrompt(packet: SpikeData.probePacket(n), question: c.q)
                t = ContinuousClock.now
                do {
                    let (p, u) = try await e.pick(instructions: SpikeData.pickInstructions, prompt: prompt)
                    let v = ms(since: t)
                    if n == 4 { pick4.append(v) } else { pick12.append(v) }
                    note("pick\(n)", r, v); guidedOK += 1
                    if promptTokens["pick\(n)"] == nil, let i = u?.input { promptTokens["pick\(n)"] = i }
                    pickN += 1
                    if p.passage == c.passage { pickRight += 1 }
                    let s = p.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty, (1...n).contains(p.passage), SpikeData.probePassages[p.passage - 1].contains(s) { pickVerbatim += 1 }
                } catch { fail("pick\(n)", error); guidedErr += 1 }
            }

            t = ContinuousClock.now
            do {
                let (_, f, _) = try await e.stream(instructions: SpikeData.phraseInstructions,
                                                   prompt: SpikeData.phrasePrompt(note: SpikeData.probePassages[c.passage - 1], question: c.q), maxTokens: 80)
                let v = ms(since: t)
                if let f { phraseFirst.append(f); phraseAll.append(v); note("phraseFirstWord", r, f); note("phraseWhole", r, v) }
            } catch { fail("phrase", error) }

            t = ContinuousClock.now
            do {
                _ = try await e.text(instructions: SpikeData.rewriteInstructions,
                                     prompt: SpikeData.rewritePrompt(earlier: SpikeData.probeQuestions[(r + 1) % SpikeData.probeQuestions.count].q), maxTokens: 40)
                let v = ms(since: t); rewrite.append(v); note("rewrite", r, v)
            } catch { fail("rewrite", error) }
        }
        // Warm = every repeat after the first.
        func warm(_ v: [Double]) -> [String: Any] { stats(Array(v.dropFirst())) }
        return [
            "repeats": repeats, "firstOfKind": first,
            "sort": warm(sortMs), "pick4": warm(pick4), "pick12": warm(pick12),
            "phraseFirstWord": warm(phraseFirst), "phraseWhole": warm(phraseAll), "rewrite": warm(rewrite),
            "all": ["sort": stats(sortMs), "pick4": stats(pick4), "pick12": stats(pick12), "phraseFirstWord": stats(phraseFirst),
                    "phraseWhole": stats(phraseAll), "rewrite": stats(rewrite)],
            "sortKinds": sortKinds, "pickRightPassage": "\(pickRight)/\(pickN)", "pickSentenceVerbatim": "\(pickVerbatim)/\(pickN)",
            "promptTokens": promptTokens, "guidedCalls": ["ok": guidedOK, "errors": guidedErr], "errors": errors,
        ]
    }

    /// The 12-case mini-suite: guided pick (plain-text fallback on error) → phrase from the picked passage, or the
    /// app's no-match line on 0 → code grade.
    private func suite(_ e: SpikeEngine, phase: String) async -> [String: Any] {
        var rows: [[String: Any]] = [], passN = 0, byKind: [String: [Int]] = [:], guidedOK = 0, guidedErr = 0, thinkLeaks = 0
        for (i, c) in Suite.cases.enumerated() {
            progress(phase, "suite \(i + 1)/\(Suite.cases.count) (\(c.id))")
            var row: [String: Any] = ["id": c.id, "kind": c.kind.rawValue, "expectedPassage": c.expectedPassage]
            var errs: [[String: Any]] = []
            let prompt = SpikeData.pickPrompt(packet: SpikeData.packet(c.packet), question: c.question)
            var passage: Int? = nil
            var t = ContinuousClock.now
            do {
                let (p, u) = try await e.pick(instructions: Suite.pickInstructions, prompt: prompt)
                passage = p.passage
                row["pickPath"] = "guided"; row["sentence"] = p.sentence; row["pickUsage"] = u?.dict ?? [:]
                if (1...c.packet.count).contains(p.passage) {
                    let s = p.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    row["sentenceVerbatim"] = !s.isEmpty && SpikeData.passage(c.packet[p.passage - 1]).contains(s)
                }
                guidedOK += 1
            } catch {
                guidedErr += 1
                var d = describeError(error); d["call"] = "guided pick"; errs.append(d)
                t = ContinuousClock.now
                do {
                    let (txt, _) = try await e.text(instructions: Suite.fallbackPickInstructions, prompt: prompt, maxTokens: 8)
                    passage = firstInt(txt); row["pickPath"] = "fallback"; row["fallbackReply"] = txt
                } catch {
                    var d = describeError(error); d["call"] = "fallback pick"; errs.append(d); row["pickPath"] = "none"
                }
            }
            row["pickMs"] = Int(ms(since: t))
            row["passage"] = passage ?? -1
            var answer = ""
            if let p = passage, p == 0 {
                answer = Suite.noMatchLine; row["answerBy"] = "app"
            } else if let p = passage, (1...c.packet.count).contains(p) {
                t = ContinuousClock.now
                do {
                    let (txt, u) = try await e.text(instructions: Suite.phraseInstructions,
                                                    prompt: SpikeData.phrasePrompt(note: SpikeData.passage(c.packet[p - 1]), question: c.question),
                                                    maxTokens: Suite.maxPhraseTokens)
                    answer = txt; row["answerBy"] = "model"; row["phraseUsage"] = u?.dict ?? [:]
                } catch {
                    var d = describeError(error); d["call"] = "phrase"; errs.append(d); row["answerBy"] = "error"
                }
                row["phraseMs"] = Int(ms(since: t))
            }
            if answer.contains("<think") || answer.contains("</think>") { thinkLeaks += 1; row["thinkLeak"] = true }
            let g = Suite.grade(c, passage: passage, answer: answer)
            row["answer"] = answer; row["pass"] = g.pass; row["reason"] = g.reason; row["errors"] = errs
            if g.pass { passN += 1 }
            byKind[c.kind.rawValue, default: [0, 0]][0] += g.pass ? 1 : 0
            byKind[c.kind.rawValue, default: [0, 0]][1] += 1
            rows.append(row)
        }
        return ["score": passN, "of": Suite.cases.count, "byKind": byKind.mapValues { "\($0[0])/\($0[1])" }, "cases": rows,
                "guidedCalls": ["ok": guidedOK, "errors": guidedErr], "thinkLeaks": thinkLeaks]
    }

    /// Q4: each sensitive note → guided pick, plain-text pick, phrase (default guardrails); a phrase that fails is
    /// retried once under `.permissiveContentTransformations` to see whether that guardrail setting is the way out.
    private func sensitive(_ e: SpikeEngine, permissive: SpikeEngine) async -> [String: Any] {
        var rows: [[String: Any]] = [], guidedRefused = 0, plainRefused = 0
        func call(_ body: () async throws -> [String: Any]) async -> [String: Any] {
            let t = ContinuousClock.now
            do { var d = try await body(); d["ok"] = true; d["ms"] = Int(ms(since: t)); return d }
            catch { return ["ok": false, "ms": Int(ms(since: t)), "error": describeError(error)] }
        }
        for n in Sensitive.notes {
            progress("apple", "sensitive \(n.id) (\(n.topic))")
            let prompt = SpikeData.pickPrompt(packet: SpikeData.packet(Sensitive.packet(for: n)), question: n.question)
            let guided = await call { let (p, _) = try await e.pick(instructions: Suite.pickInstructions, prompt: prompt); return ["passage": p.passage, "sentence": p.sentence] }
            let plain = await call { let (t, _) = try await e.text(instructions: Suite.fallbackPickInstructions, prompt: prompt, maxTokens: 8); return ["reply": t, "passage": firstInt(t) ?? -1] }
            let phrasePrompt = SpikeData.phrasePrompt(note: SpikeData.passage(n.passage), question: n.question)
            let phrase = await call { let (t, _) = try await e.text(instructions: Suite.phraseInstructions, prompt: phrasePrompt, maxTokens: Suite.maxPhraseTokens); return ["reply": t] }
            var row: [String: Any] = ["id": n.id, "topic": n.topic, "guidedPick": guided, "plainPick": plain, "phrase": phrase]
            if phrase["ok"] as? Bool == false {
                row["phrasePermissive"] = await call { let (t, _) = try await permissive.text(instructions: Suite.phraseInstructions, prompt: phrasePrompt, maxTokens: Suite.maxPhraseTokens); return ["reply": t] }
            }
            if guided["ok"] as? Bool == false { guidedRefused += 1 }
            if plain["ok"] as? Bool == false { plainRefused += 1 }
            rows.append(row)
        }
        return ["notes": rows, "guidedPickFailed": guidedRefused, "plainPickFailed": plainRefused, "of": Sensitive.notes.count]
    }

    /// Ten turns, fresh session each, ~80-word answers streamed: speed, heat, battery, memory per turn.
    private func tenTurns(_ e: SpikeEngine, phase: String) async -> [String: Any] {
        var rows: [[String: Any]] = []
        let start = Metrics.snapshot()
        for (i, turn) in TenTurns.turns.enumerated() {
            progress(phase, "turn \(i + 1)/\(TenTurns.turns.count)")
            let prompt = SpikeData.pickPrompt(packet: SpikeData.packet(turn.packet), question: turn.question)
            let t = ContinuousClock.now
            var row: [String: Any] = ["turn": i + 1]
            do {
                let (txt, first, u) = try await e.stream(instructions: TenTurns.instructions, prompt: prompt, maxTokens: TenTurns.maxTokens)
                let total = ms(since: t)
                let words = txt.split(whereSeparator: { $0.isWhitespace }).count
                let out = u?.output ?? -1
                let decodeS = max(0.001, (total - (first ?? 0)) / 1000)
                row["ttftMs"] = Int(first ?? -1); row["totalMs"] = Int(total); row["words"] = words; row["outputTokens"] = out
                row["reasoningTokens"] = u?.reasoning ?? -1; row["inputTokens"] = u?.input ?? -1
                row["tokensPerS"] = out > 1 ? Double(out - 1) / decodeS : -1
                row["wordsPerS"] = Double(words) / max(0.001, total / 1000)
                row["thinkLeak"] = txt.contains("<think") || txt.contains("</think>")
                row["chars"] = txt.count
            } catch {
                row["error"] = describeError(error); row["totalMs"] = Int(ms(since: t))
            }
            row["reading"] = Metrics.snapshot()
            rows.append(row)
        }
        return ["turns": rows, "start": start, "end": Metrics.snapshot()]
    }
}

func firstInt(_ s: String) -> Int? {
    var digits = ""
    for ch in s {
        if ch.isASCII && ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
    }
    return Int(digits)
}

func stats(_ v: [Double]) -> [String: Any] {
    guard !v.isEmpty else { return ["n": 0] }
    let s = v.sorted()
    return ["n": s.count, "medianMs": Int(s[s.count / 2]), "minMs": Int(s.first!), "maxMs": Int(s.last!)]
}

/// Samples the footprint every 250 ms while MLX runs: the peak, and the least headroom left before jetsam.
@MainActor final class PeakSampler {
    private(set) var peakMB = 0, minAvailableMB = Int.max, samples = 0
    private var task: Task<Void, Never>?
    func start() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    func stop() { task?.cancel(); task = nil; sample() }
    private func sample() {
        samples += 1
        if let f = Metrics.physFootprint() { peakMB = max(peakMB, Int(f / 1_048_576)) }
        if let a = Metrics.availableMemory() { minAvailableMB = min(minAvailableMB, Int(a / 1_048_576)) }
    }
    var dict: [String: Any] { ["peakPhysFootprintMB": peakMB, "minAvailableMemoryMB": minAvailableMB == Int.max ? -1 : minAvailableMB, "samples": samples] }
}
