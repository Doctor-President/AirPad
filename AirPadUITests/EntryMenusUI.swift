import XCTest
import UIKit

/// Mac batch C5 — the entry menu on a List row: on iPad a long-press (the secondary click's touch twin) offers Open,
/// Export…, Delete…, and Open opens it; on iPhone nothing new appears (unchanged). Reads `-RouterProbe` for depth.
final class EntryMenusUI: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    func testListRowMenu() throws {
        let app = XCUIApplication()
        var args = ["-UITestLibrary", "-UITestSampleLibrary", "-EmbedCPUOnly", "-RouterProbe", "-OpenListView"]
        for k in ["view.buttons", "map.intro", "librarian.intro", "librarian.sample", "librarian.mode", "librarian.model",
                  "entry.intro", "capture.title"] { args += ["-com.airpad.callouts.\(k)", "YES"] }
        app.launchArguments = args
        app.launch()
        let probe = app.descendants(matching: .any)["routerProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30))
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'listRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "a List row")
        row.press(forDuration: 1.2)
        let open = app.buttons["Open"], export = app.buttons["Export…"], delete = app.buttons["Delete…"]
        let shown = open.waitForExistence(timeout: 3)
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = pad ? "ipad-entry-menu" : "iphone-longpress"
        shot.lifetime = .keepAlways; add(shot)
        if pad {
            print("[EntryMenusUI] \(shown && export.exists && delete.exists ? "PASS" : "FAIL") iPad long-press → Open / Export… / Delete…")
            XCTAssertTrue(shown && export.exists && delete.exists)
            open.tap()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline, !((probe.value as? String ?? "").contains("depth=1")) { Thread.sleep(forTimeInterval: 0.3) }
            let opened = (probe.value as? String ?? "").contains("depth=1")
            print("[EntryMenusUI] \(opened ? "PASS" : "FAIL") Open opens the entry")
            XCTAssertTrue(opened)
        } else {
            print("[EntryMenusUI] \(!export.exists ? "PASS" : "FAIL") iPhone long-press → no new menu (unchanged)")
            XCTAssertFalse(export.exists)
        }
    }
}
