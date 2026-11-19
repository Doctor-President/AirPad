import XCTest
import Foundation

/// Mac-vs-iPhone perf parity — the iPhone half: ONE scripted "normal use" session with real synthesized touches, on the
/// synthetic perf library (265 entries + 6 heavy + 2 light; never a real library), with the app's built-in recorder on
/// from launch. Run by `scripts/perf/ios_parity.sh` (Release bench build, -D PERFLOG -D PANBENCH), which reads the steps
/// file this test writes and joins it to the recording (`scripts/perf/steps.py`).
///
/// Each step writes `<label>\t<verb>\t<wall ms just before the input>` to $PERF_STEPS once the test has seen the app
/// react (a step whose tap didn't land is written as `MISSED-<label>` and fails the test). Steps labelled `x-…` are the
/// navigation between measured actions (menu opens, keyboard dismissals): recorded so their work doesn't fall into the
/// neighbouring step's window, not part of the parity set. ~1 s of rest after every step.
/// Env (xcodebuild passes TEST_RUNNER_<name>): PERF_STEPS, PERF_ROUNDS (3), PERF_SECONDS (recorder window), PERF_OUT,
/// PERF_APPDATA (the Simulator's Containers/Data/Application, to wait for the saved recording).
final class PerfParity: XCTestCase {
    private var app = XCUIApplication()
    private let env = ProcessInfo.processInfo.environment
    private var stepsHandle: FileHandle?
    private var round = 0
    private var fontNames = ["SF Pro", "Lato"]

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - the session

    func testSession() throws {
        let rounds = Int(env["PERF_ROUNDS"] ?? "") ?? 3
        let seconds = env["PERF_SECONDS"] ?? "1800"
        openSteps()
        let callouts = ["view.buttons", "map.intro", "librarian.intro", "librarian.sample", "librarian.mode",
                        "librarian.model", "entry.intro", "capture.title"].flatMap { ["-com.airpad.callouts.\($0)", "YES"] }
        app.launchArguments = ["-UITestLibrary", "-EmbedCPUOnly", "-ProUnlocked", "YES",
                               "-PerfRecorder", "YES", "-PerfRecorderSeconds", seconds] + callouts
        // Cold launch: the recorder is on from the first line of the app; the script reads processStart → first frame.
        let t0 = now()
        app.launch()
        record("launch", "launch", t0)
        XCTAssertTrue(app.buttons["Back"].firstMatch.waitForExistence(timeout: 60), "the first screen (Recents) never appeared")
        write(line: "launch-ready\tready\t\(Int(now()))", to: "launch.tsv")
        sleep(5)   // the launch's own tail (first layout, store load) before the first step

        setup()
        for r in 0..<rounds {
            round = r
            print("PERFROUND \(r + 1) of \(rounds)")
            // PERF_PHASES (e.g. "map,librarian") runs only those parts: for working on the test, not for numbers.
            let only = Set((env["PERF_PHASES"] ?? "").split(separator: ",").map(String.init))
            func run(_ name: String, _ phase: () -> Void) { if only.isEmpty || only.contains(name) { phase() } }
            run("views", views)
            run("entries", entries)
            run("map", mapActions)
            run("librarian", librarian)
            run("menu", menuActions)
            run("places", places)
            run("appearance", appearance)
        }
        saveRecording()
    }





    // MARK: - setup: Library · Map · Light · Flat · Gravity on · Fluted glass on

    private func setup() {
        tapStep("x-setup", app.buttons["Back"].firstMatch, landed: { self.app.buttons["dashboard.menu"].waitForExistence(timeout: 8) }, "the Dashboard")
        toLibrary("x-setup")
        showView("Map", label: "x-setup")
        librarianToPeek()
        openMenu()
        if !selected(app.buttons["Light"].firstMatch) {
            tapStep("x-setup", app.buttons["Light"].firstMatch, landed: { self.selected(self.app.buttons["Light"].firstMatch) }, "theme Light")
        }
        if !selected(app.buttons["menuLook-flat"]) {
            tapStep("x-setup", app.buttons["menuLook-flat"], landed: { self.selected(self.app.buttons["menuLook-flat"]) }, "look Flat")
        }
        let grav = app.switches["appearance.gravityWells"]
        if val(grav) == "0" {
            tapStep("x-setup", grav.switches.firstMatch, landed: { self.val(grav) == "1" }, "Gravity on")
        }
        closeMenu()
        settingsAppearance { [self] in
            let glass = flutedSwitch()
            if val(glass) == "0" {
                tapStep("x-setup", glass.switches.firstMatch, landed: { self.val(glass) == "1" }, "Fluted glass on")
            }
            // The font alternates every round between the two it isn't now and is.
            fontNames = (fontButton().exists && fontButton().label.contains("SF Pro")) ? ["Lato", "SF Pro"] : ["SF Pro", "Lato"]
        }
    }

    // MARK: - the view switcher, List, Cards

    private func views() {
        showView("List", label: "view-list")
        scrollPair("list-scroll")
        showView("Card", label: "view-cards")
        scrollPair("cards-scroll")
        if let card = onScreen(app.descendants(matching: .other).matching(NSPredicate(format: "identifier BEGINSWITH 'cardTile-'")), "a card in Card View") {
            tapStep("open-card", card, landed: { self.app.textFields["titleField"].waitForExistence(timeout: 8) }, "the entry from a card")
            closeEntry("close-card", landed: { card.waitForExistence(timeout: 8) })
        }
        showView("Map", label: "view-map")
        sleep(1)
    }

    // MARK: - entries (from the List): open/close, typing in a note, scrolling a light and a heavy entry

    private func entries() {
        showView("List", label: "x-view-list")
        if let row = onScreen(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'listRow-'")), "a row in List View") {
            tapStep("open-list", row, landed: { self.app.textFields["titleField"].waitForExistence(timeout: 8) }, "the entry from the List")
            noteType()
            closeEntry("close-list", landed: { row.waitForExistence(timeout: 8) })
        }
        scrollEntry(id: "9E9F1000-0000-4000-8000-000000000007", label: "entry-scroll-light", flicks: 2, maxBatches: 4)
        scrollEntry(id: "9E9F1000-0000-4000-8000-000000000001", label: "entry-scroll-heavy", flicks: 3, maxBatches: 25)
        showView("Map", label: "x-view-map")
    }

    private func noteType() {
        let note = app.textViews.firstMatch
        guard need(note, "the note's text") else { return }
        tapStep("x-note-focus", note.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 120, dy: 10)),
                landed: { self.keyboardUp() }, "the keyboard for the note")
        let text = " a quiet morning at the harbour"   // 31 characters
        let t = now()
        note.typeText(text)
        rest(1.5); let tl = now()
        let ok = waitFor { self.anyValue(containing: "quiet morning at the harbour") }
        record(ok ? "note-type" : "MISSED-note-type", "key", t); record("x-harness", "click", tl)
        if !ok { XCTFail("note-type: the typed text isn't in the note") }
        dismissKeyboard()
    }

    private func scrollEntry(id: String, label: String, flicks: Int, maxBatches: Int) {
        let row = app.buttons["listRow-\(id)"]
        guard seek(row, "the row for \(label)") else { return }
        tapStep("x-open-\(label)", row, settle: 3, landed: { self.app.textFields["titleField"].waitForExistence(timeout: 10) }, "the entry for \(label)")
        sleep(1)
        // Down in batches of `flicks` fast flings until the screen stops changing (the end of the entry; a screenshot
        // compare, which doesn't query the app), then back up the same way to the top.
        func fling(_ up: Bool) {
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.75 : 0.25))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.25 : 0.75))
            a.press(forDuration: 0.02, thenDragTo: b, withVelocity: XCUIGestureVelocity(5000), thenHoldForDuration: 0)
        }
        for up in [true, false] {
            var last = Data()
            for _ in 0..<maxBatches {
                harness()
                let t = now()
                for _ in 0..<flicks { fling(up) }
                record(label, "scroll", t); rest(1.5)
                let png = XCUIScreen.main.screenshot().pngRepresentation
                if png == last { break }
                last = png
            }
            if up, round == 0 { shot("\(label)-bottom") }
        }
        closeEntry("x-close-\(label)", landed: { row.waitForExistence(timeout: 8) })
    }

    // MARK: - the Map: pan, pinch, a preview card

    private func mapActions() {
        guard onMap() else { return }
        cameraReset()
        mapPan("map-pan")
        mapPan("map-pan", reverse: true)
        // Pinch on the window: one pinch in, one out. (XCUITest's pinch on this Map is lopsided: a 1.15 pinch-in zooms
        // in far more than a 0.7 pinch-out zooms out, and a pinch-out below ~0.65 starts its lower finger on the
        // Librarian's pill and drags the panel up instead. So the camera is put back by keyboard after it.)
        if round < 3 { shot("map-round-start") }
        for (scale, velocity) in [(1.15, 0.5), (0.7, -1.0)] {
            harness(); let t = now(); app.pinch(withScale: scale, velocity: velocity); record("map-zoom", "scroll", t); rest(1.5)
            if searchY() < 800 { XCTFail("map-zoom raised the Librarian"); librarianToPeek() }
        }
        cameraReset()
        // A tap on an orb opens its card (the card with an X; the Map's own resting preview of the centre orb has none).
        let close = app.buttons.matching(NSPredicate(format: "identifier == 'mapCard' AND label == 'Close'")).firstMatch
        if let orb = orbNearCentre() {
            tapStep("map-card-open", app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: orb.frame.midX, dy: orb.frame.midY)),
                    landed: { close.waitForExistence(timeout: 3) }, "the orb's card")
        } else { XCTFail("map-card-open: no orb near the middle"); shot("map-card-no-orb"); return }
        guard close.exists else { return }
        tapStep("map-card-close", close, landed: { close.waitForNonExistence(timeout: 5) }, "the card closing")
    }

    // MARK: - the Librarian: open/close, typing in Ask and in Search

    private func librarian() {
        guard onMap() else { return }
        librarianOpen("librarian-open")
        librarianToPeek(label: "librarian-close")
        // Ask
        librarianOpen("x-librarian-open")
        let ask = app.textFields["Ask"].firstMatch
        if need(ask, "the Ask field") {
            tapStep("x-ask-focus", ask.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), landed: { self.keyboardUp() }, "the keyboard for Ask")
            let t = now()
            app.typeText("what did i write about bread")
            rest(1.5); let tl = now()
            let ok = waitFor { self.anyValue(containing: "about bread") }
            record(ok ? "ask-type" : "MISSED-ask-type", "key", t); record("x-harness", "click", tl)
            if !ok { XCTFail("ask-type: the text isn't in the Ask field") }
            let clear = app.buttons["Clear input"].firstMatch
            if clear.exists { tapStep("x-ask-clear", clear, landed: { self.waitFor { !self.anyValue(containing: "about bread") } }, "Ask cleared") }
            dismissKeyboard()
        }
        librarianToPeek(label: "x-librarian-close")
        // Search as you type: a tap raises the panel, a second focuses the field.
        let search = app.textFields["Search"].firstMatch
        if need(search, "the Search pill") {
            tapStep("x-search-open", search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), landed: { self.waitFor { self.searchY() < 800 } }, "the Librarian raised")
            tapStep("x-search-focus", search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), landed: { self.keyboardUp() }, "the keyboard for Search")
            let t = now()
            app.typeText("harbour")
            rest(1.5); let tl = now()
            let ok = waitFor { self.val(search) == "harbour" }
            record(ok ? "search-type" : "MISSED-search-type", "key", t); record("x-harness", "click", tl)
            if !ok { XCTFail("search-type: the text isn't in the Search field") }
            let clear = app.buttons["Clear search"].firstMatch
            if clear.exists { tapStep("x-search-clear", clear, landed: { self.waitFor { self.val(search) != "harbour" } }, "Search cleared") }
            dismissKeyboard()
        }
        librarianToPeek(label: "x-librarian-close")
    }

    // MARK: - the ≡ menu: Analyze, Settings

    private func menuActions() {
        guard onMap() else { return }
        openMenu()
        tapStep("analyze", app.buttons["menu.analyze"], settle: 3, landed: { self.app.buttons["menu.close"].waitForNonExistence(timeout: 5) }, "the menu closing on Analyze")
        sleep(2)
        openMenu()
        tapStep("settings-open", app.buttons["menu.settings"], landed: { self.app.buttons["settingsRow.Appearance"].waitForExistence(timeout: 8) }, "Settings")
        tapStep("settings-close", app.buttons["Done"].firstMatch, landed: { self.app.buttons["settingsRow.Appearance"].waitForNonExistence(timeout: 8) }, "Settings closing")
    }

    // MARK: - places: Today, Recents, a collection, the Library

    private func places() {
        tapStep("place-today", app.buttons["Back"].firstMatch, landed: { self.app.buttons["dashboard.menu"].waitForExistence(timeout: 8) }, "the Dashboard")
        tapStep("place-recents", app.buttons["Recents"].firstMatch, landed: { self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")).firstMatch.waitForExistence(timeout: 8) }, "Recents")
        scrollPair("recents-scroll")
        if let row = onScreen(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entryRow-'")), "a row in Recents") {
            tapStep("open-recent", row, landed: { self.app.textFields["titleField"].waitForExistence(timeout: 8) }, "the entry from Recents")
            closeEntry("close-recent", landed: { row.waitForExistence(timeout: 8) })
        }
        tapStep("x-back-today", app.buttons["Back"].firstMatch, landed: { self.app.buttons["dashboard.menu"].waitForExistence(timeout: 8) }, "the Dashboard")
        let col = app.buttons.matching(NSPredicate(format: "identifier == 'collectionRow-perf-field-notes' AND label BEGINSWITH 'Field Notes'")).firstMatch
        tapStep("place-collection", col, landed: { self.app.buttons["chrome.menu"].waitForExistence(timeout: 8) }, "the collection")
        sleep(1)
        tapStep("place-today", app.buttons["Back"].firstMatch, landed: { self.app.buttons["dashboard.menu"].waitForExistence(timeout: 8) }, "the Dashboard")
        toLibrary("place-library")
        sleep(1)
    }

    // MARK: - appearance changes on the Map, each followed by a pan

    private func appearance() {
        guard onMap() else { return }
        cameraReset()
        menuChange("theme-dark", app.buttons["Dark"].firstMatch, landed: { self.selected(self.app.buttons["Dark"].firstMatch) })
        for look in ["glass", "aura", "riso", "gradient", "outline", "flat"] {
            let b = app.buttons["menuLook-\(look)"]
            menuChange("look-\(look)", b, landed: { self.selected(b) })
        }
        let grav = app.switches["appearance.gravityWells"]
        menuChange("gravity-off", grav.switches.firstMatch, landed: { self.val(grav) == "0" })
        menuChange("gravity-on", grav.switches.firstMatch, landed: { self.val(grav) == "1" })
        for (label, want) in [("fluted-off", "0"), ("fluted-on", "1")] {
            settingsAppearance { [self] in
                let glass = flutedSwitch()
                tapStep(label, glass.switches.firstMatch, landed: { self.val(glass) == want }, label)
            }
            mapPan("map-pan-after-\(label)")
        }
        let font = fontNames[round % 2]
        settingsAppearance { [self] in
            tapStep("x-font-menu", fontButton(), landed: { self.app.buttons[font].firstMatch.waitForExistence(timeout: 5) }, "the Font menu")
            tapStep("font-change", app.buttons[font].firstMatch, settle: 3, landed: { self.waitFor { self.fontButton().exists && self.fontButton().label.contains(font) } }, "font \(font)")
        }
        mapPan("map-pan-after-font-change")
        menuChange("theme-light", app.buttons["Light"].firstMatch, landed: { self.selected(self.app.buttons["Light"].firstMatch) })
    }

    /// ≡ menu → the change → close the menu → pan the Map (`map-pan-after-<label>`).
    private func menuChange(_ label: String, _ control: XCUIElement, landed: @escaping () -> Bool) {
        openMenu()
        tapStep(label, control, settle: 2.5, landed: { self.waitFor(landed) }, label)
        closeMenu()
        mapPan("map-pan-after-\(label)")
    }

    // MARK: - navigation helpers

    private func toLibrary(_ label: String) {
        tapStep(label, app.buttons["collectionRow-_corpus"], landed: { self.app.buttons["chrome.menu"].waitForExistence(timeout: 10) }, "the Library")
    }

    /// The bottom-right view switcher (a menu: Map / List / Card).
    private func showView(_ name: String, label: String) {
        let current = app.staticTexts["\(name) View"]
        if current.exists, label.hasPrefix("x-") { return }
        let switcher = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View:'")).firstMatch
        tapStep("x-view-menu", switcher, landed: { self.app.buttons[name].firstMatch.waitForExistence(timeout: 5) }, "the view menu")
        tapStep(label, app.buttons[name].firstMatch, landed: { current.waitForExistence(timeout: 8) }, "\(name) View")
        if name == "Map" { sleep(1) }
    }

    private func onMap() -> Bool {
        if app.staticTexts["Map View"].exists && app.buttons["chrome.menu"].exists { return true }
        XCTFail("expected the Library's Map (\(app.staticTexts["Map View"].exists ? "menu hidden" : "not on the Map"))")
        shot("not-on-map")
        recover()
        return app.staticTexts["Map View"].exists
    }

    private func closeEntry(_ label: String, landed: @escaping () -> Bool) {
        if app.keyboards.element.exists { dismissKeyboard() }
        tapStep(label, app.buttons["Back"].firstMatch, landed: { self.waitFor { !self.app.textFields["titleField"].exists } && landed() }, "back from the entry")
    }

    private func openMenu() {
        tapStep("x-menu-open", app.buttons["chrome.menu"], landed: { self.app.buttons["menu.close"].waitForExistence(timeout: 5) }, "the ≡ menu")
    }

    private func closeMenu() {
        guard app.buttons["menu.close"].exists else { return }
        tapStep("x-menu-close", app.buttons["menu.close"], landed: { self.app.buttons["menu.close"].waitForNonExistence(timeout: 5) }, "the ≡ menu closing")
    }

    /// ≡ › Settings › Appearance, `body`, then back out to the Map.
    private func settingsAppearance(_ body: () -> Void) {
        openMenu()
        tapStep("x-settings-open", app.buttons["menu.settings"], landed: { self.app.buttons["settingsRow.Appearance"].waitForExistence(timeout: 8) }, "Settings")
        tapStep("x-settings-appearance", app.buttons["settingsRow.Appearance"], landed: { self.fontButton().waitForExistence(timeout: 8) }, "Settings › Appearance")
        for _ in 0..<6 where !(flutedSwitch().exists && flutedSwitch().isHittable && fontButton().isHittable) {
            harness(); let t = now(); app.swipeUp(velocity: .slow); record("x-settings-scroll", "scroll", t); rest(0.8)
        }
        body()
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        tapStep("x-settings-back", back.exists ? back : app.buttons["Settings"].firstMatch,
                landed: { self.app.buttons["settingsRow.Appearance"].waitForExistence(timeout: 8) }, "back to Settings")
        tapStep("x-settings-close", app.buttons["Done"].firstMatch, landed: { self.app.buttons["settingsRow.Appearance"].waitForNonExistence(timeout: 8) }, "Settings closing")
    }

    private func flutedSwitch() -> XCUIElement { app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Fluted glass'")).firstMatch }
    private func fontButton() -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Font, '")).firstMatch }

    /// The Map's orbs are accessibility elements labelled `node:<id>`: one snapshot of the tree, the orb nearest the
    /// middle of the screen (clear of the top chrome, the view buttons and the Librarian's pill).
    private func orbNearCentre() -> (label: String, frame: CGRect)? {
        guard let root = try? app.snapshot() else { return nil }
        var best: (String, CGRect)?; var bestD = CGFloat.greatestFiniteMagnitude
        var orbs: [(String, CGRect)] = [], cards: [CGRect] = []
        var stack: [XCUIElementSnapshot] = [root]
        while let n = stack.popLast() {
            stack.append(contentsOf: n.children)
            if n.identifier == "mapCard" { cards.append(n.frame) }
            if n.label.hasPrefix("node:") { orbs.append((n.label, n.frame)) }
        }
        // Not under the Map's resting preview card (a tap there opens the card's entry).
        for (label, f) in orbs where !cards.contains(where: { $0.insetBy(dx: -10, dy: -10).intersects(f) }) {
            // Its centre in the middle of the screen (it can be large when the Map is zoomed in).
            guard f.width > 20, f.width < 420, f.midY > 220, f.midY < 640, f.midX > 70, f.midX < 370 else { continue }
            let d = hypot(f.midX - 200, f.midY - 430)
            if d < bestD { best = (label, f); bestD = d }
        }
        return best.map { (label: $0.0, frame: $0.1) }
    }



    private func searchY() -> CGFloat { let f = app.textFields["Search"].firstMatch; return f.exists ? f.frame.minY : 9999 }
    /// Reading .value / .label / .isSelected of an element that isn't there stops the test: guard every read.
    private func val(_ e: XCUIElement) -> String { e.exists ? ((e.value as? String) ?? "") : "" }
    private func selected(_ e: XCUIElement) -> Bool { e.exists && e.isSelected }
    private func anyValue(containing s: String) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS %@", s)).firstMatch.exists
    }
    private static let heavy = (1...6).map { String(format: "9E9F1000-0000-4000-8000-%012d", $0) }
    /// The first element of `q` fully on screen (between the top chrome and the Librarian's pill), not a heavy entry.
    private func onScreen(_ q: XCUIElementQuery, _ what: String) -> XCUIElement? {
        for _ in 0..<4 {
            for e in q.allElementsBoundByIndex where e.exists {
                let f = e.frame
                if f.minY > 130, f.maxY < 820, f.width > 0, !Self.heavy.contains(where: { e.identifier.hasSuffix($0) }) { return e }
            }
            harness(); let t = now(); app.swipeUp(velocity: .slow); record("x-seek", "scroll", t); rest(0.8)
        }
        XCTFail("missing on screen: \(what)"); shot("offscreen-\(what)")
        return nil
    }
    /// A specific row: scroll the list until it's on screen (down, then back up).
    private func seek(_ e: XCUIElement, _ what: String) -> Bool {
        for dir in [0, 1] {
            for _ in 0..<5 {
                if e.exists, e.frame.minY > 130, e.frame.maxY < 820 { return true }
                harness(); let t = now(); dir == 0 ? app.swipeUp(velocity: .slow) : app.swipeDown(velocity: .slow); record("x-seek", "scroll", t); rest(0.8)
            }
        }
        XCTFail("missing on screen: \(what)"); shot("offscreen-\(what)")
        return false
    }

    /// Drag the Librarian's peek up to its half detent.
    private func librarianOpen(_ label: String) {
        let pill = app.textFields["Search"].firstMatch
        guard need(pill, "the Librarian's Search pill") else { return }
        let from = pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.2))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        dragStep(label, from, to, velocity: .slow, landed: { self.waitFor { self.searchY() < 800 } }, "the Librarian at half")
    }

    /// Drag the Librarian down from just under its grabber until it sits at peek.
    private func librarianToPeek(label: String = "x-librarian-close") {
        for _ in 0..<3 where searchY() < 800 {
            let y = (searchY() - 50) / app.frame.height
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
            dragStep(label, from, to, velocity: .fast, landed: { self.waitFor { self.searchY() > 800 } }, "the Librarian at peek", failLoudly: false)
        }
        if searchY() < 800 { XCTFail("\(label): the Librarian didn't go back to peek"); shot("librarian-not-peek") }
    }

    /// The same Map camera every time (unmeasured): Zoom to Fit (⌘0), then Zoom In (⌘+) four times, which is about
    /// where the Map opens. Hardware-keyboard commands, as on an iPad or the Mac.
    private func cameraReset() {
        harness()
        var t = now(); app.typeKey("0", modifierFlags: .command); record("x-camera", "key", t); rest(1.5)
        for _ in 0..<4 { harness(); t = now(); app.typeKey("+", modifierFlags: .command); record("x-camera", "key", t); rest(0.8) }
        rest(1)
    }

    private func mapPan(_ label: String, reverse: Bool = false) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: reverse ? 0.3 : 0.7, dy: 0.45))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: reverse ? 0.7 : 0.3, dy: 0.55))
        harness()
        let t = now()
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: 900, thenHoldForDuration: 0)
        record(label, "scroll", t)
        rest(1.5)
    }

    private func scrollPair(_ label: String) {
        harness()
        var t = now()
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        record(label, "scroll", t); rest(1.5)
        harness()
        t = now()
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
        record(label, "scroll", t); rest(1.5)
    }

    private func keyboardUp() -> Bool {
        if app.keyboards.element.waitForExistence(timeout: 4) {
            // The Simulator's one-time "slide to type" tip.
            if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
            return true
        }
        return false
    }

    private func dismissKeyboard() {
        guard app.keyboards.element.exists else { return }
        for b in [app.buttons["Dismiss keyboard"].firstMatch, app.buttons["keyboard.chevron.compact.down"].firstMatch, app.buttons["Done"].firstMatch]
        where b.exists && b.isHittable && app.keyboards.element.exists {
            tapStep("x-keyboard-dismiss", b, landed: { self.app.keyboards.element.waitForNonExistence(timeout: 4) }, "the keyboard going away", failLoudly: false)
        }
    }

    /// Something went wrong: close what's open and go back to the Library's Map.
    private func recover() {
        print("PERFRECOVER")
        if app.keyboards.element.exists { dismissKeyboard() }
        if app.buttons["menu.close"].exists { app.buttons["menu.close"].tap(); sleep(1) }
        if app.buttons["settingsRow.Appearance"].exists, app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap(); sleep(1) }
        if app.textFields["Search"].firstMatch.exists, searchY() < 800 { librarianToPeek() }
        for _ in 0..<4 where !app.buttons["dashboard.menu"].exists && app.buttons["Back"].firstMatch.exists {
            app.buttons["Back"].firstMatch.tap(); sleep(2)
        }
        if app.buttons["collectionRow-_corpus"].exists { app.buttons["collectionRow-_corpus"].tap(); sleep(3) }
        let switcher = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View:'")).firstMatch
        if !app.staticTexts["Map View"].exists, switcher.exists {
            switcher.tap(); sleep(1)
            if app.buttons["Map"].firstMatch.exists { app.buttons["Map"].firstMatch.tap(); sleep(2) }
        }
    }

    // MARK: - steps

    private func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    private func rest(_ s: Double = 1.0) { Thread.sleep(forTimeInterval: s) }
    private func waitFor(_ cond: () -> Bool, timeout: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat { if cond() { return true }; Thread.sleep(forTimeInterval: 0.2) } while Date() < end
        return cond()
    }

    @discardableResult private func need(_ e: XCUIElement, _ what: String) -> Bool {
        if e.waitForExistence(timeout: 10) { return true }
        XCTFail("missing: \(what)")
        shot("missing-\(what)")
        recover()
        return false
    }

    /// Resolve the element first (so the stamp sits just before the input), stamp, tap, then check the app reacted.
    @discardableResult
    private func tapStep(_ label: String, _ e: XCUIElement, settle: Double = 1.5, landed: () -> Bool, _ what: String, failLoudly: Bool = true) -> Bool {
        harness()
        guard need(e, "\(label): \(what)") else { record("MISSED-\(label)", "click", now()); return false }
        let hittable = waitFor({ e.exists && e.isHittable }, timeout: 3)
        let f = e.exists ? e.frame : .zero
        guard hittable || (f.width > 0 && f.minY >= 40 && f.maxY <= app.frame.height - 10 && f.minX >= 0 && f.maxX <= app.frame.width) else {
            return finish(label, "click", now(), settle: 0, landed: { false }, "\(what) — not hittable and not on screen (\(f))", failLoudly)
        }
        let t = now()
        if hittable { e.tap() } else { e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        return finish(label, "click", t, settle: settle, landed: landed, what, failLoudly)
    }

    @discardableResult
    private func tapStep(_ label: String, _ c: XCUICoordinate, settle: Double = 1.5, landed: () -> Bool, _ what: String) -> Bool {
        harness()
        let t = now()
        c.tap()
        return finish(label, "click", t, settle: settle, landed: landed, what, true)
    }

    @discardableResult
    private func dragStep(_ label: String, _ from: XCUICoordinate, _ to: XCUICoordinate, velocity: XCUIGestureVelocity,
                          landed: () -> Bool, _ what: String, failLoudly: Bool = true) -> Bool {
        harness()
        let t = now()
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: velocity, thenHoldForDuration: 0)
        return finish(label, "click", t, settle: 1.5, landed: landed, what, failLoudly)
    }

    /// The app's response gets `settle` seconds with no XCUITest queries (the harness's accessibility snapshots run on
    /// the app's main thread); then `x-harness` marks where the test starts checking that the input landed. The step's
    /// line is written once that check is done (MISSED- if it failed), so the file stays in time order.
    private func finish(_ label: String, _ verb: String, _ t: Double, settle: Double, landed: () -> Bool, _ what: String, _ failLoudly: Bool) -> Bool {
        rest(settle)
        let tl = now()
        let ok = landed()
        record(ok ? label : "MISSED-\(label)", verb, t)
        record("x-harness", "click", tl)
        if !ok {
            print("PERFMISS \(label): \(what)")
            if failLoudly { XCTFail("\(label): the tap didn't land (\(what))"); shot("missed-\(label)") }
        }
        rest(0.3)
        return ok
    }

    private func openSteps() {
        guard let path = env["PERF_STEPS"] else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        stepsHandle = FileHandle(forWritingAtPath: path)
    }

    /// Marks the start of the test's own querying (resolving the next element, checking the last step landed).
    private func harness() { record("x-harness", "click", now()) }

    private func record(_ label: String, _ verb: String, _ wallMs: Double) {
        let line = "\(label)\t\(verb)\t\(Int(wallMs))\n"
        print("PERFSTEP \(line)", terminator: "")
        stepsHandle?.write(line.data(using: .utf8)!)
    }

    private func write(line: String, to name: String) {
        guard let dir = env["PERF_OUT"] else { return }
        try? (line + "\n").write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
    }

    private func shot(_ name: String) {
        let s = app.screenshot()
        let a = XCTAttachment(screenshot: s); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["PERF_OUT"] {
            try? FileManager.default.createDirectory(atPath: dir + "/shots", withIntermediateDirectories: true)
            let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(60))
            try? s.pngRepresentation.write(to: URL(fileURLWithPath: dir + "/shots/r\(round + 1)-\(safe).png"))
        }
    }

    // MARK: - save the recording (the app writes it on the Darwin notification; wait until the file is complete)

    private func saveRecording() {
        let dir = recordingsDir()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: dir ?? "/nonexistent")) ?? [])
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("com.airpad.perf.save" as CFString), nil, nil, true)
        guard let dir else { sleep(30); return }
        var lastSize = -1
        for _ in 0..<120 {
            sleep(1)
            let new = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).subtracting(before).filter { $0.hasSuffix(".json") }
            if let f = new.first {
                let size = ((try? FileManager.default.attributesOfItem(atPath: dir + "/" + f))?[.size] as? Int) ?? 0
                if size > 0 && size == lastSize { print("PERFSAVED \(f) \(size)"); return }
                lastSize = size
            }
        }
        XCTFail("the recorder never wrote its file")
    }

    /// The app's Caches/PerfRecordings in the Simulator (its data container is the one holding the bench scratch).
    private func recordingsDir() -> String? {
        guard let root = env["PERF_APPDATA"], let apps = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for a in apps where FileManager.default.fileExists(atPath: "\(root)/\(a)/Library/Caches/AirPadBenchScratch") {
            let d = "\(root)/\(a)/Library/Caches/PerfRecordings"
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            return d
        }
        return nil
    }
}
