import SwiftUI
import UIKit

/// Stage 3.1b commit (b) — UIKit bridge for the EntryCard long-press →
/// drag reorder interaction.
///
/// **Why UIKit, not SwiftUI's `LongPressGesture.sequenced(before: DragGesture)`:**
/// the SwiftUI composition left its recognizer in a primed state after the
/// first activation that pre-empted the parent ScrollView's pan over cards
/// for the rest of the session (T observed on device 2026-05-16). UIKit's
/// `UILongPressGestureRecognizer` races with the scroll view's pan
/// naturally (hold still 0.5s → long-press wins; move → scroll wins) and
/// resets cleanly every cycle.
///
/// Applied as `.background { ZStack { Color, LongPressDragRecognizer } }`:
/// the recognizer's UIView lives behind the card's foreground content but
/// in front of the color fill. Foreground interactive widgets (chevron
/// Button, ellipsis Menu, text editors, waveform scrub) claim their own
/// hits via separate UIViews; touches that land outside those widgets
/// (the title-bar non-button area, text body whitespace, etc.) reach this
/// view's recognizer, which fires after a 0.5s still-hold.
@MainActor
struct LongPressDragRecognizer: UIViewRepresentable {

    // All four callbacks are typed `@MainActor` so that unstructured `Task { ... }`
    // bodies spawned inside them (notably the release-path Task in
    // `EntryCard.onEnd` that calls `reorder.exit()`) inherit MainActor via
    // `@_inheritActorContext` on `Task.init`. Without this, the closure runs
    // in no-actor context — even though UIKit dispatches the selector on the
    // main thread — and a deferred mutation of `@Observable` MainActor state
    // can land off the actor SwiftUI is observing on, leaving views with
    // stale state (regression filed 2026-05-18: reorder release left
    // `EntryReorderController.mode` stuck in `.lifted` from the view layer's
    // POV, killing chevron/menu/long-press on every card).
    let onLift: @MainActor (CGFloat) -> Void
    let onChange: @MainActor (_ translationY: CGFloat, _ touchWindowY: CGFloat) -> Void
    let onEnd: @MainActor () -> Void
    /// Reads the controller's accumulated scroll delta since lift. Used
    /// when capturing `layoutShift` on first `.changed` so any auto-scroll
    /// that happened before the user moved their finger isn't mistakenly
    /// included in the collapse-reflow correction.
    let scrollDeltaProvider: @MainActor () -> CGFloat

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        recognizer.minimumPressDuration = 0.5
        recognizer.allowableMovement = 10
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onLift = onLift
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
        context.coordinator.scrollDeltaProvider = scrollDeltaProvider
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLift: onLift,
            onChange: onChange,
            onEnd: onEnd,
            scrollDeltaProvider: scrollDeltaProvider
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var onLift: @MainActor (CGFloat) -> Void
        var onChange: @MainActor (CGFloat, CGFloat) -> Void
        var onEnd: @MainActor () -> Void
        var scrollDeltaProvider: @MainActor () -> CGFloat
        private var startY: CGFloat = 0
        private var startViewY: CGFloat = 0
        /// Captured on the first `.changed` after lift. Compensates for the
        /// layout reflow that happens between `.began` (when onLift triggers
        /// the global collapse-all) and the first drag tick: if there was
        /// an expanded sibling above this card, its collapse shifts this
        /// card's natural position upward, which would otherwise make the
        /// lifted card visually "shoot" away from the finger. Captured
        /// once and reused — `.offset` doesn't change natural layout, only
        /// the displayed position. Auto-scroll between `.began` and first
        /// `.changed` would also move the view; subtract `scrollDelta` at
        /// capture time so we isolate the layout reflow.
        private var layoutShift: CGFloat? = nil
        private var didLift = false

        init(
            onLift: @escaping @MainActor (CGFloat) -> Void,
            onChange: @escaping @MainActor (CGFloat, CGFloat) -> Void,
            onEnd: @escaping @MainActor () -> Void,
            scrollDeltaProvider: @escaping @MainActor () -> CGFloat
        ) {
            self.onLift = onLift
            self.onChange = onChange
            self.onEnd = onEnd
            self.scrollDeltaProvider = scrollDeltaProvider
        }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            // Read the touch in window coordinates, NOT in the recognizer's
            // own view. The recognizer lives inside the EntryCard, which is
            // moved by SwiftUI's `.offset` as the drag progresses — so the
            // view follows the finger, which makes `location(in: view)`
            // report ~0 translation and the card visibly lags. Window space
            // is stationary while the card moves, so translation here equals
            // pure finger movement on screen.
            let location = recognizer.location(in: nil)
            switch recognizer.state {
            case .began:
                startY = location.y
                startViewY = recognizer.view?.convert(CGPoint.zero, to: nil).y ?? 0
                layoutShift = nil
                didLift = true
                onLift(location.y)
            case .changed:
                guard didLift else { return }
                if layoutShift == nil, let v = recognizer.view {
                    // First `.changed` after lift: layout has settled into
                    // its all-collapsed state. The raw delta is reflow shift
                    // MINUS any scroll that's accumulated since `.began`,
                    // because scrolling down (scrollDelta > 0) moves the
                    // content up in the visible area (view.window.y
                    // decreases). Add scrollDelta back so layoutShift
                    // isolates the pure reflow component.
                    let raw = v.convert(CGPoint.zero, to: nil).y - startViewY
                    layoutShift = raw + scrollDeltaProvider()
                }
                let shift = layoutShift ?? 0
                onChange((location.y - startY) - shift, location.y)
            case .ended, .cancelled, .failed:
                // `.failed` fires when the user moved beyond
                // `allowableMovement` during the 0.5s wait — i.e. they were
                // trying to scroll. Skip onEnd in that case since onLift
                // was never called.
                guard didLift else { return }
                didLift = false
                onEnd()
            default:
                break
            }
        }
    }
}
