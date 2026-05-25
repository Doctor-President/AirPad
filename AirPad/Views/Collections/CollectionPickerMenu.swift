import SwiftUI

/// Reusable menu content for picking a collection — used by the batch action
/// surface to drive Add-to-Collection and Move-to-Collection. Mirrors the
/// shape of `TagPickerMenuContent`: the label and the `Menu { ... }` wrapper
/// are owned by the call site; this just supplies the items.
///
/// Ordering mirrors the QuikCapture pill rail: Journal first (virtual),
/// then user collections sorted by `collectionLastUsedAt` descending so
/// recently-used targets surface near the top.
///
/// `excludeID` removes one entry from the list — pass the current scope's
/// collection ID at a `.collection(id)` canvas so the user can't "Add to"
/// or "Move to" the collection they're already in. Pass `nil` at the
/// corpus scope to show every collection.
struct CollectionPickerMenuContent: View {

    let collections: [NodeCollection]
    let collectionLastUsedAt: [String: Date]
    let excludeID: String?
    let onPick: (String) -> Void

    var body: some View {
        let available = orderedRail.filter { $0.id != excludeID }
        ForEach(available) { collection in
            Button(collection.name) { onPick(collection.id) }
        }
    }

    private var orderedRail: [NodeCollection] {
        let journal = NodeCollection(id: NodeCollection.journalID, name: "Journal")
        let all = [journal] + collections
        return all.sorted { a, b in
            let aDate = collectionLastUsedAt[a.id] ?? .distantPast
            let bDate = collectionLastUsedAt[b.id] ?? .distantPast
            return aDate > bDate
        }
    }
}
