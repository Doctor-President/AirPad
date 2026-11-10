import UIKit
import UniformTypeIdentifiers

/// Mac batch C4 — what a share stages, in one place: the share extension (into the App Group inbox) and the app's
/// drag-and-drop import (into its own staging folder) build the SAME `NodeItem`s and staged files from an
/// `NSItemProvider`. Moved verbatim from `ShareViewController` (Brief CG / 1.1-C); only the inbox folder is a parameter.
/// Compiled into the app and the share extension (`AirPad/Models`).
enum ShareItemLoader {
    /// The App Group inbox the share extension stages into (`AirPad/inbox`).
    static var appGroupInbox: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.doctorpresident.airpad")?
            .appendingPathComponent("AirPad/inbox")
    }

    /// Inspect a single provider and produce AT MOST ONE `NodeItem`. Priority (most specific first):
    /// movie → audio → image → web URL → generic file → plain text. File-backed kinds copy by URL;
    /// the copy runs SYNCHRONOUSLY inside the load callback because the vended temp URL is valid
    /// only for the duration of that block.
    static func loadItem(from provider: NSItemProvider, nodeID: String, now: Date, inbox: URL,
                         completion: @escaping (NodeItem?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                completion(url.flatMap { makeFileItem(fromFileURL: $0, nodeID: nodeID, now: now, inbox: inbox, type: .video, description: nil) })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _ in
                completion(url.flatMap { makeFileItem(fromFileURL: $0, nodeID: nodeID, now: now, inbox: inbox, type: .audio, description: nil) })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                completion(makeImageItem(from: item, nodeID: nodeID, now: now, inbox: inbox, suggestedName: provider.suggestedName))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                guard let url = asURL(item) else { completion(nil); return }
                if url.isFileURL {
                    completion(makeFileItem(fromFileURL: url, nodeID: nodeID, now: now, inbox: inbox, type: .document,
                                            description: DocumentNaming.realName(suggested: provider.suggestedName, url: url)))
                } else {
                    completion(makeLinkItem(url: url, now: now))
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
            // 1.1-C (C1 / C6) — shared HTML with a table: prose + GFM tables through the one table converter.
            provider.loadDataRepresentation(forTypeIdentifier: UTType.html.identifier) { data, _ in
                let html = data.flatMap { String(data: $0, encoding: .utf8) }
                if let html, let segs = TableConverter.segments(html: html, text: nil) {
                    completion(makeTextItem(text: TableConverter.join(segs), now: now))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in   // no table: the text, as before
                        completion(asText(item).map { makeTextItem(text: $0, now: now) })
                    }
                } else if let html {
                    completion(makeTextItem(text: TableConverter.htmlToText(html), now: now))
                } else {
                    completion(nil)
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                guard let text = asText(item) else { completion(nil); return }
                // 1.1-C (C6) — tab-separated / CSV text becomes a GFM table (pipe tables already are one).
                if let segs = TableConverter.segments(html: nil, text: text) {
                    completion(makeTextItem(text: TableConverter.join(segs), now: now))
                } else {
                    completion(makeTextItem(text: text, now: now))
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                guard let url else { completion(nil); return }
                let ext = url.pathExtension.lowercased()
                // A shared text file folds into ONE text item (one share = one entry), rather than
                // batch-splitting into many nodes — the share sheet is not the batch-import channel.
                if (ext == "txt" || ext == "md"), let content = try? String(contentsOf: url, encoding: .utf8) {
                    completion(makeTextItem(text: content, now: now))
                } else {
                    // live-13 (4) — the document's real name: the provider's suggested name, else the vended file's
                    // (a temp/UUID one is no name — the app then shows the PDF title or the date).
                    completion(makeFileItem(fromFileURL: url, nodeID: nodeID, now: now, inbox: inbox, type: .document,
                                            description: DocumentNaming.realName(suggested: provider.suggestedName, url: url)))
                }
            }
        } else {
            completion(nil)
        }
    }

    // MARK: - NodeItem factories

    /// Mac batch C4 — a drag hands over the same types as `Data` (or a `String`) where a share sheet hands over
    /// `URL` / `String`; accept both.
    static func asURL(_ item: NSSecureCoding?) -> URL? {
        if let u = item as? URL { return u }
        if let d = item as? Data { return URL(dataRepresentation: d, relativeTo: nil) }
        if let s = item as? String { return URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func asText(_ item: NSSecureCoding?) -> String? {
        if let s = item as? String { return s }
        if let a = item as? NSAttributedString { return a.string }
        if let d = item as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }

    static func makeLinkItem(url: URL, now: Date) -> NodeItem {
        // Brief CG — leave `title` NIL (not the URL host). The in-app Link path keeps a bare link's
        // title empty until OG lands; the host placeholder made an imported link read as having
        // content, so the FM named it "Wayfair.com" and the OG page-title path never engaged. Nil
        // → the import enrich hits `.noContent` → `pendingLinkAuthor` → `applyOGFetch` commits the
        // page-title ghost, exactly as the in-app link capture does.
        NodeItem(
            id: UUID().uuidString, type: .link, createdAt: now, content: nil, file: nil,
            description: nil, transcript: nil, durationSeconds: nil,
            url: url.absoluteString, title: nil, preview: nil
        )
    }

    static func makeTextItem(text: String, now: Date) -> NodeItem {
        NodeItem(
            id: UUID().uuidString, type: .text, createdAt: now, content: text, file: nil,
            description: nil, transcript: nil, durationSeconds: nil, url: nil, title: nil, preview: nil
        )
    }

    static func makeImageItem(from item: NSSecureCoding?, nodeID: String, now: Date, inbox: URL, suggestedName: String?) -> NodeItem? {
        var data: Data?
        if let url = item as? URL { data = try? Data(contentsOf: url) }
        else if let image = item as? UIImage { data = image.jpegData(compressionQuality: 0.85) }
        else if let d = item as? Data, let image = UIImage(data: d) { data = image.jpegData(compressionQuality: 0.85) }   // C4: a drag
        guard let data else { return nil }
        let itemID = UUID().uuidString
        stageMedia(inbox: inbox, nodeID: nodeID, itemID: itemID, data: data, ext: "jpg")
        return ShareImportItems.imageItem(itemID: itemID, ext: "jpg", suggestedName: suggestedName,
                                          sourceURL: item as? URL, now: now)
    }

    /// Video / audio / documents — copied by file URL, never read into memory.
    static func makeFileItem(fromFileURL fileURL: URL, nodeID: String, now: Date, inbox: URL,
                                     type: NodeItemType, description: String?) -> NodeItem? {
        let itemID = UUID().uuidString
        let ext = fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension.lowercased()
        guard stageMediaCopy(inbox: inbox, nodeID: nodeID, itemID: itemID, from: fileURL, ext: ext) else { return nil }
        return NodeItem(
            id: itemID, type: type, createdAt: now, content: nil, file: "items/\(itemID).\(ext)",
            description: description, transcript: nil, durationSeconds: nil, url: nil, title: nil, preview: nil
        )
    }

    static func makeNode(id: String, createdAt: Date, items: [NodeItem]) -> Node {
        Node(
            id: id,
            createdAt: createdAt,
            updatedAt: createdAt,
            title: placeholderTitle(for: items),
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            items: items,
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: true
        )
    }

    /// A placeholder only — the app RE-DERIVES the title on import and the placeholder must not
    /// block that: a link names from its page title, photos/videos from a dated fallback, audio
    /// from its transcript — all keyed on an EMPTY (or generic) title + nil `titleSource`. So the
    /// only content-y placeholders left are text (its own words) and a document (its filename),
    /// the two rows that already named well on import. "Shared items" is gone: it was not in the
    /// photo namer's placeholder set, so it stuck.
    static func placeholderTitle(for items: [NodeItem]) -> String {
        guard items.count == 1, let first = items.first else { return "" }
        switch first.type {
        // live-29 (B4) — shared Markdown (Bear, Obsidian…) never titles an entry "### Heading": the first line, plain.
        case .text:
            let firstLine = (first.content ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let plain = firstLine.replacingOccurrences(of: #"^[\s>]*(#{1,6}\s*|[-*+•]\s+)?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            return String(plain.trimmingCharacters(in: .whitespaces).prefix(40))
        case .document: return (first.description as NSString?)?.deletingPathExtension ?? ""
        default:        return ""   // link, image, video, audio → named on import
        }
    }

    static func stageMedia(inbox: URL, nodeID: String, itemID: String, data: Data, ext: String) {
        let itemsDir = inbox.appendingPathComponent("\(nodeID)/items")
        try? FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        try? data.write(to: itemsDir.appendingPathComponent("\(itemID).\(ext)"), options: .atomic)
    }

    /// Copy a file-backed attachment into the inbox WITHOUT loading it into memory. Runs inside the
    /// provider's load callback (the source URL is only valid there). Falls back to a Data write for
    /// tiny files if the copy fails.
    static func stageMediaCopy(inbox: URL, nodeID: String, itemID: String, from fileURL: URL, ext: String) -> Bool {
        let itemsDir = inbox.appendingPathComponent("\(nodeID)/items")
        try? FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        let dest = itemsDir.appendingPathComponent("\(itemID).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: fileURL, to: dest)
            return true
        } catch {
            if let data = try? Data(contentsOf: fileURL) {
                try? data.write(to: dest, options: .atomic)
                return true
            }
            return false
        }
    }
}
