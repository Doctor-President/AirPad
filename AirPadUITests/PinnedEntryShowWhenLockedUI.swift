import XCTest

/// widget fix-up 2 — the locked widget is a per-widget choice ("Show while AirPad is locked", off by default). Real
/// SpringBoard + app events on an ERASED Simulator, Sample Library only. The Face ID answer is the DEBUG stub
/// authenticator (`-AppLockStubAuth success|fail`, kept across launches so a widget tap's launch uses it too;
/// `-AppLockStubAuthDelay 3` holds the answer so the lock screen is seen up first).
final class PinnedEntryShowWhenLockedUI: XCTestCase {

    static let sidsList = "Sid's list"
    static let sidsListID = "879D7F38-F339-5EE0-91C8-52D11C03653C"
    static let nineShots = "nine shots"

    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    static let shotsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/fixup2/shots", isDirectory: true)

    override func setUp() { continueAfterFailure = true }

    // MARK: - Evidence

    func save(_ name: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: Self.shotsDir, withIntermediateDirectories: true)
        try? data.write(to: Self.shotsDir.appendingPathComponent(name))
    }

    func shot(_ name: String, _ app: XCUIApplication? = nil) {
        let s = (app ?? springboard).screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        save("\(name).png", s.pngRepresentation)
    }

    func dump(_ name: String, _ app: XCUIApplication? = nil) {
        let text = (app ?? springboard).debugDescription
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
        save("\(name).txt", Data(text.utf8))
    }

    func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
        save("\(name).txt", Data(text.utf8))
        print("[fixup2] \(name): \(text)")
    }

    // MARK: - The widget's copy, read from the App Group container (Simulator: the runner can read the host path)

    /// `…/Devices/<udid>/data/Containers/Shared/AppGroup/<uuid>/Widget/pinned-entries.json`, found from the runner's
    /// own home (`…/data/Containers/Data/Application/<uuid>`).
    func copyURL() -> URL? {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        var containers = home
        while containers.lastPathComponent != "Containers", containers.path != "/" { containers.deleteLastPathComponent() }
        let groups = containers.appendingPathComponent("Shared/AppGroup", isDirectory: true)
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let f = dir.appendingPathComponent("Widget/pinned-entries.json")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    struct Copy { var locked: Bool; var ids: [String]; var titles: [String]; var raw: String }

    /// Reads the copy about once a second until `done` holds or `timeout` passes; notes how long it took.
    @discardableResult
    func waitForCopy(_ label: String, timeout: TimeInterval, _ done: (Copy) -> Bool) -> Copy? {
        let start = Date()
        var last: Copy?
        while Date().timeIntervalSince(start) < timeout {
            if let url = copyURL(), let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let entries = obj["entries"] as? [[String: Any]] ?? []
                let c = Copy(locked: obj["locked"] as? Bool ?? false, ids: entries.compactMap { $0["id"] as? String },
                             titles: entries.compactMap { $0["title"] as? String }, raw: String(decoding: data, as: UTF8.self))
                last = c
                if done(c) { break }
            }
            sleep(1)
        }
        note("wait-\(label)", String(format: "%@ after %.0f s", last.map(done) == true ? "reached" : "NOT reached",
                                       Date().timeIntervalSince(start)))
        return readCopy(label)
    }

    func readCopy(_ label: String) -> Copy? {
        guard let url = copyURL(), let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            note("copy-\(label)", "NO COPY FOUND (home \(ProcessInfo.processInfo.environment["HOME"] ?? "?"))")
            return nil
        }
        let entries = obj["entries"] as? [[String: Any]] ?? []
        let c = Copy(locked: obj["locked"] as? Bool ?? false,
                     ids: entries.compactMap { $0["id"] as? String },
                     titles: entries.compactMap { $0["title"] as? String },
                     raw: String(decoding: data, as: UTF8.self))
        note("copy-\(label)", "locked=\(c.locked) entries=\(c.ids.count) titles=\(c.titles) path=\(url.path)")
        save("copy-\(label).json", data)
        return c
    }

    // MARK: - SpringBoard

    func airpadWidgets() -> XCUIElementQuery {
        springboard.icons.matching(NSPredicate(format: "identifier == 'AirPad' AND value == 'Widget'"))
    }

    func addWidget(medium: Bool) {
        let sb = springboard
        var opened = false
        for attempt in 0..<3 where !opened {
            XCUIDevice.shared.press(.home); sleep(2)
            sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).press(forDuration: 1.5); sleep(1)
            if sb.buttons["Edit Home Screen"].exists { sb.buttons["Edit Home Screen"].tap(); sleep(1) }
            if sb.buttons["Edit"].waitForExistence(timeout: 5) { sb.buttons["Edit"].tap() }
            if sb.buttons["Add Widget"].waitForExistence(timeout: 8) { sb.buttons["Add Widget"].tap(); opened = true }
            else { dump("add-widget-missing-\(attempt)"); XCUIDevice.shared.press(.home); sleep(2) }
        }
        XCTAssertTrue(opened, "Edit → Add Widget")
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

    /// The AirPad widget on THIS Home Screen page whose width says small (≈ 170 pt) or medium (≈ 345 pt), read from one
    /// snapshot (element references bound by index go stale when the page changes).
    func widgetOnThisPage(small: Bool) -> XCUIElementSnapshot? {
        guard let root = try? springboard.snapshot() else { return nil }
        let screen = springboard.frame
        func all(_ s: XCUIElementSnapshot) -> [XCUIElementSnapshot] { [s] + s.children.flatMap(all) }
        return all(root).first { e in
            e.elementType == .icon && e.identifier == "AirPad" && (e.value as? String) == "Widget"
                && (e.frame.width < 250) == small && e.frame.width > 50
                && screen.contains(CGPoint(x: e.frame.midX, y: e.frame.midY))
        }
    }

    /// Looks on this page, then the pages beside it.
    func widget(small: Bool) -> XCUIElementSnapshot? {
        if let w = widgetOnThisPage(small: small) { return w }
        for step in 0..<6 {
            if step < 3 { springboard.swipeLeft() } else { springboard.swipeRight() }
            sleep(1)
            if let w = widgetOnThisPage(small: small) { return w }
        }
        dump("widget-not-found-\(small ? "small" : "medium")")
        return nil
    }

    func point(_ f: CGRect) -> XCUICoordinate {
        springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY))
    }

    /// The widget's own text, as VoiceOver reads it.
    func widgetText(small: Bool) -> String {
        guard let w = widget(small: small) else { return "<no widget>" }
        func labels(_ s: XCUIElementSnapshot) -> [String] { [s.label] + s.children.flatMap(labels) }
        return labels(w).filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// A Home Screen shot plus the widget's frame (points), for cropping the still.
    func shotWidget(_ name: String, small: Bool) {
        guard let w = widget(small: small) else { return }
        sleep(1)
        shot(name)
        let f = w.frame
        save("\(name)-frame.txt", Data(String(format: "%.0f %.0f %.0f %.0f", f.minX, f.minY, f.width, f.height).utf8))
    }

    func waitForWidget(small: Bool, containing text: String, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if widgetText(small: small).contains(text) { return true }
            sleep(1)
        }
        return false
    }

    /// Touch and hold → Edit Widget. Leaves the configuration card open.
    func openEditWidget(small: Bool) -> Bool {
        guard let w = widget(small: small) else { return false }
        point(w.frame).press(forDuration: 1.5)
        let edit = springboard.buttons["com.apple.springboardhome.application-shortcut-item.configure-widget"]
        guard edit.waitForExistence(timeout: 5) else { dump("edit-widget-missing"); return false }
        edit.tap(); sleep(2)
        return true
    }

    func closeEditWidget() {
        let card = springboard.otherElements["Pinned Entry, AirPad"]
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap(); sleep(2)
        if card.exists { XCUIDevice.shared.press(.home); sleep(2) }
        XCUIDevice.shared.press(.home); sleep(1)
    }

    /// Edit Widget's "Entry" row: the button on the same line as the "Entry" label (its label is the current value:
    /// "Choose", or the chosen entry's name).
    func entryRow() -> XCUIElement {
        let label = springboard.staticTexts.matching(NSPredicate(format: "label == 'Entry'")).firstMatch
        guard label.waitForExistence(timeout: 30) else { return springboard.buttons["Choose"] }
        let y = label.frame.midY
        let buttons = springboard.buttons.allElementsBoundByIndex
        return buttons.first { abs($0.frame.midY - y) < 12 && $0.frame.minX > label.frame.maxX } ?? springboard.buttons["Choose"]
    }

    /// What Edit Widget's Entry row shows as its value right now.
    func entryRowValue() -> String { entryRow().label }

    func pick(small: Bool, _ title: String) {
        XCTAssertTrue(openEditWidget(small: small))
        let row = entryRow()
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap(); sleep(2)
        let search = springboard.searchFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(title); sleep(2)
        let hit = springboard.cells.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5), "the picker's search finds \(title)"); hit.tap(); sleep(2)
        closeEditWidget()
    }

    // MARK: - App

    func launch(_ app: XCUIApplication, auth: String, delay: Int = 0) {
        app.terminate()
        app.launchArguments = ["-AppLockStubAuth", auth, "-AppLockStubAuthDelay", "\(delay)"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
    }

    /// AirPad's lock screen (its own window): the "AirPad is locked" words or anything carrying its identifiers.
    var lockScreen: (XCUIApplication) -> XCUIElement = {
        $0.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN {'appLock.screen', 'appLock.unlock'} OR label == 'AirPad is locked'")).firstMatch
    }

    /// Dashboard → Menu → Settings → Privacy → Require Face ID (the stub authenticator answers "Face ID").
    func setLock(_ app: XCUIApplication, on: Bool) {
        let back = app.buttons["Back"].firstMatch
        for _ in 0..<3 where !app.buttons["dashboard.menu"].firstMatch.exists && back.exists { back.tap(); sleep(2) }
        let menu = app.buttons["dashboard.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the dashboard's menu"); menu.tap(); sleep(2)
        let settings = app.buttons["menu.settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap(); sleep(2)
        let privacy = app.buttons.matching(NSPredicate(format: "label == 'Privacy'")).firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5)); privacy.tap(); sleep(2)
        let toggle = app.switches["settings.requireFaceID"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let isOn = (toggle.value as? String) == "1"
        if isOn != on {
            // The switch's knob (the row's trailing switch).
            let knob = toggle.switches.firstMatch
            (knob.exists ? knob : toggle).tap()
        }
        sleep(1)
        shot("lock-\(on ? "on" : "off")-settings", app)
        // Close Settings: back to the dashboard.
        if app.buttons["BackButton"].exists { app.buttons["BackButton"].tap(); sleep(1) }
        app.swipeDown(velocity: .fast); sleep(2)
    }

    func editorShowing(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 20) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title))
            .firstMatch.waitForExistence(timeout: timeout)
            && app.textViews["noteEditor"].firstMatch.waitForExistence(timeout: timeout)
    }

    func tapWidget(small: Bool) {
        XCUIDevice.shared.press(.home); sleep(1)
        guard let w = widget(small: small) else { return XCTFail("no widget to tap") }
        point(w.frame).tap()
    }

    func setSwitch(small: Bool, on: Bool, still: String? = nil) {
        XCTAssertTrue(openEditWidget(small: small))
        let sw = springboard.switches["Show while AirPad is locked"]
        XCTAssertTrue(sw.waitForExistence(timeout: 30), "Edit Widget shows the switch")
        for _ in 0..<3 where ((sw.value as? String) == "1") != on {
            // The switch itself sits at the row's trailing end (a tap on the row's middle does nothing).
            sw.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); sleep(2)
        }
        XCTAssertEqual(sw.value as? String, on ? "1" : "0")
        if let still { shot(still) }
        closeEditWidget()
    }

    var look: String {
        (try? String(contentsOf: Self.shotsDir.deletingLastPathComponent().appendingPathComponent("look.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "light"
    }

    /// Simulator only, best effort: XCUIDevice's lock button (a private selector).
    func pressLock() -> Bool {
        let sel = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: sel) else { return false }
        XCUIDevice.shared.perform(sel)
        return true
    }

    // MARK: - The proof

    func testShowWhileLockedFlow() {
        let look = self.look
        let app = XCUIApplication()
        launch(app, auth: "success", delay: 3)
        sleep(20)   // the Sample Library seeds; the copy is written

        // 0 · lock off: two widgets, two entries; the switch is in Edit Widget and does nothing yet.
        addWidget(medium: false)
        addWidget(medium: true)
        pick(small: true, Self.nineShots)
        pick(small: false, Self.sidsList)
        XCTAssertTrue(waitForWidget(small: false, containing: Self.sidsList))
        XCTAssertTrue(waitForWidget(small: true, containing: Self.nineShots))
        let open0 = readCopy("0-lock-off")
        XCTAssertEqual(open0?.locked, false)
        XCTAssertGreaterThan(open0?.ids.count ?? 0, 100)
        XCTAssertTrue(openEditWidget(small: false))
        XCTAssertTrue(springboard.switches["Show while AirPad is locked"].waitForExistence(timeout: 30))
        shot("fixup2-\(look)-edit-widget-switch-off")
        dump("0-edit-widget")
        closeEditWidget()

        // 1 · Require Face ID on, in AirPad: the copy is emptied at once; no widget is set to show, so it stays empty.
        app.activate(); sleep(2)
        setLock(app, on: true)
        let c1 = readCopy("1-lock-on-at-once")
        XCTAssertEqual(c1?.locked, true); XCTAssertEqual(c1?.ids, [])
        sleep(6)
        let c1b = readCopy("1-lock-on-6s")
        XCTAssertEqual(c1b?.locked, true); XCTAssertEqual(c1b?.ids, [], "both widgets hidden: nothing in the copy")
        XCUIDevice.shared.press(.home); sleep(2)
        XCTAssertTrue(waitForWidget(small: false, containing: "AirPad is locked"))
        XCTAssertTrue(waitForWidget(small: true, containing: "AirPad is locked"))
        note("1-medium-label", widgetText(small: false))
        XCTAssertFalse(widgetText(small: false).contains(Self.sidsList), "the hidden tile carries no title")
        shotWidget("fixup2-\(look)-hidden", small: false)

        // 2 · the hidden tile, tapped (cold: AirPad not running) → AirPad's lock screen → "Face ID" → that entry.
        app.terminate(); sleep(2)
        tapWidget(small: false)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let lockUp = lockScreen(app).waitForExistence(timeout: 3)
        note("2-cold-lock-screen-up", "\(lockUp)")
        XCTAssertTrue(lockUp, "the lock screen is up before Face ID passes")
        shot("2-cold-lock-screen", app)
        XCTAssertTrue(editorShowing(app, Self.sidsList, timeout: 25), "cold tap → Face ID → the pinned entry")
        XCTAssertFalse(app.buttons["dashboard.menu"].firstMatch.isHittable, "not the dashboard")
        shot("2-cold-entry", app)

        // 2b · warm: AirPad in the background past its 1-minute lock.
        XCUIDevice.shared.press(.home)
        sleep(65)
        tapWidget(small: false)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let lockUpWarm = lockScreen(app).waitForExistence(timeout: 3)
        note("2b-warm-lock-screen-up", "\(lockUpWarm)")
        XCTAssertTrue(lockUpWarm)
        XCTAssertTrue(editorShowing(app, Self.sidsList, timeout: 25), "warm tap → Face ID → the pinned entry")
        shot("2b-warm-entry", app)

        // 3 · the switch flipped on while AirPad is locked (lock screen up, Face ID never passes): nothing is added.
        launch(app, auth: "fail")
        XCTAssertTrue(lockScreen(app).waitForExistence(timeout: 10), "locked, Face ID failed")
        sleep(5)
        XCUIDevice.shared.press(.home); sleep(1)
        setSwitch(small: false, on: true, still: "fixup2-\(look)-edit-widget-switch-on")
        XCTAssertTrue(waitForWidget(small: false, containing: "Open AirPad to show this entry"))
        note("3-medium-label", widgetText(small: false))
        shotWidget("fixup2-\(look)-not-yet-shown", small: false)
        app.activate()
        XCTAssertTrue(lockScreen(app).waitForExistence(timeout: 10), "still locked")
        sleep(8)   // AirPad re-reads the widgets' choices on becoming active
        let c3 = readCopy("3-flipped-while-locked")
        XCTAssertEqual(c3?.locked, true); XCTAssertEqual(c3?.ids, [], "nothing added without Face ID")
        XCUIDevice.shared.press(.home); sleep(2)
        XCTAssertTrue(waitForWidget(small: false, containing: "Open AirPad to show this entry"))

        // 4 · Face ID passes → the entry is added, and only it.
        launch(app, auth: "success")
        // The system reports a just-flipped switch twice (old + new) for ~30 s; the entry is added once it settles.
        let c4 = waitForCopy("4-shown", timeout: 50) { $0.ids == [Self.sidsListID] }
        XCTAssertEqual(c4?.locked, true)
        XCTAssertEqual(c4?.ids, [Self.sidsListID], "the copy holds only the entry of the widget set to show")
        XCUIDevice.shared.press(.home); sleep(2)
        XCTAssertTrue(waitForWidget(small: false, containing: "Come and See"), "readable at a glance")
        XCTAssertTrue(waitForWidget(small: true, containing: "AirPad is locked"), "the other widget stays hidden")
        note("4-medium-label", widgetText(small: false))
        note("4-small-label", widgetText(small: true))
        shotWidget("fixup2-\(look)-shown-while-locked", small: false)

        // 5 · freshness: an edit in AirPad reaches the shown widget.
        tapWidget(small: false)
        XCTAssertTrue(editorShowing(app, Self.sidsList), "tap on the shown widget opens the entry")
        let ed = app.textViews["noteEditor"].firstMatch
        ed.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.04)).tap()
        if !app.keyboards.element.waitForExistence(timeout: 6) { ed.tap() }
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 6))
        sleep(1)
        ed.typeKey(.upArrow, modifierFlags: .command)
        ed.typeText("Kestrel ")
        sleep(1)
        let left = Date()
        XCUIDevice.shared.press(.home)
        let fresh = waitForWidget(small: false, containing: "Kestrel")
        note("5-freshness", String(format: "%@ after %.1f s (polled ~1 s)", fresh ? "shown" : "NOT shown", Date().timeIntervalSince(left)))
        XCTAssertTrue(fresh, "the edit reaches the widget shown while locked")
        let c5 = readCopy("5-after-edit")
        XCTAssertEqual(c5?.ids, [Self.sidsListID])
        XCTAssertTrue(c5?.raw.contains("Kestrel") ?? false)
        shot("5-widget-after-edit")

        // 6 · the picker while locked lists only entries in the locked copy.
        XCTAssertTrue(openEditWidget(small: true))
        shot("fixup2-\(look)-edit-widget-hidden-entry-card")
        // Finding (recorded, not asserted): the card's Entry row shows the name the system stored when the entry was
        // picked (lock off), whatever the copy holds now.
        note("6-card-entry-value-small", entryRowValue())
        let row = entryRow()
        XCTAssertTrue(row.waitForExistence(timeout: 30)); row.tap(); sleep(3)
        dump("6-picker-locked")
        shot("fixup2-\(look)-picker-locked")
        let cells = springboard.cells
        let offered = (0..<cells.count).map { i -> String in
            let c = cells.element(boundBy: i)
            return ([c.label] + c.staticTexts.allElementsBoundByIndex.map(\.label)).filter { !$0.isEmpty }.joined(separator: " ")
        }.filter { !$0.isEmpty }
        note("6-picker-offered", offered.joined(separator: " | "))
        let notAllowed = Set(open0?.titles ?? []).subtracting([Self.sidsList])
        // Exact names (the Sample Library has entries titled "Sid", a substring of "Sid's list").
        let leaked = offered.filter { notAllowed.contains($0) }
        XCTAssertEqual(leaked, [], "no title that isn't allowed")
        XCTAssertEqual(offered, [Self.sidsList], "only the shown entry is offered")
        closeEditWidget()

        // 7 · the Simulator's own lock, tried once (does privacySensitive redact here?).
        XCUIDevice.shared.press(.home); sleep(1)
        _ = widget(small: false)
        let locked = pressLock()
        note("7-sim-lock-pressed", "\(locked)")
        sleep(3)
        shot("7-sim-locked")
        XCUIDevice.shared.press(.home); sleep(2)    // wake: the Lock Screen
        shot("7-sim-lock-screen")
        dump("7-sim-lock-screen")
        XCUIDevice.shared.press(.home); sleep(1)    // no passcode: Home unlocks
        shot("7-sim-unlocking")
        sleep(2)
        shot("7-sim-unlocked")

        // 8 · the switch back to hidden: the tile hides at once; the copy is emptied.
        setSwitch(small: false, on: false)
        XCTAssertTrue(waitForWidget(small: false, containing: "AirPad is locked"))
        XCTAssertFalse(widgetText(small: false).contains("Come and See"))
        let c8 = waitForCopy("8-hidden-again-before-airpad-runs", timeout: 15) { $0.ids.isEmpty }
        note("8-extension-cut", (c8?.ids ?? ["?"]).isEmpty ? "the widget extension emptied the copy" : "copy still holds \(c8?.ids ?? [])")
        app.activate()
        let c8b = waitForCopy("8-hidden-again-after-airpad-active", timeout: 15) { $0.ids.isEmpty }
        XCTAssertEqual(c8b?.ids, [], "emptied once AirPad is active, at the latest")

        // 9 · lock off: unchanged — every entry in the copy, both widgets show their entries.
        setLock(app, on: false)
        sleep(3)
        let c9 = readCopy("9-lock-off")
        XCTAssertEqual(c9?.locked, false)
        XCTAssertEqual(c9?.ids.count, open0?.ids.count)
        XCUIDevice.shared.press(.home); sleep(2)
        XCTAssertTrue(waitForWidget(small: false, containing: "Kestrel"))
        XCTAssertTrue(waitForWidget(small: true, containing: Self.nineShots))
        shot("9-lock-off-widgets")
    }
}
