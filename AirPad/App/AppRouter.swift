import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    enum EntryMode: Sendable { case canvas, quikCapture }

    static var shared: AppRouter?

    var entryMode: EntryMode = .canvas

    init() {
        AppRouter.shared = self
    }
}
