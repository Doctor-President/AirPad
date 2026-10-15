#if DEBUG
import Foundation
import AVFoundation
import Speech

/// live-13 (1)–(2) — `-RecorderDeviceBench <tiers> -BenchLabel <label>`: on a real iPhone, synthetic speech files
/// (`Documents/bench/*.wav` + `.txt` reference, copied in by CC) are streamed in real time, 0.1 s buffers like the
/// microphone tap, through each tier's REAL recogniser and the recorder's one `LiveText`. Per take it logs: time to
/// ready, time to first word, words shown at 10/20/30 s, saved = shown, word error rate vs the reference, and for
/// tier 3 the recogniser's callback counts plus what the pre-live-13 overwrite would have saved. Synthetic only; it
/// never touches the library or the microphone. Results also go to `Documents/bench/out-<label>.tsv`.
enum RecorderDeviceBench {

    private final class Probe: @unchecked Sendable {
        let lock = NSLock(), t0 = ContinuousClock.now
        var firstWord: Int?, shown = "", marks: [Int: Int] = [:]
        var lastBySegment: [Int: String] = [:]          // the pre-live-13 overwrite: each segment's last words
        func update(_ s: String, _ v: String) {
            lock.withLock {
                shown = LiveText.join([s, v])
                if firstWord == nil, !shown.isEmpty { firstWord = millis(since: t0) }
            }
        }
    }

    static func run(tiers: [SpeechTier], label: String) async {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bench")
        let wavs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { _ in c.resume() } }
        }
        NSLog("[RecorderDeviceBench] start label=%@ files=%d tiers=%@ auth=%d", label, wavs.count,
              tiers.map(\.rawValue).joined(separator: ","), SFSpeechRecognizer.authorizationStatus().rawValue)
        var out = ["label\ttier\tfile\taudio_s\tready_ms\tfirst_word_ms\tshown_10s\tshown_20s\tshown_30s\tsaved_words\tsaved_eq_shown\twer\told_overwrite_wer\tfinish_ms\tstats"]
        for wav in wavs {
            let ref = (try? String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
            for tier in tiers {
                let row = await take(wav: wav, ref: ref, tier: tier, label: label)
                NSLog("[RecorderDeviceBench] %@", row.replacingOccurrences(of: "\t", with: " · "))
                out.append(row)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("out-\(label).tsv"), atomically: true, encoding: .utf8)
        NSLog("[RecorderDeviceBench] done label=%@", label)
    }

    private static func take(wav: URL, ref: String, tier: SpeechTier, label: String) async -> String {
        guard let file = try? AVAudioFile(forReading: wav) else { return "\(label)\t\(tier.rawValue)\t\(wav.lastPathComponent)\tunreadable" }
        let fmt = file.processingFormat
        let probe = Probe()
        let text = LiveText { s, v in probe.update(s, v) }
        let transcriber: (any LiveTranscribing)?
        if tier == .olderRecognizer, let recognizer = OnDeviceSpeech.recognizer() {
            // The production starter, plus a record of each segment's last words (the old overwrite's result).
            transcriber = SegmentedLiveTranscriber(text: text, finishTimeout: 6) { i, request, deliver in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    guard let e = SegmentedLiveTranscriber.event(result, error) else { return }
                    if e.error == nil { probe.lock.withLock { probe.lastBySegment[i] = e.words } }
                    deliver(e)
                }
                return { task.cancel() }
            }
        } else {
            transcriber = await LiveVoiceRecorder.transcriber(for: tier, micFormat: fmt, text: text)
        }
        let ready = millis(since: probe.t0)
        guard let transcriber else {
            return "\(label)\t\(tier.rawValue)\t\(wav.lastPathComponent)\t\t\(ready)\tCAN'T RUN"
        }
        // Real time: one 0.1 s buffer every 0.1 s, from a background thread like the tap.
        let audioSeconds = Double(file.length) / fmt.sampleRate
        let streamStart = ContinuousClock.now
        await Task.detached {
            let chunk = AVAudioFrameCount(fmt.sampleRate / 10)
            var sent = 0.0, n = 0
            while true {
                guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk), (try? file.read(into: b, frameCount: chunk)) != nil,
                      b.frameLength > 0 else { break }
                transcriber.append(b)
                sent += Double(b.frameLength) / fmt.sampleRate; n += 1
                for mark in [10, 20, 30] where n == mark * 10 {
                    probe.lock.withLock { probe.marks[mark] = probe.shown.split(separator: " ").count }
                }
                let due = streamStart + .milliseconds(Int(sent * 1000))
                if due > .now { try? await Task.sleep(until: due, clock: .continuous) }
            }
        }.value
        let finishStart = ContinuousClock.now
        _ = await transcriber.finish()
        let finishMs = millis(since: finishStart)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let saved = text.full
        let (shown, first, marks, last) = probe.lock.withLock { (probe.shown, probe.firstWord, probe.marks, probe.lastBySegment) }
        let old = last.isEmpty ? "" : LiveText.join(last.keys.sorted().map { last[$0] ?? "" })
        let stats = (transcriber as? SegmentedLiveTranscriber)?.stats ?? ""
        try? saved.write(to: wav.deletingLastPathComponent().appendingPathComponent("saved-\(label)-\(tier.rawValue)-\(wav.deletingPathExtension().lastPathComponent).txt"),
                         atomically: true, encoding: .utf8)
        func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
        return [label, tier.rawValue, wav.lastPathComponent, String(format: "%.1f", audioSeconds), "\(ready)", first.map(String.init) ?? "none",
                "\(marks[10] ?? -1)", "\(marks[20] ?? -1)", "\(marks[30] ?? -1)", "\(saved.split(separator: " ").count)",
                "\(saved == shown)", pct(wer(ref, saved)), tier == .olderRecognizer ? pct(wer(ref, old)) : "", "\(finishMs)", stats]
            .joined(separator: "\t")
    }

    /// Word error rate, case and punctuation ignored.
    static func wer(_ ref: String, _ hyp: String) -> Double {
        func words(_ s: String) -> [Substring] { s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }) }
        let r = words(ref), h = words(hyp)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var d = Array(0...h.count)
        for i in 1...r.count {
            var prev = d[0]; d[0] = i
            for j in stride(from: 1, through: h.count, by: 1) {
                let tmp = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] == h[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return Double(d[h.count]) / Double(r.count)
    }
}
#endif
