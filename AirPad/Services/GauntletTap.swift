#if DEBUG
import Foundation
import SwiftUI

/// Brief CH-0 — Gauntlet v2's RENDER TAP + REPLAY provider. DEBUG-only and inert unless launched with
/// `-GauntletTapDir <abs dir>` (the Simulator writes straight to the Mac path).
///
/// Why it exists: the BU2 gauntlet graded the FINAL answer string once, beneath the UI, and every
/// device-found bug in the 10-03/04 arc slipped through that gap — most visibly "the reasoning streams
/// as answer text, then jumps into Thought process", which a final-string check can never see. The tap
/// records, per turn:
///   • every string the answer body DISPLAYED while streaming (`answerFrame`, called from the tail's
///     chunk commit — the exact text handed to the renderer, not the model's raw deltas);
///   • the raw model deltas as they arrived (thinking vs answer channel) — the "raw output";
///   • the wire request (system prompt, history, current user content, `think`, requestID, model);
///   • the Librarian's plan (route, the packet's numbered entries, what was read in full);
///   • the committed answer + its citation chips + the Thought-process text + any error.
/// One `turn-NNN.json` per turn. The XCUITest waits on these files and pairs each with what it read
/// off the screen; `scripts/gauntlet/grade.py` grades the pair.
///
/// `-GauntletReplay <file.json>` streams RECORDED deltas instead of calling the model (everything else
/// — retrieval, packet, ChatSession, the real UI — runs for real). It is how the known-bad corpus is
/// pushed through the SAME capture path the candidates use, so "the grader went RED" proves the whole
/// chain can fail, not just a grader fed a hand-made record.
final class GauntletTap: @unchecked Sendable {
    static let shared = GauntletTap()

    let dir: URL?
    var isOn: Bool { dir != nil }

    private let lock = NSLock()
    private var seq = 0
    private var pendingPlan: [String: Any]? = nil
    private var turn: [String: Any]? = nil
    private var frames: [[String: Any]] = []
    private var raw: [[String: Any]] = []
    private var turnStart = Date()
    private var lastBeat = Date()
    private var beatSeen = false   // the self-watchdog arms only after the first main-thread beat
    private var maxGapMs = 0
    /// One id per app launch (= one Gauntlet chat), so the grader pairs a turn with the previous turn
    /// of the SAME conversation (carry / re-ask / history checks) and never across launches.
    let launchID = UUID().uuidString

    // Replay
    private var replayTurns: [[String: Any]] = []
    private var replayCursor = 0

    private init() {
        let d = UserDefaults.standard
        if let p = d.string(forKey: "GauntletTapDir"), !p.isEmpty {
            // `app-tmp` = inside the app's own sandbox (a physical device can't write Mac paths).
            let url = p == "app-tmp"
                ? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("gauntlet", isDirectory: true)
                : URL(fileURLWithPath: p, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            dir = url
        } else {
            dir = nil
        }
        // `-GauntletReplayB64 <base64 json>` — the same replay passed INLINE (a device can't read a Mac file).
        let replayData: Data? = {
            if let b = d.string(forKey: "GauntletReplayB64"), !b.isEmpty { return Data(base64Encoded: b) }
            if let rp = d.string(forKey: "GauntletReplay"), !rp.isEmpty { return try? Data(contentsOf: URL(fileURLWithPath: rp)) }
            return nil
        }()
        if let data = replayData,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let turns = obj["turns"] as? [[String: Any]] {
            replayTurns = turns
            NSLog("[GauntletTap] replay armed: %d turn(s)", turns.count)
        }
        // Main-thread HEARTBEAT: a 0.25 s main-runloop timer. The largest gap between ticks during a
        // turn is recorded (`maxMainThreadGapMs`, graded A8), and a `heartbeat` file is touched every
        // tick so the orchestrator's watchdog can terminate an app whose main thread has stopped (a
        // hung app otherwise freezes the XCUITest driver too — it waits for "idle" forever).
        if let dir {
            let hb = dir.appendingPathComponent("heartbeat")
            DispatchQueue.main.async { [weak self] in
                // `.common` modes, not `scheduledTimer`'s default mode: a runloop parked in a TRACKING mode (a
                // scroll / interactive keyboard dismiss) is not a hung main thread — the default-mode timer stopped
                // ticking there and the watchdog killed an IDLE app (2026-10-06 lab: 2 false "hangs", main thread in
                // mach_msg 1,683/2,157 samples). A real hang still stops this timer in every mode.
                let beat = Timer(timeInterval: 0.25, repeats: true) { _ in
                    guard let self else { return }
                    let now = Date()
                    self.lock.lock()
                    let gap = Int(now.timeIntervalSince(self.lastBeat) * 1000)
                    if gap > self.maxGapMs && self.beatSeen { self.maxGapMs = gap }
                    self.lastBeat = now
                    self.beatSeen = true
                    self.lock.unlock()
                    try? "\(now.timeIntervalSince1970)".write(to: hb, atomically: false, encoding: .utf8)
                }
                RunLoop.main.add(beat, forMode: .common)
            }
        }
        // `-GauntletSelfWatchdog <s>` — on a physical device nothing on the Mac can sample/kill a hung app
        // cheaply, and XCUITest blocks forever waiting for "idle". A background thread exits the app when the
        // main-thread heartbeat is older than <s> seconds, which unblocks the driver (it records APP HUNG).
        let wd = d.integer(forKey: "GauntletSelfWatchdog")
        if wd > 0, dir != nil {
            Thread.detachNewThread { [weak self] in
                while let self {
                    Thread.sleep(forTimeInterval: 1)
                    self.lock.lock(); let stale = Date().timeIntervalSince(self.lastBeat); let armed = self.beatSeen; self.lock.unlock()
                    if armed && stale > Double(wd) {
                        NSLog("[GauntletTap] SELF-WATCHDOG: main thread stalled %.0fs — exiting (86)", stale)
                        exit(86)
                    }
                }
            }
        }
        // Turn numbering continues across relaunches within one run dir (a chat group = one launch).
        if let dir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            seq = names.filter { $0.hasPrefix("turn-") && $0.hasSuffix(".json") }.count
        }
    }

    private func ms(_ d: Date = Date()) -> Int { Int(d.timeIntervalSince(turnStart) * 1000) }

    // MARK: plan / request / model

    /// The Librarian's plan for the turn about to be sent (route + the packet's numbered entries).
    func notePlan(mode: String, readNodeIDs: [String], candidates: [ChatSession.Message.Citation],
                  cardCount: Int, passageCount: Int, packetChars: Int, estTokens: Int,
                  windowTokens: Int, budgetChars: Int, alwaysCite: [Int]) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        pendingPlan = [
            "mode": mode, "readNodeIDs": readNodeIDs,
            "candidates": candidates.map { ["index": $0.index, "nodeID": $0.nodeID ?? "", "title": $0.title, "snippet": $0.snippet] },
            "cardCount": cardCount, "passageCount": passageCount, "packetChars": packetChars,
            "estTokens": estTokens, "windowTokens": windowTokens, "budgetChars": budgetChars,
            "alwaysCite": alwaysCite,
        ]
    }

    func beginTurn(requestID: String?, think: Bool, systemPrompt: String,
                   history: [[String: String]], userContent: String, numCtx: Int) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        turnStart = Date()
        frames = []; raw = []
        maxGapMs = 0; lastBeat = Date()
        turn = [
            "startedAt": ISO8601DateFormatter().string(from: turnStart),
            "requestID": requestID ?? "", "think": think, "numCtx": numCtx,
            "systemPrompt": systemPrompt, "history": history, "userContent": userContent,
            "plan": pendingPlan ?? NSNull(),
            "replay": isReplaying ? "yes" : "no",
            "launchID": launchID,
        ]
        pendingPlan = nil
    }

    /// Gauntlet v2 pillar rows (T 2026-10-06) — which path produced the turn ("plain" is implicit; "tools" = the
    /// web-search agent loop, "nokey" = the app-owned no-key line, no model call) and every tool the model called.
    func notePath(_ path: String) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        turn?["path"] = path
    }
    func noteTool(_ name: String, _ argument: String) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        var tools = (turn?["tools"] as? [[String: String]]) ?? []
        tools.append(["name": name, "argument": argument])
        turn?["tools"] = tools
    }

    /// CH Session 2 web grounding — every result a web tool returned this turn (URL, title, publication date), in
    /// the order they were numbered, so the grader can tell a returned URL from an invented one and a stale result
    /// from a fresh one. Plus any scalar the grader reads (`generalKnowledge`, `prefetch`, `prefetchMs`, `fetched`).
    func noteToolLinks(_ links: [ToolLink]) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        var all = (turn?["toolLinks"] as? [[String: String]]) ?? []
        let df = ISO8601DateFormatter(); df.formatOptions = [.withFullDate]
        all += links.map { ["url": $0.url, "title": $0.title, "snippet": $0.snippet ?? "",
                            "published": $0.published.map { df.string(from: $0) } ?? ""] }
        turn?["toolLinks"] = all
    }
    /// CH (T 2026-10-09) — each live tool status line the transcript showed this turn, in order.
    func noteStatus(_ line: String) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        let lines = ((turn?["toolStatus"] as? [String]) ?? []) + [line]
        turn?["toolStatus"] = lines
    }
    func noteValue(_ key: String, _ value: Any) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        turn?[key] = value
    }

    /// The model tag the app actually put on the wire (ModelRouter.streamHost).
    func noteModel(_ model: String) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        turn?["modelRequested"] = model
    }

    /// C4a — the ask hit a not-loaded refusal and the app loaded `model` before retrying.
    func noteAskLoad(_ model: String) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        turn?["askLoaded"] = model
    }

    func rawDelta(thinking: Bool, _ s: String) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        raw.append(["t": ms(), "ch": thinking ? "thinking" : "answer", "s": s])
    }

    /// What the answer body DISPLAYED (the streaming tail's revealed text) — one entry per change.
    func answerFrame(_ displayed: String) {
        guard isOn else { return }
        lock.lock(); defer { lock.unlock() }
        if (frames.last?["s"] as? String) == displayed { return }
        frames.append(["t": ms(), "s": displayed])
    }

    func endTurn(finalText: String?, citations: [ChatSession.Message.Citation]?, receipt: String?,
                 thinking: String, lastError: String?, isPartial: Bool) {
        guard isOn, let dir else { return }
        lock.lock()
        var t = turn ?? ["startedAt": ISO8601DateFormatter().string(from: Date()), "note": "endTurn without beginTurn"]
        t["finalText"] = finalText ?? NSNull()
        t["citations"] = (citations ?? []).map { ["index": $0.index, "nodeID": $0.nodeID ?? "", "url": $0.url ?? "", "title": $0.title, "snippet": $0.snippet] }
        t["receipt"] = receipt ?? NSNull()
        t["thinking"] = thinking
        t["lastError"] = lastError ?? NSNull()
        t["isPartial"] = isPartial
        t["frames"] = frames
        t["raw"] = raw
        t["elapsedMs"] = ms()
        t["maxMainThreadGapMs"] = maxGapMs
        seq += 1
        t["seq"] = seq
        // `-GauntletFailFirstSend`: the dead-port pairing lasts exactly ONE send, then the real Host
        // is restored so the test's Retry tap goes through (BU2 case 5).
        if HostPairing.debugForceUnreachableHost { HostPairing.debugForceUnreachableHost = false; t["forcedFailure"] = true }
        let url = dir.appendingPathComponent(String(format: "turn-%03d.json", seq))
        turn = nil; frames = []; raw = []
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: t, options: [.prettyPrinted, .sortedKeys]) {
            // Write to a temp name then move, so the XCUITest (polling this dir) never reads a half file.
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
            try? data.write(to: tmp)
            try? FileManager.default.moveItem(at: tmp, to: url)
        }
        NSLog("[GauntletTap] wrote %@", url.lastPathComponent)
    }

    /// The seq of the last turn written (store pre-screen maps cases → turn files with it).
    var currentSeq: Int { lock.lock(); defer { lock.unlock() }; return seq }
    func resetGap() { lock.lock(); maxGapMs = 0; lastBeat = Date(); lock.unlock() }
    func maxGapSinceReset() -> Int { lock.lock(); defer { lock.unlock() }; return maxGapMs }

    // MARK: replay

    var isReplaying: Bool { !replayTurns.isEmpty }

    /// The next recorded turn's deltas, or nil when not replaying / exhausted. Each delta is
    /// `["a"|"t", text]` (answer / thinking channel); `delayMs` paces them like a live stream.
    /// A recorded turn may also carry `"toolCalls": [{"name", "arguments": {…}}]` — the AGENT path's replay
    /// (`ModelRouter.streamHostAgentTurn`): the recorded calls then run through the real tool executor (the
    /// DEBUG `-WebSearchMock`), so the activity rows and web citations are produced by the app, not faked.
    func nextReplayTurn() -> (deltas: [(thinking: Bool, s: String)], delayMs: Int, toolCalls: [(name: String, argumentsJSON: String)])? {
        lock.lock(); defer { lock.unlock() }
        guard replayCursor < replayTurns.count else { return nil }
        let t = replayTurns[replayCursor]; replayCursor += 1
        // `{{n:<title prefix>}}` → `[k]`, k = that entry's number in THIS turn's packet, so a replay can
        // cite correctly (the known-good control) or deliberately mis-cite (the label↔citation known-bad)
        // without hard-coding packet order. An unknown title becomes `[?]` (and is logged).
        let cands = ((turn?["plan"] as? [String: Any])?["candidates"] as? [[String: Any]]) ?? []
        func resolve(_ s: String) -> String {
            guard s.contains("{{n:") else { return s }
            var out = s
            while let r = out.range(of: #"\{\{n:([^}]+)\}\}"#, options: .regularExpression) {
                let key = String(out[r].dropFirst(4).dropLast(2)).lowercased()
                let idx = cands.first { (($0["title"] as? String) ?? "").lowercased().hasPrefix(key) }?["index"] as? Int
                if idx == nil { NSLog("[GauntletTap] replay placeholder '%@' not in packet", key) }
                out.replaceSubrange(r, with: idx.map { "[\($0)]" } ?? "[?]")
            }
            return out
        }
        let ds = (t["deltas"] as? [[String]] ?? []).map { (thinking: $0.first == "t", s: resolve($0.count > 1 ? $0[1] : "")) }
        let calls = (t["toolCalls"] as? [[String: Any]] ?? []).compactMap { c -> (name: String, argumentsJSON: String)? in
            guard let name = c["name"] as? String else { return nil }
            let args = (try? JSONSerialization.data(withJSONObject: c["arguments"] ?? [:])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return (name, args)
        }
        return (ds, t["delayMs"] as? Int ?? 12, calls)
    }
}

/// `-GauntletTapDir` builds only: a stable accessibility id (and, for `combine`, one combined label)
/// so the XCUITest can read what is ON SCREEN. A no-op otherwise — the shipped accessibility tree is
/// untouched.
struct GauntletA11y: ViewModifier {
    let id: String
    let combine: Bool
    func body(content: Content) -> some View {
        if GauntletTap.shared.isOn {
            if combine && !UserDefaults.standard.bool(forKey: "GauntletNoCombine") {
                content.accessibilityElement(children: .combine).accessibilityIdentifier(id)
            } else {
                content.accessibilityIdentifier(id)
            }
        } else {
            content
        }
    }
}

/// Perf gate (Brief CH follow-up): time from "open the chat" to the transcript's first committed layout,
/// plus the longest main-thread stall in the 2 s after. Surfaced to XCUITest through a hidden label
/// (`gauntlet.metrics`) — on a physical device the test runner can't read the app's files.
@Observable final class GauntletMetrics {
    static let shared = GauntletMetrics()
    var line = ""
    @ObservationIgnored private var openT0: Date? = nil
    @ObservationIgnored private var opens = 0
    func markOpen() { openT0 = Date(); GauntletTap.shared.resetGap() }
    func transcriptLaidOut(messages: Int) {
        guard let t0 = openT0 else { return }
        openT0 = nil
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        opens += 1
        let n = opens
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let stall = GauntletTap.shared.maxGapSinceReset()
            self.line = "open#\(n) openMs=\(ms) stallMs=\(stall) messages=\(messages)"
            NSLog("[GauntletMetrics] %@", self.line)
        }
    }
}

/// The perf gate's hidden labels, in their OWN view so a label update re-renders only this view.
struct GauntletMetricsLabels: View {
    var body: some View {
        VStack(spacing: 0) {
            Text(GauntletMetrics.shared.line).font(.system(size: 1)).opacity(0.02)
                .accessibilityIdentifier("gauntlet.metrics")
            Text(FrameMeter.shared.line).font(.system(size: 1)).opacity(0.02)
                .accessibilityIdentifier("gauntlet.frames")
        }
        .onAppear { FrameMeter.shared.start() }
    }
}

/// Freeze-fix perf gate (Simulator) — main-thread frame pacing from a display link, since XCTest's scroll hitch
/// metrics are device-only. Cumulative counters, published every 0.5 s as `frames=N hitches=H hitchMs=X t=S`; the
/// test diffs two readings around its scroll. A hitch = a frame interval > 1.5 × the display's frame duration.
@Observable final class FrameMeter {
    static let shared = FrameMeter()
    var line = ""
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var last: CFTimeInterval = 0
    @ObservationIgnored private var t0: CFTimeInterval = 0
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var hitches = 0
    @ObservationIgnored private var hitchTime: CFTimeInterval = 0
    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        if last > 0 {
            frames += 1
            let dt = now - last, expect = max(l.duration, 1.0 / 120)
            if dt > expect * 1.5 { hitches += 1; hitchTime += dt - expect }
        } else { t0 = now }
        last = now
        if now - lastPublish > 0.5 {
            lastPublish = now
            line = String(format: "frames=%d hitches=%d hitchMs=%.0f t=%.2f", frames, hitches, hitchTime * 1000, now - t0)
        }
    }
}

/// Freeze investigation — reports a row's height to `FreezeProbe` ONLY when the tap is on; otherwise the
/// view is returned untouched (no geometry observer in ordinary DEBUG runs or perf measurements).
struct FreezeRowProbe: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        if GauntletTap.shared.isOn {
            content.onGeometryChange(for: CGFloat.self) { g in
                FreezeProbe.hit(key, Int(g.size.height)); return g.size.height
            } action: { _ in }
        } else {
            content
        }
    }
}

extension View {
    func freezeRowProbe(_ key: String) -> some View { modifier(FreezeRowProbe(key: key)) }
    func gauntletID(_ id: String, combine: Bool = false) -> some View {
        modifier(GauntletA11y(id: id, combine: combine))
    }
}
#endif

#if DEBUG
/// Freeze investigation (CH-0 follow-up) — per-second hit counts + last values at each geometry/preference
/// → state feedback edge, written by a BACKGROUND thread to `<GauntletTapDir>/probe.log`, so it keeps
/// reporting while the main thread spins. Inert without -GauntletTapDir. Measurement only.
final class FreezeProbe: @unchecked Sendable {
    static let shared = FreezeProbe()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var last: [String: String] = [:]
    private let on: Bool
    private init() {
        on = GauntletTap.shared.isOn
        guard on, let dir = GauntletTap.shared.dir else { return }
        let url = dir.appendingPathComponent("probe.log")
        let t0 = Date()
        Thread.detachNewThread { [weak self] in
            while let self {
                Thread.sleep(forTimeInterval: 1)
                self.lock.lock()
                let line = self.counts.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)(\(self.last[$0.key] ?? ""))" }.joined(separator: " ")
                self.counts = [:]
                self.lock.unlock()
                guard !line.isEmpty else { continue }
                let s = String(format: "t=%.0f ", Date().timeIntervalSince(t0)) + line + "\n"
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try? h.close() }
                else { try? s.write(to: url, atomically: false, encoding: .utf8) }
            }
        }
    }
    @inline(__always) static func hit(_ key: String, _ value: Any? = nil) {
        let p = shared
        guard p.on else { return }
        p.lock.lock()
        p.counts[key, default: 0] += 1
        if let value { p.last[key] = "\(value)" }
        p.lock.unlock()
    }
}
#endif

#if DEBUG
/// Freeze-fix gate — content-height CORRECTIONS and offset JUMPS while an answer streams. The streaming
/// tail only grows (a line at a time), so a shrink, a ≥100 pt height step or a ≥200 pt offset step is a
/// lazy row's estimate being replaced by its real size. Cumulative counts/points go to `probe.log`
/// (`stream.heightDown` / `stream.heightJump` / `stream.offsetJump`). Inert unless the tap is on.
final class StreamGeoRecorder {
    static let shared = StreamGeoRecorder()
    private var lastH: CGFloat?
    private var lastOff: CGFloat?
    private var downPt = 0, jumpPt = 0, offPt = 0
    func note(content h: CGFloat, offset y: CGFloat, streaming: Bool) {
        guard GauntletTap.shared.isOn else { return }
        defer { lastH = h; lastOff = y }
        guard streaming, let ph = lastH, let po = lastOff else { return }
        if h < ph - 0.5 { downPt += Int(ph - h); FreezeProbe.hit("stream.heightDown", downPt) }
        if abs(h - ph) >= 100 { jumpPt += Int(abs(h - ph)); FreezeProbe.hit("stream.heightJump", jumpPt) }
        if abs(y - po) >= 200 { offPt += Int(abs(y - po)); FreezeProbe.hit("stream.offsetJump", offPt) }
    }
}
#endif
