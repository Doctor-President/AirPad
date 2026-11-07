#if DEBUG
import Foundation

/// Mac batch B1e — the app half of the two-device harness (`scripts/twodevice/`). With `-TwoDeviceCommands <dir>` the
/// app polls `<dir>/cmd-*.json`, runs each command through the SAME store paths the UI uses, and answers in
/// `<dir>/done-<id>.json`. Two instances (two Simulators) each run on their own replica of one library
/// (`-TwoDeviceRoot`), with the harness's stand-in for iCloud between the replicas. DEBUG only.
///
/// Commands (`{"id": "...", "op": "...", ...}`):
/// - `new_entry` title, text, entry (fixed id) — a new entry with one note
/// - `set_text` entry, item, text — a saved note edit (`updateTextItem`, as end-of-editing does)
/// - `type` entry, item, text — UNSAVED typing in the open editor (the editor's live mirror), not yet saved
/// - `add_item` entry, text, item (fixed id) — a new note in the entry
/// - `set_title` entry, title — the header's title edit (user)
/// - `enrich` entry, title?, summary? — a background pass (naming / enrichment) writing the entry
/// - `delete_entry` entry
/// - `restore` entry, version — restore a kept version
/// - `rescan` — look for changes now; `dump` — every entry (+ its versions) and the store's sync state
@MainActor
enum TwoDeviceHarness {
    private static var started = false

    static func startIfAsked(store: CorpusStore) {
        guard !started, let dir = UserDefaults.standard.string(forKey: "TwoDeviceCommands"), dir.hasPrefix("/") else { return }
        started = true
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        print("[TwoDeviceHarness] commands from \(dir)")
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(300))
                let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                    .filter { $0.hasPrefix("cmd-") && $0.hasSuffix(".json") }.sorted()
                for f in files {
                    let u = url.appendingPathComponent(f)
                    guard let d = try? Data(contentsOf: u), let cmd = SyncJSON.object(d) else { continue }
                    try? FileManager.default.removeItem(at: u)
                    let id = cmd["id"] as? String ?? UUID().uuidString
                    var result: [String: Any] = ["id": id, "op": cmd["op"] as? String ?? ""]
                    result["result"] = await run(cmd, store: store)
                    result["device"] = SyncDevice.id
                    if let out = SyncJSON.data(result) { try? out.write(to: url.appendingPathComponent("done-\(id).json"), options: .atomic) }
                }
            }
        }
    }

    private static func run(_ c: [String: Any], store: CorpusStore) async -> Any {
        let entry = c["entry"] as? String ?? ""
        let text = c["text"] as? String ?? ""
        switch c["op"] as? String ?? "" {
        case "new_entry":
            let now = Date()
            var item = NodeItem(id: c["item"] as? String ?? UUID().uuidString, type: .text, createdAt: now)
            item.content = text
            item.updatedAt = now
            let node = Node(id: entry.isEmpty ? UUID().uuidString : entry, createdAt: now, updatedAt: now,
                            title: c["title"] as? String ?? "", summary: "", tags: [], items: [item], entrySchemaVersion: 4)
            await store.addNode(node, position: .zero)
            return node.id
        case "set_text":
            await store.updateTextItem(itemID: c["item"] as? String ?? "", newContent: text, nodeID: entry)
            return "ok"
        case "type":
            store.mirrorPendingItemEdit(itemID: c["item"] as? String ?? "", text: text)
            return "ok"
        case "add_item":
            let now = Date()
            var item = NodeItem(id: c["item"] as? String ?? UUID().uuidString, type: .text, createdAt: now)
            item.content = text
            item.updatedAt = now
            await store.appendItemToNode(nodeID: entry, item: item)
            return item.id
        case "set_title":
            let title = c["title"] as? String ?? ""
            await store.mutateNode(id: entry) { n in n.title = title; n.titleSource = .user; n.updatedAt = Date() }
            return "ok"
        case "enrich":
            let title = c["title"] as? String, summary = c["summary"] as? String
            await store.mutateNode(id: entry, origin: .background) { n in
                if let title { n.title = title; n.titleSource = .model }
                if let summary { n.summary = summary; n.summarySource = .model }
            }
            return "ok"
        case "delete_entry":
            await store.deleteNode(id: entry)
            return "ok"
        case "restore":
            await store.restoreVersion(nodeID: entry, versionID: c["version"] as? String ?? "")
            return "ok"
        case "rescan":
            LibraryWatcher.rescanNow()
            return "ok"
        case "dump":
            var nodes: [[String: Any]] = []
            for n in store.nodes {
                let versions = await store.versions(nodeID: n.id)
                nodes.append([
                    "id": n.id, "title": n.title, "summary": n.summary, "tags": n.tags,
                    "items": n.items.map { ["id": $0.id, "content": $0.content ?? ""] },
                    "rev": "\(n.syncBase?.d ?? ""):\(n.syncBase?.n ?? 0)",
                    "versions": versions.map { ["id": $0.id, "label": $0.label, "from": $0.from, "state": $0.state,
                                                "note": $0.note, "kind": $0.kind, "key": $0.key] },
                    "version_values": await rawValues(store: store, id: n.id),
                    "note": store.versionNotes[n.id]?.note ?? "",
                ])
            }
            return ["nodes": nodes, "catching_up": Array(store.catchingUp), "count": store.nodes.count]
        default:
            return "unknown op"
        }
    }

    /// Every text a kept version holds (for the harness's "nothing lost" byte check).
    private static func rawValues(store: CorpusStore, id: String) async -> [String] {
        let records = await store.rawHistory(nodeID: id)
        return records.compactMap { r in
            if let s = r["value"] as? String { return s }
            if let i = r["value"] as? [String: Any] { return i["content"] as? String }
            if let a = r["value"] as? [String] { return a.joined(separator: ", ") }
            return nil
        }
    }
}
#endif
