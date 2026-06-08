import SwiftUI
import FloatingPanel

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
    /// Height of the peek (`.tip`) detent in points. Single source of
    /// truth — the anchor below and any overlay that must ride above the
    /// peek pill (capture "+" buttons on canvas and node detail) read
    /// from here so the value lives in one place.
    static let peekDetentHeight: CGFloat = 95

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

// MARK: - State observer

/// Delegate → observable bridge. `state` mirrors the controller's live
/// detent so panel content can branch per detent. `controller` is the
/// weak handle the entry-mode wiring uses to drive the panel from outside
/// the `.floatingPanel { proxy in … }` builder closure.
@MainActor
final class LibrarianPanelStateModel: NSObject, ObservableObject, FloatingPanelControllerDelegate {
    @Published var state: FloatingPanelState = .tip

    /// True while the user is finger-dragging the panel OR FloatingPanel
    /// is animating the post-release attraction to a detent. The
    /// surface reads this to swap in a cheap static chrome during
    /// motion — the rotating angular-gradient border + blurred glow
    /// re-renders every frame on top of `.thinMaterial`, which stutters
    /// the drag if drawn live (Move 2 fix-pass A). `true` covers both
    /// the drag itself and the attraction so the chrome restore lines
    /// up with the panel coming to rest, not the finger lifting.
    @Published var isDragging: Bool = false
    weak var controller: FloatingPanelController?

    nonisolated func floatingPanelDidChangeState(_ fpc: FloatingPanelController) {
        MainActor.assumeIsolated {
            state = fpc.state
        }
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

    /// Duck the panel offscreen. Uses the library's `hide(animated:)`
    /// which `move(to: .hidden)`s to the default `hiddenAnchor`. `.hidden`
    /// is not in `LibrarianPanelLayout.anchors` so it isn't a drag target.
    func duck(animated: Bool) {
        controller?.hide(animated: animated)
    }
}

