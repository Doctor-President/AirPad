import UIKit
import UniformTypeIdentifiers

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
final class ShareViewController: UIViewController {

    private var didFinish = false
    private var appearTime: Date?
    private let minVisible: TimeInterval = 0.7

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        installCard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard appearTime == nil else { return }
        appearTime = Date()
        ingestShare()
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
                completion(makeImageItem(from: item, nodeID: nodeID, now: now))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                guard let url = item as? URL else { completion(nil); return }
                if url.isFileURL {
                    completion(makeFileItem(fromFileURL: url, nodeID: nodeID, now: now, type: .document, description: url.lastPathComponent))
                } else {
                    completion(makeLinkItem(url: url, now: now))
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                guard let text = item as? String else { completion(nil); return }
                completion(makeTextItem(text: text, now: now))
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
                    completion(makeFileItem(fromFileURL: url, nodeID: nodeID, now: now, type: .document, description: url.lastPathComponent))
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

    private static func makeImageItem(from item: NSSecureCoding?, nodeID: String, now: Date) -> NodeItem? {
        var data: Data?
        if let url = item as? URL { data = try? Data(contentsOf: url) }
        else if let image = item as? UIImage { data = image.jpegData(compressionQuality: 0.85) }
        guard let data else { return nil }
        let itemID = UUID().uuidString
        stageMedia(nodeID: nodeID, itemID: itemID, data: data, ext: "jpg")
        return NodeItem(
            id: itemID, type: .image, createdAt: now, content: nil, file: "items/\(itemID).jpg",
            description: nil, transcript: nil, durationSeconds: nil, url: nil, title: nil, preview: nil
        )
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
        case .text:     return String((first.content ?? "").prefix(40))
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
