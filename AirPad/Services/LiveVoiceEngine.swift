import Foundation
import AVFoundation
import Speech

// MARK: - live-11 (4) — the recorder's live, on-device recognition (T approved the renders 2026-10-13)
//
// The microphone tap feeds a `LiveTranscribing` while it writes the file; the words appear as they're spoken and the
// live text IS the saved transcript (no replay after Done). Every recogniser is built by `OnDeviceSpeech`, so nothing
// here can reach Apple's server:
//   • iOS 26+: `SpeechAnalyzer` + `DictationTranscriber` (or `SpeechTranscriber` — `OnDeviceSpeech.liveModel`, T's call
//     after the WER numbers). Long-form by design: one session for the whole take, no recording-length cliff.
//   • iOS 18–25, or iOS 26 before the model is on the phone: `SFSpeechRecognizer` on-device buffer requests, rotated
//     every `segmentSeconds` (Apple caps a task at about a minute) with each segment's final words carried over.
// Platform-neutral (Foundation + AVFoundation + Speech) so the Mac bench compiles this exact file.

/// Which iOS 26 transcriber the recorder uses.
enum LiveSpeechModel: String { case dictation, speech }

/// The words so far: `settled` won't change again; `volatile` is the recogniser's current guess for what's still being
/// spoken. Safe from any thread (results arrive on the recogniser's queues); `onUpdate` gets every change.
final class LiveText: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [String] = []      // settled text, in order
    private var guess = ""
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

    func settle(_ text: String) { lock.withLock { segments.append(text); guess = "" }; publish() }
    func guessing(_ text: String) { lock.withLock { guess = text }; publish() }
    /// Replace segment `i` (a rotating recogniser rewrites its whole segment as it goes).
    func setSegment(_ i: Int, _ text: String) {
        lock.withLock { while segments.count <= i { segments.append("") }; segments[i] = text }
        publish()
    }
    var full: String { lock.withLock { Self.join(segments + [guess]) } }
    var isEmpty: Bool { full.isEmpty }

    private func publish() {
        let (s, g) = lock.withLock { (Self.join(segments), guess) }
        onUpdate(s, g.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

protocol LiveTranscribing: AnyObject, Sendable {
    /// From the audio thread: one buffer in the microphone's format.
    func append(_ buffer: AVAudioPCMBuffer)
    /// End of input: waits (bounded) for the last words. `unavailable` = it errored before hearing any words for a
    /// reason other than silence (the on-device engine couldn't run) — the item then says so.
    func finish() async -> (text: String, unavailable: Bool)
    func cancel()
}

// MARK: - iOS 26: SpeechAnalyzer

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
                      onUpdate: @escaping @Sendable (String, String) -> Void) async -> AnalyzerLiveTranscriber? {
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [live.module], considering: micFormat)
        else { return nil }
        do { try await analyzer.prepareToAnalyze(in: fmt) } catch {
            print("[Speech] recorder analyzer prepare failed: \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
        let t = AnalyzerLiveTranscriber(analyzer: analyzer, live: live, format: fmt, text: LiveText(onUpdate: onUpdate))
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

    func finish() async -> (text: String, unavailable: Bool) {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        let unavailable = await withTimeout(seconds: 6) { await self.results?.value ?? false } ?? false
        return (text.full, unavailable)
    }

    func cancel() {
        input.finish()
        results?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }
}

// MARK: - iOS 18–25 (and iOS 26 before the model is installed): SFSpeechRecognizer, rotated

final class SegmentedLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    /// Apple documents roughly a one-minute limit per recognition task; rotate well before it.
    static let segmentSeconds: TimeInterval = 50
    /// Of the current segment's words, this many trailing ones show as the still-changing guess.
    static let guessWords = 4

    private let recognizer: SFSpeechRecognizer
    private let text: LiveText
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest
    private var tasks: [SFSpeechRecognitionTask] = []
    private var segment = 0
    private var segmentFrames: AVAudioFramePosition = 0
    private var pendingFinals = Set<Int>()
    private var finalsDone: CheckedContinuation<Void, Never>?
    private var failedEmpty = false
    private var sawWords = false

    init(recognizer: SFSpeechRecognizer, onUpdate: @escaping @Sendable (String, String) -> Void) {
        self.recognizer = recognizer
        self.text = LiveText(onUpdate: onUpdate)
        self.request = OnDeviceSpeech.bufferRequest()
        startTask(for: 0, request: request)
    }

    private func startTask(for index: Int, request: SFSpeechAudioBufferRecognitionRequest) {
        lock.withLock { _ = pendingFinals.insert(index) }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let words = result.bestTranscription.formattedString
                if !words.isEmpty { self.lock.withLock { self.sawWords = true } }
                if result.isFinal {
                    self.text.setSegment(index, words); self.text.guessing("")
                    self.segmentEnded(index)
                } else {
                    // The current segment re-reads itself as it goes: all but its last few words are settled for display.
                    let w = words.split(separator: " ")
                    let cut = max(0, w.count - Self.guessWords)
                    self.text.setSegment(index, w[..<cut].joined(separator: " "))
                    self.text.guessing(w[cut...].joined(separator: " "))
                }
            } else if let error {
                let ns = error as NSError
                let empty = self.lock.withLock { !self.sawWords }
                print("[Speech] recorder segment \(index) error domain=\(ns.domain) code=\(ns.code) words=\(!empty)")
                if empty && OnDeviceSpeech.meansUnavailable(error) { self.lock.withLock { self.failedEmpty = true } }
                self.segmentEnded(index)
            }
        }
        lock.withLock { tasks.append(task) }
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

    func finish() async -> (text: String, unavailable: Bool) {
        lock.withLock { request }.endAudio()
        _ = await withTimeout(seconds: 6) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let done = self.lock.withLock { () -> Bool in
                    if self.pendingFinals.isEmpty { return true }
                    self.finalsDone = c; return false
                }
                if done { c.resume() }
            }
        }
        let unavailable = lock.withLock { failedEmpty && segment == 0 }
        return (text.full, unavailable && text.isEmpty)
    }

    func cancel() {
        let all = lock.withLock { tasks }
        all.forEach { $0.cancel() }
        lock.withLock { request }.endAudio()
    }
}

/// Runs `work`, or gives up after `seconds` (nil). The recorder never hangs on a recogniser that won't finish.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { g in
        g.addTask { await work() }
        g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
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

    init(stub: String, onUpdate: @escaping @Sendable (String, String) -> Void) {
        words = stub.split(separator: " ").map(String.init)
        text = LiveText(onUpdate: onUpdate)
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
    func finish() async -> (text: String, unavailable: Bool) {
        timer?.cancel(); timer = nil
        return (words.joined(separator: " "), false)
    }
    func cancel() { timer?.cancel(); timer = nil }
}
#endif
