import Foundation

// MARK: - ws-1.0-widget — the Pinned Entry widget's saved copy (compiled into the app AND the widget extension)

/// The small, device-local copy of the library that the Home Screen widget reads. The widget never opens the
/// library: the app writes this one file into the App Group container whenever an entry changes
/// (`PinnedEntryMirrorWriter`), and the widget's picker and timeline read it. It is NOT a library file, is not in
/// iCloud Drive and is not synced (format rule 11-15: no field is added to any library file).
///
/// What it holds: for every entry that is not private, its id, a title, when it last changed and its first few lines
/// as plain text (checklist rows keep their ticked state). Private entries are never in it. With the Face ID lock on,
/// it holds no entries at all (`locked`), so nothing of the library reaches the Home Screen or the widget's picker.
struct PinnedEntryMirror: Codable, Equatable {
    /// Bumped if the shape changes; a widget that reads a different version shows "Open AirPad" until the app
    /// rewrites it.
    static let currentVersion = 1

    var version: Int = PinnedEntryMirror.currentVersion
    /// The Face ID lock is on: `entries` is empty and the widget says AirPad is locked.
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
        case locked            // the Face ID lock is on
        case emptyLibrary      // nothing (that isn't private) in the library
        case notChosen         // no entry picked yet
        case missing           // the chosen entry was deleted or made private
    }

    static func display(chosenID: String?, mirror: PinnedEntryMirror?) -> Display {
        guard let m = mirror else { return .notSetUp }
        if m.locked { return .locked }
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
