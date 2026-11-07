#if DEBUG
import Foundation

/// Mac batch B1 — `-TwoDeviceSelfTest`: the stamp, the per-field / per-item merge, the write funnel's base check and
/// history, a build without stamps editing a stamped file, and the library-file merges. Pure: temp folders only, two
/// "devices" simulated by stamping with explicit device ids. Every case that merges text checks that every byte of
/// both sides survives (in the entry or in its version history).
enum TwoDeviceSelfTest {
    static func run() -> String {
        var fails: [String] = []
        var n = 0
        func check(_ ok: Bool, _ label: String) { n += 1; if !ok { fails.append(label) } }
        func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
        func obj(_ d: Data?) -> [String: Any] { d.flatMap(SyncJSON.object) ?? [:] }
        func item(_ id: String, _ text: String, _ t: String = "2026-11-07T10:00:00Z") -> [String: Any] {
            ["id": id, "type": "text", "content": text, "created_at": "2026-11-07T09:00:00Z", "updated_at": t]
        }
        func entry(_ title: String, _ items: [[String: Any]], summary: String = "", t: String = "2026-11-07T10:00:00Z") -> [String: Any] {
            ["id": "E1", "title": title, "summary": summary, "tags": ["a"], "items": items, "entry_schema_version": 4,
             "created_at": "2026-11-07T09:00:00Z", "updated_at": t, "is_meta": false, "threads": [String]()]
        }
        func texts(_ o: [String: Any]) -> [String] { EntryMerge.items(o).compactMap { $0["content"] as? String } }
        func historyTexts(_ losers: [EntryMerge.Loser]) -> [String] {
            losers.compactMap { l in (l.value as? [String: Any])?["content"] as? String ?? l.value as? String }
        }
        var c = 1_000
        func stamp(_ o: [String: Any], base: EntryRevision?, dev: String, t: Double, origin: SyncOrigin = .user) -> EntryRevision {
            c += 1
            return EntryMerge.stamp(o, base: base, origin: origin, device: dev, label: dev == "M" ? "Mac" : "iPhone", counter: c, now: t)
        }

        // A common ancestor P, written by the iPhone (I).
        let p = entry("Trip", [item("i1", "first"), item("i2", "second")])
        let pRev = stamp(p, base: nil, dev: "I", t: 100)
        check(pRev.keys.isEmpty && pRev.vv["I"] == c, "new entry: no change records, vv has the writer")
        check(EntryMerge.adopt(EntryMerge.stamped(p, pRev).0) == EntryMerge.stamped(p, pRev).1, "adopt(stamped) = the stamp")

        // 1. Different fields on two devices → both kept, nothing in history.
        var a = p; a["title"] = "Trip to Oslo"
        var b = p; b["summary"] = "With Sid"
        var m = EntryMerge.merge(.init(obj: a, rev: stamp(a, base: pRev, dev: "M", t: 200)),
                                 .init(obj: b, rev: stamp(b, base: pRev, dev: "I", t: 210)))
        check(m.obj["title"] as? String == "Trip to Oslo" && m.obj["summary"] as? String == "With Sid", "different fields: both kept")
        check(m.losers.isEmpty, "different fields: no conflict")

        // 2. The same field on both, neither saw the other → newer wins, the other kept in history.
        a = p; a["title"] = "Oslo (Mac)"
        b = p; b["title"] = "Oslo (iPhone)"
        m = EntryMerge.merge(.init(obj: a, rev: stamp(a, base: pRev, dev: "M", t: 300)),
                             .init(obj: b, rev: stamp(b, base: pRev, dev: "I", t: 310)))
        check(m.obj["title"] as? String == "Oslo (iPhone)", "same field: newer wins")
        check(m.losers.count == 1 && m.losers[0].value as? String == "Oslo (Mac)" && m.losers[0].change.d == "M",
              "same field: loser kept, from the Mac")
        // Symmetric: the other merge order gives the same entry.
        let m2 = EntryMerge.merge(.init(obj: b, rev: stamp(b, base: pRev, dev: "I", t: 310)),
                                  .init(obj: a, rev: stamp(a, base: pRev, dev: "M", t: 300)))
        check(m2.obj["title"] as? String == "Oslo (iPhone)", "same field: merge order doesn't matter")

        // 3. A user edit beats a newer background pass.
        a = p; a["title"] = "Typed by T"
        b = p; b["title"] = "Named by the model"
        m = EntryMerge.merge(.init(obj: a, rev: stamp(a, base: pRev, dev: "M", t: 400)),
                             .init(obj: b, rev: stamp(b, base: pRev, dev: "I", t: 500, origin: .background)))
        check(m.obj["title"] as? String == "Typed by T", "user edit beats a newer background pass")

        // 4. Superseded: B changed the title AFTER seeing A's change → B, no conflict.
        a = p; a["title"] = "v1"
        let aRev = stamp(a, base: pRev, dev: "M", t: 600)
        b = a; b["title"] = "v2"
        let bRev = stamp(b, base: aRev, dev: "I", t: 590)   // even with an older clock
        m = EntryMerge.merge(.init(obj: a, rev: aRev), .init(obj: b, rev: bRev))
        check(m.obj["title"] as? String == "v2" && m.losers.isEmpty, "a change that saw the other supersedes it (clock-proof)")

        // 5. Items: each side edits a different item and adds one → all four changes kept, order sensible.
        a = p; a["items"] = [item("i1", "first + Mac"), item("i2", "second"), item("i3", "Mac new")]
        b = p; b["items"] = [item("i1", "first"), item("i2", "second + iPhone"), item("i4", "iPhone new")]
        m = EntryMerge.merge(.init(obj: a, rev: stamp(a, base: pRev, dev: "M", t: 700)),
                             .init(obj: b, rev: stamp(b, base: pRev, dev: "I", t: 710)))
        let t5 = texts(m.obj)
        check(t5.contains("first + Mac") && t5.contains("second + iPhone") && t5.contains("Mac new") && t5.contains("iPhone new"),
              "items: edits + additions on both sides kept")
        check(m.losers.isEmpty && t5.count == 4, "items: no conflict, no duplicate")
        check(EntryMerge.items(m.obj).compactMap(EntryMerge.itemID).prefix(2) == ["i1", "i2"], "items: shared order kept")

        // 6. The same item (a note body) on both → newer wins, the other's text in history: every byte survives.
        let macText = "Paragraph from the Mac — ünïcödé ✓ \u{1F600}\nline 2"
        let phoneText = "Paragraph from the iPhone\n\twith a tab"
        a = p; a["items"] = [item("i1", macText, "2026-11-07T11:00:00Z"), item("i2", "second")]
        b = p; b["items"] = [item("i1", phoneText, "2026-11-07T11:05:00Z"), item("i2", "second")]
        m = EntryMerge.merge(.init(obj: a, rev: stamp(a, base: pRev, dev: "M", t: 800)),
                             .init(obj: b, rev: stamp(b, base: pRev, dev: "I", t: 810)))
        check(texts(m.obj).contains(phoneText) && !texts(m.obj).contains(macText), "same item: newer text wins")
        check(historyTexts(m.losers) == [macText], "same item: the other text kept byte-for-byte")
        let recs = EntryHistory.records(m.losers, names: m.rev.names)
        check(recs.first?["from"] as? String == "Mac" && recs.first?["state"] as? String == "new", "history record: from the Mac, new")
        check(CorpusStore.entryVersion(recs[0])?.note == "Also edited on your Mac", "the quiet note reads \"Also edited on your Mac\"")

        // 7. Delete vs edit: B deletes i2 (having seen it), A untouched → deleted. B deletes i1 while A edits it → kept.
        a = p; a["items"] = [item("i1", "first, edited offline"), item("i2", "second")]
        b = p; b["items"] = [[String: Any]]()
        m = EntryMerge.merge(.init(obj: a, rev: stamp(a, base: pRev, dev: "M", t: 900)),
                             .init(obj: b, rev: stamp(b, base: pRev, dev: "I", t: 910)))
        check(texts(m.obj) == ["first, edited offline"], "delete vs edit: the edit survives, the untouched item stays deleted")
        // A delete AFTER seeing the edit stands.
        let aEdit = stamp(a, base: pRev, dev: "M", t: 900)
        var bAfter = a; bAfter["items"] = [item("i2", "second")]
        m = EntryMerge.merge(.init(obj: a, rev: aEdit), .init(obj: bAfter, rev: stamp(bAfter, base: aEdit, dev: "I", t: 920)))
        check(texts(m.obj) == ["second"], "a delete that saw the edit stands")

        // 8. A build without stamps (1.0) edits a stamped file: it carries the old stamp, the hash no longer matches.
        let stampedP = EntryMerge.stamped(p, pRev).0
        var legacy = stampedP; legacy["summary"] = "edited on 1.0"; legacy["updated_at"] = "2026-11-07T12:00:00Z"
        let lRev = EntryMerge.adopt(legacy)
        check(lRev.keys["summary"]?.d == EntryMerge.legacyDevice, "legacy edit detected and attributed")
        a = p; a["title"] = "edited on 1.0.2"
        m = EntryMerge.merge(.init(obj: a, rev: stamp(a, base: pRev, dev: "M", t: 1000)), .init(obj: legacy, rev: lRev))
        check(m.obj["summary"] as? String == "edited on 1.0" && m.obj["title"] as? String == "edited on 1.0.2",
              "legacy edit + stamped edit: both kept")
        // Unstamped file (written before B1) adopts cleanly.
        let un = EntryMerge.adopt(p)
        check(un.hash == SyncJSON.contentHash(p) && un.vv.isEmpty, "unstamped file adopts as an unrecorded version")

        // 9. The write funnel on a temp folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TwoDevice-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); LibraryFormatGuard.resetForSelfTest() }
        LibraryFormatGuard.resetForSelfTest()
        let file = dir.appendingPathComponent("node.json")
        // This device writes a new entry, then edits it twice WITHOUT updating its base (two saves in flight).
        let w1 = try? LibraryFormatGuard.write(json(p), to: file)
        check(w1?.revision != nil && w1?.merged == nil, "funnel: new entry stamped, no merge")
        var p2 = p; p2["title"] = "local 2"
        let w2 = try? LibraryFormatGuard.write(json(p2), to: file, entryBase: w1?.revision)
        var p3 = p2; p3["title"] = "local 3"
        let w3 = try? LibraryFormatGuard.write(json(p3), to: file, entryBase: w1?.revision)   // stale base: our own write
        check(w2?.merged == nil && w3?.merged == nil && w3?.keptVersions == 0, "funnel: our own writes never conflict")
        check(obj(try? Data(contentsOf: file))["title"] as? String == "local 3", "funnel: last local write on disk")
        // Another device's version lands (its own edit of the summary + a note).
        let disk = obj(try? Data(contentsOf: file))
        let diskRev = EntryMerge.adopt(disk)
        var other = disk; other.removeValue(forKey: EntryMerge.stampKey)
        other["summary"] = "from the iPhone"
        other["items"] = [item("i1", "first"), item("i2", "second, iPhone", "2026-11-07T13:00:00Z")]
        let oRev = stamp(other, base: diskRev, dev: "I", t: Date().timeIntervalSince1970 - 5)
        try? json(EntryMerge.stamped(other, oRev).0).write(to: file)
        // This device saves from its old base (title + the same note edited) → merged, never overwritten.
        var p4 = p3; p4["title"] = "local 4"
        p4["items"] = [item("i1", "first"), item("i2", "second, Mac", "2026-11-07T13:10:00Z")]
        let w4 = try? LibraryFormatGuard.write(json(p4), to: file, entryBase: w3?.revision)
        let after = obj(try? Data(contentsOf: file))
        check(w4?.merged != nil, "funnel: a foreign version is merged, not overwritten")
        check(after["summary"] as? String == "from the iPhone" && after["title"] as? String == "local 4",
              "funnel: both devices' fields on disk")
        let hist = EntryHistory.records(in: SyncJSON.any((try? Data(contentsOf: dir.appendingPathComponent(EntryHistory.fileName))) ?? Data()))
        let both = Set(texts(after) + hist.compactMap { ($0["value"] as? [String: Any])?["content"] as? String })
        check(both.contains("second, iPhone") && both.contains("second, Mac"), "funnel: both note texts survive (entry + versions.json)")
        check(EntryMerge.adopt(after).hash == SyncJSON.contentHash(after), "funnel: written stamp matches the content")
        // A background write over a deleted entry doesn't bring it back.
        try? FileManager.default.removeItem(at: file)
        let w5 = try? LibraryFormatGuard.write(json(p4), to: file, entryBase: w4?.revision, origin: .background)
        check(w5?.skipped == true && !FileManager.default.fileExists(atPath: file.path), "funnel: background pass doesn't resurrect a deleted entry")
        let w6 = try? LibraryFormatGuard.write(json(p4), to: file, entryBase: w4?.revision, origin: .user)
        check(w6?.deletedElsewhere == true && FileManager.default.fileExists(atPath: file.path), "funnel: a person's edit to a deleted entry is kept")

        // 10. A real Node round-trips: the stamp isn't a Node field; syncBase isn't encoded.
        var node = Node(id: "N", createdAt: Date(), updatedAt: Date(), title: "t", summary: "", tags: [], entrySchemaVersion: 4)
        node.syncBase = pRev
        if let enc = try? JSONEncoder.airPad.encode(node) {
            check(obj(enc)[EntryMerge.stampKey] == nil && obj(enc)["syncBase"] == nil, "Node: syncBase not encoded")
            let stampedNode = EntryMerge.stamped(obj(enc), pRev).0
            check((try? JSONDecoder.airPad.decode(Node.self, from: json(stampedNode))) != nil, "Node: a stamped file decodes")
            check(LibraryFormatGuard.carryUnknownEntryFields(into: enc, from: json(stampedNode)) == enc, "Node: the stamp is never carried")
        } else { check(false, "Node encode") }

        // 11. Library files.
        let tBase: [[String: Any]] = [["id": "t1", "name": "one"], ["id": "t2", "name": "two"]]
        let tMine: [[String: Any]] = [["id": "t1", "name": "one"], ["id": "t3", "name": "mine"]]           // deleted t2, added t3
        let tDisk: [[String: Any]] = [["id": "t1", "name": "ONE"], ["id": "t2", "name": "two"], ["id": "t4", "name": "theirs"]]
        let tm = AggregateMerge.merge3(file: "tags.json", base: tBase, mine: tMine, disk: tDisk) as? [[String: Any]] ?? []
        let names = tm.compactMap { $0["name"] as? String }
        check(names == ["ONE", "mine", "theirs"], "tags: their rename + both additions kept, my delete honoured (\(names))")
        check((AggregateMerge.merge3(file: "tags.json", base: nil, mine: tMine, disk: tDisk) as? [[String: Any]])?.count == 4,
              "tags without a base: union, nothing dropped")
        let chatBase: [[String: Any]] = [["id": "c1", "messages": [["id": "m1", "text": "hi"]]]]
        let chatMine: [[String: Any]] = [["id": "c1", "messages": [["id": "m1", "text": "hi"], ["id": "m2", "text": "Mac"]]]]
        let chatDisk: [[String: Any]] = [["id": "c1", "messages": [["id": "m1", "text": "hi"], ["id": "m3", "text": "iPhone"]]],
                                         ["id": "c2", "messages": [[String: Any]]()]]
        let cm = AggregateMerge.merge3(file: "chats.json", base: chatBase, mine: chatMine, disk: chatDisk) as? [[String: Any]] ?? []
        let msgs = ((cm.first?["messages"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
        check(cm.count == 2 && msgs == ["hi", "Mac", "iPhone"], "chats: messages from both devices united, new chat kept")
        let posM: [String: Any] = ["version": 1, "positions": ["a": ["x": 1], "b": ["x": 2]]]
        let posD: [String: Any] = ["version": 1, "positions": ["a": ["x": 1], "c": ["x": 3]]]
        let pm = (AggregateMerge.merge3(file: "canvas_layout.json", base: ["version": 1, "positions": ["a": ["x": 1]]], mine: posM, disk: posD)
                  as? [String: Any])?["positions"] as? [String: Any]
        check(Set(pm?.keys.map { $0 } ?? []) == ["a", "b", "c"], "canvas layout: positions from both kept")
        // The funnel merges a library file another device changed since this one read it.
        let tags = dir.appendingPathComponent("tags.json")
        try? json(tBase).write(to: tags)
        SyncBases.noteRead(tags, json(tBase))
        try? json(tDisk).write(to: tags)   // the other device's write
        let wt = try? LibraryFormatGuard.write(json(tMine), to: tags)
        let onDisk = (SyncJSON.any((try? Data(contentsOf: tags)) ?? Data()) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        check(wt?.merged != nil && onDisk == ["ONE", "mine", "theirs"], "funnel: tags.json merged three-way (\(onDisk))")
        // History union: records only gain, states only move forward.
        let h1: [[String: Any]] = [["id": "r1", "at": "2026-11-07T10:00:00Z", "state": "seen"]]
        let h2: [[String: Any]] = [["id": "r1", "at": "2026-11-07T10:00:00Z", "state": "new"], ["id": "r2", "at": "2026-11-07T11:00:00Z", "state": "new"]]
        let hu = EntryHistory.union(h1, h2)
        check(hu.count == 2 && hu.first { $0["id"] as? String == "r1" }?["state"] as? String == "seen", "history: union, state never goes back")

        return fails.isEmpty ? "PASS \(n)/\(n)" : "FAIL \(n - fails.count)/\(n): " + fails.joined(separator: "; ")
    }
}
#endif
