import SwiftUI
import UIKit

// THE LEVER — Stage 2b · THE SHIMMER
//
// A SINGLE shimmer traverse across the feather glyph on the lever button — not a
// pulse, glow, badge, or bounce, and NO sparkle. It reads through LUMINANCE + MOTION
// only (T is colourblind), so every highlight is WHITE (`#FFFFFF`), never a hue.
//
// Fires ONCE per node VISIT, within ~the first second, ONLY when the button is in
// the pending state (the SAME `Node.surfacedProposal` predicate that drives the
// gradient fill — one predicate, so they can't disagree) AND only when the button
// is actually in the viewport. Respects Reduce Motion (then: no shimmer at all —
// the gradient resting state already carries the same information).

// MARK: - Variant + dev tuning

/// The KIND of shimmer. Three distinct motions (timing is a separate slider). T
/// picks one on device. Read in ALL builds via `LeverShimmerTuning`; only the
/// picker panel is `#if DEBUG`.
enum LeverShimmerVariant: String, CaseIterable, Identifiable {
    case specular   // a crisp diagonal glint travels across the glyph
    case bloom      // a soft luminance swell rises and falls IN PLACE
    case axial      // a soft glow climbs the feather's long axis, base → tip

    var id: String { rawValue }
    var label: String {
        switch self {
        case .specular: return "Sweep"
        case .bloom:    return "Bloom"
        case .axial:    return "Axial"
        }
    }
}

/// Dev-tunable shimmer settings. The VARIANT + duration persist to UserDefaults
/// (a dev dial, like `CardTuning`); `replayToken` is a transient signal so the
/// DEBUG panel can re-fire the shimmer without re-navigating. ★ This is NOT the
/// once-per-visit state — that lives ephemerally on `LeverButton`, keyed to the
/// view (the node's visit), nothing persisted.
@Observable
final class LeverShimmerTuning {
    static let shared = LeverShimmerTuning()

    private static let variantKey  = "lever.shimmer.variant"
    private static let durationKey = "lever.shimmer.duration"

    /// ★ T's device pick (TestFlight 202608050658): Sweep @ 1.95. These are the
    /// COMPILED-IN defaults — a shipped user with empty tuning storage gets
    /// exactly this, from code, not a stored or panel-supplied value.
    static let defaultVariant: LeverShimmerVariant = .specular
    static let defaultDuration: Double = 1.95

    var variant: LeverShimmerVariant {
        didSet { UserDefaults.standard.set(variant.rawValue, forKey: Self.variantKey) }
    }
    /// Traverse duration (seconds). Timing is the slider; kind is the choice.
    var duration: Double {
        didSet { UserDefaults.standard.set(duration, forKey: Self.durationKey) }
    }
    /// DEBUG re-fire signal (not persisted). Bumped by the panel.
    var replayToken: Int = 0

    private init() {
        variant = Self.resolveVariant(from: UserDefaults.standard.string(forKey: Self.variantKey))
        duration = Self.resolveDuration(from: UserDefaults.standard.object(forKey: Self.durationKey) as? Double)
    }

    /// Variant resolution — the SHIPPED user's first-launch state has no stored
    /// value (`nil`), which MUST fall back to the compiled-in `defaultVariant`,
    /// not "no variant". `ShimmerSelfTest` asserts exactly this. Pure so it is
    /// testable without touching UserDefaults.
    static func resolveVariant(from raw: String?) -> LeverShimmerVariant {
        LeverShimmerVariant(rawValue: raw ?? "") ?? Self.defaultVariant
    }

    /// Duration resolution — empty storage falls back to the compiled-in
    /// `defaultDuration` (T's 1.95). Pure + tested, same reasoning as the variant.
    static func resolveDuration(from raw: Double?) -> Double {
        raw ?? Self.defaultDuration
    }

    func replay() { replayToken &+= 1 }
}

/// Whether internal dev tuners (the shimmer variant panel) are reachable. ON for
/// DEBUG, the Simulator, and **TestFlight** (sandbox receipt); OFF for the App
/// Store. ★ NOT `#if DEBUG` — TestFlight archives are Release, and T must reach
/// the tuner there (the whole point of building three variants). It auto-disables
/// on the App Store (the receipt is not `sandboxReceipt`), so nothing must be
/// stripped — but VERIFY absence before submission and remove in ONE edit
/// (`return false`) if desired. Recorded in queue.md § pre-submission.
enum InternalBuild {
    static let showsDevTuners: Bool = {
        #if DEBUG
        return true
        #elseif targetEnvironment(simulator)
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()
}

// MARK: - The button

/// The lever: a feather circle spanning the combined height of the two chip lanes.
/// Gradient FILL = a fresh proposal is pending; monochrome = nothing pending, still
/// fully tappable (a REQUEST mechanism first). Colours stated as hex (T verifies
/// with a picker): Klein `#00BFFF` → `#1B59C2`; resting ink `#232A2E`/`#FFFFFF`.
/// Glyph is `AirPadLogo` (the Ask feather — nothing on the tip). Stage 2b adds the
/// shimmer (below).
struct LeverButton: View {
    let node: Node
    let diameter: CGFloat
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tuning = LeverShimmerTuning.shared

    // Ephemeral, keyed to THIS view = this node's VISIT. Survives sheet
    // presentations (the tray / pickers don't recreate the detail view), so
    // returning from a sheet does not re-fire. Reset only on a fresh visit.
    @State private var hasShimmered = false
    @State private var isVisible = false
    /// Bumped to play the shimmer once (drives the overlay's keyframe animator).
    @State private var shimmerPlays = 0

    /// ★ THE ONE predicate — shared with the gradient fill (and the tray) via
    /// `Node.surfacedProposal`, so shimmer and gradient can never disagree about
    /// whether something is pending. A user-authored field is already excluded
    /// there (an unsolicited proposal on it doesn't surface), so this never fires
    /// for a field the user wrote.
    private var pending: Bool {
        node.surfacedProposal(kind: .title) != nil
            || node.surfacedProposal(kind: .summary) != nil
    }

    var body: some View {
        let kleinGrad = LinearGradient(
            colors: [Color(hexString: "00BFFF"), Color(hexString: "1B59C2")],
            startPoint: .top, endPoint: .bottom
        )
        let restingInk = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(Color(hexString: "FFFFFF"))
                : UIColor(Color(hexString: "232A2E"))
        })
        Button(action: onTap) {
            ZStack {
                // T2 — the circle NEVER changes: it is the muted resting
                // CONTAINER (the tap target) in BOTH states, not a participant in
                // the signal. The thing with something to say is the FEATHER; the
                // old filled-blue circle read as "a blue button appeared."
                Circle()
                    .fill(restingInk.opacity(0.08))
                // Pending = the FEATHER carries the cyan→blue Klein gradient (the
                // same family as the Ask feather); resting = muted, as before.
                Image("AirPadLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: diameter, height: diameter)
                    .foregroundStyle(pending ? AnyShapeStyle(kleinGrad)
                                             : AnyShapeStyle(restingInk.opacity(0.55)))
                // Shimmer masks to the FEATHER'S OWN SHAPE, so the light travels
                // along the stroked feather itself. It reads now because the
                // pending feather is the cyan→blue gradient (not white) — a white
                // glint on the coloured glyph has contrast. Only in the pending
                // state; invisible at rest (opacity 0) until `shimmerPlays` bumps.
                if pending {
                    LeverShimmerOverlay(variant: tuning.variant,
                                        diameter: diameter,
                                        duration: tuning.duration,
                                        trigger: shimmerPlays)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pending ? "Review proposals" : "Ask for a proposal")
        // VIEWPORT GATE — the button is inline in the scrolling document, so it can
        // be off screen at entry. `onScrollVisibilityChange` reports its visibility;
        // if visible → fire, if not → arm and fire when it scrolls in.
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            isVisible = visible
            attemptShimmer()
        }
        // DEBUG replay — the panel re-fires without re-navigating.
        .onChange(of: tuning.replayToken) { _, _ in
            hasShimmered = false
            attemptShimmer()
        }
    }

    private func attemptShimmer() {
        guard Self.shouldFire(pending: pending, visible: isVisible,
                              hasShimmered: hasShimmered, reduceMotion: reduceMotion) else { return }
        hasShimmered = true
        // Within ~the first second of entering / of scrolling into view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            shimmerPlays &+= 1
        }
    }

    /// The firing decision — fires ONCE per visit, only when a proposal is
    /// pending AND the button is in the viewport AND Reduce Motion is off. Pure so
    /// `ShimmerSelfTest` can assert the SHIPPED default state (pending + visible +
    /// not-yet-shimmered + motion-on) fires — the state nobody exercised.
    static func shouldFire(pending: Bool, visible: Bool,
                           hasShimmered: Bool, reduceMotion: Bool) -> Bool {
        pending && visible && !hasShimmered && !reduceMotion
    }
}

// MARK: - The three shimmer treatments

/// The animated highlight, masked to the FEATHER'S OWN SHAPE (T2) — the light
/// travels along the stroked feather itself. All white (`#FFFFFF`, luminance
/// only — never tinted); it reads because the pending feather is the cyan→blue
/// gradient, not white. Plays ONCE each time `trigger` changes; invisible
/// otherwise.
private struct LeverShimmerOverlay: View {
    let variant: LeverShimmerVariant
    let diameter: CGFloat
    let duration: Double
    let trigger: Int

    private var white: Color { Color(hexString: "FFFFFF") }

    /// The glyph's alpha — the mask that clips every treatment to the feather.
    private var featherMask: some View {
        Image("AirPadLogo").renderingMode(.template).resizable().scaledToFit()
            .frame(width: diameter, height: diameter)
    }

    var body: some View {
        Group {
            switch variant {
            case .specular: specular
            case .bloom:    bloom
            case .axial:    axial
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    // 1 — a crisp diagonal glint travels left → right along the feather.
    private var specular: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, white.opacity(0.95), .clear],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: diameter * 0.5, height: diameter * 1.7)
            .rotationEffect(.degrees(22))
            .keyframeAnimator(initialValue: Sweep(x: -diameter, o: 0), trigger: trigger) { view, v in
                view.offset(x: v.x).opacity(v.o)
            } keyframes: { _ in
                KeyframeTrack(\.x) { LinearKeyframe(diameter, duration: duration) }
                KeyframeTrack(\.o) {
                    LinearKeyframe(1, duration: duration * 0.3)
                    LinearKeyframe(1, duration: duration * 0.4)
                    LinearKeyframe(0, duration: duration * 0.3)
                }
            }
            .frame(width: diameter, height: diameter)
            .mask(featherMask)
    }

    // 2 — a soft luminance swell rises and falls IN PLACE: the feather brightens
    // to white and back (a white feather over the gradient one).
    private var bloom: some View {
        Image("AirPadLogo").renderingMode(.template).resizable().scaledToFit()
            .frame(width: diameter, height: diameter)
            .foregroundStyle(white)
            .keyframeAnimator(initialValue: Bloom(o: 0), trigger: trigger) { view, v in
                view.opacity(v.o)
            } keyframes: { _ in
                KeyframeTrack(\.o) {
                    CubicKeyframe(0.9, duration: duration * 0.45)
                    CubicKeyframe(0.0, duration: duration * 0.55)
                }
            }
    }

    // 3 — a soft glow climbs the feather's long axis, base → tip.
    private var axial: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, white.opacity(0.9), .clear],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: diameter * 1.7, height: diameter * 0.5)
            .keyframeAnimator(initialValue: Axial(y: diameter * 0.7, o: 0), trigger: trigger) { view, v in
                view.offset(y: v.y).opacity(v.o)
            } keyframes: { _ in
                KeyframeTrack(\.y) { LinearKeyframe(-diameter * 0.7, duration: duration) }
                KeyframeTrack(\.o) {
                    LinearKeyframe(0.9, duration: duration * 0.3)
                    LinearKeyframe(0.9, duration: duration * 0.4)
                    LinearKeyframe(0, duration: duration * 0.3)
                }
            }
            .frame(width: diameter, height: diameter)
            .mask(featherMask)
    }

    private struct Sweep { var x: CGFloat; var o: Double }
    private struct Bloom { var o: Double }
    private struct Axial { var y: CGFloat; var o: Double }
}

// MARK: - Variant selector (INTERNAL builds — DEBUG + Simulator + TestFlight)

/// Draggable dev widget so T picks the shimmer KIND (and dials duration) in one
/// device pass, with Replay to re-fire without re-navigating. Mirrors
/// `CardTuningPanel`. ★ Compiled in ALL configs (TestFlight is Release), but only
/// PRESENTED when `InternalBuild.showsDevTuners` — so it reaches TestFlight and
/// not the App Store. The variant it writes is read in all builds.
struct ShimmerTuningPanel: View {
    @Binding var isPresented: Bool
    @Binding var position: CGSize

    @State private var tuning = LeverShimmerTuning.shared
    @GestureState private var dragTranslation: CGSize = .zero

    private static let widgetWidth: CGFloat = 280

    private var variantBinding: Binding<LeverShimmerVariant> {
        Binding(get: { tuning.variant },
                set: { tuning.variant = $0; tuning.replay() })   // switch → show it immediately
    }
    private var durationBinding: Binding<Double> {
        Binding(get: { tuning.duration }, set: { tuning.duration = $0 })
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            Picker("Variant", selection: variantBinding) {
                ForEach(LeverShimmerVariant.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Text("Duration").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Slider(value: durationBinding, in: 0.4...2.5)
                Text(String(format: "%.2f", tuning.duration))
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
            }
            Button { tuning.replay() } label: {
                Text("Replay shimmer")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: Self.widgetWidth)
        .modifier(ShimmerWidgetSurface())
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
        .offset(x: position.width + dragTranslation.width,
                y: position.height + dragTranslation.height)
    }

    private var header: some View {
        ZStack {
            Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 36, height: 5)
            HStack {
                Text("Shimmer").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragTranslation) { value, state, _ in state = value.translation }
                .onEnded { value in
                    position.width += value.translation.width
                    position.height += value.translation.height
                }
        )
    }
}

private struct ShimmerWidgetSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}
