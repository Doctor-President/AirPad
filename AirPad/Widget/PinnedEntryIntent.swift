import AppIntents
import WidgetKit

// MARK: - ws-1.0-widget — the Pinned Entry widget's configuration (compiled into the app AND the widget extension)

/// Shared so the app can read each placed widget's own choices (`WidgetCenter.currentConfigurations()` +
/// `widgetConfigurationIntent(of:)`): which entry it shows, and whether it may show it while AirPad is locked.

struct PinnedEntryIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Pinned Entry"
    static let description = IntentDescription("Choose the entry this widget shows.")

    @Parameter(title: "Entry")
    var entry: PinnedEntryEntity?

    /// widget fix-up 2 (T, 11-27: "the locked widget is a per-widget choice") — with AirPad's Face ID lock on, this
    /// widget shows its entry instead of the "AirPad is locked" tile. Off by default, so a widget placed before this
    /// build stays hidden. It only takes effect after AirPad has been unlocked with Face ID (`PinnedEntryMirrorWriter`
    /// adds an entry to the locked copy only then). With the lock off it does nothing.
    @Parameter(title: "Show while AirPad is locked", default: false)
    var showWhenLocked: Bool

    init() {}
    init(entry: PinnedEntryEntity?, showWhenLocked: Bool = false) {
        self.entry = entry
        self.showWhenLocked = showWhenLocked
    }
}

struct PinnedEntryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Entry"
    static let defaultQuery = PinnedEntryQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

/// The picker: suggestions = the most recently changed entries; search = title and first line. Reads the saved copy
/// only, so with the lock on it lists only the entries already in the locked copy (entries some widget is set to show),
/// never another title. A saved choice whose entry is gone still resolves (so the widget can say it is gone instead of
/// silently falling back to "choose an entry"), under a neutral name.
struct PinnedEntryQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PinnedEntryEntity] {
        let byID = Dictionary((PinnedEntryMirrorFile.read()?.entries ?? []).map { ($0.id, $0.title) },
                              uniquingKeysWith: { a, _ in a })
        return identifiers.map { PinnedEntryEntity(id: $0, title: byID[$0] ?? "Unavailable entry") }
    }

    func entities(matching string: String) async throws -> [PinnedEntryEntity] {
        (PinnedEntryMirrorFile.read()?.search(string) ?? []).map { PinnedEntryEntity(id: $0.id, title: $0.title) }
    }

    func suggestedEntities() async throws -> [PinnedEntryEntity] {
        (PinnedEntryMirrorFile.read()?.suggestions() ?? []).map { PinnedEntryEntity(id: $0.id, title: $0.title) }
    }
}

// MARK: - Reading the placed widgets' choices

enum PinnedEntryConfigurations {
    /// One read of the placed widgets' choices.
    struct Read: Equatable {
        /// Entry ids every placed widget naming them has set to show.
        var show: Set<String>
        /// Entry ids the system reports both shown and hidden. Seen on iOS 27 (Simulator): for about 30 s after a
        /// switch is flipped in Edit Widget, `currentConfigurations()` lists that widget twice, with the old value and
        /// the new one, in either order. Two widgets pinned to one entry, one shown and one hidden, look the same and
        /// stay that way.
        var conflicted: Set<String> = []
        var settled: Bool { conflicted.isEmpty }
    }

    /// The placed Pinned Entry widgets' choices. Nil = the system didn't answer (an error, or not within `timeout`):
    /// callers then add nothing. The timeout really returns: the system call runs in its own task and is raced through
    /// a continuation resumed exactly once (a task group would wait for an XPC call that ignores cancellation).
    static func read(timeout: Duration = .seconds(3),
                     system: @escaping @Sendable () async -> Read? = { await systemRead() }) async -> Read? {
        let once = ResumeOnce()
        let result: Read? = await withCheckedContinuation { (cont: CheckedContinuation<Read?, Never>) in
            once.set(cont)
            Task.detached(priority: .utility) { once.resume(await system()) }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
        if result == nil { debugLog("no answer (error or timeout)") }
        return result
    }

    /// The system's answer: every placed widget of this kind, reduced.
    static func systemRead() async -> Read? {
        let infos: [WidgetInfo]
        do { infos = try await WidgetCenter.shared.currentConfigurations() } catch {
            debugLog("currentConfigurations error: \(error)")
            return nil
        }
        let configs = infos.compactMap { info -> (entryID: String?, show: Bool)? in
            guard info.kind == PinnedEntryMirrorFile.widgetKind,
                  let intent = info.widgetConfigurationIntent(of: PinnedEntryIntent.self) else { return nil }
            return (intent.entry?.id, intent.showWhenLocked)
        }
        debugLog("read \(infos.count) widgets: \(configs.map { "\($0.entryID?.prefix(8) ?? "nil"):\($0.show)" })")
        return reduce(configs)
    }

    /// Resumes a continuation exactly once, whichever of the system call and the timeout finishes first.
    final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Read?, Never>?
        private var early: Read??
        func set(_ c: CheckedContinuation<Read?, Never>) {
            lock.lock()
            if let value = early { lock.unlock(); c.resume(returning: value); return }
            cont = c
            lock.unlock()
        }
        func resume(_ value: Read?) {
            lock.lock()
            if let c = cont { cont = nil; early = .some(nil); lock.unlock(); c.resume(returning: value); return }
            if early == nil { early = .some(value) }   // arrived before `set`: hand it over then
            lock.unlock()
        }
    }

    /// DEBUG builds only: `[PinnedEntryConfig] <process> …` in the console (ids are clipped; never a title).
    static func debugLog(_ s: String) {
        #if DEBUG
        NSLog("[PinnedEntryConfig] %@ %@", ProcessInfo.processInfo.processName, s)
        #endif
    }

    /// Pure: an entry may show while locked only if every configuration naming it says show; a hide wins. So the
    /// system's transient twin (old + new value) can delay an entry being added, never keep or add one. The cost: two
    /// widgets pinning the same entry show it while locked only if both are set to show. A widget with no entry chosen
    /// counts for nothing.
    static func reduce(_ configs: [(entryID: String?, show: Bool)]) -> Read {
        var show = Set<String>(), hide = Set<String>()
        for c in configs {
            guard let id = c.entryID else { continue }
            if c.show { show.insert(id) } else { hide.insert(id) }
        }
        return Read(show: show.subtracting(hide), conflicted: show.intersection(hide))
    }
}
