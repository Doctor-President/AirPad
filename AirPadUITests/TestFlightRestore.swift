import XCTest

/// After device test runs replace T's TestFlight AirPad with a development build, put the TestFlight build
/// back: open the TestFlight app, open AirPad, tap Install (the latest TF build), wait until it offers Open.
/// Run LAST in a device session. Prints `TFRESTORE …` lines; anything unexpected → T reinstalls by hand.
final class TestFlightRestore: XCTestCase {
    func testReinstallAirPadFromTestFlight() {
        let tf = XCUIApplication(bundleIdentifier: "com.apple.TestFlight")
        tf.launch()
        Thread.sleep(forTimeInterval: 4)
        let row = tf.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'AirPad'")).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            print("TFRESTORE no AirPad row in TestFlight. Hierarchy:\n" + String(tf.debugDescription.prefix(6000)).replacingOccurrences(of: "\n", with: "\nTFRESTORE| "))
            return
        }
        print("TFRESTORE found row: \(row.elementType.rawValue) '\(row.label)'")
        row.tap()
        let installPred = NSPredicate(format: "label ==[c] 'install' OR label ==[c] 'update' OR label ==[c] 'reinstall'")
        let install = tf.buttons.matching(installPred).firstMatch
        guard install.waitForExistence(timeout: 20) else {
            print("TFRESTORE no Install button (buttons: \(tf.buttons.allElementsBoundByIndex.prefix(12).map { $0.label }))")
            return
        }
        print("TFRESTORE tapping \(install.label)")
        install.tap()
        // TestFlight may confirm replacing the existing (development) build.
        let confirm = tf.alerts.buttons.matching(installPred).firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        let open = tf.buttons.matching(NSPredicate(format: "label ==[c] 'open'")).firstMatch
        print(open.waitForExistence(timeout: 600) ? "TFRESTORE installed (Open available)" : "TFRESTORE install did not finish in 10 min")
    }
}
