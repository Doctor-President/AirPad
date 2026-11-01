import XCTest

/// 1.1 close-out A — raw stills (and the beats the preview clips record) for the App Store, driven on the real screens
/// over the Sample scratch library (`-UITestLibrary`, plus the synthetic entries `build/store/seed_entry.py` adds). Meant
/// for the bench build (Release + `-D PANBENCH`: the shipping UI, no DEBUG chrome), so it reaches every screen by taps,
/// not by DEBUG shortcuts. Full-screen grabs (`XCUIScreen.main`), status bar overridden by the caller.
/// `TEST_RUNNER_STORE_MARK=<dir>` — a test touches `<dir>/<name>` when the caller should act (the Face ID match) and
/// waits for `<dir>/<name>.done`.
final class StoreShots: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    static let callouts = ["view.buttons", "map.intro", "librarian.intro", "librarian.sample", "librarian.mode",
                           "librarian.model", "entry.intro", "capture.title"].flatMap { ["-com.airpad.callouts.\($0)", "YES"] }
    static let base = ["-UITestLibrary", "-UITestSampleLibrary", "-EmbedCPUOnly", "-NoMapDebugHUD", "-ProUnlocked", "YES"] + callouts
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    /// Seconds to hold before a grab (the clips use it for handles).
    private var hold: UInt32 { UInt32(env["STORE_HOLD"] ?? "0") ?? 0 }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = Self.base + extra
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let s = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }

    /// Ask the caller to do something (touch a file), wait until it says done.
    private func signal(_ name: String, timeout: TimeInterval = 30) {
        guard let dir = env["STORE_MARK"] else { return }
        FileManager.default.createFile(atPath: dir + "/" + name, contents: Data())
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !FileManager.default.fileExists(atPath: dir + "/" + name + ".done") { Thread.sleep(forTimeInterval: 0.25) }
    }

    /// The view switcher (the chrome's "View: …" button) → Card / List / Map.
    private func switchTo(_ app: XCUIApplication, _ label: String) {
        let view = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View:'")).firstMatch
        XCTAssertTrue(view.waitForExistence(timeout: 30), "the view switcher")
        view.tap()
        let item = app.buttons[label].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(label) item")
        item.tap()
    }

    /// The List view → the entry's row (scrolling until it's on screen) → its detail.
    private func openFromList(_ app: XCUIApplication, id: String) {
        switchTo(app, "List")
        sleep(3)
        let row = app.descendants(matching: .any).matching(identifier: "listRow-\(id)").firstMatch
        for _ in 0..<12 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow); sleep(1) }
        XCTAssertTrue(row.exists, "list row \(id)")
        row.tap()
    }

    /// The search pill → swipe up → the Librarian's Ask field.
    private func openLibrarian(_ app: XCUIApplication) -> XCUIElement {
        let pill = app.textFields["Search"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "search pill")
        pill.swipeUp(velocity: .slow)
        sleep(2)
        let pred = NSPredicate(format: "placeholderValue == 'Ask' OR label == 'Ask'")
        let tf = app.textFields.matching(pred).firstMatch
        if tf.waitForExistence(timeout: 8) { return tf }
        return app.textViews.matching(pred).firstMatch
    }

    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat, duration: TimeInterval = 0.4) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.3)
        _ = duration
    }

    // MARK: 1 / 5 — the Map, zoomed out to several territories (`STORE_ARGS`: the look / background launch arguments)

    func testMapZoomed() {
        let extra = (env["STORE_ARGS"] ?? "").split(separator: " ").map(String.init)
        let name = env["STORE_NAME"] ?? "map"
        let app = launch(["-OpenMap"] + extra)
        sleep(14)
        shot("\(name)-start")
        app.pinch(withScale: CGFloat(Double(env["STORE_PINCH"] ?? "0.55") ?? 0.55), velocity: -0.6)
        sleep(6)
        shot("\(name)-zoomed")
    }

    // MARK: 4 — an entry with text, a table and an image

    func testEntry() {
        let app = launch(["-OpenMap"])
        sleep(8)
        openFromList(app, id: "store-pourover")
        sleep(5 + hold)
        shot("04-entry-top")
        drag(app, from: 0.78, to: 0.36)
        sleep(2 + hold)
        shot("04-entry-table")
        drag(app, from: 0.70, to: 0.55)
        sleep(2)
        shot("04-entry-table-b")
    }

    // MARK: 2 — the Librarian answering, mid-stream and finished, with citation chips

    func testLibrarian() {
        let q = env["STORE_QUESTION"] ?? "What would it actually take to shoot on the Bolex?"
        let app = launch(["-OpenMap"])
        sleep(8)
        let field = openLibrarian(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Ask field")
        sleep(1)
        shot("02-librarian-empty")
        field.tap()
        field.typeText(q)
        sleep(1)
        shot("02-librarian-typed")
        app.buttons["Send"].tap()
        // The keyboard's Done bar isn't in the accessibility tree (iOS 27): tap it where it sits, above the suggestions.
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.89, dy: Double(env["STORE_DONE_Y"] ?? "0.593") ?? 0.593)).tap()
        sleep(hold)
        // Mid-stream: grab every second; stop once the screen has stopped changing for 5 s.
        var lastPNG = Data(), still = 0
        for i in 0..<70 {
            sleep(1)
            let png = XCUIScreen.main.screenshot().pngRepresentation
            let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png"); a.name = String(format: "02-librarian-t%02d", i)
            a.lifetime = .keepAlways; add(a)
            still = png == lastPNG ? still + 1 : 0
            lastPNG = png
            if still >= 5 { break }
        }
        shot("02-librarian-done")
        let sources = app.buttons.matching(NSPredicate(format: "label CONTAINS 'source'")).firstMatch
        if sources.waitForExistence(timeout: 5) {
            for _ in 0..<4 where !sources.isHittable { drag(app, from: 0.55, to: 0.35); sleep(1) }
            if sources.isHittable { sources.tap(); sleep(2 + hold); shot("02-librarian-done-sources") }
            drag(app, from: 0.60, to: 0.35); sleep(2); shot("02-librarian-done-sources-b")
        }
    }

    // MARK: 3 — AirPad's share sheet over Safari (the caller opens the page in Safari first)

    func testShareFromSafari() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        sleep(4 + hold)
        shot("03-safari-page")
        var share = safari.buttons["Share"].firstMatch
        if !share.waitForExistence(timeout: 3) {
            let more = safari.buttons.matching(NSPredicate(format: "label == 'More' OR label == 'Page Menu' OR identifier == 'PageFormatMenuButton'")).firstMatch
            if more.waitForExistence(timeout: 3) { more.tap(); sleep(1) }
            share = safari.buttons["Share"].firstMatch
        }
        XCTAssertTrue(share.waitForExistence(timeout: 5), "Safari's Share")
        share.tap()
        let airpad = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'AirPad'"))
        if !airpad.firstMatch.waitForExistence(timeout: 8) {
            let more = safari.cells.matching(NSPredicate(format: "label == 'More'")).firstMatch
            if more.waitForExistence(timeout: 3) { more.tap(); sleep(1) }
        }
        sleep(1 + hold)
        shot("03-system-share-sheet")
        XCTAssertTrue(airpad.firstMatch.waitForExistence(timeout: 8), "AirPad in the share sheet")
        for i in 0..<min(airpad.count, 4) where airpad.element(boundBy: i).isHittable {
            airpad.element(boundBy: i).tap(); break
        }
        let title = safari.descendants(matching: .any)["share.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 12), "AirPad's share sheet")
        sleep(2 + hold)
        shot("03-airpad-share-sheet")
        let dest = safari.segmentedControls["share.destination"].firstMatch
        if dest.exists, dest.buttons["Existing entry"].exists {
            dest.buttons["Existing entry"].tap(); sleep(2); shot("03-airpad-share-existing")
            dest.buttons.element(boundBy: 0).tap(); sleep(1)
        }
        if env["STORE_SHARE_SAVE"] == "1" {
            safari.buttons["share.save"].tap(); sleep(3 + hold); shot("03-after-save")
        } else {
            let cancel = safari.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
        }
    }

    // MARK: 6 — private entries: "Show private" before and after, and the Face ID prompt

    func testPrivate() {
        let app = launch(["-OpenMap"])
        sleep(8)
        switchTo(app, "List")
        sleep(3 + hold)
        shot("06-list-hidden")
        let menu = app.buttons["chrome.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "menu")
        menu.tap()
        let show = app.buttons["menu.showPrivate"]
        XCTAssertTrue(show.waitForExistence(timeout: 5), "Show private")
        sleep(1 + hold)
        shot("06-menu-show-private-before")
        show.tap()
        sleep(2)
        signal("snap-06-faceid-prompt-private")   // the system Face ID panel shows in simctl's grab, not XCUIScreen's
        signal("faceid-match")
        sleep(3)
        shot("06-menu-show-private-after")
        if app.buttons["menu.close"].exists { app.buttons["menu.close"].firstMatch.tap() }
        sleep(2 + hold)
        shot("06-list-shown")
        let row = app.descendants(matching: .any).matching(identifier: "listRow-store-private").firstMatch
        for _ in 0..<12 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow); sleep(1) }
        sleep(1)
        shot("06-list-shown-private-row")
    }

    /// The Face ID lock on open (Settings → Privacy → Require Face ID): the lock and the prompt.
    func testAppLock() {
        let app = launch(["-privacy.requireFaceID", "YES", "-OpenMap"])
        sleep(4)
        signal("snap-06-applock-prompt")
        signal("faceid-match")
        sleep(5 + hold)
        shot("06-applock-unlocked")
        _ = app
    }

    // MARK: 7 — Export: the sheet with "Save to folder…", then the .md + attachments in Files

    func testExport() {
        let app = launch(["-OpenMap"])
        sleep(8)
        openFromList(app, id: "store-pourover")
        sleep(5)
        let m = app.buttons["entryMenu"].firstMatch
        XCTAssertTrue(m.waitForExistence(timeout: 10), "entry menu")
        m.tap()
        XCTAssertTrue(app.buttons["entryMenu.export"].waitForExistence(timeout: 5))
        sleep(1)
        shot("07-entry-menu")
        app.buttons["entryMenu.export"].tap()
        let save = app.buttons["export.saveToFolder"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save to folder…")
        sleep(1 + hold)
        shot("07-export-sheet")
        save.tap()
        // The system folder picker: On My iPhone → the folder the caller made → Open.
        sleep(3)
        shot("07-folder-picker")
        let folder = env["STORE_FOLDER"] ?? "AirPad notes"
        for label in ["Browse", "On My iPhone"] {
            let b = app.buttons[label].firstMatch
            if b.waitForExistence(timeout: 3), b.isHittable { b.tap(); sleep(2) }
            let c = app.cells.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
            if c.exists, c.isHittable { c.tap(); sleep(2) }
        }
        let f = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
        if f.waitForExistence(timeout: 5) { f.tap(); sleep(2) }
        shot("07-folder-picker-in-folder")
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 5) { open.tap() }
        let saved = app.staticTexts["export.saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "saved")
        sleep(1 + hold)
        shot("07-export-saved")

        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.activate()
        sleep(3)
        for label in ["Browse", "On My iPhone", folder] {
            let b = files.buttons[label].firstMatch
            if b.waitForExistence(timeout: 3), b.isHittable { b.tap(); sleep(2); continue }
            let c = files.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            if c.waitForExistence(timeout: 3), c.isHittable { c.tap(); sleep(2) }
        }
        sleep(1 + hold)
        shot("07-files-folder")
        let att = files.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'attachments' OR label CONTAINS[c] 'assets'")).firstMatch
        if att.waitForExistence(timeout: 3), att.isHittable { att.tap(); sleep(2 + hold); shot("07-files-attachments") }
    }

    // MARK: 8 — your own models: Settings → Your own models ("Ollama …"), then the Models list (a fake server)

    func testServer() {
        let url = env["STORE_SERVER"] ?? "http://192.168.1.20:11434"
        let app = launch(["-OpenMap"])
        sleep(8)
        app.buttons["chrome.menu"].firstMatch.tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings")
        settings.tap()
        let modelsRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Models'")).firstMatch
        XCTAssertTrue(modelsRow.waitForExistence(timeout: 5), "Settings → Models")
        sleep(1 + hold)
        shot("08-settings")
        modelsRow.tap()
        sleep(2)
        let own = app.descendants(matching: .any).matching(identifier: "settings.ownModels").firstMatch
        for _ in 0..<8 where !(own.exists && own.isHittable) { app.swipeUp(velocity: .slow); sleep(1) }
        sleep(1 + hold)
        shot("08-settings-models-section")
        own.tap()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'http://192.168'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "endpoint field")
        field.tap()
        field.typeText(url + "\n")   // the caller resets the Simulator's Keychain first, so the field starts empty
        let models = app.buttons["settings.serverModels"]
        // A `.local` name can take longer than the detection's 5 s the first time: re-open the screen (it detects again).
        for _ in 0..<4 where !models.waitForExistence(timeout: 12) {
            let back = app.buttons.matching(NSPredicate(format: "label == 'Back' OR label == 'Models'")).firstMatch
            if back.exists { back.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
            sleep(2)
            own.tap()
            sleep(1)
        }
        XCTAssertTrue(models.exists, "detected")
        sleep(2 + hold)
        shot("08-your-own-models")
        models.tap()
        sleep(3 + hold)
        shot("08-models-list")
        drag(app, from: 0.8, to: 0.35)
        sleep(2)
        shot("08-models-list-b")
    }

    // MARK: Preview clips — one beat per test; the caller records between "rec-start-<name>" and "rec-stop-<name>"
    // (`STORE_HANDLE` seconds of still screen before and after the action).

    private var handle: UInt32 { UInt32(env["STORE_HANDLE"] ?? "3") ?? 3 }
    private func record(_ name: String, _ action: () -> Void) {
        signal("rec-start-\(name)")
        sleep(handle)
        action()
        sleep(handle)
        signal("rec-stop-\(name)")
    }

    /// The Map glide: two long, slow pans (`STORE_VELOCITY` points/s; the default reads as "slow").
    func testClipGlide() {
        let extra = (env["STORE_ARGS"] ?? "").split(separator: " ").map(String.init)
        let app = launch(["-OpenMap"] + extra)
        sleep(14)
        let v = XCUIGestureVelocity(CGFloat(Double(env["STORE_VELOCITY"] ?? "120") ?? 120))
        record(env["STORE_NAME"] ?? "map-glide") {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.62))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.40))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: v, thenHoldForDuration: 0.1)
            sleep(1)
            let c = app.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.70))
            let d = app.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.42))
            c.press(forDuration: 0.05, thenDragTo: d, withVelocity: v, thenHoldForDuration: 0.1)
        }
    }

    /// Map → List → the entry with the photo and the table.
    func testClipOpenEntry() {
        let app = launch(["-OpenMap"])
        sleep(14)
        record("open-entry") {
            switchTo(app, "List")
            sleep(2)
            let row = app.descendants(matching: .any).matching(identifier: "listRow-store-pourover").firstMatch
            for _ in 0..<12 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow); sleep(1) }
            row.tap()
            sleep(3)
            drag(app, from: 0.78, to: 0.40)
        }
    }

    /// Safari → Share → AirPad's sheet → Save.
    func testClipShare() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        sleep(5)
        record("share-from-safari") {
            var share = safari.buttons["Share"].firstMatch
            if !share.waitForExistence(timeout: 2) {
                let more = safari.buttons.matching(NSPredicate(format: "label == 'More' OR label == 'Page Menu'")).firstMatch
                if more.waitForExistence(timeout: 2) { more.tap(); sleep(1) }
                share = safari.buttons["Share"].firstMatch
            }
            share.tap()
            sleep(2)
            let airpad = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'AirPad'"))
            if airpad.firstMatch.waitForExistence(timeout: 8) {
                for i in 0..<min(airpad.count, 4) where airpad.element(boundBy: i).isHittable { airpad.element(boundBy: i).tap(); break }
            }
            _ = safari.descendants(matching: .any)["share.title"].firstMatch.waitForExistence(timeout: 12)
            sleep(3)
            if env["STORE_SHARE_SAVE"] == "1" { safari.buttons["share.save"].tap() } else { safari.buttons["Cancel"].firstMatch.tap() }
            sleep(1)
        }
    }

    /// The Librarian: open, ask, stream to the end.
    func testClipLibrarian() {
        let q = env["STORE_QUESTION"] ?? "What would it actually take to shoot on the Bolex?"
        let app = launch(["-OpenMap"])
        sleep(14)
        record("librarian-stream") {
            let field = openLibrarian(app)
            _ = field.waitForExistence(timeout: 10)
            field.tap()
            field.typeText(q)
            app.buttons["Send"].tap()
            sleep(1)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.89, dy: Double(env["STORE_DONE_Y"] ?? "0.593") ?? 0.593)).tap()
            var last = Data(), still = 0
            for _ in 0..<60 {
                sleep(1)
                let png = XCUIScreen.main.screenshot().pngRepresentation
                still = png == last ? still + 1 : 0; last = png
                if still >= 3 { break }
            }
        }
    }

    /// One look / background: the Map settling, then a gentle drift (`STORE_ARGS`, `STORE_NAME`).
    func testClipLook() {
        let extra = (env["STORE_ARGS"] ?? "").split(separator: " ").map(String.init)
        let app = launch(["-OpenMap"] + extra)
        sleep(14)
        record(env["STORE_NAME"] ?? "look") {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.47))
            a.press(forDuration: 0.05, thenDragTo: b, withVelocity: XCUIGestureVelocity(60), thenHoldForDuration: 0.1)
        }
    }
}
