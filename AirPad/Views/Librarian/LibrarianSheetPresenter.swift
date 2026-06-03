import SwiftUI
import UIKit

/// Mirrors the live `UISheetPresentationController.selectedDetentIdentifier`
/// into observable state so `LibrarianSurface` can branch its body content
/// per detent (`collapsedBody` / whispers at peek vs `expandedBody` at
/// medium/large). Owned by the presenter's `Coordinator`, written from the
/// sheet delegate callback, and read by the surface via its
/// `detentState:` init parameter.
@Observable
final class LibrarianSheetDetentState {
    /// Which detent the sheet is currently sitting at. Three-valued so
    /// downstream chrome (the canvas "+" capture button) can adjust
    /// padding per detent — peek lifts above 95pt, medium lifts above
    /// the half-screen, large hides the button entirely.
    enum SelectedDetent: Sendable {
        case peek
        case medium
        case large
    }

    /// Live detent. Defaults to `.peek` because we open the sheet at
    /// peek — the first `didChangeSelectedDetentIdentifier` callback
    /// only fires on subsequent user-driven detent changes, not on the
    /// initial presentation.
    var selectedDetent: SelectedDetent = .peek

    /// Convenience for the surface body branch (collapsedBody vs
    /// expandedBody). Computed so it stays in lockstep with
    /// `selectedDetent`; @Observable propagates tracking through
    /// computed properties.
    var isAtPeek: Bool { selectedDetent == .peek }
}

/// Presents `LibrarianSurface` via `UISheetPresentationController` instead of
/// the bottom-anchored ZStack overlay. The system sheet gives native
/// scroll/drag coordination for free; the load-bearing reason for the swap is
/// that we walk the sheet container's pan gesture recognizers after present
/// and flip `cancelsTouchesInView = false` so they stop cancelling SpriteKit
/// touches in the canvas behind it. Honeycomb engagement then holds at peek
/// and medium detents instead of disengaging the moment the sheet sees a
/// finger.
///
/// Three detents: custom 95pt "peek" (whispers + sparkle icon),
/// `.medium()`, `.large()`. Native peek→medium→large transitions give the
/// continuous motion the floating-pill references called for, with the
/// system's own drag/scroll coordination underneath.
///
/// Mounted as `.background` on the SpriteView in `CanvasView` (and the
/// list root in `NodeListView`) so the representable has a UIViewController
/// in the hierarchy that can call `present(...)` without sitting in the
/// foreground ZStack.
///
/// Presentation lifecycle is driven by two observed properties on
/// `LibrarianState`: `sheetPresented` (true = present / stay presented,
/// false = dismiss) and `sheetInitialDetent` (which detent to open at on
/// the next present / re-present). Capture-button-tap and CanvasView
/// `.onDisappear` both flip `sheetPresented = false`; capture-overlay
/// dismissal flips it back with `sheetInitialDetent = .medium`.
///
/// Environment crosses the UIKit boundary explicitly: `UIHostingController`
/// does not inherit SwiftUI `@Environment` values from its parent SwiftUI
/// view. Every `@Environment(SomeType.self)` that `LibrarianSurface` (or any
/// descendant view it presents inline) reads must be re-injected on the
/// rootView here. Today the surface needs `CorpusStore` and `AppRouter`;
/// `SelectionService` and `QuarantineStore` are mirrored from the app root
/// as a safety net so future surface descendants Just Work without another
/// boundary fix.
struct LibrarianSheetPresenter: UIViewControllerRepresentable {

    let store: CorpusStore
    let router: AppRouter
    let selection: SelectionService
    let quarantineStore: QuarantineStore
    let hostScope: CanvasScope

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Bind the coordinator to the router-owned detent state on every
        // update so the delegate callback writes into the shared object
        // the surface reads from. Idempotent reassignment; cheap.
        context.coordinator.detentState = router.librarian.sheetDetentState

        let librarian = router.librarian

        // Dismiss path. Capture-button-tap and CanvasView/NodeListView
        // `.onDisappear` flip `sheetPresented = false`; the F1 capture
        // flow re-flips it back to true once the capture overlay is
        // dismissed.
        if !librarian.sheetPresented {
            if let presented = context.coordinator.presentedHostingVC,
               presented.presentingViewController != nil {
                print("[LibrarianSheet] \(context.coordinator.id) dismiss (sheetPresented=false)")
                presented.dismiss(animated: true)
            } else {
                print("[LibrarianSheet] \(context.coordinator.id) dismiss no-op (no presented VC)")
            }
            context.coordinator.presentedHostingVC = nil
            return
        }

        let freshRoot = AnyView(makeRootView(coordinator: context.coordinator))

        // Already presented — just refresh the rootView so parent
        // re-renders propagate across the UIKit boundary, and bail.
        if let presented = context.coordinator.presentedHostingVC,
           presented.presentingViewController != nil {
            presented.rootView = freshRoot
            return
        }

        print("[LibrarianSheet] \(context.coordinator.id) present (firstMount=\(!context.coordinator.hasMountedSheetBefore), detent=\(librarian.sheetInitialDetent))")

        // First mount or re-present (after an F1 capture round-trip).
        // Build a fresh hosting controller and present it at the
        // detent `librarian.sheetInitialDetent` asks for.
        let hostingVC = UIHostingController(rootView: freshRoot)
        hostingVC.view.backgroundColor = .clear

        let initialDetent = librarian.sheetInitialDetent
        if let sheet = hostingVC.sheetPresentationController {
            sheet.detents = [
                .custom(identifier: .init("peek")) { _ in 95 },
                .medium(),
                .large()
            ]
            // Without this the system picks its own default detent —
            // on device that came out as medium-ish, so peek was never
            // actually rendered and the "+" capture button stayed
            // covered. Pinning the initial selection forces the
            // intended detent on present; user can still drag freely.
            sheet.selectedDetentIdentifier = Self.identifier(for: initialDetent)
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 44
        }

        context.coordinator.presentedHostingVC = hostingVC

        // Pre-flip the observed detent so body content (collapsedBody
        // vs expandedBody) renders correctly on this present pass —
        // the delegate callback only fires on subsequent user-driven
        // changes, not on the initial selection.
        context.coordinator.detentState?.selectedDetent = initialDetent

        let isFirstMount = !context.coordinator.hasMountedSheetBefore
        context.coordinator.hasMountedSheetBefore = true

        let present: (UIHostingController<AnyView>) -> Void = { [weak uiViewController, weak coordinator = context.coordinator] hostingVC in
            guard let uiViewController, let coordinator else { return }
            // First mount: animated=false to match the no-transition
            // entrance the morphing-pill had. Re-present: animated=true
            // so the sheet slides back up snappily after a capture
            // round-trip — it's a deliberate return, not a chrome swap.
            uiViewController.present(hostingVC, animated: !isFirstMount) { [hostingVC, weak coordinator] in
                // Pin the dismiss-blocking + detent-tracking delegate
                // as soon as the presentation controller exists.
                // Assigning before present() doesn't take — the
                // presentation controller isn't fully attached until
                // the present call lands. Setting on
                // `sheetPresentationController` (not the plain
                // `presentationController` slot) is what wires up
                // `sheetPresentationControllerDidChangeSelectedDetentIdentifier`;
                // assigning to the adaptive-delegate slot alone misses
                // the sheet-specific callback and the detent state
                // never updates as the user drags between peek/medium.
                hostingVC.sheetPresentationController?.delegate = coordinator

                // Let the sheet fully attach before walking gesture
                // recognizers — UIKit installs pan handlers up the
                // container chain during presentation completion, not
                // only on the immediate superview. Walking all the way
                // to the window catches every pan that would otherwise
                // swallow touches before they reach SpriteKit.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [hostingVC] in
                    Coordinator.disableTouchCancellation(from: hostingVC.view)
                }
            }
        }

        if isFirstMount {
            // First mount: the 0.3s buys enough time for SwiftUI to
            // attach the representable's VC to the window hierarchy.
            // `updateUIViewController` doesn't re-fire after
            // window-attach, so checking `view.window != nil` up
            // front silently no-ops on first mount and the sheet
            // never appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [hostingVC] in
                present(hostingVC)
            }
        } else {
            // Re-present: window-attach already happened on first
            // mount; present immediately so capture→sheet return
            // feels instant rather than introducing a 0.3s gap on
            // every round-trip.
            present(hostingVC)
        }
    }

    private static func identifier(for detent: LibrarianSheetDetentState.SelectedDetent) -> UISheetPresentationController.Detent.Identifier {
        switch detent {
        case .peek:   return .init("peek")
        case .medium: return .medium
        case .large:  return .large
        }
    }

    /// `coordinator` is threaded in so the chevron-tap closure can
    /// reach back to the live `presentedHostingVC` and animate the
    /// sheet's selected detent back to "peek". Capturing the coordinator
    /// weakly avoids a retain cycle (coordinator → hostingVC → rootView →
    /// closure → coordinator); the cycle would otherwise outlive the
    /// representable.
    private func makeRootView(coordinator: Coordinator) -> some View {
        LibrarianSurface(
            hostScope: hostScope,
            isSystemSheet: true,
            detentState: coordinator.detentState,
            onChevronTap: { [weak coordinator] in
                guard let sheet = coordinator?.presentedHostingVC?.sheetPresentationController else { return }
                // Pre-flip the observed detent so collapsedBody
                // renders this frame; the delegate callback only
                // fires once the system finishes animating, which is
                // too late for the body to swap.
                coordinator?.detentState?.selectedDetent = .peek
                sheet.animateChanges {
                    sheet.selectedDetentIdentifier = .init("peek")
                }
            },
            onExpandTap: { [weak coordinator] in
                guard let sheet = coordinator?.presentedHostingVC?.sheetPresentationController else { return }
                // Pre-flip so expandedBody renders this frame;
                // delegate callback fires post-animation, too late
                // for the body branch to swap on tap.
                coordinator?.detentState?.selectedDetent = .medium
                sheet.animateChanges {
                    sheet.selectedDetentIdentifier = .medium
                }
            },
            onSearchExpandTap: { [weak coordinator] in
                guard let sheet = coordinator?.presentedHostingVC?.sheetPresentationController else { return }
                // First-keystroke grow: drive sheet to .large so the
                // results pane gets the full window.
                coordinator?.detentState?.selectedDetent = .large
                sheet.animateChanges {
                    sheet.selectedDetentIdentifier = .large
                }
            },
            onNavigateCollapse: { [weak coordinator] in
                guard let sheet = coordinator?.presentedHostingVC?.sheetPresentationController else { return }
                // Match-tap → push detail: drop sheet to .medium so
                // the destination view is visible above the sheet.
                // No-op if already at medium or smaller (animateChanges
                // tolerates same-detent assignment).
                coordinator?.detentState?.selectedDetent = .medium
                sheet.animateChanges {
                    sheet.selectedDetentIdentifier = .medium
                }
            }
        )
        .environment(store)
        .environment(router)
        .environment(selection)
        .environment(quarantineStore)
        // Background lives INSIDE the rootView (via `.background`) rather
        // than in `.presentationBackground { ... }`. On iOS 26 the sheet's
        // Liquid Glass composites over presentationBackground content,
        // washing out (or fully suppressing) our dark material + rainbow
        // glow. Putting the chrome inside the rootView puts it in the
        // normal SwiftUI render path; clearing presentationBackground
        // tells the sheet to skip its own glass treatment so only ours
        // renders.
        //
        // `.ignoresSafeArea(.all)` is scoped to the background view only
        // so the chrome fills the sheet's true bounds at every detent —
        // without it, the background inherits the foreground's safe-area
        // insets (top grabber zone + bottom home indicator) and our 44pt
        // rounded rect draws *inside* the sheet's 44pt clip, leaving the
        // stroke as a horizontal line across the pill with the true
        // corners cut off. The foreground (LibrarianSurface) continues
        // respecting safe area normally; `collapsedBody`'s own
        // `.ignoresSafeArea` handles peek centering.
        .background {
            LibrarianSheetBackground()
                .ignoresSafeArea(.all)
        }
        .presentationBackground(.clear)
    }

    /// Inherits NSObject so it can satisfy the `@objc`-bridged
    /// `UISheetPresentationControllerDelegate` protocol (which extends
    /// `UIAdaptivePresentationControllerDelegate`). Two responsibilities:
    /// 1. `shouldDismiss → false` clamps swipe-down from peek so the
    ///    Librarian stays mounted at peek/medium/large and is never
    ///    swipe-dismissed by the user. The presenter itself can still
    ///    dismiss programmatically via `librarian.sheetPresented = false`.
    /// 2. `didChangeSelectedDetentIdentifier` mirrors the live detent
    ///    into `detentState.selectedDetent` so the surface can render
    ///    collapsedBody at peek and expandedBody at medium/large.
    final class Coordinator: NSObject, UISheetPresentationControllerDelegate {
        /// Short ID for log correlation — lets us tell whether two
        /// coordinators are alive simultaneously during a view-mode
        /// toggle (graph↔list) or scope switch. Diagnostic only.
        let id = String(UUID().uuidString.prefix(6))

        override init() {
            super.init()
            print("[LibrarianSheet] Coordinator.init \(id)")
        }

        deinit {
            print("[LibrarianSheet] Coordinator.deinit \(id)")
        }

        /// Strong reference. The hostingVC is created locally inside
        /// `updateUIViewController` and presented 0.3s later; without a
        /// strong owner here, ARC deallocates it the moment update returns
        /// and the present call fires with a dead view controller. Reset
        /// to nil on dismiss so the next `sheetPresented = true` takes
        /// the re-present path instead of the "already presented, just
        /// refresh rootView" path.
        var presentedHostingVC: UIHostingController<AnyView>?

        /// Wired from `updateUIViewController` to
        /// `router.librarian.sheetDetentState`. Optional because the
        /// coordinator is constructed by `makeCoordinator()` before
        /// `updateUIViewController` runs; treat nil as "no consumers
        /// yet" rather than substituting a local instance that would
        /// fork the live state from what the surface reads.
        var detentState: LibrarianSheetDetentState?

        /// True after the first successful present pass. Skips the
        /// 0.3s window-attach delay on re-presents (capture → sheet
        /// return), since the representable's VC is already wired
        /// into the window hierarchy after first mount.
        var hasMountedSheetBefore: Bool = false

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            false
        }

        func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheetPresentationController: UISheetPresentationController) {
            let newDetent: LibrarianSheetDetentState.SelectedDetent
            switch sheetPresentationController.selectedDetentIdentifier?.rawValue {
            case "peek":
                newDetent = .peek
            case UISheetPresentationController.Detent.Identifier.medium.rawValue:
                newDetent = .medium
            case UISheetPresentationController.Detent.Identifier.large.rawValue:
                newDetent = .large
            default:
                return
            }

            if detentState?.selectedDetent != newDetent {
                detentState?.selectedDetent = newDetent
            }

            // When the sheet returns to peek (chevron tap or user drag),
            // re-run the gesture-recognizer walk. UIKit can rebuild the
            // pan handlers on detent transitions; without re-disabling
            // their `cancelsTouchesInView`, SpriteKit stops receiving
            // touches and the canvas appears frozen.
            if newDetent == .peek, let view = presentedHostingVC?.view {
                Coordinator.disableTouchCancellation(from: view)
            }
        }

        /// Walks up the view hierarchy from `start` to the window,
        /// flipping `cancelsTouchesInView = false` on every
        /// `UIPanGestureRecognizer`. Runs at present-completion and on
        /// every return-to-peek so the SpriteKit canvas behind the sheet
        /// stays touch-responsive after detent transitions.
        static func disableTouchCancellation(from start: UIView?) {
            var view: UIView? = start
            while let v = view {
                v.gestureRecognizers?.forEach { gr in
                    if gr is UIPanGestureRecognizer {
                        gr.cancelsTouchesInView = false
                    }
                }
                view = v.superview
            }
        }
    }
}
