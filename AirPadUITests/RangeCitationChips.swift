import XCTest

/// live-17 (2a) — a Librarian answer that cites by RANGE — "[1–3]" (en dash) or "[1-12]" (hyphen), as models write —
/// rendered the bracket as raw text with no chips. A range must render like "[2, 3, 4]": one superscript and one source
/// chip per entry it covers.
///
/// On the real chat screen: `-RangeCitationDemo YES` streams a synthetic answer character by character through the real
/// answer path (the turn's citation numberer, against a synthetic 12-entry packet) and commits it as a live turn is;
/// `-CitationExpand YES` opens its sources. Asserts the on-screen answer shows no raw range bracket, and the sources list
/// holds the 12 entries the two ranges cover. No Host. Synthetic content only.
final class RangeCitationChips: XCTestCase {

    func testRangeMarkersRenderAsChips() {
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-GauntletUI", "YES", "-RangeCitationDemo", "YES", "-CitationExpand", "YES",
                               "-UITestLibrary", "-EmbedCPUOnly", "-GauntletTapDir", "app-tmp"]
        app.launch()
        let answer = app.descendants(matching: .any).matching(identifier: "chat.answer").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "the synthetic answer rendered")
        Thread.sleep(forTimeInterval: 1)
        let text = answer.label
        let chips = app.descendants(matching: .any).matching(identifier: "chat.source").allElementsBoundByIndex.map(\.label)
        print("[RangeCitationChips] answer=\(text)")
        print("[RangeCitationChips] chips=\(chips.count) \(chips.prefix(3))")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "range-citations"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(text.contains("surveys"), "the answer's prose is on screen (\(text))")
        XCTAssertNil(text.range(of: #"\[\s*\d{1,2}\s*[-‐‑–—−]"#, options: .regularExpression), "no raw range bracket on screen (\(text))")
        XCTAssertFalse(text.contains("["), "no raw bracket at all (\(text))")
        XCTAssertEqual(chips.count, 12, "one source chip per entry the ranges cover (\(chips.count))")
        app.terminate()
    }
}
