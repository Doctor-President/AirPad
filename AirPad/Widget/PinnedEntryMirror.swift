import Foundation

// MARK: - ws-1.0-widget — the Pinned Entry widget's saved copy (compiled into the app AND the widget extension)

/// The small, device-local copy of the library that the Home Screen widget reads. The widget never opens the
/// library: the app writes this one file into the App Group container whenever an entry changes
/// (`PinnedEntryMirrorWriter`), and the widget's picker and timeline read it. It is NOT a library file, is not in
/// iCloud Drive and is not synced (format rule 11-15: no field is added to any library file).
///
/// What it holds: for every entry that is not private, its id, a title, when it last changed and its first few lines
/// as plain text (checklist rows keep their ticked state). Private entries are never in it. With the Face ID lock on
/// (`locked`) it holds only the entries of widgets set to "Show while AirPad is locked" (widget fix-up 2), added only
/// after Face ID passed (`allowedIDs`), so nothing else of the library reaches the Home Screen or the widget's picker.
struct PinnedEntryMirror: Codable, Equatable {
    /// Bumped if the shape changes; a widget that reads a different version shows "Open AirPad" until the app
    /// rewrites it.
    static let currentVersion = 1

    var version: Int = PinnedEntryMirror.currentVersion
    /// The Face ID lock is on: `entries` holds only the entries some widget is set to show while locked (often none).
    var locked: Bool = false
    /// The app's chosen content face (`EntryBodyFont.rawValue`), so the widget's type follows Settings → Font.
    var font: String = "lato"
    /// widget fix-up 1 — how this phone unlocks AirPad ("faceID" / "touchID" / "opticID"), written only in the locked
    /// copy so the locked tile can show the system's glyph for it. Nil = not known or passcode only: a plain lock.
    /// Optional, so a copy written before it decodes as nil, and a widget that doesn't know it ignores it.
    var unlock: String? = nil
    /// Newest change first (the picker's suggestions are the head of this list).
    var entries: [Entry] = []

    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var updatedAt: Date
        var lines: [Line]
        /// Rows after `lines` that aren't in the copy (a long list): the widget's "+N more" counts them.
        var more: Int = 0
    }

    struct Line: Codable, Equatable {
        enum Kind: String, Codable { case text, heading, bullet, check }
        var kind: Kind
        var done: Bool = false
        var text: String
    }

    // MARK: Caps (keep the file small; a widget shows at most a handful of rows)
    static let maxLines = 6        // a widget shows at most 5 rows; the rest are counted (`more`)
    static let maxLineLength = 200
    static let maxTitleLength = 80
}

// MARK: - What the widget shows, and the picker (pure; shared so the app's unit tests cover them)

extension PinnedEntryMirror {
    /// What one widget shows for the entry chosen in its configuration.
    enum Display: Equatable {
        case entry(Entry)
        case notSetUp          // no saved copy yet: AirPad hasn't run since the widget arrived
        case locked            // the Face ID lock is on and this widget is hidden (its switch is off): "AirPad is locked"
        case emptyLibrary      // nothing (that isn't private) in the library
        case notChosen         // no entry picked yet
        case missing           // the chosen entry was deleted or made private
        /// widget fix-up 2 — the lock is on, this widget is set to show and its entry is in the locked copy: the entry,
        /// marked privacy-sensitive so the system can hide it while the phone itself is locked.
        case shownWhileLocked(Entry)
        /// widget fix-up 2 — the lock is on, this widget is set to show, but its entry isn't in the locked copy yet
        /// (switched on since AirPad was last unlocked): the locked tile, "Open AirPad to show this entry".
        case lockedNotYetShown
        /// widget fix-up 2 (review) — set to show, but another widget pinned to the same entry keeps it hidden (decided
        /// by the widget extension from its own configuration read; nothing about it is written to the copy).
        case lockedHeldBack
    }

    /// What one widget shows. `showWhenLocked` is THIS widget's own switch: with the lock on, a widget whose switch is
    /// off draws the locked tile and never reads the copy's entries, whatever the copy holds.
    static func display(chosenID: String?, showWhenLocked: Bool = false, mirror: PinnedEntryMirror?) -> Display {
        guard let m = mirror else { return .notSetUp }
        if m.locked {
            guard showWhenLocked, let id = chosenID else { return .locked }
            if let e = m.entries.first(where: { $0.id == id }) { return .shownWhileLocked(e) }
            return .lockedNotYetShown
        }
        if let id = chosenID {
            if let e = m.entries.first(where: { $0.id == id }) { return .entry(e) }
            return m.entries.isEmpty ? .emptyLibrary : .missing
        }
        return m.entries.isEmpty ? .emptyLibrary : .notChosen
    }

    /// The locked tile's glyph: the system symbol for the biometry this phone unlocks with, a plain lock otherwise.
    static func unlockSymbol(_ unlock: String?) -> String {
        switch unlock {
        case "faceID":  return "faceid"
        case "touchID": return "touchid"
        case "opticID": return "opticid"
        default:        return "lock.fill"
        }
    }

    /// The locked tile's one VoiceOver sentence.
    static func lockedAccessibilityLabel(_ unlock: String?) -> String {
        switch unlock {
        case "faceID":  return "AirPad is locked. Open AirPad and unlock it with Face ID to read your entries."
        case "touchID": return "AirPad is locked. Open AirPad and unlock it with Touch ID to read your entries."
        case "opticID": return "AirPad is locked. Open AirPad and unlock it with Optic ID to read your entries."
        default:        return "AirPad is locked. Open AirPad to read your entries."
        }
    }

    /// widget fix-up 2 — the locked tile of a widget set to show whose entry isn't in the copy yet: one sentence.
    static func notYetShownAccessibilityLabel(_ unlock: String?) -> String {
        switch unlock {
        case "faceID":  return "AirPad is locked. Open AirPad and unlock it with Face ID to show this entry."
        case "touchID": return "AirPad is locked. Open AirPad and unlock it with Touch ID to show this entry."
        case "opticID": return "AirPad is locked. Open AirPad and unlock it with Optic ID to show this entry."
        default:        return "AirPad is locked. Open AirPad to show this entry."
        }
    }

    /// widget fix-up 2 (review) — the locked tile of a widget whose entry another widget keeps hidden.
    static let heldBackAccessibilityLabel = "AirPad is locked. Another widget keeps this entry hidden."

    /// widget fix-up 2 (review 2) — a shown widget whose entry the system reports both shown and hidden. Right after a
    /// switch is flipped, iOS lists that one widget twice (old + new value) for ~30 s; two widgets pinned to one entry
    /// with different switches look the same but last. So the tile says "Another widget keeps this entry hidden" only
    /// once the split has lasted `heldBackAfter` (first seen by the extension, in memory only); before that it keeps
    /// "Open AirPad to show this entry" and asks to be drawn again when the wait is over. Pure (unit-tested).
    static let heldBackAfter: TimeInterval = 40
    static func splitTile(firstSeen: Date, now: Date) -> (heldBack: Bool, recheckAt: Date?) {
        now.timeIntervalSince(firstSeen) >= heldBackAfter
            ? (true, nil) : (false, firstSeen.addingTimeInterval(heldBackAfter + 1))
    }

    /// widget fix-up 2 (review 2) — does `new` only take away from `current`? (A locked copy whose entries are all
    /// in `current`: the empty locked copy when the lock turns on, a widget switched to hidden, an entry removed.) Only
    /// such a copy may be written when the file can't be coordinated: removal never waits, adding always does.
    static func onlyShrinks(_ new: PinnedEntryMirror, from current: PinnedEntryMirror?) -> Bool {
        guard new.locked else { return false }
        guard let current else { return new.entries.isEmpty }
        let held = Set(current.entries.map(\.id))
        return new.entries.allSatisfy { held.contains($0.id) }
    }

    /// widget fix-up 2 — which entries the LOCKED copy may hold. `current` = the ids the locked copy on disk holds now;
    /// `configuredShow` = the entry ids of the placed widgets set to show while locked; `unlocked` = Face ID has passed
    /// in this run (AirPad's lock screen isn't up). Locked, it can only shrink (`current ∩ configuredShow`): a switch
    /// flipped on by someone holding the unlocked phone adds nothing until the owner next unlocks AirPad. Unlocked, it is
    /// exactly the widgets' choice. Private entries are dropped later, when the copy is built.
    static func allowedIDs(current: Set<String>, configuredShow: Set<String>, unlocked: Bool) -> Set<String> {
        unlocked ? configuredShow : current.intersection(configuredShow)
    }

    /// widget fix-up 2 — the extension's cut: a locked copy keeps only the entries in `ids` (removal only, never adding).
    /// An unlocked copy is returned as it is.
    func pruned(keeping ids: Set<String>) -> PinnedEntryMirror {
        guard locked else { return self }
        var m = self
        m.entries = entries.filter { ids.contains($0.id) }
        return m
    }

    /// The picker's suggestions: the most recently changed entries.
    func suggestions(limit: Int = 30) -> [Entry] { Array(entries.prefix(limit)) }

    /// The picker's search: title or first line, ignoring case and accents. Empty → the suggestions.
    func search(_ string: String, limit: Int = 30) -> [Entry] {
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return suggestions(limit: limit) }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entries.filter { e in
            e.title.range(of: q, options: opts) != nil || e.lines.first?.text.range(of: q, options: opts) != nil
        }
    }
}

/// Where the copy lives, and the one reader / writer both targets use.
enum PinnedEntryMirrorFile {
    static let appGroup = "group.com.doctorpresident.airpad"
    /// The widget's kind: the app reloads exactly this widget's timelines after a write.
    static let widgetKind = "com.doctorpresident.airpad.pinnedentry"

    /// The widget's tap: `airpad://entry/<id>` (the app opens it, `WidgetEntryLink`).
    static func entryURL(for id: String) -> URL? {
        var c = URLComponents()
        c.scheme = "airpad"
        c.host = "entry"
        c.path = "/" + id
        return c.url
    }

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Widget", isDirectory: true)
            .appendingPathComponent("pinned-entries.json")
    }

    static func encode(_ mirror: PinnedEntryMirror) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return try? e.encode(mirror)
    }

    static func decode(_ data: Data) -> PinnedEntryMirror? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        guard let m = try? d.decode(PinnedEntryMirror.self, from: data),
              m.version == PinnedEntryMirror.currentVersion else { return nil }
        return m
    }

    /// Nil = no copy yet (the app hasn't run since the widget arrived) or an unreadable one.
    static func read(at url: URL? = PinnedEntryMirrorFile.url) -> PinnedEntryMirror? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func readData(at url: URL? = PinnedEntryMirrorFile.url) -> Data? {
        guard let url else { return nil }
        return try? Data(contentsOf: url)
    }

    /// widget fix-up 2 (review) — one read-modify-write of the copy, coordinated across the app and the widget
    /// extension (`NSFileCoordinator`), so neither writes back a copy built from bytes the other has since replaced.
    /// `change` gets the bytes on disk now (nil = none) and returns the bytes to write, or nil to leave the file as it
    /// is; identical bytes aren't rewritten. Returns the bytes written, nil when nothing was written.
    ///
    /// review 2 — the caller never waits on the coordinator for longer than `deadline` (the other process may hold the
    /// claim, even suspended): the coordination runs on a background queue and is cancelled at the deadline. When it
    /// fails or is cancelled, the new copy is still written directly if it only takes away from the file as it is
    /// (`onlyShrinks`): the empty locked copy when the lock turns on must never wait. A copy that would add is not.
    @discardableResult
    static func update(at url: URL? = PinnedEntryMirrorFile.url, deadline: TimeInterval = 2,
                       coordinator: NSFileCoordinator = NSFileCoordinator(filePresenter: nil),
                       _ change: @escaping (Data?) -> Data?) -> Data? {
        guard let url else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        final class Box: @unchecked Sendable { var written: Data?; var failed = false; var entered = false }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSError?
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { u in
                box.entered = true
                let now = try? Data(contentsOf: u)
                guard let next = change(now), next != now, write(next, to: u) else { return }
                box.written = next
            }
            if error != nil { box.failed = true }
            done.signal()
        }
        if done.wait(timeout: .now() + deadline) == .timedOut {
            coordinator.cancel()
            // Cancelled while waiting for the claim: returns at once. Already inside our own block: it is a small read
            // and write, let it finish; if even that doesn't come back, give up without writing.
            if done.wait(timeout: .now() + 1) == .timedOut { return nil }
        }
        guard box.failed, !box.entered else { return box.written }
        // Not coordinated: write only a copy that removes.
        let now = try? Data(contentsOf: url)
        guard let next = change(now), next != now,
              let new = decode(next), PinnedEntryMirror.onlyShrinks(new, from: now.flatMap(decode)),
              write(next, to: url) else { return nil }
        return next
    }

    @discardableResult
    static func write(_ data: Data, to url: URL? = PinnedEntryMirrorFile.url) -> Bool {
        guard let url else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // `.completeFileProtectionUntilFirstUserAuthentication`: readable by the widget after the first unlock
            // (the widget renders while the phone is locked too), never before it.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}
