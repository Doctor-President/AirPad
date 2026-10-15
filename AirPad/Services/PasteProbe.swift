#if DEBUG
import SwiftUI
import QuartzCore

/// live-11 (2) — `-PasteProbe`: what a long paste costs, measured in the app (T: pasting long copied text "glitched" and
/// the auto-title took ~10 s). Two numbers per paste, read by `LongPaste` (XCUITest) from the `pasteProbe` element:
///   • main-thread STALLS — a display link ticks every frame while the main thread is free, so the gap between two
///     ticks is how long the main thread was busy (blocked or spinning alike). Gaps ending from 1 s before the paste
///     was seen (its own insert + layout run before the editor reports the change) to 8 s after it count.
///   • paste → naming → ghost — when the naming call starts (and how many characters it reads), and when the ghost
///     title lands on screen (its shimmer trigger).
/// Content-free: lengths and milliseconds only. DEBUG-only.
@MainActor @Observable
final class PasteProbe {
    static let shared = PasteProbe()
    static let enabled = ProcessInfo.processInfo.arguments.contains("-PasteProbe")
    /// A paste is a single editor change that grows the text by more than this (typing adds 1–2 per change).
    static var pasteThreshold: Int { CorpusStore.pieceLandingChars }
    /// Stalls count from 1 s before the paste to this long after it.
    static let window: CFTimeInterval = 8

    private(set) var summary = "idle"

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var stalls: [(end: CFTimeInterval, ms: Double)] = []
    @ObservationIgnored private var pasteAt: CFTimeInterval?
    @ObservationIgnored private var pasteChars = 0
    @ObservationIgnored private var namingAt: CFTimeInterval?
    @ObservationIgnored private var namingChars = 0
    @ObservationIgnored private var ghostAt: CFTimeInterval?
    @ObservationIgnored private var shimmerAt: CFTimeInterval?

    private init() {}

    func start() {
        guard Self.enabled, link == nil else { return }
        let l = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = CACurrentMediaTime()
        NotificationCenter.default.addObserver(forName: .ghostProbe, object: nil, queue: .main) { note in
            let kind = note.object as? String
            MainActor.assumeIsolated { kind == "shimmer" ? PasteProbe.shared.noteShimmer() : PasteProbe.shared.noteGhost() }
        }
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        let gapMs = (now - lastTick) * 1000
        lastTick = now
        guard gapMs > 50 else { return }
        stalls.append((now, gapMs))
        if stalls.count > 500 { stalls.removeFirst(stalls.count - 500) }
        if pasteAt != nil { refresh() }
    }

    /// The note editor saw one change grow the text by `added` characters (UTF-16).
    func notePaste(added: Int) {
        guard Self.enabled, added > Self.pasteThreshold else { return }
        pasteAt = CACurrentMediaTime(); pasteChars = added
        namingAt = nil; namingChars = 0; ghostAt = nil; shimmerAt = nil
        refresh()
    }

    /// The naming call started, reading `chars` characters of the entry.
    nonisolated static func noteNaming(chars: Int) {
        guard enabled else { return }
        let t = CACurrentMediaTime()
        Task { @MainActor in shared.recordNaming(at: t, chars: chars) }
    }

    private func recordNaming(at t: CFTimeInterval, chars: Int) {
        guard let p = pasteAt, t >= p, namingAt == nil else { return }
        namingAt = t; namingChars = chars
        refresh()
    }

    /// A ghost's shimmer sweep started.
    func noteShimmer() {
        guard Self.enabled, pasteAt != nil, shimmerAt == nil else { return }
        shimmerAt = CACurrentMediaTime()
        refresh()
    }

    /// A ghost reached the screen.
    func noteGhost() {
        guard Self.enabled, pasteAt != nil, ghostAt == nil else { return }
        ghostAt = CACurrentMediaTime()
        refresh()
    }

    private func refresh() {
        guard let p = pasteAt else { return }
        // An XCUITest's accessibility snapshot runs on the app's main thread (and walks a 20k-character text view), so
        // the test stays silent for `window` after the paste and only reads the probe afterwards — outside the window.
        let window = stalls.filter { $0.end >= p - 1.0 && $0.end <= p + Self.window }
        let ms = { (t: CFTimeInterval?) in t.map { Int(($0 - p) * 1000) } ?? -1 }
        let worst = window.max { $0.ms < $1.ms }
        // `worstAt` = when that stall ENDED, relative to the paste (negative: before the editor reported it).
        summary = "paste=\(pasteChars) stallMax=\(Int(worst?.ms ?? 0))ms worstAt=\(worst.map { Int(($0.end - p) * 1000) } ?? 0)ms"
            + " stalls100=\(window.filter { $0.ms >= 100 }.count) stalls250=\(window.filter { $0.ms >= 250 }.count)"
            + " stallTotal=\(Int(window.map(\.ms).reduce(0, +)))ms"
            + " naming=\(ms(namingAt))ms namingChars=\(namingChars) ghost=\(ms(ghostAt))ms shimmer=\(ms(shimmerAt))ms"
        NSLog("[PasteProbe] %@", summary)
    }

    /// CADisplayLink retains its target; a small trampoline keeps the probe a plain @Observable.
    private final class Ticker: NSObject {
        weak var probe: PasteProbe?
        init(_ p: PasteProbe) { probe = p }
        @objc func tick() { MainActor.assumeIsolated { probe?.tick() } }
    }
}

/// The probe's read-out for an XCUITest. Invisible, never hit-testable.
struct PasteProbeView: View {
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier("pasteProbe")
            .accessibilityLabel(PasteProbe.shared.summary)
            .allowsHitTesting(false)
            .onAppear { PasteProbe.shared.start() }
    }
}
#endif
