import Foundation

/// THE LEVER — Stage 2b self-test. The shimmer shipped INVISIBLE-then-non-firing
/// concerns twice; both were verified only in states that don't match the
/// shipped user. This asserts the two pure decisions in the SHIPPED-EMPTY state —
/// no stored tuning value, motion on — the state nobody exercised:
///   1. variant resolution: nil / "" / garbage → `.specular` (never "no variant");
///      a stored value is honoured.
///   2. the firing decision: pending + visible + not-yet-shimmered + motion-on →
///      FIRES; and each gate (not-pending / off-screen / already-shimmered /
///      reduce-motion) suppresses it.
///
/// Pure logic → config-independent, so a DEBUG run is valid for Release (the fix
/// the app never got: exercise the shipped configuration). Run headless via
/// `-ShimmerSelfTest`.
enum ShimmerSelfTest {

    static func run() -> String {
        var failures: [String] = []
        var ran = 0

        // 1 — resolution. The shipped first-launch state is `nil` for BOTH the
        // variant and the duration; both must fall back to T's compiled-in picks
        // (Sweep @ 1.95), not "no variant" / a stale number. This is the exact
        // state that went unexercised twice.
        do {
            ran += 1
            if LeverShimmerTuning.resolveVariant(from: nil) != .specular {
                failures.append("1: nil (shipped empty) must resolve to .specular")
            }
            if LeverShimmerTuning.resolveVariant(from: "") != .specular {
                failures.append("1: \"\" must resolve to .specular")
            }
            if LeverShimmerTuning.resolveVariant(from: "not-a-variant") != .specular {
                failures.append("1: garbage must fall back to .specular")
            }
            if LeverShimmerTuning.resolveVariant(from: "bloom") != .bloom {
                failures.append("1: a stored valid value must be honoured")
            }
            // Duration — T's device pick, compiled in.
            if LeverShimmerTuning.resolveDuration(from: nil) != 1.95 {
                failures.append("1: nil (shipped empty) duration must resolve to 1.95")
            }
            if LeverShimmerTuning.resolveDuration(from: 2.5) != 2.5 {
                failures.append("1: a stored duration must be honoured")
            }
            // The compiled-in defaults ARE T's pick.
            if LeverShimmerTuning.defaultVariant != .specular || LeverShimmerTuning.defaultDuration != 1.95 {
                failures.append("1: compiled-in defaults must be Sweep @ 1.95 (T's pick)")
            }
        }

        // 2 — firing decision. The SHIPPED default state must fire.
        do {
            ran += 1
            if !LeverButton.shouldFire(pending: true, visible: true, hasShimmered: false, reduceMotion: false) {
                failures.append("2: shipped default (pending+visible+fresh+motion) must FIRE")
            }
            if LeverButton.shouldFire(pending: false, visible: true, hasShimmered: false, reduceMotion: false) {
                failures.append("2: must not fire when nothing is pending")
            }
            if LeverButton.shouldFire(pending: true, visible: false, hasShimmered: false, reduceMotion: false) {
                failures.append("2: must not fire off screen (viewport gate)")
            }
            if LeverButton.shouldFire(pending: true, visible: true, hasShimmered: true, reduceMotion: false) {
                failures.append("2: must not re-fire in the same visit")
            }
            if LeverButton.shouldFire(pending: true, visible: true, hasShimmered: false, reduceMotion: true) {
                failures.append("2: Reduce Motion must suppress the shimmer")
            }
        }

        if failures.isEmpty {
            return "Shimmer: \(ran)/\(ran) passed"
        } else {
            return "Shimmer FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }
}
