import Foundation
import Observation

/// Multi-select primitive shared by Graph and List modes. Independent of
/// `CorpusStore` so selection state outlives mode switches and corpus mutations
/// without coupling to persistence. Lives only in memory; never persisted —
/// exiting the app clears any in-flight selection.
@Observable
@MainActor
final class SelectionService {

    /// True when the user is in selection mode. Taps on nodes toggle inclusion
    /// instead of engaging/navigating.
    var isActive: Bool = false

    /// Currently selected node IDs. Persists across Graph↔List switches while
    /// `isActive` is true; cleared on `exit()`.
    var selected: Set<String> = []

    var count: Int { selected.count }

    var isEmpty: Bool { selected.isEmpty }

    func enter() {
        isActive = true
    }

    func exit() {
        isActive = false
        selected.removeAll()
    }

    func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    func isSelected(_ id: String) -> Bool {
        selected.contains(id)
    }

    /// Drop IDs that no longer exist (called after a batch delete completes so
    /// the selection set doesn't retain references to nodes that were just removed).
    /// If the selection set is empty after the prune, exits selection mode so
    /// the user lands back at the corpus instead of a stranded selection bar.
    func prune(deletedIDs: Set<String>) {
        selected.subtract(deletedIDs)
        if selected.isEmpty {
            exit()
        }
    }
}
