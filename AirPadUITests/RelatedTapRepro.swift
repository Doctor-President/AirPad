import XCTest

/// Dashboard Related-nav regression guard (2026-08-24). Root cause: `DashboardView`
/// bound its NavigationStack to a TYPED `[DashboardRoute]` path, which silently
/// DROPPED a Related link's `NavigationLink(value: NodeDetailRoute)` push (wrong
/// element type) — "tap registers but never navigates," only via the Dashboard.
/// Fix: type-erased `NavigationPath`. This drives the REAL `DashboardView` (started
/// in a node's detail via `-SPINEGATE related` = `DashboardView(initialRoute:
/// .node(src))`), taps a Related link, and observes `store.detailViewDepth` (the
/// `navDepthHUD`): the fix takes it 1 → 2; the bug held it at 1. Observe, don't infer.
final class RelatedTapRepro: XCTestCase {

    func testDashboardRelatedPushNavigates() {
        let app = XCUIApplication()
        app.launchArguments = ["-SPINEGATE", "related"]
        app.launch()
        Thread.sleep(forTimeInterval: 3.0)   // dashboard + pushed detail + store seed settle

        let hud = app.staticTexts["navDepthHUD"]
        XCTAssertTrue(hud.waitForExistence(timeout: 6), "nav depth HUD missing")
        let atDetail = hud.label   // expect depth:1 — started inside the src node's detail

        var link = app.buttons["Confit garlic method"]
        if !link.waitForExistence(timeout: 3) {
            app.swipeUp(); Thread.sleep(forTimeInterval: 0.6)   // reveal Related if low
            link = app.buttons["Confit garlic method"]
        }
        let target = link.exists ? link : app.staticTexts["Confit garlic method"]
        let found = target.waitForExistence(timeout: 3)
        if found { target.tap() }
        Thread.sleep(forTimeInterval: 1.5)
        let afterRelated = hud.label   // fix → depth:2 ; bug → stays depth:1

        let msg = "DASH-NAV — atDetail=[\(atDetail)] relatedFound=\(found) afterRelatedTap=[\(afterRelated)]"
        let a = XCTAttachment(string: msg); a.lifetime = .keepAlways; add(a)
        print("REPRO_DASH \(msg)")

        XCTAssertTrue(atDetail.contains("depth:1"), "did not start in the src node's detail — \(msg)")
        XCTAssertTrue(found, "Related link not present in the pushed NodeDetailView — \(msg)")
        XCTAssertTrue(afterRelated.contains("depth:2"), "Dashboard Related push did NOT navigate (typed-path bug) — \(msg)")
    }
}
