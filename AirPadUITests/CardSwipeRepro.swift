import XCTest

/// Card-surface repro driver. Launches straight into Card View via `-OpenCardView`
/// and performs ordinary horizontal carousel swipes — no detail navigation — so the
/// swipe artifact can be recorded and inspected frame by frame.
final class CardSwipeRepro: XCTestCase {

    func testHorizontalSwipes() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenCardView"]
        app.launch()
        Thread.sleep(forTimeInterval: 22)   // corpus load + carousel settle

        // Three unhurried right-to-left swipes across the deck.
        for _ in 0..<3 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
            let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
            start.press(forDuration: 0.08, thenDragTo: end)
            Thread.sleep(forTimeInterval: 2.0)
        }
        Thread.sleep(forTimeInterval: 2.0)
    }

    /// The CARD-CLIP-ON-RETURN repro (2026-08-10). Opens Card View, taps the
    /// centered card to push NodeDetailView (the `.zoom` transition), then performs
    /// an INTERACTIVE left-edge drag-dismiss — NOT the back button — which is the
    /// only trigger T could reproduce. On return the card body is reported clipped
    /// (bottom ~10% sliced, corners squared) for a frame or two before it resolves.
    ///
    /// Run under `simctl io <udid> recordVideo` on iOS 18.6 and iOS 26 to A/B whether
    /// this is Apple's confirmed zoom regression (absent on 18, present on 26) or ours
    /// (present on both). Slow drag + hold so the interactive return is drawn across
    /// many frames rather than snapping in one.
    func testDragDismissReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenCardView"]
        app.launch()
        Thread.sleep(forTimeInterval: 22)   // corpus load + scroll settle

        // Four tap-in / drag-out cycles so several return events are captured.
        for _ in 0..<4 {
            // Tap the centered card → push detail (zoom transition).
            let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            center.tap()
            Thread.sleep(forTimeInterval: 2.5)   // let detail settle

            // Interactive drag-dismiss: press at the very left edge, drag slowly
            // across to the right, hold at the end, then release → the system runs
            // the interactive zoom pop and settles the source card back in. This is
            // the RELIABLE dismiss (a fast flick's release re-taps the returned card).
            let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.008, dy: 0.5))
            let far  = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
            edge.press(forDuration: 0.15,
                       thenDragTo: far,
                       withVelocity: .slow,
                       thenHoldForDuration: 0.25)
            Thread.sleep(forTimeInterval: 3.0)   // watch the card resolve on return
        }
        Thread.sleep(forTimeInterval: 2.0)
    }

    /// CAROUSEL SHADOW diagnosis — clean, precisely-timed zoom-out returns.
    /// Taps the centered card (zoom-in push), then taps the top-left back chevron
    /// (zoom-out return). The back button gives an un-interactive, cleanly-timed
    /// pop that invokes the SAME `.navigationTransition(.zoom)` and its transition
    /// shadow — so it answers "where does the return shadow come from" without the
    /// drag-dismiss re-tap timing mess. Run on CoverFlow (gridColumnCount == 1).
    func testBackReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenCardView"]
        app.launch()
        Thread.sleep(forTimeInterval: 22)

        for _ in 0..<5 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
            Thread.sleep(forTimeInterval: 2.5)   // detail settles
            // Top-left back chevron.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.065, dy: 0.068)).tap()
            Thread.sleep(forTimeInterval: 2.5)   // watch the zoom-out shadow on return
        }
        Thread.sleep(forTimeInterval: 2.0)
    }

    /// ITEM 2 — vertical-scroll GAP measurement. Opens Card View (needs
    /// gridColumnCount == 4) and performs slow vertical swipes so several cards
    /// travel through the deck. `.viewAligned` snaps to one card at rest, so the
    /// gaps between consecutive cards are only visible mid-motion — recorded for
    /// pixel measurement of the inter-card gaps at varying distances from center.
    func testVerticalScrollGaps() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenCardView"]
        app.launch()
        Thread.sleep(forTimeInterval: 22)   // corpus load + scroll settle

        // Slow upward swipes — small travel each, unhurried, so the recording holds
        // frames where 2–3 cards are simultaneously visible with real gaps between.
        for _ in 0..<6 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.34))
            start.press(forDuration: 0.10, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.0)
            Thread.sleep(forTimeInterval: 2.5)
        }
        Thread.sleep(forTimeInterval: 2.0)
    }
}
