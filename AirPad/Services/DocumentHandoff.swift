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

    private static func make(id: String, title: String, ext: String, storedURL: URL) async -> DocumentHandoff {
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

    /// Removes the named copy. Idempotent.
    func release() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
        DocumentHandoffProbe.released(doc: documentID)
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

    /// Copies are kept in Caches/Opened Copies/<id>/<name> (the other app may still have them open after AirPad quits);
    /// copies older than a week go at launch (`purgeOldCopies`).
    static let copiesRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Opened Copies", isDirectory: true)

    static func openCopy(of stored: URL, named title: String, ext: String) async {
        let name = DocumentHandoff.fileName(title, ext: ext)
        let folder = copiesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(name)
        let ok: Bool = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: stored, to: copy)
                return true
            } catch { return false }
        }.value
        guard ok else { return }
        _ = workspace?.perform(NSSelectorFromString("openURL:"), with: copy)
    }

    static func purgeOldCopies() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: copiesRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        // Only copies nobody changed (sweep 1 review: an edit saved into a copy must never vanish); not the system's Caches.
        for d in dirs where ((try? d.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < cutoff {
            let files = (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? []
            let edited = files.contains { f in
                let v = try? f.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                return (v?.contentModificationDate ?? .distantPast) > (v?.creationDate ?? .distantPast).addingTimeInterval(5)
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

    static func hover(_ id: String, _ actions: Actions, _ on: Bool) {
        if on { hovered = (id, actions); install() } else if hovered?.id == id { hovered = nil }
    }
    static func clear(_ id: String?) { if let id, hovered?.id == id { hovered = nil } }

    private static func editingText() -> Bool {
        FirstResponderProbe.current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.airpadCaptureFirstResponder), to: nil, from: nil, for: nil)
        return FirstResponderProbe.current is UITextInput
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
                guard let h = hovered, !editingText() else { return event }
                switch (code, flags) {
                case (49, 0): h.actions.quickLook(); return nil                 // Space
                case (31, cmd): h.actions.open(); return nil                    // ⌘O
                case (15, cmd | shift): h.actions.reveal(); return nil          // ⌘⇧R
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
    func macDocumentActions(_ state: MacDocumentState, doc: DocumentItem?, nodeID: String,
                            quickLook: @escaping () -> Void) -> some View {
        modifier(MacDocumentActionsModifier(state: state, doc: doc, nodeID: nodeID, quickLook: quickLook))
    }
}

private struct MacDocumentActionsModifier: ViewModifier {
    let state: MacDocumentState
    let doc: DocumentItem?
    let nodeID: String
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
            .onHover { on in
                guard let id = doc?.id else { return }
                MacDocumentKeys.hover(id, .init(quickLook: quickLook, open: { state.open() }, reveal: { state.reveal() }), on)
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
