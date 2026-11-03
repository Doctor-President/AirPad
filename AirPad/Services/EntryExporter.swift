import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 1.1-C (C5) — export an entry as standard Markdown, the format its notes are already stored in:
/// - **Markdown (.md):** the text alone (tables as GFM pipe tables, checklists as `- [ ]`); images and files left out.
/// - **TextBundle (.textpack):** the .md + an `assets/` folder with the entry's images and files, zipped the way the
///   TextBundle spec packs it (Bear and iA Writer open it).
/// Both go out through the system share sheet (which has Save to Files).
/// - **Save to folder… (1.1-C fix-up (3)):** the .md, plus its images and files in an `attachments/` subfolder with
///   relative links, written straight into a folder the user picks (their Obsidian vault: a vault is just a folder of .md
///   files, and Obsidian can't import a zip). The folder is remembered (`PickedFolder`); a name clash adds " 2".
/// A private entry exports only while private entries are showing. Tables go through `TableConverter` (the same converter as paste and the share sheet).
@MainActor
enum EntryExporter {
    enum Format: String, CaseIterable, Identifiable {
        case markdown, textBundle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .markdown: "Markdown (.md)"
            case .textBundle: "TextBundle (.textpack)"
            }
        }
        var detail: String {
            switch self {
            case .markdown: "The text only. Opens in any Markdown app."
            case .textBundle: "The text with its images and files. Opens in Bear and iA Writer."
            }
        }
    }

    struct Asset: Equatable { let source: URL?; let name: String }

    /// The remembered "Save to folder…" folder.
    static let folder = PickedFolder(key: "export.folder.v1")

    #if DEBUG
    /// UI tests: `-ExportFolderSeed` remembers a fresh Documents/ExportSeed (the system folder picker isn't driven).
    private static var seeded = false
    static func debugSeedFolder() {
        guard !seeded, ProcessInfo.processInfo.arguments.contains("-ExportFolderSeed"),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("ExportSeed", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? folder.remember(dir)
        seeded = true
    }
    #endif

    /// The entry as Markdown + the files it points at (`<assetDir>/<name>`). `withAssets: false` drops images and files.
    /// Pure but for the file lookups the caller resolves (`fileFor`). The folder export names its files after the note
    /// (`assetPrefix`) and skips names already in its attachments folder (`taken`, " 2").
    static func markdown(for node: Node, withAssets: Bool, assetDir: String = "assets", assetPrefix: String = "",
                         taken: (String) -> Bool = { _ in false },
                         fileFor: (NodeItem, GalleryItem?) -> URL?) -> (text: String, assets: [Asset]) {
        var out: [String] = []
        var assets: [Asset] = []
        var used = Set<String>()
        func assetName(_ base: String, _ ext: String) -> String {
            let stem = assetPrefix + (sanitize(base).isEmpty ? "file" : sanitize(base))
            var s = stem, k = 2
            while used.contains("\(s).\(ext)".lowercased()) { s = "\(stem)-\(k)"; k += 1 }
            let n = PickedFolder.freeName(s, ext: ext, taken: taken)
            used.insert(n.lowercased())
            return n
        }
        func addFile(_ url: URL?, base: String, fallbackExt: String) -> String? {
            guard withAssets else { return nil }
            let ext = (url?.pathExtension).flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? fallbackExt
            let name = assetName(base, ext)
            assets.append(Asset(source: url, name: name))
            return assetDir + "/" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        }
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { out.append("# " + title) }
        let inlineIDs = Set(node.items.compactMap { $0.type == .text ? $0.content : nil }
            .flatMap { MarkdownCodec.referencedImageItemIDs(in: $0) })
        var imageCount = 0
        for item in node.items {
            switch item.type {
            case .text:
                guard var md = item.content, !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                // Inline images → real files beside the .md (or out, for the .md alone).
                for id in MarkdownCodec.referencedImageItemIDs(in: md) {
                    let token = MarkdownCodec.imageToken(itemID: id)
                    if let img = node.items.first(where: { $0.id == id }) {
                        imageCount += 1
                        let g = img.mediaItems?.first
                        let link = addFile(fileFor(img, g), base: "image-\(imageCount)", fallbackExt: "jpg")
                        md = md.replacingOccurrences(of: token, with: link.map { "![](\($0))" } ?? "")
                    } else {
                        md = md.replacingOccurrences(of: token, with: "")
                    }
                }
                out.append(standardMarkdown(md))
            case .imageVideo, .image, .video:
                guard !inlineIDs.contains(item.id) else { continue }
                let media = item.mediaItems ?? []
                if media.isEmpty, let link = addFile(fileFor(item, nil), base: "image-\(imageCount + 1)", fallbackExt: item.type == .video ? "mov" : "jpg") {
                    imageCount += 1
                    out.append(item.type == .video ? "[Video](\(link))" : "![](\(link))")
                }
                for g in media {
                    imageCount += 1
                    guard let link = addFile(fileFor(item, g), base: "\(g.mediaType == .video ? "video" : "image")-\(imageCount)",
                                             fallbackExt: g.mediaType == .video ? "mov" : "jpg") else { continue }
                    out.append(g.mediaType == .video ? "[Video](\(link))" : "![](\(link))")
                }
            case .link:
                guard let url = item.url, !url.isEmpty else { continue }
                let label = (item.title?.isEmpty == false ? item.title! : url).replacingOccurrences(of: "]", with: "\\]")
                out.append("[\(label)](\(url))")
            case .document, .audio:
                let name = (item.description?.isEmpty == false ? item.description! : (item.type == .audio ? "Recording" : "Document"))
                if let link = addFile(fileFor(item, nil), base: (name as NSString).deletingPathExtension,
                                      fallbackExt: item.type == .audio ? "m4a" : "pdf") {
                    out.append("[\(name)](\(link))")
                }
                if item.type == .audio, let t = item.transcript, !t.isEmpty { out.append(t) }
            default:
                continue
            }
        }
        return (out.joined(separator: "\n\n") + "\n", assets)
    }

    /// The stored note text as standard Markdown: the editor's escaped checkboxes (`- \[ ]`) read as `- [ ]`, and every
    /// table in canonical GFM (one converter).
    static func standardMarkdown(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"^(\s*(?:[-*+]|\d{1,3}[.)])\s+)\\\[([ xX])\\?\]"#, with: "$1[$2]", options: .regularExpression)
        }
        // A blank line around each table: some Markdown apps (Obsidian) only see a table that starts a block.
        var segs = TableConverter.splitGFM(lines.joined(separator: "\n"))
        for k in segs.indices {
            guard case .text(var t) = segs[k] else { continue }
            if k > 0, case .table = segs[k - 1], !t.hasPrefix("\n\n") { t = "\n" + t }
            if k + 1 < segs.count, case .table = segs[k + 1], !t.hasSuffix("\n\n") { t += "\n" }
            segs[k] = .text(t)
        }
        return TableConverter.join(segs)
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t").union(.controlCharacters)
        return s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            .prefix(80).description
    }

    static func baseName(_ node: Node) -> String {
        let t = sanitize(node.title)
        return t.isEmpty ? "AirPad entry" : t
    }

    /// Every file the entry points at (key: item id / gallery id), resolved before building (async lookups).
    private static func resolveFiles(_ node: Node, store: CorpusStore) async -> [String: URL] {
        var files: [String: URL] = [:]
        for item in node.items {
            if let media = item.mediaItems, !media.isEmpty {
                for g in media { files[g.id] = await store.resolveGalleryItemURL(g, nodeID: node.id, fallbackParentItem: item) }
            } else if item.file != nil {
                files[item.id] = await store.itemFileURL(for: item, nodeID: node.id)
            }
        }
        return files
    }

    /// Save to folder… — writes `<name>.md` (or `<name> 2.md` …) into `folder`, and its images and files into
    /// `folder/attachments/` (created only when there are any), linked relatively. Returns the .md's file name.
    static func save(_ node: Node, toFolder folder: URL, store: CorpusStore) async throws -> String {
        let files = await resolveFiles(node, store: store)
        return try PickedFolder.write(into: folder) { dir in
            try writeNote(node, into: dir) { item, g in files[g?.id ?? item.id] }
        }
    }

    /// The folder export's file work, given folder access (also run by the self-test on a scratch folder).
    static func writeNote(_ node: Node, into dir: URL, fileFor: (NodeItem, GalleryItem?) -> URL?) throws -> String {
        let fm = FileManager.default
        func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
        let mdName = PickedFolder.freeName(baseName(node), ext: "md") { exists(dir.appendingPathComponent($0)) }
        let att = dir.appendingPathComponent("attachments", isDirectory: true)
        let built = markdown(for: node, withAssets: true, assetDir: "attachments",
                             assetPrefix: (mdName as NSString).deletingPathExtension + " ",
                             taken: { exists(att.appendingPathComponent($0)) }, fileFor: fileFor)
        try built.text.write(to: dir.appendingPathComponent(mdName), atomically: true, encoding: .utf8)
        let copies = built.assets.filter { $0.source != nil }
        if !copies.isEmpty {
            try fm.createDirectory(at: att, withIntermediateDirectories: true)
            for a in copies { try? fm.copyItem(at: a.source!, to: att.appendingPathComponent(a.name)) }
        }
        return mdName
    }

    /// Writes the export into a fresh temp folder and returns the URL to share.
    static func write(_ node: Node, format: Format, store: CorpusStore) async throws -> URL {
        let files = await resolveFiles(node, store: store)
        let built = markdown(for: node, withAssets: format != .markdown) { item, g in files[g?.id ?? item.id] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = baseName(node)
        switch format {
        case .markdown:
            let url = root.appendingPathComponent(name + ".md")
            try built.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        case .textBundle:
            let bundle = root.appendingPathComponent(name + ".textbundle", isDirectory: true)
            try writeFolder(at: bundle, mdName: "text.md", text: built.text, assets: built.assets)
            let info = #"{"version":2,"type":"net.daringfireball.markdown","transient":false,"creatorIdentifier":"com.doctorpresident.airpad"}"#
            try info.write(to: bundle.appendingPathComponent("info.json"), atomically: true, encoding: .utf8)
            return try zip(bundle, as: name + ".textpack", in: root)
        }
    }

    private static func writeFolder(at dir: URL, mdName: String, text: String, assets: [Asset]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(mdName), atomically: true, encoding: .utf8)
        guard !assets.isEmpty else { return }
        let a = dir.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        for asset in assets {
            guard let src = asset.source else { continue }
            try? fm.copyItem(at: src, to: a.appendingPathComponent(asset.name))
        }
    }

    /// A folder → one .zip (the system's own archiver: a coordinated read "for uploading" vends a zip of a folder).
    private static func zip(_ dir: URL, as fileName: String, in root: URL) throws -> URL {
        var made: URL?
        var copyError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zipped in
            let dest = root.appendingPathComponent(fileName)
            do { try FileManager.default.copyItem(at: zipped, to: dest); made = dest } catch { copyError = error }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        guard let made else { throw CocoaError(.fileWriteUnknown) }
        return made
    }
}

/// The entry menu's Export sheet: pick a format, then the system share sheet (Save to Files, AirDrop, other apps); or
/// Save to folder…, which writes into a picked folder (offered first once one is remembered, with Change folder…).
struct EntryExportSheet: View {
    let nodeID: String
    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appBodyFont) private var appFont
    @State private var working: EntryExporter.Format?
    @State private var shareURL: URL?
    @State private var failed = false
    @State private var picking = false
    @State private var folderName = EntryExporter.folder.name
    @State private var saved: String?        // "Saved “X.md” to Vault."
    @State private var folderFailed = false

    private var node: Node? { store.nodes.first { $0.id == nodeID } }
    private var hasFiles: Bool {
        node?.items.contains { $0.file != nil || !($0.mediaItems ?? []).isEmpty } ?? false
    }

    var body: some View {
        NavigationStack {
            List {
                if let node, !store.isHidden(node) {
                    if folderName != nil { folderRows(node) }
                    Section { ForEach(EntryExporter.Format.allCases) { f in
                        Button { export(node, f) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(f.label).font(appFont.font(size: 16, weight: .medium, relativeTo: .body))
                                        .foregroundStyle(AppearancePalette.ink)
                                    if working == f { Spacer(); ProgressView() }
                                }
                                Text(f == .markdown && hasFiles ? f.detail + " Images and files are left out." : f.detail)
                                    .font(appFont.font(size: 13, relativeTo: .footnote))
                                    .foregroundStyle(AppearancePalette.ink.opacity(0.55))
                            }
                        }
                        .disabled(working != nil)
                        .accessibilityIdentifier("export.\(f.rawValue)")
                    }
                    if failed {
                        Text("Couldn't export this entry.").font(appFont.font(size: 13, relativeTo: .footnote)).foregroundStyle(.red)
                    } }
                    if folderName == nil { folderRows(node) }
                } else {
                    Text("This entry is private.").foregroundStyle(AppearancePalette.ink.opacity(0.6))
                }
            }
            // The system folder picker (a UIDocumentPickerViewController). On the List, not beside the share sheet's
            // `.sheet` below: two presentations stacked on one view closed this sheet when the share sheet opened.
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result, let node else { return }
                do { try EntryExporter.folder.remember(url) } catch { folderFailed = true; return }
                folderName = EntryExporter.folder.name
                saveToFolder(node)
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            shown = true
            #if DEBUG
            EntryExporter.debugSeedFolder()
            #endif
            folderName = EntryExporter.folder.name
        }
        .onDisappear { shown = false }
        .sheet(item: Binding(get: { shareURL.map(ShareTarget.init) }, set: { if $0 == nil { shareURL = nil } })) { t in
            ActivityShareView(items: [t.url]).ignoresSafeArea()
        }
    }

    /// Save to folder…: the remembered folder first, with Change folder…; or the picker when none is remembered.
    @ViewBuilder private func folderRows(_ node: Node) -> some View {
        Section {
            if let folderName {
                row(label: "Save to “\(folderName)”", detail: "The .md, with its images and files in attachments/.", busy: savingFolder) {
                    saveToFolder(node)
                }
                .accessibilityIdentifier("export.saveToFolder")
                Button("Change folder…") { picking = true }
                    .font(appFont.font(size: 15, relativeTo: .subheadline))
                    .disabled(savingFolder)
                    .accessibilityIdentifier("export.changeFolder")
            } else {
                row(label: "Save to folder…", detail: "Into a folder in Files, like your Obsidian vault. Images and files go in attachments/.",
                    busy: false) { picking = true }
                    .accessibilityIdentifier("export.saveToFolder")
            }
            if let saved {
                Text(saved).font(appFont.font(size: 13, relativeTo: .footnote)).foregroundStyle(AppearancePalette.ink.opacity(0.7))
                    .accessibilityIdentifier("export.saved")
            }
            if folderFailed {
                Text("Couldn't save to that folder. Pick it again with Change folder….")
                    .font(appFont.font(size: 13, relativeTo: .footnote)).foregroundStyle(.red)
            }
        }
    }
    @State private var savingFolder = false

    private func row(label: String, detail: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label).font(appFont.font(size: 16, weight: .medium, relativeTo: .body)).foregroundStyle(AppearancePalette.ink)
                    if busy { Spacer(); ProgressView() }
                }
                Text(detail).font(appFont.font(size: 13, relativeTo: .footnote)).foregroundStyle(AppearancePalette.ink.opacity(0.55))
            }
        }
        .disabled(working != nil || savingFolder)
    }

    private func saveToFolder(_ node: Node) {
        guard let url = EntryExporter.folder.url else { folderName = nil; picking = true; return }
        savingFolder = true; saved = nil; folderFailed = false
        Task {
            do {
                let name = try await EntryExporter.save(node, toFolder: url, store: store)
                saved = "Saved “\(name)” to \(EntryExporter.folder.name ?? "the folder")."
            } catch { folderFailed = true }
            savingFolder = false
        }
    }

    private func export(_ node: Node, _ f: EntryExporter.Format) {
        working = f; failed = false
        Task {
            do {
                let url = try await EntryExporter.write(node, format: f, store: store)
                // Closed while the file was being made: no share sheet (one presented from a closing sheet is orphaned
                // and can't be closed).
                if shown { shareURL = url }
            } catch { failed = true }
            working = nil
        }
    }
    @State private var shown = false

    private struct ShareTarget: Identifiable { let url: URL; var id: String { url.path } }
}

/// UIActivityViewController for SwiftUI.
struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
