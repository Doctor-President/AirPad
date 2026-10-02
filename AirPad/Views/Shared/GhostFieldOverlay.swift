import SwiftUI

// MARK: - Brief CD — the ghost suggestion overlay (reusable; proven dependency-free)
//
// Share-sheet readiness (ws-share-sheet §3 / Brief CG): this view is self-contained — SwiftUI +
// Foundation only, no CorpusStore / app singletons / AppearancePalette / hexString (the ink is
// INJECTED; the glint is Color.white). Moved here from QuikCaptureView (Brief CG) so the AirPadShare
// extension's lighter share editor can compile the SAME component — a pure move, NO code change.

/// Low-opacity model-suggested text rendered INSIDE an empty Title/Summary field of a fresh capture,
/// that plays the lever's specular shimmer when a NEW suggestion lands (rule 2). Store-free +
/// app-singleton-free — text + resolved Font + opacity in, shimmer `trigger` in — so the share editor
/// can reuse the SAME component (ws-share-sheet §3). The host owns WHICH proposal + what Accept does;
/// this view only renders. Reads as app-INK (not the system-gray placeholder — rule 7).
struct GhostFieldOverlay: View {
    let text: String
    let font: Font
    /// The adaptive text ink, INJECTED (not read from `AppearancePalette`) so the component has zero
    /// main-app-only dependencies and compiles unchanged into the share extension (ws-share-sheet §3).
    /// The host passes `AppearancePalette.ink`; a share editor passes its own.
    var ink: Color = .primary
    /// Ghost opacity (Brief CD1 look option; T picks). Applied to the adaptive ink.
    var opacity: Double = 0.45
    /// Bump when a NEW suggestion lands → the shimmer plays ONCE (rule 2). Never on re-render.
    var shimmerTrigger: Int = 0
    /// Reduce Motion → no sweep; the ghost just appears (crossfade — the resting dimness carries it).
    var reduceMotion: Bool = false
    /// The lever's shipped shimmer timing (LeverShimmerTuning default) so the ghost matches its vocabulary.
    var shimmerDuration: Double = 1.95
    /// Gallery demo ONLY (`-GhostGallery`) — repeat the sweep on appear so the screen recording shows
    /// it. The real capture leaves this false and drives ONE pass per new suggestion via `shimmerTrigger`.
    var demoLoop: Bool = false

    /// One-shot sweep driven by the CLOCK, not by `withAnimation`: `playStart` stamps when a new
    /// suggestion landed and the TimelineView derives the glint's phase from elapsed time (a
    /// @State + withAnimation offset *inside a mask* does not animate — proven in the CD1 gallery).
    /// `playing` pauses the TimelineView once the single pass finishes, so an idle ghost (the common
    /// case while the user reads/types) costs zero per-frame work.
    @State private var playStart: Date = .distantPast
    @State private var playing: Bool = false

    var body: some View {
        let glyphs = Text(text).font(font).frame(maxWidth: .infinity, alignment: .leading)
        // Paused unless a one-shot is mid-pass (real capture) or the gallery is looping; Reduce Motion
        // never animates (the resting dimness carries the ghost — rule 2's crossfade fallback).
        TimelineView(.animation(paused: reduceMotion || !(playing || demoLoop))) { tl in
            glyphs
                .foregroundStyle(ink.opacity(opacity))
                .overlay {
                    if !reduceMotion, playing || demoLoop { glint(at: phase(at: tl.date)) }
                }
        }
        .allowsHitTesting(false)
        .accessibilityLabel(text.isEmpty ? "" : "Suggested: \(text)")
        // The host keeps this overlay mounted for the whole empty-field lifetime and bumps
        // `shimmerTrigger` only when the model proposes NEW text, so onChange fires exactly once per
        // new suggestion (rule 2) — never on a focus toggle, scroll, or field re-empty (no remount play).
        .onChange(of: shimmerTrigger) { _, _ in play() }
    }

    /// Start a single sweep. Reduce Motion shows the ghost with no glint (just the resting dimness).
    private func play() {
        guard !reduceMotion else { return }
        playStart = Date()
        playing = true
        let ns = UInt64((shimmerDuration + 0.15) * 1_000_000_000)
        Task { try? await Task.sleep(nanoseconds: ns); playing = false }   // pause after the one pass
    }

    /// Glint phase as a multiple of the ghost width: off-screen LEFT (-1.3) → off-screen RIGHT (1.3)
    /// across `shimmerDuration`; the gallery loops it on a 2.4 s clock so the recording repeats. Rests
    /// at 1.3 (off-screen → glint hidden) when a one-shot pass is over.
    private func phase(at now: Date) -> CGFloat {
        if demoLoop {
            let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            return CGFloat(t) * 2.6 - 1.3
        }
        let e = now.timeIntervalSince(playStart)
        guard e >= 0, e < shimmerDuration else { return 1.3 }   // rest off-screen RIGHT (hidden)
        return CGFloat(e / shimmerDuration) * 2.6 - 1.3
    }

    /// The lever's specular glint (white, luminance-only — T is colourblind): a WHITE copy of the
    /// ghost text revealed only under a moving gradient slice at phase `p`, so a bright sweep travels
    /// the glyphs. `p` rests at ±1.3 (off-screen → hidden); the sweep crosses 0 (glint over the text).
    private func glint(at p: CGFloat) -> some View {
        Text(text).font(font).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.white)   // luminance-only glint (T is colourblind); no app-only helper
            .mask {
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.5)
                        .offset(x: p * w)
                }
            }
    }
}
