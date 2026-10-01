import XCTest

/// Brief CD device-bug — the regular "+" capture (NodeDetailView in capture mode) must show a title/
/// summary GHOST while you type, like Quick Capture. This drives the REAL flow (no seeded screen): the
/// real canvas "+" → createCaptureNode → NodeDetailView, then types in the REAL note editor WITHOUT
/// dismissing the keyboard, and asserts the ghost appears. `-StubAuthorModel` stands in for the absent
/// Simulator FM so the real enrichment pipeline (scheduleEnrichment → gate → processNode → proposal)
/// produces a deterministic proposal; everything else is the production path.
final class CDGhostWhileTyping: XCTestCase {

    func testPlusCaptureShowsGhostWhileTyping() {
        let app = XCUIApplication()
        // `-RealCapturePlus` runs the REAL "+" ACTION (createCaptureNode → router handoff → push
        // NodeDetailView in capture mode) — identical to tapping the chrome "+". From there everything
        // is the production path: a REAL note editor, the REAL enrichment pipeline (no seeded proposal).
        app.launchArguments = ["-RealCapturePlus", "-StubAuthorModel", "-StubNonEmptyTitle", "-EmbedCPUOnly"]
        app.launch()

        // The note auto-focuses (probe) so the keyboard is UP; type into the REAL editor and do NOT
        // dismiss. (Tap only as a fallback if the keyboard didn't raise.)
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "the note editor should exist in capture mode")
        if !app.keyboards.element.waitForExistence(timeout: 6) { editor.tap() }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 6), "the note should be focused (keyboard up)")
        editor.typeText("Four of us going as Team Rocket for the office Halloween party.")

        // While the keyboard is still UP: the ~1 s live-commit + ~2 s enrichment + stub should surface a
        // ghost. Its accessibility label is "Suggested: …". If this fails, the fix didn't land.
        let ghost = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Suggested:'")).firstMatch
        XCTAssertTrue(ghost.waitForExistence(timeout: 15),
                      "a title/summary ghost should appear WHILE typing (keyboard up) in the + capture")

        // Record what showed for the artifact.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "plus-capture-ghost-while-typing"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
