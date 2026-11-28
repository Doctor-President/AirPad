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
///
/// widget fix-up 2 — with the Face ID lock on, the copy holds the entries of the widgets set to "Show while AirPad is
/// locked" and no others. Which widgets those are comes from the system (`PinnedEntryConfigurations`), read when AirPad
/// becomes active, after an unlock, and when the lock is turned on. An entry is ADDED only while AirPad is unlocked
/// (Face ID passed in this run); while it is locked the copy can only shrink (`PinnedEntryMirror.allowedIDs`).
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
    /// widget fix-up 2 — the entry ids of the placed widgets set to show while locked, as last read. Nil = not known:
    /// not read since the lock was turned on or AirPad last went to the background, or the last read failed. While nil
    /// the locked copy only shrinks (`lockedAllowed`); nothing is added until a fresh read answers.
    private(set) var configuredShow: Set<String>?
    /// widget fix-up 2 (review) — entries one widget shows and another, pinned to the same entry, keeps hidden: still
    /// split after the re-reads ran out, so not the system's transient twin. Their tile says so.
    private(set) var heldBack: Set<String> = []
    private var configurationRead = 0          // a read started before the lock turned on / AirPad left is dropped
    private var lastEnabled: Bool?
    private var lastLocked: Bool?
    private let readConfigurations: () async -> PinnedEntryConfigurations.Read?
    private let lockState: @MainActor () -> LockState
    /// widget fix-up 2 (review) — bumped by every write; a build that finishes after a newer write started (`flush`)
    /// doesn't land.
    private let generations = WriteGeneration()
    /// Whether the last build is what the file holds (written, or identical). False after a build was dropped or trimmed;
    /// then the next pass can't skip on "nothing changed since the last build".
    private var lastLanded = false
    /// While the system's answer hasn't settled (`Read.settled`), re-read every `rereadInterval`, at most this many
    /// times (~45 s).
    static let unsettledRereads = 15
    var rereadInterval: Duration = .seconds(3)

    /// What the writer needs of the Face ID lock (injected so the unit tests can drive it).
    struct LockState {
        var enabled: Bool
        var isLocked: Bool
        var coverShown: Bool
        var method: AppLock.Method
        /// Face ID passed in this run and AirPad is in front: the only time an entry may be added to the locked copy.
        var unlocked: Bool { !isLocked && !coverShown }
        @MainActor static var app: LockState {
            let l = AppLock.shared
            return LockState(enabled: l.enabled, isLocked: l.isLocked, coverShown: l.coverShown, method: l.method)
        }
    }

    init(fileURL: URL? = PinnedEntryMirrorFile.url,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: PinnedEntryMirrorFile.widgetKind) },
         readConfigurations: @escaping () async -> PinnedEntryConfigurations.Read? = { await PinnedEntryConfigurations.read() },
         lockState: @escaping @MainActor () -> LockState = { LockState.app }) {
        self.fileURL = fileURL
        self.reload = reload
        self.readConfigurations = readConfigurations
        self.lockState = lockState
    }

    /// Called once the store has run `setup()`. Safe to call again.
    func start(store: CorpusStore) {
        let first = self.store == nil
        self.store = store
        if lastWritten == nil { lastWritten = PinnedEntryMirrorFile.readData(at: fileURL) }
        if first {
            lastEnabled = AppLock.shared.enabled
            lastLocked = AppLock.shared.isLocked
            observe()
        }
        schedule(after: .zero)
        refreshConfigurations()
    }

    /// widget fix-up 2 — read which placed widgets are set to show while locked, then rebuild the copy. Called when
    /// AirPad becomes active, after a successful unlock and when the lock is turned on. Only matters with the lock on.
    func refreshConfigurations() { readConfigurations(attempt: 0) }

    private func readConfigurations(attempt: Int) {
        guard lockState().enabled else { return }
        configurationRead += 1
        let read = configurationRead
        Task { @MainActor [weak self] in
            guard let self else { return }
            let r = await self.readConfigurations()
            PinnedEntryConfigurations.debugLog("app read #\(read) (current #\(self.configurationRead)): "
                + (r.map { "\($0.show.count) shown, settled=\($0.settled)" } ?? "nil") + " unlocked=\(self.lockState().unlocked)")
            // A read overtaken by a newer one, by the lock turning on or off, or by AirPad leaving: dropped.
            guard read == self.configurationRead, self.lockState().enabled else { return }
            guard let r else {
                // No answer: forget what an older read said; removal only until one answers.
                self.configuredShow = nil
                self.schedule(after: .zero)
                return
            }
            self.configuredShow = r.show
            if r.settled { self.heldBack = [] } else if attempt >= Self.unsettledRereads { self.heldBack = r.conflicted }
            self.schedule(after: .zero)
            // Not settled (a switch was just flipped): read again shortly; a newer read supersedes this chain.
            guard !r.settled, attempt < Self.unsettledRereads else { return }
            try? await Task.sleep(for: self.rereadInterval)
            guard read == self.configurationRead else { return }
            self.readConfigurations(attempt: attempt + 1)
        }
    }

    /// widget fix-up 2 (review) — AirPad went to the background: the widgets' choices may change on the Home Screen
    /// meanwhile, so what was read no longer counts (and a read in flight is dropped). Until the read on return answers,
    /// the locked copy only shrinks.
    func sceneDidEnterBackground() {
        configuredShow = nil
        configurationRead += 1
    }

    /// The lock setting or the lock screen changed (Observation).
    private func lockStateChanged() {
        let lock = AppLock.shared
        if lock.enabled != lastEnabled {
            lastEnabled = lock.enabled
            // Turned on: what was read before no longer counts. The empty locked copy is written at once; the allowed
            // entries follow the read (turning the lock on needs Face ID, so AirPad is unlocked then).
            configuredShow = nil
            configurationRead += 1
            if lock.enabled { refreshConfigurations() }
        }
        if lock.isLocked != lastLocked {
            lastLocked = lock.isLocked
            if !lock.isLocked { refreshConfigurations() }   // Face ID passed: the switches flipped since can now add
        }
    }

    /// Write now, on this thread (AirPad is leaving the foreground: a pending rebuild must not be lost to suspension,
    /// and a moment of main-thread work there is invisible).
    func flush() {
        pending?.cancel()
        pending = nil
        guard let input = currentInput() else { return }
        // `write` takes a newer generation, so a build still in flight (older input) can't land after this one.
        write(nodes: input.nodes, locked: input.locked, font: input.font, unlock: input.unlock, allowed: input.allowed,
              unlocked: input.unlocked, heldBack: input.heldBack)
    }

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.nodes
            _ = store.libraryLoaded
            _ = AppLock.shared.enabled
            _ = AppLock.shared.method   // widget fix-up 1 — the locked tile's glyph
            _ = AppLock.shared.isLocked // widget fix-up 2 — an unlock lets the chosen entries in
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.lockStateChanged()
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

    struct Input {
        var nodes: [Node]
        var locked: Bool
        var font: String
        var unlock: String?
        /// Locked only: the entry ids the copy may hold.
        var allowed: Set<String> = []
        /// Locked only: may this write add entries the file doesn't hold now (Face ID passed, AirPad in front)?
        var unlocked = true
        var heldBack: Set<String> = []
    }

    /// What the copy is built from right now. Nil = nothing to write yet: entries are never written before the library
    /// is in memory (an empty store during launch must not read to the widget as "nothing in your library").
    private func currentInput() -> Input? {
        guard let store else { return nil }
        let font = UserDefaults.standard.string(forKey: EntryBodyFont.defaultStorageKey) ?? EntryBodyFont.fallback.rawValue
        let lock = lockState()
        guard lock.enabled else {
            guard store.libraryLoaded else { return nil }
            return Input(nodes: store.nodes, locked: false, font: font, unlock: nil)
        }
        // The copy on disk is the truth here, not what this writer last wrote: the widget extension may have cut it
        // since. (The write checks it again, coordinated, right before it lands.)
        let disk = PinnedEntryMirrorFile.read(at: fileURL)
        guard let allowed = Self.lockedAllowed(disk: disk, configuredShow: configuredShow,
                                               libraryLoaded: store.libraryLoaded, unlocked: lock.unlocked) else { return nil }
        return Input(nodes: allowed.isEmpty ? [] : store.nodes, locked: true, font: font,
                     unlock: Self.unlockKind(lock.method), allowed: allowed, unlocked: lock.unlocked,
                     heldBack: heldBack)
    }

    /// widget fix-up 2 — with the lock on, which entries the locked copy is written with now; nil = leave the copy on
    /// disk as it is. A copy that isn't locked yet (the lock just turned on) is replaced at once by the empty locked
    /// copy. An already-locked copy waits until the library is in memory. While the widgets' choices aren't known
    /// (`configuredShow` nil: not read since AirPad came back, or the read failed) it keeps what it holds, so edits and
    /// deletions still reach it and nothing is added; once known it takes `allowedIDs` (only shrinking unless AirPad is
    /// unlocked). Pure (unit-tested).
    nonisolated static func lockedAllowed(disk: PinnedEntryMirror?, configuredShow: Set<String>?, libraryLoaded: Bool,
                                          unlocked: Bool) -> Set<String>? {
        guard let disk, disk.locked else { return [] }
        guard libraryLoaded else { return nil }
        let current = Set(disk.entries.map(\.id))
        guard let show = configuredShow else { return current }
        return PinnedEntryMirror.allowedIDs(current: current, configuredShow: show, unlocked: unlocked)
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
        let prior = state, previous = lastWritten, landed = lastLanded, url = fileURL, gens = generations
        let generation = gens.next()
        let result = await Task.detached(priority: .utility) { () -> (BuildState, Commit) in
            let built = Self.makeMirror(nodes: input.nodes, locked: input.locked, font: input.font, unlock: input.unlock,
                                        allowed: input.allowed, heldBack: input.heldBack, prior: prior)
            let c = Self.commit(built.mirror, changed: built.state.changed, input: input, previous: previous,
                                previousLanded: landed, url: url, generation: generation, generations: gens)
            return (built.state, c)
        }.value
        state = result.0
        lastLanded = result.1.landed
        if let data = result.1.written { lastWritten = data; reload() }
    }

    /// What a commit did: the bytes written (nil = none), and whether the file now holds exactly this build.
    struct Commit { var written: Data?; var landed: Bool }

    /// widget fix-up 2 (review) — the one place the app writes the copy, inside a coordinated read-modify-write
    /// (`PinnedEntryMirrorFile.update`) against the bytes on disk now, not what this writer last wrote:
    /// - a build overtaken by a newer write (`flush`) doesn't land;
    /// - unchanged input and a file nobody else touched: nothing to do (the common pass);
    /// - while AirPad is locked, the copy keeps only entries the file holds now (it never adds);
    /// - bytes identical to the file aren't rewritten.
    nonisolated static func commit(_ mirror: PinnedEntryMirror, changed: Bool, input: Input, previous: Data?,
                                   previousLanded: Bool, url: URL?, generation: Int,
                                   generations: WriteGeneration) -> Commit {
        var landed = false
        let written = PinnedEntryMirrorFile.update(at: url) { onDisk in
            guard generations.isCurrent(generation) else { return nil }        // dropped: landed stays false
            if !changed, previousLanded, let onDisk, onDisk == previous { landed = true; return nil }
            var m = mirror
            if input.locked, !input.unlocked, let disk = onDisk.flatMap(PinnedEntryMirrorFile.decode), disk.locked {
                let held = Set(disk.entries.map(\.id))
                m.entries = m.entries.filter { held.contains($0.id) }
            }
            landed = m == mirror
            return PinnedEntryMirrorFile.encode(m)
        }
        return Commit(written: written, landed: landed)
    }

    /// The write on the calling thread (unit-tested; `flush`): build, then the coordinated commit; reload on a write.
    @discardableResult
    func write(nodes: [Node], locked: Bool, font: String, unlock: String? = nil, allowed: Set<String> = [],
               unlocked: Bool = true, heldBack: Set<String> = []) -> Bool {
        if lastWritten == nil { lastWritten = PinnedEntryMirrorFile.readData(at: fileURL) }
        let generation = generations.next()
        let mirror = build(nodes: nodes, locked: locked, font: font, unlock: unlock, allowed: allowed, heldBack: heldBack)
        let input = Input(nodes: [], locked: locked, font: font, unlock: unlock, allowed: allowed, unlocked: unlocked,
                          heldBack: heldBack)
        let c = Self.commit(mirror, changed: lastBuildChanged, input: input, previous: lastWritten,
                            previousLanded: lastLanded, url: fileURL, generation: generation, generations: generations)
        lastLanded = c.landed
        guard let data = c.written else { return false }
        lastWritten = data
        reload()
        return true
    }

    /// Which write is the newest (read and bumped from any thread).
    final class WriteGeneration: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        func isCurrent(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == g }
    }

    // MARK: - Building the copy (pure; runs off the main thread)

    /// What one build leaves for the next: the per-entry cache, the shape of the copy, and whether it changed.
    struct BuildState {
        var cache: [String: (fingerprint: Int, entry: PinnedEntryMirror.Entry)] = [:]
        var shape: (locked: Bool, font: String, ids: Set<String>, unlock: String?, heldBack: [String]?)?
        /// False when the build produced exactly the copy before it (every entry from the cache, none gone, same lock
        /// and font), so there is nothing to encode or write.
        var changed = true
    }

    var lastBuildChanged: Bool { state.changed }

    func build(nodes: [Node], locked: Bool, font: String, unlock: String? = nil,
               allowed: Set<String> = [], heldBack: Set<String> = []) -> PinnedEntryMirror {
        let built = Self.makeMirror(nodes: nodes, locked: locked, font: font, unlock: unlock, allowed: allowed,
                                    heldBack: heldBack, prior: state)
        state = built.state
        return built.mirror
    }

    /// `locked`: the copy holds only the entries in `allowed` (widget fix-up 2; empty = none). Private entries never.
    nonisolated static func makeMirror(nodes: [Node], locked: Bool, font: String, unlock: String? = nil,
                                       allowed: Set<String> = [], heldBack: Set<String> = [],
                                       prior: BuildState) -> (mirror: PinnedEntryMirror, state: BuildState) {
        var m = PinnedEntryMirror()
        m.font = font
        m.locked = locked
        m.unlock = locked ? unlock : nil   // only the locked copy says how AirPad unlocks
        // Only the locked copy, and only ids (sorted, so the bytes are stable); nil is left out of the bytes.
        m.heldBack = locked && !heldBack.isEmpty ? heldBack.sorted() : nil
        var next = BuildState()
        var misses = 0
        var entries: [PinnedEntryMirror.Entry] = []
        entries.reserveCapacity(locked ? allowed.count : nodes.count)
        next.cache.reserveCapacity(locked ? allowed.count : nodes.count)
        for node in nodes where !node.isPrivate && (!locked || allowed.contains(node.id)) {
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
        let ids = Set(next.cache.keys)
        next.changed = misses > 0
            || prior.shape.map { $0.locked != locked || $0.font != font || $0.ids != ids || $0.unlock != m.unlock
                || $0.heldBack != m.heldBack } ?? true
        next.shape = (locked, font, ids, m.unlock, m.heldBack)
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
