import SwiftUI
import UIKit

/// Stage 4.7 C2 — Paste Pad's visual layer. Reads the system clipboard
/// on appear and on `UIPasteboard.changedNotification`, classifies the
/// payload via `ClipboardContentRouter`, and renders one of two states:
///
///   - `.empty` → dimmed, static "Paste anything" — tap is a no-op
///   - anything else → primed, type-aware label, continuous shimmer —
///     tap fires `onPaste(content)` (routing is C3 territory; C2's call
///     site passes an empty closure)
///
/// C2 deliberately does **not** route content. The tap-to-paste handlers
/// (`handlePastedURL`/`Image`/`Video`/`File`/`Text`/`Multi`) land in C3
/// inside `NodeDetailView` so the integration surface stays in one place.
///
/// Visual rhyme with `EntryCard`: same `EntryCardBackground` treatment,
/// same corner radius (sourced from `EntryVisualSettings.shared` so the
/// dev-panel knobs continue to drive the surface during Stage 4.4
/// iteration). Horizontal padding is inherited from the parent
/// `NodeDetailView` ScrollView VStack (`.padding(20)` outer) — Paste Pad
/// itself is full-width within that container, matching how `EntryCard`
/// lays itself out.
///
/// Clipboard observation lifecycle:
///   - `.onAppear` → read + classify, then start subscriptions
///   - `UIPasteboard.changedNotification` → re-read + reclassify
///   - `UIApplication.didBecomeActiveNotification` → re-read on
///     foreground (cross-app copies don't always re-post
///     `changedNotification` when AirPad was backgrounded; this is the
///     narrow divergence from the brief's "only on changedNotification"
///     language — the acceptance "Clipboard change while user is in
///     detail view: Paste Pad updates label and state within a beat"
///     requires it for the common path of "user leaves AirPad, copies
///     something elsewhere, returns").
///   - `.onDisappear` → no explicit teardown needed (`.onReceive`
///     subscriptions live with the view's lifetime)
///
/// **iOS 14+ pasteboard banner is expected.** Reading
/// `UIPasteboard.general` triggers a system "AirPad pasted from <app>"
/// banner. That's iOS's intended privacy surface; we don't fight it.
/// To minimize how often it fires we read only at the three points
/// above — never on every redraw. The router's classification is pure
/// and synchronous; we don't re-read inside the body.
///
/// **Shimmer animation — tunable.** Constants at the bottom of this
/// file (`Shimmer.cycle`, `.baseOpacity`, `.peakOpacity`, `.bandWidth`)
/// are first-pass values. T will dial on device. Approach: brightness-
/// only modulation via a `LinearGradient` mask sliding across an
/// overlay-rendered copy of the label. No hue shift, no transform —
/// peripheral-vision calm in a populated node was the design intent.
struct PastePadView: View {

    /// Callback fired on tap when there's readable content on the
    /// clipboard. C2 doesn't route; the call site can pass `{ _ in }`
    /// and wire the real handler in C3.
    let onPaste: (ClipboardContent) -> Void

    @State private var content: ClipboardContent = .empty

    /// Stage 4.4 dev-panel surface; same instance `EntryCard` reads so
    /// Paste Pad tracks corner-radius / body-treatment changes during
    /// Stage 4.4 iteration.
    @State private var visualSettings = EntryVisualSettings.shared

    private var isPrimed: Bool {
        if case .empty = content { return false }
        return true
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(isPrimed ? Shimmer.baseOpacity : 0.35))

            label
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .padding(.horizontal, 16)
        .background {
            EntryCardBackground(treatment: visualSettings.bodyTreatment)
                .opacity(isPrimed ? 1.0 : 0.55)
        }
        .clipShape(RoundedRectangle(cornerRadius: visualSettings.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: visualSettings.cornerRadius))
        .onTapGesture { handleTap() }
        .onAppear {
            refreshFromClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshFromClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshFromClipboard()
        }
        .animation(.easeInOut(duration: 0.2), value: isPrimed)
    }

    // MARK: - Label rendering

    @ViewBuilder
    private var label: some View {
        let text = Self.labelText(for: content)

        if isPrimed {
            // Brightness-only shimmer: render the label twice — once at
            // base opacity (always visible), once at peak opacity but
            // masked by a sliding gradient band so only the band region
            // shows the brighter copy. `TimelineView(.animation)` drives
            // continuous phase; no hue shift, no transform.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let phase = Self.shimmerPhase(at: context.date)
                ZStack {
                    Text(text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(Shimmer.baseOpacity))

                    Text(text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(Shimmer.peakOpacity))
                        .mask {
                            GeometryReader { geo in
                                LinearGradient(
                                    colors: [.clear, .white, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: geo.size.width * Shimmer.bandWidth)
                                // Sweep the band from off-left (-band)
                                // to off-right (width + band) so its
                                // entrance and exit are both off-screen.
                                .offset(x: Self.shimmerOffsetX(
                                    in: geo.size.width,
                                    phase: phase
                                ))
                            }
                        }
                }
            }
            .lineLimit(1)
        } else {
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
    }

    // MARK: - Tap handling

    private func handleTap() {
        // Empty state is a deliberate no-op per the brief — no toast,
        // no error. Tap on primed → invoke callback (C3 wires routing).
        guard isPrimed else { return }
        onPaste(content)
    }

    // MARK: - Clipboard refresh

    private func refreshFromClipboard() {
        let next = ClipboardContentRouter.classify()
        // Pasteboard reads themselves don't invoke SwiftUI redraws — we
        // assign the result, and the `isPrimed` derived state drives the
        // visual transition. The `.animation` modifier on the view
        // handles the cross-fade between empty and primed surfaces.
        content = next
    }

    // MARK: - Shimmer math

    /// Phase ∈ [0, 1). Computed off the timeline date so the animation
    /// is fully time-driven — no `withAnimation`, no `.repeatForever`,
    /// no internal `@State` clocking. Pauses cleanly when `isPrimed`
    /// flips false (the entire `TimelineView` branch is unmounted).
    private static func shimmerPhase(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let cycle = Shimmer.cycle
        let phase = (t.truncatingRemainder(dividingBy: cycle)) / cycle
        return CGFloat(phase)
    }

    /// Maps `phase ∈ [0, 1)` to a horizontal offset that sweeps the
    /// gradient band from fully off-left to fully off-right of the
    /// label region. Travel distance is `width + band` so the band's
    /// leading and trailing edges both leave the visible area.
    private static func shimmerOffsetX(in width: CGFloat, phase: CGFloat) -> CGFloat {
        let band = width * Shimmer.bandWidth
        let travel = width + band
        return -band + travel * phase
    }

    // MARK: - Label text

    /// Type-aware labels per the brief's locked table. Multi-item
    /// receives one of two shapes:
    ///   - all items same kind → "Paste N {plural-kind} here"
    ///   - mixed kinds → "Paste N items here"
    static func labelText(for content: ClipboardContent) -> String {
        switch content {
        case .empty: return "Paste anything"
        case .url: return "Paste link here"
        case .image: return "Paste image here"
        case .video: return "Paste video here"
        case .file: return "Paste document here"
        case .text: return "Paste text here"
        case .multi(let items):
            return multiLabel(for: items)
        }
    }

    private static func multiLabel(for items: [ClipboardContent]) -> String {
        let n = items.count
        guard n >= 2 else {
            // Defensive — router collapses singletons before emitting
            // `.multi`, but treat a stray as "items" rather than crash.
            return "Paste \(n) items here"
        }
        // Single-kind detection: peek the first item's kind label and
        // verify all others match. Plain text in a multi-item batch is
        // unusual; the brief doesn't lock its plural so it falls
        // through to "items" via the no-plural branch below.
        let kind = pluralKind(for: items[0])
        for item in items.dropFirst() {
            if pluralKind(for: item) != kind {
                return "Paste \(n) items here"
            }
        }
        if let kind {
            return "Paste \(n) \(kind) here"
        }
        return "Paste \(n) items here"
    }

    /// Returns the plural noun the multi-item label uses when every
    /// item shares this kind. Nil for kinds that don't have a
    /// brief-locked plural — those fall through to the generic
    /// "items" wording.
    private static func pluralKind(for item: ClipboardContent) -> String? {
        switch item {
        case .url: return "links"
        case .image: return "images"
        case .video: return "videos"
        case .file: return "documents"
        case .text, .multi, .empty: return nil
        }
    }

    // MARK: - Tunables (T dials on device)

    /// Shimmer animation tunables. First-pass values per the brief's
    /// slow + subtle constraint. T iterates these on device during C5
    /// polish.
    private enum Shimmer {
        /// Full sweep duration, seconds. Brief target: 3–4s.
        static let cycle: TimeInterval = 3.5
        /// Base text opacity (always visible). Brief target: ~0.6.
        static let baseOpacity: Double = 0.65
        /// Peak text opacity inside the sliding band. Brief target:
        /// ~0.9. Difference from base is the visible "shimmer."
        static let peakOpacity: Double = 0.95
        /// Fraction of the label width covered by the bright band at
        /// any instant. Wider → softer (slower visual transition);
        /// narrower → crisper (more obvious sweep).
        static let bandWidth: CGFloat = 0.45
    }
}

#if DEBUG
#Preview("Empty") {
    PastePadView(onPaste: { _ in })
        .padding(20)
        .background(Color.black)
}

#Preview("Primed URL") {
    // Hard-set the visible state by injecting via an internal preview
    // shim — the production view reads UIPasteboard, so previews can
    // only show whatever the simulator's clipboard happens to hold.
    // For static visual review, use the production view with a primed
    // simulator clipboard.
    PastePadView(onPaste: { _ in })
        .padding(20)
        .background(Color.black)
        .onAppear {
            UIPasteboard.general.url = URL(string: "https://example.com")
        }
}
#endif
