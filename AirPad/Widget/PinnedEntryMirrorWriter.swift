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
    private var lastWritten: Data?
    private var cache: [String: (fingerprint: Int, entry: PinnedEntryMirror.Entry)] = [:]
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

    /// Write now (AirPad is leaving the foreground: a pending rebuild must not be lost to suspension).
    func flush() {
        pending?.cancel()
        pending = nil
        writeNow()
    }

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.nodes
            _ = store.libraryLoaded
            _ = AppLock.shared.enabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule(after: self?.settle ?? .zero)
                self?.observe()   // Observation fires once per registration: register again
            }
        }
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    /// Rebuild the copy; write + reload only when it changed. Never writes before the library is in memory (an empty
    /// store during launch must not read to the widget as "nothing in your library").
    @discardableResult
    func writeNow() -> Bool {
        guard let store, store.libraryLoaded else { return false }
        let font = UserDefaults.standard.string(forKey: EntryBodyFont.defaultStorageKey) ?? EntryBodyFont.fallback.rawValue
        return write(nodes: store.nodes, locked: AppLock.shared.enabled, font: font)
    }

    /// The write itself (unit-tested): build, compare with the bytes on disk, write + reload only on a change.
    @discardableResult
    func write(nodes: [Node], locked: Bool, font: String) -> Bool {
        if lastWritten == nil { lastWritten = PinnedEntryMirrorFile.readData(at: fileURL) }
        let mirror = build(nodes: nodes, locked: locked, font: font)
        guard let data = PinnedEntryMirrorFile.encode(mirror), data != lastWritten else { return false }
        guard PinnedEntryMirrorFile.write(data, to: fileURL) else { return false }
        lastWritten = data
        reload()
        return true
    }

    // MARK: - Building the copy

    func build(nodes: [Node], locked: Bool, font: String) -> PinnedEntryMirror {
        var m = PinnedEntryMirror()
        m.font = font
        guard !locked else {
            m.locked = true
            cache.removeAll()
            return m
        }
        var seen = Set<String>()
        var entries: [PinnedEntryMirror.Entry] = []
        entries.reserveCapacity(nodes.count)
        for node in nodes where !node.isPrivate {
            seen.insert(node.id)
            let fp = Self.fingerprint(node)
            if let hit = cache[node.id], hit.fingerprint == fp {
                entries.append(hit.entry)
            } else {
                let e = Self.entry(for: node)
                cache[node.id] = (fp, e)
                entries.append(e)
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        m.entries = entries.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        return m
    }

    /// Everything `entry(for:)` reads. In-process only (String hashing is seeded per launch), never stored.
    static func fingerprint(_ node: Node) -> Int {
        var h = Hasher()
        h.combine(node.title)
        h.combine(node.summary)
        h.combine(node.updatedAt)
        for item in node.items where item.type == .text { h.combine(item.content) }
        return h.finalize()
    }

    /// One entry's title and first lines, as plain text. Read-only display data: the library is never changed.
    static func entry(for node: Node) -> PinnedEntryMirror.Entry {
        var lines: [PinnedEntryMirror.Line] = []
        outer: for item in node.items where item.type == .text {
            guard let content = item.content, !content.isEmpty else { continue }
            for raw in TableConverter.flattenForPreview(content).components(separatedBy: "\n") {
                if let line = line(raw) { lines.append(line) }
                if lines.count >= PinnedEntryMirror.maxLines + 1 { break outer }   // +1: a derived title may use one
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
        return .init(id: node.id,
                     title: String(title.prefix(PinnedEntryMirror.maxTitleLength)),
                     updatedAt: node.updatedAt,
                     lines: Array(lines.prefix(PinnedEntryMirror.maxLines)))
    }

    /// One stored line → a display row: a checklist row keeps its ticked state; headings and list items keep their
    /// kind; Markdown syntax goes (`MarkdownPlain`); blank lines and rules are dropped.
    static func line(_ raw: String) -> PinnedEntryMirror.Line? {
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

    private static func clip(_ s: String) -> String { String(s.prefix(PinnedEntryMirror.maxLineLength)) }
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
