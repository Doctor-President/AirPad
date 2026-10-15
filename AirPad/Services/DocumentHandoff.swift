import Foundation

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
        let title = doc.displayName
        let ext = doc.fileType.isEmpty ? storedURL.pathExtension : doc.fileType
        let name = fileName(title, ext: ext)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(name)
        let ok: Bool = await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: storedURL, to: copy)
                return true
            } catch {
                print("[DocHandoff] copy failed doc=\(doc.id) — the stored file goes out: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: folder)
                return false
            }
        }.value
        return DocumentHandoff(documentID: doc.id, url: ok ? copy : storedURL, title: title, folder: ok ? folder : nil)
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
