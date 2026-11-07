import Foundation
import CryptoKit
import os

/// Mac batch B1 — two-device safety (M5, T 2026-11-05: newest wins per item + kept history + a silent revision stamp).
///
/// Before this, two devices on one iCloud library each wrote the whole `node.json`; the last writer won and the other
/// edit was lost with no trace. Now every entry write carries a silent **revision stamp** (`sync_revision`, an extra
/// top-level key, so no format bump: older builds carry it forward untouched, 1.0r S0) and goes through ONE check in
/// `LibraryFormatGuard.write`: when the file on disk isn't the version this device's copy came from, the two are
/// MERGED instead of overwritten.
///
/// The stamp is a small version vector per entry:
/// - `vv` — for each device, the newest of its writes this version has seen;
/// - `keys` / `items` / `gone` — for each top-level field, each item, and each deleted item, which write last changed
///   it (device, counter, time, user or background);
/// - `fp` / `ifp` / `order` — short fingerprints of the content as written, so the next write (and a build without
///   stamps that edited the file) shows exactly which fields and items changed.
/// The merge then needs no common ancestor: per field and per item, a change the other side has already seen is
/// superseded; two changes neither side saw are a conflict — a user edit beats a background pass, then the newest
/// wins, and the loser's value goes into the entry's version history (`versions.json`) for one-tap restore. Items
/// added or edited on either side are kept; an item is dropped only by a delete that saw it.
enum SyncOrigin: Equatable { case user, background }

// MARK: - This device

enum SyncDevice {
    /// A per-install id (not synced: UserDefaults). DEBUG `-SyncDeviceID A` names a harness instance.
    static let id: String = {
        let d = UserDefaults.standard
        #if DEBUG
        if let o = d.string(forKey: "SyncDeviceID"), !o.isEmpty { return o }
        #endif
        if let s = d.string(forKey: "sync.deviceID"), !s.isEmpty { return s }
        let s = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
        d.set(s, forKey: "sync.deviceID")
        return s
    }()

    /// "Mac", "iPad" or "iPhone" — shown in the version note ("Also edited on your Mac"). Read without UIKit so any
    /// actor can stamp. DEBUG `-SyncDeviceName` overrides it for the harness.
    static let label: String = {
        #if DEBUG
        if let o = UserDefaults.standard.string(forKey: "SyncDeviceName"), !o.isEmpty { return o }
        #endif
        if ProcessInfo.processInfo.isMacCatalystApp { return "Mac" }
        var model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if model.isEmpty {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.machine", &buf, &size, nil, 0)
            model = String(cString: buf)
        }
        return model.hasPrefix("iPad") ? "iPad" : "iPhone"
    }()

    private static let counterLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// A strictly increasing write counter for this device: never below the milliseconds since 2026-01-01, so it
    /// stays monotonic across reinstalls of a harness instance that keeps its id.
    static func nextCounter() -> Int {
        counterLock.withLock { last in
            let d = UserDefaults.standard
            let floor = Int((Date().timeIntervalSince1970 - 1_767_225_600) * 1000)
            let v = max(max(last, d.integer(forKey: "sync.counter")) + 1, floor)
            last = v
            d.set(v, forKey: "sync.counter")
            return v
        }
    }
}

// MARK: - The stamp

/// Who changed something last: device, that device's write counter, time (s since 1970), user (true) or background.
struct SyncChange: Codable, Equatable {
    var d: String
    var n: Int
    var t: Double
    var u: Bool

    /// A change from before stamps existed: seen by everyone, dated by the file.
    static func zero(_ t: Double) -> SyncChange { SyncChange(d: "", n: 0, t: t, u: true) }
}

struct EntryRevision: Codable, Equatable {
    var v = 1
    /// The write that produced this version.
    var d = ""
    var n = 0
    var t: Double = 0
    var vv: [String: Int] = [:]
    var names: [String: String] = [:]
    /// Content hash of the version (everything but the stamp).
    var hash = ""
    var fp: [String: String] = [:]
    var ifp: [String: String] = [:]
    var order = ""
    var keys: [String: SyncChange] = [:]
    var items: [String: SyncChange] = [:]
    var gone: [String: SyncChange] = [:]
    var orderChange: SyncChange?

    enum CodingKeys: String, CodingKey {
        case v, d, n, t, vv, names, hash, fp, ifp, order, keys, items, gone
        case orderChange = "order_change"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        d = try c.decodeIfPresent(String.self, forKey: .d) ?? ""
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 0
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        vv = try c.decodeIfPresent([String: Int].self, forKey: .vv) ?? [:]
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
        fp = try c.decodeIfPresent([String: String].self, forKey: .fp) ?? [:]
        ifp = try c.decodeIfPresent([String: String].self, forKey: .ifp) ?? [:]
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? ""
        keys = try c.decodeIfPresent([String: SyncChange].self, forKey: .keys) ?? [:]
        items = try c.decodeIfPresent([String: SyncChange].self, forKey: .items) ?? [:]
        gone = try c.decodeIfPresent([String: SyncChange].self, forKey: .gone) ?? [:]
        orderChange = try c.decodeIfPresent(SyncChange.self, forKey: .orderChange)
    }

    var jsonObject: Any? {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    static func from(_ any: Any?) -> EntryRevision? {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(EntryRevision.self, from: data)
    }
}

// MARK: - JSON helpers

enum SyncJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func any(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// The app's file style (pretty, sorted keys), as the forward-format carry writes.
    static func data(_ obj: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    /// A short, order-independent fingerprint of a JSON value.
    static func digest(_ value: Any?, length: Int = 12) -> String {
        let wrapped: [Any] = [value ?? NSNull()]
        let bytes = (try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys])) ?? Data()
        return String(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(length))
    }

    /// Hash of an entry's content: everything but the stamp.
    static func contentHash(_ obj: [String: Any]) -> String {
        var o = obj
        o.removeValue(forKey: EntryMerge.stampKey)
        return digest(o, length: 16)
    }

    /// Hash of any library file's content, by value (formatting-blind).
    static func valueHash(_ data: Data) -> String {
        guard let v = any(data) else { return digest(data.base64EncodedString(), length: 16) }
        return digest(v, length: 16)
    }

    static func time(_ any: Any?) -> Double? {
        guard let s = any as? String, let d = try? Date(s, strategy: .iso8601) else { return nil }
        return d.timeIntervalSince1970
    }

    static func iso(_ t: Double) -> String { Date(timeIntervalSince1970: t).formatted(.iso8601) }
}

// MARK: - Entry stamp + merge

enum EntryMerge {
    static let stampKey = "sync_revision"
    /// Changes by a build without stamps (1.0 / 1.0.1) are attributed to this pseudo-device.
    static let legacyDevice = "older-build"

    /// Not merged as fields: the stamp, the derived `updated_at` (max of both), `items` (per item), the immutable id.
    static let structuralKeys: Set<String> = [stampKey, "updated_at", "items", "id"]

    /// Fields whose losing value is worth keeping in the version history (what a person typed or chose). Other
    /// fields (embeddings, analysis, layout) are derived: newest wins silently.
    static let historyKeys: Set<String> = [
        "title", "summary", "tags", "mood", "location", "journal_date", "is_journal_entry", "collection_ids",
        "connections", "cover_image_relative_path", "hero_crop", "priority", "is_private", "per_entry_body_font",
        "description_on_card",
    ]

    static func items(_ obj: [String: Any]) -> [[String: Any]] { obj["items"] as? [[String: Any]] ?? [] }
    static func itemID(_ item: [String: Any]) -> String? { item["id"] as? String }

    struct Prints { var fp: [String: String]; var ifp: [String: String]; var order: String }

    static func prints(_ obj: [String: Any]) -> Prints {
        var fp: [String: String] = [:]
        for (k, v) in obj where !structuralKeys.contains(k) { fp[k] = SyncJSON.digest(v) }
        var ifp: [String: String] = [:]
        var ids: [String] = []
        for item in items(obj) {
            guard let id = itemID(item) else { continue }
            ifp[id] = SyncJSON.digest(item)
            ids.append(id)
        }
        return Prints(fp: fp, ifp: ifp, order: SyncJSON.digest(ids))
    }

    /// Records `change` against every field / item / the order that differs from `base`. No base (a brand-new
    /// entry) → nothing to record.
    static func record(_ p: Prints, against base: EntryRevision?, as change: SyncChange, into rev: inout EntryRevision) {
        guard let base, !base.hash.isEmpty else { return }
        for k in Set(p.fp.keys).union(base.fp.keys) where p.fp[k] != base.fp[k] { rev.keys[k] = change }
        for (id, f) in p.ifp where base.ifp[id] != f { rev.items[id] = change; rev.gone[id] = nil }
        for id in base.ifp.keys where p.ifp[id] == nil { rev.gone[id] = change; rev.items[id] = nil }
        if p.order != base.order { rev.orderChange = change }
    }

    static func setPrints(_ p: Prints, hash: String, on rev: inout EntryRevision) {
        rev.fp = p.fp; rev.ifp = p.ifp; rev.order = p.order; rev.hash = hash
    }

    /// The stamp a file's bytes stand for, made true to its content.
    /// - A stamp whose hash matches → as written.
    /// - No stamp (written before B1) → an unrecorded version: fingerprints only, every change dated by the file.
    /// - A stamp whose hash does NOT match → a build without stamps edited the file and carried the old stamp: the
    ///   fingerprint differences are its changes, recorded as user edits by `older-build` at the file's updated_at.
    static func adopt(_ obj: [String: Any]) -> EntryRevision {
        let hash = SyncJSON.contentHash(obj)
        let p = prints(obj)
        guard var rev = EntryRevision.from(obj[stampKey]) else {
            var r = EntryRevision()
            setPrints(p, hash: hash, on: &r)
            r.t = SyncJSON.time(obj["updated_at"]) ?? 0
            return r
        }
        if rev.hash == hash { return rev }
        let base = rev
        let n = (rev.vv[legacyDevice] ?? 0) + 1
        let t = SyncJSON.time(obj["updated_at"]) ?? rev.t
        record(p, against: base, as: SyncChange(d: legacyDevice, n: n, t: t, u: true), into: &rev)
        rev.vv[legacyDevice] = n
        rev.d = legacyDevice; rev.n = n; rev.t = t
        setPrints(p, hash: hash, on: &rev)
        return rev
    }

    /// The stamp for writing `obj`, whose in-memory copy came from `base`.
    static func stamp(_ obj: [String: Any], base: EntryRevision?, origin: SyncOrigin,
                      device: String = SyncDevice.id, label: String = SyncDevice.label,
                      counter: Int = SyncDevice.nextCounter(), now: Double = Date().timeIntervalSince1970) -> EntryRevision {
        var rev = base ?? EntryRevision()
        let p = prints(obj)
        record(p, against: base, as: SyncChange(d: device, n: counter, t: now, u: origin == .user), into: &rev)
        rev.vv[device] = max(rev.vv[device] ?? 0, counter)
        rev.names[device] = label
        rev.d = device; rev.n = counter; rev.t = now
        setPrints(p, hash: SyncJSON.contentHash(obj), on: &rev)
        return rev
    }

    /// `obj` with `rev` (re-fingerprinted to the content) as its stamp.
    static func stamped(_ obj: [String: Any], _ rev: EntryRevision) -> ([String: Any], EntryRevision) {
        var o = obj
        o.removeValue(forKey: stampKey)
        var r = rev
        setPrints(prints(o), hash: SyncJSON.contentHash(o), on: &r)
        o[stampKey] = r.jsonObject
        return (o, r)
    }

    // MARK: Merge

    struct Side {
        var obj: [String: Any]
        var rev: EntryRevision
    }

    enum Pick { case a, b }

    /// Which of two different values stands. Superseded (one side saw the other's change) → no conflict; else a
    /// conflict: a user edit beats a background pass, then the newer time, then the larger device id (stable).
    static func decide(_ ra: SyncChange, _ vvA: [String: Int], _ rb: SyncChange, _ vvB: [String: Int]) -> (Pick, conflict: Bool) {
        let aSeesB = (vvA[rb.d] ?? 0) >= rb.n
        let bSeesA = (vvB[ra.d] ?? 0) >= ra.n
        if bSeesA && !aSeesB { return (.b, false) }
        if aSeesB && !bSeesA { return (.a, false) }
        if ra.u != rb.u { return (ra.u ? .a : .b, true) }
        if ra.t != rb.t { return (ra.t > rb.t ? .a : .b, true) }
        return (ra.d >= rb.d ? .a : .b, true)
    }

    static func later(_ a: SyncChange?, _ b: SyncChange?) -> SyncChange? {
        guard let a else { return b }
        guard let b else { return a }
        return b.t > a.t ? b : a
    }

    /// A losing value, for `versions.json`.
    struct Loser {
        var kind: String          // "field" | "item"
        var key: String           // field name or item id
        var value: Any?           // the losing value (nil = the field was absent)
        var change: SyncChange    // the loser's change
        var winner: SyncChange
    }

    /// Merges two versions of one entry. `a` is kept for everything both agree on (and its unknown keys); per field
    /// and per item the `decide` rule picks; losers come back for the version history.
    static func merge(_ a: Side, _ b: Side) -> (obj: [String: Any], rev: EntryRevision, losers: [Loser]) {
        var out = a.obj
        var rev = a.rev
        var losers: [Loser] = []
        for (dev, n) in b.rev.vv { rev.vv[dev] = max(rev.vv[dev] ?? 0, n) }
        rev.names.merge(b.rev.names) { x, _ in x }
        let tA = SyncJSON.time(a.obj["updated_at"]) ?? a.rev.t
        let tB = SyncJSON.time(b.obj["updated_at"]) ?? b.rev.t

        // Fields
        for k in Set(a.rev.fp.keys).union(b.rev.fp.keys) where !structuralKeys.contains(k) {
            if a.rev.fp[k] == b.rev.fp[k] { rev.keys[k] = later(a.rev.keys[k], b.rev.keys[k]); continue }
            let ra = a.rev.keys[k] ?? .zero(tA), rb = b.rev.keys[k] ?? .zero(tB)
            let (pick, conflict) = decide(ra, a.rev.vv, rb, b.rev.vv)
            switch pick {
            case .a:
                rev.keys[k] = a.rev.keys[k]
                if conflict && historyKeys.contains(k) {
                    losers.append(Loser(kind: "field", key: k, value: b.obj[k], change: rb, winner: ra))
                }
            case .b:
                out[k] = b.obj[k]
                rev.keys[k] = b.rev.keys[k]
                if conflict && historyKeys.contains(k) {
                    losers.append(Loser(kind: "field", key: k, value: a.obj[k], change: ra, winner: rb))
                }
            }
        }
        if tB > tA { out["updated_at"] = b.obj["updated_at"] }

        // Items
        let itemsA = items(a.obj), itemsB = items(b.obj)
        let byA = Dictionary(itemsA.compactMap { i in itemID(i).map { ($0, i) } }, uniquingKeysWith: { x, _ in x })
        let byB = Dictionary(itemsB.compactMap { i in itemID(i).map { ($0, i) } }, uniquingKeysWith: { x, _ in x })
        func itemTime(_ i: [String: Any], _ fallback: Double) -> Double {
            SyncJSON.time(i["updated_at"]) ?? SyncJSON.time(i["created_at"]) ?? fallback
        }
        var keep: [String: [String: Any]] = [:]
        var gone = a.rev.gone
        for (id, g) in b.rev.gone { gone[id] = later(gone[id], g) }
        rev.items = [:]
        for id in Set(byA.keys).union(byB.keys) {
            switch (byA[id], byB[id]) {
            case let (ia?, ib?):
                let ra = a.rev.items[id] ?? .zero(itemTime(ia, tA)), rb = b.rev.items[id] ?? .zero(itemTime(ib, tB))
                if a.rev.ifp[id] == b.rev.ifp[id] {
                    keep[id] = ia; rev.items[id] = later(a.rev.items[id], b.rev.items[id])
                    continue
                }
                let (pick, conflict) = decide(ra, a.rev.vv, rb, b.rev.vv)
                keep[id] = pick == .a ? ia : ib
                rev.items[id] = pick == .a ? a.rev.items[id] : b.rev.items[id]
                if conflict {
                    losers.append(pick == .a
                        ? Loser(kind: "item", key: id, value: ib, change: rb, winner: ra)
                        : Loser(kind: "item", key: id, value: ia, change: ra, winner: rb))
                }
                gone[id] = nil
            case let (ia?, nil):
                let ra = a.rev.items[id] ?? .zero(itemTime(ia, tA))
                // b deleted it after seeing this version → the delete stands. Otherwise (added or edited where b
                // couldn't see) it stays: an edit is never lost to a delete that didn't see it.
                if b.rev.gone[id] != nil, (b.rev.vv[ra.d] ?? 0) >= ra.n {
                    gone[id] = b.rev.gone[id]
                } else {
                    keep[id] = ia; rev.items[id] = a.rev.items[id]; gone[id] = nil
                }
            case let (nil, ib?):
                let rb = b.rev.items[id] ?? .zero(itemTime(ib, tB))
                if a.rev.gone[id] != nil, (a.rev.vv[rb.d] ?? 0) >= rb.n {
                    gone[id] = a.rev.gone[id]
                } else {
                    keep[id] = ib; rev.items[id] = b.rev.items[id]; gone[id] = nil
                }
            case (nil, nil):
                break
            }
        }
        rev.gone = gone
        rev.items = rev.items.filter { keep[$0.key] != nil }

        // Item order: the side whose order changed last leads; the other's extra items go after their predecessor.
        let orderA = itemsA.compactMap(itemID), orderB = itemsB.compactMap(itemID)
        let (orderPick, _) = decide(a.rev.orderChange ?? .zero(tA), a.rev.vv, b.rev.orderChange ?? .zero(tB), b.rev.vv)
        let (lead, other) = orderPick == .a ? (orderA, orderB) : (orderB, orderA)
        rev.orderChange = orderPick == .a ? a.rev.orderChange : b.rev.orderChange
        var order = lead.filter { keep[$0] != nil }
        var placed = Set(order)
        for (i, id) in other.enumerated() where keep[id] != nil && !placed.contains(id) {
            let prev = other[..<i].last(where: { placed.contains($0) })
            let at = prev.flatMap { p in order.firstIndex(of: p).map { $0 + 1 } } ?? 0
            order.insert(id, at: at)
            placed.insert(id)
        }
        out["items"] = order.compactMap { keep[$0] }
        // Items in neither order (no id) — kept from a.
        let idless = itemsA.filter { itemID($0) == nil }
        if !idless.isEmpty { out["items"] = (out["items"] as? [[String: Any]] ?? []) + idless }
        return (out, rev, losers)
    }
}

// MARK: - Version history (versions.json, one per entry)

enum EntryHistory {
    static let fileName = "versions.json"

    /// A history record (a plain dictionary: the value can be any JSON).
    /// `id`, `at` (ISO), `kind` field|item|restore, `key`, `value`, `from` (device label of the replaced version),
    /// `from_device`, `t` (when that version was made), `state` new|seen|restored.
    static func records(_ losers: [EntryMerge.Loser], names: [String: String], now: Double = Date().timeIntervalSince1970) -> [[String: Any]] {
        losers.map { l in
            [
                // Deterministic: two devices folding the same conflict keep ONE record (the union dedups by id).
                "id": SyncJSON.digest([l.kind, l.key, l.value ?? NSNull(), l.change.d, l.change.n,
                                       l.change.n == 0 ? now : l.change.t], length: 20),
                "at": SyncJSON.iso(now),
                "kind": l.kind,
                "key": l.key,
                "value": l.value ?? NSNull(),
                "from": deviceName(l.change.d, names),
                "from_device": l.change.d,
                "t": l.change.t,
                "state": "new",
            ]
        }
    }

    static func deviceName(_ d: String, _ names: [String: String]) -> String {
        if d == EntryMerge.legacyDevice || d.isEmpty { return "" }
        return names[d] ?? ""
    }

    static let stateRank = ["new": 0, "seen": 1, "restored": 2]

    /// Union by record id; a record's state only moves forward (new → seen → restored).
    static func union(_ a: [[String: Any]], _ b: [[String: Any]]) -> [[String: Any]] {
        var out = a
        var index: [String: Int] = [:]
        for (i, r) in out.enumerated() { if let id = r["id"] as? String { index[id] = i } }
        for r in b {
            guard let id = r["id"] as? String else { continue }
            if let i = index[id] {
                let sa = stateRank[out[i]["state"] as? String ?? "new"] ?? 0
                let sb = stateRank[r["state"] as? String ?? "new"] ?? 0
                if sb > sa { out[i]["state"] = r["state"] }
            } else {
                index[id] = out.count
                out.append(r)
            }
        }
        return out.sorted { (SyncJSON.time($0["at"]) ?? 0) > (SyncJSON.time($1["at"]) ?? 0) }
    }

    static func file(_ records: [[String: Any]]) -> [String: Any] { ["version": 1, "records": records] }
    static func records(in obj: Any?) -> [[String: Any]] { (obj as? [String: Any])?["records"] as? [[String: Any]] ?? [] }
}

// MARK: - Library-wide files (tags, collections, field definitions, chats, layouts, index)

enum AggregateMerge {
    /// Derived or regenerable: this device's write stands.
    static let mineWins: Set<String> = [
        "corpus_index.json", "corpus_routing_diagnostics.json", "sample_library.json", "card.json", "blocks.json",
    ]

    /// Three-way merge of a library file: `base` = what this device last read or wrote (nil if never read this run),
    /// `mine` = what it's writing, `disk` = what's there now (another device's change). Elements are matched by `id`
    /// (arrays) or by key (dictionaries); an element changed on one side takes that side; changed on both → mine
    /// (written now = newest), except a chat, whose messages are united; added on either side → kept; deleted on one
    /// side and untouched on the other → deleted. No base → a union (nothing dropped).
    static func merge3(file: String, base: Any?, mine: Any, disk: Any) -> Any {
        if mineWins.contains(file) { return mine }
        if file == EntryHistory.fileName {
            return EntryHistory.file(EntryHistory.union(EntryHistory.records(in: mine), EntryHistory.records(in: disk)))
        }
        switch (mine, disk) {
        case let (m as [[String: Any]], d as [[String: Any]]):
            return byID(base: base as? [[String: Any]], mine: m, disk: d, nested: file == "chats.json" ? "messages" : nil)
        case let (m as [String: Any], d as [String: Any]):
            let b = base as? [String: Any]
            if let mp = m["positions"] as? [String: Any], let dp = d["positions"] as? [String: Any] {
                var out = m
                out["positions"] = byKey(base: b?["positions"] as? [String: Any], mine: mp, disk: dp)
                return out
            }
            if let md = m["definitions"] as? [[String: Any]], let dd = d["definitions"] as? [[String: Any]] {
                var out = m
                out["definitions"] = byID(base: b?["definitions"] as? [[String: Any]], mine: md, disk: dd, nested: nil)
                return out
            }
            if file == "territory_layout.json" { return byKey(base: b, mine: m, disk: d) }
            return mine
        default:
            return mine
        }
    }

    static func same(_ x: Any?, _ y: Any?) -> Bool { SyncJSON.digest(x) == SyncJSON.digest(y) }

    static func byID(base: [[String: Any]]?, mine: [[String: Any]], disk: [[String: Any]], nested: String?) -> [[String: Any]] {
        func key(_ e: [String: Any]) -> String? { (e["id"] as? String) ?? (e["id"] as? NSNumber)?.stringValue }
        let b = Dictionary((base ?? []).compactMap { e in key(e).map { ($0, e) } }, uniquingKeysWith: { x, _ in x })
        let d = Dictionary(disk.compactMap { e in key(e).map { ($0, e) } }, uniquingKeysWith: { x, _ in x })
        let hasBase = base != nil
        var out: [[String: Any]] = []
        var seen = Set<String>()
        for m in mine {
            guard let id = key(m) else { out.append(m); continue }
            seen.insert(id)
            if let de = d[id] {
                if same(m, de) { out.append(m); continue }
                if let be = b[id] {
                    if same(m, be) { out.append(de); continue }
                    if same(de, be) { out.append(m); continue }
                }
                if let nested { out.append(unite(nested, base: b[id], mine: m, disk: de)) } else { out.append(m) }
            } else if hasBase, let be = b[id], same(m, be) {
                continue   // deleted on the other device, untouched here → deleted
            } else {
                out.append(m)
            }
        }
        for de in disk {
            guard let id = key(de), !seen.contains(id) else { continue }
            if hasBase, let be = b[id], same(de, be) { continue }   // deleted here, untouched there → deleted
            out.append(de)
        }
        return out
    }

    static func unite(_ nested: String, base: [String: Any]?, mine: [String: Any], disk: [String: Any]) -> [String: Any] {
        var out = mine
        out[nested] = byID(base: base?[nested] as? [[String: Any]], mine: mine[nested] as? [[String: Any]] ?? [],
                           disk: disk[nested] as? [[String: Any]] ?? [], nested: nil)
        if let tm = SyncJSON.time(mine["updatedAt"] ?? mine["updated_at"]),
           let td = SyncJSON.time(disk["updatedAt"] ?? disk["updated_at"]), td > tm {
            if disk["updatedAt"] != nil { out["updatedAt"] = disk["updatedAt"] } else { out["updated_at"] = disk["updated_at"] }
        }
        return out
    }

    static func byKey(base: [String: Any]?, mine: [String: Any], disk: [String: Any]) -> [String: Any] {
        var out = mine
        for (k, dv) in disk {
            if let mv = mine[k] {
                if !same(mv, dv), let bv = base?[k], same(mv, bv) { out[k] = dv }
            } else if base?[k] == nil || !same(dv, base?[k]) {
                out[k] = dv   // added there (or changed there after I deleted it)
            }
        }
        if let base {
            for (k, mv) in mine where disk[k] == nil {
                if let bv = base[k], same(mv, bv) { out.removeValue(forKey: k) }   // deleted there, untouched here
            }
        }
        return out
    }
}

// MARK: - What this device last read / wrote (process-wide; CorpusStore and ChatStore share the root)

enum SyncBases {
    private static let reads = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
    private static let own = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// A library file as this device last saw it (the base of its next three-way merge).
    static func noteRead(_ url: URL, _ data: Data) { reads.withLock { $0[url.standardizedFileURL.path] = data } }
    static func base(_ url: URL) -> Data? { reads.withLock { $0[url.standardizedFileURL.path] } }

    /// The content hash this device last wrote to `url`: finding it on disk means nobody else changed the file since.
    static func noteOwnWrite(_ url: URL, hash: String) { own.withLock { $0[url.standardizedFileURL.path] = hash } }
    static func isOwnLast(_ url: URL, hash: String) -> Bool { own.withLock { $0[url.standardizedFileURL.path] == hash } }

    #if DEBUG
    static func resetForSelfTest() { reads.withLock { $0 = [:] }; own.withLock { $0 = [:] } }
    #endif
}
