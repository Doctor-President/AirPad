import SwiftUI
import UIKit

/// Stage 3.1b commit (b) — drives auto-scroll on the entries ScrollView
/// when a lifted reorder card is dragged into the top or bottom edge zone.
///
/// **Why a UIViewRepresentable, not pure SwiftUI:** iOS 17's SwiftUI
/// ScrollView has no public API for per-frame programmatic content-offset
/// mutation. `ScrollViewReader.scrollTo(_:anchor:)` only jumps to known
/// IDs; iOS 18's `ScrollPosition` would work but we target iOS 17. The
/// pragmatic path is to introspect for the enclosing UIScrollView (walk
/// up `superview` from a 1-pt sentinel view embedded in the list content)
/// and drive `contentOffset.y` directly via a `CADisplayLink` while the
/// reorder controller reports a lifted card and a touch in the edge zone.
///
/// **Scroll-delta feedback to the controller:** each tick reports the
/// total offset shift since lift via `onScrollDelta`. The controller adds
/// this to `dragTranslation` for both the lifted card's visual offset and
/// the slot-shift math, so the card advances through slots as the list
/// scrolls past it — exactly equivalent to the user moving the finger.
@available(iOS 17.0, *)
@MainActor
struct AutoScrollDriver: UIViewRepresentable {

    /// Drive only when a card is currently lifted. Engaged-but-not-lifted
    /// shouldn't auto-scroll; the user is still composing the gesture.
    let isActive: Bool
    /// Current finger window-Y. `nil` outside an active drag.
    let touchWindowY: CGFloat?
    /// Distance from the visible-bounds edge that defines the auto-scroll
    /// hot zone. Speed ramps linearly from 0 at the zone boundary to
    /// `maxSpeed` at the screen edge.
    let edgeZone: CGFloat
    /// Called each tick with the total scroll-offset delta since `lift`.
    let onScrollDelta: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = SentinelView()
        v.coordinator = context.coordinator
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            isActive: isActive,
            touchWindowY: touchWindowY,
            edgeZone: edgeZone,
            onScrollDelta: onScrollDelta
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Invisible view planted inside the ScrollView's content so its
    /// `superview` chain reaches the underlying UIScrollView. Walked once
    /// on attach.
    final class SentinelView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var v: UIView? = superview
            while let cur = v {
                if let sv = cur as? UIScrollView {
                    coordinator?.attach(scrollView: sv)
                    return
                }
                v = cur.superview
            }
            coordinator?.attach(scrollView: nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject {

        /// Peak scroll speed at the screen edge, in points per second.
        /// Linear ramp from 0 at the zone boundary; tuned to feel
        /// responsive without overshooting on a long node.
        static let maxSpeed: CGFloat = 800

        weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var isActive = false
        private var touchWindowY: CGFloat?
        private var edgeZone: CGFloat = 80
        private var onScrollDelta: ((CGFloat) -> Void)?
        private var baselineOffsetY: CGFloat = 0
        private var lastReportedDelta: CGFloat = 0

        func attach(scrollView: UIScrollView?) {
            self.scrollView = scrollView
        }

        func update(
            isActive: Bool,
            touchWindowY: CGFloat?,
            edgeZone: CGFloat,
            onScrollDelta: @escaping (CGFloat) -> Void
        ) {
            self.touchWindowY = touchWindowY
            self.edgeZone = edgeZone
            self.onScrollDelta = onScrollDelta

            let wasActive = self.isActive
            self.isActive = isActive

            if isActive && !wasActive {
                baselineOffsetY = scrollView?.contentOffset.y ?? 0
                lastReportedDelta = 0
                startDisplayLink()
            } else if !isActive && wasActive {
                stopDisplayLink()
            }
        }

        private func startDisplayLink() {
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick() {
            guard let scrollView else { return }

            if let touchWindowY {
                // Visible bounds in window coords, then narrow by the
                // adjustedContentInset so the safe-area / nav-bar regions
                // count as "off limits" for auto-scroll triggering.
                let bounds = scrollView.convert(scrollView.bounds, to: nil)
                let topEdge = bounds.minY + scrollView.adjustedContentInset.top
                let bottomEdge = bounds.maxY - scrollView.adjustedContentInset.bottom
                let topZone = topEdge + edgeZone
                let bottomZone = bottomEdge - edgeZone

                var speed: CGFloat = 0
                if touchWindowY < topZone {
                    let depth = min(1.0, max(0.0, (topZone - touchWindowY) / edgeZone))
                    speed = -depth * Self.maxSpeed
                } else if touchWindowY > bottomZone {
                    let depth = min(1.0, max(0.0, (touchWindowY - bottomZone) / edgeZone))
                    speed = depth * Self.maxSpeed
                }

                if speed != 0 {
                    let dt = displayLink?.duration ?? (1.0 / 60.0)
                    let increment = speed * CGFloat(dt)
                    let topLimit = -scrollView.adjustedContentInset.top
                    let bottomLimit = max(
                        topLimit,
                        scrollView.contentSize.height
                            - scrollView.bounds.height
                            + scrollView.adjustedContentInset.bottom
                    )
                    let newOffset = max(
                        topLimit,
                        min(bottomLimit, scrollView.contentOffset.y + increment)
                    )
                    if newOffset != scrollView.contentOffset.y {
                        scrollView.contentOffset.y = newOffset
                    }
                }
            }

            let currentDelta = scrollView.contentOffset.y - baselineOffsetY
            if currentDelta != lastReportedDelta {
                lastReportedDelta = currentDelta
                onScrollDelta?(currentDelta)
            }
        }
    }
}
