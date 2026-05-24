import Foundation
import Observation

/// Multi-select primitive shared by Graph and List modes. Independent of
/// `CorpusStore` so selection state outlives mode switches and corpus mutations
/// without coupling to persistence. Lives only in memory; never persisted —
/// exiting the app clears any in-flight selection.
///
/// Per-scope (Canvas Chrome arc, A3). Each `CanvasScope` has its own selection
/// set; only one scope is "active" at a time. Strict no-cross-scope: public
/// accessors expose only the active scope's set. Entering selection mode on a
/// different scope swaps the active set without disturbing the others.
@Observable
@MainActor
final class SelectionService {

    /// Scope that owns the in-flight selection, or nil when not in selection
    /// mode. Setting this is how `enter(scope:)` switches contexts.
    private(set) var activeScope: CanvasScope?

    /// Per-scope selected-ID sets, keyed by `CanvasScope.key`. Inactive scopes'
    /// sets persist in memory so returning to a canvas after a navigation
    /// detour shows its prior selection — chrome lifecycle (Phase C/D) decides
    /// whether to auto-exit on disappear.
    private var sets: [String: Set<String>] = [:]

    /// True when the user is in selection mode. Taps on nodes toggle inclusion
    /// instead of engaging/navigating.
    var isActive: Bool { activeScope != nil }

    /// Currently selected node IDs in the active scope. Empty when no scope is
    /// active. Persists across Graph↔List switches while `isActive` is true;
    /// cleared on `exit()`.
    var selected: Set<String> {
        guard let key = activeScope?.key else { return [] }
        return sets[key] ?? []
    }

    var count: Int { selected.count }

    var isEmpty: Bool { selected.isEmpty }

    func enter(scope: CanvasScope) {
        activeScope = scope
    }

    func exit() {
        if let key = activeScope?.key {
            sets[key] = []
        }
        activeScope = nil
    }

    func toggle(_ id: String) {
        guard let key = activeScope?.key else { return }
        var s = sets[key] ?? []
        if s.contains(id) {
            s.remove(id)
        } else {
            s.insert(id)
        }
        sets[key] = s
    }

    func isSelected(_ id: String) -> Bool {
        guard let key = activeScope?.key else { return false }
        return sets[key]?.contains(id) ?? false
    }

    /// Drop IDs that no longer exist (called after a batch delete completes so
    /// the selection set doesn't retain references to nodes that were just removed).
    /// If the active scope's selection set is empty after the prune, exits
    /// selection mode so the user lands back at the corpus instead of a
    /// stranded selection bar.
    func prune(deletedIDs: Set<String>) {
        guard let key = activeScope?.key else { return }
        var s = sets[key] ?? []
        s.subtract(deletedIDs)
        sets[key] = s
        if s.isEmpty {
            exit()
        }
    }
}
