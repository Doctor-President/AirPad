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
/// - `open_header` entry, title — the entry open, its header's title typed (the flush stays registered, as the view's)
/// - `delete_entry` entry
/// - `restore` entry, version — restore a kept version
/// - `rescan` — look for changes now; `dump` — every entry (+ its versions) and the store's sync state
@MainActor
enum TwoDeviceHarness {
    private static var started = false
    private static var typedTitles: [String: String] = [:]
    private static var flushTokens: [String: UUID] = [:]

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
            store.mirrorPendingItemEdit(itemID: c["item"] as? String ?? "", text: text, nodeID: entry)
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
        case "open_header":
            // F1 — the entry open with its header edited: the user typed `title`, and the view stays open, so another
            // device's change first runs its flush (`NodeDetailView.commitEditsIfChanged`). DEBUG
            // `-SyncLegacyHeaderFlushForControl` = the f4a12630 flush (re-saves the title + updatedAt every time).
            let title = c["title"] as? String
            let legacy = ProcessInfo.processInfo.arguments.contains("-SyncLegacyHeaderFlushForControl")
            let flush: () async -> Void = { @MainActor in
                if legacy {
                    await store.mutateNode(id: entry) { n in
                        if let title { n.title = title; n.titleSource = .user }
                        n.updatedAt = Date()
                    }
                } else {
                    let tags = store.nodes.first(where: { $0.id == entry })?.tags ?? []
                    await store.commitHeaderEdits(nodeID: entry, title: title, summary: nil, tags: tags)
                }
            }
            await flush()
            _ = store.registerPendingFlush(nodeID: entry, flush)
            return "ok"
        case "keystrokes":
            // F2 — typing in the note key by key, as the editor does (mirror + draft + the typing-pause commit), with
            // hesitations (`hesitate`: {"<chars typed>": seconds}) and echoes of this device's own write
            // (`echo_at`: [chars typed] → the watcher's callback for this entry) mid-word.
            let itemID = c["item"] as? String ?? ""
            let keyMs = c["key_ms"] as? Int ?? 120
            let hesitate = (c["hesitate"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            let echoAt = Set((c["echo_at"] as? [Int]) ?? [])
            let base = store.nodes.first(where: { $0.id == entry })?.items.first(where: { $0.id == itemID })?.content ?? ""
            var typed = base
            for (k, ch) in text.enumerated() {
                typed.append(ch)
                store.mirrorPendingItemEdit(itemID: itemID, text: typed, nodeID: entry)
                store.scheduleCaptureLiveCommit(itemID: itemID, nodeID: entry, text: typed, enrich: false)
                try? await Task.sleep(for: .milliseconds(keyMs))
                if echoAt.contains(k + 1) { await store.librarySyncChanged(nodeIDs: [entry], files: []) }
                if let h = hesitate["\(k + 1)"] { try? await Task.sleep(for: .seconds(h)) }
            }
            try? await Task.sleep(for: .seconds(CorpusStore.typingPause + 0.5))
            return typed
        case "title_keys":
            // F2 — typing the header title key by key: the view's draft + typing-pause commit + its flush (registered
            // once, reading the title as typed so far), with hesitations and echoes as above. Legacy control: no pause
            // commit, and the f4a12630 flush (writes the title as typed + updatedAt every time).
            let keyMs = c["key_ms"] as? Int ?? 120
            let hesitate = (c["hesitate"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            let echoAt = Set((c["echo_at"] as? [Int]) ?? [])
            let legacy = CorpusStore.legacyTypingForControl
            typedTitles[entry] = ""
            if flushTokens[entry] == nil {
                flushTokens[entry] = store.registerPendingFlush(nodeID: entry) { @MainActor in
                    guard let t = typedTitles[entry] else { return }
                    if legacy { await store.mutateNode(id: entry) { n in n.title = t; n.titleSource = .user; n.updatedAt = Date() } }
                    else { await store.commitHeaderEdits(nodeID: entry, title: t, summary: nil,
                                                         tags: store.nodes.first(where: { $0.id == entry })?.tags ?? []) }
                }
            }
            var pause: Task<Void, Never>?
            for (k, ch) in text.enumerated() {
                typedTitles[entry, default: ""].append(ch)
                let t = typedTitles[entry] ?? ""
                LocalDrafts.set("title:\(entry)", node: entry, text: t)
                if !legacy {
                    pause?.cancel()
                    pause = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(CorpusStore.typingPause))
                        guard !Task.isCancelled else { return }
                        await store.commitHeaderEdits(nodeID: entry, title: t, summary: nil,
                                                      tags: store.nodes.first(where: { $0.id == entry })?.tags ?? [])
                    }
                }
                try? await Task.sleep(for: .milliseconds(keyMs))
                if echoAt.contains(k + 1) { await store.librarySyncChanged(nodeIDs: [entry], files: []) }
                if let h = hesitate["\(k + 1)"] { try? await Task.sleep(for: .seconds(h)) }
            }
            try? await Task.sleep(for: .seconds(CorpusStore.typingPause + 0.5))
            if legacy { await store.runPendingFlushers(nodeID: entry) }   // the old path saved at blur / close
            return typedTitles[entry] ?? ""
        case "watch":
            // F2 — what this device shows for the entry, sampled every 50 ms for `seconds`: every distinct title and
            // note text seen, in order.
            let seconds = (c["seconds"] as? NSNumber)?.doubleValue ?? 10
            var titles: [String] = [], notes: [String] = []
            let t0 = Date()
            while Date().timeIntervalSince(t0) < seconds {
                if let n = store.nodes.first(where: { $0.id == entry }) {
                    if titles.last != n.title { titles.append(n.title) }
                    let body = n.items.first?.content ?? ""
                    if notes.last != body { notes.append(body) }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return ["titles": titles, "notes": notes]
        case "flush_drafts":
            LocalDrafts.flushNow()
            return LocalDrafts.all().keys.sorted()
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
            return ["nodes": nodes, "catching_up": Array(store.catchingUp), "count": store.nodes.count,
                    "pill": store.entriesCatchingUp]
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
