import XCTest
import UIKit
@testable import AirPad

/// widget fix-up 1 (item 2) — the note's save when AirPad leaves the foreground: when it saves, and that the save
/// lands before the widget's copy is written, inside a background task that is given back exactly once.
/// (The real-event proofs are `TypedTextLeavesForegroundUI`.)
@MainActor
final class NoteLeaveSaveTests: XCTestCase {

    private let display: (String) -> String = { TextEntryBody.trimmingLeadingBlankLines($0) }

    func testSavesOnlyWordsTheUserTyped() {
        // Typed: saves.
        XCTAssertTrue(NoteLeaveSave.needsSave(editing: "Kestrel note", stored: "note", lastSaved: nil, displayed: display))
        XCTAssertTrue(NoteLeaveSave.needsSave(editing: "first words", stored: nil, lastSaved: nil, displayed: display))
        // Nothing typed: no write (the note is only on screen).
        XCTAssertFalse(NoteLeaveSave.needsSave(editing: "note", stored: "note", lastSaved: nil, displayed: display))
        XCTAssertFalse(NoteLeaveSave.needsSave(editing: "", stored: nil, lastSaved: nil, displayed: display))
        // The editor trims leading blank lines for display; that alone is not an edit.
        XCTAssertFalse(NoteLeaveSave.needsSave(editing: "note", stored: "\n  \nnote", lastSaved: nil, displayed: display))
        // `.inactive` then `.background` with the same words: saved once.
        XCTAssertFalse(NoteLeaveSave.needsSave(editing: "Kestrel note", stored: "note", lastSaved: "Kestrel note",
                                               displayed: display))
        // More typed since the last save (back in front, then away again): saves.
        XCTAssertTrue(NoteLeaveSave.needsSave(editing: "Kestrel Owl note", stored: "note", lastSaved: "Kestrel note",
                                              displayed: display))
    }

    func testSaveLandsBeforeTheWidgetCopyAndTimeIsGivenBackOnce() async {
        var events: [String] = []
        let done = expectation(description: "background time given back")
        let time = NoteLeaveSave.BackgroundTime(
            begin: { _ in events.append("begin"); return UIBackgroundTaskIdentifier(rawValue: 7) },
            end: { id in events.append("end \(id.rawValue)"); done.fulfill() })
        NoteLeaveSave.run({
            events.append("save start")
            await Task.yield()                       // the store's save suspends (disk write)
            events.append("save landed")
        }, then: { events.append("widget copy") }, time: time)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(events, ["begin", "save start", "save landed", "widget copy", "end 7"])
    }

    func testExpiryGivesTimeBackOnceAndTheSaveStillFinishes() async {
        var ends = 0
        var expire: (@MainActor () -> Void)?
        let saved = expectation(description: "save ran")
        let time = NoteLeaveSave.BackgroundTime(
            begin: { onExpire in expire = onExpire; return UIBackgroundTaskIdentifier(rawValue: 9) },
            end: { _ in ends += 1 })
        NoteLeaveSave.run({ await Task.yield() }, then: { saved.fulfill() }, time: time)
        expire?()                                    // iOS calls time before the save is done
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(ends, 1, "ended once, by the expiry; the save finishing doesn't end it again")
    }
}
