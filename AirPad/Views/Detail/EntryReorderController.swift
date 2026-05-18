import SwiftUI
import UIKit

/// Stage 3.1b commit (b) — controller for the detail view's drag-to-reorder
/// mode. Holds the *entire* transient UI state of a reorder cycle so the
/// store never sees per-tick mutations. Persisted state changes exactly
/// once, at release time, via `CorpusStore.moveEntry`.
///
/// **Controller-holds-the-snapshot pattern (per T, 2026-05-16):** the
/// items array is snapshotted into the controller at engage time and used
/// as the source of truth for "where would card X land if released now"
/// math while the drag runs. Cards on screen read their offsets from the
/// controller; the underlying `node.items` array doesn't reflow until
/// release. This pattern keeps the store free of UI-only churn and will
/// recur for future transient modes (multi-select, undo-preview).
///
/// State machine:
///   .inactive           — normal interaction, no card lifted
///   .engaged            — menu-path entry, all cards collapsed, no lift yet
///   .lifted(id, origIdx) — a card is held; drag tracking + parting active
///
/// Transitions:
///   .inactive  → .engaged          (Reorder menu item tapped)
///   .inactive  → .lifted           (long-press on a card)
///   .engaged   → .lifted           (long-press on a card while engaged)
///   .lifted    → .inactive         (release — commits if indices differ)
///   .engaged   → .inactive         (Done button)
///   .lifted    → .engaged          (drag canceled — returns to held state
///                                   only if we ever wire cancel; today
///                                   release is the only ending per brief)
@available(iOS 17.0, *)
@MainActor
@Observable
final class EntryReorderController {

    enum Mode: Equatable {
        case inactive
        case engaged
        case lifted(itemID: String, originalIndex: Int)
    }

    /// Per-card visual treatment derived from the current mode and drag
    /// state. `EntryCard` reads this once per render to decide its
    /// scale/shadow/offset/collapse without re-implementing the state
    /// machine.
    struct CardPresentation: Equatable {
        var isLifted: Bool = false
        /// Vertical offset to apply to this card. Positive = move down,
        /// negative = move up. Used both for the lifted card (follows
        /// finger) and for other cards parting around its drop slot.
        var offsetY: CGFloat = 0
        /// `true` whenever reorder mode is active (engaged or lifted),
        /// signaling the card to render in collapsed title-only form and
        /// suppress menu / chevron interactions.
        var reorderActive: Bool = false
    }

    // MARK: - Public state (read by views)

    private(set) var mode: Mode = .inactive

    /// Frozen at engage time. Used to compute drop indices and parting
    /// offsets without reading from the (potentially mutating) store.
    private(set) var snapshot: [String] = []

    /// Live drag translation in points (finger movement only — does NOT
    /// include scroll delta). Reset on lift/release.
    private(set) var dragTranslation: CGFloat = 0

    /// Accumulated scroll-offset change since lift, in points. The
    /// `AutoScrollDriver` reports this when it auto-scrolls the list near
    /// screen edges; the controller adds it to `dragTranslation` for both
    /// the lifted card's visual offset AND the slot-shift math, so the
    /// card slides through slots as the list scrolls past it (mirror of
    /// the reflow compensation: a scroll of X is equivalent to a finger
    /// movement of X for slot-shift purposes).
    private(set) var scrollDelta: CGFloat = 0

    /// Current touch position in window coordinates while a card is
    /// lifted. The `AutoScrollDriver` reads this to decide when the finger
    /// is in the top/bottom edge zone. `nil` outside .lifted state.
    private(set) var currentTouchWindowY: CGFloat? = nil

    /// Index in `snapshot` where the lifted card would land if released
    /// now. `nil` outside .lifted state.
    private(set) var currentDropIndex: Int? = nil

    // MARK: - Tunables

    /// Vertical pitch (card height + spacing) between consecutive collapsed
    /// cards in the scroll list. Derived from EntryCard's collapsed height
    /// (44pt title row + 12pt × 2 padding = 68pt) plus NodeDetailView's
    /// VStack spacing (24pt). Re-tune if either changes.
    static let slotPitch: CGFloat = 92

    static let liftedScale: CGFloat = 1.05
    static let liftedShadowOpacity: Double = 0.2
    static let liftedShadowRadius: CGFloat = 8
    static let liftedShadowOffsetY: CGFloat = 4

    static let edgeAutoScrollZone: CGFloat = 80
    static let landingAnimationDuration: Double = 0.25

    // MARK: - Engage / lift / release

    /// Enter reorder mode without lifting any card. Called by the "Reorder"
    /// menu action — user then long-presses a card to lift. Emits a medium
    /// haptic so the mode shift is felt.
    func engageMenuPath(snapshotIDs: [String]) {
        guard mode == .inactive else { return }
        snapshot = snapshotIDs
        mode = .engaged
        dragTranslation = 0
        currentDropIndex = nil
        fireImpactHaptic()
    }

    /// Long-press on a card commits straight to .lifted. Snapshot is
    /// captured here if we weren't already engaged via the menu path.
    /// Returns `true` if the lift was accepted; `false` if the controller
    /// rejected it (already lifting something else, or item not found).
    @discardableResult
    func lift(itemID: String, snapshotIDs: [String]) -> Bool {
        switch mode {
        case .lifted:
            return false
        case .inactive:
            snapshot = snapshotIDs
        case .engaged:
            // Snapshot already captured; reuse to keep indices stable
            // even if the store reflowed in between (shouldn't happen
            // during reorder mode, but cheap defensive choice).
            if snapshot != snapshotIDs { snapshot = snapshotIDs }
        }
        guard let originalIndex = snapshot.firstIndex(of: itemID) else { return false }
        mode = .lifted(itemID: itemID, originalIndex: originalIndex)
        dragTranslation = 0
        scrollDelta = 0
        currentTouchWindowY = nil
        currentDropIndex = originalIndex
        fireImpactHaptic()
        return true
    }

    /// Called by the gesture's `onChanged` with the drag translation in
    /// points and the current finger position in window coords. Updates
    /// the drop index based on `slotPitch` snap math, combining drag and
    /// scroll deltas.
    func updateDrag(translationY: CGFloat, touchWindowY: CGFloat) {
        guard case .lifted = mode else { return }
        dragTranslation = translationY
        currentTouchWindowY = touchWindowY
        recomputeDropIndex()
    }

    /// Called by the `AutoScrollDriver` whenever it auto-scrolls the list.
    /// `delta` is the total accumulated scroll offset shift since lift
    /// (positive = list scrolled down, content moved up under the finger).
    /// Adding it to `dragTranslation` for slot-shift math means the lifted
    /// card advances through slots as scroll moves content past it.
    func setScrollDelta(_ delta: CGFloat) {
        guard case .lifted = mode else { return }
        scrollDelta = delta
        recomputeDropIndex()
    }

    private func recomputeDropIndex() {
        guard case .lifted(_, let originalIndex) = mode else { return }
        let effective = dragTranslation + scrollDelta
        let slotShift = Int((effective / Self.slotPitch).rounded())
        let target = max(0, min(snapshot.count - 1, originalIndex + slotShift))
        currentDropIndex = target
    }

    /// Called by the gesture's `onEnded`. Returns `(from, to, slotDelta)`
    /// if the user actually moved the card; `nil` if they released without
    /// changing position. Does NOT clear controller state — the caller is
    /// expected to (1) synchronously apply the in-memory store mutation
    /// via `CorpusStore.applyMoveEntry`, (2) synchronously call
    /// `compensateForReorder(slotDelta:)` in the *same* render tick so
    /// SwiftUI batches the array reflow and the offset adjustment into
    /// one frame (otherwise the card flashes by `slotPitch × slotDelta`
    /// while the disk save awaits), then (3) `await` persistence,
    /// (4) yield a render so the compensated frame commits, and finally
    /// (5) `exit()` to fire the landing animation from the compensated
    /// value to 0.
    @discardableResult
    func release() -> (from: Int, to: Int, slotDelta: Int)? {
        // Stop auto-scroll immediately on lift-off — even if we stay in
        // .lifted mode across the store-commit await below, we don't want
        // the AutoScrollDriver to keep scrolling based on the stale finger
        // position from the last `.changed`.
        currentTouchWindowY = nil
        guard case .lifted(_, let originalIndex) = mode else {
            exit()
            return nil
        }
        let newIndex = currentDropIndex ?? originalIndex
        if newIndex == originalIndex {
            exit()
            return nil
        }
        return (originalIndex, newIndex, newIndex - originalIndex)
    }

    /// Called synchronously right after `CorpusStore.applyMoveEntry` so
    /// both mutations land in the same SwiftUI render tick. Adjusts
    /// `dragTranslation` to absorb the slot-shift the reflow just applied
    /// to the card's natural layout position, so the card's rendered
    /// position is unchanged across the array commit. Mode stays `.lifted`
    /// so the offset applies without animation; the caller then awaits
    /// persistence and yields one render (so SwiftUI commits this
    /// compensated frame) before calling `exit()`, which triggers the
    /// landing animation from the compensated value to 0 instead of from
    /// the raw finger translation.
    func compensateForReorder(slotDelta: Int) {
        guard case .lifted = mode else { return }
        dragTranslation -= CGFloat(slotDelta) * Self.slotPitch
    }

    /// Done button tap — exits reorder mode cleanly with no commit. Used
    /// by the menu-path entry; only meaningful when nothing is currently
    /// being dragged. If called mid-drag it cancels the pending drop too.
    func exit() {
        mode = .inactive
        snapshot = []
        dragTranslation = 0
        scrollDelta = 0
        currentTouchWindowY = nil
        currentDropIndex = nil
    }

    // MARK: - Per-card presentation

    /// Computes the visual treatment for a card with `itemID` at `index`
    /// in the current node's items array. Cards call this in their body
    /// to read offset/scale/shadow without knowing about the state machine.
    func presentation(forItemID itemID: String, atIndex index: Int) -> CardPresentation {
        switch mode {
        case .inactive:
            return CardPresentation()

        case .engaged:
            return CardPresentation(isLifted: false, offsetY: 0, reorderActive: true)

        case .lifted(let liftedID, let originalIndex):
            if itemID == liftedID {
                return CardPresentation(
                    isLifted: true,
                    offsetY: dragTranslation + scrollDelta,
                    reorderActive: true
                )
            }
            // Parting math: when the lifted card's drop index has moved past
            // this card, shift this card toward the lifted card's vacated
            // slot to open the gap. Movement is exactly one slotPitch.
            guard let drop = currentDropIndex else {
                return CardPresentation(isLifted: false, offsetY: 0, reorderActive: true)
            }
            var offset: CGFloat = 0
            if drop > originalIndex, index > originalIndex, index <= drop {
                offset = -Self.slotPitch
            } else if drop < originalIndex, index < originalIndex, index >= drop {
                offset = Self.slotPitch
            }
            return CardPresentation(isLifted: false, offsetY: offset, reorderActive: true)
        }
    }

    /// True whenever reorder mode is active in any form. Detail view uses
    /// this to swap the trash button for Done and hide the floating "+".
    var isReorderActive: Bool {
        mode != .inactive
    }

    /// True when a card is currently lifted. Floating "+", menus, and
    /// chevrons should all be suppressed in either reorder substate, but
    /// some chrome (e.g. status overlays) only cares about the lifted
    /// substate.
    var isCardLifted: Bool {
        if case .lifted = mode { return true }
        return false
    }

    // MARK: - Haptics

    private func fireImpactHaptic() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
    }
}
