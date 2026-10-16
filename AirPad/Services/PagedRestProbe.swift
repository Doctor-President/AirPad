import SwiftUI

#if DEBUG
/// live-19 (3d) — `-PagedRestProbe`: at every rest of a horizontally paged surface (the photo viewer's `.paging` pager,
/// a document entry's `.viewAligned` carousel), log where the item nearest the leading edge really sits and the real
/// pitch to its neighbour — the iOS 27 check `CarouselRestGeometry` made for the coverflow (live-18: iOS 27's lazy stack
/// dropped a spacing). Read by `PagedRestGeometry` (stdout file). A plain box: writing it never re-renders.
final class PagedRestProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-PagedRestProbe")
    private var frames: [Int: CGRect] = [:]
    var geometry: ScrollGeometry?

    func record(_ index: Int, _ frame: CGRect) { if Self.enabled { frames[index] = frame } }
    func forget(_ index: Int) { frames[index] = nil }

    /// `leading` = where a resting item's leading edge belongs in the scroll view; `pitch` = the expected item stride
    /// (nil = the item's own width, a full-page pager). `clamped` = the scroll rests at its start or end, where
    /// `.viewAligned` can't put an item at `leading`.
    func logRest(_ surface: String, leading: CGFloat, pitch: CGFloat?, count: Int) {
        guard Self.enabled, let (idx, f) = frames.min(by: { abs($0.value.minX - leading) < abs($1.value.minX - leading) }) else { return }
        let next = frames[idx + 1].map { $0.minX - f.minX } ?? frames[idx - 1].map { f.minX - $0.minX } ?? .nan
        var clamped = false
        if let g = geometry {
            clamped = g.contentOffset.x <= -g.contentInsets.leading + 0.5
                || g.contentOffset.x >= g.contentSize.width + g.contentInsets.trailing - g.containerSize.width - 0.5
        }
        print(String(format: "[PagedRest] %@ rest idx=%d n=%d offsetPt=%.2f pitch=%.2f expectedPitch=%.2f width=%.2f clamped=%d os=%@",
                     surface, idx, count, f.minX - leading, next, pitch ?? f.width, f.width, clamped ? 1 : 0,
                     UIDevice.current.systemVersion))
    }
}

extension View {
    /// DEBUG `-PagedRestProbe`: report this item's frame in its scroll view.
    func pagedRestProbe(_ probe: PagedRestProbe, index: Int) -> some View {
        // (DEBUG only; when the flag is off `record` returns at once.)
        onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { probe.record(index, $0) }
            .onDisappear { probe.forget(index) }
    }
}

extension View {
    /// DEBUG `-PagedRestProbe`: track the scroll view's geometry and log each rest.
    func pagedRestLogger(_ probe: PagedRestProbe, _ surface: String, leading: CGFloat, pitch: CGFloat?, count: Int) -> some View {
        onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in if PagedRestProbe.enabled { probe.geometry = g } }
            .onScrollPhaseChange { _, phase in
                guard PagedRestProbe.enabled, phase == .idle else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    probe.logRest(surface, leading: leading, pitch: pitch, count: count)
                }
            }
    }
}
#endif
