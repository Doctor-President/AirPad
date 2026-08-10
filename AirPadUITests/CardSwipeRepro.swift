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
}
