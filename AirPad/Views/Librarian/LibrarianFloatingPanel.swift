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
    let initialState: FloatingPanelState = .tip
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
    weak var controller: FloatingPanelController?

    nonisolated func floatingPanelDidChangeState(_ fpc: FloatingPanelController) {
        MainActor.assumeIsolated {
            state = fpc.state
        }
    }

    /// Raise the panel to peek. Routed through `move(to: .tip, ...)` rather
    /// than `controller.show()` so we pin the destination explicitly —
    /// `show()` reads `layout.initialState`, which is fine today but is an
    /// indirection if `initialState` ever changes.
    func raiseToPeek(animated: Bool) {
        controller?.move(to: .tip, animated: animated)
    }

    /// Duck the panel offscreen. Uses the library's `hide(animated:)`
    /// which `move(to: .hidden)`s to the default `hiddenAnchor`. `.hidden`
    /// is not in `LibrarianPanelLayout.anchors` so it isn't a drag target.
    func duck(animated: Bool) {
        controller?.hide(animated: animated)
    }
}

// MARK: - Dummy panel content (Move 1 — placeholder until Move 2 wires LibrarianSurface)

/// Throwaway content for Move 1. Reproduces the spike's `SpikePanelContent`:
/// one persistently-mounted `ScrollView` with `.floatingPanelScrollTracking`;
/// contents swap INSIDE it per detent (whisper at `.tip`; Matches +
/// Transcript sections at `.half`/`.full`). Replaced wholesale by
/// `LibrarianSurface` in Move 2.
struct DummyLibrarianPanelContent: View {

    @ObservedObject var model: LibrarianPanelStateModel
    let proxy: FloatingPanelProxy

    var body: some View {
        VStack(spacing: 0) {
            grabber
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if model.state == .tip {
                        tipContent
                    } else {
                        expandedContent
                    }
                }
            }
            .floatingPanelScrollTracking(proxy: proxy)
        }
        .background(Color(.systemBackground))
    }

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.gray.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.vertical, 8)
    }

    private var tipContent: some View {
        HStack {
            Text("Whisper — a single short line.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var expandedContent: some View {
        Section {
            ForEach(0..<30, id: \.self) { i in
                row(index: i, prefix: "Match")
            }
        } header: {
            sectionHeader("Matches")
        }

        Section {
            ForEach(0..<20, id: \.self) { i in
                row(index: i, prefix: "Transcript")
            }
        } header: {
            sectionHeader("Transcript")
        }
    }

    private func row(index i: Int, prefix: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(.blue).frame(width: 10, height: 10).padding(.top, 6)
                Text("\(prefix) \(i + 1) — sample row to fill out enough content for scrolling.")
                    .font(.system(size: 16))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider().padding(.leading, 42)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
}
