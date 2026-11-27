import Foundation
import Observation
import WidgetKit

// MARK: - ws-1.0-widget — the app keeps the Pinned Entry widget's copy current (app target only)

/// Hangs off ONE place: `CorpusStore.nodes`. Every way an entry changes while AirPad runs (an edit, a tick, a delete,
/// a merge that arrived by iCloud sync, the Sample Library being added or removed) lands in that array, so the writer
/// observes it (Observation, no change to the store's write paths), waits for the changes to settle, rebuilds the copy
/// and, only when its bytes differ from the file on disk, writes it and reloads the widget's timelines.
///
/// Freshness, stated plainly: an edit made in the app reaches the widget about a second after the store holds it (a
/// note's text is held when editing ends). A change that arrives by sync reaches it the next time AirPad runs and
/// loads it. The widget itself never reads the library.
@MainActor
final class PinnedEntryMirrorWriter {
    static let shared = PinnedEntryMirrorWriter()

    /// How long the store must be quiet before the copy is rebuilt (an edit burst, a load, a backfill).
    var settle: Duration = .milliseconds(800)

    private weak var store: CorpusStore?
    private var pending: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var lastWritten: Data?
    private var state = BuildState()
    private let fileURL: URL?
    private let reload: () -> Void

    init(fileURL: URL? = PinnedEntryMirrorFile.url,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: PinnedEntryMirrorFile.widgetKind) }) {
        self.fileURL = fileURL
        self.reload = reload
    }

    /// Called once the store has run `setup()`. Safe to call again.
    func start(store: CorpusStore) {
        let first = self.store == nil
        self.store = store
        if lastWritten == nil { lastWritten = PinnedEntryMirrorFile.readData(at: fileURL) }
        if first { observe() }
        schedule(after: .zero)
    }

    /// Write now, on this thread (AirPad is leaving the foreground: a pending rebuild must not be lost to suspension,
    /// and a moment of main-thread work there is invisible).
    func flush() {
        pending?.cancel()
        pending = nil
        guard let input = currentInput() else { return }
        write(nodes: input.nodes, locked: input.locked, font: input.font, unlock: input.unlock)
    }

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.nodes
            _ = store.libraryLoaded
            _ = AppLock.shared.enabled
            _ = AppLock.shared.method   // widget fix-up 1 — the locked tile's glyph
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // The Face ID lock turning on empties the copy at once (no settle: a kill right after must not leave
                // entry text on disk).
                self?.schedule(after: AppLock.shared.enabled ? .zero : (self?.settle ?? .zero))
                self?.observe()   // Observation fires once per registration: register again
            }
        }
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.inFlight?.value          // one rebuild at a time, newest input last
            guard !Task.isCancelled else { return }
            let run = Task { @MainActor in await self.writeInBackground() }
            self.inFlight = run
            await run.value
        }
    }

    /// What the copy is built from right now. Nil = nothing to write yet: entries are never written before the library
    /// is in memory (an empty store during launch must not read to the widget as "nothing in your library"); the locked
    /// copy (no entries) is written whenever the lock is on, loaded or not.
    private func currentInput() -> (nodes: [Node], locked: Bool, font: String, unlock: String?)? {
        guard let store else { return nil }
        let font = UserDefaults.standard.string(forKey: EntryBodyFont.defaultStorageKey) ?? EntryBodyFont.fallback.rawValue
        if AppLock.shared.enabled { return ([], true, font, Self.unlockKind(AppLock.shared.method)) }
        guard store.libraryLoaded else { return nil }
        return (store.nodes, false, font, nil)
    }

    /// widget fix-up 1 — the lock's cached method (`AppLock.method`, read from LocalAuthentication at launch and on
    /// every return to the foreground) as the copy's `unlock`. The widget doesn't ask LocalAuthentication itself: the
    /// app already knows, and the extension then needs nothing new.
    nonisolated static func unlockKind(_ method: AppLock.Method) -> String? {
        switch method {
        case .faceID:            return "faceID"
        case .touchID:           return "touchID"
        case .opticID:           return "opticID"
        case .passcode, .none:   return nil
        }
    }

    /// The normal path: snapshot on the main thread, build + encode + write off it, reload back on it.
    private func writeInBackground() async {
        guard let input = currentInput() else { return }
        let prior = state, previous = lastWritten, url = fileURL
        let result = await Task.detached(priority: .utility) { () -> (BuildState, Data?) in
            let built = Self.makeMirror(nodes: input.nodes, locked: input.locked, font: input.font,
                                        unlock: input.unlock, prior: prior)
            guard built.state.changed || previous == nil,
                  let data = PinnedEntryMirrorFile.encode(built.mirror), data != previous,
                  PinnedEntryMirrorFile.write(data, to: url) else { return (built.state, nil) }
            return (built.state, data)
        }.value
        state = result.0
        if let data = result.1 { lastWritten = data; reload() }
    }

    /// The write on the calling thread (unit-tested; `flush`): build, compare with the bytes on disk, write + reload
    /// only on a change.
    @discardableResult
    func write(nodes: [Node], locked: Bool, font: String, unlock: String? = nil) -> Bool {
        if lastWritten == nil { lastWritten = PinnedEntryMirrorFile.readData(at: fileURL) }
        let mirror = build(nodes: nodes, locked: locked, font: font, unlock: unlock)
        // Most store changes touch nothing the widget shows (embeddings, backfills, layout): skip the encode.
        guard lastBuildChanged || lastWritten == nil else { return false }
        guard let data = PinnedEntryMirrorFile.encode(mirror), data != lastWritten else { return false }
        guard PinnedEntryMirrorFile.write(data, to: fileURL) else { return false }
        lastWritten = data
        reload()
        return true
    }

    // MARK: - Building the copy (pure; runs off the main thread)

    /// What one build leaves for the next: the per-entry cache, the shape of the copy, and whether it changed.
    struct BuildState {
        var cache: [String: (fingerprint: Int, entry: PinnedEntryMirror.Entry)] = [:]
        var shape: (locked: Bool, font: String, count: Int, unlock: String?)?
        /// False when the build produced exactly the copy before it (every entry from the cache, none gone, same lock
        /// and font), so there is nothing to encode or write.
        var changed = true
    }

    var lastBuildChanged: Bool { state.changed }

    func build(nodes: [Node], locked: Bool, font: String, unlock: String? = nil) -> PinnedEntryMirror {
        let built = Self.makeMirror(nodes: nodes, locked: locked, font: font, unlock: unlock, prior: state)
        state = built.state
        return built.mirror
    }

    nonisolated static func makeMirror(nodes: [Node], locked: Bool, font: String, unlock: String? = nil,
                                       prior: BuildState) -> (mirror: PinnedEntryMirror, state: BuildState) {
        var m = PinnedEntryMirror()
        m.font = font
        var next = BuildState()
        guard !locked else {
            m.locked = true
            m.unlock = unlock   // only the locked copy says how AirPad unlocks
            next.changed = prior.shape.map { !$0.locked || $0.font != font || $0.unlock != unlock } ?? true
            next.shape = (true, font, 0, unlock)
            return (m, next)
        }
        var misses = 0
        var entries: [PinnedEntryMirror.Entry] = []
        entries.reserveCapacity(nodes.count)
        next.cache.reserveCapacity(nodes.count)
        for node in nodes where !node.isPrivate {
            let fp = fingerprint(node)
            if let hit = prior.cache[node.id], hit.fingerprint == fp {
                entries.append(hit.entry)
                next.cache[node.id] = hit
            } else {
                let e = entry(for: node)
                next.cache[node.id] = (fp, e)
                entries.append(e)
                misses += 1
            }
        }
        next.changed = misses > 0
            || prior.shape.map { $0.locked || $0.font != font || $0.count != entries.count } ?? true
        next.shape = (false, font, entries.count, nil)
        m.entries = entries.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        return (m, next)
    }

    /// Everything `entry(for:)` reads. In-process only (String hashing is seeded per launch), never stored.
    nonisolated static func fingerprint(_ node: Node) -> Int {
        var h = Hasher()
        h.combine(node.title)
        h.combine(node.summary)
        h.combine(node.updatedAt)
        for item in node.items where item.type == .text { h.combine(item.content) }
        return h.finalize()
    }

    /// One entry's title and first lines, as plain text. Read-only display data: the library is never changed.
    nonisolated static func entry(for node: Node) -> PinnedEntryMirror.Entry {
        var lines: [PinnedEntryMirror.Line] = []
        var more = 0
        for item in node.items where item.type == .text {
            guard let content = item.content, !content.isEmpty else { continue }
            for raw in TableConverter.flattenForPreview(content).components(separatedBy: "\n") {
                if lines.count < PinnedEntryMirror.maxLines + 1 {   // +1: a derived title may use one
                    if let line = line(raw) { lines.append(line) }
                } else if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    more += 1   // counted, not parsed (a rare rule or table separator counts too)
                }
            }
        }
        var title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            // An untitled entry shows its first line as the title (as its card does), not twice.
            if let first = lines.first, first.kind != .check {
                title = first.text
                lines.removeFirst()
            } else {
                title = "Untitled"
            }
        } else {
            title = MarkdownPlain.label(title)
        }
        if lines.isEmpty {
            let summary = MarkdownPlain.label(node.summary)
            if !summary.isEmpty { lines = [.init(kind: .text, text: clip(summary))] }
        }
        if lines.count > PinnedEntryMirror.maxLines {
            more += lines.count - PinnedEntryMirror.maxLines
            lines = Array(lines.prefix(PinnedEntryMirror.maxLines))
        }
        return .init(id: node.id,
                     title: String(title.prefix(PinnedEntryMirror.maxTitleLength)),
                     updatedAt: node.updatedAt,
                     lines: lines,
                     more: more)
    }

    /// One stored line → a display row: a checklist row keeps its ticked state; headings and list items keep their
    /// kind; Markdown syntax goes (`MarkdownPlain`); blank lines and rules are dropped.
    nonisolated static func line(_ raw: String) -> PinnedEntryMirror.Line? {
        if let cb = MarkdownPlain.checkbox(raw) {
            let t = MarkdownPlain.inline(cb.text).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : .init(kind: .check, done: cb.done, text: clip(t))
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let text = MarkdownPlain.inline(MarkdownPlain.block(raw)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let kind: PinnedEntryMirror.Line.Kind
        if trimmed.range(of: #"^#{1,6}(\s|$)"#, options: .regularExpression) != nil {
            kind = .heading
        } else if trimmed.range(of: #"^(?:[-*+•]|\d{1,3}[.)])\s+"#, options: .regularExpression) != nil {
            kind = .bullet
        } else {
            kind = .text
        }
        return .init(kind: kind, text: clip(text))
    }

    nonisolated private static func clip(_ s: String) -> String { String(s.prefix(PinnedEntryMirror.maxLineLength)) }
}

// MARK: - Opening an entry from the widget

/// The widget's tap: `airpad://entry/<id>`. Handled warm (`onOpenURL` / `SceneDelegate`) and cold (latched until the
/// library is in memory, then consumed). Opens the entry exactly as a Chat-view citation does
/// (`AppRouter.citedEntryToOpen` → the surface underneath pushes its Detail View). A private entry that is hidden, or
/// an id no longer in the library, just opens AirPad.
@MainActor
enum WidgetEntryLink {
    static let host = "entry"
    private(set) static var pendingID: String?
    /// Set once the store has run `setup()` (AirPadApp).
    static weak var store: CorpusStore?
    private static var lastOpened: (id: String, at: Date)?

    static func url(for id: String) -> URL? { PinnedEntryMirrorFile.entryURL(for: id) }

    static func entryID(from url: URL) -> String? {
        guard url.scheme == "airpad", url.host == host else { return nil }
        let id = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        return id.isEmpty ? nil : id
    }

    /// A widget URL arrived. Opens now if the library is loaded, otherwise waits for `consumePending`.
    static func handle(_ url: URL) -> Bool {
        guard let id = entryID(from: url) else { return false }
        pendingID = id
        consumePending()
        return true
    }

    /// Called when a URL arrives and once the store has loaded.
    static func consumePending() {
        guard let id = pendingID, let router = AppRouter.shared, let store,
              store.libraryLoaded else { return }
        pendingID = nil
        // `onOpenURL` and the scene delegate can both deliver the same tap: open it once.
        if let last = lastOpened, last.id == id, Date().timeIntervalSince(last.at) < 1.5 { return }
        guard let node = store.nodes.first(where: { $0.id == id }), !store.isHidden(node) else { return }
        lastOpened = (id, Date())
        if router.entryMode == .quikCapture { router.entryMode = .recents }
        router.citedEntryToOpen = id
    }
}
