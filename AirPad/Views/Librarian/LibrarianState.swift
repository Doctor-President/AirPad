import Foundation
import Observation

/// App-level Librarian session state. Lives on `AppRouter.librarian` and
/// travels across canvas, list, and (future) detail-view mounts so a
/// session in flight survives navigation between surfaces.
///
/// For commit 1 this carries only the tap-through hand-off for
/// `CorpusQuerySheet` — that sheet remains the typing affordance while
/// in-place morphing, the mode dropdown, scope chips, and conversation
/// history land in subsequent commits.
@Observable
@MainActor
final class LibrarianState {
    /// True when the Librarian's tap-through sheet is presented. The
    /// surface owns the binding; the flag lives here so future commits can
    /// drive the sheet from outside the view (e.g. a whisper inline-tap
    /// that pre-loads a query).
    var isPresentingQuerySheet: Bool = false

    /// Pre-populated query text passed into the sheet when it opens.
    /// Source today is the currently visible ghost-whisper at tap time,
    /// matching pre-Librarian behavior.
    var pendingQueryText: String = ""
}
