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
///   3. PROPOSAL-ARRIVES-AFTER-RENDER (Stage 2c): a visit shimmers exactly once
///      whether the proposal was present at first render OR arrived ~0.8s later
///      (the capture path — node saved EMPTY, enrichment lands while the view is
///      alive). The fire must not depend on the ORDER `pending` / `visible`
///      settle; every earlier case seeded `pending` first, which is exactly why
///      the after-render path shipped without a shimmer.
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

        // 3 — PROPOSAL-ARRIVES-AFTER-RENDER. The regression the device round
        // caught: the capture path saves the node EMPTY, renders the button
        // (pending false), then enrichment records the proposal ~0.8s later while
        // the view is alive. A visit must shimmer exactly ONCE regardless of the
        // order `pending` / `visible` settle — the seeded-first path and the
        // arrived-after path can't diverge. Models `attemptShimmer`'s
        // once-per-visit guard over the sequence of arming events (viewport flips
        // + the pending flip). The pending flip is the arming trigger Stage 2c
        // added; before it, an already-visible button whose proposal arrived
        // after render fired zero shimmers (the last case below would return 0).
        do {
            ran += 1

            // Replay one visit as a sequence of arming attempts, each gated by
            // `shouldFire`, firing at most once — the exact shape of
            // `LeverButton.attemptShimmer` across a visit. Returns the fire count.
            func firesInVisit(_ events: [(pending: Bool, visible: Bool)]) -> Int {
                var hasShimmered = false
                var plays = 0
                for e in events {
                    if LeverButton.shouldFire(pending: e.pending, visible: e.visible,
                                              hasShimmered: hasShimmered, reduceMotion: false) {
                        hasShimmered = true
                        plays += 1
                    }
                }
                return plays
            }

            // Seeded-before-render (detail view entered on a node that already
            // has proposals): pending true at the first visibility event.
            if firesInVisit([(pending: true, visible: true)]) != 1 {
                failures.append("3: seeded proposal (pending at render) must fire once")
            }
            // Arrives-after-render (THE BUG): visible first with nothing pending,
            // then the proposal lands (pending flips true) via the pending-arming
            // trigger. Must STILL fire exactly once — the path that shipped broken.
            if firesInVisit([(pending: false, visible: true),
                             (pending: true, visible: true)]) != 1 {
                failures.append("3: proposal arriving AFTER render must still fire once")
            }
            // Arrives while off-screen, then scrolls in: the viewport trigger
            // closes it. Still exactly once.
            if firesInVisit([(pending: false, visible: false),
                             (pending: true, visible: false),
                             (pending: true, visible: true)]) != 1 {
                failures.append("3: proposal arriving off-screen fires when scrolled in")
            }
            // Never re-fires once shimmered, whatever later flips occur this visit.
            if firesInVisit([(pending: false, visible: true),
                             (pending: true, visible: true),
                             (pending: true, visible: false),
                             (pending: true, visible: true)]) != 1 {
                failures.append("3: must not re-fire after the first shimmer in a visit")
            }
        }

        if failures.isEmpty {
            return "Shimmer: \(ran)/\(ran) passed"
        } else {
            return "Shimmer FAIL: \(ran - failures.count)/\(ran) passed:\n" + failures.joined(separator: "\n")
        }
    }
}
