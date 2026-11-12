import XCTest
import UIKit

/// Mac batch C1 — the Mac's menu key commands on an iPad with a hardware keyboard: each combo is pressed for real
/// (`typeKey`) and its effect read from the DEBUG `-RouterProbe` (mode, view, detail depth, Librarian at peek, sheets).
/// iPad only; on iPhone the commands exist too but there's rarely a keyboard, so it is skipped there.
final class IPadKeyCommands: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-UITestLibrary", "-UITestSampleLibrary", "-EmbedCPUOnly", "-RouterProbe", "-OpenMap"]
        for k in ["view.buttons", "map.intro", "librarian.intro", "librarian.sample", "librarian.mode", "librarian.model",
                  "entry.intro", "capture.title"] { args += ["-com.airpad.callouts.\(k)", "YES"] }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    private func probe(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["routerProbe"].value as? String ?? ""
    }

    /// Press a combo, then wait until the probe shows every `expect` token (or time out); prints one line.
    @discardableResult
    private func press(_ app: XCUIApplication, _ key: String, _ mods: XCUIElement.KeyModifierFlags = .command,
                       _ name: String, expect: [String], timeout: TimeInterval = 6) -> Bool {
        app.typeKey(key, modifierFlags: mods)
        let deadline = Date().addingTimeInterval(timeout)
        var p = probe(app)
        while Date() < deadline, !expect.allSatisfy({ p.contains($0) }) { Thread.sleep(forTimeInterval: 0.3); p = probe(app) }
        let ok = expect.allSatisfy { p.contains($0) }
        print("[IPadKeyCommands] \(ok ? "PASS" : "FAIL") \(name) — \(p)")
        XCTAssertTrue(ok, "\(name): expected \(expect) in \(p)")
        return ok
    }

    func testKeyCommands() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["routerProbe"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 6)   // the Sample Library loads
        press(app, "9", .command, "⌘9 Today", expect: ["mode=dashboard"])
        press(app, "2", .command, "⌘2 List", expect: ["mode=canvas", "view=list"])
        press(app, "3", .command, "⌘3 Cards", expect: ["view=grid"])
        press(app, "1", .command, "⌘1 Map", expect: ["view=graph"])
        press(app, "l", .command, "⌘L Librarian up", expect: ["peek=0"])
        press(app, "l", .command, "⌘L Librarian down", expect: ["peek=1"])
        press(app, "f", .command, "⌘F Find", expect: ["peek=0"])
        Thread.sleep(forTimeInterval: 1)
        app.typeText("Kuleshov")   // goes to whatever has focus
        let typed = app.textFields.allElementsBoundByIndex.contains { ($0.value as? String ?? "").contains("Kuleshov") }
        print("[IPadKeyCommands] \(typed ? "PASS" : "FAIL") ⌘F focuses the search field (typing lands in it)")
        XCTAssertTrue(typed, "⌘F: typing should land in the search field")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        press(app, "l", .command, "⌘L after Find", expect: [])
        Thread.sleep(forTimeInterval: 1)
        if probe(app).contains("peek=0") { press(app, "l", .command, "⌘L lower", expect: ["peek=1"]) }
        press(app, "n", .command, "⌘N New Entry", expect: ["capturing=1", "depth=1"])
        press(app, "[", .command, "⌘[ Back out of the empty capture", expect: ["capturing=0", "depth=0"])
        press(app, "n", [.command, .shift], "⇧⌘N New Collection", expect: ["newCollection=1"])
        if app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 3) { app.buttons["Cancel"].firstMatch.tap() }
        press(app, ",", .command, "⌘, Settings", expect: ["settings=1"])
        let settingsUp = app.navigationBars.firstMatch.waitForExistence(timeout: 3)
        print("[IPadKeyCommands] \(settingsUp ? "PASS" : "FAIL") Settings shows")
        // An open entry (a List row, clicked): Export, Back, Forward.
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() } else { app.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.5)
        press(app, "2", .command, "⌘2 List again", expect: ["view=list"])
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'listRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "a List row")
        row.tap()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !probe(app).contains("depth=1") { Thread.sleep(forTimeInterval: 0.5) }
        press(app, "e", [.command, .shift], "⇧⌘E Export Entry", expect: ["depth=1"])
        let export = app.navigationBars["Export"].waitForExistence(timeout: 5)
        print("[IPadKeyCommands] \(export ? "PASS" : "FAIL") Export sheet shows")
        XCTAssertTrue(export, "⇧⌘E should open Export")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].firstMatch.tap() } else if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }
        else { app.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 1.5)
        press(app, "[", .command, "⌘[ Back", expect: ["depth=0", "forward=1"])
        press(app, "]", .command, "⌘] Forward", expect: ["depth=1"])
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "ipad-keycommands"; shot.lifetime = .keepAlways; add(shot)
    }
}
