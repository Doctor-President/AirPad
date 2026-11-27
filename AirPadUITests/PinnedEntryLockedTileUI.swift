import XCTest

/// widget fix-up 1 (item 1) — with AirPad's Face ID lock on, the Pinned Entry widget says "AirPad is locked" with the
/// glyph for how AirPad unlocks, reads as one VoiceOver sentence, and the picker stays empty. Real SpringBoard events on
/// an ERASED Simulator; the lock is turned on by launch arguments (`-privacy.requireFaceID YES`) with the DEBUG stub
/// authenticator (`-AppLockStubAuth success`: the phone "has Face ID", no real prompt). Also shoots the stills for the
/// four Home Screen looks (Default light / dark, Tinted, Clear) into `build/fixup/shots/` (gitignored).
final class PinnedEntryLockedTileUI: XCTestCase {

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    static let shotsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/fixup/shots", isDirectory: true)

    override func setUp() { continueAfterFailure = false }

    func save(_ name: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: Self.shotsDir, withIntermediateDirectories: true)
        try? data.write(to: Self.shotsDir.appendingPathComponent(name))
    }

    func shot(_ name: String) {
        let s = springboard.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        save("\(name).png", s.pngRepresentation)
    }

    func dump(_ name: String) {
        let text = springboard.debugDescription
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
        save("\(name).txt", Data(text.utf8))
    }

    func airpadWidgets() -> XCUIElementQuery {
        springboard.icons.matching(NSPredicate(format: "identifier == 'AirPad' AND value == 'Widget'"))
    }

    func addWidget(medium: Bool) {
        let sb = springboard
        XCUIDevice.shared.press(.home); sleep(1)
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 1.5); sleep(1)
        XCTAssertTrue(sb.buttons["Edit"].waitForExistence(timeout: 5)); sb.buttons["Edit"].tap()
        XCTAssertTrue(sb.buttons["Add Widget"].waitForExistence(timeout: 5)); sb.buttons["Add Widget"].tap()
        var cell = sb.cells["AirPad"]
        if !cell.waitForExistence(timeout: 8) {
            if sb.buttons["close"].exists { sb.buttons["close"].tap(); sleep(5) }
            if sb.buttons["Edit"].waitForExistence(timeout: 3) { sb.buttons["Edit"].tap() }
            if sb.buttons["Add Widget"].waitForExistence(timeout: 5) { sb.buttons["Add Widget"].tap() }
            let search = sb.searchFields["Search Widgets"]
            if search.waitForExistence(timeout: 5) { search.tap(); search.typeText("AirPad") }
            cell = sb.cells["AirPad"]
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "AirPad in the widget gallery"); cell.tap(); sleep(1)
        if medium {
            let preview = sb.buttons.matching(NSPredicate(format: "label == 'AirPad, Pinned Entry'")).firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            preview.swipeLeft(); sleep(1)
        }
        let add = sb.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap(); sleep(2)
        if sb.buttons["Done"].exists { sb.buttons["Done"].tap(); sleep(1) }
    }

    /// The AirPad widget whose width says small (≈ 170 pt) or medium (≈ 345 pt).
    func widget(small: Bool) -> XCUIElement? {
        let q = airpadWidgets()
        for i in 0..<q.count {
            let e = q.element(boundBy: i)
            if (e.frame.width < 250) == small { return e }
        }
        return nil
    }

    /// Page the Home Screen until this widget is on screen (its content is only in the tree then).
    func bringIntoView(_ w: XCUIElement) {
        let width = springboard.frame.width
        for _ in 0..<4 where !w.isHittable {
            if w.frame.minX >= width { springboard.swipeLeft() } else { springboard.swipeRight() }
            sleep(1)
        }
        sleep(1)
    }

    /// Home Screen → Edit → Customize → a look ("Default", "Dark", "Clear", "Tinted"), then back to the Home Screen.
    func customize(_ look: String) -> Bool {
        let sb = springboard
        XCUIDevice.shared.press(.home); sleep(1)
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 1.5); sleep(1)
        if sb.buttons["Edit Home Screen"].exists { sb.buttons["Edit Home Screen"].tap(); sleep(1) }   // landed on an icon
        guard sb.buttons["Edit"].waitForExistence(timeout: 5) else { dump("edit-missing"); return false }
        sb.buttons["Edit"].tap(); sleep(1)
        let custom = sb.buttons["Customize"]
        guard custom.waitForExistence(timeout: 5) else { dump("customize-missing"); return false }
        custom.tap(); sleep(2)
        dump("customize-\(look)")
        let option = sb.buttons.matching(NSPredicate(format: "label ==[c] %@", look)).firstMatch
        guard option.waitForExistence(timeout: 5) else { return false }
        option.tap(); sleep(2)
        // Close the sheet (tap above it), then leave edit mode.
        sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap(); sleep(1)
        if sb.buttons["Done"].exists { sb.buttons["Done"].tap(); sleep(1) }
        XCUIDevice.shared.press(.home); sleep(2)
        return true
    }

    func testLockedTileShowsHowAirPadUnlocks() {
        continueAfterFailure = true   // a failed check still leaves the stills
        let app = XCUIApplication()
        app.launchArguments = ["-privacy.requireFaceID", "YES", "-AppLockStubAuth", "success"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(15)   // the Sample Library seeds; the copy is written (locked: no entries)

        addWidget(medium: false)
        addWidget(medium: true)
        XCTAssertEqual(airpadWidgets().count, 2)

        // Both sizes say it, as one VoiceOver sentence naming Face ID.
        for small in [true, false] {
            let size = small ? "small" : "medium"
            guard let w = widget(small: small) else { return XCTFail("no \(size) widget") }
            bringIntoView(w)
            dump("locked-tree-\(size)")
            // The widget's content element carries the one sentence (its texts are folded into it).
            let content = w.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH 'AirPad is locked.'")).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 10), "\(size): the locked tile is on screen")
            let label = content.label
            save("locked-label-\(size).txt", Data(label.utf8))
            XCTAssertEqual(label, "AirPad is locked. Open AirPad and unlock it with Face ID to read your entries.",
                           "\(size): one VoiceOver sentence naming Face ID")
        }

        // The picker stays empty while locked.
        guard let medium = widget(small: false) else { return XCTFail("no medium widget") }
        bringIntoView(medium)
        medium.press(forDuration: 1.5)
        let edit = springboard.buttons["com.apple.springboardhome.application-shortcut-item.configure-widget"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap(); sleep(2)
        let row = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Choose' OR label CONTAINS[c] 'Entry'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap(); sleep(2)
        shot("locked-picker")
        dump("locked-picker")
        XCTAssertFalse(springboard.cells.containing(.staticText, identifier: "Sid's list").firstMatch.exists,
                       "no entry offered while locked")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap(); sleep(2)
        XCUIDevice.shared.press(.home); sleep(2)

        // The four looks. (Light / dark is set from outside, `simctl ui appearance`, before this test.)
        for look in ["Default", "Tinted", "Clear"] {
            let ok = customize(look)
            for small in [true, false] {
                guard let w = widget(small: small) else { continue }
                bringIntoView(w)
                sleep(2)
                let name = "locked-\(look.lowercased())-\(small ? "small" : "medium")"
                shot(name)
                let f = w.frame
                save("\(name)-frame.txt", Data(String(format: "%.0f %.0f %.0f %.0f", f.minX, f.minY, f.width, f.height).utf8))
            }
            if !ok { XCTFail("couldn't set the \(look) look") }
        }
        _ = customize("Default")
    }
}
