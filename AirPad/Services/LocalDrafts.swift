import Foundation
import os

/// Batch B fix-up F2 (T's two-device pass: half-typed text synced — a title "2" before "2D one (Mac)"). Typing now
/// reaches the shared library only on a typing pause (`CorpusStore.typingPause`) or when the field loses focus, so
/// the other device sees whole edits. Between those writes, every change is kept HERE: a local draft outside the
/// synced folder (Application Support/Drafts), so a crash or force-quit never loses typing. On the next launch the
/// store recovers each draft that differs from what was saved, as a user edit (the write funnel merges it with
/// anything another device changed meanwhile).
///
/// Keys: `item:<itemID>` (a note's text), `title:<nodeID>`, `summary:<nodeID>`. Writes are coalesced and go to disk
/// off the main thread; the file is tiny (only what's unsaved).
enum LocalDrafts {
    struct Draft: Codable, Equatable {
        var node: String
        var text: String
        var t: Double
    }

    private static let state = OSAllocatedUnfairLock<[String: Draft]?>(initialState: nil)
    private static let queue = DispatchQueue(label: "AirPad.LocalDrafts", qos: .utility)
    private static let flushPending = OSAllocatedUnfairLock<Bool>(initialState: false)

    static var url: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Drafts", isDirectory: true).appendingPathComponent("drafts.json")
    }

    private static func loaded(_ s: inout [String: Draft]?) -> [String: Draft] {
        if let s { return s }
        let d = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Draft].self, from: $0) } ?? [:]
        s = d
        return d
    }

    static func all() -> [String: Draft] { state.withLock { loaded(&$0) } }

    /// DEBUG `-SyncNoDraftsForControl` — the harness's positive control for the crash row: no drafts kept.
    static let offForControl: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-SyncNoDraftsForControl")
        #else
        return false
        #endif
    }()

    static func set(_ key: String, node: String, text: String) {
        guard !offForControl else { return }
        let changed = state.withLock { s -> Bool in
            var d = loaded(&s)
            if d[key]?.text == text { return false }
            d[key] = Draft(node: node, text: text, t: Date().timeIntervalSince1970)
            s = d
            return true
        }
        if changed { scheduleFlush() }
    }

    /// The text reached the library: the draft goes, unless it has moved on since (more typing).
    static func clear(_ key: String, ifText text: String? = nil) {
        let changed = state.withLock { s -> Bool in
            var d = loaded(&s)
            guard let cur = d[key], text == nil || cur.text == text else { return false }
            d[key] = nil
            s = d
            return true
        }
        if changed { scheduleFlush() }
    }

    static func clearNode(_ node: String) {
        let changed = state.withLock { s -> Bool in
            var d = loaded(&s)
            let before = d.count
            d = d.filter { $0.value.node != node }
            s = d
            return d.count != before
        }
        if changed { scheduleFlush() }
    }

    private static func scheduleFlush() {
        let schedule = flushPending.withLock { p -> Bool in defer { p = true }; return !p }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 0.15) {
            flushPending.withLock { $0 = false }
            let snapshot = state.withLock { loaded(&$0) }
            guard let url else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if snapshot.isEmpty { try? FileManager.default.removeItem(at: url); return }
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    #if DEBUG
    /// Synchronous write, for the harness's crash check (it kills the app right after typing).
    static func flushNow() {
        let snapshot = state.withLock { loaded(&$0) }
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
    #endif
}
