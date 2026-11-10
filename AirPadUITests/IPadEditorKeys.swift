import XCTest
import UIKit

/// Mac batch C3 — the note editor on an iPad with a hardware keyboard: the formatting bar shows INLINE (not on the
/// keyboard), and the Format key commands, pressed for real (`typeKey`), change the paragraph / selection (read from
/// the DEBUG `-RouterProbe`: editor, bold, heading, bullet, checklist). iPad only.
final class IPadEditorKeys: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    func testEditorKeys() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        let app = XCUIApplication()
        var args = ["-UITestLibrary", "-UITestLibraryFresh", "-UITestSampleLibrary", "-EmbedCPUOnly", "-RouterProbe", "-OpenListView"]
        for k in ["view.buttons", "map.intro", "librarian.intro", "librarian.sample", "librarian.mode", "librarian.model",
                  "entry.intro", "capture.title"] { args += ["-com.airpad.callouts.\(k)", "YES"] }
        app.launchArguments = args
        app.launch()
        let probeEl = app.descendants(matching: .any)["routerProbe"]
        XCTAssertTrue(probeEl.waitForExistence(timeout: 30))
        func probe() -> String { probeEl.value as? String ?? "" }
        Thread.sleep(forTimeInterval: 6)
        // A new entry (⌘N), its note tapped: plain body text to work on.
        app.typeKey("n", modifierFlags: .command)
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "the new entry's note")
        editor.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let bar = app.descendants(matching: .any)["inlineFormatBar"]
        let inline = bar.waitForExistence(timeout: 5)
        print("[IPadEditorKeys] \(inline ? "PASS" : "FAIL") the inline bar shows while editing — \(probe())")
        XCTAssertTrue(inline, "inline bar")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "ipad-inline-bar"; shot.lifetime = .keepAlways; add(shot)

        @discardableResult
        func press(_ key: String, _ mods: XCUIElement.KeyModifierFlags, _ name: String, expect: [String]) -> Bool {
            app.typeKey(key, modifierFlags: mods)
            let deadline = Date().addingTimeInterval(4)
            var p = probe()
            while Date() < deadline, !expect.allSatisfy({ p.contains($0) }) { Thread.sleep(forTimeInterval: 0.25); p = probe() }
            let ok = expect.allSatisfy { p.contains($0) }
            print("[IPadEditorKeys] \(ok ? "PASS" : "FAIL") \(name) — \(p.components(separatedBy: " editor=").last ?? p)")
            XCTAssertTrue(ok, "\(name): \(expect) in \(p)")
            return ok
        }
        app.typeText("Keys\nKey test line")   // line 2: line 1 is styled as the title
        press(XCUIKeyboardKey.leftArrow.rawValue, [.shift, .command], "select the line", expect: ["editor=1"])
        let wasBold = probe().contains("bold=1")
        press("b", .command, "⌘B toggles bold", expect: [wasBold ? "bold=0" : "bold=1"])
        press("b", .command, "⌘B toggles it back", expect: [wasBold ? "bold=1" : "bold=0"])
        press("2", [.command, .option], "⌥⌘2 heading", expect: ["heading=2"])
        press("0", [.command, .option], "⌥⌘0 body", expect: ["heading=0"])
        press("8", [.command, .shift], "⇧⌘8 bulleted list", expect: ["bullet=1"])
        press("8", [.command, .shift], "⇧⌘8 off", expect: ["bullet=0"])
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])   // a caret, not a selection
        press("l", [.command, .shift], "⇧⌘L checklist", expect: ["checklist=1"])
        press("l", [.command, .shift], "⇧⌘L off", expect: ["checklist=0"])
        // ⌘↩ ticks the checkbox (the line is a checklist item again), Tab indents it.
        press("l", [.command, .shift], "⇧⌘L checklist again", expect: ["checklist=1"])
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)
        let ticked = (editor.value as? String ?? "")
        print("[IPadEditorKeys] note after ⌘↩: \(ticked.debugDescription)")
    }
}
