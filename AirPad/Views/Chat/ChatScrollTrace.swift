import Foundation

#if DEBUG || TESTFLIGHT
/// live-29 (C1) — T (device, TF 202610191107): in a chat of about 5 turns the transcript stops short of the end and the ↓
/// arrow "goes down a bit, then springs back up". Not reproduced in the Simulator (iOS 27.0 / 26.5, seeded chats of
/// 8–200 messages with every element, and 7 live turns through the Host path). This keeps the transcript's scroll
/// geometry IN MEMORY — the last 600 changes (content height, offset, container, insets) and the scroll events (opened,
/// sent, ↓ arrow, scroll-to) — so Settings → "Copy Librarian log" carries it when T reproduces it on device. TestFlight
/// and DEBUG only: compiled out of the App Store build. Numbers only, never message text.
final class ChatScrollTrace {
    static let shared = ChatScrollTrace()
    private struct Sample { let t: TimeInterval; let content, container, offY, insetB: Double; let n: Int; let event: String? }
    private var ring: [Sample] = []
    private var next = 0
    private let cap = 600
    private let t0 = Date().timeIntervalSince1970

    func geometry(content: Double, container: Double, offY: Double, insetB: Double, messages: Int) {
        // only a change worth a row: a moved offset or a new height (sub-point jitter dropped)
        if let last = lastSample, abs(last.content - content) < 0.5, abs(last.offY - offY) < 0.5, abs(last.container - container) < 0.5 { return }
        put(Sample(t: Date().timeIntervalSince1970 - t0, content: content, container: container, offY: offY, insetB: insetB, n: messages, event: nil))
    }
    func event(_ name: String, messages: Int) {
        let l = lastSample
        put(Sample(t: Date().timeIntervalSince1970 - t0, content: l?.content ?? 0, container: l?.container ?? 0, offY: l?.offY ?? 0,
                   insetB: l?.insetB ?? 0, n: messages, event: name))
    }
    private var lastSample: Sample? { ring.isEmpty ? nil : ring[(next - 1 + ring.count) % ring.count] }
    private func put(_ s: Sample) {
        if ring.count < cap { ring.append(s); next = ring.count % cap } else { ring[next] = s; next = (next + 1) % cap }
    }

    /// The trace, oldest first: one line per change; "past end" = how far the bottom of the view is past the content's end
    /// (negative = short of the end).
    func text() -> String {
        guard !ring.isEmpty else { return "(no chat scrolling recorded this session)" }
        let ordered = ring.count < cap ? ring : Array(ring[next...] + ring[..<next])
        return "— chat scroll trace (live-29 C1): t s · messages · content · container · offset · inset-bottom · past end —\n"
            + ordered.map { s in
                let past = s.offY + s.container - s.insetB - s.content
                let row = String(format: "%.2f n=%d content=%.0f container=%.0f off=%.0f insetB=%.0f pastEnd=%.0f",
                                 s.t, s.n, s.content, s.container, s.offY, s.insetB, past)
                return s.event.map { "\(row) ← \($0)" } ?? row
            }.joined(separator: "\n")
    }
}
#endif
