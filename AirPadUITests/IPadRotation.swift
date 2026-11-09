import XCTest
import UIKit

/// C7 (2026-11-08) — the iPad app turns with the device. Rotates the Simulator through all four orientations WHILE
/// typing in Quick Capture's note (the real editor) and checks every word survives, the keyboard focus is kept, and
/// the interface really turned (the window's width/height swap). Each step prints one `[IPadRotation]` line.
/// iPad only (the iPhone app stays portrait); skipped on iPhone.
final class IPadRotation: XCTestCase {

    override func setUp() { continueAfterFailure = true }

    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testTypedTextSurvivesRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only (the iPhone app is portrait-only)") }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-StubAuthorModel", "-EmbedCPUOnly", "-UITestLibrary", "-UITestLibraryFresh", "-EntryQuikCapture"]
        app.launch()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20), "Quick Capture should open")
        editor.tap()

        let steps: [(UIDeviceOrientation, String, Bool)] = [   // orientation · word typed after it · landscape?
            (.portrait, "Rotation check alpha", false),
            (.landscapeLeft, " beta", true),
            (.portraitUpsideDown, " gamma", false),
            (.landscapeRight, " delta", true),
            (.portrait, " omega", false),
        ]
        var expected = ""
        for (o, word, landscape) in steps {
            XCUIDevice.shared.orientation = o
            Thread.sleep(forTimeInterval: 2)
            let frame = app.windows.firstMatch.frame
            let turned = landscape ? frame.width > frame.height : frame.height > frame.width
            XCTAssertTrue(turned, "\(o.rawValue): interface did not turn (window \(frame.size))")
            editor.typeText(word)
            expected += word
            let value = editor.value as? String ?? ""
            print("[IPadRotation] orientation=\(o.rawValue) window=\(Int(frame.width))x\(Int(frame.height)) turned=\(turned) textOK=\(value.contains(expected))")
            XCTAssertTrue(value.contains(expected), "after \(o.rawValue): the note reads \"\(value)\", expected \"\(expected)\"")
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "rotation-\(o.rawValue)"; shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertEqual(app.state, .runningForeground)
    }
}
