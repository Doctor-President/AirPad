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
/// Clipboard observation lifecycle (Stage 4.7 C4 — prompt-free):
///   - `.onAppear` → `detectKind()` (no-prompt: numberOfItems +
///     types(forItemSet:) only)
///   - `UIPasteboard.changedNotification` → `detectKind()`
///   - `UIApplication.didBecomeActiveNotification` → `detectKind()`
///     (cross-app copies don't always re-post `changedNotification`
///     when AirPad was backgrounded; this is the narrow divergence
///     from the brief's "only on changedNotification" language — the
///     acceptance "Clipboard change while user is in detail view:
///     Paste Pad updates label and state within a beat" requires it
///     for the common path of "user leaves AirPad, copies something
///     elsewhere, returns").
///   - Tap → `classify()` (full content read; this is the only
///     prompt-triggering call site)
///   - `.onDisappear` → no explicit teardown needed (`.onReceive`
///     subscriptions live with the view's lifetime)
///
/// **iOS 16+ "Allow Paste" alert is expected, not suppressible.**
/// Reading pasteboard *values* (the `values`/`data`/`string`/`url`/
/// `image` family) triggers the system alert **once per clipboard
/// change** — once the user taps "Allow Paste" for a given
/// `changeCount`, subsequent reads against the same contents don't
/// reprompt; a new copy elsewhere advances `changeCount` and the next
/// read prompts again. The only documented suppressor is
/// `UIPasteControl` / `PasteButton` (iOS 16+/17+), which is
/// incompatible with our shimmer label (no custom-label API). So we
/// don't fight the alert — we minimize how often it fires by keeping
/// the prompt-triggering call (`classify`) off the appear / changed /
/// foreground paths entirely. The label is driven by `detectKind`,
/// which uses only documented no-prompt APIs (`numberOfItems`,
/// `types(forItemSet:)`, UTType conformance on the returned type
/// identifiers — none read content bytes). The full `classify()` runs
/// only on tap, so the user's tap IS the consent signal for the
/// prompt. The legacy iOS 14+ "AirPad pasted from <app>" banner still
/// appears post-tap; we don't fight that either.
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

    /// Detection-only kind driving the label and primed state. Updated
    /// from `detectKind()` on appear / changed / foreground — no
    /// content read, no prompt. The full `ClipboardContent` payload is
    /// resolved on tap inside `handleTap`.
    @State private var kind: ClipboardKind = .empty

    /// Stage 4.4 dev-panel surface; same instance `EntryCard` reads so
    /// Paste Pad tracks corner-radius / body-treatment changes during
    /// Stage 4.4 iteration.
    @State private var visualSettings = EntryVisualSettings.shared

    private var isPrimed: Bool {
        if case .empty = kind { return false }
        return true
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(isPrimed ? Shimmer.baseOpacity : 0.35))

            label
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.horizontal, 16)
        .background {
            EntryCardBackground(treatment: visualSettings.bodyTreatment)
                .opacity(isPrimed ? 1.0 : 0.55)
        }
        .clipShape(RoundedRectangle(cornerRadius: visualSettings.cornerRadius))
        .overlay {
            // Perimeter shimmer stroke — only visible while primed.
            // Spatial modulation (a moving bright band), not a uniform
            // opacity pulse, so the stroke and the text read as one
            // unified shimmer rather than two synced effects. The
            // gradient's bright peak is horizontally co-located with
            // the text band's bright peak — same phase math, same
            // bandWidth fraction, same baseOpacity → peakOpacity range.
            // `strokeBorder` keeps the line wholly inside the
            // rounded-rect bounds (so `.clipShape` above doesn't
            // half-clip it; mirrors the EntryCard stroke pattern).
            //
            // The horizontal nature of LinearGradient means the top and
            // bottom edges shimmer in direct sync with the text band;
            // the left and right edges show a single instant of the
            // gradient at any time — they brighten and dim as the band
            // sweeps past, which still reads as part of the same
            // perimeter shimmer.
            if isPrimed {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = Self.shimmerPhase(at: context.date)
                    RoundedRectangle(cornerRadius: visualSettings.cornerRadius)
                        .strokeBorder(
                            Self.strokeGradient(at: phase),
                            lineWidth: Shimmer.strokeWidth
                        )
                }
                .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: visualSettings.cornerRadius))
        .onTapGesture { handleTap() }
        .onAppear {
            refreshKindFromClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshKindFromClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshKindFromClipboard()
        }
        .animation(.easeInOut(duration: 0.2), value: isPrimed)
    }

    // MARK: - Label rendering

    @ViewBuilder
    private var label: some View {
        let text = Self.labelText(for: kind)

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
        // no error. Tap on primed → invoke the full classifier (the
        // ONE call site that reads content bytes and so trips iOS's
        // "Allow Paste" alert; user's tap IS the consent signal). Race
        // guard: if the clipboard was cleared between detection and
        // tap, classify returns `.empty` and we silently drop — the
        // detection-state label flips on the next changedNotification.
        guard isPrimed else { return }
        let content = ClipboardContentRouter.classify()
        if case .empty = content { return }
        onPaste(content)
    }

    // MARK: - Clipboard refresh

    private func refreshKindFromClipboard() {
        // Detection-only path: no `values`/`data`/`string` calls, so
        // no "Allow Paste" prompt. The full classifier runs in
        // `handleTap` once the user signals intent. Pasteboard reads
        // themselves don't invoke SwiftUI redraws — we assign the
        // result, and the `isPrimed` derived state drives the visual
        // transition. The `.animation` modifier on the view handles
        // the cross-fade between empty and primed surfaces.
        kind = ClipboardContentRouter.detectKind()
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

    /// Stroke gradient at the current shimmer phase. Matches the text
    /// shimmer's spatial structure: a bright band of width
    /// `Shimmer.bandWidth` (fraction of label width) whose center
    /// tracks the text band's center exactly. Outside the band the
    /// stroke is at `baseOpacity`; at the band's center it reaches
    /// `peakOpacity`.
    ///
    /// Mechanics: the gradient spans only the band itself
    /// (`startPoint.x` to `endPoint.x` covers the band's horizontal
    /// extent in unit space). SwiftUI extrapolates outside that range
    /// to the boundary stop color — which is `baseOpacity` on both
    /// ends — so the rest of the stroke shows uniform base brightness
    /// while the band region carries the peak. When the band is
    /// off-screen (`phase` 0 or 1), the entire visible stroke sits at
    /// base. Identical to how the text band's leading/trailing edges
    /// sweep off-frame at the cycle boundaries.
    private static func strokeGradient(at phase: CGFloat) -> LinearGradient {
        let bandHalf = Shimmer.bandWidth / 2
        let center = -bandHalf + (1 + Shimmer.bandWidth) * phase
        return LinearGradient(
            colors: [
                Color.white.opacity(Shimmer.baseOpacity),
                Color.white.opacity(Shimmer.peakOpacity),
                Color.white.opacity(Shimmer.baseOpacity)
            ],
            startPoint: UnitPoint(x: center - bandHalf, y: 0.5),
            endPoint: UnitPoint(x: center + bandHalf, y: 0.5)
        )
    }

    // MARK: - Label text

    /// Type-aware labels per the brief's locked table. Multi-item
    /// receives one of two shapes:
    ///   - all items same kind → "Paste N {plural-kind} here"
    ///   - mixed kinds → "Paste N items here"
    static func labelText(for kind: ClipboardKind) -> String {
        switch kind {
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

    private static func multiLabel(for items: [ClipboardKind]) -> String {
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
        let plural = pluralKind(for: items[0])
        for item in items.dropFirst() {
            if pluralKind(for: item) != plural {
                return "Paste \(n) items here"
            }
        }
        if let plural {
            return "Paste \(n) \(plural) here"
        }
        return "Paste \(n) items here"
    }

    /// Returns the plural noun the multi-item label uses when every
    /// item shares this kind. Nil for kinds that don't have a
    /// brief-locked plural — those fall through to the generic
    /// "items" wording.
    private static func pluralKind(for kind: ClipboardKind) -> String? {
        switch kind {
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
        /// Perimeter shimmer-stroke thickness. 1pt reads as a border
        /// accent against the card-background fill without crossing
        /// into "highlight" territory.
        static let strokeWidth: CGFloat = 1.0
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
