#if DEBUG
import Foundation
import AVFoundation
import Speech

/// live-13 (1) — `-RecorderSaveSelfTest`: what Done saves is what the recorder showed, on every tier. The Simulator has
/// no speech model, so tier 3 (`SegmentedLiveTranscriber`) is driven with injected recogniser callbacks — partials,
/// utterance ends, a 50 s rotation, finals that arrive after Done — including the iOS 18+ on-device behaviour T's
/// device check hit: after a pause the recogniser starts its transcription over, and the final result after
/// `endAudio()` holds only the last utterance, or nothing. Synthetic words only.
enum RecorderSaveSelfTest {

    /// The last (settled, volatile) the recorder was handed — what the screen showed.
    private final class Shown: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = "", volatile = ""
        func set(_ s: String, _ v: String) { lock.withLock { settled = s; volatile = v } }
        var text: String { lock.withLock { LiveText.join([settled, volatile]) } }
    }

    /// One scripted take: events before Done, then Done, then the events that land after `endAudio()`.
    private final class Take: @unchecked Sendable {
        let shown = Shown()
        let text: LiveText
        let transcriber: SegmentedLiveTranscriber
        private let wires = Wires()

        /// Each segment's callback, as the transcriber's starter handed it over.
        private final class Wires: @unchecked Sendable {
            private let lock = NSLock()
            private var deliver: [Int: @Sendable (RecognizerEvent) -> Void] = [:]
            func set(_ i: Int, _ d: @escaping @Sendable (RecognizerEvent) -> Void) { lock.withLock { deliver[i] = d } }
            func get(_ i: Int) -> (@Sendable (RecognizerEvent) -> Void)? { lock.withLock { deliver[i] } }
        }

        init() {
            let shown = self.shown, wires = self.wires
            text = LiveText { s, v in shown.set(s, v) }
            transcriber = SegmentedLiveTranscriber(text: text, finishTimeout: 0.5) { i, _, d in wires.set(i, d); return {} }
        }

        func partial(_ i: Int, _ w: String) { send(i, RecognizerEvent(words: w)) }
        func ended(_ i: Int, _ w: String) { send(i, RecognizerEvent(words: w, utteranceEnded: true)) }
        func final(_ i: Int, _ w: String) { send(i, RecognizerEvent(words: w, isFinal: true, utteranceEnded: true)) }
        func error(_ i: Int, _ code: Int) { send(i, RecognizerEvent(error: NSError(domain: "kAFAssistantErrorDomain", code: code))) }
        private func send(_ i: Int, _ e: RecognizerEvent) { wires.get(i)?(e) }

        /// 50 s of silence: crosses `segmentSeconds`, so segment 1's task starts.
        func rotate() {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            for _ in 0..<5 {
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 160_000)!
                b.frameLength = 160_000
                transcriber.append(b)
            }
        }

        /// Done: finish (bounded by the test's own race, so a hung finish FAILs instead of hanging), with `after`
        /// delivered once `endAudio()` has been called. Returns what the recorder saves, or nil if finish hung.
        func done(after: @escaping @Sendable (Take) -> Void = { _ in }) async -> (saved: String, unavailable: Bool)? {
            let t = transcriber, text = text
            Task.detached { try? await Task.sleep(nanoseconds: 50_000_000); after(self) }
            guard let u = await RecorderSaveSelfTest.race(seconds: 3, { await t.finish() }) else { return nil }
            return (text.full, u)
        }
    }

    /// A timeout that never waits for a child that ignores cancellation (independent of the code under test).
    static func race<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        let once = RaceOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let resume: @Sendable (T?) -> Void = { v in
                if once.lock.withLock({ () -> Bool in defer { once.fired = true }; return !once.fired }) { c.resume(returning: v) }
            }
            Task.detached { resume(await work()) }
            Task.detached { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); resume(nil) }
        }
    }

    private final class RaceOnce: @unchecked Sendable { let lock = NSLock(); var fired = false }

    static func run() async -> String {
        var rows: [String] = [], fails = 0
        func check(_ name: String, _ take: Take, _ result: (saved: String, unavailable: Bool)?, expect: String) {
            guard let result else { rows.append("FAIL \(name) — finish never returned"); fails += 1; return }
            let shown = take.shown.text
            let ok = result.saved == expect && shown == result.saved && !result.unavailable
            rows.append("\(ok ? "PASS" : "FAIL") \(name)" + (ok ? "" : " — saved=\"\(result.saved)\" shown=\"\(shown)\" want=\"\(expect)\""))
            if !ok { fails += 1 }
        }

        // 1. The steady case: one utterance, its final completes it.
        var t = Take()
        t.partial(0, "I asked"); t.partial(0, "I asked the Librarian")
        check("steady-final-completes", t, await t.done { $0.final(0, "I asked the Librarian about Quick Capture") },
              expect: "I asked the Librarian about Quick Capture")

        // 2. iOS 18+ on-device: a pause restarts the transcription; the final after Done is empty.
        t = Take()
        t.partial(0, "how are you"); t.ended(0, "how are you today"); t.partial(0, "fine"); t.partial(0, "fine thanks")
        check("pause-restart-final-empty", t, await t.done { $0.final(0, "") }, expect: "how are you today fine thanks")

        // 3. …and the final after Done holds only the last utterance.
        t = Take()
        t.partial(0, "the shelf holds"); t.ended(0, "the shelf holds three boxes"); t.partial(0, "and a lamp")
        check("pause-restart-final-last-utterance", t, await t.done { $0.final(0, "and a lamp") },
              expect: "the shelf holds three boxes and a lamp")

        // 4. A restart with no end marker: a long utterance, then a short new one.
        t = Take()
        t.partial(0, "we walked along the river path"); t.partial(0, "slowly")
        check("restart-without-end-marker", t, await t.done { $0.final(0, "slowly") },
              expect: "we walked along the river path slowly")

        // 5. A short utterance after an end marker.
        t = Take()
        t.ended(0, "okay"); t.partial(0, "so")
        check("short-utterance-after-end-marker", t, await t.done { $0.final(0, "") }, expect: "okay so")

        // 6. The 50 s rotation: segment 0's final lands late and empty while segment 1 is talking.
        t = Take()
        t.partial(0, "first segment words here"); t.rotate()
        t.partial(1, "second segment begins"); t.final(0, ""); t.partial(1, "second segment begins now")
        check("rotation-late-empty-final", t, await t.done { $0.final(1, "") },
              expect: "first segment words here second segment begins now")

        // 7. The rotation: segment 0's late final only revises punctuation.
        t = Take()
        t.partial(0, "alpha beta gamma"); t.rotate(); t.partial(1, "delta"); t.final(0, "alpha beta gamma.")
        check("rotation-late-final-revises", t, await t.done { $0.final(1, "delta epsilon") },
              expect: "alpha beta gamma. delta epsilon")

        // 8. The rotation inside a paused take: segment 0 restarted before rotating; its final keeps the last part only.
        t = Take()
        t.ended(0, "one long thought"); t.partial(0, "another one"); t.rotate()
        t.partial(1, "after the boundary"); t.final(0, "another one")
        check("rotation-after-restart", t, await t.done { $0.final(1, "") },
              expect: "one long thought another one after the boundary")

        // 9. No final ever arrives after Done: the shown words are saved, and finish is bounded.
        t = Take()
        t.partial(0, "words before done")
        check("final-never-arrives", t, await t.done(), expect: "words before done")

        // 10. A final that carries the whole take (no restart happened) is not doubled.
        t = Take()
        t.partial(0, "one two three four five"); t.partial(0, "six")
        check("final-full-text-not-doubled", t, await t.done { $0.final(0, "one two three four five six") },
              expect: "one two three four five six")

        // 11. A first-word revision as the utterance grows is not a restart.
        t = Take()
        t.partial(0, "eye"); t.partial(0, "I asked")
        check("first-word-revision-not-doubled", t, await t.done { $0.final(0, "I asked her") }, expect: "I asked her")

        // 12. "No speech" after words: the words are kept, the take isn't unavailable.
        t = Take()
        t.partial(0, "kept words")
        check("no-speech-error-keeps-words", t, await t.done { $0.error(0, 1110) }, expect: "kept words")

        // 13. After a pause, the next sentence starts with the same word as the last one.
        t = Take()
        t.ended(0, "I went home"); t.partial(0, "I"); t.partial(0, "I went out")
        check("same-first-word-after-end-marker", t, await t.done { $0.final(0, "") }, expect: "I went home I went out")

        // 14. …and with no end marker.
        t = Take()
        t.partial(0, "the lamp is on the shelf"); t.partial(0, "the"); t.partial(0, "the box is under it")
        check("same-first-word-without-marker", t, await t.done { $0.final(0, "the box is under it") },
              expect: "the lamp is on the shelf the box is under it")

        // 15. Tiers 1–2 and the stub (append path): saved = shown, including the trailing guess at Done.
        let shown = Shown()
        let live = LiveText { s, v in shown.set(s, v) }
        live.settle("Settled words."); live.guessing("still guessing")
        let ok = live.full == "Settled words. still guessing" && shown.text == live.full
        rows.append("\(ok ? "PASS" : "FAIL") append-path-saved-equals-shown"); if !ok { fails += 1 }

        return "[RecorderSaveSelfTest] \(fails == 0 ? "PASS" : "FAIL") — \(rows.count - fails)/\(rows.count)\n"
            + rows.joined(separator: "\n")
    }
}
#endif
