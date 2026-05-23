import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    enum EntryMode: Sendable {
        case dashboard
        case canvas
        /// QuikCapture surface. `forcedCollectionID` pins the capture to a
        /// specific collection (CollectionView "+" path in c4.7); nil leaves
        /// the active collection up to QuikCapture's pill rail (URL-scheme
        /// entry and dashboard "+" in c4.6 — both pass nil).
        case quikCapture(forcedCollectionID: String?)
    }

    static var shared: AppRouter?

    var entryMode: EntryMode = .dashboard

    init() {
        AppRouter.shared = self
    }
}
