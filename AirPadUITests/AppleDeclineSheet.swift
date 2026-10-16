import XCTest

/// live-20 (1) — T's device (TF 202610151405, iOS 27, the on-device model off): an entry with sexual content got no title
/// or summary, and the Proposals sheet said "The model's safety guardrails were triggered." with Retry.
///
/// On the real screens, with Apple Intelligence declining (`-StubAppleDeclines YES` throws the OS's own error — iOS 27's
/// `LanguageModelError` — into the real catch path): a seeded untitled entry → "Ask for a proposal" → Generate.
///   • no on-device model: the plain decline copy and "Open Settings" (which opens Settings at the model), never the
///     framework's words, never Retry;
///   • on-device model installed (`-StubLocalModelReady YES`): it names the entry, and the sheet says so in one line.
/// Synthetic content only; scratch library. Simulator.
final class AppleDeclineSheet: XCTestCase {

    static let base = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSeedDeclineEntry", "-EmbedCPUOnly",
                       "-StubAuthorModel", "-StubAppleDeclines", "YES"]
    static let declineCopy = "Apple Intelligence won't name this entry. Turn on the on-device model in Settings to name sensitive entries."

    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Opens the seeded entry's Proposals sheet and taps Generate on the title row.
    private func generateTitle(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.base + extra
        app.launch()
        let row = app.buttons["entryRow-uitest-decline-entry"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the seeded entry is on Recents")
        row.tap()
        let lever = app.buttons["Ask for a proposal"].firstMatch
        XCTAssertTrue(lever.waitForExistence(timeout: 15), "the entry's proposal button")
        lever.tap()
        let generate = app.buttons["Generate"].firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 15), "the Proposals sheet's Generate (title row)")
        generate.tap()
        return app
    }

    func testDeclineSaysSoAndOffersTheSetting() {
        let app = generateTitle([])
        let banner = app.descendants(matching: .any).matching(identifier: "namingDeclineBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "the decline banner")
        shot(app, "decline-banner")
        XCTAssertTrue(app.staticTexts[Self.declineCopy].exists, "the plain decline copy")
        XCTAssertFalse(app.staticTexts["The model's safety guardrails were triggered."].exists, "never the framework's words")
        XCTAssertFalse(app.buttons["Retry"].exists, "a decline is not an error to retry")
        let open = app.buttons["Open Settings"].firstMatch
        XCTAssertTrue(open.exists, "the settings link")
        open.tap()
        XCTAssertTrue(app.staticTexts["Downloaded model"].waitForExistence(timeout: 10), "Settings opens at the on-device model")
        shot(app, "decline-settings")
    }

    func testOnDeviceModelNamesItAndSaysSo() {
        let app = generateTitle(["-StubLocalModelReady", "YES"])
        let note = app.staticTexts["namedOnDeviceNote"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15), "the one-line on-device note")
        shot(app, "on-device-named")
        XCTAssertEqual(note.label, "Named by the on-device model — Apple Intelligence declined this entry.")
        XCTAssertTrue(app.staticTexts["On-device stub title"].exists, "the on-device model's proposal is shown")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "namingDeclineBanner").firstMatch.exists, "no decline banner")
    }
}
