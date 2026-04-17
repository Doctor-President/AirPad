import UIKit
import Social
import UniformTypeIdentifiers

private let appGroupID = "group.com.doctorpresident.airpad"

final class ShareViewController: SLComposeServiceViewController {

    override func isContentValid() -> Bool {
        true
    }

    override func didSelectPost() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }

        let group = DispatchGroup()
        var nodes: [Node] = []

        for extensionItem in items {
            for provider in (extensionItem.attachments ?? []) {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                        defer { group.leave() }
                        guard let url = item as? URL else { return }
                        nodes.append(Self.makeURLNode(url: url))
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                        defer { group.leave() }
                        if let url = item as? URL, let data = try? Data(contentsOf: url) {
                            nodes.append(Self.makeImageNode(data: data))
                        } else if let image = item as? UIImage,
                                  let data = image.jpegData(compressionQuality: 0.85) {
                            nodes.append(Self.makeImageNode(data: data))
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                        defer { group.leave() }
                        guard let text = item as? String else { return }
                        nodes.append(Self.makeTextNode(text: text))
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.data.identifier) { item, _ in
                        defer { group.leave() }
                        guard let url = item as? URL else { return }
                        let ext = url.pathExtension.lowercased()
                        if (ext == "txt" || ext == "md"),
                           let content = try? String(contentsOf: url, encoding: .utf8) {
                            nodes.append(contentsOf: Self.makeBatchNodes(text: content))
                        } else {
                            nodes.append(Self.makeDocumentNode(fileURL: url))
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            for node in nodes {
                Self.stageNode(node)
            }
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    override func configurationItems() -> [Any]! {
        []
    }

    // MARK: - Node factories

    private static func makeURLNode(url: URL) -> Node {
        let now = Date()
        let item = NodeItem(
            id: UUID().uuidString,
            type: .link,
            createdAt: now,
            content: nil,
            file: nil,
            description: nil,
            transcript: nil,
            durationSeconds: nil,
            url: url.absoluteString,
            title: url.host ?? url.absoluteString,
            preview: nil
        )
        return Node(
            id: UUID().uuidString,
            createdAt: now,
            updatedAt: now,
            title: url.host ?? "Link",
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            items: [item],
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: true
        )
    }

    private static func makeTextNode(text: String) -> Node {
        let now = Date()
        let item = NodeItem(
            id: UUID().uuidString,
            type: .text,
            createdAt: now,
            content: text,
            file: nil,
            description: nil,
            transcript: nil,
            durationSeconds: nil,
            url: nil,
            title: nil,
            preview: nil
        )
        return Node(
            id: UUID().uuidString,
            createdAt: now,
            updatedAt: now,
            title: String(text.prefix(40)),
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            items: [item],
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: true
        )
    }

    private static func makeImageNode(data: Data) -> Node {
        let now = Date()
        let nodeID = UUID().uuidString
        let itemID = UUID().uuidString
        let filename = "\(itemID).jpg"
        let item = NodeItem(
            id: itemID,
            type: .image,
            createdAt: now,
            content: nil,
            file: "items/\(filename)",
            description: nil,
            transcript: nil,
            durationSeconds: nil,
            url: nil,
            title: nil,
            preview: nil
        )
        let node = Node(
            id: nodeID,
            createdAt: now,
            updatedAt: now,
            title: "Photo",
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            items: [item],
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: true
        )
        stageMedia(nodeID: nodeID, itemID: itemID, data: data, ext: "jpg")
        return node
    }

    private static func makeDocumentNode(fileURL: URL) -> Node {
        let now = Date()
        let nodeID = UUID().uuidString
        let itemID = UUID().uuidString
        let ext = fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension
        let filename = "\(itemID).\(ext)"
        let item = NodeItem(
            id: itemID,
            type: .document,
            createdAt: now,
            content: nil,
            file: "items/\(filename)",
            description: fileURL.lastPathComponent,
            transcript: nil,
            durationSeconds: nil,
            url: nil,
            title: nil,
            preview: nil
        )
        let node = Node(
            id: nodeID,
            createdAt: now,
            updatedAt: now,
            title: fileURL.deletingPathExtension().lastPathComponent,
            summary: "",
            tags: [],
            mood: nil,
            isMeta: false,
            provenance: nil,
            threads: [],
            location: nil,
            items: [item],
            domain: nil,
            domainConfirmed: false,
            needsAIProcessing: true
        )
        if let data = try? Data(contentsOf: fileURL) {
            stageMedia(nodeID: nodeID, itemID: itemID, data: data, ext: ext)
        }
        return node
    }

    private static func makeBatchNodes(text: String) -> [Node] {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        return BatchParser.parse(text: text, importTimestamp: timestamp)
    }

    // MARK: - Staging helpers

    /// Writes a node JSON to the App Group inbox. Main app imports on next launch.
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
}
