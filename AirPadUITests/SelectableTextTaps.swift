import XCTest

/// live-19 (3b) — iOS 27 gives selectable `Text` the system selection UI, which may add gestures (release notes
/// 79770704). Our answers are selectable (`MarkdownBlock`) AND carry tappable links: the superscript citations
/// (`airpad-citation://n`, resolved in `ChatTranscript`'s `openURL`). On the real chat screen, with the synthetic
/// range-citation turn (`-RangeCitationDemo`): a TAP on a superscript must reach `openURL` (logged `[CitationTap]`), not
/// start a text selection. Synthetic content only; no Host.
final class SelectableTextTaps: XCTestCase {

    private static func appCaches() -> URL? {
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for c in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] {
            let caches = c.appendingPathComponent("Library/Caches")
            if fm.fileExists(atPath: caches.appendingPathComponent("AirPadUITestScratch").path) { return caches }
        }
        return nil
    }
    private static func taps() -> [String] {
        guard let log = appCaches()?.appendingPathComponent("stdout.log"),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { $0.contains("[CitationTap]") }
    }

    func testSuperscriptTapReachesItsCitation() {
        if let log = Self.appCaches()?.appendingPathComponent("stdout.log") { try? Data().write(to: log) }
        let app = XCUIApplication()
        app.launchArguments = ["-OpenMap", "-GauntletUI", "YES", "-RangeCitationDemo", "YES", "-CitationExpand", "YES",
                               "-UITestLibrary", "-EmbedCPUOnly", "-GauntletTapDir", "app-tmp", "-StdoutToFile"]
        app.launch()
        let answer = app.descendants(matching: .any).matching(identifier: "chat.answer").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "the synthetic answer rendered")
        Thread.sleep(forTimeInterval: 1.5)
        let links = app.links.allElementsBoundByIndex.filter { $0.isHittable }
        print("[SelectableTextTaps] links on screen: \(links.count) \(links.prefix(4).map(\.label))")
        XCTAssertGreaterThan(links.count, 0, "the superscripts are links")
        guard let first = links.first else { return }
        first.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = "after superscript tap"; a.lifetime = .keepAlways; add(a)
        let got = Self.taps()
        print("[SelectableTextTaps] taps logged: \(got)")
        XCTAssertTrue(got.contains { $0.contains("airpad-citation://") }, "the tap reached the citation handler (\(got))")
        XCTAssertFalse(app.menuItems["Copy"].exists, "the tap didn't open the text-selection menu instead")
    }
}
