import Foundation
import os

/// 1.0r S0 — the forward-format guard (T ruled 2026-11-01). A build NEVER writes an entry or library file saved in a
/// format newer than it understands, and opens such a library read-only.
///
/// Why: two devices on different AirPad versions share one library over iCloud. Before this guard, an older build
/// decoded a newer `node.json`, dropped the fields it didn't know, and wrote it back still labelled with the newer
/// version — so the newer build then trusted a file that had lost its data (proved in Ops `design-refs/1.0r/
/// guard-before.md`).
///
/// Structural, not remembered: every library write in `iCloudDriveService` goes through `write(_:to:)`, the ONE
/// place that checks. Two rules live there:
/// 1. A file whose on-disk version is above `knownVersion` is never overwritten, and its library goes read-only
///    for the rest of the run (`isReadOnly`, read by the store for the banner and by capture to refuse).
/// 2. An entry's top-level and per-item fields this build doesn't know are CARRIED from the file on disk into the
///    one being written, so an additive field from a newer build (the codebase adds optional fields without a
///    schema bump) survives an edit here. Deeper nested shapes aren't carried: a newer build that changes those
///    must bump `entry_schema_version`, which rule 1 then covers.
/// Format version numbers do not change here; this only reads them.
enum LibraryFormatGuard {

    /// The banner / refusal text (T's wording, directive 2026-11-02).
    static let message = "This library was updated by a newer version of AirPad. Update AirPad to keep editing."

    /// The newest `entry_schema_version` this build writes (`migrateEntrySchemaIfNeeded` brings every entry to it).
    static let entrySchemaVersion = 4

    /// The newest version this build understands, per versioned file; nil for files that carry no version.
    static func knownVersion(forFile name: String) -> Int? {
        switch name {
        case "node.json":              return entrySchemaVersion
        case "corpus_index.json":      return CorpusIndex.currentVersion
        case "field_definitions.json": return FieldDefinitionStore.currentVersion
        case "territory_layout.json":  return TerritoryLayoutSnapshot.currentVersion
        case "canvas_layout.json":     return 1
        case "sample_library.json":    return SampleLibrarySeeder.manifestVersion
        default:                       return nil
        }
    }

    /// The version a file's bytes carry: `entry_schema_version` for an entry, top-level `version` otherwise; for
    /// `territory_layout.json` (a dict of snapshots) the highest snapshot `version`.
    static func onDiskVersion(_ data: Data, file name: String) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if name == "node.json" { return obj["entry_schema_version"] as? Int }
        if let v = obj["version"] as? Int { return v }
        if name == "territory_layout.json" {
            return obj.values.compactMap { ($0 as? [String: Any])?["version"] as? Int }.max()
        }
        return nil
    }

    /// True when `data` (a file's bytes) is in a format newer than this build knows.
    static func isNewer(_ data: Data, file name: String) -> Bool {
        guard let known = knownVersion(forFile: name), let v = onDiskVersion(data, file: name) else { return false }
        return v > known
    }

    // MARK: - Library state (process-wide: CorpusStore and ChatStore each own a service on the same root)

    private static let readOnlyReason = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The library holds a file newer than this build: nothing in it is written for the rest of this run.
    static var isReadOnly: Bool { readOnlyReason.withLock { $0 != nil } }

    /// Records the first newer file seen (on load, or at a write). Logged once.
    static func markNewer(_ what: String) {
        let first = readOnlyReason.withLock { reason -> Bool in
            guard reason == nil else { return false }
            reason = what
            return true
        }
        if first { print("[FormatGuard] newer library format (\(what)) — the library is READ-ONLY this run") }
    }

    enum GuardError: Error { case newerLibraryFormat }

    // MARK: - The one write path

    /// Writes a library file — the only way `iCloudDriveService` writes one. Refuses (throws `newerLibraryFormat`)
    /// when the library is read-only or the file on disk is newer; carries unknown entry fields into a `node.json`.
    static func write(_ data: Data, to url: URL) throws {
        try requireWritable()
        let name = url.lastPathComponent
        let old = try? Data(contentsOf: url)
        var out = data
        if let old {
            if isNewer(old, file: name) {
                markNewer("\(url.deletingLastPathComponent().lastPathComponent)/\(name)")
                throw GuardError.newerLibraryFormat
            }
            if name == "node.json" { out = carryUnknownEntryFields(into: data, from: old) }
        }
        try out.write(to: url, options: .atomic)
    }

    /// For mutations that aren't a file write (delete, copy a media file in): refused while read-only.
    static func requireWritable() throws {
        if isReadOnly { throw GuardError.newerLibraryFormat }
    }

    // MARK: - Unknown fields

    static let knownEntryKeys = Set(Node.CodingKeys.allCases.map(\.stringValue))
    static let knownItemKeys = Set(NodeItem.CodingKeys.allCases.map(\.stringValue))

    /// Copies keys this build doesn't decode from the on-disk entry (`old`) into the entry about to be written
    /// (`new`): at the top level, and per item matched by `id`. A key this build KNOWS is never copied, so a field
    /// the user cleared here stays cleared. Returns `new` unchanged when there is nothing to carry.
    static func carryUnknownEntryFields(into new: Data, from old: Data) -> Data {
        guard var newObj = try? JSONSerialization.jsonObject(with: new) as? [String: Any],
              let oldObj = try? JSONSerialization.jsonObject(with: old) as? [String: Any] else { return new }
        var carried = 0
        for (k, v) in oldObj where !knownEntryKeys.contains(k) && newObj[k] == nil {
            newObj[k] = v; carried += 1
        }
        if let oldItems = oldObj["items"] as? [[String: Any]], var newItems = newObj["items"] as? [[String: Any]] {
            let oldByID = Dictionary(oldItems.compactMap { i in (i["id"] as? String).map { ($0, i) } },
                                     uniquingKeysWith: { a, _ in a })
            for idx in newItems.indices {
                guard let id = newItems[idx]["id"] as? String, let oldItem = oldByID[id] else { continue }
                for (k, v) in oldItem where !knownItemKeys.contains(k) && newItems[idx][k] == nil {
                    newItems[idx][k] = v; carried += 1
                }
            }
            newObj["items"] = newItems
        }
        guard carried > 0,
              let out = try? JSONSerialization.data(withJSONObject: newObj, options: [.prettyPrinted, .sortedKeys])
        else { return new }
        return out
    }
}

#if DEBUG
extension LibraryFormatGuard {
    /// Self-test only: clear the run's read-only state so the test leaves the app writable.
    static func resetForSelfTest() { readOnlyReason.withLock { $0 = nil } }
}

/// 1.0r S0 — `-ForwardFormatGuardSelfTest`: the version checks, the unknown-field carry, and the one write path
/// (refuses a newer file, then the whole library) on a temp folder. Pure; never touches the library.
enum ForwardFormatGuardSelfTest {
    static func run() -> String {
        var fails: [String] = []
        var n = 0
        func check(_ ok: Bool, _ label: String) { n += 1; if !ok { fails.append(label) } }
        func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }
        let G = LibraryFormatGuard.self
        G.resetForSelfTest()

        // 1. versions
        check(G.isNewer(json(["entry_schema_version": 5]), file: "node.json"), "entry v5 newer")
        check(!G.isNewer(json(["entry_schema_version": 4]), file: "node.json"), "entry v4 not newer")
        check(!G.isNewer(json(["id": "x"]), file: "node.json"), "entry without version not newer")
        check(G.isNewer(json(["version": CorpusIndex.currentVersion + 1]), file: "corpus_index.json"), "corpus_index newer")
        check(!G.isNewer(json(["version": CorpusIndex.currentVersion]), file: "corpus_index.json"), "corpus_index current")
        check(G.isNewer(json(["_corpus": ["version": TerritoryLayoutSnapshot.currentVersion + 1]]),
                        file: "territory_layout.json"), "territory snapshot newer")
        check(!G.isNewer(json([["id": "t"]]), file: "tags.json"), "tags carry no version")

        // 2. carry: unknown top-level + item fields kept; a KNOWN field cleared here stays cleared
        let old = json(["id": "n", "entry_schema_version": 4, "summary": "old", "zz_top": [1, 2], "title": "t",
                        "created_at": "2026-11-02T10:00:00Z", "updated_at": "2026-11-02T10:00:00Z", "tags": [String](),
                        "items": [["id": "i1", "type": "text", "content": "a", "zz_item": "keep"]]])
        let new = json(["id": "n", "entry_schema_version": 4,
                        "items": [["id": "i1", "type": "text", "content": "b"], ["id": "i2", "type": "text"]]])
        let carried = obj(G.carryUnknownEntryFields(into: new, from: old))
        check((carried["zz_top"] as? [Int]) == [1, 2], "top-level unknown carried")
        check(carried["summary"] == nil, "known cleared field not resurrected")
        let items = carried["items"] as? [[String: Any]] ?? []
        check(items.first?["zz_item"] as? String == "keep", "item unknown carried by id")
        check(items.first?["content"] as? String == "b", "item edit kept")
        check(items.count == 2 && items[1]["zz_item"] == nil, "new item untouched")
        let plain = json(["id": "n", "entry_schema_version": 4, "summary": "s"])
        check(G.carryUnknownEntryFields(into: new, from: plain) == new, "nothing unknown → bytes unchanged")

        // 3. a real Node round-trip through the app's own coder keeps the carried fields
        var item = NodeItem(id: "i1", type: .text, createdAt: Date())
        item.content = "a"
        let real = Node(id: "n", createdAt: Date(), updatedAt: Date(), title: "t", summary: "s", tags: [],
                        items: [item], entrySchemaVersion: 4)
        if let enc = try? JSONEncoder.airPad.encode(real) {
            var future = obj(enc)
            future["zz_top"] = [1, 2]
            var its = future["items"] as? [[String: Any]] ?? []
            if !its.isEmpty { its[0]["zz_item"] = "keep" }
            future["items"] = its
            let onDisk = json(future)
            let decoded = try? JSONDecoder.airPad.decode(Node.self, from: onDisk)
            check(decoded != nil, "future entry decodes here")
            if let decoded, let reenc = try? JSONEncoder.airPad.encode(decoded) {
                check(obj(reenc)["zz_top"] == nil, "control: plain re-encode drops the unknown field")
                let out = G.carryUnknownEntryFields(into: reenc, from: onDisk)
                check(obj(out)["zz_top"] != nil && ((obj(out)["items"] as? [[String: Any]])?.first?["zz_item"] != nil),
                      "Node re-encode + carry keeps unknowns")
                check((try? JSONDecoder.airPad.decode(Node.self, from: out)) != nil, "carried entry still decodes")
            }
        } else { check(false, "Node encode of fixture") }

        // 4. the one write path on a temp folder
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FwdGuard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); G.resetForSelfTest() }
        let same = dir.appendingPathComponent("node.json")
        try? old.write(to: same)
        check((try? G.write(new, to: same)) != nil, "write over current-version entry allowed")
        check(obj((try? Data(contentsOf: same)) ?? Data())["zz_top"] != nil, "write carried unknown field to disk")
        let sub = dir.appendingPathComponent("b"); try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let newer = sub.appendingPathComponent("node.json")
        let newerBytes = json(["id": "m", "entry_schema_version": 9, "zz": 1])
        try? newerBytes.write(to: newer)
        var refused = false
        do { try G.write(new, to: newer) } catch { refused = true }
        check(refused, "write over newer entry refused")
        check((try? Data(contentsOf: newer)) == newerBytes, "newer entry bytes untouched")
        check(G.isReadOnly, "library read-only after a newer file")
        var refusedAll = false
        do { try G.write(json([["id": "t"]]), to: dir.appendingPathComponent("tags.json")) } catch { refusedAll = true }
        check(refusedAll && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("tags.json").path),
              "read-only library refuses every write")
        check((try? G.requireWritable()) == nil, "requireWritable throws while read-only")

        return fails.isEmpty ? "PASS \(n)/\(n)" : "FAIL \(n - fails.count)/\(n): " + fails.joined(separator: "; ")
    }
}
#endif
