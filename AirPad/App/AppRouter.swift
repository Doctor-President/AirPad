import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    enum EntryMode: Sendable { case dashboard, canvas, quikCapture }

    static var shared: AppRouter?

    var entryMode: EntryMode = .dashboard

    init() {
        AppRouter.shared = self
    }
}
