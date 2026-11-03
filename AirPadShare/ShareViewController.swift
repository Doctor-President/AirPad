import UIKit
import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication

private let appGroupID = "group.com.doctorpresident.airpad"

/// Brief CG (V1) — the app-row Share Extension.
///
/// Scope (T 2026-10-02): the share editor + the three action rows are deferred to 1.1, so the
/// app-row icon **saves directly** — "Quick Capture behaviour": it ingests every shared item into
/// ONE entry, shows a brief "Saved!" confirmation, and dismisses. No compose box.
///
/// Rules this encodes:
///  • Multi-item share → ONE entry (RULED: one share = one act). Every attachment becomes a
///    `NodeItem` inside a single staged node.
///  • Video / audio / files are copied BY FILE URL (`loadFileRepresentation`), never loaded into
///    memory — the extension heap is ~20 MB (CG0 audit).
///  • Naming happens in the APP on import (`enrichIfNeeded(.committed)` — the model is unavailable
///    in an extension). The extension writes only a placeholder title; `titleSource`/`summarySource`
///    stay nil so the gate re-authors on import (`EnrichmentGate.aspectNeedsOffer` keys on source).
///  • The extension never writes the Library — it stages an inbox record the app applies.
///
/// 1.1-C (C1) — AirPad's own sheet: Title (prefilled from the page title / file name / first line) · Note (optional) ·
/// Save to: New entry (default) / Existing entry (search + recents) · Save. Settings → Quick save brings back the
/// one-tap behaviour above. No AI here (C2): the entry is named and summarised when the app next opens, as before.
/// Face ID (1.1-A A6): the extension may ADD while AirPad is locked but never SHOW its content, so with Require Face ID
/// on, "Existing entry" asks for Face ID first (failed / unavailable → only New entry). Private entries never appear in
/// the list unless unlocked here.
final class ShareViewController: UIViewController {

    private var didFinish = false
    private var appearTime: Date?
    private let minVisible: TimeInterval = 0.7

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        if ShareShared.quickSave {
            view.backgroundColor = UIColor.black.withAlphaComponent(0.18)
            installCard()
        } else {
            view.backgroundColor = .clear
            installCompose()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard appearTime == nil else { return }
        appearTime = Date()
        if ShareShared.quickSave { ingestShare() } else { stageForCompose() }
    }

    // MARK: - The sheet (1.1-C, C1)

    private let model = ShareComposeModel()

    private func installCompose() {
        model.onCancel = { [weak self] in self?.cancelCompose() }
        model.onSave = { [weak self] in self?.saveCompose() }
        let host = UIHostingController(rootView: ShareComposeView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// Loads every shared item into a staging record (`inbox/<id>/items/`, not yet visible to the app: no JSON), then
    /// prefills the title.
    private func stageForCompose() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], !items.isEmpty else {
            model.loading = false; return
        }
        let recordID = model.recordID
        let now = Date()
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [(index: Int, item: NodeItem)] = []
        var position = 0
        var pageTitle: String?
        for extensionItem in items {
            if pageTitle == nil {
                let t = (extensionItem.attributedTitle?.string ?? extensionItem.attributedContentText?.string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let t, !t.isEmpty, t.count <= 200 { pageTitle = t }
            }
            for provider in (extensionItem.attachments ?? []) {
                let index = position
                position += 1
                group.enter()
                Self.loadItem(from: provider, nodeID: recordID, now: now) { nodeItem in
                    defer { group.leave() }
                    if let nodeItem { lock.lock(); collected.append((index, nodeItem)); lock.unlock() }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let ordered = collected.sorted { $0.index < $1.index }.map { $0.item }
            self.model.items = ordered
            let isLink = ordered.count == 1 && ordered.first?.type == .link
            let prefill = isLink ? (pageTitle ?? "") : Self.placeholderTitle(for: ordered)
            self.model.prefilledTitle = prefill
            if self.model.title.isEmpty { self.model.title = prefill }
            self.model.loading = false
        }
    }

    private func saveCompose() {
        let note = model.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        var items = model.items
        if !note.isEmpty {
            items.insert(NodeItem(id: UUID().uuidString, type: .text, createdAt: now, content: note, file: nil, description: nil,
                                  transcript: nil, durationSeconds: nil, url: nil, title: nil, preview: nil), at: 0)
        }
        let title = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.destination == .existing, let target = model.target {
            Self.stageAppend(ShareAppendRecord(target: target.id, items: items), recordID: model.recordID)
        } else if !items.isEmpty || !title.isEmpty {
            var node = Self.makeNode(id: model.recordID, createdAt: now, items: items)
            if !title.isEmpty { node.title = title }
            // A title the person typed (or changed) is theirs: naming on import keeps it.
            if !title.isEmpty && title != model.prefilledTitle { node.titleSource = .user }
            Self.stageNode(node)
        } else {
            Self.removeRecord(model.recordID)
        }
        model.saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finish() }
    }

    private func cancelCompose() {
        Self.removeRecord(model.recordID)
        guard !didFinish else { return }
        didFinish = true
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private static func removeRecord(_ id: String) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent("AirPad/inbox/\(id)"))
    }

    private static func stageAppend(_ rec: ShareAppendRecord, recordID: String) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let dir = container.appendingPathComponent("AirPad/inbox/\(recordID)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(rec) else { return }
        try? data.write(to: dir.appendingPathComponent(ShareAppendRecord.fileName), options: .atomic)
    }

    // MARK: - "Saved!" confirmation card

    private func installCard() {
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false

        let check = UIImageView(image: UIImage(systemName: "checkmark.circle",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 46, weight: .regular)))
        check.tintColor = .label
        check.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Saved!"
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [check, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(card)
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 128),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -24),
        ])

        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            card.alpha = 1
            card.transform = .identity
        }
    }

    // MARK: - Ingest

    private func ingestShare() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], !items.isEmpty else {
            finishAfterMinVisible()
            return
        }

        let nodeID = UUID().uuidString
        let now = Date()
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [(index: Int, item: NodeItem)] = []

        func add(_ item: NodeItem, at index: Int) {
            lock.lock(); collected.append((index, item)); lock.unlock()
        }

        // Preserve share order across async loads: assign each provider a position, sort at the end.
        var position = 0
        for extensionItem in items {
            for provider in (extensionItem.attachments ?? []) {
                let index = position
                position += 1
                group.enter()
                Self.loadItem(from: provider, nodeID: nodeID, now: now) { nodeItem in
                    defer { group.leave() }
                    if let nodeItem { add(nodeItem, at: index) }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let ordered = collected.sorted { $0.index < $1.index }.map { $0.item }
            if !ordered.isEmpty {
                Self.stageNode(Self.makeNode(id: nodeID, createdAt: now, items: ordered))
            }
            self.finishAfterMinVisible()
        }
    }

    /// Inspect a single provider and produce AT MOST ONE `NodeItem`. Priority (most specific first):
    /// movie → audio → image → web URL → generic file → plain text. File-backed kinds copy by URL;
    /// the copy runs SYNCHRONOUSLY inside the load callback because the vended temp URL is valid
    /// only for the duration of that block.
    private static func loadItem(from provider: NSItemProvider, nodeID: String, now: Date,
                                 completion: @escaping (NodeItem?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                completion(url.flatMap { makeFileItem(fromFileURL: $0, nodeID: nodeID, now: now, type: .video, description: nil) })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, _ in
                completion(url.flatMap { makeFileItem(fromFileURL: $0, nodeID: nodeID, now: now, type: .audio, description: nil) })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                completion(makeImageItem(from: item, nodeID: nodeID, now: now, suggestedName: provider.suggestedName))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                guard let url = item as? URL else { completion(nil); return }
                if url.isFileURL {
                    completion(makeFileItem(fromFileURL: url, nodeID: nodeID, now: now, type: .document,
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
                        completion((item as? String).map { makeTextItem(text: $0, now: now) })
                    }
                } else if let html {
                    completion(makeTextItem(text: TableConverter.htmlToText(html), now: now))
                } else {
                    completion(nil)
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                guard let text = item as? String else { completion(nil); return }
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
                    completion(makeFileItem(fromFileURL: url, nodeID: nodeID, now: now, type: .document,
                                            description: DocumentNaming.realName(suggested: provider.suggestedName, url: url)))
                }
            }
        } else {
            completion(nil)
        }
    }

    // MARK: - NodeItem factories

    private static func makeLinkItem(url: URL, now: Date) -> NodeItem {
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

    private static func makeTextItem(text: String, now: Date) -> NodeItem {
        NodeItem(
            id: UUID().uuidString, type: .text, createdAt: now, content: text, file: nil,
            description: nil, transcript: nil, durationSeconds: nil, url: nil, title: nil, preview: nil
        )
    }

    private static func makeImageItem(from item: NSSecureCoding?, nodeID: String, now: Date, suggestedName: String?) -> NodeItem? {
        var data: Data?
        if let url = item as? URL { data = try? Data(contentsOf: url) }
        else if let image = item as? UIImage { data = image.jpegData(compressionQuality: 0.85) }
        guard let data else { return nil }
        let itemID = UUID().uuidString
        stageMedia(nodeID: nodeID, itemID: itemID, data: data, ext: "jpg")
        return ShareImportItems.imageItem(itemID: itemID, ext: "jpg", suggestedName: suggestedName,
                                          sourceURL: item as? URL, now: now)
    }

    /// Video / audio / documents — copied by file URL, never read into memory.
    private static func makeFileItem(fromFileURL fileURL: URL, nodeID: String, now: Date,
                                     type: NodeItemType, description: String?) -> NodeItem? {
        let itemID = UUID().uuidString
        let ext = fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension.lowercased()
        guard stageMediaCopy(nodeID: nodeID, itemID: itemID, from: fileURL, ext: ext) else { return nil }
        return NodeItem(
            id: itemID, type: type, createdAt: now, content: nil, file: "items/\(itemID).\(ext)",
            description: description, transcript: nil, durationSeconds: nil, url: nil, title: nil, preview: nil
        )
    }

    private static func makeNode(id: String, createdAt: Date, items: [NodeItem]) -> Node {
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
    private static func placeholderTitle(for items: [NodeItem]) -> String {
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

    // MARK: - Staging (App Group inbox)

    /// Writes one node JSON to `AirPad/inbox/{id}/node.json`. The app imports it on next launch /
    /// foreground and applies it to the Library (one writer per entry).
    private static func stageNode(_ node: Node) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }

        let nodeDir = container.appendingPathComponent("AirPad/inbox/\(node.id)")
        try? FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(node) else { return }
        try? data.write(to: nodeDir.appendingPathComponent("node.json"), options: .atomic)
    }

    private static func stageMedia(nodeID: String, itemID: String, data: Data, ext: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }
        let itemsDir = container.appendingPathComponent("AirPad/inbox/\(nodeID)/items")
        try? FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        try? data.write(to: itemsDir.appendingPathComponent("\(itemID).\(ext)"), options: .atomic)
    }

    /// Copy a file-backed attachment into the inbox WITHOUT loading it into memory. Runs inside the
    /// provider's load callback (the source URL is only valid there). Falls back to a Data write for
    /// tiny files if the copy fails.
    private static func stageMediaCopy(nodeID: String, itemID: String, from fileURL: URL, ext: String) -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return false }
        let itemsDir = container.appendingPathComponent("AirPad/inbox/\(nodeID)/items")
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

    // MARK: - Dismiss

    private func finishAfterMinVisible() {
        let elapsed = appearTime.map { Date().timeIntervalSince($0) } ?? minVisible
        let remaining = max(0, minVisible - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
