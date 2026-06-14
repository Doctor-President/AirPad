import SwiftUI
import UIKit

/// Unified-media-viewer commit 1 — pinch/double-tap zoomable image page.
/// Graduated from `briefs/spike-zoom-paging.md`, which validated the
/// `UIScrollView`-inside-SwiftUI-paging-ScrollView handoff on device.
///
/// ## Mechanism
///
/// Standard Photos-style recipe: a `UIScrollView` whose single zoomable
/// subview is a `UIImageView`. `viewForZooming(in:)` returns that image
/// view; UIScrollView handles the pinch and the post-pinch drag-to-pan
/// natively. We layer on:
///   - aspect-fit sizing so the image at zoomScale = 1 fills the
///     scroll view's bounds along its dominant axis (matches the prior
///     `Image.scaledToFit()` framing the gallery viewer used);
///   - re-centering via `contentInset` so the image stays centered
///     while it's smaller than the bounds along either axis (e.g.,
///     while scaling back toward 1×, or for portrait images on a
///     landscape page);
///   - a double-tap toggle between 1× and ~2.5× zoom centered on the
///     tap point;
///   - a live `isZoomed` binding back to SwiftUI so the parent pager
///     can `.scrollDisabled` itself whenever the current page is
///     zoomed past 1× — that's the gesture-arbitration rule the spike
///     validated (paging only at zoom == 1, horizontal drag pans
///     instead of paging when zoomed in).
///
/// ## Why not a SwiftUI-native magnification gesture
///
/// SwiftUI's `MagnificationGesture` + `.scaleEffect` can do the pinch
/// but doesn't get UIScrollView's centered pan-while-zoomed behavior
/// for free, doesn't bounce-back at the zoom edges, and fights the
/// outer paging gesture without explicit arbitration. The
/// UIScrollView recipe is the well-trodden Photos path and the spike
/// confirmed it feels native inside the SwiftUI paging ScrollView.
struct ZoomableImageView: UIViewRepresentable {

    let image: UIImage
    @Binding var isZoomed: Bool
    /// Fired on a single-tap that wasn't part of a double-tap-to-zoom.
    /// The viewer wires this to its `chromeVisible` toggle (Photos-style
    /// tap-to-hide chrome). Disambiguation lives in `makeUIView` via
    /// `singleTap.require(toFail: doubleTap)` — without that, every
    /// zoom double-tap would also flicker the chrome.
    var onSingleTap: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(isZoomed: $isZoomed) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = FitZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast

        // `.scaleToFill` (not `.scaleAspectFit`) so pinch-zoom enlarges
        // the actual image pixels rather than zooming into a letterboxed
        // container. The aspect-fit math lives in `applyFitLayout` and
        // sets the imageView's frame to the rect the image occupies at
        // zoomScale = 1; UIScrollView then scales that frame as the
        // user pinches.
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scroll

        // Drive the first fit from the scroll view's own layout pass.
        // `updateUIView` and `scrollViewDidZoom` both miss the moment
        // the scroll view first gets non-zero bounds, so without this
        // the imageView paints at native pixel size for one frame
        // (looks fully zoomed-in) and only fits on a later pass —
        // which is what produced the open-zoomed + flash-on-swipe bug.
        let coordinator = context.coordinator
        scroll.onLayout = { [weak coordinator] size in
            coordinator?.applyFitLayout(in: size)
        }

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        // Single-tap toggles the viewer's chrome (Photos pattern).
        // `require(toFail: doubleTap)` is the load-bearing line: without
        // it, every double-tap-to-zoom would fire singleTap first and
        // toggle chrome on the way to the zoom, producing a chrome flicker.
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        return scroll
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Refresh closure capture so the coordinator always calls the
        // current view's onSingleTap (SwiftUI re-creates the View on each
        // update; the Coordinator persists).
        context.coordinator.onSingleTap = onSingleTap
        // Image identity change → swap image, reset zoom, and force a
        // re-fit. Cheap pointer equality is enough here: the image is
        // produced once per page by the parent's decode pipeline and
        // doesn't churn.
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scrollView.setZoomScale(1, animated: false)
            context.coordinator.lastFitBounds = .zero
        }
        context.coordinator.applyFitLayout(in: scrollView.bounds.size)
    }

    /// Forwards `layoutSubviews` up so the coordinator can run the
    /// aspect-fit pass against the scroll view's current (real) bounds.
    /// Without this hook, the initial fit only runs when SwiftUI calls
    /// `updateUIView` — which happens before the scroll view has its
    /// real bounds — and the page paints zoomed-in until something
    /// else (a zoom callback, a swipe) re-fires the fit.
    private final class FitZoomScrollView: UIScrollView {
        var onLayout: ((CGSize) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(bounds.size)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var isZoomed: Binding<Bool>
        var onSingleTap: (() -> Void)?
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        /// Last bounds we ran `applyFitLayout` against. The guard against
        /// re-fitting on every `scrollViewDidZoom` callback is what
        /// keeps a zoom-in-progress from stomping the scaled frame back
        /// to 1×; bounds only actually change on rotation / size class.
        var lastFitBounds: CGSize = .zero

        init(isZoomed: Binding<Bool>) {
            self.isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            applyFitLayout(in: scrollView.bounds.size)
            let zoomed = scrollView.zoomScale > 1.01
            guard isZoomed.wrappedValue != zoomed else { return }
            // Defer the SwiftUI state write out of the active layout
            // pass — delegate callbacks are on main, but writing into
            // a `@State` mid-zoom can prompt re-entrant layout work.
            DispatchQueue.main.async { [weak self] in
                self?.isZoomed.wrappedValue = zoomed
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onSingleTap?()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let target: CGFloat = 2.5
                let point = gesture.location(in: imageView)
                let size = scrollView.bounds.size
                let w = size.width / target
                let h = size.height / target
                let rect = CGRect(
                    x: point.x - w / 2,
                    y: point.y - h / 2,
                    width: w,
                    height: h
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }

        /// On bounds change, computes the aspect-fit rect for the image
        /// inside the scroll view and pins the imageView's frame +
        /// `scroll.contentSize` to it at zoomScale = 1. Bounds-stable
        /// calls skip the frame reset (so a zoom-in-progress isn't
        /// disturbed) and only re-center.
        ///
        /// Re-centering runs on every call, including during zoom —
        /// that's what keeps the image visually centered as it shrinks
        /// back below the bounds (e.g., after a pinch-out past 1×).
        func applyFitLayout(in boundsSize: CGSize) {
            guard let scrollView, let imageView, let img = imageView.image,
                  boundsSize.width > 0, boundsSize.height > 0 else { return }
            if boundsSize != lastFitBounds {
                lastFitBounds = boundsSize
                let imageAspect = img.size.width / max(img.size.height, 0.01)
                let boundsAspect = boundsSize.width / boundsSize.height
                let fitSize: CGSize
                if imageAspect > boundsAspect {
                    fitSize = CGSize(width: boundsSize.width,
                                     height: boundsSize.width / imageAspect)
                } else {
                    fitSize = CGSize(width: boundsSize.height * imageAspect,
                                     height: boundsSize.height)
                }
                imageView.frame = CGRect(origin: .zero, size: fitSize)
                scrollView.contentSize = fitSize
                scrollView.setZoomScale(1, animated: false)
            }
            let scaled = imageView.frame.size
            let horizontalInset = max(0, (boundsSize.width - scaled.width) / 2)
            let verticalInset = max(0, (boundsSize.height - scaled.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: verticalInset,
                left: horizontalInset,
                bottom: verticalInset,
                right: horizontalInset
            )
        }
    }
}
