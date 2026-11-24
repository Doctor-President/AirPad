import Foundation
import UIKit
import SwiftUI

/// live-17 — what a document's viewer and Share sheet are HANDED: the title the viewer shows and the file name a
/// recipient receives. The `DocumentHandoffName` UI test (run with `-DocumentHandoffProbe -StdoutToFile`) asserts both are
/// the document's display name, never the stored UUID file name. DEBUG + launch arg only; Release: no-op.
enum DocumentHandoffProbe {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("-DocumentHandoffProbe")
    #endif

    static func preview(doc: String, title: String?, url: URL) {
        #if DEBUG
        if enabled { print("[DocHandoff] preview doc=\(doc) title=\(title ?? "<file name>") file=\(url.lastPathComponent)") }
        #endif
    }

    static func share(doc: String, urls: [URL]) {
        #if DEBUG
        if enabled { print("[DocHandoff] share doc=\(doc) files=\(urls.map(\.lastPathComponent).joined(separator: "|"))") }
        #endif
    }

    /// The named copy was removed; `left` = hand-off folders still on disk.
    static func released(doc: String) {
        #if DEBUG
        if enabled {
            let left = (try? FileManager.default.contentsOfDirectory(atPath: DocumentHandoff.root.path))?.count ?? 0
            print("[DocHandoff] released doc=\(doc) left=\(left)")
        }
        #endif
    }
}

/// live-17 — a document leaving its card (the viewer, the viewer's own Share, the item's "…" → Share) goes out under its
/// DISPLAY name (`DocumentItem.displayName`: real file name → PDF title → "PDF · date"), never the stored file's UUID
/// name. T (TF 202610142134): the viewer's title bar read "F1062A75-5970-…" while the card read the real name, and the
/// share sheet handed the same UUID-named file to the recipient.
///
/// Storage stays UUID-named. What goes out is a COPY named `<display name>.<ext>` (sanitised) in its own temp folder
/// (an APFS clone, so no bytes are duplicated), handed to QuickLook (with `previewItemTitle` set too) and to the share
/// sheet. The folder is removed when the viewer or share sheet closes (`release()`); `purgeAll()` at launch clears any
/// a crash left behind. If the copy fails (the file not downloaded yet), the stored file goes out with the right title,
/// logged.
struct DocumentHandoff: Identifiable, Equatable {
    let id = UUID()
    let documentID: String
    /// What the viewer / share sheet is handed: the named copy (the stored file only if the copy failed).
    let url: URL
    /// The display name: the viewer's title.
    let title: String
    /// The temp folder holding the named copy; nil when the stored file went out.
    let folder: URL?

    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentHandoff", isDirectory: true)

    /// `<display name>.<ext>` safe for a file name: no path separators or control characters, no leading dot, whitespace
    /// collapsed, at most 200 UTF-8 bytes before the extension, "Document" when nothing is left. A name that already
    /// ends with the extension keeps it once.
    static func fileName(_ display: String, ext: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        var base = display.components(separatedBy: banned).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while base.hasPrefix(".") { base.removeFirst() }
        while base.utf8.count > 200 { base.removeLast() }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Document" }
        let e = ext.lowercased()
        if e.isEmpty || base.lowercased().hasSuffix("." + e) { return base }
        return base + "." + e
    }

    static func make(for doc: DocumentItem, storedURL: URL) async -> DocumentHandoff {
        await make(id: doc.id, title: doc.displayName, ext: doc.fileType.isEmpty ? storedURL.pathExtension : doc.fileType,
                   storedURL: storedURL)
    }

    /// live-18 (0b) — a photo's or video's name when it leaves the gallery viewer: its own file name (the Photos picker's
    /// "IMG_4012", minus the extension), else "Photo · <date>" / "Video · <date>" (the date it was added).
    static func displayName(for item: GalleryItem) -> String {
        if let n = item.originalName.flatMap({ DocumentNaming.realName(suggested: $0, url: nil) }) {
            let base = (n as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty { return base }
        }
        return (item.mediaType == .video ? "Video" : "Photo") + " · " + item.capturedAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// live-18 (0b) — T (live-17 report): a photo shared from the gallery viewer went out as `<UUID>.jpg`. Now as
    /// `<displayName(for:)>.<stored ext>`, the same named-copy hand-off as a document.
    static func make(for item: GalleryItem, storedURL: URL) async -> DocumentHandoff {
        await make(id: item.id, title: displayName(for: item), ext: storedURL.pathExtension, storedURL: storedURL)
    }

    static func make(id: String, title: String, ext: String, storedURL: URL) async -> DocumentHandoff {
        let name = fileName(title, ext: ext)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(name)
        let ok: Bool = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: storedURL, to: copy)
                return true
            } catch {
                print("[DocHandoff] copy failed doc=\(id) — the stored file goes out: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: folder)
                return false
            }
        }.value
        return DocumentHandoff(documentID: id, url: ok ? copy : storedURL, title: title, folder: ok ? folder : nil)
    }

    /// Removes the named copy. Idempotent. While something still reads it (`hold`), the removal waits for the last
    /// reader to finish.
    func release() {
        guard let folder else { return }
        guard Holds.release(folder) else { return }
        try? FileManager.default.removeItem(at: folder)
        DocumentHandoffProbe.released(doc: documentID)
    }

    /// Sweep 2b · step 5 fix-up (verifier finding 6) — ⌘O in the viewer copies from the named copy in a task; Space
    /// straight after closed the viewer, whose dismantle removed the named copy first, so the copy failed and nothing
    /// opened. A reader holds the named copy for as long as it reads: take the hold BEFORE starting the task, `end()` it
    /// when done; a `release()` in between removes the folder at the end instead.
    struct Hold {
        fileprivate let handoff: DocumentHandoff
        func end() {
            guard let folder = handoff.folder, Holds.end(folder) else { return }
            try? FileManager.default.removeItem(at: folder)
            DocumentHandoffProbe.released(doc: handoff.documentID)
        }
    }
    func hold() -> Hold {
        if let folder { Holds.begin(folder) }
        return Hold(handoff: self)
    }

    /// The readers of each named copy, and the copies released while read. Thread-safe (the viewer's dismantle runs on
    /// the main thread, a reader's end wherever its task ends).
    private enum Holds {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var readers: [URL: Int] = [:]
        nonisolated(unsafe) private static var released: Set<URL> = []
        static func begin(_ f: URL) { lock.lock(); readers[f, default: 0] += 1; lock.unlock() }
        /// true = remove it now (nobody reads it)
        static func release(_ f: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if readers[f, default: 0] > 0 { released.insert(f); return false }
            return true
        }
        /// true = the last reader of a released copy: remove it now
        static func end(_ f: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let n = readers[f, default: 1] - 1
            if n > 0 { readers[f] = n; return false }
            readers[f] = nil
            return released.remove(f) != nil
        }
    }

    /// Clears every named copy (at launch: none can be in use).
    static func purgeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension CorpusStore {
    /// The document's hand-off for the viewer or the share sheet, or nil when its file can't be located.
    func documentHandoff(for doc: DocumentItem, nodeID: String) async -> DocumentHandoff? {
        guard let stored = await documentFileURL(for: doc, nodeID: nodeID) else { return nil }
        return await DocumentHandoff.make(for: doc, storedURL: stored)
    }
}

#if targetEnvironment(macCatalyst)
/// Sweep 1 · N4 [T] — a document item's three Mac actions: Quick Look (the in-app viewer), Open a COPY in its default
/// app, Reveal in Finder (the stored file, selected). Open hands over a copy by design (`design-refs/mac-sweep-1/
/// sheet-N4-open-in-app.md`): an edit made in the other app stays in that copy and never writes into the library outside
/// its own write path; the menu says "Open a Copy with <App>". Edit-in-place is held for T. AppKit through the runtime
/// (Catalyst has no NSWorkspace), on the main thread.
@MainActor
enum MacDocumentActions {
    private static var workspace: NSObject? {
        (NSClassFromString("NSWorkspace") as? NSObject.Type)?.perform(NSSelectorFromString("sharedWorkspace"))?
            .takeUnretainedValue() as? NSObject
    }

    /// The app that opens this file by default ("Preview"), nil when none.
    static func defaultAppName(for url: URL) -> String? {
        guard let ws = workspace,
              let app = ws.perform(NSSelectorFromString("URLForApplicationToOpenURL:"), with: url)?.takeUnretainedValue() as? URL
        else { return nil }
        return app.deletingPathExtension().lastPathComponent
    }

    static func reveal(_ url: URL) {
        _ = workspace?.perform(NSSelectorFromString("activateFileViewerSelectingURLs:"), with: [url] as NSArray)
    }

    /// Copies are kept in Application Support/Opened Copies/<id>/<name> — NOT the system's Caches, which macOS may purge
    /// while the other app still has the copy open or after an edit was saved into it (sweep 1 review; the v1.1 "replace
    /// the attachment with your edited version?" needs it kept). Copies older than a week that nobody changed go at
    /// launch (`purgeOldCopies`).
    nonisolated static let copiesRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Opened Copies", isDirectory: true)

    /// Sweep 2b · 4.4 (T, 11-22: "Open" opens a copy; no edits flow back) — the attachment's app is handed a COPY, never
    /// the stored file: an APFS clone (copy-on-write: an edit saved in the other app changes the clone only) under
    /// `copiesRoot`. The read is coordinated, so a file macOS evicted to iCloud downloads first instead of failing
    /// (T's "⌘O does nothing" could be that silent failure). If the copy can't be made, nothing is opened — the stored
    /// file is never handed out instead.
    static func openCopy(of stored: URL, named title: String, ext: String) async {
        guard let copy = await makeCopy(of: stored, named: title, ext: ext) else { return }
        _ = workspace?.perform(NSSelectorFromString("openURL:"), with: copy)
    }

    /// Sweep 2b · 4.4 — ⌘O in the Quick Look viewer: a copy of the shown item, made from the viewer's named copy
    /// (`makeCopy` copies again, so the stored file is never handed out). `launch: false` = make it only (self-test).
    /// The named copy is held until the copy is made (the viewer may close straight after ⌘O; verifier finding 6).
    @discardableResult
    static func openViewerItem(_ h: DocumentHandoff, launch: Bool = true) -> Task<URL?, Never> {
        let hold = h.hold()
        return Task {
            defer { hold.end() }
            guard let copy = await makeCopy(of: h.url, named: h.title, ext: h.url.pathExtension) else { return nil }
            if launch { _ = workspace?.perform(NSSelectorFromString("openURL:"), with: copy) }
            return copy
        }
    }

    /// The copy ⌘O hands out (nil when it can't be made: nothing is opened then).
    static func makeCopy(of stored: URL, named title: String, ext: String) async -> URL? {
        let name = DocumentHandoff.fileName(title, ext: ext)
        let folder = copiesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(name)
        let result: String? = await Task.detached(priority: .userInitiated) {
            var failure: String?
            var coordError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: stored, options: [.withoutChanges], error: &coordError) { u in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: u, to: copy)
                } catch { failure = (error as NSError).domain + " \((error as NSError).code)" }
            }
            if let coordError { failure = coordError.domain + " \(coordError.code)" }
            if failure != nil { try? FileManager.default.removeItem(at: folder) }
            return failure
        }.value
        if let result {
            MacProofLog.note("4.4", "open a copy FAILED (\(result)) — nothing opened, the stored file is never handed out")
            return nil
        }
        MacProofLog.note("4.4", "open a copy: .\(copy.pathExtension) in Opened Copies · stored file handed out: "
                         + "\(copy.standardizedFileURL.path == stored.standardizedFileURL.path ? "YES" : "no")")
        return copy
    }

    /// Off the main thread (sweep 2b · 4.4: was a main-actor folder walk at launch).
    nonisolated static func purgeOldCopies() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: copiesRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        // Only copies nobody changed (sweep 1 review: an edit saved into a copy must never vanish); not the system's Caches.
        for d in dirs {
            let made = (try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            guard made < cutoff else { continue }
            let files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            // Edited = changed after the copy was made: against the FOLDER's creation (an editor that saves by writing a
            // new file and renaming it gives the file a fresh creation date — sweep 1 review).
            let edited = files.contains { f in
                ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > made.addingTimeInterval(5)
            }
            if !edited { try? fm.removeItem(at: d) }
        }
    }
}

/// Sweep 1 · N4 — the keys for the document item under the pointer: Space = Quick Look, ⌘O = Open a Copy, ⌘⇧R = Reveal in
/// Finder. Taken where AppKit first sees the key (a local monitor), only while a document item is hovered and no text is
/// being edited (Space types a space in a note).
@MainActor
enum MacDocumentKeys {
    struct Actions { let quickLook: () -> Void; let open: () -> Void; let reveal: () -> Void }
    private static var hovered: (id: String, actions: Actions)?
    private static var monitor: AnyObject?
    /// Sweep 2b · 4.3 — while a Quick Look viewer is open (`MacViewerKeys`) the item under it doesn't take Space / ⌘O
    /// (Space closes the viewer); its hover is held here and handed back when the viewer closes.
    private static var viewerOpen = false
    private static var held: (id: String, actions: Actions)?

    static func hover(_ id: String, _ actions: Actions, _ on: Bool) {
        if on {
            if viewerOpen { held = (id, actions) } else { hovered = (id, actions); install() }
        } else {
            if hovered?.id == id { hovered = nil }
            if held?.id == id { held = nil }
        }
    }
    static func clear(_ id: String?) {
        if let id, hovered?.id == id { hovered = nil }
        if let id, held?.id == id { held = nil }
    }
    static func suspendForViewer() {
        viewerOpen = true
        if let h = hovered { held = h }
        hovered = nil
    }
    static func resumeAfterViewer() {
        viewerOpen = false
        if hovered == nil, let h = held { hovered = h; install() }
        held = nil
    }

    /// The class of the text input being edited (first responder), nil when none.
    private static func editingTextClass() -> String? {
        FirstResponderProbe.current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.airpadCaptureFirstResponder), to: nil, from: nil, for: nil)
        return FirstResponderProbe.current.flatMap { $0 is UITextInput ? String(describing: type(of: $0)) : nil }
    }

    private static func install() {
        guard monitor == nil, let cls: AnyClass = NSClassFromString("NSEvent") else { return }
        let sel = NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")
        guard let m = class_getClassMethod(cls, sel) else { return }
        typealias Add = @convention(c) (AnyClass, Selector, UInt64, @escaping @convention(block) (AnyObject) -> AnyObject?) -> AnyObject?
        let handler: @convention(block) (AnyObject) -> AnyObject? = { event in
            let code = (event.value(forKey: "keyCode") as? NSNumber)?.intValue ?? -1
            let flags = ((event.value(forKey: "modifierFlags") as? NSNumber)?.uintValue ?? 0) & (0xF << 17)
            let cmd: UInt = 1 << 20, shift: UInt = 1 << 17
            return MainActor.assumeIsolated {
                // Sweep 2b · 4.1 — only Space is a typing key: it belongs to a text field that is being edited (a click
                // outside a one-line field ends its editing first, `MacClickEndsFieldEditing`). ⌘O and ⌘⇧R type nothing,
                // so they act on the hovered item whatever holds focus (T's Mac: the toolbar search held them).
                switch (code, flags) {
                case (49, 0):                                                   // Space
                    guard let h = hovered else { return event }
                    if let editing = editingTextClass() {
                        MacProofLog.note("4.1", "space passes: typing in \(editing)")
                        return event
                    }
                    h.actions.quickLook(); return nil
                case (31, cmd):                                                 // ⌘O
                    guard let h = hovered else { return event }                 // (an open viewer: `MacViewerKeys`)
                    MacProofLog.note("4.1", "cmd-O opens a copy of \(h.id)")
                    h.actions.open(); return nil
                case (15, cmd | shift):                                         // ⌘⇧R
                    guard let h = hovered else { return event }
                    h.actions.reveal(); return nil
                default: return event
                }
            }
        }
        monitor = unsafeBitCast(method_getImplementation(m), to: Add.self)(cls, sel, 1 << 10, handler)
    }
}

/// The stored file and its default app for one document item (the menus read it; resolved off the menu, on appear).
@MainActor @Observable
final class MacDocumentState {
    var url: URL?
    var appName: String?
    var title = ""
    var ext = ""
    func open() { guard let url else { return }; Task { await MacDocumentActions.openCopy(of: url, named: title, ext: ext) } }
    func reveal() { if let url { MacDocumentActions.reveal(url) } }
}

/// "Open a Copy with <App>" and "Reveal in Finder", for a document item's ··· menu and right-click menu.
struct MacDocumentMenuItems: View {
    let state: MacDocumentState
    var body: some View {
        Button { state.open() } label: {
            Label(state.appName.map { "Open a Copy with \($0)" } ?? "Open a Copy", systemImage: "arrow.up.forward.app")
        }
        .disabled(state.url == nil)
        Button { state.reveal() } label: { Label("Reveal in Finder", systemImage: "folder") }
            .disabled(state.url == nil)
    }
}

extension View {
    /// Resolves the item's stored file + default app, takes the hover keys, and adds the right-click menu.
    /// Sweep 2b · 4.2 — with the "Space opens this" highlight, drawn on `cornerRadius` (the item's own shape).
    func macDocumentActions(_ state: MacDocumentState, doc: DocumentItem?, nodeID: String, cornerRadius: CGFloat = 12,
                            quickLook: @escaping () -> Void) -> some View {
        modifier(MacDocumentActionsModifier(state: state, doc: doc, nodeID: nodeID, cornerRadius: cornerRadius, quickLook: quickLook))
    }
}

private struct MacDocumentActionsModifier: ViewModifier {
    let state: MacDocumentState
    let doc: DocumentItem?
    let nodeID: String
    let cornerRadius: CGFloat
    let quickLook: () -> Void
    @Environment(CorpusStore.self) private var store

    func body(content: Content) -> some View {
        content
            .task(id: doc?.id) {
                guard let doc, let url = await store.documentFileURL(for: doc, nodeID: nodeID) else { return }
                state.url = url
                state.title = doc.displayName
                state.ext = doc.fileType.isEmpty ? url.pathExtension : doc.fileType
                state.appName = MacDocumentActions.defaultAppName(for: url)
            }
            .macSpaceHighlight(cornerRadius: cornerRadius, probe: "document \(doc?.id ?? "-")") { on in
                guard let id = doc?.id else { return }
                // Actions.quickLook runs only for Space (a click has its own gesture): it counts toward the ␣ hint.
                MacDocumentKeys.hover(id, .init(quickLook: {
                    MacSpaceHint.noteUsed()
                    MacProofLog.note("4.2", "space opens document \(id)")
                    quickLook()
                }, open: { state.open() }, reveal: { state.reveal() }), on)
            }
            .onDisappear { MacDocumentKeys.clear(doc?.id) }   // sweep 1 review: an entry closed under a still pointer
            .contextMenu {
                Button { quickLook() } label: { Label("Quick Look", systemImage: "eye") }
                MacDocumentMenuItems(state: state)
            }
            .help("Space: Quick Look · ⌘O: Open a Copy · ⌘⇧R: Reveal in Finder")
    }
}
#endif
