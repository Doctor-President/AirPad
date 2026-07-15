import SwiftUI
import FloatingPanel
import Observation

/// Per-frame morph signal. `@Observable` (per-property tracking) so a view that
/// reads `peekProgress` re-evaluates per frame while a view that only holds the
/// model reference does NOT. The whole panel model is now `@Observable` too, so
/// this split is no longer load-bearing for isolation — but it's kept as the
/// dedicated home for the continuous value the chrome leaves read.
@MainActor
@Observable
final class MorphProgressModel {
    var peekProgress: CGFloat = 0
}

// MARK: - Layout

/// In-layout panel anchors. `position: .bottom`; three user-facing detents
/// (peek/half/full). `.hidden` is intentionally **omitted** from `anchors`
/// so it cannot be a snap target for user drag — drag target selection
/// only considers `anchors.keys` (Core.swift `targetState` →
/// `sortedAnchorStatesByCoordinate` → `anchorStates`). `.tip` is therefore
/// the hard user-facing floor. `.hidden` remains reachable programmatically
/// via `FloatingPanelController.hide(animated:)`, which `move(to: .hidden)`s
/// to the library's default offscreen anchor (Layout.swift `hiddenAnchor`,
/// `validStates = anchorStates ∪ {.hidden}`).
///
/// `backdropAlpha = 0` for every state so `FloatingPanelPassThroughView`
/// lets touches reach the SpriteKit canvas behind the panel.
final class LibrarianPanelLayout: FloatingPanelLayout {
    /// Float-gap between the peek capsule's bottom edge and the safe-area
    /// bottom. SINGLE SOURCE OF TRUTH for that gap — `peekDetentHeight`
    /// below folds it into the band height, and `LibrarianSurface`'s
    /// `morphingField` peek anchor (`peekCenterY`) subtracts the SAME
    /// value, so the capsule and the band reserving space for it always
    /// move together (the two used to carry a duplicated literal `21`
    /// that could silently drift). Reduced 21 → 8 for the dock-
    /// consolidation pass: pulls the pill toward the bottom edge and,
    /// because the band shrinks, the capture "+" / carousel reserve /
    /// density pill (all `peekDetentHeight`-derived) follow it down.
    static let peekBottomGap: CGFloat = 8

    /// Height of the peek (`.tip`) detent band in points. Single source
    /// of truth — the anchor below and any overlay that must ride above
    /// the peek pill (capture "+" buttons on canvas and node detail)
    /// read from here so the value lives in one place.
    ///
    /// The band is `10pt top breathing + 64pt Apple-Maps-style capsule +
    /// peekBottomGap float gap to the safe-area bottom`. The pill itself
    /// owns its 340pt width directly in `LibrarianSurface`'s peek branch
    /// (centered), so no side-inset value lives here.
    static let peekDetentHeight: CGFloat = 10 + 64 + peekBottomGap

    /// Bottom padding for overlay chrome that must sit above the peek
    /// panel: peek height + 10pt breathing room. Used by
    /// `CanvasView.captureTriggerButton` and `NodeDetailView.floatingAddButton`
    /// so the two stay consistent.
    static let peekOverlayClearance: CGFloat = peekDetentHeight + 10

    let position: FloatingPanelPosition = .bottom
    /// Cold-launch posture: hidden offscreen. ContentView's
    /// `.floatingPanel { ... }.onAppear` aligner moves the panel to
    /// `.tip` or `.hidden` per the launched entry mode, but if the
    /// panel's `initialState` is `.tip` there's a one-frame peek
    /// flicker before the aligner runs (visible on a Dashboard cold
    /// launch). `.hidden` makes the cold posture match the launch
    /// default (Dashboard); canvas modes then raise to `.tip` on the
    /// same first frame.
    let initialState: FloatingPanelState = .hidden
    var anchors: [FloatingPanelState: FloatingPanelLayoutAnchoring] {
        [
            .full: FloatingPanelLayoutAnchor(absoluteInset: 16, edge: .top, referenceGuide: .safeArea),
            .half: FloatingPanelLayoutAnchor(fractionalInset: 0.5, edge: .bottom, referenceGuide: .safeArea),
            .tip:  FloatingPanelLayoutAnchor(absoluteInset: Self.peekDetentHeight, edge: .bottom, referenceGuide: .safeArea),
        ]
    }
    func backdropAlpha(for state: FloatingPanelState) -> CGFloat { 0.0 }
}

// MARK: - Behavior

/// Snappy detent animation (BUG 5). Every programmatic detent move
/// (`move(to:)` — expandToFull / expandToHalf / dropToHalf / raiseToPeek /
/// lock / unlock) AND the drag-release attraction run FloatingPanel's numeric
/// spring, whose ONLY timing input is `springResponseTime`. At the library
/// default (0.4) the panel crept to its anchor on a long critically-damped
/// tail — instrumentation measured half→full at ~1.6s of smooth, un-starved
/// travel (mount was ~4ms and innocent; it was purely the animation duration).
///
/// Programmatic moves have velocity 0, which the library ALWAYS runs
/// critically damped (per `FloatingPanelBehavior` docs, `springDecelerationRate`
/// is ignored below velocity 300), so response time is the only lever — and
/// it's the morph-safe one: the numeric spring keeps emitting per-frame
/// `floatingPanelDidMove`, so the pill↔field morph is untouched. (A delegate
/// `animatorForMovingTo:` UIViewPropertyAnimator would be snappier but only
/// fires at completion → it would SNAP the morph on peek transitions.)
///
/// TUNABLE — lower = snappier. `detentResponse` is the single knob.
final class LibrarianPanelBehavior: FloatingPanelDefaultBehavior {
    /// Detent settle time. Library default is 0.4 (≈1.6s perceived tail);
    /// 0.15 targets the ~0.4s snappy range. Dial down for faster / up if the
    /// short transitions (→peek) feel too abrupt.
    static let detentResponse: CGFloat = 0.15
    override var springResponseTime: CGFloat { Self.detentResponse }
}

// MARK: - State observer

/// Delegate → observable bridge. `state` mirrors the controller's live
/// detent so panel content can branch per detent. `controller` is the
/// weak handle the entry-mode wiring uses to drive the panel from outside
/// the `.floatingPanel { proxy in … }` builder closure.
@MainActor
@Observable
final class LibrarianPanelStateModel: NSObject, FloatingPanelControllerDelegate {
    var state: FloatingPanelState = .tip

    /// True while the user is finger-dragging the panel OR FloatingPanel
    /// is animating the post-release attraction to a detent. The
    /// surface reads this to swap in a cheap static chrome during
    /// motion — the rotating angular-gradient border + blurred glow
    /// re-renders every frame on top of `.thinMaterial`, which stutters
    /// the drag if drawn live (Move 2 fix-pass A). `true` covers both
    /// the drag itself and the attraction so the chrome restore lines
    /// up with the panel coming to rest, not the finger lifting.
    var isDragging: Bool = false

    /// Continuous 0…1 morph signal: 0 = panel sitting at `.tip`,
    /// 1 = panel at `.half` (or above). Driven per-frame by
    /// `floatingPanelDidMove` during finger-drag and during the
    /// post-release attraction animator, and recomputed once on
    /// every state-change so non-dragged moves (programmatic
    /// `move(to:)`, hide) settle the value correctly. Surface
    /// content crossfades against this to remove the dismiss-jump
    /// the discrete `.tip` ↔ expanded switch caused.
    ///
    /// Per-frame morph signal, isolated (see MorphProgressModel). Surface morph + fade
    /// wrappers observe THIS, not self, so per-frame churn doesn't wake the surface body.
    let progress = MorphProgressModel()

    /// Coarse reveal flag — true once dragged past the content-mount point (0.4). Flips
    /// only at the crossing, so the chrome's heavy subtree mounts on the boundary instead
    /// of being re-gated every frame. Replaces the surface's inline `p > 0.4` gate.
    var contentRevealed: Bool = false

    /// True while the panel is pinned at `.full` with its pan recognizer
    /// disabled. Drives the expanded header's collapse affordance.
    /// Cleared via `unlock(animated:)` (collapse-button tap) or
    /// `duck(animated:)`'s defensive `clearLock()` (forced-exit paths
    /// like Dashboard nav or capture overlay).
    var isLocked: Bool = false
    @ObservationIgnored weak var controller: FloatingPanelController?

    nonisolated func floatingPanelDidChangeState(_ fpc: FloatingPanelController) {
        MainActor.assumeIsolated {
            if state != fpc.state { state = fpc.state }   // guard: same-value sets still emit objectWillChange
            recomputeProgress(fpc)
        }
    }

    // Explicit @objc on the per-move callback. The protocol declares it
    // `@objc optional` (Controller.swift:53-55), so dispatch happens via
    // selector. NSObject subclasses normally get `@objc` inferred for
    // methods that satisfy `@objc` protocol requirements, but pinning it
    // here removes any doubt — if the protocol's required selector ever
    // drifts, the compiler will flag the mismatch instead of failing
    // silently.
    @objc nonisolated func floatingPanelDidMove(_ fpc: FloatingPanelController) {
        MainActor.assumeIsolated {
            recomputeProgress(fpc)
        }
    }

    private func recomputeProgress(_ fpc: FloatingPanelController) {
        let tipY = fpc.surfaceLocation(for: .tip).y
        let halfY = fpc.surfaceLocation(for: .half).y
        let liveY = fpc.surfaceLocation.y
        let span = tipY - halfY
        let value: CGFloat = span > 0 ? min(max((tipY - liveY) / span, 0), 1) : 0
        progress.peekProgress = value
        let revealed = value > 0.4
        if revealed != contentRevealed { contentRevealed = revealed } // emit once per crossing
    }

    nonisolated func floatingPanelWillBeginDragging(_ fpc: FloatingPanelController) {
        MainActor.assumeIsolated {
            isDragging = true
        }
    }

    nonisolated func floatingPanelDidEndDragging(_ fpc: FloatingPanelController, willAttract attract: Bool) {
        MainActor.assumeIsolated {
            // If FloatingPanel will animate-attract to a detent, stay
            // in the dragging state through the attraction so the
            // chrome doesn't pop back to expensive mid-flight.
            if !attract {
                isDragging = false
            }
        }
    }

    nonisolated func floatingPanelDidEndAttracting(_ fpc: FloatingPanelController) {
        MainActor.assumeIsolated {
            isDragging = false
        }
    }

    /// Raise the panel to peek. Routed through `move(to: .tip, ...)` rather
    /// than `controller.show()` so we pin the destination explicitly —
    /// `show()` reads `layout.initialState`, which is `.hidden` after
    /// Move 2 and would not raise the panel into view.
    func raiseToPeek(animated: Bool) {
        controller?.move(to: .tip, animated: animated)
    }

    /// Expand the panel to half. Surface intents: pill-tap from peek
    /// (`collapsedBody.onTapGesture`) and `openNode` (match-tap pushes
    /// detail; drop from `.full` so the detail is visible above the
    /// Librarian rather than behind it).
    func expandToHalf(animated: Bool) {
        controller?.move(to: .half, animated: animated)
    }

    /// Expand the panel to full. Surface intents: input focus
    /// (`isInputFocused` true) and the search-field paste fallback
    /// (`librarian.searchText` empty→non-empty when focus didn't
    /// already promote). Full is the only detent at which the keyboard
    /// composites cleanly (probe Round 2).
    func expandToFull(animated: Bool) {
        controller?.move(to: .full, animated: animated)
    }

    /// Drop the panel from full down to half. Distinct intent from
    /// `expandToHalf` because the source posture is full, not peek —
    /// surfaces a different mental model in callers (collapse vs grow).
    func dropToHalf(animated: Bool) {
        controller?.move(to: .half, animated: animated)
    }

    /// Pin the panel at `.full` for a focused chat posture. The lock
    /// engages SYNCHRONOUSLY before the move so there's no unlocked
    /// window during the shoot-to-full animation — the panel animates
    /// while already locked. `isRemovalInteractionEnabled = false` (the
    /// library default, set here belt-and-suspenders) keeps the duck
    /// path disarmed. Inner scroll lives on a separate recognizer and
    /// is unaffected. The lock IS the absence of drag, not a reactive
    /// snap-back — don't gate it on a move-completion closure that the
    /// library can drop on interruption.
    func lockToFull(animated: Bool) {
        guard let controller else { return }
        controller.isRemovalInteractionEnabled = false
        controller.panGestureRecognizer.isEnabled = false
        isLocked = true
        controller.move(to: .full, animated: animated)
    }

    /// Programmatic exit from the locked-at-full posture (the collapse
    /// affordance in the expanded header taps this). Restores drag
    /// SYNCHRONOUSLY before the move so a dropped move-completion can
    /// never leave the pan gesture permanently disabled, then animates
    /// to `.half`.
    func unlock(animated: Bool) {
        guard let controller else { return }
        clearLock()
        controller.move(to: .half, animated: animated)
    }

    /// Defensive lock-clear. Any forced-exit path (duck, future
    /// programmatic navigation) routes through here so the pan gesture
    /// can never be left disabled with `isLocked` true. Anywhere
    /// `isLocked` could be left true with the gesture disabled is a
    /// permanent wedge — call this on every exit.
    private func clearLock() {
        isLocked = false
        controller?.panGestureRecognizer.isEnabled = true
    }

    /// Removal-veto delegate. While locked, swipe-to-remove is refused
    /// at the source (Core.swift `shouldRemove` — the return value
    /// short-circuits the velocity-threshold check). Free belt to the
    /// `isRemovalInteractionEnabled = false` gate (delegate is only
    /// consulted when that flag is `true`).
    @objc(floatingPanel:shouldRemoveAtLocation:withVelocity:)
    nonisolated func floatingPanel(_ fpc: FloatingPanelController,
                                   shouldRemoveAt location: CGPoint,
                                   with velocity: CGVector) -> Bool {
        MainActor.assumeIsolated {
            return !isLocked
        }
    }

    /// Duck the panel offscreen. Uses the library's `hide(animated:)`
    /// which `move(to: .hidden)`s to the default `hiddenAnchor`. `.hidden`
    /// is not in `LibrarianPanelLayout.anchors` so it isn't a drag target.
    ///
    /// Blunt resignFirstResponder fires first so every duck path
    /// (Dashboard, QuikCapture, capture overlay) dismisses the keyboard
    /// regardless of state-change timing — `@FocusState` alone has
    /// missed when the navigation races the detent change. Harmless
    /// no-op when nothing is first responder.
    ///
    /// Belt: `clearLock()` runs unconditionally so a duck issued while
    /// locked (Dashboard nav, capture overlay) cannot strand the pan
    /// gesture disabled — every forced-exit path restores drag.
    func duck(animated: Bool) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        clearLock()
        controller?.hide(animated: animated)
    }
}

