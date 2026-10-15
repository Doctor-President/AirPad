import Foundation
import AVFoundation
import Speech

// MARK: - live-11 (4) — the recorder's live, on-device recognition (T approved the renders 2026-10-13)
//
// The microphone tap feeds a `LiveTranscribing` while it writes the file; the words appear as they're spoken and the
// live text IS the saved transcript (no replay after Done). Every recogniser is built by `OnDeviceSpeech`, so nothing
// here can reach Apple's server:
// live-12 (1) — T ruled the Speech chain (2026-10-14), tried best first for each take (`SpeechTier`):
//   1. iOS 26+: `SpeechAnalyzer` + `SpeechTranscriber` — most accurate; takes no vocabulary hints.
//   2. iOS 26+ without it (device/locale/model): the same analyzer session with `DictationTranscriber` + the app words.
//      Long-form by design: one session for the whole take, no recording-length cliff.
//   3. iOS 18–25, or iOS 26 before a model is on the phone: `SFSpeechRecognizer` on-device buffer requests, rotated
//      every `segmentSeconds` (Apple caps a task at about a minute) with each segment's final words carried over.
//   4. none of them: "Transcript unavailable — …"; the audio is kept.
// Platform-neutral (Foundation + AVFoundation + Speech) so the Mac bench compiles this exact file.

/// live-12 (1) — the recorder's on-device speech tiers, best first. Chosen per take from Apple's availability checks
/// (OS, locale, model on the phone), never from the device model.
enum SpeechTier: String, CaseIterable, Sendable {
    case speech, dictation, olderRecognizer, unavailable
    var label: String {
        switch self {
        case .speech: return "Speech"
        case .dictation: return "Dictation"
        case .olderRecognizer: return "Older recognizer"
        case .unavailable: return "Unavailable"
        }
    }
}

/// live-12 (2) — the TestFlight-only "Speech engine (testing)" switch (`SpeechEngineTesting`): Automatic runs the chain;
/// a forced tier starts the chain AT that tier (it still falls to the next one if it can't run, as a real user's would).
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case automatic, speech, dictation, olderRecognizer, unavailable
    var label: String { self == .automatic ? "Automatic" : SpeechTier(rawValue: rawValue)?.label ?? rawValue }
}

/// The words so far — the recorder's ONE text for every tier (live-13 (1)): the screen shows it and Done saves
/// `full`, so what's saved is what was shown. `settled` won't change again; `volatile` is the recogniser's current guess
/// for what's still being spoken. Safe from any thread (results arrive on the recogniser's queues); `onUpdate` gets
/// every change. Words that were shown are never dropped: a recogniser that starts over, or a final that comes back
/// shorter (or empty), adds to the text rather than replacing it (`heard`).
final class LiveText: @unchecked Sendable {
    /// One recognition task's words (tier 3 rotates tasks): the utterances it finished, and the one it's hearing now.
    private struct Segment { var done: [String] = []; var current = ""; var ended = false }

    /// Of tier 3's newest words, this many trailing ones show as the still-changing guess.
    static let heardGuessWords = 4

    private let lock = NSLock()
    private var segments: [Segment] = []     // in order
    private var guess = ""
    private var heardMode = false
    private var restartsKept = 0
    /// How many times a recogniser started over and the earlier words were kept (a count, never words).
    var stats: String { lock.withLock { "restartsKept=\(restartsKept)" } }
    private let onUpdate: @Sendable (_ settled: String, _ volatile: String) -> Void

    init(onUpdate: @escaping @Sendable (String, String) -> Void) { self.onUpdate = onUpdate }

    /// Joins pieces with one space unless a piece already starts with whitespace or punctuation.
    static func join(_ parts: [String]) -> String {
        parts.reduce(into: "") { acc, p in
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            if acc.isEmpty || t.first.map({ ",.;:!?".contains($0) }) == true { acc += t } else { acc += " " + t }
        }
    }

    /// Tiers 1–2 (and the stub): a final result is appended; the guess is replaced.
    func settle(_ text: String) { lock.withLock { segments.append(Segment(done: [text])); guess = "" }; publish() }
    func guessing(_ text: String) { lock.withLock { guess = text }; publish() }

    /// Tier 3: segment `i`'s recogniser re-reads its utterance as it goes. iOS 18+ on-device starts the transcription
    /// over after a pause, and its final (after `endAudio()`) can hold only the last utterance, or nothing — so:
    ///   • empty words never replace anything;
    ///   • words that continue the current utterance (a revision: same opening, not much shorter) replace it;
    ///   • words that don't (`isRestart`) are a new utterance: the old one is kept;
    ///   • words that cover the whole segment (no restart really happened) replace the segment, so nothing doubles.
    func heard(_ i: Int, _ words: String, isFinal: Bool, utteranceEnded: Bool) {
        lock.withLock {
            heardMode = true
            while segments.count <= i { segments.append(Segment()) }
            var seg = segments[i]
            let new = Self.norm(words)
            if !new.isEmpty {
                let whole = Self.norm(Self.join(seg.done + [seg.current]))
                if !seg.done.isEmpty, Self.startsLike(new, whole), new.count + 1 >= whole.count {
                    seg.done = []; seg.current = words
                } else if !seg.current.isEmpty, Self.isRestart(new, Self.norm(seg.current), afterEnd: seg.ended) {
                    seg.done.append(seg.current); seg.current = words; restartsKept += 1
                } else {
                    seg.current = words
                }
                seg.ended = utteranceEnded
            }
            if isFinal, !seg.current.isEmpty { seg.done.append(seg.current); seg.current = ""; seg.ended = false }
            segments[i] = seg
        }
        publish()
    }

    var full: String { lock.withLock { Self.join(parts + [guess]) } }
    var isEmpty: Bool { full.isEmpty }

    private var parts: [String] { segments.flatMap { $0.done + [$0.current] } }   // under the lock

    private static func norm(_ s: String) -> [Substring] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
    }
    /// A new utterance rather than a revision of `old`. A recogniser revising its words keeps how they began and
    /// doesn't shrink them by much; one that started over (after a pause) begins again short — often with the same
    /// first word ("I went home." … "I …"). So: shrinking by 2+ words, or shrinking with a different opening, or —
    /// after an utterance-end marker — anything that doesn't keep the opening AND at least the length.
    private static func isRestart(_ new: [Substring], _ old: [Substring], afterEnd: Bool) -> Bool {
        if new.count + 2 <= old.count { return true }
        if new.count < old.count, !startsLike(new, old) { return true }
        return afterEnd && (!startsLike(new, old) || new.count < old.count)
    }
    /// The first few words agree (a recogniser revising its utterance keeps how it began).
    private static func startsLike(_ a: [Substring], _ b: [Substring]) -> Bool {
        let k = min(3, a.count, b.count)
        return a.prefix(k) == b.prefix(k)
    }

    private func publish() {
        let (s, g) = lock.withLock { () -> (String, String) in
            // Tier 3: the newest utterance's last few words are the still-changing guess.
            if heardMode, guess.isEmpty, let last = segments.lastIndex(where: { !$0.current.isEmpty }) {
                var segs = segments
                let w = segs[last].current.split(separator: " ")
                let cut = max(0, w.count - Self.heardGuessWords)
                segs[last].current = w[..<cut].joined(separator: " ")
                return (Self.join(segs.flatMap { $0.done + [$0.current] }), w[cut...].joined(separator: " "))
            }
            return (Self.join(parts), guess)
        }
        onUpdate(s, g.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

protocol LiveTranscribing: AnyObject, Sendable {
    /// From the audio thread: one buffer in the microphone's format.
    func append(_ buffer: AVAudioPCMBuffer)
    /// End of input: waits (bounded) for the last words to land in the recorder's `LiveText` (what Done saves).
    /// True = unavailable: it errored before hearing any words for a reason other than silence (the on-device engine
    /// couldn't run) — the item then says so.
    func finish() async -> Bool
    func cancel()
}

// MARK: - Tiers 1–2 — iOS 26: SpeechAnalyzer

@available(iOS 26.0, macOS 26.0, *)
enum LiveModule {
    case dictation(DictationTranscriber)
    case speech(SpeechTranscriber)
    var module: any SpeechModule {
        switch self { case .dictation(let m): return m; case .speech(let m): return m }
    }
    var locale: Locale {
        switch self { case .dictation(let m): return m.selectedLocales.first ?? .current
                      case .speech(let m): return m.selectedLocales.first ?? .current }
    }
}

@available(iOS 26.0, macOS 26.0, *)
final class AnalyzerLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let live: LiveModule
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let stream: AsyncStream<AnalyzerInput>
    private let text: LiveText
    private var converter: AVAudioConverter?          // audio thread only
    private var results: Task<Bool, Never>?           // true ⇒ ended in an error before any words

    private init(analyzer: SpeechAnalyzer, live: LiveModule, format: AVAudioFormat, text: LiveText) {
        self.analyzer = analyzer; self.live = live; self.analyzerFormat = format; self.text = text
        (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Prepares the analyzer for `micFormat` and starts listening. Nil ⇒ no usable format (the caller falls back).
    static func start(analyzer: SpeechAnalyzer, live: LiveModule, micFormat: AVAudioFormat,
                      text: LiveText) async -> AnalyzerLiveTranscriber? {
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [live.module], considering: micFormat)
        else { return nil }
        do { try await analyzer.prepareToAnalyze(in: fmt) } catch {
            print("[Speech] recorder analyzer prepare failed: \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
        let t = AnalyzerLiveTranscriber(analyzer: analyzer, live: live, format: fmt, text: text)
        t.results = Task { await t.collect() }
        do { try await analyzer.start(inputSequence: t.stream) } catch {
            print("[Speech] recorder analyzer start failed: \((error as NSError).domain) \((error as NSError).code)")
            t.cancel(); return nil
        }
        return t
    }

    private func collect() async -> Bool {
        do {
            switch live {
            case .dictation(let m):
                for try await r in m.results { r.isFinal ? text.settle(String(r.text.characters)) : text.guessing(String(r.text.characters)) }
            case .speech(let m):
                for try await r in m.results { r.isFinal ? text.settle(String(r.text.characters)) : text.guessing(String(r.text.characters)) }
            }
            return false
        } catch {
            let ns = error as NSError
            print("[Speech] recorder analyzer error domain=\(ns.domain) code=\(ns.code) words=\(!text.isEmpty)")
            return text.isEmpty && OnDeviceSpeech.meansUnavailable(error)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if buffer.format == analyzerFormat { input.yield(AnalyzerInput(buffer: buffer)); return }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: analyzerFormat) }
        guard let converter else { return }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat,
                                         frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() async -> Bool {
        input.finish()
        return await withTimeout(seconds: 6) {
            try? await self.analyzer.finalizeAndFinishThroughEndOfInput()
            return await self.results?.value ?? false
        } ?? false
    }

    func cancel() {
        input.finish()
        results?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }
}

// MARK: - Tier 3 — iOS 18–25 (and iOS 26 before a model is installed): SFSpeechRecognizer, rotated

/// One tier-3 recogniser callback, reduced to what the transcriber uses (injectable: `-RecorderSaveSelfTest`).
struct RecognizerEvent: Sendable {
    var words = ""
    var isFinal = false
    /// The recogniser marked the end of an utterance (`speechRecognitionMetadata` arrives with it).
    var utteranceEnded = false
    var error: NSError?
}

final class SegmentedLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    /// Apple documents roughly a one-minute limit per recognition task; rotate well before it.
    static let segmentSeconds: TimeInterval = 50

    /// Starts a recognition task for segment `index` on `request`, delivering every callback; returns its cancel.
    typealias TaskStarter = (_ index: Int, _ request: SFSpeechAudioBufferRecognitionRequest,
                             _ deliver: @escaping @Sendable (RecognizerEvent) -> Void) -> () -> Void

    private let starter: TaskStarter
    private let finishTimeout: Double
    private let text: LiveText
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest
    private var cancels: [() -> Void] = []
    private var segment = 0
    private var segmentFrames: AVAudioFramePosition = 0
    private var pendingFinals = Set<Int>()
    private var finalsDone: CheckedContinuation<Void, Never>?
    private var failedEmpty = false
    private var sawWords = false
    private var counts = (partials: 0, ended: 0, finals: 0, emptyFinals: 0, errors: 0)
    /// Callback counts for the log and `-RecorderDeviceBench` (counts only, never words).
    var stats: String {
        lock.withLock { "partials=\(counts.partials) ended=\(counts.ended) finals=\(counts.finals) emptyFinals=\(counts.emptyFinals) errors=\(counts.errors) segments=\(segment + 1)" }
            + " " + text.stats
    }

    convenience init(recognizer: SFSpeechRecognizer, text: LiveText) {
        self.init(text: text, finishTimeout: 6) { _, request, deliver in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let e = Self.event(result, error) { deliver(e) }
            }
            return { task.cancel() }
        }
    }

    static func event(_ result: SFSpeechRecognitionResult?, _ error: Error?) -> RecognizerEvent? {
        if let result {
            return RecognizerEvent(words: result.bestTranscription.formattedString, isFinal: result.isFinal,
                                   utteranceEnded: result.speechRecognitionMetadata != nil)
        }
        return error.map { RecognizerEvent(error: $0 as NSError) }
    }

    init(text: LiveText, finishTimeout: Double, starter: @escaping TaskStarter) {
        self.starter = starter
        self.finishTimeout = finishTimeout
        self.text = text
        self.request = OnDeviceSpeech.bufferRequest()
        startTask(for: 0, request: request)
    }

    private func startTask(for index: Int, request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock { _ = pendingFinals.insert(index) }
        let cancel = starter(index, request) { [weak self] event in self?.receive(index, event) }
        lock.withLock { cancels.append(cancel) }
    }

    private func receive(_ index: Int, _ event: RecognizerEvent) {
        lock.withLock {
            if event.error != nil { counts.errors += 1 }
            else if event.isFinal { counts.finals += 1; if event.words.isEmpty { counts.emptyFinals += 1 } }
            else { counts.partials += 1; if event.utteranceEnded { counts.ended += 1 } }
        }
        if let ns = event.error {
            let empty = lock.withLock { !sawWords }
            print("[Speech] recorder segment \(index) error domain=\(ns.domain) code=\(ns.code) words=\(!empty)")
            if empty && OnDeviceSpeech.meansUnavailable(ns) { lock.withLock { failedEmpty = true } }
            segmentEnded(index)
            return
        }
        if !event.words.isEmpty { lock.withLock { sawWords = true } }
        text.heard(index, event.words, isFinal: event.isFinal, utteranceEnded: event.utteranceEnded)
        if event.isFinal { segmentEnded(index) }
    }

    private func segmentEnded(_ index: Int) {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            pendingFinals.remove(index)
            guard pendingFinals.isEmpty, let c = finalsDone else { return nil }
            finalsDone = nil; return c
        }
        resume?.resume()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let rotateTo = lock.withLock { () -> (Int, SFSpeechAudioBufferRecognitionRequest)? in
            segmentFrames += AVAudioFramePosition(buffer.frameLength)
            guard Double(segmentFrames) / buffer.format.sampleRate >= Self.segmentSeconds else { return nil }
            request.endAudio()                     // the old segment finishes and delivers its final words
            segment += 1; segmentFrames = 0
            request = OnDeviceSpeech.bufferRequest()
            return (segment, request)
        }
        if let (i, r) = rotateTo { startTask(for: i, request: r) }
        lock.withLock { request }.append(buffer)
    }

    func finish() async -> Bool {
        lock.withLock { request }.endAudio()
        _ = await withTimeout(seconds: finishTimeout) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let done = self.lock.withLock { () -> Bool in
                    if self.pendingFinals.isEmpty { return true }
                    self.finalsDone = c; return false
                }
                if done { c.resume() }
            }
        }
        let unavailable = lock.withLock { failedEmpty && segment == 0 }
        return unavailable && text.isEmpty
    }

    func cancel() {
        let all = lock.withLock { cancels }
        all.forEach { $0() }
        lock.withLock { request }.endAudio()
    }
}

/// Milliseconds since `t` — for the per-take timing log (times only, never words).
func millis(since t: ContinuousClock.Instant) -> Int {
    let d = ContinuousClock.now - t
    return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

/// Runs `work`, or gives up after `seconds` (nil). The recorder never hangs on a recogniser that won't finish.
/// live-13 (1): a race, not a task group — a group waits for every child, so a child awaiting a callback that never
/// comes (tier 3's final after `endAudio()`) held `finish()`, and Done, open for good.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
    let once = ResumeOnce()
    return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
        let resume: @Sendable (T?) -> Void = { v in if once.claim() { c.resume(returning: v) } }
        let worker = Task { resume(await work()) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            worker.cancel(); resume(nil)
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
}

#if DEBUG
/// `-StubVoiceTranscript <text>` / `-StubLiveTranscript <text>` — the Simulator has no speech model. Words arrive
/// ~3 a second as if spoken, settling a phrase at a time; `finish` returns the whole text (the recording itself is
/// the real path).
final class StubLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    private let words: [String]
    private let text: LiveText
    private var timer: DispatchSourceTimer?
    private var next = 0
    private var phrase: [String] = []

    init(stub: String, text: LiveText) {
        words = stub.split(separator: " ").map(String.init)
        self.text = text
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 0.4, repeating: 1.0 / 3)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    private func tick() {
        guard next < words.count else { return }
        phrase.append(words[next]); next += 1
        if phrase.count >= 5 || phrase.last?.hasSuffix(".") == true {
            text.settle(phrase.joined(separator: " ")); phrase = []
        } else {
            text.guessing(phrase.joined(separator: " "))
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {}
    /// Like a recogniser finalising: the words not yet shown land in the text, which is what Done saves.
    func finish() async -> Bool {
        timer?.cancel(); timer = nil
        let rest = phrase + words[next...]
        phrase = []; next = words.count
        if !rest.isEmpty { text.settle(rest.joined(separator: " ")) }
        return false
    }
    func cancel() { timer?.cancel(); timer = nil }
}
#endif
